@AGENTS.md

## Agent skills

### Issue tracker

Issues and PRDs live in this repository's GitHub Issues, driven by the `gh` CLI.
Read an issue with `gh issue view <n> --json ...` (bare `--comments` prints only
the comment thread, not the body); create with `--label needs-triage`; use `gh`'s
native `--parent` / `--blocked-by` flags for relationships, never body text.
Full conventions: `docs/agents/issue-tracker.md`.

### Triage labels

`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix` —
repo-specific labels (only `wontfix` is a GitHub default), one per issue at a
time. Meanings and the `gh label create` bootstrap: `docs/agents/triage-labels.md`.

### Domain docs

Single-context repository. Domain documentation is at the root — `SPECS.md`
(behaviour + settings reference), `AGENTS.md` (architecture, imported above),
`DESIGN.md` (UI system). There is no `CONTEXT.md` and no `docs/adr/`; decisions
are recorded inline in `SPECS.md` (§11, §12). See `docs/agents/domain.md`.
