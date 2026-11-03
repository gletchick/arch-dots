#!/bin/bash

if hyprctl clients | grep -q "org.telegram.desktop"; then
    hyprctl dispatch togglespecialworkspace tg
else
    Telegram &
    sleep 0.5
    hyprctl dispatch togglespecialworkspace tg
fi
