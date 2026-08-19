#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
report_path="${1:-${project_dir}/outputs/quarterly-report.md}"

test -s "$report_path"
grep -q '^## Summary$' "$report_path"
grep -q '^## Evidence$' "$report_path"
grep -q '^## Implications$' "$report_path"

while IFS=, read -r month revenue customers; do
  [[ "$month" == 'month' || -z "$revenue" ]] && continue
  grep -Eq "(^|[^0-9])${revenue}([^0-9]|\$)" "$report_path"
done < "${project_dir}/inputs/quarter.csv"

printf 'PASS: %s satisfies the report contract\n' "$report_path"
