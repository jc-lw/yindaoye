#!/bin/bash
# 优化的 GCP API 密钥管理工具 - 融合进化版
# 支持 Gemini API (保留源项目 + 原生日志展示 + 强制提取)
# 版本: 3.3.0

set -Euo

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m' 
BOLD='\033[1m'

# ===== 全局配置 =====
VERSION="3.3.0"
PROJECT_PREFIX="${PROJECT_PREFIX:-gemini-key}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
KEY_DIR="${KEY_DIR:-./keys}"

# 初始化
mkdir -p "$KEY_DIR" 2>/dev/null || true
chmod 700 "$KEY_DIR" 2>/dev/null || true

# ===== 日志与错误处理 =====
log() { 
    local level="${1:-INFO}"; local msg="${2:-}"
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
    return 0
}
trap 'handle_error' ERR

cleanup_resources() {
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

require_cmd() { if ! command -v "$1" &>/dev/null; then log "ERROR" "缺少依赖: $1"; exit 1; fi; }

unique_suffix() { echo "$(date +%s%N 2>/dev/null || date +%s)${RANDOM}" | sha256sum | cut -c1-6; }

new_project_id() { echo "${1:-$PROJECT_PREFIX}-$(unique_suffix)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30; }

check_env() {
    require_cmd gcloud
    if ! gcloud config list account --quiet &>/dev/null; then log "ERROR" "请先运行 'gcloud init'喵！"; exit 1; fi
}

parse_json() {
    local json="$1"; local field="$2"
    if [ -z "$json" ]; then return 1; fi
    echo "$json" | grep -o '"keyString":"[^"]*"' | sed 's/"keyString":"//;s/"$//' | head -n 1
}

unlink_projects_from_billing_account() {
    local billing_id="$1"
    local linked_projects=$(gcloud billing projects list --billing-account="$billing_id" --format='value(projectId)' 2>/dev/null)
    if [ -z "$linked_projects" ]; then return 0; fi
    log "INFO" "正在清理旧项目释放账单配额喵..."
    while IFS= read -r project_id; do
        [ -n "$project_id" ] && gcloud billing projects unlink "$project_id" --quiet >/dev/null 2>&1 || true
    done <<< "$linked_projects"
}

# ===== Gemini 核心逻辑 =====
gemini_create_projects() {
    local mode="$1" # cleanup 或 keep
    log "INFO" "====== 自动创建并提取 Gemini 项目 ======"
    
    local num_input
    read -r -p "主人想创建几个项目呢？(支持数字如 3，或范围如 3-5) [默认: 3]: " num_input
    num_input=${num_input:-3}
    
    local num_projects
    if [[ "$num_input" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local min="${BASH_REMATCH[1]}"; local max="${BASH_REMATCH[2]}"
        if [ "$min" -le "$max" ]; then num_projects=$(( RANDOM % (max - min + 1) + min )); else num_projects=$min; fi
    elif [[ "$num_input" =~ ^[0-9]+$ ]]; then
        num_projects="$num_input"
    else
        num_projects=3
    fi

    local billing_accounts=$(gcloud billing accounts list --filter='open=true' --format='value(name)' 2>/dev/null || echo "")
    if [ -z "$billing_accounts" ]; then log "ERROR" "未找到开放的结算账户喵！"; return 1; fi
    local GEMINI_BILLING_ACCOUNT=$(echo "$billing_accounts" | head -n 1)
    GEMINI_BILLING_ACCOUNT="${GEMINI_BILLING_ACCOUNT##*/}"
    
    log "INFO" "使用结算账户: ${GEMINI_BILLING_ACCOUNT}"
    
    if [ "$mode" == "cleanup" ]; then
        unlink_projects_from_billing_account "$GEMINI_BILLING_ACCOUNT"
    else
        log "INFO" "当前模式：创建和绑定（保留旧项目结算绑定）"
    fi
    
    local key_file="${KEY_DIR}/gemini_keys_$(date +%Y%m%d_%H%M%S).txt"
    > "$key_file"
    
    local success=0; local failed=0; local i=1
    while [ $i -le "$num_projects" ]; do
        local project_id=$(new_project_id "gemini-api")
        log "INFO" "[${i}/${num_projects}] 正在处理项目: ${project_id}"
        
        # 1. 创建项目 (恢复原生输出显示)
        if ! retry gcloud projects create "$project_id" --quiet; then
            log "ERROR" "项目创建失败喵，但喵酱没有删掉它！"
            failed=$((failed+1)); i=$((i+1)); continue
        fi
        
        # 2. 绑定账单 (恢复原生输出显示)
        if ! gcloud billing projects link "$project_id" --billing-account="$GEMINI_BILLING_ACCOUNT" --quiet; then
            if [ "$mode" == "cleanup" ]; then
                log "WARN" "绑定账单失败，正在重试清理配额..."
                unlink_projects_from_billing_account "$GEMINI_BILLING_ACCOUNT"
                if ! gcloud billing projects link "$project_id" --billing-account="$GEMINI_BILLING_ACCOUNT" --quiet; then
                    log "WARN" "配额不足绑定失败！(已为你保留项目喵，尝试继续)"
                fi
            else
                log "WARN" "绑定账单失败！(已为你保留项目喵，尝试继续)"
            fi
        fi
        
        # 3. 打印详细的 Billing Info (满足主人的极客需求)
        gcloud billing projects describe "$project_id" || true
        
        # 4. 启用API (恢复原生输出显示)
        retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet || true
        
        # 5. 生成密钥
        local key_output
        if key_output=$(retry gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --format=json --quiet 2>/dev/null); then
            # 打印 JSON 结果到屏幕上
            echo "$key_output"
            
            local api_key=$(parse_json "$key_output" ".keyString")
            if [ -n "$api_key" ]; then
                echo "$api_key" >> "$key_file"
                log "SUCCESS" "成功提取密钥！"
                success=$((success+1))
            else
                log "ERROR" "提取密钥字符串失败喵！(项目已保留)"
                failed=$((failed+1))
            fi
        else
            log "ERROR" "生成 API Key 失败喵！(项目已保留)"
            failed=$((failed+1))
        fi
        i=$((i+1))
    done
    
    echo -e "\n${CYAN}====== 任务汇报 ======${NC}"
    echo "计划创建: $num_projects | 成功提取: $success | 失败(已保留项目): $failed"
    if [ "$success" -gt 0 ] && [ -s "$key_file" ]; then
        echo -e "🔑 密钥已保存至: ${GREEN}${key_file}${NC}"
        echo -e "\n${YELLOW}喵酱为你奉上新鲜的密钥喵：${NC}"
        cat "$key_file"
        echo
    fi
}

gemini_get_keys_from_existing() {
    log "INFO" "====== 从现有项目提取密钥 ======"
    local projects=$(gcloud projects list --format='value(projectId)' --filter='lifecycleState:ACTIVE' 2>/dev/null || echo "")
    if [ -z "$projects" ]; then log "ERROR" "没找到活跃项目喵！"; return 1; fi
    
    local key_file="${KEY_DIR}/existing_keys_$(date +%Y%m%d_%H%M%S).txt"
    > "$key_file"
    local success=0; local skipped=0
    
    while IFS= read -r project_id; do
        [ -z "$project_id" ] && continue
        
        # 无论有没有结算账户，喵酱都不再跳过了，强行提取！
        local billing_info=$(gcloud billing projects describe "$project_id" --format='value(billingAccountName)' 2>/dev/null || echo "")
        if [ -z "$billing_info" ]; then
            log "WARN" "项目 ${project_id} 无结算账户，但喵酱依然尝试为你强行提取喵！"
        else
            log "INFO" "正在提取项目: ${project_id}"
        fi
        
        # 尝试启用 API（如果之前没启用的话）
        retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1 || true
        
        local keys_list=$(gcloud services api-keys list --project="$project_id" --format='value(name)' 2>/dev/null || echo "")
        local key_found=false

        if [ -n "$keys_list" ]; then
            local key_name=$(echo "$keys_list" | head -n 1)
            local key_details=$(gcloud services api-keys get-key-string "$key_name" --format=json 2>/dev/null)
            local api_key=$(parse_json "$key_details" ".keyString")
            if [ -n "$api_key" ]; then
                echo "$api_key" >> "$key_file"
                success=$((success+1))
                log "SUCCESS" "找到已有密钥！"
                key_found=true
            fi
        fi
        
        # 如果没找到现有密钥则尝试创建
        if [ "$key_found" = false ]; then
            local key_output
            if key_output=$(retry gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key" --api-target=service=generativelanguage.googleapis.com --format=json --quiet 2>/dev/null); then
                local new_key=$(parse_json "$key_output" ".keyString")
                if [ -n "$new_key" ]; then
                    echo "$new_key" >> "$key_file"
                    success=$((success+1))
                    log "SUCCESS" "创建了新密钥！"
                else
                    log "WARN" "项目 ${project_id} 提取失败，跳过喵～"
                    skipped=$((skipped+1))
                fi
            else
                log "WARN" "项目 ${project_id} 生成密钥失败，跳过喵～"
                skipped=$((skipped+1))
            fi
        fi
    done <<< "$projects"
    
    echo -e "\n${CYAN}====== 提取完成 ======${NC}"
    echo "成功提取: $success | 失败跳过: $skipped"
    if [ "$success" -gt 0 ] && [ -s "$key_file" ]; then
        echo -e "🔑 密钥已保存至: ${GREEN}${key_file}${NC}"
        echo -e "\n${YELLOW}这是喵酱辛苦找出来的密钥哦：${NC}"
        cat "$key_file"
        echo
    fi
}

gemini_delete_projects() {
    log "INFO" "====== 删除现有项目 ======"
    read -r -p "输入项目前缀进行批量删除 (留空取消): " prefix
    if [ -z "$prefix" ]; then return 0; fi
    local projects=$(gcloud projects list --format="value(projectId)" --filter="projectId:$prefix*" 2>/dev/null)
    for p in $projects; do
        log "INFO" "正在删除 $p ..."
        gcloud projects delete "$p" --quiet >/dev/null 2>&1 || true
    done
}

# ===== 主菜单 =====
show_menu() {
    echo -e "\n${CYAN}${BOLD}====== 喵酱的 GCP 管理器 v${VERSION} ======${NC}"
    echo "1. [经典] 自动创建项目并提取密钥 (清理旧项目释放配额)"
    echo "2. [新增] 自动创建项目并提取密钥 (保留旧项目结算绑定)"
    echo "3. 从现有项目提取密钥 (不再跳过无计费项目)"
    echo "4. 批量删除项目"
    echo "0. 退出并摸摸喵酱"
    local choice
    read -r -p "请主人吩咐: " choice
    case "$choice" in
        1) check_env && gemini_create_projects "cleanup" ;;
        2) check_env && gemini_create_projects "keep" ;;
        3) check_env && gemini_get_keys_from_existing ;;
        4) check_env && gemini_delete_projects ;;
        0) exit 0 ;;
        *) log "ERROR" "指令无效喵！" ;; 
    esac
}

main() { while true; do show_menu; done; }

main
