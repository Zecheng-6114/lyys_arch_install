#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

# ===== Root 权限检查 =====
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用 root 权限运行此脚本（sudo $0）" >&2
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
    echo ""
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

# ===== 配置变量（交互式输入，回车使用默认值） =====
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

while true; do
    read -s -p "root 密码: " ROOT_PASSWORD < /dev/tty; echo
    read -s -p "确认 root 密码: " ROOT_PASSWORD_CONFIRM < /dev/tty; echo
    if [ -z "$ROOT_PASSWORD" ]; then
        echo "密码不能为空，请重新输入。"
    elif [ "$ROOT_PASSWORD" != "$ROOT_PASSWORD_CONFIRM" ]; then
        echo "两次输入不一致，请重新输入。"
    else
        break
    fi
done

while true; do
    read -s -p "用户 ${USERNAME} 密码: " USER_PASSWORD < /dev/tty; echo
    read -s -p "确认用户密码: " USER_PASSWORD_CONFIRM < /dev/tty; echo
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

MAX_SWAP_MIB=16384
[ $SWAP_MIB -gt $MAX_SWAP_MIB ] && SWAP_MIB=$MAX_SWAP_MIB

echo "内存: ${TOTAL_MEM_MIB} MiB -> Swap: ${SWAP_MIB} MiB"

# ===== 按磁盘大小配比 Root 分区 =====
DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
DISK_MIB=$((DISK_BYTES / 1024 / 1024))
EFI_MIB=1024

# Root 取磁盘 25%，并限制在 [30G, 150G] 区间
ROOT_MIB=$((DISK_MIB / 4))
MIN_ROOT_MIB=30720
MAX_ROOT_MIB=153600
[ $ROOT_MIB -lt $MIN_ROOT_MIB ] && ROOT_MIB=$MIN_ROOT_MIB
[ $ROOT_MIB -gt $MAX_ROOT_MIB ] && ROOT_MIB=$MAX_ROOT_MIB

# 校验磁盘容量：EFI + Swap + Root 之外至少给 Home 预留 5G
NEED_MIB=$((EFI_MIB + SWAP_MIB + ROOT_MIB + 5120))
if [ $DISK_MIB -lt $NEED_MIB ]; then
    echo "错误：磁盘容量不足（${DISK_MIB} MiB），至少需要 ${NEED_MIB} MiB。"
    exit 1
fi

echo "磁盘: ${DISK_MIB} MiB -> Root: ${ROOT_MIB} MiB, Home: 剩余空间"

# ---- 分区前缀判断（修复） ----
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

# ===== 主动预防：卸载可能残留的旧挂载 =====
echo ">>> 清理旧的挂载和 Swap 激活..."
umount -R /mnt 2>/dev/null || true
swapoff "${PART_SWAP}" 2>/dev/null || true
echo "清理完成"

# ===== 时钟 =====
echo ">>> 同步系统时钟..."
timedatectl set-ntp true
echo "时钟同步完成"

# ===== 分区与格式化 =====
if [[ "$INSTALL_MODE" == "full" ]]; then
    echo ">>> 清除旧分区表..."
    sgdisk -Z "$DISK"
    echo "分区表已清除"

    echo ">>> 创建 EFI 分区 (${EFI_MIB}M)..."
    sgdisk -n 1::+${EFI_MIB}M -t 1:ef00 -c 1:"EFI" "$DISK"
    echo "EFI 分区已创建"

    echo ">>> 创建 Swap 分区 (${SWAP_MIB}M)..."
    sgdisk -n 2::+${SWAP_MIB}M -t 2:8200 -c 2:"SWAP" "$DISK"
    echo "Swap 分区已创建"

    echo ">>> 创建 Root 分区 (${ROOT_MIB}M)..."
    sgdisk -n 3::+${ROOT_MIB}M -t 3:8300 -c 3:"ROOT" "$DISK"
    echo "Root 分区已创建"

    echo ">>> 创建 Home 分区 (剩余空间)..."
    sgdisk -n 4:0:0 -t 4:8300 -c 4:"HOME" "$DISK"
    echo "Home 分区已创建"

    echo ">>> 格式化 EFI..."
    mkfs.fat -F32 "$PART_EFI"
    echo "EFI 格式化完成"

    echo ">>> 格式化 Swap..."
    mkswap "$PART_SWAP"
    echo "Swap 格式化完成"

    echo ">>> 格式化 Root..."
    mkfs.ext4 -F "$PART_ROOT"
    echo "Root 格式化完成"

    echo ">>> 格式化 Home..."
    mkfs.xfs -f "$PART_HOME"
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
    mkfs.fat -F32 "$PART_EFI"
    echo "EFI 格式化完成"

    echo ">>> 格式化 Swap..."
    mkswap "$PART_SWAP"
    echo "Swap 格式化完成"

    echo ">>> 格式化 Root..."
    mkfs.ext4 -F "$PART_ROOT"
    echo "Root 格式化完成"
fi

# ===== 挂载 =====
echo ">>> 挂载 Root 到 /mnt..."
mount "$PART_ROOT" /mnt
echo "Root 已挂载"

echo ">>> 创建挂载点..."
mkdir -p /mnt/boot /mnt/home
echo "挂载点已创建"

echo ">>> 挂载 EFI 到 /mnt/boot..."
mount "$PART_EFI" /mnt/boot
echo "EFI 已挂载"

echo ">>> 激活 Swap..."
swapon "$PART_SWAP"
echo "Swap 已激活"

echo ">>> 挂载 Home 到 /mnt/home..."
mount "$PART_HOME" /mnt/home
echo "Home 已挂载"

# ===== 镜像源 =====
echo ">>> 使用 reflector 更新镜像源（按速度排序）..."
echo "正在测试镜像下载速度，可能需要 1~2 分钟，请稍候..."
cp /etc/pacman.d/mirrorlist "/etc/pacman.d/mirrorlist.bak.$$" 2>/dev/null || true

reflector \
    --country China \
    --protocol https \
    --latest 5 \
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
pacstrap /mnt base linux linux-firmware base-devel vim networkmanager sudo xfsprogs grub efibootmgr git openssh curl plymouth fastfetch $CPU_UCODE
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
    printf 'USERNAME=%q\n' "$USERNAME"
} > /mnt/root/config.env
chmod 600 /mnt/root/config.env
echo "配置变量文件已写入"

echo ">>> 准备 chroot 配置脚本..."
cat <<'INNER_EOF' > /mnt/root/config.sh
#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

source /root/config.env

IFS= read -r ROOT_PASSWORD
IFS= read -r USER_PASSWORD

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

echo ">>> 配置 GitHub520 hosts 自动更新..."
cat > /usr/local/bin/github520-update.sh <<'UPDATE_EOF'
#!/bin/bash
set -Eeo pipefail

GITHUB520_URL="https://raw.fastgit.org/521xueweihan/GitHub520/main/hosts"
HOSTS_FILE="/etc/hosts"
HOSTS_TMP=$(mktemp)
START_MARKER="# GITHUB520_START"
END_MARKER="# GITHUB520_END"

cleanup() {
    rm -f "$HOSTS_TMP"
}
trap cleanup EXIT

download_github520() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 30 "$GITHUB520_URL" > "$HOSTS_TMP"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=30 "$GITHUB520_URL" > "$HOSTS_TMP"
    else
        echo "GitHub520 更新失败：未找到 curl 或 wget" >&2
        exit 1
    fi
}

MAX_RETRIES=3
for attempt in $(seq 1 "$MAX_RETRIES"); do
    if download_github520 && [ -s "$HOSTS_TMP" ]; then
        break
    fi
    echo "GitHub520 下载失败（第 ${attempt}/${MAX_RETRIES} 次）" >&2
    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        sleep 3
    fi
done

if [ ! -s "$HOSTS_TMP" ]; then
    echo "GitHub520 更新失败：${MAX_RETRIES} 次尝试均失败" >&2
    exit 1
fi

# 移除旧的 GitHub520 段（如果存在），避免重复堆积
# 使用 | 作为分隔符，避免标记值含 / 时导致 sed 语法错误
if grep -qF "$START_MARKER" "$HOSTS_FILE"; then
    sed -i "\|${START_MARKER}|,\|${END_MARKER}|d" "$HOSTS_FILE"
fi

# 追加新的 GitHub520 段（用标记包裹，便于下次更新时定位）
{
    echo "$START_MARKER"
    cat "$HOSTS_TMP"
    echo "$END_MARKER"
} >> "$HOSTS_FILE"

echo "GitHub520 hosts 更新完成（$(date)）"
UPDATE_EOF
chmod +x /usr/local/bin/github520-update.sh

cat > /etc/systemd/system/github520-update.service <<'SERVICE_EOF'
[Unit]
Description=Update GitHub520 hosts
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/github520-update.sh
SERVICE_EOF

cat > /etc/systemd/system/github520-update.timer <<'TIMER_EOF'
[Unit]
Description=Run GitHub520 hosts update every hour

[Timer]
OnBootSec=5min
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

echo ">>> 首次运行 GitHub520 更新..."
/usr/local/bin/github520-update.sh || echo "警告：GitHub520 首次更新失败，将在系统启动后由 timer 自动重试"

echo ">>> 启用 GitHub520 定时更新..."
systemctl enable github520-update.timer
echo "GitHub520 定时更新已启用"

echo ">>> 设置 root 密码..."
printf '%s\n' "root:${ROOT_PASSWORD}" | chpasswd
echo "root 密码设置完成"

echo ">>> 创建用户 ${USERNAME}..."
if [ -d "/home/${USERNAME}" ]; then
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

echo ">>> 配置登录时运行 fastfetch..."
USER_BASHRC="/home/${USERNAME}/.bashrc"
if ! grep -qx 'fastfetch' "$USER_BASHRC" 2>/dev/null; then
    echo 'fastfetch' >> "$USER_BASHRC"
fi
chown "${USERNAME}:${USERNAME}" "$USER_BASHRC"
echo "fastfetch 已配置"

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

echo ">>> 配置 Plymouth 启动动画..."
if grep -q '\bplymouth\b' /etc/mkinitcpio.conf; then
    :
elif grep -qE '^HOOKS=.*\budev\b' /etc/mkinitcpio.conf; then
    sed -i '/^HOOKS=/s/\budev\b/udev plymouth/' /etc/mkinitcpio.conf
elif grep -qE '^HOOKS=.*\bsystemd\b' /etc/mkinitcpio.conf; then
    sed -i '/^HOOKS=/s/\bsystemd\b/systemd plymouth/' /etc/mkinitcpio.conf
elif grep -qE '^HOOKS=\(' /etc/mkinitcpio.conf; then
    sed -i '/^HOOKS=(/s/)/ plymouth)/' /etc/mkinitcpio.conf
else
    echo "错误：无法在 mkinitcpio.conf 中定位 HOOKS 行以添加 plymouth。"
    exit 1
fi
if ! grep -q 'splash' /etc/default/grub; then
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/"\(.*\)"/"\1 splash"/' /etc/default/grub
fi

echo ">>> 安装 Plymouth 主题 catppuccin..."
PLYMOUTH_THEME_REPO="https://github.com/catppuccin/plymouth.git"
THEME_SRC="/tmp/catppuccin-plymouth"
PLYMOUTH_FLAVOR="mocha"
FALLBACK_THEME="bgrt"

install_custom_theme() {
    rm -rf "$THEME_SRC"
    local n=1
    while [ $n -le 3 ]; do
        git clone --depth 1 "$PLYMOUTH_THEME_REPO" "$THEME_SRC" && break
        echo "克隆失败（第 ${n} 次），重试中..."
        rm -rf "$THEME_SRC"
        n=$((n + 1))
    done
    [ -d "$THEME_SRC" ] || return 1

    local theme_plymouth theme_name
    theme_plymouth=$(find "$THEME_SRC" -name "*${PLYMOUTH_FLAVOR}*.plymouth" | head -n1)
    [ -n "$theme_plymouth" ] || { echo "仓库中未找到 ${PLYMOUTH_FLAVOR} 风味的 .plymouth 文件"; return 1; }
    theme_name=$(basename "$theme_plymouth" .plymouth)

    if [ -f "${THEME_SRC}/Makefile" ]; then
        make -C "$THEME_SRC" install || return 1
    else
        install -d "/usr/share/plymouth/themes/${theme_name}" || return 1
        cp -r "$(dirname "$theme_plymouth")"/. "/usr/share/plymouth/themes/${theme_name}/" || return 1
    fi
    plymouth-set-default-theme "$theme_name" || return 1
    echo "Plymouth 主题 ${theme_name} 已设为默认"
    return 0
}

if install_custom_theme; then
    :
else
    echo "警告：自定义主题安装失败，回退到内置主题 ${FALLBACK_THEME}。"
    plymouth-set-default-theme "$FALLBACK_THEME" || echo "警告：回退主题设置失败，将使用 Plymouth 默认主题。"
fi
rm -rf "$THEME_SRC"

mkinitcpio -P
echo "Plymouth 配置完成"

echo ">>> 安装 GRUB 引导..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="GRUB"

echo ">>> 安装 GRUB 主题 catppuccin..."
GRUB_THEME_REPO="https://github.com/catppuccin/grub.git"
GRUB_THEME_SRC="/tmp/catppuccin-grub"
GRUB_THEME_FLAVOR="mocha"

rm -rf "$GRUB_THEME_SRC"
if git clone --depth 1 "$GRUB_THEME_REPO" "$GRUB_THEME_SRC"; then
    GRUB_THEME_DIR=$(find "$GRUB_THEME_SRC/src" -maxdepth 1 -type d -name "*${GRUB_THEME_FLAVOR}*" | head -n1)
    if [ -n "$GRUB_THEME_DIR" ] && [ -f "$GRUB_THEME_DIR/theme.txt" ]; then
        install -d /usr/share/grub/themes
        cp -r "$GRUB_THEME_DIR" /usr/share/grub/themes/
        THEME_DIR_NAME=$(basename "$GRUB_THEME_DIR")
        sed -i '/^GRUB_THEME=/d' /etc/default/grub
        echo "GRUB_THEME=\"/usr/share/grub/themes/${THEME_DIR_NAME}/theme.txt\"" >> /etc/default/grub
        echo "GRUB 主题 catppuccin-${GRUB_THEME_FLAVOR} 已设为默认"
    else
        echo "警告：未找到 catppuccin GRUB 主题文件，跳过。"
    fi
else
    echo "警告：克隆 catppuccin/grub 失败，跳过 GRUB 主题安装。"
fi
rm -rf "$GRUB_THEME_SRC"

grub-mkconfig -o /boot/grub/grub.cfg
echo "GRUB 安装完成"
INNER_EOF

echo ">>> 进入 chroot 环境执行配置..."
printf '%s\n%s\n' "$ROOT_PASSWORD" "$USER_PASSWORD" | arch-chroot /mnt bash /root/config.sh
echo "chroot 配置完成"

echo ">>> 清理临时脚本..."
rm /mnt/root/config.sh /mnt/root/config.env
echo "临时脚本已清理"

# ===== 卸载 =====
echo ">>> 卸载分区..."
swapoff "$PART_SWAP"
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