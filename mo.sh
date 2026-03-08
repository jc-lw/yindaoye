#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版)
# 支持自定义项目数量、终端打印 JSON Key 以及一键配置现有项目
# 版本: 2.2.0

# 仅启用 errtrace (-E) 与 nounset (-u)
set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="2.2.0"
LAST_UPDATED="2025-05-23"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
TEMP_DIR=""

# Vertex模式配置
BILLING_ACCOUNT="${BILLING_ACCOUNT:-}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
KEY_DIR="${KEY_DIR:-./keys}"
ENABLE_EXTRA_ROLES=("roles/iam.serviceAccountUser" "roles/aiplatform.user")

# 全局数组，用于收集本次生成的密钥文件路径
GENERATED_JSON_KEYS=()

# ===== 初始化 =====
TEMP_DIR=$(mktemp -d -t gcp_vertex_XXXXXX) || {
    echo "错误：无法创建临时目录"
    exit 1
}

mkdir -p "$KEY_DIR" 2>/dev/null || {
    echo "错误：无法创建密钥目录 $KEY_DIR"
    exit 1
}
chmod 700 "$KEY_DIR" 2>/dev/null || true
SECONDS=0

# ===== 日志与错误处理 =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "INFO")     echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
        "SUCCESS")  echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
        "WARN")     echo -e "${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" >&2 ;;
        "ERROR")    echo -e "${RED}[${timestamp}] [ERROR] ${msg}${NC}" >&2 ;;
        *)          echo "[${timestamp}] [${level}] ${msg}" ;;
    esac
}

handle_error() {
    local exit_code=$?
    local line_no=$1
    case $exit_code in
        141) return 0 ;;
        130) log "INFO" "用户中断操作"; exit 130 ;;
    esac
    log "ERROR" "在第 ${line_no} 行发生错误 (退出码 ${exit_code})"
    if [ $exit_code -gt 1 ]; then
        log "ERROR" "发生严重错误，请检查日志"
        return $exit_code
    else
        log "WARN" "发生非严重错误，继续执行"
        return 0
    fi
}
trap 'handle_error $LINENO' ERR

cleanup_resources() {
    local exit_code=$?
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi
    if [ $exit_code -eq 0 ]; then
        echo -e "\n${CYAN}感谢使用 Vertex AI 密钥管理工具${NC}"
    fi
}
trap cleanup_resources EXIT

# ===== 工具函数 =====
retry() {
    local max_attempts="$MAX_RETRY_ATTEMPTS"
    local attempt=1
    local delay
    
    while [ $attempt -le $max_attempts ]; do
        if "$@"; then
            return 0
        fi
        local error_code=$?
        if [ $attempt -ge $max_attempts ]; then
            log "ERROR" "命令在 ${max_attempts} 次尝试后失败: $*"
            return $error_code
        fi
        delay=$(( attempt * 10 + RANDOM % 5 ))
        log "WARN" "重试 ${attempt}/${max_attempts}: $* (等待 ${delay}s)"
        sleep $delay
        attempt=$((attempt + 1)) || true
    done
}

require_cmd() { 
    if ! command -v "$1" &>/dev/null; then
        log "ERROR" "缺少依赖: $1"
        exit 1
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local resp
    if [ ! -t 0 ]; then
        [[ "$default" =~ ^[Yy]$ ]] && return 0 || return 1
    fi
    if [[ "$default" == "N" ]]; then
        read -r -p "${prompt} [y/N]: " resp || resp="$default"
    else
        read -r -p "${prompt} [Y/n]: " resp || resp="$default"
    fi
    resp=${resp:-$default}
    [[ "$resp" =~ ^[Yy]$ ]]
}

unique_suffix() { 
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr -d '-' | cut -c1-6 | tr '[:upper:]' '[:lower:]'
    else
        echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6
    fi
}

new_project_id() {
    local prefix="${1:-$PROJECT_PREFIX}"
    local suffix
    suffix=$(unique_suffix)
    echo "${prefix}-${suffix}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30
}

is_service_enabled() {
    local proj="$1"
    local svc="$2"
    gcloud services list --enabled --project="$proj" --filter="name:${svc}" --format='value(name)' 2>/dev/null | grep -q .
}

check_env() {
    log "INFO" "检查环境配置..."
    require_cmd gcloud
    if ! gcloud config list account --quiet &>/dev/null; then
        log "ERROR" "请先运行 'gcloud init' 初始化"
        exit 1
    fi
    local active_account
    active_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)
    if [ -z "$active_account" ]; then
        log "ERROR" "请先运行 'gcloud auth login' 登录"
        exit 1
    fi
    log "SUCCESS" "环境检查通过 (账号: ${active_account})"
}

enable_services() {
    local proj="$1"
    shift
    local services=("$@")
    if [ ${#services[@]} -eq 0 ]; then
        services=(
            "aiplatform.googleapis.com"
            "iam.googleapis.com"
            "iamcredentials.googleapis.com"
            "cloudresourcemanager.googleapis.com"
        )
    fi
    log "INFO" "为项目 ${proj} 启用必要的API服务..."
    local failed=0
    for svc in "${services[@]}"; do
        if is_service_enabled "$proj" "$svc"; then
            log "INFO" "服务 ${svc} 已启用"
            continue
        fi
        log "INFO" "启用服务: ${svc}"
        if retry gcloud services enable "$svc" --project="$proj" --quiet; then
            log "SUCCESS" "成功启用服务: ${svc}"
        else
            log "ERROR" "无法启用服务: ${svc}"
            failed=$((failed + 1)) || true
        fi
    done
    if [ $failed -gt 0 ]; then
        log "WARN" "有 ${failed} 个服务启用失败"
        return 1
    fi
    return 0
}

show_progress() {
    local completed="${1:-0}"
    local total="${2:-1}"
    if [ "$total" -le 0 ]; then return; fi
    if [ "$completed" -gt "$total" ]; then completed=$total; fi
    local percent=$((completed * 100 / total))
    local bar_length=50
    local filled=$((percent * bar_length / 100))
    local bar=""
    local i=0
    while [ $i -lt $filled ]; do bar+="█"; i=$((i + 1)) || true; done
    i=$filled
    while [ $i -lt $bar_length ]; do bar+="░"; i=$((i + 1)) || true; done
    printf "\r[%s] %3d%% (%d/%d)" "$bar" "$percent" "$completed" "$total"
    if [ "$completed" -eq "$total" ]; then echo; fi
}

display_generated_keys() {
    if [ ${#GENERATED_JSON_KEYS[@]} -eq 0 ]; then
        return 0
    fi
    
    echo -e "\n${CYAN}${BOLD}====== 本次提取的 Vertex AI 密钥 (JSON) ======${NC}"
    echo -e "${YELLOW}提示: Vertex AI 必须使用完整的 JSON 作为密钥认证。${NC}\n"
    
    for key_path in "${GENERATED_JSON_KEYS[@]}"; do
        if [ -f "$key_path" ]; then
            echo -e "${GREEN}▶ 来源文件: ${key_path}${NC}"
            echo -e "--------------------------------------------------"
            cat "$key_path"
            echo -e "\n--------------------------------------------------\n"
        fi
    done
}

# ===== Vertex AI 核心功能 =====

vertex_setup_service_account() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        log "INFO" "创建服务账号..."
        if ! retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
            --display-name="Vertex AI Service Account" \
            --project="$project_id" --quiet; then
            log "ERROR" "创建服务账号失败"
            return 1
        fi
    else
        log "INFO" "服务账号已存在"
    fi
    
    local roles=(
        "roles/aiplatform.admin"
        "roles/iam.serviceAccountUser"
        "roles/iam.serviceAccountTokenCreator"
        "roles/aiplatform.user"
    )
    
    log "INFO" "分配IAM角色..."
    for role in "${roles[@]}"; do
        if retry gcloud projects add-iam-policy-binding "$project_id" \
            --member="serviceAccount:${sa_email}" \
            --role="$role" \
            --quiet &>/dev/null; then
            log "SUCCESS" "授予角色: ${role}"
        else
            log "WARN" "授予角色失败: ${role}"
        fi
    done
    
    log "INFO" "生成服务账号密钥..."
    local key_file="${KEY_DIR}/${project_id}-${SERVICE_ACCOUNT_NAME}-$(date +%Y%m%d-%H%M%S).json"
    
    if retry gcloud iam service-accounts keys create "$key_file" \
        --iam-account="$sa_email" \
        --project="$project_id" \
        --quiet; then
        chmod 600 "$key_file"
        log "SUCCESS" "密钥已保存: ${key_file}"
        
        # 将生成的密钥路径加入全局数组，以便后续打印
        GENERATED_JSON_KEYS+=("$key_file")
        return 0
    else
        log "ERROR" "生成密钥失败"
        return 1
    fi
}

vertex_create_projects() {
    log "INFO" "====== 创建新项目并生成密钥 ======"
    GENERATED_JSON_KEYS=()
    
    local existing_projects
    existing_projects=$(gcloud projects list --filter="billingAccountName:billingAccounts/${BILLING_ACCOUNT}" --format='value(projectId)' 2>/dev/null | wc -l)
    log "INFO" "当前结算账户已有 ${existing_projects} 个项目"
    
    local num_projects
    read -r -p "请输入要创建的项目数量 (例如 3, 5, 8 等): " num_projects
    
    if ! [[ "$num_projects" =~ ^[0-9]+$ ]] || [ "$num_projects" -lt 1 ]; then
        log "ERROR" "无效的项目数量"
        return 1
    fi
    
    local project_prefix
    read -r -p "请输入项目前缀 (默认: vertex): " project_prefix
    project_prefix=${project_prefix:-vertex}
    
    echo -e "\n${YELLOW}即将创建 ${num_projects} 个项目${NC}"
    echo "项目前缀: ${project_prefix}"
    echo "结算账户: ${BILLING_ACCOUNT}"
    echo
    
    if ! ask_yes_no "确认继续？" "N"; then
        log "INFO" "操作已取消"
        return 1
    fi
    
    log "INFO" "开始创建项目..."
    local success=0
    local failed=0
    local i=1
    
    while [ $i -le $num_projects ]; do
        local project_id
        project_id=$(new_project_id "$project_prefix")
        
        log "INFO" "[${i}/${num_projects}] 创建项目: ${project_id}"
        
        if ! retry gcloud projects create "$project_id" --quiet; then
            log "ERROR" "创建项目失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        log "INFO" "关联结算账户..."
        if ! retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet; then
            log "ERROR" "关联结算账户失败: ${project_id}"
            gcloud projects delete "$project_id" --quiet 2>/dev/null
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        log "INFO" "启用必要的API..."
        if ! enable_services "$project_id"; then
            log "ERROR" "启用API失败: ${project_id}"
            failed=$((failed + 1)) || true
            show_progress "$i" "$num_projects"
            i=$((i + 1)) || true
            continue
        fi
        
        log "INFO" "配置服务账号..."
        if vertex_setup_service_account "$project_id"; then
            log "SUCCESS" "成功配置项目: ${project_id}"
            success=$((success + 1)) || true
        else
            log "ERROR" "配置服务账号失败: ${project_id}"
            failed=$((failed + 1)) || true
        fi
        
        show_progress "$i" "$num_projects"
        sleep 2
        i=$((i + 1)) || true
    done
    
    echo -e "\n${GREEN}创建操作完成！${NC}"
    echo "成功: ${success}, 失败: ${failed}"
    
    # 打印本次生成的所有 JSON 密钥
    display_generated_keys
}

vertex_configure_existing() {
    log "INFO" "====== 在现有项目上配置 Vertex AI ======"
    GENERATED_JSON_KEYS=()
    
    log "INFO" "获取项目列表..."
    local all_projects
    all_projects=$(gcloud projects list --format='value(projectId)' --filter="lifecycleState=ACTIVE" 2>/dev/null || echo "")
    
    local projects=""
    while IFS= read -r project_id; do
        if [ -n "$project_id" ]; then
            local billing_info
            billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
            if [ -n "$billing_info" ] && [[ "$billing_info" == *"${BILLING_ACCOUNT}"* ]]; then
                projects="${projects}${projects:+$'\n'}${project_id}"
            fi
        fi
    done <<< "$all_projects"
    
    local project_array=()
    if [ -n "$projects" ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then project_array+=("$line"); fi
        done <<< "$projects"
    fi
    
    local total=${#project_array[@]}
    
    if [ "$total" -eq 0 ]; then
        log "WARN" "未找到与当前结算账户关联的项目"
        echo -e "\n${YELLOW}请选择操作:${NC}"
        echo "1. 显示所有活跃项目 (尝试强行关联账单)"
        echo "2. 返回主菜单"
        local list_choice
        read -r -p "请选择 [1-2]: " list_choice
        if [ "$list_choice" = "1" ]; then
            while IFS= read -r line; do
                if [ -n "$line" ]; then project_array+=("$line"); fi
            done <<< "$all_projects"
            total=${#project_array[@]}
        else
            return 0
        fi
    fi
    
    echo -e "\n项目列表:"
    for ((i=0; i<total && i<20; i++)); do
        local billing_info
        billing_info=$(gcloud billing projects describe "${project_array[i]}" --format='value(billingAccountName)' 2>/dev/null || echo "")
        local status=""
        if [ -n "$billing_info" ] && [[ "$billing_info" == *"${BILLING_ACCOUNT}"* ]]; then
            status="(已关联当前结算账户)"
        elif [ -n "$billing_info" ]; then
            status="(关联了其他结算账户)"
        else
            status="(未关联结算)"
        fi
        echo "$((i+1)). ${project_array[i]} ${status}"
    done
    
    if [ "$total" -gt 20 ]; then
        echo "... 还有 $((total-20)) 个项目"
    fi
    
    local selected_projects=()
    
    # 新增：询问是否一键配置
    echo ""
    if ask_yes_no "是否一键在现有项目中配置 Vertex项目 (自动选中所有已关联当前结算账户的项目)？" "N"; then
        log "INFO" "正在筛选已关联当前结算账户的项目..."
        for proj in "${project_array[@]}"; do
            local b_info
            b_info=$(gcloud billing projects describe "$proj" --format='value(billingAccountName)' 2>/dev/null || echo "")
            if [ -n "$b_info" ] && [[ "$b_info" == *"${BILLING_ACCOUNT}"* ]]; then
                selected_projects+=("$proj")
            fi
        done
        log "INFO" "自动选中了 ${#selected_projects[@]} 个已关联结算的项目。"
    else
        read -r -p "请输入项目编号（多个用空格分隔，输入 'all' 选择全部显示项目）: " -a numbers
        
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
    
    if [ ${#selected_projects[@]} -eq 0 ]; then
        log "ERROR" "未选择任何项目，操作已取消。"
        return 1
    fi
    
    echo -e "\n${YELLOW}将为 ${#selected_projects[@]} 个项目配置 Vertex AI${NC}"
    if ! ask_yes_no "确认继续？" "N"; then return 1; fi
    
    local success=0
    local failed=0
    local current=0
    
    for project_id in "${selected_projects[@]}"; do
        current=$((current + 1)) || true
        log "INFO" "[${current}/${#selected_projects[@]}] 处理项目: ${project_id}"
        
        local billing_info
        billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
        
        if [ -z "$billing_info" ]; then
            log "WARN" "项目未关联结算账户，尝试关联..."
            if ! retry gcloud billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet; then
                log "ERROR" "关联结算账户失败: ${project_id}"
                failed=$((failed + 1)) || true
                show_progress "$current" "${#selected_projects[@]}"
                continue
            fi
        fi
        
        log "INFO" "启用必要的API..."
        if ! enable_services "$project_id"; then
            failed=$((failed + 1)) || true
            show_progress "$current" "${#selected_projects[@]}"
            continue
        fi
        
        log "INFO" "配置服务账号..."
        if vertex_setup_service_account "$project_id"; then
            success=$((success + 1)) || true
        else
            failed=$((failed + 1)) || true
        fi
        show_progress "$current" "${#selected_projects[@]}"
    done
    
    echo -e "\n${GREEN}配置操作完成！${NC}"
    echo "成功: ${success}, 失败: ${failed}"
    
    # 打印本次生成的所有 JSON 密钥
    display_generated_keys
}

vertex_manage_keys() {
    log "INFO" "====== 管理服务账号密钥 ======"
    echo "请选择操作:"
    echo "1. 列出本地保存的所有服务账号密钥"
    echo "0. 返回"
    echo
    local choice
    read -r -p "请选择 [0-1]: " choice
    case "$choice" in
        1) 
            local key_files=()
            while IFS= read -r -d '' file; do key_files+=("$file"); done < <(find "$KEY_DIR" -name "*.json" -type f -print0 2>/dev/null)
            if [ ${#key_files[@]} -eq 0 ]; then
                log "INFO" "未找到任何密钥文件"
            else
                echo -e "\n找到 ${#key_files[@]} 个密钥文件:"
                for ((i=0; i<${#key_files[@]}; i++)); do
                    echo "$((i+1)). ${key_files[i]}"
                done
            fi
            ;;
        0) return 0 ;;
        *) log "ERROR" "无效选项"; return 1 ;;
    esac
}

# ===== 主程序 =====
main() {
    echo -e "${CYAN}${BOLD}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║       Vertex AI 独立密钥管理工具 v${VERSION}               ║"
    echo "║       (支持终端打印 JSON Key / 自定义项目数量)          ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_env
    
    echo -e "${YELLOW}警告: Vertex AI 需要结算账户，会产生实际费用！${NC}\n"
    
    log "INFO" "检查结算账户..."
    local billing_accounts
    billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name,displayName)' 2>/dev/null || echo "")
    
    if [ -z "$billing_accounts" ]; then
        log "ERROR" "未找到任何开放的结算账户"
        echo -e "${RED}Vertex AI 需要有效的结算账户才能使用${NC}"
        exit 1
    fi
    
    local billing_array=()
    while IFS=$'\t' read -r id name; do
        billing_array+=("${id##*/} - $name")
    done <<< "$billing_accounts"
    local billing_count=${#billing_array[@]}
    
    if [ "$billing_count" -eq 1 ]; then
        BILLING_ACCOUNT="${billing_array[0]%% - *}"
        log "INFO" "使用结算账户: ${BILLING_ACCOUNT}"
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
        echo "1. 创建新项目并生成密钥"
        echo "2. 在现有项目上配置 Vertex AI"
        echo "3. 管理服务账号密钥"
        echo "0. 退出工具"
        echo
        
        local choice
        read -r -p "请选择 [0-3]: " choice
        
        case "$choice" in
            1) vertex_create_projects ;;
            2) vertex_configure_existing ;;
            3) vertex_manage_keys ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项" ;;
        esac
    done
}

main
