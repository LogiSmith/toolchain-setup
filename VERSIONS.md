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

## Conventions

- **Toolchain version** — `YYYY.MM.N` label for a tested bundle of the columns to
  its right. Bump `N` for same-month re-pins.
- **Anvil** — tracks the **latest published GitHub release** (`ANVIL_VERSION=latest`
  in `install.sh`), not `main`. The release tag matches the `VERSION` file in the
  Anvil repo. Pin a specific tag by setting `ANVIL_VERSION=vX.Y.Z`.
- **f4pga-examples** — pinned to a commit (`F4PGA_EXAMPLES_REF` in `install.sh`);
  its `environment.yml` defines the `xc7` conda env, so this fixes the env contents.
- **Simulation tools** (optional, `--no-sim`) — Verilator built from source
  (`VERILATOR_VERSION`, currently `v5.048`), plus cocotb (`2.0.1`) + forastero in a
  venv at `~/opt/verif`.
- A row is only added once the combination has passed the installer's end-to-end
  integration test on the listed platform.
