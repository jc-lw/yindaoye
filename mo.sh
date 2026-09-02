
# mo_v3.sh - minimal controller based on kn.sh + test.sh
# Flow: reuse/create 2 billed projects -> parallel Vertex API/key jobs + GCP SOCKS5 -> print only
set -uo pipefail

TESTSH_URL="${TESTSH_URL:-https://raw.githubusercontent.com/jc-lw/yindaoye/refs/heads/main/test.sh}"
NEED_PROJECTS="${NEED_PROJECTS:-2}"

export PROJECT_SUBMIT_GAP="${PROJECT_SUBMIT_GAP:-1}"
export PROJECT_CREATE_GAP="${PROJECT_CREATE_GAP:-1}"
export API_BATCH_GAP="${API_BATCH_GAP:-0}"
export API_REPAIR_ROUNDS="${API_REPAIR_ROUNDS:-2}"
export API_REPAIR_SLEEP="${API_REPAIR_SLEEP:-3}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
say(){ echo -e "${CYAN}${BOLD}[kn]${NC} $*"; }
ok(){ echo -e "${GREEN}[kn] $*${NC}"; }
warn(){ echo -e "${YELLOW}[kn] $*${NC}"; }
err(){ echo -e "${RED}[kn] $*${NC}"; }

command -v gcloud >/dev/null 2>&1 || { err "未找到 gcloud，请在 Cloud Shell 或已装 gcloud 的机器上运行"; exit 1; }
command -v openssl >/dev/null 2>&1 || { err "未找到 openssl"; exit 1; }
ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)
[ -z "$ACCOUNT" ] && ACCOUNT=$(gcloud config get-value account 2>/dev/null)
say "当前账号: ${ACCOUNT:-未知}"

# ============================================================
# 建 ck5(SOCKS5) 代理的函数——放后台跑，结果(PROXY_URL / EXTERNAL_IP:PORT)写临时文件
# ============================================================
PROXY_OUT="/tmp/kn_proxy_$$.env"
PROJECT_HINT="/tmp/kn_project_$$.txt"   # 前台一拿到可用项目就写这里，供后台建代理用
build_proxy() {
  local PROJECT_ID US_ZONES RANDOM_ZONE INSTANCE_NAME PORT PROXY_USER PROXY_PASS EXTERNAL_IP
  # 解析一个可用项目：①当前默认项目 ②等前台发布的项目(最多~120s) ③gcloud 现有项目兜底
  PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    say "[代理] 当前会话无默认项目，等待前台创建项目..."
    for _i in $(seq 1 60); do
      [ -s "$PROJECT_HINT" ] && { PROJECT_ID=$(head -n1 "$PROJECT_HINT"); break; }
      sleep 2
    done
  fi
  if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    PROJECT_ID=$(gcloud projects list --format='value(projectId)' --limit=1 2>/dev/null | head -n1)
  fi
  [ -z "$PROJECT_ID" ] && { err "[代理] 无法确定可用项目，代理创建放弃"; return 1; }
  say "[代理] 使用项目: ${PROJECT_ID}"

  # ★复用已有代理：若设 REUSE_PROXY!=0(默认开)，先找账户里现成的、端口通的 socks5 VM，
  #   从它的 metadata 读回账密，直接复用，不再新建（省时间 + 避开区域缺货 + 不浪费配额）。
  #   用【聚合列表】一次查所有项目(几秒)，避免逐项目 list 各等 25s 超时导致整体卡几分钟。
  if [ "${REUSE_PROXY:-1}" != "0" ]; then
    say "[代理] 扫描账户里现有的 socks5 代理（可复用则不新建）..."
    local ex_line ex_proj ex_name ex_zone ex_ip
    # 聚合查询：不带 --project，一条命令跨所有项目列出 socks5 VM（selfLink 反查项目）
    ex_line=$(timeout 30 gcloud compute instances list \
        --filter='name~socks5-node AND status=RUNNING' \
        --format='value(name,zone,networkInterfaces[0].accessConfigs[0].natIP,selfLink)' 2>/dev/null | head -n1)
    if [ -n "$ex_line" ]; then
      ex_name=$(echo "$ex_line" | awk '{print $1}')
      ex_zone=$(echo "$ex_line" | awk '{print $2}')
      ex_zone=$(basename "$ex_zone")   # 聚合模式 zone 可能是 URL，取末段
      ex_ip=$(echo "$ex_line"   | awk '{print $3}')
      ex_proj=$(echo "$ex_line" | grep -oE 'projects/[^/]+' | head -n1 | cut -d/ -f2)
      # 端口通才复用
      if [ -n "$ex_ip" ] && timeout 6 bash -c "cat < /dev/null > /dev/tcp/$ex_ip/1080" 2>/dev/null; then
        local mu mp
        mu=$(timeout 20 gcloud compute instances describe "$ex_name" --project="$ex_proj" --zone="$ex_zone" \
             --format='value(metadata.items.filter("key:kn-proxy-user").extract("value").flatten())' 2>/dev/null)
        mp=$(timeout 20 gcloud compute instances describe "$ex_name" --project="$ex_proj" --zone="$ex_zone" \
             --format='value(metadata.items.filter("key:kn-proxy-pass").extract("value").flatten())' 2>/dev/null)
        if [ -n "$mu" ] && [ -n "$mp" ]; then
          {
            echo "PROXY_URL=socks5://${mu}:${mp}@${ex_ip}:1080"
            echo "PROXY_HOSTPORT=${ex_ip}:1080"
            echo "PROXY_ADSPOWER=${ex_ip}:1080:${mu}:${mp}"
          } > "$PROXY_OUT"
          ok "[代理] ♻ 复用现有代理 $ex_name: socks5://${mu}:***@${ex_ip}:1080（项目 $ex_proj）"
          return 0
        fi
        say "[代理] 现有 $ex_name 无账密 metadata（旧版建的），改为新建"
      else
        say "[代理] 现有 $ex_name 端口未通，改为新建"
      fi
    fi
    say "[代理] 没有可复用的现成代理，新建一个"
  fi

  gcloud services enable compute.googleapis.com --project="${PROJECT_ID}" -q 2>/dev/null

  US_ZONES=(
    "us-central1-a" "us-central1-b" "us-central1-c"
    "us-east1-b" "us-east1-c" "us-east1-d"
    "us-east4-a" "us-east4-b" "us-east4-c"
    "us-east5-a" "us-east5-b" "us-east5-c"
    "us-west1-a" "us-west1-b" "us-west1-c"
    "us-west2-a" "us-west2-b" "us-west2-c"
    "us-west3-a" "us-west3-b" "us-west3-c"
    "us-west4-a" "us-west4-b" "us-west4-c"
    "us-south1-a" "us-south1-b" "us-south1-c"
  )
  RANDOM_ZONE=${US_ZONES[$RANDOM % ${#US_ZONES[@]}]}
  INSTANCE_NAME="socks5-node-$(date +%s)"
  PORT="1080"
  PROXY_USER="usr$(openssl rand -hex 4)"
  PROXY_PASS="$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')"

  say "[代理] 目标区域: ${RANDOM_ZONE}，开放端口 ${PORT}"

  local SU=/tmp/kn_startup_$$.sh
  cat << VM_EOF > "$SU"
#!/bin/bash
apt-get update && apt-get install -y build-essential git
cd /tmp
git clone https://github.com/rofl0r/microsocks.git
cd microsocks
make
cp microsocks /usr/local/bin/microsocks

cat << SERVICE_EOF > /etc/systemd/system/microsocks.service
[Unit]
Description=MicroSocks SOCKS5 Proxy
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/microsocks -p ${PORT} -u ${PROXY_USER} -P ${PROXY_PASS}
Restart=always

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable microsocks
systemctl start microsocks
VM_EOF

  say "[代理] 创建 VM 并部署 microsocks..."
  # 区域库存可能耗尽(ZONE_RESOURCE_POOL_EXHAUSTED)：打乱区域顺序，逐个试，
  # 遇到"该区域无机器"就换下一个，最多试 8 个区域。
  local vm_ok=0 vm_out vm_rc
  mapfile -t SHUF_ZONES < <(printf '%s\n' "${US_ZONES[@]}" | shuf)
  local try_zone tried=0
  for try_zone in "${SHUF_ZONES[@]}"; do
    tried=$((tried+1))
    [ "$tried" -gt 8 ] && break
    say "[代理] 尝试区域 ${try_zone} (第${tried}次)..."
    vm_out=$(gcloud compute instances create ${INSTANCE_NAME} \
        --project="${PROJECT_ID}" \
        --zone=${try_zone} \
        --machine-type="e2-micro" \
        --image-family="debian-12" \
        --image-project="debian-cloud" \
        --metadata=kn-proxy-user="${PROXY_USER}",kn-proxy-pass="${PROXY_PASS}",kn-proxy-port="${PORT}" \
        --metadata-from-file=startup-script="$SU" 2>&1); vm_rc=$?
    if [ "$vm_rc" -eq 0 ]; then
      RANDOM_ZONE="$try_zone"; vm_ok=1
      ok "[代理] VM 已创建于 ${try_zone}"
      break
    fi
    if echo "$vm_out" | grep -qiE 'ZONE_RESOURCE_POOL_EXHAUSTED|does not have enough resources|currently unavailable'; then
      warn "[代理] ${try_zone} 库存不足，换区域..."
      continue
    fi
    # 其他错误(配额/权限等)：换区域也没用，直接报错
    err "[代理] 创建 VM 失败：$(echo "$vm_out" | tail -n1 | cut -c1-120)"
    rm -f "$SU"; return 1
  done
  [ "$vm_ok" != "1" ] && { err "[代理] 试了多个区域都无 e2-micro 库存，稍后再试"; rm -f "$SU"; return 1; }

  # ★关键修复：防火墙规则在 VM 建成后再创建。
  #   VM 能建成 = Compute API 已就绪，此时建防火墙必成功。
  #   （旧版在 enable API 后立刻建防火墙，API 还没生效 → 防火墙静默失败 → VM活着但1080不通）
  #   幂等：已存在则视为成功。带重试。
  say "[代理] 为项目 ${PROJECT_ID} 创建 ${PORT} 防火墙规则..."
  local fw_ok=0 fw_try
  for fw_try in 1 2 3; do
    local fw_out fw_rc
    fw_out=$(gcloud compute firewall-rules create allow-socks5-${PORT} \
        --project="${PROJECT_ID}" \
        --direction=INGRESS --priority=1000 --network=default \
        --action=ALLOW --rules=tcp:${PORT} --source-ranges=0.0.0.0/0 \
        --quiet 2>&1); fw_rc=$?
    if [ "$fw_rc" -eq 0 ]; then fw_ok=1; ok "[代理] 防火墙规则已创建"; break; fi
    if echo "$fw_out" | grep -qiE 'already exists|alreadyExists'; then fw_ok=1; ok "[代理] 防火墙规则已存在（复用）"; break; fi
    warn "[代理] 建防火墙第 ${fw_try}/3 次失败，重试... ($(echo "$fw_out" | tail -n1 | cut -c1-80))"
    sleep 5
  done
  [ "$fw_ok" != "1" ] && warn "[代理] ⚠ 防火墙规则最终未创建成功，端口可能连不上（请事后用 fw.sh 补）"

  say "[代理] 等待获取公网 IP..."
  sleep 10
  EXTERNAL_IP=$(gcloud compute instances describe ${INSTANCE_NAME} --project="${PROJECT_ID}" --zone=${RANDOM_ZONE} --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
  rm -f "$SU"
  [ -z "$EXTERNAL_IP" ] && { err "[代理] 未取得公网 IP"; return 1; }

  {
    echo "PROXY_URL=socks5://${PROXY_USER}:${PROXY_PASS}@${EXTERNAL_IP}:${PORT}"
    echo "PROXY_HOSTPORT=${EXTERNAL_IP}:${PORT}"
    echo "PROXY_ADSPOWER=${EXTERNAL_IP}:${PORT}:${PROXY_USER}:${PROXY_PASS}"
  } > "$PROXY_OUT"
  ok "[代理] 已创建: socks5://${PROXY_USER}:***@${EXTERNAL_IP}:${PORT}"
}

# Start SOCKS5 in background. If no default project, it waits for PROJECT_HINT.
# ★并行：把建代理丢到后台，主流程同时去提 key（代理的编译/装 microsocks 与提 key 重叠进行）
say "启动【建代理】后台任务，同时开始提取 Vertex key..."
build_proxy &
PROXY_PID=$!

say "阶段1：准备 ${NEED_PROJECTS} 个已绑账单的项目并提取 Vertex key"
TESTSH=/tmp/kn_testsh_$$.sh
curl -sL "$TESTSH_URL" -o "$TESTSH" || { err "下载 test.sh 失败"; exit 1; }
sed -i 's/^main$/: # main disabled by mo_v3.sh/' "$TESTSH"

# 复用 test.sh 的函数库，但立即清除它带来的 set -e / ERR trap，避免污染本脚本
# shellcheck disable=SC1090
source "$TESTSH" >/dev/null 2>&1 || true
set +Eeu +o pipefail 2>/dev/null || true
trap - ERR 2>/dev/null || true

# test.sh must expose these as associative arrays. Sourcing at top level preserves their type.
if ! declare -p BILLING_BLOCKED_APIS 2>/dev/null | grep -q "^declare -A"; then
  declare -gA BILLING_BLOCKED_APIS=()
fi
if ! declare -p PERMISSION_BLOCKED_APIS 2>/dev/null | grep -q "^declare -A"; then
  declare -gA PERMISSION_BLOCKED_APIS=()
fi

for fn in billing_accounts_tsv project_billing_enabled create_projects_exact ensure_vertex_key_apis v27_setup_and_extract_aq_key; do
  declare -F "$fn" >/dev/null 2>&1 || { err "test.sh missing required function: $fn"; exit 1; }
done

# 1) 选一个 billing account（多个时取第一个；可用 BILLING_ID 覆盖）
BILLING_ID="${BILLING_ID:-}"
if [ -z "$BILLING_ID" ]; then
  BILLING_ID=$(billing_accounts_tsv 2>/dev/null | awk -F'\t' 'NF{print $1; exit}')
  BILLING_ID="${BILLING_ID#billingAccounts/}"
fi
[ -z "$BILLING_ID" ] && { err "未找到可用的 Billing Account，无法绑定项目"; exit 1; }
say "使用 Billing Account: ${BILLING_ID}"

# 2) 列出无组织(no-org)项目，找出已绑账单的
say "扫描现有无组织项目的账单状态..."
mapfile -t NOORG_PIDS < <(gcloud projects list \
    --format='value(projectId)' \
    --filter='parent.type!=organization AND parent.type!=folder' 2>/dev/null)
BILLED_PIDS=()
for pid in "${NOORG_PIDS[@]:-}"; do
  [ -z "$pid" ] && continue
  if project_billing_enabled "$pid" 2>/dev/null; then
    BILLED_PIDS+=("$pid")
    say "  已绑账单: $pid"
    [ "${#BILLED_PIDS[@]}" -ge "$NEED_PROJECTS" ] && break
  fi
done
ok "现有已绑账单的无组织项目: ${#BILLED_PIDS[@]} 个"

# 3) 不足则补建
TARGET_PIDS=("${BILLED_PIDS[@]:0:$NEED_PROJECTS}")
MISSING=$(( NEED_PROJECTS - ${#TARGET_PIDS[@]} ))
if [ "$MISSING" -gt 0 ]; then
  say "需补建 ${MISSING} 个新项目并绑定账单..."
  NEW_PIDS=()
  create_projects_exact "$MISSING" "$BILLING_ID" NEW_PIDS "mo补建" || true
  for pid in "${NEW_PIDS[@]:-}"; do
    [ -z "$pid" ] && continue
    TARGET_PIDS+=("$pid")
    project_billing_enabled "$pid" 2>/dev/null || warn "  新建项目 $pid 账单未生效(可能撞配额)，仍尝试提取 key"
  done
fi

[ "${#TARGET_PIDS[@]}" -eq 0 ] && { err "没有可用项目，终止"; exit 1; }
say "目标项目(${#TARGET_PIDS[@]}): ${TARGET_PIDS[*]}"
# 把第一个可用项目发布给后台建代理任务（会话无默认项目时它靠这个）
printf '%s\n' "${TARGET_PIDS[0]}" > "$PROJECT_HINT" 2>/dev/null || true

# 4) 各项目【并行】补齐必需 API → 提取 Vertex key（两个项目同时跑，省一半关键路径时间）
say "并行处理 ${#TARGET_PIDS[@]} 个项目（补齐API+提key同时进行）..."
KEYDIR=$(mktemp -d /tmp/kn_keys_XXXXXX)
kpids=()
for pid in "${TARGET_PIDS[@]}"; do
  (
    if ! ensure_vertex_key_apis "$pid" "mo-Vertex提取前" >&2; then
      echo "[$pid] Vertex 必需 API 未就绪，跳过" >&2; exit 0
    fi
    vkey=$(v27_setup_and_extract_aq_key "$pid" 1 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | head -n1)
    if [ -n "$vkey" ]; then
      echo "$vkey" > "$KEYDIR/$pid.key"
      echo "[$pid] Vertex key 提取成功: ${vkey:0:12}..." >&2
    else
      echo "[$pid] Vertex key 提取失败" >&2
    fi
  ) &
  kpids+=("$!")
done
for p in "${kpids[@]}"; do wait "$p" || true; done
mapfile -t VKEYS < <(cat "$KEYDIR"/*.key 2>/dev/null | grep -oE 'AQ\.[A-Za-z0-9_.\-]{20,}' | awk '!seen[$0]++')
rm -rf "$KEYDIR"
[ "${#VKEYS[@]}" -lt "$NEED_PROJECTS" ] && warn "本次提取到 ${#VKEYS[@]} 个 key（目标 ${NEED_PROJECTS}）。可能某项目账单未生效/API 未就绪。"

say "Waiting for SOCKS5 background task..."
wait "$PROXY_PID" || true
PROXY_READY=0
if [ -s "$PROXY_OUT" ]; then
  # shellcheck disable=SC1090
  source "$PROXY_OUT"
  PROXY_READY=1
fi

echo ""
echo "================ FINAL RESULT ================"
if [ "$PROXY_READY" = "1" ]; then
  printf "%s   %s\n" "$PROXY_URL" "代理Proxy"
else
  printf "%s\n" "SOCKS5 创建/复用失败"
fi
if [ "${#VKEYS[@]}" -gt 0 ]; then
  for k in "${VKEYS[@]}"; do
    printf "%s   Key\n" "$k"
  done
else
  printf "%s\n" "没有成功提取 Vertex key"
fi
echo "================================================"

rm -f "${PROXY_OUT:-}" "${PROJECT_HINT:-}" "${TESTSH:-}" 2>/dev/null || true
[ "$PROXY_READY" = "1" ] && [ "${#VKEYS[@]}" -gt 0 ]

# MO_V3_EOF_OK
