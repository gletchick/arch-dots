#!/usr/bin/env bash
# Install/update a private Linux Flutter bundle if this user's GitHub CLI
# credentials grant access. No source checkout, no credentials in dotfiles.
set -euo pipefail

MUSIC_SYNC_REPO="${MUSIC_SYNC_REPO:-gletchick/sync-app}"
MUSIC_SYNC_ASSET="${MUSIC_SYNC_ASSET:-music-sync-linux-x64.tar.gz}"
INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/music-sync/bundle"
BIN_DIR="$HOME/.local/bin"
APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
VERSION_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/music-sync/installed-release"

log() { printf '[music-sync] %s\n' "$*"; }
skip() { log "$* (skipped)"; exit 0; }
fatal() { log "ERROR: $*" >&2; exit 1; }

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    skip 'Only Linux x86_64 release is configured'
fi
if ! command -v gh >/dev/null 2>&1; then
    skip 'GitHub CLI (gh) is not installed; run: sudo pacman -S github-cli'
fi
if ! gh auth status --hostname github.com >/dev/null 2>&1; then
    skip 'GitHub CLI is not authenticated; run: gh auth login --git-protocol ssh'
fi
if ! gh api "repos/$MUSIC_SYNC_REPO" >/dev/null 2>&1; then
    skip "No GitHub API access to $MUSIC_SYNC_REPO (or GitHub unavailable)"
fi

# Read release metadata before touching the installed application.
release_json="$(gh release view --repo "$MUSIC_SYNC_REPO" --json tagName,assets 2>/dev/null)" \
    || skip "No readable published release for $MUSIC_SYNC_REPO"
if ! command -v python3 >/dev/null 2>&1; then
    skip 'python3 is required to inspect release metadata'
fi
if ! release_tag="$(printf '%s' "$release_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tagName"])')"; then
    skip 'Could not read release tag'
fi
if ! MUSIC_SYNC_ASSET_NAME="$MUSIC_SYNC_ASSET" python3 -c '
import json, os, sys
release=json.load(sys.stdin)
asset=os.environ["MUSIC_SYNC_ASSET_NAME"]
sys.exit(0 if any(a["name"] == asset for a in release.get("assets", [])) else 1)
' <<< "$release_json"; then
    skip "Release $release_tag has no asset named $MUSIC_SYNC_ASSET"
fi

if [[ -f "$VERSION_FILE" && -x "$BIN_DIR/music-sync" && -d "$INSTALL_DIR" ]] && \
   [[ "$(cat "$VERSION_FILE")" == "$MUSIC_SYNC_REPO@$release_tag" ]]; then
    log "Already installed: $release_tag"
    exit 0
fi

tmp_dir="$(mktemp -d)"
backup_dir=''
rollback_needed=false
cleanup() {
    if [[ "$rollback_needed" == true && -n "$backup_dir" && -d "$backup_dir" ]]; then
        rm -rf -- "$INSTALL_DIR"
        mv -- "$backup_dir" "$INSTALL_DIR"
    fi
    rm -rf -- "$tmp_dir"
}
trap cleanup EXIT

log "Downloading $MUSIC_SYNC_REPO $release_tag ($MUSIC_SYNC_ASSET)..."
if ! gh release download "$release_tag" --repo "$MUSIC_SYNC_REPO" \
    --pattern "$MUSIC_SYNC_ASSET" --dir "$tmp_dir"; then
    fatal 'Download failed; existing installation was not modified'
fi
archive="$tmp_dir/$MUSIC_SYNC_ASSET"
[[ -s "$archive" ]] || fatal 'Downloaded archive missing or empty'

mkdir -p "$tmp_dir/extracted"
# Private asset is trusted to come from the authorized repository owner.
# Still reject unsafe archive members to avoid writing outside staging.
python3 - "$archive" "$tmp_dir/extracted" <<'PY'
import os, pathlib, sys, tarfile
archive, dest = sys.argv[1:]
with tarfile.open(archive, 'r:gz') as tf:
    for m in tf.getmembers():
        path = pathlib.PurePosixPath(m.name)
        if path.is_absolute() or '..' in path.parts or not (m.isfile() or m.isdir()):
            raise SystemExit(f'Unsafe archive entry: {m.name}')
    tf.extractall(dest, filter='data')
PY

# Release asset may contain the files at its root or under bundle/.
bundle_dir=''
while IFS= read -r -d '' data_dir; do
    candidate="$(dirname "$data_dir")"
    if [[ -d "$candidate/lib" ]]; then
        bundle_dir="$candidate"
        break
    fi
done < <(find "$tmp_dir/extracted" -maxdepth 4 -type d -name data -print0)
[[ -n "$bundle_dir" ]] || fatal 'Archive lacks Flutter Linux bundle data/ and lib/ directories'

mapfile -t executables < <(find "$bundle_dir" -maxdepth 1 -type f -executable -printf '%f\n')
(( ${#executables[@]} == 1 )) || fatal 'Cannot uniquely identify executable in bundle root'
app_binary="${executables[0]}"

# Stage on the same filesystem as the final directory for atomic rename.
mkdir -p "$(dirname "$INSTALL_DIR")" "$BIN_DIR" "$APPS_DIR" "$(dirname "$VERSION_FILE")"
staged_dir="$(mktemp -d "$(dirname "$INSTALL_DIR")/.music-sync-stage.XXXXXX")"
trap 'cleanup; rm -rf -- "${staged_dir:-}"' EXIT
cp -a "$bundle_dir/." "$staged_dir/"

if [[ -d "$INSTALL_DIR" ]]; then
    backup_dir="$(dirname "$INSTALL_DIR")/.music-sync-previous.$$"
    mv -- "$INSTALL_DIR" "$backup_dir"
    rollback_needed=true
fi
mv -- "$staged_dir" "$INSTALL_DIR"

# Keep data and libraries beside the executable, set cwd explicitly.
printf -v quoted_install '%q' "$INSTALL_DIR"
printf -v quoted_binary '%q' "$app_binary"
cat > "$BIN_DIR/music-sync" <<LAUNCHER
#!/usr/bin/env bash
cd -- $quoted_install || exit 1
exec $quoted_install/$quoted_binary "\$@"
LAUNCHER
chmod +x "$BIN_DIR/music-sync"

cat > "$APPS_DIR/music-sync.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Music Sync
Comment=Music player with device synchronization
Exec=$BIN_DIR/music-sync
Terminal=false
Categories=Audio;AudioVideo;Player;
StartupNotify=true
DESKTOP

printf '%s\n' "$MUSIC_SYNC_REPO@$release_tag" > "$VERSION_FILE"
rollback_needed=false
if [[ -n "$backup_dir" ]]; then rm -rf -- "$backup_dir"; fi
log "Installed $release_tag. Launcher: $BIN_DIR/music-sync"
