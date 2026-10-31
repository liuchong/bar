set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${BAR_SIGN_IDENTITY:-}" ]]; then
    BAR_SIGN_IDENTITY=$(security find-identity -v -p codesigning | awk 'index($0,"Apple Development:"){print $2; exit}')
    export BAR_SIGN_IDENTITY
fi
if [[ -z "$BAR_SIGN_IDENTITY" ]]; then
    echo "Set BAR_SIGN_IDENTITY to a persistent local signing identity before installing." >&2
    exit 1
fi
bash scripts/build.sh
destination="${BAR_INSTALL_DIR:-$(swift -e 'import Foundation; print(FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)[0].path)')}"
running_pid=$(pgrep -f "$destination/Bar.app/Contents/MacOS/Bar" || true)
if [[ -e "$destination/Bar.app" && -n "$running_pid" ]]; then
    echo "Quit Bar before replacing its installed bundle." >&2
    exit 1
fi
mkdir -p "$destination"
ditto dist/Bar.app "$destination/Bar.app"
codesign --verify --strict "$destination/Bar.app"
echo "Installed: $destination/Bar.app"
