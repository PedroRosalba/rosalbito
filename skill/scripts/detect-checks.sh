#!/usr/bin/env bash
# detect-checks.sh — print the deterministic checks this repo supports, one per line: <label>\t<command>
# Heuristic, by build files. Read .github/workflows too when present (printed as a note).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
have() { command -v "$1" >/dev/null 2>&1; }
found=0
emit() { printf '%s\t%s\n' "$1" "$2"; found=1; }

if [ -f Cargo.toml ]; then
  emit build "cargo build --all-targets"
  emit test  "cargo test"
  cargo clippy --version >/dev/null 2>&1 && emit lint "cargo clippy --all-targets -- -D warnings"
  cargo fmt --version >/dev/null 2>&1 && emit fmt "cargo fmt --check"
fi
if [ -f package.json ] && have jq; then
  pm=npm; [ -f pnpm-lock.yaml ] && pm=pnpm; [ -f yarn.lock ] && pm=yarn; [ -f bun.lockb ] || [ -f bun.lock ] && pm=bun
  for s in lint typecheck type-check check test build; do
    if jq -e --arg s "$s" '.scripts[$s] // empty' package.json >/dev/null 2>&1; then
      case "$s" in test) emit test "$pm run test";; build) emit build "$pm run build";; *) emit "$s" "$pm run $s";; esac
    fi
  done
fi
if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f pytest.ini ]; then
  have pytest && emit test "pytest -q"
  have ruff && emit lint "ruff check ."
  have mypy && [ -f mypy.ini -o -f pyproject.toml ] && emit typecheck "mypy ."
fi
if [ -f go.mod ]; then emit build "go build ./..."; emit vet "go vet ./..."; emit test "go test ./..."; fi
if [ -f Makefile ]; then
  for t in test lint check; do grep -qE "^$t:" Makefile && emit "make-$t" "make $t"; done
fi
if [ -d .github/workflows ]; then
  echo "# note: CI workflows present — read them for extra checks: $(ls .github/workflows | tr '\n' ' ')" >&2
fi
[ "$found" -eq 1 ] || echo "# no checks detected — define them in the acceptance contract" >&2
