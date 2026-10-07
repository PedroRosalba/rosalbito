# Reuse vs build

Presumptive defaults from the spec, each overturned only with a recorded reason.

| SUBSYSTEM | EXISTING | REUSE | CANNOT REUSE | WILL BUILD | WHY |
|---|---|---|---|---|---|
| Code reviewer | `/code-review` (+ultra), Agent tool | yes, inside fresh-context reviewer subagents | — | only the adversarial briefs (`references/reviews.md`) | a reviewer prompt is not a reviewer; the installed one is |
| Security scanner | `security-review` skill | yes, inside the security reviewer | — | nothing | scanner-vs-exploitable distinction is an instruction to the reviewer |
| Loop runner | `ralph-loop` Stop hook, `/loop`, Workflow | **ralph-loop** | `/loop` is polling-shaped; Workflow needs explicit user opt-in per invocation | `start-loop.sh` (writes the plugin's state file with our re-entry prompt) | see `docs/driver-decision.md` |
| Orchestration framework | Agent tool (subagents) | yes | — | nothing | composition via subagents, not stacked slash commands |
| Metrics platform | — | — | — | `metrics.sh` → one JSONL line per run | only what the agent can observe |
| Context management | Claude Code compaction + resume protocol | yes | — | `current.md` schema + `state.sh` | the state file is the context that survives |
| Database / runtime | — | — | — | nothing: Markdown, YAML, JSONL, Git | spec §4 |
| Entrypoint + router | — | — | no installed skill does two-axis routing | `skill/SKILL.md`, `references/routing.md` | the actual project |
| State schema + resume | — | — | ralph-loop's state file is driver state, not run state | `templates/current.md`, `state.sh`, `init-run.sh`, `finish-run.sh` | spec §11, §13 |
| Classification + path overrides | — | — | — | `config/risk-overrides.yaml`, `classify-paths.sh` | the classifier under-classifies by incentive; rules are a floor |
| Acceptance contract | — | — | — | `templates/acceptance.yaml` | every criterion names its verification |
| Evidence recording | — | — | — | `verify.sh`, `evidence-summary.sh`, `detect-checks.sh` | commands with exit codes outrank opinions |
| Hard gates | existing `safety-check.sh` (broken: reads an env var hooks don't set) | the hook *slot* in settings.json | the script itself | `hooks/rosalbito-guard.sh` + `install.sh` | "must never happen" needs a mechanism |
| Caps | ralph-loop `max_iterations` | yes, as the plugin-side cap | no wall-clock or same-failure cap there | `caps-check.sh`, `config/caps.yaml` | spec §12 |
| Reports | — | — | — | `templates/report.md`, `blocked.md`, `pr-body.md`, `references/reports.md` | spec §15 |
| Heavy planning | `enor-plan` | not in Phase 1 | its instruction surface is large and would stack into the orchestrator context | plan section in `current.md` + Explore subagent | revisit if a real run shows thin plans |
