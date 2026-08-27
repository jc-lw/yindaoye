
# GCP API Key Manager - Agent Platform + Vertex/Gemini + Agent Studio APIs
# Version: 6.3.2 (2026-08-27)
# Changes:
#   - Remove the previous experimental Billing status diagnostic flow
#   - Billing discovery no longer filters open=true and never blocks on Free/Paid tier
#   - Enable IAM Connectors API by default because Agent Studio still displays/checks it
#   - Add App Lifecycle Manager API (saasservicemgmt.googleapis.com)
#   - Add current App Lifecycle Manager dependency APIs from Google documentation
#   - Add Security Command Center API (securitycenter.googleapis.com)
#   - Verify EVERY API requested by this script, not only a 22-API subset
#   - Automatically re-submit any API that is still missing after the first async submission
#   - Two-phase multi-project flow: submit project A -> wait 5s -> project B -> ... -> verify/repair -> extract keys
#   - Exact per-project API summary includes names of any APIs still not enabled
#   - Fallback Billing discovery from the currently configured project; actual link errors are shown
#   - Distinguish "Billing Account linked" from project billingEnabled=true
#   - Detect UREQ_PROJECT_BILLING_NOT_OPEN as a non-retryable Google precondition
#   - On BILLING_NOT_OPEN, stop retrying the whole batch and probe each API once
#   - Track APIs blocked by closed/non-open Cloud Billing and never resend them in repair loops
#   - Continue enabling free/available APIs and continue key extraction even when some Cloud APIs are billing-blocked
#   - Final API summary separates ENABLED / BILLING_BLOCKED / ordinary MISSING

set -Euo pipefail

# ===== Colors =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ===== Global config =====
VERSION="6.3.2"
PROJECT_PREFIX="${PROJECT_PREFIX:-miaojiang}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-4}"
CACHE_FILE="$HOME/.miaojiang_keys.cache"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
API_BATCH_SIZE="${API_BATCH_SIZE:-8}"
API_BATCH_GAP="${API_BATCH_GAP:-1}"
PROJECT_SUBMIT_GAP="${PROJECT_SUBMIT_GAP:-5}"
API_REPAIR_ROUNDS="${API_REPAIR_ROUNDS:-4}"
API_REPAIR_SLEEP="${API_REPAIR_SLEEP:-5}"

rm -f "$CACHE_FILE" 2>/dev/null || true

# Per-process state used by the smart API engine. A project can be successfully
# linked to a Billing Account while ProjectBillingInfo.billingEnabled is false.
# In that case some Google Cloud services return UREQ_PROJECT_BILLING_NOT_OPEN.
declare -A BILLING_BLOCKED_APIS=()


# ===== Current Google Cloud service sets =====
# Core admin + AI services.
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

# APIs shown/used by the current Agent Studio / Agent Platform experience.
# IAM Connectors is legacy for new auth integrations, but Agent Studio can still
# display it in the "Enable APIs" dialog, so v6.3 enables it by default.
AGENT_PLATFORM_API_SERVICES=(
  "agentregistry.googleapis.com"
  "agentidentity.googleapis.com"
  "agentidentitycredentials.googleapis.com"
  "apphub.googleapis.com"
  "apptopology.googleapis.com"
  "cloudapiregistry.googleapis.com"
  "iamconnectors.googleapis.com"
  "iap.googleapis.com"
  "modelarmor.googleapis.com"
  "networksecurity.googleapis.com"
  "networkservices.googleapis.com"
  "notebooks.googleapis.com"
  "observability.googleapis.com"
  "securitycenter.googleapis.com"
  "telemetry.googleapis.com"
  "cloudtrace.googleapis.com"
  "texttospeech.googleapis.com"
  "dataform.googleapis.com"
  "dns.googleapis.com"
  "saasservicemgmt.googleapis.com"
)

# App Lifecycle Manager dependencies documented by Google.
# Duplicates already present in CORE/AGENT (storage/apphub/resource-manager/IAM/
# monitoring/logging) are intentionally not repeated here.
APP_LIFECYCLE_DEPENDENCY_SERVICES=(
  "artifactregistry.googleapis.com"
  "cloudbuild.googleapis.com"
  "developerconnect.googleapis.com"
  "config.googleapis.com"
  "designcenter.googleapis.com"
  "cloudasset.googleapis.com"
  "servicehealth.googleapis.com"
)

# Agent Runtime / common deployment integrations not already listed above.
RUNTIME_API_SERVICES=(
  "run.googleapis.com"
  "eventarc.googleapis.com"
  "pubsub.googleapis.com"
  "secretmanager.googleapis.com"
  "servicenetworking.googleapis.com"
  "networkconnectivity.googleapis.com"
  "servicedirectory.googleapis.com"
)

COMPAT_API_SERVICES=(
  "dialogflow.googleapis.com"
)

FULL_API_SERVICES=(
  "${CORE_API_SERVICES[@]}"
  "${AGENT_PLATFORM_API_SERVICES[@]}"
  "${APP_LIFECYCLE_DEPENDENCY_SERVICES[@]}"
  "${RUNTIME_API_SERVICES[@]}"
  "${COMPAT_API_SERVICES[@]}"
)

# v6.3.2 verifies the entire requested set. This is deliberately not a smaller
# "critical" subset: a project only passes after every requested API is visible
# in `gcloud services list --enabled`.
VERIFY_API_SERVICES=("${FULL_API_SERVICES[@]}")

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

# ===== Billing discovery / precheck =====
# v6.3.1 intentionally does NOT classify Free Trial / Free tier / Paid tier.
# It also does NOT use `open=true` as a hard gate.
#
# Discovery order:
#   1) `gcloud billing accounts list` WITHOUT an open filter.
#   2) If that is empty (for example because list permission is limited), read the
#      Billing Account attached to the currently configured project.
#   3) If discovery still fails, project creation itself is NOT blocked. Options
#      that actually need to attach a Billing Account can ask for a Billing ID.

get_current_project_billing_account() {
  local project_id
  project_id=$(gcloud config get-value project 2>/dev/null || true)
  if [ -z "$project_id" ] || [ "$project_id" = "(unset)" ]; then
    return 1
  fi

  local billing_name
  billing_name=$(gcloud billing projects describe "$project_id" \
    --format='value(billingAccountName)' 2>/dev/null || true)
  billing_name=$(echo "$billing_name" | tr -d '\r' | xargs)

  if [ -n "$billing_name" ]; then
    echo "$billing_name"
    return 0
  fi
  return 1
}

# Output TSV: resource-name<TAB>display-name<TAB>currency
billing_accounts_tsv() {
  local raw
  raw=$(gcloud billing accounts list \
    --format='value(name,displayName,currencyCode)' \
    2>/dev/null || true)

  if [ -n "$raw" ]; then
    printf '%s\n' "$raw"
    return 0
  fi

  # Some identities can use a project's attached Billing Account but cannot list
  # all Billing Accounts. Recover that account from the current project.
  local billing_name
  billing_name=$(get_current_project_billing_account || true)
  [ -z "$billing_name" ] && return 1

  local billing_id="${billing_name#billingAccounts/}"
  local display_name currency_code
  display_name=$(gcloud billing accounts describe "$billing_id" \
    --format='value(displayName)' 2>/dev/null || true)
  currency_code=$(gcloud billing accounts describe "$billing_id" \
    --format='value(currencyCode)' 2>/dev/null || true)

  [ -z "$display_name" ] && display_name="Current Project Billing"
  [ -z "$currency_code" ] && currency_code="Unknown"

  printf '%s\t%s\t%s\n' "$billing_name" "$display_name" "$currency_code"
}

billing_account_names() {
  local raw
  raw=$(billing_accounts_tsv || true)
  [ -z "$raw" ] && return 1

  local billing_name display_name currency_code
  while IFS=$'\t' read -r billing_name display_name currency_code; do
    [ -n "$billing_name" ] && printf '%s\n' "$billing_name"
  done <<< "$raw"
}

prompt_upgrade_billing() {
  log "INFO" "Billing 检测：Free/Paid/Open 状态均不作为项目创建限制。"

  local billing_raw
  billing_raw=$(billing_accounts_tsv || true)

  if [ -z "$billing_raw" ]; then
    log "WARN" "当前 CLI 暂未解析到 Billing Account；不阻止创建项目。"
    log "WARN" "若后续需要绑定账单，脚本会要求输入 Billing Account ID，并显示 Google 的真实绑定错误。"
    return 0
  fi

  local count=0
  local billing_name display_name currency_code
  while IFS=$'\t' read -r billing_name display_name currency_code; do
    [ -z "$billing_name" ] && continue
    count=$((count + 1))
    log "SUCCESS" "[${billing_name#billingAccounts/}] 检测到 Billing Account: ${display_name:-Unknown} | ${currency_code:-Unknown}"
  done <<< "$billing_raw"

  log "SUCCESS" "Billing 检测完成：${count} 个账户；不区分 Free/Paid，不检查 open 状态，允许继续。"
  return 0
}

# A successful `gcloud billing projects link` only means the relationship was
# written. The authoritative project-side flag is ProjectBillingInfo.billingEnabled.
# If it is false, the project can still exist and some APIs can still be enabled,
# but paid Cloud services can reject activation with UREQ_PROJECT_BILLING_NOT_OPEN.
project_billing_info() {
  local project_id="$1"
  local info
  info=$(gcloud billing projects describe "$project_id" \
    --format='value(billingEnabled,billingAccountName)' 2>/dev/null || true)
  [ -n "$info" ] && printf '%s
' "$info"
}

project_billing_enabled() {
  local project_id="$1"
  local info enabled account_name
  info=$(project_billing_info "$project_id" || true)
  [ -z "$info" ] && return 1
  read -r enabled account_name <<< "$info"
  [ "$enabled" = "True" ] || [ "$enabled" = "true" ]
}

show_project_billing_state() {
  local project_id="$1"
  local info enabled account_name
  info=$(project_billing_info "$project_id" || true)
  if [ -z "$info" ]; then
    log "WARN" "[$project_id] 无法读取 ProjectBillingInfo；后续按 Google 实际 API 返回处理。"
    return 2
  fi

  read -r enabled account_name <<< "$info"
  if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
    log "SUCCESS" "[$project_id] ProjectBillingInfo: billingEnabled=true | ${account_name:-no-account}"
    return 0
  fi

  log "WARN" "[$project_id] ProjectBillingInfo: billingEnabled=false | ${account_name:-no-account}"
  log "WARN" "[$project_id] 项目可以保留/继续处理，但需要开放 Cloud Billing 的服务可能返回 UREQ_PROJECT_BILLING_NOT_OPEN。"
  return 1
}

is_billing_not_open_error() {
  local text="${1:-}"
  echo "$text" | grep -qiE \
    'UREQ_PROJECT_BILLING_NOT_OPEN|PROJECT_BILLING_NOT_OPEN|billing account .* is not open|billing must be enabled for activation|project billing.*not open'
}

billing_block_key() {
  printf '%s|%s' "$1" "$2"
}

mark_billing_blocked_api() {
  local project_id="$1"
  local api="$2"
  BILLING_BLOCKED_APIS["$(billing_block_key "$project_id" "$api")"]=1
}

is_billing_blocked_api() {
  local project_id="$1"
  local api="$2"
  [ -n "${BILLING_BLOCKED_APIS[$(billing_block_key "$project_id" "$api")]+x}" ]
}

clear_billing_blocked_for_project() {
  local project_id="$1"
  local key
  for key in "${!BILLING_BLOCKED_APIS[@]}"; do
    if [[ "$key" == "${project_id}|"* ]]; then
      unset 'BILLING_BLOCKED_APIS[$key]'
    fi
  done
}

# Show the real Google error when a Billing Account cannot be attached, then
# immediately check billingEnabled instead of assuming "link succeeded" means
# the Cloud Billing account is active for paid services.
link_project_to_billing() {
  local project_id="$1"
  local billing_id="$2"
  local out

  if out=$(gcloud billing projects link "$project_id" \
      --billing-account="$billing_id" --quiet 2>&1); then
    log "SUCCESS" "[$project_id] Billing Account 已关联: $billing_id"
    if project_billing_enabled "$project_id"; then
      log "SUCCESS" "[$project_id] Billing 状态确认: billingEnabled=true"
      clear_billing_blocked_for_project "$project_id"
    else
      log "WARN" "[$project_id] Billing 已关联，但 billingEnabled=false；不会阻止创建项目或提取可用 Key。"
      log "WARN" "[$project_id] 需要开放 Cloud Billing 的 API 将自动标记 BILLING_BLOCKED，并停止无意义重试。"
    fi
    return 0
  fi

  local short_out
  short_out=$(echo "$out" | tail -n 8 | tr '
' ' ' | cut -c1-1200)
  log "WARN" "[$project_id] Billing 绑定失败 ($billing_id): $short_out"
  return 1
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

# ===== API enable + full verification/repair engine =====
get_requested_api_services() {
  printf '%s
' "${FULL_API_SERVICES[@]}"
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

    # This is a Google billing precondition, not a transient network/rate error.
    # Retrying the same batch 5 times can never fix it.
    if is_billing_not_open_error "$out"; then
      local short_out
      short_out=$(echo "$out" | tail -n 5 | tr '
' ' ' | cut -c1-700)
      log "WARN" "[$proj] ${batch_name} 命中 BILLING_NOT_OPEN；停止整包重试，立即拆分逐项检测。 ${short_out}"
      return 20
    fi

    if echo "$out" | grep -qiE '429|RESOURCE_EXHAUSTED|RATE_LIMIT_EXCEEDED|quota|Mutate requests|rate.?limit'; then
      local exp=$((1 << (attempt - 1)))
      local delay=$((exp * 6 + RANDOM % 6))
      [ "$delay" -gt 60 ] && delay=60
      log "WARN" "[$proj] ${batch_name} 遇到 Service Usage 配额限制，等待 ${delay}s 后重试 (${attempt}/${max_attempts})"
      sleep "$delay"
    else
      local short_out
      short_out=$(echo "$out" | tail -n 3 | tr '
' ' ' | cut -c1-500)
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

  # If this exact API was already proven billing-blocked during this run, don't
  # send it again until the project's billingEnabled state changes.
  if is_billing_blocked_api "$proj" "$api"; then
    return 20
  fi

  while [ "$attempt" -le "$max_attempts" ]; do
    if out=$(gcloud services enable "$api" --project="$proj" --async --quiet 2>&1); then
      log "SUCCESS" "[$proj] 已提交: $api"
      return 0
    fi

    if is_billing_not_open_error "$out"; then
      mark_billing_blocked_api "$proj" "$api"
      log "WARN" "[$proj] [BILLING_BLOCKED] $api"
      return 20
    fi

    if echo "$out" | grep -qiE '429|RESOURCE_EXHAUSTED|RATE_LIMIT_EXCEEDED|quota|Mutate requests|rate.?limit'; then
      local delay=$((attempt * 12 + RANDOM % 8))
      log "WARN" "[$proj] $api 遇到配额限制，等待 ${delay}s (${attempt}/${max_attempts})"
      sleep "$delay"
    else
      local short_out
      short_out=$(echo "$out" | tail -n 2 | tr '
' ' ' | cut -c1-400)
      log "WARN" "[$proj] $api 暂未成功: $short_out"
      sleep $((4 + attempt * 2))
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

submit_api_list_batched() {
  local proj="$1"
  local label="$2"
  shift 2
  local requested=("$@")

  [ "${#requested[@]}" -eq 0 ] && return 0

  local start=0
  local batch_num=1
  local total=${#requested[@]}
  local api

  while [ "$start" -lt "$total" ]; do
    local batch=("${requested[@]:start:API_BATCH_SIZE}")
    local batch_rc=0
    enable_api_with_retry "$proj" "${label}-批次${batch_num}" "${batch[@]}" || batch_rc=$?

    if [ "$batch_rc" -ne 0 ]; then
      if [ "$batch_rc" -eq 20 ]; then
        log "WARN" "[$proj] ${label}-批次${batch_num} 含至少一个 Billing 不可用服务；不再重试整包，逐项探测一次。"
      else
        log "WARN" "[$proj] ${label}-批次${batch_num} 整包失败，改为逐个补发"
      fi

      for api in "${batch[@]}"; do
        local single_rc=0
        enable_single_api_with_retry "$proj" "$api" || single_rc=$?
        case "$single_rc" in
          0) ;;
          20) ;; # Already logged and recorded as BILLING_BLOCKED.
          *) log "ERROR" "[$proj] 最终未能提交: $api" ;;
        esac
        sleep 1
      done
    fi

    start=$((start + API_BATCH_SIZE))
    batch_num=$((batch_num + 1))
    if [ "$start" -lt "$total" ]; then
      sleep "$API_BATCH_GAP"
    fi
  done
}

v60_enable_all_services() {
  local proj="$1"
  local requested=()
  local api
  while IFS= read -r api; do
    [ -n "$api" ] && requested+=("$api")
  done < <(get_requested_api_services)

  # Re-opened billing can make previously blocked APIs available. Clear the
  # per-process block cache when Google says billingEnabled=true.
  if project_billing_enabled "$proj"; then
    clear_billing_blocked_for_project "$proj"
    log "INFO" "[$proj] Project Billing: billingEnabled=true"
  else
    log "WARN" "[$proj] Project Billing: billingEnabled=false/unknown；仍会启用所有可用 API，Billing 限制项只尝试一次。"
  fi

  log "INFO" "[$proj] 准备提交 Agent Studio / Agent Platform 全套 API，共 ${#requested[@]} 个"
  submit_api_list_batched "$proj" "API" "${requested[@]}"
  log "INFO" "[$proj] 全套 API 首轮扫描/提交完成"
}

# Backward-compatible names used by older branches of this script.
v27_enable_all_services() {
  v60_enable_all_services "$@"
}

get_missing_requested_apis() {
  local pid="$1"
  local enabled_list
  enabled_list=$(gcloud services list --project="$pid" --enabled --format='value(config.name)' 2>/dev/null || true)

  declare -A enabled_map=()
  local svc
  while IFS= read -r svc; do
    [ -n "$svc" ] && enabled_map["$svc"]=1
  done <<< "$enabled_list"

  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    if [ -z "${enabled_map[$svc]+x}" ]; then
      printf '%s
' "$svc"
    fi
  done < <(get_requested_api_services)
}

get_repairable_missing_apis() {
  local pid="$1"
  local svc
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    if ! is_billing_blocked_api "$pid" "$svc"; then
      printf '%s
' "$svc"
    fi
  done < <(get_missing_requested_apis "$pid")
}

get_billing_blocked_missing_apis() {
  local pid="$1"
  local svc
  while IFS= read -r svc; do
    [ -z "$svc" ] && continue
    if is_billing_blocked_api "$pid" "$svc"; then
      printf '%s
' "$svc"
    fi
  done < <(get_missing_requested_apis "$pid")
}

check_api_ready() {
  local pid="$1"
  local stage="$2"
  local round=1
  local total
  total=$(get_requested_api_services | grep -c . || true)

  if project_billing_enabled "$pid"; then
    clear_billing_blocked_for_project "$pid"
  fi

  log "INFO" "[$pid] ${stage} 开始全量核验 ${total} 个 API；普通缺失自动补发，Billing 阻止项不会死循环"

  while [ "$round" -le "$API_REPAIR_ROUNDS" ]; do
    local missing=()
    local repairable=()
    local blocked=()
    mapfile -t missing < <(get_missing_requested_apis "$pid")

    if [ "${#missing[@]}" -eq 0 ]; then
      log "SUCCESS" "[$pid] ${stage} 全量核验通过：${total}/${total} 个 API 已启用"
      return 0
    fi

    mapfile -t repairable < <(get_repairable_missing_apis "$pid")
    mapfile -t blocked < <(get_billing_blocked_missing_apis "$pid")

    log "WARN" "[$pid] ${stage} 第 ${round}/${API_REPAIR_ROUNDS} 轮：缺失 ${#missing[@]} | 可补发 ${#repairable[@]} | Billing阻止 ${#blocked[@]}"

    local svc
    for svc in "${blocked[@]}"; do
      echo -e "${YELLOW}  [BILLING_BLOCKED] ${svc}${NC}" >&2
    done
    for svc in "${repairable[@]}"; do
      echo -e "${YELLOW}  [REPAIR] ${svc}${NC}" >&2
    done

    # Nothing left to repair: all remaining gaps are a known Billing precondition.
    if [ "${#repairable[@]}" -eq 0 ]; then
      log "WARN" "[$pid] ${stage} 剩余 ${#blocked[@]} 个 API 均被 Cloud Billing 状态阻止；停止重复请求，继续后续 Key 流程。"
      return 2
    fi

    submit_api_list_batched "$pid" "补发${round}" "${repairable[@]}"
    log "INFO" "[$pid] 补发完成，等待 ${API_REPAIR_SLEEP}s 后重新核验"
    sleep "$API_REPAIR_SLEEP"

    # If billing was activated while the script was running, immediately allow
    # formerly blocked APIs to enter the next repair round.
    if project_billing_enabled "$pid"; then
      clear_billing_blocked_for_project "$pid"
    fi

    round=$((round + 1))
  done

  local final_missing=()
  local final_blocked=()
  local final_repairable=()
  mapfile -t final_missing < <(get_missing_requested_apis "$pid")
  mapfile -t final_blocked < <(get_billing_blocked_missing_apis "$pid")
  mapfile -t final_repairable < <(get_repairable_missing_apis "$pid")

  if [ "${#final_missing[@]}" -eq 0 ]; then
    log "SUCCESS" "[$pid] ${stage} 全量核验通过：${total}/${total} 个 API 已启用"
    return 0
  fi

  if [ "${#final_repairable[@]}" -eq 0 ] && [ "${#final_blocked[@]}" -gt 0 ]; then
    log "WARN" "[$pid] ${stage} 核验结束：${#final_blocked[@]} 个 API 因 Cloud Billing 未开放而未启用；不再重试。"
    return 2
  fi

  log "ERROR" "[$pid] ${stage} 完成 ${API_REPAIR_ROUNDS} 轮后仍有 ${#final_missing[@]} 个 API 未启用"
  local svc
  for svc in "${final_blocked[@]}"; do
    echo -e "${YELLOW}  [BILLING_BLOCKED] ${svc}${NC}" >&2
  done
  for svc in "${final_repairable[@]}"; do
    echo -e "${RED}  [MISSING] ${svc}${NC}" >&2
  done
  return 1
}

show_enabled_api_summary() {
  local pid="$1"
  local total
  total=$(get_requested_api_services | grep -c . || true)
  local missing=()
  local blocked=()
  local repairable=()
  mapfile -t missing < <(get_missing_requested_apis "$pid")
  mapfile -t blocked < <(get_billing_blocked_missing_apis "$pid")
  mapfile -t repairable < <(get_repairable_missing_apis "$pid")
  local ok=$((total - ${#missing[@]}))

  log "INFO" "[$pid] API 汇总: ENABLED ${ok}/${total} | BILLING_BLOCKED ${#blocked[@]} | MISSING ${#repairable[@]}"

  local svc
  for svc in "${blocked[@]}"; do
    echo -e "${YELLOW}  [BILLING_BLOCKED] ${svc}${NC}" >&2
  done
  for svc in "${repairable[@]}"; do
    echo -e "${RED}  [MISSING] ${svc}${NC}" >&2
  done

  if [ "${#blocked[@]}" -gt 0 ]; then
    echo -e "${YELLOW}  提示：这些 API 不是脚本重试能解决的；Google 返回的前置条件是 Cloud Billing 未开放。${NC}" >&2
    echo -e "${CYAN}  Activate / Billing: https://console.cloud.google.com/welcome${NC}" >&2
  fi
}

submit_projects_api_phase() {
  local projects=("$@")
  local total=${#projects[@]}
  local idx=0
  local pid

  [ "$total" -eq 0 ] && return 0

  log "INFO" "====== API 第一阶段：逐项目提交全套 API ======"
  for pid in "${projects[@]}"; do
    idx=$((idx + 1))
    log "INFO" "[提交 ${idx}/${total}] $pid"
    v60_enable_all_services "$pid"
    if [ "$idx" -lt "$total" ]; then
      log "INFO" "[$pid] 本项目提交完成，等待 ${PROJECT_SUBMIT_GAP}s 后提交下一个项目"
      sleep "$PROJECT_SUBMIT_GAP"
    fi
  done
  log "SUCCESS" "API 第一阶段完成：${total} 个项目均已完成首轮提交"
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
  billing_raw=$(billing_accounts_tsv || true)

  if [ -z "$billing_raw" ]; then
    echo -e "\n${YELLOW}自动检测不到 Billing Account，但不会把 Free/Paid 当成限制。${NC}" >&2
    local manual_billing
    read -r -p "请输入 Billing Account ID [留空取消绑定]: " manual_billing < /dev/tty
    manual_billing="${manual_billing#billingAccounts/}"
    manual_billing=$(echo "$manual_billing" | tr -d ' ')
    if [ -z "$manual_billing" ]; then
      log "ERROR" "没有可用于绑定的 Billing Account"
      return 1
    fi
    SELECTED_BILLING_IDS=("$manual_billing")
    SELECTED_BILLING_NAMES=("Manual Billing Account")
    return 0
  fi

  local ids=()
  local names=()
  local bid bname currency_code
  while IFS=$'\t' read -r bid bname currency_code; do
    [ -z "$bid" ] && continue
    ids+=("${bid##*/}")
    names+=("${bname:-Billing Account}")
  done <<< "$billing_raw"

  if [ "${#ids[@]}" -eq 1 ]; then
    log "INFO" "检测到 1 个 Billing Account: ${names[0]} (${ids[0]})"
    SELECTED_BILLING_IDS=("${ids[0]}")
    SELECTED_BILLING_NAMES=("${names[0]}")
    return 0
  fi

  echo -e "\n${CYAN}${BOLD}可用的 Billing Account：${NC}" >&2
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
    log "ERROR" "未选择任何 Billing Account"
    return 1
  fi
  return 0
}

_select_billing_for_opt6() {
  local billing_raw
  billing_raw=$(billing_accounts_tsv || true)

  if [ -z "$billing_raw" ]; then
    echo -e "\n${YELLOW}自动检测不到 Billing Account。${NC}" >&2
    local manual_billing
    read -r -p "请输入 Billing Account ID: " manual_billing < /dev/tty
    manual_billing="${manual_billing#billingAccounts/}"
    manual_billing=$(echo "$manual_billing" | tr -d ' ')
    if [ -n "$manual_billing" ]; then
      echo "$manual_billing"
      return 0
    fi
    return 1
  fi

  local ids=()
  local names=()
  local bid bname currency_code
  while IFS=$'\t' read -r bid bname currency_code; do
    [ -z "$bid" ] && continue
    ids+=("${bid##*/}")
    names+=("${bname:-Billing Account}")
  done <<< "$billing_raw"

  if [ "${#ids[@]}" -eq 1 ]; then
    log "INFO" "检测到 1 个 Billing Account: ${names[0]} (${ids[0]})"
    echo "${ids[0]}"
    return 0
  fi

  echo -e "\n${CYAN}${BOLD}可用的 Billing Account：${NC}" >&2
  local idx
  for idx in "${!ids[@]}"; do
    echo -e "  ${GREEN}$((idx + 1))${NC}. ${names[$idx]} (${ids[$idx]})" >&2
  done

  local choice
  read -r -p "请选择 1 个主要 Billing Account [默认: 1]: " choice < /dev/tty
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
    billing_raw=$(billing_accounts_tsv || true)
    if [ -z "$billing_raw" ]; then
      log "ERROR" "未找到可用于绑定的 Billing Account"
      return 1
    fi
    SELECTED_BILLING_IDS=()
    SELECTED_BILLING_NAMES=()
    while IFS=$'\t' read -r bid bname currency_code; do
      [ -z "$bid" ] && continue
      SELECTED_BILLING_IDS+=("${bid##*/}")
      SELECTED_BILLING_NAMES+=("${bname:-Billing Account}")
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

      link_project_to_billing "$project_id" "$billing_account" || true

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

  echo -e "\n${CYAN}${BOLD}====== 选项3: 现有项目 -> 全套 API -> 全量复检/补发 -> 提取密钥 ======${NC}"
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

  log "INFO" "检测到 ${#valid_projects[@]} 个已绑账单项目。先全部提交 API，再统一核验/补发/提 Key。"
  submit_projects_api_phase "${valid_projects[@]}"

  local VERTEX_KEYS=()
  local AS_KEYS=()
  local project_id

  log "INFO" "====== API 第二阶段：全量核验、缺失补发，然后提取 Key ======"
  for project_id in "${valid_projects[@]}"; do
    log "INFO" "正在复检并处理: $project_id"

    check_api_ready "$project_id" "【提Key前】" || true

    if [ "$sub_choice" = "1" ] || [ "$sub_choice" = "3" ]; then
      local v_key
      v_key=$(v27_setup_and_extract_aq_key "$project_id" || true)
      if [ -n "$v_key" ]; then
        VERTEX_KEYS+=("$v_key")
        log "SUCCESS" "[$project_id] Vertex key 提取成功: $(mask_key "$v_key")"
      else
        log "WARN" "[$project_id] Vertex Authorization key 提取失败"
      fi
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

    # Key creation may itself cause service state propagation. Final exact recheck.
    check_api_ready "$project_id" "【提Key后】" || true
    show_enabled_api_summary "$project_id"
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

  local TARGET_BILLING_ID
  TARGET_BILLING_ID=$(_select_billing_for_opt6) || {
    log "ERROR" "未选择可用于绑定的 Billing Account"
    return 1
  }

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
  link_project_to_billing "$ORIGINAL_PROJECT" "$TARGET_BILLING_ID" || true
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
      link_project_to_billing "$pid" "$TARGET_BILLING_ID" || true
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
        link_project_to_billing "$pid" "$BILLING_ACCOUNT" || true
        created_pids+=("$pid")
      fi
    done

    sleep 5
    local pid
    submit_projects_api_phase "${created_pids[@]}"
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

      check_api_ready "$pid" "【提Key后】" || true
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
    log "INFO" "====== 执行 6.3.2 多账单自动模式 ======"

    local billing_raw
    billing_raw=$(billing_accounts_tsv || true)
    if [ -z "$billing_raw" ]; then
      log "ERROR" "未找到可用于绑定的 Billing Account"
      return 1
    fi

    local b_ids=()
    local b_names=()
    while IFS=$'\t' read -r bid bname currency_code; do
      [ -z "$bid" ] && continue
      b_ids+=("${bid##*/}")
      b_names+=("${bname:-Billing Account}")
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
          link_project_to_billing "$default_pid" "$CURRENT_BILLING" || true
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
            link_project_to_billing "$pid" "$CURRENT_BILLING" || true
            created_pids+=("$pid")
          fi
        done

        sleep 5
        local pid
        submit_projects_api_phase "${created_pids[@]}"

        for pid in "${created_pids[@]}"; do
          check_api_ready "$pid" "【提Key前】" || true
          local v_key
          v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
          if [ -n "$v_key" ]; then
            VERTEX_KEYS+=("$v_key")
            log "SUCCESS" "[$pid] Vertex key: $(mask_key "$v_key")"
          fi
          check_api_ready "$pid" "【提Key后】" || true
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
            link_project_to_billing "$pid" "$CURRENT_BILLING" || true
            created_pids+=("$pid")
          fi
        done

        sleep 5
        local pid
        submit_projects_api_phase "${created_pids[@]}"

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
          check_api_ready "$pid" "【提Key后】" || true
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
  echo -e "${YELLOW}⚠️ 此操作会解绑并删除所有可见 Billing Account 下关联的项目。${NC}"
  read -r -p "确认执行吗？[y/N]: " confirm_del < /dev/tty
  if [[ ! "$confirm_del" =~ ^[Yy]$ ]]; then
    log "INFO" "操作已取消"
    return 0
  fi

  local billing_raw
  billing_raw=$(billing_accounts_tsv || true)
  if [ -z "$billing_raw" ]; then
    log "ERROR" "未找到可用于绑定的 Billing Account"
    return 1
  fi

  local b_ids=()
  local b_names=()
  while IFS=$'\t' read -r bid bname currency_code; do
    [ -z "$bid" ] && continue
    b_ids+=("${bid##*/}")
    b_names+=("${bname:-Billing Account}")
  done <<< "$billing_raw"

  log "INFO" "检测到 ${#b_ids[@]} 个 Billing Account"

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
      link_project_to_billing "$pid" "$CURRENT_BILLING" || true
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

# ===== Option 8: patch existing projects with the full current API set =====
option8_enable_latest_apis_existing() {
  prompt_upgrade_billing || return 1

  echo -e "
${CYAN}${BOLD}====== 选项8: 给现有项目补齐 Agent Studio / Agent Platform 全套 API ======${NC}"
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

  log "INFO" "将处理 ${#targets[@]} 个项目：第一阶段逐项目提交，每个项目之间间隔 ${PROJECT_SUBMIT_GAP}s"
  submit_projects_api_phase "${targets[@]}"

  log "INFO" "====== 第二阶段：逐项目全量核验，并自动补发缺失 API ======"
  local pid
  for pid in "${targets[@]}"; do
    check_api_ready "$pid" "【补齐API】" || true
    show_enabled_api_summary "$pid"
  done

  log "SUCCESS" "现有项目 API 补齐流程完成"
}

show_api_catalog() {
  echo -e "\n${CYAN}${BOLD}====== v${VERSION} 默认启用并全量核验的 API (${#FULL_API_SERVICES[@]} 个) ======${NC}"
  local svc
  for svc in "${CORE_API_SERVICES[@]}"; do echo "[CORE]      $svc"; done
  for svc in "${AGENT_PLATFORM_API_SERVICES[@]}"; do echo "[AGENT]     $svc"; done
  for svc in "${APP_LIFECYCLE_DEPENDENCY_SERVICES[@]}"; do echo "[LIFECYCLE] $svc"; done
  for svc in "${RUNTIME_API_SERVICES[@]}"; do echo "[RUNTIME]   $svc"; done
  for svc in "${COMPAT_API_SERVICES[@]}"; do echo "[COMPAT]    $svc"; done
  echo
  echo "v6.3.1 会对以上全部 API 做精确核验；发现缺失会自动再次发送 enable 请求。"
}

# ===== Main menu =====
show_menu() {
  echo -e "\n${CYAN}${BOLD}====== 喵酱的 GCP 管理器 v${VERSION} ======${NC}"
  echo "1. [经典] 自动创建项目并提 Gemini key (解绑旧项目)"
  echo "2. [保留] 自动创建项目并提 Gemini key (保留旧结算绑定)"
  echo "3. 提取现有项目 Vertex Authorization + Gemini key"
  echo "4. 批量删除项目"
  echo "5. [护盾] 保护原项目 -> 转移结算 -> 建2个凑齐3个 Gemini key"
  echo "6. [完整] 创建项目 -> 智能开全套 API -> 提 Vertex + Gemini key"
  echo "7. [重置] 删光账单关联项目 -> 每账单建1提1 Gemini key"
  echo "8. [补齐] 给现有项目补齐并全量复检 Agent Studio / Agent Platform API"
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
