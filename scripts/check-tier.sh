#!/bin/sh
# check-tier.sh v3.0 — Testing Tier System with hybrid granularity + redundancy gates
#
# Usage: check-tier.sh [--floor <tier>] [--integration-junit-dir <dir>] [--test-src <dir>]
#                      <jacoco-xml> <pit-xml> [junit-xml-dir]
#
# --floor <tier>               : Minimum tier (default: Gold)
# --integration-junit-dir <dir>: Integration test JUnit XML dir (separate timing)
# --test-src <dir>             : Test source dir for M_p source analysis (Phase 2, optional)
#
# Gates enforced:
#   Axiom 1: Instruction + Branch coverage (JaCoCo)
#   Axiom 2: Mutation score (PIT)
#   Axiom 3a: M_t — max transitive methods per test (PIT mutations.xml) [Phase 1]
#   Axiom 3b: R  — max killers per mutation (PIT killingTests) [Phase 1]
#   Axiom 3c: M_p — max primary methods per test (source analysis) [Phase 2, optional]
#   Guardrail: Exclusion ratio, unit test speed, partial PIT detection

JACOCO_XML=""
PIT_XML=""
JUNIT_DIR=""
INTEGRATION_JUNIT_DIR=""
TEST_SRC_DIR=""
FLOOR_TIER="Gold"

while [ $# -gt 0 ]; do
    case "$1" in
        --floor)
            FLOOR_TIER="$2"; shift 2 ;;
        --integration-junit-dir)
            INTEGRATION_JUNIT_DIR="$2"; shift 2 ;;
        --test-src)
            TEST_SRC_DIR="$2"; shift 2 ;;
        *)
            if [ -z "$JACOCO_XML" ]; then JACOCO_XML="$1"
            elif [ -z "$PIT_XML" ]; then PIT_XML="$1"
            elif [ -z "$JUNIT_DIR" ]; then JUNIT_DIR="$1"
            fi
            shift ;;
    esac
done

JACOCO_XML="${JACOCO_XML:-gradle-tools/build/reports/jacoco/test/jacocoTestReport.xml}"
PIT_XML="${PIT_XML:-gradle-tools/build/reports/pitest/mutations.xml}"
JUNIT_DIR="${JUNIT_DIR:-gradle-tools/build/test-results/test}"

if [ ! -f "$JACOCO_XML" ]; then echo "ERROR: JaCoCo XML not found at $JACOCO_XML"; exit 2; fi
if [ ! -f "$PIT_XML" ]; then echo "ERROR: PIT XML not found at $PIT_XML"; exit 2; fi
if ! command -v python3 >/dev/null 2>&1; then echo "ERROR: python3 is required"; exit 2; fi

python3 - "$JACOCO_XML" "$PIT_XML" "$JUNIT_DIR" "$FLOOR_TIER" "$INTEGRATION_JUNIT_DIR" "$TEST_SRC_DIR" << 'PYEOF'
import xml.etree.ElementTree as ET
import sys, os, glob, subprocess, re
from collections import defaultdict

jacoco_path = sys.argv[1]
pit_path = sys.argv[2]
junit_dir = sys.argv[3] if len(sys.argv) > 3 else ""
floor_tier = sys.argv[4] if len(sys.argv) > 4 else "Gold"
integration_junit_dir = sys.argv[5] if len(sys.argv) > 5 else ""
test_src_dir = sys.argv[6] if len(sys.argv) > 6 else ""

# ============ Parse JaCoCo ============
jacoco_root = ET.parse(jacoco_path).getroot()
instruction_missed = instruction_covered = branch_missed = branch_covered = 0
for c in jacoco_root.findall('counter'):
    t, m, cv = c.get('type', ''), int(c.get('missed', 0)), int(c.get('covered', 0))
    if t == 'INSTRUCTION': instruction_missed, instruction_covered = m, cv
    elif t == 'BRANCH': branch_missed, branch_covered = m, cv

instruction_total = instruction_missed + instruction_covered
instruction_pct = instruction_covered * 100 / instruction_total if instruction_total > 0 else 0
branch_total = branch_missed + branch_covered
branch_pct = branch_covered * 100 / branch_total if branch_total > 0 else 0

# ============ Parse PIT ============
pit_root = ET.parse(pit_path).getroot()
is_partial = pit_root.get('partial', 'false').lower() == 'true'

total_mutations = killed_mutations = survived_mutations = no_coverage_mutations = 0
pit_classes = set()
# Per-mutation: {mut_id: {test_names}}
mutation_killers = defaultdict(set)
# Per-test: {test_name: set of (mutatedClass, mutatedMethod)}
test_methods = defaultdict(set)

def extract_method_name(test_full):
    """Extract clean test method name from PIT's JUnit5 unique ID format."""
    if '[method:' in test_full:
        raw = test_full.split('[method:')[1]
        # Remove trailing ] and any ]() suffix artifacts
        method = raw.rstrip(']')
        return method
    return test_full.strip()

for m in pit_root.findall('.//mutation'):
    status = m.get('status', '')
    total_mutations += 1
    if status == 'KILLED': killed_mutations += 1
    elif status == 'SURVIVED': survived_mutations += 1
    elif status == 'NO_COVERAGE': no_coverage_mutations += 1

    cls_elem = m.find('mutatedClass')
    method_elem = m.find('mutatedMethod')
    src = m.find('sourceFile')
    line = m.find('lineNumber')
    mutator = m.find('mutator')
    cls_name = cls_elem.text if cls_elem is not None else '?'
    method_name = method_elem.text if method_elem is not None else '?'
    mut_id = f"{src.text if src is not None else '?'}:{line.text if line is not None else '?'}:{mutator.text.split('.')[-1] if mutator is not None else '?'}"

    if cls_name != '?': pit_classes.add(cls_name)

    # Build method key (normalized — strip Kotlin module suffix like $gradle_tools)
    method_key = f"{cls_name}::{method_name}"
    method_key = re.sub(r'\$.*', '', method_key)  # normalize synthetic suffixes

    # Parse killingTests (plural, fullMutationMatrix) or killingTest (singular)
    kt_elem = m.find('killingTests')
    if kt_elem is not None and kt_elem.text:
        for test_full in kt_elem.text.split('|'):
            test_name = extract_method_name(test_full)
            if test_name:
                mutation_killers[mut_id].add(test_name)
                test_methods[test_name].add(method_key)
    else:
        kt_elem = m.find('killingTest')
        if kt_elem is not None and kt_elem.text:
            test_name = extract_method_name(kt_elem.text)
            if test_name:
                mutation_killers[mut_id].add(test_name)
                test_methods[test_name].add(method_key)

mutation_pct = killed_mutations * 100 / total_mutations if total_mutations > 0 else 0

# ============ Compute M_t (transitive methods per test) ============
# M_t for each test = number of unique (class, method) pairs it kills mutations in
test_mt = {t: len(methods) for t, methods in test_methods.items()}
max_mt = max(test_mt.values()) if test_mt else 0

# Also compute M_t distribution
mt_distribution = defaultdict(int)
for t, mt in test_mt.items():
    mt_distribution[mt] += 1

# ============ Compute R (killers per mutation) ============
# R for each killed mutation = number of tests that kill it
mutation_r = {mid: len(killers) for mid, killers in mutation_killers.items() if killers}
max_r = max(mutation_r.values()) if mutation_r else 0

# R distribution
r_distribution = defaultdict(int)
for mid, r in mutation_r.items():
    r_distribution[r] += 1

# ============ Parse JUnit ============
test_count = 0
test_time_seconds = 0.0
if junit_dir and os.path.isdir(junit_dir):
    for xml_file in glob.glob(os.path.join(junit_dir, '*.xml')):
        try:
            suite = ET.parse(xml_file).getroot()
            test_count += int(suite.get('tests', 0))
            test_time_seconds += float(suite.get('time', 0))
        except: pass

avg_test_ms = (test_time_seconds * 1000 / test_count) if test_count > 0 else None

integration_test_count = 0
integration_test_time_seconds = 0.0
if integration_junit_dir and os.path.isdir(integration_junit_dir):
    for xml_file in glob.glob(os.path.join(integration_junit_dir, '*.xml')):
        try:
            suite = ET.parse(xml_file).getroot()
            integration_test_count += int(suite.get('tests', 0))
            integration_test_time_seconds += float(suite.get('time', 0))
        except: pass

integration_avg_test_ms = (integration_test_time_seconds * 1000 / integration_test_count) if integration_test_count > 0 else None

# ============ Test isolation + strategy ============
test_isolation = os.path.exists('TEST_ISOLATION.md') or os.path.exists('TEST_STRATEGY.md')
has_strategy = os.path.exists('TEST_STRATEGY.md')

# ============ Exclusion ratio ============
included_classes = set()
for pkg in jacoco_root.findall('package'):
    for cls in pkg.findall('class'):
        name = cls.get('name', '')
        if name: included_classes.add(name)

class_dirs = ['gradle-tools/build/classes/kotlin/main', 'build/classes/kotlin/main', 'build/classes/java/main']
excluded_instr_count = 0
excluded_class_names = []

for class_dir in class_dirs:
    if not os.path.isdir(class_dir): continue
    for root_dir, dirs, files in os.walk(class_dir):
        for f in files:
            if not f.endswith('.class'): continue
            full_path = os.path.join(root_dir, f)
            rel_path = os.path.relpath(full_path, class_dir)
            cls_name = rel_path.replace('.class', '').replace(os.sep, '/')
            cls_base = cls_name.split('$')[0]
            if cls_name in included_classes or cls_base in included_classes: continue
            found = any(inc == cls_name or inc.startswith(cls_name + '$') or cls_name.startswith(inc + '$') for inc in included_classes)
            if found: continue
            try:
                result = subprocess.run(['javap', '-c', full_path], capture_output=True, text=True, timeout=10)
                instr_count = sum(1 for line in result.stdout.split('\n') if line.strip() and ':' in line and not line.strip().startswith('//'))
                excluded_instr_count += instr_count
                excluded_class_names.append(cls_name.split('/')[-1])
            except: pass
    break

included_instr = instruction_covered + instruction_missed
total_instr = included_instr + excluded_instr_count
exclusion_ratio_pct = excluded_instr_count * 100 / total_instr if total_instr > 0 else 0

# ============ M_p (Phase 2 — source analysis, optional) ============
max_mp = None
mp_warning = ""
if test_src_dir and os.path.isdir(test_src_dir):
    # Phase 2: parse test source for direct production method calls
    # This is a simplified implementation — full implementation needs call graph analysis
    mp_warning = "  (M_p source analysis: Phase 2 — not yet implemented)"
else:
    mp_warning = "  (M_p: Phase 2 — pass --test-src to enable)"

# ============ Print Results ============
print("=" * 60)
print("TESTING TIER REPORT v3.0")
print("=" * 60)
print()
print(f"  Instruction:      {instruction_covered}/{instruction_total} = {instruction_pct:.1f}%")
print(f"  Branch:           {branch_covered}/{branch_total} = {branch_pct:.1f}%")
print(f"  Mutation:         {killed_mutations}/{total_mutations} = {mutation_pct:.1f}%")
print(f"  Survived:         {survived_mutations}")
print(f"  No coverage:      {no_coverage_mutations}")
print(f"  PIT run:          {'PARTIAL (stale cache)' if is_partial else 'Complete'}")
print(f"  Test count:       {test_count} (unit)")
if integration_test_count > 0:
    print(f"  Integration:      {integration_test_count} tests")
if avg_test_ms is not None:
    print(f"  Unit test speed:  {avg_test_ms:.1f}ms/test")
else:
    print(f"  Unit test speed:  N/A")
if integration_avg_test_ms is not None:
    print(f"  Integ test speed: {integration_avg_test_ms:.1f}ms/test")

# Axiom 3a: M_t
print(f"  M_t (max):        {max_mt} transitive methods/test")
print(f"  M_t dist:         " + ", ".join(f"{mt}m:{cnt}t" for mt, cnt in sorted(mt_distribution.items())[:8]))

# Axiom 3b: R
print(f"  R (max):          {max_r} killers/mutation")
print(f"  R dist:           " + ", ".join(f"{r}k:{cnt}m" for r, cnt in sorted(r_distribution.items())[:8]))

# Axiom 3c: M_p (Phase 2)
if max_mp is not None:
    print(f"  M_p (max):        {max_mp} primary methods/test")
else:
    print(f"  M_p (max):        Phase 2 {mp_warning}")

print(f"  Test isolation:   {'Yes' if test_isolation else 'No'}")
print(f"  Doc strategy:     {'Yes' if has_strategy else 'No'}")
print(f"  Exclusion ratio:  {exclusion_ratio_pct:.1f}% ({excluded_instr_count}/{total_instr} instr excluded)")
if no_mutation_classes := [c for c in [n for pkg in jacoco_root.findall('package') for cls in pkg.findall('class') for n in [cls.get('name','')] if n] if c.replace('/','.') not in str(pit_classes) and any(int(counter.get('covered',0))+int(counter.get('missed',0))>0 for counter in [cl for cl in jacoco_root.findall(f'.//class[@name="{c}"]/counter[@type="BRANCH"]')])]:
    print(f"\n  WARNING: {len(no_mutation_classes)} classes have JaCoCo branches but NO PIT mutations")
print()

# ============ Tier Definitions (v3.0) ============
# TES removed. Replaced by M_t + R + M_p.
# M_p is Phase 2 — not enforced yet. When --test-src is provided, it's checked.
tiers = [
    ("Bronze", {
        "instruction": 50, "branch": 40, "mutation": 20,
        "mt": 10, "r": 15,
        "exclusion_ratio": 5.0, "unit_speed": 200,
    }),
    ("Silver", {
        "instruction": 70, "branch": 60, "mutation": 35,
        "mt": 6, "r": 10,
        "exclusion_ratio": 5.0, "unit_speed": 100,
    }),
    ("Gold", {
        "instruction": 85, "branch": 75, "mutation": 50,
        "mt": 4, "r": 5,
        "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 3.0, "unit_speed": 50,
        "requires_full_pit": True,
    }),
    ("Platinum", {
        "instruction": 95, "branch": 90, "mutation": 80,
        "mt": 3, "r": 3,
        "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 2.0, "unit_speed": 30,
        "requires_full_pit": True,
    }),
    ("Perfection", {
        "instruction": 100, "branch": 100, "mutation": 100,
        "mt": 3, "r": 3,
        "test_isolation": True, "has_strategy": True,
        "exclusion_ratio": 1.0, "unit_speed": 10,
        "requires_full_pit": True,
    }),
]

highest_tier_idx = -1

for idx, (tier_name, reqs) in enumerate(tiers):
    met = True
    failures = []

    if "instruction" in reqs and instruction_pct < reqs["instruction"]:
        met = False; failures.append(f"instruction {instruction_pct:.1f}% < {reqs['instruction']}%")

    if "branch" in reqs and branch_pct < reqs["branch"]:
        met = False; failures.append(f"branch {branch_pct:.1f}% < {reqs['branch']}%")

    if "mutation" in reqs and mutation_pct < reqs["mutation"]:
        met = False; failures.append(f"mutation {mutation_pct:.1f}% < {reqs['mutation']}%")

    if "mt" in reqs:
        if max_mt > reqs["mt"]:
            met = False; failures.append(f"M_t {max_mt} > {reqs['mt']} (mega-test or broad test)")

    if "r" in reqs:
        if max_r > reqs["r"]:
            met = False; failures.append(f"R {max_r} > {reqs['r']} (redundant killers)")

    if "requires_full_pit" in reqs and is_partial:
        met = False; failures.append("partial PIT run (stale cache)")

    if "test_isolation" in reqs and not test_isolation:
        met = False; failures.append("test isolation not verified")

    if "has_strategy" in reqs and not has_strategy:
        met = False; failures.append("no TEST_STRATEGY.md")

    if "exclusion_ratio" in reqs and exclusion_ratio_pct > reqs["exclusion_ratio"]:
        met = False; failures.append(f"exclusion ratio {exclusion_ratio_pct:.1f}% > {reqs['exclusion_ratio']}%")

    if "unit_speed" in reqs and avg_test_ms is not None:
        if avg_test_ms > reqs["unit_speed"]:
            met = False; failures.append(f"unit test speed {avg_test_ms:.1f}ms > {reqs['unit_speed']}ms")

    # Phase 2: M_p (only if test source analysis is available)
    if "mp" in reqs and max_mp is not None:
        if max_mp > reqs["mp"]:
            met = False; failures.append(f"M_p {max_mp} > {reqs['mp']} (unfocused test)")

    if met:
        highest_tier_idx = idx
    else:
        if highest_tier_idx == idx - 1 or (highest_tier_idx == -1 and idx == 0):
            print(f"  Blocked at {tier_name}:")
            for f in failures:
                print(f"    X {f}")
            print()
        break

achieved_tier = tiers[highest_tier_idx][0] if highest_tier_idx >= 0 else "Below Bronze"

print("=" * 60)
print(f"  TIER: {achieved_tier}")
print("=" * 60)

tier_order = ["Below Bronze", "Bronze", "Silver", "Gold", "Platinum", "Perfection"]
tier_idx = tier_order.index(achieved_tier) if achieved_tier in tier_order else 0
floor_idx = tier_order.index(floor_tier) if floor_tier in tier_order else 3

if tier_idx >= floor_idx:
    sys.exit(0)
else:
    print(f"\n  FAILED: Tier {achieved_tier} is below floor {floor_tier}")
    sys.exit(1)
PYEOF
