# uml-transport

Binaries for the Linux Guest (UML) transport in
[Haven](https://github.com/GlassOnTin/haven). `core/local/fetch-uml.sh` in that
repository downloads the three files below from this project's releases and
verifies their checksums before the build packages them.

Everything here runs on arm64 Android without root and without a hypervisor.
User-Mode Linux is a Linux kernel compiled to run as an ordinary process, so
the guest kernel is just another executable in the app's native library
directory.

## Release artifacts

Pinned by Haven's `fetch-uml.sh`, tag `uml-guest-1`:

| file | size | sha256 |
|---|---|---|
| `libvmlinux.so` | 79,307,152 | `7c557572db754b4794ecf7a9cfcfec58d69977d8f09dc1c71f4d9361e032271f` |
| `libuml-stub.so` | 1,920 | `83f51f7c45133daa135b595562b09c5e2829f1d0f1e00b7fce2a7695370781fc` |
| `libuml-passt.so` | 608,472 | `e78fa0a504994f94423085f2b7ddfc891ab27b21a2e9150ec264ed59441c1c44` |

All three are arm64. `libvmlinux.so` and `libuml-stub.so` are statically
linked bionic executables (renamed `lib*.so` so Android packages and execs
them from the app's native library directory). `libuml-passt.so` is a
statically linked musl executable. Nothing here is dynamically linked, and
none of it links against libandroid or JNI.

APK packaging strips debug symbols from `libvmlinux.so` (79.3 MB down to
about 8 MB). The loadable segment is byte-identical before and after; only
ELF headers and section tables change.

## Rebuilding the kernel and stub

Source is the `um-arm64` branch of
[zalexdev/linux-um-arm64](https://github.com/zalexdev/linux-um-arm64)
(Linux 7.2-rc4, 38 commits) at commit `8897487c5`, with the two patches in
this repository applied in order:

1. `stub-execve-fallback.patch` — after `execveat(fd, "", AT_EMPTY_PATH)`
   fails to exec the stub, retry with plain `execve()` on the path given by
   the `stub_exe=` kernel option. Needed because syscall interceptors reject
   the fd-based exec, and because Android refuses exec from a memfd.
2. `android-app-compat.patch` — in an app process the seccomp allowlist
   kills `personality()` outright rather than returning an error, so skip
   the re-exec-on-ASLR-change path under `__ANDROID__` and install a
   diagnostic handler that names a blocked syscall before the process dies.

The stub (`libuml-stub.so`) is `arch/um/kernel/skas/stub_exe` from the same
build, renamed.

Build with the NDK toolchain so the kernel takes its bionic paths:

    export NDK=$HOME/Android/Sdk/ndk/27.0.12077973
    PATH=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH
    make -C linux-um-arm64 ARCH=um SUBARCH=arm64 LLVM=1 O=$PWD/build defconfig
    scripts/config --file build/.config -e STATIC_LINK -e UML_NET_VECTOR
    make -C linux-um-arm64 ARCH=um SUBARCH=arm64 LLVM=1 O=$PWD/build olddefconfig
    make -C linux-um-arm64 ARCH=um SUBARCH=arm64 LLVM=1 O=$PWD/build -j32

The kernel needs clang; a GNU cross build fails on a glibc/kernel
`__alloc_size__` clash in `arch/um/os-Linux/`. `CONFIG_STATIC_LINK=y` picks
the static link. No other changes were made: the toolchain defines
`__ANDROID__`, which activates the bionic paths already in the tree.

A GNU/Linux glibc-dynamic build of this kernel does not run on Android (no
`/lib/ld-linux-aarch64.so.1`), which is why the static bionic build is the
one shipped.

## Rebuilding passt

`libuml-passt.so` is [passt](https://passt.top/passt) at commit `3a890a6`
with `passt/passt-uml.patch` applied, built statically against musl. The
patch adds:

- `PASST_RAW_L2` — bare ethernet frames over the `SOCK_SEQPACKET` socket
  instead of the 4-byte length-prefixed QEMU stream format. The UML vector
  `fd` transport sends bare frames. In the same mode, passt sends one frame
  per `sendmsg`: on a seqpacket socket one sendmsg is one datagram, and the
  upstream batching would concatenate frames into an oversized one the guest
  drops (this showed up as ~700 B/s TCP with silent DNS loss before it was
  found).
- `PASST_NO_SANDBOX` — no user namespace, no mount namespace, no seccomp
  drop. App processes cannot use any of them (the app SELinux domain also
  denies the netlink bind, which puts passt into local mode with the guest
  at 169.254.2.1/16).
- netlink fails soft instead of aborting, so the local-mode fallback above
  works.

`passt/build.sh` drives the musl static build; it expects a
`aarch64-linux-musl` cross toolchain on `PATH`-configured paths as noted in
the script.

## Launcher

The fourth file Haven ships, `libuml-net.so`, is built from Haven's own
source (`core/local/src/main/cpp/uml_net.c`); it is not part of this
project. It opens the socketpair, execs passt on one end and the kernel on
the other, and appends the `vec0:transport=fd` kernel argument.

## License

The kernel and the stub are GPL-2.0, from the Linux sources named above
(Linux's `COPYING` applies, including the syscall note). passt is
GPL-2.0-or-later per its upstream `SPDX-License-Identifier`. The GNU GPL
text is in `LICENSE`, the patches carry their changes back to the same
terms, and the pinned binaries in the releases correspond to the sources
described in this README.