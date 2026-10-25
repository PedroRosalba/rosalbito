# Inbox: one queue for everything waiting on Pedro

> Sessions are disposable; the inbox is not. Anything a session leaves for Pedro goes into
> the inbox before the session stops, so the terminal can be closed without losing work.

The inbox is a folder of markdown files, one per item, at `inbox.sh path` (default
`~/Projects/obsidian-vault/oss/inbox/`, so Obsidian shows it too). `inbox.sh` is the only
writer; never hand-edit frontmatter from a session.

## Kinds: what Pedro has to do

| kind | Pedro's action | body must contain |
|---|---|---|
| `review-comment` | read a reviewer's comment and approve our reply | the comment quoted (author, date, link), what it asks, **the exact reply text** we would post, and what code change (if any) goes with it |
| `ship-pr` | approve opening/undrafting a PR or publishing an upstream post | branch/worktree path, **the exact PR title and body** (or post text), evidence summary (checks run, pass/fail/not-run), risks |
| `decide` | pick between options | the question, 2–4 options, the recommendation and why |
| `read` | read a finding or vault update | 3–5 line summary, why it matters for the work, the file to open |

Pedro reads the final text of every upstream post before it goes out. A `review-comment` or
`ship-pr` item without the exact text is incomplete: write the text, then add the item.

## Priority

| P | when |
|---|---|
| P0 | a maintainer or reviewer has been waiting on us > 48h; our PR has red CI or a bug a reviewer found; anything with a deadline |
| P1 | default for `review-comment`, `ship-pr`, `decide`: ready, only Pedro's OK is missing |
| P2 | needs more work before it is shippable, or nobody is blocked by it |
| P3 | default for `read`: ecosystem notes, findings, vault updates |

Inside a priority: `review-comment` → `ship-pr` → `decide` → `read`, oldest first (a human
waiting on us beats our own shipping). `waiting: upstream` marks an item where the ball is
in the maintainers' court: it stays open for tracking but is listed, not presented.

## Writing an item (any session)

Before a session stops, and whenever a run ends `blocked` or produces something only Pedro
can release:

```bash
bash SKILL_DIR/scripts/inbox.sh add --kind ship-pr --repo tokio-rs/tokio \
  --link https://github.com/tokio-rs/tokio/pull/8484 --source notes/patrol/8484.md \
  --title "Undraft #8484: JSPI waker fix" <<'EOF'
<body per the table above>
EOF
```

Re-adding with the same `--link` refreshes the open item instead of duplicating it, so it is
safe to run on every stop. Absolute paths in `--source` and the body: the reader is a
different session in a different repo.

## `/rosalbito inbox`: the coordinator

Runs in **this** context (Pedro is interacting). Read-only until Pedro approves an item.

1. **Refresh.** `inbox.sh list --tsv`. For every open item with a GitHub link, check reality
   with `gh` (`gh pr view <url> --json state,isDraft,reviewDecision,comments,reviews,statusCheckRollup`):
   merged/closed → `set <id> status done`; new comments since `updated` → bump priority per
   the table and note it; red CI → P0. Run independent `gh` calls in parallel.
2. **Discover.** `gh search prs --author @me --state open` and
   `gh search issues --commenter @me --state open --updated ">=<7 days ago>"`: comments
   addressed to Pedro that have no inbox item become `review-comment` items (draft the
   reply text first).
3. **Present.** One line of totals (`3 to ship · 2 comments · 1 decision · 4 reads · 5
   waiting on upstream`), then the queue in order. Per item: priority, kind, title, link, one
   sentence of what is needed, and the full text to approve for `review-comment`/`ship-pr`.
   Present at most 5 actionable items, then offer more.
4. **Act on Pedro's answer, item by item.** "ok"/"ship" on an item → perform exactly that
   action with exactly that text (post reply, `gh pr ready`, `gh pr create`), then
   `set <id> status done`. Edits → apply, show the final text again, wait for OK. "later" →
   leave it. "drop" → `set <id> status dropped`. An approval covers that item only.
5. **Close.** Print what was done and what remains.

## `/rosalbito inbox sweep`: drain old sessions

For cleaning up a pile of terminals. `ListAgents`, keep peers whose name matches the repo or
focus Pedro gives. `SendMessage` each one:

> Write every item that is waiting on Pedro into the inbox with
> `bash ~/.claude/skills/rosalbito/scripts/inbox.sh add` (format:
> `~/.claude/skills/rosalbito/references/inbox.md`, include the exact text for any post or
> reply). Then reply with: the item ids you wrote, and `SAFE TO CLOSE` or why not.

Then report a table: session · items written · safe to close. Never close a session
yourself.
