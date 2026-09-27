# Stored-record read performance

Base `0022aee170e9647ffd207039666c99d115c36b34`. Debug package tests on macOS 26.7 arm64 with Apple Swift 6.3.3. Disk-backed SwiftData contains 200 pending jobs, 200 settlements, and 5,000 legacy-cause provenance rows. Two hundred provenance keys consume the pending jobs. The unsettled fixture gives the settlement rows unrelated job IDs, so coverage must come from provenance.

Fixture seeding and ledger recovery happen before timing. The budget test calls the app's recurring `Ledger.flushJobs(in:)` entry point and asserts the exact job count, IDs, and settled state. No schema or query changes were made.

## Matched isolated profiles

Both profiles use `caffeinate -i pnpm test:swift --disable-sandbox --filter RecordReadPerformanceTests --attachments-path <existing-directory>`.

| Measurement | Before ms | After ms |
| --- | ---: | ---: |
| local-read | 82.058 | 26.711 |
| settled-read | 82.640 | 29.266 |
| provenance-read | 936.556 | 261.289 |
| unsettled-read | 1401.551 | 306.115 |
| local-fetch | 12.959 | 13.056 |
| local-decode | 65.082 | 9.421 |
| local-civil-date | 52.180 | 1.100 |
| local-sort | 2.284 | 2.430 |
| provenance-fetch | 147.356 | 148.748 |
| provenance-decode | 818.920 | 96.921 |
| provenance-civil-date | 668.054 | 13.575 |
| provenance-sort | 3.851 | 3.651 |

Component measurements are separate passes. CivilDate cost is included in decode and must not be added to it. Decode includes first access to persisted fields. Component fetch measures context creation and an unfiltered fetch in a store containing only the measured row class. End-to-end reads use production predicates. Separate reads and the complete unsettled operation do not form an additive breakdown.

The formatter was the dominant measured decode cost. SwiftData fetch and sorting remain similar after the change. The existing scalar columns cannot distinguish the 200 consumed provenance markers from the other 4,800 legacy rows. Narrowing that read while preserving coverage requires a separately approved migration or contract change. The unsettled operation remains above 50 ms.

## Three complete debug suites

Each run uses `caffeinate -i pnpm test:swift --disable-sandbox --attachments-path <existing-directory>`.

| Run | 400-row budget ms | Provenance read ms | Unsettled read ms | Full suite |
| --- | ---: | ---: | ---: | --- |
| 1 | 28.851 | 259.844 | 295.920 | 431 passed |
| 2 | 37.774 | 260.895 | 296.886 | 431 passed |
| 3 | 33.104 | 257.920 | 312.003 | 431 passed |

The budget is 50 ms. Full-suite timings include concurrent tests. The isolated profile above matches the baseline measurement conditions.

## Date compatibility

The DateFormatter oracle agrees with the validator and failable CivilDate initializer for 79,596 modern candidates. These cover all 73,414 valid dates from 1900-01-01 through 2100-12-31 and 6,182 invalid day/month combinations. Another 6,468 historical and boundary candidates cover year zero, the 1582 cutover, 1500-02-29, Gregorian century boundaries, and year 9999. Forty noncanonical or malformed strings cover variable field widths, alternate separators, surrounding spaces, Unicode digits, trailing content, and invalid fields. Explicit February 29 checks cover 1900, 1996, 2000, 2004, 2096, and 2100.

The fast path claims canonical ASCII keys only, from year 1583 onward. All other strings use the unchanged per-call formatter. Whether keys should become strict is an open operator question for a separate change.

## Mutation evidence

Every patch ran against the complete 431-test suite, exited 1 because of assertions, and was restored with `git apply -R`. The restored source hash matched after every mutation.

| Patch | Defect | Killing test |
| --- | --- | --- |
| `01-wrong-leap-year.patch` | Treat every fourth year as leap | Leap-year cases and both oracle tests |
| `02-thirty-day-month.patch` | Accept day 31 in 30-day months | Both oracle tests |
| `03-claims-noncanonical.patch` | Let the fast path claim arbitrary separators | Historical and malformed oracle |
| `04-formatter-per-call.patch` | Construct and parse with a formatter on the fast path | Budget test measured 135.961 ms |
| `05-historical-calendar.patch` | Apply Gregorian arithmetic before the cutover | Historical and malformed oracle |

## Gates and limits

- Catalog generation and equality passed.
- Source checks passed.
- SwiftLint passed with `--no-cache`.
- Swift formatting passed.
- Lint baseline passed with `LINT_BASELINE_BASE=origin/milestone/m1`.
- All 431 tests passed in each of three full suites.
- The existing frozen-lockfile installation was reused.
- No simulator or simulator xcodebuild was run, as instructed.
- The existing untracked `.pnpm-store/` was not staged.

The first targeted invocation stopped because its attachment directory did not exist. Creating that directory and rerunning passed all six selected tests. Whole-diff whitespace checks report unified-diff context prefixes inside the mutation patch files; the Swift files pass. All required gates passed without exclusions or baseline changes.

The local evidence directory is `m1-10c` under the Enduragent M1 logs. It contains `before.md`, `after.md`, `provenance-options.md`, `mutants.tsv`, `gates.tsv`, and raw logs and attachments for every run.
