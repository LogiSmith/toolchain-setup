# Decision log

Lightweight ADRs (Architecture Decision Records) for the toolchain setup.
Newest first. Each entry: status, context, decision, consequences, follow-up.

---

## ADR 0001 — `install.sh` is the current setup mechanism; migrate to Nix later

**Status:** Accepted (stopgap) · 2026-06-05

**Context.**
We need a reproducible way to install the FPGA toolchain (Anvil, sv2v,
Miniconda/F4PGA, …) on Ubuntu/WSL2. Options considered: manual docs, an install
script, Docker, and Nix.

- Docker was rejected for our setup: we run under **WSL2 (Windows)**, where Docker
  Desktop adds a Linux VM + slow bind-mount filesystem (real overhead). We want
  the toolchain running **directly on Ubuntu**, native speed. (Note: on native
  Linux, Docker is near-native — the penalty is Windows-specific.)
- **Nix** is the better long-term fit: it runs **natively on the host (no VM)**
  yet gives bit-exact, declarative, reproducible environments — exactly the
  "direct on Ubuntu but reproducible" goal. It is strictly more powerful than a
  shell script (pinned `flake.lock`, multiple versions, `nix develop` per-project
  shells, rollback).

**Decision.**
Ship an idempotent **`install.sh`** now. It is the pragmatic, industry-common
choice (rustup/nvm/Homebrew style) and works today.

**Consequences.**
- Imperative: it mutates the host system; reproducibility is best-effort, not
  guaranteed.
- Good enough for current needs and as a single source of truth that Docker/Nix
  could later reuse.

**Follow-up — migrate to Nix.**
- Most tools are already in nixpkgs (`yosys`, `nextpnr`, `vpr`, `openFPGALoader`,
  `sv2v`, `iverilog`, `gtkwave`, RISC-V toolchain).
- The real work: **F4PGA / SymbiFlow `symbiflow-arch-defs` are not in nixpkgs** —
  they'd need a custom derivation pulling the pinned tarballs.
- **Anvil would need to stop depending on Conda + hardcoded paths.** Today
  `anvil.py` hardcodes `~/miniconda3`, conda env `xc7`, `~/opt/f4pga`, and runs
  `conda_run` (sources conda). Under Nix, tools arrive on `PATH` via
  `nix develop` and Conda disappears. This is an architectural change, not a tweak.
- Estimate: a few days + Nix learning curve. Trigger to prioritise: F4PGA version
  drift causing "works on one machine, not another".

---

## ADR 0002 — Toolchain is currently Xilinx (xc7) only; generalise to other chips later

**Status:** Accepted (known limitation) · 2026-06-05

**Context.**
The current flow is hardwired to the Xilinx 7-series (xc7) F4PGA target (Artix-7,
Nexys A7). Several variables and steps are xc7/Xilinx-specific and would not work
for other families/vendors (e.g. Lattice ice40/ecp5 via yosys+nextpnr, QuickLogic
eos-s3 via F4PGA).

**Decision.**
Accept Xilinx-only for now. Record the hardcoded spots so generalisation is a
mechanical follow-up rather than archaeology.

**Xilinx-specific spots to generalise.**

In `install.sh`:
- `FPGA_FAM="xc7"` and the `~/opt/f4pga/xc7` install dir.
- Conda env named `xc7` (create + detect).
- Arch-defs downloads: `symbiflow-arch-defs-install-xc7-*` and
  `symbiflow-arch-defs-xc7a100t_test-*` (xc7a100t = Artix-7).
- Pinned `F4PGA_TIMESTAMP` / `F4PGA_HASH` (point at xc7 artifacts).
- Carry-chain patch path: `f4pga/utils/xc7/fix_xc7_carry.py`.
- udev rule `0403:6010` (Nexys FTDI — board-specific, not chip-family).

In `anvil.py`:
- `CONDA_ENV = "xc7"` and `export FPGA_FAM=xc7` in `conda_run` (hardcoded).
- `boards.json` entries (`device: artix7`, `partname: xc7*`) and the
  `target → device/partname` map in `common/common.mk`.

**Follow-up.**
- Parameterise `FPGA_FAM` / family per board (drive it from `boards.json`).
- Make the installer take a target family (e.g. `--family xc7|eos-s3`) and fetch
  the matching arch-defs + conda env.
- Apply the carry patch only for families that need it.
- Likely folded into the Nix migration (ADR 0001), since per-family environments
  are exactly what `nix develop` shells model well.
