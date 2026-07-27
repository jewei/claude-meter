# Triage labels

Five triage labels drive issue state. They are **repo-specific**, not GitHub
defaults — they were created for this repo and exist on `jewei/claude-meter`
(verify with `gh label list`).

| Label             | Meaning                                  |
| ----------------- | ---------------------------------------- |
| `needs-triage`    | A maintainer needs to evaluate the issue |
| `needs-info`      | Waiting for more information             |
| `ready-for-agent` | Fully specified and ready for an agent   |
| `ready-for-human` | Requires human implementation            |
| `wontfix`         | Will not be implemented                  |

Labels are applied at creation (`gh issue create --label needs-triage`) and
moved with `gh issue edit <n> --add-label ... --remove-label ...`. An issue
should carry exactly one of these at a time.

`wontfix` ships with every GitHub repo; the other four do not. If
`gh issue edit` fails with `'needs-triage' not found` (a fresh fork or a new
repo), bootstrap them:

```bash
gh label create needs-triage    --color d4c5f9 --description "A maintainer needs to evaluate this"   --force
gh label create needs-info      --color fef2c0 --description "Waiting for more information"          --force
gh label create ready-for-agent --color 0e8a16 --description "Fully specified and ready for an agent" --force
gh label create ready-for-human --color 1d76db --description "Requires human implementation"          --force
```
