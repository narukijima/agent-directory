#!/usr/bin/env python3
"""Deterministically score an Agent Directory behavioral trace."""

import argparse
import fnmatch
import json
from pathlib import Path
import re
import sys


MAP_EXPECTATIONS = {"must_search"}
SUPPORTED_EXPECTATIONS = {
    "route", "must_search", "max_candidates", "must_read", "must_not_read",
    "max_read_files", "max_context_bytes", "must_run", "must_not_run",
    "must_update", "must_not_write", "may_write", "must_preserve", "must_set",
    "must_report", "must_not_report",
}


class EvalError(Exception):
    pass


def strip_yaml_comment(value):
    quote = None
    escaped = False
    for index, character in enumerate(value):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote == '"':
            escaped = True
            continue
        if character in {"'", '"'}:
            if quote == character:
                quote = None
            elif quote is None:
                quote = character
            continue
        if character == "#" and quote is None and (index == 0 or value[index - 1].isspace()):
            return value[:index].rstrip()
    return value.rstrip()


def yaml_scalar(value):
    value = strip_yaml_comment(value.strip())
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return json.loads(value)
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1].replace("''", "'")
    if re.fullmatch(r"[0-9]+", value):
        return int(value)
    if value in {"true", "false"}:
        return value == "true"
    return value


def parse_case(path):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise EvalError("cannot read case %s: %s" % (path, error))
    case = {"expect": {}, "report_match": {}, "request": ""}
    section = None
    subsection = None
    request_lines = []
    in_request = False
    for raw_line in lines:
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        stripped = raw_line.strip()
        if in_request:
            if stripped and indent == 0:
                in_request = False
            else:
                request_lines.append(raw_line[2:] if raw_line.startswith("  ") else raw_line)
                continue
        if not stripped or stripped.startswith("#"):
            continue
        if indent == 0:
            if ":" not in stripped:
                raise EvalError("invalid top-level case line: %s" % raw_line)
            key, value = stripped.split(":", 1)
            value = strip_yaml_comment(value.strip())
            subsection = None
            if key == "request" and value == "|":
                in_request = True
                section = "request"
            elif key in {"expect", "report_match"} and not value:
                section = key
            else:
                case[key] = yaml_scalar(value)
                section = None
            continue
        if section == "expect" and indent == 2:
            if ":" not in stripped:
                raise EvalError("invalid expectation line: %s" % raw_line)
            key, value = stripped.split(":", 1)
            value = strip_yaml_comment(value.strip())
            if value:
                case["expect"][key] = yaml_scalar(value)
                subsection = None
            else:
                case["expect"][key] = {} if key in MAP_EXPECTATIONS else []
                subsection = key
            continue
        if section == "expect" and indent == 4 and subsection:
            if stripped.startswith("- "):
                if not isinstance(case["expect"][subsection], list):
                    raise EvalError("list item under map expectation %s" % subsection)
                case["expect"][subsection].append(yaml_scalar(stripped[2:]))
            elif ":" in stripped:
                if not isinstance(case["expect"][subsection], dict):
                    raise EvalError("map item under list expectation %s" % subsection)
                key, value = stripped.split(":", 1)
                case["expect"][subsection][key] = yaml_scalar(value)
            else:
                raise EvalError("invalid nested expectation line: %s" % raw_line)
            continue
        if section == "report_match" and indent == 2:
            if not stripped.endswith(":"):
                raise EvalError("invalid report_match slug: %s" % raw_line)
            subsection = stripped[:-1]
            case["report_match"][subsection] = []
            continue
        if section == "report_match" and indent == 4 and subsection and stripped.startswith("- "):
            case["report_match"][subsection].append(yaml_scalar(stripped[2:]))
            continue
        raise EvalError("unsupported case schema line: %s" % raw_line)
    case["request"] = "\n".join(request_lines).rstrip() + ("\n" if request_lines else "")
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", str(case.get("name", ""))):
        raise EvalError("case has an invalid or missing name")
    if not isinstance(case.get("expect"), dict) or "route" not in case["expect"]:
        raise EvalError("case must declare expect.route")
    return case


def load_trace(path):
    events = []
    try:
        with path.open(encoding="utf-8") as stream:
            for line_number, line in enumerate(stream, 1):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as error:
                    raise EvalError("%s:%d invalid JSON: %s" % (path, line_number, error))
                if not isinstance(event, dict) or not isinstance(event.get("event"), str):
                    raise EvalError("%s:%d trace event must be an object with event" % (path, line_number))
                events.append(event)
    except OSError as error:
        raise EvalError("cannot read trace %s: %s" % (path, error))
    if not events:
        raise EvalError("trace is empty: %s" % path)
    return events


def validate_case(case, repo_root):
    unknown = sorted(set(case["expect"]) - SUPPORTED_EXPECTATIONS)
    if unknown:
        raise EvalError("case %s has unsupported expectations: %s" % (case["name"], unknown))
    if case["expect"].get("route") not in {"knowledge", "skill", "project", "meta"}:
        raise EvalError("case %s has an invalid route" % case["name"])
    fixture = case.get("fixture")
    if fixture:
        fixture_root = (repo_root / "tests" / "evals" / "fixtures" / str(fixture)).resolve()
        try:
            fixture_root.relative_to((repo_root / "tests" / "evals" / "fixtures").resolve())
        except ValueError:
            raise EvalError("case %s fixture escapes tests/evals/fixtures" % case["name"])
        if not fixture_root.is_dir():
            raise EvalError("case %s fixture does not exist: %s" % (case["name"], fixture))
    report_tokens = set(case["expect"].get("must_report", [])) | set(case["expect"].get("must_not_report", []))
    missing_patterns = sorted(str(token) for token in report_tokens if str(token) not in case["report_match"])
    if missing_patterns:
        raise EvalError("case %s has report tokens without patterns: %s" % (case["name"], missing_patterns))
    return case


def path_matches(pattern, actual):
    return actual == pattern or fnmatch.fnmatchcase(actual, pattern)


def command_matches(expected, actual):
    expected = " ".join(str(expected).split())
    actual = " ".join(str(actual).split())
    return actual == expected or actual.startswith(expected + " ")


def score_case(case, events):
    trace_headers = [event for event in events if event["event"] == "trace"]
    if not trace_headers:
        raise EvalError("trace must begin with a trace event")
    header = trace_headers[0]
    if header.get("case") != case["name"]:
        raise EvalError("trace case does not match: %s" % header.get("case"))
    coverage = set(header.get("coverage", []))
    reads = [event for event in events if event["event"] == "read" and isinstance(event.get("path"), str)]
    runs = [event for event in events if event["event"] == "run" and isinstance(event.get("command"), str)]
    writes = [event for event in events if event["event"] == "write" and isinstance(event.get("path"), str)]
    searches = [event for event in events if event["event"] == "search"]
    states = [event for event in events if event["event"] == "state"]
    final_text = "\n".join(
        event.get("text", "") for event in events
        if event["event"] == "final_response" and isinstance(event.get("text"), str)
    )
    checks = []

    def add(name, status, detail):
        checks.append({"check": name, "status": status, "detail": detail})

    def observed_or_unverified(kind, passed, detail):
        return ("PASS" if passed else "FAIL") if kind in coverage else "UNVERIFIED", detail

    for key, expected in case["expect"].items():
        if key == "route":
            values = [event.get("route") for event in events if event["event"] == "route"]
            status, detail = observed_or_unverified("route", expected in values, "observed=%s expected=%s" % (values, expected))
            add(key, status, detail)
        elif key == "must_search":
            matched = [event for event in searches if all(str(event.get(name, "")) == str(value) for name, value in expected.items())]
            status, detail = observed_or_unverified("search", bool(matched), "expected=%s" % expected)
            add(key, status, detail)
        elif key == "max_candidates":
            values = [event.get("returned") for event in searches if isinstance(event.get("returned"), int)]
            status, detail = observed_or_unverified("search", not any(value > expected for value in values),
                                                    "observed=%s limit=%s" % (values, expected))
            add(key, status, detail)
        elif key in {"must_read", "must_not_read"}:
            actual = [event["path"] for event in reads]
            if key == "must_read":
                missing = [pattern for pattern in expected if not any(path_matches(pattern, path) for path in actual)]
                passed, detail = not missing, "missing=%s" % missing
            else:
                forbidden = [path for path in actual if any(path_matches(pattern, path) for pattern in expected)]
                passed, detail = not forbidden, "forbidden=%s" % forbidden
            status, detail = observed_or_unverified("read", passed, detail)
            add(key, status, detail)
        elif key == "max_read_files":
            count = len({event["path"] for event in reads})
            status, detail = observed_or_unverified("read", count <= expected, "observed=%d limit=%s" % (count, expected))
            add(key, status, detail)
        elif key == "max_context_bytes":
            total = sum(event.get("bytes", 0) for event in reads if isinstance(event.get("bytes"), int))
            status, detail = observed_or_unverified("read", total <= expected, "observed=%d limit=%s" % (total, expected))
            add(key, status, detail)
        elif key in {"must_run", "must_not_run"}:
            actual = [event["command"] for event in runs]
            if key == "must_run":
                missing = [command for command in expected if not any(command_matches(command, item) for item in actual)]
                passed, detail = not missing, "missing=%s" % missing
            else:
                forbidden = [item for item in actual if any(command_matches(command, item) for command in expected)]
                passed, detail = not forbidden, "forbidden=%s" % forbidden
            status, detail = observed_or_unverified("run", passed, detail)
            add(key, status, detail)
        elif key in {"must_update", "must_not_write", "may_write", "must_preserve"}:
            actual = [event["path"] for event in writes]
            if key == "must_update":
                missing = [pattern for pattern in expected if not any(
                    path_matches(pattern, event["path"]) and event.get("operation") in {"update", "create", "delete"}
                    for event in writes)]
                passed, detail = not missing, "missing=%s" % missing
            elif key == "must_not_write":
                forbidden = [path for path in actual if any(path_matches(pattern, path) for pattern in expected)]
                passed, detail = not forbidden, "forbidden=%s" % forbidden
            elif key == "may_write":
                outside = [path for path in actual if not any(path_matches(pattern, path) for pattern in expected)]
                passed, detail = not outside, "outside=%s" % outside
            else:
                changed = [path for path in actual if any(path_matches(pattern, path) for pattern in expected)]
                passed, detail = not changed, "changed=%s" % changed
            status, detail = observed_or_unverified("write", passed, detail)
            add(key, status, detail)
        elif key == "must_set":
            missing = []
            for expression in expected:
                left, separator, value = str(expression).partition("=")
                path, marker, field = left.partition("#")
                if not separator or not marker or not any(
                    event.get("path") == path and event.get("field") == field and str(event.get("value")) == value
                    for event in states
                ):
                    missing.append(expression)
            status, detail = observed_or_unverified("state", not missing, "missing=%s" % missing)
            add(key, status, detail)
        elif key in {"must_report", "must_not_report"}:
            matches = []
            for slug in expected:
                patterns = case["report_match"].get(str(slug), [])
                if not patterns:
                    raise EvalError("report token has no report_match patterns: %s" % slug)
                if all(re.search(str(pattern), final_text, re.IGNORECASE) for pattern in patterns):
                    matches.append(slug)
            passed = len(matches) == len(expected) if key == "must_report" else not matches
            detail = "matched=%s expected=%s" % (matches, expected)
            status, detail = observed_or_unverified("final_response", passed, detail)
            add(key, status, detail)
        else:
            add(key, "UNVERIFIED", "scorer has no observation for this expectation")

    pass_count = sum(check["status"] == "PASS" for check in checks)
    fail_count = sum(check["status"] == "FAIL" for check in checks)
    unverified_count = sum(check["status"] == "UNVERIFIED" for check in checks)
    status = "FAIL" if fail_count else ("UNVERIFIED" if unverified_count else "PASS")
    return {
        "schema_version": 1,
        "case": case["name"],
        "status": status,
        "checks": checks,
        "pass_checks": pass_count,
        "fail_checks": fail_count,
        "unverified_checks": unverified_count,
    }


def resolve_case(repo_root, value):
    candidate = Path(value)
    if not candidate.is_file():
        candidate = repo_root / "tests" / "evals" / "cases" / (value if value.endswith(".yaml") else value + ".yaml")
    if not candidate.is_file():
        raise EvalError("case does not exist: %s" % value)
    return candidate.resolve()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    score = subparsers.add_parser("score", help="score one existing JSONL trace")
    score.add_argument("--case", required=True)
    score.add_argument("--trace", required=True)
    score.add_argument("--json", action="store_true")
    subparsers.add_parser("validate", help="validate every repository behavioral case schema")
    return parser


def main():
    args = build_parser().parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    try:
        if args.command == "validate":
            case_paths = sorted((repo_root / "tests" / "evals" / "cases").glob("*.yaml"))
            for case_path in case_paths:
                validate_case(parse_case(case_path), repo_root)
            print("EVAL_CASES_VALID count=%d" % len(case_paths))
            return 0
        case = validate_case(parse_case(resolve_case(repo_root, args.case)), repo_root)
        summary = score_case(case, load_trace(Path(args.trace).resolve()))
    except EvalError as error:
        print("EVAL_ERROR: %s" % error, file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print("EVAL_RESULT case=%s status=%s pass=%d fail=%d unverified=%d" %
              (summary["case"], summary["status"], summary["pass_checks"],
               summary["fail_checks"], summary["unverified_checks"]))
    return 0 if summary["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
