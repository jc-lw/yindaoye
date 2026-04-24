#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版)
# 支持自定义数量、双密钥(JSON + Agent Platform 专属 AQ.格式)共存分离展示、全自动配置
# 版本: 2.4.0

# 仅启用 errtrace (-E) 与 nounset (-u)
set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="2.4.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
TEMP_DIR=""

# Vertex模式配置
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"

# 全局数组，用于分别收集 JSON 路径和文本 Key
GENERATED_JSON_KEYS=()
GENERATED_API_KEYS=()

# ===== 初始化 =====
TEMP_DIR=$(mktemp -d -t gcp_vertex_XXXXXX) || { echo "错误：无法创建临时目录"; exit 1; }
mkdir -p "$KEY_DIR" 2>/dev/null || true
chmod 700 "$KEY_DIR" 2>/dev/null || true
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

enable_services() {
    local proj="$1"
    local services=(
        "aiplatform.googleapis.com"
        "iam.googleapis.com"
        "iamcredentials.googleapis.com"
        "cloudresourcemanager.googleapis.com"
        "apikeys.googleapis.com"
    )
    log "INFO" "为项目 ${proj} 启用必要的API服务..."
    local failed=0
    for svc in "${services[@]}"; do
        retry gcloud services enable "$svc" --project="$proj" --quiet >/dev/null 2>&1 || failed=$((failed + 1))
    done
    if [ $failed -gt 0 ]; then return 1; fi
    return 0
}

show_progress() {
    local completed="${1:-0}"; local total="${2:-1}"
    if [ "$total" -le 0 ]; then return; fi
    if [ "$completed" -gt "$total" ]; then completed=$total; fi
    local percent=$((completed * 100 / total))
    local bar_length=50
    local filled=$((percent * bar_length / 100))
    local bar=""; local i=0
    while [ $i -lt $filled ]; do bar+="█"; i=$((i + 1)); done
    i=$filled
    while [ $i -lt $bar_length ]; do bar+="░"; i=$((i + 1)); done
    printf "\r[%s] %3d%% (%d/%d)" "$bar" "$percent" "$completed" "$total"
    if [ "$completed" -eq "$total" ]; then echo; fi
}

# ===== 密钥提取与展示 =====

vertex_setup_service_account() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex AI Service Account" --project="$project_id" --quiet >/dev/null 2>&1 || return 1
    fi
    
    local roles=("roles/aiplatform.admin" "roles/iam.serviceAccountUser" "roles/iam.serviceAccountTokenCreator" "roles/aiplatform.user")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    
    local key_file="${KEY_DIR}/${project_id}-${SERVICE_ACCOUNT_NAME}-$(date +%Y%m%d-%H%M%S).json"
    if retry gcloud iam service-accounts keys create "$key_file" --iam-account="$sa_email" --project="$project_id" --quiet >/dev/null 2>&1; then
        chmod 600 "$key_file"
        GENERATED_JSON_KEYS+=("$key_file")
        return 0
    else
        return 1
    fi
}

extract_api_key() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    # 1. 先尝试寻找已有的 AQ. 开头密钥 (绑定了服务账号的密钥)
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

    # 2. 如果没有 AQ. 密钥，使用 gcloud beta 指令，将 API Key 强制绑定到服务账号，生成 Agent Platform 专属密钥
    retry gcloud beta services api-keys create --project="$project_id" --display-name="Vertex Agent Platform Key" --service-account="$sa_email" --quiet >/dev/null 2>&1 || true
    
    # 3. 再次拉取并获取 AQ. 密钥
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
        # 如果由于某种原因没生成 AQ.，兜底返回最新生成的
        local fallback_name
        fallback_name=$(echo "$keys_list" | head -n 1 | tr -d '\r' | xargs)
        local fallback_key
        fallback_key=$(gcloud services api-keys get-key-string "$fallback_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
        if [ -n "$fallback_key" ]; then
            echo "$fallback_key"
            return 0
        fi
    fi
    return 1
}

display_generated_keys() {
    if [ ${#GENERATED_API_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的 Agent Platform API 密钥 (AQ. 格式) ======${NC}"
        for k in "${GENERATED_API_KEYS[@]}"; do echo "$k"; done
        echo
    fi

    if [ ${#GENERATED_JSON_KEYS[@]} -gt 0 ]; then
        echo -e "\n${CYAN}${BOLD}====== 本次生成的 Vertex AI 凭证 (JSON) ======${NC}"
        for key_path in "${GENERATED_JSON_KEYS[@]}"; do
            if [ -f "$key_path" ]; then
                echo -e "${GREEN}▶ 来源文件: ${key_path}${NC}"
                echo -e "--------------------------------------------------"
                cat "$key_path"
                echo -e "\n--------------------------------------------------\n"
            fi
        done
    fi
}

# ===== 核心功能 =====
vertex_create_projects() {
    log "INFO" "====== 创建新项目并生成双密钥 ======"
    GENERATED_JSON_KEYS=()
    GENERATED_API_KEYS=()
    
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
        
        if ! enable_services "$project_id"; then failed=$((failed+1)); i=$((i+1)); continue; fi
        
        # 1. 提取服务账号 JSON
        if vertex_setup_service_account "$project_id"; then
            log "SUCCESS" "JSON 密钥生成成功！"
        else
            log "WARN" "JSON 密钥生成失败！"
        fi

        # 2. 提取文本 API Key (必定绑定为 AQ. 格式)
        local api_key
        if api_key=$(extract_api_key "$project_id"); then
            GENERATED_API_KEYS+=("$api_key")
            log "SUCCESS" "AQ. 格式 API 密钥提取成功！"
            success=$((success+1))
        else
            log "WARN" "API 密钥提取失败！"
            failed=$((failed+1))
        fi
        
        i=$((i+1))
    done
    
    echo -e "\n${GREEN}====== 创建操作完成 ======${NC}"
    echo "总计成功: ${success}, 失败: ${failed}"
    display_generated_keys
}

vertex_configure_existing() {
    log "INFO" "====== 在现有项目上配置 Vertex AI ======"
    GENERATED_JSON_KEYS=()
    GENERATED_API_KEYS=()
    
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
        
        if ! enable_services "$project_id"; then failed=$((failed+1)); continue; fi
        
        if vertex_setup_service_account "$project_id"; then
            log "SUCCESS" "JSON 生成成功！"
        else
            log "WARN" "JSON 生成失败！"
        fi

        local api_key
        if api_key=$(extract_api_key "$project_id"); then
            GENERATED_API_KEYS+=("$api_key")
            log "SUCCESS" "AQ. 格式 API 密钥提取成功！"
            success=$((success+1))
        else
            log "WARN" "API 密钥提取失败！"
            failed=$((failed+1))
        fi
    done
    
    echo -e "\n${GREEN}====== 配置操作完成 ======${NC}"
    echo "总计成功: ${success}, 失败: ${failed}"
    display_generated_keys
}

vertex_manage_keys() {
    log "INFO" "====== 本地服务账号密钥管理 ======"
    local key_files=()
    while IFS= read -r -d '' file; do key_files+=("$file"); done < <(find "$KEY_DIR" -name "*.json" -type f -print0 2>/dev/null)
    if [ ${#key_files[@]} -eq 0 ]; then
        log "INFO" "喵酱没找到任何保存在本地的密钥文件喵"
    else
        echo -e "\n本地存放着 ${#key_files[@]} 个 JSON 密钥文件:"
        for ((i=0; i<${#key_files[@]}; i++)); do echo "$((i+1)). ${key_files[i]}"; done
    fi
}

# ===== 主程序 =====
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        Vertex AI 独立密钥管理工具 v${VERSION}               ║"
    echo "║        (支持 AQ. 专属密钥提取 / 全自动项目配置)         ║"
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
        echo "1. 创建新项目并生成双密钥 (JSON + Agent Platform 专属 AQ Key)"
        echo "2. 在现有项目上配置 Vertex AI (支持一键全自动提取)"
        echo "3. 管理本地服务账号密钥 (JSON)"
        echo "0. 退出工具并摸摸喵酱"
        echo
        
        local choice
        read -r -p "请选择 [0-3]: " choice
        case "$choice" in
            1) vertex_create_projects ;;
            2) vertex_configure_existing ;;
            3) vertex_manage_keys ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项喵" ;;
        esac
    done
}

main
