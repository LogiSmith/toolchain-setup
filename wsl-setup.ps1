#Requires -Version 5.1
<#
.SYNOPSIS
  LogiSmith FPGA toolchain — Windows/WSL2 helper.

.DESCRIPTION
  This is NOT the toolchain installer (that is install.sh, which runs inside
  Linux). This script prepares the Windows side: it verifies WSL 2 is present,
  new enough, and has the USB/IP + FTDI kernel modules the board flow needs,
  creates a dedicated distro for the toolchain, and then hands off to install.sh
  inside it.

  Idempotent: safe to re-run. Re-running against an existing distro (-Reuse)
  just re-checks it and re-runs install.sh, which is itself idempotent.

.PARAMETER Name
  Name of the WSL distro to create/use. Default: anvil.

.PARAMETER Image
  Distro image to install from `wsl --list --online`. Default: Ubuntu-24.04.

.PARAMETER Reuse
  If the distro already exists, use it instead of asking.

.PARAMETER SkipAnvil
  Prepare/verify WSL only; do not run install.sh.

.PARAMETER SkipDriverCheck
  Skip the vhci-hcd / ftdi_sio kernel-module check (no board programming).

.PARAMETER InstallArgs
  Extra flags passed through to install.sh, e.g. '--no-test' or '--minimal'.

.EXAMPLE
  .\wsl-setup.ps1
.EXAMPLE
  .\wsl-setup.ps1 -Name anvil-dev -InstallArgs '--no-test'
#>
[CmdletBinding()]
param(
  [string]$Name = 'anvil',
  [string]$Image = 'Ubuntu-24.04',
  [switch]$Reuse,
  [switch]$SkipAnvil,
  [switch]$SkipDriverCheck,
  [switch]$AllowOlder,
  [string]$InstallArgs = '',
  [string]$InstallUrl = 'https://raw.githubusercontent.com/LogiSmith/toolchain-setup/main/install.sh'
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'

# ─── Minimum versions (see VERSIONS.md) ─────────────────────────────────────
# The FTDI + USB/IP modules (ftdi_sio, vhci-hcd) ship built-in only from these
# versions on; older WSL kernels need a hand-compiled kernel.
$MIN_WSL    = [version]'2.7.13.0'   # tested pin  -- bump when a newer set is verified
$MIN_KERNEL = [version]'6.18.33.2'  # tested pin  -- see VERSIONS.md
# Hard floor, independent of the pins above: `wsl --install --name` needs 2.4.4.
# Below this the script cannot do its job at all; above it, -AllowOlder can
# downgrade the pin check to a warning and let the step-6 module check decide.
$ABS_MIN_WSL = [version]'2.4.4'
# Same tested WSL release as $MIN_WSL, in winget's 3-part format (winget reports
# 2.7.13, `wsl --version` reports 2.7.13.0). Bump both together.
$MIN_WSL_WINGET  = '2.7.13'
$WSL_RELEASES    = 'https://github.com/microsoft/WSL/releases'
$MIN_WIN_BUILD = 19041          # WSL 2 requires Windows 10 2004 / Windows 11
$MIN_FREE_GB   = 25             # conda env + F4PGA arch defs + Verilator build

$DOC_USB    = 'https://learn.microsoft.com/windows/wsl/connect-usb'
$DOC_KERNEL = 'https://learn.microsoft.com/windows/wsl/use-custom-kernel'
$DOC_WSL    = 'https://learn.microsoft.com/windows/wsl/install'

# ─── Logging (mirrors install.sh) ───────────────────────────────────────────
function Step($m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host '  [ok] '   -ForegroundColor Green  -NoNewline; Write-Host $m }
function Skip($m) { Write-Host '  [skip] ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Warn($m) { Write-Host '  [warn] ' -ForegroundColor Yellow -NoNewline; Write-Host $m }
function Info($m) { Write-Host "  $m" }
function Die($m) {
  Write-Host ''
  Write-Host '[ERROR] ' -ForegroundColor Red -NoNewline
  Write-Host $m -ForegroundColor Red
  exit 1
}

# Run wsl.exe and capture stdout. stderr stays on the console so real WSL errors
# are visible; callers check $script:WslExit.
#
# Two rules for everything passed to a distro, both learned the hard way:
#   1. Use --exec, never --. Plain `wsl -d X -- cmd` runs cmd through the distro's
#      default shell first, which expands $vars it does not know (to nothing) and
#      eats quoting before the real command ever sees it. --exec runs the binary
#      directly. Symptom without it: `bash -lc 'echo $BASH_VERSION'` reaches bash
#      already expanded, as a syntax error.
#   2. No double quotes inside a command string: Windows PowerShell 5.1 does not
#      escape them when building the native command line, so the argument gets
#      split at the quote. Use single quotes in the shell snippet.
#   3. --exec resolves a bare program name against /usr/bin but NOT /usr/sbin, so
#      anything living there (modprobe, adduser, usermod) must go through
#      `bash -lc` or an absolute path. It fails as
#      `execvpe(modprobe) failed: No such file or directory`, which reads like a
#      missing package rather than a lookup problem. (lsmod happens to work only
#      because /usr/bin/lsmod exists as a symlink and /usr/bin/modprobe does not.)
$script:WslExit = 0
function Wsl([string[]]$Arguments) {
  $out = & wsl.exe @Arguments
  $script:WslExit = $LASTEXITCODE
  return ($out | Out-String)
}

# Failsafe: prove the command channel still behaves before trusting it with real
# work. Everything this script does inside a distro rides on `wsl --exec` passing
# a command through unchanged; if a future WSL changes that, commands would be
# silently half-executed instead of failing. These three canaries catch it.
function Get-WslChannelProblem([string]$distro) {
  $problems = @()

  # 1. plain argv reaches the binary intact
  $r = Wsl @('-d', $distro, '--exec', 'echo', 'CANARY-ARGV-OK')
  if ($r -notmatch 'CANARY-ARGV-OK') {
    $problems += "argument passing -- expected CANARY-ARGV-OK, got: $(($r -replace '\s+', ' ').Trim())"
  }

  # 2. quoting + shell expansion survive. This is exactly what `wsl -- cmd`
  #    (without --exec) breaks: an extra shell expands $v away before bash sees it,
  #    turning CANARY-42-END into CANARY--END.
  $r = Wsl @('-d', $distro, '--exec', 'bash', '-c', 'v=42; echo CANARY-$v-END')
  if ($r -notmatch 'CANARY-42-END') {
    $problems += "shell quoting/expansion -- expected CANARY-42-END, got: $(($r -replace '\s+', ' ').Trim())"
  }

  # 3. exit codes come back, or every success/failure test below is meaningless
  Wsl @('-d', $distro, '--exec', 'bash', '-c', 'exit 7') | Out-Null
  if ($script:WslExit -ne 7) {
    $problems += "exit-code propagation -- expected 7, got: $script:WslExit"
  }

  return $problems
}

# WSL's default user is separate from the account itself: the first-run setup
# creates the user, but switching the default is its own step -- so a distro can
# have a perfectly good account and still start as root.
function Set-DefaultUser([string]$distro, [string]$user) {
  & wsl.exe --manage $distro --set-default-user $user | Out-Null
  if ($LASTEXITCODE -ne 0) {
    # Fallback for WSL builds without --manage: /etc/wsl.conf, read at boot.
    $conf = "printf '[user]\ndefault=$user\n' >> /etc/wsl.conf"
    & wsl.exe -d $distro -u root --exec bash -c $conf | Out-Null
  }
  & wsl.exe --terminate $distro | Out-Null      # the default is applied at boot
  return (Wsl \n('-d', $distro, '--exec', 'whoami')).Trim()
}

# A distro declares its own first-run setup (create user + password) in
# /etc/wsl-distribution.conf. Running that directly beats launching the distro:
# a launch drops the user into a Linux shell afterwards, leaving this script
# waiting, invisibly, for them to type 'exit'.
function Get-OobeCommand([string]$distro) {
  $conf = Wsl @('-d', $distro, '--exec', 'cat', '/etc/wsl-distribution.conf')
  if ($script:WslExit -ne 0) { return $null }
  $inOobe = $false
  foreach ($line in ($conf -split "`r?`n")) {
    $t = $line.Trim()
    if ($t -match '^\[(.+)\]$') { $inOobe = ($matches[1] -ieq 'oobe'); continue }
    if ($inOobe -and $t -match '^command\s*=\s*(\S.*)$') { return $matches[1].Trim() }
  }
  return $null
}

# Pull the first dotted version out of a string ("6.18.33.2-2" -> 6.18.33.2).
function Get-Ver([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $m = [regex]::Match($text, '\d+(\.\d+){1,3}')
  if (-not $m.Success) { return $null }
  try { return [version]$m.Value } catch { return $null }
}

Write-Host ''
Write-Host 'LogiSmith FPGA toolchain — WSL 2 helper (Windows side)' -ForegroundColor White
Write-Host 'Prepares WSL, then runs install.sh inside it.'

# ─── 1. Is WSL 2 there at all? ──────────────────────────────────────────────
Step '1. WSL present'

$winBuild = [System.Environment]::OSVersion.Version.Build
if ($winBuild -lt $MIN_WIN_BUILD) {
  Die @"
Windows build $winBuild is too old for WSL 2 (need $MIN_WIN_BUILD+, i.e. Windows 10 2004 or Windows 11).
Update Windows first: $DOC_WSL
"@
}
Ok "Windows build $winBuild"

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
  Die @"
WSL is not installed on this machine.

Install WSL 2 from an ADMINISTRATOR PowerShell, then reboot:

    wsl --install

That enables the 'Virtual Machine Platform' + 'Windows Subsystem for Linux'
features and installs the WSL 2 kernel. Hardware virtualization (VT-x / AMD-V)
must be enabled in the BIOS/UEFI.
Docs: $DOC_WSL

Re-run this script after the reboot.
"@
}

$verText = Wsl @('--version')
if ($script:WslExit -ne 0 -or [string]::IsNullOrWhiteSpace($verText)) {
  Die @"
'wsl --version' failed — wsl.exe exists but WSL itself is not installed or is the
old inbox version that cannot report a version.

From an ADMINISTRATOR PowerShell:

    wsl --install          # first-time install (reboot afterwards)
    wsl --update           # if WSL is installed but outdated

Also confirm virtualization is enabled in BIOS/UEFI and that the 'Virtual Machine
Platform' Windows feature is on.
Docs: $DOC_WSL
"@
}
Ok 'WSL is installed'

# ─── 2. Versions: WSL + kernel ──────────────────────────────────────────────
Step '2. WSL and kernel versions'

# `wsl --version` labels are localized, so match keywords first and fall back to
# line order (line 0 = WSL version, line 1 = kernel version).
$verLines = @($verText -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
$wslLine    = $verLines | Where-Object { $_ -match '(?i)wsl' -and $_ -notmatch '(?i)wslg' } | Select-Object -First 1
$kernelLine = $verLines | Where-Object { $_ -match '(?i)kernel' } | Select-Object -First 1
if (-not $wslLine    -and $verLines.Count -ge 1) { $wslLine    = $verLines[0] }
if (-not $kernelLine -and $verLines.Count -ge 2) { $kernelLine = $verLines[1] }

$wslVer    = Get-Ver $wslLine
$kernelVer = Get-Ver $kernelLine

if (-not $wslVer)    { Die "Could not parse the WSL version from:`n$verText" }
if (-not $kernelVer) { Die "Could not parse the WSL kernel version from:`n$verText" }

if ($wslVer -lt $ABS_MIN_WSL) {
  Die @"
WSL $wslVer is too old to use at all (need $ABS_MIN_WSL+ for 'wsl --install --name').

From an ADMINISTRATOR PowerShell:

    wsl --update
    wsl --shutdown

then re-run this script.
"@
}

$needUpdate = @()
if ($wslVer    -lt $MIN_WSL)    { $needUpdate += "WSL $wslVer (tested: $MIN_WSL)" }
if ($kernelVer -lt $MIN_KERNEL) { $needUpdate += "kernel $kernelVer (tested: $MIN_KERNEL)" }

if ($needUpdate.Count -gt 0 -and -not $AllowOlder) {
  Die @"
WSL is older than the tested set: $($needUpdate -join ' / ')

A WSL update is required — the FPGA board flow needs a kernel that ships the
USB/IP and FTDI modules (vhci-hcd, ftdi_sio). Run from an ADMINISTRATOR PowerShell:

    wsl --update
    wsl --shutdown

then re-run this script. If 'wsl --update' says WSL is managed by the Microsoft
Store, update it there (or: winget upgrade --id Microsoft.WSL).

These two numbers are pins, not laws (VERSIONS.md): they record what was tested,
so they go stale as Microsoft ships new releases. If you believe your WSL is fine
(e.g. Microsoft moved back to an LTS kernel with a lower number), re-run with
-AllowOlder: the check drops to a warning and the module check in step 6 — which
is what actually decides whether the board works — gets the final say.
"@
}
if ($needUpdate.Count -gt 0) {
  Warn "older than the tested set: $($needUpdate -join ' / ') — continuing (-AllowOlder)"
  Info '  step 6 (kernel modules) decides whether the board flow actually works'
} else {
  Ok "WSL $wslVer (tested $MIN_WSL)"
  Ok "kernel $kernelVer (tested $MIN_KERNEL)"
}

# ─── 2b. Custom kernel in .wslconfig (allowed, but worth flagging) ──────────
$wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
$customKernel = $false
if (Test-Path -LiteralPath $wslConfig) {
  # Only uncommented settings count — a commented-out kernel= line is inert.
  $active = Get-Content -LiteralPath $wslConfig |
            Where-Object { $_ -notmatch '^\s*[#;]' }
  foreach ($line in $active) {
    if ($line -match '^\s*(kernel|kernelModules)\s*=\s*(\S.*)$') {
      $customKernel = $true
      Warn "detected custom (non-Microsoft) kernel setting in $($wslConfig): $($line.Trim())"
    }
  }
  if (-not $customKernel) { Ok ".wslconfig present, no custom kernel configured" }
} else {
  Ok 'no .wslconfig (stock Microsoft kernel)'
}
if ($customKernel) {
  Info 'A custom kernel is fine as long as it has vhci-hcd + ftdi_sio built in;'
  Info "the module check below is what actually decides. Docs: $DOC_KERNEL"
}

# ─── 2c. Host-side sanity (not fatal) ───────────────────────────────────────
try {
  $sysDrive = ($env:SystemDrive)
  $freeGb = [math]::Round((Get-PSDrive -Name $sysDrive.TrimEnd(':')).Free / 1GB, 1)
  if ($freeGb -lt $MIN_FREE_GB) {
    Warn "only ${freeGb} GB free on $sysDrive — the toolchain (conda + F4PGA arch defs + Verilator) needs roughly ${MIN_FREE_GB} GB"
  } else {
    Ok "${freeGb} GB free on $sysDrive"
  }
} catch { Warn 'could not determine free disk space' }

if (-not (Get-Command usbipd.exe -ErrorAction SilentlyContinue)) {
  Warn 'usbipd-win not found — required to attach the FPGA board (USB) to WSL'
  Info '  install:  winget install --exact dorssel.usbipd-win'
  Info "  usage:    usbipd list / usbipd attach --wsl --busid <BUSID>   ($DOC_USB)"
} else {
  Ok 'usbipd-win present (USB passthrough to WSL)'
}

# WSL 1 distros cannot run this toolchain; make 2 the default for new installs.
try { & wsl.exe --set-default-version 2 | Out-Null } catch { }

# ─── 3. Pick a distro name ──────────────────────────────────────────────────
Step '3. Distro name'

function Get-Distros {
  $raw = Wsl @('--list', '--quiet')
  if ($script:WslExit -ne 0) { return @() }
  return @($raw -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

$existing = Get-Distros
$createNew = $true

while ($true) {
  if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
    Warn "invalid distro name '$Name' — use letters, digits, dot, dash or underscore only"
    $Name = Read-Host '  New distro name'
    continue
  }
  $hit = $existing | Where-Object { $_ -ieq $Name }
  if (-not $hit) { Ok "'$Name' is free"; break }

  if ($Reuse) { Skip "distro '$Name' already exists — reusing it (-Reuse)"; $createNew = $false; break }

  Warn "a WSL distro named '$Name' already exists"
  Info '  [R] reuse it (re-check + re-run install.sh — safe, nothing is deleted)'
  Info '  [N] pick a different name and create a new one'
  Info '  [Q] quit'
  $choice = (Read-Host '  Choice [R/N/Q]').Trim().ToUpperInvariant()
  if ($choice -eq 'R') { $createNew = $false; break }
  elseif ($choice -eq 'N') { $Name = (Read-Host '  New distro name').Trim(); continue }
  elseif ($choice -eq 'Q') { Write-Host 'Aborted.'; exit 0 }
  else { Info 'Please answer R, N or Q.'; continue }
}

# ─── 4. Create the distro ───────────────────────────────────────────────────
Step "4. WSL distro '$Name'"

if ($createNew) {
  $online = Wsl @('--list', '--online')
  if ($script:WslExit -eq 0 -and $online -notmatch [regex]::Escape($Image)) {
    Warn "'$Image' is not in 'wsl --list --online'; falling back to 'Ubuntu'"
    $Image = 'Ubuntu'
  }
  Info "creating '$Name' from image '$Image' (this downloads a few hundred MB) ..."
  # --no-launch: register the distro without entering it. A plain install runs the
  # first-run setup and then leaves you at a Linux prompt, with this script waiting
  # for an 'exit' whose instructions have long scrolled off screen.
  $launched = $false
  & wsl.exe --install --distribution $Image --name $Name --no-launch
  if ($LASTEXITCODE -ne 0) {
    Warn "'--no-launch' was rejected (exit $LASTEXITCODE) — installing the normal way"
    Write-Host ''
    Write-Host '  >>> A Linux shell will open. Create your user, then type: exit  <<<' -ForegroundColor Yellow
    Write-Host ''
    & wsl.exe --install --distribution $Image --name $Name
    if ($LASTEXITCODE -ne 0) {
      Die "'wsl --install --distribution $Image --name $Name' failed (exit $LASTEXITCODE).
    If WSL reports that --name is unknown, run 'wsl --update' and try again."
    }
    $launched = $true
  }

  $existing = Get-Distros
  if (-not ($existing | Where-Object { $_ -ieq $Name })) {
    Die "distro '$Name' does not appear in 'wsl --list' after install — creation did not complete."
  }
  Ok "created '$Name'"

  if (-not $launched) {
    $oobe = Get-OobeCommand $Name
    if ($oobe) {
      Write-Host ''
      Write-Host '  Now create your Linux user account.' -ForegroundColor Yellow
      Write-Host '  WSL asks for the username and password itself; this script neither sets' -ForegroundColor Yellow
      Write-Host '  nor reads them. It continues on its own when you are done.' -ForegroundColor Yellow
      Write-Host ''
      $argv = @('-d', $Name, '--exec') + ($oobe -split '\s+')
      & wsl.exe @argv
      if ($LASTEXITCODE -ne 0) {
        Warn "first-run setup exited with $LASTEXITCODE — step 5 will check the user"
      }
      # Running the OOBE ourselves creates the account but leaves WSL defaulting to
      # root (a plain `wsl --install` launch does this part for us).
      $firstUser = (Wsl @('-d', $Name, '--exec', 'id', '-nu', '1000')).Trim()
      if ($script:WslExit -eq 0 -and $firstUser -and $firstUser -ne 'root') {
        if ((Set-DefaultUser $Name $firstUser) -eq $firstUser) { Ok "default user set to '$firstUser'" }
        else { Warn "could not make '$firstUser' the default user — step 5 will retry" }
      }
    } else {
      Warn 'distro declares no first-run setup — step 5 will create the user instead'
    }
  }
} else {
  Skip "using existing distro '$Name'"
}

# The distro must be WSL 2 — WSL 1 has no real kernel, so no USB/IP at all.
$verbose = Wsl @('--list', '--verbose')
$distroVersion = $null
foreach ($line in ($verbose -split "`r?`n")) {
  if ($line -match '^\s*\*?\s*(\S+)\s+(\S+)\s+(\d+)\s*$' -and $matches[1] -ieq $Name) {
    $distroVersion = [int]$matches[3]
  }
}
if ($distroVersion -eq 1) {
  Die "distro '$Name' is WSL 1. Convert it:  wsl --set-version $Name 2"
} elseif ($distroVersion -eq 2) {
  Ok "'$Name' is WSL 2"
} else {
  Warn "could not confirm the WSL version of '$Name' — continuing"
}

# ─── 4b. Command channel self-test (failsafe) ───────────────────────────────
Step '4b. Command channel self-test'
$chan = Get-WslChannelProblem $Name
if ($chan.Count -gt 0) {
  Die @"
wsl.exe no longer passes commands into the distro the way this script expects:

$($chan | ForEach-Object { "  - $_" } | Out-String)
Every later step (kernel-module checks, running install.sh) rides on that channel,
so the script stops here instead of half-executing commands inside your system.

The likely cause is a newer WSL changing its command/argument handling. You are on
WSL $wslVer; the last release this script was verified against is $MIN_WSL
(kernel $MIN_KERNEL) -- see VERSIONS.md.

Go back to that tested release, from an ADMINISTRATOR PowerShell:

    wsl --shutdown
    winget uninstall --id Microsoft.WSL --exact
    winget install --id Microsoft.WSL --exact --version $MIN_WSL_WINGET --accept-package-agreements
    winget pin add --id Microsoft.WSL --exact
    wsl --version                       # confirm it now reports $MIN_WSL

'winget pin add' stops Windows from silently updating it again; undo it later with
'winget pin remove --id Microsoft.WSL --exact'. To see what winget offers:
'winget show --id Microsoft.WSL --exact --versions'. If the version is not there,
download that release's installer from
    $WSL_RELEASES
run it, then 'wsl --shutdown'.

Then re-run this script.

Fixing it forward instead: the calling convention is 'wsl --exec' plus
single-quoted command strings (DECISIONS.md, ADR 0003). Once the script is adapted
and verified, bump MIN_WSL / MIN_WSL_WINGET at the top and add a row to VERSIONS.md.
"@
}
Ok 'command channel behaves as expected (argv, quoting, exit codes)'

# ─── 5. A non-root default user (install.sh refuses to run as root) ─────────
Step '5. Default user'

$whoami = (Wsl @('-d', $Name, '--exec', 'whoami')).Trim()
if ($script:WslExit -ne 0 -or $whoami -eq '') {
  Die "could not start '$Name' (wsl -d $Name --exec whoami failed)."
}
if ($whoami -eq 'root') {
  # An account may already exist while WSL still starts as root; adopt it rather
  # than asking for a second, pointless user.
  $firstUser = (Wsl @('-d', $Name, '--exec', 'id', '-nu', '1000')).Trim()
  if ($script:WslExit -eq 0 -and $firstUser -and $firstUser -ne 'root') {
    Info "account '$firstUser' (uid 1000) exists but WSL starts as root -- making it the default"
    $whoami = Set-DefaultUser $Name $firstUser
  }
}
if ($whoami -eq 'root') {
  Warn "the default user of '$Name' is root -- install.sh refuses to run as root"
  $newUser = (Read-Host '  Create a normal sudo user now? Enter a username (or blank to abort)').Trim()
  if ($newUser -eq '') {
    Die @"
Create a user inside the distro, then re-run this script. Enter it as root:

    wsl -d $Name -u root

and there, in the Linux shell (no quoting games -- you are inside Linux now):

    adduser <username>
    usermod -aG sudo <username>
    exit

then back in PowerShell:  wsl --manage $Name --set-default-user <username>
"@
  }
  if ($newUser -notmatch '^[a-z_][a-z0-9_-]*$') { Die "invalid UNIX username: $newUser" }
  Info "  creating '$newUser' (you will be asked for its password) ..."
  # bash -lc, not --exec adduser: adduser lives in /usr/sbin, which --exec does
  # not search (see the rules above Wsl()).
  & wsl.exe -d $Name -u root --exec bash -lc "adduser $newUser"
  if ($LASTEXITCODE -ne 0) { Die "adduser failed for '$newUser'" }
  & wsl.exe -d $Name -u root --exec bash -lc "usermod -aG sudo $newUser"
  if ($LASTEXITCODE -ne 0) { Die "could not add '$newUser' to the sudo group" }
  $whoami = Set-DefaultUser $Name $newUser
  if ($whoami -ne $newUser) { Die "default user is still '$whoami' after setting it to '$newUser'" }
  Ok "default user is now '$whoami'"
} else {
  Ok "default user is '$whoami' (non-root)"
}

# ─── 6. Kernel modules for board programming ────────────────────────────────
Step '6. USB/IP + FTDI kernel modules'

if ($SkipDriverCheck) {
  Skip 'module check (-SkipDriverCheck)'
} else {
  # uname -r is the REAL running kernel. `wsl --version` only reports the kernel
  # WSL *ships*: a running VM keeps whatever kernel it booted with (a custom one
  # from .wslconfig, or a stale one from before an update) until every distro
  # stops, so the two can disagree and only this one decides what the board sees.
  $uname = (Wsl @('-d', $Name, '--exec', 'uname', '-r')).Trim()
  Info "running kernel: $uname"
  $runningVer = Get-Ver $uname
  # A trailing '+' means locally built from a git tree; a stock kernel has none.
  if ($uname -match '\+$' -or $uname -notmatch '(?i)microsoft') {
    Warn 'running kernel is a custom build (locally compiled, not a stock Microsoft kernel)'
  }
  $stale = ($runningVer -and $kernelVer -and $runningVer -ne $kernelVer)
  if ($stale) {
    Warn "running kernel $runningVer is NOT the kernel WSL ships ($kernelVer)"
    Info "  the WSL VM keeps its kernel until every distro stops:  wsl --shutdown"
    Info "  if that was not intended, remove the kernel= line from $wslConfig first"
  }
  if ($runningVer -and $runningVer -lt $MIN_KERNEL) {
    Warn "running kernel $runningVer is older than the tested $MIN_KERNEL"
  }

  # Check before acting: if the modules are already there, nothing needs loading
  # and the user is not asked for a password for no reason.
  $lsmod = Wsl @('-d', $Name, '--exec', 'lsmod')
  # A kernel may have the drivers built IN (=y) rather than as modules (=m): then
  # modprobe succeeds silently and lsmod never lists them. Check both, or a
  # perfectly good custom kernel gets reported as broken.
  $builtin = Wsl @('-d', $Name, '--exec', 'bash', '-c', "cat /lib/modules/$uname/modules.builtin 2>/dev/null")

  $haveVhci = ($lsmod -match '(?m)^vhci_hcd\s') -or ($builtin -match 'vhci[-_]hcd\.ko')
  $haveFtdi = ($lsmod -match '(?m)^ftdi_sio\s') -or ($builtin -match 'ftdi_sio\.ko')

  if ($haveVhci -and $haveFtdi) {
    Skip 'already loaded -- no modprobe needed'
  } else {
    # -u root, not sudo: WSL grants root without a Linux password, so the helper
    # stays non-interactive instead of stopping at a prompt.
    Info 'loading vhci-hcd + ftdi_sio ...'
    foreach ($m in 'vhci-hcd', 'ftdi_sio') {
      & wsl.exe -d $Name -u root --exec bash -lc "modprobe $m"
    }
    $lsmod = Wsl @('-d', $Name, '--exec', 'lsmod')
    $haveVhci = ($lsmod -match '(?m)^vhci_hcd\s') -or ($builtin -match 'vhci[-_]hcd\.ko')
    $haveFtdi = ($lsmod -match '(?m)^ftdi_sio\s') -or ($builtin -match 'ftdi_sio\.ko')
  }

  if (-not ($haveVhci -and $haveFtdi)) {
    $missing = @()
    if (-not $haveVhci) { $missing += 'vhci-hcd (USB/IP)' }
    if (-not $haveFtdi) { $missing += 'ftdi_sio (FTDI serial)' }

    # The usual cause of a load failure on a custom kernel: the distro has no
    # /lib/modules tree for the kernel that is actually running.
    Wsl @('-d', $Name, '--exec', 'test', '-d', "/lib/modules/$uname") | Out-Null
    $modDir = if ($script:WslExit -eq 0) { "present" } else { "MISSING" }

    $kernelNote = ''
    if ($stale -or $modDir -eq 'MISSING') {
      $kernelNote = @"

  0. Most likely here: '$Name' is running kernel $uname, and
     /lib/modules/$uname in that distro is $modDir.
     A custom kernel only works where its modules are installed. Either drop the
     custom kernel and reboot the VM:
         (remove the kernel= line from $wslConfig)
         wsl --shutdown
     or install the matching modules inside '$Name' (make modules_install from
     the kernel tree you built).
"@
    }

    Die @"
Required kernel modules not found in '$Name': $($missing -join ', ')

Without them the board cannot be attached to WSL (no usbipd passthrough, no
/dev/ttyUSB*), so programming and the UART console will not work.
$kernelNote
Other fixes:

  1. Update WSL to a stable version that ships these modules (recommended) —
     from an ADMINISTRATOR PowerShell:
         wsl --update
         wsl --shutdown
     then re-run this script.

  2. Build a custom WSL kernel with CONFIG_USBIP_VHCI_HCD and CONFIG_USB_SERIAL_FTDI_SIO
     enabled, install its modules into the distro, and point .wslconfig at it:
         $DOC_KERNEL
         https://github.com/microsoft/WSL2-Linux-Kernel

  USB passthrough setup (usbipd-win): $DOC_USB
"@
  }
  Ok 'vhci_hcd and ftdi_sio loaded'

  # Make them load on every boot, so the board works without a manual modprobe.
  $persist = "printf 'vhci-hcd\nftdi_sio\n' > /etc/modules-load.d/anvil-usbip.conf"
  & wsl.exe -d $Name -u root --exec bash -c $persist
  if ($LASTEXITCODE -eq 0) { Ok 'modules set to load at boot (/etc/modules-load.d/anvil-usbip.conf)' }
  else { Warn 'could not persist the module list — run modprobe manually after each WSL restart' }
}

# ─── 7. Hand off to install.sh ──────────────────────────────────────────────
Write-Host ''
Write-Host "WSL distro '$Name' is ready." -ForegroundColor Green -NoNewline
Write-Host " (user: $whoami, kernel: $kernelVer)" -ForegroundColor Green

if ($SkipAnvil) {
  Write-Host ''
  Skip 'Anvil toolchain install (-SkipAnvil)'
  Info "Run it yourself: enter the distro with 'wsl -d $Name', then inside it:"
  Info "    curl -fsSL $InstallUrl | bash"
  exit 0
}

for ($i = 5; $i -ge 1; $i--) {
  Write-Host "  starting the Anvil toolchain install in $i ..." -ForegroundColor Green
  Start-Sleep -Seconds 1
}

Step "7. Anvil toolchain install (inside '$Name')"
Info 'This takes a while (conda env, F4PGA arch defs, Verilator build).'
Info 'sudo inside WSL will ask for the password you just created.'
Write-Host ''

# Download first, then run from a file: with `curl | bash` the script's stdin is
# the pipe, which makes interactive prompts inside install.sh fragile. Same
# script, safer plumbing.
$tmp = '/tmp/anvil-install.sh'
$fetch = "curl -fsSL $InstallUrl -o $tmp && chmod +x $tmp"
& wsl.exe -d $Name --exec bash -lc $fetch
if ($LASTEXITCODE -ne 0) { Die "could not download install.sh inside '$Name' (network? proxy?)" }

$run = "bash $tmp $InstallArgs"
& wsl.exe -d $Name --exec bash -lc $run
$installRc = $LASTEXITCODE
& wsl.exe -d $Name --exec rm -f $tmp | Out-Null

Write-Host ''
if ($installRc -ne 0) {
  Die "install.sh failed inside '$Name' (exit $installRc). It is idempotent -- fix the
reported issue and re-run this script, or enter the distro ('wsl -d $Name') and run:
    curl -fsSL $InstallUrl | bash"
}

Write-Host "OK — toolchain installed in WSL distro '$Name'." -ForegroundColor Green
Write-Host ''
Info "Enter it with:            wsl -d $Name"
Info "Make it your default:     wsl --set-default $Name"
Info "Attach the board first:   usbipd list  ->  usbipd attach --wsl --busid <BUSID>"
Info "Then, inside WSL:         anvil doctor"
