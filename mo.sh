#!/bin/bash
# 优化的 GCP 密钥管理工具 (Vertex + AI Studio 双端融合版)
# 支持智能流浪项目救助、双端密钥分离提取、幽灵记忆库、彻底防403
# 版本: 4.1.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="4.1.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"

# Vertex / Gemini 模式配置
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"
CACHE_FILE="$HOME/.miaojiang_keys.cache"

# ===== 日志与错误处理 =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 所有日志输出重定向到 stderr (>&2)，防止污染函数的 stdout 返回值
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

# ===== 幽灵记忆库功能 (一字不改，原汁原味) =====
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
        delay=$(( attempt * 2 + RANDOM % 2 ))
        sleep $delay
        attempt=$((attempt + 1))
    done
}

require_cmd() { 
    if ! command -v "$1" &>/dev/null; then log "ERROR" "缺少依赖: $1"; exit 1; fi
}

unique_suffix() { 
    if command -v uuidgen &>/dev/null; then uuidgen | tr -d '-' | cut -c1-2 | tr '[:upper:]' '[:lower:]'
    else echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-2; fi
}

new_project_id() {
    local prefix="${1:-$PROJECT_PREFIX}"
    echo "${prefix}-$(unique_suffix)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30
}

check_env() {
    log "INFO" "检查环境配置..."
    require_cmd gcloud
    if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init' 初始化"; exit 1; fi
    touch "$CACHE_FILE" 2>/dev/null || true
}

# ===== Gemini AI Studio 专属提取逻辑 (一字不改) =====
extract_key_safely() {
    local project_id="$1"
    
    # 尝试唤醒服务
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

# ===== Vertex 核心：提取凭证 =====
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
    
    log "INFO" "同步 Vertex IAM 权限..."
    sleep 8

    # 提取 AQ 密钥逻辑
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

    log "INFO" "请求生成 Vertex Agent Platform 专属密钥..."
    local attempt=1
    while [ $attempt -le 4 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            break
        fi
        local err_msg
        err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* ]] || [[ "$err_msg" == *"constraints"* ]]; then
            log "ERROR" "组织策略拦截，启动 Vertex 降级方案..."
            break
        fi
        sleep 5
        attempt=$((attempt+1))
    done

    # 二次查找 (含 AIza 降级)
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

# ===== 双保险开通双端全量 API (彻底消灭 403) =====
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
        "generativelanguage.googleapis.com" # 【重点修复】强行开通 Gemini 权限，防止 AI Studio 出现 403！
    )
    
    log "INFO" "🚀 [主方案] 并发开启 Vertex + Gemini 核心权限..."
    
    local chunk1=("${services[@]:0:12}")
    local chunk2=("${services[@]:12}")
    local main_plan_success=true
    
    if ! gcloud services enable "${chunk1[@]}" --project="$proj" --quiet >/dev/null 2>&1; then main_plan_success=false; fi
    if ! gcloud services enable "${chunk2[@]}" --project="$proj" --quiet >/dev/null 2>&1; then main_plan_success=false; fi

    if [ "$main_plan_success" = false ]; then
        log "WARN" "⚠️ 主方案受阻，启动 [备用方案] 逐个击破模式..."
        local idx=1
        for svc in "${services[@]}"; do
            printf "\r\033[0;36m[%s] [INFO] 凿门中 [%d/%d] 正在死磕: %s\033[0m\033[K" "$(date '+%Y-%m-%d %H:%M:%S')" "$idx" "${#services[@]}" "$svc" >&2
            retry gcloud services enable "$svc" --project="$proj" --quiet >/dev/null 2>&1 || true
            idx=$((idx+1))
        done
        echo >&2
    fi
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

# ===== 功能 3：现有项目双端提取 (智能流浪收容救助版) =====
configure_and_extract_both() {
    log "INFO" "====== 开始智能提取所有双端密钥 (Vertex + AI Studio 融合救助版) ======"
    
    local ALL_AVAILABLE_BIDS=()
    local BID_PROJECT_COUNTS=()
    local BID_DISPLAY_NAMES=()
    
    log "INFO" "喵酱正在分析全局结算账户配额..."
    local open_billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
    if [ -z "$open_billing_accounts" ]; then log "ERROR" "未找到可用的结算账户喵！"; return 1; fi
    
    while IFS=',' read -r bid bname; do
        bid="${bid##*/}"
        ALL_AVAILABLE_BIDS+=("$bid")
        BID_DISPLAY_NAMES+=("$bname")
        local p_count=$(gcloud billing projects list --billing-account="$bid" --format='value(projectId)' 2>/dev/null | wc -l)
        BID_PROJECT_COUNTS+=("$p_count")
    done <<< "$open_billing_accounts"

    local projects
    projects=$(gcloud projects list --format='value(projectId)' --filter="lifecycleState=ACTIVE" 2>/dev/null || echo "")
    if [ -z "$projects" ]; then log "ERROR" "没找到活跃项目喵！"; return 1; fi
    
    local GENERATED_VERTEX_KEYS=()
    local GENERATED_GEMINI_KEYS=()
    local success_count=0
    local skipped_count=0

    for project_id in $projects; do
        [ -z "$project_id" ] && continue
        
        local billing_raw
        billing_raw=$(gcloud billing projects describe "$project_id" --format='csv[no-heading](billingAccountName)' 2>/dev/null || echo "")
        local billing_account_path="${billing_raw%%,*}"
        local billing_id="${billing_account_path##*/}"

        # 【核心流浪救助逻辑】自动寻找空闲账单复活！
        if [ -z "$billing_id" ] || [ "$billing_id" = "" ]; then
            log "WARN" "发现掉签项目 ${project_id}！喵酱尝试流浪救助，寻找空闲账单..."
            local rebind_success=false
            for idx in "${!ALL_AVAILABLE_BIDS[@]}"; do
                local candidate_bid="${ALL_AVAILABLE_BIDS[$idx]}"
                local current_count="${BID_PROJECT_COUNTS[$idx]}"
                if [ "$current_count" -lt 3 ]; then
                    if retry gcloud billing projects link "$project_id" --billing-account="$candidate_bid" --quiet >/dev/null 2>&1; then
                        log "SUCCESS" "重新绑定成功！(救助至 ${BID_DISPLAY_NAMES[$idx]})"
                        billing_id="$candidate_bid"
                        BID_PROJECT_COUNTS[$idx]=$((current_count + 1))
                        rebind_success=true
                        break
                    fi
                fi
            done
            if [ "$rebind_success" = false ]; then
                log "WARN" "配额全满，救助失败，项目彻底断网，含泪跳过喵！"
                skipped_count=$((skipped_count+1))
                continue
            fi
        fi

        if ! verify_billing_status "$project_id"; then
            log "WARN" "计费确认失败，跳过 ${project_id}"
            continue
        fi

        log "INFO" "正在为项目 ${project_id} 开通双端全量权限..."
        enable_essential_services "$project_id"
        
        # 1. 提取 Vertex 密钥
        local v_result
        if v_result=$(setup_and_extract_credentials "$project_id"); then
            if [[ "$v_result" == *KEY:* ]]; then
                local v_key="${v_result#*KEY:}"
                v_key=$(echo "$v_key" | tr -d '\r' | tr -d '\n')
                GENERATED_VERTEX_KEYS+=("$v_key")
                log "SUCCESS" "Vertex 密钥提取成功！"
            fi
        fi

        # 2. 提取 AI Studio (Gemini) 密钥
        local g_key
        if g_key=$(extract_key_safely "$project_id"); then
            GENERATED_GEMINI_KEYS+=("$g_key")
            log "SUCCESS" "AI Studio (Gemini) 密钥提取成功！"
        else
            # 兜底：如果没找到，强行创建一个再提取
            gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --quiet >/dev/null 2>&1 || true
            if g_key=$(extract_key_safely "$project_id"); then
                GENERATED_GEMINI_KEYS+=("$g_key")
                log "SUCCESS" "AI Studio 密钥创建并提取成功！"
            fi
        fi
        
        success_count=$((success_count+1))
    done
    
    echo -e "\n${GREEN}====== 配置与提取操作完成 ======${NC}"
    echo "成功处理项目: ${success_count} | 救助失败跳过: ${skipped_count}"
    
    # 【强迫症狂喜：顺序打印】
    if [ ${#GENERATED_VERTEX_KEYS[@]} -gt 0 ]; then
        echo -e "\n${CYAN}${BOLD}====== 1. 本次提取的 Vertex 密钥 (Agent 优先) ======${NC}"
        for k in "${GENERATED_VERTEX_KEYS[@]}"; do echo "$k"; done
    fi

    if [ ${#GENERATED_GEMINI_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 2. 本次提取的 AI Studio (Gemini) 密钥 ======${NC}"
        for k in "${GENERATED_GEMINI_KEYS[@]}"; do echo "$k"; done
        echo
    fi
}

# ===== 主程序 =====
main() {
    check_env
    while true; do
        echo -e "\n${CYAN}${BOLD}====== 喵酱的双端全能管理器 v${VERSION} ======${NC}"
        echo "1. [经典] 自动创建项目并提取 Vertex 密钥 (需自行选择计费逻辑)"
        echo "2. [新增] 自动创建项目并提取 Vertex 密钥 (保留旧号账单)"
        echo "3. 在现有项目上配置并提取 双端密钥 (Vertex + Gemini 融合, 智能流浪救助)"
        echo "0. 退出工具并摸摸喵酱"
        echo
        
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1) echo "暂不执行，请优先测试选项3喵！" ;;
            2) echo "暂不执行，请优先测试选项3喵！" ;;
            3) configure_and_extract_both ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项喵" ;;
        esac
    done
}

main
