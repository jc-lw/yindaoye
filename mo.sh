
# mo_v13_fast.sh
# Fast controller:
#   1) reuse/create 2 usable billed projects
#   2) parallel Vertex Authorization AQ extraction
#   3) in parallel, reuse/create and verify one SOCKS5 proxy
#   4) print only the final proxy + AQ keys
#
# Compatible with the current jc-lw/yindaoye test.sh function library.
# Normal final format intentionally stays compatible with mo_v12:
#
# ================= FINAL RESULT ================
# socks5://user:pass@1.2.3.4:1080
#
# AQ....
# AQ....

set -uo pipefail

VERSION="13.0.0-fast"
TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"

REUSE_PROXY="${REUSE_PROXY:-1}"
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_ZONE_TRIES="${PROXY_ZONE_TRIES:-8}"
PROXY_ZONES_PER_PROJECT="${PROXY_ZONES_PER_PROJECT:-3}"
PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-180}"
PROXY_REUSE_GRACE_SECONDS="${PROXY_REUSE_GRACE_SECONDS:-8}"
PROXY_SCAN_JOBS="${PROXY_SCAN_JOBS:-6}"
BILLING_SCAN_JOBS="${BILLING_SCAN_JOBS:-6}"
KEY_SCAN_JOBS="${KEY_SCAN_JOBS:-4}"
KEY_SCAN_LIMIT="${KEY_SCAN_LIMIT:-12}"

[[ "$NEED_PROJECTS" =~ ^[1-9][0-9]*$ ]] || NEED_PROJECTS=2
[[ "$PROXY_SCAN_JOBS" =~ ^[1-9][0-9]*$ ]] || PROXY_SCAN_JOBS=6
[[ "$BILLING_SCAN_JOBS" =~ ^[1-9][0-9]*$ ]] || BILLING_SCAN_JOBS=6
[[ "$KEY_SCAN_JOBS" =~ ^[1-9][0-9]*$ ]] || KEY_SCAN_JOBS=4
[[ "$KEY_SCAN_LIMIT" =~ ^[1-9][0-9]*$ ]] || KEY_SCAN_LIMIT=12
[[ "$PROXY_REUSE_GRACE_SECONDS" =~ ^[0-9]+$ ]] || PROXY_REUSE_GRACE_SECONDS=8

# Keep the stable test.sh SA propagation waits untouched.
export PROJECT_SUBMIT_GAP="${PROJECT_SUBMIT_GAP:-1}"
export PROJECT_CREATE_GAP="${PROJECT_CREATE_GAP:-1}"
export API_BATCH_GAP="${API_BATCH_GAP:-0}"
export API_REPAIR_ROUNDS="${API_REPAIR_ROUNDS:-2}"
export API_REPAIR_SLEEP="${API_REPAIR_SLEEP:-3}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

say(){ echo -e "${CYAN}${BOLD}[mo]${NC} $*" >&2; }
ok(){ echo -e "${GREEN}[mo] $*${NC}" >&2; }
warn(){ echo -e "${YELLOW}[mo] $*${NC}" >&2; }
err(){ echo -e "${RED}[mo] $*${NC}" >&2; }

for cmd in gcloud curl openssl timeout; do
  command -v "$cmd" >/dev/null 2>&1 || { err "missing command: $cmd"; exit 1; }
done

ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)
[ -z "$ACCOUNT" ] && ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
[ -z "$ACCOUNT" ] || [ "$ACCOUNT" = "(unset)" ] && { err "no active gcloud account"; exit 1; }

say "version: $VERSION"
say "account: $ACCOUNT"

PROXY_OUT="/tmp/mo_proxy_$$.env"
TESTSH="/tmp/mo_testsh_$$.sh"
KEYDIR=""
BILLDIR=""
PROXY_PID=""

FINAL_ARMED=0
FINAL_PRINTED=0
PROXY_READY=0
VKEYS=()

cleanup(){
  rm -f "${PROXY_OUT:-}" "${TESTSH:-}" 2>/dev/null || true
  [ -n "${KEYDIR:-}" ] && rm -rf "$KEYDIR" 2>/dev/null || true
  [ -n "${BILLDIR:-}" ] && rm -rf "$BILLDIR" 2>/dev/null || true
}

emit_final(){
  [ "${FINAL_PRINTED:-0}" = "1" ] && return 0
  FINAL_PRINTED=1

  if [ -s "${PROXY_OUT:-}" ]; then
    # shellcheck disable=SC1090
    source "$PROXY_OUT" 2>/dev/null || true
    [ -n "${PROXY_URL:-}" ] && PROXY_READY=1
  fi

  local final_proxy="SOCKS5_FAILED"
  [ "${PROXY_READY:-0}" = "1" ] && [ -n "${PROXY_URL:-}" ] && final_proxy="$PROXY_URL"

  printf '\n================ FINAL RESULT ================\n%s\n\n' "$final_proxy"
  if declare -p VKEYS >/dev/null 2>&1; then
    printf '%s\n' "${VKEYS[@]:0:${NEED_PROJECTS:-2}}"
  fi
}

on_exit(){
  local rc=$?
  trap - EXIT

  if [ -n "${PROXY_PID:-}" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
  fi

  if [ "${FINAL_ARMED:-0}" = "1" ] && [ "${FINAL_PRINTED:-0}" != "1" ]; then
    warn "main flow ended early; printing collected result"
    emit_final
  fi

  cleanup
  exit "$rc"
}
trap on_exit EXIT

wait_pid_batch(){
  local p
  for p in "$@"; do
    wait "$p" 2>/dev/null || true
  done
}

# ============================================================
# Load upstream test.sh
# ============================================================
say "download test.sh: $TESTSH_URL"
curl -fsSL "$TESTSH_URL" -o "$TESTSH" || { err "failed to download test.sh"; exit 1; }
bash -n "$TESTSH" || { err "remote test.sh has Bash syntax errors"; exit 1; }

# Disable only the exact top-level main invocation.
sed -i -E 's/^[[:space:]]*main[[:space:]]*$/: # main disabled by mo_v13_fast.sh/' "$TESTSH"

# shellcheck disable=SC1090
source "$TESTSH" >/dev/null 2>&1 || true

# test.sh enables -Euo pipefail and an ERR trap. Keep nounset/pipefail, drop errexit/ERR trap.
set +e +E
set -u
set -o pipefail
trap - ERR 2>/dev/null || true

if ! declare -p BILLING_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then
  declare -gA BILLING_BLOCKED_APIS=()
fi
if ! declare -p PERMISSION_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then
  declare -gA PERMISSION_BLOCKED_APIS=()
fi

for fn in \
  billing_accounts_tsv \
  project_billing_enabled \
  create_projects_exact \
  ensure_vertex_key_apis \
  v27_setup_and_extract_aq_key \
  find_authorization_key_string
do
  declare -F "$fn" >/dev/null 2>&1 || { err "test.sh missing function: $fn"; exit 1; }
done

ok "test.sh function self-check passed"

# ============================================================
# Faster but equivalent Vertex Authorization key lookup.
# Upstream find_authorization_key_string describes each API key twice:
# once for serviceAccountEmail and once for restrictions. This override
# reads one JSON description per key, then calls get-key-string once.
# ============================================================
mo_key_desc_match(){
  local desc="$1"
  local expected_sa="$2"

  if command -v python3 >/dev/null 2>&1; then
    KEY_DESC_JSON="$desc" python3 - "$expected_sa" <<'PY'
import json, os, sys
expected = sys.argv[1]
try:
    d = json.loads(os.environ.get("KEY_DESC_JSON", ""))
except Exception:
    print("0 0")
    raise SystemExit(0)

bound = (d.get("serviceAccountEmail") or "").strip()
targets = ((d.get("restrictions") or {}).get("apiTargets") or [])
vertex = any(isinstance(t, dict) and t.get("service") == "aiplatform.googleapis.com" for t in targets)
print("1" if bound == expected and bound else "0", "1" if vertex else "0")
PY
    return 0
  fi

  local bound_match=0 vertex_match=0
  echo "$desc" | grep -Fq "\"serviceAccountEmail\": \"$expected_sa\"" && bound_match=1
  echo "$desc" | grep -Fq '"service": "aiplatform.googleapis.com"' && vertex_match=1
  printf '%s %s\n' "$bound_match" "$vertex_match"
}

find_authorization_key_string(){
  local project_id="$1"
  local sa_email="$2"
  local keys_list key_name desc matches bound_ok vertex_ok api_key
  local fallback_prefix_key=""

  keys_list=$(gcloud services api-keys list \
    --project="$project_id" \
    --format='value(name)' 2>/dev/null || true)
  [ -z "$keys_list" ] && return 1

  while IFS= read -r key_name; do
    key_name=$(printf '%s' "$key_name" | tr -d '\r' | xargs)
    [ -z "$key_name" ] && continue

    desc=$(gcloud services api-keys describe "$key_name" \
      --project="$project_id" --format=json 2>/dev/null || true)
    [ -z "$desc" ] && continue

    matches=$(mo_key_desc_match "$desc" "$sa_email")
    read -r bound_ok vertex_ok <<< "$matches"
    [ "${vertex_ok:-0}" = "1" ] || continue

    api_key=$(gcloud services api-keys get-key-string "$key_name" \
      --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs || true)
    [ -z "$api_key" ] && continue

    if [ "${bound_ok:-0}" = "1" ]; then
      printf '%s\n' "$api_key"
      return 0
    fi

    if [[ "$api_key" == AQ.* ]] && [ -z "$fallback_prefix_key" ]; then
      fallback_prefix_key="$api_key"
    fi
  done <<< "$keys_list"

  [ -n "$fallback_prefix_key" ] && { printf '%s\n' "$fallback_prefix_key"; return 0; }
  return 1
}

# ============================================================
# SOCKS5 helpers
# ============================================================
mo_proxy_test(){
  local proxy_url="${1:-}" proxy_h
  [ -z "$proxy_url" ] && return 1
  proxy_h="${proxy_url/socks5:\/\//socks5h:\/\/}"

  curl -4 -fsS --connect-timeout 4 --max-time 8 \
    --proxy "$proxy_h" -o /dev/null \
    https://www.google.com/generate_204 >/dev/null 2>&1 && return 0

  curl -4 -fsS --connect-timeout 4 --max-time 8 \
    --proxy "$proxy_h" -o /dev/null \
    https://api.ipify.org >/dev/null 2>&1
}

mo_tcp_test(){
  local host="$1" port="$2"
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

mo_wait_proxy(){
  local proxy_url="$1" host="$2" port="$3"
  local elapsed=0 step=3

  while [ "$elapsed" -lt "$PROXY_WAIT_SECONDS" ]; do
    if mo_tcp_test "$host" "$port" && mo_proxy_test "$proxy_url"; then
      return 0
    fi
    sleep "$step"
    elapsed=$((elapsed + step))
    if [ $((elapsed % 30)) -eq 0 ]; then
      say "[proxy] waiting SOCKS5: ${elapsed}/${PROXY_WAIT_SECONDS}s"
    fi
  done
  return 1
}

mo_ensure_network(){
  local project="$1"

  if gcloud compute networks describe default --project="$project" >/dev/null 2>&1; then
    echo default
    return 0
  fi

  if gcloud compute networks describe kn-proxy-net --project="$project" >/dev/null 2>&1; then
    echo kn-proxy-net
    return 0
  fi

  say "[proxy] no default VPC in $project; creating kn-proxy-net"
  if gcloud compute networks create kn-proxy-net \
      --project="$project" --subnet-mode=auto \
      --bgp-routing-mode=regional --quiet >/dev/null 2>&1; then
    echo kn-proxy-net
    return 0
  fi

  return 1
}

mo_ensure_firewall(){
  local project="$1" network="$2" port="$3" current_network
  local rule="allow-socks5-${port}"
  [ "$network" != "default" ] && rule="allow-socks5-${port}-knproxy"

  if gcloud compute firewall-rules describe "$rule" --project="$project" >/dev/null 2>&1; then
    current_network=$(gcloud compute firewall-rules describe "$rule" \
      --project="$project" --format='value(network)' 2>/dev/null || true)
    current_network=$(basename "$current_network")

    if [ -n "$current_network" ] && [ "$current_network" != "$network" ]; then
      warn "[proxy] firewall $rule belongs to $current_network; rebuilding for $network"
      gcloud compute firewall-rules delete "$rule" \
        --project="$project" --quiet >/dev/null 2>&1 || true
    else
      if gcloud compute firewall-rules update "$rule" \
          --project="$project" \
          --allow="tcp:${port}" \
          --source-ranges="0.0.0.0/0" \
          --target-tags=socks5-proxy \
          --priority=1000 \
          --quiet >/dev/null 2>&1; then
        return 0
      fi

      gcloud compute firewall-rules delete "$rule" \
        --project="$project" --quiet >/dev/null 2>&1 || true
    fi
  fi

  gcloud compute firewall-rules create "$rule" \
    --project="$project" \
    --network="$network" \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules="tcp:${port}" \
    --source-ranges="0.0.0.0/0" \
    --target-tags=socks5-proxy \
    --quiet >/dev/null 2>&1
}

mo_make_startup_script(){
  local path="$1" port="$2" user="$3" pass="$4"

  cat > "$path" <<'VM_EOF'
#!/bin/bash
set -u
exec >>/var/log/mo-microsocks-startup.log 2>&1

PORT="__PORT__"
PROXY_USER="__USER__"
PROXY_PASS="__PASS__"
export DEBIAN_FRONTEND=noninteractive

retry_cmd(){
  local n=1
  while [ "$n" -le 3 ]; do
    "$@" && return 0
    sleep $((n * 3))
    n=$((n + 1))
  done
  return 1
}

systemctl stop microsocks >/dev/null 2>&1 || true

# One apt update only. Prefer the Debian package; compile only as fallback.
if retry_cmd apt-get update -qq; then
  if retry_cmd apt-get install -y --no-install-recommends ca-certificates microsocks; then
    BIN=$(command -v microsocks || true)
    [ -n "$BIN" ] && install -m 0755 "$BIN" /usr/local/bin/microsocks
  else
    retry_cmd apt-get install -y --no-install-recommends ca-certificates build-essential git
    rm -rf /opt/microsocks
    retry_cmd git clone --depth 1 https://github.com/rofl0r/microsocks.git /opt/microsocks
    make -C /opt/microsocks
    install -m 0755 /opt/microsocks/microsocks /usr/local/bin/microsocks
  fi
fi

test -x /usr/local/bin/microsocks || exit 1

cat > /etc/systemd/system/microsocks.service <<SERVICE_EOF
[Unit]
Description=MicroSocks SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/microsocks -p ${PORT} -u ${PROXY_USER} -P ${PROXY_PASS}
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable microsocks >/dev/null 2>&1 || true
systemctl restart microsocks
VM_EOF

  sed -i \
    -e "s/__PORT__/${port}/g" \
    -e "s/__USER__/${user}/g" \
    -e "s/__PASS__/${pass}/g" "$path"
}

mo_save_proxy(){
  local url="$1" hostport="$2" adspower="$3" project="$4" instance="$5" zone="$6"
  {
    printf 'PROXY_URL=%q\n' "$url"
    printf 'PROXY_HOSTPORT=%q\n' "$hostport"
    printf 'PROXY_ADSPOWER=%q\n' "$adspower"
    printf 'PROXY_PROJECT=%q\n' "$project"
    printf 'PROXY_INSTANCE=%q\n' "$instance"
    printf 'PROXY_ZONE=%q\n' "$zone"
  } > "$PROXY_OUT"
}

mo_proxy_metadata_creds(){
  local project="$1" instance="$2" zone="$3"
  local meta

  meta=$(timeout 12 gcloud compute instances describe "$instance" \
    --project="$project" --zone="$zone" \
    --format=json 2>/dev/null || true)
  [ -z "$meta" ] && return 1

  if command -v python3 >/dev/null 2>&1; then
    VM_META_JSON="$meta" python3 - <<'PY'
import json, os
try:
    d = json.loads(os.environ.get("VM_META_JSON", ""))
except Exception:
    raise SystemExit(1)
items = ((d.get("metadata") or {}).get("items") or [])
m = {}
for item in items:
    if isinstance(item, dict) and item.get("key"):
        m[item["key"]] = item.get("value", "")
u = m.get("kn-proxy-user", "")
p = m.get("kn-proxy-pass", "")
if not u or not p:
    raise SystemExit(1)
print(u)
print(p)
PY
    return $?
  fi

  local user pass
  user=$(timeout 12 gcloud compute instances describe "$instance"     --project="$project" --zone="$zone"     --format='value(metadata.items.filter("key:kn-proxy-user").extract("value").flatten())'     2>/dev/null || true)
  pass=$(timeout 12 gcloud compute instances describe "$instance"     --project="$project" --zone="$zone"     --format='value(metadata.items.filter("key:kn-proxy-pass").extract("value").flatten())'     2>/dev/null || true)
  [ -n "$user" ] && [ -n "$pass" ] || return 1
  printf '%s\n%s\n' "$user" "$pass"
}

mo_validate_proxy_candidate(){
  local project="$1" name="$2" zone="$3" ip="$4"
  local creds user pass url

  [ -z "$project" ] || [ -z "$name" ] || [ -z "$zone" ] || [ -z "$ip" ] && return 1
  zone=$(basename "$zone")

  creds=$(mo_proxy_metadata_creds "$project" "$name" "$zone" || true)
  user=$(printf '%s\n' "$creds" | sed -n '1p')
  pass=$(printf '%s\n' "$creds" | sed -n '2p')
  [ -z "$user" ] || [ -z "$pass" ] && return 1

  url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"

  if mo_proxy_test "$url"; then
    mo_save_proxy "$url" "${ip}:${PROXY_PORT}" \
      "${ip}:${PROXY_PORT}:${user}:${pass}" \
      "$project" "$name" "$zone"
    ok "[proxy] reuse verified: $name / $project / $ip"
    return 0
  fi

  [ "$PROXY_REUSE_GRACE_SECONDS" -le 0 ] && return 1
  sleep "$PROXY_REUSE_GRACE_SECONDS"

  if mo_proxy_test "$url"; then
    mo_save_proxy "$url" "${ip}:${PROXY_PORT}" \
      "${ip}:${PROXY_PORT}:${user}:${pass}" \
      "$project" "$name" "$zone"
    ok "[proxy] reuse recovered after grace: $name / $project / $ip"
    return 0
  fi

  return 1
}

mo_find_reusable_proxy(){
  local candidates=("$@")
  local project rows file
  local jobs=()
  local scan_dir candidate_file

  scan_dir=$(mktemp -d /tmp/mo_proxy_scan_XXXXXX)
  candidate_file="$scan_dir/candidates.all"
  : > "$candidate_file"

  # Expensive "instances list" calls are parallelized in bounded batches.
  for project in "${candidates[@]}"; do
    [ -z "$project" ] && continue

    (
      rows=$(timeout 12 gcloud compute instances list         --project="$project"         --filter='name~socks5-node AND status=RUNNING'         --format='value(name,zone,networkInterfaces[0].accessConfigs[0].natIP)'         2>/dev/null || true)
      if [ -n "$rows" ]; then
        file="$scan_dir/${project}.tsv"
        while read -r name zone ip; do
          [ -n "${name:-}" ] && [ -n "${ip:-}" ] &&             printf '%s\t%s\t%s\t%s\n' "$project" "$name" "$zone" "$ip"
        done <<< "$rows" > "$file"
      fi
    ) &
    jobs+=("$!")

    if [ "${#jobs[@]}" -ge "$PROXY_SCAN_JOBS" ]; then
      wait_pid_batch "${jobs[@]}"
      jobs=()
    fi
  done
  [ "${#jobs[@]}" -gt 0 ] && wait_pid_batch "${jobs[@]}"

  cat "$scan_dir"/*.tsv 2>/dev/null > "$candidate_file" || true
  if [ ! -s "$candidate_file" ]; then
    rm -rf "$scan_dir"
    return 1
  fi

  while IFS=$'\t' read -r project name zone ip; do
    if mo_validate_proxy_candidate "$project" "$name" "$zone" "$ip"; then
      rm -rf "$scan_dir"
      return 0
    fi
  done < "$candidate_file"

  rm -rf "$scan_dir"
  return 1
}

mo_show_serial_tail(){
  local project="$1" instance="$2" zone="$3"
  warn "[proxy] startup failed; serial log tail follows"
  gcloud compute instances get-serial-port-output "$instance" \
    --project="$project" --zone="$zone" --port=1 2>/dev/null | tail -n 12 >&2 || true
}

build_proxy(){
  local candidates=("$@")
  local project startup user pass url ip instance zone vm_out rc
  local attempt_total=0 project_attempt candidate_index=0
  local network billing_hint enable_out enable_rc
  local zones try_zone

  if [ "$REUSE_PROXY" != "0" ]; then
    say "[proxy] parallel inventory scan across ${#candidates[@]} project(s)"
    if mo_find_reusable_proxy "${candidates[@]}"; then
      return 0
    fi
  fi

  for project in "${candidates[@]}"; do
    [ -z "$project" ] && continue
    candidate_index=$((candidate_index + 1))

    # This is informational only. Failure does not block the real VM attempt.
    billing_hint="unknown"
    if project_billing_enabled "$project" 2>/dev/null; then
      billing_hint="true"
    fi
    say "[proxy] create candidate $candidate_index/${#candidates[@]}: $project (billingEnabled=$billing_hint)"

    user="usr$(openssl rand -hex 4)"
    pass="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    startup="/tmp/mo_startup_$$.sh"
    mo_make_startup_script "$startup" "$PROXY_PORT" "$user" "$pass"

    zones=(
      us-west1-a us-west1-b us-west1-c
      us-central1-a us-central1-b us-central1-c
      us-east1-b us-east1-c us-east1-d
      us-east4-a us-east4-b us-east4-c
      us-east5-a us-east5-b us-east5-c
      us-west2-a us-west2-b us-west2-c
      us-west3-a us-west3-b us-west3-c
      us-west4-a us-west4-b us-west4-c
      us-south1-a us-south1-b us-south1-c
    )

    if [ "${PROXY_SHUFFLE_ZONES:-1}" = "1" ] && command -v shuf >/dev/null 2>&1; then
      mapfile -t zones < <(printf '%s\n' "${zones[@]}" | shuf)
    fi

    project_attempt=0
    network="default"

    for try_zone in "${zones[@]}"; do
      zone="$try_zone"

      [ "$attempt_total" -ge "$PROXY_ZONE_TRIES" ] && break 2
      [ "$project_attempt" -ge "$PROXY_ZONES_PER_PROJECT" ] && break

      attempt_total=$((attempt_total + 1))
      project_attempt=$((project_attempt + 1))
      instance="socks5-node-$(date +%s)-${attempt_total}"

      say "[proxy] [$project] VM-first create $zone (total ${attempt_total}/${PROXY_ZONE_TRIES})"

      vm_out=$(gcloud compute instances create "$instance" \
        --project="$project" \
        --zone="$zone" \
        --machine-type=e2-micro \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --tags=socks5-proxy \
        --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
        --metadata-from-file=startup-script="$startup" \
        --quiet 2>&1)
      rc=$?

      # Preserve the current kn/le-compatible fallback order.
      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE \
          'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
        warn "[proxy] [$project] Compute API disabled; enable, wait 30s, retry same zone"
        enable_out=$(gcloud services enable compute.googleapis.com \
          --project="$project" --quiet 2>&1)
        enable_rc=$?
        [ "$enable_rc" -ne 0 ] && \
          warn "[proxy] [$project] enable returned: $(echo "$enable_out" | tail -n 3 | tr '\n' ' ' | cut -c1-220)"

        sleep 30

        vm_out=$(gcloud compute instances create "$instance" \
          --project="$project" \
          --zone="$zone" \
          --machine-type=e2-micro \
          --image-family=debian-12 \
          --image-project=debian-cloud \
          --tags=socks5-proxy \
          --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
          --metadata-from-file=startup-script="$startup" \
          --quiet 2>&1)
        rc=$?
      fi

      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE \
          'default network.*not found|network.*default.*not found|resource.*default.*not found'; then
        network=$(mo_ensure_network "$project" || true)
        if [ -n "$network" ]; then
          vm_out=$(gcloud compute instances create "$instance" \
            --project="$project" \
            --zone="$zone" \
            --machine-type=e2-micro \
            --image-family=debian-12 \
            --image-project=debian-cloud \
            --tags=socks5-proxy \
            --network="$network" \
            --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
            --metadata-from-file=startup-script="$startup" \
            --quiet 2>&1)
          rc=$?
        fi
      fi

      if [ "$rc" -ne 0 ]; then
        if echo "$vm_out" | grep -qiE \
            'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable|resource pool exhausted'; then
          warn "[proxy] [$project] $zone out of stock; next zone"
          continue
        fi

        if echo "$vm_out" | grep -qiE \
            'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
          warn "[proxy] [$project] Compute still unavailable; next project"
          break
        fi

        if echo "$vm_out" | grep -qiE \
            'PERMISSION_DENIED|AUTH_PERMISSION_DENIED|FAILED_PRECONDITION|UREQ_PROJECT_BILLING_NOT_OPEN|UREQ_PROJECT_BILLING_NOT_FOUND|billing|BILLING|QUOTA_EXCEEDED|quota.*exceeded'; then
          warn "[proxy] [$project] Billing/permission/quota rejected VM; next project"
          break
        fi

        warn "[proxy] [$project] $zone create failed; next zone: $(echo "$vm_out" | tail -n1 | cut -c1-180)"
        sleep 2
        continue
      fi

      ok "[proxy] VM created: $instance / $project / $zone"

      network=$(gcloud compute instances describe "$instance" \
        --project="$project" --zone="$zone" \
        --format='get(networkInterfaces[0].network)' 2>/dev/null || true)
      network=$(basename "${network:-default}")
      [ -z "$network" ] && network="default"

      if ! mo_ensure_firewall "$project" "$network" "$PROXY_PORT"; then
        warn "[proxy] firewall first attempt failed; retry in 4s"
        sleep 4
        mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      fi

      ip=$(gcloud compute instances describe "$instance" \
        --project="$project" --zone="$zone" \
        --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)

      if [ -z "$ip" ]; then
        warn "[proxy] VM has no public IPv4; delete and continue"
        gcloud compute instances delete "$instance" \
          --project="$project" --zone="$zone" \
          --delete-disks=all --quiet >/dev/null 2>&1 || true
        continue
      fi

      url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"
      say "[proxy] waiting microsocks + firewall + authenticated request: ${ip}:${PROXY_PORT}"

      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" \
          "${ip}:${PROXY_PORT}:${user}:${pass}" \
          "$project" "$instance" "$zone"
        ok "[proxy] verified: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      warn "[proxy] first wait failed; repair firewall + reset VM once"
      mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      gcloud compute instances reset "$instance" \
        --project="$project" --zone="$zone" --quiet >/dev/null 2>&1 || true

      sleep 8

      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" \
          "${ip}:${PROXY_PORT}:${user}:${pass}" \
          "$project" "$instance" "$zone"
        ok "[proxy] fallback repair verified: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      mo_show_serial_tail "$project" "$instance" "$zone"
      gcloud compute instances delete "$instance" \
        --project="$project" --zone="$zone" \
        --delete-disks=all --quiet >/dev/null 2>&1 || true
    done

    rm -f "$startup"
  done

  err "[proxy] all candidate projects failed"
  return 1
}

# ============================================================
# Stage 1: Billing / Project inventory
# ============================================================
say "================ Stage 1: Billing / Project ================"

BILLING_ID="${BILLING_ID:-}"
if [ -z "$BILLING_ID" ]; then
  BILLING_ID=$(billing_accounts_tsv 2>/dev/null | awk -F'\t' 'NF{print $1; exit}')
  BILLING_ID="${BILLING_ID#billingAccounts/}"
fi
[ -z "$BILLING_ID" ] && { err "no Billing Account found"; exit 1; }

say "Billing Account selected: $BILLING_ID"

mapfile -t NOORG_PIDS < <(
  gcloud projects list \
    --format='value(projectId)' \
    --filter='parent.type!=organization AND parent.type!=folder' \
    2>/dev/null | awk 'NF && !seen[$0]++'
)

[ "${#NOORG_PIDS[@]}" -eq 0 ] && warn "no existing no-org projects found"

# One billing describe per project, not two. Scan in bounded parallel batches.
BILLDIR=$(mktemp -d /tmp/mo_billing_XXXXXX)
jobs=()

for pid in "${NOORG_PIDS[@]}"; do
  (
    info=$(gcloud billing projects describe "$pid" \
      --format='value(billingAccountName,billingEnabled)' 2>/dev/null || true)

    acct=$(printf '%s' "$info" | awk '{print $1}')
    enabled=$(printf '%s' "$info" | awk '{print $2}')
    acct="${acct#billingAccounts/}"
    enabled=$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

    printf '%s\t%s\t%s\n' "$pid" "$acct" "$enabled" > "$BILLDIR/$pid.tsv"
  ) &
  jobs+=("$!")

  if [ "${#jobs[@]}" -ge "$BILLING_SCAN_JOBS" ]; then
    wait_pid_batch "${jobs[@]}"
    jobs=()
  fi
done
[ "${#jobs[@]}" -gt 0 ] && wait_pid_batch "${jobs[@]}"

SELECTED_BILLED_PIDS=()
OTHER_BILLED_PIDS=()
SELECTED_LINKED_PIDS=()
OTHER_LINKED_PIDS=()

for pid in "${NOORG_PIDS[@]}"; do
  [ -s "$BILLDIR/$pid.tsv" ] || continue
  IFS=$'\t' read -r _pid acct enabled < "$BILLDIR/$pid.tsv"

  if [ "$acct" = "$BILLING_ID" ]; then
    SELECTED_LINKED_PIDS+=("$pid")
    [ "$enabled" = "true" ] && SELECTED_BILLED_PIDS+=("$pid")
  elif [ -n "$acct" ] && [ "$acct" != "None" ]; then
    OTHER_LINKED_PIDS+=("$pid")
    [ "$enabled" = "true" ] && OTHER_BILLED_PIDS+=("$pid")
  fi
done

say "selected billing: linked=${#SELECTED_LINKED_PIDS[@]} enabled=${#SELECTED_BILLED_PIDS[@]}"
say "other billing: linked=${#OTHER_LINKED_PIDS[@]} enabled=${#OTHER_BILLED_PIDS[@]}"

# Existing AQ may still be reusable on a linked project even when billingEnabled is false.
mapfile -t KEY_REUSE_CANDIDATES < <(
  printf '%s\n' \
    "${SELECTED_BILLED_PIDS[@]}" \
    "${OTHER_BILLED_PIDS[@]}" \
    "${SELECTED_LINKED_PIDS[@]}" \
    "${OTHER_LINKED_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)

# For NEW key work, follow kn's stronger rule: prefer billingEnabled=true projects.
mapfile -t KEY_WORK_CANDIDATES < <(
  printf '%s\n' \
    "${SELECTED_BILLED_PIDS[@]}" \
    "${OTHER_BILLED_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)

declare -A PREKEY_BY_PID=()
KEY_PIDS=()

# Scan existing AQ keys in bounded parallel batches. Stop after enough are found.
if [ "${#KEY_REUSE_CANDIDATES[@]}" -gt 0 ]; then
  KEY_SCAN_DIR=$(mktemp -d /tmp/mo_prekeys_XXXXXX)
  scan_count=0
  start=0

  while [ "$start" -lt "${#KEY_REUSE_CANDIDATES[@]}" ] && \
        [ "${#KEY_PIDS[@]}" -lt "$NEED_PROJECTS" ] && \
        [ "$scan_count" -lt "$KEY_SCAN_LIMIT" ]; do

    jobs=()
    batch_pids=()
    n=0

    while [ "$n" -lt "$KEY_SCAN_JOBS" ] && \
          [ "$start" -lt "${#KEY_REUSE_CANDIDATES[@]}" ] && \
          [ "$scan_count" -lt "$KEY_SCAN_LIMIT" ]; do
      pid="${KEY_REUSE_CANDIDATES[$start]}"
      start=$((start + 1))
      scan_count=$((scan_count + 1))
      batch_pids+=("$pid")

      (
        sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
        existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | \
          grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
        [ -n "$existing_key" ] && printf '%s\n' "$existing_key" > "$KEY_SCAN_DIR/$pid.key"
      ) &
      jobs+=("$!")
      n=$((n + 1))
    done

    wait_pid_batch "${jobs[@]}"

    for pid in "${batch_pids[@]}"; do
      if [ -s "$KEY_SCAN_DIR/$pid.key" ]; then
        existing_key=$(head -n1 "$KEY_SCAN_DIR/$pid.key")
        if [ -z "${PREKEY_BY_PID[$pid]:-}" ]; then
          PREKEY_BY_PID["$pid"]="$existing_key"
          KEY_PIDS+=("$pid")
          ok "existing AQ: $pid / ${existing_key:0:12}..."
          [ "${#KEY_PIDS[@]}" -ge "$NEED_PROJECTS" ] && break
        fi
      fi
    done
  done

  rm -rf "$KEY_SCAN_DIR"
fi

NEED_SLOTS=$((NEED_PROJECTS - ${#KEY_PIDS[@]}))
WORK_PIDS=()

if [ "$NEED_SLOTS" -gt 0 ]; then
  for pid in "${KEY_WORK_CANDIDATES[@]}"; do
    [ -n "${PREKEY_BY_PID[$pid]:-}" ] && continue
    WORK_PIDS+=("$pid")
    [ "${#WORK_PIDS[@]}" -ge "$NEED_SLOTS" ] && break
  done
fi

MISSING_PROJECTS=$((NEED_SLOTS - ${#WORK_PIDS[@]}))
NEW_PIDS=()

if [ "$MISSING_PROJECTS" -gt 0 ]; then
  say "need $MISSING_PROJECTS new billed project(s)"
  create_projects_exact "$MISSING_PROJECTS" "$BILLING_ID" NEW_PIDS "mo-v13-fast" || true

  for pid in "${NEW_PIDS[@]}"; do
    [ -z "$pid" ] && continue

    if project_billing_enabled "$pid" 2>/dev/null; then
      WORK_PIDS+=("$pid")
    else
      warn "new project $pid is not billingEnabled yet; skip it for new Vertex key work"
    fi
  done
fi

mapfile -t KEY_PROJECTS < <(
  printf '%s\n' "${KEY_PIDS[@]}" "${WORK_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)
KEY_PROJECTS=("${KEY_PROJECTS[@]:0:$NEED_PROJECTS}")

if [ "${#KEY_PROJECTS[@]}" -lt "$NEED_PROJECTS" ]; then
  err "could not determine $NEED_PROJECTS usable key projects"
  exit 1
fi

say "final key projects (${#KEY_PROJECTS[@]}): ${KEY_PROJECTS[*]}"

# ============================================================
# Start SOCKS5 in background BEFORE Stage 2.
# This restores kn.sh's important critical-path optimization:
# proxy setup overlaps Vertex API/SA/key propagation.
# ============================================================
mapfile -t ALL_PIDS < <(
  gcloud projects list --format='value(projectId)' 2>/dev/null |
  awk 'NF && !seen[$0]++'
)

DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
[ "$DEFAULT_PROJECT" = "(unset)" ] && DEFAULT_PROJECT=""

mapfile -t PROXY_CREATE_PIDS < <(
  printf '%s\n' \
    "$DEFAULT_PROJECT" \
    "${KEY_PROJECTS[@]}" \
    "${ALL_PIDS[@]}" |
  awk 'NF && !seen[$0]++'
)

FINAL_ARMED=1

say "[parallel] start proxy task now; Vertex key extraction continues in foreground"
build_proxy "${PROXY_CREATE_PIDS[@]}" &
PROXY_PID=$!

# ============================================================
# Stage 2: Vertex AQ keys, parallel per project
# ============================================================
say "================ Stage 2: Vertex Key ======================="

KEYDIR=$(mktemp -d /tmp/mo_keys_XXXXXX)
KPIDS=()

for pid in "${KEY_PROJECTS[@]}"; do
  (
    existing_key="${PREKEY_BY_PID[$pid]:-}"

    if [ -z "$existing_key" ]; then
      sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
      existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | \
        grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
    fi

    if [ -n "$existing_key" ]; then
      printf '%s\n' "$existing_key" > "$KEYDIR/$pid.key"
      echo "[$pid] Existing AQ -> reuse: ${existing_key:0:12}..." >&2
      exit 0
    fi

    if ! ensure_vertex_key_apis "$pid" "mo-v13-Vertex" >&2; then
      echo "[$pid] Vertex required APIs not ready" >&2
      exit 0
    fi

    vkey=$(v27_setup_and_extract_aq_key "$pid" 1 2>/dev/null | \
      grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)

    if [ -n "$vkey" ]; then
      printf '%s\n' "$vkey" > "$KEYDIR/$pid.key"
      echo "[$pid] Vertex AQ ready: ${vkey:0:12}..." >&2
    else
      echo "[$pid] Vertex AQ failed" >&2
    fi
  ) &
  KPIDS+=("$!")
done

wait_pid_batch "${KPIDS[@]}"

VKEYS=()
for pid in "${KEY_PROJECTS[@]}"; do
  if [ -s "$KEYDIR/$pid.key" ]; then
    k=$(head -n1 "$KEYDIR/$pid.key")
    duplicate=0

    for old in "${VKEYS[@]}"; do
      [ "$k" = "$old" ] && { duplicate=1; break; }
    done

    [ "$duplicate" = "0" ] && [ -n "$k" ] && VKEYS+=("$k")
  fi
done

KEY_STAGE_OK=1
if [ "${#VKEYS[@]}" -lt "$NEED_PROJECTS" ]; then
  KEY_STAGE_OK=0
  err "Vertex key stage: got ${#VKEYS[@]}/$NEED_PROJECTS"
else
  VKEYS=("${VKEYS[@]:0:$NEED_PROJECTS}")
  ok "Vertex key stage complete: ${#VKEYS[@]}/$NEED_PROJECTS"
fi

# ============================================================
# Stage 3: wait for parallel SOCKS5 task and verify once more
# ============================================================
say "================ Stage 3: SOCKS5 ==========================="

wait "$PROXY_PID" 2>/dev/null || true
PROXY_PID=""

if [ -s "$PROXY_OUT" ]; then
  # shellcheck disable=SC1090
  source "$PROXY_OUT" 2>/dev/null || true

  if mo_proxy_test "${PROXY_URL:-}"; then
    PROXY_READY=1
  else
    PROXY_READY=0
    warn "final authenticated SOCKS5 verification failed"
  fi
fi

# ============================================================
# Stage 4: output
# ============================================================
emit_final

FINAL_RC=0
[ "$KEY_STAGE_OK" = "1" ] || FINAL_RC=1
[ "$PROXY_READY" = "1" ] || FINAL_RC=1

exit "$FINAL_RC"
