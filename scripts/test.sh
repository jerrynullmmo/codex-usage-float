#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -swift-version 5 Sources/UsageCore.swift Sources/ActiveConversation.swift Tests/main.swift -o build/tests/accounting
build/tests/accounting
