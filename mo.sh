
# mo_v8.sh
# Minimal controller: reuse/create 2 billed projects -> parallel Vertex AQ keys
# + account-wide SOCKS5 reuse/create with repair/fallback -> print only.
set -uo pipefail

VERSION="9.0.0"
TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"
REUSE_PROXY="${REUSE_PROXY:-1}"
REUSE_KEYS="${REUSE_KEYS:-1}"
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_ZONE_TRIES="${PROXY_ZONE_TRIES:-8}"
PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-180}"
PROXY_REUSE_GRACE_SECONDS="${PROXY_REUSE_GRACE_SECONDS:-20}"
PROXY_ZONES_PER_PROJECT="${PROXY_ZONES_PER_PROJECT:-3}"

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

mo_compute_enabled() {
  local project="$1"
  gcloud services list --project="$project" --enabled \
    --filter='config.name=compute.googleapis.com' \
    --format='value(config.name)' 2>/dev/null | grep -qx 'compute.googleapis.com'
}

mo_ensure_compute_api() {
  local project="$1" i j out rc tailmsg
  mo_compute_enabled "$project" && return 0

  for i in 1 2 3; do
    say "[代理] [$project] 启用 Compute Engine API (${i}/3)..."
    out=$(gcloud services enable compute.googleapis.com --project="$project" --quiet 2>&1); rc=$?

    if [ "$rc" -eq 0 ]; then
      # Service Usage can return before the API is visible to Compute. Poll instead
      # of blindly submitting the same enable request again.
      for j in $(seq 1 12); do
        mo_compute_enabled "$project" && return 0
        sleep 5
      done
      warn "[代理] [$project] Compute API 启用请求成功，但 60 秒内仍未确认生效"
      return 2
    fi

    tailmsg=$(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ' | cut -c1-260)
    if printf '%s' "$out" | grep -qiE 'UREQ_PROJECT_BILLING_NOT_OPEN|UREQ_PROJECT_BILLING_NOT_FOUND|PROJECT_BILLING_NOT_OPEN|PROJECT_BILLING_NOT_FOUND|billing.*(not open|not enabled|disabled)|FAILED_PRECONDITION.*billing'; then
      warn "[代理] [$project] Compute API 被 Cloud Billing 前置条件阻止，换项目。${tailmsg}"
      return 20
    fi
    if printf '%s' "$out" | grep -qiE 'PERMISSION_DENIED|AUTH_PERMISSION_DENIED|not authorized|does not have permission|organization policy'; then
      warn "[代理] [$project] Compute API 被权限/组织策略阻止，换项目。${tailmsg}"
      return 30
    fi

    warn "[代理] [$project] Compute API 启用失败，准备重试。${tailmsg}"
    sleep $((i * 5))
  done
  return 1
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
    warn "[代理] 发现旧代理 $name，但首次真实 SOCKS5 测试失败；等待 ${PROXY_REUSE_GRACE_SECONDS}s 后复检"
    sleep "$PROXY_REUSE_GRACE_SECONDS"
    if mo_proxy_test "$url"; then
      mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$name" "$zone"
      ok "[代理] 旧代理等待后恢复可用，直接复用: $name / $project / $ip"
      return 0
    fi
    warn "[代理] 旧代理 $name 复检仍失败，不复用"
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
  local candidates=("$@")
  local project network startup user pass url ip instance zone vm_out rc
  local attempt_total=0 project_attempt candidate_index=0

  # Pass 1: read-only reuse across every accessible project.
  if [ "$REUSE_PROXY" != "0" ]; then
    say "[代理] 扫描当前账号全部候选项目中的现有 socks5-node..."
    for project in "${candidates[@]}"; do
      [ -z "$project" ] && continue
      if mo_try_reuse_proxy_project "$project"; then return 0; fi
    done
  fi

  # Pass 2: mirror kn.sh behavior: DO NOT hard-skip a project only because
  # ProjectBillingInfo.billingEnabled currently reads false. Newly linked Billing
  # can lag behind other backends, and kn.sh succeeds by actually attempting the
  # Compute API/VM flow, waiting for propagation, then retrying. Google remains
  # the authority: real Billing/permission/precondition errors still move us to
  # the next project.
  for project in "${candidates[@]}"; do
    [ -z "$project" ] && continue
    candidate_index=$((candidate_index + 1))

    billing_hint="false"
    project_billing_enabled "$project" 2>/dev/null && billing_hint="true"
    say "[代理] 尝试项目 $project（候选 ${candidate_index}/${#candidates[@]}，billingEnabled=${billing_hint}）"

    if ! mo_ensure_compute_api "$project"; then
      warn "[代理] 项目 $project 的 Compute API 真实启用/确认失败，自动换下一个项目"
      continue
    fi

    network=$(mo_ensure_network "$project") || {
      warn "[代理] 项目 $project 无可用 VPC 且无法创建 kn-proxy-net，换项目"
      continue
    }
    say "[代理] [$project] 使用网络: $network"

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
    project_attempt=0

    for zone in "${zones[@]}"; do
      [ "$attempt_total" -ge "$PROXY_ZONE_TRIES" ] && break 2
      [ "$project_attempt" -ge "$PROXY_ZONES_PER_PROJECT" ] && break
      attempt_total=$((attempt_total + 1))
      project_attempt=$((project_attempt + 1))
      instance="socks5-node-$(date +%s)-${attempt_total}"
      say "[代理] [$project] 创建 VM: $zone（总 ${attempt_total}/${PROXY_ZONE_TRIES}，本项目 ${project_attempt}/${PROXY_ZONES_PER_PROJECT}）"

      vm_out=$(gcloud compute instances create "$instance" \
        --project="$project" --zone="$zone" --machine-type=e2-micro \
        --image-family=debian-12 --image-project=debian-cloud \
        --network="$network" --tags=socks5-proxy \
        --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
        --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?

      if [ "$rc" -ne 0 ]; then
        # kn.sh-compatible propagation fallback: a freshly enabled Compute API
        # can still return SERVICE_DISABLED for the first VM request. Re-enable,
        # wait, and retry the SAME zone once before abandoning the project.
        if echo "$vm_out" | grep -qiE 'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
          warn "[代理] [$project] VM 返回 SERVICE_DISABLED；按 kn.sh 策略重新启用 Compute 并等待 30 秒后重试同一区域"
          gcloud services enable compute.googleapis.com --project="$project" --quiet >/dev/null 2>&1 || true
          sleep 30
          vm_out=$(gcloud compute instances create "$instance" \
            --project="$project" --zone="$zone" --machine-type=e2-micro \
            --image-family=debian-12 --image-project=debian-cloud \
            --network="$network" --tags=socks5-proxy \
            --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
            --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?
          if [ "$rc" -eq 0 ]; then
            ok "[代理] [$project] Compute 传播后重试成功"
          fi
        fi

        if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable|resource pool exhausted'; then
          warn "[代理] [$project] $zone 库存不足，换区域"
          continue
        fi
        if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE 'PERMISSION_DENIED|AUTH_PERMISSION_DENIED|SERVICE_DISABLED|FAILED_PRECONDITION|billing|BILLING|QUOTA_EXCEEDED|quota.*exceeded'; then
          warn "[代理] [$project] VM 被权限/API/Billing/配额阻止，换项目: $(echo "$vm_out" | tail -n 2 | tr '\n' ' ' | cut -c1-220)"
          break
        fi
        if [ "$rc" -ne 0 ]; then
          warn "[代理] [$project] $zone 创建失败，继续换区域: $(echo "$vm_out" | tail -n1 | cut -c1-160)"
          sleep 3
          continue
        fi
      fi

      ok "[代理] VM 已创建: $instance / $project / $zone"

      if ! mo_ensure_firewall "$project" "$network" "$PROXY_PORT"; then
        warn "[代理] 防火墙首次配置失败，5 秒后修复一次"
        sleep 5
        mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      fi

      ip=$(gcloud compute instances describe "$instance" --project="$project" --zone="$zone" \
        --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)
      if [ -z "$ip" ]; then
        warn "[代理] VM 没有公网 IPv4，删除并继续"
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

      warn "[代理] 首轮测试失败，执行兜底：防火墙重检 + VM reset + startup 重跑"
      mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      gcloud compute instances reset "$instance" --project="$project" --zone="$zone" --quiet >/dev/null 2>&1 || true
      sleep 10

      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$instance" "$zone"
        ok "[代理] 兜底修复成功: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      mo_show_serial_tail "$project" "$instance" "$zone"
      warn "[代理] 当前 VM 修复后仍不可用，删除并继续其他区域/项目"
      gcloud compute instances delete "$instance" --project="$project" --zone="$zone" --delete-disks=all --quiet >/dev/null 2>&1 || true
    done

    rm -f "$startup"
  done

  err "[代理] 全账号候选项目均无法得到可用 SOCKS5。若所有项目 billingEnabled=false，GCP Compute VM 无法创建；Vertex AQ Key 仍可能正常。"
  return 1
}

# ============================================================
# Load test.sh at TOP LEVEL so its declare -A state remains global.
# ============================================================
say "下载 test.sh 函数库: $TESTSH_URL"
curl -fsSL "$TESTSH_URL" -o "$TESTSH" || { err "下载 test.sh 失败"; exit 1; }
bash -n "$TESTSH" || { err "远程 test.sh Bash 语法异常"; exit 1; }
sed -i -E 's/^[[:space:]]*main[[:space:]]*$/: # main disabled by mo_v9.sh/' "$TESTSH"
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

say "扫描全部无组织/Folder父级项目，识别 Billing 关联状态..."
mapfile -t NOORG_PIDS < <(gcloud projects list \
  --format='value(projectId)' \
  --filter='parent.type!=organization AND parent.type!=folder' 2>/dev/null | awk 'NF && !seen[$0]++')
mapfile -t ALL_PIDS < <(gcloud projects list --format='value(projectId)' 2>/dev/null | awk 'NF && !seen[$0]++')

BILLED_PIDS=()             # billingEnabled=true
LINKED_PIDS=()             # linked to any Billing Account, even if billingEnabled=false
SELECTED_LINKED_PIDS=()    # linked specifically to BILLING_ID

for pid in "${NOORG_PIDS[@]}"; do
  # Read the two fields separately. A leading empty billingAccountName would be
  # lost by Bash `read` because whitespace IFS trims it, which can falsely mark
  # an unlinked project as linked.
  acct=$(gcloud billing projects describe "$pid" --format='value(billingAccountName)' 2>/dev/null || true)
  enabled=$(gcloud billing projects describe "$pid" --format='value(billingEnabled)' 2>/dev/null || true)
  acct="${acct#billingAccounts/}"
  enabled=$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')

  if [ -n "$acct" ] && [ "$acct" != "None" ]; then
    LINKED_PIDS+=("$pid")
    [ "$acct" = "$BILLING_ID" ] && SELECTED_LINKED_PIDS+=("$pid")
  fi
  if [ "$enabled" = "true" ]; then
    BILLED_PIDS+=("$pid")
    say "billingEnabled=true: $pid"
  fi
done

say "项目状态: no-org=${#NOORG_PIDS[@]} | Billing已关联=${#LINKED_PIDS[@]} | billingEnabled=true=${#BILLED_PIDS[@]}"

# Proxy discovery is account-wide and independent of Vertex/Billing placement.
mapfile -t PROXY_SCAN_PIDS < <(printf '%s\n' "${ALL_PIDS[@]}" | awk 'NF && !seen[$0]++')
say "SOCKS5 扫描项目总数: ${#PROXY_SCAN_PIDS[@]}（全账号可访问项目）"

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
# Key reuse must stay inside Billing-linked projects. v8 scanned every no-org
# project and could therefore return an AQ key from a project with no Billing
# Account at all. Prefer the selected Billing Account, then any other linked
# Billing project. billingEnabled may be false; linkage itself is required.
mapfile -t KEY_SCAN_PIDS < <(
  printf '%s\n' "${SELECTED_LINKED_PIDS[@]}" "${LINKED_PIDS[@]}" | awk 'NF && !seen[$0]++'
)
if [ "$REUSE_KEYS" != "0" ] && [ "${#KEY_SCAN_PIDS[@]}" -gt 0 ]; then
  say "优先读取已绑定 Billing Account 项目中的现有 Vertex Authorization key；未绑定账单的项目 Key 不复用..."
  for pid in "${KEY_SCAN_PIDS[@]}"; do
    sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
    existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
    if [ -n "$existing_key" ]; then
      key_acct=$(gcloud billing projects describe "$pid" --format='value(billingAccountName)' 2>/dev/null || true)
      key_acct="${key_acct#billingAccounts/}"
      key_enabled=$(gcloud billing projects describe "$pid" --format='value(billingEnabled)' 2>/dev/null || true)
      VKEYS+=("$existing_key")
      KEY_PIDS+=("$pid")
      ok "复用含账单 Vertex key: $pid / Billing=${key_acct:-unknown} / billingEnabled=${key_enabled:-unknown} / ${existing_key:0:12}..."
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

# Reuse projects already linked to Billing even when billingEnabled=false.
# The logs prove Vertex Authorization keys can still be created in this state;
# do not create two more projects on every rerun just because Compute is unavailable.
mapfile -t KEY_WORK_CANDIDATES < <(
  printf '%s\n' "${SELECTED_LINKED_PIDS[@]}" "${LINKED_PIDS[@]}" "${BILLED_PIDS[@]}" | awk 'NF && !seen[$0]++'
)

if [ "$NEED_KEYS" -gt 0 ]; then
  for pid in "${KEY_WORK_CANDIDATES[@]}"; do
    already=0
    for kp in "${KEY_PIDS[@]}"; do
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
  say "已有 Billing 关联项目仍缺 $MISSING_PROJECTS 个 Key 槽位，才补建项目..."
  create_projects_exact "$MISSING_PROJECTS" "$BILLING_ID" NEW_PIDS "mo补建" || true
  for pid in "${NEW_PIDS[@]}"; do
    [ -z "$pid" ] && continue
    LINKED_PIDS+=("$pid")
    SELECTED_LINKED_PIDS+=("$pid")
    WORK_PIDS+=("$pid")
    if project_billing_enabled "$pid" 2>/dev/null; then
      BILLED_PIDS+=("$pid")
      ok "新项目 Billing 已生效: $pid"
    else
      warn "新项目已关联 Billing 但 billingEnabled=false: $pid；仍尝试 Vertex key，但不会拿它强行创建 Compute VM"
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
  # Refresh after project creation. Prioritize projects where Compute is already
  # enabled, then billingEnabled=true projects, then the rest. build_proxy itself
  # will skip any project that cannot legally host a Compute VM.
  mapfile -t ALL_PIDS < <(gcloud projects list --format='value(projectId)' 2>/dev/null | awk 'NF && !seen[$0]++')
  COMPUTE_READY_PIDS=()
  for pid in "${ALL_PIDS[@]}"; do
    mo_compute_enabled "$pid" && COMPUTE_READY_PIDS+=("$pid")
  done
  mapfile -t PROXY_CREATE_PIDS < <(
    printf '%s\n' \
      "${COMPUTE_READY_PIDS[@]}" \
      "${BILLED_PIDS[@]}" \
      "${SELECTED_LINKED_PIDS[@]}" \
      "${LINKED_PIDS[@]}" \
      "${ALL_PIDS[@]}" | awk 'NF && !seen[$0]++'
  )

  if [ "${#PROXY_CREATE_PIDS[@]}" -eq 0 ]; then
    err "没有可访问项目可用于 SOCKS5 扫描/创建"
  else
    say "全账号仍未找到可复用 SOCKS5；按项目逐个尝试 Compute，失败自动换项目"
    build_proxy "${PROXY_CREATE_PIDS[@]}" &
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
