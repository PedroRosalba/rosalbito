# Eval drafts: merged PRs become graded coding-agent tasks

> A task counts only once its grader has given the right verdict on the reference fix, on no
> change, on a wrong fix and on another correct fix. Drafts stay local and Pedro judges each one.

The single protocol for patrol step 7 and for `/rosalbito eval <pr-url | --since date>`.
Settings: `SKILL_DIR/config/evals.yaml` (override in `.agent/context/evals.yaml`;
`ROSALBITO_EVALS_DIR` overrides `evals_dir`). The worked example lives in `<evals_dir>`:
`tasks/wasm-bindgen-5415/`, `validation/wasm-bindgen-5415/`, `reports/wasm-bindgen-5415.md`. It is
grader validated and image validated, with no agent run yet.

The order for each draft: pick, build, validate, read why each case failed, write the report,
commit including results, then add the inbox item.

## 1. Pick

| Source | Run |
|---|---|
| patrol of `owner/name` | `eval-candidates.sh --since <since> --repo owner/name` |
| patrol of nothing, or a config entry `owner/*` | `eval-candidates.sh --since <since> --repo a/b --repo c/d`, one `--repo` for each concrete repo the patrol collected. Never `owner/*`: the script exits 2 |
| patrol of `author:x` | `eval-candidates.sh --since <since> --author x` |
| patrol of `#n` or a topic | `eval-candidates.sh --since <since> --repo a/b`, one `--repo` for each repo it collected. A merged PR URL it collected can go down the `<pr-url>` path below |
| `/rosalbito eval --since <date>` | `eval-candidates.sh --since <date> --repo <upstream>`, with `upstream` from `oss-detect.sh`. If there is none, ask for the repo in one line |
| `/rosalbito eval <pr-url>` | no search: Pedro already picked, so ranking and size limits don't apply. `gh pr view <url> --json url,mergedAt`, then use the returned `url` from here on, so an old link still matches. Not merged means stop and say so. Then `eval-candidates.sh --built <url>`: 0 means already built or dropped, so stop and say so; 1 means go on; 2 means a bad URL |

Each PR costs one `gh api` call (217 s for 248 PRs), so run the script in the background for
windows over about 100 PRs. Progress goes to stderr every 25 PRs.

A non-zero exit means the search failed, not that there are no candidates: report the failure.
From the list choose at most `max_drafts_per_patrol` by reading the actual diff and tests. Prefer
PRs where a tempting wrong fix exists and the test checks behaviour. Skip anything needing a
build too heavy for the machine. Zero is a fine answer.

## 2. Build

The eval repo is local only, so drafts commit straight to its `main`. One `[writer]` subagent per
draft, one at a time: they share the checkout and `.work/`. Before each draft run
`git -C <evals_dir> status --porcelain`. If the repo is dirty, for example left by a crashed
draft, skip the draft and name it in the chat report. Never clean up or stash what's there.

`<name>` is `<repo>-<number>`. Add the owner only when two repos collide. Produce:

```text
tasks/<name>/        instruction.md, task.toml (with [metadata] source_pr = "<url>"),
                     environment/Dockerfile, solution/, tests/test.sh, tests/grade.sh, tests/test.patch
validation/<name>/   expected.tsv, config.env, at least one flawed-* fix, one alt-* correct fix
reports/<name>.md    what was built, what validation changed, what wasn't run
```

`source_pr` holds the canonical URL `gh pr view <url> --json url` reports at build time, because
exclusion compares owner, repo and number.

These files can become public after Pedro's OK, and only then. They contain no personal names or
handles: grep them for the PR's author and reviewers before committing, and use plain diffs for
patches, not `format-patch`.

### Prompt rules (`instruction.md`)

- State behaviour, not the fix. Remove the diagnosis and suggested fixes from the source issue.
- Every rule the grader enforces is stated in the prompt.
- Compare the prompt against what the tests really assert.
- Compare the fixtures with the hidden test for fixes that pass by luck, including renamed or
  aliased identifiers and a second code path for the same bug. Cover those with cases.
- A "must not change" claim in a prompt needs a check that actually enforces it.

### Grader rules (`tests/grade.sh`, `tests/test.sh`)

Each was learned from the worked example.

- Exit 0 pass, 1 wrong, 2 grader or environment error. An error writes no reward.
- Check the count of tests that ran: `cargo test` exits 0 when a filter matches nothing.
- A skipped required test is an error, and `grade.sh` names which test is required. A test that
  legitimately skips (for example because it needs a patched toolchain) must not count towards
  the expected test total.
- Scan logs for environment signatures (out of disk, killed, offline or fetch failures) before
  treating a failure as the solution's fault, so they exit 2.
- Pin tool versions to what the repo's own CI uses: a newer tool can hide the bug.
- Restore test files from the base commit before applying the test patch.
- Fetch only the base commit into the image.
- Network, in `task.toml`:
  - `[environment] network_mode = "public"`, so `agent.setup()` can install the agent.
  - `[agent] network_mode = "allowlist"` with the model API hosts in `allowed_hosts`, so it can't
    fetch the merged fix.
  - `[verifier] network_mode = "no-network"`.

  Harbor applies the phase policy to every agent, oracle and nop included. On Docker, any
  `[agent]` or `[verifier]` override needs the nftables sidecar for them too, and on a runtime
  without it the trial raises an error. Only a real agent's API traffic stays unproven. If the
  local runtime can't run these policies, record that, validate the image with the phase
  overrides removed in a throwaway copy, and say so in the report.

## 3. Validate

`nice -n 10 env CARGO_BUILD_JOBS=2 bash <evals_dir>/scripts/validate.sh <name>`.

1. For every failing case read WHY it failed. A wrong fix must fail at the check it was written
   to trigger, not somewhere else.
2. Then the two opposite checks. A correct alternative must pass. If the upstream test rejects
   a correct alternative, loosen the grader and record that in the report.
3. Grader validation runs on the host toolchain, so before building the image list what the tests
   actually need: search for `RUSTUP_TOOLCHAIN`, `nightly`, `-Zbuild-std` and similar, and read
   the repo's CI job. Install all of it in the Dockerfile, including under the exact toolchain
   name the tests hardcode. The agent and the verifier must get the same tools from PATH: don't
   rely on sourcing an env script only in `test.sh`.

Two levels. The report and the inbox item state each one as run or not run, and anything less
than the first is reported as not validated, naming what wasn't run.

- **Grader validated**: `scripts/validate.sh <name>` exits 0 with no case filter. The script
  itself refuses a task lacking oracle, nop, at least one `flawed-*` and at least one `alt-*`.
- **Image validated**: `harbor run -p tasks/<name> -a oracle` scores 1 and
  `harbor run -p tasks/<name> -a nop` scores 0, using `uvx --from harbor harbor` when `harbor`
  isn't on PATH. A Docker client that doesn't answer makes this not run; it doesn't block the
  draft.

A task isn't a finished example until it is image validated. The two levels don't prove a real
agent can run the task. An agent smoke run stays Pedro's call, because it costs money.

## Hard limits

- Never run paid agents (claude-code, codex, or Rosalbito against a task) from a patrol or from
  `/rosalbito eval`.
- Never push or publish `<evals_dir>`.
- Check `df -h <evals_dir>` before building. If free disk is under twice the build's size, or a
  machine limit blocks a draft, record it in the chat report and skip the draft, with no inbox
  item about the machine (inbox.md, "Not inbox items").
- Run heavy builds at low priority (`nice`, `CARGO_BUILD_JOBS=2`).

## 4. Commit, then hand off

Write `reports/<name>.md`, then commit the draft with `validation/<name>/results.tsv` included, so
the repo is clean for the next draft. Only then add one `decide` item per draft, P2. Nothing else
goes in the inbox for it.

```bash
bash SKILL_DIR/scripts/inbox.sh add --kind decide --priority P2 --repo <owner/name> \
  --link <abs path to reports/<name>.md> --source <same path> \
  --title "Eval draft: <owner/name>#<number>" <<'EOF_ITEM'
<body>
EOF_ITEM
```

Titles start `Eval draft:`. `--link` is the report path, never the PR URL: `inbox.sh refresh`
archives an item whose linked GitHub thread is closed, and this PR is already merged. The body, in
order:

1. The required `## In plain words` section (inbox.md).
2. The question "Keep, fix or drop this eval?", the recommendation and why, and what Keep does:
   it closes the item, the draft stays on the eval repo's local `main`, and nothing is published.
3. The prompt text, verbatim.
4. The validation table, with grader validated and image validated each as run or not run.
5. The grader decisions that need Pedro's judgment.
6. What wasn't run.
7. Absolute paths (task, validation, report) and the source PR URL.

