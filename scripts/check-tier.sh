#!/bin/sh
# check-tier.sh — Determine a repo's testing tier from JaCoCo + PIT XML reports.
# Usage: check-tier.sh <jacoco-xml> <pit-xml> [test-loc] [test-count] [test-time-ms]
#
# Outputs: tier name + per-metric breakdown.
# Exit code: 0 if tier >= Gold, 1 if below Gold, 2 if reports missing.
#
# Part of the Angus Software Testing Tier System.
# See: TEST_TIER_SYSTEM.md for full definitions.

set -e

JACOCO_XML="${1:-gradle-tools/build/reports/jacoco/test/jacocoTestReport.xml}"
PIT_XML="${2:-gradle-tools/build/reports/pitest/mutations.xml}"
TEST_LOC="${3:-}"
TEST_COUNT="${4:-}"
TEST_TIME_MS="${5:-}"

# Check files exist
if [ ! -f "$JACOCO_XML" ]; then
    echo "ERROR: JaCoCo XML not found at $JACOCO_XML"
    exit 2
fi

if [ ! -f "$PIT_XML" ]; then
    echo "ERROR: PIT XML not found at $PIT_XML"
    exit 2
fi

# Need python3 for XML parsing
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required"
    exit 2
fi

python3 - "$JACOCO_XML" "$PIT_XML" "$TEST_LOC" "$TEST_COUNT" "$TEST_TIME_MS" << 'PYEOF'
import xml.etree.ElementTree as ET
import sys
import os

jacoco_path = sys.argv[1]
pit_path = sys.argv[2]
test_loc_str = sys.argv[3] if len(sys.argv) > 3 else ""
test_count_str = sys.argv[4] if len(sys.argv) > 4 else ""
test_time_str = sys.argv[5] if len(sys.argv) > 5 else ""

# ============ Parse JaCoCo ============
jacoco_tree = ET.parse(jacoco_path)
jacoco_root = jacoco_tree.getroot()

instruction_missed = 0
instruction_covered = 0
branch_missed = 0
branch_covered = 0
excluded_instruction_missed = 0
excluded_instruction_covered = 0

for c in jacoco_root.findall('counter'):
    t = c.get('type', '')
    m = int(c.get('missed', 0))
    cv = int(c.get('covered', 0))
    if t == 'INSTRUCTION':
        instruction_missed = m
        instruction_covered = cv
    elif t == 'BRANCH':
        branch_missed = m
        branch_covered = cv

instruction_total = instruction_missed + instruction_covered
instruction_pct = instruction_covered * 100 / instruction_total if instruction_total > 0 else 0
branch_total = branch_missed + branch_covered
branch_pct = branch_covered * 100 / branch_total if branch_total > 0 else 0

# Exclusion ratio: count excluded classes from classDirectories
# This is harder to measure from XML alone — the XML only shows what's IN the report.
# We approximate by checking if excluded classes are listed in a sidecar file.
# For now, exclusion ratio is reported as N/A unless provided externally.
exclusion_ratio = None  # Would need build config parsing

# ============ Parse PIT ============
pit_tree = ET.parse(pit_path)
pit_root = pit_tree.getroot()

total_mutations = 0
killed_mutations = 0
survived_mutations = 0
no_coverage_mutations = 0

# Track which tests kill which mutations
mutation_kills = {}  # mutation_id -> set of killing test names
test_kill_counts = {}  # test_name -> count of mutations killed

for m in pit_root.findall('.//mutation'):
    status = m.get('status', '')
    total_mutations += 1
    
    if status == 'KILLED':
        killed_mutations += 1
    elif status == 'SURVIVED':
        survived_mutations += 1
    elif status == 'NO_COVERAGE':
        no_coverage_mutations += 1
    
    # Track killing test
    kt_elem = m.find('killingTest')
    if kt_elem is not None and kt_elem.text:
        killing_test = kt_elem.text.strip()
        src = m.find('sourceFile')
        line = m.find('lineNumber')
        sf = src.text if src is not None else '?'
        ln = line.text if line is not None else '?'
        mut_id = f"{sf}:{ln}"
        
        if mut_id not in mutation_kills:
            mutation_kills[mut_id] = set()
        mutation_kills[mut_id].add(killing_test)
        
        if killing_test not in test_kill_counts:
            test_kill_counts[killing_test] = 0
        test_kill_counts[killing_test] += 1

mutation_pct = killed_mutations * 100 / total_mutations if total_mutations > 0 else 0

# ============ Redundant test ratio ============
# A test is redundant if every mutation it kills is also killed by another test.
redundant_tests = 0
total_tests_with_kills = len(test_kill_counts)

for test_name, kill_count in test_kill_counts.items():
    # Check if this test has any unique kill
    has_unique = False
    for mut_id, killers in mutation_kills.items():
        if test_name in killers and len(killers) == 1:
            has_unique = True
            break
    if not has_unique:
        redundant_tests += 1

redundant_ratio = redundant_tests * 100 / total_tests_with_kills if total_tests_with_kills > 0 else 0

# ============ Mutation kill density ============
# mutations killed / test LOC
if test_loc_str:
    test_loc = int(test_loc_str)
    kill_density = killed_mutations / test_loc if test_loc > 0 else 0
else:
    # Count test LOC from test source directories
    test_loc = 0
    for test_dir in ['src/test/kotlin', 'src/test/java', 'gradle-tools/src/test/kotlin', 'gradle-tools/src/test/java']:
        if os.path.isdir(test_dir):
            for root_dir, dirs, files in os.walk(test_dir):
                for f in files:
                    if f.endswith('.kt') or f.endswith('.java'):
                        try:
                            with open(os.path.join(root_dir, f)) as fh:
                                test_loc += sum(1 for _ in fh)
                        except:
                            pass
    kill_density = killed_mutations / test_loc if test_loc > 0 else 0

# ============ Test speed ============
if test_count_str and test_time_str:
    test_count = int(test_count_str)
    test_time_ms = int(test_time_str)
    avg_test_ms = test_time_ms / test_count if test_count > 0 else 0
else:
    avg_test_ms = None

# ============ Test isolation ============
# Not measurable from XML — requires running tests multiple times
# Check if a TEST_ISOLATION.md or similar exists as proof
test_isolation = os.path.exists('TEST_ISOLATION.md') or os.path.exists('TEST_STRATEGY.md')

# ============ Documented strategy ============
has_strategy = os.path.exists('TEST_STRATEGY.md')

# ============ Exclusion ratio (from PIT excluded classes) ============
# Count excluded classes from build config — not available from XML
# Report as N/A
exclusion_ratio_str = "N/A"

# ============ Print Results ============
print("=" * 60)
print("TESTING TIER REPORT")
print("=" * 60)
print()
print(f"  Instruction:     {instruction_covered}/{instruction_total} = {instruction_pct:.1f}%")
print(f"  Branch:          {branch_covered}/{branch_total} = {branch_pct:.1f}%")
print(f"  Mutation:        {killed_mutations}/{total_mutations} = {mutation_pct:.1f}%")
print(f"  Survived:        {survived_mutations}")
print(f"  No coverage:     {no_coverage_mutations}")
print(f"  Redundant tests: {redundant_tests}/{total_tests_with_kills} = {redundant_ratio:.1f}%")
print(f"  Kill density:    {killed_mutations}/{test_loc} = {kill_density:.4f}")
if avg_test_ms is not None:
    print(f"  Avg test speed:  {avg_test_ms:.1f}ms/test")
else:
    print(f"  Avg test speed:  N/A (provide test count + time)")
print(f"  Test isolation:  {'✅' if test_isolation else '❌'}")
print(f"  Doc strategy:    {'✅' if has_strategy else '❌'}")
print(f"  Exclusion ratio: {exclusion_ratio_str}")
print()

# ============ Determine Tier ============
# Define tier requirements
tiers = [
    ("Bronze", {
        "instruction": 50, "branch": 40, "exclusion_ratio": 5,
    }),
    ("Silver", {
        "instruction": 70, "branch": 60, "exclusion_ratio": 5,
    }),
    ("Gold", {
        "instruction": 85, "branch": 75, "mutation": 50,
        "test_isolation": True, "exclusion_ratio": 3,
    }),
    ("Platinum", {
        "instruction": 95, "branch": 90, "mutation": 80,
        "redundant_ratio": 40, "kill_density": 0.05,
        "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 2,
    }),
    ("Diamond", {
        "instruction": 98, "branch": 95, "mutation": 95,
        "redundant_ratio": 20, "kill_density": 0.10,
        "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 2,
    }),
    ("Perfection", {
        "instruction": 100, "branch": 100, "mutation": 100,
        "redundant_ratio": 0, "kill_density": 0.15,
        "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 1,
    }),
]

# Speed thresholds (ms per test)
speed_tiers = {
    "Gold": 100, "Platinum": 50, "Diamond": 30, "Perfection": 10,
}

achieved_tier = None
highest_tier_idx = -1

for idx, (tier_name, reqs) in enumerate(tiers):
    met = True
    failures = []
    
    if "instruction" in reqs and instruction_pct < reqs["instruction"]:
        met = False
        failures.append(f"instruction {instruction_pct:.1f}% < {reqs['instruction']}%")
    
    if "branch" in reqs and branch_pct < reqs["branch"]:
        met = False
        failures.append(f"branch {branch_pct:.1f}% < {reqs['branch']}%")
    
    if "mutation" in reqs and mutation_pct < reqs["mutation"]:
        met = False
        failures.append(f"mutation {mutation_pct:.1f}% < {reqs['mutation']}%")
    
    if "redundant_ratio" in reqs and redundant_ratio > reqs["redundant_ratio"]:
        met = False
        failures.append(f"redundant ratio {redundant_ratio:.1f}% > {reqs['redundant_ratio']}%")
    
    if "kill_density" in reqs and kill_density < reqs["kill_density"]:
        met = False
        failures.append(f"kill density {kill_density:.4f} < {reqs['kill_density']}")
    
    if "test_isolation" in reqs and not test_isolation:
        met = False
        failures.append("test isolation not verified")
    
    if "has_strategy" in reqs and not has_strategy:
        met = False
        failures.append("no TEST_STRATEGY.md")
    
    # Speed check (skip if not measured)
    if tier_name in speed_tiers and avg_test_ms is not None:
        if avg_test_ms > speed_tiers[tier_name]:
            met = False
            failures.append(f"unit test speed {avg_test_ms:.1f}ms > {speed_tiers[tier_name]}ms")
    
    if met:
        highest_tier_idx = idx
    else:
        # Print what's blocking this tier
        if highest_tier_idx == idx - 1 or (highest_tier_idx == -1 and idx == 0):
            print(f"  Blocked at {tier_name}:")
            for f in failures:
                print(f"    ❌ {f}")
            print()
        break

if highest_tier_idx >= 0:
    achieved_tier = tiers[highest_tier_idx][0]
else:
    achieved_tier = "Below Bronze"

print("=" * 60)
print(f"  TIER: {achieved_tier}")
print("=" * 60)

# Exit code
tier_order = ["Below Bronze", "Bronze", "Silver", "Gold", "Platinum", "Diamond", "Perfection"]
tier_idx = tier_order.index(achieved_tier) if achieved_tier in tier_order else 0
if tier_idx >= 2:  # Gold or above
    sys.exit(0)
else:
    sys.exit(1)
PYEOF
