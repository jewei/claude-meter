# GitHub issue workflow

Issues and product requirements live in this repository's GitHub Issues. Use `gh`
from the clone so it selects the repository. Triage work through issues; use PRs for
code review.

## Read and identify work

Use JSON to retrieve both the body and comments:

```bash
gh issue view <number> --json number,title,state,body,labels,comments
gh issue list --state open --json number,title,body,labels,comments
gh pr view <number> --json number,title,body,state,labels,comments
gh pr diff <number>
```

Issues and PRs share numbers. `gh issue view` also accepts PR numbers, so identify a
bare reference before treating it as an issue:

```bash
gh api repos/{owner}/{repo}/issues/42 --jq 'if has("pull_request") then "pr" else "issue" end'
```

For PR author association, use `gh api repos/{owner}/{repo}/pulls` and its
`author_association` field; `gh pr list --json` does not expose that field.

## Create and update work

Use `--body-file` for multiline descriptions and comments. Write the exact text to a
file first to preserve newlines and prevent shell substitution.

```bash
gh issue create --title "..." --body-file /tmp/issue-body.md --label needs-triage
gh issue edit <number> --body-file /tmp/issue-body.md
gh issue comment <number> --body-file /tmp/issue-comment.md
gh issue edit <number> --add-assignee @me
gh issue close <number> --comment "..."
```

Use native relationships, not body text such as "Blocked by #12":

| Relationship | Create | Edit |
| --- | --- | --- |
| Parent | `--parent <parent>` | `--parent <parent>` |
| Sub-issue | Create with a parent | On parent: `--add-sub-issue <child>` |
| Dependency | `--blocked-by <n>` / `--blocking <n>` | `--add-blocked-by <n>` / `--add-blocking <n>` |

The edit flags also have `--remove-*` forms. A skill request to publish to the issue
tracker means create a GitHub issue; a request to fetch a ticket means read that issue.

## Triage labels

Keep exactly one triage label on each issue. New issues start with `needs-triage`;
fully specified work may start with `ready-for-agent`.

| Label | Meaning |
| --- | --- |
| `needs-triage` | A maintainer must evaluate the issue |
| `needs-info` | More information is required |
| `ready-for-agent` | Fully specified and ready for an agent |
| `ready-for-human` | Requires human implementation |
| `wontfix` | Will not be implemented |

Change state with `gh issue edit <n> --add-label <new> --remove-label <old>`.
Only `wontfix` is a GitHub default. Check `gh label list` on a fresh fork. If missing,
create the other labels:

```bash
gh label create needs-triage --color d4c5f9 --description "A maintainer needs to evaluate this"
gh label create needs-info --color fef2c0 --description "Waiting for more information"
gh label create ready-for-agent --color 0e8a16 --description "Fully specified and ready for an agent"
gh label create ready-for-human --color 1d76db --description "Requires human implementation"
```
