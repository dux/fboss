#!/bin/bash

APP_NAME="fBoss"
REPO="dux/fboss"
INSTALL_DIR="/Applications"
DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$APP_NAME.app.tar.gz"

[[ "$(uname)" == "Darwin" ]] || { echo "ERROR: macOS required"; exit 1; }

echo "* Installing $APP_NAME..."

# install homebrew if missing
if ! command -v brew &>/dev/null; then
  echo "* Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || { echo "ERROR: Homebrew install failed"; exit 1; }
  if [[ "$(uname -m)" == "arm64" ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# install dependencies one by one
for pkg in libimobiledevice fd ffmpeg duti; do
  brew list "$pkg" &>/dev/null || brew install "$pkg"
done

# download app
TMP_DIR="$(mktemp -d)"
echo "* Downloading..."
curl -fSL "$DOWNLOAD_URL" -o "$TMP_DIR/$APP_NAME.app.tar.gz" || { echo "ERROR: Download failed"; exit 1; }
tar -xzf "$TMP_DIR/$APP_NAME.app.tar.gz" -C "$TMP_DIR"
[[ -d "$TMP_DIR/$APP_NAME.app" ]] || { echo "ERROR: Bad archive"; exit 1; }

# install
pkill -x "$APP_NAME" 2>/dev/null && sleep 0.3 || true
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$TMP_DIR/$APP_NAME.app" "$INSTALL_DIR/"
rm -rf "$TMP_DIR"

echo "* Installed to $INSTALL_DIR/$APP_NAME.app"

# create 'fe' shortcut command
if [[ "$(uname -m)" == "arm64" ]]; then
  FE_DIR="/opt/homebrew/bin"
else
  FE_DIR="/usr/local/bin"
fi
echo "* Creating 'fe' command in $FE_DIR..."
cat > "$FE_DIR/fe" <<'SCRIPT'
#!/bin/bash
open -a fBoss "${1:-.}"
SCRIPT
chmod +x "$FE_DIR/fe"

open "$INSTALL_DIR/$APP_NAME.app"
