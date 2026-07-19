#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

# ===== 依赖工具检查 =====
echo ">>> 检查依赖工具..."
REQUIRED_TOOLS="sgdisk mkfs.fat mkswap mkfs.ext4 mkfs.xfs mount umount swapon swapoff lsblk awk grep ping reflector timedatectl pacstrap genfstab arch-chroot"
MISSING_TOOLS=""
for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS="${MISSING_TOOLS} ${tool}"
    fi
done
if [ -n "$MISSING_TOOLS" ]; then
    echo "错误：缺少以下依赖工具:${MISSING_TOOLS}"
    echo "请在 Arch 安装环境中运行，或安装 gptfdisk/dosfstools/xfsprogs/arch-install-scripts 等对应软件包。"
    exit 1
fi
echo "依赖工具检查通过"

# ===== 配置变量（交互式输入，回车使用默认值） =====
echo ">>> 检测可用磁盘..."
lsblk -dpno NAME,SIZE,MODEL,TYPE | awk '$4=="disk"'
echo ""

DEFAULT_DISK=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1; exit}')
read -p "目标磁盘 [默认 ${DEFAULT_DISK}]: " DISK
DISK="${DISK:-$DEFAULT_DISK}"

read -p "主机名 [默认 arch]: " HOSTNAME
HOSTNAME="${HOSTNAME:-arch}"

read -p "用户名 [默认 user]: " USERNAME
USERNAME="${USERNAME:-user}"

read -p "时区 [默认 Asia/Shanghai]: " TIMEZONE
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

read -p "语言环境 [默认 zh_CN.UTF-8]: " LOCALE
LOCALE="${LOCALE:-zh_CN.UTF-8}"

while true; do
    read -s -p "root 密码: " ROOT_PASSWORD; echo
    read -s -p "确认 root 密码: " ROOT_PASSWORD_CONFIRM; echo
    if [ -z "$ROOT_PASSWORD" ]; then
        echo "密码不能为空，请重新输入。"
    elif [ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]; then
        echo "两次输入不一致，请重新输入。"
    else
        break
    fi
done

while true; do
    read -s -p "用户 ${USERNAME} 密码: " USER_PASSWORD; echo
    read -s -p "确认用户密码: " USER_PASSWORD_CONFIRM; echo
    if [ -z "$USER_PASSWORD" ]; then
        echo "密码不能为空，请重新输入。"
    elif [ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]; then
        echo "两次输入不一致，请重新输入。"
    else
        break
    fi
done

if [ ! -b "$DISK" ]; then
    echo "错误：磁盘 $DISK 不存在。"
    exit 1
fi

echo "配置确认：磁盘=$DISK 主机名=$HOSTNAME 用户=$USERNAME 时区=$TIMEZONE 语言=$LOCALE"

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

# nvme/mmc/loop 等设备分区名带 p 前缀（如 nvme0n1p1），sd 等则直接跟数字（如 sda1）
if [[ "$DISK" =~ (nvme|mmcblk|loop|nbd)[0-9]+$ ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="${DISK}"
fi
PART_EFI="${PART_PREFIX}1"
PART_SWAP="${PART_PREFIX}2"
PART_ROOT="${PART_PREFIX}3"
PART_HOME="${PART_PREFIX}4"

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
    sgdisk -n 4:0:0 -t 4:8300 -c 4:"HOME" $DISK
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
    if [ -b "$PART_EFI" ]; then
        echo "EFI 分区存在: $PART_EFI"
    else
        echo "错误：EFI 分区不存在"
        exit 1
    fi
    if [ -b "$PART_SWAP" ]; then
        echo "Swap 分区存在: $PART_SWAP"
    else
        echo "错误：Swap 分区不存在"
        exit 1
    fi
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
echo ">>> 使用 reflector 更新镜像源（按速度排序）..."
cp /etc/pacman.d/mirrorlist "/etc/pacman.d/mirrorlist.bak.$$" 2>/dev/null || true
reflector --country China --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
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

# ===== 网络检测 =====
echo ">>> 检测网络连通性..."
NET_OK=""
for host in 223.5.5.5 8.8.8.8 archlinux.org; do
    if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
        NET_OK="1"
        break
    fi
done
if [ -z "$NET_OK" ]; then
    echo "错误：无法连接网络，pacstrap 需要联网下载软件包。"
    echo "请先配置网络（有线通常自动获取，无线可用 iwctl 连接）后重试。"
    exit 1
fi
echo "网络连通性正常"

# ===== 安装基础系统 =====
echo ">>> 开始安装基础系统，这可能需要几分钟..."
pacstrap /mnt base linux linux-firmware base-devel vim networkmanager sudo xfsprogs grub efibootmgr git openssh $CPU_UCODE
echo "基础系统安装完成"

# ===== fstab =====
echo ">>> 生成 fstab..."
genfstab -U /mnt > /mnt/etc/fstab
echo "fstab 生成完成"

# ===== chroot 配置脚本 =====
echo ">>> 写入配置变量文件..."
{
    printf 'TIMEZONE=%q\n' "$TIMEZONE"
    printf 'LOCALE=%q\n' "$LOCALE"
    printf 'HOSTNAME=%q\n' "$HOSTNAME"
    printf 'ROOT_PASSWORD=%q\n' "$ROOT_PASSWORD"
    printf 'USERNAME=%q\n' "$USERNAME"
    printf 'USER_PASSWORD=%q\n' "$USER_PASSWORD"
} > /mnt/root/config.env
chmod 600 /mnt/root/config.env
echo "配置变量文件已写入"

echo ">>> 准备 chroot 配置脚本..."
cat <<'INNER_EOF' > /mnt/root/config.sh
#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

source /root/config.env

echo ">>> 配置时区..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
echo "时区配置完成"

echo ">>> 配置语言环境..."
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
sed -i "\|${LOCALE}|s/^#//" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "语言环境配置完成"

echo ">>> 配置主机名..."
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTFILE
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTFILE
echo "主机名配置完成"

echo ">>> 设置 root 密码..."
printf '%s\n' "root:${ROOT_PASSWORD}" | chpasswd
echo "root 密码设置完成"

echo ">>> 创建用户 ${USERNAME}..."
if [ -d "/home/${USERNAME}" ]; then
    # 重装保留 Home：沿用原家目录的 UID/GID，避免属主错乱
    EXIST_UID=$(stat -c '%u' "/home/${USERNAME}")
    EXIST_GID=$(stat -c '%g' "/home/${USERNAME}")
    echo "检测到已有家目录，沿用 UID=${EXIST_UID} GID=${EXIST_GID}"
    getent group "$EXIST_GID" >/dev/null 2>&1 || groupadd -g "$EXIST_GID" "${USERNAME}"
    useradd -M -u "$EXIST_UID" -g "$EXIST_GID" -G wheel -s /bin/bash "${USERNAME}"
else
    useradd -m -G wheel -s /bin/bash "${USERNAME}"
fi
printf '%s\n' "${USERNAME}:${USER_PASSWORD}" | chpasswd
echo "用户 ${USERNAME} 创建完成"

echo ">>> 配置 sudo 权限..."
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/99-wheel
chmod 440 /etc/sudoers.d/99-wheel
echo "sudo 权限配置完成"

echo ">>> 启用 NetworkManager..."
systemctl enable NetworkManager
echo "NetworkManager 已启用"

echo ">>> 启用 SSH 服务..."
systemctl enable sshd
echo "SSH 服务已启用"

echo ">>> 安装 GRUB 引导..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="GRUB"
grub-mkconfig -o /boot/grub/grub.cfg
echo "GRUB 安装完成"
INNER_EOF

echo ">>> 进入 chroot 环境执行配置..."
arch-chroot /mnt bash /root/config.sh
echo "chroot 配置完成"

echo ">>> 清理临时脚本..."
rm /mnt/root/config.sh /mnt/root/config.env
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