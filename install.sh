#!/bin/bash
set -Eeo pipefail
trap 'echo "错误（行 ${LINENO}）：${BASH_COMMAND}" >&2; exit 1' ERR

[ "$(id -u)" -ne 0 ] && { echo "请使用 root 权限运行" >&2; exit 1; }
[ ! -d /sys/firmware/efi ] && { echo "仅支持 UEFI 模式" >&2; exit 1; }

echo "=== Arch Linux 安装脚本 ==="
lsblk -dpno NAME,SIZE,MODEL,TYPE
echo ""

read -p "目标磁盘: " DISK < /dev/tty
read -p "主机名 [arch]: " HOSTNAME < /dev/tty;    HOSTNAME="${HOSTNAME:-arch}"
read -p "用户名 [user]: " USERNAME < /dev/tty;    USERNAME="${USERNAME:-user}"
read -p "时区 [Asia/Shanghai]: " TZ < /dev/tty;   TZ="${TZ:-Asia/Shanghai}"
read -p "语言 [zh_CN.UTF-8]: " LOCALE < /dev/tty; LOCALE="${LOCALE:-zh_CN.UTF-8}"

read -s -p "root 密码: " ROOT_PW < /dev/tty; echo
read -s -p "用户密码: " USER_PW < /dev/tty; echo

# 分区
[[ "${DISK: -1}" =~ [0-9] ]] && P="${DISK}p" || P="$DISK"

MEM_MIB=$(awk '/MemTotal/{$2=int($2/1024); print $2}' /proc/meminfo)
(( SWAP = MEM_MIB <= 2048 ? MEM_MIB*2 : MEM_MIB <= 8192 ? MEM_MIB : MEM_MIB <= 65536 ? MEM_MIB*3/4 : 16384 ))
(( SWAP > 16384 )) && SWAP=16384

DISK_MIB=$(($(lsblk -bdno SIZE "$DISK") / 1048576))
(( ROOT = DISK_MIB / 4 ))
(( ROOT < 30720 ))  && ROOT=30720
(( ROOT > 153600 )) && ROOT=153600

echo "EFI=1024M  Swap=${SWAP}M  Root=${ROOT}M  Home=剩余"
read -p "输入 yes 确认执行: " confirm < /dev/tty
[[ "$confirm" != "yes" ]] && exit 0

umount -R /mnt 2>/dev/null || true
swapoff "${P}2" 2>/dev/null || true
timedatectl set-ntp true

sgdisk -Z "$DISK"
sgdisk -n 1::+1024M  -t 1:ef00 "$DISK"
sgdisk -n 2::+${SWAP}M -t 2:8200 "$DISK"
sgdisk -n 3::+${ROOT}M -t 3:8300 "$DISK"
sgdisk -n 4:0:0      -t 4:8300 "$DISK"

mkfs.fat -F32 "${P}1"
mkswap "${P}2"
mkfs.ext4 -F "${P}3"
mkfs.xfs -f "${P}4"

mount "${P}3" /mnt
mkdir -p /mnt/boot /mnt/home
mount "${P}1" /mnt/boot
swapon "${P}2"
mount "${P}4" /mnt/home

# 镜像源
reflector --country China --protocol https --latest 10 --sort rate --save /etc/pacman.d/mirrorlist --download-timeout 5 2>/dev/null

# 多线程下载（纯 curl Range 分片，每文件 4 连接）
cat > /tmp/.mt-dl.sh << 'MTDL'
#!/bin/bash
o="$1"; u="$2"
fs=$(curl -sI -L "$u" 2>/dev/null | grep -i '^content-length:' | tail -1 | awk '{print $2}' | tr -d '\r\n')
if [ -z "$fs" ] || [ "$fs" -lt 524288 ] || [ "$(curl -sI -L -H 'Range: bytes=0-0' "$u" -o /dev/null -w '%{http_code}' 2>/dev/null)" != "206" ]; then
    exec curl -fL -o "$o" "$u"
fi
cs=$((fs/4)); pids=()
for i in 0 1 2 3; do
    s=$((i*cs)); [ $i -eq 3 ] && e=$((fs-1)) || e=$(((i+1)*cs-1))
    curl -fs -L -H "Range: bytes=$s-$e" -o "${o}.p$i" "$u" & pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" || { rm -f "${o}".p*; exec curl -fL -o "$o" "$u"; }; done
: > "$o"; for i in 0 1 2 3; do cat "${o}.p$i" >> "$o"; rm -f "${o}.p$i"; done
MTDL
chmod +x /tmp/.mt-dl.sh
sed -i '/^\[options\]/a XferCommand = /tmp/.mt-dl.sh %o %u' /etc/pacman.conf

# GitHub520 hosts
sed -i "/# GitHub520 Host Start/Q" /etc/hosts
curl -fsSL https://raw.hellogithub.com/hosts >> /etc/hosts 2>/dev/null || true

# 微码
grep -q "GenuineIntel" /proc/cpuinfo && UCODE="intel-ucode" || grep -q "AuthenticAMD" /proc/cpuinfo && UCODE="amd-ucode" || UCODE=""

# 安装
pacstrap /mnt base linux linux-firmware base-devel vim networkmanager sudo xfsprogs grub efibootmgr openssh curl $UCODE
genfstab -U /mnt > /mnt/etc/fstab

# 写入 chroot 配置
cat > /mnt/root/setup.sh <<EOF
#!/bin/bash
set -Eeo pipefail
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime && hwclock --systohc
sed -i '/en_US.UTF-8/s/^#//' /etc/locale.gen
sed -i '\\|${LOCALE}|s/^#//' /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS
echo 'root:${ROOT_PW}' | chpasswd
useradd -m -G wheel -s /bin/bash ${USERNAME}
echo '${USERNAME}:${USER_PW}' | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel && chmod 440 /etc/sudoers.d/wheel
systemctl enable NetworkManager sshd
# GitHub520 hosts + 定时更新
sed -i "/# GitHub520 Host Start/Q" /etc/hosts
curl -fsSL https://raw.hellogithub.com/hosts >> /etc/hosts 2>/dev/null || true
cat > /usr/local/bin/github520-update.sh << 'G520'
#!/bin/bash
sed -i "/# GitHub520 Host Start/Q" /etc/hosts
curl -fsSL https://raw.hellogithub.com/hosts >> /etc/hosts 2>/dev/null
G520
chmod +x /usr/local/bin/github520-update.sh
cat > /etc/systemd/system/github520-update.service << 'SVC'
[Unit]
Description=Update GitHub520 hosts
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/github520-update.sh
SVC
cat > /etc/systemd/system/github520-update.timer << 'TMR'
[Unit]
Description=Run GitHub520 hosts update hourly
[Timer]
OnBootSec=5min
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
TMR
systemctl enable github520-update.timer
# archlinuxcn + paru
cat >> /etc/pacman.conf <<'CNREPO'

[archlinuxcn]
Server = https://mirrors.zju.edu.cn/archlinuxcn/\$arch
CNREPO
pacman -Sy --noconfirm archlinux-keyring archlinuxcn-keyring paru
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF
chmod +x /mnt/root/setup.sh
arch-chroot /mnt bash /root/setup.sh
rm /mnt/root/setup.sh

swapoff "${P}2"
umount -R /mnt
rm -f /tmp/.mt-dl.sh

echo "=== 安装完成，请 reboot 重启 ==="
