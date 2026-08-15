# Domain docs

Domain documentation lives at the **repository root**, not in `CONTEXT.md` or
`docs/adr/` — neither exists here. The one exception is area-specific gotchas,
which live in a `CLAUDE.md` beside the code they describe so they load only when
you work under that directory.

## Layout

```text
/
├── SPECS.md                  # full behavioural spec + settings/persistence reference
├── AGENTS.md                 # cross-cutting architecture + gotchas (imported by CLAUDE.md)
├── DESIGN.md                 # playful-UI design system and tokens
├── ClaudeMeter/CLAUDE.md     # playful UI / energy design, notifications
├── ClaudeMeterWidget/CLAUDE.md
├── ClaudeMeterCore/Sources/ClaudeMeterProviders/CLAUDE.md
└── docs/
    └── agents/               # these conventions (issue tracker, triage labels, domain)
```

`AGENTS.md` is already in context every session via `CLAUDE.md`'s `@AGENTS.md`
import — do not re-read it. The directory-level `CLAUDE.md` files are **not**
always loaded: read the one for the area you are about to touch, and put new
area-specific gotchas there rather than in `AGENTS.md`.

## Before exploring

Read the doc that covers the area you are about to touch:

- **Behaviour, settings keys, data sources** → `SPECS.md` (pipeline in §3,
  settings in §7, networking/security in §10).
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

There are no ADRs. Current architectural contracts live in `SPECS.md`; migration
history and non-obvious implementation decisions live in `AGENTS.md`. If proposed
work conflicts with one, name the conflict instead of silently overriding it. For
example:

> Contradicts the three-tier pipeline in SPECS.md §3, but may be worth reopening
> because...

When a decision changes, update the root doc that records it in the same change.
