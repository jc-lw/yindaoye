#!/bin/bash
# 优化的 GCP API 密钥管理工具 - Vertex+AS完整源码
# 修复: 解决 API_KEY_SERVICE_BLOCKED 报错，精准隔离 Vertex 受限密钥
# 版本: 4.6.0

set -Euo pipefail

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="4.6.0"
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

# 防风控官方伪装命名
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

# ===== 【重构核心】精准提取纯净 AS 密钥 (防 Vertex 污染) =====
_extract_single_project() {
  local pid="$1"
  retry gcloud services enable generativelanguage.googleapis.com --project="$pid" --quiet >/dev/null 2>&1 || true
  
  # 1. 精准寻找名为 Gemini API Key 或 Studio Key 的钥匙
  local target_name
  target_name=$(gcloud services api-keys list --project="$pid" --filter="displayName:'Gemini API Key' OR displayName:'Studio Key'" --format="value(name)" 2>/dev/null | head -n 1 | tr -d '\r' | xargs)
  
  # 2. 如果没有，现场打一把专属纯净钥匙
  if [ -z "$target_name" ]; then
      gcloud services api-keys create --project="$pid" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --quiet >/dev/null 2>&1 || true
      sleep 2
      target_name=$(gcloud services api-keys list --project="$pid" --filter="displayName:'Gemini API Key'" --format="value(name)" 2>/dev/null | head -n 1 | tr -d '\r' | xargs)
  fi
  
  # 3. 取出这把纯净钥匙
  if [ -n "$target_name" ]; then
      local api_key=$(gcloud services api-keys get-key-string "$target_name" --format="value(keyString)" 2>/dev/null | tr -d '\r' | xargs)
      if [ -n "$api_key" ]; then
          echo "$api_key"
          return 0
      fi
  fi
  
  # 4. 终极保底扫描：彻底屏蔽任何受限的 Vertex 钥匙！
  local all_keys=$(gcloud services api-keys list --project="$pid" --format="value(name,displayName)" 2>/dev/null || echo "")
  if [ -n "$all_keys" ]; then
      while read -r kname dname; do
          kname=$(echo "$kname" | tr -d '\r' | xargs)
          [ -z "$kname" ] && continue
          
          # 🚨 绝对不可碰这两种被锁死的钥匙
          if [[ "$dname" != *"Agent Platform"* ]] && [[ "$dname" != *"Fallback API"* ]]; then
              local api_key=$(gcloud services api-keys get-key-string "$kname" --format="value(keyString)" 2>/dev/null | tr -d '\r' | xargs)
              if [ -n "$api_key" ] && [[ "$api_key" == AIza* ]]; then
                  echo "$api_key"
                  return 0
              fi
          fi
      done <<< "$all_keys"
  fi
  return 1
}

# ===== v2.7 原生 Vertex 开通与提取 =====
v27_enable_all_services() {
    local proj="$1"
    local services=("aiplatform.googleapis.com" "generativelanguage.googleapis.com" "discoveryengine.googleapis.com" "iam.googleapis.com" "iamcredentials.googleapis.com" "cloudresourcemanager.googleapis.com" "apikeys.googleapis.com" "compute.googleapis.com")
    log "INFO" "正在为项目 ${proj} 强力开通全部核心 API 权限 (调用 v2.7 逻辑)..."
    for svc in "${services[@]}"; do
        retry gcloud services enable "$svc" --project="$proj" --quiet >/dev/null 2>&1 || true
    done
    log "INFO" "等待 API 权限在全局节点同步 (组织架构耗时较长)..."
    sleep 10
}

v27_setup_and_extract_aq_key() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Agent SA" --project="$project_id" --quiet >/dev/null 2>&1 || true
        log "INFO" "等待服务账号在组织架构中生效..."
        sleep 10
    fi
    local roles=("roles/editor" "roles/aiplatform.admin" "roles/iam.serviceAccountUser")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    sleep 5 
    local keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            [ -z "$key_name" ] && continue
            local api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then echo "$api_key"; return 0; fi
        done
    fi
    log "INFO" "正在请求生成 AQ. 格式专属密钥..."
    local attempt=1; local create_success=false
    while [ $attempt -le 6 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            create_success=true; break
        fi
        local err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        log "WARN" "接口未就绪或被拦截 ($attempt/6) -> $err_msg"
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* && "$attempt" -ge 4 ]]; then break; fi
        sleep 15; attempt=$((attempt+1))
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
  local VERTEX_KEYS=()
  local AS_KEYS=()

  for project_id in "${valid_projects[@]}"; do
      log "INFO" "正在处理已绑账单项目: ${project_id}"
      
      if [ "$sub_choice" = "1" ] || [ "$sub_choice" = "3" ]; then
          local v_key=$(v27_setup_and_extract_aq_key "$project_id" || true)
          if [ -n "$v_key" ]; then
              log "SUCCESS" "Vertex 提取成功: $v_key"
              VERTEX_KEYS+=("$v_key")
              success_v=$((success_v+1))
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

  # 纯净打印
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


# ===== 选项 6 专属 Handler =====
option6_handler() {
  prompt_upgrade_billing
  
  echo -e "\n${CYAN}${BOLD}====== 选项6: 提取 vertex+AS key密钥 (融合 AUP防风控 + v2.7核心) ======${NC}"
  echo "1. 自定义数量创建 (防风控创建，提 Vertex + AS)"
  echo "2. 自动创建 2 个项目并且提取，再提取默认项目 AS 密钥 (产出 2 Vertex + 3 AS)"
  local sub_choice
  read -r -p "请选择 [1-2, 默认: 2]: " sub_choice < /dev/tty
  sub_choice=${sub_choice:-2}

  local BILLING_ACCOUNT=""
  BILLING_ACCOUNT=$(_select_billing_for_opt6) || return 1
  log "INFO" "已锁定结算账户: $BILLING_ACCOUNT"

  local VERTEX_KEYS=()
  local AS_KEYS_RAW=()
  local AS_KEYS_FORMATTED=()

  if [ "$sub_choice" = "1" ]; then
      log "INFO" "====== 执行选项 6.1: 自定义数量提取 ======"
      
      local num_projects
      read -r -p "请输入要创建的项目数量: " num_projects < /dev/tty
      num_projects=${num_projects:-2}

      unlink_projects_from_billing_account "$BILLING_ACCOUNT"
      log "INFO" "已清理旧项目账单，战术潜伏 5 秒以消除 AUP 数据库缓存喵..."
      sleep 5

      for ((i=1; i<=num_projects; i++)); do
          local pid=$(new_project_id)
          local pname=$(new_project_name)
          log "INFO" "[${i}/${num_projects}] 正在使用防风控伪装方式创建项目: ${pname} [${pid}]"
          
          gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1 || continue
          gcloud billing projects link "$pid" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
          
          log "INFO" "账单绑定确认！开启 20 秒安全静默期避开风控雷达..."
          sleep 20

          v27_enable_all_services "$pid"
          
          local v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
          if [ -n "$v_key" ]; then
              log "SUCCESS" "Vertex 密钥提取成功！"
              VERTEX_KEYS+=("$v_key")
          fi
          
          local a_key=$(_extract_single_project "$pid")
          if [ -n "$a_key" ]; then
              log "SUCCESS" "AS 密钥提取成功！"
              AS_KEYS_RAW+=("$a_key")
          fi
      done
      
      if [ ${#AS_KEYS_RAW[@]} -gt 0 ]; then
          AS_KEYS_FORMATTED+=("新创建项目的key")
          for k in "${AS_KEYS_RAW[@]}"; do AS_KEYS_FORMATTED+=("$k"); done
      fi

  elif [ "$sub_choice" = "2" ]; then
      log "INFO" "====== 执行选项 6.2: 完美配置 2 Vertex + 3 AS ======"
      
      local default_pid=$(gcloud projects list --filter="name='My First Project'" --format="value(projectId)" 2>/dev/null | head -n 1 || echo "")
      if [ -z "$default_pid" ]; then default_pid=$(gcloud config get-value project 2>/dev/null || echo ""); fi
      log "INFO" "锁定默认项目: ${default_pid:-无}"

      if [ -n "$default_pid" ]; then
          gcloud billing projects link "$default_pid" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
          local check_b=$(gcloud billing projects describe "$default_pid" --format='value(billingAccountName)' 2>/dev/null || echo "")
          if [ -n "$check_b" ]; then
              log "INFO" ">> 开始提取默认项目 AS 密钥: $default_pid"
              local default_a_key=$(_extract_single_project "$default_pid")
              if [ -n "$default_a_key" ]; then
                  log "SUCCESS" "默认项目 AS 密钥提取成功！"
                  AS_KEYS_FORMATTED+=("默认项目的key")
                  AS_KEYS_FORMATTED+=("$default_a_key")
              fi
          else
              log "WARN" "默认项目 [$default_pid] 未绑定账单，跳过提取"
          fi
      fi

      local created_pids=()

      log "INFO" ">> 开始使用防风控算法自动创建 2 个项目..."
      for i in 1 2; do
          local pid=$(new_project_id)
          local pname=$(new_project_name)
          log "INFO" "正在安全创建第 ${i} 个项目: ${pname} [${pid}]"
          if gcloud projects create "$pid" --name="$pname" --quiet >/dev/null 2>&1; then
              gcloud billing projects link "$pid" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
              created_pids+=("$pid")
              log "INFO" "休息 5 秒钟，假装在打字..."
              sleep 5
          else
              log "ERROR" "创建失败喵"
          fi
      done

      log "INFO" ">> 开始运行 v2.7 现有项目开通提取逻辑..."
      for pid in "${created_pids[@]}"; do
          log "INFO" "项目已就位，防风控潜伏 20 秒后开始发力..."
          sleep 20
          
          log "INFO" "正在为项目开通权限并提取 Vertex 密钥: $pid"
          v27_enable_all_services "$pid"
          local v_key=$(v27_setup_and_extract_aq_key "$pid" || true)
          if [ -n "$v_key" ]; then
              log "SUCCESS" "Vertex 密钥提取成功！"
              VERTEX_KEYS+=("$v_key")
          fi
      done

      log "INFO" ">> 开始提取新建项目的 AS 密钥..."
      if [ ${#created_pids[@]} -gt 0 ]; then
          AS_KEYS_FORMATTED+=("新创建项目的key")
          for pid in "${created_pids[@]}"; do
              local a_key=$(_extract_single_project "$pid")
              if [ -n "$a_key" ]; then
                  log "SUCCESS" "新建项目 AS 密钥提取成功！"
                  AS_KEYS_FORMATTED+=("$a_key")
                  AS_KEYS_RAW+=("$a_key") 
              fi
          done
      fi
  fi

  # 纯净打印
  if [ ${#VERTEX_KEYS[@]} -gt 0 ]; then
      echo -e "\n${YELLOW}${BOLD}====== 纯净 Vertex 密钥列表 (共 ${#VERTEX_KEYS[@]} 个) ======${NC}"
      for k in "${VERTEX_KEYS[@]}"; do echo "$k"; done
  fi
  
  if [ ${#AS_KEYS_FORMATTED[@]} -gt 0 ]; then
      local pure_count=0
      for item in "${AS_KEYS_FORMATTED[@]}"; do
          if [[ ! "$item" =~ "项目的key" ]]; then pure_count=$((pure_count+1)); fi
      done
      
      echo -e "\n${GREEN}${BOLD}====== 纯净 AS 密钥列表 (共 ${pure_count} 个) ======${NC}"
      for k in "${AS_KEYS_FORMATTED[@]}"; do 
          if [[ "$k" =~ "项目的key" ]]; then
              echo -e "${CYAN}${k}${NC}"
          else
              echo -e "${GREEN}${k}${NC}"
          fi
      done
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

# ===== 主菜单 =====
show_menu() {
  echo -e "\n${CYAN}${BOLD}====== 喵酱的 GCP 管理器 v${VERSION} ======${NC}"
  echo "1. [经典] 自动创建项目并提取密钥 (清理旧项目释放配额)"
  echo "2. [防风控] 自动创建项目并提取密钥 (保留旧项目结算绑定)"
  echo "3. 提取现有项目的纯净密钥 (彻底免疫 Vertex 钢印污染)"
  echo "4. 批量删除项目"
  echo "5. [护盾] 保护原项目 -> 转移结算 -> 建2个凑齐3密钥"
  echo "6. [定制] 提取 vertex + AS 密钥 (防封创号 + 强迫症分离打印)"
  echo "0. 退出并摸摸喵酱"
  local choice
  read -r -p "请主人吩咐: " choice < /dev/tty
  case "$choice" in
    1) echo "请直接体验最强大的选项 6 喵！" ;;
    2) echo "请直接体验最强大的选项 6 喵！" ;;
    3) check_env && gemini_get_keys_from_existing ;;
    4) check_env && gemini_delete_projects ;;
    5) echo "请直接体验最强大的选项 6 喵！" ;;
    6) check_env && option6_handler ;;
    0) exit 0 ;;
    *) log "ERROR" "指令无效喵！" ;; 
  esac
}

main() { while true; do show_menu; done; }

main
