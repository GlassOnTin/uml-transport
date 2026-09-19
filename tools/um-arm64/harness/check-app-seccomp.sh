#!/usr/bin/env python3
"""Fail if a UML kernel binary still contains seccomp-killed syscall sites.

An Android app process runs under zygote's seccomp filter, which kills
set_robust_list(2) and rseq(2) with SIGSYS delivered via force_sig_info --
handlers are bypassed and ptrace cannot intervene, because seccomp evaluates
before the syscall-entry stop. A statically linked kernel that still issues
either syscall dies ~100 ms after exec, exit 159, with no output of any kind.

This is the regression gate for harness/patch-glibc-seccomp.py, which neuters
the svc instructions after the offending mov x8, #imm sites. Both scan the
same way: find the mov, then look for svc #0 within the next 16 instructions,
stopping at another target mov. A binary where the checker and the patcher
disagree would be a bug in one of them, so they share this logic by design
rather than by import -- the patcher is standalone so it can be copied to a
build host without the tree.

Exit status:
  0  clean -- no unpatched sites (patched, or none present at all)
  1  UNPATCHED SITES PRESENT -- this binary would die in an app (exit 159)
  2  usage / I/O / not an arm64 ELF

Verified against the real binaries:
  uml-guest-1 (shipped in Haven 5.89.6)      -> exit 0 (patched from birth)
  uml-guest-2, -3 (release assets, unpatched) -> exit 1 (3x set_robust_list,
                                                 2x rseq)
  uml-guest-4 (release asset, patched)        -> exit 0
  uml-guest-4 after AGP's jniLibs strip       -> exit 0
"""
import struct
import sys

SVC0 = 0xD4000001

# syscall number -> name
KILLED = {
    99: "set_robust_list",
    293: "rseq",
}


def enc_mov_x8_imm(imm):
    """mov x8, #imm (and the w8 form) encodings."""
    return (0xD2800000 | (imm << 5) | 8, 0x52800000 | (imm << 5) | 8)


def main(path):
    with open(path, "rb") as f:
        data = f.read()

    if len(data) < 20 or data[:4] != b"\x7fELF":
        print("check-app-seccomp: %s: not an ELF file" % path, file=sys.stderr)
        return 2
    e_type, e_machine = struct.unpack_from("<HH", data, 16)
    if e_machine != 183:  # EM_AARCH64
        print("check-app-seccomp: %s: not an arm64 ELF (e_machine=%d)"
              % (path, e_machine), file=sys.stderr)
        return 2
    # ET_EXEC (2) or ET_DYN (3) both occur: the pre-strip link output is
    # ET_EXEC, some installs see ET_DYN. The scan is position-independent.
    if e_type not in (2, 3):
        print("check-app-seccomp: %s: not an executable (e_type=%d)"
              % (path, e_type), file=sys.stderr)
        return 2

    n = len(data) // 4
    words = struct.unpack_from("<%dI" % n, data, 0)

    targets = {}
    for num, name in KILLED.items():
        for enc in enc_mov_x8_imm(num):
            targets[enc] = (num, name)

    # (file offset, syscall nr, name) of every svc that would still kill us
    unpatched = []
    for i in range(n - 16):
        hit = targets.get(words[i])
        if not hit:
            continue
        num, name = hit
        for j in range(i + 1, min(i + 16, n)):
            if words[j] == SVC0:
                unpatched.append((j * 4, num, name))
                break
            if words[j] in targets:
                break

    if unpatched:
        print("check-app-seccomp: FAIL %s: %d unpatched seccomp-killed "
              "syscall site(s)" % (path, len(unpatched)))
        for off, num, name in unpatched:
            print("  svc for %s (%d) at file offset 0x%x" % (name, num, off))
        print("  this binary dies with exit 159 in an Android app context;"
              " run harness/patch-glibc-seccomp.py on it first")
        return 1

    print("check-app-seccomp: OK %s: no unpatched seccomp-killed sites" % path)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: %s <uml-kernel-binary>" % sys.argv[0])
    sys.exit(main(sys.argv[1]))