#!/bin/bash
set -Eeo pipefail
trap 'echo "错误：步骤失败（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

source /root/config.env

IFS= read -r ROOT_PASSWORD
IFS= read -r USER_PASSWORD

# --- 时区 ---
echo ">>> 配置时区..."
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
hwclock --systohc

# --- 语言环境 ---
echo ">>> 配置语言环境..."
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
sed -i "\|${LOCALE}|s/^#//" /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

# --- 主机名 ---
echo ">>> 配置主机名..."
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTFILE
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTFILE

# --- archlinuxcn 软件源 ---
echo ">>> 配置 archlinuxcn 软件源..."
cat >> /etc/pacman.conf <<'CNREPO'

[archlinuxcn]
Server = https://mirrors.zju.edu.cn/archlinuxcn/$arch
CNREPO
pacman -Sy --noconfirm archlinux-keyring archlinuxcn-keyring

# --- GitHub520 hosts 自动更新 ---
echo ">>> 配置 GitHub520 hosts 自动更新..."
chmod +x /usr/local/bin/github520-update.sh
/usr/local/bin/github520-update.sh || echo "警告：GitHub520 首次更新失败，将在系统启动后由 timer 自动重试"
systemctl enable github520-update.timer

# --- 密码与用户 ---
echo ">>> 设置 root 密码..."
printf '%s\n' "root:${ROOT_PASSWORD}" | chpasswd

echo ">>> 创建用户 ${USERNAME}..."
if [ -d "/home/${USERNAME}" ]; then
    EXIST_UID=$(stat -c '%u' "/home/${USERNAME}")
    EXIST_GID=$(stat -c '%g' "/home/${USERNAME}")
    echo "检测到已有家目录，沿用 UID=${EXIST_UID} GID=${EXIST_GID}"
    getent group "$EXIST_GID" >/dev/null 2>&1 || groupadd -g "$EXIST_GID" "${USERNAME}"
else
    useradd -m -G wheel -s /bin/bash "${USERNAME}"
fi
printf '%s\n' "${USERNAME}:${USER_PASSWORD}" | chpasswd

# --- 用户配置 ---
echo ">>> 配置登录时运行 fastfetch..."
USER_BASHRC="/home/${USERNAME}/.bashrc"
if ! grep -qx 'fastfetch' "$USER_BASHRC" 2>/dev/null; then
    echo 'fastfetch' >> "$USER_BASHRC"
fi
chown "${USERNAME}:${USERNAME}" "$USER_BASHRC"

echo ">>> 配置 sudo 权限..."
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/99-wheel
chmod 440 /etc/sudoers.d/99-wheel

# --- 系统服务 ---
echo ">>> 启用系统服务..."
systemctl enable NetworkManager
systemctl enable sshd

# --- Plymouth ---
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

echo ">>> 安装 Plymouth 自定义主题..."
chmod +x /usr/local/bin/plymouth-theme-update.sh
systemctl enable plymouth-theme-update.timer
/usr/local/bin/plymouth-theme-update.sh || {
    echo "警告：自定义主题安装失败，回退到内置主题 bgrt。"
    plymouth-set-default-theme bgrt || echo "警告：回退主题设置失败。"
}

mkinitcpio -P

# --- GRUB ---
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

# --- AUR 助手 ---
echo ">>> 安装 paru (AUR 助手)..."
pacman -S --noconfirm paru
