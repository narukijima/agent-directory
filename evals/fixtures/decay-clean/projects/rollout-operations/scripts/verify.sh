#!/usr/bin/env bash
set -euo pipefail

grep -Fq '10% canary' projects/rollout-operations/STATE.md
grep -Fq '10%のcanary' knowledge/wiki/topics/rollout-policy-current.md
printf 'VERIFY_OK rollout=10%%-canary\n'
