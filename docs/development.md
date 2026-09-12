# Building and testing now

[Back to the README](../README.md)

Requires Xcode Command Line Tools with a macOS 15 or later SDK (the build uses the active SDK
reported by `xcrun`; override with `SDK_PATH` if needed).

```bash
./build-app.sh
```

Builds optimized `outputs/now.app` and `outputs/now.zip` using SwiftPM, in Swift 5 mode for macOS
13+, arm64. `--debug` builds an unoptimized development bundle and ZIP under `outputs/debug/`.
`--release` is the default. Incremental compilation artifacts are retained; `--clean` explicitly
clears SwiftPM build artifacts. Use `--require-identity` to require the stable signing identity.
Bundling, resources, entitlements, and signature verification remain in the wrapper.

## Development tools

### Markdown formatting

Install the pinned Prettier version with Node.js/npm, then format and check project Markdown:

```bash
npm ci
npm run format-docs
npm run check-docs
```

Formatting wraps prose at 100 columns and leaves code examples unchanged. Installed third-party
skills in `.agents/skills/`, build outputs, and local-only docs are excluded. Node.js is only
required for these documentation commands; the Swift build remains independent.

### Code analysis

Install the pinned SwiftLint binary locally, then check for new findings:

```bash
./scripts/setup-analysis.sh
./scripts/analyze.sh
./scripts/analyze.sh --report # include the existing backlog for review
```

Setup downloads SwiftLint 0.65.1 from its official GitHub release and verifies the pinned SHA-256.
The ignored `.tools/` installation survives app builds. Analysis never downloads tools, signs an
app, requests permissions, or launches now. A missing/wrong tool version is an error. `SWIFTLINT`
can point to another installation of the same version. Command Line Tools SourceKit discovery is
handled by the script. Python 3 and the active Swift compiler are also required; npm is not.

The default command fails on compiler errors, new compiler warnings, new SwiftLint findings, or tool
failures. `--report` makes findings informational but still fails on compiler/tool errors. Reports
and compiler-version information go under `.build/analysis/`, which app builds retain. Run analysis
after building. Release preflight runs the default check, including with `--app`.

The compiler emits the shared `NowCore` module, then separately checks shipping sources, the
selftest configuration, the signed-updater runner and the core-only runner against it with
`-strict-concurrency=complete` in Swift 5 mode for arm64/macOS 13. All 13 original warnings have
been resolved; the concurrency baseline is empty. See the [finding review](../analysis/review.md)
for ownership changes and retained lint rationales. Matching uses file, diagnostic message,
source-line text and occurrence count, so line-number shifts alone do not cause failures.
Compiler/SDK upgrades or edits to a flagged line can require deliberate review. The current snapshot
is written to `.build/analysis/concurrency-current.json`; it never overwrites the committed
baseline.

SwiftLint checks complexity, function length, parameter count, nesting, force casts/tries, duplicate
conditions and identical operands. The separate `Tests` directory is outside production lint scope;
embedded test helpers in other files remain included. File/type length and formatting rules are
deliberately absent. The 16 retained findings are mostly parser branching and long functions, with
two seven-parameter helpers. For example, strict RRULE parsing has complexity 37: its rejection
branches protect correctness, so reducing that number alone is not a reason to rewrite it.

Baselines in `analysis/` record existing debt rather than declaring it safe. SwiftLint's native
baseline can keep suppressing a finding in an existing function even as it grows; use `--report`
when touching these hotspots. Review baseline diffs, prune resolved entries, and explain any new
exception. Never bulk-refresh a baseline or silence concurrency checking just to obtain a pass. Size
findings invite review, not automatic extraction into tiny functions. These checks complement the
behavioral regression suites; they do not verify reminder ownership, cache recovery or updater
safety. Duplication/dead-code tools are deferred until a concrete audit warrants them.

When changing the analysis tooling, run `python3 scripts/analysis-smoke.py`. It uses disposable
Swift sources to verify baseline matching, rejection of new warnings/lint findings, report mode, and
compiler/missing-tool failures. Probes cover both core and shell findings and inaccessible core
APIs. `--compiler-only` runs portable compiler/baseline probes without the macOS SDK or SwiftLint;
it does not replace the full analysis smoke.

### App diagnostics and checks

```bash
./scripts/test.sh        # parser unit tests
./outputs/now.app/Contents/MacOS/now --parse <url-or-file> # inspect any iCal feed
./outputs/now.app/Contents/MacOS/now --native [list]       # inspect Apple Calendar access
./outputs/now.app/Contents/MacOS/now --meeting            # inspect active meeting audio metadata
python3 scripts/calendar-cache-smoke.py             # isolated offline restart/cache checks
./scripts/preflight.sh                            # full build + release regression suites
./release.sh --dry-run                             # release prerequisites (no tests/publication)
```

See [AGENTS.md](../AGENTS.md) for development notes and the release workflow.

### Test target boundary

`./scripts/test.sh` builds the deterministic suite in a separate SwiftPM executable;
`NOW_TEST_CONFIGURATION=release ./scripts/test.sh` exercises optimized compilation. Command Line
Tools lack XCTest, so the manifest selects a named `NowHarness` executable from an allow-list via
`NOW_TEST_SUITE`. Each suite uses `.build/tests/<suite>`, with debug/release artifacts separated by
SwiftPM. The shipping default selects `NowApp` and its `NowCore` dependency. Every macOS harness
imports that same library instead of compiling a private core copy. Core access needed within the
package uses Swift 5.9 `package` visibility; no external public API is introduced. Suite
conditionals remain on the shell harness rather than propagating into the library.

Hosted harnesses share `scripts/harness.py` and compile production source with conditional
`NOW_TESTING` accessors. Native fetching asserts empty native selections and returns; notification
fixtures use a fake transport and skip archive staging. Cache fixtures install an offline
URLProtocol. Quit fixtures replace dialog responses and termination actions. These differences are
compile-time only. Synthetic feeds, caches and preference domains remain disposable.

The app retains `--parse`, `--native`, `--meeting`, and read-only `--update-check` diagnostics.
`--selftest` and `--update-smoke` exit with a migration message. Updater smoke validates the
supplied release signature, then builds a separately signed optimized updater runner under
`outputs/testing/release/now.app`. Headless reporting and fault injection are test-only; staging,
signature/version/OS checks, swap and rollback use the production implementation. Test builds cannot
replace release output. The helper script retains its explicit fault contract so tests exercise the
same script; production install calls pass no fault environment and strip inherited smoke variables.
Updater fault tests therefore exercise a test binary, not the byte-identical shipping binary.

`python3 scripts/artifact-smoke.py outputs/now.app` verifies shipping metadata, the exact signing
requirement and entitlements, arm64/macOS 13 load commands, fixture exclusion, and production parser
and update-check diagnostics. It launches production code for five seconds in a signed disposable
bundle with an empty profile. This checks startup liveness; it does not replace manual testing of
Calendar permission prompts, real Notification Center delivery or older macOS versions.

The pinned-ID updater fixture uses an explicit disposable preference suite and injected cache;
changing HOME alone does not isolate macOS preferences. Interactive menu/focus checks require an
unlocked, undisturbed desktop. Historical parser comparisons build complete archived revisions with
their own SwiftPM layouts. Use
`python3 scripts/parser-performance-smoke.py --compare-revision d01dbd7` for extraction equivalence;
`--compare-head` compares to the current committed revision. Both compare the full materialization
fixture digests, including identities and presentation fields.

### Shared core and Linux checks

`Sources/NowCore/ICS.swift` currently contains parsed values, envelope/date parsing, recurrence
expansion and meeting-link policy. `Sources/ICS.swift` retains macOS `NSDataDetector` discovery and
feed materialization into the app's palette-dependent models. The complete app and its reminder,
cache and persistence controllers have not been ported.

With a Swift 5.9-or-newer host toolchain and its system dependencies installed:

```bash
swift --version
./scripts/test-core.sh
NOW_TEST_CONFIGURATION=release ./scripts/test-core.sh
python3 scripts/analysis-smoke.py --compiler-only
```

The core script selects `NOW_TEST_SUITE=core` and builds `NowCoreTests` against `NowCore`, in Swift
5 mode with complete concurrency checking and warnings treated as errors. It bypasses the macOS
`xcrun`/arm64 wrapper, works without XCTest, and uses `.build/tests/core`. The synthetic fixtures
cover envelopes, folding/limits, durations, timezone mapping, raw recurrence anchors, DST
gap/overlap expansion, exact work budgets, and link policy with injected candidates. They do not
access live preferences, calendars, network or UI. Linux compiler and system-library versions must
be recorded with validation evidence; Linux success does not establish Windows support or macOS
GUI/signing health. Full macOS validation still runs on the signing Mac.
