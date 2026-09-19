#!/usr/bin/env python3
"""Neuter seccomp-killed syscalls in a statically linked arm64 UML kernel.

Android app processes are started by zygote with a seccomp filter already
installed. That filter kills some syscalls outright -- SIGSYS is delivered
with force_sig_info, so handlers are bypassed and ptrace cannot intervene,
because seccomp is evaluated before the syscall-entry stop. The libc a
statically linked kernel pulls in calls two of them from __tls_init_tp at
startup and again on thread creation, so the kernel dies ~100 ms after exec
with exit 159 (128 + SIGSYS) and no output of any kind.

Killed on OPPO CPH2655, Android 16, kernel 6.6 (probed with harness/probe):
  set_robust_list (99)  - glibc __tls_init_tp; every result is unchecked,
                          so fake success (mov w0, #0) is safe.
  rseq (293)            - glibc __tls_init_tp; the caller checks the result
                          and on failure sets RSEQ_CPU_ID_REGISTRATION_FAILED
                          and carries on, so fake failure (mov w0, #-1 via
                          movn w0, #0) is safe.
bionic's startup calls set_robust_list too, so this is not glibc-specific.

Every site sets x8 = syscall number then issues svc #0 within 16
instructions. We patch only the svc, leaving libc's own result checks to
take their normal paths.

Scans rather than using fixed addresses, so it survives rebuilds; running
it twice is a no-op (the svc is gone once patched). check-app-seccomp.sh
is the gate that fails if a binary ever ships unpatched.
"""
import struct
import sys

MOV_W0_0 = 0x52800000   # mov w0, #0   -> fake success
MOVN_W0_0 = 0x12800000  # mov w0, #-1  -> fake failure
SVC0 = 0xD4000001       # svc #0

# syscall number -> (replacement, description)
PATCHES = {
    99: (MOV_W0_0, "set_robust_list"),
    293: (MOVN_W0_0, "rseq"),
}


def enc_mov_x8_imm(imm):
    """mov x8, #imm (and w8) encodings."""
    assert 0 <= imm < 0x10000
    return (0xD2800000 | (imm << 5) | 8, 0x52800000 | (imm << 5) | 8)


def main(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())

    # aarch64 ET_EXEC with a single RWE LOAD at 0x60000000 and file offset 0,
    # so we can scan the whole file as one flat code image.
    n = len(data) // 4
    words = list(struct.unpack_from("<%dI" % n, data, 0))

    targets = {}
    for num, (repl, name) in PATCHES.items():
        for enc in enc_mov_x8_imm(num):
            targets[enc] = (repl, name)

    counts = {}
    for i in range(n - 16):
        hit = targets.get(words[i])
        if not hit:
            continue
        repl, name = hit
        for j in range(i + 1, min(i + 16, n)):
            if words[j] == SVC0:
                words[j] = repl
                counts[name] = counts.get(name, 0) + 1
                break
            if words[j] in targets:
                break

    if counts:
        struct.pack_into("<%dI" % n, data, 0, *words)
        with open(path, "wb") as f:
            f.write(data)
    if not counts:
        print("%s: nothing to patch (already patched?)" % path)
    else:
        for name, c in sorted(counts.items()):
            print("%s: neutered %d %s svc site(s)" % (path, c, name))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: %s <uml-kernel-binary>" % sys.argv[0])
    sys.exit(main(sys.argv[1]))