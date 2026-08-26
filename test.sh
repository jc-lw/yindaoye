
# GCP API Key Manager - Vertex AI + Gemini API + Gemini Enterprise Agent Platform
# Version: 6.1.0 (2026-08-26)
# Changes:
#   - Add GA Agent Identity API + Agent Identity Credentials API
#   - Add Cloud DNS required by the current Agent Platform full-suite docs
#   - Add Agent Runtime deployment APIs (Artifact Registry / Cloud Build / Cloud Run / Eventarc / Secret Manager)
#   - Legacy iamconnectors is no longer required by default; optional compatibility switch remains
#   - Exact API readiness verification and quota-aware exponential backoff
#   - Authorization-key detection uses bound service account metadata first, prefix only as fallback
#   - Add two-layer Billing Guard: API open-state check + console Paid/Free Trial confirmation
#   - Free Trial path prints official Billing Overview and Welcome/Activate upgrade links

set -Euo pipefail

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ===== Global config =====
VERSION="6.1.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-miaojiang}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-4}"
CACHE_FILE="$HOME/.miaojiang_keys.cache"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
API_READY_MAX_ATTEMPTS="${API_READY_MAX_ATTEMPTS:-30}"
API_READY_SLEEP="${API_READY_SLEEP:-8}"
API_BATCH_SIZE="${API_BATCH_SIZE:-8}"
ENABLE_LEGACY_IAM_CONNECTORS="${ENABLE_LEGACY_IAM_CONNECTORS:-0}"
BILLING_PAID_CACHE="${BILLING_PAID_CACHE:-$HOME/.miaojiang_paid_billing.cache}"

rm -f "$CACHE_FILE" 2>/dev/null || true

# ===== Current Google Cloud service sets =====
# Core admin + AI APIs used by this script and Vertex/Gemini.
CORE_API_SERVICES=(
  "serviceusage.googleapis.com"
  "cloudresourcemanager.googleapis.com"
  "iam.googleapis.com"
  "iamcredentials.googleapis.com"
  "apikeys.googleapis.com"
  "aiplatform.googleapis.com"
  "generativelanguage.googleapis.com"
  "discoveryengine.googleapis.com"
  "compute.googleapis.com"
  "storage.googleapis.com"
  "logging.googleapis.com"
  "monitoring.googleapis.com"
)

# Gemini Enterprise Agent Platform full-suite / governance APIs.
AGENT_PLATFORM_API_SERVICES=(
  "agentregistry.googleapis.com"
  "agentidentity.googleapis.com"
  "agentidentitycredentials.googleapis.com"
  "apphub.googleapis.com"
  "apptopology.googleapis.com"
  "cloudapiregistry.googleapis.com"
  "modelarmor.googleapis.com"
  "networksecurity.googleapis.com"
  "networkservices.googleapis.com"
  "dns.googleapis.com"
  "iap.googleapis.com"
  "observability.googleapis.com"
  "telemetry.googleapis.com"
  "cloudtrace.googleapis.com"
  "notebooks.googleapis.com"
  "texttospeech.googleapis.com"
  "dataform.googleapis.com"
)

# Agent Runtime / container deployment and common integration APIs.
RUNTIME_API_SERVICES=(
  "artifactregistry.googleapis.com"
  "cloudbuild.googleapis.com"
  "run.googleapis.com"
  "eventarc.googleapis.com"
  "pubsub.googleapis.com"
  "secretmanager.googleapis.com"
  "servicenetworking.googleapis.com"
  "networkconnectivity.googleapis.com"
  "servicedirectory.googleapis.com"
)

# Kept because the old script enabled it and some existing projects may still use it.
COMPAT_API_SERVICES=(
  "dialogflow.googleapis.com"
)

# Legacy service replaced by Agent Identity. Disabled by default.
LEGACY_API_SERVICES=(
  "iamconnectors.googleapis.com"
)

FULL_API_SERVICES=(
  "${CORE_API_SERVICES[@]}"
  "${AGENT_PLATFORM_API_SERVICES[@]}"
  "${RUNTIME_API_SERVICES[@]}"
  "${COMPAT_API_SERVICES[@]}"
)

# Critical list used for readiness gating. This intentionally includes the new 2026 APIs.
VERIFY_API_SERVICES=(
  "aiplatform.googleapis.com"
  "generativelanguage.googleapis.com"
  "discoveryengine.googleapis.com"
  "agentregistry.googleapis.com"
  "agentidentity.googleapis.com"
  "agentidentitycredentials.googleapis.com"
  "apphub.googleapis.com"
  "apptopology.googleapis.com"
  "cloudapiregistry.googleapis.com"
  "modelarmor.googleapis.com"
  "networksecurity.googleapis.com"
  "networkservices.googleapis.com"
  "dns.googleapis.com"
  "observability.googleapis.com"
  "telemetry.googleapis.com"
  "cloudtrace.googleapis.com"
  "logging.googleapis.com"
  "monitoring.googleapis.com"
  "storage.googleapis.com"
  "compute.googleapis.com"
  "artifactregistry.googleapis.com"
  "cloudbuild.googleapis.com"
)

# ===== Logging =====
log() {
  local level="${1:-INFO}"
  local msg="${2:-}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  case "$level" in
    INFO) echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" >&2 ;;
    SUCCESS) echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" >&2 ;;
    WARN) echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
    ERROR) echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
  esac
}

handle_error() {
  local exit_code=$?
  case "$exit_code" in
    141|130) return 0 ;;
  esac
  if [ "$exit_code" -gt 1 ]; then
    return "$exit_code"
  fi
  return 0
}
trap 'handle_error' ERR

retry() {
  local max="$MAX_RETRY_ATTEMPTS"
  local attempt=1
  local delay
  while [ "$attempt" -le "$max" ]; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      return 1
    fi
    delay=$((attempt * 3 + RANDOM % 3))
    log "WARN" "重试 ${attempt}/${max}，等待 ${delay}s..."
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "ERROR" "缺少依赖: $1"
    exit 1
  fi
}

mask_key() {
  local key="${1:-}"
  local len=${#key}
  if [ "$len" -le 12 ]; then
    echo "***"
  else
    echo "${key:0:6}...${key: -6}"
  fi
}

# ===== Billing check: two-layer guard =====
# Google Cloud Billing API exposes whether an account is open, but does not expose
# the Console billable status ("Free trial account" vs "Paid account") as a public
# BillingAccount field. Therefore:
#   Layer 1: automatically verify the Billing Account exists and open=true.
#   Layer 2: require Console confirmation of Paid/Free Trial status.
# If Free Trial is selected, print the official upgrade page and block execution
# until the user upgrades and confirms "Paid account" in Billing Overview.

billing_cache_key() {
  local billing_id="$1"
  local account
  account=$(gcloud config get-value account 2>/dev/null || echo "unknown")
  printf '%s|%s\n' "$account" "$billing_id"
}

billing_paid_is_cached() {
  local billing_id="$1"
  local key
  key=$(billing_cache_key "$billing_id")
  [ -f "$BILLING_PAID_CACHE" ] && grep -Fqx -- "$key" "$BILLING_PAID_CACHE" 2>/dev/null
}

billing_mark_paid_cached() {
  local billing_id="$1"
  local key
  key=$(billing_cache_key "$billing_id")
  mkdir -p "$(dirname "$BILLING_PAID_CACHE")" 2>/dev/null || true
  touch "$BILLING_PAID_CACHE" 2>/dev/null || true
  if ! grep -Fqx -- "$key" "$BILLING_PAID_CACHE" 2>/dev/null; then
    printf '%s\n' "$key" >> "$BILLING_PAID_CACHE"
  fi
  chmod 600 "$BILLING_PAID_CACHE" 2>/dev/null || true
}

billing_remove_paid_cache() {
  local billing_id="$1"
  local key tmp
  key=$(billing_cache_key "$billing_id")
  [ -f "$BILLING_PAID_CACHE" ] || return 0
  tmp="${BILLING_PAID_CACHE}.tmp.$$"
  grep -Fvx -- "$key" "$BILLING_PAID_CACHE" > "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$BILLING_PAID_CACHE" 2>/dev/null || true
  chmod 600 "$BILLING_PAID_CACHE" 2>/dev/null || true
}

show_billing_upgrade_links() {
  local billing_id="$1"
  echo -e "\n${YELLOW}${BOLD}⚠️ 当前账户仍是 Free Trial：必须先升级为 Paid account 才继续。${NC}" >&2
  echo -e "${CYAN}Billing Account ID:${NC} ${billing_id}" >&2
  echo >&2
  echo -e "${BOLD}① 查看当前 Free/Paid 状态：${NC}" >&2
  echo -e "${CYAN}👉 https://console.cloud.google.com/billing/overview${NC}" >&2
  echo -e "   打开后选择 Billing Account: ${billing_id}" >&2
  echo >&2
  echo -e "${BOLD}② 官方升级入口（Welcome 页面）：${NC}" >&2
  echo -e "${CYAN}👉 https://console.cloud.google.com/welcome${NC}" >&2
  echo -e "   在页面顶部点击 ${GREEN}${BOLD}Activate / Upgrade / 激活${NC}，并确认升级。" >&2
  echo >&2
  echo -e "${YELLOW}升级后，Billing Overview 应显示：${GREEN}${BOLD}Paid account${NC}" >&2
  echo -e "${YELLOW}如果仍显示 ${BOLD}Free trial account${NC}，不要继续执行本脚本。" >&2
}

verify_paid_status_in_console() {
  local billing_name="$1"
  local billing_id="${billing_name#billingAccounts/}"
  local display_name="$2"

  # A previous manual Paid confirmation is accepted only while Layer 1 still
  # confirms that the same Billing Account remains open.
  if billing_paid_is_cached "$billing_id"; then
    log "SUCCESS" "[$billing_id] 第二层：已有 Paid account 人工确认缓存，继续执行。"
    return 0
  fi

  while true; do
    echo -e "\n${CYAN}${BOLD}====== Billing 第二层：Free Trial / Paid 核验 ======${NC}" >&2
    echo -e "结算账户 : ${GREEN}${display_name}${NC}" >&2
    echo -e "Billing ID : ${billing_id}" >&2
    echo >&2
    echo -e "Cloud Billing API 只能确认 open=true，不能可靠返回 Free Trial / Paid。" >&2
    echo -e "请打开 Google 官方 Billing Overview：" >&2
    echo -e "${CYAN}👉 https://console.cloud.google.com/billing/overview${NC}" >&2
    echo -e "然后选择 Billing Account: ${billing_id}" >&2
    echo >&2
    echo -e "页面会明确显示：" >&2
    echo -e "  ${GREEN}1.${NC} Paid account        - 已升级，可继续" >&2
    echo -e "  ${YELLOW}2.${NC} Free trial account  - 免费试用，需要升级" >&2
    echo -e "  ${RED}0.${NC} 取消执行" >&2

    local status_choice
    read -r -p "请输入页面实际显示的状态 [1/2/0]: " status_choice < /dev/tty

    case "$status_choice" in
      1)
        billing_mark_paid_cached "$billing_id"
        log "SUCCESS" "[$billing_id] 已确认 Billing Overview 显示 Paid account。"
        return 0
        ;;
      2)
        billing_remove_paid_cache "$billing_id"
        show_billing_upgrade_links "$billing_id"
        echo >&2
        read -r -p "请在浏览器完成升级。升级完成后按回车重新核验；输入 q 取消: " upgrade_done < /dev/tty
        if [[ "$upgrade_done" =~ ^[Qq]$ ]]; then
          log "WARN" "用户取消：Billing 尚未确认升级为 Paid account。"
          return 1
        fi
        # Layer 1 is rechecked after the user returns from the upgrade page.
        local is_open
        is_open=$(gcloud billing accounts describe "$billing_id" --format='value(open)' 2>/dev/null || echo "False")
        if [ "$is_open" != "True" ] && [ "$is_open" != "true" ]; then
          log "ERROR" "[$billing_id] 升级后 Billing Account 当前不是 open=true，请检查 Billing 控制台。"
          return 1
        fi
        log "INFO" "[$billing_id] 第一层复检仍为 open=true；请再次查看 Billing Overview 的 Free/Paid 状态。"
        ;;
      0|q|Q)
        log "WARN" "已取消 Billing Paid 核验。"
        return 1
        ;;
      *)
        log "WARN" "无效选择，请输入 1、2 或 0。"
        ;;
    esac
  done
}

prompt_upgrade_billing() {
  log "INFO" "Billing 第一层：正在检查当前账号可见的结算账户和 open 状态..."

  local billing_raw
  billing_raw=$(gcloud billing accounts list \
    --format='value(name,displayName,open,currencyCode)' \
    2>/dev/null || true)

  if [ -z "$billing_raw" ]; then
    echo -e "\n${RED}${BOLD}❌ 没有检测到当前账号可见的 Cloud Billing Account。${NC}" >&2
    echo -e "请先打开：${CYAN}https://console.cloud.google.com/billing${NC}" >&2
    return 1
  fi

  local open_names=()
  local open_displays=()
  local open_count=0
  local closed_count=0

  while IFS=$'\t' read -r billing_name display_name is_open currency_code; do
    [ -z "$billing_name" ] && continue
    billing_name=$(echo "$billing_name" | tr -d '\r')
    display_name=$(echo "$display_name" | tr -d '\r')
    is_open=$(echo "$is_open" | tr -d '\r')
    currency_code=$(echo "$currency_code" | tr -d '\r')

    local billing_id="${billing_name#billingAccounts/}"
    if [ "$is_open" = "True" ] || [ "$is_open" = "true" ]; then
      open_names+=("$billing_name")
      open_displays+=("${display_name:-Unknown}")
      open_count=$((open_count + 1))
      log "SUCCESS" "[$billing_id] 第一层通过: open=true | ${display_name:-Unknown} | ${currency_code:-Unknown}"
    else
      closed_count=$((closed_count + 1))
      billing_remove_paid_cache "$billing_id"
      log "WARN" "[$billing_id] 第一层失败: open=false | ${display_name:-Unknown}"
    fi
  done <<< "$billing_raw"

  if [ "$open_count" -eq 0 ]; then
    echo -e "\n${RED}${BOLD}❌ 找到了 Billing Account，但没有任何账户是 open=true。${NC}" >&2
    echo -e "请检查 Billing 页面：${CYAN}https://console.cloud.google.com/billing${NC}" >&2
    return 1
  fi

  echo -e "\n${GREEN}${BOLD}✅ Billing 第一层通过：${open_count} 个 open=true${NC}" >&2
  if [ "$closed_count" -gt 0 ]; then
    echo -e "${YELLOW}另外发现 ${closed_count} 个 closed Billing Account，已忽略。${NC}" >&2
  fi

  # Layer 2: verify every open billing account visible to this script. This is
  # intentional because several menu modes can later select/process any of them.
  local idx
  for idx in "${!open_names[@]}"; do
    verify_paid_status_in_console "${open_names[$idx]}" "${open_displays[$idx]}" || return 1
  done

  echo -e "\n${GREEN}${BOLD}✅ 双层 Billing Guard 已通过：所有 open Billing Account 均已确认 Paid。${NC}\n" >&2
  return 0
}

# ===== Project name/id =====
new_project_name() {
  echo "My Project $((RANDOM % 90000 + 10000))"
}

new_project_id() {
  local adjs=("aesthetic" "bold" "brave" "calm" "clever" "cosmic" "dazzling" "deep" "epic" "fancy" "gentle" "happy" "jolly" "kind" "lively" "magic" "noble" "proud" "quiet" "rapid" "shiny" "smart" "sunny" "sweet" "vivid" "warm" "wild" "wise" "zesty")
  local nouns=("aleph" "beacon" "cloud" "dawn" "echo" "forge" "grove" "haven" "iris" "jewel" "kite" "leaf" "moon" "nexus" "oasis" "pulse" "quest" "ridge" "spark" "tide" "unity" "vortex" "wave" "zenith")
  local suffixes=("" "-m1" "-v2" "-m2" "-q1")
  local adj="${adjs[$((RANDOM % ${#adjs[@]}))]}"
  local noun="${nouns[$((RANDOM % ${#nouns[@]}))]}"
  local num=$((RANDOM % 900000 + 100000))
  local suffix="${suffixes[$((RANDOM % ${#suffixes[@]}))]}"
  echo "${adj}-${noun}-${num}${suffix}"
}

check_env() {
  require_cmd gcloud

  local account
  account=$(gcloud config get-value account 2>/dev/null || true)
  if [ -z "$account" ] || [ "$account" = "(unset)" ]; then
    log "ERROR" "未检测到 gcloud 登录账号，请先运行: gcloud init"
    exit 1
  fi

  log "INFO" "当前 gcloud 账号: $account"

  if ! gcloud beta services api-keys create --help >/dev/null 2>&1; then
    log "WARN" "当前 gcloud 可能缺少 beta API Keys 参数支持。若 Vertex Authorization key 创建失败，请先更新 Google Cloud CLI。"
  fi
}

unlink_projects_from_billing_account() {
  local billing_id="$1"
  local linked_projects
  linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null || true)
  if [ -z "$linked_projects" ]; then
    return 0
  fi

  log "WARN" "正在解绑该结算账户下的旧项目..."
  local project_id
  for project_id in $linked_projects; do
    [ -z "$project_id" ] && continue
    gcloud billing projects unlink "$project_id" --quiet >/dev/null 2>&1 || true
  done
}

# ===== API enable engine =====
get_requested_api_services() {
  printf '%s\n' "${FULL_API_SERVICES[@]}"
  if [ "$ENABLE_LEGACY_IAM_CONNECTORS" = "1" ]; then
    printf '%s\n' "${LEGACY_API_SERVICES[@]}"
  fi
}

enable_api_with_retry() {
  local proj="$1"
  local batch_name="$2"
  shift 2
  local apis=("$@")

  [ "${#apis[@]}" -eq 0 ] && return 0

  local attempt=1
  local max_attempts=5
  local out=""

  while [ "$attempt" -le "$max_attempts" ]; do
    if out=$(gcloud services enable "${apis[@]}" --project="$proj" --async --quiet 2>&1); then
      log "SUCCESS" "[$proj] ${batch_name} 已提交 (${#apis[@]} 个 API)"
      return 0
    fi

    if echo "$out" | grep -qiE '429|RESOURCE_EXHAUSTED|RATE_LIMIT_EXCEEDED|quota|Mutate requests|rate.?limit'; then
      local exp=$((1 << (attempt - 1)))
      local delay=$((exp * 6 + RANDOM % 6))
      [ "$delay" -gt 60 ] && delay=60
      log "WARN" "[$proj] ${batch_name} 遇到 Service Usage 配额限制，等待 ${delay}s 后重试 (${attempt}/${max_attempts})"
      sleep "$delay"
    else
      local short_out
      short_out=$(echo "$out" | tail -n 3 | tr '\n' ' ' | cut -c1-500)
      log "WARN" "[$proj] ${batch_name} 提交失败 (${attempt}/${max_attempts}): ${short_out}"
      sleep $((5 + attempt * 2))
    fi

    attempt=$((attempt + 1))
  done

  return 1
}

enable_single_api_with_retry() {
  local proj="$1"
  local api="$2"
  local attempt=1
  local max_attempts=4
  local out=""

  while [ "$attempt" -le "$max_attempts" ]; do
    if out=$(gcloud services enable "$api" --project="$proj" --async --quiet 2>&1); then
      log "SUCCESS" "[$proj] 已提交: $api"
      return 0
    fi

    if echo "$out" | grep -qiE '429|RESOURCE_EXHAUSTED|RATE_LIMIT_EXCEEDED|quota|Mutate requests|rate.?limit'; then
      local delay=$((attempt * 12 + RANDOM % 8))
      log "WARN" "[$proj] $api 遇到配额限制，等待 ${delay}s (${attempt}/${max_attempts})"
      sleep "$delay"
    else
      local short_out
      short_out=$(echo "$out" | tail -n 2 | tr '\n' ' ' | cut -c1-400)
      log "WARN" "[$proj] $api 暂未成功: $short_out"
      sleep $((4 + attempt * 2))
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

v60_enable_all_services() {
  local proj="$1"
  local requested=()
  local api

  while IFS= read -r api; do
    [ -n "$api" ] && requested+=("$api")
  done < <(get_requested_api_services)

  log "INFO" "[$proj] 准备启用 Vertex/Gemini/Agent Platform 全套 API，共 ${#requested[@]} 个"
  if [ "$ENABLE_LEGACY_IAM_CONNECTORS" = "1" ]; then
    log "WARN" "[$proj] 已开启兼容模式：同时启用 legacy iamconnectors.googleapis.com"
  fi

  local start=0
  local batch_num=1
  local total=${#requested[@]}
  while [ "$start" -lt "$total" ]; do
    local batch=("${requested[@]:start:API_BATCH_SIZE}")
    if ! enable_api_with_retry "$proj" "API批次${batch_num}" "${batch[@]}"; then
      log "WARN" "[$proj] 批次 ${batch_num} 未整体成功，改为逐个补开，避免单个服务影响整批"
      for api in "${batch[@]}"; do
        enable_single_api_with_retry "$proj" "$api" || log "ERROR" "[$proj] 最终未能启用: $api"
        sleep 1
      done
    fi
    start=$((start + API_BATCH_SIZE))
    batch_num=$((batch_num + 1))
    sleep 3
  done

  log "INFO" "[$proj] 所有 API 启用请求已提交，等待后台生效..."
}

# Backward-compatible function name used by the old script.
v27_enable_all_services() {
  v60_enable_all_services "$@"
}

check_api_ready() {
  local pid="$1"
  local stage="$2"
  log "INFO" "[$pid] ${stage} 正在核验关键 API（包含 Agent Identity / DNS / Runtime）..."

  local attempt=1
  while [ "$attempt" -le "$API_READY_MAX_ATTEMPTS" ]; do
    local enabled_list
    enabled_list=$(gcloud services list --project="$pid" --enabled --format='value(config.name)' 2>/dev/null || true)

    declare -A enabled_map=()
    local svc
    while IFS= read -r svc; do
      [ -n "$svc" ] && enabled_map["$svc"]=1
    done <<< "$enabled_list"

    local missing=()
    for svc in "${VERIFY_API_SERVICES[@]}"; do
      if [ -z "${enabled_map[$svc]+x}" ]; then
        missing+=("$svc")
      fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
      log "SUCCESS" "[$pid] ${stage} 核验通过：${#VERIFY_API_SERVICES[@]} 个关键 API 已全部生效"
      return 0
    fi

    if [ "$attempt" -eq 1 ] || [ $((attempt % 5)) -eq 0 ]; then
      log "INFO" "[$pid] 仍有 ${#missing[@]} 个关键 API 等待生效: ${missing[*]}"
    fi

    sleep "$API_READY_SLEEP"
    attempt=$((attempt + 1))
  done

  log "WARN" "[$pid] ${stage} 核验超时。部分 API 可能仍在后台传播，后续流程继续执行。"
  return 1
}

show_enabled_api_summary() {
  local pid="$1"
  local enabled_list
  enabled_list=$(gcloud services list --project="$pid" --enabled --format='value(config.name)' 2>/dev/null || true)
  declare -A enabled_map=()
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] && enabled_map["$svc"]=1
  done <<< "$enabled_list"

  local ok=0
  local miss=0
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    if [ -n "${enabled_map[$svc]+x}" ]; then
      ok=$((ok + 1))
    else
      miss=$((miss + 1))
    fi
  done < <(get_requested_api_services)

  log "INFO" "[$pid] API 汇总: 已启用 ${ok} | 未确认 ${miss}"
}

# ===== Gemini API / AI Studio standard key =====
_extract_single_project() {
  local pid="$1"
  retry gcloud services enable generativelanguage.googleapis.com apikeys.googleapis.com --project="$pid" --quiet >/dev/null 2>&1 || true

  local target_name
  target_name=$(gcloud services api-keys list --project="$pid" \
    --filter="displayName:'Gemini API Key' OR displayName:'Studio Key'" \
    --format='value(name)' 2>/dev/null | head -n 1 | tr -d '\r' | xargs || true)

  if [ -z "$target_name" ]; then
    gcloud services api-keys create \
      --project="$pid" \
      --display-name="Gemini API Key" \
      --api-target=service=generativelanguage.googleapis.com \
      --quiet >/dev/null 2>&1 || true
    sleep 3
    target_name=$(gcloud services api-keys list --project="$pid" \
      --filter="displayName:'Gemini API Key'" \
      --format='value(name)' 2>/dev/null | head -n 1 | tr -d '\r' | xargs || true)
  fi

  if [ -n "$target_name" ]; then
    local api_key
    api_key=$(gcloud services api-keys get-key-string "$target_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs || true)
    if [ -n "$api_key" ]; then
      echo "$api_key"
      return 0
    fi
  fi

  local all_keys
  all_keys=$(gcloud services api-keys list --project="$pid" --format='value(name,displayName)' 2>/dev/null || true)
  if [ -n "$all_keys" ]; then
    while read -r kname dname; do
      kname=$(echo "$kname" | tr -d '\r' | xargs)
      [ -z "$kname" ] && continue
      if [[ "$dname" != *"Agent Platform"* ]] && [[ "$dname" != *"Authorization"* ]] && [[ "$dname" != *"Fallback"* ]]; then
        local api_key
        api_key=$(gcloud services api-keys get-key-string "$kname" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs || true)
        if [ -n "$api_key" ] && [[ "$api_key" == AIza* ]]; then
          echo "$api_key"
          return 0
        fi
      fi
    done <<< "$all_keys"
  fi

  return 1
}

# ===== Authorization key helpers =====
key_bound_service_account() {
  local project_id="$1"
  local key_name="$2"
  gcloud services api-keys describe "$key_name" \
    --project="$project_id" \
    --format='value(serviceAccountEmail)' 2>/dev/null | tr -d '\r' | xargs || true
}

find_authorization_key_string() {
  local project_id="$1"
  local sa_email="$2"
  local keys_list
  keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || true)
  [ -z "$keys_list" ] && return 1

  local fallback_prefix_key=""
  local key_name
  for key_name in $keys_list; do
    key_name=$(echo "$key_name" | tr -d '\r' | xargs)
    [ -z "$key_name" ] && continue

    local bound_sa
    bound_sa=$(key_bound_service_account "$project_id" "$key_name")

    local api_key
    api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs || true)
    [ -z "$api_key" ] && continue

    if [ -n "$bound_sa" ] && [ "$bound_sa" = "$sa_email" ]; then
      echo "$api_key"
      return 0
    fi

    # Prefix is kept only as a fallback for older gcloud output formats.
    if [[ "$api_key" == AQ.* ]]; then
      fallback_prefix_key="$api_key"
    fi
  done

  if [ -n "$fallback_prefix_key" ]; then
    echo "$fallback_prefix_key"
    return 0
  fi

  return 1
}

v27_setup_and_extract_aq_key() {
  local project_id="$1"
  local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"

  # Ensure the APIs needed to create/manage authorization keys are ready.
  retry gcloud services enable \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    apikeys.googleapis.com \
    aiplatform.googleapis.com \
    generativelanguage.googleapis.com \
    --project="$project_id" --quiet >/dev/null 2>&1 || true

  if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" >/dev/null 2>&1; then
    retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
      --display-name="Vertex Agent SA" \
      --project="$project_id" \
      --quiet >/dev/null 2>&1 || true
    log "INFO" "[$project_id] 等待服务账号生效..."
    sleep 6
  fi

  # Preserve the old permissions and add the new Agent Identity usage role.
  local roles=(
    "roles/editor"
    "roles/aiplatform.admin"
    "roles/iam.serviceAccountUser"
    "roles/agentidentity.user"
    "roles/serviceusage.serviceUsageConsumer"
  )

  local role
  for role in "${roles[@]}"; do
    retry gcloud projects add-iam-policy-binding "$project_id" \
      --member="serviceAccount:${sa_email}" \
      --role="$role" \
      --quiet >/dev/null 2>&1 || true
  done

  sleep 4

  local existing_key
  existing_key=$(find_authorization_key_string "$project_id" "$sa_email" || true)
  if [ -n "$existing_key" ]; then
    echo "$existing_key"
    return 0
  fi

  log "INFO" "[$project_id] 正在创建绑定服务账号的 Vertex/Gemini Authorization key..."
  local attempt=1
  local max_attempts=6
  local create_success=false
  local last_error=""

  while [ "$attempt" -le "$max_attempts" ]; do
    if last_error=$(gcloud beta services api-keys create \
      --project="$project_id" \
      --display-name="Agent Platform Authorization Key" \
      --api-target=service=aiplatform.googleapis.com \
      --api-target=service=generativelanguage.googleapis.com \
      --service-account="$sa_email" \
      --quiet 2>&1); then
      create_success=true
      break
    fi

    if echo "$last_error" | grep -qiE '429|RESOURCE_EXHAUSTED|quota|rate.?limit|Mutate requests'; then
      local delay=$((attempt * 12 + RANDOM % 8))
      log "WARN" "[$project_id] Authorization key 创建遇到配额限制，等待 ${delay}s (${attempt}/${max_attempts})"
      sleep "$delay"
    elif echo "$last_error" | grep -qiE 'disableServiceAccountApiKeyCreation|organization policy|ORG_POLICY|Policy|FAILED_PRECONDITION'; then
      log "WARN" "[$project_id] 组织策略阻止创建绑定服务账号的 Authorization key。不会自动修改组织安全策略。"
      break
    else
      local short_err
      short_err=$(echo "$last_error" | tail -n 3 | tr '\n' ' ' | cut -c1-500)
      log "WARN" "[$project_id] Authorization key 创建暂未成功: $short_err"
      sleep 10
    fi
    attempt=$((attempt + 1))
  done

  if [ "$create_success" = true ]; then
    sleep 5
    local auth_key
    auth_key=$(find_authorization_key_string "$project_id" "$sa_email" || true)
    if [ -n "$auth_key" ]; then
      echo "$auth_key"
      return 0
    fi
  fi

  # Compatibility fallback: create a standard API key. It is not equivalent to a bound authorization key.
  log "WARN" "[$project_id] 无法取得 Authorization key，尝试创建标准 API key 作为兼容回退。"
  gcloud services api-keys create \
    --project="$project_id" \
    --display-name="Fallback API Key" \
    --api-target=service=generativelanguage.googleapis.com \
    --quiet >/dev/null 2>&1 || true
  sleep 3

  local keys_list
  keys_list=$(gcloud services api-keys list --project="$project_id" --filter="displayName:'Fallback API Key'" --format='value(name)' 2>/dev/null || true)
  local key_name
  for key_name in $keys_list; do
    local api_key
    api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs || true)
    if [ -n "$api_key" ]; then
      echo "$api_key"
      return 0
    fi
  done

  return 1
}

# ===== Billing selection =====
select_billing_accounts() {
  local billing_raw
  billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || true)
  if [ -z "$billing_raw" ]; then
    log "ERROR" "未找到开放的结算账户"
    return 1
  fi

  local ids=()
  local names=()
  while IFS=',' read -r bid bname; do
    [ -z "$bid" ] && continue
    bid="${bid##*/}"
    ids+=("$bid")
    names+=("$bname")
  done <<< "$billing_raw"

  if [ "${#ids[@]}" -eq 1 ]; then
    log "INFO" "仅检测到 1 个可用结算账户: ${names[0]} (${ids[0]})"
    SELECTED_BILLING_IDS=("${ids[0]}")
    SELECTED_BILLING_NAMES=("${names[0]}")
    return 0
  fi

  echo -e "\n${CYAN}${BOLD}可用的结算账户：${NC}" >&2
  local idx
  for idx in "${!ids[@]}"; do
    echo -e "  ${GREEN}$((idx + 1))${NC}. ${names[$idx]} (${ids[$idx]})" >&2
  done
  echo -e "  ${GREEN}0${NC}. 全部选择" >&2

  local choice
  read -r -p "请选择结算账户 (多个用逗号分隔，如 1,3) [默认: 0]: " choice < /dev/tty
  choice=${choice:-0}

  SELECTED_BILLING_IDS=()
  SELECTED_BILLING_NAMES=()

  if [ "$choice" = "0" ]; then
    SELECTED_BILLING_IDS=("${ids[@]}")
    SELECTED_BILLING_NAMES=("${names[@]}")
  else
    IFS=',' read -ra selections <<< "$choice"
    local sel
    for sel in "${selections[@]}"; do
      sel=$(echo "$sel" | tr -d ' ')
      if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#ids[@]}" ]; then
        local si=$((sel - 1))
        SELECTED_BILLING_IDS+=("${ids[$si]}")
        SELECTED_BILLING_NAMES+=("${names[$si]}")
      fi
    done
  fi

  if [ "${#SELECTED_BILLING_IDS[@]}" -eq 0 ]; then
    log "ERROR" "未选择任何结算账户"
    return 1
  fi
}

_select_billing_for_opt6() {
  local billing_raw
  billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || true)
  if [ -z "$billing_raw" ]; then
    log "ERROR" "未找到开放的结算账户"
    return 1
  fi

  local ids=()
  local names=()
  while IFS=',' read -r bid bname; do
    [ -z "$bid" ] && continue
    bid="${bid##*/}"
    ids+=("$bid")
    names+=("$bname")
  done <<< "$billing_raw"

  if [ "${#ids[@]}" -eq 1 ]; then
    log "INFO" "仅检测到 1 个可用结算账户: ${names[0]} (${ids[0]})"
    echo "${ids[0]}"
    return 0
  fi

  echo -e "\n${CYAN}${BOLD}可用的结算账户：${NC}" >&2
  local idx
  for idx in "${!ids[@]}"; do
    echo -e "  ${GREEN}$((idx + 1))${NC}. ${names[$idx]} (${ids[$idx]})" >&2
  done

  local choice
  read -r -p "请选择 1 个主要结算账户 [默认: 1]: " choice < /dev/tty
  choice=${choice:-1}

  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ids[@]}" ]; then
    local si=$((choice - 1))
    echo "${ids[$si]}"
    return 0
  fi

  log "ERROR" "无效的选择"
  return 1
}

# ===== Options 1/2: Gemini standard keys =====
gemini_create_projects() {
  prompt_upgrade_billing || return 1
  local keep_billing="${1:-false}"
  local auto_mode="${2:-false}"

  if [ "$keep_billing" = "true" ]; then
    log "INFO" "====== 自动创建项目并提取 Gemini API key（保留旧结算绑定） ======"
  else
    log "INFO" "====== 自动创建项目并提取 Gemini API key（先解绑旧项目） ======"
  fi

  local num_per_billing
  if [ "$auto_mode" = "true" ]; then
    local billing_raw
    billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || true)
    if [ -z "$billing_raw" ]; then
      log "ERROR" "未找到开放的结算账户"
      return 1
    fi
    SELECTED_BILLING_IDS=()
    SELECTED_BILLING_NAMES=()
    while IFS=',' read -r bid bname; do
      [ -z "$bid" ] && continue
      SELECTED_BILLING_IDS+=("${bid##*/}")
      SELECTED_BILLING_NAMES+=("$bname")
    done <<< "$billing_raw"
    num_per_billing=3
  else
    select_billing_accounts || return 1
    local num_input
    read -r -p "每个结算账户创建几个项目？支持 3 或 3-5 [默认: 3]: " num_input < /dev/tty
    num_input=${num_input:-3}
    if [[ "$num_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local min="${BASH_REMATCH[1]}"
      local max="${BASH_REMATCH[2]}"
      if [ "$min" -le "$max" ]; then
        num_per_billing=$((RANDOM % (max - min + 1) + min))
      else
        num_per_billing="$min"
      fi
    elif [[ "$num_input" =~ ^[0-9]+$ ]]; then
      num_per_billing="$num_input"
    else
      num_per_billing=3
    fi
  fi

  local total_projects=$((num_per_billing * ${#SELECTED_BILLING_IDS[@]}))
  local ALL_KEYS=()

  local billing_idx
  for billing_idx in "${!SELECTED_BILLING_IDS[@]}"; do
    local billing_account="${SELECTED_BILLING_IDS[$billing_idx]}"
    local billing_name="${SELECTED_BILLING_NAMES[$billing_idx]}"

    echo -e "\n${CYAN}${BOLD}──── 结算账户 $((billing_idx + 1))/${#SELECTED_BILLING_IDS[@]}: ${billing_name} (${billing_account}) ────${NC}"
    if [ "$keep_billing" = "false" ]; then
      unlink_projects_from_billing_account "$billing_account"
    fi

    local success=0
    local failed=0
    local skipped=0
    local i=1
    while [ "$i" -le "$num_per_billing" ]; do
      local global_idx=$((billing_idx * num_per_billing + i))
      local project_id
      project_id=$(new_project_id)
      local project_name
      project_name=$(new_project_name)

      log "INFO" "[${global_idx}/${total_projects}] 创建项目: ${project_name} [${project_id}]"
      if ! gcloud projects create "$project_id" --name="$project_name" --quiet >/dev/null 2>&1; then
        failed=$((failed + 1))
        i=$((i + 1))
        continue
      fi

      gcloud billing projects link "$project_id" --billing-account="$billing_account" --quiet >/dev/null 2>&1 || true

      local billing_info
      billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || true)
      if [ -z "$billing_info" ]; then
        log "WARN" "[$project_id] 未确认账单绑定，跳过"
        skipped=$((skipped + 1))
        i=$((i + 1))
        continue
      fi

      local api_key
      api_key=$(_extract_single_project "$project_id" || true)
      if [ -n "$api_key" ]; then
        ALL_KEYS+=("$api_key")
        log "SUCCESS" "[$project_id] Gemini key 提取成功: $(mask_key "$api_key")"
        success=$((success + 1))
      else
        log "WARN" "[$project_id] Gemini key 提取失败"
        failed=$((failed + 1))
      fi
      i=$((i + 1))
    done

    echo -e "${CYAN}  ${billing_name} 小结: 成功 ${success} | 失败 ${failed} | 跳过 ${skipped}${NC}"
  done

  if [ "${#ALL_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${GREEN}${BOLD}====== Gemini / AI Studio 标准密钥列表 (共 ${#ALL_KEYS[@]} 个) ======${NC}"
    local k
    for k in "${ALL_KEYS[@]}"; do
      echo -e "${GREEN}$k${NC}"
    done
    echo
  fi
}

# ===== Option 3 =====
gemini_get_keys_from_existing() {
  prompt_upgrade_billing || return 1

  echo -e "\n${CYAN}${BOLD}====== 选项3: 从现有已绑账单项目提取密钥 ======${NC}"
  echo "1. 只提 Vertex Authorization key"
  echo "2. 只提 Gemini / AI Studio 标准 key"
  echo "3. Vertex + Gemini 双端 key"

  local sub_choice
  read -r -p "请选择 [1-3, 默认: 3]: " sub_choice < /dev/tty
  sub_choice=${sub_choice:-3}

  log "INFO" "正在扫描已绑定账单的活跃项目..."
  local projects
  projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null || true)
  local valid_projects=()
  local pid
  for pid in $projects; do
    local b_info
    b_info=$(gcloud billing projects describe "$pid" --format='value(billingAccountName)' 2>/dev/null || true)
    [ -n "$b_info" ] && valid_projects+=("$pid")
  done

  if [ "${#valid_projects[@]}" -eq 0 ]; then
    log "ERROR" "没有找到绑定账单的项目"
    return 1
  fi

  local VERTEX_KEYS=()
  local AS_KEYS=()

  local project_id
  for project_id in "${valid_projects[@]}"; do
    log "INFO" "正在处理: $project_id"

    if [ "$sub_choice" = "1" ] || [ "$sub_choice" = "3" ]; then
      v60_enable_all_services "$project_id"
      check_api_ready "$project_id" "【提Key前】" || true
      local v_key
      v_key=$(v27_setup_and_extract_aq_key "$project_id" || true)
      if [ -n "$v_key" ]; then
        VERTEX_KEYS+=("$v_key")
        log "SUCCESS" "[$project_id] Vertex key 提取成功: $(mask_key "$v_key")"
      else
        log "WARN" "[$project_id] Vertex Authorization key 提取失败"
      fi
      show_enabled_api_summary "$project_id"
    fi

    if [ "$sub_choice" = "2" ] || [ "$sub_choice" = "3" ]; then
      local a_key
      a_key=$(_extract_single_project "$project_id" || true)
      if [ -n "$a_key" ]; then
        AS_KEYS+=("$a_key")
        log "SUCCESS" "[$project_id] Gemini key 提取成功: $(mask_key "$a_key")"
      else
        log "WARN" "[$project_id] Gemini key 提取失败"
      fi
    fi
  done

  if [ "${#VERTEX_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}====== Vertex Authorization key 列表 (共 ${#VERTEX_KEYS[@]} 个) ======${NC}"
    local k
    for k in "${VERTEX_KEYS[@]}"; do
      echo -e "${GREEN}$k${NC}"
    done
  fi

  if [ "${#AS_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${GREEN}${BOLD}====== Gemini / AI Studio 标准 key 列表 (共 ${#AS_KEYS[@]} 个) ======${NC}"
    local k
    for k in "${AS_KEYS[@]}"; do
      echo -e "${GREEN}$k${NC}"
    done
    echo
  fi
}

# ===== Option 4 =====
gemini_delete_projects() {
  log "INFO" "====== 批量删除项目 ======"
  read -r -p "输入项目前缀进行批量删除 (留空取消): " prefix < /dev/tty
  [ -z "$prefix" ] && return 0

  local projects
  projects=$(gcloud projects list --format='value(projectId)' --filter="projectId:${prefix}*" 2>/dev/null || true)
  local p
  for p in $projects; do
    log "INFO" "正在删除 $p ..."
    gcloud projects delete "$p" --quiet || true
  done
}

# ===== Option 5 =====
rebuild_and_transfer_billing() {
  prompt_upgrade_billing || return 1
  log "INFO" "====== 选项5: 保护原项目 -> 转移结算 -> 新建2个项目 ======"

  local default_project
  default_project=$(gcloud projects list --filter="name='My First Project'" --format='value(projectId)' 2>/dev/null | head -n 1 || true)
  if [ -z "$default_project" ]; then
    default_project=$(gcloud config get-value project 2>/dev/null || true)
    [ "$default_project" = "(unset)" ] && default_project=""
  fi

  local ORIGINAL_PROJECT=""
  while [ -z "$ORIGINAL_PROJECT" ]; do
    echo -e "${YELLOW}⚠️ 此操作会删除除保护项目以外的其他项目。${NC}" >&2
    if [ -n "$default_project" ]; then
      read -r -p "请输入绝对不能删除的原始项目 ID [默认: ${default_project}]: " ORIGINAL_PROJECT < /dev/tty
      ORIGINAL_PROJECT=${ORIGINAL_PROJECT:-$default_project}
    else
      read -r -p "请输入绝对不能删除的原始项目 ID: " ORIGINAL_PROJECT < /dev/tty
    fi
  done

  local CURRENT_ACCOUNT
  CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
  log "INFO" "当前登录账号: $CURRENT_ACCOUNT"

  local TARGET_EMAIL
  read -r -p "请输入接收结算权限的目标邮箱 [默认: $CURRENT_ACCOUNT]: " TARGET_EMAIL < /dev/tty
  TARGET_EMAIL=${TARGET_EMAIL:-$CURRENT_ACCOUNT}

  local billing_raw
  billing_raw=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1 || true)
  if [ -z "$billing_raw" ]; then
    log "ERROR" "未找到活动结算账户"
    return 1
  fi
  local TARGET_BILLING_ID="${billing_raw#billingAccounts/}"

  log "INFO" "处理结算账户: $TARGET_BILLING_ID"
  local policy_json
  policy_json=$(gcloud beta billing accounts get-iam-policy "$TARGET_BILLING_ID" --format=json 2>/dev/null || true)

  if [ -n "$policy_json" ] && command -v python3 >/dev/null 2>&1; then
    local roles
    roles=$(python3 -c '
import sys, json
try:
    policy = json.loads(sys.argv[1])
    member = "user:" + sys.argv[2]
    roles = set()
    for b in policy.get("bindings", []):
        if member in b.get("members", []):
            roles.add(b.get("role"))
    for r in sorted(roles):
        print(r)
except Exception:
    pass
' "$policy_json" "$CURRENT_ACCOUNT")

    if [ -n "$roles" ]; then
      log "INFO" "复制当前账号的 Billing IAM 角色给 $TARGET_EMAIL ..."
      local role
      for role in $roles; do
        gcloud beta billing accounts add-iam-policy-binding "$TARGET_BILLING_ID" \
          --member="user:$TARGET_EMAIL" \
          --role="$role" \
          --quiet >/dev/null 2>&1 || true
      done
    fi
  fi

  log "INFO" "开始清理非保护项目..."
  local all_projects
  all_projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null || true)
  local p
  for p in $all_projects; do
    if [ "$p" = "$ORIGINAL_PROJECT" ]; then
      log "SUCCESS" "保护项目 [$p] 保留"
      continue
    fi
    log "INFO" "删除项目 $p ..."
    gcloud projects delete "$p" --quiet >/dev/null 2>&1 || true
    sleep 3
  done

  local AS_KEYS=()

  log "INFO" "处理原始项目并提取 Gemini key..."
  gcloud billing projects link "$ORIGINAL_PROJECT" --billing-account="$TARGET_BILLING_ID" --quiet >/dev/null 2>&1 || true
  local orig_key
  orig_key=$(_extract_single_project "$ORIGINAL_PROJECT" || true)
  if [ -n "$orig_key" ]; then
    AS_KEYS+=("$orig_key")
    log "SUCCESS" "原始项目 key 提取成功"
  fi

  log "INFO" "创建 2 个新项目..."
  local i
  for i in 1 2; do
    local pid
    pid=$(new_project_id)
    local pname
    pname=$(new_project_name)
    log "INFO" "创建: $pname [$pid]"
    if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
      sleep 3
      gcloud billing projects link "$pid" --billing-account="$TARGET_BILLING_ID" --quiet >/dev/null 2>&1 || true
      local new_key
      new_key=$(_extract_single_project "$pid" || true)
      if [ -n "$new_key" ]; then
        AS_KEYS+=("$new_key")
        log "SUCCESS" "[$pid] key 提取成功"
      fi
    fi
    sleep 3
  done

  if [ "${#AS_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${GREEN}${BOLD}====== Gemini / AI Studio 标准 key 列表 ======${NC}"
    local k
    for k in "${AS_KEYS[@]}"; do
      echo -e "${GREEN}$k${NC}"
    done
  fi
}

# ===== Option 6 =====
option6_handler() {
  prompt_upgrade_billing || return 1

  echo -e "\n${CYAN}${BOLD}====== 选项6: 创建项目 + 开全套 API + 提 Vertex/Gemini key ======${NC}"
  echo "1. 单账单自定义数量"
  echo "2. 多账单自动模式 (账单1: 默认项目+2新项目; 账单2~N: 3新项目)"

  local sub_choice
  read -r -p "请选择 [1-2, 默认: 2]: " sub_choice < /dev/tty
  sub_choice=${sub_choice:-2}

  local VERTEX_KEYS=()
  local AS_KEYS_FORMATTED=()

  if [ "$sub_choice" = "1" ]; then
    local BILLING_ACCOUNT
    BILLING_ACCOUNT=$(_select_billing_for_opt6) || return 1
    log "INFO" "已选择结算账户: $BILLING_ACCOUNT"

    local num_projects
    read -r -p "请输入要创建的项目数量 [默认: 2]: " num_projects < /dev/tty
    num_projects=${num_projects:-2}
    if ! [[ "$num_projects" =~ ^[0-9]+$ ]] || [ "$num_projects" -lt 1 ]; then
      num_projects=2
    fi

    unlink_projects_from_billing_account "$BILLING_ACCOUNT"
    sleep 5

    local created_pids=()
    local i
    for ((i = 1; i <= num_projects; i++)); do
      local pid
      pid=$(new_project_id)
      local pname
      pname=$(new_project_name)
      log "INFO" "[$i/$num_projects] 创建: ${pname} [${pid}]"
      if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
        gcloud billing projects link "$pid" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
        created_pids+=("$pid")
      fi
    done

    sleep 5
    local pid
    for pid in "${created_pids[@]}"; do
      v60_enable_all_services "$pid"
    done

    sleep 12
    for pid in "${created_pids[@]}"; do
      check_api_ready "$pid" "【提Key前】" || true

      local v_key
      v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
      if [ -n "$v_key" ]; then
        VERTEX_KEYS+=("$v_key")
        log "SUCCESS" "[$pid] Vertex key: $(mask_key "$v_key")"
      fi

      local a_key
      a_key=$(_extract_single_project "$pid" || true)
      if [ -n "$a_key" ]; then
        AS_KEYS_FORMATTED+=("$a_key")
        log "SUCCESS" "[$pid] Gemini key: $(mask_key "$a_key")"
      fi

      show_enabled_api_summary "$pid"
    done

    if [ "${#AS_KEYS_FORMATTED[@]}" -gt 0 ]; then
      local temp=("新创建项目的key")
      local k
      for k in "${AS_KEYS_FORMATTED[@]}"; do
        temp+=("$k")
      done
      AS_KEYS_FORMATTED=("${temp[@]}")
    fi

  elif [ "$sub_choice" = "2" ]; then
    log "INFO" "====== 执行 6.2 多账单自动模式 ======"

    local billing_raw
    billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || true)
    if [ -z "$billing_raw" ]; then
      log "ERROR" "未找到开放的结算账户"
      return 1
    fi

    local b_ids=()
    local b_names=()
    while IFS=',' read -r bid bname; do
      [ -z "$bid" ] && continue
      b_ids+=("${bid##*/}")
      b_names+=("$bname")
    done <<< "$billing_raw"

    local b_idx
    for b_idx in "${!b_ids[@]}"; do
      local CURRENT_BILLING="${b_ids[$b_idx]}"
      local CURRENT_BNAME="${b_names[$b_idx]}"

      log "INFO" "=========================================================="
      log "INFO" "处理结算账户 $((b_idx + 1))/${#b_ids[@]}: $CURRENT_BNAME"

      VERTEX_KEYS+=("【账单: ${CURRENT_BNAME}】")
      AS_KEYS_FORMATTED+=("【账单: ${CURRENT_BNAME}】")

      if [ "$b_idx" -eq 0 ]; then
        local default_pid
        default_pid=$(gcloud projects list --filter="name='My First Project'" --format='value(projectId)' 2>/dev/null | head -n 1 || true)
        if [ -z "$default_pid" ]; then
          default_pid=$(gcloud config get-value project 2>/dev/null || true)
          [ "$default_pid" = "(unset)" ] && default_pid=""
        fi

        if [ -n "$default_pid" ]; then
          log "INFO" ">> [账单1] 处理默认项目: $default_pid"
          gcloud billing projects link "$default_pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
          local check_b
          check_b=$(gcloud billing projects describe "$default_pid" --format='value(billingAccountName)' 2>/dev/null || true)
          if [ -n "$check_b" ]; then
            local default_a_key
            default_a_key=$(_extract_single_project "$default_pid" || true)
            if [ -n "$default_a_key" ]; then
              AS_KEYS_FORMATTED+=("默认项目的key" "$default_a_key")
            fi
          fi
        fi

        local created_pids=()
        log "INFO" ">> [账单1] 创建 2 个新项目..."
        local i
        for i in 1 2; do
          local pid
          pid=$(new_project_id)
          local pname
          pname=$(new_project_name)
          if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
            gcloud billing projects link "$pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
            created_pids+=("$pid")
          fi
        done

        sleep 5
        local pid
        for pid in "${created_pids[@]}"; do
          v60_enable_all_services "$pid"
        done
        sleep 12

        for pid in "${created_pids[@]}"; do
          check_api_ready "$pid" "【提Key前】" || true
          local v_key
          v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
          if [ -n "$v_key" ]; then
            VERTEX_KEYS+=("$v_key")
            log "SUCCESS" "[$pid] Vertex key: $(mask_key "$v_key")"
          fi
          show_enabled_api_summary "$pid"
        done

        if [ "${#created_pids[@]}" -gt 0 ]; then
          AS_KEYS_FORMATTED+=("新创建项目的key")
          for pid in "${created_pids[@]}"; do
            local a_key
            a_key=$(_extract_single_project "$pid" || true)
            [ -n "$a_key" ] && AS_KEYS_FORMATTED+=("$a_key")
          done
        fi

      else
        local created_pids=()
        log "INFO" ">> [账单$((b_idx + 1))] 创建 3 个新项目..."
        local i
        for i in 1 2 3; do
          local pid
          pid=$(new_project_id)
          local pname
          pname=$(new_project_name)
          if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
            gcloud billing projects link "$pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
            created_pids+=("$pid")
          fi
        done

        sleep 5
        local pid
        for pid in "${created_pids[@]}"; do
          v60_enable_all_services "$pid"
        done
        sleep 12

        local v_count=0
        for pid in "${created_pids[@]}"; do
          if [ "$v_count" -ge 2 ]; then
            show_enabled_api_summary "$pid"
            continue
          fi
          check_api_ready "$pid" "【提Key前】" || true
          local v_key
          v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
          if [ -n "$v_key" ]; then
            VERTEX_KEYS+=("$v_key")
            v_count=$((v_count + 1))
            log "SUCCESS" "[$pid] Vertex key: $(mask_key "$v_key")"
          fi
          show_enabled_api_summary "$pid"
        done

        if [ "${#created_pids[@]}" -gt 0 ]; then
          AS_KEYS_FORMATTED+=("新创建项目的key")
          for pid in "${created_pids[@]}"; do
            local a_key
            a_key=$(_extract_single_project "$pid" || true)
            [ -n "$a_key" ] && AS_KEYS_FORMATTED+=("$a_key")
          done
        fi
      fi
    done
  else
    log "ERROR" "无效选择"
    return 1
  fi

  local pure_v=0
  local item
  for item in "${VERTEX_KEYS[@]}"; do
    if [[ "$item" != *"【账单"* ]]; then
      pure_v=$((pure_v + 1))
    fi
  done

  if [ "$pure_v" -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}====== Vertex Authorization key 列表 (共 ${pure_v} 个) ======${NC}"
    local k
    for k in "${VERTEX_KEYS[@]}"; do
      if [[ "$k" == *"【账单"* ]]; then
        echo -e "\n${CYAN}${k}${NC}"
      else
        echo -e "${GREEN}${k}${NC}"
      fi
    done
  fi

  local pure_a=0
  for item in "${AS_KEYS_FORMATTED[@]}"; do
    if [[ "$item" != *"项目的key"* ]] && [[ "$item" != *"【账单"* ]]; then
      pure_a=$((pure_a + 1))
    fi
  done

  if [ "$pure_a" -gt 0 ]; then
    echo -e "\n${GREEN}${BOLD}====== Gemini / AI Studio 标准 key 列表 (共 ${pure_a} 个) ======${NC}"
    local k
    for k in "${AS_KEYS_FORMATTED[@]}"; do
      if [[ "$k" == *"【账单"* ]] || [[ "$k" == *"项目的key"* ]]; then
        echo -e "${CYAN}${k}${NC}"
      else
        echo -e "${GREEN}${k}${NC}"
      fi
    done
    echo
  fi
}

# ===== Option 7 =====
option7_handler() {
  prompt_upgrade_billing || return 1

  echo -e "\n${CYAN}${BOLD}====== 选项7: 删除所有账单关联项目 -> 每账单新建1个并提 Gemini key ======${NC}"
  echo -e "${YELLOW}⚠️ 此操作会解绑并删除所有可见活动结算账户下关联的项目。${NC}"
  read -r -p "确认执行吗？[y/N]: " confirm_del < /dev/tty
  if [[ ! "$confirm_del" =~ ^[Yy]$ ]]; then
    log "INFO" "操作已取消"
    return 0
  fi

  local billing_raw
  billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || true)
  if [ -z "$billing_raw" ]; then
    log "ERROR" "未找到开放的结算账户"
    return 1
  fi

  local b_ids=()
  local b_names=()
  while IFS=',' read -r bid bname; do
    [ -z "$bid" ] && continue
    b_ids+=("${bid##*/}")
    b_names+=("$bname")
  done <<< "$billing_raw"

  log "INFO" "检测到 ${#b_ids[@]} 个活动结算账户"

  local b_idx
  for b_idx in "${!b_ids[@]}"; do
    local CURRENT_BILLING="${b_ids[$b_idx]}"
    local CURRENT_BNAME="${b_names[$b_idx]}"
    log "INFO" ">> 清理结算账户 [$CURRENT_BNAME] 下的项目..."

    local linked_projects
    linked_projects=$(gcloud billing projects list --billing-account="$CURRENT_BILLING" --format='value(projectId)' 2>/dev/null || true)
    local p
    for p in $linked_projects; do
      [ -z "$p" ] && continue
      log "INFO" "解绑并删除: $p"
      gcloud billing projects unlink "$p" --quiet >/dev/null 2>&1 || true
      gcloud projects delete "$p" --quiet || true
      sleep 2
    done
  done

  log "INFO" "清理完毕，开始为每个结算账户创建 1 个新项目"
  local AS_KEYS_FORMATTED=()

  for b_idx in "${!b_ids[@]}"; do
    local CURRENT_BILLING="${b_ids[$b_idx]}"
    local CURRENT_BNAME="${b_names[$b_idx]}"
    AS_KEYS_FORMATTED+=("【账单: ${CURRENT_BNAME}】")

    local pid
    pid=$(new_project_id)
    local pname
    pname=$(new_project_name)
    log "INFO" "[$((b_idx + 1))/${#b_ids[@]}] 创建: ${pname} [${pid}]"

    if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
      gcloud billing projects link "$pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
      sleep 15

      local a_key
      a_key=$(_extract_single_project "$pid" || true)
      if [ -n "$a_key" ]; then
        log "SUCCESS" "[$pid] Gemini key 提取成功"
        AS_KEYS_FORMATTED+=("$a_key")
      else
        log "WARN" "[$pid] Gemini key 提取失败"
      fi
    else
      log "ERROR" "项目创建失败: $pid"
    fi
  done

  local pure_a=0
  local item
  for item in "${AS_KEYS_FORMATTED[@]}"; do
    [[ "$item" != *"【账单"* ]] && pure_a=$((pure_a + 1))
  done

  if [ "$pure_a" -gt 0 ]; then
    echo -e "\n${GREEN}${BOLD}====== Gemini / AI Studio 标准 key 列表 (共 ${pure_a} 个) ======${NC}"
    local k
    for k in "${AS_KEYS_FORMATTED[@]}"; do
      if [[ "$k" == *"【账单"* ]]; then
        echo -e "\n${CYAN}${k}${NC}"
      else
        echo -e "${GREEN}${k}${NC}"
      fi
    done
    echo
  fi
}

# ===== Option 8: New - patch existing projects with the latest API set =====
option8_enable_latest_apis_existing() {
  prompt_upgrade_billing || return 1

  echo -e "\n${CYAN}${BOLD}====== 选项8: 给现有已绑账单项目补齐 2026-08 最新 API ======${NC}"
  echo "1. 当前 gcloud project"
  echo "2. 所有已绑定账单的可见项目"
  echo "3. 手动输入 project ID"

  local choice
  read -r -p "请选择 [1-3, 默认: 2]: " choice < /dev/tty
  choice=${choice:-2}

  local targets=()

  case "$choice" in
    1)
      local current
      current=$(gcloud config get-value project 2>/dev/null || true)
      if [ -z "$current" ] || [ "$current" = "(unset)" ]; then
        log "ERROR" "当前 gcloud project 未设置"
        return 1
      fi
      targets+=("$current")
      ;;
    2)
      local projects
      projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null || true)
      local pid
      for pid in $projects; do
        local b_info
        b_info=$(gcloud billing projects describe "$pid" --format='value(billingAccountName)' 2>/dev/null || true)
        [ -n "$b_info" ] && targets+=("$pid")
      done
      ;;
    3)
      local manual_pid
      read -r -p "输入 project ID: " manual_pid < /dev/tty
      [ -n "$manual_pid" ] && targets+=("$manual_pid")
      ;;
    *)
      log "ERROR" "无效选择"
      return 1
      ;;
  esac

  if [ "${#targets[@]}" -eq 0 ]; then
    log "ERROR" "没有可处理的项目"
    return 1
  fi

  log "INFO" "将处理 ${#targets[@]} 个项目"
  local pid
  for pid in "${targets[@]}"; do
    log "INFO" "========== 补齐 API: $pid =========="
    v60_enable_all_services "$pid"
    check_api_ready "$pid" "【补齐API】" || true
    show_enabled_api_summary "$pid"
  done

  log "SUCCESS" "现有项目 API 补齐流程完成"
}

show_api_catalog() {
  echo -e "\n${CYAN}${BOLD}====== v${VERSION} 默认启用 API (${#FULL_API_SERVICES[@]} 个) ======${NC}"
  local svc
  for svc in "${CORE_API_SERVICES[@]}"; do echo "[CORE]    $svc"; done
  for svc in "${AGENT_PLATFORM_API_SERVICES[@]}"; do echo "[AGENT]   $svc"; done
  for svc in "${RUNTIME_API_SERVICES[@]}"; do echo "[RUNTIME] $svc"; done
  for svc in "${COMPAT_API_SERVICES[@]}"; do echo "[COMPAT]  $svc"; done
  echo
  echo "Legacy IAM Connectors 默认不开启。需要兼容旧项目时运行："
  echo "ENABLE_LEGACY_IAM_CONNECTORS=1 bash test.sh"
}

# ===== Main menu =====
show_menu() {
  echo -e "\n${CYAN}${BOLD}====== 喵酱的 GCP 管理器 v${VERSION} ======${NC}"
  echo "1. [经典] 自动创建项目并提 Gemini key (解绑旧项目)"
  echo "2. [保留] 自动创建项目并提 Gemini key (保留旧结算绑定)"
  echo "3. 提取现有项目 Vertex Authorization + Gemini key"
  echo "4. 批量删除项目"
  echo "5. [护盾] 保护原项目 -> 转移结算 -> 建2个凑齐3个 Gemini key"
  echo "6. [完整] 创建项目 -> 开全套最新 API -> 提 Vertex + Gemini key"
  echo "7. [重置] 删光账单关联项目 -> 每账单建1提1 Gemini key"
  echo "8. [新增] 给现有项目补齐 2026-08 最新 Agent Platform API"
  echo "9. 查看本版默认启用的 API 清单"
  echo "0. 退出"

  local choice
  read -r -p "请主人吩咐: " choice < /dev/tty

  case "$choice" in
    1)
      check_env && gemini_create_projects "false" "false"
      ;;
    2)
      check_env || return
      echo -e "\n${CYAN}请选择模式：${NC}"
      echo "1. 自定义选择结算账户和数量"
      echo "2. 所有可用结算账户各创建3个项目"
      local sub_choice
      read -r -p "请选择 [1-2, 默认: 1]: " sub_choice < /dev/tty
      sub_choice=${sub_choice:-1}
      if [ "$sub_choice" = "2" ]; then
        gemini_create_projects "true" "true"
      else
        gemini_create_projects "true" "false"
      fi
      ;;
    3)
      check_env && gemini_get_keys_from_existing
      ;;
    4)
      check_env && gemini_delete_projects
      ;;
    5)
      check_env && rebuild_and_transfer_billing
      ;;
    6)
      check_env && option6_handler
      ;;
    7)
      check_env && option7_handler
      ;;
    8)
      check_env && option8_enable_latest_apis_existing
      ;;
    9)
      show_api_catalog
      ;;
    0)
      exit 0
      ;;
    *)
      log "ERROR" "无效指令"
      ;;
  esac
}

main() {
  while true; do
    show_menu
  done
}

main
