#!/bin/bash
# swift test with only the command line tools: the 26.5 SDK (see README), and
# the swift-testing macro plugin named outright — incremental builds lose it.
set -euo pipefail
cd "$(dirname "$0")"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
