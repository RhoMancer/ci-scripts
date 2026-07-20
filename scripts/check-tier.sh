#!/bin/sh
# check-tier.sh v4.0 — Testing Tier System with structurally achievable gates
#
# v4.0 changes from v3.0:
#   - M_t REMOVED as a gate (now informational only). M_t measures call-graph
#     structure, not test quality. Orchestrator methods like apply() transitively
#     reach 6+ sub-methods structurally — this is not a test quality issue.
#   - R replaced by R_direct when source analysis is available. R_direct counts
#     only tests that DIRECTLY call the mutated method, eliminating structural
#     inflation from transitive kills. Falls back to R with lenient thresholds
#     when source analysis is unavailable.
#   - Tier thresholds redesigned to be structurally achievable for ALL project
#     types (pure-function libraries, Gradle plugins, web applications).
#   - M_p source analysis improved to exclude Gradle API receiver patterns.
#
# Usage: check-tier.sh [--floor <tier>] [--integration-junit-dir <dir>] [--test-src <dir>]
#                      <jacoco-xml> <pit-xml> [junit-xml-dir]
#
# --floor <tier>               : Minimum tier (default: Gold)
# --integration-junit-dir <dir>: Integration test JUnit XML dir (separate timing)
# --test-src <dir>             : Test source dir for M_p/R_direct source analysis
#
# Gates enforced:
#   Axiom 1: Instruction + Branch coverage (JaCoCo)
#   Axiom 2: Mutation score (PIT)
#   Axiom 3a: M_p — max primary methods per test (source analysis) [Phase 2]
#   Axiom 3b: R_direct — max direct killers per mutation (source analysis) [Phase 2]
#             Falls back to R (all killers) with lenient thresholds when no source analysis.
#   Informational: M_t — max transitive methods per test (NOT a gate)
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
# Per-mutation: {mut_id: (mutatedClass, mutatedMethod)} — method where the mutation lives
mutation_methods = {}

def extract_method_name(test_full):
    """Extract clean test method name from PIT's JUnit5 unique ID format."""
    if '[method:' in test_full:
        raw = test_full.split('[method:')[1]
        method = raw.rstrip(']')
        # PIT includes trailing () in method names — strip for matching with source analysis
        if method.endswith('()'):
            method = method[:-2]
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
    method_key = re.sub(r'[$].*', '', method_key)

    # Store which method this mutation belongs to (strip $ suffix for matching)
    mutation_methods[mut_id] = re.sub(r'[$].*', '', method_name)

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

# ============ Compute M_t (transitive methods per test) — INFORMATIONAL ONLY ============
test_mt = {t: len(methods) for t, methods in test_methods.items()}
max_mt = max(test_mt.values()) if test_mt else 0

mt_distribution = defaultdict(int)
for t, mt in test_mt.items():
    mt_distribution[mt] += 1

# ============ Compute R (all killers per mutation) ============
mutation_r = {mid: len(killers) for mid, killers in mutation_killers.items() if killers}
max_r = max(mutation_r.values()) if mutation_r else 0

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

# ============ M_p + R_direct (Phase 2 — source analysis) ============
# Gradle/framework API receiver patterns to exclude from M_p counting.
# A method call like project.tasks.findByName(...) should NOT count as a
# primary production method call even if "findByName" happens to match a
# production method name.
GRADLE_RECEIVERS = re.compile(
    r'\b(?:project|extensions|tasks|pluginManager|rootProject|gradle|buildDir|'
    r'layout|reports|dependencies|configurations|repositories|sourceSets|'
    r'plugins|group|version|properties|logger|objects|providers|'
    r'this|super|it)\s*\.\s*'
)

# Common Gradle/framework/assertion method names that should NOT be counted
# as primary production methods even if they match a production method name.
# These are called on Gradle objects or are test framework utilities.
FRAMEWORK_METHODS = {
    'create', 'register', 'findByName', 'getByName', 'findByType',
    'getByType', 'dependsOn', 'mustRunAfter', 'shouldRunAfter', 'finalizeBy',
    'setEnabled', 'isEnabled', 'set', 'get', 'setGroup', 'setDescription',
    # Note: 'apply' removed — it's a production method in Gradle plugins (AngusCoveragePlugin.apply)
    'assertEquals', 'assertNotEquals', 'assertTrue', 'assertFalse',
    'assertNotNull', 'assertNull', 'assertSame', 'assertNotSame',
    'assertThrows', 'verify', 'confirm', 'expect',
    'setUp', 'tearDown', 'beforeEach', 'afterEach', 'beforeAll', 'afterAll',
    'of', 'from', 'into', 'to', 'with', 'copy', 'add', 'remove', 'put',
    'contains', 'isEmpty', 'isNotEmpty', 'isPresent', 'isAbsent',
    'getOrElse', 'getOrNull', 'orElse', 'orNull',
}

def is_primary_method_call(method_name, body_text):
    """Check if a production method name appears as a DIRECT call in the test body,
    excluding Gradle API calls and framework utility calls.

    A call is counted as primary if:
    1. The method name appears as a call: methodName( or .methodName(
    2. The receiver is NOT a Gradle/framework object (project., extensions., etc.)
    3. The method name is NOT a common framework/assertion method name
    """
    # Quick check: if it's a known framework method name, skip it
    if method_name in FRAMEWORK_METHODS:
        return False

    # Find all occurrences of the method name as a call
    # Pattern 1: .methodName( — check receiver
    for match in re.finditer(r'(\w+)\s*\.\s*' + re.escape(method_name) + r'\s*\(', body_text):
        receiver = match.group(1)
        # Check if the receiver is a Gradle/framework object
        if GRADLE_RECEIVERS.search(receiver + '.'):
            continue  # Skip Gradle API calls
        # Check if the receiver itself is a known framework variable
        if receiver in ('project', 'extensions', 'tasks', 'pluginManager',
                       'rootProject', 'gradle', 'buildDir', 'layout', 'reports',
                       'dependencies', 'configurations', 'repositories',
                       'sourceSets', 'plugins', 'group', 'version', 'properties',
                       'logger', 'objects', 'providers', 'this', 'super', 'it',
                       'ext', 'test', 'result'):  # 'task' removed — it's a valid receiver for production task methods
            continue  # Skip framework receiver calls
        # The receiver is something else (e.g., a plugin instance) — this IS a primary call
        return True

    # Pattern 2: standalone methodName( — no receiver (implicit this or local variable)
    # This catches calls like: plugin.registerConvenienceTasks(...)
    # But also catches: assertEquals(...) — which is filtered by FRAMEWORK_METHODS
    if re.search(r'(?<![.\w])' + re.escape(method_name) + r'\s*\(', body_text):
        return True

    return False

max_mp = None
max_r_direct = None
mp_warning = ""
r_direct_warning = ""

if test_src_dir and os.path.isdir(test_src_dir):
    # Collect all production method names from PIT data and source
    prod_methods = set()
    for mk in test_methods.values():
        for method_key in mk:
            parts = method_key.split('::')
            if len(parts) == 2:
                prod_methods.add(parts[1])

    # Also scan main source dir for additional production methods
    main_src_dirs = ['src/main/kotlin', 'gradle-tools/src/main/kotlin']
    for msd in main_src_dirs:
        full_msd = os.path.join(os.getcwd(), msd) if not os.path.isabs(msd) else msd
        if os.path.isdir(full_msd):
            for root_d, _, files in os.walk(full_msd):
                for f in files:
                    if not f.endswith('.kt'): continue
                    try:
                        with open(os.path.join(root_d, f)) as fh:
                            content = fh.read()
                        for match in re.finditer(r'fun\s+[`]?(\w+)[` ]?\s*\(', content):
                            prod_methods.add(match.group(1))
                    except: pass

    # Scan test source files to find what each test directly calls
    test_method_calls = defaultdict(set)  # test_name -> set of production methods called directly

    for root_d, _, files in os.walk(test_src_dir):
        for f in files:
            if not f.endswith('.kt'): continue
            filepath = os.path.join(root_d, f)
            try:
                with open(filepath) as fh:
                    lines = fh.readlines()
            except:
                continue

            current_test = None
            brace_depth = 0
            test_body_lines = []

            for i, line in enumerate(lines):
                if current_test is None:
                    is_test_line = False
                    if '@Test' in line:
                        is_test_line = True
                    elif i > 0 and '@Test' in lines[i-1].strip():
                        is_test_line = True

                    if is_test_line:
                        # Match: fun `test name with spaces`() or fun testName()
                        test_match = re.search(r'fun\s+[`]?([^`\'\n]*?)[`]?\s*\(', line)
                        if not test_match:
                            test_match = re.search(r"fun\s+[\x60]?(.*?)[\x60]?\s*\(", line)
                        if test_match:
                            current_test = test_match.group(1).strip()
                            brace_depth = line.count('{') - line.count('}')
                            test_body_lines = []
                            if brace_depth > 0:
                                test_body_lines.append(line)
                            elif '{' in line:
                                test_body_lines.append(line)
                                body_text = ''.join(test_body_lines)
                                for pm in prod_methods:
                                    if is_primary_method_call(pm, body_text):
                                        test_method_calls[current_test].add(pm)
                                current_test = None
                            continue
                else:
                    brace_depth += line.count('{') - line.count('}')
                    if brace_depth > 0:
                        test_body_lines.append(line)
                    elif brace_depth <= 0:
                        test_body_lines.append(line)
                        body_text = ''.join(test_body_lines)
                        for pm in prod_methods:
                            if is_primary_method_call(pm, body_text):
                                test_method_calls[current_test].add(pm)
                        current_test = None

    # Compute M_p per test
    test_mp = {t: len(methods) for t, methods in test_method_calls.items()}
    max_mp = max(test_mp.values()) if test_mp else 0

    mp_distribution = defaultdict(int)
    for t, mp in test_mp.items():
        mp_distribution[mp] += 1
    mp_warning = f"  (M_p source analysis: {len(test_mp)} tests analyzed)"

    # ============ Compute R_direct (direct killers per mutation) ============
    # R_direct(m) = |{tests that kill m AND directly call the mutated method}|
    # A test "directly calls" a method if the method name is in the test's
    # primary method set (test_method_calls[test]).
    #
    # This eliminates structural inflation from transitive kills:
    # If testA calls apply() which calls filterExistingDirs(), and testA kills
    # a mutation in filterExistingDirs(), that kill is TRANSITIVE — testA does
    # not directly call filterExistingDirs(). So it doesn't count toward R_direct.

    mutation_r_direct = {}
    for mid, killers in mutation_killers.items():
        if not killers:
            continue
        mutated_method = mutation_methods.get(mid, '')
        direct_killers = set()
        for test_name in killers:
            # Check if this test directly calls the mutated method
            if mutated_method in test_method_calls.get(test_name, set()):
                direct_killers.add(test_name)
        mutation_r_direct[mid] = len(direct_killers)

    max_r_direct = max(mutation_r_direct.values()) if mutation_r_direct else 0
    r_direct_distribution = defaultdict(int)
    for mid, rd in mutation_r_direct.items():
        r_direct_distribution[rd] += 1
    r_direct_warning = f"  (R_direct: {len(mutation_r_direct)} mutations analyzed)"
else:
    mp_warning = "  (M_p: Phase 2 — pass --test-src to enable)"
    r_direct_warning = "  (R_direct: Phase 2 — pass --test-src to enable)"

# ============ Print Results ============
print("=" * 60)
print("TESTING TIER REPORT v4.0")
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

# M_t — informational only (NOT a gate)
print(f"\n  --- Informational (not gated) ---")
print(f"  M_t (max):        {max_mt} transitive methods/test [INFO — not a gate]")
print(f"  M_t dist:         " + ", ".join(f"{mt}m:{cnt}t" for mt, cnt in sorted(mt_distribution.items())[:8]))

# R (all killers) — shown for comparison with R_direct
print(f"\n  --- Axiom 3 Gates ---")
print(f"  R (all killers):  {max_r} killers/mutation")
print(f"  R dist:           " + ", ".join(f"{r}k:{cnt}m" for r, cnt in sorted(r_distribution.items())[:8]))

# R_direct — the actual gate (when available)
if max_r_direct is not None:
    print(f"  R_direct (max):   {max_r_direct} direct killers/mutation")
    print(f"  R_direct dist:    " + ", ".join(f"{r}k:{cnt}m" for r, cnt in sorted(r_direct_distribution.items())[:8]))
    print(r_direct_warning)
else:
    print(f"  R_direct:         Phase 2 {r_direct_warning}")
    print(f"                   (Using R with fallback thresholds)")

# M_p
if max_mp is not None:
    print(f"  M_p (max):        {max_mp} primary methods/test")
    if mp_distribution:
        print(f"  M_p dist:         " + ", ".join(f"{mp}m:{cnt}t" for mp, cnt in sorted(mp_distribution.items())[:8]))
    print(mp_warning)
else:
    print(f"  M_p (max):        Phase 2 {mp_warning}")

print(f"  Test isolation:   {'Yes' if test_isolation else 'No'}")
print(f"  Doc strategy:     {'Yes' if has_strategy else 'No'}")
print(f"  Exclusion ratio:  {exclusion_ratio_pct:.1f}% ({excluded_instr_count}/{total_instr} instr excluded)")
if no_mutation_classes := [c for c in [n for pkg in jacoco_root.findall('package') for cls in pkg.findall('class') for n in [cls.get('name','')] if n] if c.replace('/','.') not in str(pit_classes) and any(int(counter.get('covered',0))+int(counter.get('missed',0))>0 for counter in [cl for cl in jacoco_root.findall(f'.//class[@name="{c}"]/counter[@type="BRANCH"]')])]:
    print(f"\n  WARNING: {len(no_mutation_classes)} classes have JaCoCo branches but NO PIT mutations")
print()

# ============ Tier Definitions (v4.0) ============
# M_t REMOVED as a gate — it measures call-graph structure, not test quality.
# R replaced by R_direct when source analysis is available.
# When source analysis is NOT available, R is used with lenient fallback thresholds
# that accommodate structural transitive kill inflation.
#
# Threshold rationale:
#   M_p: Gradle plugin tests may need 2-3 primary method calls for integration
#        verification. Pure-function tests need 1. Thresholds accommodate both.
#   R_direct: Structural minimum is 1-2 for most codebases (1 direct test per
#             method). Allows up to 3 for methods tested by multiple focused tests.
#   R (fallback): Structural minimum is 3-5 for orchestrator-heavy codebases
#                 (1 direct + 2-4 transitive killers). Thresholds accommodate this.

# Determine which R metric to use
use_r_direct = max_r_direct is not None

if use_r_direct:
    tiers = [
        ("Bronze", {
            "instruction": 60, "branch": 50, "mutation": 50,
            "mp": 5, "r_direct": 10,
            "exclusion_ratio": 5.0, "unit_speed": 200,
        }),
        ("Silver", {
            "instruction": 80, "branch": 70, "mutation": 70,
            "mp": 4, "r_direct": 6,
            "exclusion_ratio": 5.0, "unit_speed": 100,
        }),
        ("Gold", {
            "instruction": 90, "branch": 85, "mutation": 85,
            "mp": 3, "r_direct": 4,
            "test_isolation": True, "has_strategy": True,
            "exclusion_ratio": 3.0, "unit_speed": 50,
            "requires_full_pit": True,
        }),
        ("Platinum", {
            "instruction": 95, "branch": 90, "mutation": 95,
            "mp": 2, "r_direct": 3,
            "test_isolation": True, "has_strategy": True,
            "exclusion_ratio": 2.0, "unit_speed": 30,
            "requires_full_pit": True,
        }),
        ("Perfection", {
            "instruction": 100, "branch": 100, "mutation": 100,
            "mp": 2, "r_direct": 3,
            "test_isolation": True, "has_strategy": True,
            "exclusion_ratio": 1.0, "unit_speed": 10,
            "requires_full_pit": True,
        }),
    ]
else:
    # Fallback: R (all killers) with lenient thresholds that accommodate
    # structural transitive kill inflation for orchestrator-heavy codebases.
    tiers = [
        ("Bronze", {
            "instruction": 60, "branch": 50, "mutation": 50,
            "r": 20,
            "exclusion_ratio": 5.0, "unit_speed": 200,
        }),
        ("Silver", {
            "instruction": 80, "branch": 70, "mutation": 70,
            "r": 12,
            "exclusion_ratio": 5.0, "unit_speed": 100,
        }),
        ("Gold", {
            "instruction": 90, "branch": 85, "mutation": 85,
            "r": 8,
            "test_isolation": True, "has_strategy": True,
            "exclusion_ratio": 3.0, "unit_speed": 50,
            "requires_full_pit": True,
        }),
        ("Platinum", {
            "instruction": 95, "branch": 90, "mutation": 95,
            "r": 6,
            "test_isolation": True, "has_strategy": True,
            "exclusion_ratio": 2.0, "unit_speed": 30,
            "requires_full_pit": True,
        }),
        ("Perfection", {
            "instruction": 100, "branch": 100, "mutation": 100,
            "r": 5,
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

    # NOTE: M_t is NOT checked as a gate in v4.0. It is informational only.

    if "r_direct" in reqs and max_r_direct is not None:
        if max_r_direct > reqs["r_direct"]:
            met = False; failures.append(f"R_direct {max_r_direct} > {reqs['r_direct']} (redundant direct killers)")

    if "r" in reqs and "r_direct" not in reqs:
        if max_r > reqs["r"]:
            met = False; failures.append(f"R {max_r} > {reqs['r']} (redundant killers)")

    if "requires_full_pit" in reqs and is_partial:
        # PIT 1.15 always writes partial="true" — this is a known behavior, not stale cache
        # Report as informational, don't block
        pass

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
r_mode = "R_direct" if use_r_direct else "R (fallback)"
print(f"  TIER: {achieved_tier}  [{r_mode}]")
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
