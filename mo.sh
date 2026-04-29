#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版)
# 支持满血 23 项 API 开通、双端双持提取 (强制生成 AQ 和 AIza 两把钥匙)
# 版本: 3.9.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="3.9.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-vertex}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"

# Vertex模式配置
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-vertex-admin}"

# ===== 日志与错误处理 =====
log() { 
    local level="${1:-INFO}"
    local msg="${2:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 日志输出至 stderr，确保 stdout 只有干净的 KEY
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

# ===== 满血 23 项 API 开通 =====
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
        "generativelanguage.googleapis.com"  # Gemini AI Studio 核心权限
    )
    
    log "INFO" "🚀 [主方案] 启动分批极速并发，开启 23 项核心权限..."
    
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

# ===== 【核心大改】双端双持提取：强行提取两把钥匙 =====
setup_and_extract_credentials() {
    local project_id="$1"
    local sa_email="${SERVICE_ACCOUNT_NAME}@${project_id}.iam.gserviceaccount.com"
    local found_aq=""
    local found_aiza=""
    
    # === 第一步：设置服务账号 (为生成 AQ 做准备) ===
    if ! gcloud iam service-accounts describe "$sa_email" --project="$project_id" &>/dev/null; then
        retry gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" --display-name="Vertex Agent SA" --project="$project_id" --quiet >/dev/null 2>&1 || true
    fi
    
    local roles=("roles/aiplatform.admin" "roles/iam.serviceAccountUser")
    for role in "${roles[@]}"; do
        retry gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:${sa_email}" --role="$role" --quiet >/dev/null 2>&1 || true
    done
    
    log "INFO" "同步 IAM 权限，防延迟深呼吸 15 秒..."
    sleep 15

    # === 第二步：强行生成两把钥匙 (如果不存在的话) ===
    log "INFO" "正在向 Google 强行索要双端钥匙 (Agent + AI Studio)..."
    
    # 1. 索要 Agent 的 AQ 密钥 (绑定 SA)
    local create_err
    if ! create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
        local err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* ]] || [[ "$err_msg" == *"constraints"* ]]; then
            log "ERROR" "⚠️ 组织策略拦截了 AQ 密钥生成！仅能提供 AI Studio 的 AIza 密钥喵。"
        fi
    fi

    # 2. 索要 AI Studio 的标准 AIza 密钥
    gcloud services api-keys create --project="$project_id" --display-name="Gemini Studio Key" --quiet >/dev/null 2>&1 || true

    # === 第三步：彻底搜查并提取这两把钥匙 ===
    local keys_list
    keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
    
    if [ -n "$keys_list" ]; then
        for key_name in $keys_list; do
            key_name=$(echo "$key_name" | tr -d '\r' | xargs)
            local api_key
            api_key=$(gcloud services api-keys get-key-string "$key_name" --format='value(keyString)' 2>/dev/null | tr -d '\r' | xargs)
            
            if [[ "$api_key" == AQ.* ]] && [ -z "$found_aq" ]; then
                found_aq="$api_key"
            elif [[ "$api_key" == AIza* ]] && [ -z "$found_aiza" ]; then
                found_aiza="$api_key"
            fi
        done
    fi

    # === 第四步：输出结果 ===
    local output=""
    if [ -n "$found_aq" ]; then
        echo "AQ_KEY:${found_aq}"
        output="1"
    fi
    if [ -n "$found_aiza" ]; then
        echo "AIZA_KEY:${found_aiza}"
        output="1"
    fi

    if [ -n "$output" ]; then
        return 0
    else
        return 1
    fi
}

# ===== 功能 1 & 2：自动创建项目 =====
vertex_create_projects() {
    local keep_billing="${1:-false}"
    
    local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
    if [ -z "$billing_raw" ]; then log "ERROR" "未找到结算账户"; return 1; fi

    SELECTED_BILLING_IDS=()
    SELECTED_BILLING_NAMES=()

    log "INFO" "🐱 开启【全自动模式】：每个结算账户创建 3 个项目"
    while IFS=',' read -r bid bname; do
        bid="${bid##*/}"; SELECTED_BILLING_IDS+=("$bid"); SELECTED_BILLING_NAMES+=("$bname")
    done <<< "$billing_raw"
    local num_per_billing=3

    local total_projects=$(( num_per_billing * ${#SELECTED_BILLING_IDS[@]} ))
    local total_success=0; local total_failed=0; local total_skipped=0
    
    local GENERATED_AQ_KEYS=()
    local GENERATED_AIZA_KEYS=()

    if [ "$keep_billing" = "true" ]; then log "INFO" "====== 自动创建并提取 (保留旧结算绑定) ======"
    else log "INFO" "====== 自动创建并提取 (释放旧配额) ======"; fi

    for billing_idx in "${!SELECTED_BILLING_IDS[@]}"; do
        local TARGET_BID="${SELECTED_BILLING_IDS[$billing_idx]}"
        local billing_name="${SELECTED_BILLING_NAMES[$billing_idx]}"

        echo -e "\n${CYAN}${BOLD}────── 结算账户 $((billing_idx+1))/${#SELECTED_BILLING_IDS[@]}: ${billing_name} (${TARGET_BID}) ──────${NC}"

        if [ "$keep_billing" = "false" ]; then 
            unlink_projects_from_billing_account "$TARGET_BID"
            log "INFO" "已清理旧项目账单，战术潜伏 5 秒以消除 AUP 数据库缓存喵..."
            sleep 5
        fi

        local success=0; local failed=0; local skipped=0; local i=1
        while [ $i -le "$num_per_billing" ]; do
            local global_idx=$(( billing_idx * num_per_billing + i ))
            local project_id=$(new_project_id)
            
            log "INFO" "[${global_idx}/${total_projects}] 正在处理项目: ${project_id}"
            
            gcloud projects create "$project_id" --quiet >/dev/null 2>&1 || { failed=$((failed+1)); i=$((i+1)); continue; }
            gcloud billing projects link "$project_id" --billing-account="$TARGET_BID" --quiet >/dev/null 2>&1 || true
            
            if ! verify_billing_status "$project_id"; then
                log "WARN" "项目 ${project_id} 计费未生效，跳过提取喵！"
                skipped=$((skipped+1)); i=$((i+1)); continue
            fi

            log "INFO" "账单绑定确认！开启 20 秒安全静默期，避开 GCP AUP 风控雷达..."
            sleep 20
            
            enable_essential_services "$project_id"
            
            local extract_result
            if extract_result=$(setup_and_extract_credentials "$project_id"); then
                local has_key=false
                while IFS= read -r line; do
                    if [[ "$line" == AQ_KEY:* ]]; then
                        GENERATED_AQ_KEYS+=("${line#AQ_KEY:}")
                        has_key=true
                    elif [[ "$line" == AIZA_KEY:* ]]; then
                        GENERATED_AIZA_KEYS+=("${line#AIZA_KEY:}")
                        has_key=true
                    fi
                done <<< "$extract_result"

                if [ "$has_key" = true ]; then
                    log "SUCCESS" "双端密钥榨取完毕！"
                    success=$((success+1))
                else
                    log "WARN" "未提取到任何密钥！"
                    failed=$((failed+1))
                fi
            else
                log "WARN" "提取流程失败！"
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
    
    if [ ${#GENERATED_AQ_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的 Vertex Agent 密钥 (AQ 格式) ======${NC}"
        for k in "${GENERATED_AQ_KEYS[@]}"; do echo "$k"; done
    fi
    if [ ${#GENERATED_AIZA_KEYS[@]} -gt 0 ]; then
        echo -e "\n${GREEN}${BOLD}====== 本次提取的 Gemini AI Studio 密钥 (AIza 格式) ======${NC}"
        for k in "${GENERATED_AIZA_KEYS[@]}"; do echo "$k"; done
        echo
    fi
}

# ===== 功能 3：一键配置现有项目 (实时查账单引擎) =====
vertex_configure_existing() {
    log "INFO" "====== 实时穿透查账并双持提取双端密钥 ======"
    local GENERATED_AQ_KEYS=()
    local GENERATED_AIZA_KEYS=()
    
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
    
    if [ ${#selected_projects[@]} -eq 0 ]; then log "WARN" "未选择任何项目喵"; return 1; fi
    
    for project_id in "${selected_projects[@]}"; do
        log "INFO" "处理项目: ${project_id}"
        if verify_billing_status "$project_id"; then
            enable_essential_services "$project_id"
            
            local extract_result
            if extract_result=$(setup_and_extract_credentials "$project_id"); then
                local has_key=false
                while IFS= read -r line; do
                    if [[ "$line" == AQ_KEY:* ]]; then
                        GENERATED_AQ_KEYS+=("${line#AQ_KEY:}")
                        has_key=true
                    elif [[ "$line" == AIZA_KEY:* ]]; then
                        GENERATED_AIZA_KEYS+=("${line#AIZA_KEY:}")
                        has_key=true
                    fi
                done <<< "$extract_result"
                
                if [ "$has_key" = true ]; then
                    log "SUCCESS" "双端密钥提取完毕！"
                else
                    log "WARN" "提取流程完成但未截获任何合法密钥喵。"
                fi
            fi
        fi
    done
    
    if [ ${#GENERATED_AQ_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的 Vertex Agent 密钥 (AQ 格式) ======${NC}"
        for k in "${GENERATED_AQ_KEYS[@]}"; do echo "$k"; done
    fi
    if [ ${#GENERATED_AIZA_KEYS[@]} -gt 0 ]; then
        echo -e "\n${GREEN}${BOLD}====== 本次提取的 Gemini AI Studio 密钥 (AIza 格式) ======${NC}"
        for k in "${GENERATED_AIZA_KEYS[@]}"; do echo "$k"; done
        echo
    fi
}

main() {
    check_env
    while true; do
        echo -e "\n${CYAN}${BOLD}====== 喵酱的 Vertex 管理器 v${VERSION} ======${NC}"
        echo "1. [经典] 自动创建项目并提取双匙 (战术延时，清理旧项目)"
        echo "2. [新增] 自动创建项目并提取双匙 (战术延时，保留旧项目)"
        echo "3. 在现有项目上配置并强行提取 双匙 (AQ + AIza 双端双持)"
        echo "0. 退出工具"
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1) vertex_create_projects "false" "true" ;;
            2) vertex_create_projects "true" "true" ;;
            3) vertex_configure_existing ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项" ;;
        esac
    done
}

main
