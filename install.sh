#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

# ===== 工具函数 =====

prompt_password() {
    local var_name="$1" prompt="$2"
    local confirm_name="${var_name}_CONFIRM"
    while true; do
        read -s -p "$prompt: " "${var_name}" < /dev/tty; echo
        read -s -p "确认${prompt}: " "$confirm_name" < /dev/tty; echo
        if [ -z "${!var_name}" ]; then
            echo "密码不能为空，请重新输入。"
        elif [ "${!var_name}" != "${!confirm_name}" ]; then
            echo "两次输入不一致，请重新输入。"
        else
            break
        fi
    done
}

check_partitions() {
    local missing=0
    for part in "$@"; do
        if [ -b "$part" ]; then
            echo "分区存在: $part"
        else
            echo "错误：分区不存在 $part"
            missing=1
        fi
    done
    [ $missing -eq 0 ]
}

# ===== Root 权限检查 =====
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本" >&2
    echo "正确用法：" >&2
    echo "  curl -L <url> | sudo bash" >&2
    echo "  或：sudo bash install.sh" >&2
    exit 1
fi

# ===== 依赖工具检查 =====
echo ">>> 检查依赖工具..."

tool_pkg() {
    case "$1" in
        sgdisk) echo "gptfdisk" ;;
        mkfs.fat) echo "dosfstools" ;;
        mkfs.ext4) echo "e2fsprogs" ;;
        mkfs.xfs) echo "xfsprogs" ;;
        mkswap|mount|umount|swapon|swapoff|lsblk) echo "util-linux" ;;
        awk) echo "gawk" ;;
        grep) echo "grep" ;;
        ping) echo "iputils" ;;
        reflector) echo "reflector" ;;
        timedatectl) echo "systemd" ;;
        pacstrap|genfstab|arch-chroot) echo "arch-install-scripts" ;;
        *) echo "$1" ;;
    esac
}

REQUIRED_TOOLS="sgdisk mkfs.fat mkswap mkfs.ext4 mkfs.xfs mount umount swapon swapoff lsblk awk grep ping reflector timedatectl pacstrap genfstab arch-chroot"
MISSING_TOOLS=""
MISSING_PKGS=""
for tool in $REQUIRED_TOOLS; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS="${MISSING_TOOLS} ${tool}"
        pkg=$(tool_pkg "$tool")
        case " $MISSING_PKGS " in
            *" $pkg "*) ;;
            *) MISSING_PKGS="${MISSING_PKGS} ${pkg}" ;;
        esac
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    echo "缺少以下依赖工具:${MISSING_TOOLS}"
    echo "对应软件包:${MISSING_PKGS}"
    if ! command -v pacman >/dev/null 2>&1; then
        echo "错误：未找到 pacman，无法自动安装，请手动安装后重试。"
        exit 1
    fi
    read -p "是否现在用 pacman 安装这些软件包？[y/N]: " INSTALL_DEPS < /dev/tty
    if [[ "$INSTALL_DEPS" =~ ^[Yy]$ ]]; then
        pacman -Sy --needed --noconfirm $MISSING_PKGS
        for tool in $MISSING_TOOLS; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                echo "错误：安装后仍缺少工具 ${tool}，请手动检查。"
                exit 1
            fi
        done
        echo "依赖工具安装完成"
    else
        echo "已取消，请手动安装依赖后重试。"
        exit 1
    fi
fi
echo "依赖工具检查通过"

# ===== 配置变量 =====
echo ">>> 检测可用磁盘..."
DISK_LIST=$(timeout 10 lsblk -dpno NAME,SIZE,MODEL,TYPE 2>/dev/null)
if [ -z "$DISK_LIST" ]; then
    echo "警告：lsblk 未能正常返回磁盘列表，尝试简化检测..."
    DISK_LIST=$(lsblk -dpno NAME,TYPE 2>/dev/null | grep disk || echo "")
    if [ -z "$DISK_LIST" ]; then
        echo "错误：无法获取磁盘列表，请检查系统存储设备。"
        exit 1
    fi
fi
echo "$DISK_LIST"
echo ""

DEFAULT_DISK=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1; exit}')
read -p "目标磁盘 [默认 ${DEFAULT_DISK}]: " DISK < /dev/tty
DISK="${DISK:-$DEFAULT_DISK}"

read -p "主机名 [默认 arch]: " HOSTNAME < /dev/tty
HOSTNAME="${HOSTNAME:-arch}"

read -p "用户名 [默认 user]: " USERNAME < /dev/tty
USERNAME="${USERNAME:-user}"

read -p "时区 [默认 Asia/Shanghai]: " TIMEZONE < /dev/tty
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

read -p "语言环境 [默认 zh_CN.UTF-8]: " LOCALE < /dev/tty
LOCALE="${LOCALE:-zh_CN.UTF-8}"

prompt_password ROOT_PASSWORD "root 密码"
prompt_password USER_PASSWORD "用户 ${USERNAME} 密码"

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
read -p "输入选项 [1/2]: " MODE_CHOICE < /dev/tty

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

[ $SWAP_MIB -gt 16384 ] && SWAP_MIB=16384
echo "内存: ${TOTAL_MEM_MIB} MiB -> Swap: ${SWAP_MIB} MiB"

# ===== 按磁盘大小配比 Root 分区 =====
DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
DISK_MIB=$((DISK_BYTES / 1024 / 1024))
EFI_MIB=1024

ROOT_MIB=$((DISK_MIB / 4))
[ $ROOT_MIB -lt 30720 ] && ROOT_MIB=30720
[ $ROOT_MIB -gt 153600 ] && ROOT_MIB=153600

NEED_MIB=$((EFI_MIB + SWAP_MIB + ROOT_MIB + 5120))
if [ $DISK_MIB -lt $NEED_MIB ]; then
    echo "错误：磁盘容量不足（${DISK_MIB} MiB），至少需要 ${NEED_MIB} MiB。"
    exit 1
fi
echo "磁盘: ${DISK_MIB} MiB -> Root: ${ROOT_MIB} MiB, Home: 剩余空间"

# ===== 分区命名 =====
if [[ "${DISK: -1}" =~ [0-9] ]]; then
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

read -p "输入 'yes' 继续: " confirm < /dev/tty
if [[ "$confirm" != "yes" ]]; then
    echo "已取消。"
    exit 0
fi

# ===== 清理旧挂载 =====
echo ">>> 清理旧的挂载和 Swap 激活..."
umount -R /mnt 2>/dev/null || true
swapoff "${PART_SWAP}" 2>/dev/null || true

# ===== 同步时钟 =====
echo ">>> 同步系统时钟..."
timedatectl set-ntp true

# ===== 分区与格式化 =====
if [[ "$INSTALL_MODE" == "full" ]]; then
    echo ">>> 创建分区..."
    sgdisk -Z "$DISK"
    sgdisk -n 1::+${EFI_MIB}M -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2::+${SWAP_MIB}M -t 2:8200 -c 2:"SWAP" "$DISK"
    sgdisk -n 3::+${ROOT_MIB}M -t 3:8300 -c 3:"ROOT" "$DISK"
    sgdisk -n 4:0:0 -t 4:8300 -c 4:"HOME" "$DISK"
    echo "分区创建完成"
else
    echo ">>> 检查现有分区..."
    check_partitions "$PART_EFI" "$PART_SWAP" "$PART_ROOT" "$PART_HOME"
fi

echo ">>> 格式化分区..."
mkfs.fat -F32 "$PART_EFI"
mkswap "$PART_SWAP"
mkfs.ext4 -F "$PART_ROOT"
if [[ "$INSTALL_MODE" == "full" ]]; then
    mkfs.xfs -f "$PART_HOME"
fi
echo "格式化完成"

# ===== 挂载 =====
echo ">>> 挂载分区..."
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot /mnt/home
mount "$PART_EFI" /mnt/boot
swapon "$PART_SWAP"
if [[ "$INSTALL_MODE" == "full" ]]; then
    mount "$PART_HOME" /mnt/home
fi
echo "挂载完成"

# ===== 镜像源 =====
echo ">>> 使用 reflector 更新镜像源（按速度排序）..."
echo "正在测试镜像下载速度，可能需要 1~2 分钟，请稍候..."
cp /etc/pacman.d/mirrorlist "/etc/pacman.d/mirrorlist.bak.$$" 2>/dev/null || true

reflector \
    --country China \
    --protocol https \
    --latest 10 \
    --sort rate \
    --save /etc/pacman.d/mirrorlist \
    --verbose \
    --download-timeout 5

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
PACKAGES="base linux linux-firmware base-devel vim networkmanager sudo xfsprogs grub efibootmgr git openssh curl plymouth fastfetch $CPU_UCODE"
for attempt in 1 2 3; do
    if pacstrap /mnt $PACKAGES; then
        break
    fi
    if [ $attempt -lt 3 ]; then
        echo "警告：pacstrap 失败（第 ${attempt} 次），10 秒后重试..."
        sleep 10
    else
        echo "错误：pacstrap 多次失败，请检查网络连接和镜像源后重试。"
        exit 1
    fi
done
echo "基础系统安装完成"

# ===== fstab =====
echo ">>> 生成 fstab..."
genfstab -U /mnt > /mnt/etc/fstab

# ===== chroot 配置 =====
echo ">>> 写入配置变量文件..."
{
    printf 'TIMEZONE=%q\n' "$TIMEZONE"
    printf 'LOCALE=%q\n' "$LOCALE"
    printf 'HOSTNAME=%q\n' "$HOSTNAME"
    printf 'USERNAME=%q\n' "$USERNAME"
} > /mnt/root/config.env
chmod 600 /mnt/root/config.env

echo ">>> 下载配置脚本..."
RAW_BASE="https://raw.githubusercontent.com/Zecheng-6114/lyys_arch_install/main"

download() {
    curl -fsSL "${RAW_BASE}/$1" -o "$2" || { echo "错误：下载失败 $1"; exit 1; }
}

install -d /mnt/root /mnt/usr/local/bin /mnt/etc/systemd/system

download config.sh /mnt/root/config.sh
chmod +x /mnt/root/config.sh

download github520/update.sh /mnt/usr/local/bin/github520-update.sh
download plymouth-theme/update.sh /mnt/usr/local/bin/plymouth-theme-update.sh
chmod +x /mnt/usr/local/bin/github520-update.sh /mnt/usr/local/bin/plymouth-theme-update.sh

download github520/update.service /mnt/etc/systemd/system/github520-update.service
download github520/update.timer /mnt/etc/systemd/system/github520-update.timer
download plymouth-theme/update.service /mnt/etc/systemd/system/plymouth-theme-update.service
download plymouth-theme/update.timer /mnt/etc/systemd/system/plymouth-theme-update.timer

echo "配置脚本下载完成"

echo ">>> 进入 chroot 环境执行配置..."
printf '%s\n%s\n' "$ROOT_PASSWORD" "$USER_PASSWORD" | arch-chroot /mnt bash /root/config.sh

# ===== 清理与卸载 =====
echo ">>> 清理临时脚本..."
rm /mnt/root/config.sh /mnt/root/config.env

echo ">>> 卸载分区..."
swapoff "$PART_SWAP"
umount -R /mnt

echo "=========================================="
if [[ "$INSTALL_MODE" == "full" ]]; then
    echo "Arch Linux 全新安装完成！"
else
    echo "Arch Linux 重装完成 (Home 已保留)！"
fi
echo "请执行 reboot 重启系统。"
echo "=========================================="

