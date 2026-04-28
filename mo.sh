#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版)
# 支持极速配置、纯 AQ. 专属密钥提取、防 403 计费延迟同步
# 版本: 2.9.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="2.9.0"
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
        delay=$(( attempt * 2 + RANDOM % 2 ))
        sleep $delay
        attempt=$((attempt + 1))
    done
}

require_cmd() { 
    if ! command -v "$1" &>/dev/null; then log "ERROR" "缺少依赖: $1"; exit 1; fi
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

# ===== 极速开通核心 API (修复缓慢问题) =====
enable_essential_services() {
    local proj="$1"
    # 剔除冗余，仅保留 Vertex AI 界面提示需要的核心权限
    local services=(
        "aiplatform.googleapis.com"
        "apikeys.googleapis.com"
    )
    log "INFO" "正在极速开通 Vertex AI 核心权限..."
    for svc in "${services[@]}"; do
        retry gcloud services enable "$svc" --project="$proj" --quiet >/dev/null 2>&1 || true
    done
}

# ===== 核心：提取 AQ. 格式专属密钥 =====
setup_and_extract_aq_key() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    # 1. 创建服务账号
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Agent SA" --project="$project_id" --quiet >/dev/null 2>&1 || true
    fi
    
    # 2. 极简赋权
    local roles=("roles/aiplatform.admin" "roles/iam.serviceAccountUser")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    sleep 3

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
                echo "AQ_KEY:${api_key}"
                return 0
            fi
        done
    fi

    # 4. 尝试生成 AQ 密钥
    log "INFO" "正在请求生成 AQ. 格式专属密钥..."
    local attempt=1
    local create_success=false
    
    while [ $attempt -le 3 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            create_success=true
            break
        fi
        
        local err_msg
        err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        
        # 破壁机制：精准识别安全策略拦截
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* ]]; then
            log "ERROR" "⚠️ 检测到安全策略拦截！无法生成 API 金钥！"
            break
        fi
        
        sleep 5
        attempt=$((attempt+1))
    done

    if [ "$create_success" = true ]; then
        keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
        if [ -n "$keys_list" ]; then
            for key_name in $keys_list; do
                key_name=$(echo "$key_name" | tr -d '\r' | xargs)
                [ -z "$key_name" ] && continue
                local api_key
                api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
                if [[ "$api_key" == AQ.* ]]; then
                    echo "AQ_KEY:${api_key}"
                    return 0
                fi
            done
        fi
    fi

    # 5. B计划（降级生成 JSON）
    if [ "$create_success" = false ]; then
        log "INFO" "🚀 启动降级：改用 ADC (JSON 服务账号密钥)..."
        local key_file="/tmp/${project_id}-ADC-$(date +%Y%m%d%H%M%S).json"
        if retry gcloud iam service-accounts keys create "$key_file" --iam-account="$sa_email" --project="$project_id" --quiet >/dev/null 2>&1; then
            echo "JSON_FILE:${key_file}"
            return 0
        fi
    fi

    return 1
}

# ===== 坚固的计费检查 (防止 403) =====
verify_billing_status() {
    local project_id="$1"
    local attempt=1
    while [ $attempt -le 3 ]; do
        local billing_status
        billing_status=$(gcloud billing projects describe "$project_id" --format='value(billingEnabled)' 2>/dev/null || echo "False")
        if [ "$billing_status" = "True" ] || [ "$billing_status" = "true" ]; then
            return 0
        fi
        log "WARN" "等待计费系统同步至全球节点 (防 403 错误)... ($attempt/3)"
        sleep 6
        attempt=$((attempt+1))
    done
    return 1
}

display_generated_keys() {
    if [ ${#GENERATED_API_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的 Agent Platform API 密钥 (AQ. 格式) ======${NC}"
        for k in "${GENERATED_API_KEYS[@]}"; do echo "$k"; done
        echo
    fi

    if [ ${#GENERATED_JSON_KEYS[@]} -gt 0 ]; then
        echo -e "\n${CYAN}${BOLD}====== 🚨 组织拦截下的破壁凭证: ADC (JSON) ======${NC}"
        for key_path in "${GENERATED_JSON_KEYS[@]}"; do
            if [ -f "$key_path" ]; then
                echo -e "${GREEN}▶ 项目密钥 JSON 内容：${NC}"
                echo -e "--------------------------------------------------"
                cat "$key_path"
                echo -e "\n--------------------------------------------------\n"
            fi
        done
    fi
}

# ===== 功能 2：一键配置现有项目 =====
vertex_configure_existing() {
    log "INFO" "====== 在现有项目上极速配置 Vertex AI 并提取凭证 ======"
    local GENERATED_API_KEYS=()
    local GENERATED_JSON_KEYS=()
    
    local all_projects
    all_projects=$(gcloud projects list --format='value(projectId)' --filter="lifecycleState=ACTIVE" 2>/dev/null || echo "")
    if [ -z "$all_projects" ]; then log "ERROR" "没找到活跃项目喵"; return 1; fi

    local project_array=()
    while IFS= read -r line; do [ -n "$line" ] && project_array+=("$line"); done <<< "$all_projects"
    local total=${#project_array[@]}
    local selected_projects=()
    
    echo -e "\n${CYAN}主人想怎么配置现有项目呢？${NC}"
    echo "1. 手动挑选项目配置"
    echo "2. 全自动一键配置 (自动选中所有关联当前账单的项目，包括默认项目)"
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
        
        # 核心防 403 机制
        if ! verify_billing_status "$project_id"; then
            log "WARN" "此项目计费未生效或被锁定，强行提取会导致 403，跳过喵！"
            failed=$((failed+1))
            continue
        fi
        
        enable_essential_services "$project_id"
        
        local extract_result
        if extract_result=$(setup_and_extract_credentials "$project_id"); then
            if [[ "$extract_result" == AQ_KEY:* ]]; then
                local ak="${extract_result#AQ_KEY:}"
                GENERATED_API_KEYS+=("$ak")
                log "SUCCESS" "AQ. 格式 API 密钥提取成功！"
            elif [[ "$extract_result" == JSON_FILE:* ]]; then
                local jf="${extract_result#JSON_FILE:}"
                GENERATED_JSON_KEYS+=("$jf")
                log "SUCCESS" "突破组织封锁，ADC (JSON) 凭证生成成功！"
            fi
            success=$((success+1))
        else
            log "WARN" "凭证提取完全失败！"
            failed=$((failed+1))
        fi
    done
    
    echo -e "\n${GREEN}====== 配置操作完成 ======${NC}"
    echo "总计成功: ${success}, 失败: ${failed}"
    display_generated_keys
}

# ===== 主程序 =====
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║        Vertex AI 独立密钥管理工具 v${VERSION}               ║"
    echo "║        (极速开通防 403 延迟版 / 纯 AQ. 格式提取)        ║"
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
        echo "2. 在现有项目上极速配置并提取密钥 (防 403 延迟)"
        echo "0. 退出工具并摸摸喵酱"
        echo
        
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            2) vertex_configure_existing ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项喵" ;;
        esac
    done
}

main
