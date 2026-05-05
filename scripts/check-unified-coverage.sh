#!/usr/bin/env bash
# check-unified-coverage.sh — Enforce combined coverage thresholds from UNIFIED_COVERAGE.md
#
# Usage: ./scripts/check-unified-coverage.sh [report-path] [min-line%] [min-branch%]
# Defaults: report=shared/build/reports/coverage/UNIFIED_COVERAGE.md  line=80  branch=65
#
# Parses the "Combined Metrics (Line-Level OR Merge)" table from the markdown report.
# Falls back to Kover-only metrics if no combined data is available.
# Exits non-zero if coverage is below thresholds.

set -euo pipefail

REPORT="${1:-shared/build/reports/coverage/UNIFIED_COVERAGE.md}"
MIN_LINE="${2:-80}"
MIN_BRANCH="${3:-65}"

if [ ! -f "$REPORT" ]; then
    echo "ERROR: Coverage report not found: $REPORT"
    exit 1
fi

# Try to extract Combined Metrics first, fall back to Kover-only
# The markdown table has rows like:
# | Line Coverage | ... | **82.5%** (330/400) |
# | Branch Coverage | ... | **67.0%** (134/200) |

# Extract the last percentage in each row (Combined column), or first if no combined
extract_pct() {
    local metric="$1"
    # Try combined metrics table first (bold percentage)
    local combined
    combined=$(grep -E "^\| ${metric} Coverage \|" "$REPORT" | grep -oE '\*\*[0-9]+\.[0-9]+%\*\*' | head -1 | grep -oE '[0-9]+\.[0-9]+')
    if [ -n "$combined" ]; then
        echo "$combined"
        return
    fi
    # Try unified report format (e.g., "| Branches | 4 | 81 | 85 | 4.7% |")
    local unified
    # Handle both plural forms: Line->Lines, Branch->Branches
    local metric_plural="${metric}es"
    if [ "$metric" = "Line" ]; then
        metric_plural="${metric}s"
    fi
    unified=$(grep "| ${metric_plural} |" "$REPORT" | grep -oE '[0-9]+\.[0-9]+%' | tail -1 | grep -oE '[0-9]+\.[0-9]+')
    if [ -z "$unified" ]; then
        unified=$(grep "| ${metric} |" "$REPORT" | grep -oE '[0-9]+\.[0-9]+%' | tail -1 | grep -oE '[0-9]+\.[0-9]+')
    fi
    if [ -n "$unified" ]; then
        echo "$unified"
        return
    fi
    # Fall back to Kover-only table
    local kover
    kover=$(grep -E "^\| Lines \|" "$REPORT" | head -1 | grep -oE '[0-9]+\.[0-9]+%' | head -1 | grep -oE '[0-9]+\.[0-9]+')
    echo "${kover:-0.0}"
}

LINE_PCT=$(extract_pct "Line")
BRANCH_PCT=$(extract_pct "Branch")

# Compare using integer arithmetic (multiply by 10 to handle one decimal)
LINE_INT=$(echo "$LINE_PCT" | awk '{printf "%d", $1 * 10}')
BRANCH_INT=$(echo "$BRANCH_PCT" | awk '{printf "%d", $1 * 10}')
MIN_LINE_INT=$((MIN_LINE * 10))
MIN_BRANCH_INT=$((MIN_BRANCH * 10))

echo "=== Coverage Threshold Check ==="
echo "Line:   ${LINE_PCT}% (min: ${MIN_LINE}%)"
echo "Branch: ${BRANCH_PCT}% (min: ${MIN_BRANCH}%)"

PASS=true

if [ "$LINE_INT" -lt "$MIN_LINE_INT" ]; then
    echo "FAIL: Line coverage ${LINE_PCT}% < ${MIN_LINE}%"
    PASS=false
else
    echo "PASS: Line coverage ${LINE_PCT}% >= ${MIN_LINE}%"
fi

if [ "$BRANCH_INT" -lt "$MIN_BRANCH_INT" ]; then
    echo "FAIL: Branch coverage ${BRANCH_PCT}% < ${MIN_BRANCH}%"
    PASS=false
else
    echo "PASS: Branch coverage ${BRANCH_PCT}% >= ${MIN_BRANCH}%"
fi

if [ "$PASS" = true ]; then
    echo "=== All coverage thresholds met ==="
    exit 0
else
    echo "=== Coverage thresholds NOT met ==="
    exit 1
fi
