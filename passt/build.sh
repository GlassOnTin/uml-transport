# Builds passt for the Android app context and deploys it as
# lib/arm64-v8a/libuml-passt.so in the umltest APK.
#
# Base is passt at commit 3a890a6 (https://passt.top/passt) with
# passt-uml.patch applied: PASST_NO_SANDBOX (no userns/mounts/seccomp-drop,
# for app processes), PASST_RAW_L2 (bare ethernet frames over the
# SEQPACKET vector-fd socket), netlink fail-soft (no netlink bind in the
# app SELinux domain), and one-frame-per-sendmsg on the SEQPACKET tap
# socket (a batched sendmsg there is a single datagram, which would
# concatenate frames).
#
# The musl cross toolchain is the musl.cc aarch64-linux-musl-cross prebuilt
# (GCC 11.2.1) untarred at the default path below; MUSL_CROSS points
# elsewhere. passt source lives at SRC (default /tmp/passt), passt at commit
# 3a890a6 with passt-uml.patch applied. The built binary lands at DEST:
#   ./build.sh
set -e
MUSL_CROSS=${MUSL_CROSS:-/tmp/aarch64-linux-musl-cross}
CC=$MUSL_CROSS/bin/aarch64-linux-musl-gcc
if [ ! -x "$CC" ]; then
	echo "musl cross toolchain not found at $MUSL_CROSS" >&2
	exit 1
fi
SRC=${SRC:-/tmp/passt}
HERE=$(dirname "$0")
DEST=${DEST:-$HERE/../apk/lib/arm64-v8a/libuml-passt.so}

cd "$SRC"
make CC="$CC" clean >/dev/null
# Serial: `make static` depends on `clean`, which races its parallel job
# list and deletes seccomp.h mid-build.
make CC="$CC" static >/dev/null
file passt

mkdir -p "$(dirname "$DEST")"
cp passt "$DEST"