#!/bin/bash
SELF="/usr/local/bin/github520-update.sh"
REMOTE_URL="https://raw.githubusercontent.com/Zecheng-6114/lyys_arch_install/main/github520/update.sh"

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
sed -i "/# GitHub520 Host Start/Q" /etc/hosts
curl -fsSL https://raw.hellogithub.com/hosts >> /etc/hosts
