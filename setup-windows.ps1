<#
.SYNOPSIS
    Install and configure ingine (Inkling-2-Mini abliterated) on Windows via WSL2.

.DESCRIPTION
    Checks Windows RTX 5090 / driver / WSL2 (>= 2.7.0) prerequisites, clones upstream ingine into
    WSL2's native Linux filesystem (avoiding /mnt/c slowness and CRLF issues), runs the upstream
    Linux installer inside WSL2, and installs a Windows `ingine` CLI shim on your PATH so you can
    run `ingine start|stop|status|logs|serve|update` directly from PowerShell or CMD.

.PARAMETER Distro
    WSL2 distribution name (defaults to your default WSL2 distro).

.PARAMETER InstallDir
    Linux path inside WSL2 for the ingine install (default: $HOME/inkling-2-mini-abliterated-ingine).
    Must be on the WSL2 Linux filesystem, not /mnt/c.

.PARAMETER RepoUrl
    Git repository cloned inside WSL2 (default: upstream satellitedown/inkling-2-mini-abliterated-ingine
    so `ingine update` pulls engine and model updates directly).

.PARAMETER ShimDir
    Windows directory where `ingine.cmd` and `ingine.ps1` are installed (default: %LOCALAPPDATA%\ingine\bin).

.PARAMETER CheckOnly
    Run prerequisite checks only without installing or modifying anything.

.PARAMETER ShimOnly
    Only install/refresh the Windows `ingine` CLI shim and config (skip WSL2 install).

.PARAMETER NoPathUpdate
    Do not add ShimDir to the current user's Windows PATH.
#>
[CmdletBinding()]
param(
    [string]$Distro = "",
    [string]$InstallDir = "",
    [string]$RepoUrl = "https://github.com/satellitedown/inkling-2-mini-abliterated-ingine.git",
    [string]$ShimDir = (Join-Path $env:LOCALAPPDATA "ingine\bin"),
    [switch]$CheckOnly,
    [switch]$ShimOnly,
    [switch]$NoPathUpdate
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Warn([string]$Message) {
    Write-Host "Warning: $Message" -ForegroundColor Yellow
}

function Fail([string]$Message) {
    Write-Host "Error: $Message" -ForegroundColor Red
    exit 1
}

function Strip-Nulls([object[]]$Lines) {
    return @($Lines | ForEach-Object { ("$_" -replace "`0", "").Trim() } | Where-Object { $_ -ne "" })
}

function Escape-BashSingle([string]$Value) {
    # PowerShell 5.1 strips double quotes when invoking native binaries, so never emit '"' here.
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-NativeCapture([scriptblock]$Block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & $Block 2>&1
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = (Strip-Nulls $out)
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-WslBash([string]$DistroName, [string]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & wsl.exe -d $DistroName -- bash -lc $Command
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Invoke-WslBashCapture([string]$DistroName, [string]$Command) {
    return Invoke-NativeCapture { & wsl.exe -d $DistroName -- bash -lc $Command }
}

# ---- 1. Host OS & GPU checks -----------------------------------------------------------------------
Write-Step "Checking Windows host, GPU, and WSL2 prerequisites"

if (-not [Environment]::Is64BitOperatingSystem) {
    Fail "Windows x64 is required."
}

$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if (-not $nvidiaSmi) {
    Fail "nvidia-smi not found. Install the Windows NVIDIA Game Ready or Studio driver (580+ for CUDA 13) first."
}

$gpuRes = Invoke-NativeCapture { & nvidia-smi --query-gpu=index,name,compute_cap,memory.used,memory.free,memory.total,driver_version --format=csv,noheader,nounits }
if ($gpuRes.ExitCode -ne 0 -or $gpuRes.Output.Count -eq 0) {
    Fail ("nvidia-smi failed: " + ($gpuRes.Output -join "`n"))
}

$found5090 = $false
$driverMajor = 0
$freeMib = 0
$totalMib = 0

foreach ($line in $gpuRes.Output) {
    $parts = ($line -split ",") | ForEach-Object { $_.Trim() }
    if ($parts.Count -lt 7) { continue }
    Write-Host ("  GPU {0}: {1} (CC {2}, {3}/{5} MiB used, {4} MiB free, driver {6})" -f $parts[0], $parts[1], $parts[2], $parts[3], $parts[4], $parts[5], $parts[6])
    $drv = [int](($parts[6] -split "\.")[0])
    if ($drv -gt $driverMajor) { $driverMajor = $drv }
    if ($parts[2] -eq "12.0" -and [int]$parts[5] -ge 31744) {
        $found5090 = $true
        $freeMib = [int]$parts[4]
        $totalMib = [int]$parts[5]
    }
}

if ($driverMajor -lt 580) {
    Fail "NVIDIA driver major version $driverMajor is too old. ingine builds with CUDA 13 and requires driver 580 or newer."
}
if (-not $found5090) {
    Write-Warn "No 32 GB compute-capability 12.0 GPU (RTX 5090 class) detected. ingine kernels target sm_120a only and will not run on older architectures."
} elseif ($freeMib -lt 25600) {
    Write-Warn ("Only {0:N1} GiB of {1:N1} GiB VRAM is currently free on Windows. Default 262K context needs ~24.4 GiB; close heavy GPU apps or set INGINE_CTX=131072 / --no-vision in ~/.config/ingine/env." -f ($freeMib / 1024.0), ($totalMib / 1024.0))
}

# ---- 2. WSL2 version & distro checks ---------------------------------------------------------------
$wslCmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
if (-not $wslCmd) {
    Fail "WSL2 is not installed. Run 'wsl --install -d Ubuntu-24.04' in an Administrator PowerShell, reboot, then rerun this script."
}

$wslVerRes = Invoke-NativeCapture { & wsl.exe --version }
$wslVerLine = $wslVerRes.Output | Where-Object { $_ -match "WSL\s+version:\s*([0-9]+\.[0-9]+\.[0-9]+)" } | Select-Object -First 1
if ($wslVerLine -match "([0-9]+\.[0-9]+\.[0-9]+)") {
    $wslVer = [Version]$Matches[1]
    Write-Host "  WSL version: $wslVer"
    if ($wslVer -lt [Version]"2.7.0") {
        Write-Warn "WSL $wslVer is older than 2.7.0. Blackwell (RTX 5090) CUDA Graph capture requires WSL 2.7.0+. Run 'wsl --update' and 'wsl --shutdown' before installing."
    }
} else {
    Write-Warn "Could not parse 'wsl --version'. Ensure WSL is updated to 2.7.0+ ('wsl --update') for RTX 5090 CUDA Graph support."
}

$distroRes = Invoke-NativeCapture { & wsl.exe -l -v }
$distros = @()
foreach ($line in $distroRes.Output) {
    if ($line -match "^NAME\s+STATE\s+VERSION") { continue }
    $isDefault = $line.StartsWith("*")
    $clean = ($line -replace "^\*\s*", "").Trim()
    if ($clean -match "^(.+?)\s+(Running|Stopped|Installing|Converting)\s+(\d+)$") {
        $distros += [PSCustomObject]@{
            Name      = $Matches[1].Trim()
            State     = $Matches[2].Trim()
            Version   = [int]$Matches[3]
            IsDefault = $isDefault
        }
    }
}

$wsl2Distros = @($distros | Where-Object { $_.Version -eq 2 -and $_.Name -notmatch "^docker-desktop" })
if ($wsl2Distros.Count -eq 0) {
    Fail "No Linux WSL2 distribution found. Run 'wsl --install -d Ubuntu-24.04', complete initial user setup, then rerun this script."
}

if ($Distro -ne "") {
    $selected = $wsl2Distros | Where-Object { $_.Name -eq $Distro } | Select-Object -First 1
    if (-not $selected) {
        $avail = ($wsl2Distros | ForEach-Object { $_.Name }) -join ", "
        Fail "WSL2 distro '$Distro' not found (or not WSL version 2). Available WSL2 distros: $avail"
    }
} else {
    $selected = $wsl2Distros | Where-Object { $_.IsDefault } | Select-Object -First 1
    if (-not $selected) {
        $selected = $wsl2Distros | Where-Object { $_.Name -match "Ubuntu" } | Select-Object -First 1
    }
    if (-not $selected) {
        $selected = $wsl2Distros[0]
    }
    $Distro = $selected.Name
}
Write-Host "  WSL2 distro: $Distro"

# Verify GPU passthrough & native Linux home inside WSL2 (avoid quotes for PS 5.1 compatibility)
$wslProbe = Invoke-WslBashCapture $Distro 'echo HOME=$HOME && nvidia-smi --query-gpu=name,compute_cap,memory.total,driver_version --format=csv,noheader,nounits && df -BG --output=avail $HOME | tail -n 1'
if ($wslProbe.ExitCode -ne 0) {
    Fail ("WSL2 GPU probe failed in '{0}'. Output:`n{1}" -f $Distro, ($wslProbe.Output -join "`n"))
}

$wslHome = ""
foreach ($l in $wslProbe.Output) {
    if ($l -match "^HOME=(.+)$") { $wslHome = $Matches[1].Trim() }
}
if (-not $wslHome) {
    Fail "Could not determine Linux HOME inside WSL2 distro '$Distro'."
}
if ($InstallDir -eq "") {
    $InstallDir = "$wslHome/inkling-2-mini-abliterated-ingine"
}
if ($InstallDir -match "^/mnt/[a-zA-Z](/|$)") {
    Fail "Refusing to install under $InstallDir (/mnt/* is slow NTFS over 9P and breaks symlinks/LF scripts). Use a native Linux path such as $wslHome/inkling-2-mini-abliterated-ingine."
}

$freeGbLine = $wslProbe.Output[-1]
if ($freeGbLine -match "(\d+)\s*G?$") {
    $freeGb = [int]$Matches[1]
    Write-Host "  WSL2 Linux disk free: $freeGb GiB (target: $InstallDir)"
    if ($freeGb -lt 25) {
        Write-Warn "WSL2 Linux filesystem has only $freeGb GiB free; ingine needs ~24 GB (20.2 GB model + ~3 GB CUDA/build tools)."
    }
}

if ($CheckOnly) {
    Write-Host "`nAll prerequisite checks completed." -ForegroundColor Green
    exit 0
}

# ---- 3. WSL2 setup: prerequisites, clone, install --------------------------------------------------
if (-not $ShimOnly) {
    Write-Step "Checking Linux build prerequisites in $Distro"
    $missingCheck = Invoke-WslBashCapture $Distro 'for c in git curl cc c++ setsid; do command -v $c >/dev/null || echo MISSING:$c; done'
    $missingList = @()
    foreach ($l in $missingCheck.Output) {
        if ($l -match "^MISSING:(.+)$") { $missingList += $Matches[1].Trim() }
    }
    if ($missingList.Count -gt 0) {
        Write-Host ("  Missing tools in WSL2: " + ($missingList -join " "))
        Write-Host "  Installing build-essential, git, curl, util-linux via apt (may prompt for your WSL sudo password)..."
        $aptRc = Invoke-WslBash $Distro 'sudo apt-get update && sudo apt-get install -y build-essential git curl util-linux'
        if ($aptRc -ne 0) {
            Fail "Failed to install Linux build prerequisites in WSL2. Install git, curl, gcc/g++ (12-16), and util-linux in $Distro and rerun."
        }
    } else {
        Write-Host "  Linux build tools present (git, curl, cc, c++, setsid)."
    }

    Write-Step "Cloning / verifying repository in WSL2 ($InstallDir)"
    $hasGit = Invoke-NativeCapture { & wsl.exe -d $Distro -- test -d "$InstallDir/.git" }
    if ($hasGit.ExitCode -eq 0) {
        Write-Host "  Existing git clone found at $InstallDir"
    } else {
        $pathExists = Invoke-NativeCapture { & wsl.exe -d $Distro -- test -e $InstallDir }
        if ($pathExists.ExitCode -eq 0) {
            Fail "$InstallDir already exists in $Distro and is not a git repository. Move it aside or pass -InstallDir."
        }
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { & wsl.exe -d $Distro -- git clone $RepoUrl $InstallDir; $cloneRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        if ($cloneRc -ne 0) {
            Fail "git clone into $InstallDir inside $Distro failed (exit $cloneRc)."
        }
    }

    # Forward Hugging Face token if available in Windows env (never printed or written to disk)
    $hfToken = $env:HF_TOKEN
    if (-not $hfToken) { $hfToken = $env:HUGGING_FACE_HUB_TOKEN }
    if (-not $hfToken) { $hfToken = $env:HF_PAT }

    $prevHf = $env:HF_TOKEN
    $prevWslEnv = $env:WSLENV
    try {
        if ($hfToken) {
            $env:HF_TOKEN = $hfToken
            if ($env:WSLENV) {
                if ($env:WSLENV -notmatch "(^|:)HF_TOKEN(:|/|$)") {
                    $env:WSLENV = "$($env:WSLENV):HF_TOKEN"
                }
            } else {
                $env:WSLENV = "HF_TOKEN"
            }
            Write-Host "  Forwarding Hugging Face token from Windows environment into WSL2."
        }

        Write-Step "Running upstream scripts/install.sh inside WSL2 (CUDA 13.4 + build + 20.2 GB model)"
        $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        try { & wsl.exe -d $Distro -- bash "$InstallDir/scripts/install.sh"; $installRc = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
        if ($installRc -ne 0) {
            Fail "scripts/install.sh exited with code $installRc. You can safely rerun setup-windows.ps1 to resume."
        }
    } finally {
        $env:HF_TOKEN = $prevHf
        $env:WSLENV = $prevWslEnv
    }

    Write-Step "Linking ~/.local/bin/ingine inside WSL2"
    $linkRes = Invoke-NativeCapture {
        & wsl.exe -d $Distro -- mkdir -p "$wslHome/.local/bin"
        if ($LASTEXITCODE -eq 0) {
            & wsl.exe -d $Distro -- ln -sfn "$InstallDir/scripts/ingine" "$wslHome/.local/bin/ingine"
        }
    }
    if ($linkRes.ExitCode -ne 0) {
        Write-Warn "Could not create ~/.local/bin/ingine symlink inside WSL2."
    }
}

# ---- 4. Install Windows CLI shim -------------------------------------------------------------------
Write-Step "Installing Windows 'ingine' command into $ShimDir"

$configDir = Split-Path -Parent $ShimDir
New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
New-Item -ItemType Directory -Force -Path $configDir | Out-Null

$configPath = Join-Path $configDir "config.json"
@{
    distro      = $Distro
    install_dir = $InstallDir
} | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8

$localShimSource = if ($PSScriptRoot) { Join-Path $PSScriptRoot "scripts\ingine.ps1" } else { "" }
$shimPs1 = Join-Path $ShimDir "ingine.ps1"
if ($localShimSource -and (Test-Path $localShimSource)) {
    Copy-Item -Path $localShimSource -Destination $shimPs1 -Force
} else {
    # Self-contained fallback when setup-windows.ps1 is run via irm | iex without a local Windows clone
    @'
[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$ArgsForward)

$ErrorActionPreference = "Continue"
$stateDir = Join-Path $env:LOCALAPPDATA "ingine"
$configPath = Join-Path $stateDir "config.json"
$keepalivePidPath = Join-Path $stateDir "keepalive.pid"
$distro = $env:INGINE_WSL_DISTRO
$installDir = $env:INGINE_WSL_DIR

if (Test-Path $configPath) {
    $cfg = Get-Content -Raw -Path $configPath | ConvertFrom-Json
    if (-not $distro -and $cfg.distro) { $distro = [string]$cfg.distro }
    if (-not $installDir -and $cfg.install_dir) { $installDir = [string]$cfg.install_dir }
}

function Get-KeepaliveProcess {
    if (-not (Test-Path $keepalivePidPath)) { return $null }
    $raw = (Get-Content -Raw -Path $keepalivePidPath -ErrorAction SilentlyContinue)
    if (-not $raw -or $raw.Trim() -notmatch "^\d+$") { return $null }
    $proc = Get-Process -Id ([int]$raw.Trim()) -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq "wsl") { return $proc }
    return $null
}

function Ensure-Keepalive([string]$DistroName) {
    if (Get-KeepaliveProcess) { return $false }
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $wslArgs = if ($DistroName) { @("-d", $DistroName, "--", "sleep", "infinity") } else { @("--", "sleep", "infinity") }
    $proc = Start-Process -FilePath "wsl.exe" -ArgumentList $wslArgs -WindowStyle Hidden -PassThru
    Set-Content -Path $keepalivePidPath -Value "$($proc.Id)" -Encoding ASCII
    Start-Sleep -Milliseconds 500
    return $true
}

function Stop-Keepalive {
    $existing = Get-KeepaliveProcess
    if ($existing) { Stop-Process -Id $existing.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Path $keepalivePidPath -Force -ErrorAction SilentlyContinue
}

$forwardVars = @("INGINE_MODEL_DIR", "INGINE_ABLATION", "HOST", "PORT", "INGINE_CTX", "INGINE_EXTRA_ARGS", "INGINE_START_TIMEOUT", "INGINE_GPU_PROFILE", "HF_TOKEN")
$subcmd = if ($ArgsForward -and $ArgsForward.Count -gt 0) { $ArgsForward[0] } else { "" }
$startedKeepalive = $false
$prevHf = $env:HF_TOKEN
$prevWslEnv = $env:WSLENV
try {
    if (-not $env:HF_TOKEN) {
        if ($env:HUGGING_FACE_HUB_TOKEN) { $env:HF_TOKEN = $env:HUGGING_FACE_HUB_TOKEN }
        elseif ($env:HF_PAT) { $env:HF_TOKEN = $env:HF_PAT }
    }
    $entries = @()
    if ($env:WSLENV) { $entries += ($env:WSLENV -split ":" | Where-Object { $_ -ne "" }) }
    foreach ($name in $forwardVars) {
        $val = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $val -and ($entries | Where-Object { $_ -match "^$([regex]::Escape($name))(/|$)" }).Count -eq 0) {
            $entries += $name
        }
    }
    if ($entries.Count -gt 0) { $env:WSLENV = ($entries -join ":") }

    if ($subcmd -eq "start") { $startedKeepalive = Ensure-Keepalive $distro }

    $target = if ($installDir) { "$installDir/scripts/ingine" } else { "ingine" }
    if ($distro) {
        if ($ArgsForward -and $ArgsForward.Count -gt 0) { & wsl.exe -d $distro -- $target @ArgsForward } else { & wsl.exe -d $distro -- $target }
    } else {
        if ($ArgsForward -and $ArgsForward.Count -gt 0) { & wsl.exe -- $target @ArgsForward } else { & wsl.exe -- $target }
    }
    $rc = $LASTEXITCODE

    if ($subcmd -eq "start" -and $rc -ne 0 -and $startedKeepalive) { Stop-Keepalive }
    elseif ($subcmd -eq "stop") { Stop-Keepalive }
    exit $rc
} finally {
    $env:HF_TOKEN = $prevHf
    $env:WSLENV = $prevWslEnv
}
'@ | Set-Content -Path $shimPs1 -Encoding UTF8
}

$shimCmd = Join-Path $ShimDir "ingine.cmd"
@"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ingine.ps1" %*
exit /b %ERRORLEVEL%
"@ | Set-Content -Path $shimCmd -Encoding ASCII

if (-not $NoPathUpdate) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $segments = @()
    if ($userPath) { $segments = $userPath -split ";" | Where-Object { $_ -ne "" } }
    if ($segments -notcontains $ShimDir) {
        $newPath = if ($userPath) { "$userPath;$ShimDir" } else { $ShimDir }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        if (($env:Path -split ";") -notcontains $ShimDir) {
            $env:Path = "$env:Path;$ShimDir"
        }
        Write-Host "  Added $ShimDir to your User PATH (open a new terminal for other windows to see it)."
    } else {
        Write-Host "  $ShimDir is already on your User PATH."
    }
}

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host "  WSL2 install: $Distro :: $InstallDir"
Write-Host "  Windows CLI:  $shimCmd"
Write-Host "  Commands:     ingine start | ingine status | ingine stop | ingine logs -f | ingine update"
Write-Host "  API endpoint: http://127.0.0.1:8003/v1  (model: inkling-2-mini-abliterated)"
