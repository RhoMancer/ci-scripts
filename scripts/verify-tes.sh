#!/bin/sh
# verify-tes.sh — Verified TES via automated delete-verify-revert per method.
#
# Phase 1: Detect subset candidates from full kill matrix
# Phase 2: For each candidate, temporarily remove it, run PIT, check mutations
# Phase 3: Compute verified TES from confirmed bloat
#
# Safe by construction: every deletion is verified. False positives are automatically reverted.
#
# Usage: verify-tes.sh <jacoco-xml> <pit-xml> <junit-dir>
# Requires: fullMutationMatrix=true in PIT config

set -e

JACOCO_XML="${1:-gradle-tools/build/reports/jacoco/test/jacocoTestReport.xml}"
PIT_XML="${2:-gradle-tools/build/reports/pitest/mutations.xml}"
JUNIT_DIR="${3:-gradle-tools/build/test-results/test}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GRADLE="${GRADLE:-./gradlew}"
MODULE="${MODULE:-gradle-tools}"

echo "========================================"
echo "VERIFIED TES — Delete-Verify-Revert"
echo "========================================"
echo ""

# ============ Phase 1: Get baseline mutation count ============
echo "--- Phase 1: Establishing baseline ---"

BASELINE_KILLS=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$PIT_XML')
root = tree.getroot()
print(sum(1 for m in root.findall('.//mutation') if m.get('status') == 'KILLED'))
")
echo "Baseline: $BASELINE_KILLS mutations killed"

# Get total test count
TOTAL_TESTS=$(python3 -c "
import glob, xml.etree.ElementTree as ET
total = 0
for f in glob.glob('$JUNIT_DIR/*.xml'):
    tree = ET.parse(f)
    total += int(tree.getroot().get('tests', 0))
print(total)
")
echo "Total tests: $TOTAL_TESTS"

# ============ Phase 2: Detect and verify candidates ============
echo ""
echo "--- Phase 2: Delete-Verify-Revert ---"

# Get list of (file, method) pairs for bloat candidates
python3 - "$PIT_XML" << 'PYEOF' > /tmp/tes_candidates.txt
import xml.etree.ElementTree as ET
from collections import defaultdict
import sys, glob, re, os

pit_path = sys.argv[1]
tree = ET.parse(pit_path)
root = tree.getroot()

test_kills = defaultdict(set)
for m in root.findall('.//mutation'):
    if m.get('status') != 'KILLED': continue
    src = m.find('sourceFile')
    line = m.find('lineNumber')
    mutator = m.find('mutator')
    mut_id = f'{src.text}:{line.text}:{mutator.text.split(".")[-1]}'
    kt_elem = m.find('killingTests')
    if kt_elem is not None and kt_elem.text:
        for test_full in kt_elem.text.split('|'):
            if '[method:' in test_full:
                method = test_full.split('[method:')[1].split('()]')[0]
                test_kills[method].add(mut_id)
    else:
        kt_elem = m.find('killingTest')
        if kt_elem is not None and kt_elem.text:
            text = kt_elem.text.strip()
            if '[method:' in text:
                method = text.split('[method:')[1].split('()]')[0]
                test_kills[method].add(mut_id)

test_names = list(test_kills.keys())
bloat = set()
for i, a in enumerate(test_names):
    for j, b in enumerate(test_names):
        if i == j: continue
        if test_kills[a] < test_kills[b]:
            bloat.add(a); break
        elif test_kills[a] == test_kills[b] and i < j:
            bloat.add(a); break

# Map methods to files
for method in sorted(bloat):
    # Find which file contains this method
    for f in glob.glob('gradle-tools/src/test/kotlin/**/*.kt', recursive=True):
        try:
            with open(f) as fh:
                if method in fh.read():
                    print(f'{f}|{method}')
                    break
        except:
            pass
PYEOF

CANDIDATE_COUNT=$(wc -l < /tmp/tes_candidates.txt)
echo "Found $CANDIDATE_COUNT subset bloat candidates to verify"

CONFIRMED_BLOAT=0
REVERTED=0

while IFS='|' read -r FILEPATH METHOD; do
    echo ""
    echo "  Testing: $METHOD"
    echo "    File: $(basename "$FILEPATH")"
    
    # Backup the file
    cp "$FILEPATH" "${FILEPATH}.bak"
    
    # Delete the test method using Python (proper brace matching)
    python3 - "$FILEPATH" "$METHOD" << 'PYEOF'
import re, sys

filepath = sys.argv[1]
method_name = sys.argv[2]

with open(filepath) as f:
    content = f.read()

# Match @Test followed by fun `method_name`() {
pattern = r'(^[ \t]*//[^\n]*\n)*^[ \t]*@Test\n[ \t]*fun [`\x27]' + re.escape(method_name) + r'[`\x27]\(\) \{'
match = re.search(pattern, content, re.MULTILINE)
if not match:
    print(f"NOT_FOUND")
    sys.exit(0)

brace_start = match.end() - 1
depth = 0
i = brace_start
while i < len(content):
    if content[i] == '{': depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            while end < len(content) and content[end] in '\n\r': end += 1
            new_content = content[:match.start()] + content[end:]
            with open(filepath, 'w') as f:
                f.write(new_content)
            print("DELETED")
            sys.exit(0)
    i += 1
print("BRACE_ERROR")
PYEOF
    DELETE_RESULT=$(python3 - "$FILEPATH" "$METHOD" << 'PYEOF2'
import re, sys
filepath = sys.argv[1]
method_name = sys.argv[2]
with open(filepath) as f:
    content = f.read()
pattern = r'(^[ \t]*//[^\n]*\n)*^[ \t]*@Test\n[ \t]*fun [`\x27]' + re.escape(method_name) + r'[`\x27]\(\) \{'
match = re.search(pattern, content, re.MULTILINE)
if not match:
    print("NOT_FOUND")
    sys.exit(0)
brace_start = match.end() - 1
depth = 0
i = brace_start
while i < len(content):
    if content[i] == '{': depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            while end < len(content) and content[end] in '\n\r': end += 1
            with open(filepath, 'w') as f:
                f.write(content[:match.start()] + content[end:])
            print("DELETED")
            sys.exit(0)
    i += 1
print("BRACE_ERROR")
PYEOF2
)

    if [ "$DELETE_RESULT" != "DELETED" ]; then
        echo "    SKIP: Could not delete ($DELETE_RESULT)"
        cp "${FILEPATH}.bak" "$FILEPATH"
        rm "${FILEPATH}.bak"
        continue
    fi
    
    # Run PIT
    echo "    Running PIT..."
    $GRADLE --no-daemon ":${MODULE}:pitest" --rerun-tasks 2>&1 | strings | grep "Generated.*mutations" | tail -1
    
    # Check mutation score
    AFTER_KILLS=$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$PIT_XML')
root = tree.getroot()
print(sum(1 for m in root.findall('.//mutation') if m.get('status') == 'KILLED'))
")
    
    if [ "$AFTER_KILLS" -eq "$BASELINE_KILLS" ]; then
        echo "    CONFIRMED BLOAT: mutation score unchanged ($AFTER_KILLS/$BASELINE_KILLS)"
        CONFIRMED_BLOAT=$((CONFIRMED_BLOAT + 1))
        rm "${FILEPATH}.bak"
    else
        echo "    FALSE POSITIVE: mutation score dropped ($AFTER_KILLS < $BASELINE_KILLS) — REVERTING"
        cp "${FILEPATH}.bak" "$FILEPATH"
        rm "${FILEPATH}.bak"
        REVERTED=$((REVERTED + 1))
    fi
done < /tmp/tes_candidates.txt

# ============ Phase 3: Report ============
echo ""
echo "--- Phase 3: Results ---"
echo ""
echo "Confirmed bloat: $CONFIRMED_BLOAT"
echo "Reverted (false positives): $REVERTED"
echo "Skipped: $((CANDIDATE_COUNT - CONFIRMED_BLOAT - REVERTED))"
echo ""

# Restore full PIT run with final test state
echo "Restoring PIT with verified test suite..."
$GRADLE --no-daemon ":${MODULE}:pitest" --rerun-tasks 2>&1 | strings | grep "Generated.*mutations" | tail -1

echo ""
echo "========================================"
echo "Running check-tier.sh with verified suite..."
echo "========================================"
sh "$SCRIPT_DIR/check-tier.sh" "$JACOCO_XML" "$PIT_XML" "$JUNIT_DIR"
