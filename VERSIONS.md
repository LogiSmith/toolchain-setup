# Toolchain versions

Known-good component versions — combinations that have been **tested together**.
The machine-readable pins live in the "Pinned versions" block at the top of
[`install.sh`](install.sh); this file is the human-readable history of what was
tested, so updates aren't blind.

When bumping a pin: change it in `install.sh`, run the installer end to end
(including the integration test), and add a row here.

| Toolchain | Anvil | sv2v | F4PGA arch-defs | f4pga-examples | Tested on | Date | Notes |
|-----------|-------|------|-----------------|----------------|-----------|------|-------|
| 2026.06.0 | v1.0.0 | v0.0.13 | `66a976d` (20220907-210059) | `13f1119` | Ubuntu 22.04 / WSL2 | 2026-06-05 | Initial pinned set |

## Windows / WSL 2 side

Pins for [`wsl-setup.ps1`](wsl-setup.ps1) (constants at the top of the script).
Unlike the toolchain pins these are **floors, not exact versions** — newer is fine.

| Component | Pin | Kind | Why |
|-----------|-----|------|-----|
| WSL | `2.7.13.0` | tested | first set verified end to end with the board flow |
| WSL kernel | `6.18.33.2` | tested | ships `vhci-hcd` + `ftdi_sio` as modules |
| WSL (absolute) | `2.4.4` | hard | `wsl --install --name` exists from here on |

The tested pins stop the run by default; `-AllowOlder` drops them to a warning.
They are a convenience gate only — the **authority is the module check** (step 6),
which loads `vhci-hcd` + `ftdi_sio` and verifies them in `lsmod` or
`modules.builtin`. A kernel that passes that check works regardless of its number.

The WSL pin is stored twice, in two formats, because the tools disagree: `$MIN_WSL`
= `2.7.13.0` (what `wsl --version` prints) and `$MIN_WSL_WINGET` = `2.7.13` (what
winget calls the same release). **Bump both together.**

Separately from versions, step 4b self-tests the *command channel* (does
`wsl --exec` still pass arguments, quoting and exit codes through unchanged). If a
future WSL breaks that, the script refuses to run and prints how to pin WSL back to
`$MIN_WSL_WINGET` — see ADR 0003 in [DECISIONS.md](DECISIONS.md).

## Conventions

- **Toolchain version** — `YYYY.MM.N` label for a tested bundle of the columns to
  its right. Bump `N` for same-month re-pins.
- **Anvil** — tracks the **latest published GitHub release** (`ANVIL_VERSION=latest`
  in `install.sh`), not `main`. The release tag matches the `VERSION` file in the
  Anvil repo. Pin a specific tag by setting `ANVIL_VERSION=vX.Y.Z`.
- **f4pga-examples** — pinned to a commit (`F4PGA_EXAMPLES_REF` in `install.sh`);
  its `environment.yml` defines the `xc7` conda env, so this fixes the env contents.
- **F4PGA arch-defs** — one base package plus one tarball per device, listed as
  `<device>:<sha256>` in `F4PGA_DEVICES`. All come from the single
  `F4PGA_TIMESTAMP`/`F4PGA_HASH` build, so devices are never mixed across builds.
  Each device is marked installed separately, so adding a board to Anvil's
  `boards.json` only downloads the one architecture that board needs. The list
  must cover every `vpr_device` in `boards.json` — `anvil doctor` reports a
  mismatch.
- **Simulation tools** (optional, `--no-sim`) — Verilator built from source
  (`VERILATOR_VERSION`, currently `v5.048`), plus cocotb (`1.9.2`) + forastero in a
  venv at `~/opt/verif`. (cocotb pinned to 1.9.2 because forastero needs cocotb <2.0.)
- A row is only added once the combination has passed the installer's end-to-end
  integration test on the listed platform.
