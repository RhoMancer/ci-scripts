#!/bin/sh
# check-tier.sh — Determine a repo's testing tier from JaCoCo + PIT + JUnit XML reports.
# Usage: check-tier.sh [--floor <tier>] <jacoco-xml> <pit-xml> [junit-xml-dir]
#
# --floor <tier> : Minimum tier required (default: Gold). Build fails if below.
#                  Valid: Bronze, Silver, Gold, Platinum, Diamond, Perfection
#
# Outputs: tier name + per-metric breakdown.
# Exit code: 0 if tier >= floor, 1 if below floor, 2 if reports missing.
#
# Part of the Angus Software Testing Tier System.
# See: TEST_TIER_SYSTEM.md for full definitions.

JACOCO_XML=""
PIT_XML=""
JUNIT_DIR=""
FLOOR_TIER="Gold"

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --floor)
            FLOOR_TIER="$2"
            shift 2
            ;;
        *)
            if [ -z "$JACOCO_XML" ]; then
                JACOCO_XML="$1"
            elif [ -z "$PIT_XML" ]; then
                PIT_XML="$1"
            elif [ -z "$JUNIT_DIR" ]; then
                JUNIT_DIR="$1"
            fi
            shift
            ;;
    esac
done

JACOCO_XML="${JACOCO_XML:-gradle-tools/build/reports/jacoco/test/jacocoTestReport.xml}"
PIT_XML="${PIT_XML:-gradle-tools/build/reports/pitest/mutations.xml}"
JUNIT_DIR="${JUNIT_DIR:-gradle-tools/build/test-results/test}"

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

python3 - "$JACOCO_XML" "$PIT_XML" "$JUNIT_DIR" "$FLOOR_TIER" << 'PYEOF'
import xml.etree.ElementTree as ET
import sys
import os
import glob

jacoco_path = sys.argv[1]
pit_path = sys.argv[2]
junit_dir = sys.argv[3] if len(sys.argv) > 3 else ""
floor_tier = sys.argv[4] if len(sys.argv) > 4 else "Gold"

# ============ Parse JaCoCo ============
jacoco_tree = ET.parse(jacoco_path)
jacoco_root = jacoco_tree.getroot()

instruction_missed = 0
instruction_covered = 0
branch_missed = 0
branch_covered = 0

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

# ============ Parse PIT ============
pit_tree = ET.parse(pit_path)
pit_root = pit_tree.getroot()

total_mutations = 0
killed_mutations = 0
survived_mutations = 0
no_coverage_mutations = 0

# Track which classes PIT generated mutations for
pit_classes = set()

for m in pit_root.findall('.//mutation'):
    status = m.get('status', '')
    total_mutations += 1
    if status == 'KILLED':
        killed_mutations += 1
    elif status == 'SURVIVED':
        survived_mutations += 1
    elif status == 'NO_COVERAGE':
        no_coverage_mutations += 1
    cls = m.find('mutatedClass')
    if cls is not None and cls.text:
        pit_classes.add(cls.text)

mutation_pct = killed_mutations * 100 / total_mutations if total_mutations > 0 else 0

# ============ Exclusion consistency check ============
# JaCoCo and PIT must exclude the same classes. If a class is in JaCoCo
# but has NO mutations in PIT, it's either excluded from PIT (mismatch — FAIL)
# or has no mutatable bytecode (OK — but only if it also has no branches,
# since PIT's RemoveConditional mutator targets every branch).
jacoco_classes = {}  # name -> has_branches
for pkg in jacoco_root.findall('package'):
    for cls in pkg.findall('class'):
        cls_name = cls.get('name', '')
        if not cls_name:
            continue
        has_branches = False
        for counter in cls.findall('counter'):
            if counter.get('type') == 'BRANCH':
                covered = int(counter.get('covered', 0))
                missed = int(counter.get('missed', 0))
                if covered + missed > 0:
                    has_branches = True
        jacoco_classes[cls_name] = has_branches

# Find classes in JaCoCo but not in PIT
exclusion_mismatches = []
for cls_name, has_branches in jacoco_classes.items():
    cls_normalized = cls_name.replace('/', '.')
    found = any(
        pit_cls.startswith(cls_normalized) or cls_normalized.startswith(pit_cls)
        for pit_cls in pit_classes
    )
    if not found:
        short_name = cls_name.split('/')[-1]
        if has_branches:
            # Has branches but no mutations = definitely excluded from PIT
            exclusion_mismatches.append(short_name)

# ============ Parse JUnit (test count + time) ============
test_count = 0
test_time_seconds = 0.0

if junit_dir and os.path.isdir(junit_dir):
    for xml_file in glob.glob(os.path.join(junit_dir, '*.xml')):
        try:
            tree = ET.parse(xml_file)
            suite = tree.getroot()
            test_count += int(suite.get('tests', 0))
            test_time_seconds += float(suite.get('time', 0))
        except:
            pass

test_time_ms = test_time_seconds * 1000
avg_test_ms = test_time_ms / test_count if test_count > 0 else None

# ============ Test Efficiency Score ============
# Formula: killed_mutations / test_count (kills per test)
# Higher = better. Each test should kill >1 mutation on average.
if test_count > 0:
    test_efficiency = killed_mutations / test_count
else:
    test_efficiency = 0

# ============ Test isolation ============
test_isolation = os.path.exists('TEST_ISOLATION.md') or os.path.exists('TEST_STRATEGY.md')

# ============ Documented strategy ============
has_strategy = os.path.exists('TEST_STRATEGY.md')

# ============ Exclusion ratio ============
exclusion_ratio_str = "N/A"

# ============ Print Results ============
print("=" * 60)
print("TESTING TIER REPORT")
print("=" * 60)
print()
print(f"  Instruction:      {instruction_covered}/{instruction_total} = {instruction_pct:.1f}%")
print(f"  Branch:           {branch_covered}/{branch_total} = {branch_pct:.1f}%")
print(f"  Mutation:         {killed_mutations}/{total_mutations} = {mutation_pct:.1f}%")
print(f"  Survived:         {survived_mutations}")
print(f"  No coverage:      {no_coverage_mutations}")
print(f"  Test count:       {test_count}")
if avg_test_ms is not None:
    print(f"  Avg test speed:   {avg_test_ms:.1f}ms/test")
else:
    print(f"  Avg test speed:   N/A")
print(f"  Test Efficiency:  {test_efficiency:.3f}  [K/T = kills per test]")
print(f"  Test isolation:   {'Yes' if test_isolation else 'No'}")
print(f"  Doc strategy:     {'Yes' if has_strategy else 'No'}")
print(f"  Exclusion ratio:  {exclusion_ratio_str}")
if exclusion_mismatches:
    print(f"\n  FATAL: {len(exclusion_mismatches)} classes have JaCoCo branches but NO PIT mutations:")
    for cls in sorted(exclusion_mismatches)[:10]:
        print(f"    ! {cls}")
    if len(exclusion_mismatches) > 10:
        print(f"    ... and {len(exclusion_mismatches) - 10} more")
    print(f"\n  These classes are excluded from PIT but not JaCoCo.")
    print(f"  Exclusion lists MUST be identical. Add to JaCoCo excludes or remove from PIT excludes.")
    sys.exit(2)
print()

# ============ Determine Tier ============
tiers = [
    ("Bronze", {
        "instruction": 50, "branch": 40,
    }),
    ("Silver", {
        "instruction": 70, "branch": 60,
    }),
    ("Gold", {
        "instruction": 85, "branch": 75, "mutation": 50,
        "test_efficiency": 0.3, "test_isolation": True,
    }),
    ("Platinum", {
        "instruction": 95, "branch": 90, "mutation": 80,
        "test_efficiency": 0.5, "test_isolation": True, "has_strategy": True,
    }),
    ("Diamond", {
        "instruction": 98, "branch": 95, "mutation": 95,
        "test_efficiency": 0.9, "test_isolation": True, "has_strategy": True,
    }),
    ("Perfection", {
        "instruction": 100, "branch": 100, "mutation": 100,
        "test_efficiency": 1.0, "test_isolation": True, "has_strategy": True,
    }),
]

# Speed thresholds (ms per test)
speed_tiers = {
    "Gold": 100, "Platinum": 50, "Diamond": 30, "Perfection": 10,
}

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

    if "test_efficiency" in reqs and test_efficiency < reqs["test_efficiency"]:
        met = False
        failures.append(f"test efficiency {test_efficiency:.3f} < {reqs['test_efficiency']}")

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
        if highest_tier_idx == idx - 1 or (highest_tier_idx == -1 and idx == 0):
            print(f"  Blocked at {tier_name}:")
            for f in failures:
                print(f"    X {f}")
            print()
        break

if highest_tier_idx >= 0:
    achieved_tier = tiers[highest_tier_idx][0]
else:
    achieved_tier = "Below Bronze"

print("=" * 60)
print(f"  TIER: {achieved_tier}")
print("=" * 60)

# Exit code: 0 if achieved tier >= floor tier, 1 if below
tier_order = ["Below Bronze", "Bronze", "Silver", "Gold", "Platinum", "Diamond", "Perfection"]
tier_idx = tier_order.index(achieved_tier) if achieved_tier in tier_order else 0
floor_idx = tier_order.index(floor_tier) if floor_tier in tier_order else 3  # default Gold
if tier_idx >= floor_idx:
    sys.exit(0)
else:
    print(f"\n  FAILED: Tier {achieved_tier} is below floor {floor_tier}")
    sys.exit(1)
PYEOF
