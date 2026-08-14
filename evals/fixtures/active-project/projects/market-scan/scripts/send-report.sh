#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${1:-}" == 'configured-recipient' ]]
bash "${script_dir}/verify-report.sh"
printf 'SENT: configured-recipient\n'
