#!/bin/sh
# Unit tests of the MRR rules (Sources/Metrics.swift and the Stripe reading): compiles them with Tests/main.swift and runs.
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
xcrun swiftc -swift-version 5 -o "$OUT/tests" Tests/main.swift Sources/Metrics.swift Sources/History.swift Sources/Stripe.swift Sources/Store.swift
"$OUT/tests"
