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
cp "$workspace/evals/fixtures/eval-runtime/pass.jsonl" "$trace"
