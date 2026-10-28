#!/bin/zsh
# Gera as imagens de divulgação em docs/images usando as telas reais do app com dados de demonstração.
set -e
cd "$(dirname "$0")/.."
mkdir -p .build/marketing
swiftc -O $(ls Sources/ClaudeUsage/*.swift | grep -v '/main.swift$') marketing/main.swift -o .build/marketing/render
.build/marketing/render "${1:-docs/images}"
