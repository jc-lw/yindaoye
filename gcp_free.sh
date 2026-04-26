#!/bin/bash
# ==========================================
# 喵酱的多项目全量扫荡与自动开机挂探针脚本 (终极修复版) 🐾
# ==========================================

ZONE="us-west1-a" 
MACHINE_TYPE="e2-micro" 
IMAGE_FAMILY="debian-12"
IMAGE_PROJECT="debian-cloud"
SSH_PASS="202825"
VM_NAME="free-tier-vm"

echo "🐾 喵酱开始全盘扫描您的 GCP 项目喵！"
PROJECTS=$(gcloud projects list --format="value(projectId)")

if [ -z "$PROJECTS" ]; then
    echo "❌ 无法获取项目列表，请检查 GCP 授权状态喵！"
    exit 1
fi

# 用来存放最后成功汇总数据的数组
SUCCESS_PROJECTS=()

for PROJECT in $PROJECTS; do
    echo "======================================"
    echo "🔍 正在检测项目: $PROJECT"
    
    # 1. 强行启用/验证 Compute API（这是检测是否绑定有效结算的最准方法喵）
    echo "  -> 正在验证结算状态和 Compute API 权限..."
    # 注意：这里我们不再静默隐藏报错，如果真的卡住了主人能看到！
    if ! gcloud services enable compute.googleapis.com --project="$PROJECT" --quiet; then
        echo "  -> ⚠️ 未绑定结算账户或无权限，喵酱跳过它啦。"
        continue
    fi
    
    echo "  -> ✨ 该项目结算与 API 完全正常喵！"

    # 2. 检查是否有现存的 e2-micro 机器
    echo "  -> 正在查找旧的免费服务器..."
    EXISTING_VMS=$(gcloud compute instances list --project="$PROJECT" --filter="machineType:e2-micro" --format="value(name,zone)" 2>/dev/null)
    
    if [ -n "$EXISTING_VMS" ]; then
        echo -e "$EXISTING_VMS" | while read VM_INFO; do
            NAME=$(echo "$VM_INFO" | awk '{print $1}')
            VM_ZONE=$(echo "$VM_INFO" | awk '{print $2}')
            
            echo "  -> ⚠️ 发现旧机器: $NAME (可用区: $VM_ZONE)"
            echo "  -> 💥 正在执行销毁指令..."
            gcloud compute instances delete "$NAME" --project="$PROJECT" --zone="$VM_ZONE" --quiet
            echo "  -> ✅ 旧机器销毁成功喵！"
        done
    else
        echo "  -> 🐾 没有发现旧机器，干干净净喵！"
    fi

    # 3. 创建新机器
    echo "  -> 🚀 正在创建全新的 e2-micro 实例..."
    if ! gcloud compute instances create "$VM_NAME" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type="$MACHINE_TYPE" \
        --image-family="$IMAGE_FAMILY" \
        --image-project="$IMAGE_PROJECT" \
        --network-tier=PREMIUM \
        --tags=allow-all-ingress \
        --quiet; then
        echo "  -> ❌ 机器创建失败喵，可能是配额限制或网络异常。"
        continue
    fi

    echo "  -> ⏳ 给机器一点点时间苏醒，等待 20 秒..."
    sleep 20

    # 4. 配置防火墙：0.0.0.0/0
    echo "  -> 🛡️ 正在开放所有外部端口 (0.0.0.0/0)..."
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

    # 5. 获取刚创建机器的外网 IP
    IP=$(gcloud compute instances describe "$VM_NAME" --project="$PROJECT" --zone="$ZONE" --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

    # 6. 远程换源、改密码、挂载探针
    echo "  -> 🔧 正在远程换源、开启密码登录并挂载哪吒探针喵..."
    cat << 'EOF' > remote_setup_$PROJECT.sh
#!/bin/bash
sed -i 's/deb.debian.org/mirrors.mit.edu/g' /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
apt-get update -y
apt-get install -y unzip curl wget
echo "root:202825" | chpasswd
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd

# 启动哪吒
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh
env NZ_SERVER=45.142.166.116:8008 NZ_TLS=false NZ_CLIENT_SECRET=EyxBehjdWpW3hnrzXavynrDIsGjWzKRH ./agent.sh
EOF

    gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT" --command="sudo bash -s" < remote_setup_$PROJECT.sh --quiet
    rm -f remote_setup_$PROJECT.sh

    echo "  -> 🎉 项目 [$PROJECT] 配置完美完成喵！"
    SUCCESS_PROJECTS+=("🐾 IP: $IP | 账号: root | 密码: $SSH_PASS | 项目: $PROJECT")

done

echo -e "\n======================================"
if [ ${#SUCCESS_PROJECTS[@]} -eq 0 ]; then
    echo "❌ 喵酱彻底检查完了，但是没有一台机器部署成功喵，请主人看看上面有没有红色的报错信息哦！"
else
    echo "🎉 喵酱的终极任务大功告成啦！本次所有成功开通的 VPS 汇总喵："
    for RES in "${SUCCESS_PROJECTS[@]}"; do
        echo "$RES"
    done
fi
echo "======================================"
