# Loop driver: ralph-loop Stop hook

"Runs overnight" is a mechanism decision. Phase 1 picks ONE driver.

**Chosen: the installed `ralph-loop` plugin's Stop hook.** `start-loop.sh` writes
`.claude/ralph-loop.local.md` (the plugin's state file) with the Rosalbito re-entry prompt,
`max_iterations` from `caps.yaml`, and the completion promise `ROSALBITO RUN FINISHED`.

How it behaves:

1. Rosalbito works; when the model ends its turn, the Stop hook fires.
2. The hook finds the state file, sees no `<promise>ROSALBITO RUN FINISHED</promise>` in
   the last message, increments `iteration`, blocks the stop and feeds the re-entry prompt
   back: *read `.agent/state/current.md`, run `caps-check.sh`, continue from `next_action`.*
3. Context grows and eventually compacts. The re-entry prompt plus `current.md` is enough
   to continue — that is what the resume protocol is for.
4. `finish-run.sh done|blocked` removes the state file; the final message carries the
   promise; the hook lets the session stop. `max_iterations` is the plugin-side hard cap.

Why this over the alternatives:

- `/loop` (ScheduleWakeup/Cron) is for *polling*: it inserts idle waits and is tied to the
  interactive session's scheduler. The Stop hook re-enters immediately and costs nothing idle.
- A bash `while` driver script around `claude -p` is the most robust against session death,
  but it needs its own process supervision and permission flags. Kept as the documented
  fallback (`docs/driver-decision.md`) if real runs show the Stop hook dying with the session.

Degradation: if the plugin is not installed/enabled, `start-loop.sh` warns and the run
proceeds single-session. Resume manually with `/rosalbito` — the state file is still the
entry point. Session isolation: the plugin keys the state file on `CLAUDE_CODE_SESSION_ID`,
which the Bash tool exposes, so a loop armed in one session does not block another.
