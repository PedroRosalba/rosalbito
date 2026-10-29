# Session records: remember a session, find it again later

A Claude Code session holds context nothing else has: why a decision went one way, which
dead ends were tried, the exact repro. `scripts/session.sh` keeps a record of it in the vault
(`oss/sessions/`, next to the inbox), so a later session, or a `refresh` that sees a maintainer
reply, can point back to it and reopen it with `claude --resume`.

The record is an index, not a dump. Durable facts still go where they belong: knowledge to
the vault topic notes, rules and preferences to Claude memory, pending work to the inbox.

## Save: when Pedro is closing the session

Triggers: "I'm closing the session", "imma close this", "closing this one", "wrap up", "that's
it for today", "save this session", `/rosalbito save [title]`. Do it before the goodbye.

1. **Pending work first.** Anything only Pedro can release goes into the inbox
   (`references/inbox.md` §Writing an item). Anything posted gets `inbox.sh posted`. Threads of
   others we follow get `inbox.sh watch`.
2. **Write the record.** Pass every inbox/outbox/watch item this session created or touched
   with `--items` (they get a `context:` link back, and their threads join the record's watch
   list). Add other threads with `--watch`.
   ```
   session.sh save --title "<what this session was about>" --repo <owner/name> \
     --items <id>... --watch <url>... <<'EOF'
   ## In plain words
   - What this session was about, in two lines.
   - Where it ended: what's done, what's waiting on whom.

   ## Done
   - <thing> — <link or path>

   ## Open threads
   - <thread>: waiting on <who>; next step <what>.

   ## Decisions and why
   - <decision>: <reason>. Rejected: <alternative> because <reason>.

   ## Where the evidence is
   - <repro, logs, drafts, branches: absolute paths>
   EOF
   ```
   Saving again from the same session updates the same record (body replaced, lists merged).
3. **Tell Pedro** the record path and the resume command (`session.sh resume <id>`), in one line.

Outside OSS mode, write the same body to `.agent/context/pending.md` instead.

## Recall: when work comes back

- **A refresh item names a session** (`Earlier sessions on this thread`, or `context:` on the
  item): read that record before drafting anything. Its decisions stand unless new facts
  change them. If the reply needs more than the record holds (a repro to rerun, a long
  argument), tell Pedro the resume command; don't reconstruct from memory.
- **Starting OSS work** (a task, a patrol, a new inbox item): `session.sh find <owner/name>`
  and `session.sh find <thread url>` first. A hit means that ground was covered: read the
  record, build on it, and link the new work to it.
- **Pedro asks "where were we on X"**: `session.sh find "<X>"`, then the record.

A record is never a reason to skip re-checking upstream: threads move. Re-read the thread
before acting on anything a record says is open.
