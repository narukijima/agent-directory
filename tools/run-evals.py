#!/usr/bin/env python3
"""Run or score agent-directory behavior evals without a model dependency."""

import argparse
import datetime as dt
import fnmatch
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


TRUSTED_SOURCES = {"client", "harness"}
MAP_EXPECTATIONS = {"must_search", "must_not_search", "must_prefer"}


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
        try:
            return json.loads(value)
        except json.JSONDecodeError as error:
            raise EvalError("invalid quoted YAML scalar: %s" % error)
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


def path_matches(pattern, actual):
    return actual == pattern or fnmatch.fnmatchcase(actual, pattern)


def command_matches(expected, actual):
    expected = " ".join(str(expected).split())
    actual = " ".join(str(actual).split())
    return actual == expected or actual.startswith(expected + " ")


def baseline_case(baseline, name):
    if not baseline:
        return None
    if baseline.get("case") == name:
        return baseline
    for item in baseline.get("cases", []):
        if item.get("case") == name:
            return item
    return None


def compare_regression(summary, baseline, percent):
    previous = baseline_case(baseline, summary["case"])
    if not previous:
        return []
    regressions = []
    current_metrics = summary["metrics"]
    old_metrics = previous.get("metrics", {})

    def numeric(name, floor, absolute_slack=0):
        current = current_metrics.get(name)
        old = old_metrics.get(name)
        if not isinstance(current, (int, float)) or not isinstance(old, (int, float)) or old < floor:
            return
        limit = max(old * (1 + percent / 100.0), old + absolute_slack)
        if current > limit:
            regressions.append({"metric": name, "before": old, "after": current, "limit": limit})

    numeric("wall_time_ms", 100, 100)
    numeric("tool_calls", 1, 1)
    numeric("read_file_count", 1, 1)
    numeric("context_bytes", 1024, 1024)
    old_rate = previous.get("verified_check_rate")
    if isinstance(old_rate, (int, float)) and summary["verified_check_rate"] + 0.0001 < old_rate:
        regressions.append({"metric": "verified_check_rate", "before": old_rate,
                            "after": summary["verified_check_rate"], "limit": old_rate})
    old_route = old_metrics.get("route_accuracy")
    new_route = current_metrics.get("route_accuracy")
    if old_route == 1 and new_route != 1:
        regressions.append({"metric": "route_accuracy", "before": old_route,
                            "after": new_route, "limit": 1})
    for phase, current in current_metrics.get("phase_duration_ms", {}).items():
        old = old_metrics.get("phase_duration_ms", {}).get(phase)
        if isinstance(old, (int, float)) and old >= 100 and current > max(old * (1 + percent / 100.0), old + 100):
            regressions.append({"metric": "phase_duration_ms.%s" % phase,
                                "before": old, "after": current,
                                "limit": max(old * (1 + percent / 100.0), old + 100)})
    return regressions


def average(values):
    numeric = [value for value in values if isinstance(value, (int, float))]
    return sum(numeric) / len(numeric) if numeric else None


def amplification(aged, clean):
    if not isinstance(aged, (int, float)) or not isinstance(clean, (int, float)) or clean <= 0:
        return None
    return aged / clean


def decay_definitions(cases):
    paired_cases = [case for case in cases if "decay_pair" in case or "decay_variant" in case]
    if not paired_cases:
        return {}, []

    pairs = {}
    errors = []
    for case in paired_cases:
        pair = case.get("decay_pair")
        variant = case.get("decay_variant")
        if not isinstance(pair, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", pair):
            errors.append("%s has an invalid decay_pair" % case["name"])
            continue
        if variant not in {"clean", "aged"}:
            errors.append("%s has an invalid decay_variant" % case["name"])
            continue
        pair_entry = pairs.setdefault(pair, {})
        if variant in pair_entry:
            errors.append("%s repeats decay_variant=%s" % (pair, variant))
            continue
        pair_entry[variant] = case

    complete_pairs = {}
    for pair, variants in pairs.items():
        if set(variants) != {"clean", "aged"}:
            errors.append("%s must include one clean and one aged case" % pair)
            continue
        if variants["clean"]["request"] != variants["aged"]["request"]:
            errors.append("%s clean and aged requests differ" % pair)
            continue
        complete_pairs[pair] = variants
    return complete_pairs, errors


def decay_comparison(cases, results, regression_percent):
    complete_pairs, errors = decay_definitions(cases)
    if not complete_pairs and not errors:
        return None

    results_by_case = {result["case"]: result for result in results}
    variant_results = {"clean": [], "aged": []}
    stale_results = {"clean": [], "aged": []}
    for variants in complete_pairs.values():
        for variant, case in variants.items():
            result = results_by_case.get(case["name"])
            if result:
                variant_results[variant].append(result)
                if case.get("decay_stale_check") is True:
                    stale_results[variant].append(result)

    def success_rate(variant):
        items = variant_results[variant]
        return sum(item.get("status") == "PASS" for item in items) / len(items) if items else None

    def metric_average(variant, name):
        return average([item.get("metrics", {}).get(name) for item in variant_results[variant]])

    def stale_rate(variant):
        covered = [item for item in stale_results[variant]
                   if item.get("metrics", {}).get("reference_coverage") is True]
        if not covered:
            return None
        return sum(item.get("metrics", {}).get("forbidden_reference_count", 0) > 0
                   for item in covered) / len(covered)

    def verification_rate(variant):
        checks = []
        for item in variant_results[variant]:
            checks.extend(check for check in item.get("checks", [])
                          if check.get("check", "").startswith("must_run:") and
                          re.search(r"(verify|validat)", check.get("check", ""), re.IGNORECASE))
        return sum(check.get("status") == "PASS" for check in checks) / len(checks) if checks else None

    clean_success = success_rate("clean")
    aged_success = success_rate("aged")
    clean_reads = metric_average("clean", "read_file_count")
    aged_reads = metric_average("aged", "read_file_count")
    clean_context = metric_average("clean", "context_bytes")
    aged_context = metric_average("aged", "context_bytes")
    clean_tools = metric_average("clean", "tool_calls")
    aged_tools = metric_average("aged", "tool_calls")
    clean_stale = stale_rate("clean")
    aged_stale = stale_rate("aged")
    metrics = {
        "clean_success_rate": clean_success,
        "aged_success_rate": aged_success,
        "clean_avg_reads": clean_reads,
        "aged_avg_reads": aged_reads,
        "clean_avg_context_bytes": clean_context,
        "aged_avg_context_bytes": aged_context,
        "clean_avg_tool_calls": clean_tools,
        "aged_avg_tool_calls": aged_tools,
        "clean_avg_escalations": metric_average("clean", "human_intervention_count"),
        "aged_avg_escalations": metric_average("aged", "human_intervention_count"),
        "clean_stale_reference_rate": clean_stale,
        "aged_stale_reference_rate": aged_stale,
        "clean_verification_success_rate": verification_rate("clean"),
        "aged_verification_success_rate": verification_rate("aged"),
        "success_delta": aged_success - clean_success
        if isinstance(aged_success, (int, float)) and isinstance(clean_success, (int, float)) else None,
        "read_amplification": amplification(aged_reads, clean_reads),
        "context_amplification": amplification(aged_context, clean_context),
        "tool_call_amplification": amplification(aged_tools, clean_tools),
    }

    checks = []

    def gate(name, passed, detail):
        checks.append({"check": name, "status": "PASS" if passed else "FAIL", "detail": detail})

    complete = not errors and len(variant_results["clean"]) == len(complete_pairs) and \
        len(variant_results["aged"]) == len(complete_pairs)
    gate("complete-pairs", complete, "; ".join(errors) if errors else "all pairs are complete")
    all_observed = complete and all(item.get("status") not in {"UNVERIFIED", "INFRA"}
                                    for variant in variant_results.values() for item in variant)
    gate("trusted-observation", all_observed, "all paired cases are mechanically observed")
    if metrics["success_delta"] is not None:
        gate("success-delta", metrics["success_delta"] >= 0,
             "observed=%s limit=>=0" % metrics["success_delta"])
    read_limit = max(clean_reads * (1 + regression_percent / 100.0), clean_reads + 1) \
        if isinstance(clean_reads, (int, float)) else None
    if read_limit is not None and isinstance(aged_reads, (int, float)):
        gate("read-amplification", aged_reads <= read_limit,
             "aged=%s limit=%s" % (aged_reads, read_limit))
    context_limit = max(clean_context * (1 + regression_percent / 100.0), clean_context + 1024) \
        if isinstance(clean_context, (int, float)) else None
    if context_limit is not None and isinstance(aged_context, (int, float)):
        gate("context-amplification", aged_context <= context_limit,
             "aged=%s limit=%s" % (aged_context, context_limit))
    if stale_results["clean"] or stale_results["aged"]:
        stale_observed = clean_stale is not None and aged_stale is not None
        gate("stale-reference-observation", stale_observed,
             "trusted reference coverage is required for stale-sensitive pairs")
        if stale_observed:
            gate("aged-stale-reference-rate", aged_stale == 0,
                 "observed=%s limit=0" % aged_stale)

    has_failed_gate = any(check["status"] == "FAIL" for check in checks)
    unverified_gate = not complete or not all_observed or \
        any(check["check"] == "stale-reference-observation" and check["status"] == "FAIL" for check in checks)
    status = "UNVERIFIED" if unverified_gate else ("FAIL" if has_failed_gate else "PASS")
    return {"schema_version": 1, "status": status, "pair_count": len(complete_pairs),
            "regression_percent": regression_percent, "metrics": metrics, "checks": checks}


def score_case(case, events, baseline=None, regression_percent=20):
    header = next((event for event in events if event["event"] == "trace"), {})
    if header.get("case") and header["case"] != case["name"]:
        raise EvalError("trace case %s does not match %s" % (header["case"], case["name"]))
    trace_source = header.get("source")
    raw_coverage = header.get("coverage", [])
    if not isinstance(raw_coverage, list) or not all(isinstance(item, str) for item in raw_coverage):
        raise EvalError("trace coverage must be a list of event names")
    coverage = set(raw_coverage) if trace_source in TRUSTED_SOURCES else set()

    def trusted(event):
        return event.get("source", trace_source) in TRUSTED_SOURCES

    observed = [event for event in events if trusted(event)]
    checks = []

    def add(name, status, detail):
        checks.append({"check": name, "status": status, "detail": detail})

    def absent_status(category):
        return "FAIL" if category in coverage else "UNVERIFIED"

    reads = [event for event in observed if event["event"] == "read" and isinstance(event.get("path"), str)]
    runs = [event for event in observed if event["event"] == "run" and isinstance(event.get("command"), str)]
    writes = [event for event in observed if event["event"] == "write" and isinstance(event.get("path"), str)]
    searches = [event for event in observed if event["event"] == "search"]
    states = [event for event in observed if event["event"] == "state"]
    references = [event for event in observed if event["event"] == "reference"]
    finals = [event for event in observed if event["event"] == "final_response" and isinstance(event.get("text"), str)]

    for key, expected in case["expect"].items():
        if key == "route":
            routes = [event.get("route") for event in observed if event["event"] == "route"]
            if routes:
                add("route", "PASS" if routes[-1] == expected else "FAIL",
                    "observed=%s expected=%s" % (routes[-1], expected))
            else:
                add("route", "UNVERIFIED", "trusted route event is unavailable")
        elif key in {"must_read", "must_not_read"}:
            negative = key == "must_not_read"
            for item in expected:
                matches = [event["path"] for event in reads if path_matches(str(item), event["path"])]
                if negative:
                    status = "FAIL" if matches else ("PASS" if "read" in coverage else "UNVERIFIED")
                else:
                    status = "PASS" if matches else absent_status("read")
                add("%s:%s" % (key, item), status,
                    "observed" if matches else "no matching trusted read event")
        elif key in {"must_run", "must_not_run"}:
            negative = key == "must_not_run"
            for item in expected:
                matches = [event for event in runs if command_matches(item, event["command"])]
                if negative:
                    add("%s:%s" % (key, item),
                        "FAIL" if matches else ("PASS" if "run" in coverage else "UNVERIFIED"),
                        "observed" if matches else "no matching trusted run event")
                else:
                    # EVALS.md examines the exit code: a required command that ran and
                    # failed is not satisfied evidence (a mere attempt must not pass).
                    succeeded = [event for event in matches if event.get("exit_code", 0) == 0]
                    add("%s:%s" % (key, item),
                        "PASS" if succeeded else absent_status("run"),
                        "observed" if succeeded else
                        ("matching run event(s) exited nonzero" if matches
                         else "no matching trusted run event"))
        elif key == "must_not_write":
            for item in expected:
                matches = [event["path"] for event in writes if path_matches(str(item), event["path"])]
                add("%s:%s" % (key, item), "FAIL" if matches else
                    ("PASS" if "write" in coverage else "UNVERIFIED"),
                    "observed forbidden write" if matches else "no matching trusted write event")
        elif key == "must_update":
            for item in expected:
                matches = [event for event in writes if path_matches(str(item), event["path"]) and
                           event.get("operation") in {"create", "update"}]
                add("must_update:%s" % item, "PASS" if matches else absent_status("write"),
                    "observed" if matches else "no matching trusted update event")
        elif key == "may_write":
            unexpected = [event["path"] for event in writes
                          if not any(path_matches(str(item), event["path"]) for item in expected)]
            add("may_write", "FAIL" if unexpected else ("PASS" if "write" in coverage else "UNVERIFIED"),
                "unexpected=%s" % unexpected if unexpected else "all observed writes are allowed")
        elif key == "must_not_reference":
            for item in expected:
                matches = [event.get("target") for event in references
                           if isinstance(event.get("target"), str) and path_matches(str(item), event["target"])]
                add("must_not_reference:%s" % item, "FAIL" if matches else
                    ("PASS" if "reference" in coverage else "UNVERIFIED"),
                    "observed forbidden reference" if matches else "no matching trusted reference event")
        elif key == "must_set":
            for item in expected:
                reference, separator, value = str(item).partition("=")
                matches = [event for event in states if event.get("reference") == reference and
                           (not separator or str(event.get("value")) == value)]
                add("must_set:%s" % item, "PASS" if matches else absent_status("state"),
                    "observed" if matches else "no matching trusted state event")
        elif key == "must_preserve":
            for item in expected:
                matches = [event for event in states if event.get("reference") == item and event.get("preserved") is True]
                add("must_preserve:%s" % item, "PASS" if matches else absent_status("state"),
                    "observed" if matches else "no trusted preservation evidence")
        elif key == "must_report":
            response = finals[-1]["text"] if finals else None
            for slug in expected:
                patterns = case.get("report_match", {}).get(slug, [])
                if not patterns:
                    add("must_report:%s" % slug, "UNVERIFIED", "report_match has no deterministic patterns")
                    continue
                if response is None:
                    add("must_report:%s" % slug, absent_status("final_response"),
                        "trusted final_response is unavailable")
                    continue
                matched = True
                try:
                    for pattern in patterns:
                        if re.search(str(pattern), response, re.IGNORECASE) is None:
                            matched = False
                except re.error as error:
                    raise EvalError("invalid report_match regex for %s: %s" % (slug, error))
                add("must_report:%s" % slug, "PASS" if matched else "FAIL",
                    "all patterns matched" if matched else "one or more patterns did not match")
        elif key in {"must_search", "must_not_search"}:
            matches = [event for event in searches
                       if command_matches(expected.get("command", ""), event.get("command", "")) and
                       ("status" not in expected or event.get("status") == expected["status"])]
            if key == "must_not_search":
                add("must_not_search", "FAIL" if matches else
                    ("PASS" if "search" in coverage else "UNVERIFIED"),
                    "observed forbidden search" if matches else "no matching trusted search event")
            else:
                add("must_search", "PASS" if matches else absent_status("search"),
                    "observed" if matches else "no matching trusted search event")
        elif key == "must_prefer":
            wanted = expected.get("status")
            selected = []
            for event in searches:
                selected.extend(event.get("selected_statuses", []))
            if selected:
                add("must_prefer", "PASS" if selected[0] == wanted else "FAIL",
                    "selected_statuses=%s" % selected)
            else:
                add("must_prefer", absent_status("search"), "selected status evidence is unavailable")
        elif key == "fallback":
            modes = [event.get("mode") for event in observed if event["event"] == "fallback"]
            invalid = [mode for mode in modes if mode not in expected]
            add("fallback", "FAIL" if invalid else ("PASS" if "fallback" in coverage else "UNVERIFIED"),
                "unexpected=%s" % invalid if invalid else "observed fallback modes are allowed")
        elif key == "max_candidates":
            values = [event.get("returned") for event in searches if isinstance(event.get("returned"), int)]
            too_many = [value for value in values if value > expected]
            add("max_candidates", "FAIL" if too_many else
                ("PASS" if "search" in coverage else "UNVERIFIED"),
                "observed=%s limit=%s" % (values, expected))
        elif key == "max_read_files":
            count = len({event["path"] for event in reads})
            status = "FAIL" if count > expected else ("PASS" if "read" in coverage else "UNVERIFIED")
            add("max_read_files", status, "observed=%d limit=%s" % (count, expected))
        elif key == "max_context_bytes":
            total = sum(event.get("bytes", 0) for event in reads if isinstance(event.get("bytes"), int))
            status = "FAIL" if total > expected else ("PASS" if "read" in coverage else "UNVERIFIED")
            add("max_context_bytes", status, "observed=%d limit=%s" % (total, expected))
        elif key == "max_escalations":
            count = sum(event["event"] == "escalation" for event in observed)
            status = "FAIL" if count > expected else ("PASS" if "escalation" in coverage else "UNVERIFIED")
            add("max_escalations", status, "observed=%d limit=%s" % (count, expected))
        else:
            add(key, "UNVERIFIED", "scorer has no mechanical observation for this expectation")

    pass_count = sum(check["status"] == "PASS" for check in checks)
    fail_count = sum(check["status"] == "FAIL" for check in checks)
    unverified_count = sum(check["status"] == "UNVERIFIED" for check in checks)
    status = "FAIL" if fail_count else ("UNVERIFIED" if unverified_count else "PASS")
    read_paths = {event["path"] for event in reads}
    phases = {}
    for event in observed:
        if event["event"] == "phase" and isinstance(event.get("name"), str) and isinstance(event.get("duration_ms"), (int, float)):
            phases[event["name"]] = phases.get(event["name"], 0) + event["duration_ms"]
    summaries = [event for event in observed if event["event"] == "summary"]
    wall_time = summaries[-1].get("wall_time_ms") if summaries else None
    summary_tool_calls = summaries[-1].get("tool_calls") if summaries else None
    route_check = next((check for check in checks if check["check"] == "route"), None)
    metrics = {
        "route_accuracy": None if not route_check or route_check["status"] == "UNVERIFIED" else
                          (1 if route_check["status"] == "PASS" else 0),
        "human_intervention_count": sum(event["event"] == "escalation" for event in observed),
        "tool_calls": summary_tool_calls if isinstance(summary_tool_calls, int) else len(runs),
        "read_file_count": len(read_paths),
        "context_bytes": sum(event.get("bytes", 0) for event in reads if isinstance(event.get("bytes"), int)),
        "wall_time_ms": wall_time if isinstance(wall_time, (int, float)) else None,
        "phase_duration_ms": phases,
        "cache_modes": [event.get("mode") for event in observed if event["event"] == "cache"],
        "reference_coverage": "reference" in coverage,
        "forbidden_reference_count": sum(
            1 for event in references
            if isinstance(event.get("target"), str) and
            any(path_matches(str(pattern), event["target"])
                   for pattern in case["expect"].get("must_not_reference", []))
        ),
    }
    total = len(checks)
    summary = {
        "schema_version": 1,
        "case": case["name"],
        "status": status,
        "checks": checks,
        "pass_checks": pass_count,
        "fail_checks": fail_count,
        "unverified_checks": unverified_count,
        "verified_check_rate": (pass_count + fail_count) / total if total else 0,
        "unverified_check_rate": unverified_count / total if total else 0,
        "metrics": metrics,
        "regressions": [],
    }
    summary["regressions"] = compare_regression(summary, baseline, regression_percent)
    summary["regression_count"] = len(summary["regressions"])
    return summary


def load_json(path):
    if not path:
        return None
    try:
        with path.open(encoding="utf-8") as stream:
            value = json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise EvalError("cannot read baseline %s: %s" % (path, error))
    if not isinstance(value, dict):
        raise EvalError("baseline must be a JSON object")
    return value


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp-%d" % os.getpid())
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(str(temporary), str(path))


def print_result(summary, as_json=False):
    if as_json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    else:
        print("EVAL_RESULT case=%s status=%s pass=%d fail=%d unverified=%d regressions=%d" %
              (summary["case"], summary["status"], summary["pass_checks"],
               summary["fail_checks"], summary["unverified_checks"], summary["regression_count"]))


def resolve_case(repo_root, value):
    candidate = Path(value)
    if not candidate.is_file():
        candidate = repo_root / "evals" / "cases" / (value if value.endswith(".yaml") else value + ".yaml")
    if not candidate.is_file():
        raise EvalError("case does not exist: %s" % value)
    return candidate.resolve()


def resolve_profile(repo_root, value):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value):
        raise EvalError("profile has an invalid name: %s" % value)
    profile_path = repo_root / "evals" / "profiles" / (value + ".txt")
    if not profile_path.is_file():
        raise EvalError("profile does not exist: %s" % value)
    names = []
    for line_number, raw_line in enumerate(profile_path.read_text(encoding="utf-8").splitlines(), 1):
        name = raw_line.strip()
        if not name or name.startswith("#"):
            continue
        if name in names:
            raise EvalError("profile %s repeats case %s at line %d" % (value, name, line_number))
        names.append(name)
    if not names:
        raise EvalError("profile is empty: %s" % value)
    return [resolve_case(repo_root, name) for name in names]


def copy_workspace(repo_root, destination):
    result = subprocess.run(["git", "-C", str(repo_root), "ls-files", "-co", "--exclude-standard", "-z"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode != 0:
        raise EvalError("cannot enumerate workspace: %s" % result.stderr.decode("utf-8", "replace").strip())
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        relative = Path(os.fsdecode(raw_path))
        source = repo_root / relative
        if not source.is_file():
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(source), str(target))


def run_adapter(args, repo_root):
    dirty = subprocess.run(["git", "-C", str(repo_root), "status", "--porcelain"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if dirty.returncode != 0:
        raise EvalError("cannot inspect Git status")
    if dirty.stdout and not args.allow_dirty:
        raise EvalError("run mode requires a clean Git tree (use --allow-dirty only for an intentional local comparison)")
    adapter = Path(args.adapter).expanduser()
    if not adapter.is_absolute():
        adapter = (Path.cwd() / adapter).resolve()
    if not adapter.is_file() or not os.access(str(adapter), os.X_OK):
        raise EvalError("adapter must be an existing executable file: %s" % adapter)
    selectors = int(bool(args.all)) + int(bool(args.case)) + int(bool(args.profile))
    if selectors != 1:
        raise EvalError("choose exactly one of --profile, --all, or --case")
    case_paths = [resolve_case(repo_root, value) for value in args.case]
    if args.profile:
        case_paths = resolve_profile(repo_root, args.profile)
    elif args.all:
        case_paths = sorted((repo_root / "evals" / "cases").glob("*.yaml"))
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output_dir = Path(args.output_dir or (repo_root / ".agent-cache" / "evals" / timestamp)).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    baseline = load_json(Path(args.baseline).resolve()) if args.baseline else None
    cases = [parse_case(case_path) for case_path in case_paths]
    _, decay_errors = decay_definitions(cases)
    paired_case_count = sum("decay_pair" in case or "decay_variant" in case for case in cases)
    if decay_errors and paired_case_count > 1:
        raise EvalError("invalid decay comparison: %s" % "; ".join(decay_errors))
    results = []
    for case in cases:
        with tempfile.TemporaryDirectory(prefix=".workspace-%s-" % case["name"], dir=str(output_dir)) as temporary:
            workspace = Path(temporary)
            copy_workspace(repo_root, workspace)
            fixture = case.get("fixture")
            if fixture:
                fixtures_root = (repo_root / "evals" / "fixtures").resolve()
                fixture_root = (fixtures_root / str(fixture)).resolve()
                try:
                    fixture_root.relative_to(fixtures_root)
                except ValueError:
                    raise EvalError("fixture escapes evals/fixtures: %s" % fixture)
                if not fixture_root.is_dir():
                    raise EvalError("fixture does not exist: %s" % fixture)
                shutil.copytree(str(fixture_root), str(workspace), dirs_exist_ok=True)
            # Seal the copy as its own Git repository. Without a .git here, any git
            # command an adapter runs resolves upward to the real checkout and mutates
            # it; the baseline commit also makes commit/rev-parse expectations
            # satisfiable inside the isolated workspace.
            for git_step in (["init", "-q"],
                             ["add", "-A"],
                             ["-c", "user.name=agent-eval", "-c", "user.email=agent-eval@invalid",
                              "commit", "-q", "--no-verify", "-m", "eval workspace baseline"]):
                sealed = subprocess.run(["git", "-C", str(workspace)] + git_step,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
                if sealed.returncode != 0:
                    raise EvalError("cannot isolate the eval workspace: %s"
                                    % sealed.stderr.decode("utf-8", "replace").strip())
            request_path = output_dir / (case["name"] + ".request.txt")
            trace_path = output_dir / (case["name"] + ".jsonl")
            request_path.write_text(case["request"], encoding="utf-8")
            started = time.monotonic()
            environment = os.environ.copy()
            environment.update({"AGENT_EVAL_CASE": case["name"],
                                "AGENT_EVAL_FIXTURE": str(fixture or "")})
            completed = subprocess.run([str(adapter), "--request", str(request_path),
                                        "--workspace", str(workspace), "--trace", str(trace_path)],
                                       cwd=str(workspace), env=environment, check=False)
            elapsed_ms = round((time.monotonic() - started) * 1000)
            if completed.returncode != 0 or not trace_path.is_file():
                result = {"schema_version": 1, "case": case["name"], "status": "INFRA",
                          "adapter_exit_code": completed.returncode,
                          "error": "adapter failed or did not produce a trace",
                          "metrics": {"wall_time_ms": elapsed_ms}, "regression_count": 0}
                for key in ("decay_pair", "decay_variant", "decay_stale_check"):
                    if key in case:
                        result[key] = case[key]
                results.append(result)
                continue
            summary = score_case(case, load_trace(trace_path), baseline, args.regression_percent)
            summary["adapter_exit_code"] = completed.returncode
            summary["runner_wall_time_ms"] = elapsed_ms
            for key in ("decay_pair", "decay_variant", "decay_stale_check"):
                if key in case:
                    summary[key] = case[key]
            write_json(output_dir / (case["name"] + ".summary.json"), summary)
            results.append(summary)
    counts = {status: sum(item["status"] == status for item in results)
              for status in ("PASS", "FAIL", "UNVERIFIED", "INFRA")}
    total = len(results)
    scored = [item for item in results if item["status"] != "INFRA"]
    total_checks = sum(item.get("pass_checks", 0) + item.get("fail_checks", 0) +
                       item.get("unverified_checks", 0) for item in scored)
    verified_checks = sum(item.get("pass_checks", 0) + item.get("fail_checks", 0) for item in scored)
    unverified_checks = sum(item.get("unverified_checks", 0) for item in scored)
    route_values = [item.get("metrics", {}).get("route_accuracy") for item in scored]
    route_values = [value for value in route_values if isinstance(value, (int, float))]
    aggregate_metrics = {
        "route_accuracy": sum(route_values) / len(route_values) if route_values else None,
        "human_intervention_count": sum(item.get("metrics", {}).get("human_intervention_count", 0)
                                        for item in scored),
        "tool_calls": sum(item.get("metrics", {}).get("tool_calls", 0) for item in scored),
        "read_file_count": sum(item.get("metrics", {}).get("read_file_count", 0) for item in scored),
        "context_bytes": sum(item.get("metrics", {}).get("context_bytes", 0) for item in scored),
        "wall_time_ms": sum(item.get("metrics", {}).get("wall_time_ms") or 0 for item in scored),
    }
    comparison = decay_comparison(cases, results, args.regression_percent)
    aggregate = {"schema_version": 1, "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                 "cases": results, "counts": counts,
                 "case_pass_rate": counts["PASS"] / total if total else 0,
                 "verified_check_rate": verified_checks / total_checks if total_checks else 0,
                 "unverified_check_rate": unverified_checks / total_checks if total_checks else 0,
                 "metrics": aggregate_metrics,
                 "regression_count": sum(item.get("regression_count", 0) for item in results)}
    if comparison:
        aggregate["decay_comparison"] = comparison
    write_json(output_dir / "summary.json", aggregate)
    decay_status = comparison["status"] if comparison else "not-applicable"
    print("EVAL_RUN total=%d pass=%d fail=%d unverified=%d infra=%d regressions=%d decay=%s output=%s" %
          (total, counts["PASS"], counts["FAIL"], counts["UNVERIFIED"], counts["INFRA"],
           aggregate["regression_count"], decay_status, output_dir))
    if counts["FAIL"] or counts["INFRA"] or (args.fail_on_unverified and counts["UNVERIFIED"]) or \
            (args.fail_on_regression and aggregate["regression_count"]) or \
            (comparison and comparison["status"] == "FAIL"):
        return 1
    return 0


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    score = subparsers.add_parser("score", help="score one existing JSONL trace")
    score.add_argument("--case", required=True)
    score.add_argument("--trace", required=True)
    score.add_argument("--baseline")
    score.add_argument("--output")
    score.add_argument("--regression-percent", type=float, default=20)
    score.add_argument("--fail-on-unverified", action="store_true")
    score.add_argument("--fail-on-regression", action="store_true")
    score.add_argument("--json", action="store_true")
    run = subparsers.add_parser("run", help="run an executable adapter in an isolated workspace and score its trace")
    run.add_argument("--adapter", required=True)
    run.add_argument("--case", action="append", default=[])
    run.add_argument("--all", action="store_true")
    run.add_argument("--profile", help="run a named case list from evals/profiles/<name>.txt")
    run.add_argument("--output-dir")
    run.add_argument("--baseline")
    run.add_argument("--regression-percent", type=float, default=20)
    run.add_argument("--fail-on-unverified", action="store_true")
    run.add_argument("--fail-on-regression", action="store_true")
    run.add_argument("--allow-dirty", action="store_true")
    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parent.parent
    try:
        if args.command == "run":
            return run_adapter(args, repo_root)
        case_path = resolve_case(repo_root, args.case)
        summary = score_case(parse_case(case_path), load_trace(Path(args.trace).resolve()),
                             load_json(Path(args.baseline).resolve()) if args.baseline else None,
                             args.regression_percent)
        if args.output:
            write_json(Path(args.output).resolve(), summary)
        print_result(summary, args.json)
        if summary["status"] == "FAIL" or (args.fail_on_unverified and summary["status"] == "UNVERIFIED") or \
                (args.fail_on_regression and summary["regression_count"]):
            return 1
        return 0
    except EvalError as error:
        print("EVAL_ERROR %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
