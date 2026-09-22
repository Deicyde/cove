#!/bin/sh
# Builds cove/bin/cove-reminders (EventKit helper for the reminders widget).
set -e
cd "$(dirname "$0")"
mkdir -p ../bin
swiftc -O main.swift -o ../bin/cove-reminders \
	-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Info.plist
codesign -s - -f --identifier me.kirancodes.cove.reminders ../bin/cove-reminders
