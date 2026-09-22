#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/tests
swiftc -swift-version 5 Sources/UsageCore.swift Sources/Pricing.swift Sources/FamilyUsage.swift Sources/OpenCodeUsage.swift Sources/UsageSources.swift Sources/AllUsage.swift Sources/YonshoreAccount.swift Sources/ActiveConversation.swift Tests/main.swift -o build/tests/accounting
build/tests/accounting
