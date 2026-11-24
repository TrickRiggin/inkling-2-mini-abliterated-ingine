<#
.SYNOPSIS
    Windows CLI shim that forwards `ingine` commands directly into the WSL2 installation.
    Maintains a lightweight hidden WSL2 keepalive process between `ingine start` and `ingine stop`
    so Windows WSL2 does not auto-terminate the background server when no WSL terminal is open.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ArgsForward
)

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
    $procId = [int]$raw.Trim()
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($proc -and $proc.ProcessName -eq "wsl") { return $proc }
    return $null
}

function Ensure-Keepalive([string]$DistroName) {
    $existing = Get-KeepaliveProcess
    if ($existing) { return $false }
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
    $wslArgs = if ($DistroName) {
        @("-d", $DistroName, "--", "sleep", "infinity")
    } else {
        @("--", "sleep", "infinity")
    }
    $proc = Start-Process -FilePath "wsl.exe" -ArgumentList $wslArgs -WindowStyle Hidden -PassThru
    Set-Content -Path $keepalivePidPath -Value "$($proc.Id)" -Encoding ASCII
    # Brief pause so the WSL session registers with systemd-logind before `ingine start` runs.
    Start-Sleep -Milliseconds 500
    return $true
}

function Stop-Keepalive {
    $existing = Get-KeepaliveProcess
    if ($existing) {
        Stop-Process -Id $existing.Id -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $keepalivePidPath -Force -ErrorAction SilentlyContinue
}

# Forward ingine configuration and HF token variables into WSL2 when set on Windows.
$forwardVars = @(
    "INGINE_MODEL_DIR",
    "INGINE_ABLATION",
    "HOST",
    "PORT",
    "INGINE_CTX",
    "INGINE_EXTRA_ARGS",
    "INGINE_START_TIMEOUT",
    "INGINE_GPU_PROFILE",
    "HF_TOKEN"
)

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
    if ($env:WSLENV) {
        $entries += ($env:WSLENV -split ":" | Where-Object { $_ -ne "" })
    }
    foreach ($name in $forwardVars) {
        $val = [Environment]::GetEnvironmentVariable($name)
        if ($null -ne $val -and ($entries | Where-Object { $_ -match "^$([regex]::Escape($name))(/|$)" }).Count -eq 0) {
            $entries += $name
        }
    }
    if ($entries.Count -gt 0) {
        $env:WSLENV = ($entries -join ":")
    }

    if ($subcmd -eq "start") {
        $startedKeepalive = Ensure-Keepalive $distro
    }

    $target = if ($installDir) { "$installDir/scripts/ingine" } else { "ingine" }

    if ($distro) {
        if ($ArgsForward -and $ArgsForward.Count -gt 0) {
            & wsl.exe -d $distro -- $target @ArgsForward
        } else {
            & wsl.exe -d $distro -- $target
        }
    } else {
        if ($ArgsForward -and $ArgsForward.Count -gt 0) {
            & wsl.exe -- $target @ArgsForward
        } else {
            & wsl.exe -- $target
        }
    }
    $rc = $LASTEXITCODE

    if ($subcmd -eq "start" -and $rc -ne 0 -and $startedKeepalive) {
        Stop-Keepalive
    } elseif ($subcmd -eq "stop") {
        Stop-Keepalive
    }

    exit $rc
} finally {
    $env:HF_TOKEN = $prevHf
    $env:WSLENV = $prevWslEnv
}
