#!/usr/bin/env bash
set -euo pipefail

request=''
workspace=''
trace=''
while (( $# > 0 )); do
  case "$1" in
    --request) request="$2"; shift 2 ;;
    --workspace) workspace="$2"; shift 2 ;;
    --trace) trace="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ -s "$request" && -f "$workspace/eval-runtime-marker.txt" && -n "$trace" ]] || exit 1
case "${AGENT_EVAL_CASE:-}" in
  runtime-decay-aged)
    if [[ "${AGENT_EVAL_DECAY_REGRESSION:-false}" == true ]]; then
      cp "$workspace/evals/fixtures/eval-runtime/runtime-decay-aged-regressed.jsonl" "$trace"
    else
      cp "$workspace/evals/fixtures/eval-runtime/${AGENT_EVAL_CASE}.jsonl" "$trace"
    fi
    ;;
  runtime-decay-clean)
    cp "$workspace/evals/fixtures/eval-runtime/${AGENT_EVAL_CASE}.jsonl" "$trace"
    ;;
  *)
    cp "$workspace/evals/fixtures/eval-runtime/pass.jsonl" "$trace"
    ;;
esac
