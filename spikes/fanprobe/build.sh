#!/bin/sh
set -e
cd "$(dirname "$0")"
swiftc -O -o fanprobe fanprobe.swift -framework IOKit
codesign -s - -f fanprobe
