
# mo_v7.sh
# Minimal controller: reuse/create 2 billed projects -> parallel Vertex AQ keys
# + account-wide SOCKS5 reuse/create with repair/fallback -> print only.
set -uo pipefail

VERSION="7.0.0"
TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"
REUSE_PROXY="${REUSE_PROXY:-1}"
REUSE_KEYS="${REUSE_KEYS:-1}"
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_ZONE_TRIES="${PROXY_ZONE_TRIES:-8}"
PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-180}"

# Only shorten waits used by test.sh. Vertex SA propagation waits are untouched.
export PROJECT_SUBMIT_GAP="${PROJECT_SUBMIT_GAP:-1}"
export PROJECT_CREATE_GAP="${PROJECT_CREATE_GAP:-1}"
export API_BATCH_GAP="${API_BATCH_GAP:-0}"
export API_REPAIR_ROUNDS="${API_REPAIR_ROUNDS:-2}"
export API_REPAIR_SLEEP="${API_REPAIR_SLEEP:-3}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
say(){ echo -e "${CYAN}${BOLD}[mo]${NC} $*"; }
ok(){ echo -e "${GREEN}[mo] $*${NC}"; }
warn(){ echo -e "${YELLOW}[mo] $*${NC}"; }
err(){ echo -e "${RED}[mo] $*${NC}"; }

command -v gcloud >/dev/null 2>&1 || { err "未找到 gcloud"; exit 1; }
command -v curl >/dev/null 2>&1 || { err "未找到 curl"; exit 1; }
command -v openssl >/dev/null 2>&1 || { err "未找到 openssl"; exit 1; }

ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)
[ -z "$ACCOUNT" ] && ACCOUNT=$(gcloud config get-value account 2>/dev/null)
[ -z "$ACCOUNT" ] && { err "没有已登录的 gcloud 账号"; exit 1; }
say "当前账号: $ACCOUNT"

PROXY_OUT="/tmp/mo_proxy_$$.env"
TESTSH="/tmp/mo_testsh_$$.sh"
KEYDIR=""
cleanup(){ rm -f "$PROXY_OUT" "$TESTSH" 2>/dev/null || true; [ -n "${KEYDIR:-}" ] && rm -rf "$KEYDIR" 2>/dev/null || true; }
trap cleanup EXIT

# ============================================================
# SOCKS5 helpers
# ============================================================
mo_proxy_test() {
  local proxy_url="$1" proxy_h
  proxy_h="${proxy_url/socks5:\/\//socks5h:\/\/}"
  curl -4 -fsS --connect-timeout 5 --max-time 10 \
    --proxy "$proxy_h" \
    -o /dev/null https://www.google.com/generate_204 >/dev/null 2>&1 && return 0
  curl -4 -fsS --connect-timeout 5 --max-time 10 \
    --proxy "$proxy_h" \
    -o /dev/null https://api.ipify.org >/dev/null 2>&1
}

mo_tcp_test() {
  local host="$1" port="$2"
  timeout 4 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

mo_wait_proxy() {
  local proxy_url="$1" host="$2" port="$3"
  local elapsed=0 step=5
  while [ "$elapsed" -lt "$PROXY_WAIT_SECONDS" ]; do
    if mo_tcp_test "$host" "$port" && mo_proxy_test "$proxy_url"; then
      return 0
    fi
    sleep "$step"
    elapsed=$((elapsed + step))
    if [ $((elapsed % 30)) -eq 0 ]; then
      say "[代理] 等待 SOCKS5 就绪: ${elapsed}/${PROXY_WAIT_SECONDS}s"
    fi
  done
  return 1
}

mo_ensure_compute_api() {
  local project="$1" i
  for i in 1 2 3; do
    if gcloud services list --project="$project" --enabled \
      --filter='config.name=compute.googleapis.com' \
      --format='value(config.name)' 2>/dev/null | grep -qx 'compute.googleapis.com'; then
      return 0
    fi
    say "[代理] 启用 Compute Engine API (${i}/3)..."
    gcloud services enable compute.googleapis.com --project="$project" --quiet >/dev/null 2>&1 || true
    sleep 5
  done
  gcloud services list --project="$project" --enabled \
    --filter='config.name=compute.googleapis.com' \
    --format='value(config.name)' 2>/dev/null | grep -qx 'compute.googleapis.com'
}

mo_ensure_network() {
  local project="$1"
  if gcloud compute networks describe default --project="$project" >/dev/null 2>&1; then
    echo default
    return 0
  fi
  if gcloud compute networks describe kn-proxy-net --project="$project" >/dev/null 2>&1; then
    echo kn-proxy-net
    return 0
  fi
  say "[代理] 项目没有 default 网络，创建 kn-proxy-net 自动模式网络..." >&2
  if gcloud compute networks create kn-proxy-net --project="$project" \
      --subnet-mode=auto --bgp-routing-mode=regional --quiet >/dev/null 2>&1; then
    echo kn-proxy-net
    return 0
  fi
  return 1
}

mo_ensure_firewall() {
  local project="$1" network="$2" port="$3" current_network
  local rule="allow-socks5-${port}"
  [ "$network" != "default" ] && rule="allow-socks5-${port}-knproxy"

  if gcloud compute firewall-rules describe "$rule" --project="$project" >/dev/null 2>&1; then
    current_network=$(gcloud compute firewall-rules describe "$rule" --project="$project" \
      --format='value(network)' 2>/dev/null || true)
    current_network=$(basename "$current_network")
    if [ -n "$current_network" ] && [ "$current_network" != "$network" ]; then
      warn "[代理] 旧防火墙规则属于网络 $current_network，不是 $network；删除后重建" >&2
      gcloud compute firewall-rules delete "$rule" --project="$project" --quiet >/dev/null 2>&1 || true
    else
      # Existing does not automatically mean correct. Repair its allow/source/tag fields.
      if gcloud compute firewall-rules update "$rule" --project="$project" \
        --allow="tcp:${port}" --source-ranges="0.0.0.0/0" \
        --target-tags=socks5-proxy --priority=1000 --quiet >/dev/null 2>&1; then
        ok "[代理] 防火墙规则已检查/修复: $rule" >&2
        return 0
      fi
      warn "[代理] 旧防火墙规则无法更新，删除后重建: $rule" >&2
      gcloud compute firewall-rules delete "$rule" --project="$project" --quiet >/dev/null 2>&1 || true
    fi
  fi

  if gcloud compute firewall-rules create "$rule" --project="$project" \
    --network="$network" --direction=INGRESS --priority=1000 \
    --action=ALLOW --rules="tcp:${port}" --source-ranges="0.0.0.0/0" \
    --target-tags=socks5-proxy --quiet >/dev/null 2>&1; then
    ok "[代理] 防火墙规则已创建: $rule" >&2
    return 0
  fi
  return 1
}

mo_make_startup_script() {
  local path="$1" port="$2" user="$3" pass="$4"
  cat > "$path" <<'VM_EOF'
#!/bin/bash
set -u
exec >>/var/log/mo-microsocks-startup.log 2>&1
PORT="__PORT__"
PROXY_USER="__USER__"
PROXY_PASS="__PASS__"
export DEBIAN_FRONTEND=noninteractive

retry_cmd() {
  local n=1
  while [ "$n" -le 3 ]; do
    "$@" && return 0
    sleep $((n * 4))
    n=$((n + 1))
  done
  return 1
}

systemctl stop microsocks >/dev/null 2>&1 || true

# First try Debian package. If unavailable/fails, fall back to the original kn.sh source-build method.
if retry_cmd apt-get update && retry_cmd apt-get install -y ca-certificates microsocks; then
  BIN=$(command -v microsocks || true)
  [ -n "$BIN" ] && cp "$BIN" /usr/local/bin/microsocks
else
  retry_cmd apt-get update || true
  retry_cmd apt-get install -y ca-certificates build-essential git
  rm -rf /opt/microsocks
  retry_cmd git clone --depth 1 https://github.com/rofl0r/microsocks.git /opt/microsocks
  make -C /opt/microsocks
  install -m 0755 /opt/microsocks/microsocks /usr/local/bin/microsocks
fi

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
sleep 2
systemctl --no-pager --full status microsocks || true
ss -lntp | grep ":${PORT}" || true
VM_EOF
  sed -i \
    -e "s/__PORT__/${port}/g" \
    -e "s/__USER__/${user}/g" \
    -e "s/__PASS__/${pass}/g" "$path"
}

mo_save_proxy() {
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

mo_try_reuse_proxy_project() {
  local project="$1"
  local rows name zone ip user pass url
  rows=$(timeout 20 gcloud compute instances list --project="$project" \
    --filter='name~socks5-node AND status=RUNNING' \
    --format='value(name,zone,networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)
  [ -z "$rows" ] && return 1

  while read -r name zone ip; do
    [ -z "${name:-}" ] && continue
    zone=$(basename "$zone")
    [ -z "${ip:-}" ] && continue
    user=$(timeout 15 gcloud compute instances describe "$name" --project="$project" --zone="$zone" \
      --format='value(metadata.items.filter("key:kn-proxy-user").extract("value").flatten())' 2>/dev/null || true)
    pass=$(timeout 15 gcloud compute instances describe "$name" --project="$project" --zone="$zone" \
      --format='value(metadata.items.filter("key:kn-proxy-pass").extract("value").flatten())' 2>/dev/null || true)
    [ -z "$user" ] || [ -z "$pass" ] && continue
    url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"

    # Reuse only after a real authenticated SOCKS5 request succeeds, not just TCP/1080.
    if mo_proxy_test "$url"; then
      mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$name" "$zone"
      ok "[代理] 复用已验证 SOCKS5: $name / $project / $ip"
      return 0
    fi
    warn "[代理] 发现旧代理 $name，但真实 SOCKS5 测试失败，不复用"
  done <<< "$rows"
  return 1
}

mo_show_serial_tail() {
  local project="$1" instance="$2" zone="$3"
  warn "[代理] 启动失败诊断（serial log 最后 12 行）:"
  gcloud compute instances get-serial-port-output "$instance" --project="$project" --zone="$zone" \
    --port=1 2>/dev/null | tail -n 12 >&2 || true
}

build_proxy() {
  local primary_project="$1"
  shift
  local candidates=("$@")
  local project network startup user pass url ip instance zone vm_out rc attempt

  # 1) Reuse across every candidate project supplied by the controller.
  #    Key projects and proxy projects are intentionally decoupled: kn/le may
  #    leave the SOCKS5 VM in a third/non-Key project. A real authenticated
  #    SOCKS5 request must pass before reuse.
  if [ "$REUSE_PROXY" != "0" ]; then
    say "[代理] 扫描当前账号全部候选项目中的现有 socks5-node..."
    for project in "${candidates[@]}"; do
      [ -z "$project" ] && continue
      if mo_try_reuse_proxy_project "$project"; then return 0; fi
    done
  fi

  # 2) Create new proxy in primary target project.
  project="$primary_project"
  [ -z "$project" ] && { err "[代理] 没有可用于创建代理的项目"; return 1; }
  say "[代理] 未找到可复用代理，使用项目 $project 新建"

  if ! mo_ensure_compute_api "$project"; then
    err "[代理] Compute Engine API 未能启用/确认"
    return 1
  fi

  network=$(mo_ensure_network "$project") || { err "[代理] 无可用 VPC 网络，也无法创建 kn-proxy-net"; return 1; }
  say "[代理] 使用网络: $network"

  user="usr$(openssl rand -hex 4)"
  pass="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)"
  startup="/tmp/mo_startup_$$.sh"
  mo_make_startup_script "$startup" "$PROXY_PORT" "$user" "$pass"

  local zones=(
    us-central1-a us-central1-b us-central1-c
    us-east1-b us-east1-c us-east1-d
    us-west1-a us-west1-b us-west1-c
    us-east4-a us-east4-b us-east4-c
    us-east5-a us-east5-b us-east5-c
    us-west2-a us-west2-b us-west2-c
    us-west3-a us-west3-b us-west3-c
    us-west4-a us-west4-b us-west4-c
    us-south1-a us-south1-b us-south1-c
  )
  mapfile -t zones < <(printf '%s\n' "${zones[@]}" | shuf)

  attempt=0
  for zone in "${zones[@]}"; do
    attempt=$((attempt + 1))
    [ "$attempt" -gt "$PROXY_ZONE_TRIES" ] && break
    instance="socks5-node-$(date +%s)-${attempt}"
    say "[代理] 创建 VM: $zone (${attempt}/${PROXY_ZONE_TRIES})"

    vm_out=$(gcloud compute instances create "$instance" \
      --project="$project" --zone="$zone" --machine-type=e2-micro \
      --image-family=debian-12 --image-project=debian-cloud \
      --network="$network" --tags=socks5-proxy \
      --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
      --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?

    if [ "$rc" -ne 0 ]; then
      if echo "$vm_out" | grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable|resource pool exhausted'; then
        warn "[代理] $zone 库存不足，自动换区域"
        continue
      fi
      if echo "$vm_out" | grep -qiE 'PERMISSION_DENIED|QUOTA_EXCEEDED|billing|quota.*exceeded'; then
        err "[代理] 创建 VM 被权限/配额/Billing 阻止: $(echo "$vm_out" | tail -n1 | cut -c1-180)"
        rm -f "$startup"
        return 1
      fi
      warn "[代理] $zone 创建失败，继续换区域: $(echo "$vm_out" | tail -n1 | cut -c1-160)"
      sleep 3
      continue
    fi

    ok "[代理] VM 已创建: $instance / $zone"

    # Firewall fallback #1: create OR repair existing rule.
    if ! mo_ensure_firewall "$project" "$network" "$PROXY_PORT"; then
      warn "[代理] 防火墙首次配置失败，等待 5 秒再修复一次"
      sleep 5
      mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
    fi

    ip=$(gcloud compute instances describe "$instance" --project="$project" --zone="$zone" \
      --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)
    if [ -z "$ip" ]; then
      warn "[代理] VM 没有取得公网 IPv4，删除并换区域"
      gcloud compute instances delete "$instance" --project="$project" --zone="$zone" --delete-disks=all --quiet >/dev/null 2>&1 || true
      continue
    fi

    url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"
    say "[代理] 等待 microsocks + 防火墙 + 真实 SOCKS5 请求通过: ${ip}:${PROXY_PORT}"
    if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
      mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$instance" "$zone"
      ok "[代理] SOCKS5 已验证可用: ${ip}:${PROXY_PORT}"
      rm -f "$startup"
      return 0
    fi

    # Fallback #2: firewall repair + VM reset. Startup script runs again after boot.
    warn "[代理] 首轮真实 SOCKS5 测试失败，执行兜底修复：防火墙重检 + VM reset + startup重跑"
    mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
    gcloud compute instances reset "$instance" --project="$project" --zone="$zone" --quiet >/dev/null 2>&1 || true
    sleep 10

    if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
      mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$instance" "$zone"
      ok "[代理] 兜底修复成功: ${ip}:${PROXY_PORT}"
      rm -f "$startup"
      return 0
    fi

    # Fallback #3: diagnose then delete broken VM and move to another zone.
    mo_show_serial_tail "$project" "$instance" "$zone"
    warn "[代理] 当前 VM 修复后仍不可用，删除坏实例并换下一区域"
    gcloud compute instances delete "$instance" --project="$project" --zone="$zone" --delete-disks=all --quiet >/dev/null 2>&1 || true
  done

  rm -f "$startup"
  err "[代理] 已尝试 ${PROXY_ZONE_TRIES} 个区域，仍未得到通过真实 SOCKS5 测试的代理"
  return 1
}

# ============================================================
# Load test.sh at TOP LEVEL so its declare -A state remains global.
# ============================================================
say "下载 test.sh 函数库: $TESTSH_URL"
curl -fsSL "$TESTSH_URL" -o "$TESTSH" || { err "下载 test.sh 失败"; exit 1; }
bash -n "$TESTSH" || { err "远程 test.sh Bash 语法异常"; exit 1; }
sed -i -E 's/^[[:space:]]*main[[:space:]]*$/: # main disabled by mo_v6.sh/' "$TESTSH"
# shellcheck disable=SC1090
source "$TESTSH" >/dev/null 2>&1 || true
set +e +E
set -u
set -o pipefail
trap - ERR 2>/dev/null || true

# Keep test.sh smart API caches associative even if its implementation changes.
if ! declare -p BILLING_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then declare -gA BILLING_BLOCKED_APIS=(); fi
if ! declare -p PERMISSION_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then declare -gA PERMISSION_BLOCKED_APIS=(); fi

for fn in billing_accounts_tsv project_billing_enabled create_projects_exact ensure_vertex_key_apis v27_setup_and_extract_aq_key find_authorization_key_string; do
  declare -F "$fn" >/dev/null 2>&1 || { err "test.sh 缺少函数: $fn"; exit 1; }
done
ok "test.sh 函数库加载完成"

# ============================================================
# Billing + reuse-first project/key/proxy discovery
# ============================================================
BILLING_ID="${BILLING_ID:-}"
if [ -z "$BILLING_ID" ]; then
  BILLING_ID=$(billing_accounts_tsv 2>/dev/null | awk -F'\t' 'NF{print $1; exit}')
  BILLING_ID="${BILLING_ID#billingAccounts/}"
fi
[ -z "$BILLING_ID" ] && { err "未找到 Billing Account"; exit 1; }
say "使用 Billing Account: $BILLING_ID"

say "扫描全部无组织/Folder父级项目，收集 billingEnabled=true 项目..."
mapfile -t NOORG_PIDS < <(gcloud projects list \
  --format='value(projectId)' \
  --filter='parent.type!=organization AND parent.type!=folder' 2>/dev/null)

BILLED_PIDS=()
for pid in "${NOORG_PIDS[@]:-}"; do
  [ -z "$pid" ] && continue
  if project_billing_enabled "$pid" 2>/dev/null; then
    BILLED_PIDS+=("$pid")
    say "已绑账单: $pid"
  fi
done
say "已绑账单项目总数: ${#BILLED_PIDS[@]}"

# Proxy placement is independent from Vertex-key placement. kn/le can create
# a socks5-node in an older/default project while the two AQ keys live in two
# newly billed projects. Therefore proxy discovery MUST scan every project the
# active gcloud account can see, not only BILLED_PIDS.
mapfile -t ALL_PIDS < <(gcloud projects list --format='value(projectId)' 2>/dev/null | awk 'NF && !seen[$0]++')
mapfile -t PROXY_SCAN_PIDS < <(
  printf '%s\n' "${BILLED_PIDS[@]}" "${ALL_PIDS[@]}" | awk 'NF && !seen[$0]++'
)
say "SOCKS5 扫描项目总数: ${#PROXY_SCAN_PIDS[@]}（全账号可访问项目，不要求 billingEnabled=true）"

# ------------------------------------------------------------
# Reuse pass A: existing SOCKS5 across ALL accessible projects.
# Both kn/le and mo store credentials in kn-proxy-user/pass metadata,
# so the resources are mutually readable. A real authenticated request
# must pass before reuse. No API is enabled and no VM is created here.
# ------------------------------------------------------------
PROXY_READY=0
if [ "$REUSE_PROXY" != "0" ] && [ "${#PROXY_SCAN_PIDS[@]}" -gt 0 ]; then
  say "优先扫描当前账号所有可访问项目中的现有 SOCKS5..."
  for pid in "${PROXY_SCAN_PIDS[@]}"; do
    if mo_try_reuse_proxy_project "$pid"; then
      PROXY_READY=1
      break
    fi
  done
fi

# ------------------------------------------------------------
# Reuse pass B: read existing Vertex Authorization keys first.
# This is read-only: do NOT delete old keys, do NOT create a new key,
# and do NOT touch IAM/API state if a valid existing Vertex key is found.
# ------------------------------------------------------------
VKEYS=()
KEY_PIDS=()
if [ "$REUSE_KEYS" != "0" ] && [ "${#BILLED_PIDS[@]}" -gt 0 ]; then
  say "优先读取现有 Vertex Authorization key；找到即复用，不重新创建..."
  for pid in "${BILLED_PIDS[@]}"; do
    sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
    existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
    if [ -n "$existing_key" ]; then
      VKEYS+=("$existing_key")
      KEY_PIDS+=("$pid")
      ok "复用现有 Vertex key: $pid / ${existing_key:0:12}..."
      [ "${#VKEYS[@]}" -ge "$NEED_PROJECTS" ] && break
    fi
  done
fi

# If le/kn/mo has already left both resources behind, this run is only a reader.
if [ "$PROXY_READY" = "1" ] && [ "${#VKEYS[@]}" -ge "$NEED_PROJECTS" ]; then
  # shellcheck disable=SC1090
  [ -s "$PROXY_OUT" ] && source "$PROXY_OUT"
  printf '\n================ FINAL RESULT ================\n%s\n\n' "$PROXY_URL"
  printf '%s\n' "${VKEYS[@]:0:$NEED_PROJECTS}"
  exit 0
fi

# ------------------------------------------------------------
# Choose only the projects still needed for missing keys.
# Existing-key projects are not sent through ensure/create again.
# ------------------------------------------------------------
NEED_KEYS=$((NEED_PROJECTS - ${#VKEYS[@]}))
WORK_PIDS=()

if [ "$NEED_KEYS" -gt 0 ]; then
  for pid in "${BILLED_PIDS[@]}"; do
    already=0
    for kp in "${KEY_PIDS[@]:-}"; do
      [ "$pid" = "$kp" ] && { already=1; break; }
    done
    [ "$already" = "1" ] && continue
    WORK_PIDS+=("$pid")
    [ "${#WORK_PIDS[@]}" -ge "$NEED_KEYS" ] && break
  done
fi

MISSING_PROJECTS=$((NEED_KEYS - ${#WORK_PIDS[@]}))
NEW_PIDS=()
if [ "$MISSING_PROJECTS" -gt 0 ]; then
  say "现有项目还缺 $MISSING_PROJECTS 个 Key 槽位，补建项目..."
  create_projects_exact "$MISSING_PROJECTS" "$BILLING_ID" NEW_PIDS "mo补建" || true
  for pid in "${NEW_PIDS[@]:-}"; do
    [ -z "$pid" ] && continue
    BILLED_PIDS+=("$pid")
    WORK_PIDS+=("$pid")
    if project_billing_enabled "$pid" 2>/dev/null; then
      ok "新项目 Billing 已生效: $pid"
    else
      warn "新项目 Billing 未确认生效: $pid；仍尝试 Vertex key"
    fi
  done
fi

if [ "${#VKEYS[@]}" -lt "$NEED_PROJECTS" ] && [ "${#WORK_PIDS[@]}" -eq 0 ]; then
  err "没有可用于补齐 Vertex key 的项目"
  exit 1
fi

say "已有 Key=${#VKEYS[@]}，需要新提取=$NEED_KEYS，处理项目=${#WORK_PIDS[@]}"

# ------------------------------------------------------------
# Proxy creation only if account-wide reuse failed. Refresh the project list
# once more to close the race where le/kn created a proxy while this script was
# processing Billing/Keys. build_proxy scans ALL projects again before it creates
# anything. New VM creation itself still uses a billed project as the primary.
# ------------------------------------------------------------
PROXY_PID=""
if [ "$PROXY_READY" != "1" ]; then
  mapfile -t ALL_PIDS < <(gcloud projects list --format='value(projectId)' 2>/dev/null | awk 'NF && !seen[$0]++')
  mapfile -t PROXY_SCAN_PIDS < <(
    printf '%s\n' "${BILLED_PIDS[@]}" "${ALL_PIDS[@]}" | awk 'NF && !seen[$0]++'
  )
  PRIMARY_PROJECT="${BILLED_PIDS[0]:-${WORK_PIDS[0]:-}}"
  if [ -z "$PRIMARY_PROJECT" ]; then
    err "没有已绑账单项目可用于创建新的 SOCKS5"
  else
    say "全账号仍未找到可复用 SOCKS5，后台启动创建；Vertex Key 同时处理"
    build_proxy "$PRIMARY_PROJECT" "${PROXY_SCAN_PIDS[@]}" &
    PROXY_PID=$!
  fi
else
  say "已有 SOCKS5 已通过真实请求验证，不再创建 VM"
fi

# ------------------------------------------------------------
# Create only missing Vertex keys, in parallel.
# ------------------------------------------------------------
KEYDIR=$(mktemp -d /tmp/mo_keys_XXXXXX)
KPIDS=()
for pid in "${WORK_PIDS[@]}"; do
  (
    echo >&2
    echo "========== Vertex: $pid ==========" >&2

    # One last read-only check closes the race where another script created
    # the key after our initial scan but before this worker started.
    sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
    existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
    if [ -n "$existing_key" ]; then
      printf '%s\n' "$existing_key" > "$KEYDIR/$pid.key"
      echo "[$pid] 发现现有 Vertex key，直接复用: ${existing_key:0:12}..." >&2
      exit 0
    fi

    if ! ensure_vertex_key_apis "$pid" "mo-Vertex提取前" >&2; then
      echo "[$pid] Vertex 必需 API 未就绪，跳过" >&2
      exit 0
    fi
    vkey=$(v27_setup_and_extract_aq_key "$pid" 1 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1)
    if [ -n "$vkey" ]; then
      printf '%s\n' "$vkey" > "$KEYDIR/$pid.key"
      echo "[$pid] Vertex key 提取成功: ${vkey:0:12}..." >&2
    else
      echo "[$pid] Vertex key 提取失败" >&2
    fi
  ) &
  KPIDS+=("$!")
done
# Empty KPIDS is valid when two reusable AQ keys already exist. Do not use
# ${KPIDS[@]:-} here because that expands to one empty argument and causes
# `wait: '': not a pid or valid job spec`.
for p in "${KPIDS[@]}"; do wait "$p" || true; done

for pid in "${WORK_PIDS[@]}"; do
  if [ -s "$KEYDIR/$pid.key" ]; then
    k=$(head -n1 "$KEYDIR/$pid.key")
    duplicate=0
    for old in "${VKEYS[@]:-}"; do [ "$k" = "$old" ] && { duplicate=1; break; }; done
    [ "$duplicate" = "0" ] && [ -n "$k" ] && VKEYS+=("$k")
  fi
  [ "${#VKEYS[@]}" -ge "$NEED_PROJECTS" ] && break
done
say "Vertex key 收集完成: ${#VKEYS[@]} 个"

# Wait only when a new proxy job actually exists.
if [ -n "$PROXY_PID" ]; then
  say "等待 SOCKS5 后台任务..."
  wait "$PROXY_PID" || true
fi

if [ -s "$PROXY_OUT" ]; then
  # shellcheck disable=SC1090
  source "$PROXY_OUT"
  if mo_proxy_test "${PROXY_URL:-}"; then
    PROXY_READY=1
  else
    PROXY_READY=0
    warn "代理结果存在，但最终真实 SOCKS5 复检失败"
  fi
fi

# ============================================================
# EXACT final format: proxy, blank line, AQ keys.
# Tail-safe: intentionally no open if/for/case blocks below this point.
# ============================================================
FINAL_PROXY="${PROXY_URL:-SOCKS5_FAILED}"
[ "$PROXY_READY" = "1" ] || FINAL_PROXY="SOCKS5_FAILED"
VKEYS=("${VKEYS[@]:0:$NEED_PROJECTS}")
FINAL_OK=1
[ "$PROXY_READY" = "1" ] || FINAL_OK=0
[ "${#VKEYS[@]}" -ge "$NEED_PROJECTS" ] || FINAL_OK=0

printf '\n================ FINAL RESULT ================\n%s\n\n' "$FINAL_PROXY"
printf '%s\n' "${VKEYS[@]}"

# Exit status only; no compound Bash block after final output.
[ "$FINAL_OK" = "1" ]

# MO_V7_EOF_OK
