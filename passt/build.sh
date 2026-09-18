# Builds passt for the Android app context and deploys it as
# lib/arm64-v8a/libuml-passt.so in the umltest APK.
#
# Base is passt at commit 3a890a6 (https://passt.top/passt) with
# passt-uml.patch applied: PASST_NO_SANDBOX (no userns/mounts/seccomp-drop,
# for app processes), PASST_RAW_L2 (bare ethernet frames over the
# SEQPACKET vector-fd socket), netlink fail-soft (no netlink bind in the
# app SELinux domain), and one-frame-per-sendmsg on the SEQPACKET tap
# socket (a batched sendmsg there is a single datagram, which would
# concatenate frames), and epoll_pwait in the main loop (the seccomp
# allow-list has epoll_pwait only; glibc's epoll_wait() issues raw
# epoll_wait2 and gets SIGSYS on a glibc host — bionic is unaffected).
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
#
# VERSION is pinned to the string passt's Makefile falls back to when
# `git describe` fails, which is what the released libuml-passt.so was
# built with. Left to default, a build inside a git checkout embeds the
# git describe string instead, and the binary comes out different (the
# version literal lives in .rodata, and its length shifts every section
# after it).
make CC="$CC" VERSION='unknown\ version' static >/dev/null
file passt

mkdir -p "$(dirname "$DEST")"
cp passt "$DEST"