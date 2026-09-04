
# mo_v12.sh
# Minimal controller: reuse/create 2 billed projects -> parallel Vertex AQ keys
# + account-wide SOCKS5 reuse/create with repair/fallback -> print only.
set -uo pipefail

VERSION="12.0.0"
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

# Final-result guard. v9 could finish the background proxy job and then leave
# the top-level shell before reaching the normal tail on some Cloud Shell runs.
# Arm this only after the controller has enough state to produce a meaningful
# result. The EXIT trap then guarantees one final print, without duplicates.
FINAL_ARMED=0
FINAL_PRINTED=0
PROXY_READY=0
VKEYS=()

cleanup(){
  rm -f "${PROXY_OUT:-}" "${TESTSH:-}" 2>/dev/null || true
  [ -n "${KEYDIR:-}" ] && rm -rf "$KEYDIR" 2>/dev/null || true
}

emit_final(){
  [ "${FINAL_PRINTED:-0}" = "1" ] && return 0
  FINAL_PRINTED=1

  # build_proxy/mo_try_reuse_proxy_project only write PROXY_OUT after a real
  # authenticated SOCKS5 test succeeds. Therefore a result file is safe to
  # recover even when the main flow exited before its normal final re-check.
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
  if [ "${FINAL_ARMED:-0}" = "1" ] && [ "${FINAL_PRINTED:-0}" != "1" ]; then
    warn "主流程提前结束，触发 FINAL RESULT 兜底输出" >&2
    emit_final
  fi
  cleanup
  exit "$rc"
}
trap on_exit EXIT

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
  local project startup user pass url ip instance zone vm_out rc
  local attempt_total=0 project_attempt candidate_index=0
  local network="default" enable_out enable_rc

  # Pass 1: account-wide read-only reuse. Keep the stronger mo validation:
  # metadata credentials + a real authenticated SOCKS5 request must succeed.
  if [ "$REUSE_PROXY" != "0" ]; then
    say "[代理] 扫描当前账号全部候选项目中的现有 socks5-node..."
    for project in "${candidates[@]}"; do
      [ -z "$project" ] && continue
      if mo_try_reuse_proxy_project "$project"; then return 0; fi
    done
  fi

  # Pass 2: NEW proxy creation deliberately follows kn/le order.
  # IMPORTANT: do NOT preflight gcloud services enable here. kn/le first asks
  # Compute to create the VM. If Google answers SERVICE_DISABLED, it then runs
  # services enable, waits 30s, and retries the SAME VM/zone. This matters for
  # freshly linked Billing accounts where Service Usage can temporarily say
  # UREQ_PROJECT_BILLING_NOT_OPEN while the Compute create path soon becomes ready.
  for project in "${candidates[@]}"; do
    [ -z "$project" ] && continue
    candidate_index=$((candidate_index + 1))

    billing_hint="false"
    project_billing_enabled "$project" 2>/dev/null && billing_hint="true"
    say "[代理] 尝试项目 $project（候选 ${candidate_index}/${#candidates[@]}，billingEnabled=${billing_hint}）"

    user="usr$(openssl rand -hex 4)"
    pass="$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    startup="/tmp/mo_startup_$$.sh"
    mo_make_startup_script "$startup" "$PROXY_PORT" "$user" "$pass"

    local zones=(
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
    # Keep kn's random-zone behavior, but put us-west1 first before shuffling by
    # default because the live le/kn logs repeatedly start there.
    if [ "${PROXY_SHUFFLE_ZONES:-1}" = "1" ]; then
      mapfile -t zones < <(printf '%s\n' "${zones[@]}" | shuf)
    fi
    project_attempt=0
    network="default"

    for zone in "${zones[@]}"; do
      [ "$attempt_total" -ge "$PROXY_ZONE_TRIES" ] && break 2
      [ "$project_attempt" -ge "$PROXY_ZONES_PER_PROJECT" ] && break
      attempt_total=$((attempt_total + 1))
      project_attempt=$((project_attempt + 1))
      instance="socks5-node-$(date +%s)-${attempt_total}"
      say "[代理] [$project] 先按 kn/le 直接创建 VM: $zone（总 ${attempt_total}/${PROXY_ZONE_TRIES}，本项目 ${project_attempt}/${PROXY_ZONES_PER_PROJECT}）"

      # First attempt intentionally does NOT call Service Usage first and does
      # not force a network flag. This is the proven kn/le order.
      vm_out=$(gcloud compute instances create "$instance" \
        --project="$project" --zone="$zone" --machine-type=e2-micro \
        --image-family=debian-12 --image-project=debian-cloud \
        --tags=socks5-proxy \
        --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
        --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?

      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE 'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
        warn "[代理] [$project] 首次 VM 返回 SERVICE_DISABLED；完全按 kn/le：主动开启 Compute API，等待 30 秒，再重试同一区域"

        # kn/le does not treat an enable-command failure as final truth here.
        # A newly linked Billing backend may still be propagating. Capture the
        # message for diagnostics, but always wait and retry the actual VM call.
        enable_out=$(gcloud services enable compute.googleapis.com --project="$project" --quiet 2>&1); enable_rc=$?
        if [ "$enable_rc" -ne 0 ]; then
          warn "[代理] [$project] enable 暂未成功，仍按 kn/le 等待后重试 VM: $(echo "$enable_out" | tail -n 3 | tr '\n' ' ' | cut -c1-240)"
        fi
        sleep 30

        vm_out=$(gcloud compute instances create "$instance" \
          --project="$project" --zone="$zone" --machine-type=e2-micro \
          --image-family=debian-12 --image-project=debian-cloud \
          --tags=socks5-proxy \
          --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
          --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?
        [ "$rc" -eq 0 ] && ok "[代理] [$project] 等待传播后 VM 重试成功"
      fi

      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE 'default network.*not found|network.*default.*not found|resource.*default.*not found'; then
        # kn assumes a default VPC. Only when that exact assumption fails do we
        # use mo's fallback network, without changing the normal kn path.
        warn "[代理] [$project] 没有 default VPC；创建 kn-proxy-net 后重试同一区域"
        network=$(mo_ensure_network "$project") || network=""
        if [ -n "$network" ]; then
          vm_out=$(gcloud compute instances create "$instance" \
            --project="$project" --zone="$zone" --machine-type=e2-micro \
            --image-family=debian-12 --image-project=debian-cloud \
            --tags=socks5-proxy \
            --network="$network" --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
            --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?
        fi
      fi

      if [ "$rc" -ne 0 ]; then
        if echo "$vm_out" | grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable|resource pool exhausted'; then
          warn "[代理] [$project] $zone 库存不足，换区域"
          continue
        fi
        if echo "$vm_out" | grep -qiE 'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
          warn "[代理] [$project] Compute 等待后仍未就绪，换下一个项目"
          break
        fi
        if echo "$vm_out" | grep -qiE 'PERMISSION_DENIED|AUTH_PERMISSION_DENIED|FAILED_PRECONDITION|UREQ_PROJECT_BILLING_NOT_OPEN|UREQ_PROJECT_BILLING_NOT_FOUND|billing|BILLING|QUOTA_EXCEEDED|quota.*exceeded'; then
          warn "[代理] [$project] VM 被 Google Billing/权限/配额真实拒绝，换项目: $(echo "$vm_out" | tail -n 3 | tr '\n' ' ' | cut -c1-240)"
          break
        fi
        warn "[代理] [$project] $zone 创建失败，继续换区域: $(echo "$vm_out" | tail -n1 | cut -c1-180)"
        sleep 3
        continue
      fi

      ok "[代理] VM 已创建: $instance / $project / $zone"

      # Determine the actual VM network only AFTER the VM exists, matching kn's
      # "VM first, firewall second" rule.
      network=$(gcloud compute instances describe "$instance" --project="$project" --zone="$zone" \
        --format='get(networkInterfaces[0].network)' 2>/dev/null || true)
      network=$(basename "${network:-default}")
      [ -z "$network" ] && network="default"

      if ! mo_ensure_firewall "$project" "$network" "$PROXY_PORT"; then
        warn "[代理] 防火墙首次配置失败，5 秒后再修复一次"
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
      say "[代理] VM 已成，等待 microsocks + 防火墙 + 真实 SOCKS5 请求通过: ${ip}:${PROXY_PORT}"
      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$instance" "$zone"
        ok "[代理] SOCKS5 已验证可用: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      # Extra safety on top of kn/le: do not print an unverified proxy.
      warn "[代理] 首轮真实测试失败；修防火墙 + reset VM 后再测试一次"
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
      warn "[代理] 当前 VM 最终不可用，删除并继续"
      gcloud compute instances delete "$instance" --project="$project" --zone="$zone" --delete-disks=all --quiet >/dev/null 2>&1 || true
    done

    rm -f "$startup"
  done

  err "[代理] 所有候选项目都按 kn/le 的 VM-first 流程实际尝试后仍失败"
  return 1
}

# ============================================================
# Load test.sh at TOP LEVEL so its declare -A state remains global.
# ============================================================
say "下载 test.sh 函数库: $TESTSH_URL"
curl -fsSL "$TESTSH_URL" -o "$TESTSH" || { err "下载 test.sh 失败"; exit 1; }
bash -n "$TESTSH" || { err "远程 test.sh Bash 语法异常"; exit 1; }
sed -i -E 's/^[[:space:]]*main[[:space:]]*$/: # main disabled by mo_v12.sh/' "$TESTSH"
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
# Stage 1: Billing / Project
# Select Billing -> scan Billing-linked projects -> check AQ first ->
# create only when there are not enough project slots -> fix two Key projects.
# ============================================================
say "================ Stage 1: Billing / Project ================"
BILLING_ID="${BILLING_ID:-}"
if [ -z "$BILLING_ID" ]; then
  BILLING_ID=$(billing_accounts_tsv 2>/dev/null | awk -F'\t' 'NF{print $1; exit}')
  BILLING_ID="${BILLING_ID#billingAccounts/}"
fi
[ -z "$BILLING_ID" ] && { err "No Billing Account found"; exit 1; }
say "Billing Account selected: $BILLING_ID"

mapfile -t NOORG_PIDS < <(gcloud projects list \
  --format='value(projectId)' \
  --filter='parent.type!=organization AND parent.type!=folder' 2>/dev/null | awk 'NF && !seen[$0]++')

LINKED_PIDS=()
SELECTED_LINKED_PIDS=()
BILLED_PIDS=()
for pid in "${NOORG_PIDS[@]}"; do
  acct=$(gcloud billing projects describe "$pid" --format='value(billingAccountName)' 2>/dev/null || true)
  enabled=$(gcloud billing projects describe "$pid" --format='value(billingEnabled)' 2>/dev/null || true)
  acct="${acct#billingAccounts/}"
  enabled=$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  if [ -n "$acct" ] && [ "$acct" != "None" ]; then
    LINKED_PIDS+=("$pid")
    [ "$acct" = "$BILLING_ID" ] && SELECTED_LINKED_PIDS+=("$pid")
  fi
  [ "$enabled" = "true" ] && BILLED_PIDS+=("$pid")
done
say "Billing-linked projects=${#LINKED_PIDS[@]} | selected-account projects=${#SELECTED_LINKED_PIDS[@]} | billingEnabled=true=${#BILLED_PIDS[@]}"

# Prefer projects linked to the selected Billing Account, then other Billing-linked projects.
mapfile -t KEY_CANDIDATES < <(
  printf '%s\n' "${SELECTED_LINKED_PIDS[@]}" "${LINKED_PIDS[@]}" | awk 'NF && !seen[$0]++'
)

declare -A PREKEY_BY_PID=()
KEY_PIDS=()
say "Checking existing Vertex Authorization AQ keys before creating projects..."
for pid in "${KEY_CANDIDATES[@]}"; do
  sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
  existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
  if [ -n "$existing_key" ]; then
    PREKEY_BY_PID["$pid"]="$existing_key"
    KEY_PIDS+=("$pid")
    ok "Existing AQ found: $pid / ${existing_key:0:12}..."
    [ "${#KEY_PIDS[@]}" -ge "$NEED_PROJECTS" ] && break
  fi
done

NEED_SLOTS=$((NEED_PROJECTS - ${#KEY_PIDS[@]}))
WORK_PIDS=()
if [ "$NEED_SLOTS" -gt 0 ]; then
  for pid in "${KEY_CANDIDATES[@]}"; do
    [ -n "${PREKEY_BY_PID[$pid]:-}" ] && continue
    WORK_PIDS+=("$pid")
    [ "${#WORK_PIDS[@]}" -ge "$NEED_SLOTS" ] && break
  done
fi

MISSING_PROJECTS=$((NEED_SLOTS - ${#WORK_PIDS[@]}))
NEW_PIDS=()
if [ "$MISSING_PROJECTS" -gt 0 ]; then
  say "Only $(( ${#KEY_PIDS[@]} + ${#WORK_PIDS[@]} )) Key project slots exist; creating $MISSING_PROJECTS missing project(s)..."
  create_projects_exact "$MISSING_PROJECTS" "$BILLING_ID" NEW_PIDS "mo-stage1" || true
  for pid in "${NEW_PIDS[@]}"; do
    [ -z "$pid" ] && continue
    WORK_PIDS+=("$pid")
    LINKED_PIDS+=("$pid")
    SELECTED_LINKED_PIDS+=("$pid")
  done
fi

mapfile -t KEY_PROJECTS < <(
  printf '%s\n' "${KEY_PIDS[@]}" "${WORK_PIDS[@]}" | awk 'NF && !seen[$0]++'
)
KEY_PROJECTS=("${KEY_PROJECTS[@]:0:$NEED_PROJECTS}")

if [ "${#KEY_PROJECTS[@]}" -lt "$NEED_PROJECTS" ]; then
  err "Could not determine $NEED_PROJECTS Key projects; stop before Vertex/SOCKS5"
  exit 1
fi
say "Final Key projects (${#KEY_PROJECTS[@]}): ${KEY_PROJECTS[*]}"

# ============================================================
# Stage 2: Vertex Key
# Two fixed projects run in parallel. Existing AQ is reused; otherwise:
# 5 required APIs -> service account/roles -> Authorization AQ key.
# SOCKS5 does NOT start until exactly two keys have been collected.
# ============================================================
say "================ Stage 2: Vertex Key ======================="
KEYDIR=$(mktemp -d /tmp/mo_keys_XXXXXX)
KPIDS=()
for pid in "${KEY_PROJECTS[@]}"; do
  (
    existing_key="${PREKEY_BY_PID[$pid]:-}"
    if [ -z "$existing_key" ]; then
      sa_email="${SERVICE_ACCOUNT_NAME}@${pid}.iam.gserviceaccount.com"
      existing_key=$(find_authorization_key_string "$pid" "$sa_email" 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
    fi

    if [ -n "$existing_key" ]; then
      printf '%s\n' "$existing_key" > "$KEYDIR/$pid.key"
      echo "[$pid] Existing AQ -> reuse: ${existing_key:0:12}..." >&2
      exit 0
    fi

    if ! ensure_vertex_key_apis "$pid" "mo-Vertex" >&2; then
      echo "[$pid] Vertex required APIs not ready" >&2
      exit 0
    fi

    vkey=$(v27_setup_and_extract_aq_key "$pid" 1 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1 || true)
    if [ -n "$vkey" ]; then
      printf '%s\n' "$vkey" > "$KEYDIR/$pid.key"
      echo "[$pid] Vertex AQ ready: ${vkey:0:12}..." >&2
    else
      echo "[$pid] Vertex AQ failed" >&2
    fi
  ) &
  KPIDS+=("$!")
done
for p in "${KPIDS[@]}"; do wait "$p" || true; done

VKEYS=()
for pid in "${KEY_PROJECTS[@]}"; do
  if [ -s "$KEYDIR/$pid.key" ]; then
    k=$(head -n1 "$KEYDIR/$pid.key")
    duplicate=0
    for old in "${VKEYS[@]}"; do [ "$k" = "$old" ] && { duplicate=1; break; }; done
    [ "$duplicate" = "0" ] && [ -n "$k" ] && VKEYS+=("$k")
  fi
done

if [ "${#VKEYS[@]}" -lt "$NEED_PROJECTS" ]; then
  err "Vertex Key stage failed: got ${#VKEYS[@]}/$NEED_PROJECTS. SOCKS5 stage will not start."
  exit 1
fi
VKEYS=("${VKEYS[@]:0:$NEED_PROJECTS}")
ok "Vertex Key stage complete: ${#VKEYS[@]}/$NEED_PROJECTS"

# ============================================================
# Stage 3: SOCKS5
# Only after both AQ keys exist: scan the whole account -> real authenticated
# SOCKS5 test -> reuse if good. Otherwise follow kn.sh VM-first flow:
# direct VM -> SERVICE_DISABLED -> enable Compute -> wait 30s -> retry same VM.
# ============================================================
say "================ Stage 3: SOCKS5 ==========================="
mapfile -t ALL_PIDS < <(gcloud projects list --format='value(projectId)' 2>/dev/null | awk 'NF && !seen[$0]++')
PROXY_READY=0
if [ "$REUSE_PROXY" != "0" ] && [ "${#ALL_PIDS[@]}" -gt 0 ]; then
  say "Scanning all accessible projects for existing socks5-node and running a real SOCKS5 test..."
  for pid in "${ALL_PIDS[@]}"; do
    if mo_try_reuse_proxy_project "$pid"; then
      PROXY_READY=1
      break
    fi
  done
fi

if [ "$PROXY_READY" != "1" ]; then
  DEFAULT_PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  [ "$DEFAULT_PROJECT" = "(unset)" ] && DEFAULT_PROJECT=""
  # Match kn.sh project selection preference, but keep fallback across the account:
  # current default first, then the two Key projects, then every accessible project.
  mapfile -t PROXY_CREATE_PIDS < <(
    printf '%s\n' "$DEFAULT_PROJECT" "${KEY_PROJECTS[@]}" "${ALL_PIDS[@]}" | awk 'NF && !seen[$0]++'
  )

  if [ "${#PROXY_CREATE_PIDS[@]}" -eq 0 ]; then
    err "No accessible project is available for SOCKS5 creation"
  else
    say "No reusable SOCKS5 found; start kn.sh-style VM-first creation"
    REUSE_PROXY=0 build_proxy "${PROXY_CREATE_PIDS[@]}" || true
  fi
fi

if [ -s "$PROXY_OUT" ]; then
  # shellcheck disable=SC1090
  source "$PROXY_OUT" 2>/dev/null || true
  if mo_proxy_test "${PROXY_URL:-}"; then
    PROXY_READY=1
  else
    PROXY_READY=0
    warn "Final real SOCKS5 verification failed"
  fi
fi

# ============================================================
# Stage 4: OUTPUT
# ============================================================
FINAL_ARMED=1
emit_final

FINAL_RC=0
[ "$PROXY_READY" = "1" ] || FINAL_RC=1
