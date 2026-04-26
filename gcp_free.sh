#!/bin/bash
# ==========================================
# 喵酱的 GCP 盲盒开机脚本 (按结算账户随机单抽版) 🐾
# ==========================================

ZONE="us-west1-a"
MACHINE_TYPE="e2-micro"
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
SSH_PASS="202825"
VM_NAME="free-tier-vm"

echo "🐾 喵酱开始为主人扫描所有的项目并匹配结算账户喵..."

# 1. 获取所有项目，并用 shuf 随机打乱顺序（实现“随机抽取”的核心喵）
SHUFFLED_PROJECTS=$(gcloud projects list --format="value(projectId)" | shuf)

# 用于记录已经开过机器的结算账户
declare -A PROCESSED_BILLING_ACCOUNTS
SELECTED_PROJECTS=()
RESULTS=()

for PROJECT in $SHUFFLED_PROJECTS; do
    # 尝试获取该项目的结算账户信息
    BILLING_ACCOUNT=$(gcloud beta billing projects describe $PROJECT --format="value(billingAccountName)" 2>/dev/null)
    
    # 如果该项目有结算账户
    if [ -n "$BILLING_ACCOUNT" ]; then
        # 检查这个结算账户是不是已经被抽中过了
        if [ -z "${PROCESSED_BILLING_ACCOUNTS[$BILLING_ACCOUNT]}" ]; then
            echo "🎉 结算账户 [$BILLING_ACCOUNT] 随机抽中了项目: $PROJECT 喵！"
            PROCESSED_BILLING_ACCOUNTS[$BILLING_ACCOUNT]="1"
            SELECTED_PROJECTS+=("$PROJECT")
        fi
    fi
done

if [ ${#SELECTED_PROJECTS[@]} -eq 0 ]; then
    echo "⚠️ 喵酱没有找到任何绑定了结算账户的项目喵..."
    exit 1
fi

echo -e "\n🚀 抽签完毕！准备为选中的项目开通服务器喵！"

# 2. 开始为抽中的项目执行开机任务
for PROJECT in "${SELECTED_PROJECTS[@]}"; do
    echo -e "\n======================================"
    echo "✨ 正在处理项目: $PROJECT"
    gcloud config set project $PROJECT >/dev/null 2>&1

    # 启用 Compute Engine API
    gcloud services enable compute.googleapis.com --project=$PROJECT >/dev/null 2>&1 || true

    # 创建实例
    if gcloud compute instances describe $VM_NAME --zone=$ZONE >/dev/null 2>&1; then
         echo "⚠️ 实例 $VM_NAME 已经存在喵，将直接尝试刷新防火墙和 SSH 配置！"
    else
         echo "🚀 正在创建 e2-micro 免费实例..."
         gcloud compute instances create $VM_NAME \
            --project=$PROJECT \
            --zone=$ZONE \
            --machine-type=$MACHINE_TYPE \
            --image-family=$IMAGE_FAMILY \
            --image-project=$IMAGE_PROJECT \
            --network-tier=PREMIUM \
            --tags=allow-all-ingress \
            --quiet
         
         echo "⏳ 给 GCP 一点时间启动机器，喵酱原地转个圈 (等待 20 秒)..."
         sleep 20
    fi

    # 配置防火墙：外部端口权限全部开放 0.0.0.0/0
    echo "🛡️ 正在开放所有端口 (0.0.0.0/0)..."
    gcloud compute firewall-rules create allow-all-ingress-custom \
        --project=$PROJECT \
        --direction=INGRESS \
        --priority=1000 \
        --network=default \
        --action=ALLOW \
        --rules=all \
        --source-ranges=0.0.0.0/0 \
        --target-tags=allow-all-ingress \
        --quiet >/dev/null 2>&1 || true

    # 获取外部 IP
    IP=$(gcloud compute instances describe $VM_NAME --zone=$ZONE --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

    # 生成内部执行脚本 (换源 + 改密码)
    echo "🔧 正在远程开启 SSH 密码登录..."
    cat << 'EOF' > remote_setup.sh
#!/bin/bash
sed -i 's/deb.debian.org/mirrors.mit.edu/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
echo "root:202825" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
EOF

    # 远程执行脚本
    gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT --command="sudo bash -s" < remote_setup.sh --quiet

    if [ $? -eq 0 ]; then
        echo "✅ $PROJECT 配置完美完成喵！"
        RESULTS+=("IP: $IP | 账号: root | 密码: $SSH_PASS | 项目: $PROJECT")
    else
        echo "❌ $PROJECT 的 SSH 远程配置似乎有点小问题，主人可能需要检查一下 API 权限喵..."
    fi
    
    rm -f remote_setup.sh
done

echo -e "\n======================================"
echo "🎉 喵酱的任务完成啦！本次成功开通的 VPS 汇总喵："
for RES in "${RESULTS[@]}"; do
    echo "🐾 $RES"
done
echo "======================================"
