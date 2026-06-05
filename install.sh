#!/usr/bin/env bash
#
# LogiSmith FPGA toolchain installer — Ubuntu (native or WSL2).
#
# Installs everything Anvil needs at the fixed paths it expects:
#   ~/opt/anvil          Anvil CLI
#   ~/opt/sv2v/sv2v      SystemVerilog -> Verilog
#   ~/miniconda3         Conda (with the `xc7` F4PGA env)
#   ~/opt/f4pga/xc7      F4PGA architecture definitions
#   ~/f4pga-examples     F4PGA examples (common.mk)
#
# Idempotent: safe to re-run; already-installed steps are skipped.
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --minimal     Skip optional tools (RISC-V toolchain + openFPGALoader/board)
#   --no-board    Skip only openFPGALoader + udev (no board programming)
#   --no-test     Skip the final integration test (scaffold/build/delete a project)
#   --skip-apt    Skip the apt-get steps (assume deps already present)
#   -h, --help    Show this help
#
set -Eeuo pipefail        # -E: ERR trap fires inside functions/subshells too

# Non-interactive apt: avoid needrestart/config prompts stalling under `curl | bash`.
export DEBIAN_FRONTEND=noninteractive

# ─── Pinned versions ────────────────────────────────────────────────────────
# This block is the toolchain "lockfile": the component versions that are tested
# to work together. See VERSIONS.md for the history of tested combinations.
ANVIL_VERSION="latest"                 # GitHub "Latest" release; or pin a tag, e.g. v1.0.0
SV2V_VERSION="v0.0.13"
SV2V_SHA256="552799a1d76cd177b9b4cc63a3e77823a3d2a6eb4ec006569288abeff28e1ff8"
F4PGA_TIMESTAMP="20220907-210059"
F4PGA_HASH="66a976d"
ANVIL_REPO="https://github.com/LogiSmith/Anvil.git"
ANVIL_LATEST_API="https://api.github.com/repos/LogiSmith/Anvil/releases/latest"

# SHA256 pins for the immutable, version-pinned F4PGA downloads.
# (Miniconda is intentionally "latest" — a moving target with no stable hash;
#  its integrity comes from HTTPS + the post-install conda check.)
F4PGA_INSTALL_SHA256="8fa1aa9cfc033c9fef59c2ac19d4ff18568a66bc8ce15c3385cd9ec1d1901274"
F4PGA_DEVICE_SHA256="49b355e8a442e46652c7b089c23dc020d4babb8009d8f4494e09d72e37b2e5ef"
# Carry-chain patch target (fix_xc7_carry.py). The f4pga package is pinned to a
# commit, so this file is deterministic: verify it's the known pre-patch version,
# then that our edit produced the known post-patch version.
CARRY_PRE_SHA256="3b6ac9ab514a9f56f9f42c1687d01beb4ab07e26aac52e98e11f568b29a443e5"
CARRY_POST_SHA256="b70beddff4ded4d48a6f3b158650a0d436af81599086afb523b6726f8325ae7b"

# ─── Paths (must match anvil.py) ────────────────────────────────────────────
ANVIL_DIR="$HOME/opt/anvil"
SV2V_DIR="$HOME/opt/sv2v"
CONDA_DIR="$HOME/miniconda3"
CONDA_SH="$CONDA_DIR/etc/profile.d/conda.sh"
F4PGA_INSTALL_DIR="$HOME/opt/f4pga"
F4PGA_EXAMPLES="$HOME/f4pga-examples"
FPGA_FAM="xc7"

# ─── Options ────────────────────────────────────────────────────────────────
DO_RISCV=1; DO_BOARD=1; DO_TEST=1; DO_APT=1

usage() {
  cat <<'EOF'
LogiSmith FPGA toolchain installer — Ubuntu (native or WSL2).

Usage: ./install.sh [options]

Options:
  --minimal     Skip optional tools (RISC-V toolchain + openFPGALoader/board)
  --no-board    Skip only openFPGALoader + udev (no board programming)
  --no-test     Skip the final integration test (scaffold/build/delete a project)
  --skip-apt    Skip the apt-get steps (assume deps already present)
  -h, --help    Show this help

Installs Anvil + sv2v + Miniconda/F4PGA at the fixed paths anvil.py expects.
Idempotent: safe to re-run; already-installed steps are skipped.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --minimal)  DO_RISCV=0; DO_BOARD=0 ;;
    --no-board) DO_BOARD=0 ;;
    --no-test)  DO_TEST=0 ;;
    --skip-apt) DO_APT=0 ;;
    -h|--help)  usage; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
  esac
done

# ─── Logging ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
CURRENT_STEP="startup"
step() { CURRENT_STEP="$*"; echo; echo "${B}==> $*${N}"; }
ok()   { echo "${G}  [ok]${N} $*"; }
skip() { echo "${Y}  [skip]${N} $*"; }
info() { echo "  $*"; }
die()  { echo "${R}[ERROR]${N} $*" >&2; exit 1; }

# ─── Failure handling ───────────────────────────────────────────────────────
# Any unhandled command failure (e.g. network drop mid-download/clone) lands here
# with the step name + the exact command, so the run never continues blindly.
on_error() {
  local line="$1" cmd="$2" ec="$3"
  echo >&2
  echo "${R}${B}✗ Install failed${N}${R} during step: ${CURRENT_STEP}${N}" >&2
  echo "${R}  command : ${cmd}${N}" >&2
  echo "${R}  exit    : ${ec} (line ${line})${N}" >&2
  echo "${Y}  Fix the issue and re-run — the installer is idempotent, so completed steps are skipped.${N}" >&2
  exit "$ec"
}
trap 'rc=$?; on_error "$LINENO" "$BASH_COMMAND" "$rc"' ERR

# Download with retries; fail loudly on a dead network and reject empty files.
download() {  # download <url> <dest>
  local url="$1" dest="$2"
  wget --tries=3 --timeout=30 --waitretry=5 -q "$url" -O "$dest" \
    || die "download failed (network?): $url"
  [ -s "$dest" ] || die "downloaded file is empty: $url"
}

# Verify a file's SHA256 against an expected value; no-op if expected is empty.
verify_sha256() {  # verify_sha256 <file> <expected|"">
  local file="$1" expected="${2:-}" actual
  [ -n "$expected" ] || { info "[info] no sha256 pinned for $(basename "$file") — skipping checksum"; return 0; }
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "checksum mismatch for $(basename "$file")
    expected: $expected
    actual:   $actual"
  info "[ok] sha256 verified: $(basename "$file")"
}

# Post-condition assertions — confirm a step actually produced what it should.
require_file() { [ -e "$1" ] || die "expected path missing after '${CURRENT_STEP}': $1"; }
require_cmd()  { command -v "$1" >/dev/null 2>&1 || die "expected command missing after '${CURRENT_STEP}': $1"; }

# Runtime tools the installer relies on. Most are provided by the apt step; under
# --skip-apt they must already be present. Checked early so a missing tool is a
# clear up-front error instead of a cryptic failure mid-run.
RUNTIME_TOOLS="curl git wget unzip tar xz sha256sum awk sed python3"
check_tools() {
  local t missing=""
  for t in $RUNTIME_TOOLS; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] || die "missing required tools:${missing}
    install them first (most come from the apt step; you passed --skip-apt)."
  ok "required tools present (${RUNTIME_TOOLS})"
}

# ─── Cleanup (single EXIT handler) ──────────────────────────────────────────
# One place to tear everything down, so individual steps don't fight over the
# EXIT trap. Runs on normal exit, on die(), and on an ERR-trap exit.
SUDO_KEEPALIVE_PID=""
TESTDIR=""
cleanup() {
  [ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  [ -n "$TESTDIR" ] && rm -rf "$TESTDIR" 2>/dev/null || true
}
trap cleanup EXIT

# ─── Preflight ──────────────────────────────────────────────────────────────
step "Preflight checks"
[ "$(uname -s)" = "Linux" ] || die "This installer targets Linux (Ubuntu)."
if [ -r /etc/os-release ]; then
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || echo "${Y}  [warn]${N} Tested on Ubuntu; '${ID:-unknown}' may differ."
fi
[ "$(id -u)" -ne 0 ] || die "Run as a normal user (not root); sudo is used where needed."
command -v sudo >/dev/null || die "sudo is required."
ok "Linux / user / sudo present"
# With --skip-apt nothing gets installed, so all runtime tools must already exist.
[ "$DO_APT" -eq 1 ] || check_tools

# Cache sudo credentials up front (clear early failure if the user can't sudo),
# then keep them warm in the background so a long install never re-prompts mid-run.
NEED_SUDO=0
if [ "$DO_APT" -eq 1 ] || [ "$DO_BOARD" -eq 1 ]; then NEED_SUDO=1; fi
if [ "$NEED_SUDO" -eq 1 ]; then
  sudo -v || die "sudo access is required (apt / board install) — run as a sudo-capable user, or use: --skip-apt --no-board"
  ( while true; do sleep 50; sudo -n true 2>/dev/null || break; done ) &
  SUDO_KEEPALIVE_PID=$!
  ok "sudo authenticated (keep-alive active)"
fi

# ─── 1. apt dependencies ────────────────────────────────────────────────────
step "1. Build dependencies (apt)"
if [ "$DO_APT" -eq 1 ]; then
  sudo apt-get update
  sudo apt-get install -y build-essential flex bison libssl-dev \
      libelf-dev bc python3 pahole cmake pkg-config \
      libusb-1.0-0-dev libudev-dev git g++ gcc \
      libftdi1-dev libhidapi-dev zlib1g-dev unzip wget curl xz-utils
  sudo apt-get install -y iverilog gtkwave
  ok "apt packages installed"
  check_tools   # verify apt actually delivered everything we depend on
else
  skip "apt steps (--skip-apt)"
fi

# ─── 2. Anvil CLI ───────────────────────────────────────────────────────────
step "2. Anvil CLI"
if [ ! -d "$ANVIL_DIR/.git" ]; then
  mkdir -p "$(dirname "$ANVIL_DIR")"
  git clone "$ANVIL_REPO" "$ANVIL_DIR"
  ok "cloned Anvil"
fi
# Resolve the target tag: the GitHub "Latest" release (NOT main — main and the
# latest release can be out of sync). Pin a specific tag via ANVIL_VERSION.
if [ "$ANVIL_VERSION" = "latest" ]; then
  target="$(curl -fsSL "$ANVIL_LATEST_API" 2>/dev/null \
    | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')"
else
  target="$ANVIL_VERSION"
fi
git -C "$ANVIL_DIR" fetch --tags --force --quiet origin 2>/dev/null || true
if [ -n "$target" ] && git -C "$ANVIL_DIR" checkout --quiet "$target" 2>/dev/null; then
  ok "Anvil at $target ($(git -C "$ANVIL_DIR" rev-parse --short HEAD))"
else
  echo "${Y}  [warn]${N} could not resolve latest release (got '$target') —"
  echo "          is a release published on GitHub? Staying on current branch."
  git -C "$ANVIL_DIR" pull --ff-only --quiet 2>/dev/null || true
fi
require_file "$ANVIL_DIR/anvil.py"
chmod +x "$ANVIL_DIR/anvil.py"
if ! grep -qs 'alias anvil=' "$HOME/.bashrc"; then
  echo "alias anvil=\"python3 $ANVIL_DIR/anvil.py\"" >> "$HOME/.bashrc"
  ok "added 'anvil' alias to ~/.bashrc"
else
  skip "'anvil' alias already in ~/.bashrc"
fi
# Resolve the command the installed `anvil` alias actually runs, straight from
# ~/.bashrc. This lets the verify/test steps exercise the real installed entry
# point without an interactive shell (aliases only expand interactively, and an
# interactive shell fights job control under `curl | bash`). Falls back to the
# known launcher if the alias line can't be parsed.
ANVIL_CMD="$(sed -nE 's/^alias anvil="(.*)"$/\1/p' "$HOME/.bashrc" | head -1)"
[ -n "$ANVIL_CMD" ] || ANVIL_CMD="python3 $ANVIL_DIR/anvil.py"

# ─── 3. sv2v ────────────────────────────────────────────────────────────────
step "3. sv2v ($SV2V_VERSION)"
if [ -x "$SV2V_DIR/sv2v" ] && "$SV2V_DIR/sv2v" --version 2>/dev/null | grep -q "${SV2V_VERSION#v}"; then
  skip "sv2v $SV2V_VERSION already at $SV2V_DIR/sv2v"
else
  tmp="$(mktemp -d)"
  download "https://github.com/zachjs/sv2v/releases/download/$SV2V_VERSION/sv2v-Linux.zip" "$tmp/sv2v.zip"
  verify_sha256 "$tmp/sv2v.zip" "$SV2V_SHA256"
  unzip -oq "$tmp/sv2v.zip" -d "$tmp"
  mkdir -p "$SV2V_DIR"
  cp "$tmp/sv2v-Linux/sv2v" "$SV2V_DIR/sv2v"
  chmod +x "$SV2V_DIR/sv2v"
  rm -rf "$tmp"
  require_file "$SV2V_DIR/sv2v"
  "$SV2V_DIR/sv2v" --version >/dev/null || die "sv2v installed but not runnable"
  ok "installed $("$SV2V_DIR/sv2v" --version)"
fi

# ─── 4. Miniconda ───────────────────────────────────────────────────────────
step "4. Miniconda"
if [ -f "$CONDA_SH" ]; then
  skip "Miniconda already at $CONDA_DIR"
else
  tmp="$(mktemp -d)"
  # Intentionally the latest installer (moving target, no stable hash to pin).
  # What matters for reproducibility is the xc7 env (pinned by environment.yml),
  # not the Miniconda version. Integrity: HTTPS + the require_file check below.
  download "https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh" "$tmp/miniconda.sh"
  bash "$tmp/miniconda.sh" -b -p "$CONDA_DIR"
  rm -rf "$tmp"
  require_file "$CONDA_SH"
  ok "installed Miniconda"
fi
if ! grep -qs "conda.sh" "$HOME/.bashrc"; then
  echo "source $CONDA_SH" >> "$HOME/.bashrc"
  ok "added conda init to ~/.bashrc"
fi
# shellcheck disable=SC1090
source "$CONDA_SH"

# ─── 5. F4PGA environment ───────────────────────────────────────────────────
step "5. F4PGA conda environment ($FPGA_FAM)"
if [ ! -d "$F4PGA_EXAMPLES/.git" ]; then
  git clone https://github.com/chipsalliance/f4pga-examples "$F4PGA_EXAMPLES"
  ok "cloned f4pga-examples"
else
  skip "f4pga-examples already at $F4PGA_EXAMPLES"
fi
# Accept Anaconda channel Terms of Service non-interactively. Without this, conda
# prompts on stdin during solving — which under `curl | bash` IS the installer
# script, so conda consumes the rest of it and the run silently stops.
conda tos accept --channel https://repo.anaconda.com/pkgs/main \
                 --channel https://repo.anaconda.com/pkgs/r >/dev/null 2>&1 || true
if conda env list | grep -qE "^xc7\s|/envs/xc7$"; then
  skip "conda env 'xc7' already exists"
else
  envyml="$F4PGA_EXAMPLES/environment.yml"
  [ -f "$envyml" ] || envyml="$F4PGA_EXAMPLES/xc7/environment.yml"
  [ -f "$envyml" ] || die "environment.yml not found in f4pga-examples"
  conda env create -f "$envyml" < /dev/null   # < /dev/null: extra guard so conda can't eat the script
  conda env list | grep -qE "^xc7\s|/envs/xc7$" || die "conda env 'xc7' not found after create"
  ok "created conda env 'xc7'"
fi

step "5b. F4PGA architecture definitions (Artix-7)"
marker="$F4PGA_INSTALL_DIR/$FPGA_FAM/.installed-$F4PGA_HASH"
# Skip if our marker exists, OR if arch defs are already extracted on disk
# (e.g. installed manually / from an exported image) — then write the marker.
if [ -f "$marker" ] || [ -d "$F4PGA_INSTALL_DIR/$FPGA_FAM/share" ]; then
  touch "$marker" 2>/dev/null || true
  skip "arch defs already installed (found $F4PGA_INSTALL_DIR/$FPGA_FAM/share)"
else
  mkdir -p "$F4PGA_INSTALL_DIR/$FPGA_FAM"
  base="https://storage.googleapis.com/symbiflow-arch-defs/artifacts/prod/foss-fpga-tools/symbiflow-arch-defs/continuous/install/${F4PGA_TIMESTAMP}"
  tmp="$(mktemp -d)"
  # Download to files first (with retries + optional checksum) so a truncated
  # transfer is caught before we extract, instead of streaming straight to tar.
  info "downloading install package..."
  download "$base/symbiflow-arch-defs-install-${FPGA_FAM}-${F4PGA_HASH}.tar.xz" "$tmp/install.tar.xz"
  verify_sha256 "$tmp/install.tar.xz" "$F4PGA_INSTALL_SHA256"
  info "downloading xc7a100t device..."
  download "$base/symbiflow-arch-defs-xc7a100t_test-${F4PGA_HASH}.tar.xz" "$tmp/device.tar.xz"
  verify_sha256 "$tmp/device.tar.xz" "$F4PGA_DEVICE_SHA256"
  info "extracting..."
  tar -xJf "$tmp/install.tar.xz" -C "$F4PGA_INSTALL_DIR/${FPGA_FAM}"
  tar -xJf "$tmp/device.tar.xz"  -C "$F4PGA_INSTALL_DIR/${FPGA_FAM}"
  rm -rf "$tmp"
  require_file "$F4PGA_INSTALL_DIR/$FPGA_FAM/share"
  touch "$marker"
  ok "installed arch defs"
fi

step "5c. Carry-chain patch"
# Hash-verified patch: confirm the file is the known pre-patch version, apply the
# edit, then confirm it became the known post-patch version. Refuses to touch an
# unexpected file (e.g. if the pinned f4pga version ever changes).
patched=0
for f in "$CONDA_DIR"/envs/xc7/lib/python3*/site-packages/f4pga/utils/xc7/fix_xc7_carry.py; do
  [ -f "$f" ] || continue
  patched=1
  cur="$(sha256sum "$f" | awk '{print $1}')"
  if [ "$cur" = "$CARRY_POST_SHA256" ]; then
    skip "already patched (sha256 verified)"
  elif [ "$cur" = "$CARRY_PRE_SHA256" ]; then
    sed -i 's/assert list_of_cells\[0\] is None, (bit, list_of_cells\[0\], cellname)/if list_of_cells[0] is not None: continue/' "$f"
    new="$(sha256sum "$f" | awk '{print $1}')"
    [ "$new" = "$CARRY_POST_SHA256" ] || die "carry patch produced unexpected result (sha256 $new)"
    ok "patched + verified ($(basename "$f"))"
  else
    die "unexpected fix_xc7_carry.py (sha256 $cur) — pinned f4pga version may have changed; update CARRY_*_SHA256"
  fi
done
[ "$patched" -eq 1 ] || echo "${Y}  [warn]${N} fix_xc7_carry.py not found — skipping patch."

# ─── 6. RISC-V toolchain (optional) ─────────────────────────────────────────
step "6. RISC-V toolchain (SoC firmware)"
if [ "$DO_RISCV" -eq 1 ]; then
  if command -v riscv64-unknown-elf-g++ >/dev/null; then
    skip "riscv64-unknown-elf-g++ already present"
  elif [ "$DO_APT" -eq 1 ]; then
    sudo apt-get install -y gcc-riscv64-unknown-elf
    require_cmd riscv64-unknown-elf-g++
    ok "installed RISC-V toolchain"
  else
    skip "would apt-install gcc-riscv64-unknown-elf (--skip-apt)"
  fi
else
  skip "RISC-V toolchain (--minimal)"
fi

# ─── 7. openFPGALoader + udev (optional) ────────────────────────────────────
step "7. openFPGALoader (board programming)"
if [ "$DO_BOARD" -eq 1 ]; then
  if [ -x /usr/local/bin/openFPGALoader ]; then
    skip "openFPGALoader already installed"
  else
    tmp="$(mktemp -d)"
    git clone https://github.com/trabucayre/openFPGALoader "$tmp/ofl"
    ( cd "$tmp/ofl" && mkdir -p build && cd build && cmake .. && make -j"$(nproc)" && sudo make install )
    rm -rf "$tmp"
    require_file /usr/local/bin/openFPGALoader
    ok "built and installed openFPGALoader"
  fi
  rules=/etc/udev/rules.d/99-openfpgaloader.rules
  if [ ! -f "$rules" ]; then
    echo 'SUBSYSTEM=="usb", ATTR{idVendor}=="0403", ATTR{idProduct}=="6010", MODE="0666", GROUP="plugdev"' | sudo tee "$rules" >/dev/null
    sudo usermod -aG plugdev "$USER" || true
    sudo udevadm control --reload-rules 2>/dev/null && sudo udevadm trigger 2>/dev/null || true
    ok "added udev rule for FTDI 0403:6010"
  else
    skip "udev rule already present"
  fi
else
  skip "openFPGALoader + udev (--no-board / --minimal)"
fi

# ─── 8. Verify ──────────────────────────────────────────────────────────────
step "8. Verify — anvil doctor"
$ANVIL_CMD doctor < /dev/null

# ─── 9. Integration test ────────────────────────────────────────────────────
# Final end-to-end check using the installed `anvil` command (resolved from the
# alias in ~/.bashrc): scaffold a test project under ~/opt, build it to a
# bitstream, then remove it. Skip with --no-test.
#
# Runs non-interactively with stdin from /dev/null so that, even under
# `curl | bash`, no child can grab the terminal for job control (which otherwise
# stops the whole pipeline when a long job like `anvil build` starts).
if [ "$DO_TEST" -eq 1 ]; then
  step "9. Integration test (system commands)"
  TESTDIR="$HOME/opt/_anvil_integration_test"   # global: removed by cleanup() on any exit
  rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"

  echo "  scaffolding + building a test project in $TESTDIR ..."
  set +e
  ( cd "$TESTDIR" \
      && $ANVIL_CMD init --board Nexys-A7-100T --example uart-hello \
      && $ANVIL_CMD build ) < /dev/null
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || die "integration test FAILED during 'anvil init'/'anvil build'"

  bit="$(find "$TESTDIR/build" -name '*.bit' 2>/dev/null | head -1)"
  [ -n "$bit" ] || die "integration test FAILED — no bitstream produced"
  ok "bitstream produced: ${bit#$TESTDIR/}"

  rm -rf "$TESTDIR"; TESTDIR=""    # cleaned up; clear so cleanup() is a no-op
  ok "test project removed"
else
  skip "integration test (--no-test)"
fi

echo
if [ "$DO_TEST" -eq 1 ]; then
  echo "${G}${B}✓ Toolchain installed and all tests passed${N}"
else
  echo "${G}${B}✓ Toolchain installed${N}${G} (integration test skipped)${N}"
fi
echo "Open a new shell (or 'source ~/.bashrc') so the 'anvil' alias and conda are active."
