#!/usr/bin/env bash
# test-summary.sh — Print test results summary from JUnit XML files
#
# Usage: ./scripts/test-summary.sh <xml-glob-pattern>
# Example: ./scripts/test-summary.sh "shared/build/outputs/androidTest-results/connected/debug/TEST-*.xml"

set -euo pipefail

PATTERN="${1:-}"

if [ -z "$PATTERN" ]; then
    echo "Usage: test-summary.sh <xml-glob-pattern>"
    exit 0
fi

echo "=== Test Summary ==="
awk -F'"' '
  /<testsuite/ { tests+=int($4); fails+=int($10); skips+=int($12) }
  /<testcase/ { name=$8; classname=$4 }
  /<failure/ { failures[++fc]="FAIL: " classname " - " name }
  END {
    pass=tests-fails-skips;
    print "Passed: " pass " | Failed: " fails " | Skipped: " skips " | Total: " tests
    if (fails > 0) {
      print "=== FAILED TESTS ==="
      for (i=1; i<=fc; i++) print failures[i]
    }
  }
' $PATTERN 2>/dev/null || echo "No test results found matching: $PATTERN"
