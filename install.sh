#!/bin/bash
# Install or remove hyprland-monitor-wake-fix for the current user. No root needed.
#
# Usage: ./install.sh              install and start the service
#        ./install.sh --uninstall  stop the service and remove both files
#
# Optional, and the only part that needs root:
#        sudo ./install.sh --root-helper            install the detect helper
#        sudo ./install.sh --uninstall-root-helper  remove it

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir=$HOME/.local/bin
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
name=hyprland-monitor-wake-fix

helper=/usr/local/libexec/$name-detect
rule=/etc/sudoers.d/$name

if [[ ${1:-} == --root-helper ]]; then
  if ((EUID != 0)) || [[ -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
    echo "Run this as yourself through sudo: sudo ./install.sh --root-helper" >&2
    exit 1
  fi
  [[ $SUDO_USER =~ ^[a-z_][a-z0-9_-]*$ ]] || { echo "Unexpected user name: $SUDO_USER" >&2; exit 1; }
  install -d -o root -g root -m755 /usr/local/libexec
  install -o root -g root -m755 "$here/$name-detect" "$helper"
  # A broken sudoers file locks sudo, so it is checked before it goes in.
  draft=$(mktemp)
  trap 'rm -f "$draft"' EXIT
  printf '%s ALL=(root) NOPASSWD: %s\n' "$SUDO_USER" "$helper" >"$draft"
  visudo -cf "$draft" >/dev/null
  install -o root -g root -m440 "$draft" "$rule"
  echo "Installed $helper, which $SUDO_USER may run as root without a password"
  exit 0
fi

if [[ ${1:-} == --uninstall-root-helper ]]; then
  rm -f "$rule" "$helper"
  echo "Removed $helper and $rule"
  exit 0
fi

if [[ ${1:-} == --uninstall ]]; then
  systemctl --user disable --now "$name.service" 2>/dev/null || true
  rm -f "$bin_dir/$name" "$unit_dir/$name.service"
  systemctl --user daemon-reload
  echo "Removed $name"
  [[ -e $helper ]] && echo "The root helper is still installed. Remove it with: sudo ./install.sh --uninstall-root-helper"
  exit 0
fi

for dependency in hyprctl jq; do
  if ! command -v "$dependency" >/dev/null; then
    echo "$name needs $dependency, which is not installed" >&2
    exit 1
  fi
done

install -Dm755 "$here/$name" "$bin_dir/$name"
install -Dm644 "$here/$name.service" "$unit_dir/$name.service"
systemctl --user daemon-reload
systemctl --user enable "$name.service"
systemctl --user restart "$name.service"
echo "Installed $name. Follow it with: journalctl --user -u $name -f"
