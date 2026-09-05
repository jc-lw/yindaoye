#!/bin/bash
# mo_v13.1.sh - Optimized Parallel Architecture with Precision Proxy Reuse
set -uo pipefail

VERSION="13.1.0"
TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"
REUSE_PROXY="${REUSE_PROXY:-1}"
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_ZONE_TRIES="${PROXY_ZONE_TRIES:-8}"
PROXY_WAIT_SECONDS="${PROXY_WAIT_SECONDS:-180}"
PROXY_REUSE_GRACE_SECONDS="${PROXY_REUSE_GRACE_SECONDS:-20}"
PROXY_ZONES_PER_PROJECT="${PROXY_ZONES_PER_PROJECT:-3}"

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

bsay(){ echo -e "${CYAN}${BOLD}[代理-后台]${NC} $*"; }
bok(){ echo -e "${GREEN}[代理-后台] $*${NC}"; }
bwarn(){ echo -e "${YELLOW}[代理-后台] $*${NC}"; }
berr(){ echo -e "${RED}[代理-后台] $*${NC}"; }

command -v gcloud >/dev/null 2>&1 || { err "未找到 gcloud"; exit 1; }
command -v curl >/dev/null 2>&1 || { err "未找到 curl"; exit 1; }
command -v openssl >/dev/null 2>&1 || { err "未找到 openssl"; exit 1; }

ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)
[ -z "$ACCOUNT" ] && ACCOUNT=$(gcloud config get-value account 2>/dev/null)
[ -z "$ACCOUNT" ] && { err "没有已登录的 gcloud 账号"; exit 1; }
say "当前账号: $ACCOUNT"

PROXY_OUT="/tmp/mo_proxy_$$.env"
PROJECT_HINT="/tmp/mo_project_hint_$$.txt"
TESTSH="/tmp/mo_testsh_$$.sh"
KEYDIR=""

FINAL_ARMED=0
FINAL_PRINTED=0
PROXY_READY=0
VKEYS=()

cleanup(){
  rm -f "${PROXY_OUT:-}" "${TESTSH:-}" "${PROJECT_HINT:-}" 2>/dev/null || true
  [ -n "${KEYDIR:-}" ] && rm -rf "$KEYDIR" 2>/dev/null || true
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

mo_wait_proxy() {
  local proxy_url="$1" host="$2" port="$3"
  local elapsed=0 step=5
  while [ "$elapsed" -lt "$PROXY_WAIT_SECONDS" ]; do
    if timeout 4 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1; then
      if mo_proxy_test "$proxy_url"; then
        return 0
      fi
    fi
    sleep "$step"
    elapsed=$((elapsed + step))
    if [ $((elapsed % 30)) -eq 0 ]; then
      bsay "等待 SOCKS5 就绪: ${elapsed}/${PROXY_WAIT_SECONDS}s"
    fi
  done
  return 1
}

mo_ensure_network() {
  local project="$1"
  if gcloud compute networks describe default --project="$project" >/dev/null 2>&1; then
    echo default; return 0
  fi
  if gcloud compute networks describe kn-proxy-net --project="$project" >/dev/null 2>&1; then
    echo kn-proxy-net; return 0
  fi
  bwarn "[$project] 没有 default 网络，创建 kn-proxy-net..." >&2
  if gcloud compute networks create kn-proxy-net --project="$project" \
      --subnet-mode=auto --bgp-routing-mode=regional --quiet >/dev/null 2>&1; then
    echo kn-proxy-net; return 0
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
      bwarn "旧防火墙属于 $current_network，重建" >&2
      gcloud compute firewall-rules delete "$rule" --project="$project" --quiet >/dev/null 2>&1 || true
    else
      if gcloud compute firewall-rules update "$rule" --project="$project" \
        --allow="tcp:${port}" --source-ranges="0.0.0.0/0" \
        --target-tags=socks5-proxy --priority=1000 --quiet >/dev/null 2>&1; then
        bok "防火墙规则已检查/修复: $rule" >&2
        return 0
      fi
      gcloud compute firewall-rules delete "$rule" --project="$project" --quiet >/dev/null 2>&1 || true
    fi
  fi

  if gcloud compute firewall-rules create "$rule" --project="$project" \
    --network="$network" --direction=INGRESS --priority=1000 \
    --action=ALLOW --rules="tcp:${port}" --source-ranges="0.0.0.0/0" \
    --target-tags=socks5-proxy --quiet >/dev/null 2>&1; then
    bok "防火墙规则已创建: $rule" >&2
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
  sed -i -e "s/__PORT__/${port}/g" -e "s/__USER__/${user}/g" -e "s/__PASS__/${pass}/g" "$path"
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
    [ -z "$name" ] && continue
    zone=$(basename "$zone")
    [ -z "$ip" ] && continue

    # 吸收 kn.sh 优点：先用 netcat/bash 探 1080 端口，不通直接跳过，避开慢速 API
    if ! timeout 4 bash -c "cat < /dev/null > /dev/tcp/${ip}/${PROXY_PORT}" 2>/dev/null; then
      continue
    fi

    user=$(timeout 15 gcloud compute instances describe "$name" --project="$project" --zone="$zone" \
      --format='value(metadata.items.filter("key:kn-proxy-user").extract("value").flatten())' 2>/dev/null || true)
    pass=$(timeout 15 gcloud compute instances describe "$name" --project="$project" --zone="$zone" \
      --format='value(metadata.items.filter("key:kn-proxy-pass").extract("value").flatten())' 2>/dev/null || true)
    [ -z "$user" ] || [ -z "$pass" ] && continue
    url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"

    # 坚持 mo 的强验证：TCP 探通不算，能走原生代理 curl 通才算
    if mo_proxy_test "$url"; then
      mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$name" "$zone"
      bok "♻ 复用已验证 SOCKS5: $name / $project / $ip"
      return 0
    fi
    bwarn "发现旧代理 $name，但真实请求失败；等待 ${PROXY_REUSE_GRACE_SECONDS}s 后复检"
    sleep "$PROXY_REUSE_GRACE_SECONDS"
    if mo_proxy_test "$url"; then
      mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$name" "$zone"
      bok "♻ 旧代理复检恢复可用，直接复用: $name / $project / $ip"
      return 0
    fi
  done <<< "$rows"
  return 1
}

mo_show_serial_tail() {
  local project="$1" instance="$2" zone="$3"
  bwarn "启动失败诊断（serial log 最后 12 行）:"
  gcloud compute instances get-serial-port-output "$instance" --project="$project" --zone="$zone" \
    --port=1 2>/dev/null | tail -n 12 >&2 || true
}

build_proxy() {
  local candidates=("$@")
  local project startup user pass url ip instance zone vm_out rc
  local attempt_total=0 project_attempt candidate_index=0
  local network="default" enable_out enable_rc

  for project in "${candidates[@]}"; do
    [ -z "$project" ] && continue
    candidate_index=$((candidate_index + 1))
    bsay "尝试新建项目 $project（候选 ${candidate_index}/${#candidates[@]}）"

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
      bsay "[$project] 按 VM-first 模式创建: $zone"

      vm_out=$(gcloud compute instances create "$instance" \
        --project="$project" --zone="$zone" --machine-type=e2-micro \
        --image-family=debian-12 --image-project=debian-cloud \
        --tags=socks5-proxy \
        --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
        --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?

      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE 'SERVICE_DISABLED|has not been used in project .* before or it is disabled'; then
        bwarn "[$project] 首次 VM 返回 SERVICE_DISABLED；主动开启 Compute API 并等待 30 秒"
        enable_out=$(gcloud services enable compute.googleapis.com --project="$project" --quiet 2>&1); enable_rc=$?
        sleep 30
        vm_out=$(gcloud compute instances create "$instance" \
          --project="$project" --zone="$zone" --machine-type=e2-micro \
          --image-family=debian-12 --image-project=debian-cloud \
          --tags=socks5-proxy \
          --metadata=kn-proxy-user="$user",kn-proxy-pass="$pass",kn-proxy-port="$PROXY_PORT" \
          --metadata-from-file=startup-script="$startup" --quiet 2>&1); rc=$?
      fi

      if [ "$rc" -ne 0 ] && echo "$vm_out" | grep -qiE 'default network.*not found|network.*default.*not found|resource.*default.*not found'; then
        bwarn "[$project] 没有 default VPC；创建 kn-proxy-net 后重试"
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
        if echo "$vm_out" | grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable'; then
          bwarn "[$project] $zone 库存不足，换区域"
          continue
        fi
        if echo "$vm_out" | grep -qiE 'SERVICE_DISABLED|PERMISSION_DENIED|BILLING|QUOTA_EXCEEDED|quota.*exceeded'; then
          bwarn "[$project] API/Billing/Quota 被拒绝，换项目"
          break
        fi
        continue
      fi

      bok "VM 已创建: $instance / $project / $zone"
      network=$(gcloud compute instances describe "$instance" --project="$project" --zone="$zone" \
        --format='get(networkInterfaces[0].network)' 2>/dev/null || true)
      network=$(basename "${network:-default}")
      [ -z "$network" ] && network="default"

      if ! mo_ensure_firewall "$project" "$network" "$PROXY_PORT"; then
        sleep 5
        mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      fi

      ip=$(gcloud compute instances describe "$instance" --project="$project" --zone="$zone" \
        --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)
      if [ -z "$ip" ]; then
        bwarn "VM 没有公网 IPv4，删除并继续"
        gcloud compute instances delete "$instance" --project="$project" --zone="$zone" --delete-disks=all --quiet >/dev/null 2>&1 || true
        continue
      fi

      url="socks5://${user}:${pass}@${ip}:${PROXY_PORT}"
      bsay "等待 SOCKS5 服务与防火墙就绪: ${ip}:${PROXY_PORT}"
      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$instance" "$zone"
        bok "SOCKS5 已验证可用: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      bwarn "首轮测试失败；重置 VM 后再测一次"
      mo_ensure_firewall "$project" "$network" "$PROXY_PORT" || true
      gcloud compute instances reset "$instance" --project="$project" --zone="$zone" --quiet >/dev/null 2>&1 || true
      sleep 10
      if mo_wait_proxy "$url" "$ip" "$PROXY_PORT"; then
        mo_save_proxy "$url" "${ip}:${PROXY_PORT}" "${ip}:${PROXY_PORT}:${user}:${pass}" "$project" "$instance" "$zone"
        bok "兜底修复成功: ${ip}:${PROXY_PORT}"
        rm -f "$startup"
        return 0
      fi

      mo_show_serial_tail "$project" "$instance" "$zone"
      bwarn "当前 VM 最终不可用，删除并继续"
      gcloud compute instances delete "$instance" --project="$project" --zone="$zone" --delete-disks=all --quiet >/dev/null 2>&1 || true
    done
    rm -f "$startup"
  done
  berr "所有候选项目创建代理均失败"
  return 1
}

mo_bg_proxy_worker() {
  local hint_pids=()
  bsay "等待前台主进程分配优先候选项目..."
  for _ in {1..60}; do
    if [ -s "$PROJECT_HINT" ]; then
      mapfile -t hint_pids < "$PROJECT_HINT"
      break
    fi
    sleep 2
  done

  # 构建扫描队列：前台确定的 Key 项目 -> 默认项目 -> 账户里所有其他项目
  local scan_pids=("${hint_pids[@]}")
  local default_proj
  default_proj=$(gcloud config get-value project 2>/dev/null || true)
  [ "$default_proj" != "(unset)" ] && [ -n "$default_proj" ] && scan_pids+=("$default_proj")
  
  local all_pids=()
  mapfile -t all_pids < <(gcloud projects list --format='value(projectId)' 2>/dev/null || true)
  scan_pids+=("${all_pids[@]}")

  local uniq_scan_pids=()
  mapfile -t uniq_scan_pids < <(printf '%s\n' "${scan_pids[@]}" | awk 'NF && !seen[$0]++')

  if [ "${REUSE_PROXY:-1}" != "0" ]; then
    bsay "定向扫描队列中的现存 socks5-node..."
    for proj in "${uniq_scan_pids[@]}"; do
      if mo_try_reuse_proxy_project "$proj"; then
        return 0
      fi
    done
  fi

  if [ ${#hint_pids[@]} -eq 0 ]; then
    hint_pids=("${uniq_scan_pids[@]:0:3}")
  fi
  if [ ${#hint_pids[@]} -eq 0 ]; then
    berr "无任何可用项目，建代理任务结束"
    return 1
  fi

  bsay "未发现可复用代理，开始新建流程..."
  build_proxy "${hint_pids[@]}"
}

# ============================================================
# Main Setup & Test.sh inclusion
# ============================================================
say "下载 test.sh 函数库: $TESTSH_URL"
curl -fsSL "$TESTSH_URL" -o "$TESTSH" || { err "下载 test.sh 失败"; exit 1; }
bash -n "$TESTSH" || { err "远程 test.sh Bash 语法异常"; exit 1; }
sed -i -E 's/^[[:space:]]*main[[:space:]]*$/: # main disabled by mo.sh/' "$TESTSH"
# shellcheck disable=SC1090
source "$TESTSH" >/dev/null 2>&1 || true
set +e +E
set -u
set -o pipefail
trap - ERR 2>/dev/null || true

if ! declare -p BILLING_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then declare -gA BILLING_BLOCKED_APIS=(); fi
if ! declare -p PERMISSION_BLOCKED_APIS 2>/dev/null | grep -q '^declare -A'; then declare -gA PERMISSION_BLOCKED_APIS=(); fi

ok "test.sh 函数库加载完成，启动后台代理引擎..."
mo_bg_proxy_worker &
PROXY_PID=$!

# ============================================================
# Stage 1: Billing / Project
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
for pid in "${NOORG_PIDS[@]}"; do
  acct=$(gcloud billing projects describe "$pid" --format='value(billingAccountName)' 2>/dev/null || true)
  acct="${acct#billingAccounts/}"
  if [ -n "$acct" ] && [ "$acct" != "None" ]; then
    LINKED_PIDS+=("$pid")
    [ "$acct" = "$BILLING_ID" ] && SELECTED_LINKED_PIDS+=("$pid")
  fi
done

mapfile -t KEY_CANDIDATES < <(
  printf '%s\n' "${SELECTED_LINKED_PIDS[@]}" "${LINKED_PIDS[@]}" | awk 'NF && !seen[$0]++'
)

declare -A PREKEY_BY_PID=()
KEY_PIDS=()
say "Checking existing Vertex Authorization AQ keys..."
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
  say "Creating $MISSING_PROJECTS missing project(s)..."
  create_projects_exact "$MISSING_PROJECTS" "$BILLING_ID" NEW_PIDS "mo-stage1" || true
  for pid in "${NEW_PIDS[@]}"; do
    [ -z "$pid" ] && continue
    WORK_PIDS+=("$pid")
  done
fi

mapfile -t KEY_PROJECTS < <(
  printf '%s\n' "${KEY_PIDS[@]}" "${WORK_PIDS[@]}" | awk 'NF && !seen[$0]++'
)
KEY_PROJECTS=("${KEY_PROJECTS[@]:0:$NEED_PROJECTS}")

if [ "${#KEY_PROJECTS[@]}" -lt "$NEED_PROJECTS" ]; then
  err "Could not determine $NEED_PROJECTS Key projects; exiting."
  exit 1
fi
say "Final Key projects (${#KEY_PROJECTS[@]}): ${KEY_PROJECTS[*]}"

# 高优项目锁定！立刻发送线索给后台任务，解除后台复用扫描阻塞状态
printf '%s\n' "${KEY_PROJECTS[@]}" > "$PROJECT_HINT" 2>/dev/null || true

# ============================================================
# Stage 2: Vertex Key
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
  err "Vertex Key stage failed: got ${#VKEYS[@]}/$NEED_PROJECTS."
  exit 1
fi
VKEYS=("${VKEYS[@]:0:$NEED_PROJECTS}")
ok "Vertex Key stage complete: ${#VKEYS[@]}/$NEED_PROJECTS"

# ============================================================
# Stage 3: Sync Proxy
# ============================================================
say "================ Stage 3: SOCKS5 Wait ======================"
say "等待后台【建代理】任务收尾..."
wait "$PROXY_PID" || true

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

FINAL_ARMED=1
emit_final

FINAL_RC=0
[ "$PROXY_READY" = "1" ] || FINAL_RC=1
exit "$FINAL_RC"
