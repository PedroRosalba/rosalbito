---
run_id: __RUN_ID__
task: "__TASK__"
repo: __REPO__
branch: __BRANCH__
base_branch: __BASE__
risk: __RISK__
path_floor: __FLOOR__
human_required: __HUMAN_REQUIRED__
human_level: __HUMAN_LEVEL__
status: classifying
iteration: 1
started_at: __STARTED_AT__
updated_at: __STARTED_AT__
driver: none
acceptance: .agent/acceptance/__RUN_ID__.yaml
evidence: .agent/evidence/__RUN_ID__.jsonl
pr: ""
next_action: "Classify the task (risk tier, path floor, human routing) and write the plan."
---

# Rosalbito run __RUN_ID__

> Resume protocol: a fresh agent reads this file first, runs `caps-check.sh`, and continues
> from `next_action`. Keep every section truthful. Never promote a guess to a fact.

## Task

__TASK__

## Classification

- risk: __RISK__ (floor __FLOOR__) — why:
- human: level=__HUMAN_LEVEL__ required=__HUMAN_REQUIRED__ — reason:

## Plan

1.

## Verified

<!-- one line per passed check, citing the evidence line: `- test — evidence #3 (exit 0)` -->

## Failed

<!-- one line per failing check with the current hypothesis -->

## Reviews

<!-- round N: reviewer / verdict / findings -->

## Open decisions

<!-- only genuine decisions for Pedro; otherwise write a decision record -->

## Log

- __STARTED_AT__ run created
