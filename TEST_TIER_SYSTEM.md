# Testing Tier System

Finalized July 14, 2026. Adversarially reviewed and hardened.

## Prerequisites (not tiered)
- Tests exist
- Tests pass in CI
- PIT mutation testing configured

## Tier Requirements

| Metric | Bronze | Silver | Gold | Platinum | Diamond | Perfection |
|--------|--------|--------|------|----------|---------|------------|
| Instruction | >=50% | >=70% | >=85% | >=95% | >=98% | **100%** |
| Branch | >=40% | >=60% | >=75% | >=90% | >=95% | **100%** |
| Mutation | — | — | >=50% | >=80% | >=95% | **100%** |
| Redundant test ratio | — | — | — | **<20%** | **<10%** | **0%** |
| Mutation kill density | — | — | — | **>0.05** | **>0.10** | **>0.15** |
| Test isolation | — | — | ✅ | ✅ | ✅ | ✅ |
| Documented strategy | — | — | — | ✅ | ✅ | ✅ |
| Unit test speed | — | — | <100ms/test | <50ms/test | <30ms/test | **<10ms/test** |
| Instrumented test speed | — | — | <5s/test | <3s/test | <2s/test | **<1s/test** |
| Exclusion ratio | <5% | <5% | <3% | <2% | <2% | **<1%** |

## Key Definitions

- **Instruction coverage**: JaCoCo bytecode instruction coverage. Most granular coverage metric.
- **Branch coverage**: JaCoCo branch (control flow edge) coverage. Independent from instruction — 100% instruction does NOT guarantee 100% branch.
- **Mutation score**: PIT mutation testing kill rate. Percentage of generated mutations that tests detect. Equivalent mutants handled via exclusion ratio.
- **Redundant test ratio**: % of tests that don't kill a single mutation that another test doesn't already kill. 0% = every test is unique. Lower is better. Measured by analyzing PIT's killingTest field per mutation.
- **Mutation kill density**: Total mutations killed / total test source lines. Higher is better. Rewards dense, focused tests that do more with less.
- **Test isolation**: Tests pass when run multiple times in random order. No shared mutable state, no order dependency.
- **Documented strategy**: TEST_STRATEGY.md committed to repo describing what's tested, how, and why. Decision document, not tutorial.
- **Unit test speed**: Average wall-clock time per unit test (total test time / test count). Excludes compile/build and PIT.
- **Instrumented test speed**: Average wall-clock time per instrumented/emulator test. N/A if project has none (not counted, not penalized).
- **Exclusion ratio**: % of code excluded from coverage/mutation reports. Lower is better. High exclusions = gaming coverage. Handles equivalent mutants — if you exclude them, the ratio tracks how much.
- **Tollgate**: CI-enforced (build fails if not met). Metrics without tollgates are report-only.

## Dropped from tiers (per-project decision, not universal)
- Integration tests — not every project has integration boundaries worth testing
- Property-based tests — if they don't kill unique mutations, they don't add tier value
- Fuzzing — only relevant for code processing untrusted input (parsers, network-facing)
- Multi-version testing — bonus category outside tiers
- Line/method/class coverage — implied by instruction + branch at 100%

## Dropped during adversarial review
- Mutation overlap — required unit/integration suite distinction that was dropped from tiers. Self-contradictory. Replaced with redundant test ratio.
- Test/code ratio — penalized thorough testing. More tests = better testing, but ratio punished it. Replaced with mutation kill density.

## Tier Calculation
A repo's tier is the HIGHEST tier where ALL required metrics are met. If any metric for a tier is not met, the repo cannot be at that tier or any tier above it.

## Usage
Run `check-tier.sh` in CI to determine a repo's tier. The script reads JaCoCo and PIT XML reports and outputs the tier with per-metric breakdown.
