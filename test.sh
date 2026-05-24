#!/bin/bash
# 优化的 GCP API 密钥管理工具 - Vertex+AS完整源码
# 核心革命: 引入 --async 服务端异步引擎，根除本地 gcloud 进程死锁导致的开启失败
# 版本: 5.7.0

set -Euo pipefail

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="5.7.0"
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

# ===== 5.7 严格地毯式核验 (彻底治愈强迫症) =====
check_api_ready() {
    local pid="$1"
    local stage="$2"
    log "INFO" "[$pid] ${stage} 核心与UI全量 API 核验 (静默同步中...)"
    
    local attempt=1
    local max_attempts=18  # 最长等待 3 分钟
    
    # 严格死守控制台要求的所有 UI 权限
    local target_apis=("aiplatform" "generativelanguage" "agentregistry" "apphub" "apptopology" "cloudapiregistry" "iamconnectors" "iap" "modelarmor" "networksecurity" "networkservices" "notebooks" "observability" "texttospeech")
    
    while [ $attempt -le $max_attempts ]; do
        local enabled_list
        enabled_list=$(gcloud services list --project="$pid" --enabled --format="value(config.name)" 2>/dev/null || echo "")
        
        local all_ready=true
        for api in "${target_apis[@]}"; do
            if [[ "$enabled_list" != *"${api}.googleapis.com"* ]]; then
                all_ready=false
                break
            fi
        done
        
        if [ "$all_ready" = true ]; then
            log "SUCCESS" "[$pid] ${stage}核验通过：全量大满贯 API 已全部就绪！网页控制台全绿确认！"
            return 0
        fi
        
        sleep 10
        attempt=$((attempt+1))
    done
    log "WARN" "[$pid] ${stage}核验超时，可能因网络波动少许UI服务未显示，跳过并强行提取喵。"
    return 1
}

# ===== 5.7 核心黑科技: 官方单包 + 服务端 --async 异步下发 =====
v27_enable_all_services() {
    local proj="$1"
    # 完全对齐你抓取到的 15 个最新官方微服务 + 底层支撑服务
    local services=(
        "agentregistry.googleapis.com" "aiplatform.googleapis.com" "apphub.googleapis.com" 
        "apptopology.googleapis.com" "cloudapiregistry.googleapis.com" "compute.googleapis.com" 
        "iam.googleapis.com" "iamconnectors.googleapis.com" "iap.googleapis.com" 
        "modelarmor.googleapis.com" "networksecurity.googleapis.com" "networkservices.googleapis.com" 
        "notebooks.googleapis.com" "observability.googleapis.com" "texttospeech.googleapis.com"
        "generativelanguage.googleapis.com" "discoveryengine.googleapis.com" "iamcredentials.googleapis.com" 
        "cloudresourcemanager.googleapis.com" "apikeys.googleapis.com" "dialogflow.googleapis.com" 
        "dataform.googleapis.com" "serviceusage.googleapis.com" "cloudtrace.googleapis.com" 
        "logging.googleapis.com" "monitoring.googleapis.com" "telemetry.googleapis.com" "storage.googleapis.com"
    )
    
    log "INFO" "[$proj] 正在向 Google 服务器投递原生全量 API 大包指令..."
    
    # 彻底解决本地死锁：使用 --async 让 gcloud 瞬间返回，由 Google 强大的后端负责多项目并发开启
    local out
    if ! out=$(gcloud services enable "${services[@]}" --project="$proj" --async --quiet 2>&1); then
        log "ERROR" "[$proj] API 指令投递被 Google 拒绝: $out"
    else
        log "SUCCESS" "[$proj] 指令投递成功！云端已开启异步原子处理！"
    fi
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
  if [ ${#AS_KEYS[@]} -gt 0 ]; then
      echo -e "\n${GREEN}${BOLD}====== 纯净 AS 密钥列表 (共 ${success_a} 个) ======${NC}"
      for k in "${AS_KEYS[@]}"; do echo -e "${GREEN}$k${NC}"; done
      echo
  fi
}

gemini_delete_projects() {
  log "INFO" "====== 删除现有项目 ======"
  read -r -p "输入项目前缀进行批量删除 (留空取消): " prefix < /dev/tty
  if [ -z "$prefix" ]; then return 0; fi
  local projects=$(gcloud projects list --format="value(projectId)" --filter="projectId:$prefix*" 2>/dev/null)
  for p in $projects; do log "INFO" "正在删除 $p ..."; gcloud projects delete "$p" --quiet; done
}

# ===== 选项 5: 护盾模式 =====
rebuild_and_transfer_billing() {
  prompt_upgrade_billing
  log "INFO" "====== 选项5: 终极护盾转移重建模式 ======"
  
  local default_project=$(gcloud projects list --filter="name='My First Project'" --format="value(projectId)" 2>/dev/null | head -n 1 || echo "")
  if [ -z "$default_project" ]; then default_project=$(gcloud config get-value project 2>/dev/null || echo ""); fi
  
  local ORIGINAL_PROJECT=""
  while [ -z "$ORIGINAL_PROJECT" ]; do
    echo -e "${YELLOW}⚠️ 喵酱警告：接下来的操作会删除其他所有项目！${NC}" >&2
    if [ -n "$default_project" ]; then
      read -r -p "请输入绝对不能删除的【原始项目 ID】[直接回车默认保护: ${default_project}]: " ORIGINAL_PROJECT < /dev/tty
      ORIGINAL_PROJECT=${ORIGINAL_PROJECT:-$default_project}
    else 
      read -r -p "请输入绝对不能删除的【原始项目 ID】(必填): " ORIGINAL_PROJECT < /dev/tty
    fi
  done

  local CURRENT_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
  log "INFO" "当前登录账号: $CURRENT_ACCOUNT"
  local TARGET_EMAIL
  read -r -p "请输入接收结算权限的目标邮箱 [直接回车默认: $CURRENT_ACCOUNT]: " TARGET_EMAIL < /dev/tty
  TARGET_EMAIL=${TARGET_EMAIL:-$CURRENT_ACCOUNT}
  
  local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1)
  if [ -z "$billing_raw" ]; then log "ERROR" "未找到活动的结算账户，无法继续喵！"; return 1; fi
  local TARGET_BILLING_ID="${billing_raw#billingAccounts/}"
  
  log "INFO" "处理结算账户: $TARGET_BILLING_ID"
  local policy_json=$(gcloud beta billing accounts get-iam-policy "$TARGET_BILLING_ID" --format=json 2>/dev/null || echo "")
  if [ -n "$policy_json" ]; then
    local roles=$(python3 -c '
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
except Exception as e:
    pass
' "$policy_json" "$CURRENT_ACCOUNT")
    
    if [ -n "$roles" ]; then
      log "INFO" "为目标邮箱 $TARGET_EMAIL 赋予权限..."
      for role in $roles; do
        gcloud beta billing accounts add-iam-policy-binding "$TARGET_BILLING_ID" --member="user:$TARGET_EMAIL" --role="$role" --quiet >/dev/null 2>&1 || true
      done
    fi
  fi
  
  log "INFO" "====== 开始清理非保护项目 ======"
  local all_projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null || echo "")
  if [ -n "$all_projects" ]; then
    for p in $all_projects; do
      if [ "$p" = "$ORIGINAL_PROJECT" ]; then log "SUCCESS" "检测到原始项目 [$p]，已死死抱住，绝对不删！"; continue; fi
      log "INFO" "正在删除项目 $p ..."
      gcloud projects delete "$p" --quiet >/dev/null 2>&1 || true
      sleep 3
    done
  fi
  
  local AS_KEYS=()
  
  log "INFO" "====== 开始处理原始项目并提取密钥 ======"
  gcloud billing projects link "$ORIGINAL_PROJECT" --billing-account="$TARGET_BILLING_ID" --quiet >/dev/null 2>&1 || true
  local orig_key=$(_extract_single_project "$ORIGINAL_PROJECT")
  if [ -n "$orig_key" ]; then AS_KEYS+=("$orig_key"); log "SUCCESS" "原始项目提取成功喵！"; fi

  log "INFO" "====== 开始创建 2 个新项目并提取密钥 ======"
  for i in 1 2; do
    local pid=$(new_project_id); local pname=$(new_project_name)
    log "INFO" "正在创建新项目: $pname [$pid]"
    if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
      sleep 3; gcloud billing projects link "$pid" --billing-account="$TARGET_BILLING_ID" --quiet >/dev/null 2>&1 || true
      local new_key=$(_extract_single_project "$pid")
      if [ -n "$new_key" ]; then AS_KEYS+=("$new_key"); log "SUCCESS" "新项目提取成功喵！"; fi
    fi
    sleep 3
  done

  if [ "${#AS_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${GREEN}${BOLD}====== 纯净 AS 密钥列表 ======${NC}"
    for k in "${AS_KEYS[@]}"; do echo -e "${GREEN}$k${NC}"; done
  fi
  echo -e "\n${GREEN}任务圆满完成！${NC}"
}

# ===== 选项 6 全新多账单自动循环逻辑 =====
option6_handler() {
  prompt_upgrade_billing
  
  echo -e "\n${CYAN}${BOLD}====== 选项6: 提取 vertex+AS key密钥 (工业级大包并发 + 全量核验) ======${NC}"
  echo "1. 单账单自定义数量创建 (防风控创建，提 Vertex + AS)"
  echo "2. 多账单全自动榨干模式 (账单1:默认+2新项目; 账单2~N: 3新项目。保证每账单 2V+3AS)"
  local sub_choice
  read -r -p "请选择 [1-2, 默认: 2]: " sub_choice < /dev/tty
  sub_choice=${sub_choice:-2}

  local VERTEX_KEYS=()
  local AS_KEYS_FORMATTED=()

  if [ "$sub_choice" = "1" ]; then
      local BILLING_ACCOUNT=""
      BILLING_ACCOUNT=$(_select_billing_for_opt6) || return 1
      log "INFO" "已锁定结算账户: $BILLING_ACCOUNT"

      local num_projects
      read -r -p "请输入要创建的项目数量: " num_projects < /dev/tty
      num_projects=${num_projects:-2}

      unlink_projects_from_billing_account "$BILLING_ACCOUNT"
      log "INFO" "已清理旧项目账单，战术潜伏 5 秒以消除 AUP 数据库缓存喵..."
      sleep 5

      local created_pids=()
      for ((i=1; i<=num_projects; i++)); do
          local pid=$(new_project_id); local pname=$(new_project_name)
          log "INFO" "[$i/$num_projects] 正在使用防风控创建: ${pname} [${pid}]"
          if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
              gcloud billing projects link "$pid" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
              created_pids+=("$pid")
          fi
      done
      
      log "INFO" "批量创建完毕，防风控潜伏 5 秒..."
      sleep 5

      log "INFO" ">> 开始为 ${#created_pids[@]} 个项目串行下发异步 API 大包指令..."
      for pid in "${created_pids[@]}"; do
          v27_enable_all_services "$pid"
      done
      log "INFO" "指令派发完毕，静默等待 10 秒供后端消化..."
      sleep 10

      for pid in "${created_pids[@]}"; do
          check_api_ready "$pid" "【提Key前】"
          
          local v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
          if [ -n "$v_key" ]; then 
              VERTEX_KEYS+=("$v_key")
              log "SUCCESS" "Vertex 提取成功！"
              check_api_ready "$pid" "【提Key后】"
          fi
          
          local a_key=$(_extract_single_project "$pid")
          if [ -n "$a_key" ]; then 
              AS_KEYS_FORMATTED+=("$a_key")
              log "SUCCESS" "AS 提取成功！"
          fi
      done
      
      if [ ${#AS_KEYS_FORMATTED[@]} -gt 0 ]; then
          local temp=("新创建项目的key")
          for k in "${AS_KEYS_FORMATTED[@]}"; do temp+=("$k"); done
          AS_KEYS_FORMATTED=("${temp[@]}")
      fi

  elif [ "$sub_choice" = "2" ]; then
      log "INFO" "====== 执行选项 6.2: 全自动并发极限榨干 ======"
      
      local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
      if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi

      local b_ids=(); local b_names=()
      while IFS=',' read -r bid bname; do
          b_ids+=("${bid##*/}"); b_names+=("$bname")
      done <<< "$billing_raw"
      
      for b_idx in "${!b_ids[@]}"; do
          local CURRENT_BILLING="${b_ids[$b_idx]}"
          local CURRENT_BNAME="${b_names[$b_idx]}"
          
          log "INFO" "=========================================================="
          log "INFO" "开始处理结算账户 $((b_idx+1))/${#b_ids[@]}: $CURRENT_BNAME"
          
          VERTEX_KEYS+=("【账单: ${CURRENT_BNAME}】")
          AS_KEYS_FORMATTED+=("【账单: ${CURRENT_BNAME}】")

          if [ "$b_idx" -eq 0 ]; then
              local default_pid=$(gcloud projects list --filter="name='My First Project'" --format="value(projectId)" 2>/dev/null | head -n 1 || echo "")
              if [ -z "$default_pid" ]; then default_pid=$(gcloud config get-value project 2>/dev/null || echo ""); fi
              
              if [ -n "$default_pid" ]; then
                  log "INFO" ">> [账单1] 处理默认项目: $default_pid"
                  gcloud billing projects link "$default_pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
                  local check_b=$(gcloud billing projects describe "$default_pid" --format='value(billingAccountName)' 2>/dev/null || echo "")
                  if [ -n "$check_b" ]; then
                      local default_a_key=$(_extract_single_project "$default_pid")
                      if [ -n "$default_a_key" ]; then
                          AS_KEYS_FORMATTED+=("默认项目的key" "$default_a_key")
                      fi
                  fi
              fi

              local created_pids=()
              log "INFO" ">> [账单1] 批量创建 2 个新项目..."
              for i in 1 2; do
                  local pid=$(new_project_id); local pname=$(new_project_name)
                  if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
                      gcloud billing projects link "$pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
                      created_pids+=("$pid")
                  fi
              done
              log "INFO" "创建完毕，防风控潜伏 5 秒..."
              sleep 5

              log "INFO" ">> 向 Google 后台批量投递 API 大包指令..."
              for pid in "${created_pids[@]}"; do v27_enable_all_services "$pid"; done
              log "INFO" "指令派发完毕，静默等待 10 秒缓冲..."
              sleep 10

              for pid in "${created_pids[@]}"; do
                  check_api_ready "$pid" "【提Key前】"
                  local v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
                  if [ -n "$v_key" ]; then VERTEX_KEYS+=("$v_key"); check_api_ready "$pid" "【提Key后】"; fi
              done

              if [ ${#created_pids[@]} -gt 0 ]; then
                  AS_KEYS_FORMATTED+=("新创建项目的key")
                  for pid in "${created_pids[@]}"; do
                      local a_key=$(_extract_single_project "$pid")
                      if [ -n "$a_key" ]; then AS_KEYS_FORMATTED+=("$a_key"); fi
                  done
              fi

          else
              local created_pids=()
              log "INFO" ">> [账单$((b_idx+1))] 批量自动创建 3 个新项目..."
              for i in 1 2 3; do
                  local pid=$(new_project_id); local pname=$(new_project_name)
                  if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
                      gcloud billing projects link "$pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
                      created_pids+=("$pid")
                  fi
              done
              log "INFO" "创建完毕，防风控潜伏 5 秒..."
              sleep 5

              log "INFO" ">> 向 Google 后台批量投递 API 大包指令..."
              for pid in "${created_pids[@]}"; do v27_enable_all_services "$pid"; done
              log "INFO" "指令派发完毕，静默等待 10 秒缓冲..."
              sleep 10

              local v_count=0
              for pid in "${created_pids[@]}"; do
                  if [ "$v_count" -ge 2 ]; then continue; fi
                  check_api_ready "$pid" "【提Key前】"
                  local v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
                  if [ -n "$v_key" ]; then VERTEX_KEYS+=("$v_key"); check_api_ready "$pid" "【提Key后】"; v_count=$((v_count+1)); fi
              done

              if [ ${#created_pids[@]} -gt 0 ]; then
                  AS_KEYS_FORMATTED+=("新创建项目的key")
                  for pid in "${created_pids[@]}"; do
                      local a_key=$(_extract_single_project "$pid")
                      if [ -n "$a_key" ]; then AS_KEYS_FORMATTED+=("$a_key"); fi
                  done
              fi
          fi
      done
  fi

  local pure_v=0
  for item in "${VERTEX_KEYS[@]}"; do if [[ ! "$item" =~ "【账单" ]]; then pure_v=$((pure_v+1)); fi; done
  
  if [ "$pure_v" -gt 0 ]; then
      echo -e "\n${YELLOW}${BOLD}====== 纯净 Vertex 密钥列表 (共 ${pure_v} 个) ======${NC}"
      for k in "${VERTEX_KEYS[@]}"; do 
          if [[ "$k" =~ "【账单" ]]; then echo -e "\n${CYAN}${k}${NC}"; else echo -e "${GREEN}${k}${NC}"; fi
      done
  fi
  
  local pure_a=0
  for item in "${AS_KEYS_FORMATTED[@]}"; do if [[ ! "$item" =~ "项目的key" ]] && [[ ! "$item" =~ "【账单" ]]; then pure_a=$((pure_a+1)); fi; done

  if [ "$pure_a" -gt 0 ]; then
      echo -e "\n${GREEN}${BOLD}====== 纯净 AS 密钥列表 (共 ${pure_a} 个) ======${NC}"
      for k in "${AS_KEYS_FORMATTED[@]}"; do 
          if [[ "$k" =~ "【账单" ]] || [[ "$k" =~ "项目的key" ]]; then echo -e "${CYAN}${k}${NC}"
          else echo -e "${GREEN}${k}${NC}"; fi
      done
      echo
  fi
}

# ===== 选项 7 毁灭重生模式 =====
option7_handler() {
  prompt_upgrade_billing
  
  echo -e "\n${CYAN}${BOLD}====== 选项7: 毁灭重生模式 (删光账单项目 + 每账单建1提1 AS) ======${NC}"
  echo -e "${YELLOW}⚠️ 喵酱警告：此操作将查找所有可用结算账户，解绑并彻底删除所有关联的项目！${NC}"
  read -r -p "确认执行此毁灭性操作吗？[y/N]: " confirm_del < /dev/tty
  if [[ ! "$confirm_del" =~ ^[Yy]$ ]]; then
      log "INFO" "操作已取消喵"
      return 0
  fi

  local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
  if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi

  local b_ids=(); local b_names=()
  while IFS=',' read -r bid bname; do
      b_ids+=("${bid##*/}"); b_names+=("$bname")
  done <<< "$billing_raw"
  
  log "INFO" "总共检测到 ${#b_ids[@]} 个活跃结算账户。开始执行清理..."

  for b_idx in "${!b_ids[@]}"; do
      local CURRENT_BILLING="${b_ids[$b_idx]}"
      local CURRENT_BNAME="${b_names[$b_idx]}"
      log "INFO" ">> 正在查找结算账户 [$CURRENT_BNAME] 下的所有项目..."
      
      local linked_projects=$(gcloud billing projects list --billing-account="$CURRENT_BILLING" --format='value(projectId)' 2>/dev/null || echo "")
      for p in $linked_projects; do
          [ -z "$p" ] && continue
          log "INFO" "正在删除项目和结算: $p ..."
          gcloud billing projects unlink "$p" --quiet >/dev/null 2>&1 || true
          gcloud projects delete "$p" --quiet || true
          sleep 2
      done
  done

  log "INFO" "====== 清理完毕！开始为每个结算账户创建 1 个新项目 ======"
  local AS_KEYS_FORMATTED=()

  for b_idx in "${!b_ids[@]}"; do
      local CURRENT_BILLING="${b_ids[$b_idx]}"
      local CURRENT_BNAME="${b_names[$b_idx]}"
      
      log "INFO" "----------------------------------------------------------"
      log "INFO" "[账单 $((b_idx+1))/${#b_ids[@]}] $CURRENT_BNAME - 正在建站提取..."
      AS_KEYS_FORMATTED+=("【账单: ${CURRENT_BNAME}】")
      
      local pid=$(new_project_id); local pname=$(new_project_name)
      log "INFO" "创建新项目: ${pname} [${pid}]"
      
      if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
          gcloud billing projects link "$pid" --billing-account="$CURRENT_BILLING" --quiet >/dev/null 2>&1 || true
          log "INFO" "账单绑定成功，防风控潜伏 15 秒..."
          sleep 15
          
          local a_key=$(_extract_single_project "$pid")
          if [ -n "$a_key" ]; then 
              log "SUCCESS" "AS 密钥提取成功！"
              AS_KEYS_FORMATTED+=("$a_key")
          else
              log "WARN" "AS 密钥提取失败喵..."
          fi
      else
          log "ERROR" "项目创建失败！"
      fi
  done

  local pure_a=0
  for item in "${AS_KEYS_FORMATTED[@]}"; do if [[ ! "$item" =~ "【账单" ]]; then pure_a=$((pure_a+1)); fi; done

  if [ "$pure_a" -gt 0 ]; then
      echo -e "\n${GREEN}${BOLD}====== 纯净 AS 密钥列表 (共 ${pure_a} 个) ======${NC}"
      for k in "${AS_KEYS_FORMATTED[@]}"; do 
          if [[ "$k" =~ "【账单" ]]; then echo -e "\n${CYAN}${k}${NC}"
          else echo -e "${GREEN}${k}${NC}"; fi
      done
      echo
  fi
}

# ===== 主菜单 =====
show_menu() {
  echo -e "\n${CYAN}${BOLD}====== 喵酱的 GCP 管理器 v${VERSION} ======${NC}"
  echo "1. [经典] 自动创建项目并提取密钥 (清理旧项目释放配额)"
  echo "2. [防风控] 自动创建项目并提取密钥 (保留旧项目结算绑定)"
  echo "3. 提取现有项目的纯净密钥 (彻底免疫 Vertex 钢印污染)"
  echo "4. 批量删除项目"
  echo "5. [护盾] 保护原项目 -> 转移结算 -> 建2个凑齐3密钥"
  echo "6. [定制] 提取 vertex + AS 密钥 (智能并发 + 官方单包开启)"
  echo "7. [重置] 删光所有带账单项目 -> 每账单建1提1 (纯提AS)"
  echo "0. 退出并摸摸喵酱"
  local choice
  read -r -p "请主人吩咐: " choice < /dev/tty
  case "$choice" in
    1) check_env && gemini_create_projects "false" "false" ;;
    2) 
      check_env || return
      echo -e "\n${CYAN}主人想怎么操作呢？${NC}"
      echo "1. 自定义选择结算账户和数量"
      echo "2. 全自动 (为所有可用账户各创建3个项目)"
      local sub_choice
      read -r -p "请选择 [1-2, 默认: 1]: " sub_choice < /dev/tty
      sub_choice=${sub_choice:-1}
      if [ "$sub_choice" = "2" ]; then gemini_create_projects "true" "true"
      else gemini_create_projects "true" "false"; fi
      ;;
    3) check_env && gemini_get_keys_from_existing ;;
    4) check_env && gemini_delete_projects ;;
    5) check_env && rebuild_and_transfer_billing ;;
    6) check_env && option6_handler ;;
    7) check_env && option7_handler ;;
    0) exit 0 ;;
    *) log "ERROR" "指令无效喵！" ;; 
  esac
}

main() { while true; do show_menu; done; }

main
