#!/usr/bin/env bash
# inbox.sh — what is waiting on Pedro, and what is waiting on upstream (see references/inbox.md)
#
#   inbox.sh add --kind <k> --title "<t>" [--link <url>] [--repo <owner/name>]
#                [--priority P0..P3] [--source <path>] [--session <name>]
#                                          body (what Pedro must do) from stdin
#   inbox.sh watch [<id> | --title "<t>" [--repo r] [--source p]] [--then "<plan>"] <url>...
#                                          follow someone else's PR/issue instead of competing:
#                                          archived when it closes, an @mention -> inbox; with
#                                          --then, its closing raises a decide item for the plan
#   inbox.sh list [--outbox|--watch|--archive|--all] [--tsv]
#                                          default: inbox (waiting on Pedro), by priority
#   inbox.sh posted <id> <url>...          posted upstream: move to outbox, watch the threads
#   inbox.sh close <id> <outcome>          finished: move to archive (outcome e.g. merged,
#                                          closed, answered, dropped, expired)
#   inbox.sh refresh [--dry-run]           check GitHub: archive what was merged/closed, turn
#                                          replies on our posts into inbox items, expire reads
#   inbox.sh set <id> <key> <value> | show <id> | path
#
# Folders (siblings): inbox/ waiting on Pedro · outbox/ posted, waiting on upstream ·
# watch/ others' threads we follow · archive/ finished. kinds: review-comment | ship-pr | decide | read. An inbox item with the
# same --link is updated in place. ROSALBITO_INBOX overrides the inbox directory.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

INBOX_DIR="${ROSALBITO_INBOX:-$HOME/Projects/obsidian-vault/oss/inbox}"
OUTBOX_DIR="$(dirname "$INBOX_DIR")/outbox"
WATCH_DIR="$(dirname "$INBOX_DIR")/watch"
ARCHIVE_DIR="$(dirname "$INBOX_DIR")/archive"
KINDS="review-comment ship-pr decide read"
READ_TTL_DAYS="${ROSALBITO_READ_TTL_DAYS:-14}"

cmd="${1:-list}"; shift || true
[ "$cmd" = "--help" ] && { sed -n '2,23p' "$0"; exit 0; }
[ "$cmd" = "path" ] && { echo "$INBOX_DIR"; exit 0; }

# frontmatter value verbatim: unlike yaml_scalar, keeps '#' (titles say "#8484") and unescapes \"
field() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed -e 's/^"\(.*\)"$/\1/' -e 's/\\"/"/g'
}

item_file() {
  local d
  for d in "$INBOX_DIR" "$OUTBOX_DIR" "$WATCH_DIR" "$ARCHIVE_DIR"; do [ -f "$d/$1.md" ] && { echo "$d/$1.md"; return; }; done
  die "no item '$1' in $INBOX_DIR, $OUTBOX_DIR, $WATCH_DIR or $ARCHIVE_DIR"
}

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

move_to() { mkdir -p "$2"; [ "$(dirname "$1")" = "$2" ] || mv "$1" "$2/"; }

close_item() {  # close_item <file> <outcome>
  set_key "$1" status "$([ "$2" = dropped ] && echo dropped || echo done)"
  set_key "$1" outcome "$2"; set_key "$1" closed "$(now_iso)"; set_key "$1" updated "$(now_iso)"
  move_to "$1" "$ARCHIVE_DIR"
}

default_priority() {
  case "$1" in review-comment|ship-pr|decide) echo P1 ;; *) echo P3 ;; esac
}

kind_rank() {  # tie-break inside a priority: someone waiting on a reply beats our own shipping
  case "$1" in review-comment) echo 1 ;; ship-pr) echo 2 ;; decide) echo 3 ;; *) echo 4 ;; esac
}

# https://github.com/o/r/pull/12#x -> "o/r 12" (issues too); nothing for other urls
thread_of() { printf '%s\n' "$1" | sed -En 's#^https://github\.com/([^/]+/[^/]+)/(pull|issues)/([0-9]+).*#\1 \3#p'; }

# urls -> deduplicated thread urls, fragments stripped (non-GitHub urls dropped)
watch_urls() {
  local u t w watch=""
  for u in "$@"; do
    t=$(thread_of "$u"); [ -n "$t" ] || continue
    w="https://github.com/${t% *}/$(case "$u" in */pull/*) echo pull ;; *) echo issues ;; esac)/${t#* }"
    case " $watch " in *" $w "*) ;; *) watch="${watch:+$watch }$w" ;; esac
  done
  echo "$watch"
}

# sessions that worked on a thread (session.sh records), as a section for a new item's body
session_context() {
  local s; s=$(bash "$(dirname "$0")/session.sh" find --brief "$1" 2>/dev/null | head -3) || true
  [ -z "$s" ] || printf '\n**Earlier sessions on this thread** (read the record before drafting; resume it for the full context):\n%s\n' "$s"
}

case "$cmd" in
  add)
    kind="" title="" link="" repo="" prio="" src="" session="${CLAUDE_SESSION_NAME:-}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --kind) kind="$2"; shift 2 ;;
        --title) title="$2"; shift 2 ;;
        --link) link="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --priority) prio="$2"; shift 2 ;;
        --waiting) shift 2 ;;  # accepted for old callers; the folder says who is waiting now
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

    # same link already in the inbox -> refresh it instead of adding a duplicate
    if [ -n "$link" ]; then
      for f in "$INBOX_DIR"/*.md; do
        [ -f "$f" ] || continue
        [ "$(field "$f" link)" = "$link" ] || continue
        set_key "$f" title "$title"; set_key "$f" priority "$prio"; set_key "$f" updated "$(now_iso)"
        [ -n "$body" ] && printf '\n## Update %s\n\n%s\n' "$(now_iso)" "$body" >> "$f"
        basename "$f" .md; exit 0
      done
    fi

    # every new item explains itself to a non-expert first (references/inbox.md §In plain words)
    printf '%s\n' "$body" | grep -q '^## In plain words' \
      || die "add: body must start with an '## In plain words' section (see references/inbox.md)"

    slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-50 | sed 's/-$//')
    id="$(date -u +%Y%m%d)-$slug"; n=2
    while [ -e "$INBOX_DIR/$id.md" ] || [ -e "$OUTBOX_DIR/$id.md" ] || [ -e "$WATCH_DIR/$id.md" ] || [ -e "$ARCHIVE_DIR/$id.md" ]; do
      id="$(date -u +%Y%m%d)-$slug-$n"; n=$((n+1))
    done
    {
      echo "---"
      echo "kind: $kind"
      echo "status: open"
      echo "priority: $prio"
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
    dirs="$INBOX_DIR" tsv=0 label="inbox"
    for a in "$@"; do
      case "$a" in
        --outbox) dirs="$OUTBOX_DIR" label="outbox" ;;
        --watch) dirs="$WATCH_DIR" label="watch" ;;
        --archive) dirs="$ARCHIVE_DIR" label="archive" ;;
        --all) dirs="$INBOX_DIR $OUTBOX_DIR $WATCH_DIR $ARCHIVE_DIR" label="all" ;;
        --tsv) tsv=1 ;;
        *) die "list: unknown flag $a" ;;
      esac
    done
    rows=$(for d in $dirs; do for f in "$d"/*.md; do
      [ -f "$f" ] || continue
      k=$(yaml_scalar "$f" kind)
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(yaml_scalar "$f" priority)" "$(kind_rank "$k")" "$(yaml_scalar "$f" created)" \
        "$(basename "$f" .md)" "$k" "$(yaml_scalar "$f" status)" "$(field "$f" activity)" "$(field "$f" title)" \
        "$(field "$f" posted)$( [ -z "$(field "$f" posted)" ] && field "$f" link)"
    done; done | sort -t$'\t' -k1,1 -k2,2n -k3,3)
    [ -n "$rows" ] || { [ $tsv -eq 1 ] || echo "$label empty"; exit 0; }
    if [ $tsv -eq 1 ]; then
      printf '%s\n' "$rows" | cut -f1,4-9
    else
      printf '%s\n' "$rows" | awk -F'\t' '{printf "%s  %-15s %-7s %s\n      id=%s%s%s\n", $1, $5, ($6=="open"?"":$6), $8, $4, ($9!=""?"  "$9:""), ($7!=""?"\n      activity: "$7:"")}'
    fi
    ;;

  posted)
    [ $# -ge 2 ] || die "usage: inbox.sh posted <id> <url>..."
    f=$(item_file "$1"); shift
    set_key "$f" status posted; set_key "$f" posted "$*"; set_key "$f" watch "$(watch_urls "$@")"
    set_key "$f" last_seen "$(now_iso)"; set_key "$f" updated "$(now_iso)"
    move_to "$f" "$OUTBOX_DIR"
    ;;

  watch)
    title="" repo="" src="" session="${CLAUDE_SESSION_NAME:-}" f="" plan=""
    case "${1:-}" in ""|--*|http*) ;; *) f=$(item_file "$1"); shift ;; esac
    while [ $# -gt 0 ]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --repo) repo="$2"; shift 2 ;;
        --source) src="$2"; shift 2 ;;
        --session) session="$2"; shift 2 ;;
        --then) plan="$2"; shift 2 ;;
        --*) die "watch: unknown flag $1" ;;
        *) break ;;
      esac
    done
    watch=$(watch_urls "$@")
    [ -n "$watch" ] || die "usage: inbox.sh watch [<id> | --title <t>] <github pr/issue url>..."
    if [ -z "$f" ]; then
      [ -n "$title" ] || die "watch: --title is required for a new watch"
      body=""; [ -t 0 ] || body="$(cat)"
      mkdir -p "$WATCH_DIR"
      for g in "$WATCH_DIR"/*.md; do  # already watching that thread -> refresh the title
        [ -f "$g" ] || continue
        [ "$(field "$g" link)" = "${watch%% *}" ] || continue
        set_key "$g" title "$title"; set_key "$g" updated "$(now_iso)"; basename "$g" .md; exit 0
      done
      slug=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-50 | sed 's/-$//')
      id="$(date -u +%Y%m%d)-$slug"; n=2
      while [ -e "$INBOX_DIR/$id.md" ] || [ -e "$OUTBOX_DIR/$id.md" ] || [ -e "$WATCH_DIR/$id.md" ] || [ -e "$ARCHIVE_DIR/$id.md" ]; do
        id="$(date -u +%Y%m%d)-$slug-$n"; n=$((n+1))
      done
      f="$WATCH_DIR/$id.md"
      {
        echo "---"
        echo "kind: watch"
        echo "status: watching"
        echo "priority: P3"
        echo "title: \"$(printf '%s' "$title" | sed 's/"/\\"/g')\""
        echo "repo: $repo"
        echo "link: ${watch%% *}"
        echo "source: $src"
        echo "session: $session"
        echo "created: $(now_iso)"
        echo "updated: $(now_iso)"
        echo "---"
        echo
        [ -n "$body" ] && echo "$body"
      } > "$f"
    fi
    set_key "$f" status watching; set_key "$f" watch "$watch"
    [ -z "$plan" ] || set_key "$f" then "$plan"
    set_key "$f" last_seen "$(now_iso)"; set_key "$f" updated "$(now_iso)"
    move_to "$f" "$WATCH_DIR"
    basename "$f" .md
    ;;

  close)
    [ $# -eq 2 ] || die "usage: inbox.sh close <id> <outcome>"
    close_item "$(item_file "$1")" "$2"
    ;;

  refresh)
    dry=0; [ "${1:-}" = "--dry-run" ] && dry=1
    me="${ROSALBITO_GH_LOGIN:-$(gh api user --jq .login)}"
    now="$(now_iso)"; ttl=$((READ_TTL_DAYS * 86400)); now_s=$(iso_to_epoch "$now")
    say() { echo "$*"; }

    # inbox: expire old reads; drop items whose thread upstream is already closed
    for f in "$INBOX_DIR"/*.md; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .md); k=$(yaml_scalar "$f" kind)
      c_s=$(iso_to_epoch "$(yaml_scalar "$f" created)" || echo "$now_s")
      if [ "$k" = read ] && [ $((now_s - c_s)) -gt $ttl ]; then
        say "expire  $id (read, older than ${READ_TTL_DAYS}d)"; [ $dry -eq 1 ] || close_item "$f" expired; continue
      fi
      t=$(thread_of "$(field "$f" link)"); [ -n "$t" ] || continue
      st=$(gh api "repos/${t% *}/issues/${t#* }" --jq '.state + " " + (.pull_request.merged_at // "")' 2>/dev/null) || continue
      case "$st" in closed*)
        o=$([ -n "${st#closed }" ] && echo upstream-merged || echo upstream-closed)
        say "close   $id ($o before we posted)"; [ $dry -eq 1 ] || close_item "$f" "$o" ;;
      esac
    done

    # outbox and watch: archive when the first watched thread closes; replies to us -> inbox
    for f in "$OUTBOX_DIR"/*.md "$WATCH_DIR"/*.md; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .md); since=$(yaml_scalar "$f" last_seen); title=$(field "$f" title)
      where=$([ "$(dirname "$f")" = "$WATCH_DIR" ] && echo "a thread we watch," || echo "where we posted")
      primary=1 closed_as="" others=0
      for w in $(field "$f" watch); do
        t=$(thread_of "$w"); or="${t% *}"; n="${t#* }"
        info=$(gh api "repos/$or/issues/$n" --jq '[.state, (.pull_request.merged_at // "-"), .user.login, (if .pull_request then "pr" else "issue" end)] | @tsv' 2>/dev/null) || { primary=0; continue; }
        IFS=$'\t' read -r state merged author typ <<<"$info"
        if [ $primary -eq 1 ] && [ "$state" = closed ]; then closed_as=$([ "$merged" != "-" ] && echo merged || echo closed); fi
        # replies since we last looked, not by us, not by bots
        q='.[] | select(((.created_at // .submitted_at) // "") > "'"$since"'") | select(.user.login != "'"$me"'") | select(.user.login | endswith("[bot]") | not)
           | [(.created_at // .submitted_at), .user.login, .html_url, ((.body // "") | test("@'"$me"'\\b"; "i") | tostring)] | @tsv'
        new=$( { gh api --paginate "repos/$or/issues/$n/comments" --jq "$q" 2>/dev/null
                 if [ "$typ" = pr ]; then gh api --paginate "repos/$or/pulls/$n/reviews" --jq "$q" 2>/dev/null
                                         gh api --paginate "repos/$or/pulls/$n/comments" --jq "$q" 2>/dev/null; fi; } | sort)
        if [ -n "$new" ]; then
          if [ "$author" = "$me" ]; then to_us="$new"; else to_us=$(printf '%s\n' "$new" | awk -F'\t' '$4=="true"'); fi
          other=$(( $(printf '%s\n' "$new" | grep -c .) - $(printf '%s' "$to_us" | grep -c . || true) ))
          others=$((others + other))
          if [ -n "$to_us" ]; then
            say "reply   $or#$n: $(printf '%s\n' "$to_us" | grep -c .) new for us -> inbox"
            [ $dry -eq 1 ] || printf '## In plain words\n- **What'"'"'s going on:** someone answered on %s#%s, %s "%s".\n- **What you'"'"'re deciding:** whether and how to reply. The coordinator reads the thread and drafts the exact reply first.\n\nNew replies since %s:\n\n%s\n%s' \
              "$or" "$n" "$where" "$title" "$since" "$(printf '%s\n' "$to_us" | awk -F'\t' '{print "- " $1 " @" $2 ": " $3}')" "$(session_context "$w")" \
              | bash "$0" add --kind review-comment --priority P1 --repo "$or" --link "$w" --source "$f" \
                  --title "Reply on $or#$n (re: $title)" >/dev/null
          fi
        fi
        primary=0
      done
      if [ $dry -eq 0 ]; then
        [ $others -gt 0 ] && set_key "$f" activity "$others new comment(s) not addressed to us since $since"
        set_key "$f" last_seen "$now"
      fi
      if [ -n "$closed_as" ]; then
        plan=$([ "$(dirname "$f")" = "$WATCH_DIR" ] && field "$f" then || true)
        if [ -n "$plan" ]; then
          w1=$(field "$f" link); t1=$(thread_of "$w1")
          say "plan    $id ($closed_as) -> inbox: $plan"
          [ $dry -eq 1 ] || printf '## In plain words\n- **What'"'"'s going on:** %s, which we were waiting on ("%s"), was %s.\n- **What you'"'"'re deciding:** whether to go ahead with what we planned for this moment: %s\n%s' \
            "${t1% *}#${t1#* }" "$title" "$closed_as" "$plan" "$(session_context "$w1")" \
            | bash "$0" add --kind decide --priority P2 --repo "${t1% *}" --link "$w1" --source "$f" \
                --title "${t1% *}#${t1#* } $closed_as: $plan" >/dev/null
        fi
        say "archive $id ($closed_as)"; [ $dry -eq 1 ] || close_item "$f" "$closed_as"
      fi
    done
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
