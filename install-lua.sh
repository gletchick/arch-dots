#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
sourceDir="$PWD/.config/hypr"
targetDir="$HOME/.config/hypr"
[[ -d "$targetDir" ]] || { echo "Missing $targetDir" >&2; exit 1; }
[[ -d "$sourceDir" ]] || { echo "Missing $sourceDir" >&2; exit 1; }
backup="$HOME/.config/hypr.backup-before-lua-$(date +%Y%m%d-%H%M%S)"
cp -a "$targetDir" "$backup"
echo "Backup: $backup"
installed=0
skipped=0
while IFS= read -r -d '' src; do
  rel="${src#"$sourceDir"/}"
  dst="$targetDir/$rel"
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" && "$src" -ef "$dst" ]]; then
    printf 'Already in place: %s\n' "$rel"
    ((skipped+=1))
    continue
  fi
  # If the destination is a symlink, update its actual file (e.g. in the dots repo)
  # rather than breaking the symlink.
  if [[ -L "$dst" ]]; then
    resolved="$(readlink -f -- "$dst")"
    [[ -n "$resolved" ]] || { echo "Broken symlink: $dst" >&2; exit 1; }
    cp -- "$src" "$resolved"
  else
    cp -- "$src" "$dst"
  fi
  ((installed+=1))
done < <(find "$sourceDir" -type f -print0)
echo "Installed: $installed; already in place: $skipped"
echo "Run: hyprctl reload && hyprctl configerrors"
