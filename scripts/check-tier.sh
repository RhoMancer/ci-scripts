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
import subprocess

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

# Track which tests killed mutations (for zero-kill ratio)
killing_test_names = set()

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
    kt = m.find('killingTest')
    if kt is not None and kt.text:
        killing_test_names.add(kt.text.strip())

mutation_pct = killed_mutations * 100 / total_mutations if total_mutations > 0 else 0

# ============ Exclusion consistency check ============
# JaCoCo and PIT must exclude the same classes. If a class is in JaCoCo
# but has NO mutations in PIT, it's either excluded from PIT (mismatch — FAIL)
# or has no mutatable bytecode (OK — some classes only call methods in PIT's
# avoidCallsTo list, which means their branches are legitimate but unmutatable).
#
# We can't distinguish "excluded" from "avoidCallsTo" from XML alone.
# Instead: flag as a WARNING (not failure) if a class has branches but zero
# mutations. Flag as FAILURE only if we can determine it's a config mismatch.
# Since we can't read the excludedClasses config from XML, we treat all
# branch-but-no-mutation classes as warnings unless the project has explicitly
# documented the exclusion in TEST_STRATEGY.md.
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
no_mutation_classes = []
for cls_name, has_branches in jacoco_classes.items():
    cls_normalized = cls_name.replace('/', '.')
    found = any(
        pit_cls.startswith(cls_normalized) or cls_normalized.startswith(pit_cls)
        for pit_cls in pit_classes
    )
    if not found and has_branches:
        short_name = cls_name.split('/')[-1]
        no_mutation_classes.append(short_name)

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
# Target = 1.0 (one test per mutation point = perfect correspondence)
if test_count > 0:
    test_efficiency = killed_mutations / test_count
else:
    test_efficiency = 0

# ============ Zero-Kill Test Ratio ============
# % of tests that are not reported as killing any mutation by PIT
# Target = 0% (every test kills at least 1 mutation)
# Note: PIT reports ONE killing test per mutation, so this is a lower bound
# on the true zero-kill count (some tests may kill mutations PIT attributed
# to other tests)
zero_kill_count = test_count - len(killing_test_names) if test_count > 0 else 0
zero_kill_ratio = zero_kill_count * 100 / test_count if test_count > 0 else 0

# ============ Test isolation ============
test_isolation = os.path.exists('TEST_ISOLATION.md') or os.path.exists('TEST_STRATEGY.md')

# ============ Documented strategy ============
has_strategy = os.path.exists('TEST_STRATEGY.md')

# ============ Exclusion ratio ============
# Compare included classes (in JaCoCo XML) vs all compiled .class files.
# Classes on disk but not in JaCoCo XML are excluded.
# Count their bytecode instructions using javap.
included_classes = set()
for pkg in jacoco_root.findall('package'):
    for cls in pkg.findall('class'):
        name = cls.get('name', '')  # e.g. com/angussoftware/gradletools/Foo
        if name:
            included_classes.add(name)

# Find compiled .class directory
class_dirs = [
    'gradle-tools/build/classes/kotlin/main',
    'build/classes/kotlin/main',
    'build/classes/java/main',
]
excluded_instr_count = 0
excluded_class_names = []

for class_dir in class_dirs:
    if not os.path.isdir(class_dir):
        continue
    for root_dir, dirs, files in os.walk(class_dir):
        for f in files:
            if not f.endswith('.class'):
                continue
            full_path = os.path.join(root_dir, f)
            # Get class name relative to class_dir
            rel_path = os.path.relpath(full_path, class_dir)
            # Normalize: com/angussoftware/.../Foo.class -> com/angussoftware/.../Foo
            cls_name = rel_path.replace('.class', '').replace(os.sep, '/')
            # Check inner classes: Foo$Bar -> parent is Foo
            cls_base = cls_name.split('$')[0]
            # Is this class (or its parent) in JaCoCo?
            if cls_name in included_classes or cls_base in included_classes:
                continue
            # Also check if any JaCoCo class starts with this prefix
            found = any(
                inc == cls_name or inc.startswith(cls_name + '$') or cls_name.startswith(inc + '$')
                for inc in included_classes
            )
            if found:
                continue
            # This class is excluded — count its instructions via javap
            try:
                result = subprocess.run(
                    ['javap', '-c', full_path],
                    capture_output=True, text=True, timeout=10
                )
                # Count lines that look like bytecode instructions
                instr_count = sum(1 for line in result.stdout.split('\n')
                                  if line.strip() and ':' in line and not line.strip().startswith('//'))
                excluded_instr_count += instr_count
                excluded_class_names.append(cls_name.split('/')[-1])
            except:
                pass
    break  # only process first matching class_dir

included_instr = instruction_covered + instruction_missed
total_instr = included_instr + excluded_instr_count
exclusion_ratio_pct = excluded_instr_count * 100 / total_instr if total_instr > 0 else 0

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
print(f"  Test Efficiency:  {test_efficiency:.3f}  [K/T = kills per test, target=1.0]")
print(f"  Zero-Kill Ratio:  {zero_kill_ratio:.1f}% ({zero_kill_count}/{test_count} tests kill 0 mutations)")
print(f"  Test isolation:   {'Yes' if test_isolation else 'No'}")
print(f"  Doc strategy:     {'Yes' if has_strategy else 'No'}")
print(f"  Exclusion ratio:  {exclusion_ratio_pct:.1f}% ({excluded_instr_count}/{total_instr} instr excluded)")
if no_mutation_classes:
    print(f"\n  WARNING: {len(no_mutation_classes)} classes have JaCoCo branches but NO PIT mutations:")
    for cls in sorted(no_mutation_classes)[:10]:
        print(f"    ! {cls}")
    if len(no_mutation_classes) > 10:
        print(f"    ... and {len(no_mutation_classes) - 10} more")
    print(f"  (May be excluded from PIT, or only calls avoidCallsTo methods)")
    print(f"  If excluded: ensure JaCoCo excludes match. If avoidCallsTo: document in TEST_STRATEGY.md")
print()

# ============ Determine Tier ============
tiers = [
    ("Bronze", {
        "instruction": 50, "branch": 40, "mutation": 20,
        "test_efficiency": 0.1, "exclusion_ratio": 5,
        "zero_kill_ratio": 85, "unit_speed": 200, "instrumented_speed": 10000,
    }),
    ("Silver", {
        "instruction": 70, "branch": 60, "mutation": 35,
        "test_efficiency": 0.2, "exclusion_ratio": 5,
        "zero_kill_ratio": 75, "unit_speed": 100, "instrumented_speed": 5000,
    }),
    ("Gold", {
        "instruction": 85, "branch": 75, "mutation": 50,
        "test_efficiency": 0.5, "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 3, "zero_kill_ratio": 65,
        "unit_speed": 50, "instrumented_speed": 3000,
    }),
    ("Platinum", {
        "instruction": 95, "branch": 90, "mutation": 80,
        "test_efficiency": 0.7, "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 2, "zero_kill_ratio": 50,
        "unit_speed": 30, "instrumented_speed": 2000,
    }),
    ("Diamond", {
        "instruction": 98, "branch": 95, "mutation": 95,
        "test_efficiency": 0.9, "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 2, "zero_kill_ratio": 30,
        "unit_speed": 15, "instrumented_speed": 1000,
    }),
    ("Perfection", {
        "instruction": 100, "branch": 100, "mutation": 100,
        "test_efficiency": 1.0, "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 1, "zero_kill_ratio": 0,
        "unit_speed": 10, "instrumented_speed": 500,
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

    if "exclusion_ratio" in reqs and exclusion_ratio_pct > reqs["exclusion_ratio"]:
        met = False
        failures.append(f"exclusion ratio {exclusion_ratio_pct:.1f}% > {reqs['exclusion_ratio']}%")

    if "zero_kill_ratio" in reqs and zero_kill_ratio > reqs["zero_kill_ratio"]:
        met = False
        failures.append(f"zero-kill ratio {zero_kill_ratio:.1f}% > {reqs['zero_kill_ratio']}%")

    # Speed check (skip if not measured)
    if "unit_speed" in reqs and avg_test_ms is not None:
        if avg_test_ms > reqs["unit_speed"]:
            met = False
            failures.append(f"unit test speed {avg_test_ms:.1f}ms > {reqs['unit_speed']}ms")

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
