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

source /root/config.env

IFS= read -r ROOT_PASSWORD
IFS= read -r USER_PASSWORD

# --- 时区 ---
info "配置时区 → ${TIMEZONE}..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc
success "时区配置完成"

# --- 语言环境 ---
info "配置语言环境 → ${LOCALE}..."
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
sed -i "\|${LOCALE}|s/^#//" /etc/locale.gen
locale-gen >/dev/null
echo "LANG=${LOCALE}" > /etc/locale.conf
success "语言环境配置完成"

# --- 主机名 ---
info "配置主机名 → ${HOSTNAME}..."
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTFILE
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTFILE
success "主机名配置完成"

# --- archlinuxcn 软件源 ---
info "配置 archlinuxcn 软件源..."
cat >> /etc/pacman.conf <<'CNREPO'

[archlinuxcn]
Server = https://mirrors.zju.edu.cn/archlinuxcn/$arch
CNREPO
pacman -Sy --noconfirm archlinux-keyring archlinuxcn-keyring >/dev/null
success "archlinuxcn 软件源配置完成"

# --- GitHub520 hosts 自动更新 ---
info "配置 GitHub520 hosts 自动更新..."
chmod +x /usr/local/bin/github520-update.sh
/usr/local/bin/github520-update.sh || warn "GitHub520 首次更新失败，将在系统启动后由 timer 自动重试"
systemctl enable github520-update.timer >/dev/null
success "GitHub520 hosts 自动更新已启用"

# --- 密码与用户 ---
info "设置 root 密码..."
printf '%s\n' "root:${ROOT_PASSWORD}" | chpasswd

USER_HOME="/home/${USERNAME}"

info "创建用户 ${USERNAME}..."
if [ -d "$USER_HOME" ]; then
    EXIST_UID=$(stat -c '%u' "$USER_HOME")
    EXIST_GID=$(stat -c '%g' "$USER_HOME")
    echo -e "  ${DIM}检测到已有家目录，沿用 UID=${EXIST_UID} GID=${EXIST_GID}${NC}"
    getent group "$EXIST_GID" >/dev/null 2>&1 || groupadd -g "$EXIST_GID" "${USERNAME}"
    useradd -u "$EXIST_UID" -g "$EXIST_GID" -G wheel -s /bin/bash "${USERNAME}"
else
    useradd -m -G wheel -s /bin/bash "${USERNAME}"
fi
printf '%s\n' "${USERNAME}:${USER_PASSWORD}" | chpasswd
success "用户 ${USERNAME} 配置完成"

# --- 用户配置 ---
info "配置登录时运行 fastfetch..."
USER_BASHRC="${USER_HOME}/.bashrc"
if ! grep -qx 'fastfetch' "$USER_BASHRC" 2>/dev/null; then
    echo 'fastfetch' >> "$USER_BASHRC"
fi
chown "${USERNAME}:$(id -gn "${USERNAME}")" "$USER_BASHRC"

info "配置 sudo 权限..."
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/99-wheel
chmod 440 /etc/sudoers.d/99-wheel
success "sudo 权限配置完成"

# --- 系统服务 ---
info "启用系统服务..."
systemctl enable NetworkManager sshd >/dev/null
success "NetworkManager, sshd 已启用"

# --- Plymouth ---
info "配置 Plymouth 启动动画..."
if ! grep -q '\bplymouth\b' /etc/mkinitcpio.conf; then
    if grep -qE '^HOOKS=.*\b(udev|systemd)\b' /etc/mkinitcpio.conf; then
        sed -i '/^HOOKS=/s/\b\(udev\|systemd\)\b/& plymouth/' /etc/mkinitcpio.conf
    elif grep -qE '^HOOKS=\(' /etc/mkinitcpio.conf; then
        sed -i '/^HOOKS=(/s/)/ plymouth)/' /etc/mkinitcpio.conf
    else
        fatal "无法在 mkinitcpio.conf 中定位 HOOKS 行以添加 plymouth。"
    fi
fi

if ! grep -q 'splash' /etc/default/grub; then
    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/"\(.*\)"/"\1 splash"/' /etc/default/grub
fi

info "安装 Plymouth 自定义主题..."
chmod +x /usr/local/bin/plymouth-theme-update.sh
systemctl enable plymouth-theme-update.timer >/dev/null
if /usr/local/bin/plymouth-theme-update.sh; then
    success "Plymouth 自定义主题安装完成"
else
    warn "自定义主题安装失败，回退到内置主题 bgrt"
    plymouth-set-default-theme bgrt || warn "回退主题设置失败"
fi

mkinitcpio -P >/dev/null
success "initramfs 重建完成"

# --- GRUB ---
info "安装 GRUB 引导..."
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="GRUB" >/dev/null 2>&1
success "GRUB 引导安装完成"

info "安装 GRUB 主题 catppuccin-mocha..."
GRUB_THEME_REPO="https://github.com/catppuccin/grub.git"
GRUB_THEME_SRC="/tmp/catppuccin-grub"
GRUB_THEME_FLAVOR="mocha"

rm -rf "$GRUB_THEME_SRC"
if git clone --depth 1 -q "$GRUB_THEME_REPO" "$GRUB_THEME_SRC"; then
    GRUB_THEME_DIR=$(find "$GRUB_THEME_SRC/src" -maxdepth 1 -type d -name "*${GRUB_THEME_FLAVOR}*" | head -n1)
    if [ -n "$GRUB_THEME_DIR" ] && [ -f "$GRUB_THEME_DIR/theme.txt" ]; then
        install -d /usr/share/grub/themes
        cp -r "$GRUB_THEME_DIR" /usr/share/grub/themes/
        THEME_DIR_NAME=$(basename "$GRUB_THEME_DIR")
        sed -i '/^GRUB_THEME=/d' /etc/default/grub
        echo "GRUB_THEME=\"/usr/share/grub/themes/${THEME_DIR_NAME}/theme.txt\"" >> /etc/default/grub
        success "GRUB 主题 catppuccin-${GRUB_THEME_FLAVOR} 已设为默认"
    else
        warn "未找到 catppuccin GRUB 主题文件，跳过"
    fi
else
    warn "克隆 catppuccin/grub 失败，跳过 GRUB 主题安装"
fi
rm -rf "$GRUB_THEME_SRC"

grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
success "GRUB 配置已生成"

# --- AUR 助手 ---
info "安装 paru (AUR 助手)..."
pacman -S --noconfirm paru >/dev/null
success "paru 安装完成"

echo ""
success "系统配置全部完成"
