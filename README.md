# toolchain-setup

[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

One-shot installer for the **LogiSmith open-source FPGA toolchain** on Ubuntu
(native or WSL2). It automates the [manual installation guide](https://logismith.github.io/Docs/installation/ubuntu/)
and verifies the result with an end-to-end build.

> Currently **Ubuntu only**. WSL2 USB/board setup and Docker are out of scope for now.

## What it installs

Everything Anvil needs, at the fixed paths `anvil.py` expects:

| Path | Component |
|------|-----------|
| `~/opt/anvil` | Anvil CLI |
| `~/opt/sv2v/sv2v` | SystemVerilog → Verilog converter |
| `~/miniconda3` | Conda + the `xc7` F4PGA environment |
| `~/opt/f4pga/xc7` | F4PGA architecture definitions (Artix-7) |
| `~/f4pga-examples` | F4PGA examples (`common.mk`) |

Plus the F4PGA carry-chain patch, and optionally the RISC-V toolchain and
openFPGALoader (board programming).

## Usage

```bash
git clone https://github.com/LogiSmith/toolchain-setup.git
cd toolchain-setup
./install.sh
```

Or in one line:

```bash
curl -fsSL https://raw.githubusercontent.com/LogiSmith/toolchain-setup/main/install.sh | bash
```

### Options

| Flag | Effect |
|------|--------|
| `--minimal` | Skip optional tools (RISC-V + openFPGALoader/board) |
| `--no-board` | Skip only openFPGALoader + udev |
| `--no-test` | Skip the end-to-end build self-test |
| `--skip-apt` | Skip the apt steps (deps already present) |
| `-h`, `--help` | Show help |

The installer is **idempotent** — re-running skips anything already installed.

## What the self-test does

After installing, it runs `anvil doctor` and then builds the `uart-hello`
example end to end, failing if no bitstream is produced. Skip with `--no-test`.

## License

Released under the [MIT License](LICENSE). © 2026 LogiSmith.
