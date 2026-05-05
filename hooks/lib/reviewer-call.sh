# Shellcheck-friendly library: no-credential reviewer call defaults/helpers.
# shellcheck shell=bash

: "${CODEX_STOP_REVIEWER_TIMEOUT:=240}"
: "${CODEX_EDIT_PRE_REVIEWER_TIMEOUT:=60}"

reviewer_ollama_options() {
  local seed="${1:-42}"
  jq -n --argjson seed "$seed" '{
    temperature: 0.3,
    top_k: 40,
    top_p: 0.9,
    seed: $seed,
    num_ctx: 32768,
    num_predict: 2048,
    repeat_penalty: 1.0
  }'
}

reviewer_strip_fences() {
  sed -E '/^[[:space:]]*```[a-zA-Z]*[[:space:]]*$/d; /^[[:space:]]*```[[:space:]]*$/d'
}

reviewer_call_chat() {
  local kind="$1"
  local sys_file="$2"
  local usr_file="$3"
  local schema_file="$4"
  local timeout_secs="$5"
  local raw response http_code body send_path

  case "$REVIEWER_BACKEND" in
    ollama)
      send_path=$(mktemp)
      jq -n \
        --arg model "$REVIEWER_OLLAMA_MODEL" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        --argjson schema "$(cat "$schema_file")" \
        --argjson options "$(reviewer_ollama_options 42)" \
        '{model:$model,stream:false,think:false,format:$schema,options:$options,
          messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' >"$send_path"
      response=$(timeout "$timeout_secs" curl -s --max-time "$timeout_secs" \
        -X POST "$REVIEWER_OLLAMA_HOST/api/chat" \
        -H 'Content-Type: application/json' \
        --data-binary "@$send_path" \
        -w '\n%{http_code}' 2>/dev/null)
      local exit_call=$?
      rm -f "$send_path"
      [ "$exit_call" -eq 0 ] || return 1
      http_code=$(printf '%s' "$response" | tail -n1)
      body=$(printf '%s' "$response" | sed '$d')
      case "$http_code" in 2*) ;; *) return 1 ;; esac
      raw=$(printf '%s' "$body" | jq -r '.message.content // empty' 2>/dev/null)
      ;;
    opencode-zen)
      send_path=$(mktemp)
      jq -n \
        --arg model "$REVIEWER_OPENCODE_MODEL" \
        --rawfile sys "$sys_file" \
        --rawfile usr "$usr_file" \
        --argjson schema "$(cat "$schema_file")" \
        --arg name "${kind}_verdict" \
        '{model:$model,stream:false,max_tokens:8192,max_completion_tokens:8192,
          temperature:0.3,top_p:0.9,seed:42,
          response_format:{type:"json_schema",json_schema:{name:$name,schema:$schema,strict:false}},
          messages:[{role:"system",content:$sys},{role:"user",content:$usr}]}' >"$send_path"
      response=$(timeout "$timeout_secs" curl -s --max-time "$timeout_secs" \
        -X POST "$REVIEWER_OPENCODE_HOST/zen/v1/chat/completions" \
        -H 'Content-Type: application/json' \
        --data-binary "@$send_path" \
        -w '\n%{http_code}' 2>/dev/null)
      local exit_call=$?
      rm -f "$send_path"
      [ "$exit_call" -eq 0 ] || return 1
      http_code=$(printf '%s' "$response" | tail -n1)
      body=$(printf '%s' "$response" | sed '$d')
      case "$http_code" in 2*) ;; *) return 1 ;; esac
      raw=$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
      ;;
    *)
      return 1
      ;;
  esac

  [ -n "$raw" ] || return 1
  printf '%s' "$raw" | reviewer_strip_fences
}
