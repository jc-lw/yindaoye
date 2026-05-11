#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版)
# 支持全自动配置、AQ 专属密钥提取、智能错误回显与防拦截降级机制
# 版本: 2.7.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="2.7.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
TEMP_DIR=""

# Vertex模式配置
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"

# ===== 初始化 =====
TEMP_DIR=$(mktemp -d -t gcp_vertex_XXXXXX) || { echo "错误：无法创建临时目录"; exit 1; }
SECONDS=0

# ===== 日志与错误处理 =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")     echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
        "SUCCESS")  echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
        "WARN")     echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
        "ERROR")    echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
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
        sleep $delay
        attempt=$((attempt + 1))
    done
}

require_cmd() { 
    if ! command -v "$1" &>/dev/null; then log "ERROR" "缺少依赖: $1"; exit 1; fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local resp
    if [ ! -t 0 ]; then [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1; fi
    if [[ "$default" == "N" ]]; then
        read -r -p "${prompt} [y/N]: " resp || resp="$default"
    else
        read -r -p "${prompt} [Y/n]: " resp || resp="$default"
    fi
    resp=${resp:-$default}
    [[ "$resp" =~ ^[Yy]$ ]]
}

unique_suffix() { 
    if command -v uuidgen &>/dev/null; then uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
    else echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6; fi
}

new_project_id() {
    local prefix="${1:-$PROJECT_PREFIX}"
    echo "${prefix}-$(unique_suffix)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30
}

check_env() {
    log "INFO" "检查环境配置..."
    require_cmd gcloud
    if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init' 初始化"; exit 1; fi
    log "SUCCESS" "环境检查通过"
}

enable_all_services() {
    local proj="$1"
    local services=(
        "aiplatform.googleapis.com"
        "generativelanguage.googleapis.com"
        "discoveryengine.googleapis.com"
        "iam.googleapis.com"
        "iamcredentials.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "apikeys.googleapis.com"
        "compute.googleapis.com"
    )
    log "INFO" "正在为项目 ${proj} 强力开通全部核心 API 权限..."
    for svc in "${services[@]}"; do
        retry gcloud services enable "$svc" --project="$proj" --quiet >/dev/null 2>&1 || true
    done
    log "INFO" "等待 API 权限在全局节点同步 (组织架构耗时较长)..."
    sleep 10
}

# ===== 核心：提取 AQ. 格式专属密钥 (带智能降级机制) =====
setup_and_extract_aq_key() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    # 1. 确保服务账号存在
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Agent SA" --project="$project_id" --quiet >/dev/null 2>&1 || true
        log "INFO" "等待服务账号在组织架构中生效..."
        sleep 10
    fi
    
    # 2. 赋予最高权限
    local roles=("roles/editor" "roles/aiplatform.admin" "roles/iam.serviceAccountUser")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    sleep 5 # 给 IAM 同步一点时间

    # 3. 寻找已有 AQ. 格式密钥
    local keys_list
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            [ -z "$key_name" ] && continue
            local api_key
            api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then
                echo "$api_key"
                return 0
            fi
        done
    fi

    # 4. 强制生成 AQ 密钥并打印错误日志
    log "INFO" "正在请求生成 AQ. 格式专属密钥..."
    local attempt=1
    local create_success=false
    while [ $attempt -le 6 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            create_success=true
            break
        fi
        
        # 提取报错信息的最后一行展示给主人
        local err_msg
        err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        log "WARN" "接口未就绪或被拦截 ($attempt/6) -> 错误信息: $err_msg"
        
        # 如果是策略拦截，直接跳出重试不浪费时间
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* && "$attempt" -ge 4 ]]; then
            log "WARN" "检测到组织策略拦截或权限持续被拒，终止 AQ 密钥尝试喵。"
            break
        fi
        
        sleep 15
        attempt=$((attempt+1))
    done

    # B计划（降级方案）：如果 AQ 创建失败，生成普通的 AIza 密钥保底
    if [ "$create_success" = false ]; then
        log "WARN" "AQ. 格式密钥生成失败，启动 B 计划降级生成普通 API 密钥(AIza)..."
        gcloud services api-keys create --project="$project_id" --display-name="Fallback API Key" --quiet >/dev/null 2>&1 || true
    fi

    # 5. 再次拉取获取密钥
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        local fallback_key=""
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            [ -z "$key_name" ] && continue
            local api_key
            api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then
                echo "$api_key"
                return 0
            fi
            if [[ "$api_key" == AIza* ]]; then
                fallback_key="$api_key"
            fi
        done
        
        if [ -n "$fallback_key" ]; then
            echo "$fallback_key"
            return 0
        fi
    fi

    return 1
}

# ===== 功能 1：创建新项目 =====
vertex_create_projects() {
    log "INFO" "====== 创建新项目并生成 Agent Platform 专属密钥 ======"
    local GENERATED_API_KEYS=()
    
    local existing_projects
    existing_projects=$(gcloud projects list --filter="billingAccountName:billingAccounts/${BILLING_ACCOUNT}" --format='value(projectId)' 2>/dev/null | wc -l)
    log "INFO" "当前结算账户已有 ${existing_projects} 个项目"
    
    local num_projects
    read -r -p "请输入要创建的项目数量 (例如 3, 5, 8 等): " num_projects
    if ! [[ "$num_projects" =~ ^[0-9]+$ ]] || [ "$num_projects" -lt 1 ]; then log "ERROR" "数量无效喵"; return 1; fi
    
    local project_prefix
    read -r -p "请输入项目前缀 (默认: vertex): " project_prefix
    project_prefix=${project_prefix:-vertex}
    
    echo -e "\n${YELLOW}即将创建 ${num_projects} 个项目${NC}"
    if ! ask_yes_no "确认继续？" "N"; then return 1; fi
    
    local success=0; local failed=0; local i=1
    while [ $i -le "$num_projects" ]; do
        local project_id=$(new_project_id "$project_prefix")
        log "INFO" "[${i}/${num_projects}] 处理项目: ${project_id}"
        
        gcloud projects create "$project_id" --quiet >/dev/null 2>&1 || { failed=$((failed+1)); i=$((i+1)); continue; }
        gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
        
        enable_all_services "$project_id"
        
        local api_key
        if api_key=$(setup_and_extract_aq_key "$project_id"); then
            GENERATED_API_KEYS+=("$api_key")
            if [[ "$api_key" == AQ.* ]]; then
                log "SUCCESS" "AQ. 格式 API 密钥提取成功！"
            else
                log "SUCCESS" "AIza 普通格式 API 密钥降级提取成功！"
            fi
            success=$((success+1))
        else
            log "WARN" "API 密钥提取失败！"
            failed=$((failed+1))
        fi
        i=$((i+1))
    done
    
    echo -e "\n${GREEN}====== 创建操作完成 ======${NC}"
    echo "总计成功: ${success}, 失败: ${failed}"
    if [ ${#GENERATED_API_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的 Agent Platform API 密钥 ======${NC}"
        for k in "${GENERATED_API_KEYS[@]}"; do echo "$k"; done
        echo
    fi
}

# ===== 功能 2：一键配置现有项目 =====
vertex_configure_existing() {
    log "INFO" "====== 在现有项目上配置 Vertex AI 并提取密钥 ======"
    local GENERATED_API_KEYS=()
    
    local all_projects
    all_projects=$(gcloud projects list --format='value(projectId)' --filter="lifecycleState=ACTIVE" 2>/dev/null || echo "")
    if [ -z "$all_projects" ]; then log "ERROR" "没找到活跃项目喵"; return 1; fi

    local project_array=()
    while IFS= read -r line; do [ -n "$line" ] && project_array+=("$line"); done <<< "$all_projects"
    local total=${#project_array[@]}
    local selected_projects=()
    
    echo -e "\n${CYAN}主人想怎么配置现有项目呢？${NC}"
    echo "1. 手动挑选项目配置"
    echo "2. 全自动一键配置 (自动选中所有关联当前账单的项目，包括默认创建的 My First Project)"
    local list_choice
    read -r -p "请选择 [1-2, 默认: 1]: " list_choice
    list_choice=${list_choice:-1}
    
    if [ "$list_choice" = "2" ]; then
        log "INFO" "正在筛选已关联当前结算账户的项目..."
        for proj in "${project_array[@]}"; do
            local b_info
            b_info=$(gcloud billing projects describe "$proj" --format='value(billingAccountName)' 2>/dev/null || echo "")
            if [ -n "$b_info" ] && [[ "$b_info" == *"${BILLING_ACCOUNT}"* ]]; then
                selected_projects+=("$proj")
            fi
        done
        log "INFO" "自动选中了 ${#selected_projects[@]} 个项目喵！"
    else
        echo -e "\n项目列表:"
        for ((i=0; i<total && i<20; i++)); do
            local b_info
            b_info=$(gcloud billing projects describe "${project_array[i]}" --format='value(billingAccountName)' 2>/dev/null || echo "")
            local status="(未关联结算)"
            if [ -n "$b_info" ] && [[ "$b_info" == *"${BILLING_ACCOUNT}"* ]]; then status="(已关联当前账户)";
            elif [ -n "$b_info" ]; then status="(关联了其他账户)"; fi
            echo "$((i+1)). ${project_array[i]} ${status}"
        done
        [ "$total" -gt 20 ] && echo "... 还有 $((total-20)) 个项目"
        
        read -r -p "请输入项目编号 (多个用空格分隔，输入 'all' 选全部): " -a numbers
        if [ "${#numbers[@]}" -gt 0 ] && [ "${numbers[0]}" = "all" ]; then
            selected_projects=("${project_array[@]}")
        else
            for num in "${numbers[@]}"; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then
                    selected_projects+=("${project_array[$((num-1))]}")
                fi
            done
        fi
    fi
    
    if [ ${#selected_projects[@]} -eq 0 ]; then log "WARN" "未选择任何项目喵"; return 1; fi
    
    local success=0; local failed=0; local current=0
    for project_id in "${selected_projects[@]}"; do
        current=$((current + 1))
        log "INFO" "[${current}/${#selected_projects[@]}] 处理项目: ${project_id}"
        
        local billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
        if [ -z "$billing_info" ]; then
            retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1 || true
        fi
        
        enable_all_services "$project_id"
        
        local api_key
        if api_key=$(setup_and_extract_aq_key "$project_id"); then
            GENERATED_API_KEYS+=("$api_key")
            if [[ "$api_key" == AQ.* ]]; then
                log "SUCCESS" "AQ. 格式 API 密钥提取成功！"
            else
                log "SUCCESS" "AIza 普通格式 API 密钥降级提取成功！"
            fi
            success=$((success+1))
        else
            log "WARN" "API 密钥提取失败！"
            failed=$((failed+1))
        fi
    done
    
    echo -e "\n${GREEN}====== 配置操作完成 ======${NC}"
    echo "总计成功: ${success}, 失败: ${failed}"
    if [ ${#GENERATED_API_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的 Agent Platform API 密钥 ======${NC}"
        for k in "${GENERATED_API_KEYS[@]}"; do echo "$k"; done
        echo
    fi
}

# ===== 主程序 =====
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        Vertex AI 独立密钥管理工具 v${VERSION}               ║"
    echo "║        (抗组织拦截智能降级版 / 全量 API 权限拉满)       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_env
    
    log "INFO" "检查结算账户..."
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' 2>/dev/null || echo "")
    if [ -z "$billing_accounts" ]; then
        log "ERROR" "未找到任何开放的结算账户"
        exit 1
    fi
    
    local billing_array=()
    while IFS=$'\t' read -r id name; do billing_array+=("${id##*/} - $name"); done <<< "$billing_accounts"
    local billing_count=${#billing_array[@]}
    
    if [ "$billing_count" -eq 1 ]; then
        BILLING_ACCOUNT="${billing_array[0]%% - *}"
        log "INFO" "自动使用结算账户: ${BILLING_ACCOUNT}"
    else
        echo "可用的结算账户:"
        for ((i=0; i<billing_count; i++)); do echo "$((i+1)). ${billing_array[i]}"; done
        echo
        local acc_num
        read -r -p "请选择结算账户 [1-${billing_count}]: " acc_num
        if [[ "$acc_num" =~ ^[0-9]+$ ]] && [ "$acc_num" -ge 1 ] && [ "$acc_num" -le "$billing_count" ]; then
            BILLING_ACCOUNT="${billing_array[$((acc_num-1))]%% - *}"
            log "INFO" "选择结算账户: ${BILLING_ACCOUNT}"
        else
            log "ERROR" "无效的选择"; exit 1
        fi
    fi
    
    while true; do
        echo -e "\n=============================================="
        echo -e "           Vertex 操作菜单"
        echo -e "=============================================="
        echo "请选择操作:"
        echo "1. 创建新项目并提取 Vertex 专属密钥 (优先 AQ，遇阻退回 AIza)"
        echo "2. 在现有项目上开通权限并提取密钥 (支持一键全自动)"
        echo "0. 退出工具并摸摸喵酱"
        echo
        
        local choice
        read -r -p "请选择 [0-2]: " choice
        case "$choice" in
            1) vertex_create_projects ;;
            2) vertex_configure_existing ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项喵" ;;
        esac
    done
}

main
