#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

if (( EUID == 0 )); then
    echo "Run this installer as your normal desktop user, not with sudo." >&2
    exit 1
fi

REPO="MorpheApp/morphe-desktop"
BASE="${MORPHE_PORTABLE_DIR:-$HOME/applications/morphe}"
APP="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONS="${XDG_DATA_HOME:-$HOME/.local/share}/icons"
DESKTOP="$APP/morphe-desktop.desktop"
ICON="$ICONS/morphe-logo.png"

for cmd in curl python3 unzip cmp install mv mktemp find sort grep; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Missing dependency: $cmd" >&2
        exit 1
    }
done

# Install Java 21+ only when no compatible runtime is available.
java_major_version() {
    java -version 2>&1 | python3 -c 'import re,sys; m=re.search(r"\b(?:openjdk|java)(?:\s+version)?\s+\"?(\d+)", sys.stdin.read(), re.I); print(m.group(1) if m else "")'
}
JAVA_MAJOR=""
if command -v java >/dev/null 2>&1; then
    JAVA_MAJOR="$(java_major_version || true)"
fi
if [[ ! "$JAVA_MAJOR" =~ ^[0-9]+$ ]] || (( JAVA_MAJOR < 21 )); then
    echo "Java 21+ is missing; installing OpenJDK 21..."
    command -v sudo >/dev/null 2>&1 || {
        echo "Missing dependency: sudo (required to install Java)" >&2
        exit 1
    }
    command -v dnf >/dev/null 2>&1 || {
        echo "Java 21+ is missing and DNF is unavailable." >&2
        exit 1
    }
    sudo -v || {
        echo "Administrator authentication is required to install Java." >&2
        exit 1
    }
    sudo dnf install -y java-21-openjdk-headless || {
        echo "Could not install OpenJDK 21. Check DNF repositories." >&2
        exit 1
    }
    JAVA_MAJOR="$(java_major_version || true)"
    if [[ ! "$JAVA_MAJOR" =~ ^[0-9]+$ ]] || (( JAVA_MAJOR < 21 )); then
        echo "Java 21+ remains unavailable after package installation." >&2
        exit 1
    fi
fi

mkdir -p "$BASE" "$APP" "$ICONS"
BASE="$(cd -- "$BASE" && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Finding latest Morphe Desktop release..."

URL="$(python3 - "$REPO" <<'PY'
import json, re, sys, time, urllib.request

url = f"https://api.github.com/repos/{sys.argv[1]}/releases?per_page=100"

while url:
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers={
                "Accept": "application/vnd.github+json",
                "User-Agent": "Morphe-Installer",
            })
            with urllib.request.urlopen(req, timeout=30) as r:
                releases = json.load(r)
                links = r.headers.get("Link", "")
            break
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)

    for release in releases:
        if release.get("draft"):
            continue
        for asset in release.get("assets", []):
            name = asset.get("name", "")
            if name.lower().startswith("morphe-desktop") and name.lower().endswith(".jar"):
                print(asset["browser_download_url"])
                sys.exit(0)

    match = re.search(r'<([^>]+)>;\s*rel="next"', links)
    url = match.group(1) if match else None

sys.exit("No matching JAR found in published releases.")
PY
)"

NAME="${URL##*/}"
[[ "${NAME,,}" == *.jar && "$NAME" != */* ]] || {
    echo "GitHub returned an invalid JAR filename." >&2
    exit 1
}
JAR="$BASE/$NAME"
echo "Downloading $NAME..."

curl -fLsS --retry 3 --retry-all-errors "$URL" -o "$TMP/$NAME"
unzip -tqq "$TMP/$NAME"

# Extract the logo when the release contains it. A missing logo must not
# prevent an otherwise valid application JAR from installing.
if unzip -Z1 "$TMP/$NAME" | grep -x 'morphe_logo.png' >/dev/null; then
    unzip -p "$TMP/$NAME" morphe_logo.png > "$TMP/logo.png"
    python3 -c 'import sys; assert open(sys.argv[1],"rb").read(8) == b"\x89PNG\r\n\x1a\n", "Invalid PNG"' "$TMP/logo.png"
else
    echo "[WARN] The JAR has no morphe_logo.png; keeping the current icon if present." >&2
fi

# Install only when the contents change. Use the release asset's actual name.
if ! cmp -s "$TMP/$NAME" "$JAR" 2>/dev/null; then
    install -m 644 "$TMP/$NAME" "$TMP/$NAME.new"
    mv -f "$TMP/$NAME.new" "$JAR"
fi

if [[ -s "$TMP/logo.png" ]] && ! cmp -s "$TMP/logo.png" "$ICON" 2>/dev/null; then
    install -m 644 "$TMP/logo.png" "$TMP/logo.new"
    mv -f "$TMP/logo.new" "$ICON"
fi

JAVA_BIN="$(command -v java)"
cat > "$TMP/launch-morphe.sh" <<EOF_LAUNCHER
#!/usr/bin/env bash
set -Eeuo pipefail
BASE="\$(cd -- "\$(dirname -- "\$0")" && pwd -P)"
JAVA_BIN="$JAVA_BIN"
mapfile -t JARS < <(find "\$BASE" -maxdepth 1 -type f -name '*.jar' -printf '%T@ %p\n' | sort -nr)
if (( \${#JARS[@]} == 0 )); then
    printf 'Morphe Desktop: no JAR file found in %s\n' "\$BASE" >&2
    exit 1
fi
JAR="\${JARS[0]#* }"
if [[ ! -f "\$JAR" ]]; then
    printf 'Morphe Desktop: selected JAR does not exist: %s\n' "\$JAR" >&2
    exit 1
fi
exec "\$JAVA_BIN" -jar "\$JAR" "\$@"
EOF_LAUNCHER

if ! cmp -s "$TMP/launch-morphe.sh" "$BASE/launch-morphe.sh" 2>/dev/null; then
    install -m 755 "$TMP/launch-morphe.sh" "$TMP/launch-morphe.sh.new"
    mv -f "$TMP/launch-morphe.sh.new" "$BASE/launch-morphe.sh"
fi

cat > "$TMP/launcher" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Morphe Desktop
Comment=Morphe Desktop Manager
Exec="$BASE/launch-morphe.sh"
Icon=$ICON
Terminal=false
Categories=Utility;Development;
StartupNotify=true
EOF

if ! cmp -s "$TMP/launcher" "$DESKTOP" 2>/dev/null; then
    install -m 755 "$TMP/launcher" "$APP/.morphe-desktop.new"
    mv -f "$APP/.morphe-desktop.new" "$DESKTOP"
fi

command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$APP" >/dev/null 2>&1 || true

echo "Morphe Desktop installed: $NAME"
echo "Launch it from the KDE application menu."
