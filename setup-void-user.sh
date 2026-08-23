#!/bin/bash
set -euo pipefail

flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install -y io.github.flattool.Warehouse com.github.tchx84.Flatseal com.brave.Browser
mkdir -p $HOME/.config/sway
cp /etc/sway/config $HOME/.config/sway/config
sed -i 's/^set \$menu wmenu-run/set $menu rofi -show combi/' $HOME/.config/sway/config

cat > $HOME/.bashrc << 'EOF'
# If not running interactively, don't do anything
[[ $- != *i* ]] && return

alias ls='ls --color=auto'
PS1='[\u@\h \W]\$ '
export PATH="$HOME/.local/bin:$HOME/.local/share/flatpak/exports/bin:/var/lib/flatpak/exports/bin:$PATH"
EOF

cat > $HOME/.bash_profile << 'EOF'
[ -f $HOME/.bashrc ] && . $HOME/.bashrc
#For the M1 Core this is correct. May vary for other chips
export WLR_DRM_DEVICES=/dev/dri/card0
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
	dbus-run-session sway
fi
EOF

source $HOME/.bash_profile
