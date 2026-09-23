#!/bin/sh
# Build cove-remote for a Linux host and install it there at the same path as
# this checkout's bin/cove-remote (the path the Mac's attach runs over ssh).
#
#   cove/remote/install-linux.sh aws-dev
#
# Also installs kitty's terminfo as ~/.terminfo/x/xterm-kitty on the host, in
# case the host has no kitty checkout next to the binary.
set -eu
host=${1:?usage: install-linux.sh HOST}
here=$(cd "$(dirname "$0")" && pwd -P)
bindir=$(cd "$here/../bin" && pwd -P)
case $(ssh -o BatchMode=yes "$host" uname -m) in
x86_64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) echo "install-linux.sh: unknown arch on $host" >&2; exit 1 ;;
esac
out="$bindir/cove-remote-linux-$arch"
(cd "$here" && GOOS=linux GOARCH=$arch CGO_ENABLED=0 go build -o "$out" .)
dest="$bindir/cove-remote"
ssh -o BatchMode=yes "$host" "mkdir -p '$bindir' ~/.terminfo/x"
# Replace by rename: running session daemons keep their old binary.
scp -q "$out" "$host:$dest.new"
scp -q "$here/../../terminfo/x/xterm-kitty" "$host:.terminfo/x/xterm-kitty"
ssh -o BatchMode=yes "$host" "chmod +x '$dest.new' && mv -f '$dest.new' '$dest' && '$dest' local-ls >/dev/null"
echo "installed $out as $host:$dest"
