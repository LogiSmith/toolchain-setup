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
set -euo pipefail

# ─── Pinned versions ────────────────────────────────────────────────────────
SV2V_VERSION="v0.0.13"
F4PGA_TIMESTAMP="20220907-210059"
F4PGA_HASH="66a976d"
ANVIL_REPO="https://github.com/LogiSmith/Anvil.git"

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
step() { echo; echo "${B}==> $*${N}"; }
ok()   { echo "${G}  [ok]${N} $*"; }
skip() { echo "${Y}  [skip]${N} $*"; }
die()  { echo "${R}[ERROR]${N} $*" >&2; exit 1; }

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

# ─── 1. apt dependencies ────────────────────────────────────────────────────
step "1. Build dependencies (apt)"
if [ "$DO_APT" -eq 1 ]; then
  sudo apt-get update
  sudo apt-get install -y build-essential flex bison libssl-dev \
      libelf-dev bc python3 pahole cmake pkg-config \
      libusb-1.0-0-dev libudev-dev git g++ gcc \
      libftdi1-dev libhidapi-dev zlib1g-dev unzip wget
  sudo apt-get install -y iverilog gtkwave
  ok "apt packages installed"
else
  skip "apt steps (--skip-apt)"
fi

# ─── 2. Anvil CLI ───────────────────────────────────────────────────────────
step "2. Anvil CLI"
if [ -d "$ANVIL_DIR/.git" ]; then
  skip "Anvil already cloned at $ANVIL_DIR"
else
  mkdir -p "$(dirname "$ANVIL_DIR")"
  git clone "$ANVIL_REPO" "$ANVIL_DIR"
  ok "cloned Anvil"
fi
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
  wget -q "https://github.com/zachjs/sv2v/releases/download/$SV2V_VERSION/sv2v-Linux.zip" -O "$tmp/sv2v.zip"
  unzip -oq "$tmp/sv2v.zip" -d "$tmp"
  mkdir -p "$SV2V_DIR"
  cp "$tmp/sv2v-Linux/sv2v" "$SV2V_DIR/sv2v"
  chmod +x "$SV2V_DIR/sv2v"
  rm -rf "$tmp"
  ok "installed $("$SV2V_DIR/sv2v" --version)"
fi

# ─── 4. Miniconda ───────────────────────────────────────────────────────────
step "4. Miniconda"
if [ -f "$CONDA_SH" ]; then
  skip "Miniconda already at $CONDA_DIR"
else
  tmp="$(mktemp -d)"
  wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O "$tmp/miniconda.sh"
  bash "$tmp/miniconda.sh" -b -p "$CONDA_DIR"
  rm -rf "$tmp"
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
if conda env list | grep -qE "^xc7\s|/envs/xc7$"; then
  skip "conda env 'xc7' already exists"
else
  envyml="$F4PGA_EXAMPLES/environment.yml"
  [ -f "$envyml" ] || envyml="$F4PGA_EXAMPLES/xc7/environment.yml"
  [ -f "$envyml" ] || die "environment.yml not found in f4pga-examples"
  conda env create -f "$envyml"
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
  echo "  downloading install package..."
  wget -qO- "$base/symbiflow-arch-defs-install-${FPGA_FAM}-${F4PGA_HASH}.tar.xz" | tar -xJC "$F4PGA_INSTALL_DIR/${FPGA_FAM}"
  echo "  downloading xc7a100t device..."
  wget -qO- "$base/symbiflow-arch-defs-xc7a100t_test-${F4PGA_HASH}.tar.xz" | tar -xJC "$F4PGA_INSTALL_DIR/${FPGA_FAM}"
  touch "$marker"
  ok "installed arch defs"
fi

step "5c. Carry-chain patch"
patched=0
for f in "$CONDA_DIR"/envs/xc7/lib/python3*/site-packages/f4pga/utils/xc7/fix_xc7_carry.py; do
  [ -f "$f" ] || continue
  if grep -q "if list_of_cells\[0\] is not None: continue" "$f"; then
    skip "already patched ($f)"; patched=1; continue
  fi
  sed -i 's/assert list_of_cells\[0\] is None, (bit, list_of_cells\[0\], cellname)/if list_of_cells[0] is not None: continue/' "$f"
  ok "patched $f"; patched=1
done
[ "$patched" -eq 1 ] || echo "${Y}  [warn]${N} fix_xc7_carry.py not found — skipping patch."

# ─── 6. RISC-V toolchain (optional) ─────────────────────────────────────────
step "6. RISC-V toolchain (SoC firmware)"
if [ "$DO_RISCV" -eq 1 ]; then
  if command -v riscv64-unknown-elf-g++ >/dev/null; then
    skip "riscv64-unknown-elf-g++ already present"
  elif [ "$DO_APT" -eq 1 ]; then
    sudo apt-get install -y gcc-riscv64-unknown-elf
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
  TESTDIR="$HOME/opt/_anvil_integration_test"
  rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"
  trap 'rm -rf "$TESTDIR"' EXIT          # always clean up, even on failure

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

  rm -rf "$TESTDIR"; trap - EXIT
  ok "test project removed"
else
  skip "integration test (--no-test)"
fi

step "Done"
echo "Open a new shell (or 'source ~/.bashrc') so the 'anvil' alias and conda are active."
