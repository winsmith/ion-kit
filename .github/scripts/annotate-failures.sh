#!/usr/bin/env bash
# Turns compiler errors and swift-testing failures in a build/test log into GitHub check annotations and a step
# summary, so a failed job can be read from the Checks tab (and through the API) without opening the raw log.
set -u
log="${1:-test.log}"
[ -f "$log" ] || { echo "::error::no log at $log"; exit 0; }

# Compiler errors, failed expectations, recorded issues, crashes; swift-testing prints one line per issue.
grep -E "error:|✘|Expectation failed|recorded an issue|Fatal error|Crash|signal code|Test run with .* failed" "$log" \
  | grep -vE "^\s*$" | sort -u > failures.txt || true

{
  echo "## Failures"
  echo
  echo '```'
  head -n 80 failures.txt
  echo '```'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# At most 10 annotations per step are shown; put the most specific lines first.
{ grep -E "error:|Expectation failed|recorded an issue" failures.txt; grep -vE "error:|Expectation failed|recorded an issue" failures.txt; } \
  | head -n 10 | while IFS= read -r line; do
    printf '::error::%s\n' "${line//$'\n'/ }"
  done
