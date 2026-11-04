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

