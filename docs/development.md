# Building and testing now

[Back to the README](../README.md)

Requires Xcode Command Line Tools with a macOS 15 or later SDK (the build uses the active SDK
reported by `xcrun`; override with `SDK_PATH` if needed).

```bash
./build-app.sh
```

Builds `outputs/now.app` and `outputs/now.zip`. macOS 13+, arm64.

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
and compiler-version information go under `.build/analysis/`, which the next app build clears. Run
analysis after building. Release preflight runs the default check, including with `--app`.

The compiler checks all `Sources/*.swift`, including selftests, with `-strict-concurrency=complete`
in Swift 5 mode for arm64/macOS 13. The initial baseline contains 13 warnings from Apple Swift
6.3.3: shared preference defaults/formatter, concurrent closure captures, and actor-isolated
settings helpers called by selftests. These are review items, not proof of 13 runtime races.
Matching uses file, diagnostic message, source-line text and occurrence count, so line-number shifts
alone do not cause failures. Compiler/SDK upgrades or edits to a flagged line can require deliberate
review. The current snapshot is written to `.build/analysis/concurrency-current.json`; it never
overwrites the committed baseline.

SwiftLint checks complexity, function length, parameter count, nesting, force casts/tries, duplicate
conditions and identical operands. The four dedicated selftest files are excluded from lint only;
embedded test helpers in other files remain included. File/type length and formatting rules are
deliberately absent. The initial 17 findings are mostly parser branching and long functions, with
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
compiler/missing-tool failures.

### App diagnostics and checks

```bash
./outputs/now.app/Contents/MacOS/now --selftest        # parser unit tests
./outputs/now.app/Contents/MacOS/now --parse <url-or-file> # inspect any iCal feed
./outputs/now.app/Contents/MacOS/now --native [list]       # inspect Apple Calendar access
./outputs/now.app/Contents/MacOS/now --meeting            # inspect active meeting audio metadata
python3 scripts/calendar-cache-smoke.py             # isolated offline restart/cache checks
./scripts/preflight.sh                            # full build + release regression suites
./release.sh --dry-run                             # release prerequisites (no tests/publication)
```

See [AGENTS.md](../AGENTS.md) for development notes and the release workflow.
