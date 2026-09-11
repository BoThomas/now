# Writing useful repository documentation

## Explain systems, not inventories

Choose the aspects that matter for each topic:

- Responsibility, ownership, and the user-facing behavior it supports.
- Entry points and the path data or control takes through the system.
- State, persistence, lifecycle, ordering, and concurrency.
- Invariants, failure handling, recovery, and important tradeoffs.
- Configuration, dependencies, integrations, and operational effects.
- Where to extend the behavior and which tests exercise it.

These are research lenses, not mandatory headings. Do not pad pages with empty
sections or describe every symbol. Explain connections between components.
Use compact plain-text or Mermaid diagrams when they clarify a flow or boundary,
following the project's rendering conventions. Name real components and make
the diagram agree with the accompanying explanation.

## Keep structure proportional

Start with quickstart and only the supporting pages the project needs. A small
project may need just the quickstart. Choose larger projects' topics from their
actual architecture and workflows rather than a fixed taxonomy or page count.

Use directories when they group meaningful topics. Prefer a section in an
existing page over a directory with one short stub. Keep each concept's detailed
explanation in one place and link to it elsewhere.

The quickstart should route readers by task: understand the system, change a
major behavior, run checks, or find user docs. It should not replace a good README
or copy all engineering rules from AGENTS.md. Link to those sources.

## Ground and maintain claims

Follow representative behavior, including unhappy paths. Confirm important
mechanisms in implementation and focused tests. A test name, comment, or old
commit alone is not proof of current behavior. Explain unknowns rather than
inventing answers. Do not expand a documentation task into a general code review.

Prefer stable file links with enough prose to locate the relevant function or
type. Line numbers and large symbol inventories go stale quickly. Reference a
commit when it explains an important decision, not as a list to refresh each run.

For updates, tie each changed passage to a verified behavior change or gap.
Remove claims that are no longer true. Avoid wording, formatting, and structure
changes solely to produce a diff. If the requested areas are accurate, leave
them unchanged and say what was checked.

## Be precise about completion

For initial creation, report the entrypoint, topic pages, researched areas, and
validation. For a focused refresh, explain the behavior change and affected docs;
do not imply unrelated areas were revalidated. For a no-op, explain why the
reviewed docs still fit. For an interrupted review, identify unfinished areas
without claiming completion or writing metadata that suggests full coverage.
