# Domain docs

This is a single-context repository. Its domain documentation lives at the
**repository root**, not in `CONTEXT.md` or `docs/adr/` — neither exists here.

## Layout

```text
/
├── SPECS.md                  # full behavioural spec + settings/persistence reference
├── AGENTS.md                 # architecture, non-obvious gotchas (imported by CLAUDE.md)
├── DESIGN.md                 # playful-UI design system and tokens
└── docs/
    └── agents/               # these conventions (issue tracker, triage labels, domain)
```

`AGENTS.md` is already in context every session via `CLAUDE.md`'s `@AGENTS.md`
import — do not re-read it.

## Before exploring

Read the doc that covers the area you are about to touch:

- **Behaviour, settings keys, data sources** → `SPECS.md` (see its numbered
  sections; §2.7 and §8 hold the settings/persistence reference).
- **UI, colours, typography, energy framing** → `DESIGN.md`.
- **Prior design work on a feature** → `docs/superpowers/` when present (local
  scratch, gitignored — absent in a fresh clone).

## Use the established vocabulary

Name domain concepts the way `SPECS.md` and `AGENTS.md` already do — *account
key*, *config dir*, *limit window*, *energy left*, *statusline bridge*, *tier*,
*reading state*. Do not introduce synonyms for terms that are already load-bearing
in code and docs (e.g. don't write "workspace" for *config dir*, or reframe
thresholds as "% left" — only the display is inverted).

If a needed concept has no name yet, check whether the codebase already uses one
before coining a new term.

## Flag decision conflicts

There are no ADRs. Architectural decisions are recorded inline in `SPECS.md`
(notably §11 "Explicitly discarded legacy features" and §12 "Non-goals") and in
`AGENTS.md`'s per-subsystem notes. If proposed work conflicts with one, name the
conflict instead of silently overriding it. For example:

> Contradicts SPECS.md §11 (the claude.ai web source was deliberately removed),
> but may be worth reopening because...

When a decision changes, update the root doc that records it in the same change.
