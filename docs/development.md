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
