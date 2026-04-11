#!/bin/bash
# 优化的 GCP API 密钥管理工具 - 融合进化版
# 支持 Gemini API (全自动模式 + 纯控制台打印 + 终极防漏抓取 + 默认项目提取)
# 版本: 3.8.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="3.8.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-miaojiang-api}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
TEMP_DIR=""

# 初始化
TEMP_DIR=$(mktemp -d -t gcp_script_XXXXXX) || { echo "错误：无法创建临时目录"; exit 1; }
SECONDS=0

# ===== 日志与错误处理 =====
log() { 
  local level="${1:-INFO}"
  local msg="${2:-}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  case "$level" in
    "INFO") echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
    "SUCCESS") echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
    "WARN") echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
    "ERROR") echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
  esac
}

handle_error() {
  local exit_code=$?
  case $exit_code in 141|130) return 0 ;; esac
  if [ $exit_code -gt 1 ]; then log "ERROR" "发生严重错误，请检查日志"; return $exit_code; else return 0; fi
}
trap 'handle_error' ERR

cleanup_resources() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR" 2>/dev/null || true; fi
  echo -e "\n${CYAN}喵酱期待下次为主人服务喵～${NC}"
}
trap cleanup_resources EXIT

# ===== 工具函数 =====
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

unique_suffix() { 
  if command -v uuidgen &>/dev/null; then uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
  else echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6; fi
}

new_project_id() { echo "${1:-$PROJECT_PREFIX}-$(unique_suffix)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30; }

check_env() {
  require_cmd gcloud
  if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init'喵！"; exit 1; fi
}

parse_json() {
  local json="$1"; local field="$2"
  if [ -z "$json" ]; then return 1; fi
  if command -v jq &>/dev/null; then
    local res
    res=$(echo "$json" | jq -r "$field" 2>/dev/null)
    if [ -n "$res" ] && [ "$res" != "null" ]; then echo "$res"; return 0; fi
  fi
  if [ "$field" = ".keyString" ]; then
    echo "$json" | grep -o '"keyString" *: *"[^"]*"' | sed 's/"keyString" *: *"//;s/"$//' | head -n 1
  fi
}

# ===== 核心提取逻辑 (内置强力防阻断) =====
extract_key_safely() {
  local project_id="$1"
  local keys_list=""
  
  local attempt=1
  while [ $attempt -le $MAX_RETRY_ATTEMPTS ]; do
    if keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null); then
      break
    fi
    sleep 2
    attempt=$((attempt+1))
  done
  
  if [ -n "$keys_list" ]; then
    # 强力遍历所有 key，只要找到一个就返回
    for key_name in $keys_list; do
      key_name=$(echo "$key_name" | tr -d '\r' | xargs)
      [ -z "$key_name" ] && continue
      
      local api_key=""
      local k_attempt=1
      while [ $k_attempt -le $MAX_RETRY_ATTEMPTS ]; do
        if api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null); then
          break
        fi
        sleep 2
        k_attempt=$((k_attempt+1))
      done
      
      api_key=$(echo "$api_key" | tr -d '\r' | xargs)
      if [ -n "$api_key" ]; then
        echo "$api_key"
        return 0
      fi
    done
  fi
  return 1
}

unlink_projects_from_billing_account() {
  local billing_id="$1"
  local linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null)
  if [ -z "$linked_projects" ]; then return 0; fi
  log "WARN" "发现旧项目占用结算账户，喵酱开始清理释放配额..."
  for project_id in $linked_projects; do
    [ -n "$project_id" ] && retry gcloud billing projects unlink "$project_id" --quiet &>/dev/null
  done
  return 0
}

# ===== 结算账户选择 =====
select_billing_accounts() {
  local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
  if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi

  local ids=(); local names=()
  while IFS=',' read -r bid bname; do
    bid="${bid##*/}"
    ids+=("$bid"); names+=("$bname")
  done <<< "$billing_raw"

  echo -e "\n${CYAN}${BOLD}可用的结算账户：${NC}"
  for idx in "${!ids[@]}"; do
    echo -e "  ${GREEN}$((idx+1))${NC}. ${names[$idx]} (${ids[$idx]})"
  done
  echo -e "  ${GREEN}0${NC}. 全部选择"

  local choice
  read -r -p "请选择结算账户 (输入编号，多个用逗号分隔，如 1,3) [默认: 0]: " choice
  choice=${choice:-0}

  SELECTED_BILLING_IDS=()
  SELECTED_BILLING_NAMES=()
  if [ "$choice" = "0" ]; then
    SELECTED_BILLING_IDS=("${ids[@]}")
    SELECTED_BILLING_NAMES=("${names[@]}")
  else
    IFS=',' read -ra selections <<< "$choice"
    for sel in "${selections[@]}"; do
      sel=$(echo "$sel" | tr -d ' ')
      if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#ids[@]}" ]; then
        local si=$((sel-1))
        SELECTED_BILLING_IDS+=("${ids[$si]}")
        SELECTED_BILLING_NAMES+=("${names[$si]}")
      else
        log "WARN" "无效编号: ${sel}，已跳过"
      fi
    done
  fi

  if [ "${#SELECTED_BILLING_IDS[@]}" -eq 0 ]; then
    log "ERROR" "未选择任何结算账户喵！"; return 1
  fi
}

# ===== Gemini 核心逻辑 =====
gemini_create_projects() {
  local keep_billing="${1:-false}"
  local auto_mode="${2:-false}"
  
  if [ "$keep_billing" = "true" ]; then
    log "INFO" "====== 自动创建并提取 Gemini 项目 (保留旧结算绑定) ======"
  else
    log "INFO" "====== 自动创建并提取 Gemini 项目 (释放旧配额) ======"
  fi

  local num_per_billing

  if [ "$auto_mode" = "true" ]; then
    log "INFO" "🐱 喵酱已开启【全自动模式】：将为所有可用结算账户各创建 3 个项目喵！"
    local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
    if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi

    SELECTED_BILLING_IDS=()
    SELECTED_BILLING_NAMES=()
    while IFS=',' read -r bid bname; do
      bid="${bid##*/}"
      SELECTED_BILLING_IDS+=("$bid"); SELECTED_BILLING_NAMES+=("$bname")
    done <<< "$billing_raw"
    num_per_billing=3
  else
    select_billing_accounts || return 1
    local num_input
    read -r -p "每个结算账户创建几个项目？(支持数字如 3，或范围如 3-5) [默认: 3]: " num_input
    num_input=${num_input:-3}
    
    if [[ "$num_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
      local min="${BASH_REMATCH[1]}"; local max="${BASH_REMATCH[2]}"
      if [ "$min" -le "$max" ]; then num_per_billing=$(( RANDOM % (max - min + 1) + min ))
      else num_per_billing=$min; fi
    elif [[ "$num_input" =~ ^[0-9]+$ ]]; then num_per_billing="$num_input"
    else num_per_billing=3; fi
  fi

  local total_projects=$(( num_per_billing * ${#SELECTED_BILLING_IDS[@]} ))
  local total_success=0; local total_failed=0; local total_skipped=0
  local ALL_KEYS=()
  local BILLING_KEY_MAP=()

  for billing_idx in "${!SELECTED_BILLING_IDS[@]}"; do
    local GEMINI_BILLING_ACCOUNT="${SELECTED_BILLING_IDS[$billing_idx]}"
    local billing_name="${SELECTED_BILLING_NAMES[$billing_idx]}"

    echo -e "\n${CYAN}${BOLD}────── 结算账户 $((billing_idx+1))/${#SELECTED_BILLING_IDS[@]}: ${billing_name} (${GEMINI_BILLING_ACCOUNT}) ──────${NC}"

    if [ "$keep_billing" = "false" ]; then
      unlink_projects_from_billing_account "$GEMINI_BILLING_ACCOUNT"
    fi

    local success=0; local failed=0; local skipped=0; local i=1
    while [ $i -le "$num_per_billing" ]; do
      local global_idx=$(( billing_idx * num_per_billing + i ))
      local project_id=$(new_project_id)
      log "INFO" "[${global_idx}/${total_projects}] 正在处理项目: ${project_id} (结算: ${billing_name})"
      
      retry gcloud projects create "$project_id" --quiet || { failed=$((failed+1)); i=$((i+1)); continue; }
      retry gcloud billing projects link "$project_id" --billing-account="$GEMINI_BILLING_ACCOUNT" --quiet || true
      
      local billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
      if [ -z "$billing_info" ]; then
        log "WARN" "项目 ${project_id} 未绑定结算账户，跳过密钥提取喵！"
        skipped=$((skipped+1)); i=$((i+1)); continue
      fi
      
      retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet || { failed=$((failed+1)); i=$((i+1)); continue; }
      retry gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --quiet >/dev/null 2>&1 || true
      
      local api_key
      if api_key=$(extract_key_safely "$project_id"); then
        ALL_KEYS+=("$api_key")
        BILLING_KEY_MAP+=("${billing_idx}:${api_key}")
        log "SUCCESS" "成功提取密钥！"
        success=$((success+1))
      else
        log "WARN" "项目 ${project_id} 密钥解析失败"
        failed=$((failed+1))
      fi
      i=$((i+1))
    done

    echo -e "${CYAN}  结算 ${billing_name} 小结: 成功 ${success} | 失败 ${failed} | 跳过 ${skipped}${NC}"
    total_success=$((total_success + success))
    total_failed=$((total_failed + failed))
    total_skipped=$((total_skipped + skipped))
  done
  
  echo -e "\n${CYAN}${BOLD}====== 全部任务汇报 ======${NC}"
  echo "结算账户: ${#SELECTED_BILLING_IDS[@]} 个 | 计划创建: ${total_projects} | 成功: ${total_success} | 失败: ${total_failed} | 跳过: ${total_skipped}"
  
  if [ "${#ALL_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}喵酱为你奉上所有密钥喵（按结算账户分组）：${NC}"
    echo -e "${YELLOW}─────────────────────────────────────────${NC}"
    for bi in "${!SELECTED_BILLING_IDS[@]}"; do
      local b_name="${SELECTED_BILLING_NAMES[$bi]}"
      local b_id="${SELECTED_BILLING_IDS[$bi]}"
      local count=0
      local keys_for_this_billing=()

      for entry in "${BILLING_KEY_MAP[@]}"; do
        local e_bi="${entry%%:*}"
        local e_key="${entry#*:}"
        if [ "$e_bi" = "$bi" ]; then 
          count=$((count+1))
          keys_for_this_billing+=("$e_key")
        fi
      done

      if [ "$count" -gt 0 ]; then
        echo -e "\n${CYAN}${BOLD}${b_name} - ${b_id}  (${count} 个密钥)${NC}"
        for k in "${keys_for_this_billing[@]}"; do echo "$k"; done
      fi
    done
    echo -e "\n${YELLOW}─────────────────────────────────────────${NC}"
    echo -e "共 ${GREEN}${#ALL_KEYS[@]}${NC} 个密钥"
    echo
  fi
}

gemini_get_keys_from_existing() {
  log "INFO" "====== 从现有项目提取密钥 ======"
  local projects
  # 重点更新：移除状态过滤，强行获取所有项目，防止因数据库同步延迟导致遗漏！
  projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null || echo "")
  if [ -z "$projects" ]; then log "ERROR" "没找到活跃项目喵！"; return 1; fi
  
  local success=0; local skipped=0; local failed=0
  local ALL_KEYS=()
  local BILLING_IDS=()
  local BILLING_NAMES=()
  local BILLING_KEY_MAP=()

  # 强力遍历，无视回车符陷阱
  for project_id in $projects; do
    [ -z "$project_id" ] && continue
    
    local billing_raw
    billing_raw=$(gcloud billing projects describe "$project_id" --format='csv[no-heading](billingAccountName)' 2>/dev/null || echo "")
    local billing_account_path="${billing_raw%%,*}"
    local billing_id="${billing_account_path##*/}"
    local billing_display_name

    if [ -z "$billing_id" ] || [ "$billing_id" = "" ]; then
      billing_id="Unlinked"
      billing_display_name="未绑定结算账户 (被强行解绑)"
    else
      billing_display_name=$(gcloud billing accounts describe "$billing_id" --format='value(displayName)' 2>/dev/null || echo "$billing_id")
      [ -z "$billing_display_name" ] && billing_display_name="$billing_id"
    fi

    local bi=-1
    for idx in "${!BILLING_IDS[@]}"; do
      if [ "${BILLING_IDS[$idx]}" = "$billing_id" ]; then
        bi="$idx"; break
      fi
    done
    if [ "$bi" -eq -1 ]; then
      BILLING_IDS+=("$billing_id")
      BILLING_NAMES+=("$billing_display_name")
      bi="$(( ${#BILLING_IDS[@]} - 1 ))"
    fi
    
    log "INFO" "正在提取项目: ${project_id} (结算: ${billing_display_name})"
    
    local api_key
    # 强行提取！
    if api_key=$(extract_key_safely "$project_id"); then
      ALL_KEYS+=("$api_key")
      BILLING_KEY_MAP+=("${bi}:${api_key}")
      success=$((success+1))
      log "SUCCESS" "找到已有密钥！"
    else
      if [ "$billing_id" = "Unlinked" ]; then
        log "WARN" "项目无结算账户且没找到存活密钥，含泪跳过喵！"
        skipped=$((skipped+1))
        continue
      fi

      retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1 || true
      gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --quiet >/dev/null 2>&1 || true
      
      if api_key=$(extract_key_safely "$project_id"); then
        ALL_KEYS+=("$api_key")
        BILLING_KEY_MAP+=("${bi}:${api_key}")
        success=$((success+1))
        log "SUCCESS" "创建了新密钥！"
      else
        failed=$((failed+1))
      fi
    fi
  done
  
  echo -e "\n${CYAN}====== 提取完成 ======${NC}"
  echo "成功提取: $success | 无账单跳过: $skipped | 失败: $failed"
  
  if [ "${#ALL_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}喵酱为你奉上所有密钥喵（按结算账户分组）：${NC}"
    echo -e "${YELLOW}─────────────────────────────────────────${NC}"
    for bi in "${!BILLING_IDS[@]}"; do
      local b_name="${BILLING_NAMES[$bi]}"
      local b_id="${BILLING_IDS[$bi]}"
      local count=0
      local keys_for_this_billing=()

      for entry in "${BILLING_KEY_MAP[@]}"; do
        local e_bi="${entry%%:*}"
        local e_key="${entry#*:}"
        if [ "$e_bi" = "$bi" ]; then 
          count=$((count+1))
          keys_for_this_billing+=("$e_key")
        fi
      done

      if [ "$count" -gt 0 ]; then
        echo -e "\n${CYAN}${BOLD}${b_name} - ${b_id}  (${count} 个密钥)${NC}"
        for k in "${keys_for_this_billing[@]}"; do echo "$k"; done
      fi
    done
    echo -e "\n${YELLOW}─────────────────────────────────────────${NC}"
    echo -e "共 ${GREEN}${#ALL_KEYS[@]}${NC} 个密钥"
    echo
  fi
}

gemini_delete_projects() {
  log "INFO" "====== 删除现有项目 ======"
  read -r -p "输入项目前缀进行批量删除 (留空取消): " prefix
  if [ -z "$prefix" ]; then return 0; fi
  local projects=$(gcloud projects list --format="value(projectId)" --filter="projectId:$prefix*" 2>/dev/null)
  for p in $projects; do
    log "INFO" "正在删除 $p ..."
    gcloud projects delete "$p" --quiet
  done
}

# ===== 主菜单 =====
show_menu() {
  echo -e "\n${CYAN}${BOLD}====== 喵酱的 GCP 管理器 v${VERSION} ======${NC}"
  echo "1. [经典] 自动创建项目并提取密钥 (清理旧项目释放配额)"
  echo "2. [新增] 自动创建项目并提取密钥 (保留旧项目结算绑定)"
  echo "3. 从现有项目提取密钥 (纯净控制台打印，支持默认项目)"
  echo "4. 批量删除项目"
  echo "0. 退出并摸摸喵酱"
  local choice
  read -r -p "请主人吩咐: " choice
  case "$choice" in
    1) check_env && gemini_create_projects "false" "false" ;;
    2) 
      check_env || return
      echo -e "\n${CYAN}主人想怎么操作呢？${NC}"
      echo "1. 自定义选择结算账户和数量"
      echo "2. 全自动 (为所有可用账户各创建3个项目)"
      local sub_choice
      read -r -p "请选择 [1-2, 默认: 1]: " sub_choice
      sub_choice=${sub_choice:-1}
      if [ "$sub_choice" = "2" ]; then gemini_create_projects "true" "true"
      else gemini_create_projects "true" "false"; fi
      ;;
    3) check_env && gemini_get_keys_from_existing ;;
    4) check_env && gemini_delete_projects ;;
    0) exit 0 ;;
    *) log "ERROR" "指令无效喵！" ;; 
  esac
}

main() { while true; do show_menu; done; }

main
