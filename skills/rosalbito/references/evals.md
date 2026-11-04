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

