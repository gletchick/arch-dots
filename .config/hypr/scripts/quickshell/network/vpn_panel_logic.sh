#!/usr/bin/env bash

# ==============================================================================
# VPN Toggle & Status Script for Quickshell
# ==============================================================================
# Setup Instructions / Requirements:
#
# 1. Make the VPN control scripts executable and place them in /usr/local/bin:
#    sudo chmod +x /usr/local/bin/vpn-up /usr/local/bin/vpn-down
#
# 2. Configure sudoers for passwordless execution (NOPASSWD):
#    Run `sudo visudo -f /etc/sudoers.d/vpn` and add the following line:
#    %wheel ALL=(ALL) NOPASSWD: /usr/local/bin/vpn-up, /usr/local/bin/vpn-down
#
# 3. Make this script executable:
#    chmod +x ~/.config/hypr/scripts/quickshell/network/vpn_panel_logic.sh
#
# 4. Network interface matching:
#    This script detects active interfaces matching: wg*, tun*, awg*, vless*.
# ==============================================================================

is_vpn_active() {
    ip -br link show | grep -E '^(wg|tun|awg|vless)' | grep -q '<.*UP.*>'
}

toggle_vpn() {
    if is_vpn_active; then
        sudo /usr/local/bin/vpn-down
    else
        sudo /usr/local/bin/vpn-up
    fi
}

case "$1" in
    toggle)
        toggle_vpn
        exit 0
        ;;
    up)
        vpn-up
        exit 0
        ;;
    down)
        vpn-down
        exit 0
        ;;
esac

VPN_DEV=$(ip -br link show | grep -E '^(wg|tun|awg|vless)' | grep '<.*UP.*>' | head -n 1 | awk '{print $1}')

if [ -n "$VPN_DEV" ]; then
    echo "{\"active\": true, \"icon\": \"󰦞\", \"text\": \"$VPN_DEV\"}"
else
    echo "{\"active\": false, \"icon\": \"󰦞\", \"text\": \"VPN Off\"}"
fi