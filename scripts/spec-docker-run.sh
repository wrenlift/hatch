#!/usr/bin/env bash
# spec-docker-run.sh — entry script inside the spec-docker container.
#
# This is the in-container half of the local Linux spec runner. It
# mirrors `.github/workflows/regression.yml`'s build + stage + run
# pipeline so the local reproduction matches CI step-for-step:
#
#   1. Build wlift + the plugin cdylib set from /wren_lift source.
#   2. Stage each plugin's lib<crate>.so into the owning package's
#      libs/linux-x86_64/ (matches how the publish job stages dylibs
#      against the per-triple [native_libs] hatchfile mapping).
#   3. Topo-build every package into a workspace-local
#      $HATCH_CACHE_DIR, mirroring each artifact under any
#      version any sibling pins so HATCH_OFFLINE=1 lookups land.
#   4. Run every package's `*.spec.wren` under the chosen mode
#      (defaults to tiered to maximise overlap with the CI flake
#      surface — interpreter mode is reachable via MODE=interpreter
#      or `spec-docker.sh -m interpreter`).
#
# Inputs (all via env, set by spec-docker.sh on the host side):
#
#   WLIFT_SRC          — host wren_lift checkout mounted to /wren_lift
#   HATCH_DIR          — this repo mounted to /hatch (== $PWD here)
#   MODE               — interpreter | tiered (default tiered)
#   PKG_FILTER         — optional substring; only matching pkgs run
#   HATCH_CI_SKIP      — space-separated skip list. Default matches
#                        regression.yml's hardware-bound list +
#                        @hatch:postfx (pending the VM
#                        layout-from-bundle fix).
#
# Cargo cache layout — set by spec-docker.sh's volume mounts:
#
#   CARGO_TARGET_DIR=/spec-target  → named volume for build artefacts
#   CARGO_HOME=/spec-cargo         → named volume for registry/git
#
# Why not just rely on $WLIFT_SRC/target/?  On macOS hosts the source
# mount goes through osxfs / virtiofs which makes cargo's
# many-small-files writes glacial; persisting target/ inside a Linux-
# native docker volume keeps the second rebuild fast (~10s for the
# incremental wlift binary on a quad-core).

set -u

# --- 0. Resolve inputs -----------------------------------------------------

WLIFT_SRC="${WLIFT_SRC:-/wren_lift}"
HATCH_DIR="${HATCH_DIR:-/hatch}"
MODE="${MODE:-tiered}"
PKG_FILTER="${PKG_FILTER:-${1:-}}"
HATCH_CI_SKIP="${HATCH_CI_SKIP:-hatch-audio hatch-gpu hatch-window hatch-postfx}"
HATCH_CACHE_DIR="${HATCH_CACHE_DIR:-/tmp/hatch-cache}"

if [ ! -d "$WLIFT_SRC" ]; then
  echo "::error::wren_lift source not mounted at $WLIFT_SRC"
  echo "  set WLIFT_SRC on the host and re-run spec-docker.sh"
  exit 2
fi
if [ ! -d "$HATCH_DIR" ]; then
  echo "::error::hatch repo not mounted at $HATCH_DIR"
  exit 2
fi

# --- 1. Build wlift + plugins ---------------------------------------------

echo "==> [1/4] building wlift + plugins from $WLIFT_SRC"
cd "$WLIFT_SRC"
cargo build --release --bin wlift --bin hatch
# Same plugin set + ordering as `regression.yml`'s "Build plugins"
# step. Keep them in sync when a new plugin lands.
for crate in wlift_audio wlift_gpu wlift_image wlift_noise wlift_physics wlift_sqlite wlift_window; do
  cargo build --release -p "$crate"
done

WLIFT="$WLIFT_SRC/target/release/wlift"
HATCH="$WLIFT_SRC/target/release/hatch"
if [ "${CARGO_TARGET_DIR:-}" != "" ]; then
  WLIFT="$CARGO_TARGET_DIR/release/wlift"
  HATCH="$CARGO_TARGET_DIR/release/hatch"
fi
PLUGIN_SO_DIR="$(dirname "$WLIFT")"

echo "    wlift:  $WLIFT"
echo "    hatch:  $HATCH"
echo "    libs:   $PLUGIN_SO_DIR"

# --- 2. Stage plugin dylibs into packages ---------------------------------

cd "$HATCH_DIR"

echo "==> [2/4] staging plugin dylibs into packages/<pkg>/libs/linux-x86_64/"
python3 - "$PLUGIN_SO_DIR" << 'PY'
import os, shutil, sys, tomllib
plugin_dir = sys.argv[1]
for d in sorted(os.listdir("packages")):
    hf = os.path.join("packages", d, "hatchfile")
    if not os.path.isfile(hf):
        continue
    with open(hf, "rb") as f:
        m = tomllib.load(f)
    ps = m.get("plugin_source")
    if not ps:
        continue
    crate = ps.get("crate")
    if not crate:
        continue
    src = os.path.join(plugin_dir, f"lib{crate}.so")
    dst_dir = os.path.join("packages", d, "libs", "linux-x86_64")
    os.makedirs(dst_dir, exist_ok=True)
    if os.path.isfile(src):
        shutil.copy(src, os.path.join(dst_dir, f"lib{crate}.so"))
        print(f"    staged {crate:20s} → {dst_dir}")
    else:
        print(f"::warning::missing plugin {crate} (expected {src})")
PY

# --- 3. Topo pre-build into local cache -----------------------------------

echo "==> [3/4] topo pre-build → $HATCH_CACHE_DIR"
mkdir -p "$HATCH_CACHE_DIR"
python3 - "$HATCH" << 'PY'
# Walk packages/, build each in topo order against its
# [dependencies], and mirror under every pinned version a sibling
# asks for. Exactly the same logic as regression.yml's "Pre-build
# packages into local hatch cache" step — keep them in sync when
# either side changes.
import os, shutil, subprocess, sys, tomllib

HATCH_BIN = sys.argv[1]
CACHE_DIR = os.environ["HATCH_CACHE_DIR"]
PACKAGES_DIR = "packages"

def scoped_to_dir(name):
    return name[1:].replace(":", "-").replace("/", "-") if name.startswith("@") else name.replace(":", "-").replace("/", "-")

pkgs = {}
for d in sorted(os.listdir(PACKAGES_DIR)):
    hf = os.path.join(PACKAGES_DIR, d, "hatchfile")
    if not os.path.isfile(hf):
        continue
    with open(hf, "rb") as f:
        m = tomllib.load(f)
    pkgs[m["name"]] = {
        "dir": os.path.join(PACKAGES_DIR, d),
        "version": m["version"],
        "deps": list((m.get("dependencies") or {}).keys()),
        "manifest": m,
    }

remaining = dict(pkgs)
ordered = []
while remaining:
    ready = sorted(
        name for name, info in remaining.items()
        if all(d not in remaining for d in info["deps"])
    )
    if not ready:
        print(f"::error::dependency cycle among: {sorted(remaining)}")
        sys.exit(1)
    for name in ready:
        ordered.append(name)
        del remaining[name]

required_versions = {}
for info in pkgs.values():
    for dep_name in info["deps"]:
        dep_decl = (info["manifest"].get("dependencies") or {}).get(dep_name)
        if isinstance(dep_decl, str):
            required_versions.setdefault(dep_name, set()).add(dep_decl)

for name in ordered:
    info = pkgs[name]
    dir_ = info["dir"]
    version = info["version"]
    flat = scoped_to_dir(name)
    out_path = os.path.join(dir_, f"{name}.hatch")
    try:
        subprocess.run(
            [HATCH_BIN, "build", dir_],
            check=True,
            env={**os.environ, "HATCH_CACHE_DIR": CACHE_DIR},
            stdout=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError as e:
        print(f"::error::hatch build failed for {name}: {e}")
        sys.exit(1)
    if not os.path.isfile(out_path):
        print(f"::error::expected {out_path} after hatch build")
        sys.exit(1)
    cache_name = f"{flat}-{version}.hatch"
    shutil.copy(out_path, os.path.join(CACHE_DIR, cache_name))
    for pinned in required_versions.get(name, set()):
        if pinned == version:
            continue
        alias = f"{flat}-{pinned}.hatch"
        shutil.copy(out_path, os.path.join(CACHE_DIR, alias))
    print(f"    cached {name}@{version}")
PY

# --- 4. Run specs ----------------------------------------------------------

echo "==> [4/4] running specs ($MODE${PKG_FILTER:+, filter=$PKG_FILTER})"
echo ""

export HATCH_OFFLINE=1
export HATCH_CACHE_DIR

total=0
passed=0
skipped=0
failed_pkgs=()

for dir in packages/*/; do
  pkg=$(basename "$dir")
  hf="$dir/hatchfile"
  [ -f "$hf" ] || continue
  spec=$(ls "$dir"*.spec.wren 2>/dev/null | head -1 || true)
  [ -n "$spec" ] || continue

  if [[ -n "$PKG_FILTER" && "$pkg" != *"$PKG_FILTER"* ]]; then
    continue
  fi

  if [[ " $HATCH_CI_SKIP " == *" $pkg "* ]]; then
    echo "  [skip]  $pkg (HATCH_CI_SKIP)"
    skipped=$((skipped + 1))
    continue
  fi

  # Plugin-backed packages need a .so staged in libs/. The build
  # step above tries; if it missed, skip with a clear note rather
  # than failing the whole run on what's likely a missing-crate
  # plumbing issue.
  if grep -q '^\[plugin_source\]' "$hf"; then
    if ! find "$dir"libs -maxdepth 2 -name '*.so' -print -quit 2>/dev/null | grep -q .; then
      echo "  [skip]  $pkg (plugin-backed, no .so staged)"
      skipped=$((skipped + 1))
      continue
    fi
  fi

  total=$((total + 1))
  specname=$(basename "$spec")
  pushd "$dir" >/dev/null

  if output=$("$WLIFT" --mode "$MODE" "$specname" 2>&1); then
    clean=$(echo "$output" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
    if echo "$clean" | grep -q "^ok:"; then
      summary=$(echo "$clean" | grep "^ok:" | head -1)
      echo "  [ok]    $pkg — $summary"
      passed=$((passed + 1))
    else
      echo "  [FAIL]  $pkg (no ok summary)"
      echo "$clean" | tail -20 | sed 's/^/      /'
      failed_pkgs+=("$pkg")
    fi
  else
    rc=$?
    echo "  [FAIL]  $pkg (wlift exit $rc)"
    echo "$output" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tail -20 | sed 's/^/      /'
    failed_pkgs+=("$pkg")
  fi
  popd >/dev/null
done

echo ""
echo "================================================================"
echo "  $MODE: $passed / $total ran cleanly ($skipped skipped)"
echo "================================================================"
if [ ${#failed_pkgs[@]} -gt 0 ]; then
  echo ""
  echo "Failing packages:"
  for p in "${failed_pkgs[@]}"; do echo "  - $p"; done
  exit 1
fi
