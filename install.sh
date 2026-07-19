#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

# ===== 配置变量（按你的实际情况改） =====
DISK="/dev/nvme0n1"
HOSTNAME="114"
USERNAME="514"
USER_PASSWORD="191"
ROOT_PASSWORD="981"
TIMEZONE="Asia/Shanghai"
LOCALE="zh_CN.UTF-8"

# ===== 检查 UEFI =====
if [ ! -d /sys/firmware/efi ]; then
    echo "仅支持 UEFI 启动模式。"
    exit 1
fi
echo "UEFI 启动模式已确认"

# ===== 安装模式 =====
echo "选择安装模式："
echo "1) 全新安装"
echo "2) 仅重装 Root (保留 Home)"
read -p "输入选项 [1/2]: " MODE_CHOICE

if [[ "$MODE_CHOICE" == "1" ]]; then
    INSTALL_MODE="full"
    echo "已选择：全新安装"
elif [[ "$MODE_CHOICE" == "2" ]]; then
    INSTALL_MODE="reinstall_root"
    echo "已选择：仅重装 Root"
else
    echo "无效输入，退出。"
    exit 1
fi

# ===== 计算 Swap =====
TOTAL_MEM_KIB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TOTAL_MEM_MIB=$((TOTAL_MEM_KIB / 1024))

if [ $TOTAL_MEM_MIB -le 2048 ]; then
    SWAP_MIB=$((TOTAL_MEM_MIB * 2))
elif [ $TOTAL_MEM_MIB -le 8192 ]; then
    SWAP_MIB=$TOTAL_MEM_MIB
elif [ $TOTAL_MEM_MIB -le 65536 ]; then
    SWAP_MIB=$((TOTAL_MEM_MIB * 3 / 4))
else
    SWAP_MIB=16384
fi

MAX_SWAP_MIB=16384
[ $SWAP_MIB -gt $MAX_SWAP_MIB ] && SWAP_MIB=$MAX_SWAP_MIB

echo "内存: ${TOTAL_MEM_MIB} MiB -> Swap: ${SWAP_MIB} MiB"

PART_EFI="${DISK}p1"
PART_SWAP="${DISK}p2"
PART_ROOT="${DISK}p3"
PART_HOME="${DISK}p4"

# ===== 确认 =====
if [[ "$INSTALL_MODE" == "full" ]]; then
    echo "警告：【全新安装】将清空 ${DISK} 全部数据！"
else
    echo "警告：【仅重装 Root】将格式化 EFI/Swap/Root，保留 Home。"
fi

read -p "输入 'yes' 继续: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "已取消。"
    exit 0
fi

# ===== 时钟 =====
echo ">>> 同步系统时钟..."
timedatectl set-ntp true
echo "时钟同步完成"

# ===== 分区与格式化 =====
if [[ "$INSTALL_MODE" == "full" ]]; then
    echo ">>> 清除旧分区表..."
    sgdisk -Z $DISK
    echo "分区表已清除"

    echo ">>> 创建 EFI 分区 (1G)..."
    sgdisk -n 1::+1024M -t 1:ef00 -c 1:"EFI" $DISK
    echo "EFI 分区已创建"

    echo ">>> 创建 Swap 分区 (${SWAP_MIB}M)..."
    sgdisk -n 2::+${SWAP_MIB}M -t 2:8200 -c 2:"SWAP" $DISK
    echo "Swap 分区已创建"

    echo ">>> 创建 Root 分区 (100G)..."
    sgdisk -n 3::+102400M -t 3:8300 -c 3:"ROOT" $DISK
    echo "Root 分区已创建"

    echo ">>> 创建 Home 分区 (剩余空间)..."
    sgdisk -N 4 -t 4:8300 -c 4:"HOME" $DISK
    echo "Home 分区已创建"

    echo ">>> 格式化 EFI..."
    mkfs.fat -F32 $PART_EFI
    echo "EFI 格式化完成"

    echo ">>> 格式化 Swap..."
    mkswap $PART_SWAP
    echo "Swap 格式化完成"

    echo ">>> 格式化 Root..."
    mkfs.ext4 -F $PART_ROOT
    echo "Root 格式化完成"

    echo ">>> 格式化 Home..."
    mkfs.xfs -f $PART_HOME
    echo "Home 格式化完成"
else
    echo ">>> 检查现有分区..."
    if [ -b "$PART_ROOT" ]; then
        echo "Root 分区存在: $PART_ROOT"
    else
        echo "错误：Root 分区不存在"
        exit 1
    fi
    if [ -b "$PART_HOME" ]; then
        echo "Home 分区存在: $PART_HOME"
    else
        echo "错误：Home 分区不存在"
        exit 1
    fi

    echo ">>> 格式化 EFI..."
    mkfs.fat -F32 $PART_EFI
    echo "EFI 格式化完成"

    echo ">>> 格式化 Swap..."
    mkswap $PART_SWAP
    echo "Swap 格式化完成"

    echo ">>> 格式化 Root..."
    mkfs.ext4 -F $PART_ROOT
    echo "Root 格式化完成"
fi

# ===== 挂载 =====
echo ">>> 挂载 Root 到 /mnt..."
mount $PART_ROOT /mnt
echo "Root 已挂载"

echo ">>> 创建挂载点..."
mkdir -p /mnt/boot /mnt/home
echo "挂载点已创建"

echo ">>> 挂载 EFI 到 /mnt/boot..."
mount $PART_EFI /mnt/boot
echo "EFI 已挂载"

echo ">>> 激活 Swap..."
swapon $PART_SWAP
echo "Swap 已激活"

echo ">>> 挂载 Home 到 /mnt/home..."
mount $PART_HOME /mnt/home
echo "Home 已挂载"

# ===== 镜像源 =====
echo ">>> 配置镜像源..."
echo "Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
echo "Server = https://mirrors.ustc.edu.cn/archlinux/\$repo/os/\$arch" >> /etc/pacman.d/mirrorlist
echo "镜像源配置完成"

# ===== 微码 =====
CPU_UCODE=""
if grep -q "GenuineIntel" /proc/cpuinfo; then
    CPU_UCODE="intel-ucode"
    echo "检测到 Intel CPU，将安装 intel-ucode"
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    CPU_UCODE="amd-ucode"
    echo "检测到 AMD CPU，将安装 amd-ucode"
else
    echo "未检测到已知 CPU，跳过微码安装"
fi

# ===== 安装基础系统 =====
echo ">>> 开始安装基础系统，这可能需要几分钟..."
pacstrap /mnt base linux linux-firmware base-devel vim networkmanager sudo xfsprogs grub efibootmgr $CPU_UCODE
echo "基础系统安装完成"

# ===== fstab =====
echo ">>> 生成 fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
echo "fstab 生成完成"

# ===== chroot 配置脚本 =====
echo ">>> 准备 chroot 配置脚本..."
cat <<'INNER_EOF' > /mnt/root/config.sh
#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

echo ">>> 配置时区..."
ln -sf /usr/share/zoneinfo/__TIMEZONE__ /etc/localtime
hwclock --systohc
echo "时区配置完成"

echo ">>> 配置语言环境..."
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
sed -i "/__LOCALE__/s/^#//" /etc/locale.gen
locale-gen
echo "LANG=__LOCALE__" > /etc/locale.conf
echo "语言环境配置完成"

echo ">>> 配置主机名..."
echo "__HOSTNAME__" > /etc/hostname
cat > /etc/hosts <<HOSTFILE
127.0.0.1   localhost
::1         localhost
127.0.1.1   __HOSTNAME__.localdomain __HOSTNAME__
HOSTFILE
echo "主机名配置完成"

echo ">>> 设置 root 密码..."
echo "root:__ROOT_PASSWORD__" | chpasswd
echo "root 密码设置完成"

echo ">>> 创建用户 __USERNAME__..."
useradd -m -G wheel -s /bin/bash __USERNAME__
echo "__USERNAME__:__USER_PASSWORD__" | chpasswd
echo "用户 __USERNAME__ 创建完成"

echo ">>> 配置 sudo 权限..."
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/99-wheel
chmod 440 /etc/sudoers.d/99-wheel
echo "sudo 权限配置完成"

echo ">>> 启用 NetworkManager..."
systemctl enable NetworkManager
echo "NetworkManager 已启用"

echo ">>> 安装 GRUB 引导..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="GRUB"
grub-mkconfig -o /boot/grub/grub.cfg
echo "GRUB 安装完成"
INNER_EOF

echo ">>> 替换配置变量..."
sed -i "s|__TIMEZONE__|$TIMEZONE|g" /mnt/root/config.sh
sed -i "s|__LOCALE__|$LOCALE|g" /mnt/root/config.sh
sed -i "s|__HOSTNAME__|$HOSTNAME|g" /mnt/root/config.sh
sed -i "s|__ROOT_PASSWORD__|$ROOT_PASSWORD|g" /mnt/root/config.sh
sed -i "s|__USERNAME__|$USERNAME|g" /mnt/root/config.sh
sed -i "s|__USER_PASSWORD__|$USER_PASSWORD|g" /mnt/root/config.sh
echo "变量替换完成"

echo ">>> 进入 chroot 环境执行配置..."
arch-chroot /mnt bash /root/config.sh
echo "chroot 配置完成"

echo ">>> 清理临时脚本..."
rm /mnt/root/config.sh
echo "临时脚本已清理"

# ===== 卸载 =====
echo ">>> 卸载分区..."
swapoff $PART_SWAP
echo "Swap 已关闭"
umount -R /mnt
echo "分区已卸载"

echo "=========================================="
if [[ "$INSTALL_MODE" == "full" ]]; then
    echo "Arch Linux 全新安装完成！"
else
    echo "Arch Linux 重装完成 (Home 已保留)！"
fi
echo "请执行 reboot 重启系统。"
echo "=========================================="