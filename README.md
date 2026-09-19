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

Pinned by Haven's `fetch-uml.sh`, tag `uml-guest-4`:

| file | size | sha256 |
|---|---|---|
| `libvmlinux.so` | 79,307,152 | `71cc9dc73c683a8c00fb533d01e7a1be27974876dcab2068419ea4b272fb387c` |
| `libuml-stub.so` | 1,920 | `83f51f7c45133daa135b595562b09c5e2829f1d0f1e00b7fce2a7695370781fc` |
| `libuml-passt.so` | 608,472 | `17703eb787afcfc57475921f186bec6eae479db00cf60e1763c1a8459c055b36` |

A fourth file, `rootfs-aarch64.ext4.gz`, is pinned separately by Haven's
`fetch-uml-rootfs.sh`:

| file | size | sha256 |
|---|---|---|
| `rootfs-aarch64.ext4.gz` | 4,497,803 | `c4acb30d0b53421775de080dcbd498a7d94bedf628d0dba77f7fb744f3792e47` |

`uml-guest-4` is the `uml-guest-3` kernel with one post-link step added:
`tools/um-arm64/harness/patch-glibc-seccomp.py` (below) replaces five svc
instructions. The stub, passt and rootfs binaries are the same bytes as
`uml-guest-3`.

That post-link step exists because Haven 5.89.7 (which shipped the
`uml-guest-2`/`-3` kernel) failed to boot any guest on some devices: the
process died with exit 159 (128+SIGSYS) about 100 ms after exec, before
printing anything. An Android app process runs under zygote's seccomp
filter, which kills `set_robust_list(2)` and `rseq(2)` with SIGSYS
delivered via `force_sig_info` — handlers are bypassed and ptrace cannot
intervene, because seccomp is evaluated before the syscall-entry stop.
The statically linked libc issues both from `__tls_init_tp` at startup
(and again on every thread creation). `uml-guest-1` predates the NAPI
rebuild and was patched the same way from birth; the `-2`/`-3` relink
dropped that step, which is the whole regression.

`patch-glibc-seccomp.py` rewrites the svc after each `mov x8, #99` /
`mov x8, #293` site: `set_robust_list` gets `mov w0, #0` (callers never
check the result) and `rseq` gets `mov w0, #-1` (its caller treats that
as `RSEQ_CPU_ID_REGISTRATION_FAILED` and carries on). It scans rather
than using fixed addresses, so it survives relinks; running it twice is
a no-op. `tools/um-arm64/harness/check-app-seccomp.sh` is the gate: it
fails any binary that still contains a killed site, and
`tools/um-arm64/harness/build-bionic.sh` runs the patch and then the
gate after every link. Patching the `uml-guest-3` binary with the
script reproduces the `uml-guest-4` sha256 byte for byte.

`libuml-passt.so` picks up the passt-side raw-L2 pool-drain fix described
under "Rebuilding passt" below (commit `0720a63` in this repository). On the
production-shaped load the kernel NAPI fix alone already delivers every
response; the passt drain fix bounds the same failure mode on the passt side
of the transport.

The rootfs is the Alpine aarch64 image shipped since `uml-guest-1`, edited in
place: `/sbin/haven-net` (kept in `rootfs-overlay/sbin/` here) runs at
sysinit after `ifup -a` and retries the vec0 DHCP a few times, printing a
visible warning if it never comes up. `ifup -a` runs with stderr silenced in
the image's inittab, and on some boots its udhcpc loses the race against
passt not accepting on the vec0 fd transport yet — a fresh guest would boot
with no interface and no hint why. `test/goose-repro.sh` is the regression
gate for both fixes, run inside a guest.

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
(Linux 7.2-rc4, 38 commits) at commit `8897487c5`, with the three patches in
this repository applied in order:

1. `stub-execve-fallback.patch` — after `execveat(fd, "", AT_EMPTY_PATH)`
   fails to exec the stub, retry with plain `execve()` on the path given by
   the `stub_exe=` kernel option. Needed because syscall interceptors reject
   the fd-based exec, and because Android refuses exec from a memfd.
2. `android-app-compat.patch` — in an app process the seccomp allowlist
   kills `personality()` outright rather than returning an error, so skip
   the re-exec-on-ASLR-change path under `__ANDROID__` and install a
   diagnostic handler that names a blocked syscall before the process dies.
3. `vector-napi-budget.patch` — `vector_poll` returned `napi_complete_done`
   when `work_done <= budget`. A poll that consumed its whole budget must
   return `budget` without completing, because `net/core/dev.c` keeps NAPI
   scheduled by comparing `work == budget`; completing in that case
   deschedules the poll and loses the "still more work" signal until
   something else re-enables the queue. Verified against a production-shaped
   load (3 concurrent agents, 80 MB of responses each, byte-exact delivery
   with the fix and repeated "Budget exhausted after napi rescheduled"
   warnings without it).

The stub (`libuml-stub.so`) is `arch/um/kernel/skas/stub_exe` from the same
build, renamed.

Build with the NDK toolchain so the kernel takes its bionic paths:

    export NDK=$HOME/Android/Sdk/ndk/27.0.12077973
    PATH=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH
    make -C linux-um-arm64 ARCH=um SUBARCH=arm64 LLVM=1 O=$PWD/build defconfig
    linux-um-arm64/scripts/config --file build/.config -e STATIC_LINK -e UML_NET_VECTOR
    make -C linux-um-arm64 ARCH=um SUBARCH=arm64 LLVM=1 O=$PWD/build olddefconfig
    make -C linux-um-arm64 ARCH=um SUBARCH=arm64 LLVM=1 O=$PWD/build -j32

The kernel needs clang; a GNU cross build fails on a glibc/kernel
`__alloc_size__` clash in `arch/um/os-Linux/`. `CONFIG_STATIC_LINK=y` picks
the static link. No other changes were made: the toolchain defines
`__ANDROID__`, which activates the bionic paths already in the tree.

After linking, the app-seccomp neutering from the `uml-guest-4` section
above is mandatory before the binary can run in an app:

    python3 tools/um-arm64/harness/patch-glibc-seccomp.py build/linux
    python3 tools/um-arm64/harness/check-app-seccomp.sh build/linux   # must pass

The same scripts live on the source branch at
`tools/um-arm64/harness/` (commits `d4e32a483`, `d580adc09`, `9ba484601`
on top of `7edec4df1` in the local um-arm64 tree; pushing that branch to
GitHub fails server-side on the 282 MB pack, so this copy under
`tools/um-arm64/harness/` is the published one).

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
- the raw-L2 guest-input path drains each datagram into its own `pkt_buf`
  slot. Draining every frame from the buffer start would overwrite frames
  still queued in the packet pool, so frames are processed in place and the
  pool is kept draining (`PASST_FORCE_LOCAL` also skips host interface
  discovery entirely).

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