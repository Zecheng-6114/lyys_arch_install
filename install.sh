#!/bin/bash
set -Eeo pipefail

# ===== 输出样式 =====

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}>>> ${1}${NC}"; }
success() { echo -e "  ${GREEN}✓${NC} ${1}"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} ${1}" >&2; }
error()   { echo -e "  ${RED}✗${NC} ${1}" >&2; }
fatal()   { error "$1"; exit 1; }

trap 'fatal "步骤失败（行 ${LINENO}）：${BASH_COMMAND}"' ERR

# ===== 多线程下载引擎（纯 curl，基于 HTTP Range） =====

MT_DOWNLOAD="/tmp/.mt-download.sh"

create_mt_download() {
    cat > "$MT_DOWNLOAD" << 'MTSCRIPT'
#!/bin/bash
output="$1"
url="$2"
threads=4

filesize=$(curl -sI -L "$url" 2>/dev/null | grep -i '^content-length:' | tail -1 | awk '{print $2}' | tr -d '\r\n')

if [ -z "$filesize" ] || [ "$filesize" -lt 524288 ]; then
    exec curl -fL --retry 3 -o "$output" "$url"
fi

code=$(curl -sI -L -H "Range: bytes=0-0" "$url" -o /dev/null -w '%{http_code}' 2>/dev/null)
if [ "$code" != "206" ]; then
    exec curl -fL --retry 3 -o "$output" "$url"
fi

chunk_size=$((filesize / threads))
pids=()
for i in $(seq 0 $((threads - 1))); do
    start=$((i * chunk_size))
    if [ "$i" -eq $((threads - 1)) ]; then
        end=$((filesize - 1))
    else
        end=$(((i + 1) * chunk_size - 1))
    fi
    curl -fs -L -H "Range: bytes=$start-$end" --retry 3 -o "${output}.mt.${i}" "$url" &
    pids+=($!)
done

for pid in "${pids[@]}"; do
    wait "$pid" || { rm -f "${output}.mt."*; exec curl -fL --retry 3 -o "$output" "$url"; }
done

: > "$output"
for i in $(seq 0 $((threads - 1))); do
    cat "${output}.mt.${i}" >> "$output"
    rm -f "${output}.mt.${i}"
done
MTSCRIPT
    chmod +x "$MT_DOWNLOAD"
}

# ===== 工具函数 =====

prompt_password() {
    local var_name="$1" prompt="$2"
    local confirm_name="${var_name}_CONFIRM"
    while true; do
        read -s -p "$prompt: " "${var_name}" < /dev/tty; echo
        read -s -p "确认${prompt}: " "$confirm_name" < /dev/tty; echo
        if [ -z "${!var_name}" ]; then
            warn "密码不能为空，请重新输入。"
        elif [ "${!var_name}" != "${!confirm_name}" ]; then
            warn "两次输入不一致，请重新输入。"
        else
            break
        fi
    done
}

check_partitions() {
    local missing=0
    for part in "$@"; do
        if [ -b "$part" ]; then
            success "分区存在: $part"
        else
            error "分区不存在: $part"
            missing=1
        fi
    done
    [ $missing -eq 0 ]
}

# ===== Root 权限检查 =====
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误：请使用 root 权限运行此脚本${NC}" >&2
    echo -e "正确用法：" >&2
    echo -e "  curl -L <url> | sudo bash" >&2
    echo -e "  或：sudo bash install.sh" >&2
    exit 1
fi

echo -e "\n${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Arch Linux 自动化安装工具        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}\n"

# ===== 依赖工具检查 =====
info "检查依赖工具..."

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
    warn "缺少依赖工具:${MISSING_TOOLS}"
    warn "对应软件包:${MISSING_PKGS}"
    if ! command -v pacman >/dev/null 2>&1; then
        fatal "未找到 pacman，无法自动安装，请手动安装后重试。"
    fi
    read -p "$(echo -e "  ${BOLD}?${NC} 是否现在用 pacman 安装？[y/N]: ")" INSTALL_DEPS < /dev/tty
    if [[ "$INSTALL_DEPS" =~ ^[Yy]$ ]]; then
        pacman -Sy --needed --noconfirm $MISSING_PKGS
        for tool in $MISSING_TOOLS; do
            command -v "$tool" >/dev/null 2>&1 || fatal "安装后仍缺少工具 ${tool}，请手动检查。"
        done
        success "依赖工具安装完成"
    else
        fatal "已取消，请手动安装依赖后重试。"
    fi
fi
success "依赖工具检查通过"

# ===== 创建多线程下载引擎 =====
create_mt_download
success "多线程下载引擎就绪 ${DIM}(curl Range × 4 连接)${NC}"

# ===== 配置变量 =====
info "检测可用磁盘..."
DISK_LIST=$(timeout 10 lsblk -dpno NAME,SIZE,MODEL,TYPE 2>/dev/null)
if [ -z "$DISK_LIST" ]; then
    warn "lsblk 未能正常返回磁盘列表，尝试简化检测..."
    DISK_LIST=$(lsblk -dpno NAME,TYPE 2>/dev/null | grep disk || echo "")
    if [ -z "$DISK_LIST" ]; then
        fatal "无法获取磁盘列表，请检查系统存储设备。"
    fi
fi
echo -e "${DIM}${DISK_LIST}${NC}"
echo ""

DEFAULT_DISK=$(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1; exit}')
read -p "$(echo -e "  ${BOLD}?${NC} 目标磁盘 [默认 ${DEFAULT_DISK}]: ")" DISK < /dev/tty
DISK="${DISK:-$DEFAULT_DISK}"

read -p "$(echo -e "  ${BOLD}?${NC} 主机名 [默认 arch]: ")" HOSTNAME < /dev/tty
HOSTNAME="${HOSTNAME:-arch}"

read -p "$(echo -e "  ${BOLD}?${NC} 用户名 [默认 user]: ")" USERNAME < /dev/tty
USERNAME="${USERNAME:-user}"

read -p "$(echo -e "  ${BOLD}?${NC} 时区 [默认 Asia/Shanghai]: ")" TIMEZONE < /dev/tty
TIMEZONE="${TIMEZONE:-Asia/Shanghai}"

read -p "$(echo -e "  ${BOLD}?${NC} 语言环境 [默认 zh_CN.UTF-8]: ")" LOCALE < /dev/tty
LOCALE="${LOCALE:-zh_CN.UTF-8}"

prompt_password ROOT_PASSWORD "root 密码"
prompt_password USER_PASSWORD "用户 ${USERNAME} 密码"

[ -b "$DISK" ] || fatal "磁盘 $DISK 不存在。"

echo -e "\n${BOLD}配置确认：${NC}"
echo -e "  磁盘    = ${BOLD}${DISK}${NC}"
echo -e "  主机名  = ${BOLD}${HOSTNAME}${NC}"
echo -e "  用户名  = ${BOLD}${USERNAME}${NC}"
echo -e "  时区    = ${BOLD}${TIMEZONE}${NC}"
echo -e "  语言    = ${BOLD}${LOCALE}${NC}"
echo -e "  加速    = ${BOLD}curl 多线程 (4 连接/文件)${NC}"
echo ""

# ===== 检查 UEFI =====
[ -d /sys/firmware/efi ] || fatal "仅支持 UEFI 启动模式。"
success "UEFI 启动模式已确认"

# ===== 安装模式 =====
echo -e "\n${BOLD}选择安装模式：${NC}"
echo -e "  1) 全新安装 ${DIM}— 清空磁盘${NC}"
echo -e "  2) 仅重装 Root ${DIM}— 保留 Home${NC}"
read -p "$(echo -e "  ${BOLD}?${NC} 输入选项 [1/2]: ")" MODE_CHOICE < /dev/tty

if [[ "$MODE_CHOICE" == "1" ]]; then
    INSTALL_MODE="full"
elif [[ "$MODE_CHOICE" == "2" ]]; then
    INSTALL_MODE="reinstall_root"
else
    fatal "无效输入，退出。"
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

# ===== 按磁盘大小配比 Root 分区 =====
DISK_BYTES=$(lsblk -bdno SIZE "$DISK")
DISK_MIB=$((DISK_BYTES / 1024 / 1024))
EFI_MIB=1024

ROOT_MIB=$((DISK_MIB / 4))
[ $ROOT_MIB -lt 30720 ] && ROOT_MIB=30720
[ $ROOT_MIB -gt 153600 ] && ROOT_MIB=153600

NEED_MIB=$((EFI_MIB + SWAP_MIB + ROOT_MIB + 5120))
[ $DISK_MIB -ge $NEED_MIB ] || fatal "磁盘容量不足（${DISK_MIB} MiB），至少需要 ${NEED_MIB} MiB。"

echo -e "\n${BOLD}分区方案：${NC}"
echo -e "  EFI  = ${EFI_MIB} MiB"
echo -e "  Swap = ${SWAP_MIB} MiB ${DIM}(内存 ${TOTAL_MEM_MIB} MiB)${NC}"
echo -e "  Root = ${ROOT_MIB} MiB"
echo -e "  Home = 剩余空间"
echo ""

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
    echo -e "  ${RED}${BOLD}警告：【全新安装】将清空 ${DISK} 全部数据！${NC}"
else
    echo -e "  ${YELLOW}${BOLD}警告：【仅重装 Root】将格式化 EFI/Swap/Root，保留 Home。${NC}"
fi

read -p "$(echo -e "  ${BOLD}?${NC} 输入 'yes' 继续: ")" confirm < /dev/tty
if [[ "$confirm" != "yes" ]]; then
    echo -e "  已取消。"
    exit 0
fi

# ===== 清理旧挂载 =====
info "清理旧的挂载和 Swap 激活..."
umount -R /mnt 2>/dev/null || true
swapoff "${PART_SWAP}" 2>/dev/null || true

# ===== 同步时钟 =====
info "同步系统时钟..."
timedatectl set-ntp true

# ===== 分区与格式化 =====
if [[ "$INSTALL_MODE" == "full" ]]; then
    info "创建分区..."
    sgdisk -Z "$DISK"
    sgdisk -n 1::+${EFI_MIB}M -t 1:ef00 -c 1:"EFI" "$DISK"
    sgdisk -n 2::+${SWAP_MIB}M -t 2:8200 -c 2:"SWAP" "$DISK"
    sgdisk -n 3::+${ROOT_MIB}M -t 3:8300 -c 3:"ROOT" "$DISK"
    sgdisk -n 4:0:0 -t 4:8300 -c 4:"HOME" "$DISK"
    success "分区创建完成"
else
    info "检查现有分区..."
    check_partitions "$PART_EFI" "$PART_SWAP" "$PART_ROOT" "$PART_HOME"
fi

info "格式化分区..."
mkfs.fat -F32 "$PART_EFI"  >/dev/null
mkswap "$PART_SWAP"         >/dev/null
mkfs.ext4 -F "$PART_ROOT"  >/dev/null
if [[ "$INSTALL_MODE" == "full" ]]; then
    mkfs.xfs -f "$PART_HOME" >/dev/null
fi
success "格式化完成 ${DIM}(EFI/FAT32, Swap, Root/ext4, Home/xfs)${NC}"

# ===== 挂载 =====
info "挂载分区..."
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot /mnt/home
mount "$PART_EFI" /mnt/boot
swapon "$PART_SWAP"
mount "$PART_HOME" /mnt/home
success "挂载完成"

# ===== 镜像源 =====
info "使用 reflector 更新镜像源（按速度排序）..."
echo -e "  ${DIM}正在测试镜像下载速度，请稍候...${NC}"
cp /etc/pacman.d/mirrorlist "/etc/pacman.d/mirrorlist.bak.$$" 2>/dev/null || true

reflector \
    --country China \
    --protocol https \
    --latest 10 \
    --sort rate \
    --save /etc/pacman.d/mirrorlist \
    --download-timeout 5 \
    2>/dev/null

success "镜像源配置完成"

# ===== 配置 pacman 多线程下载 =====
sed -i '/^\[options\]/a XferCommand = '"${MT_DOWNLOAD}"' %o %u' /etc/pacman.conf
success "已配置 pacman 多线程下载 ${DIM}(每文件 4 连接并行)${NC}"

# ===== 微码 =====
CPU_UCODE=""
if grep -q "GenuineIntel" /proc/cpuinfo; then
    CPU_UCODE="intel-ucode"
    success "检测到 Intel CPU → intel-ucode"
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    CPU_UCODE="amd-ucode"
    success "检测到 AMD CPU → amd-ucode"
else
    warn "未检测到已知 CPU，跳过微码安装"
fi

# ===== 网络检测 =====
info "检测网络连通性..."
NET_OK=""
for host in 223.5.5.5 8.8.8.8 archlinux.org; do
    if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
        NET_OK="1"
        break
    fi
done
if [ -z "$NET_OK" ]; then
    fatal "无法连接网络，pacstrap 需要联网下载软件包。\n    请先配置网络（有线通常自动获取，无线可用 iwctl 连接）后重试。"
fi
success "网络连通性正常"

# ===== GitHub520 hosts =====
info "配置 GitHub520 hosts..."
sed -i "/# GitHub520 Host Start/Q" /etc/hosts
if curl -fsSL https://raw.hellogithub.com/hosts >> /etc/hosts; then
    success "GitHub520 hosts 配置完成"
else
    warn "GitHub520 hosts 配置失败，继续安装"
fi

# ===== 安装基础系统 =====
info "开始安装基础系统（这可能需要几分钟）..."
PACKAGES="base linux linux-firmware base-devel vim networkmanager sudo xfsprogs grub efibootmgr git openssh curl plymouth fastfetch $CPU_UCODE"
for attempt in 1 2 3; do
    if pacstrap /mnt $PACKAGES; then
        break
    fi
    if [ $attempt -lt 3 ]; then
        warn "pacstrap 失败（第 ${attempt} 次），10 秒后重试..."
        sleep 10
    else
        fatal "pacstrap 多次失败，请检查网络连接和镜像源后重试。"
    fi
done
success "基础系统安装完成"

# ===== fstab =====
info "生成 fstab..."
genfstab -U /mnt > /mnt/etc/fstab
success "fstab 已生成"

# ===== chroot 配置 =====
info "写入配置变量文件..."
{
    printf 'TIMEZONE=%q\n' "$TIMEZONE"
    printf 'LOCALE=%q\n' "$LOCALE"
    printf 'HOSTNAME=%q\n' "$HOSTNAME"
    printf 'USERNAME=%q\n' "$USERNAME"
} > /mnt/root/config.env
chmod 600 /mnt/root/config.env

info "下载配置脚本..."
RAW_BASE="https://raw.githubusercontent.com/Zecheng-6114/lyys_arch_install/main"

install -d /mnt/root /mnt/usr/local/bin /mnt/etc/systemd/system

FILES=(
    "config.sh|/mnt/root/config.sh"
    "github520/update.sh|/mnt/usr/local/bin/github520-update.sh"
    "plymouth-theme/update.sh|/mnt/usr/local/bin/plymouth-theme-update.sh"
    "github520/update.service|/mnt/etc/systemd/system/github520-update.service"
    "github520/update.timer|/mnt/etc/systemd/system/github520-update.timer"
    "plymouth-theme/update.service|/mnt/etc/systemd/system/plymouth-theme-update.service"
    "plymouth-theme/update.timer|/mnt/etc/systemd/system/plymouth-theme-update.timer"
)

pids=()
for entry in "${FILES[@]}"; do
    src="${entry%%|*}"
    dst="${entry##*|}"
    curl -fsSL "${RAW_BASE}/${src}" -o "$dst" &
    pids+=($!)
done

fail=0
for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { error "下载失败 ${FILES[$i]%%|*}"; fail=1; }
done
(( fail )) && exit 1

for entry in "${FILES[@]}"; do
    dst="${entry##*|}"
    [[ "$dst" == *.sh ]] && chmod +x "$dst"
done
success "配置脚本下载完成"

info "进入 chroot 环境执行配置..."
printf '%s\n%s\n' "$ROOT_PASSWORD" "$USER_PASSWORD" | arch-chroot /mnt bash /root/config.sh

# ===== 清理与卸载 =====
info "清理临时脚本..."
rm -f "$MT_DOWNLOAD"
rm /mnt/root/config.sh /mnt/root/config.env

info "卸载分区..."
swapoff "$PART_SWAP"
umount -R /mnt

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════╗${NC}"
if [[ "$INSTALL_MODE" == "full" ]]; then
    echo -e "${GREEN}${BOLD}║    Arch Linux 全新安装完成！         ║${NC}"
else
    echo -e "${GREEN}${BOLD}║    Arch Linux 重装完成 (Home 已保留) ║${NC}"
fi
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════╝${NC}"
echo -e "\n请执行 ${BOLD}reboot${NC} 重启系统。\n"
