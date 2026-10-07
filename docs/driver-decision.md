# Decision 001: loop driver = ralph-loop Stop hook

Date: 2026-10-06 · Status: decided, to be revisited after real runs

## Context

"Runs overnight" needs a mechanism that re-enters the loop when the model ends a turn,
when context compacts, and ideally when the session dies. Three candidates were installed
or available: the `ralph-loop` plugin (Stop hook), `/loop` (ScheduleWakeup / cron), and a
small bash driver around `claude -p`.

## Options

1. **ralph-loop Stop hook** — in-session; blocks exit and re-feeds a fixed prompt until a
   `<promise>` appears or `max_iterations` is reached. Zero idle time. Survives compaction
   (the prompt + `.agent/state/current.md` carry the state). Does *not* survive the process
   dying: a killed session needs `/rosalbito` typed again (the resume protocol handles the rest).
2. **/loop** — schedules wake-ups at an interval or self-paced. Designed for polling; inserts
   idle waits between iterations and ties the loop to the interactive scheduler. Also dies
   with the session.
3. **bash driver** `while :; do claude -p "/rosalbito" ...; done` with a `--max-turns` and
   the state file deciding when to stop — survives session death, can be `nohup`ed/launchd,
   but needs `--dangerously-skip-permissions` or a tuned permission mode, its own supervision,
   and would run outside the user's interactive session (less visibility).

## Choice

Option 1. It is already installed, it is the cheapest re-entry, it is exactly the shape of
the loop ("same prompt, see your own work in files"), and `max_iterations` gives a plugin-
side hard cap for free. `start-loop.sh` writes the plugin's state file directly (format
documented in its README) rather than calling its setup script, so the re-entry prompt is
ours and the dependency is only on the Stop hook.

## Consequences

- Session death requires one human (or scheduled) `/rosalbito` to resume. Tested in
  `docs/resume-test.md`.
- If real overnight runs show sessions dying regularly, promote option 3 to a supported
  mode: `scripts/driver.sh` wrapping `claude -p` under launchd. Not built until observed.
- The wall-clock and same-failure caps live in `caps-check.sh` (run at each re-entry), not in
  the plugin.
