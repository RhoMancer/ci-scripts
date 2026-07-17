# Testing Tier System

Finalized July 15, 2026. Adversarially reviewed and hardened through multiple rounds of subagent analysis.

## Prerequisites (not tiered)
- Tests exist
- Tests pass in CI
- PIT mutation testing configured

## Tier Requirements

| Metric | Bronze | Silver | Gold | Platinum | Diamond | Perfection |
|--------|--------|--------|------|----------|---------|------------|
| Instruction | >=50% | >=70% | >=85% | >=95% | >=98% | **100%** |
| Branch | >=40% | >=60% | >=75% | >=90% | >=95% | **100%** |
| Mutation | >=20% | >=35% | >=50% | >=80% | >=95% | **100%** |
| TES | >=0.10 | >=0.20 | >=0.30 | >=0.50 | >=0.70 | **1.00** |
| Test isolation | Optional | Optional | Yes | Yes | Yes | Yes |
| Documented strategy | Optional | Optional | Yes | Yes | Yes | Yes |
| Unit test speed | <200ms | <100ms | <50ms | <30ms | <15ms | **<10ms** |
| Instrumented test speed | <10s | <5s | <3s | <2s | <1s | **<0.5s** |
| Exclusion ratio | <5% | <5% | <3% | <2% | <2% | **<1%** |

## Key Definitions

- **Instruction coverage**: `instr_covered / (instr_covered + instr_missed) * 100` from JaCoCo XML `<counter type="INSTRUCTION">`. Measures % of bytecode instructions that executed during tests. JaCoCo counts every JVM bytecode op (ILOAD, IADD, IFGT, ARETURN, etc.).

- **Branch coverage**: `branch_covered / (branch_covered + branch_missed) * 100` from JaCoCo XML `<counter type="BRANCH">`. Measures % of control flow edges (if/when/switch paths) where BOTH directions were taken. 100% branch guarantees 100% instruction, but NOT vice versa.

- **Mutation score**: `killed_mutations / total_mutations * 100` from PIT XML. total_mutations = count of all `<mutation>` elements (deterministic: depends only on mutatable bytecode patterns in production code). killed_mutations = count of `<mutation status="KILLED">` (PIT broke the code, ran tests, at least one test failed).

- **TES (Test Efficiency Score)**: `1 - (zero_kill + subset_bloat) / total_tests`. Where:
  - `zero_kill` = tests with 0 mutations killed
  - `subset_bloat` = tests whose kills are a strict subset of another test's kills
  - TES = 1.0 means every test kills at least one unique mutation. Lower = more bloat.

- **Zero-Kill Ratio**: `(test_count - killing_test_count) / test_count * 100`. % of tests not reported as killing any mutation by PIT. PIT reports one killing test per mutation, so this is a lower bound on the true zero-kill count. Target = 0%. Prevents TES gaming via test variance.

- **Test isolation**: Tests pass when run 3+ times with randomized execution order. No shared mutable state, no order dependency.

- **Documented strategy**: TEST_STRATEGY.md committed to repo. Decision document describing what's tested, how, and why. Not a tutorial.

- **Unit test speed**: `test_time_ms / test_count`. Average wall-clock time per test. Excludes compile and PIT time.

- **Instrumented test speed**: Same formula for instrumented/emulator tests. N/A if project has none (not counted, not penalized).

- **Exclusion ratio**: `excluded_instr / (excluded_instr + instr_total) * 100`. % of production code excluded from coverage. Tracks gaming. High exclusions = gaming coverage. Handles equivalent mutants — if you exclude them, the ratio tracks how much.

## Tier Calculation
A repo's tier is the HIGHEST tier where ALL required metrics are met. If any metric for a tier is not met, the repo cannot be at that tier or any tier above it.

## Usage
Run `check-tier.sh` in CI to determine a repo's tier. The script reads JaCoCo and PIT XML reports and outputs the tier with per-metric breakdown.

## Metrics History (what was tried and rejected)
- Redundant test ratio: PIT reports one killing test per mutation, can't reliably identify redundant tests
- Test/code ratio (LOC): 2.2x swing from counting choices, Kotlin denominator compression
- Mutation kill density (kills/LOC): mega-test gameable
- Test efficiency (kills/tests alone): perverse incentive (adding good tests lowers score)
- CMG (coverage-mutation gap): redundant with mutation score at high coverage
- TCR (test-to-code ratio): counting instability, punishes test infrastructure
- KPKI (kills per kilo-instruction): proven to be mutation score in disguise (K/I ~ kill_rate/18)
- (K/M)^2 * (K/T): squaring mutation score was redundant with mutation score gate
- instr_covered / T: not size-invariant (large projects score higher)
- Mutation overlap: required unit/integration suite distinction that was dropped from tiers. Self-contradictory.
- Line/method/class coverage: implied by instruction + branch at 100%

## Dropped from tiers (per-project decision, not universal)
- Integration tests — not every project has integration boundaries worth testing
- Property-based tests — if they don't kill unique mutations, they don't add tier value
- Fuzzing — only relevant for code processing untrusted input (parsers, network-facing)
- Multi-version testing — bonus category outside tiers
