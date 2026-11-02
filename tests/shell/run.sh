#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for file in "$ROOT/onboarding.sh" "$ROOT"/shell/*.sh "$ROOT"/tests/shell/*.sh; do bash -n "$file"; done
for test in "$ROOT"/tests/shell/test_*.sh; do bash "$test"; done
printf 'All Bash test suites passed\n'
