#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║            RESONANCE.SH  — Universal AI Conversation Tree               ║
# ║  Turns linear AI chats into navigable knowledge trees in pure bash.     ║
# ║  Works with: OpenAI · Anthropic · DeepSeek · Ollama · Groq · Together   ║
# ║  Requirements: bash 4+, curl, jq                                        ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# QUICK START:
#   chmod +x resonance.sh
#   ./resonance.sh setup           ← configure your AI provider
#   ./resonance.sh                 ← launch interactive REPL
#   ./resonance.sh ask "Why is the sky blue?"   ← one-shot query
#
# NON-INTERACTIVE / PIPELINE:
#   echo "Explain recursion" | ./resonance.sh pipe
#   ./resonance.sh ask "Your question" --parent abc123 --save

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS & PATHS
# ─────────────────────────────────────────────────────────────────────────────
VERSION="1.0.0"
TREE_FILE="${RESONANCE_TREE:-resonance_tree.json}"
CONFIG_FILE="${RESONANCE_CONFIG:-$HOME/.resonance_config}"
LOG_FILE="resonance.log"
EXPORT_FILE="resonance_export.md"
MAX_PREVIEW=100
FOLD_THRESH=600
MAX_CONTEXT_TURNS=8

# ── ANSI colours (auto-disable if not a tty) ──────────────────────────────
if [ -t 1 ]; then
  R="\033[0m" ; BOLD="\033[1m" ; DIM="\033[2m"
  CYA="\033[96m" ; BLU="\033[94m" ; GRN="\033[92m"
  YEL="\033[93m" ; RED="\033[91m" ; PUR="\033[95m"
  WHT="\033[97m" ; GRY="\033[90m"
else
  R="" ; BOLD="" ; DIM="" ; CYA="" ; BLU="" ; GRN=""
  YEL="" ; RED="" ; PUR="" ; WHT="" ; GRY=""
fi

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCY CHECKS
# ─────────────────────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for dep in curl jq; do
    command -v "$dep" &>/dev/null || missing+=("$dep")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo -e "${RED}✗ Missing dependencies: ${missing[*]}${R}"
    echo -e "${DIM}  Install with:${R}"
    echo -e "    Ubuntu/Debian : sudo apt-get install ${missing[*]}"
    echo -e "    macOS         : brew install ${missing[*]}"
    echo -e "    Fedora/RHEL   : sudo dnf install ${missing[*]}"
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG  (stored in ~/.resonance_config as shell variables)
# ─────────────────────────────────────────────────────────────────────────────
load_config() {
  PROVIDER="openai"
  API_KEY=""
  AI_MODEL=""
  CUSTOM_URL=""
  [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
PROVIDER="${PROVIDER}"
API_KEY="${API_KEY}"
AI_MODEL="${AI_MODEL}"
CUSTOM_URL="${CUSTOM_URL}"
EOF
  chmod 600 "$CONFIG_FILE"
}

# Resolve endpoint and default model for each provider
get_provider_info() {
  case "$PROVIDER" in
    openai)    ENDPOINT="${CUSTOM_URL:-https://api.openai.com/v1/chat/completions}"
               DEFAULT_MODEL="gpt-4o-mini" ;;
    deepseek)  ENDPOINT="${CUSTOM_URL:-https://api.deepseek.com/v1/chat/completions}"
               DEFAULT_MODEL="deepseek-chat" ;;
    groq)      ENDPOINT="${CUSTOM_URL:-https://api.groq.com/openai/v1/chat/completions}"
               DEFAULT_MODEL="llama3-70b-8192" ;;
    together)  ENDPOINT="${CUSTOM_URL:-https://api.together.xyz/v1/chat/completions}"
               DEFAULT_MODEL="mistralai/Mixtral-8x7B-Instruct-v0.1" ;;
    anthropic) ENDPOINT="${CUSTOM_URL:-https://api.anthropic.com/v1/messages}"
               DEFAULT_MODEL="claude-3-haiku-20240307" ;;
    ollama)    ENDPOINT="${CUSTOM_URL:-http://localhost:11434/api/chat}"
               DEFAULT_MODEL="llama3" ;;
    xai)       ENDPOINT="${CUSTOM_URL:-https://api.x.ai/v1/chat/completions}"
               DEFAULT_MODEL="grok-beta" ;;
    mistral)   ENDPOINT="${CUSTOM_URL:-https://api.mistral.ai/v1/chat/completions}"
               DEFAULT_MODEL="mistral-medium" ;;
    cohere)    ENDPOINT="${CUSTOM_URL:-https://api.cohere.ai/v1/chat}"
               DEFAULT_MODEL="command-r" ;;
    custom)    ENDPOINT="${CUSTOM_URL:-http://localhost:8080/v1/chat/completions}"
               DEFAULT_MODEL="${AI_MODEL:-gpt-4}" ;;
    *)         ENDPOINT="${CUSTOM_URL:-https://api.openai.com/v1/chat/completions}"
               DEFAULT_MODEL="gpt-4o-mini" ;;
  esac
  MODEL="${AI_MODEL:-$DEFAULT_MODEL}"
}

# ─────────────────────────────────────────────────────────────────────────────
# TREE JSON  (resonance_tree.json)
# ─────────────────────────────────────────────────────────────────────────────

init_tree() {
  local name="${1:-New Conversation}"
  local root_id
  root_id="$(new_id)"
  local now
  now="$(date -u +"%Y-%m-%dT%H:%M:%S")"
  jq -n \
    --arg name "$name" \
    --arg created "$now" \
    --arg root_id "$root_id" \
    '{name:$name, created:$created, root:{id:$root_id, role:"root", text:"ROOT",
      collapsed:false, starred:false, tags:[], children:[], created:$created}}'
}

ensure_tree() {
  if [ ! -f "$TREE_FILE" ]; then
    init_tree "New Conversation" > "$TREE_FILE"
  fi
}

new_id() {
  # 8-char hex ID (portable — no uuidgen dependency needed)
  head -c 4 /dev/urandom | xxd -p 2>/dev/null \
    || printf '%08x' $((RANDOM * RANDOM)) 2>/dev/null \
    || date +%s%N | sha256sum | head -c 8
}

root_id() {
  jq -r '.root.id' "$TREE_FILE"
}

tree_name() {
  jq -r '.name' "$TREE_FILE"
}

# ── Find a node by id (returns JSON of the node) ──────────────────────────
find_node() {
  local nid="$1"
  jq --arg id "$nid" '
    def find_node(id):
      if .id == id then .
      else (.children[]? | find_node(id)) // empty
      end;
    .root | find_node($id)
  ' "$TREE_FILE" 2>/dev/null
}

node_exists() {
  local node
  node="$(find_node "$1")"
  [ -n "$node" ] && [ "$node" != "null" ]
}

# ── Add a child node ──────────────────────────────────────────────────────
add_node() {
  local parent_id="$1" role="$2" text="$3"
  local nid now
  nid="$(new_id)"
  now="$(date -u +"%Y-%m-%dT%H:%M:%S")"

  local new_node
  new_node="$(jq -n \
    --arg id "$nid" --arg role "$role" --arg text "$text" --arg created "$now" \
    '{id:$id, role:$role, text:$text, collapsed:false, starred:false, tags:[], children:[], created:$created}')"

  local tmp
  tmp="$(mktemp)"
  jq --arg pid "$parent_id" --argjson node "$new_node" '
    def add_to(pid; node):
      if .id == pid then . + {children: (.children + [node])}
      else . + {children: [.children[] | add_to(pid; node)]}
      end;
    .root |= add_to($pid; $node)
  ' "$TREE_FILE" > "$tmp" && mv "$tmp" "$TREE_FILE"

  echo "$nid"
}

# ── Delete a node by id ───────────────────────────────────────────────────
delete_node() {
  local nid="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$nid" '
    def rm(id):
      . + {children: [.children[] | select(.id != id) | rm(id)]};
    .root |= rm($id)
  ' "$TREE_FILE" > "$tmp" && mv "$tmp" "$TREE_FILE"
}

# ── Move a node to a new parent ───────────────────────────────────────────
move_node() {
  local nid="$1" new_parent="$2"
  local node
  node="$(find_node "$nid")"
  if [ -z "$node" ] || [ "$node" = "null" ]; then
    echo -e "${RED}  Node '$nid' not found.${R}"
    return 1
  fi
  local tmp
  tmp="$(mktemp)"
  # Step 1: remove node
  jq --arg id "$nid" '
    def rm(id):
      . + {children: [.children[] | select(.id != id) | rm(id)]};
    .root |= rm($id)
  ' "$TREE_FILE" > "$tmp" && mv "$tmp" "$TREE_FILE"
  # Step 2: insert under new parent
  tmp="$(mktemp)"
  jq --arg pid "$new_parent" --argjson node "$node" '
    def add_to(pid; node):
      if .id == pid then . + {children: (.children + [node])}
      else . + {children: [.children[] | add_to(pid; node)]}
      end;
    .root |= add_to($pid; $node)
  ' "$TREE_FILE" > "$tmp" && mv "$tmp" "$TREE_FILE"
  echo -e "${GRN}  Moved [$nid] → [$new_parent].${R}"
}

# ── Toggle field (collapsed / starred) ───────────────────────────────────
toggle_field() {
  local nid="$1" field="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$nid" --arg field "$field" '
    def toggle(id; field):
      if .id == id then . + {(field): (.[(field)] | not)}
      else . + {children: [.children[] | toggle(id; field)]}
      end;
    .root |= toggle($id; $field)
  ' "$TREE_FILE" > "$tmp" && mv "$tmp" "$TREE_FILE"
}

# ── Toggle a tag on a node ────────────────────────────────────────────────
toggle_tag() {
  local nid="$1" tag="$2"
  local tmp
  tmp="$(mktemp)"
  jq --arg id "$nid" --arg tag "$tag" '
    def toggle_tag(id; tag):
      if .id == id then
        if (.tags | index(tag)) != null
        then . + {tags: [.tags[] | select(. != tag)]}
        else . + {tags: (.tags + [tag])}
        end
      else . + {children: [.children[] | toggle_tag(id; tag)]}
      end;
    .root |= toggle_tag($id; $tag)
  ' "$TREE_FILE" > "$tmp" && mv "$tmp" "$TREE_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
# AI API CALL
# ─────────────────────────────────────────────────────────────────────────────

# Build context JSON array from ancestor path of a node
build_context() {
  local nid="$1"
  # Walk the tree, collect all ancestor nodes ordered root→node
  jq --arg id "$nid" --argjson max "$MAX_CONTEXT_TURNS" '
    def path_to(id; acc):
      if .id == id then acc + [.]
      else
        (.children[]? as $c |
          path_to($c | .id; acc + [.]) | 
          select(last.id == id)) // empty
      end;
    [ .root | path_to($id; []) | .[]
      | select(.role == "user" or .role == "ai")
      | { role: (if .role == "ai" then "assistant" else "user" end),
          content: .text }
    ] | .[-($max):]
  ' "$TREE_FILE" 2>/dev/null || echo "[]"
}

# Send a message to the AI, return response text
call_ai() {
  local prompt="$1"
  local context_json="${2:-[]}"
  get_provider_info

  # Append current user message to context
  local messages
  messages="$(echo "$context_json" | jq --arg p "$prompt" '. + [{role:"user",content:$p}]')"

  local http_code response_body
  local tmp_response
  tmp_response="$(mktemp)"

  if [ "$PROVIDER" = "anthropic" ]; then
    http_code="$(curl -s -o "$tmp_response" -w "%{http_code}" \
      -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -H "x-api-key: $API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      --data "$(jq -n \
        --arg model "$MODEL" \
        --argjson msgs "$messages" \
        '{model:$model, max_tokens:2048, messages:$msgs}')" \
      --max-time 90)"
    response_body="$(cat "$tmp_response")"
    rm -f "$tmp_response"

    if [ "$http_code" != "200" ]; then
      echo "[HTTP $http_code] $(echo "$response_body" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null)"
      return 1
    fi
    echo "$response_body" | jq -r '.content[0].text // empty'

  elif [ "$PROVIDER" = "ollama" ]; then
    http_code="$(curl -s -o "$tmp_response" -w "%{http_code}" \
      -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      --data "$(jq -n \
        --arg model "$MODEL" \
        --argjson msgs "$messages" \
        '{model:$model, messages:$msgs, stream:false}')" \
      --max-time 120)"
    response_body="$(cat "$tmp_response")"
    rm -f "$tmp_response"

    if [ "$http_code" != "200" ]; then
      echo "[HTTP $http_code] $(echo "$response_body" | jq -r '.error // "Unknown error"' 2>/dev/null)"
      return 1
    fi
    echo "$response_body" | jq -r '.message.content // empty'

  else
    # OpenAI-compatible (openai, deepseek, groq, together, xai, mistral, custom …)
    http_code="$(curl -s -o "$tmp_response" -w "%{http_code}" \
      -X POST "$ENDPOINT" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $API_KEY" \
      --data "$(jq -n \
        --arg model "$MODEL" \
        --argjson msgs "$messages" \
        '{model:$model, max_tokens:2048, messages:$msgs}')" \
      --max-time 90)"
    response_body="$(cat "$tmp_response")"
    rm -f "$tmp_response"

    if [ "$http_code" != "200" ]; then
      echo "[HTTP $http_code] $(echo "$response_body" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null)"
      return 1
    fi
    echo "$response_body" | jq -r '.choices[0].message.content // empty'
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# DISPLAY / RENDERING
# ─────────────────────────────────────────────────────────────────────────────

print_banner() {
  echo -e "${CYA}${BOLD}"
  echo '  ██████  ███████ ███████  ██████  ███    ██  █████  ███    ██  ██████ ███████'
  echo '  ██   ██ ██      ██      ██    ██ ████   ██ ██   ██ ████   ██ ██      ██'
  echo '  ██████  █████   ███████ ██    ██ ██ ██  ██ ███████ ██ ██  ██ ██      █████'
  echo '  ██   ██ ██           ██ ██    ██ ██  ██ ██ ██   ██ ██  ██ ██ ██      ██'
  echo '  ██   ██ ███████ ███████  ██████  ██   ████ ██   ██ ██   ████  ██████ ███████'
  echo -e "${R}${GRY}  Universal AI Conversation Tree  •  bash edition  v${VERSION}${R}"
  echo ""
}

role_icon() {
  case "$1" in
    user) echo "❯" ;; ai) echo "◆" ;; note) echo "✎" ;; root) echo "⬡" ;; *) echo "·" ;;
  esac
}

role_color() {
  case "$1" in
    user) echo "$CYA" ;; ai) echo "$GRN" ;; note) echo "$YEL" ;; *) echo "$GRY" ;;
  esac
}

# Render the full tree recursively
render_tree() {
  local focused="${1:-}"
  # Use jq to build a flat outline array, then display
  jq -r --arg max "$MAX_PREVIEW" '
    def outline(depth; prefix):
      (if .role != "root" then
        "\(depth)|\(.role)|\(.id)|\(.starred)|\(.collapsed)|" +
        (if (.children|length) > 0 then "\(.children|length)" else "0" end) + "|" +
        (.tags | join(",")) + "|" +
        (.text | gsub("\n";" ") | .[0:($max|tonumber)] + if (. | length) > ($max|tonumber) then "…" else "" end)
      else "" end),
      (if .collapsed then empty else .children[] | outline(depth+1; prefix+"    ") end);
    .root.children[] | outline(0; "")
  ' "$TREE_FILE" 2>/dev/null | while IFS='|' read -r depth role nid starred collapsed kids tags preview; do
    [ -z "$nid" ] && continue
    local indent=""
    local i=0
    while [ "$i" -lt "$depth" ]; do indent="${indent}    "; i=$((i+1)); done
    local prefix=""
    [ "$depth" -gt 0 ] && prefix="├── "
    local icon
    icon="$(role_icon "$role")"
    local col
    col="$(role_color "$role")"
    local star_mark=""
    [ "$starred" = "true" ] && star_mark="${YEL}★ ${R}"
    local kids_mark=""
    [ "$kids" -gt 0 ] && kids_mark="${GRY} [${kids}]${R}"
    local fold_mark=""
    [ "$collapsed" = "true" ] && fold_mark="${DIM} [+]${R}"
    local focus_mark=""
    [ "$nid" = "$focused" ] && focus_mark="${YEL} ◀${R}"
    local tags_fmt=""
    [ -n "$tags" ] && tags_fmt=" ${PUR}#${tags//,/ #}${R}"

    echo -e "  ${indent}${prefix}${star_mark}${col}${BOLD}${icon}${R} ${GRY}[${nid}]${R} ${col}${preview}${R}${kids_mark}${fold_mark}${tags_fmt}${focus_mark}"
  done
  echo ""
}

# Show full node content
show_node() {
  local nid="$1"
  local node
  node="$(find_node "$nid")"
  if [ -z "$node" ] || [ "$node" = "null" ]; then
    echo -e "${RED}  Node '$nid' not found.${R}"; return 1
  fi
  local role text created starred tags
  role="$(echo "$node" | jq -r '.role')"
  text="$(echo "$node" | jq -r '.text')"
  created="$(echo "$node" | jq -r '.created')"
  starred="$(echo "$node" | jq -r '.starred')"
  tags="$(echo "$node" | jq -r '.tags | join(", ")')"
  local col
  col="$(role_color "$role")"
  local icon
  icon="$(role_icon "$role")"
  echo ""
  echo -e "  ${col}${BOLD}${icon} [${nid}]  ${role^^}${R}"
  echo -e "  ${DIM}Created: ${created}${R}"
  [ "$starred" = "true" ] && echo -e "  ${YEL}★ Starred${R}"
  [ -n "$tags" ] && echo -e "  ${PUR}Tags: ${tags}${R}"
  echo ""
  echo "$text" | fold -s -w 88 | sed 's/^/    /'
  echo ""
}

# Table of contents
show_toc() {
  echo -e "${BOLD}${BLU}\n  ── Table of Contents ──${R}"
  jq -r --arg max "$MAX_PREVIEW" '
    def toc(depth):
      (if .role != "root" then
        "\(depth)|\(.role)|\(.id)|\(.starred)|\(.text | gsub("\n";" ") | .[0:($max|tonumber)])"
      else "" end),
      (.children[] | toc(depth+1));
    .root.children[] | toc(0)
  ' "$TREE_FILE" 2>/dev/null | while IFS='|' read -r depth role nid starred preview; do
    [ -z "$nid" ] && continue
    local indent=""
    local i=0
    while [ "$i" -lt "$depth" ]; do indent="${indent}  "; i=$((i+1)); done
    local icon
    icon="$(role_icon "$role")"
    local col
    col="$(role_color "$role")"
    local star=""
    [ "$starred" = "true" ] && star="${YEL}★ ${R}"
    echo -e "  ${indent}${col}${icon}${R} ${GRY}${nid}${R}  ${star}${preview}"
  done
  echo ""
}

# Stats
show_stats() {
  local name
  name="$(tree_name)"
  local created
  created="$(jq -r '.created' "$TREE_FILE")"
  local user_count ai_count note_count total starred
  user_count="$(jq '[.. | objects | select(.role=="user")]  | length' "$TREE_FILE")"
  ai_count="$(  jq '[.. | objects | select(.role=="ai")]    | length' "$TREE_FILE")"
  note_count="$(jq '[.. | objects | select(.role=="note")]  | length' "$TREE_FILE")"
  total="$(      jq '[.. | objects | select(.role!="root" and .role!=null)] | length' "$TREE_FILE")"
  starred="$(   jq '[.. | objects | select(.starred==true)] | length' "$TREE_FILE")"

  echo -e "\n  ${BOLD}Tree: ${name}${R}"
  echo -e "  ${DIM}Created: ${created}${R}"
  echo -e "  User messages : ${CYA}${user_count}${R}"
  echo -e "  AI responses  : ${GRN}${ai_count}${R}"
  echo -e "  Notes         : ${YEL}${note_count}${R}"
  echo -e "  Total nodes   : ${BOLD}${total}${R}"
  echo -e "  Starred       : ${YEL}${starred}${R}"
  echo ""
}

# Search
do_search() {
  local query="$1"
  echo -e "${CYA}\n  Searching for '${query}'…${R}"
  local q_lower
  q_lower="$(echo "$query" | tr '[:upper:]' '[:lower:]')"
  jq -r --arg q "$q_lower" --arg max "$MAX_PREVIEW" '
    [ .. | objects
      | select(.id? and .role? and .role != "root")
      | select(
          (.text | ascii_downcase | contains($q)) or
          (.tags | join(" ") | ascii_downcase | contains($q))
        )
      | "\(.role)|\(.id)|\(.text | gsub("\n";" ") | .[0:($max|tonumber)])"
    ] | .[]
  ' "$TREE_FILE" 2>/dev/null | while IFS='|' read -r role nid preview; do
    local col
    col="$(role_color "$role")"
    local icon
    icon="$(role_icon "$role")"
    echo -e "    ${col}${icon}${R} ${GRY}[${nid}]${R}  ${preview}"
  done
  echo ""
}

# Starred nodes
show_stars() {
  echo -e "${YEL}\n  ── Starred Nodes ──${R}"
  jq -r --arg max "$MAX_PREVIEW" '
    [ .. | objects
      | select(.id? and .starred == true and .role != "root")
      | "\(.role)|\(.id)|\(.text | gsub("\n";" ") | .[0:($max|tonumber)])"
    ] | .[]
  ' "$TREE_FILE" 2>/dev/null | while IFS='|' read -r role nid preview; do
    local col
    col="$(role_color "$role")"
    local icon
    icon="$(role_icon "$role")"
    echo -e "    ${YEL}★${R} ${col}${icon}${R} ${GRY}[${nid}]${R}  ${preview}"
  done
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# MARKDOWN EXPORT
# ─────────────────────────────────────────────────────────────────────────────
export_markdown() {
  local out="${1:-$EXPORT_FILE}"
  local name
  name="$(tree_name)"
  {
    echo "# ${name}"
    echo ""
    echo "_Exported by Resonance.sh_"
    echo ""
    echo "---"
    echo ""
    jq -r '
      def md(depth):
        if .role != "root" then
          (("#" * (([depth+2, 6]|min))) + " " +
           (if .role == "user" then "❯" elif .role == "ai" then "◆" else "✎" end) +
           " \`[" + .id + "]\` (" + .role + ")\n\n" +
           (if .starred then "⭐ **Starred**\n\n" else "" end) +
           (if (.tags|length) > 0 then "Tags: " + (.tags | map("`#"+.+"`") | join(", ")) + "\n\n" else "" end) +
           .text + "\n")
        else "" end,
        (.children[] | md(depth+1));
      .root.children[] | md(0)
    ' "$TREE_FILE"
  } > "$out"
  echo -e "${GRN}  Exported to ${out}${R}"
}

# ─────────────────────────────────────────────────────────────────────────────
# SETUP WIZARD
# ─────────────────────────────────────────────────────────────────────────────
run_setup() {
  echo -e "\n${BOLD}${CYA}  ── Resonance Setup Wizard ──${R}\n"
  echo -e "  ${DIM}Available providers:${R}"
  echo "    1) openai    — GPT-4o, GPT-4o-mini, o1 …"
  echo "    2) anthropic — Claude 3 Haiku/Sonnet/Opus"
  echo "    3) deepseek  — DeepSeek-Chat, DeepSeek-Coder"
  echo "    4) groq      — Llama3, Mixtral (fast inference)"
  echo "    5) together  — 100+ open-source models"
  echo "    6) ollama    — Local models (no API key needed)"
  echo "    7) xai       — Grok by xAI"
  echo "    8) mistral   — Mistral AI models"
  echo "    9) custom    — Any OpenAI-compatible endpoint"
  echo ""
  read -rp "  Provider [1-9, or name]: " prov_input

  case "$prov_input" in
    1|openai)    PROVIDER="openai" ;;
    2|anthropic) PROVIDER="anthropic" ;;
    3|deepseek)  PROVIDER="deepseek" ;;
    4|groq)      PROVIDER="groq" ;;
    5|together)  PROVIDER="together" ;;
    6|ollama)    PROVIDER="ollama" ;;
    7|xai)       PROVIDER="xai" ;;
    8|mistral)   PROVIDER="mistral" ;;
    9|custom)    PROVIDER="custom" ;;
    *)           PROVIDER="$prov_input" ;;
  esac

  get_provider_info

  if [ "$PROVIDER" != "ollama" ]; then
    read -rp "  API key: " API_KEY
  else
    API_KEY=""
    echo -e "  ${DIM}(Ollama runs locally — no API key required)${R}"
  fi

  read -rp "  Model name [${DEFAULT_MODEL}]: " model_input
  AI_MODEL="${model_input:-$DEFAULT_MODEL}"

  if [ "$PROVIDER" = "custom" ]; then
    read -rp "  API endpoint URL: " CUSTOM_URL
  else
    CUSTOM_URL=""
    read -rp "  Custom URL (leave blank to use default): " CUSTOM_URL
  fi

  save_config
  echo -e "\n${GRN}  ✓ Configuration saved to ${CONFIG_FILE}${R}"
  echo -e "  ${DIM}Provider: ${PROVIDER}  Model: ${AI_MODEL}${R}\n"

  # Quick test
  read -rp "  Run a test call? [y/N] " do_test
  if [[ "$do_test" =~ ^[Yy] ]]; then
    echo -e "  ${DIM}Testing…${R}"
    local reply
    reply="$(call_ai "Say 'Resonance is ready!' and nothing else." "[]")"
    echo -e "  ${GRN}AI reply: ${reply}${R}\n"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
  echo -e "${BOLD}${CYA}\n  ── Resonance Commands ──${R}\n"
  local cmds=(
    "tree                        Show full conversation tree"
    "toc                         Table of contents"
    "show <id>                   Show full text of a node"
    "ask <text>                  Ask AI under focused node"
    "add <text>                  Add user message under focused node"
    "note <text>                 Add personal note under focused node"
    "reply <id> <text>           Branch from specific node"
    "focus <id>                  Set focused node (default parent)"
    "move <id> <parent-id>       Re-parent / reorganise a node"
    "collapse <id>               Toggle collapse node children"
    "star <id>                   Toggle star"
    "tag <id> <tag>              Toggle tag on node"
    "delete <id>                 Delete node and its subtree"
    "search <query>              Full-text + tag search"
    "stars                       List all starred nodes"
    "stats                       Tree statistics"
    "export [file.md]            Export tree to Markdown"
    "save [file.json]            Save tree"
    "load [file.json]            Load tree"
    "new [name]                  Start a new tree"
    "config                      Show current AI config"
    "setup                       Re-run setup wizard"
    "setprovider <n>          Change provider"
    "setkey <key>                Change API key"
    "setmodel <model>            Change model"
    "seturl <url>                Set custom endpoint"
    "help                        This help"
    "quit / exit                 Save and exit"
  )
  for line in "${cmds[@]}"; do
    local cmd="${line%%   *}"
    local desc="${line##*   }"
    echo -e "  ${YEL}$(printf '%-32s' "$cmd")${R}  ${DIM}${desc}${R}"
  done
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# NON-INTERACTIVE MODES
# ─────────────────────────────────────────────────────────────────────────────

one_shot_ask() {
  # ./resonance.sh ask "question" [--parent <id>] [--save]
  local prompt="$1"
  shift
  local parent_override="" do_save=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parent) parent_override="$2"; shift 2 ;;
      --save)   do_save=true; shift ;;
      *)        shift ;;
    esac
  done

  ensure_tree
  load_config
  local parent="${parent_override:-$(root_id)}"
  local context
  context="$(build_context "$parent")"
  local reply
  reply="$(call_ai "$prompt" "$context")"
  echo "$reply"

  if "$do_save"; then
    local user_id
    user_id="$(add_node "$parent" "user" "$prompt")"
    add_node "$user_id" "ai" "$reply" >/dev/null
    echo -e "${DIM}(Saved to $TREE_FILE)${R}" >&2
  fi
}

pipe_mode() {
  # Read from stdin, ask AI, print to stdout
  local prompt
  prompt="$(cat)"
  ensure_tree
  load_config
  local root
  root="$(root_id)"
  call_ai "$prompt" "$(build_context "$root")"
}

# ─────────────────────────────────────────────────────────────────────────────
# INTERACTIVE REPL
# ─────────────────────────────────────────────────────────────────────────────
run_repl() {
  print_banner
  ensure_tree
  load_config

  local focused
  focused="$(root_id)"
  local tree_name_val
  tree_name_val="$(tree_name)"

  echo -e "  ${GRN}Tree:${R} ${tree_name_val}  ${DIM}(${TREE_FILE})${R}"
  echo -e "  ${DIM}Type 'help' for commands, 'quit' to exit.${R}\n"

  if [ -z "$API_KEY" ] && [ "$PROVIDER" != "ollama" ]; then
    echo -e "  ${YEL}⚠  No API key set. Run 'setup' to configure an AI provider.${R}\n"
  fi

  while true; do
    local prompt_label
    prompt_label="${CYA}resonance${R}${DIM} [${focused}] ${R}${BOLD}›${R} "
    read -rp "$(echo -e "$prompt_label")" raw || break
    [ -z "$raw" ] && continue

    local cmd arg1 arg2 rest
    cmd="$(echo "$raw" | awk '{print tolower($1)}')"
    arg1="$(echo "$raw" | awk '{print $2}')"
    rest="$(echo "$raw" | cut -d' ' -f3-)"
    arg2="$(echo "$raw" | cut -d' ' -f2-)"  # everything after cmd

    case "$cmd" in

      quit|exit|q)
        echo -e "${GRN}  Goodbye.${R}"
        break ;;

      tree)
        render_tree "$focused" ;;

      toc)
        show_toc ;;

      show)
        [ -z "$arg1" ] && { echo -e "${RED}  Usage: show <id>${R}"; continue; }
        show_node "$arg1" ;;

      focus)
        if [ -z "$arg1" ]; then
          focused="$(root_id)"
          echo -e "${DIM}  Focused on root.${R}"
        elif node_exists "$arg1"; then
          focused="$arg1"
          echo -e "${GRN}  Focused on [${arg1}].${R}"
        else
          echo -e "${RED}  Node '${arg1}' not found.${R}"
        fi ;;

      add)
        local add_text
        add_text="${arg2}"
        [ -z "$add_text" ] && { echo -e "${RED}  Usage: add <text>${R}"; continue; }
        local new_id
        new_id="$(add_node "$focused" "user" "$add_text")"
        focused="$new_id"
        echo -e "${CYA}  Added [${new_id}].${R}" ;;

      note)
        [ -z "$arg2" ] && { echo -e "${RED}  Usage: note <text>${R}"; continue; }
        local note_id
        note_id="$(add_node "$focused" "note" "$arg2")"
        echo -e "${YEL}  Note [${note_id}] added.${R}" ;;

      ask)
        [ -z "$arg2" ] && { echo -e "${RED}  Usage: ask <question>${R}"; continue; }
        if [ -z "$API_KEY" ] && [ "$PROVIDER" != "ollama" ]; then
          echo -e "${RED}  No API key. Run 'setup'.${R}"; continue
        fi
        local user_id
        user_id="$(add_node "$focused" "user" "$arg2")"
        focused="$user_id"
        local ctx
        ctx="$(build_context "$focused")"
        echo -e "${DIM}  ◆ Asking ${PROVIDER} (${MODEL})…${R}"
        local ai_reply
        ai_reply="$(call_ai "$arg2" "$ctx")"
        local ai_id
        ai_id="$(add_node "$focused" "ai" "$ai_reply")"
        focused="$ai_id"
        show_node "$ai_id"
        # Auto-save after each exchange
        echo -e "${DIM}  (auto-saved)${R}" ;;

      reply)
        local rep_parent="$arg1"
        local rep_text
        rep_text="$rest"
        if [ -z "$rep_parent" ] || [ -z "$rep_text" ]; then
          echo -e "${RED}  Usage: reply <id> <text>${R}"; continue
        fi
        if ! node_exists "$rep_parent"; then
          echo -e "${RED}  Node '${rep_parent}' not found.${R}"; continue
        fi
        if [ -z "$API_KEY" ] && [ "$PROVIDER" != "ollama" ]; then
          echo -e "${RED}  No API key. Run 'setup'.${R}"; continue
        fi
        local r_user_id
        r_user_id="$(add_node "$rep_parent" "user" "$rep_text")"
        local r_ctx
        r_ctx="$(build_context "$r_user_id")"
        echo -e "${DIM}  ◆ Branching from [${rep_parent}]…${R}"
        local r_reply
        r_reply="$(call_ai "$rep_text" "$r_ctx")"
        local r_ai_id
        r_ai_id="$(add_node "$r_user_id" "ai" "$r_reply")"
        focused="$r_ai_id"
        show_node "$r_ai_id" ;;

      move)
        local mv_id="$arg1"
        local mv_parent
        mv_parent="$(echo "$raw" | awk '{print $3}')"
        if [ -z "$mv_id" ] || [ -z "$mv_parent" ]; then
          echo -e "${RED}  Usage: move <id> <new-parent-id>${R}"; continue
        fi
        move_node "$mv_id" "$mv_parent" ;;

      delete)
        [ -z "$arg1" ] && { echo -e "${RED}  Usage: delete <id>${R}"; continue; }
        read -rp "$(echo -e "  ${RED}Delete [${arg1}] and subtree? [y/N] ${R}")" confirm
        if [[ "$confirm" =~ ^[Yy] ]]; then
          delete_node "$arg1"
          [ "$focused" = "$arg1" ] && focused="$(root_id)"
          echo -e "${YEL}  Deleted [${arg1}].${R}"
        fi ;;

      collapse)
        [ -z "$arg1" ] && { echo -e "${RED}  Usage: collapse <id>${R}"; continue; }
        toggle_field "$arg1" "collapsed"
        local cstate
        cstate="$(find_node "$arg1" | jq -r '.collapsed')"
        echo -e "${DIM}  [${arg1}] collapsed=${cstate}${R}" ;;

      star)
        [ -z "$arg1" ] && { echo -e "${RED}  Usage: star <id>${R}"; continue; }
        toggle_field "$arg1" "starred"
        local sstate
        sstate="$(find_node "$arg1" | jq -r '.starred')"
        local smsg
        [ "$sstate" = "true" ] && smsg="★ starred" || smsg="unstarred"
        echo -e "${YEL}  [${arg1}] ${smsg}${R}" ;;

      tag)
        local tag_id="$arg1"
        local tag_val
        tag_val="$(echo "$raw" | awk '{print $3}' | sed 's/^#//')"
        if [ -z "$tag_id" ] || [ -z "$tag_val" ]; then
          echo -e "${RED}  Usage: tag <id> <tagname>${R}"; continue
        fi
        toggle_tag "$tag_id" "$tag_val"
        echo -e "${PUR}  Tag #${tag_val} toggled on [${tag_id}].${R}" ;;

      search)
        [ -z "$arg2" ] && { echo -e "${RED}  Usage: search <query>${R}"; continue; }
        do_search "$arg2" ;;

      stars)
        show_stars ;;

      stats)
        show_stats ;;

      export)
        export_markdown "${arg1:-$EXPORT_FILE}" ;;

      save)
        local sf="${arg1:-$TREE_FILE}"
        # Tree is always kept up-to-date in-place; just confirm path
        [ "$sf" != "$TREE_FILE" ] && cp "$TREE_FILE" "$sf"
        echo -e "${GRN}  Saved to ${sf}.${R}" ;;

      load)
        local lf="${arg1:-$TREE_FILE}"
        if [ ! -f "$lf" ]; then
          echo -e "${RED}  File '${lf}' not found.${R}"
        else
          TREE_FILE="$lf"
          focused="$(root_id)"
          echo -e "${GRN}  Loaded $(tree_name) from ${lf}.${R}"
        fi ;;

      new)
        local new_name="${arg2:-New Conversation}"
        init_tree "$new_name" > "$TREE_FILE"
        focused="$(root_id)"
        echo -e "${GRN}  New tree '${new_name}' created.${R}" ;;

      config)
        echo -e "\n  ${BOLD}── Configuration ──${R}"
        echo -e "  ${YEL}Provider${R}  : $PROVIDER"
        echo -e "  ${YEL}Model${R}     : ${AI_MODEL:-<default>}"
        echo -e "  ${YEL}API Key${R}   : ${API_KEY:+$(printf '%*s' ${#API_KEY} '' | tr ' ' '*')}"
        echo -e "  ${YEL}Custom URL${R}: ${CUSTOM_URL:-(none)}"
        echo "" ;;

      setup)
        run_setup
        load_config ;;

      setprovider)
        [ -z "$arg1" ] && { echo -e "${RED}  Usage: setprovider <n>${R}"; continue; }
        PROVIDER="$arg1"; save_config
        echo -e "${GRN}  Provider set to '${arg1}'.${R}" ;;

      setkey)
        [ -z "$arg2" ] && { echo -e "${RED}  Usage: setkey <api-key>${R}"; continue; }
        API_KEY="$arg2"; save_config
        echo -e "${GRN}  API key saved.${R}" ;;

      setmodel)
        [ -z "$arg1" ] && { echo -e "${RED}  Usage: setmodel <model>${R}"; continue; }
        AI_MODEL="$arg1"; save_config
        echo -e "${GRN}  Model set to '${arg1}'.${R}" ;;

      seturl)
        [ -z "$arg2" ] && { echo -e "${RED}  Usage: seturl <url>${R}"; continue; }
        CUSTOM_URL="$arg2"; save_config
        echo -e "${GRN}  Custom URL set.${R}" ;;

      help|h|"?")
        show_help ;;

      *)
        echo -e "${DIM}  Unknown command '${cmd}'. Type 'help'.${R}" ;;
    esac
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# ENTRY POINT
# ─────────────────────────────────────────────────────────────────────────────
main() {
  check_deps

  case "${1:-}" in
    setup)
      load_config
      run_setup ;;
    ask)
      shift
      local q="$*"
      # Strip --parent and --save if present
      local clean_q=""
      local parent_arg="" save_flag=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --parent) parent_arg="$2"; shift 2 ;;
          --save)   save_flag=true; shift ;;
          *)        clean_q="${clean_q} $1"; shift ;;
        esac
      done
      [ -n "$parent_arg" ] && one_shot_ask "${clean_q:-$q}" --parent "$parent_arg" || \
        one_shot_ask "${clean_q:-$q}" ;;
    pipe)
      pipe_mode ;;
    export)
      ensure_tree
      load_config
      export_markdown "${2:-$EXPORT_FILE}" ;;
    stats)
      ensure_tree
      show_stats ;;
    version|-v|--version)
      echo "Resonance.sh v${VERSION}" ;;
    help|-h|--help)
      print_banner
      show_help ;;
    "")
      run_repl ;;
    *)
      echo -e "${RED}Unknown command: $1${R}"
      echo "Usage: $0 [setup|ask|pipe|export|stats|version|help]"
      exit 1 ;;
  esac
}

main "$@"
