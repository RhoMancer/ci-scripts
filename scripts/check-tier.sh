#!/bin/sh
# check-tier.sh v4.2 — Anvil Testing System
# The 3-axiom testing tier system with structurally achievable gates
#
# v4.2 changes from v4.1:
#   - Anti-gaming: exclusion ratio replaced with sliding exclusion scale.
#     Fixed percentage thresholds were gameable for large repos (1% of 100K
#     instructions = 1000 instructions = several full classes hidden).
#     New formula: max_excluded = min(N * pct/100, absolute_cap)
#     Small repos use percentage; large repos hit the absolute cap.
#     Perfection is now zero-tolerance (0 excluded instructions).
#
# v4.1 changes from v4.0:
#   - Anti-gaming: speed gate switched from MEAN to MEDIAN (robust against
#     trivial-test dilution). Mean still reported as informational.
#   - Anti-gaming: total wall-clock time added as secondary speed gate.
#     Not gameable by adding trivial tests (they add time).
#   - Anti-gaming: JUnit test count cross-referenced with PIT test methods.
#     Warns if >20% discrepancy (possible trivial tests or fake JUnit XML).
#   - Anti-gaming: zero-mutation-kill diagnostic. Shows how many tests kill
#     zero mutations, broken down by test class.
#   - P95 and P99 test times reported as informational metrics.
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
#   Guardrail: Sliding exclusion scale (percentage + absolute cap), median test speed, total wall-clock, partial PIT detection
#   Anti-gaming: JUnit↔PIT count cross-ref, zero-kill diagnostics

JACOCO_XML=""
PIT_XML=""
JUNIT_DIR=""
INTEGRATION_JUNIT_DIR=""
TEST_SRC_DIR=""
PIT_CONFIG=""
PROJECT_DIR=""
FLOOR_TIER="Gold"

while [ $# -gt 0 ]; do
    case "$1" in
        --floor)
            FLOOR_TIER="$2"; shift 2 ;;
        --integration-junit-dir)
            INTEGRATION_JUNIT_DIR="$2"; shift 2 ;;
        --test-src)
            TEST_SRC_DIR="$2"; shift 2 ;;
        --pit-config)
            PIT_CONFIG="$2"; shift 2 ;;
        --project-dir)
            PROJECT_DIR="$2"; shift 2 ;;
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

python3 - "$JACOCO_XML" "$PIT_XML" "$JUNIT_DIR" "$FLOOR_TIER" "$INTEGRATION_JUNIT_DIR" "$TEST_SRC_DIR" "$PIT_CONFIG" "$PROJECT_DIR" << 'PYEOF'
import xml.etree.ElementTree as ET
import sys, os, glob, subprocess, re, json
from collections import defaultdict

jacoco_path = sys.argv[1]
pit_path = sys.argv[2]
junit_dir = sys.argv[3] if len(sys.argv) > 3 else ""
floor_tier = sys.argv[4] if len(sys.argv) > 4 else "Gold"
integration_junit_dir = sys.argv[5] if len(sys.argv) > 5 else ""
test_src_dir = sys.argv[6] if len(sys.argv) > 6 else ""
pit_config_path = sys.argv[7] if len(sys.argv) > 7 else ""
project_dir = sys.argv[8] if len(sys.argv) > 8 else ""

# Base directory for TEST_STRATEGY.md and other project-relative lookups.
# When --project-dir is provided, project files are searched there instead of CWD.
strategy_base_dir = project_dir if project_dir else os.getcwd()

def strategy_file_exists(filename):
    """Check if a project file exists in the strategy base dir (or CWD as fallback)."""
    if project_dir:
        candidate = os.path.join(project_dir, filename)
        if os.path.exists(candidate):
            return True
    return os.path.exists(filename)

def strategy_file_path(filename):
    """Return the path to a project file if it exists, else None."""
    if project_dir:
        candidate = os.path.join(project_dir, filename)
        if os.path.exists(candidate):
            return candidate
    if os.path.exists(filename):
        return filename
    return None

def read_strategy_file(filename):
    """Read a project file from strategy base dir (or CWD as fallback). Returns content or empty string."""
    path = strategy_file_path(filename)
    if path:
        try:
            with open(path) as f:
                return f.read()
        except:
            pass
    return ""

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

# Verify fullMutationMatrix is enabled (killingTests plural present)
has_full_matrix = any(m.find('killingTests') is not None and m.find('killingTests').text
                      for m in pit_root.findall('.//mutation') if m.get('status') == 'KILLED')
if not has_full_matrix:
    print("  WARNING: fullMutationMatrix appears DISABLED — only singular killingTest found")
    print("  R and R_direct metrics will be inaccurate. Set fullMutationMatrix.set(true) in PIT config.")

total_mutations = killed_mutations = survived_mutations = no_coverage_mutations = 0
pit_classes = set()
pit_mutators = set()
# Per-mutation: {mut_id: {test_names}}
mutation_killers = defaultdict(set)
# Per-test: {test_name: set of (mutatedClass, mutatedMethod)}
test_methods = defaultdict(set)
# Per-mutation: {mut_id: (mutatedClass, mutatedMethod)} — method where the mutation lives
mutation_methods = {}
# All unique test method names that PIT actually ran (from killingTests + succeedingTests)
pit_test_names = set()

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
    # Include index/block in mut_id to avoid duplicates when multiple mutations share file:line:mutator
    idx_elem = m.find('indexes/index')
    idx_val = idx_elem.text if idx_elem is not None else '?'
    block_elem = m.find('blocks/block')
    block_val = block_elem.text if block_elem is not None else '?'
    mut_id = f"{src.text if src is not None else '?'}:{line.text if line is not None else '?'}:{mutator.text.split('.')[-1] if mutator is not None else '?'}:{idx_val}:{block_val}"

    if cls_name != '?': pit_classes.add(cls_name)
    if mutator is not None and mutator.text:
        pit_mutators.add(mutator.text)

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
                pit_test_names.add(test_name)
    else:
        kt_elem = m.find('killingTest')
        if kt_elem is not None and kt_elem.text:
            test_name = extract_method_name(kt_elem.text)
            if test_name:
                mutation_killers[mut_id].add(test_name)
                test_methods[test_name].add(method_key)
                pit_test_names.add(test_name)

    # Parse succeedingTests for cross-reference (tests PIT ran but didn't kill this mutation)
    st_elem = m.find('succeedingTests')
    if st_elem is not None and st_elem.text:
        for test_full in st_elem.text.split('|'):
            test_name = extract_method_name(test_full)
            if test_name:
                pit_test_names.add(test_name)

mutation_pct = killed_mutations * 100 / total_mutations if total_mutations > 0 else 0

# ============ PIT Config Verification (from XML inference) ============
# Infer PIT configuration quality from mutations.xml to detect config gaming.
# A developer can inflate the mutation score by:
#   1. Narrowing targetClasses to exclude hard-to-test classes
#   2. Adding excludedClasses/excludedMethods for methods with surviving mutations
#   3. Changing mutators from STRONGER to DEFAULTS (fewer mutations = higher score)
#   4. Disabling fullMutationMatrix (hides redundant test information)
#
# Checks possible from PIT XML alone:
#   - mutators: if only DEFAULTS present (no STRONGER-exclusive mutators), warn
#   - fullMutationMatrix: already checked above (has_full_matrix)
# Checks requiring class comparison (computed later, after JaCoCo parse):
#   - excludedClasses/targetClasses: classes with JaCoCo branches but no PIT mutations

# Mutators that are ONLY present when STRONGER (or ALL) is configured.
# Source: PIT StandardMutatorGroups.java —
#   DEFAULTS = INVERT_NEGS, MATH, VOID_METHOD_CALLS,
#              REMOVE_CONDITIONALS_ORDER_ELSE, REMOVE_CONDITIONALS_EQUAL_ELSE,
#              CONDITIONALS_BOUNDARY, INCREMENTS, RETURNS (5 return mutators)
#   STRONGER = DEFAULTS + EXPERIMENTAL_SWITCH
#                        + REMOVE_CONDITIONALS_ORDER_IF
#                        + REMOVE_CONDITIONALS_EQUAL_IF
# These three are the STRONGER-exclusive markers:
STRONGER_EXCLUSIVE_MUTATORS = {
    'RemoveConditionalMutator_EQUAL_IF',
    'RemoveConditionalMutator_ORDER_IF',
    'SwitchMutator',
}

has_stronger_mutators = any(
    any(marker in mut for marker in STRONGER_EXCLUSIVE_MUTATORS)
    for mut in pit_mutators
) if pit_mutators else True  # pass if empty (caught by mutation score)

if pit_mutators and not has_stronger_mutators:
    found_names = sorted(set(m.split('.')[-1] for m in pit_mutators))
    print("  WARNING: Only DEFAULTS mutators detected — STRONGER not enabled")
    print(f"  Found: {', '.join(found_names)}")
    print("  Mutation score may be inflated. Set mutators.set(listOf(\"STRONGER\")) in PIT config.")

# ============ PIT Config Verification (from pit-config.json) ============
# If the Gradle dumpPitConfig task produced a JSON config file, use it for
# authoritative verification. This catches excludedMethods and incremental
# analysis that can't be detected from mutations.xml alone.
pit_config = {}
pit_config_source = "not found"
if pit_config_path and os.path.isfile(pit_config_path):
    try:
        with open(pit_config_path) as f:
            pit_config = json.load(f)
        pit_config_source = os.path.basename(pit_config_path)
    except:
        pit_config_source = "parse error"
elif pit_config_path:
    pit_config_source = f"not found at {pit_config_path}"

# Override XML-inferred values with authoritative config when available
if pit_config:
    if 'mutators' in pit_config:
        cfg_mutators = pit_config['mutators']
        has_stronger_mutators = any('STRONGER' in m or 'ALL' in m for m in cfg_mutators)
    if 'enableDefaultIncrementalAnalysis' in pit_config:
        is_partial = pit_config['enableDefaultIncrementalAnalysis']  # treat as partial risk
    # NOTE: fullMutationMatrix from JSON is circular (same config that PIT uses).
    # Keep the XML-inferred check (has_full_matrix from line 110) as authoritative.

# Read TEST_STRATEGY.md early (needed for exclusion checks below)
strategy_content = read_strategy_file('TEST_STRATEGY.md')

# Compute config violation flags for tier gating
pit_excluded_classes = pit_config.get('excludedClasses', [])
pit_excluded_methods = pit_config.get('excludedMethods', [])
pit_avoid_calls_to = pit_config.get('avoidCallsTo', [])
pit_incremental = pit_config.get('enableDefaultIncrementalAnalysis', None)

# Standard avoidCallsTo entries that are legitimate for Gradle/Kotlin projects
# These suppress mutations on framework calls that produce nonsense mutants
STANDARD_AVOID_CALLS_TO = {
    'kotlin.jvm.internal.Intrinsics',
    'org.gradle.api.Project',
    'org.gradle.api.invocation.Gradle',
    'org.gradle.api.plugins.PluginManager',
    'org.gradle.api.provider.Property',
    'org.gradle.api.provider.Provider',
    'org.gradle.api.provider.ListProperty',
    'org.gradle.api.file.ConfigurableFileCollection',
    'org.gradle.api.file.DirectoryProperty',
    'org.gradle.api.file.RegularFileProperty',
    'org.gradle.api.tasks.TaskProvider',
    'org.gradle.api.tasks.TaskCollection',
    'org.gradle.api.logging.Logger',
    'org.gradle.api.execution.TaskExecutionGraph',
    'org.gradle.api.tasks.Exec',
    'org.gradle.testing.jacoco.tasks.JacocoReport',
    'javax.xml.parsers.DocumentBuilderFactory',
}

# Flag avoidCallsTo entries that are NOT standard (potential gaming)
undocumented_avoid_calls = [
    entry for entry in pit_avoid_calls_to
    if entry not in STANDARD_AVOID_CALLS_TO and entry not in strategy_content
]

undocumented_excluded_classes = [c for c in pit_excluded_classes if c not in strategy_content] if pit_excluded_classes else []
undocumented_excluded_methods = [m for m in pit_excluded_methods if m not in strategy_content] if pit_excluded_methods else []
has_undocumented_exclusions = bool(undocumented_excluded_classes or undocumented_excluded_methods or undocumented_avoid_calls)
has_incremental_risk = pit_incremental is True

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

# ============ Parse JUnit (with per-test timing) ============
def parse_junit_dir(junit_dir):
    """Parse JUnit XML dir, returning aggregate and per-test timing data."""
    total_count = 0
    total_time_seconds = 0.0
    test_times_ms = []          # individual test times in ms
    test_classes = defaultdict(list)  # classname -> [(test_name, time_ms)]
    test_names = set()          # all test method names
    if not junit_dir or not os.path.isdir(junit_dir):
        return total_count, total_time_seconds, test_times_ms, test_classes, test_names
    for xml_file in glob.glob(os.path.join(junit_dir, '*.xml')):
        try:
            suite = ET.parse(xml_file).getroot()
            total_count += int(suite.get('tests', 0))
            total_time_seconds += float(suite.get('time', 0))
            for tc in suite.findall('.//testcase'):
                tc_name = tc.get('name', '')
                # Normalize: strip trailing () to match PIT's method name format
                if tc_name.endswith('()'):
                    tc_name = tc_name[:-2]
                tc_class = tc.get('classname', '')
                tc_time_s = float(tc.get('time', '0'))
                tc_time_ms = tc_time_s * 1000
                test_times_ms.append(tc_time_ms)
                test_classes[tc_class].append((tc_name, tc_time_ms))
                if tc_name:
                    test_names.add(tc_name)
        except:
            pass
    return total_count, total_time_seconds, test_times_ms, test_classes, test_names

test_count, test_time_seconds, test_times_ms, junit_test_classes, junit_test_names = parse_junit_dir(junit_dir)

integration_test_count, integration_test_time_seconds, integ_times_ms, _, _ = parse_junit_dir(integration_junit_dir)

# ============ Compute speed metrics (anti-gaming) ============
# MEAN is gameable: add trivial assertTrue(true) tests at 0ms to dilute it.
# MEDIAN is robust: adding 100 trivial tests at 0ms barely shifts the median.
# P95 captures the slowest tests regardless of how many trivial tests are added.

def percentile(sorted_vals, pct):
    """Compute the pct-th percentile of a sorted list."""
    if not sorted_vals:
        return None
    k = (len(sorted_vals) - 1) * pct / 100
    f = int(k)
    c = min(f + 1, len(sorted_vals) - 1)
    if f == c:
        return sorted_vals[f]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)

avg_test_ms = (test_time_seconds * 1000 / test_count) if test_count > 0 else None

sorted_times = sorted(test_times_ms)
median_test_ms = percentile(sorted_times, 50) if sorted_times else None
p95_test_ms = percentile(sorted_times, 95) if sorted_times else None
p99_test_ms = percentile(sorted_times, 99) if sorted_times else None

integration_avg_test_ms = (integration_test_time_seconds * 1000 / integration_test_count) if integration_test_count > 0 else None

# ============ Anti-Gaming: JUnit ↔ PIT cross-reference (Measure A) ============
# If JUnit reports 200 tests but PIT only ran against 127, the extra 73 might
# be trivial tests that don't exercise any mutations. We cross-reference test
# counts to detect this. Also detects fake JUnit XML files with invented tests.
pit_test_count = len(pit_test_names)
junit_test_names_count = len(junit_test_names)
count_discrepancy_pct = 0
if pit_test_count > 0 and junit_test_names_count > 0:
    count_discrepancy_pct = abs(junit_test_names_count - pit_test_count) * 100 / max(pit_test_count, junit_test_names_count)

# ============ Anti-Gaming: Zero-mutation-kill diagnostic (Measure B) ============
# Tests that never kill any mutation are suspicious — they may be trivial
# assertTrue(true) tests added to dilute the speed metric.
# test_methods has entries only for tests that kill at least one mutation.
killing_test_names = set(test_methods.keys())
zero_kill_tests = junit_test_names - killing_test_names  # JUnit tests that never kill
zero_kill_by_class = defaultdict(int)
for cls_name, tests in junit_test_classes.items():
    for tc_name, _ in tests:
        if tc_name in zero_kill_tests:
            zero_kill_by_class[cls_name] += 1

# ============ Test isolation + strategy ============
test_isolation = strategy_file_exists('TEST_ISOLATION.md') or strategy_file_exists('TEST_STRATEGY.md')
has_strategy = strategy_file_exists('TEST_STRATEGY.md')

# ============ PIT config: targetClasses / excludedClasses verification ============
# Compare JaCoCo classes (production code with branches) against PIT mutated
# classes. If a class has JaCoCo branches but NO PIT mutations, it was either:
#   - Excluded via excludedClasses
#   - Not matched by targetClasses (narrowed pattern)
#   - Genuinely has no mutatable bytecode (rare)
# At Gold+, undocumented gaps are a gate failure.

_all_jacoco_classes = [n for pkg in jacoco_root.findall('package') for cls in pkg.findall('class') for n in [cls.get('name','')] if n]
no_mutation_classes = []
for c in _all_jacoco_classes:
    c_dotted = c.replace('/', '.')
    found_in_pit = any(c_dotted.startswith(pc) or pc.startswith(c_dotted) for pc in pit_classes)
    if not found_in_pit:
        branch_counters = jacoco_root.findall(f'.//class[@name="{c}"]/counter[@type="BRANCH"]')
        has_branches = any(int(cnt.get('covered', 0)) + int(cnt.get('missed', 0)) > 0 for cnt in branch_counters)
        if has_branches:
            no_mutation_classes.append(c.split('/')[-1])

# Check TEST_STRATEGY.md for documented exclusions
# (strategy_content already read early above — re-read in case it changed,
# but this is the same file so just ensure it's populated)
if not strategy_content:
    strategy_content = read_strategy_file('TEST_STRATEGY.md')

undocumented_excluded = [cls for cls in no_mutation_classes if cls not in strategy_content]

# ============ Exclusion ratio ============
# With unified XML, classes from BOTH Kover (JVM) and JaCoCo (instrumented)
# appear in <class> elements. Classes covered by NEITHER are correctly flagged.
included_classes = set()
for pkg in jacoco_root.findall('package'):
    for cls in pkg.findall('class'):
        name = cls.get('name', '')
        if name: included_classes.add(name)

# Class directories for JVM, Gradle plugin, Android, and KMP projects.
# When --project-dir is provided, paths are resolved relative to it.
class_dirs = ['gradle-tools/build/classes/kotlin/main',
              'build/classes/kotlin/main', 'build/classes/java/main',
              'build/classes/kotlin/jvm/main', 'build/classes/kotlin/desktop/main',
              # KMP Android outputs
              'build/tmp/kotlin-classes/debug',
              'build/intermediates/javac/debug/classes',
              'build/intermediates/runtime_library_classes_jar/debug/bundleLibRuntimeToJarDebug']
# Resolve relative to project_dir when provided
if project_dir:
    class_dirs = [os.path.join(project_dir, d) if not os.path.isabs(d) else d for d in class_dirs]
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
    # Process ALL class dirs, not just the first

included_instr = instruction_covered + instruction_missed
total_instr = included_instr + excluded_instr_count
exclusion_ratio_pct = excluded_instr_count * 100 / total_instr if total_instr > 0 else 0

# ============ Sliding exclusion threshold (v4.2) ============
# Fixed percentage thresholds are gameable for large repos: 1% of 100,000
# instructions = 1,000 instructions that can be hidden (several full classes).
# The sliding scale uses min(percentage-based, absolute-cap) to bound the
# maximum hideable instructions regardless of repo size.
#
# Formula:
#   max_allowed = min(N * pct/100, cap)
#
# where N = total_instr (included + excluded), pct = tier percentage, 
# cap = tier absolute instruction cap.
#
# Transition point: N_t = cap * 100 / pct. Below N_t, percentage governs.
# Above N_t, cap governs (percentage becomes irrelevant).
#
# Proof of non-gameability (Assumption 1 resolved):
#   Since min(a, b) <= b, max_allowed <= cap for ALL N.
#   A developer can hide at most `cap` instructions regardless of repo size.
#   A meaningful business-logic class has >=100 instructions.
#   Gold (cap=100) prevents hiding even one full class.
#   Perfection (cap=0) prevents hiding anything. QED.
#
# Proof of monotonicity (Assumption 3):
#   For N <= N_t: effective_pct = pct (constant)
#   For N > N_t:  effective_pct = cap/N * 100 (monotonically decreasing)
#   At N_t:      both cases give effective_pct = pct (continuous)
#   Therefore effective_pct is monotonically non-increasing in N. QED.
#
# Proof of achievability for small repos (Assumption 4):
#   For N <= N_t: max_allowed = N * pct / 100 (proportional to N).
#   A repo with 0 excluded always passes (0 <= any non-negative threshold).
#   Even a 100-instruction repo gets 5 instructions of tolerance at Bronze.
#   QED.

def compute_max_excluded(total_instr, pct, cap):
    """Compute the maximum allowed excluded instructions for a tier.

    Uses min(percentage-based, absolute-cap) to prevent gaming on large repos.
    At Perfection, both pct and cap are 0 (zero tolerance).

    Args:
        total_instr: Total instructions (included + excluded).
        pct: Tier percentage threshold (e.g., 5.0 for Bronze).
        cap: Tier absolute instruction cap (e.g., 200 for Bronze).

    Returns:
        Maximum allowed excluded instruction count (float).
    """
    if total_instr <= 0:
        return 0
    pct_based = total_instr * pct / 100.0
    return min(pct_based, cap)


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

def is_primary_method_call(method_name, body_text, allow_property_matching=False):
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

    # Strip comments to prevent false positives from method names in comments
    clean_body = re.sub(r'//.*$', '', body_text, flags=re.MULTILINE)
    clean_body = re.sub(r'/\*.*?\*/', '', clean_body, flags=re.DOTALL)

    # Find all occurrences of the method name as a call
    # Pattern 1: .methodName( — check receiver
    for match in re.finditer(r'(\w+)\s*\.\s*' + re.escape(method_name) + r'\s*\(', clean_body):
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
    if re.search(r'(?<![.\w])' + re.escape(method_name) + r'\s*\(', clean_body):
        return True

    # Pattern 3: Kotlin property access — ONLY for R_direct, not M_p
    # Property matching is too imprecise for M_p (false positives from variable names)
    if not allow_property_matching:
        return False

    kotlin_props = _kotlin_property_names(method_name)
    for prop_name in kotlin_props:
        if prop_name in FRAMEWORK_METHODS:
            continue
        # Match .propName NOT followed by '(' (so we don't double-match method calls).
        # The negative lookahead ensures this is property access, not a function call.
        # We check the receiver the same way as method calls to exclude Gradle/framework receivers.
        for match in re.finditer(r'(\w+)\s*\.\s*' + re.escape(prop_name) + r'\s*(?!\w|\s*\()', clean_body):
            receiver = match.group(1)
            if GRADLE_RECEIVERS.search(receiver + '.'):
                continue  # Skip Gradle API property accesses
            if receiver in ('project', 'extensions', 'tasks', 'pluginManager',
                           'rootProject', 'gradle', 'buildDir', 'layout', 'reports',
                           'dependencies', 'configurations', 'repositories',
                           'sourceSets', 'plugins', 'group', 'version', 'properties',
                           'logger', 'objects', 'providers', 'this', 'super', 'it',
                           'ext', 'test', 'result'):
                continue  # Skip framework receiver property accesses
            # This is a property access on a non-framework object — counts as direct
            return True

    return False


def _kotlin_property_names(method_name):
    """Derive Kotlin property name(s) from a JVM getter/setter method name.

    Kotlin follows JavaBeans conventions for property access:
      getFoo()  → property "foo"
      isFoo()   → property "isFoo" (Kotlin keeps the "is" prefix for Boolean)
                   also returns "foo" as a fallback
      setFoo()  → property "foo"
      hasFoo()  → not a standard Kotlin property pattern

    Returns a list of candidate property names (may be empty for non-getter methods).
    """
    candidates = []
    # getFoo → foo  (must be followed by uppercase letter)
    if re.match(r'get[A-Z]', method_name):
        prop = method_name[3:]            # strip "get"
        prop = prop[0].lower() + prop[1:] # lowercase first char
        candidates.append(prop)
    # isFoo → isFoo (kept as-is), also try foo as fallback
    elif re.match(r'is[A-Z]', method_name):
        candidates.append(method_name)     # "isFoo" — Kotlin keeps the prefix
        prop = method_name[2:]             # strip "is"
        prop = prop[0].lower() + prop[1:]  # "foo" — fallback
        candidates.append(prop)
    # setFoo → foo
    elif re.match(r'set[A-Z]', method_name):
        prop = method_name[3:]             # strip "set"
        prop = prop[0].lower() + prop[1:]  # lowercase first char
        candidates.append(prop)
    return candidates

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
    main_src_dirs = ['src/main/kotlin', 'gradle-tools/src/main/kotlin',
                     'src/commonMain/kotlin', 'src/jvmMain/kotlin']
    for msd in main_src_dirs:
        full_msd = os.path.join(strategy_base_dir, msd) if not os.path.isabs(msd) else msd
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
    # test_method_calls: method-call syntax ONLY (e.g., obj.getBranchTotal())
    #   — used for M_p (must avoid false positives from property syntax)
    # test_all_calls: method-call OR property-access syntax (e.g., obj.branchTotal)
    #   — used for R_direct (detects Kotlin property-style access to getter/setter methods)
    test_method_calls = defaultdict(set)  # test_name -> production methods called via method-call syntax (for M_p)
    test_all_calls = defaultdict(set)     # test_name -> production methods called via any syntax (for R_direct)

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
                                    is_call = is_primary_method_call(pm, body_text)
                                    if is_call:
                                        test_method_calls[current_test].add(pm)
                                        test_all_calls[current_test].add(pm)
                                    elif is_primary_method_call(pm, body_text, allow_property_matching=True):
                                        test_all_calls[current_test].add(pm)
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
                            is_call = is_primary_method_call(pm, body_text)
                            if is_call:
                                test_method_calls[current_test].add(pm)
                                test_all_calls[current_test].add(pm)
                            elif is_primary_method_call(pm, body_text, allow_property_matching=True):
                                test_all_calls[current_test].add(pm)
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
    # A test "directly calls" a method if the method name (or its Kotlin
    # property equivalent) is in the test's call set.
    #
    # We use test_all_calls (method-call + property-access) rather than
    # test_method_calls (method-call only) because Kotlin property syntax
    # (obj.branchTotal) is semantically a direct call to getBranchTotal().
    # Using test_all_calls here does NOT affect M_p, which uses the stricter
    # test_method_calls set.
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
            # Check if this test directly calls the mutated method (method-call
            # or property-access syntax). test_all_calls contains the method
            # name if EITHER syntax form was found in the test source.
            if mutated_method in test_all_calls.get(test_name, set()):
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
print("ANVIL TESTING SYSTEM — Tier Report")
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
# Anti-gaming speed metrics — show median (gate) + mean (info) + percentiles
if median_test_ms is not None:
    print(f"  Speed (median):   {median_test_ms:.1f}ms/test [GATE]")
    print(f"  Speed (mean):     {avg_test_ms:.1f}ms/test [info]")
    print(f"  Speed (P95):      {p95_test_ms:.1f}ms/test [info]")
    print(f"  Speed (P99):      {p99_test_ms:.1f}ms/test [info]")
    print(f"  Total wall-clock: {test_time_seconds:.1f}s [GATE]")
else:
    print(f"  Unit test speed:  N/A")
if integration_avg_test_ms is not None:
    print(f"  Integ test speed: {integration_avg_test_ms:.1f}ms/test")

# Anti-gaming: JUnit ↔ PIT cross-reference (Measure A)
print(f"\n  --- Anti-Gaming Checks ---")
if pit_test_count > 0:
    print(f"  JUnit tests:      {junit_test_names_count} unique test methods")
    print(f"  PIT tests:        {pit_test_count} unique test methods")
    if count_discrepancy_pct > 20:
        print(f"  ⚠ WARNING: {count_discrepancy_pct:.0f}% discrepancy between JUnit and PIT test counts")
        print(f"    Possible trivial tests or fake JUnit XML. Investigate.")
    else:
        print(f"  Count match:      {count_discrepancy_pct:.0f}% discrepancy (OK)")
else:
    print(f"  PIT test count:   unavailable (no fullMutationMatrix?)")

# Anti-gaming: zero-mutation-kill diagnostic (Measure B)
if zero_kill_tests:
    zero_pct = len(zero_kill_tests) * 100 / len(junit_test_names) if junit_test_names else 0
    zero_classes = sum(1 for v in zero_kill_by_class.values() if v > 0)
    print(f"  Zero-kill tests:  {len(zero_kill_tests)}/{len(junit_test_names)} ({zero_pct:.0f}%) kill no mutations")
    if zero_classes > 0:
        print(f"  Zero-kill classes:{zero_classes} class(es) with non-killing tests")
    # Show top offenders (classes with most zero-kill tests)
    sorted_zero = sorted(zero_kill_by_class.items(), key=lambda x: -x[1])[:5]
    for cls, cnt in sorted_zero:
        if cnt > 0:
            short_cls = cls.rsplit('.', 1)[-1] if '.' in cls else cls
            total_in_cls = len(junit_test_classes.get(cls, []))
            print(f"    ! {short_cls}: {cnt}/{total_in_cls} tests kill nothing")

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
print(f"  Exclusion:        {excluded_instr_count}/{total_instr} instr ({exclusion_ratio_pct:.1f}%) [sliding scale]")
if pit_config:
    print(f"\n  --- PIT Config ({pit_config_source}) ---")
    print(f"  Full mutation matrix:   {'true' if pit_config.get('fullMutationMatrix') else 'FALSE'} {'✅' if pit_config.get('fullMutationMatrix') else '❌'}")
    print(f"  Incremental analysis:   {pit_config.get('enableDefaultIncrementalAnalysis', '?')} {'✅' if not pit_config.get('enableDefaultIncrementalAnalysis') else '❌'}")
    cfg_muts = pit_config.get('mutators', [])
    print(f"  Mutators:               {', '.join(cfg_muts)} {'✅' if any('STRONGER' in m or 'ALL' in m for m in cfg_muts) else '❌'}")
    excl_cls = pit_config.get('excludedClasses', [])
    print(f"  Excluded classes:       {len(excl_cls)} {'✅' if not excl_cls else '❌'}")
    excl_mth = pit_config.get('excludedMethods', [])
    print(f"  Excluded methods:       {len(excl_mth)} {'✅' if not excl_mth else '❌'}")
    avoid_calls = pit_config.get('avoidCallsTo', [])
    undocumented_avoid = [a for a in avoid_calls if a not in STANDARD_AVOID_CALLS_TO and a not in strategy_content]
    print(f"  avoidCallsTo:           {len(avoid_calls)} entries ({len(undocumented_avoid)} undocumented) {'✅' if not undocumented_avoid else '❌'}")
    if undocumented_avoid:
        print(f"    ! Non-standard avoidCallsTo entries:")
        for a in undocumented_avoid[:5]:
            print(f"      {a}")
    print(f"  Config source:          {pit_config_source}")
if no_mutation_classes:
    print(f"\n  WARNING: {len(no_mutation_classes)} classes have JaCoCo branches but NO PIT mutations")
    for cls in sorted(no_mutation_classes)[:10]:
        doc_status = "[undocumented]" if cls not in strategy_content else "[documented]"
        print(f"    ! {cls} {doc_status}")
print()

# ============ Tier Definitions (v4.2) ============
# M_t REMOVED as a gate — it measures call-graph structure, not test quality.
# R replaced by R_direct when source analysis is available.
# When source analysis is NOT available, R is used with lenient fallback thresholds
# that accommodate structural transitive kill inflation.
#
# Exclusion scale (v4.2): sliding threshold using min(pct, cap).
#   max_allowed = min(N * pct/100, cap)
#   This prevents gaming on large repos where a fixed percentage allows hiding
#   many full classes. The absolute cap bounds hideable instructions regardless
#   of repo size. See compute_max_excluded() for the mathematical proof.
#   Perfection uses zero tolerance (pct=0, cap=0) — zero hidden code, period.
#
# Threshold rationale:
#   M_p: Gradle plugin tests may need 2-3 primary method calls for integration
#        verification. Pure-function tests need 1. Thresholds accommodate both.
#   R_direct: Structural minimum is 1-2 for most codebases (1 direct test per
#             method). Allows up to 3 for methods tested by multiple focused tests.
#   R (fallback): Structural minimum is 3-5 for orchestrator-heavy codebases
#                 (1 direct + 2-4 transitive killers). Thresholds accommodate this.
#   Exclusion: Caps chosen so that at most 1 small framework boilerplate class
#              (~100 instructions) can be hidden at Gold, ~0.5 class at Platinum,
#              and zero at Perfection. A meaningful business-logic class has
#              >=100 instructions, so the caps prevent hiding real code.

# Determine which R metric to use
use_r_direct = max_r_direct is not None

if use_r_direct:
    tiers = [
        ("Bronze", {
            "instruction": 60, "branch": 50, "mutation": 50,
            "mp": 5, "r_direct": 10,
            "exclusion_pct": 5.0, "exclusion_cap": 200, "median_speed": 200, "total_wall_seconds": 120,
        }),
        ("Silver", {
            "instruction": 80, "branch": 70, "mutation": 70,
            "mp": 4, "r_direct": 6,
            "exclusion_pct": 5.0, "exclusion_cap": 150, "median_speed": 100, "total_wall_seconds": 60,
        }),
        ("Gold", {
            "instruction": 90, "branch": 85, "mutation": 85,
            "mp": 3, "r_direct": 4,
            "test_isolation": True, "has_strategy": True,
            "exclusion_pct": 3.0, "exclusion_cap": 100, "median_speed": 50, "total_wall_seconds": 30,
            "requires_full_pit": True,
            "requires_stronger_mutators": True,
            "no_hidden_exclusions": True,
            "requires_full_matrix": True,
            "no_undocumented_exclusions": True,
            "no_incremental_analysis": True,
        }),
        ("Platinum", {
            "instruction": 95, "branch": 90, "mutation": 95,
            "mp": 2, "r_direct": 3,
            "test_isolation": True, "has_strategy": True,
            "exclusion_pct": 2.0, "exclusion_cap": 50, "median_speed": 30, "total_wall_seconds": 15,
            "requires_full_pit": True,
            "requires_stronger_mutators": True,
            "no_hidden_exclusions": True,
            "requires_full_matrix": True,
            "no_undocumented_exclusions": True,
            "no_incremental_analysis": True,
        }),
        ("Perfection", {
            "instruction": 100, "branch": 100, "mutation": 100,
            "mp": 2, "r_direct": 3,
            "test_isolation": True, "has_strategy": True,
            "exclusion_pct": 0.0, "exclusion_cap": 0, "median_speed": 15, "total_wall_seconds": 10,
            "requires_full_pit": True,
            "requires_stronger_mutators": True,
            "no_hidden_exclusions": True,
            "requires_full_matrix": True,
            "no_undocumented_exclusions": True,
            "no_incremental_analysis": True,
        }),
    ]
else:
    # Fallback: R (all killers) with lenient thresholds that accommodate
    # structural transitive kill inflation for orchestrator-heavy codebases.
    tiers = [
        ("Bronze", {
            "instruction": 60, "branch": 50, "mutation": 50,
            "r": 20,
            "exclusion_pct": 5.0, "exclusion_cap": 200, "median_speed": 200, "total_wall_seconds": 120,
        }),
        ("Silver", {
            "instruction": 80, "branch": 70, "mutation": 70,
            "r": 12,
            "exclusion_pct": 5.0, "exclusion_cap": 150, "median_speed": 100, "total_wall_seconds": 60,
        }),
        ("Gold", {
            "instruction": 90, "branch": 85, "mutation": 85,
            "r": 8,
            "test_isolation": True, "has_strategy": True,
            "exclusion_pct": 3.0, "exclusion_cap": 100, "median_speed": 50, "total_wall_seconds": 30,
            "requires_full_pit": True,
            "requires_stronger_mutators": True,
            "no_hidden_exclusions": True,
            "requires_full_matrix": True,
            "no_undocumented_exclusions": True,
            "no_incremental_analysis": True,
        }),
        ("Platinum", {
            "instruction": 95, "branch": 90, "mutation": 95,
            "r": 6,
            "test_isolation": True, "has_strategy": True,
            "exclusion_pct": 2.0, "exclusion_cap": 50, "median_speed": 30, "total_wall_seconds": 15,
            "requires_full_pit": True,
            "requires_stronger_mutators": True,
            "no_hidden_exclusions": True,
            "requires_full_matrix": True,
            "no_undocumented_exclusions": True,
            "no_incremental_analysis": True,
        }),
        ("Perfection", {
            "instruction": 100, "branch": 100, "mutation": 100,
            "r": 5,
            "test_isolation": True, "has_strategy": True,
            "exclusion_pct": 0.0, "exclusion_cap": 0, "median_speed": 15, "total_wall_seconds": 10,
            "requires_full_pit": True,
            "requires_stronger_mutators": True,
            "no_hidden_exclusions": True,
            "requires_full_matrix": True,
            "no_undocumented_exclusions": True,
            "no_incremental_analysis": True,
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

    # PIT incremental analysis gate (Gold+) — uses pit-config.json value
    # PIT 1.15 always writes partial="true" to XML, so we use the config JSON instead
    if "requires_full_pit" in reqs and has_incremental_risk:
        met = False; failures.append("enableDefaultIncrementalAnalysis is true — stale PIT cache risk")

    # PIT config verification gates (Gold+)
    if "requires_stronger_mutators" in reqs and not has_stronger_mutators and pit_mutators:
        met = False; failures.append("STRONGER mutators not enabled — only DEFAULTS detected (mutation score inflated)")

    if "no_hidden_exclusions" in reqs and undocumented_excluded:
        met = False; failures.append(f"{len(undocumented_excluded)} classes with branches but no PIT mutations (undocumented in TEST_STRATEGY.md)")

    if "requires_full_matrix" in reqs and not has_full_matrix:
        met = False; failures.append("fullMutationMatrix disabled — only singular killingTest found")

    # PIT config JSON gates (Gold+) — only when pit-config.json available
    if "no_undocumented_exclusions" in reqs and has_undocumented_exclusions:
        excl = undocumented_excluded_classes + undocumented_excluded_methods
        met = False; failures.append(f"PIT excludedClasses/excludedMethods has {len(excl)} undocumented entries: {', '.join(excl[:5])}")

    if "no_incremental_analysis" in reqs and has_incremental_risk:
        met = False; failures.append("enableDefaultIncrementalAnalysis is true — stale PIT cache risk")

    if "test_isolation" in reqs and not test_isolation:
        met = False; failures.append("test isolation not verified")

    if "has_strategy" in reqs and not has_strategy:
        met = False; failures.append("no TEST_STRATEGY.md")

    # Sliding exclusion scale (v4.2): max_allowed = min(N*pct/100, cap)
    if "exclusion_pct" in reqs:
        excl_pct = reqs["exclusion_pct"]
        excl_cap = reqs["exclusion_cap"]
        max_allowed_excl = compute_max_excluded(total_instr, excl_pct, excl_cap)
        if excluded_instr_count > max_allowed_excl:
            # Determine which limit is binding for the error message
            pct_limit = total_instr * excl_pct / 100.0 if total_instr > 0 else 0
            if excl_cap < pct_limit:
                limit_desc = f"cap of {excl_cap} instr"
            else:
                limit_desc = f"{excl_pct:.1f}%"
            met = False
            failures.append(
                f"exclusion {excluded_instr_count} instr ({exclusion_ratio_pct:.1f}%) > "
                f"allowed {max_allowed_excl:.0f} instr ({limit_desc})"
            )

    # Anti-gaming: use MEDIAN test speed (robust against trivial-test dilution)
    if "median_speed" in reqs and median_test_ms is not None:
        if median_test_ms > reqs["median_speed"]:
            met = False; failures.append(f"median test speed {median_test_ms:.1f}ms > {reqs['median_speed']}ms")

    # Anti-gaming: total wall-clock gate (not gameable by adding trivial tests)
    if "total_wall_seconds" in reqs:
        # Sliding wall-clock: scales with instruction count to be fair for large repos
        # Formula: max_wall = max(base, N * rate) where N = total instructions
        # base = the tier's total_wall_seconds (minimum for tiny repos)
        # rate = per-instruction time budget (scales for large repos)
        wall_base = reqs["total_wall_seconds"]
        wall_rate = reqs.get("wall_per_instr", 0.001)  # 1ms per instruction default
        max_wall = max(wall_base, instruction_total * wall_rate)
        if test_time_seconds > max_wall:
            met = False; failures.append(f"total wall-clock {test_time_seconds:.1f}s > {max_wall:.1f}s (sliding: base={wall_base}s, rate={wall_rate}s/instr, N={instruction_total})")

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
