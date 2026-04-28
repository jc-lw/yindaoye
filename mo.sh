#!/bin/bash
# 优化的 GCP Vertex AI 密钥管理工具 (独立版)
# 支持主方案分批并发突破20限额、备用方案兜底、战术延时防风控
# 版本: 3.7.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="3.7.0"
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

# ===== 【极致优化】双保险开通 API (突破 20 个 API 限制) =====
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
    )
    
    log "INFO" "🚀 [主方案] 启动分批极速并发，开启 ${#services[@]} 项核心权限..."
    
    # 将 22 个 API 对半劈开，防止触发 Google 官方单次限额 20 的物理红线
    local chunk1=("${services[@]:0:11}")
    local chunk2=("${services[@]:11}")
    
    local main_plan_success=true
    
    # 连续丢两批，速度飞快且绝对不会被 Google 拒收
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
    
    # 强制状态校验 (防 403 核心机制)
    log "INFO" "正在强制校验核心 Vertex AI API 激活状态..."
    local verify_attempt=1
    while [ $verify_attempt -le 6 ]; do
        local state
        state=$(gcloud services list --project="$proj" --filter="config.name:aiplatform.googleapis.com" --format="value(state)" 2>/dev/null || echo "DISABLED")
        if [[ "$state" == "ENABLED" ]]; then
            log "SUCCESS" "底层激活确认！"
            return 0
        fi
        log "WARN" "API 尚未就绪，Google 服务器同步中... ($verify_attempt/6)"
        sleep 10
        verify_attempt=$((verify_attempt+1))
    done
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
        log "WARN" "等待计费系统同步 (防 403 错误)... ($attempt/3)"
        sleep 6
        attempt=$((attempt+1))
    done
    return 1
}

# ===== 核心：提取凭证 =====
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
    
    log "INFO" "同步 IAM 权限..."
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

    log "INFO" "正在请求生成 AQ. 格式专属密钥..."
    local attempt=1
    while [ $attempt -le 4 ]; do
        local create_err
        if create_err=$(gcloud beta services api-keys create --project="$project_id" --display-name="Agent Platform Key" --service-account="$sa_email" --quiet 2>&1); then
            break
        fi
        local err_msg
        err_msg=$(echo "$create_err" | tail -n 1 | tr -d '\r')
        if [[ "$err_msg" == *"Policy"* ]] || [[ "$err_msg" == *"PermissionDenied"* ]] || [[ "$err_msg" == *"constraints"* ]]; then
            log "ERROR" "组织策略拦截，降级中..."
            break
        fi
        log "WARN" "接口重试中 ($attempt/4)..."
        sleep 8
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

# ===== 功能 1 & 2：自动创建项目 (含战术延时) =====
vertex_create_projects() {
    local keep_billing="${1:-false}"
    local auto_mode="${2:-false}"
    
    local billing_raw=$(gcloud billing accounts list --filter='open=true' --format='csv[no-heading](name,displayName)' 2>/dev/null || echo "")
    if [ -z "$billing_raw" ]; then log "ERROR" "未找到结算账户"; return 1; fi

    SELECTED_BILLING_IDS=()
    SELECTED_BILLING_NAMES=()

    if [ "$auto_mode" = "true" ]; then
        log "INFO" "🐱 开启【全自动模式】：每个结算账户创建 3 个项目"
        while IFS=',' read -r bid bname; do
            bid="${bid##*/}"; SELECTED_BILLING_IDS+=("$bid"); SELECTED_BILLING_NAMES+=("$bname")
        done <<< "$billing_raw"
        num_per_billing=3
    else
        local ids=(); local names=()
        while IFS=',' read -r bid bname; do
            bid="${bid##*/}"; ids+=("$bid"); names+=("$bname")
        done <<< "$billing_raw"

        echo -e "\n${CYAN}${BOLD}可用的结算账户：${NC}"
        for idx in "${!ids[@]}"; do
            echo -e "  ${GREEN}$((idx+1))${NC}. ${names[$idx]} (${ids[$idx]})"
        done
        echo -e "  ${GREEN}0${NC}. 全部选择"

        local choice
        read -r -p "请选择结算账户 (输入编号，多个用逗号分隔，如 1,3) [默认: 0]: " choice
        choice=${choice:-0}

        if [ "$choice" = "0" ]; then
            SELECTED_BILLING_IDS=("${ids[@]}"); SELECTED_BILLING_NAMES=("${names[@]}")
        else
            IFS=',' read -ra selections <<< "$choice"
            for sel in "${selections[@]}"; do
                sel=$(echo "$sel" | tr -d ' ')
                if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#ids[@]}" ]; then
                    local si=$((sel-1))
                    SELECTED_BILLING_IDS+=("${ids[$si]}")
                    SELECTED_BILLING_NAMES+=("${names[$si]}")
                fi
            done
        fi
        
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
    
    local GENERATED_API_KEYS=()
    local BILLING_KEY_MAP=()

    if [ "$keep_billing" = "true" ]; then log "INFO" "====== 自动创建并提取 Vertex 密钥 (保留旧结算绑定) ======"
    else log "INFO" "====== 自动创建并提取 Vertex 密钥 (释放旧配额) ======"; fi

    for billing_idx in "${!SELECTED_BILLING_IDS[@]}"; do
        local TARGET_BID="${SELECTED_BILLING_IDS[$billing_idx]}"
        local billing_name="${SELECTED_BILLING_NAMES[$billing_idx]}"

        echo -e "\n${CYAN}${BOLD}────── 结算账户 $((billing_idx+1))/${#SELECTED_BILLING_IDS[@]}: ${billing_name} (${TARGET_BID}) ──────${NC}"

        if [ "$keep_billing" = "false" ]; then 
            unlink_projects_from_billing_account "$TARGET_BID"
            log "INFO" "已清理旧项目账单，原地静默潜伏 5 秒钟以消除数据库缓存喵..."
            sleep 5
        fi

        local success=0; local failed=0; local skipped=0; local i=1
        while [ $i -le "$num_per_billing" ]; do
            local global_idx=$(( billing_idx * num_per_billing + i ))
            local project_id=$(new_project_id)
            log "INFO" "[${global_idx}/${total_projects}] 正在处理新建项目: ${project_id}"
            
            gcloud projects create "$project_id" --quiet >/dev/null 2>&1 || { failed=$((failed+1)); i=$((i+1)); continue; }
            gcloud billing projects link "$project_id" --billing-account="$TARGET_BID" --quiet >/dev/null 2>&1 || true
            
            if ! verify_billing_status "$project_id"; then
                log "WARN" "项目 ${project_id} 计费未生效，跳过提取喵！"
                skipped=$((skipped+1)); i=$((i+1)); continue
            fi

            log "INFO" "账单绑定确认成功！开启 20 秒安全静默期，模拟人类操作避开 GCP 风控雷达..."
            sleep 20
            
            enable_essential_services "$project_id"
            
            local extract_result
            if extract_result=$(setup_and_extract_credentials "$project_id"); then
                if [[ "$extract_result" == *KEY:* ]]; then
                    local ak="${extract_result#*KEY:}"
                    ak=$(echo "$ak" | tr -d '\r' | tr -d '\n')
                    GENERATED_API_KEYS+=("$ak")
                    BILLING_KEY_MAP+=("${billing_idx}:${ak}")
                    if [[ "$ak" == AQ.* ]]; then
                        log "SUCCESS" "AQ. 格式专属 API 密钥提取成功！"
                    else
                        log "SUCCESS" "突破组织限制，降级生成标准密钥 (AIza) 成功！"
                    fi
                    success=$((success+1))
                fi
            else
                log "WARN" "凭证提取完全失败！"
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
    
    if [ "${#GENERATED_API_KEYS[@]}" -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}喵酱为你奉上所有提取到的密钥喵（按结算账户分组）：${NC}"
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
        echo -e "共计 ${GREEN}${#GENERATED_API_KEYS[@]}${NC} 个有效密钥"
        echo
    fi
}

# ===== 功能 3：一键配置现有项目 (实时查账单引擎) =====
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
                GENERATED_API_KEYS+=("$ak")
                log "SUCCESS" "密钥提取成功！"
            fi
        fi
    done
    
    if [ ${#GENERATED_API_KEYS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}====== 本次提取的密钥列表 ======${NC}"
        for k in "${GENERATED_API_KEYS[@]}"; do echo "$k"; done
    fi
}

# ===== 主程序 =====
main() {
    check_env
    while true; do
        echo -e "\n${CYAN}${BOLD}====== 喵酱的 Vertex 管理器 v${VERSION} ======${NC}"
        echo "1. [经典] 自动创建项目并提取 (战术延时，清理旧项目)"
        echo "2. [新增] 自动创建项目并提取 (战术延时，保留旧项目)"
        echo "3. 在现有项目上配置并提取 (分批提速，双保险防漏)"
        echo "0. 退出工具"
        local choice
        read -r -p "请选择: " choice
        case "$choice" in
            1) vertex_create_projects "false" "false" ;;
            2) 
                echo -e "\n${CYAN}主人想怎么操作呢？${NC}"
                echo "1. 自定义选择结算账户和数量"
                echo "2. 全自动 (为所有可用账户各创建3个项目)"
                local sub_choice
                read -r -p "请选择 [1-2, 默认: 1]: " sub_choice
                sub_choice=${sub_choice:-1}
                if [ "$sub_choice" = "2" ]; then vertex_create_projects "true" "true"
                else vertex_create_projects "true" "false"; fi
                ;;
            3) vertex_configure_existing ;;
            0) exit 0 ;;
            *) log "ERROR" "无效选项" ;;
        esac
    done
}

main
