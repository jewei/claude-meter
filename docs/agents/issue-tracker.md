# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for all
operations; it infers the repo from the clone, so no `--repo` flag is needed.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..." --label needs-triage`.
  Use a heredoc for multi-line bodies. Every new issue starts at `needs-triage`
  (see the triage labels in `CLAUDE.md`) unless it is being filed already
  specified, in which case use `--label ready-for-agent`.
- **Read an issue**: `gh issue view <number> --json number,title,state,body,labels,comments --jq '{number, title, state, labels: [.labels[].name], body, comments: [.comments[].body]}'`.
  `--comments` alone prints **only** the comment thread as plain text — no title,
  no body, and nothing `jq` can parse. Always go through `--json`.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`
  with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

## Relationships

`gh` supports issue relationships natively — use the flags, never body-text
conventions like `Part of #12` or `Blocked by: #12`, which no query can read back.

- **Sub-issues**: `gh issue create --parent <parent>`, or
  `gh issue edit <parent> --add-sub-issue <child>` / `--remove-sub-issue <child>`.
- **Dependencies**: `gh issue create --blocked-by <n>,<n> --blocking <n>`, or
  `gh issue edit <n> --add-blocked-by <n>` / `--add-blocking <n>`.
- **Assign**: `gh issue edit <n> --add-assignee @me`.

## Pull requests

PRs are **not** a request surface for this repo — triage happens on issues.
PRs are still read during review:

- `gh pr view <number> --json number,title,body,state,labels,comments --jq '...'`
  (same caveat as issues: bare `--comments` prints only the thread), and
  `gh pr diff <number>` for the patch.
- Author association is **not** available from `gh pr list --json` — the field
  does not exist there. Use `gh api repos/{owner}/{repo}/pulls --jq '.[] | {number, assoc: .author_association}'`.

Issues and PRs share one number space, and `gh issue view <pr-number>` **succeeds
silently**, rendering a PR as if it were an issue (a merged PR reads as
`state: MERGED`). For a bare reference such as `#42`, resolve the kind first:

```bash
gh api repos/{owner}/{repo}/issues/42 --jq 'if has("pull_request") then "pr" else "issue" end'
```

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Use the **Read an issue** command above.
