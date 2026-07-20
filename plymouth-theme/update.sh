#!/bin/bash
SELF="/usr/local/bin/plymouth-theme-update.sh"
REMOTE_URL="https://raw.githubusercontent.com/Zecheng-6114/lyys_arch_install/main/plymouth-theme/update.sh"

self_update() {
    local tmp
    tmp=$(mktemp)
    if curl -fsSL "$REMOTE_URL" -o "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
        if ! cmp -s "$tmp" "$SELF"; then
            cp "$tmp" "$SELF"
            chmod +x "$SELF"
            echo "脚本已自更新"
        fi
    fi
    rm -f "$tmp"
}

self_update

REPO="https://github.com/Zecheng-6114/lyys-plymouthd-theme.git"
CACHE="/var/cache/lyys-plymouth-theme"

install_from_cache() {
    local theme_plymouth theme_name
    theme_plymouth=$(ls "$CACHE"/*.plymouth 2>/dev/null | head -n1)
    [ -n "$theme_plymouth" ] || return 1
    theme_name=$(basename "$theme_plymouth" .plymouth)

    install -d "/usr/share/plymouth/themes/${theme_name}" || return 1
    cp -r "$CACHE"/. "/usr/share/plymouth/themes/${theme_name}/" || return 1
    plymouth-set-default-theme "$theme_name" || return 1
    mkinitcpio -P
    return 0
}

if [ -d "$CACHE/.git" ]; then
    LOCAL_HASH=$(git -C "$CACHE" rev-parse HEAD)
    REMOTE_HASH=$(git ls-remote "$REPO" HEAD | cut -f1)
    if [ -z "$REMOTE_HASH" ]; then
        echo "无法获取远程版本，跳过更新"
        exit 0
    fi
    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
        echo "主题已是最新"
        exit 0
    fi
    echo "发现新版本，正在更新..."
    git -C "$CACHE" pull --ff-only || {
        echo "拉取失败，重新克隆..."
        rm -rf "$CACHE"
        git clone --depth 1 "$REPO" "$CACHE" || exit 1
    }
else
    echo "首次下载主题..."
    rm -rf "$CACHE"
    git clone --depth 1 "$REPO" "$CACHE" || exit 1
fi

install_from_cache && echo "主题更新完成" || echo "主题安装失败"
