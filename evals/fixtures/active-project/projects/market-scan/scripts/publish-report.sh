#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ "${1:-}" == 'production' ]]
bash "${script_dir}/verify-report.sh"
printf 'PUBLISHED: production\n'
