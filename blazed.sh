#!/usr/bin/env bash
# blazed.sh - CLI and MCP stdio server for the blazed.sh Web3 PaaS API.
# Dependencies: bash >= 4, curl, jq.
set -euo pipefail

VERSION="0.1.0"
DEFAULT_API_URL="https://backend.blazed.sh"
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/blazed/config"
PROTOCOL_VERSION="2025-06-18"

JSON_OUT=0
API_KEY=""
API_URL=""
API_URL_FLAG=""
KEY_SOURCE=""
HTTP_CODE=""
RESP_BODY=""

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------

die() { # die [exit_code] message...
  local code=1
  if [[ ${1:-} =~ ^[0-9]+$ ]]; then code=$1; shift; fi
  printf 'blazed.sh: error: %s\n' "$*" >&2
  exit "$code"
}

warn() { printf 'blazed.sh: %s\n' "$*" >&2; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 \
      || die 2 "required command not found: $c (install it via your package manager)"
  done
}

need_val() { # need_val FLAG [VALUE...] — ensure the flag has a value after it
  (($# >= 2)) || die 2 "$1 requires a value"
}

validate_id() {
  [[ $1 =~ ^[A-Za-z0-9_-]+$ ]] || die 2 "invalid id: $1"
}

usage() {
  local topic=${1:-main}
  case $topic in
    main) cat <<EOF
blazed.sh $VERSION — CLI and MCP server for the blazed.sh Web3 PaaS

USAGE
  blazed.sh [--json] [--api-url URL] <command> ...

COMMANDS
  container  create | list | get | stop | delete | logs | ports
  script     create | update | list | get | run | stop | delete | logs
  config     set-key | show     manage local configuration
  mcp                           run as an MCP stdio server

GLOBAL FLAGS
  --json           print raw API JSON responses instead of human output
  --api-url URL    override the API base URL (default $DEFAULT_API_URL)
  -h, --help       show help (also per topic: blazed.sh container --help)
  -V, --version    print version

AUTHENTICATION
  Set BLAZED_API_KEY, or run 'blazed.sh config set-key' to store a key in
  $CONFIG_FILE. Keys are issued at https://panel.blazed.sh.
EOF
      ;;
    container) cat <<EOF
USAGE
  blazed.sh container create <name> --image IMAGE [options]
      --image IMAGE            Docker image, e.g. nginx:latest (required)
      -e, --env KEY=VALUE      environment variable (repeatable)
      --env-file FILE          read KEY=VALUE lines from FILE (# comments ok)
      -p, --port PORT          container port to expose, e.g. 8080 (repeatable;
                               host ports are auto-assigned, see 'ports')
      --cmd STRING             start command as a single string
      --tty | --no-tty         allocate a TTY (field omitted if not given)
      --volume-id ID           attach a volume by id
      --mount-path PATH        volume mount path (default /data when volume set)
  blazed.sh container list
  blazed.sh container get    <id>
  blazed.sh container stop   <id>
  blazed.sh container delete <id>
  blazed.sh container logs   <id> [-f|--follow] [--interval SECS]   (default 2)
  blazed.sh container ports  <id>     assigned host ports (container -> host)
EOF
      ;;
    script) cat <<EOF
USAGE
  blazed.sh script create <name> [--file PATH | --code STRING | -]
      code comes from --file, --code, or stdin (pipe, or explicit "-")
  blazed.sh script update <id> [--name NEW_NAME] [--file PATH | --code STRING | -]
      at least one of --name / code source is required; stdin needs explicit "-"
  blazed.sh script list
  blazed.sh script get    <id>
  blazed.sh script run    <id>
  blazed.sh script stop   <id>
  blazed.sh script delete <id>
  blazed.sh script logs   <id> [-f|--follow] [--interval SECS]   (default 2)
EOF
      ;;
    config) cat <<EOF
USAGE
  blazed.sh config set-key [KEY]   save API key to the config file (prompts if omitted)
  blazed.sh config show            print resolved configuration

CONFIG FILE ($CONFIG_FILE)
  key=value lines, parsed (never sourced):
    api_key=...
    api_url=$DEFAULT_API_URL

PRECEDENCE
  api key:  BLAZED_API_KEY env var, then config file
  api url:  --api-url flag, then BLAZED_API_URL env var, then config file
EOF
      ;;
    mcp) cat <<EOF
USAGE
  blazed.sh mcp    run as an MCP (Model Context Protocol) stdio server

  Exposes 15 tools mapping 1:1 to the blazed.sh API:
    blazed_create_container, blazed_list_containers, blazed_get_container,
    blazed_stop_container, blazed_delete_container, blazed_container_logs,
    blazed_container_ports, blazed_create_script, blazed_update_script,
    blazed_list_scripts, blazed_get_script, blazed_run_script,
    blazed_stop_script, blazed_delete_script, blazed_script_logs

  Register with Claude Code:
    claude mcp add blazed -- $0 mcp
  or drop the .mcp.json from this repo into your project.
EOF
      ;;
  esac
}

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------

load_config() {
  local line file_key="" file_url=""
  if [[ -f $CONFIG_FILE ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      case $line in
        api_key=*) file_key=${line#api_key=} ;;
        api_url=*) file_url=${line#api_url=} ;;
      esac
    done <"$CONFIG_FILE"
  fi
  if [[ -n ${BLAZED_API_KEY:-} ]]; then
    API_KEY=$BLAZED_API_KEY KEY_SOURCE="env"
  elif [[ -n $file_key ]]; then
    API_KEY=$file_key KEY_SOURCE="config file"
  fi
  if [[ -n $API_URL_FLAG ]]; then
    API_URL=$API_URL_FLAG
  elif [[ -n ${BLAZED_API_URL:-} ]]; then
    API_URL=$BLAZED_API_URL
  elif [[ -n $file_url ]]; then
    API_URL=$file_url
  else
    API_URL=$DEFAULT_API_URL
  fi
  API_URL=${API_URL%/}
}

require_key() {
  [[ -n $API_KEY ]] && return 0
  die 2 "no API key configured
Get one at https://panel.blazed.sh, then either:
  export BLAZED_API_KEY=...   (environment variable)
  blazed.sh config set-key       (saves to $CONFIG_FILE)"
}

cmd_config_set_key() {
  local key=${1:-}
  if [[ -z $key ]]; then
    read -rsp "API key: " key
    printf '\n' >&2
    [[ -n $key ]] || die 2 "no key entered"
  fi
  mkdir -p "$(dirname "$CONFIG_FILE")"
  local tmp
  tmp=$(mktemp)
  if [[ -f $CONFIG_FILE ]]; then
    grep -v '^api_key=' "$CONFIG_FILE" >"$tmp" || true
  fi
  printf 'api_key=%s\n' "$key" >>"$tmp"
  mv "$tmp" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  printf 'API key saved to %s\n' "$CONFIG_FILE"
}

cmd_config_show() {
  local state=""
  [[ -f $CONFIG_FILE ]] || state=" (not found)"
  printf 'config file: %s%s\n' "$CONFIG_FILE" "$state"
  printf 'api url:     %s\n' "$API_URL"
  if [[ -n $API_KEY ]]; then
    local masked="****"
    if ((${#API_KEY} > 8)); then masked="${API_KEY:0:4}...${API_KEY: -2}"; fi
    printf 'api key:     %s (from %s)\n' "$masked" "$KEY_SOURCE"
  else
    printf 'api key:     (not set)\n'
  fi
}

# ---------------------------------------------------------------------------
# HTTP core
# ---------------------------------------------------------------------------

# http_request METHOD PATH [JSON_BODY]
# Sets HTTP_CODE and RESP_BODY. Returns non-zero on transport failure.
http_request() {
  local method=$1 path=$2 raw
  local curl_args=(-sS --max-time 30 -w '%{http_code}' -X "$method"
    -H "Authorization: Bearer $API_KEY"
    -H "Content-Type: application/json")
  if (($# >= 3)); then curl_args+=(--data "$3"); fi
  raw=$(curl "${curl_args[@]}" "$API_URL$path") || return 1
  HTTP_CODE=${raw: -3}
  RESP_BODY=${raw%???}
  [[ $HTTP_CODE =~ ^[0-9]{3}$ ]] || return 1
}

# api_request METHOD PATH [JSON_BODY] — CLI wrapper: dies on any failure.
api_request() {
  require_key
  http_request "$@" || die 1 "network error contacting $API_URL"
  if ((10#$HTTP_CODE >= 400)); then
    {
      printf 'blazed.sh: API error (HTTP %s)' "$HTTP_CODE"
      [[ $HTTP_CODE == 401 ]] && printf ' — check your API key'
      printf ':\n'
      if jq -e . >/dev/null 2>&1 <<<"$RESP_BODY"; then
        jq . <<<"$RESP_BODY"
      else
        printf '%s\n' "$RESP_BODY"
      fi
    } >&2
    exit 1
  fi
}

# output_status LABEL — for endpoints answering {"status": "..."}
output_status() {
  if ((JSON_OUT)); then
    printf '%s\n' "$RESP_BODY"
    return 0
  fi
  local status
  status=$(jq -r '.status // empty' <<<"$RESP_BODY" 2>/dev/null) || status=""
  printf '%s: %s\n' "$1" "${status:-ok}"
}

output_record() { # output_record VERB NOUN
  if ((JSON_OUT)); then
    printf '%s\n' "$RESP_BODY"
    return 0
  fi
  local id name
  id=$(jq -r '.id // "?"' <<<"$RESP_BODY")
  name=$(jq -r '.name // "?"' <<<"$RESP_BODY")
  printf '%s %s %s (id: %s)\n' "$1" "$2" "$name" "$id"
}

# output_json_pretty — for get/list endpoints; humans get pretty JSON
output_json_pretty() {
  if ((JSON_OUT)); then
    printf '%s\n' "$RESP_BODY"
  else
    jq . <<<"$RESP_BODY"
  fi
}

# ---------------------------------------------------------------------------
# shared arg parsing
# ---------------------------------------------------------------------------

ARG_ID=""
FOLLOW=0
INTERVAL=2

# parse_id_args TOPIC ALLOW_FOLLOW ARGS... — for commands taking a single <id>
parse_id_args() {
  local topic=$1 allow_follow=$2
  shift 2
  ARG_ID="" FOLLOW=0 INTERVAL=2
  local positional=()
  while (($#)); do
    case $1 in
      -f | --follow)
        ((allow_follow)) || die 2 "unknown flag: $1"
        FOLLOW=1
        shift
        ;;
      --interval)
        ((allow_follow)) || die 2 "unknown flag: $1"
        need_val "$@"
        [[ $2 =~ ^[0-9]+([.][0-9]+)?$ ]] || die 2 "--interval expects a number of seconds"
        INTERVAL=$2
        shift 2
        ;;
      --json)
        JSON_OUT=1
        shift
        ;;
      --api-url)
        need_val "$@"
        API_URL=${2%/}
        shift 2
        ;;
      -h | --help)
        usage "$topic"
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        die 2 "unknown flag: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  ((${#positional[@]} == 1)) || {
    usage "$topic" >&2
    exit 2
  }
  ARG_ID=${positional[0]}
  validate_id "$ARG_ID"
}

# parse_no_args TOPIC ARGS... — for commands taking no positional arguments
parse_no_args() {
  local topic=$1
  shift
  while (($#)); do
    case $1 in
      --json)
        JSON_OUT=1
        shift
        ;;
      --api-url)
        need_val "$@"
        API_URL=${2%/}
        shift 2
        ;;
      -h | --help)
        usage "$topic"
        exit 0
        ;;
      *)
        die 2 "unexpected argument: $1"
        ;;
    esac
  done
}

# logs_show RESOURCE_PATH ID — one-shot or --follow polling
logs_show() {
  local path="/api/$1/$2/logs" text
  if ((!FOLLOW)); then
    api_request GET "$path"
    if ((JSON_OUT)); then
      printf '%s\n' "$RESP_BODY"
    else
      text=$(jq -r '.text // ""' <<<"$RESP_BODY")
      [[ -n $text ]] && printf '%s\n' "$text"
    fi
    return 0
  fi
  local prev_len=0
  while true; do
    api_request GET "$path"
    # keep exact bytes: a sentinel stops $() from eating trailing newlines
    text=$(jq -j '(.text // "") + "\u0001"' <<<"$RESP_BODY")
    text=${text%$'\x01'}
    if ((${#text} < prev_len)); then prev_len=0; fi # log shrank: reprint
    if ((${#text} > prev_len)); then
      printf '%s' "${text:prev_len}"
      prev_len=${#text}
    fi
    sleep "$INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# container commands
# ---------------------------------------------------------------------------

read_env_file() { # appends to caller's env_lines array
  local file=$1 line
  [[ -r $file ]] || die 2 "cannot read env file: $file"
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line || $line == \#* ]] && continue
    [[ $line == *=* ]] || die 2 "invalid line in $file (expected KEY=VALUE): $line"
    env_lines+=("$line")
  done <"$file"
}

cmd_container_create() {
  local image="" cmd_str="" volume_id="" mount_path="" tty_json='{}'
  local env_lines=() port_specs=() positional=()
  while (($#)); do
    case $1 in
      --image)
        need_val "$@"
        image=$2
        shift 2
        ;;
      -e | --env)
        need_val "$@"
        [[ $2 == *=* ]] || die 2 "--env expects KEY=VALUE, got: $2"
        env_lines+=("$2")
        shift 2
        ;;
      --env-file)
        need_val "$@"
        read_env_file "$2"
        shift 2
        ;;
      -p | --port)
        need_val "$@"
        if [[ ! $2 =~ ^[0-9]+$ ]] || ((10#$2 < 1 || 10#$2 > 65535)); then
          die 2 "--port expects a plain container port number (1-65535), got: $2
host ports are assigned by the platform — check them with 'blazed.sh container ports <id>'"
        fi
        port_specs+=("$2")
        shift 2
        ;;
      --cmd)
        need_val "$@"
        cmd_str=$2
        shift 2
        ;;
      --volume-id)
        need_val "$@"
        volume_id=$2
        shift 2
        ;;
      --mount-path)
        need_val "$@"
        mount_path=$2
        shift 2
        ;;
      --tty)
        tty_json='{"tty":true}'
        shift
        ;;
      --no-tty)
        tty_json='{"tty":false}'
        shift
        ;;
      --json)
        JSON_OUT=1
        shift
        ;;
      --api-url)
        need_val "$@"
        API_URL=${2%/}
        shift 2
        ;;
      -h | --help)
        usage container
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        die 2 "unknown flag for container create: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  ((${#positional[@]} == 1)) || {
    usage container >&2
    exit 2
  }
  local name=${positional[0]}
  [[ -n $image ]] || die 2 "container create requires --image"

  local env_str="" ports_json='[]'
  if ((${#env_lines[@]})); then
    env_str=$(printf '%s\n' "${env_lines[@]}") # $() strips the trailing newline
  fi
  if ((${#port_specs[@]})); then
    # the API takes ports as an array of plain port-number strings
    ports_json=$(jq -nc '$ARGS.positional' --args -- "${port_specs[@]}")
  fi

  local body
  body=$(jq -nc --arg name "$name" --arg image "$image" --arg env "$env_str" \
    --argjson ports "$ports_json" --arg cmd "$cmd_str" \
    --arg volumeId "$volume_id" --arg mountPath "$mount_path" \
    --argjson tty "$tty_json" '
      {name: $name, image: $image}
      + (if $env != ""             then {env: $env}             else {} end)
      + (if ($ports | length) > 0  then {ports: $ports}         else {} end)
      + (if $cmd != ""             then {cmd: $cmd}             else {} end)
      + (if $volumeId != ""        then {volumeId: $volumeId}   else {} end)
      + (if $mountPath != ""       then {mountPath: $mountPath} else {} end)
      + $tty')
  api_request POST /api/containers "$body"
  output_record Created container
}

cmd_container_list() {
  parse_no_args container "$@"
  api_request GET /api/containers
  if ((JSON_OUT)); then
    printf '%s\n' "$RESP_BODY"
    return 0
  fi
  local table
  table=$(jq -r '(["ID", "NAME", "IMAGE", "STATUS"],
                  (.[] | [.id, .name, .image, (.status // "-")])) | @tsv' <<<"$RESP_BODY") \
    || die 1 "unexpected API response: $RESP_BODY"
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' <<<"$table"
  else
    printf '%s\n' "$table"
  fi
}

cmd_container_get() {
  parse_id_args container 0 "$@"
  api_request GET "/api/containers/$ARG_ID"
  output_json_pretty
}

cmd_container_stop() {
  parse_id_args container 0 "$@"
  api_request POST "/api/containers/$ARG_ID/stop"
  output_status "Container $ARG_ID"
}

cmd_container_delete() {
  parse_id_args container 0 "$@"
  api_request DELETE "/api/containers/$ARG_ID"
  ((JSON_OUT)) || printf 'Deleted container %s\n' "$ARG_ID"
}

cmd_container_logs() {
  parse_id_args container 1 "$@"
  logs_show containers "$ARG_ID"
}

cmd_container_ports() {
  parse_id_args container 0 "$@"
  api_request GET "/api/containers/$ARG_ID/ports"
  if ((JSON_OUT)); then
    printf '%s\n' "$RESP_BODY"
    return 0
  fi
  # response is a map: {"<containerPort>": <assigned hostPort>, ...}
  local table
  table=$(jq -r '(["CONTAINER", "HOST"],
                  (to_entries[] | [.key, (.value | tostring)])) | @tsv' <<<"$RESP_BODY") \
    || die 1 "unexpected API response: $RESP_BODY"
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' <<<"$table"
  else
    printf '%s\n' "$table"
  fi
}

# ---------------------------------------------------------------------------
# script commands
# ---------------------------------------------------------------------------

cmd_script_create() {
  local code_file="" code_str="" has_code=0 use_stdin=0 positional=()
  while (($#)); do
    case $1 in
      --file)
        need_val "$@"
        code_file=$2
        shift 2
        ;;
      --code)
        need_val "$@"
        code_str=$2
        has_code=1
        shift 2
        ;;
      -)
        use_stdin=1
        shift
        ;;
      --json)
        JSON_OUT=1
        shift
        ;;
      --api-url)
        need_val "$@"
        API_URL=${2%/}
        shift 2
        ;;
      -h | --help)
        usage script
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        die 2 "unknown flag for script create: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  ((${#positional[@]} == 1)) || {
    usage script >&2
    exit 2
  }
  local name=${positional[0]} body
  if [[ -n $code_file ]]; then
    [[ -r $code_file ]] || die 2 "cannot read file: $code_file"
    body=$(jq -nc --arg name "$name" --rawfile code "$code_file" '{name: $name, code: $code}')
  elif ((has_code)); then
    body=$(jq -nc --arg name "$name" --arg code "$code_str" '{name: $name, code: $code}')
  elif ((use_stdin)) || [[ ! -t 0 ]]; then
    code_str=$(cat)
    body=$(jq -nc --arg name "$name" --arg code "$code_str" '{name: $name, code: $code}')
  else
    die 2 "script create needs code: --file PATH, --code STRING, or pipe via stdin"
  fi
  api_request POST /api/scripts "$body"
  output_record Created script
}

cmd_script_update() {
  local new_name="" code_file="" code_str="" has_code=0 use_stdin=0 positional=()
  while (($#)); do
    case $1 in
      --name)
        need_val "$@"
        new_name=$2
        shift 2
        ;;
      --file)
        need_val "$@"
        code_file=$2
        shift 2
        ;;
      --code)
        need_val "$@"
        code_str=$2
        has_code=1
        shift 2
        ;;
      -)
        use_stdin=1
        shift
        ;;
      --json)
        JSON_OUT=1
        shift
        ;;
      --api-url)
        need_val "$@"
        API_URL=${2%/}
        shift 2
        ;;
      -h | --help)
        usage script
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      -*)
        die 2 "unknown flag for script update: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done
  ((${#positional[@]} == 1)) || {
    usage script >&2
    exit 2
  }
  local id=${positional[0]}
  validate_id "$id"
  local body='{}'
  if [[ -n $new_name ]]; then
    body=$(jq -c --arg name "$new_name" '. + {name: $name}' <<<"$body")
  fi
  if [[ -n $code_file ]]; then
    [[ -r $code_file ]] || die 2 "cannot read file: $code_file"
    body=$(jq -c --rawfile code "$code_file" '. + {code: $code}' <<<"$body")
  elif ((has_code)); then
    body=$(jq -c --arg code "$code_str" '. + {code: $code}' <<<"$body")
  elif ((use_stdin)); then
    code_str=$(cat)
    body=$(jq -c --arg code "$code_str" '. + {code: $code}' <<<"$body")
  fi
  [[ $body != '{}' ]] || die 2 "script update requires --name and/or code (--file, --code, or -)"
  api_request PATCH "/api/scripts/$id" "$body"
  output_record Updated script
}

cmd_script_list() {
  parse_no_args script "$@"
  api_request GET /api/scripts
  if ((JSON_OUT)); then
    printf '%s\n' "$RESP_BODY"
    return 0
  fi
  local table
  table=$(jq -r '(["ID", "NAME", "LAST_EXIT", "STATUS"],
                  (.[] | [.id, .name, (.lastExitCode // "-" | tostring),
                          (.currentContainer.status // "-")])) | @tsv' <<<"$RESP_BODY") \
    || die 1 "unexpected API response: $RESP_BODY"
  if command -v column >/dev/null 2>&1; then
    column -t -s $'\t' <<<"$table"
  else
    printf '%s\n' "$table"
  fi
}

cmd_script_get() {
  parse_id_args script 0 "$@"
  api_request GET "/api/scripts/$ARG_ID"
  output_json_pretty
}

cmd_script_run() {
  parse_id_args script 0 "$@"
  api_request POST "/api/scripts/$ARG_ID/run"
  output_status "Script $ARG_ID"
}

cmd_script_stop() {
  parse_id_args script 0 "$@"
  api_request POST "/api/scripts/$ARG_ID/stop"
  output_status "Script $ARG_ID"
}

cmd_script_delete() {
  parse_id_args script 0 "$@"
  api_request DELETE "/api/scripts/$ARG_ID"
  ((JSON_OUT)) || printf 'Deleted script %s\n' "$ARG_ID"
}

cmd_script_logs() {
  parse_id_args script 1 "$@"
  logs_show scripts "$ARG_ID"
}

# ---------------------------------------------------------------------------
# MCP stdio server (JSON-RPC 2.0 <-> REST bridge)
# stdout is protocol-only here; all diagnostics go to stderr.
# ---------------------------------------------------------------------------

tools_json() {
  cat <<'EOF'
[
  {
    "name": "blazed_create_container",
    "description": "Deploy a Docker container on blazed.sh (it runs co-located with a fully-synced Ethereum node, reachable from inside the container). Returns the created record; keep the returned id for stop/logs/ports calls.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {"type": "string", "description": "Container name"},
        "image": {"type": "string", "description": "Docker image, e.g. nginx:latest"},
        "env": {"type": "string", "description": "Environment variables as ONE newline-separated string of KEY=VALUE lines, e.g. \"NODE_ENV=production\nPORT=3000\""},
        "ports": {"type": "array", "items": {"type": "string"}, "description": "Container ports to expose, as an array of plain port-number strings, e.g. [\"8080\"]. Host ports are auto-assigned by the platform; read them back with blazed_container_ports."},
        "cmd": {"type": "string", "description": "Start command as a single string"},
        "tty": {"type": "boolean", "description": "Allocate a TTY"},
        "volumeId": {"type": "string", "description": "Optional volume id to attach"},
        "mountPath": {"type": "string", "description": "Mount path for the attached volume (default /data)"}
      },
      "required": ["name", "image"]
    }
  },
  {
    "name": "blazed_list_containers",
    "description": "List all containers of the authenticated user (array of container records with id, name, image, status, ...).",
    "inputSchema": {"type": "object", "properties": {}}
  },
  {
    "name": "blazed_get_container",
    "description": "Get a single blazed.sh container record by id.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Container id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_stop_container",
    "description": "Stop a running blazed.sh container by id. Responds {\"status\":\"stopping\"}.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Container id (from blazed_create_container)"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_delete_container",
    "description": "Delete a blazed.sh container by id. Responds with HTTP 204 (empty) on success.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Container id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_container_logs",
    "description": "Fetch logs of a blazed.sh container. Returns a point-in-time snapshot of the full log text; call again for newer output.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Container id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_container_ports",
    "description": "Get the assigned port mappings of a blazed.sh container. Returns a map of containerPort to auto-assigned hostPort, e.g. {\"8080\": 30123}.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Container id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_create_script",
    "description": "Create a NodeJS script on blazed.sh. Scripts run in a containerized environment with ethers.js and web3.js preinstalled and a fully-synced Ethereum node reachable at ws://blazed_infra_eth-execution:8545. Returns the created record; keep the returned id.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "name": {"type": "string", "description": "Script name"},
        "code": {"type": "string", "description": "NodeJS source code"}
      },
      "required": ["name", "code"]
    }
  },
  {
    "name": "blazed_update_script",
    "description": "Update the name and/or code of an existing blazed.sh script (partial update; only provided fields change).",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {"type": "string", "description": "Script id"},
        "name": {"type": "string", "description": "New script name"},
        "code": {"type": "string", "description": "New NodeJS source code"}
      },
      "required": ["id"]
    }
  },
  {
    "name": "blazed_list_scripts",
    "description": "List all scripts of the authenticated user (array with id, name, lastExitCode, lastExecTime and currentContainer if one is running).",
    "inputSchema": {"type": "object", "properties": {}}
  },
  {
    "name": "blazed_get_script",
    "description": "Get a single blazed.sh script by id, including its code and current runner container.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Script id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_run_script",
    "description": "Execute a blazed.sh script by id (asynchronous; responds {\"status\":\"running\"} — use blazed_script_logs to see output).",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Script id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_stop_script",
    "description": "Stop a running blazed.sh script by id. Responds {\"status\":\"stopped\"}.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Script id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_delete_script",
    "description": "Delete a blazed.sh script by id. Responds with HTTP 204 (empty) on success.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Script id"}},
      "required": ["id"]
    }
  },
  {
    "name": "blazed_script_logs",
    "description": "Fetch execution logs of a blazed.sh script. Returns a point-in-time snapshot of the full log text; call again for newer output.",
    "inputSchema": {
      "type": "object",
      "properties": {"id": {"type": "string", "description": "Script id"}},
      "required": ["id"]
    }
  }
]
EOF
}

mcp_send() { printf '%s\n' "$1"; }

mcp_reply() { # mcp_reply ID_JSON RESULT_JSON
  mcp_send "$(jq -nc --argjson id "$1" --argjson result "$2" \
    '{jsonrpc: "2.0", id: $id, result: $result}')"
}

mcp_error_reply() { # mcp_error_reply ID_JSON CODE MESSAGE
  mcp_send "$(jq -nc --argjson id "$1" --argjson code "$2" --arg msg "$3" \
    '{jsonrpc: "2.0", id: $id, error: {code: $code, message: $msg}}')"
}

mcp_tool_result() { # mcp_tool_result ID_JSON IS_ERROR TEXT
  local result
  result=$(jq -nc --argjson err "$2" --arg text "$3" \
    '{content: [{type: "text", text: $text}], isError: $err}')
  mcp_reply "$1" "$result"
}

mcp_call_tool() { # mcp_call_tool ID_JSON REQUEST_LINE
  local id_json=$1 line=$2
  local name args method path needs_id id body
  name=$(jq -r '.params.name // empty' <<<"$line")
  args=$(jq -c '.params.arguments // {} | if type == "object" then . else {} end' <<<"$line")
  case $name in
    blazed_create_container) method=POST   path='/api/containers' needs_id=0 ;;
    blazed_list_containers)  method=GET    path='/api/containers' needs_id=0 ;;
    blazed_get_container)    method=GET    path='/api/containers/{id}' needs_id=1 ;;
    blazed_stop_container)   method=POST   path='/api/containers/{id}/stop' needs_id=1 ;;
    blazed_delete_container) method=DELETE path='/api/containers/{id}' needs_id=1 ;;
    blazed_container_logs)   method=GET    path='/api/containers/{id}/logs' needs_id=1 ;;
    blazed_container_ports)  method=GET    path='/api/containers/{id}/ports' needs_id=1 ;;
    blazed_create_script)    method=POST   path='/api/scripts' needs_id=0 ;;
    blazed_update_script)    method=PATCH  path='/api/scripts/{id}' needs_id=1 ;;
    blazed_list_scripts)     method=GET    path='/api/scripts' needs_id=0 ;;
    blazed_get_script)       method=GET    path='/api/scripts/{id}' needs_id=1 ;;
    blazed_run_script)       method=POST   path='/api/scripts/{id}/run' needs_id=1 ;;
    blazed_stop_script)      method=POST   path='/api/scripts/{id}/stop' needs_id=1 ;;
    blazed_delete_script)    method=DELETE path='/api/scripts/{id}' needs_id=1 ;;
    blazed_script_logs)      method=GET    path='/api/scripts/{id}/logs' needs_id=1 ;;
    *)
      mcp_tool_result "$id_json" true "Unknown tool: ${name:-<none>}"
      return 0
      ;;
  esac
  if ((needs_id)); then
    id=$(jq -r '.id // empty' <<<"$args")
    if [[ ! $id =~ ^[A-Za-z0-9_-]+$ ]]; then
      mcp_tool_result "$id_json" true "Missing or invalid required argument: id"
      return 0
    fi
    path=${path//\{id\}/$id}
  fi
  body=$(jq -c 'del(.id)' <<<"$args")
  warn "mcp: $name -> $method $path"
  local rc=0
  if [[ ($method == POST || $method == PATCH) && $body != '{}' ]]; then
    http_request "$method" "$path" "$body" || rc=$?
  else
    http_request "$method" "$path" || rc=$?
  fi
  if ((rc != 0)); then
    mcp_tool_result "$id_json" true "Network error contacting $API_URL"
  elif [[ $HTTP_CODE =~ ^2 ]]; then
    mcp_tool_result "$id_json" false "${RESP_BODY:-OK (HTTP $HTTP_CODE)}"
  else
    mcp_tool_result "$id_json" true "API error (HTTP $HTTP_CODE): $RESP_BODY"
  fi
}

mcp_handle() {
  local line=$1 method has_id id_json
  if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
    mcp_error_reply null -32700 "Parse error"
    return 0
  fi
  method=$(jq -r '.method // empty' <<<"$line")
  has_id=$(jq -r 'has("id")' <<<"$line")
  [[ $has_id == true ]] || return 0 # notification: no response
  id_json=$(jq -c '.id' <<<"$line")
  case $method in
    initialize)
      local proto
      proto=$(jq -r '.params.protocolVersion // empty' <<<"$line")
      [[ -n $proto ]] || proto=$PROTOCOL_VERSION
      mcp_reply "$id_json" "$(jq -nc --arg pv "$proto" --arg v "$VERSION" \
        '{protocolVersion: $pv, capabilities: {tools: {}},
          serverInfo: {name: "blazed-mcp", version: $v}}')"
      ;;
    tools/list)
      mcp_reply "$id_json" "$(jq -nc --argjson tools "$(tools_json)" '{tools: $tools}')"
      ;;
    tools/call)
      mcp_call_tool "$id_json" "$line"
      ;;
    ping)
      mcp_reply "$id_json" '{}'
      ;;
    *)
      mcp_error_reply "$id_json" -32601 "Method not found: $method"
      ;;
  esac
}

mcp_serve() {
  require_key
  warn "mcp server ready (api: $API_URL)"
  local line
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    mcp_handle "$line" || true # one bad request must not kill the server
  done
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

dispatch_container() {
  local cmd=${1:-}
  case $cmd in
    create) shift; cmd_container_create "$@" ;;
    list)   shift; cmd_container_list "$@" ;;
    get)    shift; cmd_container_get "$@" ;;
    stop)   shift; cmd_container_stop "$@" ;;
    delete | rm) shift; cmd_container_delete "$@" ;;
    logs)   shift; cmd_container_logs "$@" ;;
    ports)  shift; cmd_container_ports "$@" ;;
    -h | --help | help) usage container ;;
    "")
      usage container >&2
      exit 2
      ;;
    *)
      warn "unknown container command: $cmd"
      usage container >&2
      exit 2
      ;;
  esac
}

dispatch_script() {
  local cmd=${1:-}
  case $cmd in
    create) shift; cmd_script_create "$@" ;;
    update) shift; cmd_script_update "$@" ;;
    list)   shift; cmd_script_list "$@" ;;
    get)    shift; cmd_script_get "$@" ;;
    run)    shift; cmd_script_run "$@" ;;
    stop)   shift; cmd_script_stop "$@" ;;
    delete | rm) shift; cmd_script_delete "$@" ;;
    logs)   shift; cmd_script_logs "$@" ;;
    -h | --help | help) usage script ;;
    "")
      usage script >&2
      exit 2
      ;;
    *)
      warn "unknown script command: $cmd"
      usage script >&2
      exit 2
      ;;
  esac
}

dispatch_config() {
  local cmd=${1:-}
  case $cmd in
    set-key) shift; cmd_config_set_key "$@" ;;
    show)    shift; cmd_config_show "$@" ;;
    -h | --help | help) usage config ;;
    "")
      usage config >&2
      exit 2
      ;;
    *)
      warn "unknown config command: $cmd"
      usage config >&2
      exit 2
      ;;
  esac
}

main() {
  require_cmd curl jq
  while (($#)); do
    case $1 in
      --json)
        JSON_OUT=1
        shift
        ;;
      --api-url)
        need_val "$@"
        API_URL_FLAG=$2
        shift 2
        ;;
      -h | --help)
        usage main
        exit 0
        ;;
      -V | --version)
        printf 'blazed.sh %s\n' "$VERSION"
        exit 0
        ;;
      *) break ;;
    esac
  done
  if (($# == 0)); then
    usage main >&2
    exit 2
  fi
  local resource=$1
  shift
  load_config
  case $resource in
    container) dispatch_container "$@" ;;
    script)    dispatch_script "$@" ;;
    config)    dispatch_config "$@" ;;
    mcp)       mcp_serve ;;
    help)      usage "${1:-main}" ;;
    *)
      warn "unknown command: $resource"
      usage main >&2
      exit 2
      ;;
  esac
}

main "$@"
