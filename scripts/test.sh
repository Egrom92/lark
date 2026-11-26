#!/bin/bash
# Тесты Lark: чистая логика, компиляция AppleScript для установленных программ, JavaScript вкладок в WebKit.
#   ./scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" -o build/LarkTests Sources/Logic.swift Tests/main.swift
./build/LarkTests
