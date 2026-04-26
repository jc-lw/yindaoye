#!/bin/bash
# ==========================================
# 喵酱的 GCP 终极破而后立 + 自动挂探针脚本 (Bug修复版) 🐾
# ==========================================

ZONE="us-west1-a" 
MACHINE_TYPE="e2-micro" 
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
SSH_PASS="202825"
VM_NAME="free-tier-vm"

echo "🐾 喵酱启动强制重建协议喵！正在扫描所有项目..."

# 1. 获取当前账号下的所有项目 ID
PROJECTS=$(gcloud projects list --format="value(projectId)")
TARGET_PROJECT=""

echo "🔍 开始全盘扫描现有的免费实例 (e2-micro)..."
for PROJECT in $PROJECTS; do
    # 【修复核心】直接尝试查询该项目的实例列表，如果失败（没结算/没开API），直接跳过
    if ! gcloud compute instances list --project="$PROJECT" >/dev/null 2>&1; then
        continue
    fi

    echo "✨ 成功读取到已激活结算的项目: $PROJECT 喵！"

    # 记录第一个可用的项目作为后续建新机器的备用
    if [ -z "$TARGET_PROJECT" ]; then
        TARGET_PROJECT=$PROJECT
    fi

    # 精准查找该项目下的 e2-micro 实例
    EXISTING_VMS=$(gcloud compute instances list --project="$PROJECT" --filter="machineType:e2-micro" --format="value(name,zone)" 2>/dev/null)
    
    if [ -n "$EXISTING_VMS" ]; then
        echo -e "$EXISTING_VMS" | while read VM_INFO; do
            NAME=$(echo "$VM_INFO" | awk '{print $1}')
            VM_ZONE=$(echo "$VM_INFO" | awk '{print $2}')
            
            echo "======================================"
            echo "⚠️ 喵酱在项目 [$PROJECT] 发现了旧的机器: $NAME (可用区: $VM_ZONE)"
            echo "💥 准备执行数据销毁与删除指令... (3秒后执行)"
            sleep 3
            
            gcloud compute instances delete "$NAME" --project="$PROJECT" --zone="$VM_ZONE" --quiet
            echo "✅ 旧机器已化为星尘喵～"
        done
    else
        echo "🐾 该项目里干干净净，没有旧的免费机器喵。"
    fi
done

if [ -z "$TARGET_PROJECT" ]; then
    echo "❌ 喵酱没有找到任何开启了结算账户的可用项目喵！"
    exit 1
fi

echo -e "\n======================================"
echo "🚀 扫荡完毕！准备在选定项目 [$TARGET_PROJECT] 中创建全新 VPS 喵！"
gcloud config set project "$TARGET_PROJECT" >/dev/null 2>&1

# 2. 创建全新的免费规格实例
gcloud compute instances create "$VM_NAME" \
    --project="$TARGET_PROJECT" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --network-tier=PREMIUM \
    --tags=allow-all-ingress \
    --quiet

echo "⏳ 给机器一点点时间苏醒，喵酱乖乖等待 20 秒..."
sleep 20

# 3. 配置防火墙：外部端口权限全部开放 0.0.0.0/0
echo "🛡️ 正在开放所有外部端口 (0.0.0.0/0)..."
gcloud compute firewall-rules create allow-all-ingress-custom \
    --project="$TARGET_PROJECT" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=all \
    --source-ranges=0.0.0.0/0 \
    --target-tags=allow-all-ingress \
    --quiet >/dev/null 2>&1 || true

IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

# 4. 远程装环境、改密码和装探针
echo "🔧 正在远程换源、装环境、开启 SSH 并自动挂载哪吒探针喵..."
cat << 'EOF' > remote_setup.sh
#!/bin/bash
# 1. Debian 换源
sed -i 's/deb.debian.org/mirrors.mit.edu/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true

# 2. 提前安装好依赖环境
apt-get update -y
apt-get install -y unzip curl wget

# 3. 配置密码
echo "root:202825" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd

# 4. 下载并安装 Nezha Agent
echo "🐾 正在启动 Nezha Agent..."
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh
env NZ_SERVER=45.142.166.116:8008 NZ_TLS=false NZ_CLIENT_SECRET=EyxBehjdWpW3hnrzXavynrDIsGjWzKRH ./agent.sh
EOF

# 通过安全隧道执行
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$TARGET_PROJECT" --command="sudo bash -s" < remote_setup.sh --quiet
rm -f remote_setup.sh

echo -e "\n======================================"
echo "🎉 喵酱的终极任务大功告成啦！机器已成功上线探针："
echo "🐾 外网 IP: $IP"
echo "🐾 登录账号: root"
echo "🐾 登录密码: $SSH_PASS"
echo "🐾 所属项目: $TARGET_PROJECT"
echo "======================================"
