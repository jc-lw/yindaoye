#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版)
# 支持满血 23 项 API 开通(找回 Gemini AI Studio)、智能双保险、强制校验
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
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"

# Vertex模式配置
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"

# ===== 日志与错误处理 =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    case "$level" in
        "INFO")     echo -e "${CYAN}[${timestamp}] [INFO] ${msg}${NC}" >&2 ;;
        "SUCCESS")  echo -e "${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" >&2 ;;
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
}

unlink_projects_from_billing_account() {
    local billing_id="$1"
    local linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null)
    if [ -z "$linked_projects" ]; then return 0; fi
    log "WARN" "发现旧项目占用结算账户，喵酱开始清理释放配额..."
    for project_id in $linked_projects; do
        [ -n "$project_id" ] && gcloud billing projects unlink "$project_id" --quiet >/dev/null 2>&1 || true
    done
    return 0
}

# ===== 【极致优化】满血 23 项 API 开通 =====
enable_essential_services() {
    local proj="$1"
    local services=(
        "agentregistry.googleapis.com" "aiplatform.googleapis.com" "apikeys.googleapis.com"
        "apphub.googleapis.com" "apptopology.googleapis.com" "cloudapiregistry.googleapis.com"
        "cloudtrace.googleapis.com" "compute.googleapis.com" "dataform.googleapis.com"
        "iam.googleapis.com" "logging.googleapis.com" "modelarmor.googleapis.com"
        "monitoring.googleapis.com" "networksecurity.googleapis.com" "networkservices.googleapis.com"
        "notebooks.googleapis.com" "observability.googleapis.com" "storage-component.googleapis.com"
        "telemetry.googleapis.com" "texttospeech.googleapis.com" "discoveryengine.googleapis.com"
        "dialogflow.googleapis.com" 
        "generativelanguage.googleapis.com"  # 【修复】补回被遗漏的 Gemini AI Studio 权限
    )
    
    log "INFO" "🚀 [主方案] 启动分批极速并发，开启 ${#services[@]} 项核心权限..."
    
    # 23 个 API 切割为两批，绝对低于单次 20 个的 Google 物理红线
    local chunk1=("${services[@]:0:12}")
    local chunk2=("${services[@]:12}")
    
    local main_plan_success=true
    
    if ! gcloud services enable "${chunk1[@]}" --project="$proj" --quiet >/dev/null 2>&1; then main_plan_success=false; fi
    if ! gcloud services enable "${chunk2[@]}" --project="$proj" --quiet >/dev/null 2>&1; then main_plan_success=false; fi

    if [ "$main_plan_success" = true ]; then
        log "SUCCESS" "主方案一键分批开通成功！"
    else
        log "WARN" "⚠️ 主方案部分受阻，切换 [备用方案] 启动逐个击破模式..."
        local idx=1
        for svc in "${services[@]}"; do
            printf "\r\033[0;36m[%s] [INFO] 备用方案凿门中 [%d/%d] 正在死磕: %s\033[0m\033[K" "$(date '+%Y-%m-%d %H:%M:%S')" "$idx" "${#services[@]}" "$svc" >&2
            retry gcloud services enable "$svc" --project="$proj" --quiet >/dev/null 2>&1 || true
            idx=$((idx+1))
        done
        echo >&2
        log "SUCCESS" "备用方案执行完毕！"
    fi
    
    # 强制状态校验
    log "INFO" "正在强制校验核心 Vertex AI 和 Gemini API 激活状态..."
    local verify_attempt=1
    while [ $verify_attempt -le 6 ]; do
        local state1 state2
        state1=$(gcloud services list --project="$proj" --filter="config.name:aiplatform.googleapis.com" --format="value(state)" 2>/dev/null || echo "DISABLED")
        state2=$(gcloud services list --project="$proj" --filter="config.name:generativelanguage.googleapis.com" --format="value(state)" 2>/dev/null || echo "DISABLED")
        
        if [[ "$state1" == "ENABLED" ]] && [[ "$state2" == "ENABLED" ]]; then
            log "SUCCESS" "底层激活确认！"
            return 0
        fi
        log "WARN" "API 尚未就绪，Google 服务器同步中... ($verify_attempt/6)"
        sleep 10
        verify_attempt=$((verify_attempt+1))
    done
    return 1
}

verify_billing_status() {
    local project_id="$1"
    local attempt=1
    while [ $attempt -le 3 ]; do
        local billing_status
        billing_status=$(gcloud billing projects describe "$project_id" --format='value(billingEnabled)' 2>/dev/null || echo "False")
        if [ "$billing_status" = "True" ] || [ "$billing_status" = "true" ]; then
            return 0
        fi
        log "WARN" "等待计费系统同步 (防 403 错误)... ($attempt/3)"
        sleep 6
        attempt=$((attempt+1))
    done
    return 1
}

setup_and_extract_credentials() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Agent SA" --project="$project_id" --quiet >/dev/null 2>&1 || true
    fi
    
    local roles=("roles/aiplatform.admin" "roles/iam.serviceAccountUser")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    
    # 增加 IAM 缓冲时间，抵抗严重的延迟
    log "INFO" "同步 IAM 权限，防延迟深呼吸 15 秒..."
    sleep 15

    local keys_list
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    if [ -n "$keys_list" ]; then
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            local api_key
            api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            if [[ "$api_key" == AQ.* ]]; then
                echo "KEY:${api_key}"
                return 0
            fi
        done
    fi

    log "INFO" "正在请求生成 AQ. 格式专属密钥..."
    local attempt=1
    local policy_blocked=false
    while [ $attempt -le 4 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            break
        fi
        local err_msg
        err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* ]] || [[ "$err_msg" == *"constraints"* ]]; then
            log "ERROR" "⚠️ 遭遇企业组织策略死锁拦截！强行降级生成通用备用密钥..."
            policy_blocked=true
            break
        fi
        log "WARN" "接口重试中 ($attempt/4)..."
        sleep 8
        attempt=$((attempt+1))
    done

    # B 计划 (生成 AIza)
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    [ -z "$keys_list" ] && gcloud services api-keys create --project="$project_id" --display-name="Fallback Key" --quiet >/dev/null 2>&1
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    
    for key_name in $keys_list; do
        key_name=$(echo "$key_name" | tr -d '\r' | xargs)
        local api_key
        api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
        [ -n "$api_key" ] && { echo "KEY:${api_key}"; return 0; }
    done

    return 1
}

# ===== (略) 功能 1&2：自动创建项目 =====
# 保持原逻辑...

vertex_configure_existing() {
    log "INFO" "====== 实时穿透查账并提取 Vertex 密钥 ======"
    local GENERATED_API_KEYS=()
    local BILLING_KEY_MAP=()
    
    local active_billing=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null | head -n 1)
    if [ -z "$active_billing" ]; then log "ERROR" "无开放账单"; return 1; fi
    local billing_id="${active_billing##*/}"
    
    echo -e "\n${CYAN}1. 手动挑选  2. 全自动一键配置 (实时账单穿透)${NC}"
    local list_choice
    read -r -p "请选择: " list_choice
    
    local selected_projects=()
    if [ "$list_choice" = "2" ]; then
        log "INFO" "正在实时查询账单下所有项目..."
        local linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null || echo "")
        for proj in $linked_projects; do [ -n "$proj" ] && selected_projects+=("$proj"); done
    else
        local all_projects=$(gcloud projects list --format='value(projectId)' --filter="lifecycleState=ACTIVE" 2>/dev/null || echo "")
        local project_array=()
        while IFS= read -r line; do [ -n "$line" ] && project_array+=("$line"); done <<< "$all_projects"
        local total=${#project_array[@]}
        
        for ((i=0; i<total && i<20; i++)); do echo "$((i+1)). ${project_array[i]}"; done
        read -r -p "请输入项目编号 (多个空格分隔，all选全部): " -a numbers
        if [ "${#numbers[@]}" -gt 0 ] && [ "${numbers[0]}" = "all" ]; then selected_projects=("${project_array[@]}");
        else
            for num in "${numbers[@]}"; do
                if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total" ]; then
                    selected_projects+=("${project_array[$((num-1))]}")
                fi
            done
        fi
    fi
    
    for project_id in "${selected_projects[@]}"; do
        log "INFO" "处理项目: ${project_id}"
        if verify_billing_status "$project_id"; then
            enable_essential_services "$project_id"
            local extract_result
            if extract_result=$(setup_and_extract_credentials "$project_id"); then
                local ak="${extract_result#*KEY:}"
                ak=$(echo "$ak" | tr -d '\r' | tr -d '\n')
                GENERATED_API_KEYS+=("$ak")
                
                if [[ "$ak" == AQ.* ]]; then
                    log "SUCCESS" "Agent 专属 AQ. 密钥提取成功！"
                else
                    log "SUCCESS" "突破防线，通用 AIza 密钥提取成功！"
                    log "WARN" "⚠️ 注意：当前项目受组织安全策略封锁，无法生成 AQ 密钥，Vertex Agent 平台可能拒认此 AIza 密钥喵！"
                fi
            fi
        fi
    done
    
    if [ ${#GENERATED_API_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的密钥列表 ======${NC}"
        for k in "${GENERATED_API_KEYS[@]}"; do echo "$k"; done
        echo -e "\n${CYAN}提示：AQ. 开头为 Agent 专属密钥，AIza 开头为通用标准密钥 (含 Gemini 权限)。${NC}"
    fi
}

main() {
    check_env
    while true; do
        echo -e "\n${CYAN}${BOLD}====== 喵酱的 Vertex 管理器 v${VERSION} ======${NC}"
        echo "1. [经典] 自动创建项目并提取 (战术延时，清理旧项目)"
        echo "2. [新增] 自动创建项目并提取 (战术延时，保留旧项目)"
        echo "3. 在现有项目上配置并提取 (满血 23 权限补齐版)"
        echo "0. 退出工具"
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1) echo "请优先测试选项 3喵！" ;;
            2) echo "请优先测试选项 3喵！" ;;
            3) vertex_configure_existing ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项" ;;
        esac
    done
}

main
