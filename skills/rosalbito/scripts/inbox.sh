#!/usr/bin/env bash
# inbox.sh — the cross-session inbox: what is waiting on Pedro (see references/inbox.md)
#
#   inbox.sh add --kind <k> --title "<t>" [--link <url>] [--repo <owner/name>]
#                [--priority P0..P3] [--waiting pedro|upstream] [--source <path>]
#                [--session <name>]          body (what Pedro must do) from stdin
#   inbox.sh list [--all] [--tsv]          open items, highest priority first
#   inbox.sh set <id> <key> <value>        e.g. set <id> status done
#   inbox.sh show <id>                     print one item
#   inbox.sh path                          print the inbox directory
#
# kinds: review-comment | ship-pr | decide | read. An open item with the same --link is
# updated in place instead of duplicated. ROSALBITO_INBOX overrides the directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INBOX_DIR="${ROSALBITO_INBOX:-$HOME/Projects/obsidian-vault/oss/inbox}"
KINDS="review-comment ship-pr decide read"

cmd="${1:-list}"; shift || true
[ "$cmd" = "--help" ] && { sed -n '2,13p' "$0"; exit 0; }
[ "$cmd" = "path" ] && { echo "$INBOX_DIR"; exit 0; }

# frontmatter value verbatim: unlike yaml_scalar, keeps '#' (titles say "#8484") and unescapes \"
field() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed -e 's/^"\(.*\)"$/\1/' -e 's/\\"/"/g'
}

item_file() { local f="$INBOX_DIR/$1.md"; [ -f "$f" ] || die "no inbox item '$1' in $INBOX_DIR"; echo "$f"; }

# set a frontmatter scalar in an item (same approach as state.sh)
set_key() {
  local file="$1" key="$2" value="$3" tmp="$1.tmp.$$" esc
  esc=$(printf '%s' "$value" | sed -e 's/[\/&|]/\\&/g')
  awk -v key="$key" -v val="$esc" '
    BEGIN{fm=0; done=0}
    /^---$/ {fm++; if(fm==2 && !done){print key": "val; done=1} print; next}
    fm==1 && !done && $0 ~ "^"key":" {print key": "val; done=1; next}
    {print}
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

default_priority() {
  case "$1" in review-comment|ship-pr|decide) echo P1 ;; *) echo P3 ;; esac
}

kind_rank() {  # tie-break inside a priority: someone waiting on a reply beats our own shipping
  case "$1" in review-comment) echo 1 ;; ship-pr) echo 2 ;; decide) echo 3 ;; *) echo 4 ;; esac
}

case "$cmd" in
  add)
    kind="" title="" link="" repo="" prio="" waiting="pedro" src="" session="${CLAUDE_SESSION_NAME:-}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) kind="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --link) link="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --priority) prio="$2"; shift 2 ;;
        --waiting) waiting="$2"; shift 2 ;;
        --source) src="$2"; shift 2 ;;
        --session) session="$2"; shift 2 ;;
        *) die "add: unknown flag $1" ;;
      esac
    done
    [ -n "$kind" ] && [ -n "$title" ] || die "add: --kind and --title are required"
    case " $KINDS " in *" $kind "*) ;; *) die "add: kind must be one of: $KINDS" ;; esac
    prio="${prio:-$(default_priority "$kind")}"
    case "$prio" in P0|P1|P2|P3) ;; *) die "add: priority must be P0..P3" ;; esac
    body=""; [ -t 0 ] || body="$(cat)"
    mkdir -p "$INBOX_DIR"

    # same link already open -> refresh it instead of adding a duplicate
    if [ -n "$link" ]; then
      for f in "$INBOX_DIR"/*.md; do
        [ -f "$f" ] || continue
        [ "$(field "$f" link)" = "$link" ] && [ "$(yaml_scalar "$f" status)" = "open" ] || continue
        set_key "$f" title "$title"; set_key "$f" priority "$prio"; set_key "$f" waiting "$waiting"
        set_key "$f" updated "$(now_iso)"
        [ -n "$body" ] && printf '\n## Update %s\n\n%s\n' "$(now_iso)" "$body" >> "$f"
        basename "$f" .md; exit 0
      done
    fi

    slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-50 | sed 's/-$//')
    id="$(date -u +%Y%m%d)-$slug"; n=2
    while [ -e "$INBOX_DIR/$id.md" ]; do id="$(date -u +%Y%m%d)-$slug-$n"; n=$((n+1)); done
    {
      echo "---"
      echo "kind: $kind"
      echo "status: open"
      echo "priority: $prio"
      echo "waiting: $waiting"
      echo "title: \"$(printf '%s' "$title" | sed 's/"/\\"/g')\""
      echo "repo: $repo"
      echo "link: $link"
      echo "source: $src"
      echo "session: $session"
      echo "created: $(now_iso)"
      echo "updated: $(now_iso)"
      echo "---"
      echo
      [ -n "$body" ] && echo "$body"
    } > "$INBOX_DIR/$id.md"
    echo "$id"
    ;;

  list)
    all=0 tsv=0
    for a in "$@"; do case "$a" in --all) all=1 ;; --tsv) tsv=1 ;; *) die "list: unknown flag $a" ;; esac; done
    [ -d "$INBOX_DIR" ] || { [ $tsv -eq 1 ] || echo "inbox empty ($INBOX_DIR)"; exit 0; }
    rows=$(for f in "$INBOX_DIR"/*.md; do
      [ -f "$f" ] || continue
      st=$(yaml_scalar "$f" status); [ $all -eq 1 ] || [ "$st" = "open" ] || continue
      k=$(yaml_scalar "$f" kind)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(yaml_scalar "$f" priority)" "$(kind_rank "$k")" "$(yaml_scalar "$f" created)" \
        "$(basename "$f" .md)" "$k" "$st" "$(yaml_scalar "$f" waiting)" "$(field "$f" title)" "$(field "$f" link)"
    done | sort -t$'\t' -k1,1 -k2,2n -k3,3)
    [ -n "$rows" ] || { [ $tsv -eq 1 ] || echo "inbox empty ($INBOX_DIR)"; exit 0; }
    if [ $tsv -eq 1 ]; then
      printf '%s\n' "$rows" | cut -f1,4-9
    else
      printf '%s\n' "$rows" | awk -F'\t' '{printf "%s  %-15s %-8s %s\n      id=%s%s\n", $1, $5, ($7=="upstream"?"[upstr]":""), $8, $4, ($9!=""?"  "$9:"")}'
    fi
    ;;

  set)
    [ $# -eq 3 ] || die "usage: inbox.sh set <id> <key> <value>"
    f=$(item_file "$1"); set_key "$f" "$2" "$3"; set_key "$f" updated "$(now_iso)"
    ;;

  show)
    [ $# -eq 1 ] || die "usage: inbox.sh show <id>"
    cat "$(item_file "$1")"
    ;;

  *) die "unknown command '$cmd' (see --help)" ;;
esac
