#!/usr/bin/env bash
# Smoke test: a quick "is the whole stack alive?" check through the frontend (nginx -> backend -> PostgreSQL).
# Usage: BASE_URL=http://localhost:8080 ./tests/smoke/smoke_test.sh
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
failures=0

# check <description> <command...>: runs the command and records a failure instead of stopping at the first one.
check() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  ${description}"
  else
    echo "FAIL  ${description}"
    failures=$((failures + 1))
  fi
}

# Frontend serves the web page.
check "frontend serves the home page" curl -fsS "${BASE_URL}/"
# Backend answers through the nginx /api proxy.
check "backend liveness through the proxy" curl -fsS "${BASE_URL}/api/health/live"
# Readiness runs SELECT 1, so it only passes when PostgreSQL is reachable.
check "backend readiness (database reachable)" curl -fsS "${BASE_URL}/api/health/ready"
# The seed data from init.sql must be there, which proves the tables were created.
check "seeded student Ananya Rao (class 10) is found" bash -c \
  "curl -fsS '${BASE_URL}/api/students?first_name=Ananya&last_name=Rao&class_name=10' | grep -q 'SCI-2026-00101'"

if [[ "${failures}" -gt 0 ]]; then
  echo "${failures} smoke check(s) failed"
  exit 1
fi
echo "All smoke checks passed"
