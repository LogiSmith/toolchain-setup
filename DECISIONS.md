# Decision log

Lightweight ADRs (Architecture Decision Records) for the toolchain setup.
Ordered by ADR number. Each entry: status, context, decision, consequences, follow-up.

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

---

## ADR 0003 — Windows support is a separate WSL helper, not a branch of `install.sh`

**Status:** Accepted · 2026-09-05

**Context.**
Most students run Windows. `install.sh` is a Linux script and cannot check
anything on the Windows side — yet that is where the failures actually happen:
WSL missing or WSL 1, a WSL/kernel too old to have `vhci-hcd` + `ftdi_sio` (so the
board can never be attached), a custom kernel from `.wslconfig`, a distro that
comes up as `root` (which `install.sh` refuses), no `usbipd-win`. Detecting these
*after* a 30-minute toolchain install is the worst possible time.

**Decision.**
Ship `wsl-setup.ps1`: a PowerShell **helper**, not a second installer. It creates a
dedicated distro (default name `anvil`, never overwriting an existing one), verifies
the kernel modules actually load, and only then hands off to `install.sh` inside the
distro. `install.sh` stays the single source of truth for what gets installed.

Version handling is deliberately layered, because a version number is a poor proxy
for "does the board work":
- **hard floor** (WSL 2.4.4) — below it `wsl --install --name` does not exist, so the
  script cannot do its job; not waivable;
- **tested pins** (WSL 2.7.13.0, kernel 6.18.33.2) — stop by default, but `-AllowOlder`
  drops them to a warning, because Microsoft can ship a good kernel with a *lower*
  number (an LTS branch) and a stale pin must not block a working setup;
- **module check** — the authority. It decides, not the numbers.

**Consequences.**
- Two entry points to keep in sync — but only at the boundary (the handoff to
  `install.sh`), not in install logic.
- The version minimums are Windows-side pins that will drift; they live as two
  constants at the top of the script.
- Interactive by design (distro name, WSL's own username/password prompt), so it
  is not usable unattended — acceptable for a one-time setup on a student laptop.
- Requires a UTF-8 **BOM**: Windows PowerShell 5.1 misreads the script's non-ASCII
  characters without it.
- Every command sent into a distro must use `wsl --exec`, never `wsl -- cmd`. The
  plain form runs the command through the distro's **default shell first**, which
  expands shell variables it does not know (to nothing) and consumes quoting before
  the intended command ever sees the text. It fails silently and sometimes appears
  to work, because that first shell happily performs the pipes and redirections
  itself. Diagnostic: `wsl -d X -- bash -lc 'echo $BASH_VERSION'` reaches bash
  already expanded, as a syntax error; with `--exec` it prints the version.
  Related: Windows PowerShell 5.1 does not escape double quotes when building a
  native command line, so command strings use single quotes only.
- `--exec` resolves a bare program name against `/usr/bin` but **not** `/usr/sbin`,
  even though the running process's own `PATH` contains both. So `modprobe`,
  `adduser` and `usermod` go through `bash -lc`. The failure reads
  `execvpe(modprobe) failed: No such file or directory`, which looks like a missing
  package rather than a lookup problem. `lsmod` masks this nicely: it works only
  because `/usr/bin/lsmod` exists as a symlink while `/usr/bin/modprobe` does not.
- Creating the distro with `--no-launch` and invoking its own first-run setup
  (`[oobe] command` in `/etc/wsl-distribution.conf`) avoids stranding the user in a
  Linux shell that the script silently waits on. The cost: WSL's *default user* is
  a separate setting that a normal launch would have set, so the script sets it
  explicitly with `wsl --manage <distro> --set-default-user`. A distro can
  otherwise have a valid account and still start as root.

**Follow-up.**
Same as ADR 0001 — a Nix migration does not remove the Windows-side needs (WSL
version, kernel modules, usbipd), so this helper survives it.
