#!/usr/bin/env bash
set -euo pipefail

GQL_URL="${RUNPOD_GQL_URL:-https://api.runpod.io/graphql}"
FORGE_OUT_DIR="${RUNPOD_FORGE_DIR:-/home/forge/sd-webui/output/txt2img-images}"
DL_DEST="${RUNPOD_DOWNLOAD_DIR:-.}"
KEY_FILE="${RUNPOD_API_KEY_FILE:-$HOME/.config/runpod}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

QUERY='query Pods {
  myself {
    pods {
      id
      name
      desiredStatus
      runtime {
        uptimeInSeconds
        ports { ip publicPort type }
      }
      machine { gpuDisplayName }
    }
  }
}'

SELECTED_LINE=""
RESP_JSON=""
API_KEY=""

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: runpod_cli.sh [API_KEY]

Interactive pod picker for RunPod:
  - lists your pods (running first)
  - connect to a pod via SSH
  - download the Forge txt2img output of a pod

API key resolution (first match wins):
  1. first argument
  2. RUNPOD_API_KEY env var
  3. first non-blank line of RUNPOD_API_KEY_FILE (default ~/.config/runpod)

Env vars:
  RUNPOD_API_KEY        RunPod API key
  RUNPOD_API_KEY_FILE   file holding the API key (default ~/.config/runpod)
  RUNPOD_FORGE_DIR      remote images dir (default /home/forge/sd-webui/output/txt2img-images)
  RUNPOD_DOWNLOAD_DIR   local download destination (default current directory)
  RUNPOD_GQL_URL        GraphQL endpoint override (default https://api.runpod.io/graphql)
EOF
}

human_uptime() {
  local s=${1:-0}
  local d=$((s / 86400)) h=$(((s % 86400) / 3600)) m=$(((s % 3600) / 60))
  if ((d > 0)); then printf '%dd %dh %dm' "$d" "$h" "$m"
  elif ((h > 0)); then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

require_deps() {
  local d
  for d in curl jq; do
    command -v "$d" >/dev/null 2>&1 || die "missing dependency: $d"
  done
}

CURL_FAIL_BODY=--fail-with-body
if ! curl --help 2>&1 | grep -q -- --fail-with-body; then
  CURL_FAIL_BODY=-f
fi

fetch_pods() {
  curl -sS --max-time 30 "$CURL_FAIL_BODY" -X POST "$GQL_URL?api_key=$API_KEY" \
    -H 'Content-Type: application/json' \
    --data "$(jq -n --arg q "$QUERY" '{query:$q}')"
}

check_resp() {
  local resp=$1 errs
  if ! jq -e . <<<"$resp" >/dev/null 2>&1; then
    die "unexpected API response: ${resp:0:300}"
  fi
  errs=$(jq -r '[.errors[]? | (.message // tojson)] + (if .error then [(.error | tojson)] else [] end) | .[]' <<<"$resp" || true)
  if [[ -n $errs ]]; then
    printf 'API error:\n%s\n' "$errs" >&2
    exit 1
  fi
  jq -e '.data.myself != null' <<<"$resp" >/dev/null || die "unexpected API response: ${resp:0:300}"
}

get_rows() {
  local resp=$1
  jq -r '
    .data.myself.pods[]?
    | . as $p
    | [$p.runtime.ports[]? | select(((.type // "") | ascii_downcase) == "ssh")] as $sshp
    | [$p.runtime.ports[]? | select(((.type // "") | ascii_downcase) == "tcp")] as $tcpp
    | (if ($sshp | length) > 0 then $sshp else $tcpp end) as $cand
    | (if ($cand | length) > 0
       then "\(($cand[0].ip // "?")):\(($cand[0].publicPort // "?"))"
       else "-" end) as $sshtarget
    | [$p.id,
       (($p.name // $p.id) | gsub("[\t\r\n]"; " ")),
       (($p.machine.gpuDisplayName // "-") | gsub("[\t\r\n]"; " ")),
       (if $p.runtime == null then "stopped" else "running" end),
       ($p.runtime.uptimeInSeconds // 0),
       $sshtarget]
    | @tsv' <<<"$resp" | sort -t$'\t' -k4,4 -k2,2
}

DISPLAY_ROWS=()

build_display() {
  local rows=$1 line id name gpu status up ssh
  DISPLAY_ROWS=()
  while IFS=$'\t' read -r id name gpu status up ssh; do
    if [[ -z $id ]]; then continue; fi
    DISPLAY_ROWS+=("$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$id" "$name" "$gpu" "$status" "$(human_uptime "$up")" "$ssh")")
  done <<<"$rows"
}

select_pod_fzf() {
  local sel st=0 header quitrow
  header=$(printf 'ID\tNAME\tGPU\tSTATUS\tUPTIME\tSSH')
  quitrow=$(printf '[q]\tQuit')
  sel=$(printf '%s\n' "$header" "${DISPLAY_ROWS[@]}" "$quitrow" | fzf \
    --header-lines=1 --delimiter=$'\t' --tabstop=4 --height=85% --reverse \
    --prompt='pod> ') || st=$?
  if ((st != 0)); then return 2; fi
  if [[ ${sel%%$'\t'*} == "[q]" ]]; then
    printf '%s\n' 'Bye.'
    exit 0
  fi
  SELECTED_LINE=$sel
}

select_pod_menu() {
  local line id name gpu status uptime ssh idx choice
  while true; do
    echo
    printf '  %-4s %-36s %-26s %-8s %-12s %s\n' '#' 'NAME' 'GPU' 'STATUS' 'UPTIME' 'SSH'
    idx=1
    for line in "${DISPLAY_ROWS[@]}"; do
      IFS=$'\t' read -r id name gpu status uptime ssh <<<"$line"
      printf '  %-4d %-36s %-26s %-8s %-12s %s\n' "$idx" "$name" "$gpu" "$status" "$uptime" "$ssh"
      idx=$((idx + 1))
    done
    printf '  r) refresh   q) quit\n'
    read -rp '  Select pod: ' choice || exit 0
    case $choice in
      r | R) return 2 ;;
      q | Q) printf '%s\n' 'Bye.'; exit 0 ;;
      '' | *[!0-9]*) printf '  Invalid choice: %s\n' "$choice"; continue ;;
    esac
    if ((choice >= 1 && choice <= ${#DISPLAY_ROWS[@]})); then
      SELECTED_LINE=${DISPLAY_ROWS[choice - 1]}
      return 0
    fi
    printf '  Out of range: %s\n' "$choice"
  done
}

ssh_candidates() {
  jq -r --arg id "$1" '
    .data.myself.pods[]?
    | select(.id == $id)
    | [.runtime.ports[]? | select(((.type // "") | ascii_downcase) == "ssh")] +
      [.runtime.ports[]? | select(((.type // "") | ascii_downcase) == "tcp")]
    | .[]
    | "\(.ip):\(.publicPort)"' <<<"$RESP_JSON"
}

has_ssh_banner() {
  local hostport=$1
  local host=${hostport%:*} port=${hostport##*:} banner
  banner=$(timeout 8 curl -s --max-time 3 "telnet://$host:$port" </dev/null 2>/dev/null | head -c 32 || true)
  [[ $banner == SSH-2.0-* ]]
}

pick_ssh_target() {
  local id=$1 cands first count c
  local cand_list=()
  cands=$(ssh_candidates "$id")
  if [[ -z $cands ]]; then return 1; fi
  mapfile -t cand_list <<<"$cands"
  first=${cand_list[0]}
  count=${#cand_list[@]}
  if ((count == 1)); then
    printf '%s\n' "$first"
    return 0
  fi
  printf 'Multiple SSH candidates, probing for the real SSH port...\n' >&2
  for c in "${cand_list[@]}"; do
    if has_ssh_banner "$c"; then
      printf 'Found SSH on %s\n' "$c" >&2
      printf '%s\n' "$c"
      return 0
    fi
  done
  printf 'No SSH banner found, using %s\n' "$first" >&2
  printf '%s\n' "$first"
}

connect_ssh() {
  local host=$1 port=$2
  printf '\nConnecting: ssh -p %s root@%s\n' "$port" "$host"
  if ssh -t -p "$port" "${SSH_OPTS[@]}" "root@$host"; then
    printf '\nSSH session ended.\n'
  else
    printf '\nSSH session ended with an error.\n'
  fi
}

download_images() {
  local host=$1 port=$2 mode=${3:-scp} dst="${DL_DEST%/}/txt2img-images"
  printf '\nDownloading %s from %s:%s to %s (mode: %s)\n' "$FORGE_OUT_DIR" "$host" "$port" "$dst" "$mode"
  if [[ $mode == rsync ]] && command -v rsync >/dev/null 2>&1; then
    mkdir -p "$dst" || return 1
    rsync -az --partial --info=progress2 -e "ssh -p $port ${SSH_OPTS[*]}" \
      "root@$host:$FORGE_OUT_DIR/" "$dst/" || return 1
  else
    scp -P "$port" "${SSH_OPTS[@]}" -r "root@$host:$FORGE_OUT_DIR" "$DL_DEST" || return 1
  fi
  printf 'Done. Images are in %s\n' "$dst"
}

ACTION_ITEMS=()
ACTION_HEADER=""

build_action_items() {
  local has_rsync=$1
  ACTION_ITEMS=("[1] Connect via SSH")
  if ((has_rsync)); then
    ACTION_ITEMS+=("[2] Download images with rsync  ($FORGE_OUT_DIR -> ${DL_DEST%/}/txt2img-images)")
    ACTION_ITEMS+=("[3] Download images with scp    ($FORGE_OUT_DIR -> ${DL_DEST%/}/txt2img-images)")
  else
    ACTION_ITEMS+=("[2] Download images with scp  ($FORGE_OUT_DIR -> ${DL_DEST%/}/txt2img-images)")
  fi
  ACTION_ITEMS+=("[b] Back to pod list" "[q] Quit")
}

select_action() {
  local st=0 sel ans key
  if command -v fzf >/dev/null 2>&1 && [[ -t 0 ]]; then
    sel=$(printf '%s\n' "${ACTION_ITEMS[@]}" | fzf \
      --height=60% --reverse --prompt='action> ' \
      --header="${ACTION_HEADER}") || st=$?
    if ((st != 0)); then
      printf 'b\n'
      return 0
    fi
    key=${sel%%[[:space:]]*}
    key=${key#[}
    key=${key%]}
    printf '%s\n' "$key"
    return 0
  fi
  printf '%s\n' "${ACTION_ITEMS[@]}" >&2
  read -rp '  Choose: ' ans || return 1
  printf '%s\n' "$ans"
}

run_pod_actions() {
  local id name gpu status uptime sshstr host port act target desired has_rsync dl_mode
  IFS=$'\t' read -r id name gpu status uptime sshstr <<<"$SELECTED_LINE"
  if [[ $sshstr == "-" ]]; then
    printf '\nPod "%s" is not running (no SSH endpoint).\n' "$name"
    return
  fi
  if ! target=$(pick_ssh_target "$id"); then
    printf '\nPod "%s" is not running (no SSH endpoint).\n' "$name"
    return
  fi
  host=${target%:*}
  port=${target##*:}
  desired=$(jq -r --arg id "$id" \
    '.data.myself.pods[]? | select(.id == $id) | .desiredStatus // "-"' <<<"$RESP_JSON")
  if command -v rsync >/dev/null 2>&1; then has_rsync=1; else has_rsync=0; fi
  if ((has_rsync)); then dl_mode=rsync; else dl_mode=scp; fi
  build_action_items "$has_rsync"
  ACTION_HEADER="Pod: $name ($gpu)  |  SSH: root@$host -p $port"
  echo
  printf '  Pod:     %s  (%s)\n' "$name" "$id"
  printf '  GPU:     %s\n' "$gpu"
  printf '  Status:  %s (desired: %s)\n' "$status" "$desired"
  printf '  Up:      %s\n' "$uptime"
  printf '  SSH:     root@%s -p %s\n' "$host" "$port"
  echo
  while true; do
    act=$(select_action) || exit 0
    case $act in
      1) connect_ssh "$host" "$port" || true ;;
      2) if ! download_images "$host" "$port" "$dl_mode"; then printf '\nDownload failed.\n'; fi ;;
      3) if ((has_rsync)); then
           if ! download_images "$host" "$port" scp; then printf '\nDownload failed.\n'; fi
         else
           printf 'Unknown choice: %s\n' "$act"
         fi ;;
      b | B) return ;;
      q | Q) printf '%s\n' 'Bye.'; exit 0 ;;
      *) printf 'Unknown choice: %s\n' "$act" ;;
    esac
  done
}

main() {
  require_deps
  case ${1:-} in
    -h | --help) usage; exit 0 ;;
  esac
  if [[ -n ${1:-} ]]; then
    API_KEY=$1
  elif [[ -n ${RUNPOD_API_KEY:-} ]]; then
    API_KEY=$RUNPOD_API_KEY
  elif [[ -f $KEY_FILE ]]; then
    while IFS= read -r API_KEY || [[ -n $API_KEY ]]; do
      API_KEY=${API_KEY//[[:space:]]/}
      if [[ -n $API_KEY ]]; then break; fi
    done <"$KEY_FILE"
  fi
  if [[ -z $API_KEY ]]; then
    die "no API key: pass it as an argument, set RUNPOD_API_KEY, or put it in $KEY_FILE"
  fi
  while true; do
    printf '%s\n' 'Fetching pods from RunPod...'
    resp=$(fetch_pods) || true
    check_resp "$resp"
    RESP_JSON=$resp
    build_display "$(get_rows "$resp")"
    if ((${#DISPLAY_ROWS[@]} == 0)); then
      printf '%s\n' 'No pods found on your RunPod account.'
      exit 0
    fi
    while true; do
      local rc=0
      if command -v fzf >/dev/null 2>&1 && [[ -t 0 ]]; then
        select_pod_fzf || rc=$?
      else
        select_pod_menu || rc=$?
      fi
      if ((rc == 2)); then break; fi
      if ((rc == 0)); then
        run_pod_actions
      fi
    done
    echo
  done
}

main "$@"
