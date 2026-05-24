#!/bin/bash
# 优化的 GCP API 密钥管理工具 - Vertex+AS完整源码
# 核心革命: 引入 --async 异步并发引擎，彻底解决一票否决导致的 3 分钟死锁问题
# 版本: 5.5.0

set -Euo pipefail

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="5.5.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-miaojiang}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
CACHE_FILE="$HOME/.miaojiang_keys.cache"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"

# 强制清空旧的污染缓存
rm -f "$CACHE_FILE" 2>/dev/null || true

# ===== 日志处理 =====
log() { 
  local level="${1:-INFO}"
  local msg="${2:-}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  case "$level" in
    "INFO") echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" >&2 ;;
    "SUCCESS") echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" >&2 ;;
    "WARN") echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
    "ERROR") echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
  esac
}

handle_error() {
  local exit_code=$?
  case $exit_code in 141|130) return 0 ;; esac
  if [ $exit_code -gt 1 ]; then return $exit_code; else return 0; fi
}
trap 'handle_error' ERR

# ===== 智能嗅探付费层级 =====
prompt_upgrade_billing() {
  log "INFO" "正在联网调用 Cloud Billing API，探测当前账号结算层级..."
  local active_billing
  active_billing=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1 || echo "")
  
  if [ -n "$active_billing" ]; then
    local is_open
    is_open=$(gcloud billing accounts describe "$active_billing" --format='value(open)' 2>/dev/null || echo "False")
    if [ "$is_open" = "True" ] || [ "$is_open" = "true" ]; then
       echo -e "\n${GREEN}${BOLD}✅ [系统探针] 检测到当前账户已关联活跃结算 (付费层级特征)，免去人工确认打扰喵！${NC}\n" >&2
       return 0
    fi
  fi

  echo -e "\n${YELLOW}${BOLD}⚠️ 喵酱的风控防御与付费激活提示：${NC}" >&2
  echo -e "根据 Google Cloud 官方安全限制，代码无法自动将「免费试用」升级为「付费层级」。" >&2
  echo -e "请务必点击下方链接，在网页顶部点击 ${GREEN}【激活 (Activate) / 升级 (Upgrade)】${NC} 按钮：" >&2
  echo -e "${CYAN}👉 https://console.cloud.google.com/billing ${NC}" >&2
  read -r -p "确认您已手动激活后，请按回车键继续执行脚本 (Press Enter to continue)..." _ < /dev/tty
}

# ===== 基础工具 =====
retry() {
  local max="$MAX_RETRY_ATTEMPTS"; local attempt=1; local delay
  while [ $attempt -le $max ]; do
    if "$@"; then return 0; fi
    if [ $attempt -ge $max ]; then return 1; fi
    delay=$(( attempt * 3 + RANDOM % 3 ))
    log "WARN" "重试 ${attempt}/${max} (等待 ${delay}s)..."
    sleep $delay
    attempt=$((attempt + 1))
  done
}

require_cmd() { if ! command -v "$1" &>/dev/null; then log "ERROR" "缺少依赖: $1"; exit 1; fi; }

new_project_name() { echo "My Project $((RANDOM % 90000 + 10000))"; }
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
  if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init'喵！"; exit 1; fi
}

unlink_projects_from_billing_account() {
  local billing_id="$1"
  local linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null)
  if [ -z "$linked_projects" ]; then return 0; fi
  log "WARN" "清理释放旧配额..."
  for project_id in $linked_projects; do
    [ -n "$project_id" ] && gcloud billing projects unlink "$project_id" --quiet >/dev/null 2>&1 || true
  done
  return 0
}

# ===== 精准提取纯净 AS 密钥 =====
_extract_single_project() {
  local pid="$1"
  retry gcloud services enable generativelanguage.googleapis.com --project="$pid" --quiet >/dev/null 2>&1 || true
  
  local target_name
  target_name=$(gcloud services api-keys list --project="$pid" --filter="displayName:'Gemini API Key' OR displayName:'Studio Key'" --format="value(name)" 2>/dev/null | head -n 1 | tr -d '\r' | xargs)
  
  if [ -z "$target_name" ]; then
      gcloud services api-keys create --project="$pid" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --quiet >/dev/null 2>&1 || true
      sleep 2
      target_name=$(gcloud services api-keys list --project="$pid" --filter="displayName:'Gemini API Key'" --format="value(name)" 2>/dev/null | head -n 1 | tr -d '\r' | xargs)
  fi
  
  if [ -n "$target_name" ]; then
      local api_key=$(gcloud services api-keys get-key-string "$target_name" --format="value(keyString)" 2>/dev/null | tr -d '\r' | xargs)
      if [ -n "$api_key" ]; then echo "$api_key"; return 0; fi
  fi
  
  local all_keys=$(gcloud services api-keys list --project="$pid" --format="value(name,displayName)" 2>/dev/null || echo "")
  if [ -n "$all_keys" ]; then
      while read -r kname dname; do
          kname=$(echo "$kname" | tr -d '\r' | xargs)
          [ -z "$kname" ] && continue
          if [[ "$dname" != *"Agent Platform"* ]] && [[ "$dname" != *"Fallback API"* ]]; then
              local api_key=$(gcloud services api-keys get-key-string "$kname" --format="value(keyString)" 2>/dev/null | tr -d '\r' | xargs)
              if [ -n "$api_key" ] && [[ "$api_key" == AIza* ]]; then echo "$api_key"; return 0; fi
          fi
      done <<< "$all_keys"
  fi
  return 1
}

# ===== 5.5 静默核心：前后置双重核验引擎 (减负放行版) =====
check_api_ready() {
    local pid="$1"
    local stage="$2"
    log "INFO" "[$pid] ${stage} 核心 API 核验 (静默等待同步...)"
    
    local attempt=1
    local max_attempts=18  # 18次 x 10秒 = 180秒极限等待
    
    while [ $attempt -le $max_attempts ]; do
        local enabled_list
        enabled_list=$(gcloud services list --project="$pid" --enabled --format="value(config.name)" 2>/dev/null || echo "")
        
        # 【核心减负】只检查提Key最最需要的两兄弟，剩下的UI服务让他们后台慢慢加载，绝不死等！
        if [[ "$enabled_list" == *"aiplatform.googleapis.com"* ]] && \
           [[ "$enabled_list" == *"generativelanguage.googleapis.com"* ]]; then
            log "SUCCESS" "[$pid] ${stage}核验通过：核心 API 已就绪！"
            return 0
        fi
        
        sleep 10
        attempt=$((attempt+1))
    done
    log "WARN" "[$pid] ${stage}核验超时，将强行执行提取喵。"
    return 1
}

# ===== 5.5 黑科技: 极速异步单开全家桶 API =====
v27_enable_all_services() {
    local proj="$1"
    local services=(
        # 核心 AI 与鉴权 API (最重要)
        "aiplatform.googleapis.com" "generativelanguage.googleapis.com" "discoveryengine.googleapis.com"
        "iam.googleapis.com" "iamcredentials.googleapis.com" "cloudresourcemanager.googleapis.com"
        "apikeys.googleapis.com" "serviceusage.googleapis.com" "dialogflow.googleapis.com"
        
        # 基础云服务
        "compute.googleapis.com" "storage-component.googleapis.com" "storage.googleapis.com" "logging.googleapis.com" 
        "monitoring.googleapis.com" "cloudtrace.googleapis.com" "telemetry.googleapis.com" "dataform.googleapis.com"
        
        # Agent Platform 最新微服务全家桶 (彻底补齐UI要求)
        "agentregistry.googleapis.com" "apphub.googleapis.com" "apptopology.googleapis.com" 
        "cloudapiregistry.googleapis.com" "apiregistry.googleapis.com" "iamconnectors.googleapis.com" "connectors.googleapis.com"
        "iap.googleapis.com" "modelarmor.googleapis.com" "networksecurity.googleapis.com" "networkservices.googleapis.com" 
        "notebooks.googleapis.com" "observability.googleapis.com" "texttospeech.googleapis.com" 
    )
    
    log "INFO" "[$proj] 正在发射异步 API 开通指令雨 (无阻滞并发模式)..."
    for svc in "${services[@]}"; do
        # 核心突破：--async 瞬间返回不阻塞，单条失效绝不波及全局！
        gcloud services enable "$svc" --project="$proj" --async --quiet >/dev/null 2>&1 || true
    done
}

v27_setup_and_extract_aq_key() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Agent SA" --project="$project_id" --quiet >/dev/null 2>&1 || true
        log "INFO" "[$project_id] 等待服务账号生效..."
        sleep 5
    fi
    local roles=("roles/editor" "roles/aiplatform.admin" "roles/iam.serviceAccountUser")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    sleep 3 
    local keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            [ -z "$key_name" ] && continue
            local api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then echo "$api_key"; return 0; fi
        done
    fi
    log "INFO" "[$project_id] 正在请求生成 AQ 格式专属密钥..."
    local attempt=1; local create_success=false
    while [ $attempt -le 6 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            create_success=true; break
        fi
        local err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* && "$attempt" -ge 4 ]]; then break; fi
        sleep 10; attempt=$((attempt+1))
    done
    if [ "$create_success" = false ]; then gcloud services api-keys create --project="$project_id" --display-name="Fallback API Key" --quiet >/dev/null 2>&1 || true; fi
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        local fallback_key=""
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            [ -z "$key_name" ] && continue
            local api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then echo "$api_key"; return 0; fi
            if [[ "$api_key" == AIza* ]]; then fallback_key="$api_key"; fi
        done
        if [ -n "$fallback_key" ]; then echo "$fallback_key"; return 0; fi
    fi
    return 1
}

# ===== 提取可用结算账号工具 =====
select_billing_accounts() {
  local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
  if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi

  local ids=(); local names=()
  while IFS=',' read -r bid bname; do
    bid="${bid##*/}"; ids+=("$bid"); names+=("$bname")
  done <<< "$billing_raw"

  if [ "${#ids[@]}" -eq 1 ]; then
    log "INFO" "系统检测到仅有 1 个可用结算账户，已为您自动锁定: ${names[0]} (${ids[0]})"
    SELECTED_BILLING_IDS=("${ids[0]}")
    SELECTED_BILLING_NAMES=("${names[0]}")
    return 0
  fi

  echo -e "\n${CYAN}${BOLD}可用的结算账户：${NC}" >&2
  for idx in "${!ids[@]}"; do echo -e "  ${GREEN}$((idx+1))${NC}. ${names[$idx]} (${ids[$idx]})" >&2; done
  echo -e "  ${GREEN}0${NC}. 全部选择" >&2

  local choice
  read -r -p "请选择结算账户 (输入编号，多个用逗号分隔，如 1,3) [默认: 0]: " choice < /dev/tty
  choice=${choice:-0}

  SELECTED_BILLING_IDS=()
  SELECTED_BILLING_NAMES=()
  if [ "$choice" = "0" ]; then
    SELECTED_BILLING_IDS=("${ids[@]}"); SELECTED_BILLING_NAMES=("${names[@]}")
  else
    IFS=',' read -ra selections <<< "$choice"
    for sel in "${selections[@]}"; do
      sel=$(echo "$sel" | tr -d ' ')
      if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#ids[@]}" ]; then
        local si=$((sel-1))
        SELECTED_BILLING_IDS+=("${ids[$si]}"); SELECTED_BILLING_NAMES+=("${names[$si]}")
      fi
    done
  fi
  if [ "${#SELECTED_BILLING_IDS[@]}" -eq 0 ]; then log "ERROR" "未选择任何结算账户喵！"; return 1; fi
}

_select_billing_for_opt6() {
  local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
  if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi

  local ids=(); local names=()
  while IFS=',' read -r bid bname; do
    bid="${bid##*/}"; ids+=("$bid"); names+=("$bname")
  done <<< "$billing_raw"

  if [ "${#ids[@]}" -eq 1 ]; then
    log "INFO" "系统检测到仅有 1 个可用结算账户，已为您自动锁定: ${names[0]} (${ids[0]})"
    echo "${ids[0]}"
    return 0
  fi

  echo -e "\n${CYAN}${BOLD}可用的结算账户：${NC}" >&2
  for idx in "${!ids[@]}"; do echo -e "  ${GREEN}$((idx+1))${NC}. ${names[$idx]} (${ids[$idx]})" >&2; done

  local choice
  read -r -p "请选择 1 个主要结算账户 (输入编号) [默认: 1]: " choice < /dev/tty
  choice=${choice:-1}
  
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ids[@]}" ]; then
    local si=$((choice-1)); echo "${ids[$si]}"; return 0
  else
    log "ERROR" "无效的选择"; return 1
  fi
}

# ===== 选项 1、2：经典与防风控逻辑 =====
gemini_create_projects() {
  prompt_upgrade_billing
  local keep_billing="${1:-false}"; local auto_mode="${2:-false}"
  if [ "$keep_billing" = "true" ]; then log "INFO" "====== 自动创建并提取 Gemini 项目 (保留旧结算绑定) ======"; else log "INFO" "====== 自动创建并提取 Gemini 项目 (释放配额) ======"; fi

  local num_per_billing
  if [ "$auto_mode" = "true" ]; then
    local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
    if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi
    SELECTED_BILLING_IDS=(); SELECTED_BILLING_NAMES=()
    while IFS=',' read -r bid bname; do bid="${bid##*/}"; SELECTED_BILLING_IDS+=("$bid"); SELECTED_BILLING_NAMES+=("$bname"); done <<< "$billing_raw"
    num_per_billing=3
  else
    select_billing_accounts || return 1
    local num_input
    read -r -p "每个结算账户创建几个项目？(支持数字如 3，或范围如 3-5) [默认: 3]: " num_input < /dev/tty
    num_input=${num_input:-3}
    if [[ "$num_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then local min="${BASH_REMATCH[1]}"; local max="${BASH_REMATCH[2]}"; if [ "$min" -le "$max" ]; then num_per_billing=$(( RANDOM % (max - min + 1) + min )); else num_per_billing=$min; fi
    elif [[ "$num_input" =~ ^[0-9]+$ ]]; then num_per_billing="$num_input"; else num_per_billing=3; fi
  fi

  local total_projects=$(( num_per_billing * ${#SELECTED_BILLING_IDS[@]} ))
  local total_success=0; local total_failed=0; local total_skipped=0; local ALL_KEYS=()
  
  for billing_idx in "${!SELECTED_BILLING_IDS[@]}"; do
    local GEMINI_BILLING_ACCOUNT="${SELECTED_BILLING_IDS[$billing_idx]}"
    local billing_name="${SELECTED_BILLING_NAMES[$billing_idx]}"
    
    echo -e "\n${CYAN}${BOLD}────── 结算账户 $((billing_idx+1))/${#SELECTED_BILLING_IDS[@]}: ${billing_name} (${GEMINI_BILLING_ACCOUNT}) ──────${NC}"
    if [ "$keep_billing" = "false" ]; then unlink_projects_from_billing_account "$GEMINI_BILLING_ACCOUNT"; fi
    
    local success=0; local failed=0; local skipped=0; local i=1
    while [ $i -le "$num_per_billing" ]; do
      local global_idx=$(( billing_idx * num_per_billing + i )); local project_id=$(new_project_id); local project_name=$(new_project_name)
      log "INFO" "[${global_idx}/${total_projects}] 正在处理项目: ${project_name} [${project_id}]"
      gcloud projects create "$project_id" --name="$project_name" --quiet >/dev/null 2>&1 || { failed=$((failed+1)); i=$((i+1)); continue; }
      gcloud billing projects link "$project_id" --billing-account="$GEMINI_BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
      
      local billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
      if [ -z "$billing_info" ]; then log "WARN" "未绑定结算，跳过！"; skipped=$((skipped+1)); i=$((i+1)); continue; fi
      
      local api_key=$(_extract_single_project "$project_id")
      if [ -n "$api_key" ]; then ALL_KEYS+=("$api_key"); log "SUCCESS" "提取成功！"; success=$((success+1))
      else log "WARN" "解析失败"; failed=$((failed+1)); fi
      i=$((i+1))
    done
    echo -e "${CYAN}  结算 ${billing_name} 小结: 成功 ${success} | 失败 ${failed} | 跳过 ${skipped}${NC}"
  done

  if [ "${#ALL_KEYS[@]}" -gt 0 ]; then 
      echo -e "\n${GREEN}${BOLD}====== 纯净 AS 密钥列表 (共 ${#ALL_KEYS[@]} 个) ======${NC}"
      for k in "${ALL_KEYS[@]}"; do echo -e "${GREEN}$k${NC}"; done
      echo
  fi
}

# ===== 选项 3 深度定制 =====
gemini_get_keys_from_existing() {
  prompt_upgrade_billing
  
  echo -e "\n${CYAN}${BOLD}====== 选项3: 从现有项目强力提取密钥 ======${NC}"
  echo "1. 单独提取 Vertex 项目密钥 (采用 v2.7 原生提取方法)"
  echo "2. 单独提取 AS (Gemini Studio) 项目纯净密钥"
  echo "3. 提取 Vertex + AS 项目双端密钥"
  local sub_choice
  read -r -p "请选择 [1-3, 默认: 3]: " sub_choice < /dev/tty
  sub_choice=${sub_choice:-3}

  log "INFO" "正在扫描并筛选【已绑定账单】的活跃项目..."
  local projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null || echo "")
  local valid_projects=()
  for pid in $projects; do
      local b_info=$(gcloud billing projects describe "$pid" --format='value(billingAccountName)' 2>/dev/null || echo "")
      if [ -n "$b_info" ]; then valid_projects+=("$pid"); fi
  done

  if [ ${#valid_projects[@]} -eq 0 ]; then
      log "ERROR" "没有找到任何绑定了账单的项目，无法提取密钥喵！"
      return 1
  fi

  local success_v=0; local success_a=0
  local VERTEX_KEYS=(); local AS_KEYS=()

  for project_id in "${valid_projects[@]}"; do
      log "INFO" "正在处理已绑账单项目: ${project_id}"
      
      if [ "$sub_choice" = "1" ] || [ "$sub_choice" = "3" ]; then
          v27_enable_all_services "$project_id" 
          check_api_ready "$project_id" "【提Key前】"
          local v_key=$(v27_setup_and_extract_aq_key "$project_id" || true)
          if [ -n "$v_key" ]; then
              log "SUCCESS" "Vertex 提取成功: $v_key"
              VERTEX_KEYS+=("$v_key")
              success_v=$((success_v+1))
              check_api_ready "$project_id" "【提Key后】"
          fi
      fi

      if [ "$sub_choice" = "2" ] || [ "$sub_choice" = "3" ]; then
          local a_key=$(_extract_single_project "$project_id")
          if [ -n "$a_key" ]; then
              log "SUCCESS" "AS 提取成功: $a_key"
              AS_KEYS+=("$a_key")
              success_a=$((success_a+1))
          fi
      fi
  done

  if [ ${#VERTEX_KEYS[@]} -gt 0 ]; then
      echo -e "\n${YELLOW}${BOLD}====== 纯净 Vertex 密钥列表 (共 ${success_v} 个) ======${NC}"
      for k in "${VERTEX_KEYS[@]}"; do echo -e "${GREEN}$k${NC}"; done
  fi
  if [ ${
