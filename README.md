# toolchain-setup


One-shot installer for the **LogiSmith open-source FPGA toolchain** on Ubuntu
(native or WSL2) or **Arch Linux**. It automates the [manual installation guide](https://logismith.github.io/Docs/installation/ubuntu/)
and verifies the result with an end-to-end build.

On Windows, [`wsl-setup.ps1`](wsl-setup.ps1) prepares the WSL 2 distro first
(versions, USB/IP + FTDI kernel modules) and then runs `install.sh` inside it —
see [Windows (WSL 2)](#windows-wsl-2--wsl-setupps1).

> Supports **Ubuntu and Arch Linux**; **Xilinx (xc7) only**. This script is a
> stopgap — the plan is to migrate to Nix, and to generalise beyond Xilinx. See
> [DECISIONS.md](DECISIONS.md).

## What it installs

Everything Anvil needs, at the fixed paths `anvil.py` expects:

| Path | Component |
|------|-----------|
| `~/opt/anvil` | Anvil CLI |
| `~/opt/sv2v/sv2v` | SystemVerilog → Verilog converter |
| `~/miniconda3` | Conda + the `xc7` F4PGA environment |
| `~/opt/f4pga/xc7` | F4PGA architecture definitions (Artix-7) |
| `~/f4pga-examples` | F4PGA examples (`common.mk`) |
| `~/opt/verif` | venv with cocotb + forastero (simulation) |

Plus the F4PGA carry-chain patch, and optionally the RISC-V toolchain,
openFPGALoader (board programming), and simulation tools — Verilator (built from
source) with cocotb + forastero (`--no-sim` to skip).

## Usage

```bash
git clone https://github.com/LogiSmith/toolchain-setup.git
cd toolchain-setup
./install.sh
```

The package-manager step auto-detects `pacman` vs `apt` — no flag needed to pick
between Ubuntu and Arch.

Or in one line:

```bash
curl -fsSL https://raw.githubusercontent.com/LogiSmith/toolchain-setup/main/install.sh | bash
```

On **Windows**, don't start here — start with the WSL 2 helper below, which
prepares the distro and then runs this installer inside it.

### Options

| Flag | Effect |
|------|--------|
| `--minimal` | Skip optional tools (RISC-V, openFPGALoader/board, simulation) |
| `--no-board` | Skip only openFPGALoader + udev |
| `--no-sim` | Skip simulation tools (Verilator + cocotb + forastero) |
| `--no-test` | Skip the final integration test |
| `--skip-apt` | Skip the package-manager steps (deps already present) |
| `-h`, `--help` | Show help |

The installer is **idempotent** — re-running skips anything already installed,
and is **update-aware**: it checks out the **latest published Anvil release**
(GitHub Releases, not `main`) and picks up any bumped dependency versions. So
re-running it (or `anvil update`) updates the whole toolchain, not just one part.
Dependency pins are the "lockfile" at the top of `install.sh`; Anvil itself
tracks its latest release — see [VERSIONS.md](VERSIONS.md).

## Windows (WSL 2) — `wsl-setup.ps1`

[`wsl-setup.ps1`](wsl-setup.ps1) is the Windows-side helper, not a second
installer: it prepares WSL and then calls `install.sh` inside it.

```powershell
# normal (non-admin) PowerShell, in the cloned repo
.\wsl-setup.ps1
```

It checks, in order:

1. **WSL present** — Windows build ≥ 19041 and WSL installed; otherwise it prints
   the `wsl --install` instructions (admin + reboot) and stops.
2. **WSL and kernel versions** — at least **WSL 2.7.13.0** and **kernel 6.18.33.2**
   (the versions shipping `vhci-hcd` + `ftdi_sio`); otherwise it stops and asks for
   `wsl --update`. A `kernel=`/`kernelModules=` line in `%USERPROFILE%\.wslconfig`
   is allowed but reported as a **custom (non-Microsoft) kernel** — commented-out
   lines are ignored. Also warns on low disk space and missing `usbipd-win`.
3. **Distro name** — default `anvil`; if it already exists you can reuse it or pick
   another name. Nothing is ever deleted.
4. **Create the distro** — `wsl --install --name <name> --no-launch`, then runs the
   distro's own first-run setup (`[oobe] command` from `/etc/wsl-distribution.conf`)
   directly. WSL's own prompt asks for the UNIX username and password — the script
   neither sets nor reads them — and control returns here by itself. `--no-launch`
   matters: a plain install ends by dropping you into a Linux shell, where the
   script appears to hang while it waits for you to type `exit`.
4b. **Command channel self-test** — a failsafe. Everything the script does inside
   the distro depends on `wsl --exec` passing a command through unchanged, so it
   first proves that still holds: plain arguments arrive intact, quoting and shell
   expansion survive, and exit codes come back. If a future WSL changes this, the
   script stops here — before touching anything — and tells you to pin WSL back to
   the last verified release (with the `winget` commands to do it).
5. **Default user** — must be non-root (`install.sh` refuses root). WSL's default
   user is a setting separate from the account, so a distro can hold a perfectly
   good account and still start as root: if that happens the existing uid-1000
   account is adopted (`wsl --manage --set-default-user`), and only if there is
   none does it offer to create one.
6. **Kernel modules** — the check that actually decides. Reports the *running*
   kernel (`uname -r`), which is not always the one `wsl --version` reports: a
   running VM keeps the kernel it booted with (custom, or stale from before an
   update) until every distro stops, so it warns and points at `wsl --shutdown`.
   Then loads `vhci-hcd` + `ftdi_sio` and accepts them from `lsmod` **or**
   `modules.builtin` — a kernel with the drivers built in (`=y`) never shows them
   in `lsmod`. On failure it reports whether `/lib/modules/<running kernel>` even
   exists in the distro (the usual cause with a custom kernel) and gives the fixes:
   drop the custom kernel and `wsl --shutdown`, `wsl --update`, or build a kernel
   with `CONFIG_USBIP_VHCI_HCD` + `CONFIG_USB_SERIAL_FTDI_SIO` and install its
   modules. On success it persists them in `/etc/modules-load.d`.
7. **Toolchain** — green "ready" line, 5 s pause, then `install.sh` inside the distro.

| Flag | Effect |
|------|--------|
| `-Name <name>` | Distro name (default `anvil`) |
| `-Image <image>` | Image from `wsl --list --online` (default `Ubuntu-24.04`) |
| `-Reuse` | Reuse the distro if it exists, without asking |
| `-SkipAnvil` | Prepare/verify WSL only; don't run `install.sh` |
| `-SkipDriverCheck` | Skip the `vhci-hcd`/`ftdi_sio` check (no board programming) |
| `-AllowOlder` | Accept a WSL/kernel older than the tested pins (warn instead of stop) |
| `-InstallArgs '<flags>'` | Flags passed through to `install.sh`, e.g. `'--no-test'` |

Re-running is safe: with `-Reuse` it re-checks the distro and re-runs the
(idempotent) installer.

**When Microsoft ships a new WSL.** The two version numbers are *pins* (see
[VERSIONS.md](VERSIONS.md)), recording what was tested — not a claim about what
works. A newer WSL passes them, so a normal Microsoft update changes nothing. Two
cases can still bite:

- **Microsoft drops the modules again** (this is why `bzImage-ftdi`-style custom
  kernels exist). The version check would pass, but step 6 fails and tells you to
  update or build a kernel — the module check, not the version number, is the
  authority on whether the board works.
- **Microsoft renumbers downwards** (e.g. back to a 6.6 LTS kernel, numerically
  lower than 6.18 but perfectly fine). The pin would stop you wrongly; re-run with
  `-AllowOlder` to drop it to a warning and let step 6 decide, and bump the pins
  in the script once the new set is verified.

Only `wsl --install --name`, which needs **WSL 2.4.4+**, is a hard requirement that
`-AllowOlder` cannot waive.

If the change is not in the *versions* but in **how WSL runs commands**, the step-4b
self-test catches it and prints the way back to the tested release:

```powershell
# ADMINISTRATOR PowerShell
wsl --shutdown
winget uninstall --id Microsoft.WSL --exact
winget install --id Microsoft.WSL --exact --version 2.7.13 --accept-package-agreements
winget pin add --id Microsoft.WSL --exact     # stop it updating again
wsl --version                                 # confirm 2.7.13.0
```

(`winget show --id Microsoft.WSL --exact --versions` lists what is available;
the installers are also at <https://github.com/microsoft/WSL/releases>.)

To program a board from WSL you also need [usbipd-win](https://learn.microsoft.com/windows/wsl/connect-usb)
on the Windows side (`winget install --exact dorssel.usbipd-win`), then
`usbipd attach --wsl --busid <BUSID>` once per session.

If PowerShell blocks the script (execution policy), run it as:

```powershell
powershell -ExecutionPolicy Bypass -File .\wsl-setup.ps1
```

## Updating

```bash
anvil update            # from anywhere — re-runs this installer
# or directly:
curl -fsSL https://raw.githubusercontent.com/LogiSmith/toolchain-setup/main/install.sh | bash
```

`anvil update` passes flags through, e.g. `anvil update --no-test`.

## What the integration test does

After installing, it runs `anvil doctor`, then — using the installed `anvil`
command (resolved from the alias in `~/.bashrc`) — scaffolds a `uart-hello`
project under `~/opt`, builds it end to end, verifies a bitstream was produced,
and deletes the project. Fails loudly if anything breaks. Skip with `--no-test`.

## License

Released under the [MIT License](LICENSE). © 2026 LogiSmith.
