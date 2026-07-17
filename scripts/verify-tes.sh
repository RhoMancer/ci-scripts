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
superset_map = {}
for i, a in enumerate(test_names):
    for j, b in enumerate(test_names):
        if i == j: continue
        if test_kills[a] < test_kills[b]:
            bloat.add(a); superset_map[a] = b; break
        elif test_kills[a] == test_kills[b] and i < j:
            bloat.add(a); superset_map[a] = b; break

# Output candidates with their supersets
for method in sorted(bloat):
    superset = superset_map.get(method, '')
    # Find files for both bloat method and superset method
    bloat_file = ''
    super_file = ''
    for f in glob.glob('gradle-tools/src/test/kotlin/**/*.kt', recursive=True):
        try:
            with open(f) as fh:
                content = fh.read()
            if method in content:
                bloat_file = f
            if superset and superset in content:
                super_file = f
        except:
            pass
    if bloat_file:
        print(f'{bloat_file}|{method}|{super_file}|{superset}')
PYEOF

CANDIDATE_COUNT=$(wc -l < /tmp/tes_candidates.txt)
echo "Found $CANDIDATE_COUNT subset bloat candidates to verify"

CONFIRMED_BLOAT=0
REVERTED=0
SUPERSET_REVERSED=0  # Cases where the "bloat" was actually the superset

# Helper function: delete a method, run PIT, return kills
verify_deletion() {
    local FILEPATH="$1"
    local METHOD="$2"
    
    cp "$FILEPATH" "${FILEPATH}.bak"
    
    python3 - "$FILEPATH" "$METHOD" << 'DEL_EOF'
import re, sys
filepath = sys.argv[1]
method_name = sys.argv[2]
with open(filepath) as f:
    content = f.read()
pattern = r'(^[ \t]*//[^\n]*\n)*^[ \t]*@Test\n[ \t]*fun [`\x27]' + re.escape(method_name) + r'[`\x27]\(\) \{'
match = re.search(pattern, content, re.MULTILINE)
if not match:
    print("NOT_FOUND"); sys.exit(0)
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
            print("DELETED"); sys.exit(0)
    i += 1
print("BRACE_ERROR")
DEL_EOF
}

# Helper: count kills from current PIT XML
count_kills() {
    python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('$PIT_XML')
root = tree.getroot()
print(sum(1 for m in root.findall('.//mutation') if m.get('status') == 'KILLED'))
"
}

# Helper: restore a file
restore_file() {
    local FILEPATH="$1"
    if [ -f "${FILEPATH}.bak" ]; then
        cp "${FILEPATH}.bak" "$FILEPATH"
        rm "${FILEPATH}.bak"
    fi
}

while IFS='|' read -r BLOAT_FILE BLOAT_METHOD SUPER_FILE SUPER_METHOD; do
    echo ""
    echo "  === Candidate: $BLOAT_METHOD ==="
    echo "    Superset: $SUPER_METHOD"
    
    # Step 1: Delete bloat candidate, check if mutations survive
    echo "    Step 1: Delete bloat, run PIT..."
    verify_deletion "$BLOAT_FILE" "$BLOAT_METHOD"
    
    $GRADLE --no-daemon ":${MODULE}:pitest" --rerun-tasks 2>&1 | strings | grep "Generated.*mutations" | tail -1
    BLOAT_AFTER=$(count_kills)
    
    if [ "$BLOAT_AFTER" -lt "$BASELINE_KILLS" ]; then
        echo "    FALSE POSITIVE: bloat deletion dropped mutations ($BLOAT_AFTER < $BASELINE_KILLS)"
        restore_file "$BLOAT_FILE"
        REVERTED=$((REVERTED + 1))
        continue
    fi
    
    echo "    Bloat deletion OK: mutations unchanged ($BLOAT_AFTER/$BASELINE_KILLS)"
    restore_file "$BLOAT_FILE"
    
    # Step 2: Also verify the superset — maybe IT's the bloat, not the candidate
    if [ -n "$SUPER_FILE" ] && [ -n "$SUPER_METHOD" ]; then
        echo "    Step 2: Delete superset, run PIT..."
        verify_deletion "$SUPER_FILE" "$SUPER_METHOD"
        
        $GRADLE --no-daemon ":${MODULE}:pitest" --rerun-tasks 2>&1 | strings | grep "Generated.*mutations" | tail -1
        SUPER_AFTER=$(count_kills)
        
        if [ "$SUPER_AFTER" -eq "$BASELINE_KILLS" ]; then
            echo "    SUPERSET IS BLOAT: deleting superset keeps mutations ($SUPER_AFTER/$BASELINE_KILLS)"
            echo "    The 'bloat' candidate ($BLOAT_METHOD) is actually the essential one!"
            restore_file "$SUPER_FILE"
            SUPERSET_REVERSED=$((SUPERSET_REVERSED + 1))
            # Don't count this candidate as confirmed bloat
            continue
        else
            echo "    Superset essential: deletion drops mutations ($SUPER_AFTER < $BASELINE_KILLS)"
            restore_file "$SUPER_FILE"
        fi
    fi
    
    # Step 3: Both survive independently → bloat is confirmed
    echo "    CONFIRMED BLOAT: $BLOAT_METHOD is redundant (both survive without the other)"
    CONFIRMED_BLOAT=$((CONFIRMED_BLOAT + 1))
done < /tmp/tes_candidates.txt

# ============ Phase 3: Report ============
echo ""
echo "--- Phase 3: Results ---"
echo ""
echo "Confirmed bloat: $CONFIRMED_BLOAT"
echo "Reverted (false positives): $REVERTED"
echo "Superset reversed: $SUPERSET_REVERSED"
echo "Skipped: $((CANDIDATE_COUNT - CONFIRMED_BLOAT - REVERTED - SUPERSET_REVERSED))"
echo ""

# Restore full PIT run with final test state
echo "Restoring PIT with verified test suite..."
$GRADLE --no-daemon ":${MODULE}:pitest" --rerun-tasks 2>&1 | strings | grep "Generated.*mutations" | tail -1

echo ""
echo "========================================"
echo "Running check-tier.sh with verified suite..."
echo "========================================"
sh "$SCRIPT_DIR/check-tier.sh" "$JACOCO_XML" "$PIT_XML" "$JUNIT_DIR"
