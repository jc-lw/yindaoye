#!/bin/bash
# ==========================================
# 喵酱的 GCP 大清洗 + 按结算单抽 + TG通知脚本 (自动开API版) 🐾
# ==========================================

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

ZONE="us-west1-a" 
MACHINE_TYPE="e2-micro" 
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
SSH_PASS="202825"
VM_NAME="free-tier-vm"

# Telegram 配置
TG_TOKEN="7745672750:AAG7q5904SL9-fMfmS5TZnwu_10rQ4SDsHc"
TG_CHAT_ID="7034468156"
TG_API="https://api.telegram.org"

send_tg_msg() {
    local text="$1"
    curl -s -X POST "${TG_API}/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" > /dev/null
}

echo "🐾 喵酱启动【大清洗与严格单抽模式】喵！"
PROJECTS=$(gcloud projects list --format="value(projectId)")

if [ -z "$PROJECTS" ]; then
    echo "❌ 无法获取项目列表喵！请检查授权。"
    exit 1
fi

# ==========================================
# 第一阶段：无差别清洗所有现存的免费机器
# ==========================================
echo "======================================"
echo "🧹 第一阶段：全网搜寻并摧毁旧的免费机器..."
for PROJECT in $PROJECTS; do
    echo "  -> 🔍 正在扫描项目: $PROJECT"
    EXISTING_VMS=$(gcloud compute instances list --project="$PROJECT" --filter="machineType:e2-micro" --format="value(name,zone)" 2>/dev/null)
    
    if [ -n "$EXISTING_VMS" ]; then
        echo -e "$EXISTING_VMS" | while read VM_INFO; do
            NAME=$(echo "$VM_INFO" | awk '{print $1}')
            VM_ZONE=$(echo "$VM_INFO" | awk '{print $2}')
            
            if [ -n "$NAME" ]; then
                echo "    💥 发现目标！正在摧毁项目 [$PROJECT] 中的 $NAME..."
                gcloud compute instances delete "$NAME" --project="$PROJECT" --zone="$VM_ZONE" --quiet
                echo "    ✅ 摧毁成功！"
            fi
        done
    fi
done

# ==========================================
# 第二阶段：按结算账户严格单抽创建
# ==========================================
echo "======================================"
echo "🎲 第二阶段：匹配结算账户，严格执行“一结算一机器”..."

SHUFFLED_PROJECTS=$(echo "$PROJECTS" | shuf)
declare -A PROCESSED_BILLING_ACCOUNTS
SUCCESS_PROJECTS=()

for PROJECT in $SHUFFLED_PROJECTS; do
    echo "  -> ⚙️ 正在匹配项目 [$PROJECT] 的结算信息..."
    
    # 获取结算账户 ID
    BILLING_ACCOUNT=$(gcloud beta billing projects describe "$PROJECT" --format="value(billingAccountName)" 2>/dev/null)
    
    if [ -z "$BILLING_ACCOUNT" ]; then
        echo "    ⏭️ 无可用结算账户，跳过喵。"
        continue
    fi

    # 检查这个结算账户是不是已经被抽中过了
    if [ -n "${PROCESSED_BILLING_ACCOUNTS[$BILLING_ACCOUNT]}" ]; then
        echo "    ⏭️ 跳过：该结算账户 [$BILLING_ACCOUNT] 已被使用，喵酱帮你守住钱包喵！"
        continue
    fi

    echo "    🎉 结算账户 [$BILLING_ACCOUNT] 选中了项目: $PROJECT！"
    PROCESSED_BILLING_ACCOUNTS[$BILLING_ACCOUNT]="1"

    # 【核心修复】：为选中的项目激活 Compute Engine API
    echo "    🔌 正在为该项目激活 Compute Engine API (这需要十几秒，请主人耐心等喵)..."
    gcloud services enable compute.googleapis.com --project="$PROJECT" --quiet
    sleep 15 # 等待 API 生效，防止 GCP 反应慢报错

    echo "    🚀 准备开机..."
    if ! gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="$IMAGE_FAMILY" \
        --image-project="$IMAGE_PROJECT" \
        --network-tier=PREMIUM \
        --tags=allow-all-ingress \
        --quiet; then
        echo "    ❌ 机器创建失败，可能是配额限制喵..."
        continue
    fi

    echo "    ⏳ 等待机器苏醒 (20 秒)..."
    sleep 20

    # 开放防火墙
    gcloud compute firewall-rules create allow-all-ingress-custom \
        --project="$PROJECT" \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=all \
        --source-ranges=0.0.0.0/0 \
        --target-tags=allow-all-ingress \
        --quiet >/dev/null 2>&1 || true

    # 抓取 IP
    IP=$(gcloud compute instances describe "$VM_NAME" --project="$PROJECT" --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

    # 远程配置环境与探针
    echo "    🔧 正在配置环境与探针..."
    cat << 'EOF' > remote_setup_$PROJECT.sh
#!/bin/bash
sed -i 's/deb.debian.org/mirrors.mit.edu/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
apt-get update -y
apt-get install -y unzip curl wget
echo "root:202825" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd

curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh
env NZ_SERVER=45.142.166.116:8008 NZ_TLS=false NZ_CLIENT_SECRET=EyxBehjdWpW3hnrzXavynrDIsGjWzKRH ./agent.sh
EOF

    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --command="sudo bash -s" < remote_setup_$PROJECT.sh --quiet
    rm -f remote_setup_$PROJECT.sh

    echo "    ✅ 部署成功喵！正在推送到 Telegram..."
    
    TG_MSG="🐾 <b>喵酱汇报：新免费节点上线！</b>
项目：<code>${PROJECT}</code>
IP：<code>${IP}</code>
账号：<code>root</code>
密码：<code>${SSH_PASS}</code>"
    
    send_tg_msg "$TG_MSG"

    SUCCESS_PROJECTS+=("🐾 IP: $IP | 项目: $PROJECT | [消息已推送至 TG]")
done

echo -e "\n======================================"
if [ ${#SUCCESS_PROJECTS[@]} -eq 0 ]; then
    echo "❌ 报告主人，目前没有任何符合条件的新机器部署成功喵..."
else
    echo "🎉 完美收工！以下是本次大清洗并新建的汇总喵："
    for RES in "${SUCCESS_PROJECTS[@]}"; do
        echo "$RES"
    done
fi
echo "======================================"
