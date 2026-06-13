#!/usr/bin/env bash
#
# Provide the elfutils (libdw/libelf) DEV headers + link symlinks WITHOUT sudo.
#
# Why: since the 2026-06 upstream pull, the ISS trace resolves PC->symbol at
# runtime via libdw (core/models/cpu/iss*/src/trace.cpp includes
# <elfutils/libdwfl.h>, and riscv.py calls add_libraries(['dw','elf'])). The
# build host (AlmaLinux 8) ships the runtime libs (libdw.so.1 / libelf.so.1)
# but NOT elfutils-devel, and there is no passwordless sudo. This script
# downloads the matching elfutils-devel RPM into the repo and extracts just the
# headers + creates the missing `libdw.so` link symlink, so the build can find
# them via CPATH / LIBRARY_PATH (gcc's include / link search env vars).
#
# Usage:
#   scripts/setup_elfutils_headers.sh          # fetch + extract (idempotent)
#   eval "$(scripts/setup_elfutils_headers.sh --env)"   # just print the exports
#
# Then build with the printed CPATH / LIBRARY_PATH exported (see CLAUDE.md
# "Build environment").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$HERE/third_party/elfutils-devel"
INC="$DEST/root/usr/include"
LIB="$DEST/lib"

print_env() {
    echo "export CPATH=\"$INC\${CPATH:+:\$CPATH}\""
    echo "export LIBRARY_PATH=\"$LIB\${LIBRARY_PATH:+:\$LIBRARY_PATH}\""
}

if [ "${1:-}" = "--env" ]; then
    print_env
    exit 0
fi

# Match the installed runtime ABI (e.g. elfutils-libs-0.190-2.el8.alma.1).
ver="$(rpm -q --qf '%{VERSION}-%{RELEASE}' elfutils-libs 2>/dev/null || true)"
echo "==> installed elfutils-libs: ${ver:-unknown}"

mkdir -p "$DEST/rpms"
if [ ! -f "$INC/elfutils/libdwfl.h" ]; then
    echo "==> downloading elfutils-devel + elfutils-libelf-devel (no sudo)"
    dnf download --destdir="$DEST/rpms" elfutils-devel elfutils-libelf-devel
    echo "==> extracting headers into $DEST/root"
    rm -rf "$DEST/root"; mkdir -p "$DEST/root"
    ( cd "$DEST/root"
      for r in "$DEST"/rpms/elfutils-devel-*.x86_64.rpm \
               "$DEST"/rpms/elfutils-libelf-devel-*.x86_64.rpm; do
          rpm2cpio "$r" | cpio -idm --quiet
      done )
else
    echo "==> headers already present"
fi

# The dev `.so` link symlinks: the host has libdw.so.1 but no libdw.so, so `-ldw`
# fails. Point local symlinks at the real runtime libs (absolute → cwd-independent).
mkdir -p "$LIB"
ln -sf /usr/lib64/libdw.so.1  "$LIB/libdw.so"
ln -sf /usr/lib64/libelf.so.1 "$LIB/libelf.so"

test -f "$INC/elfutils/libdwfl.h" || { echo "FAIL: libdwfl.h missing" >&2; exit 1; }
echo "==> OK. Add these to your build environment:"
print_env
