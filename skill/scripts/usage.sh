#!/usr/bin/env bash
# usage.sh — model usage, spawned agents and estimated API cost of one run, read after the
# fact from Claude Code's own transcripts (the model never counts its own tokens)
#
#   usage.sh --run-id <id> --start <iso> [--end <iso>] [--sessions a,b]
#
# Roles: a description that starts with `[role]` (e.g. `[review:security] ...`) is taken as
# is; otherwise the role is inferred from the description's wording.
# Sessions: the ids given, plus every top-level transcript that printed `run_id=<id>`
# (init-run.sh) or `run_id: <id>` (state.sh show). Only messages inside [start, end+10m]
# count, so a session that hosted several runs is split by time. Subagents come from
# <session>/subagents/agent-*.jsonl and their .meta.json (description, type, depth).
# Subagent transcripts often keep only the streaming-start usage (stop_reason null): input
# and cache counts are exact, output is then estimated as max(reported, chars/4) of the
# visible content and counted in output_estimated_messages (hidden thinking is not seen).
# Transcripts: $CLAUDE_PROJECTS_DIR (default ~/.claude/projects). Prices: config/pricing.json.
# Prints one JSON object: {sessions, agents:[...], totals}.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
[ "${1:-}" = "--help" ] && { sed -n '2,17p' "$0"; exit 0; }

RUN_ID=""; START=""; END=""; SESSIONS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run-id) RUN_ID="$2"; shift 2;;
    --start) START="$2"; shift 2;;
    --end) END="$2"; shift 2;;
    --sessions) SESSIONS="$2"; shift 2;;
    *) die "unknown arg $1";;
  esac
done
[ -n "$RUN_ID" ] && [ -n "$START" ] || die "usage: usage.sh --run-id <id> --start <iso> [--end <iso>] [--sessions a,b]"
PROJ="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
PRICING="$SKILL_DIR/config/pricing.json"
end_e="$(iso_to_epoch "${END:-$(now_iso)}")"; end_e="${end_e:-$(date +%s)}"
END_SLACK="$(epoch_to_iso $((end_e + 600)))"
# transcript timestamps carry milliseconds: start one second early so `…:05.120Z` >= start
start_e="$(iso_to_epoch "$START")"; [ -n "$start_e" ] && START="$(epoch_to_iso $((start_e - 1)))"

files="$(
  for s in ${SESSIONS//,/ }; do ls "$PROJ"/*/"$s".jsonl 2>/dev/null; done
  grep -l -E "run_id(=|: )$RUN_ID" "$PROJ"/*/*.jsonl 2>/dev/null
)"
files="$(printf '%s\n' "$files" | sed '/^$/d' | sort -u)"

records="$(mktemp)"; metas="$(mktemp)"; trap 'rm -f "$records" "$metas"' EXIT
SEL='select(.type=="assistant" and .message.usage != null and .timestamp >= $s and .timestamp <= $e)
  | {sess:$sess, agent:(if .isSidechain == true then (.agentId // "sidechain") else $agent end),
     id:(.message.id // .uuid), ts:.timestamp, model:(.message.model // "unknown"), u:.message.usage,
     final:(.message.stop_reason != null),
     chars:([.message.content[]? | if .type=="text" then (.text|length) elif .type=="tool_use" then (.input|tostring|length) else 0 end] | add // 0),
     tools:[.message.content[]? | select(.type=="tool_use") | .name]}'
echo '{}' > "$metas"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  sid="$(basename "$f" .jsonl)"
  jq -c --arg s "$START" --arg e "$END_SLACK" --arg sess "$sid" --arg agent main "$SEL" "$f" 2>/dev/null >> "$records"
  for sf in "${f%.jsonl}"/subagents/agent-*.jsonl; do
    [ -f "$sf" ] || continue
    aid="$(basename "$sf" .jsonl)"; aid="${aid#agent-}"
    jq -c --arg s "$START" --arg e "$END_SLACK" --arg sess "$sid" --arg agent "$aid" "$SEL | .agent = \$agent" "$sf" 2>/dev/null >> "$records"
    meta="${sf%.jsonl}.meta.json"
    [ -f "$meta" ] && jq -c --arg a "$aid" '{($a): .}' "$meta" 2>/dev/null >> "$metas"
  done
done <<< "$files"

jq -s -c --slurpfile pricing "$PRICING" --slurpfile metas <(jq -s 'add' "$metas") \
  --argjson sessions "$(printf '%s\n' "$files" | sed '/^$/d' | xargs -n1 basename 2>/dev/null | sed 's/\.jsonl$//' | jq -R . | jq -s .)" '
  ($pricing[0].models) as $P | ($metas[0] // {}) as $M |
  def price($m): [$P | to_entries[] | select(.key as $k | $m | startswith($k))] | sort_by(.key|length) | last | .value;
  def cw5($u): if $u.cache_creation then ($u.cache_creation.ephemeral_5m_input_tokens // 0) else ($u.cache_creation_input_tokens // 0) end;
  def cw1($u): $u.cache_creation.ephemeral_1h_input_tokens // 0;
  def cost($r): price($r.model) as $p | if $p == null then 0 else
      ((($r.u.input_tokens // 0) * $p.input) + (($r.u.output_tokens // 0) * $p.output)
       + (cw5($r.u) * $p.cache_write_5m) + (cw1($r.u) * $p.cache_write_1h)
       + (($r.u.cache_read_input_tokens // 0) * $p.cache_read)) / 1e6
      * (if $r.u.speed == "fast" then ($p.fast_multiplier // 1) else 1 end) end;
  def role: (.description | ascii_downcase) as $d |
    if .agent_id == "main" then "orchestrator"
    elif ($d | test("^\\[[a-z:-]+\\]")) then ($d | capture("^\\[(?<r>[a-z:-]+)\\]").r)
    elif ($d | test("^(implement|fix|build|add|refactor|migrat)")) then "implementer"
    elif ($d | test("secur")) then "review:security"
    elif ($d | test("architect")) then "review:architecture"
    elif ($d | test("correct")) then "review:correctness"
    elif ($d | test("review|audit|verif")) then "review:other"
    elif ($d | test("debug|diagnos|root.cause")) then "debugger"
    elif .agent_type == "Explore" or ($d | test("understand|explor|research|investigat|map ")) then "explorer"
    elif ($d | test("implement|fix|build|write|add |refactor|migrat")) then "implementer"
    elif .agent_type == "Plan" or ($d | test("plan")) then "planner"
    elif ($d | test("^w[0-9]|author|draft|spec|readme|docs?\\b")) then "writer"
    elif ($d | test("test")) then "tester"
    else "other" end;
  def sumk(f): map(f) | add // 0;
  (group_by([.sess, .agent]) | map(
     .[0] as $f | ($M[$f.agent] // {}) as $meta |
     (group_by(.id) | map(
        (map(.chars) | add) as $chars | (map(select(.final)) | length > 0) as $final | max_by(.u.output_tokens // 0)
        | if $final then .est = false else .est = true | .u.output_tokens = ([(.u.output_tokens // 0), (($chars / 4) | ceil)] | max) end
      )) as $msgs |
     {session: $f.sess, agent_id: $f.agent,
      description: (if $f.agent == "main" then "orchestrator (main session)" else ($meta.description // "") end),
      agent_type: (if $f.agent == "main" then "main" else ($meta.agentType // "unknown") end),
      depth: (if $f.agent == "main" then 0 else ($meta.spawnDepth // 1) end),
      background: (($meta.requestShape // "") == "background"),
      models: ($msgs | map(.model) | unique),
      messages: ($msgs | length),
      first_ts: (map(.ts) | min), last_ts: (map(.ts) | max),
      input_tokens: ($msgs | sumk(.u.input_tokens // 0)),
      output_tokens: ($msgs | sumk(.u.output_tokens // 0)),
      output_estimated_messages: ($msgs | map(select(.est)) | length),
      cache_write_tokens: ($msgs | sumk(cw5(.u) + cw1(.u))),
      cache_read_tokens: ($msgs | sumk(.u.cache_read_input_tokens // 0)),
      cost_usd: ($msgs | map(cost(.)) | add // 0),
      cost_by_kind: {
        input: ($msgs | map(price(.model) as $p | if $p then (.u.input_tokens // 0) * $p.input / 1e6 else 0 end) | add // 0),
        output: ($msgs | map(price(.model) as $p | if $p then (.u.output_tokens // 0) * $p.output / 1e6 else 0 end) | add // 0),
        cache_write: ($msgs | map(price(.model) as $p | if $p then (cw5(.u) * $p.cache_write_5m + cw1(.u) * $p.cache_write_1h) / 1e6 else 0 end) | add // 0),
        cache_read: ($msgs | map(price(.model) as $p | if $p then (.u.cache_read_input_tokens // 0) * $p.cache_read / 1e6 else 0 end) | add // 0)},
      tools: ([.[].tools[]] | group_by(.) | map({key: .[0], value: length}) | from_entries)}
     | .role = role)) as $agents |
  {sessions: $sessions,
   agents: ($agents | sort_by(.first_ts)),
   totals: {
     agents_spawned: ($agents | map(select(.agent_id != "main")) | length),
     max_depth: ($agents | map(.depth) | max // 0),
     messages: ($agents | sumk(.messages)),
     input_tokens: ($agents | sumk(.input_tokens)),
     output_tokens: ($agents | sumk(.output_tokens)),
     output_estimated_messages: ($agents | sumk(.output_estimated_messages)),
     cache_write_tokens: ($agents | sumk(.cache_write_tokens)),
     cache_read_tokens: ($agents | sumk(.cache_read_tokens)),
     cost_usd: ($agents | sumk(.cost_usd)),
     cache_hit_ratio: (($agents | sumk(.cache_read_tokens)) as $r | ($agents | sumk(.cache_write_tokens + .input_tokens)) as $w
                       | if ($r + $w) > 0 then $r / ($r + $w) else null end),
     cost_by_role: ($agents | group_by(.role) | map({key: .[0].role, value: (map(.cost_usd) | add)}) | from_entries),
     unpriced_models: ([$agents[].models[]] | unique | map(select(. as $m | price($m) == null and $m != "<synthetic>"))),
     pricing_as_of: $pricing[0].as_of}}' "$records"
