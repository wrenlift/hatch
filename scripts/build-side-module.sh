#!/usr/bin/env bash
# Build a plugin crate as a wasm32-wasip1 side module: the dylink.0
# module a wasm AOT program's host loads beside it, sharing the
# program's memory and table (Ash's model for native libraries on wasm).
#
#   scripts/build-side-module.sh <source-dir> <crate> <package-dir> <out-dir>
#
# Writes <out-dir>/<crate>.wasm, exporting every `#!symbol` the
# package's Wren names that the crate defines. The library name is the
# crate name, as it is for the native builds.
#
# The crate is built as a position-independent staticlib, which needs
# nightly's -Z build-std (the shipped std is not position-independent),
# then linked with rust-lld -shared. TOOLCHAIN picks the toolchain
# (default +nightly; empty uses the default one). A C dependency builds
# with CC_wasm32_wasip1 against WASI_SYSROOT.
set -euo pipefail

if [ $# -ne 4 ]; then
    echo "usage: $0 <source-dir> <crate> <package-dir> <out-dir>" >&2
    exit 2
fi
src=$1
crate=$2
pkg=$3
out=$4
triple=wasm32-wasip1
toolchain=${TOOLCHAIN-+nightly}

export RUSTFLAGS="${RUSTFLAGS:-} -C relocation-model=pic -C target-feature=+mutable-globals"
if [ -n "${WASI_SYSROOT:-}" ]; then
    export CFLAGS_wasm32_wasip1="${CFLAGS_wasm32_wasip1:---target=wasm32-wasi --sysroot=$WASI_SYSROOT -fPIC}"
fi

# shellcheck disable=SC2086
(cd "$src" && cargo $toolchain rustc -p "$crate" --release --lib --target "$triple" \
    --crate-type staticlib -Z build-std=std,panic_abort)
archive="${CARGO_TARGET_DIR:-$src/target}/$triple/release/lib${crate}.a"
if [ ! -f "$archive" ]; then
    echo "cargo produced no $archive" >&2
    exit 1
fi

# The symbols the Wren side binds. --export-if-defined, because a
# package can name symbols of another library, or of a browser-only one.
exports=()
while IFS= read -r sym; do
    exports+=("--export-if-defined=$sym")
done < <(grep -rhoE '#!symbol *= *"[^"]+"' "$pkg" --include='*.wren' \
    | sed -E 's/.*"([^"]+)"/\1/' | sort -u)
if [ ${#exports[@]} -eq 0 ]; then
    echo "$pkg names no #!symbol, so the side module would export nothing" >&2
    exit 1
fi

# shellcheck disable=SC2086
host=$(rustc $toolchain -vV | sed -n 's/^host: //p')
# shellcheck disable=SC2086
lld="$(rustc $toolchain --print sysroot)/lib/rustlib/$host/bin/rust-lld"
mkdir -p "$out"
# Undefined data as well as functions are imported: Rust's std takes
# the address of `errno`.
"$lld" -flavor wasm --experimental-pic -shared --no-entry --gc-sections \
    --unresolved-symbols=import-dynamic "${exports[@]}" \
    --whole-archive "$archive" --no-whole-archive -o "$out/$crate.wasm"

# A side module's first section is dylink.0.
if ! head -c 64 "$out/$crate.wasm" | grep -q dylink.0; then
    echo "$out/$crate.wasm is not a side module" >&2
    exit 1
fi
echo "wrote $out/$crate.wasm ($(wc -c < "$out/$crate.wasm" | tr -d ' ') bytes)"
