# OSS mode: upstream repos Pedro contributes to

> The work is for learning the ecosystem and getting changes upstream. Nothing reaches
> upstream (PR, comment, review, issue, push) until Pedro has read the exact text and said
> ok for that item. What we learn goes to the vault; what waits on Pedro goes to the inbox.

`oss-detect.sh` decides (exit 0 = OSS mode) and prints `upstream`, `vault_dir`, `inbox`,
`git_identity`, `identity_ok`. Repos and folders live in `config/oss.yaml`; a new ecosystem
is one line there plus a vault folder.

## What changes in OSS mode

| Normal run | OSS mode |
|---|---|
| durable learnings → `.agent/context/` | **also** → `vault_dir`: update the topic note it belongs to (`<vault_dir>/topics/*.md`, or the root `<vault_dir>/<folder>.md` map of content) rather than creating a new note; new note only for a new area, linked from the root note |
| push branch + `gh pr create` | commit on a local feature branch, **stop**: `inbox.sh add --kind ship-pr` with branch/worktree, the exact PR title and body (repo template + `templates/pr-body.md` evidence table), and the pass/fail/not-run evidence. On Pedro's ok: push to **his fork** (never to upstream), `gh pr create --draft --repo <upstream>` with that exact text |
| reply on a PR | draft it, `inbox.sh add --kind review-comment` with the quoted comment and the exact reply |
| decision gate | `inbox.sh add --kind decide` as well as the blocked report |

Also:
- `identity_ok=0` → `git config user.name/user.email` from `git_identity` (repo-local) before
  the first commit. Never commit OSS work under a work identity.
- Read before acting: `<vault_dir>/<folder>.md`, the topic notes the task touches, the
  maintainer note if there is one (`topics/Maintainer.md`, `topics/Maintainers.md`), and any
  `patrol/` brief or `today.md`. They record what upstream already rejected, who owns what,
  and the maintainers' norms. File at the owning layer.
- Before proposing a PR: search upstream for overlap (`gh pr list --repo <upstream> --search
  <terms> --state all`, issues too). Overlapping a maintainer's open PR → a `review-comment`
  item offering the change on that PR, not a competing PR.
- If `<vault_dir>/patrol/` already runs its own loop (cards, `feedback.md`, board), follow it:
  cards stay the work log; a card that is ready to ship also gets a `ship-pr` inbox item
  pointing at the card, and Pedro's ok in the inbox counts as `ship <card>`.

## `/rosalbito patrol [target] [since]`

Read-only toward upstream. Local repros in worktrees are fine.

`target`: an upstream repo (`cloudflare/workerd`), a PR or issue (`#8484`), an author
(`author:guybedford`), a topic (`hyperdrive`), or nothing (= every upstream repo that
`config/oss.yaml` maps to this vault folder; `owner/*` entries mean the repos we already
have PRs, issues or comments in). `since`: default = date of the last patrol report in
`<vault_dir>/patrol/`, else 7 days.

1. **Load context**: `oss-detect.sh`; the vault reads above; the last patrol report (what we
   already saw: skip unchanged items); `inbox.sh list --tsv` (don't duplicate open items).
2. **Collect** with `gh` (parallel): PRs and issues in the window matching the target; for
   each: state, diff stat, review state, comments since `since`; our own open PRs and threads
   with unanswered comments.
3. **Analyze**: one `[explorer]` subagent per significant PR/issue (≤ 8; batch small ones),
   brief: *what changes and why, which layer owns it, does it touch our work or open items
   (name the vault note), what could we do (review, repro, test, comment, nothing), evidence
   for each claim*. Claims labeled KNOWN (read in diff/thread/ran) / INFERRED.
4. **Write the report**: `<vault_dir>/patrol/<YYYY-MM-DD>-<slug>.md` — frontmatter
   (`type: patrol`, `target`, `since`, `created`), then **The picture** (5–10 lines: what is
   moving in the ecosystem and why it matters to us), then a table (item · what · owner · impact
   on us · action), then **Open questions**. Link it from the root note under Patrol.
5. **Update knowledge**: durable facts into the topic notes (with the PR link and date).
6. **Fill the inbox**: one `read` item for the report (P2 if anything in it touches our work,
   else P3), plus a `review-comment` / `ship-pr` / `decide` item for every action, each with
   its drafted text. Post nothing.
7. **Report** in chat: the picture, the counts, `/rosalbito inbox` as the next step.

## `/rosalbito <task>` in an OSS repo

The normal loop (§1–§3 of SKILL.md) with the table above applied: classify, understand
(read the vault first), acceptance, implement, verify, review, then deliver to the inbox
instead of opening the PR. Implementation tasks also write what they learned to the topic
notes before finishing.

## Prompt shapes Pedro uses

```
/rosalbito patrol cloudflare/workerd since 2026-10-20
/rosalbito patrol author:guybedford
/rosalbito patrol #8484
/rosalbito patrol                         # everything for this vault folder since last time
/rosalbito fix <issue url>                # OSS implementation, ends as a ship-pr item
/rosalbito answer the review on <pr url>  # drafts the reply as a review-comment item
/rosalbito understand <area>              # writes to .agent/context and the topic note
/rosalbito inbox                          # work the queue
```
