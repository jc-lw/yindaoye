
# ============================================================
# mo_clean.sh - GCP Vertex + SOCKS5 streamlined controller
#
# Purpose:
#   1) Load the existing test.sh as a function library (no menu)
#   2) Reuse billingEnabled=true no-org projects first
#   3) If fewer than 2 projects exist, call test.sh:create_projects_exact
#   4) In parallel:
#        - Project A/B: ensure_vertex_key_apis -> v27_setup_and_extract_aq_key
#        - Build/reuse one GCP e2-micro + microsocks SOCKS5 proxy
#   5) Print the full AQ keys and SOCKS5 credentials to the console
#
# This script DOES NOT upload keys/proxy anywhere.
# It deliberately reuses test.sh for Billing / project creation / Vertex logic
# instead of duplicating thousands of lines of code.
# ============================================================

set -uo pipefail

VERSION="1.0.0"
TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"
REUSE_PROXY="${REUSE_PROXY:-1}"
PROXY_PORT="${PROXY_PORT:-1080}"
PROXY_OUT="/tmp/mo_proxy_$$.env"
TESTSH="/tmp/mo_testsh_$$.sh"
KEYDIR=""

# Keep the same speed overrides used by kn.sh. These affect test.sh functions.
export PROJECT_SUBMIT_GAP="${PROJECT_SUBMIT_GAP:-1}"
export PROJECT_CREATE_GAP="${PROJECT_CREATE_GAP:-1}"
export API_BATCH_GAP="${API_BATCH_GAP:-0}"
export API_REPAIR_ROUNDS="${API_REPAIR_ROUNDS:-2}"
export API_REPAIR_SLEEP="${API_REPAIR_SLEEP:-3}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

say()  { echo -e "${CYAN}${BOLD}[mo]${NC} $*"; }
ok()   { echo -e "${GREEN}[mo] $*${NC}"; }
warn() { echo -e "${YELLOW}[mo] $*${NC}"; }
err()  { echo -e "${RED}[mo] $*${NC}" >&2; }

mo_cleanup() {
  rm -f "$PROXY_OUT" "$TESTSH" 2>/dev/null || true
  if [ -n "${KEYDIR:-}" ] && [ -d "$KEYDIR" ]; then
    rm -rf "$KEYDIR" 2>/dev/null || true
  fi
}
trap mo_cleanup EXIT

require_cmd_local() {
  command -v "$1" >/dev/null 2>&1 || {
    err "缺少命令: $1"
    exit 1
  }
}

# ------------------------------------------------------------
# Load test.sh only as a function library.
# ------------------------------------------------------------
load_testsh_library() {
  say "下载 test.sh 函数库: $TESTSH_URL"

  if ! curl -fsSL "$TESTSH_URL" -o "$TESTSH"; then
    err "下载 test.sh 失败"
    exit 1
  fi

  # Catch truncated/broken remote files before sourcing them.
  if ! bash -n "$TESTSH"; then
    err "远程 test.sh 本身存在 Bash 语法错误，已停止。"
    err "请先修复 GitHub 上的 test.sh。"
    exit 1
  fi

  # test.sh ends with a standalone `main`; disable only that invocation.
  sed -i -E 's/^[[:space:]]*main[[:space:]]*$/: # main disabled by mo_clean.sh/' "$TESTSH"

  # shellcheck disable=SC1090
  source "$TESTSH" >/dev/null 2>&1 || true

  # test.sh may enable strict shell/traps. Keep this controller independent.
  set +Eeu +o pipefail 2>/dev/null || true
  trap - ERR 2>/dev/null || true

  local fn
  for fn in \
    check_env \
    billing_accounts_tsv \
    project_billing_enabled \
    create_projects_exact \
    ensure_vertex_key_apis \
    v27_setup_and_extract_aq_key; do
    if ! declare -F "$fn" >/dev/null 2>&1; then
      err "test.sh 缺少必需函数: $fn"
      err "当前远程 test.sh 与本脚本不兼容。"
      exit 1
    fi
  done

  ok "test.sh 函数库加载完成"
}

# ------------------------------------------------------------
# Build/reuse SOCKS5 using GCP Compute Engine + e2-micro.
# This is the same mechanism as kn.sh: no external proxy provider API.
# ------------------------------------------------------------
write_proxy_result() {
  local project_id="$1"
  local instance_name="$2"
  local zone="$3"
  local ip="$4"
  local user="$5"
  local pass="$6"

  {
    echo "PROXY_PROJECT=$project_id"
    echo "PROXY_INSTANCE=$instance_name"
    echo "PROXY_ZONE=$zone"
    echo "PROXY_IP=$ip"
    echo "PROXY_PORT=$PROXY_PORT"
    echo "PROXY_USER=$user"
    echo "PROXY_PASS=$pass"
    echo "PROXY_HOSTPORT=$ip:$PROXY_PORT"
    echo "PROXY_URL=socks5://$user:$pass@$ip:$PROXY_PORT"
    echo "PROXY_ADSPOWER=$ip:$PROXY_PORT:$user:$pass"
  } > "$PROXY_OUT"
}

proxy_port_open() {
  local ip="$1"
  timeout 6 bash -c "cat < /dev/null > /dev/tcp/$ip/$PROXY_PORT" >/dev/null 2>&1
}

try_reuse_proxy_from_project() {
  local project_id="$1"
  local line name zone ip user pass

  line=$(timeout 25 gcloud compute instances list \
    --project="$project_id" \
    --filter='name~socks5-node AND status=RUNNING' \
    --format='value(name,zone,networkInterfaces[0].accessConfigs[0].natIP)' \
    2>/dev/null | head -n1 || true)

  [ -z "$line" ] && return 1

  name=$(echo "$line" | awk '{print $1}')
  zone=$(echo "$line" | awk '{print $2}')
  zone=$(basename "$zone")
  ip=$(echo "$line" | awk '{print $3}')

  [ -z "$name" ] || [ -z "$zone" ] || [ -z "$ip" ] && return 1

  if ! proxy_port_open "$ip"; then
    warn "[代理] $project_id 中发现 $name，但 $ip:$PROXY_PORT 暂未连通"
    return 1
  fi

  user=$(timeout 20 gcloud compute instances describe "$name" \
    --project="$project_id" --zone="$zone" \
    --format='value(metadata.items.filter("key:kn-proxy-user").extract("value").flatten())' \
    2>/dev/null || true)

  pass=$(timeout 20 gcloud compute instances describe "$name" \
    --project="$project_id" --zone="$zone" \
    --format='value(metadata.items.filter("key:kn-proxy-pass").extract("value").flatten())' \
    2>/dev/null || true)

  [ -z "$user" ] || [ -z "$pass" ] && return 1

  write_proxy_result "$project_id" "$name" "$zone" "$ip" "$user" "$pass"
  ok "[代理] 复用现有 SOCKS5: $name ($project_id / $zone / $ip:$PROXY_PORT)"
  return 0
}

build_or_reuse_proxy() {
  local candidate_projects=("$@")
  local project_id

  if [ "$REUSE_PROXY" != "0" ]; then
    say "[代理] 扫描目标项目中的现有 socks5-node VM..."
    for project_id in "${candidate_projects[@]}"; do
      [ -z "$project_id" ] && continue
      if try_reuse_proxy_from_project "$project_id"; then
        return 0
      fi
    done
  fi

  [ "${#candidate_projects[@]}" -eq 0 ] && {
    err "[代理] 没有可用于创建代理的项目"
    return 1
  }

  # Prefer a billingEnabled project for Compute Engine.
  local proxy_project=""
  for project_id in "${candidate_projects[@]}"; do
    if project_billing_enabled "$project_id" >/dev/null 2>&1; then
      proxy_project="$project_id"
      break
    fi
  done
  [ -z "$proxy_project" ] && proxy_project="${candidate_projects[0]}"

  say "[代理] 未找到可复用代理，使用项目 $proxy_project 创建 e2-micro + microsocks"

  local api_ok=0 api_try
  for api_try in 1 2 3; do
    if gcloud services enable compute.googleapis.com --project="$proxy_project" --quiet >/dev/null 2>&1; then
      api_ok=1
      break
    fi
    warn "[代理] Compute API 启用第 $api_try/3 次未成功，等待后重试"
    sleep $((api_try * 4))
  done
  [ "$api_ok" != "1" ] && {
    err "[代理] compute.googleapis.com 无法启用"
    return 1
  }

  # Keep kn.sh's US-zone strategy. e2-micro itself does not imply zero cost.
  local us_zones=(
    us-central1-a us-central1-b us-central1-c
    us-east1-b us-east1-c us-east1-d
    us-east4-a us-east4-b us-east4-c
    us-east5-a us-east5-b us-east5-c
    us-west1-a us-west1-b us-west1-c
    us-west2-a us-west2-b us-west2-c
    us-west3-a us-west3-b us-west3-c
    us-west4-a us-west4-b us-west4-c
    us-south1-a us-south1-b us-south1-c
  )

  local instance_name="socks5-node-$(date +%s)"
  local proxy_user="usr$(openssl rand -hex 4)"
  local proxy_pass
  proxy_pass=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 16)
  [ -z "$proxy_pass" ] && proxy_pass="p$(openssl rand -hex 8)"

  local startup="/tmp/mo_startup_$$.sh"
  cat > "$startup" <<VM_STARTUP
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y build-essential git
rm -rf /tmp/microsocks
git clone --depth=1 https://github.com/rofl0r/microsocks.git /tmp/microsocks
cd /tmp/microsocks
make
install -m 0755 microsocks /usr/local/bin/microsocks
cat > /etc/systemd/system/microsocks.service <<SERVICE_EOF
[Unit]
Description=MicroSocks SOCKS5 Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/microsocks -p $PROXY_PORT -u $proxy_user -P $proxy_pass
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE_EOF
systemctl daemon-reload
systemctl enable --now microsocks
VM_STARTUP

  local zones=()
  mapfile -t zones < <(printf '%s\n' "${us_zones[@]}" | shuf)

  local zone="" create_out="" vm_ok=0 tried=0
  local candidate_zone
  for candidate_zone in "${zones[@]}"; do
    tried=$((tried + 1))
    [ "$tried" -gt 8 ] && break

    say "[代理] 创建 VM，尝试区域 $candidate_zone ($tried/8)"
    create_out=$(gcloud compute instances create "$instance_name" \
      --project="$proxy_project" \
      --zone="$candidate_zone" \
      --machine-type=e2-micro \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --metadata=kn-proxy-user="$proxy_user",kn-proxy-pass="$proxy_pass",kn-proxy-port="$PROXY_PORT" \
      --metadata-from-file=startup-script="$startup" \
      --quiet 2>&1)
    local rc=$?

    if [ "$rc" -eq 0 ]; then
      zone="$candidate_zone"
      vm_ok=1
      ok "[代理] VM 创建成功: $instance_name / $zone"
      break
    fi

    if echo "$create_out" | grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable'; then
      warn "[代理] $candidate_zone 资源不足，换区域"
      continue
    fi

    err "[代理] VM 创建失败: $(echo "$create_out" | tail -n3 | tr '\n' ' ' | cut -c1-500)"
    rm -f "$startup"
    return 1
  done
  rm -f "$startup"

  [ "$vm_ok" != "1" ] && {
    err "[代理] 尝试多个区域后仍无法创建 e2-micro"
    return 1
  }

  # Firewall: create once; already-exists is success.
  local fw_name="allow-socks5-$PROXY_PORT"
  local fw_out fw_try fw_ok=0
  for fw_try in 1 2 3; do
    fw_out=$(gcloud compute firewall-rules create "$fw_name" \
      --project="$proxy_project" \
      --direction=INGRESS \
      --priority=1000 \
      --network=default \
      --action=ALLOW \
      --rules="tcp:$PROXY_PORT" \
      --source-ranges=0.0.0.0/0 \
      --quiet 2>&1)
    local fw_rc=$?

    if [ "$fw_rc" -eq 0 ] || echo "$fw_out" | grep -qiE 'already exists|alreadyExists'; then
      fw_ok=1
      break
    fi
    warn "[代理] 防火墙创建第 $fw_try/3 次失败，等待重试"
    sleep 5
  done

  [ "$fw_ok" != "1" ] && {
    err "[代理] 防火墙规则未创建成功"
    return 1
  }

  local external_ip=""
  local ip_try
  for ip_try in $(seq 1 20); do
    external_ip=$(gcloud compute instances describe "$instance_name" \
      --project="$proxy_project" --zone="$zone" \
      --format='get(networkInterfaces[0].accessConfigs[0].natIP)' \
      2>/dev/null || true)
    [ -n "$external_ip" ] && break
    sleep 3
  done

  [ -z "$external_ip" ] && {
    err "[代理] VM 已创建，但未取得公网 IPv4"
    return 1
  }

  say "[代理] 等待 microsocks 启动并确认 $external_ip:$PROXY_PORT 可连接..."
  local port_try
  for port_try in $(seq 1 60); do
    if proxy_port_open "$external_ip"; then
      write_proxy_result "$proxy_project" "$instance_name" "$zone" "$external_ip" "$proxy_user" "$proxy_pass"
      ok "[代理] SOCKS5 已就绪: $external_ip:$PROXY_PORT"
      return 0
    fi
    [ $((port_try % 10)) -eq 0 ] && say "[代理] 仍在等待启动 ($port_try/60)"
    sleep 3
  done

  err "[代理] VM 已创建，但 180 秒内 $external_ip:$PROXY_PORT 未连通"
  return 1
}

# ------------------------------------------------------------
# Project selection: reuse billed no-org projects first,
# then ask test.sh:create_projects_exact to fill the missing count.
# ------------------------------------------------------------
prepare_projects() {
  local out_array_name="$1"
  local -n out_ref="$out_array_name"
  out_ref=()

  local billing_id="${BILLING_ID:-}"
  if [ -z "$billing_id" ]; then
    billing_id=$(billing_accounts_tsv 2>/dev/null | awk -F'\t' 'NF{print $1; exit}')
    billing_id="${billing_id#billingAccounts/}"
  fi

  [ -z "$billing_id" ] && {
    err "没有找到 Billing Account"
    return 1
  }
  say "使用 Billing Account: $billing_id"

  say "扫描无组织/Folder父级项目，优先复用 billingEnabled=true 的项目..."
  local pids=()
  mapfile -t pids < <(gcloud projects list \
    --format='value(projectId)' \
    --filter='parent.type!=organization AND parent.type!=folder' \
    2>/dev/null || true)

  local pid
  for pid in "${pids[@]}"; do
    [ -z "$pid" ] && continue
    if project_billing_enabled "$pid" >/dev/null 2>&1; then
      out_ref+=("$pid")
      ok "复用已绑账单项目: $pid"
      [ "${#out_ref[@]}" -ge "$NEED_PROJECTS" ] && break
    fi
  done

  local missing=$((NEED_PROJECTS - ${#out_ref[@]}))
  if [ "$missing" -gt 0 ]; then
    say "现有可复用项目不足 $NEED_PROJECTS 个，需要补建 $missing 个"
    local new_pids=()
    create_projects_exact "$missing" "$billing_id" new_pids "mo补建" || true

    for pid in "${new_pids[@]}"; do
      [ -z "$pid" ] && continue
      out_ref+=("$pid")
      if project_billing_enabled "$pid" >/dev/null 2>&1; then
        ok "新项目 Billing 已生效: $pid"
      else
        warn "新项目 $pid billingEnabled 尚未确认，仍会尝试 Vertex 必需 API"
      fi
    done
  fi

  if [ "${#out_ref[@]}" -eq 0 ]; then
    err "没有可处理的项目"
    return 1
  fi

  if [ "${#out_ref[@]}" -lt "$NEED_PROJECTS" ]; then
    warn "目标 $NEED_PROJECTS 个项目，目前只有 ${#out_ref[@]} 个；继续处理已有项目"
  fi

  say "目标项目 (${#out_ref[@]}): ${out_ref[*]}"
}

# ------------------------------------------------------------
# Extract Vertex Authorization keys in parallel.
# ------------------------------------------------------------
extract_vertex_keys_parallel() {
  local out_array_name="$1"
  shift
  local projects=("$@")
  local -n out_ref="$out_array_name"
  out_ref=()

  KEYDIR=$(mktemp -d /tmp/mo_keys_XXXXXX)
  local jobs=()
  local pid

  say "并行处理 ${#projects[@]} 个项目：Vertex API 检查/补齐 + AQ key"

  for pid in "${projects[@]}"; do
    (
      echo "" >&2
      echo "========== Vertex: $pid ==========" >&2

      if ! ensure_vertex_key_apis "$pid" "mo-Vertex提取前" >&2; then
        echo "[$pid] Vertex 必需 API 未就绪，跳过 key" >&2
        exit 0
      fi

      local_vkey=$(v27_setup_and_extract_aq_key "$pid" 1 | \
        grep -oE 'AQ\.[A-Za-z0-9_.-]{20,}' | head -n1 || true)

      if [ -n "$local_vkey" ]; then
        printf '%s\n' "$local_vkey" > "$KEYDIR/$pid.key"
        echo "[$pid] Vertex key 成功: ${local_vkey:0:12}..." >&2
      else
        echo "[$pid] Vertex key 提取失败" >&2
      fi
    ) &
    jobs+=("$!")
  done

  local job
  for job in "${jobs[@]}"; do
    wait "$job" || true
  done

  if compgen -G "$KEYDIR/*.key" >/dev/null 2>&1; then
    mapfile -t out_ref < <(cat "$KEYDIR"/*.key 2>/dev/null | \
      grep -oE 'AQ\.[A-Za-z0-9_.-]{20,}' | awk '!seen[$0]++')
  fi

  ok "Vertex key 收集完成: ${#out_ref[@]} 个"
}

print_final_result() {
  local proxy_ready="$1"
  shift
  local keys=("$@")

  echo ""
  echo -e "${GREEN}${BOLD}================ Vertex Authorization Keys ================${NC}"
  if [ "${#keys[@]}" -gt 0 ]; then
    local k
    for k in "${keys[@]}"; do
      echo "$k"
    done
  else
    echo "没有成功提取 Vertex key"
  fi

  echo ""
  echo -e "${CYAN}${BOLD}================ SOCKS5 Proxy ==============================${NC}"
  if [ "$proxy_ready" = "1" ] && [ -s "$PROXY_OUT" ]; then
    # shellcheck disable=SC1090
    source "$PROXY_OUT"
    echo "IP:PORT : $PROXY_HOSTPORT"
    echo "用户名  : $PROXY_USER"
    echo "密码    : $PROXY_PASS"
    echo "SOCKS5  : $PROXY_URL"
    echo "AdsPower: $PROXY_ADSPOWER"
    echo "项目    : $PROXY_PROJECT"
    echo "实例    : $PROXY_INSTANCE"
    echo "区域    : $PROXY_ZONE"

    echo ""
    echo -e "${YELLOW}${BOLD}================ Key + Proxy ================================${NC}"
    local key
    for key in "${keys[@]}"; do
      echo "$key"
      echo "$PROXY_URL"
      echo ""
    done
  else
    echo "SOCKS5 创建/复用失败；Vertex key 仍按上方结果保留。"
  fi

  echo -e "${GREEN}${BOLD}=============================================================${NC}"
}

main() {
  require_cmd_local gcloud
  require_cmd_local curl
  require_cmd_local openssl
  require_cmd_local timeout
  require_cmd_local shuf

  echo -e "${CYAN}${BOLD}====== GCP Vertex + SOCKS5 自动化 v$VERSION ======${NC}"
  echo ""

  load_testsh_library
  check_env

  local account
  account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1 || true)
  [ -z "$account" ] && account=$(gcloud config get-value account 2>/dev/null || true)
  say "当前账号: ${account:-未知}"

  local target_projects=()
  prepare_projects target_projects || exit 1

  # Start proxy in background, then immediately start Vertex jobs.
  say "后台启动 SOCKS5 扫描/创建，同时开始并行提取 Vertex key"
  build_or_reuse_proxy "${target_projects[@]}" &
  local proxy_pid=$!

  local keys=()
  extract_vertex_keys_parallel keys "${target_projects[@]}"

  say "等待 SOCKS5 后台任务结束..."
  local proxy_ready=0
  if wait "$proxy_pid" && [ -s "$PROXY_OUT" ]; then
    proxy_ready=1
  fi

  print_final_result "$proxy_ready" "${keys[@]}"
