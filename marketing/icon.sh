#!/bin/zsh
# Gera Resources/AppIcon.icns. Variantes: escuro (padrão), cores, quente.
#   ./marketing/icon.sh [variante]
set -e
cd "$(dirname "$0")/.."
VARIANT="${1:-escuro}"
mkdir -p .build/marketing Resources
swiftc -O marketing/icon/main.swift -o .build/marketing/icon
rm -rf .build/marketing/AppIcon.iconset
.build/marketing/icon "$VARIANT" --iconset .build/marketing/AppIcon.iconset
iconutil -c icns .build/marketing/AppIcon.iconset -o Resources/AppIcon.icns
echo "Ícone ($VARIANT): $PWD/Resources/AppIcon.icns"
