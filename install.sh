#!/bin/bash
# Install or remove hyprland-monitor-wake-fix for the current user. No root needed.
#
# Usage: ./install.sh              install and start the service
#        ./install.sh --uninstall  stop the service and remove both files

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir=$HOME/.local/bin
unit_dir=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
name=hyprland-monitor-wake-fix

if [[ ${1:-} == --uninstall ]]; then
  systemctl --user disable --now "$name.service" 2>/dev/null || true
  rm -f "$bin_dir/$name" "$unit_dir/$name.service"
  systemctl --user daemon-reload
  echo "Removed $name"
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
