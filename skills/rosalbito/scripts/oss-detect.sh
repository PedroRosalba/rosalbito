#!/usr/bin/env bash
# oss-detect.sh — is this an OSS repo Pedro contributes to? (config/oss.yaml, references/oss.md)
#
#   oss-detect.sh [dir]     print key=value lines; exit 0 in OSS mode, 1 otherwise
#
# oss=1|0  upstream=<owner/name>  vault_dir=<abs>  inbox=<abs>  git_identity=<name <email>>
# identity_ok=1|0 (git user.email in dir matches git_identity). Remote named `upstream` wins.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[ "${1:-}" = "--help" ] && { sed -n '2,7p' "$0"; exit 0; }
DIR="$(cd "${1:-.}" && pwd -P)"
CFG="$(config_file oss.yaml)"
[ -f "$CFG" ] || { echo "oss=0"; exit 1; }

expand() { case "$1" in "~"*) echo "$HOME${1#\~}" ;; *) echo "$1" ;; esac; }
section() {  # section <name>: "key<TAB>value" pairs of an indented yaml map
  awk -v s="$1" '
    /^[^[:space:]#][^:]*:/ { in_s = ($0 ~ "^"s":") ; next }
    in_s && /^[[:space:]]+[^#[:space:]]/ {
      line=$0; sub(/#.*/, "", line); sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      k=line; sub(/:[[:space:]].*$/, "", k); v=line; sub(/^[^:]*:[[:space:]]*/, "", v)
      if (k != "" && v != "") print k "\t" v
    }' "$CFG"
}

vault="$(expand "$(yaml_scalar "$CFG" vault)")"
inbox_rel="$(yaml_scalar "$CFG" inbox)"
ident="$(yaml_scalar "$CFG" git_identity)"

# GitHub owner/name of each remote, `upstream` first
remotes=""
if git -C "$DIR" rev-parse >/dev/null 2>&1; then
  remotes=$(git -C "$DIR" remote -v 2>/dev/null | awk '$3=="(fetch)"{print ($1=="upstream"?0:1) "\t" $2}' | sort -n | cut -f2 \
    | sed -n -e 's#^.*github\.com[:/]\([^/]*\)/\([^/ ]*\)$#\1/\2#p' | sed 's/\.git$//')
fi

upstream="" folder=""
for r in $remotes; do
  while IFS=$'\t' read -r pat dirname; do
    # shellcheck disable=SC2254
    case "$r" in $pat) upstream="$r"; folder="$dirname"; break 2 ;; esac
  done < <(section repos)
done
if [ -z "$folder" ]; then
  while IFS=$'\t' read -r p dirname; do
    p="$(expand "$p")"; [ -d "$p" ] && p="$(cd "$p" && pwd -P)"
    case "$DIR/" in "$p"/*) folder="$dirname"; break ;; esac
  done < <(section paths)
fi

[ -n "$folder" ] || { echo "oss=0"; exit 1; }
email="$(git -C "$DIR" config user.email 2>/dev/null || true)"
want_email="$(printf '%s' "$ident" | sed -n 's/.*<\(.*\)>.*/\1/p')"
echo "oss=1"
echo "upstream=$upstream"
echo "vault_dir=$vault/$folder"
echo "inbox=$vault/$inbox_rel"
echo "git_identity=$ident"
echo "identity_ok=$([ -z "$want_email" ] || [ "$email" = "$want_email" ] && echo 1 || echo 0)"
