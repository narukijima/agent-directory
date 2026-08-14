#!/usr/bin/env python3
"""Bounded reasoning adapter for the maintenance routine.

Contract owner: routines/ROUTINES.md. Invoked only by tools/run-routine.sh.

Two modes, both with a line-based stdout protocol so bash 3.2 can parse them:

  --request        read validator findings on stdin, send one bounded request to the
                   configured provider (deepseek | openai | anthropic), write the
                   proposed unified diff to --output.
                   stdout: REASONING_OK patch_bytes=<n> | REASONING_EMPTY |
                           REASONING_FAILED reason=<reason>

  --inspect-patch  read a candidate patch on stdin and enforce the safety boundary
                   (allowlisted existing files only, no create/delete/rename/mode/
                   binary changes, size limits).
                   stdout: PATCH_OK files=<n> lines=<n> bytes=<n> then FILE <path> lines
                           | PATCH_REJECTED reason=<reason>

Standard library only. Deterministic maintenance never requires this file: when
Python or the provider configuration is missing, tools/run-routine.sh reports the
reasoning layer as unavailable and still completes.

API keys are read from the environment, never echoed, and never written to the
patch, the logs, or any error message.
"""

import json
import os
import socket
import sys
import urllib.error
import urllib.request

MAX_PATCH_FILES = 3
MAX_PATCH_BYTES = 32768
MAX_PATCH_CHANGED_LINES = 200
MAX_CONTEXT_FILES = 12
MAX_CONTEXT_BYTES = 32768
# The transmission budget covers the whole outbound payload: instructions + findings + context.
MAX_PAYLOAD_BYTES = 32768
# Upper bound on how much of a provider response is read; a compliant answer is far smaller.
MAX_RESPONSE_BYTES = 1048576
ABSOLUTE_MAX_MODEL_CALLS = 3
# The Anthropic Messages API requires max_tokens on every request, so a floor stays
# even when AGENT_ROUTINE_REASONING_MAX_OUTPUT_TOKENS is unset. Chat Completions
# providers accept requests without a token cap and then use the model's own limit.
ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS = 8192

SUPPORTED_PROVIDERS = ("deepseek", "openai", "anthropic")

PROMPT_INSTRUCTIONS = (
    "You are the maintenance assistant of a Git-tracked agent workspace. "
    "The structural validator reported the findings below. Propose the smallest "
    "safe repair, editing ONLY the provided files. Reply with ONE JSON object "
    'exactly of the form {"analysis": "<short reasoning>", "patch": "<unified '
    'diff>"}. The patch must be a standard unified diff (--- a/<path> / '
    "+++ b/<path>) that modifies existing files only: never create, delete, or "
    "rename files, never change file modes, never touch files you were not "
    "given, and never include shell commands. If no safe minimal repair exists, "
    'return {"analysis": "<why>", "patch": ""}.'
)


def fail(reason: str, code: int = 3) -> "NoReturn":  # noqa: F821
    print(f"REASONING_FAILED reason={reason}")
    sys.exit(code)


def env(name: str, default: str = "") -> str:
    value = os.environ.get(name, default).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        value = value[1:-1]
    return value


def positive_int(name: str, default: int, ceiling: int = 0) -> int:
    raw = env(name)
    if not raw:
        value = default
    else:
        try:
            value = int(raw)
        except ValueError:
            fail("invalid-configuration")
    if value < 1:
        fail("invalid-configuration")
    if ceiling and value > ceiling:
        value = ceiling
    return value


def optional_positive_int(name: str):
    """Like positive_int, but an unset variable means "no limit" (None)."""
    raw = env(name)
    if not raw:
        return None
    try:
        value = int(raw)
    except ValueError:
        fail("invalid-configuration")
    if value < 1:
        fail("invalid-configuration")
    return value


def build_request(provider: str, model: str, api_key: str, prompt: str,
                  max_output_tokens):
    """Return (url, headers, body) for the selected provider only.

    Request shapes follow each provider's official Messages / Chat Completions
    documentation. There is no fallback between providers. max_output_tokens
    may be None: Chat Completions requests then omit the cap entirely, while
    Anthropic falls back to ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS because the
    Messages API rejects requests without max_tokens.
    """
    if provider == "anthropic":
        base = env("ANTHROPIC_BASE_URL") or "https://api.anthropic.com"
        url = base.rstrip("/") + "/v1/messages"
        headers = {
            "content-type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
        }
        body = {
            "model": model,
            "max_tokens": max_output_tokens or ANTHROPIC_DEFAULT_MAX_OUTPUT_TOKENS,
            "system": PROMPT_INSTRUCTIONS,
            "messages": [{"role": "user", "content": prompt}],
        }
        return url, headers, body

    if provider == "deepseek":
        base = env("DEEPSEEK_BASE_URL") or "https://api.deepseek.com"
        url = base.rstrip("/") + "/chat/completions"
        token_field = "max_tokens"
    else:  # openai
        base = env("OPENAI_BASE_URL") or "https://api.openai.com/v1"
        url = base.rstrip("/") + "/chat/completions"
        token_field = "max_completion_tokens"
    headers = {
        "content-type": "application/json",
        "authorization": f"Bearer {api_key}",
    }
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": PROMPT_INSTRUCTIONS},
            {"role": "user", "content": prompt},
        ],
    }
    if max_output_tokens is not None:
        body[token_field] = max_output_tokens
    return url, headers, body


def is_timeout(error) -> bool:
    """True when a transport failure is specifically the request timing out.

    urllib surfaces timeouts either bare (mid-read) or wrapped in URLError
    (during connect). socket.timeout is checked alongside TimeoutError for
    interpreters older than 3.10, where they are distinct classes.
    """
    timeout_types = (TimeoutError, socket.timeout)
    if isinstance(error, timeout_types):
        return True
    return isinstance(error, urllib.error.URLError) and \
        isinstance(error.reason, timeout_types)


def check_not_truncated(provider: str, payload) -> None:
    """Separate a budget problem from a malformed reply before parsing.

    A reply cut off at the output-token cap almost always fails JSON parsing,
    which used to surface as malformed-response and misdirect diagnosis toward
    the model instead of the token budget.
    """
    try:
        if provider == "anthropic":
            truncated = payload.get("stop_reason") == "max_tokens"
        else:
            truncated = payload["choices"][0].get("finish_reason") == "length"
    except (KeyError, IndexError, TypeError, AttributeError):
        return  # structural problems are classified by extract_text
    if truncated:
        fail("output-truncated")


def extract_text(provider: str, payload) -> str:
    try:
        if provider == "anthropic":
            blocks = payload["content"]
            return "".join(b.get("text", "") for b in blocks
                           if isinstance(b, dict) and b.get("type") == "text")
        return payload["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        fail("malformed-response")


def parse_model_json(text: str):
    """Extract the single JSON object the model was asked to return."""
    text = text.strip()
    if text.startswith("```"):
        lines = [line for line in text.splitlines() if not line.startswith("```")]
        text = "\n".join(lines).strip()
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end <= start:
        fail("malformed-response")
    try:
        parsed = json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        fail("malformed-response")
    if not isinstance(parsed, dict) or not isinstance(parsed.get("patch", None), str):
        fail("malformed-response")
    if not isinstance(parsed.get("analysis", ""), str):
        fail("malformed-response")
    return parsed


def run_request(argv) -> int:
    root = ""
    output = ""
    context_files = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--root" and i + 1 < len(argv):
            root = argv[i + 1]
            i += 2
        elif arg == "--output" and i + 1 < len(argv):
            output = argv[i + 1]
            i += 2
        elif arg == "--context-file" and i + 1 < len(argv):
            context_files.append(argv[i + 1])
            i += 2
        else:
            fail("invalid-arguments", 2)
    if not root or not output:
        fail("invalid-arguments", 2)

    provider = env("AGENT_ROUTINE_REASONING_PROVIDER")
    model = env("AGENT_ROUTINE_REASONING_MODEL")
    if provider not in SUPPORTED_PROVIDERS:
        fail("unsupported-provider")
    key_variable = {"deepseek": "DEEPSEEK_API_KEY", "openai": "OPENAI_API_KEY",
                    "anthropic": "ANTHROPIC_API_KEY"}[provider]
    api_key = env(key_variable)
    if not model or not api_key:
        fail("unconfigured")
    # Hang guard, not a latency target. Measured worst case is 378s with a single
    # 23KB context file; the payload budget allows ~1.4x that input, and reasoning
    # time also grows with problem complexity, so the default sits well above the
    # extrapolated worst case. Hitting it is reported as model-timeout.
    timeout = positive_int("AGENT_ROUTINE_REASONING_TIMEOUT_SECONDS", 900)
    max_calls = positive_int("AGENT_ROUTINE_REASONING_MAX_MODEL_CALLS", 1,
                             ABSOLUTE_MAX_MODEL_CALLS)
    max_output_tokens = optional_positive_int("AGENT_ROUTINE_REASONING_MAX_OUTPUT_TOKENS")

    findings = sys.stdin.read()
    if len(context_files) > MAX_CONTEXT_FILES:
        fail("context-budget-exceeded")
    sections = [f"## Validator findings\n\n{findings.strip()}\n"]
    total_bytes = 0
    for relative in context_files:
        if os.path.isabs(relative) or ".." in relative.split("/"):
            fail("invalid-context-path")
        absolute = os.path.join(root, relative)
        try:
            with open(absolute, "r", encoding="utf-8") as handle:
                content = handle.read()
        except (OSError, UnicodeDecodeError):
            fail("unreadable-context-file")
        total_bytes += len(content.encode("utf-8"))
        if total_bytes > MAX_CONTEXT_BYTES:
            fail("context-budget-exceeded")
        sections.append(f"## File: {relative}\n\n{content}\n")
    prompt = "\n".join(sections)
    payload_bytes = len(PROMPT_INSTRUCTIONS.encode("utf-8")) + len(prompt.encode("utf-8"))
    if payload_bytes > MAX_PAYLOAD_BYTES:
        fail("context-budget-exceeded")

    url, headers, body = build_request(provider, model, api_key, prompt,
                                       max_output_tokens)
    data = json.dumps(body).encode("utf-8")
    payload = None
    attempts = 0
    while attempts < max_calls:
        attempts += 1
        request = urllib.request.Request(url, data=data, headers=headers,
                                         method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body_bytes = response.read(MAX_RESPONSE_BYTES + 1)
                if len(body_bytes) > MAX_RESPONSE_BYTES:
                    fail("response-too-large")
                payload = json.loads(body_bytes.decode("utf-8"))
            break
        except urllib.error.HTTPError as error:
            # HTTP error bodies may contain secrets, so never print them; report only the status.
            fail(f"http-{error.code}")
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            if attempts >= max_calls:
                # A timeout is a budget signal, not a network fault; report it
                # distinctly so diagnosis points at TIMEOUT_SECONDS, not the wire.
                fail("model-timeout" if is_timeout(error) else "transport-error")
        except (json.JSONDecodeError, ValueError):
            fail("malformed-response")
    if payload is None:
        fail("transport-error")

    check_not_truncated(provider, payload)
    parsed = parse_model_json(extract_text(provider, payload))
    analysis = parsed.get("analysis", "").strip()
    if analysis:
        # Never persist the analysis body: it may quote input documents. Record only its size.
        print(f"analysis_received bytes={len(analysis.encode('utf-8'))}", file=sys.stderr)
    patch = parsed["patch"]
    if not patch.strip():
        print("REASONING_EMPTY")
        return 0
    if not patch.endswith("\n"):
        patch += "\n"
    encoded = patch.encode("utf-8")
    with open(output, "wb") as handle:
        handle.write(encoded)
    print(f"REASONING_OK patch_bytes={len(encoded)}")
    return 0


def reject(reason: str) -> "NoReturn":  # noqa: F821
    print(f"PATCH_REJECTED reason={reason}")
    sys.exit(4)


def run_inspect(argv) -> int:
    allowed = []
    i = 0
    while i < len(argv):
        if argv[i] == "--allow" and i + 1 < len(argv):
            allowed.append(argv[i + 1])
            i += 2
        else:
            reject("invalid-arguments")

    raw = sys.stdin.buffer.read()
    if len(raw) > MAX_PATCH_BYTES:
        reject("patch-too-large")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        reject("binary-patch")

    files = []
    changed_lines = 0
    old_path = None
    saw_hunk = False
    for line in text.splitlines():
        if line.startswith(("diff --git ", "index ", "@@ ")):
            if line.startswith("@@ "):
                saw_hunk = True
            continue
        if line.startswith(("GIT binary patch", "Binary files ")):
            reject("binary-patch")
        if line.startswith(("new file mode", "deleted file mode", "old mode",
                            "new mode", "rename from", "rename to",
                            "copy from", "copy to")):
            reject("structural-change")
        if line.startswith("--- "):
            old_path = line[4:].split("\t")[0].strip()
            continue
        if line.startswith("+++ "):
            new_path = line[4:].split("\t")[0].strip()
            if old_path is None:
                reject("not-a-unified-diff")
            if old_path == "/dev/null":
                reject("creates-file")
            if new_path == "/dev/null":
                reject("deletes-file")
            if old_path.startswith("a/"):
                old_path = old_path[2:]
            if new_path.startswith("b/"):
                new_path = new_path[2:]
            if old_path != new_path:
                reject("renames-file")
            if new_path.startswith("/") or ".." in new_path.split("/"):
                reject("forbidden-path")
            if new_path not in allowed:
                reject("forbidden-path")
            if new_path not in files:
                files.append(new_path)
            old_path = None
            continue
        if line.startswith(("+", "-")):
            changed_lines += 1

    if not files or not saw_hunk:
        reject("not-a-unified-diff")
    if len(files) > MAX_PATCH_FILES:
        reject("too-many-files")
    if changed_lines > MAX_PATCH_CHANGED_LINES:
        reject("too-many-lines")

    print(f"PATCH_OK files={len(files)} lines={changed_lines} bytes={len(raw)}")
    for path in files:
        print(f"FILE {path}")
    return 0


def main() -> int:
    argv = sys.argv[1:]
    if not argv:
        fail("invalid-arguments", 2)
    mode, rest = argv[0], argv[1:]
    if mode == "--request":
        return run_request(rest)
    if mode == "--inspect-patch":
        return run_inspect(rest)
    fail("invalid-arguments", 2)


if __name__ == "__main__":
    sys.exit(main())
