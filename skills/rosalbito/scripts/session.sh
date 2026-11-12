#!/usr/bin/env bash
# session.sh — remember a Claude Code session so a later one can pick its work back up
# (see references/sessions.md)
#
#   session.sh save --title "<t>" [--repo <owner/name>] [--items <id>...] [--watch <url>...]
#                                          body (what happened, what's open) from stdin; one
#                                          record per session id, saved again = updated in place.
#                                          --items get a `context:` link back to the record, and
#                                          their watched threads join the record's watch list
#   session.sh find [--brief] <github url | owner/name | text>
#                                          records about that thread / repo / text, newest first
#   session.sh list                        all records, newest first
#   session.sh resume <id>                 the command that reopens that session
#   session.sh show <id> | path
#
# Records live in sessions/, a sibling of the inbox (ROSALBITO_INBOX overrides it).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INBOX_DIR="${ROSALBITO_INBOX:-$HOME/Projects/obsidian-vault/oss/inbox}"
SESS_DIR="$(dirname "$INBOX_DIR")/sessions"
INBOX="$(dirname "${BASH_SOURCE[0]}")/inbox.sh"

die() { echo "session.sh: $*" >&2; exit 1; }
field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed -e 's/^"\(.*\)"$/\1/' -e 's/\\"/"/g'; }
set_key() {  # set_key <file> <key> <value>: replace or append inside the frontmatter
  local file="$1" key="$2" tmp="$1.tmp.$$" esc
  esc=$(printf '%s' "$3" | sed -e 's/[\/&|]/\\&/g')
  awk -v key="$key" -v val="$esc" '
    BEGIN { n = 0; done = 0 }
    /^---$/ { n++; if (n == 2 && !done) { print key ": " val; done = 1 } print; next }
    n == 1 && index($0, key ": ") == 1 && !done { print key ": " val; done = 1; next }
    { print }' "$file" > "$tmp"
  mv "$tmp" "$file"
}
# a github issue/pr url -> "owner/name number"
thread_of() { printf '%s' "$1" | sed -nE 's#^https://github.com/([^/]+/[^/]+)/(pull|issues)/([0-9]+).*#\1 \3#p'; }
resume_cmd() { printf 'cd %q && claude --resume %s' "$(field "$1" cwd)" "$(field "$1" session_id)"; }
newest_first() { for f in "$SESS_DIR"/*.md; do [ -f "$f" ] && printf '%s\t%s\n' "$(field "$f" updated)" "$f"; done | sort -r | cut -f2; }
rec_file() { [ -f "$SESS_DIR/$1.md" ] && echo "$SESS_DIR/$1.md" || die "no session record '$1' in $SESS_DIR"; }

cmd="${1:-list}"; shift || true
case "$cmd" in
  --help|-h) sed -n '2,17p' "$0" ;;
  path) echo "$SESS_DIR" ;;

  save)
    title="" repo="" items="" watch=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --items) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do items="$items $1"; shift; done ;;
        --watch) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do watch="$watch $1"; shift; done ;;
        *) die "save: unknown argument $1" ;;
      esac
    done
    [ -n "$title" ] || die "save: --title is required"
    sid="${CLAUDE_CODE_SESSION_ID:-}"; [ -n "$sid" ] || die "save: CLAUDE_CODE_SESSION_ID is not set (run inside Claude Code)"
    body="$(cat)"
    printf '%s\n' "$body" | grep >/dev/null '^## In plain words' || die "save: the body must start with a '## In plain words' section"
    mkdir -p "$SESS_DIR"
    f=""
    for g in "$SESS_DIR"/*.md; do [ -f "$g" ] && [ "$(field "$g" session_id)" = "$sid" ] && { f="$g"; break; }; done
    created="$(now_iso)"
    if [ -n "$f" ]; then  # saved again: keep the id and creation time, merge the lists
      created="$(field "$f" created)"; items="$(field "$f" items) $items"; watch="$(field "$f" watch) $watch"
      [ -n "$repo" ] || repo="$(field "$f" repo)"
    else
      slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-50 | sed 's/-$//')
      id="$(date -u +%Y%m%d)-$slug"; n=2
      while [ -e "$SESS_DIR/$id.md" ]; do id="$(date -u +%Y%m%d)-$slug-$n"; n=$((n+1)); done
      f="$SESS_DIR/$id.md"
    fi
    # each item: link it back here, and follow the threads it watches
    for i in $items; do
      p=$(bash "$INBOX" set "$i" context "$f" 2>/dev/null && bash "$INBOX" show "$i") || { echo "session.sh: no inbox item '$i', skipped" >&2; continue; }
      watch="$watch $(printf '%s\n' "$p" | sed -n 's/^watch: //p;s/^link: //p' | head -2 | tr '\n' ' ')"
    done
    items=$(printf '%s\n' $items | awk 'NF && !seen[$0]++' | tr '\n' ' ' | sed 's/ $//')
    watch=$(printf '%s\n' $watch | sed 's/#.*//' | grep '^https://' | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//' || true)
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    {
      echo "---"
      echo "kind: session"
      echo "title: \"$(printf '%s' "$title" | sed 's/"/\\"/g')\""
      echo "session_id: $sid"
      echo "cwd: $PWD"
      echo "branch: $branch"
      echo "repo: $repo"
      echo "items: $items"
      echo "watch: $watch"
      echo "created: $created"
      echo "updated: $(now_iso)"
      echo "---"
      echo
      printf '%s\n' "$body"
      echo
      echo "## Resume"
      echo '```'
      printf 'cd %q && claude --resume %s\n' "$PWD" "$sid"
      echo '```'
    } > "$f.tmp.$$" && mv "$f.tmp.$$" "$f"
    basename "$f" .md
    ;;

  find)
    brief=0; [ "${1:-}" = "--brief" ] && { brief=1; shift; }
    [ $# -eq 1 ] || die "usage: session.sh find [--brief] <github url | owner/name | text>"
    t=$(thread_of "$1")
    if [ -n "$t" ]; then  # the same thread, whether linked as pull/ or issues/, with or without a fragment
      pat="github\.com/${t% *}/(pull|issues)/${t#* }([^0-9]|$)"
    else
      pat=$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g')
    fi
    for f in $(newest_first); do
      grep -Eiq -- "$pat" "$f" || continue
      if [ $brief -eq 1 ]; then
        printf -- '- "%s" (%s): `%s`; resume: `%s`\n' "$(field "$f" title)" "$(field "$f" updated | cut -c1-10)" "$f" "$(resume_cmd "$f")"
      else
        printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$(field "$f" updated | cut -c1-10)" "$(field "$f" title)"
      fi
    done
    ;;

  list)
    [ -d "$SESS_DIR" ] || { echo "no session records"; exit 0; }
    for f in $(newest_first); do printf '%s\t%s\t%s\n' "$(basename "$f" .md)" "$(field "$f" updated | cut -c1-10)" "$(field "$f" title)"; done
    ;;

  resume) [ $# -eq 1 ] || die "usage: session.sh resume <id>"; resume_cmd "$(rec_file "$1")"; echo ;;
  show)   [ $# -eq 1 ] || die "usage: session.sh show <id>"; cat "$(rec_file "$1")" ;;
  *) die "unknown command '$cmd' (save | find | list | resume | show | path)" ;;
esac
