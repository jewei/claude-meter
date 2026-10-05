# Token history on this Mac

How the app counts Claude Code, Codex, and Grok Build tokens from local session files.
Cursor history comes from the Cursor account export and is not described here.

Code: `Sources/MeterPlatform/History` (scanner, records, days) and the `History` folder of
each provider module (`ClaudeTokenHistory`, `CodexTokenHistory`, `GrokTokenHistory`).

## Scope

1. History counts tokens. It does not count money, and it does not change quota, severity,
   selection, or the menu bar.
2. History covers today and the previous six local calendar days.
3. The date in each record sets the day. The date of the file does not set the day.
4. The calendar of the read sets the days. A change of time zone makes the old history
   unknown until the next read. The default calendar follows the system time zone.
5. Each account counts only the records in its own folder: the Claude config dir, the Codex
   home, or the Grok home. The folder sets the scope, not the login. A folder can hold
   records of earlier logins.
6. An account without a folder has no records. Its history is unknown, not zero.
7. The app keeps history in memory only. It writes no history to disk. A restart reads all
   files again.
8. The app keeps counts and record IDs only. It never keeps prompt or response text.

## File locations

| Tool | Folder per account | Files |
| --- | --- | --- |
| Claude Code | `<config dir>/projects` | `*.jsonl` at any depth |
| Codex | `<Codex home>/sessions` and `<Codex home>/archived_sessions` | `*.jsonl` at any depth |
| Grok Build | `<Grok home>/sessions` | `updates.jsonl` at any depth |

9. The scanner skips hidden files and hidden folders (names that start with a dot).
10. Each root folder in the table (such as `<config dir>/projects`) goes through `realpath`,
    so a root that is a symbolic link, or that is inside a linked folder, is read. Below each
    root, the scanner does not follow symbolic links. A link or a special file (such as a
    FIFO) with a matching name is skipped. This does not make history partial.
11. A folder with a matching name, such as `notes.jsonl/`, is a folder. The scanner looks
    inside it.
12. The scanner skips a file that was last modified before the first covered day.

## Record shapes

Each example shows every field that history reads, in its usual spelling. The line after an
example lists the other spellings that are also read. Real lines have more fields, and the
parsers ignore them, but each line must be one valid JSON object, or it makes history
partial (rule 64).

### Claude Code

```json
{"type":"assistant","timestamp":"2026-10-01T12:00:00Z","requestId":"req_1",
 "message":{"id":"msg_1","usage":{"input_tokens":10,"output_tokens":3,
  "cache_read_input_tokens":7,"cache_creation_input_tokens":2,
  "cache_creation":{"ephemeral_5m_input_tokens":1,"ephemeral_1h_input_tokens":1}}}}
```

Other spellings: `request_id` for `requestId`.

### Codex

```json
{"type":"session_meta","timestamp":"…","payload":{"id":"<session>","timestamp":"…",
 "forked_from_id":"<parent>","parent_thread_id":"<parent>",
 "source":{"subagent":{"thread_spawn":{"parent_thread_id":"<parent>"}}},
 "subagent_history_start_ordinal":12}}
{"type":"turn_context","payload":{"turn_id":"…"}}
{"type":"event_msg","payload":{"type":"task_started","turn_id":"…"}}
{"type":"event_msg","timestamp":"…","ordinal":17,"payload":{"type":"token_count",
 "turn_id":"…","response_id":"…",
 "info":{"total_token_usage":{"input_tokens":160,"output_tokens":16},
  "last_token_usage":{"input_tokens":60,"output_tokens":6},"response_id":"…"}}}
```

Other spellings: `session_id` for the session `id`; `turnId` for `turn_id`; `request_id`
for `response_id`, in `payload` and in `info`; `forkedFromId`, `parent_session_id`, and
`parentSessionId` for the parent. A `token_count` event takes the response ID from `info`
first, then from `payload`, and the turn ID from its own `payload`, then from the last
`turn_context` or `task_started` line.

### Grok Build

```json
{"params":{"_meta":{"eventId":"e1","agentTimestampMs":1790856000000},
 "update":{"sessionUpdate":"turn_completed","usage":{"modelUsage":{"model-a":
  {"inputTokens":1000,"outputTokens":50}}}}},"timestamp":"…"}
```

Other spellings: `update` and `_meta` can also be at the top level. The top-level
`timestamp` is used when `agentTimestampMs` is missing.

## Field values

13. A count is a non-negative integer, as a number or as a string of digits. A boolean, a
    fraction, a negative number, or a number larger than `Int64` is not a count.
14. A date is an ISO-8601 string with a zone (`Z` or an offset), or Unix time in seconds or
    in milliseconds, as a number or as a string. A number larger than 100,000,000,000 is
    milliseconds. A time without a zone is not a date.
15. An ID is a non-empty string of at most 512 bytes.

## Counting rules: Claude Code

16. Only lines with `type` `assistant` and an object `message.usage` count. Other lines are
    ignored.
17. Tokens = input + output + cache read + cache write.
18. Input and output are necessary. Cache read and cache write are zero when they are
    missing or null.
19. If `cache_creation` holds `ephemeral_5m_input_tokens` or `ephemeral_1h_input_tokens`
    (even as null), cache write is the sum of those two. Else cache write is
    `cache_creation_input_tokens`.
20. The key of a record is the request ID (`requestId`, then `request_id`) and `message.id`.
    Without a request ID, `message.id` alone is the key. The session ID is never part of it:
    a resumed session copies a response under a new session ID. A line without `message.id`
    has no key: it still counts, once per line, and it makes the history partial (rule 64).
21. Records with the same key count once. Claude Code writes one line per content block,
    and each line repeats the cumulative usage of the response. The account folders come
    from the config dirs. When they cannot be listed in time, the read fails and keeps its
    last value. It never scans an empty root list, which would discard the scan state
    (rule 59).

## Counting rules: Codex

22. Only `token_count` events count. An event with `info: null` is ignored.
23. Tokens of an event = input + output. `cached_input_tokens` and
    `cache_write_input_tokens` are parts of `input_tokens`. `reasoning_output_tokens` is a
    part of `output_tokens`. The app does not add them again.
24. The cache-write decision comes from upstream Codex (`openai/codex`,
    `codex-rs/codex-api/src/sse/responses.rs`). Codex fills `cached_input_tokens` and
    `cache_write_input_tokens` from the Responses API `input_tokens_details`. Its test has
    input 100, cached 40, cache write 60, output 10, and total 110.
25. Codex writes cumulative counters. An event counts only the growth over the highest
    counters seen before it, and at most its own `last_token_usage`. Counters that fall below
    that mark restarted (for example a session resumed in the same file): the event counts
    its own `last_token_usage`, and the mark starts again from its total. A restart seen at
    its first response (total equal to last) is exact; a later one makes history partial.
26. A repeated `response_id` counts once.
27. An event with only `last_token_usage` counts once per turn, response, and value.
28. Copies of one session (the same session ID, for example in `sessions` and
    `archived_sessions`) count once. A copy that continues the other replaces it.
29. A fork or subagent file starts with a copy of its parent's history. It counts only the
    events after its owned boundary:
    - With `subagent_history_start_ordinal`, the boundary is the first event at that
      ordinal or later.
    - Without it, the boundary is the first event after the fork time whose counters
      continue the parent's counters.

    A file has a parent when it names one (`forked_from_id`, `forkedFromId`,
    `parent_session_id`, `parentSessionId`, `parent_thread_id`, or
    `source.subagent.thread_spawn.parent_thread_id`), has an ordinal, or repeats another
    session's metadata. A subagent without any of these (such as `{"subagent":"review"}`)
    starts its own history and owns all its events.
30. The parent must be in the same account's folders. The account folders come from the
    Codex homes. When the homes cannot be resolved in time, the read fails and keeps its last
    value. It never scans an empty root list, which would discard the scan state (rule 59).

## Counting rules: Grok Build

31. Only `turn_completed` updates with `usage.modelUsage` count. Unfinished turns are
    absent. They do not make history partial. A completed turn with an empty `modelUsage`
    used no tokens, so it counts nothing and does not make history partial, even without a
    date or an event ID.
32. Tokens of a model in a turn = input + output. Cache and reasoning counts are parts of
    them. Output is zero when it is missing. `_meta.agentTimestampMs` is always milliseconds.
33. The key of a record is the event ID and the model name. Records with the same key count
    once, also when one line has the `params` form and the other the top-level form.

## Copies and ties

34. One rule applies inside a file and across files, so the result does not depend on the
    read order: of two records with the same key, the record with the larger count wins.
    With equal counts, the record with the earlier date wins.
35. Codex session copies that disagree make history partial. The copy with more events wins.
    With equal counts, the first copy in root order, then path order, wins.
36. A file that is reachable by two paths (a hard link) counts once, for the root that comes
    first in the configured order.
37. A file that two nested roots find belongs to the root that comes first in the
    configured order.
38. Two roots at the same folder count once. The first root keeps its account.
39. The scanner records the root that found each file. It never uses path prefixes to find
    the owner of a file.

## Limits

| Limit | Value |
| --- | --- |
| Bytes read in one scan | 64 MiB |
| Bytes read from one file in one scan | 8 MiB |
| Length of one line | 1 MiB |
| Files kept | 2,048 |
| Directory entries visited in one scan | 20,000 |
| Records kept from one file | 20,000 |
| Records kept for one provider | 100,000 |
| One blocking call (a directory page, a root check, one file) | 5 s |
| One history read (applied by the app) | 20 s |

40. The scanner reads the most recently modified files first, so they get the byte budget
    first.
41. A file over the byte limit continues on the next scan.
42. A line over the line limit is skipped once. Its bytes are not read again.
43. At the per-file record limit, the scanner stops reading that file.
44. At the provider record limit, the newest files are kept. Older files are not read.
45. At the file limit, the newest files are kept.
46. History reads use their own pool of blocking threads, so stuck history folders never
    make quota reads fail. When 16 history reads are stuck, the scanner waits up to 2 s for
    one of them to end.

## Incremental reads

47. For each file, the scanner keeps the offset after the last complete line, the first
    256 bytes, and the 256 bytes before the offset.
48. A file with the same identity, size, and change times is not read again.
49. A grown file is read from the saved offset when its first bytes and the bytes before
    the offset did not change.
50. The scanner reads the whole file again when the file was replaced (a new inode),
    became shorter, changed at the same size, or changed its first bytes or the bytes before
    the offset. This assumes that the tools only append to their files.
51. An incomplete final line is not counted. The scanner reads it again on the next scan.
52. A file that grows while it is read keeps the new offset. A file that shrinks or changes
    at the same size while it is read keeps its previous offset and records.
53. A file that cannot be opened or read loses its records until a later read succeeds.

## Discovery

54. Discovery takes one entry from each root in turn, so a large root cannot block the
    others.
55. Discovery continues on the next scan after the entry or file budget of a scan. It reads
    a folder in chunks of 1,024 entries and keeps its position, so a large folder takes
    several short reads. When the folder changed between two chunks, its listing goes on
    from the same position, so a large folder that changes often still reaches its end. A
    new entry can then move another entry after the position: it is listed twice and counts
    once. A removed entry can move another entry before the position, where the sweep does
    not see it: the completed sweep keeps the files of that folder from the earlier list when
    a read found them. A new file that the sweep did not see is found by the next sweep.
56. A completed sweep replaces the file list (except as rule 55 says), so deleted files
    disappear. The next scan starts a new sweep, which finds new files. Until the new sweep
    completes, the list of the last complete sweep keeps its folders complete.
57. An incomplete sweep only adds files. It never removes files that an earlier sweep found.
58. An unreadable folder does not stop the sweep. The other folders of the root are read.
59. A change of the roots, of a root folder on disk (path, existence, device, or inode), or
    of an account, or a move of the first covered day to an earlier day, discards all scan
    state. When the first covered day moves later (at local midnight), the scan state stays,
    and the file list stays too: the date that discovery saved for a file can be older than
    the file, because a resumed session can have written to it since. Records before the new
    first day do not count. A sweep that starts after the move does not find the files last
    modified before the new first day, so its completion removes them, except as rule 55
    says.
60. A discovery page that times out ends discovery for that scan. The files found by
    earlier pages still count. The sweep skips the folder that the page waited for and makes
    its account partial, so the next page goes on past it; a later sweep lists the folder
    again. A root check that times out returns the files of the last scan, with every
    account partial. A root check, discovery page, or file whose earlier read timed out and
    still runs is skipped until that read ends, so a stuck folder holds one thread, not one
    more for each scan.
61. Cancellation stops a scan between directory pages, inside a folder listing, and between
    files. Progress made before the cancellation is kept. One scan runs at a time for each
    tool.

## Partial and unknown history

62. History is unknown when the account has no records, when the time zone changed, when
    the covered days do not include the period, or when the last read was on an earlier day
    (the days after that read are not covered).
63. Partial coverage belongs to the account whose folder caused it. Other accounts stay
    complete.
64. These conditions make an account partial:
    - a folder in it could not be read, or neither the current sweep nor a complete earlier
      sweep walked its folders to the end;
    - its root check timed out;
    - a file in it was not read completely (byte budget, incomplete final line, long line,
      per-file record limit, provider record limit, read error, or timeout);
    - a line in it could not be counted (invalid JSON, a missing or invalid count or date,
      a missing ID, or a date more than 60 s after the start of the read). A date up to 60 s
      after the start of the read belongs to a line written during the read: it is not
      counted yet and does not make history partial, and the next read counts it;
    - Codex: an unresolved fork, invalid ownership fields, a file without session metadata,
      counters that do not agree, or copies that disagree.
65. The file limit makes every account partial.
66. No limit makes history read as a complete zero.
