# Inbox: one queue for everything waiting on Pedro

> Sessions are disposable; the inbox is not. Anything a session leaves for Pedro goes into
> the inbox before the session stops, so the terminal can be closed without losing work.

Three sibling folders of markdown files, one file per item (default under
`~/Projects/obsidian-vault/oss/`, so Obsidian shows them too):

| folder | means | how an item gets there |
|---|---|---|
| `inbox/` | waiting on Pedro: review, approve, decide, read | `inbox.sh add`; `refresh` when someone replies to us |
| `outbox/` | posted upstream, waiting on them | `inbox.sh posted <id> <urls>` right after posting |
| `archive/` | finished, with `outcome` (merged, closed, answered, dropped, expired, upstream-closed) | `inbox.sh close`, or `refresh` when the watched thread closes |

`inbox.sh` is the only writer; never hand-edit frontmatter from a session.

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
waiting on us beats our own shipping). Something where the ball is in the maintainers' court
belongs in `outbox/`, not in the inbox.

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

1. **Refresh.** `inbox.sh refresh` (deterministic): archives outbox items whose PR/issue was
   merged or closed, turns replies on our posts (any reply on our own PR/issue, mentions of
   Pedro elsewhere) into `review-comment` inbox items, records other chatter as `activity` on
   the outbox item, expires `read` items older than 14 days, closes inbox items whose thread
   closed before we posted. Then `inbox.sh list --tsv`; for inbox items still worth a look,
   check CI with `gh pr view <url> --json statusCheckRollup` (red → P0).
2. **Discover.** `gh search prs --author @me --state open` and
   `gh search issues --commenter @me --state open --updated ">=<7 days ago>"`: comments
   addressed to Pedro that have no inbox item become `review-comment` items (draft the
   reply text first).
3. **Present.** One line of totals (`3 to ship · 2 comments · 1 decision · 4 reads · 5
   in outbox`), what `refresh` archived or raised, then the inbox queue in order. Per item: priority, kind, title, link, one
   sentence of what is needed, and the full text to approve for `review-comment`/`ship-pr`.
   Present at most 5 actionable items, then offer more.
4. **Act on Pedro's answer, item by item.** "ok"/"ship" on an item → re-check the target
   didn't move (branch heads, thread state), perform exactly that action with exactly that
   text (post reply, `gh pr ready`, `gh pr create`; only placeholders like `#<n>` get filled),
   verify what landed matches, then `inbox.sh posted <id> <every url created>` and
   `set <id> outcome approved-as-is|edited`. A `decide`/`read` answered → `close <id> answered|read`. Edits → apply, show the final text again, wait for OK. "later" →
   leave it. "drop" → `set <id> status dropped`. An approval covers that item only.
5. **Close.** Print what was posted (links), what moved to the outbox, and what remains.

Outside a session, `refresh` can run on a timer so the Obsidian views stay current; nothing
in it posts anything.

## `/rosalbito inbox sweep`: drain old sessions

For cleaning up a pile of terminals. `ListAgents`, keep peers whose name matches the repo or
focus Pedro gives. `SendMessage` each one:

> Write every item that is waiting on Pedro into the inbox with
> `bash ~/.claude/skills/rosalbito/scripts/inbox.sh add` (format:
> `~/.claude/skills/rosalbito/references/inbox.md`, include the exact text for any post or
> reply). Then reply with: the item ids you wrote, and `SAFE TO CLOSE` or why not.

Then report a table: session · items written · safe to close. Never close a session
yourself.
