#!/bin/bash
# 优化的 GCP API 密钥管理工具 - 经典护航版
# 支持 Gemini API (全量提取 + 动态救助掉签项目重绑账单 + 幽灵记忆库)
# 修复：选项3完美打印 + 强制人工激活计费拦截 + 选项5智能读取默认项目
# 版本: 4.3.8

set -Euo pipefail

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="4.3.8"
PROJECT_PREFIX="${PROJECT_PREFIX:-miaojiang-api}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
CACHE_FILE="$HOME/.miaojiang_keys.cache"
TEMP_DIR=""

# 初始化
TEMP_DIR=$(mktemp -d -t gcp_script_XXXXXX) || { echo "错误：无法创建临时目录"; exit 1; }
touch "$CACHE_FILE" 2>/dev/null || true
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
  if [ $exit_code -gt 1 ]; then return $exit_code; else return 0; fi
}
trap 'handle_error' ERR

cleanup_resources() {
  if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR" 2>/dev/null || true; fi
  echo -e "\n${CYAN}期待下次为您服务～${NC}"
}
trap cleanup_resources EXIT

# ===== 强制升级付费层级拦截提示 =====
prompt_upgrade_billing() {
  echo -e "\n${YELLOW}${BOLD}⚠️ 风控防御与付费激活提示：${NC}"
  echo -e "根据 Google Cloud 官方安全限制，${RED}代码无法自动将「免费试用」升级为「付费层级」${NC}。"
  echo -e "如果您的账号尚未激活付费层级，接下来将触发 403 封禁或配额不足！"
  echo -e "请务必点击下方链接，在网页顶部点击 ${GREEN}【激活 (Activate) / 升级 (Upgrade)】${NC} 按钮："
  echo -e "${CYAN}👉 https://console.cloud.google.com/billing ${NC}"
  read -r -p "确认您已手动激活后，请按回车键继续执行脚本 (Press Enter to continue)..." _
}

# ===== 幽灵记忆库功能 =====
save_key_to_cache() {
  local pid="$1"; local key="$2"
  [ -z "$key" ] && return
  if ! grep -q "^${pid}:${key}$" "$CACHE_FILE" 2>/dev/null; then
    echo "${pid}:${key}" >> "$CACHE_FILE" 2>/dev/null || true
  fi
}

get_key_from_cache() {
  local pid="$1"
  if [ -f "$CACHE_FILE" ]; then
    grep "^${pid}:" "$CACHE_FILE" 2>/dev/null | cut -d':' -f2 | tail -n 1
  fi
}

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

# 完全模拟 GCP 官方 Web UI 的项目名称生成器
new_project_name() { 
  echo "My Project $((RANDOM % 90000 + 10000))"
}

# 完全模拟 GCP 官方 Web UI 的项目 ID 生成器
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
  if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init'！"; exit 1; fi
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

unlink_projects_from_billing_account() {
  local billing_id="$1"
  local linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null)
  if [ -z "$linked_projects" ]; then return 0; fi
  log "WARN" "发现旧项目占用结算账户，开始清理释放配额..."
  for project_id in $linked_projects; do
    [ -n "$project_id" ] && gcloud billing projects unlink "$project_id" --quiet >/dev/null 2>&1 || true
  done
  return 0
}

# ===== 核心提取逻辑 =====
extract_key_safely() {
  local project_id="$1"
  retry gcloud services enable apikeys.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1 || true

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
        save_key_to_cache "$project_id" "$api_key"
        echo "$api_key"
        return 0
      fi
    done
  fi

  local cached_key
  cached_key=$(get_key_from_cache "$project_id")
  if [ -n "$cached_key" ]; then
    echo "$cached_key"
    return 0
  fi
  return 1
}

_extract_single_project() {
  local pid="$1"
  gcloud services enable generativelanguage.googleapis.com --project="$pid" --quiet >/dev/null 2>&1 || true
  local key_output=""
  key_output=$(gcloud services api-keys create --project="$pid" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --format=json 2>/dev/null) || true
  
  local api_key=""
  api_key=$(parse_json "$key_output" ".keyString") || true
  if [ -z "$api_key" ]; then
    api_key=$(extract_key_safely "$pid") || true
  fi
  echo "$api_key"
}

# ===== 结算账户选择 =====
select_billing_accounts() {
  local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
  if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户！"; return 1; fi

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
    log "ERROR" "未选择任何结算账户！"; return 1
  fi
}

# ===== 选项1、2 核心逻辑 =====
gemini_create_projects() {
  prompt_upgrade_billing
  
  local keep_billing="${1:-false}"
  local auto_mode="${2:-false}"
  
  if [ "$keep_billing" = "true" ]; then
    log "INFO" "====== 自动创建并提取 Gemini 项目 (保留旧结算绑定) ======"
  else
    log "INFO" "====== 自动创建并提取 Gemini 项目 (释放旧配额) ======"
  fi

  local num_per_billing

  if [ "$auto_mode" = "true" ]; then
    log "INFO" "开启【全自动模式】：将为所有可用结算账户各创建 3 个项目！"
    local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
    if [ -z "$billing_raw" ]; then log "ERROR" "未找到开放的结算账户！"; return 1; fi

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
      local project_name=$(new_project_name)
      
      log "INFO" "[${global_idx}/${total_projects}] 正在处理项目: ${project_name} [${project_id}] (结算: ${billing_name})"
      
      gcloud projects create "$project_id" --name="$project_name" || { failed=$((failed+1)); i=$((i+1)); continue; }
      gcloud billing projects link "$project_id" --billing-account="$GEMINI_BILLING_ACCOUNT" || true
      
      local billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
      if [ -z "$billing_info" ]; then
        log "WARN" "项目 ${project_id} 未绑定结算账户，跳过密钥提取！"
        skipped=$((skipped+1)); i=$((i+1)); continue
      fi
      
      local api_key=$(_extract_single_project "$project_id")

      if [ -n "$api_key" ]; then
        save_key_to_cache "$project_id" "$api_key"
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
  
  if [ "${#ALL_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}为您奉上所有提取的密钥：${NC}"
    for k in "${ALL_KEYS[@]}"; do echo "$k"; done
    echo
  fi
}

# ===== 选项3 核心逻辑：提取现有项目 =====
gemini_get_keys_from_existing() {
  prompt_upgrade_billing
  
  log "INFO" "====== 从现有项目强力提取密钥 ======"
  local projects
  projects=$(gcloud projects list --format='value(projectId)' 2>/dev/null || echo "")
  if [ -z "$projects" ]; then log "ERROR" "没找到活跃项目！"; return 1; fi
  
  local success=0; local failed=0
  local ALL_KEYS=()
  
  for project_id in $projects; do
    log "INFO" "正在提取项目: ${project_id}"
    local api_key=$(_extract_single_project "$project_id")
    if [ -n "$api_key" ]; then
      log "SUCCESS" "提取成功: $api_key"
      ALL_KEYS+=("[${project_id}] : ${api_key}") 
      success=$((success+1))
    else
      log "WARN" "提取失败"
      failed=$((failed+1))
    fi
  done
  
  echo -e "\n${CYAN}成功提取: $success | 失败: $failed${NC}"

  if [ "${#ALL_KEYS[@]}" -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}====== 为您奉上所有提取到的密钥 ======${NC}"
    for k in "${ALL_KEYS[@]}"; do echo -e "${GREEN}$k${NC}"; done
    echo
  fi
}

# ===== 选项4 核心逻辑：批量删除 =====
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

# ===== 选项5 智能提取默认项目 -> 转移结算 -> 建2个提取1+2 =====
rebuild_and_transfer_billing() {
  prompt_upgrade_billing

  log "INFO" "====== 选项5: 终极护盾转移重建模式 ======"
  
  # 0. 智能探测默认项目ID
  local default_project
  default_project=$(gcloud config get-value project 2>/dev/null || echo "")
  
  local ORIGINAL_PROJECT=""
  while [ -z "$ORIGINAL_PROJECT" ]; do
    echo -e "${YELLOW}⚠️ 警告：接下来的操作会删除其他所有项目！${NC}"
    if [ -n "$default_project" ]; then
      read -r -p "请输入绝对不能删除的【原始项目 ID】[直接回车默认保护当前项目: ${default_project}]: " ORIGINAL_PROJECT
      ORIGINAL_PROJECT=${ORIGINAL_PROJECT:-$default_project}
    else
      read -r -p "请输入绝对不能删除的【原始项目 ID】(必填): " ORIGINAL_PROJECT
    fi
  done
  
  # 1. 转移结算权限
  local CURRENT_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
  log "INFO" "当前登录账号: $CURRENT_ACCOUNT"
  
  local TARGET_EMAIL
  read -r -p "请输入接收结算权限的目标邮箱 [直接回车默认: $CURRENT_ACCOUNT]: " TARGET_EMAIL
  TARGET_EMAIL=${TARGET_EMAIL:-$CURRENT_ACCOUNT}
  
  log "INFO" "正在查找可用的结算账户..."
  local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1)
  if [ -z "$billing_raw" ]; then
    log "ERROR" "未找到活动的结算账户，无法继续！"
    return 1
  fi
  local TARGET_BILLING_ID="${billing_raw#billingAccounts/}"
  
  log "INFO" "处理结算账户: $TARGET_BILLING_ID"
  local policy_json
  policy_json=$(gcloud beta billing accounts get-iam-policy "$TARGET_BILLING_ID" --format=json 2>/dev/null || echo "")
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
        gcloud beta billing accounts add-iam-policy-binding "$TARGET_BILLING_ID" \
          --member="user:$TARGET_EMAIL" \
          --role="$role" --quiet >/dev/null 2>&1 || log "WARN" "授权 $role 失败"
      done
    fi
  fi
  
  # 2. 逐个删除其他项目 (遇原项目则跳过)
  log "INFO" "====== 开始清理非保护项目 ======"
  local all_projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null || echo "")
  if [ -n "$all_projects" ]; then
    for p in $all_projects; do
      if [ "$p" = "$ORIGINAL_PROJECT" ]; then
        log "SUCCESS" "检测到原始项目 [$p]，已死死抱住，绝对不删！"
        continue
      fi
      log "INFO" "正在删除项目 $p ..."
      gcloud projects delete "$p" --quiet >/dev/null 2>&1 || true
      log "INFO" "休眠 3 秒，防止风控..."
      sleep 3
    done
  fi
  
  local FINAL_KEYS=()
  
  # 3. 处理原始项目
  log "INFO" "====== 开始处理原始项目并提取密钥 ======"
  gcloud billing projects link "$ORIGINAL_PROJECT" --billing-account="$TARGET_BILLING_ID" --quiet >/dev/null 2>&1 || true
  local orig_key=$(_extract_single_project "$ORIGINAL_PROJECT")
  if [ -n "$orig_key" ]; then
    FINAL_KEYS+=("【原始项目】 $ORIGINAL_PROJECT : $orig_key")
    log "SUCCESS" "原始项目密钥提取成功！"
  else
    log "WARN" "原始项目提取失败！"
  fi

  # 4. 创建 2 个新项目
  log "INFO" "====== 开始创建 2 个新项目并提取密钥 ======"
  for i in 1 2; do
    local pid=$(new_project_id)
    local pname=$(new_project_name)
    log "INFO" "[${i}/2] 正在创建新项目: $pname [$pid]"
    
    if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
      sleep 3
      gcloud billing projects link "$pid" --billing-account="$TARGET_BILLING_ID" --quiet >/dev/null 2>&1 || true
      local new_key=$(_extract_single_project "$pid")
      if [ -n "$new_key" ]; then
        FINAL_KEYS+=("【新建项目】 $pid : $new_key")
        log "SUCCESS" "新项目密钥提取成功！"
      else
        log "WARN" "新项目提取失败！"
      fi
    else
      log "ERROR" "新项目创建失败..."
    fi
    sleep 3
  done

  # 5. 打印最终的 3 个 Key
  echo -e "\n${YELLOW}${BOLD}====== 终极提取报告 ======${NC}"
  for k in "${FINAL_KEYS[@]}"; do
    echo -e "${CYAN}${k}${NC}"
  done
  echo -e "\n${GREEN}任务圆满完成！${NC}"
}

# ===== 主菜单 =====
show_menu() {
  echo -e "\n${CYAN}${BOLD}====== GCP API 管理器 v${VERSION} ======${NC}"
  echo "1. [经典] 自动创建项目并提取密钥 (清理旧项目释放配额)"
  echo "2. [防风控] 自动创建项目并提取密钥 (保留旧项目结算绑定)"
  echo "3. 从现有项目提取密钥"
  echo "4. 批量删除项目"
  echo "5. [护盾] 保护原项目 -> 转移结算 -> 删闲置 -> 建2个凑齐3密钥"
  echo "0. 退出"
  local choice
  read -r -p "请选择: " choice
  case "$choice" in
    1) check_env && gemini_create_projects "false" "false" ;;
    2) 
      check_env || return
      echo -e "\n${CYAN}请选择操作方式：${NC}"
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
    5) check_env && rebuild_and_transfer_billing ;;
    0) exit 0 ;;
    *) log "ERROR" "指令无效！" ;; 
  esac
}

main() { while true; do show_menu; done; }

main
