#!/bin/zsh
# Compila e empacota o ClaudeUsage.app (app só de barra de menus).
# Com o Xcode completo gera um app universal (Intel + Apple Silicon); só com as
# Command Line Tools, gera para a arquitetura deste Mac.
#   ./build.sh            gera build/ClaudeUsage.app
#   ./build.sh --install  também copia para /Applications
#   ./build.sh --zip      também gera build/ClaudeUsage.zip (para publicar uma release)
set -e
cd "$(dirname "$0")"
VERSION="1.2.0"

# O build universal depende do xcbuild, que só vem com o Xcode.
if [[ "$(xcode-select -p 2>/dev/null)" == *Xcode*.app* ]]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/ClaudeUsage
else
  echo "Xcode não encontrado: compilando só para $(uname -m)."
  swift build -c release
  BIN=.build/release/ClaudeUsage
fi
APP=build/ClaudeUsage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>local.claudeusage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Pronto: $PWD/$APP"

for arg in "$@"; do
  case "$arg" in
    --install)
      rm -rf /Applications/ClaudeUsage.app
      cp -R "$APP" /Applications/
      echo "Instalado em /Applications" ;;
    --zip)
      rm -f build/ClaudeUsage.zip
      ditto -c -k --keepParent "$APP" build/ClaudeUsage.zip
      echo "Zip: $PWD/build/ClaudeUsage.zip" ;;
  esac
done
