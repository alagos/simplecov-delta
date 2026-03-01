#!/bin/bash
set -euo pipefail

echo "::group::SimpleCov Delta — Collation"
bundle exec ruby /action/scripts/collate.rb
echo "::endgroup::"

# Set outputs for merged results
COVERAGE_PATH="${COVERAGE_PATH:-coverage}"
echo "html-path=${COVERAGE_PATH}" >> "$GITHUB_OUTPUT"
echo "resultset-path=${COVERAGE_PATH}/.resultset.json" >> "$GITHUB_OUTPUT"

# Read total coverage from collation output
if [ -f "${COVERAGE_PATH}/coverage_result.json" ]; then
  TOTAL_COVERAGE=$(cat "${COVERAGE_PATH}/coverage_result.json" | ruby -rjson -e 'puts JSON.parse(STDIN.read)["total_coverage"]')
  echo "total-coverage=${TOTAL_COVERAGE}" >> "$GITHUB_OUTPUT"
else
  TOTAL_COVERAGE="0"
  echo "total-coverage=0" >> "$GITHUB_OUTPUT"
fi

# Phase 2: Compare against baseline (if provided)
DELTA=""
if [ -n "${BASELINE_PATH:-}" ] && [ -f "${BASELINE_PATH}" ]; then
  echo "::group::SimpleCov Delta — Comparison"
  bundle exec ruby /action/scripts/compare.rb
  echo "::endgroup::"

  if [ -f "${COVERAGE_PATH}/comparison.json" ]; then
    DELTA=$(cat "${COVERAGE_PATH}/comparison.json" | ruby -rjson -e '
      data = JSON.parse(STDIN.read)
      delta = data["overall"]["delta"]
      puts delta >= 0 ? "+#{delta}" : delta.to_s
    ')
  fi
else
  echo "No baseline provided or baseline file not found — skipping comparison."
fi
echo "coverage-delta=${DELTA}" >> "$GITHUB_OUTPUT"

# Phase 3: Reporting (Check Run, Job Summary, PR Comment)
echo "::group::SimpleCov Delta — Reporting"
bundle exec ruby /action/scripts/report.rb
echo "::endgroup::"

echo "SimpleCov Delta completed successfully."
