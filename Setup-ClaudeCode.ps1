#Requires -Version 5.1
<#
.SYNOPSIS
    Sets up Claude Code on Windows with custom status line for Git Bash.

.DESCRIPTION
    Idempotent. Edit the CONFIG block below, then run:

        powershell -ExecutionPolicy Bypass -File .\Setup-ClaudeCode.ps1

    Re-running is safe — already-installed components and existing
    config entries are detected and skipped.

    One manual step remains at the end: setting Git Bash as the VS Code
    default terminal (touching VS Code's settings.json automatically
    would risk corrupting an existing user config).
#>

# ============================================================================
# CONFIG  -- edit these, then run
# ============================================================================

$DefaultModel  = 'opus'    # opus | sonnet | haiku  (or $null for no alias)
$InstallWinget = $true     # bootstrap winget via PSGallery if missing (Server/LTSC images may need this)
$InstallGit    = $true     # install Git for Windows via winget if Git Bash isn't found
$InstallNode   = $true     # install latest Node.js via winget if missing (set $false if you manage Node yourself, e.g. nvm)
$InstallJq     = $true     # install jq via winget if missing

# ============================================================================

$ErrorActionPreference = 'Stop'

# PS7 + winget: native stdout capture fails on some Server/LTSC images unless
# console encoding is UTF-8. Also disable promoted native errors so winget's
# stderr chatter doesn't terminate the script.
$OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope Global -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Test-Cmd { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }
function Get-CmdVersion {
    # Safely capture --version output. Avoids inline native-command calls in
    # Write-Host interpolations, which trip a PS7 StandardOutputEncoding bug.
    param([string]$Cmd)
    try {
        $out = & $Cmd --version 2>&1 | Out-String
        return $out.Trim()
    } catch {
        return 'installed (version check failed)'
    }
}
function Write-Step { param([string]$Msg) Write-Host "`n>> $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "   [OK] $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "   [--] $Msg" -ForegroundColor DarkGray }
function Update-SessionPath {
    # Refresh current session PATH from registry (Machine + User) after winget installs
    $m = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $u = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = "$m;$u"
}
function Find-GitBash {
    # Git for Windows install locations: system-wide (64/32-bit) or per-user
    $candidates = @(
        "$env:ProgramFiles\Git\bin\bash.exe",
        "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    # Fall back to PATH lookup, but only if it's actually Git Bash (not WSL bash, MSYS2, etc.)
    $cmd = Get-Command bash.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source -like '*Git*') { return $cmd.Source }
    return $null
}
function Test-WingetWorking {
    # On Server/LTSC/sysprep'd images, winget.exe in WindowsApps is an App
    # Execution Alias stub that errors with "No applicable app licenses found"
    # because the underlying UWP package isn't provisioned. Verify it actually runs.
    if (-not (Test-Cmd 'winget')) { return $false }
    try {
        $v = & winget --version 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0) -and ($v.Trim() -match '^v?\d')
    } catch {
        return $false
    }
}

# ---------------------------------------------------------------------------
# Pre-flight: verify prerequisites and gather state
# ---------------------------------------------------------------------------

Write-Host "`n=== Claude Code Setup ===" -ForegroundColor Cyan

$WingetInstalled = Test-WingetWorking
$WingetStubOnly  = (Test-Cmd 'winget') -and -not $WingetInstalled
$NodeInstalled   = Test-Cmd 'node'
$JqInstalled     = Test-Cmd 'jq'
$GitBash         = Find-GitBash
$GitInstalled    = $null -ne $GitBash
$NeedNode        = -not $NodeInstalled -and $InstallNode
$NeedJq          = -not $JqInstalled -and $InstallJq
$NeedGit         = -not $GitInstalled -and $InstallGit
$NeedWinget      = -not $WingetInstalled -and ($NeedNode -or $NeedJq -or $NeedGit) -and $InstallWinget

if (-not $NodeInstalled -and -not $InstallNode) {
    Write-Host "Node.js not found and `$InstallNode = `$false. Install from https://nodejs.org or set `$InstallNode = `$true and re-run." -ForegroundColor Red
    exit 1
}

if (-not $GitInstalled -and -not $InstallGit) {
    Write-Host "Git Bash not found and `$InstallGit = `$false. Install Git for Windows or set `$InstallGit = `$true and re-run." -ForegroundColor Red
    exit 1
}

if (-not $WingetInstalled -and ($NeedNode -or $NeedJq -or $NeedGit) -and -not $InstallWinget) {
    Write-Host "winget required to install dependencies but missing, and `$InstallWinget = `$false. Set `$InstallWinget = `$true or install App Installer from the Microsoft Store." -ForegroundColor Red
    exit 1
}

$ClaudeBin    = "$env:USERPROFILE\.local\bin"
$ClaudeExe    = "$ClaudeBin\claude.exe"
$NeedClaude   = -not (Test-Path $ClaudeExe)

# Capture versions once to dodge the PS7 inline-native-call encoding bug
$WingetVersion = if ($WingetInstalled) { Get-CmdVersion 'winget' } else { '' }
$NodeVersion   = if ($NodeInstalled)   { Get-CmdVersion 'node' }   else { '' }

# ---------------------------------------------------------------------------
# Plan + confirm
# ---------------------------------------------------------------------------

Write-Host "`nDetected:" -ForegroundColor Yellow
Write-Host "   winget      $(if ($WingetInstalled) {$WingetVersion} elseif ($WingetStubOnly) {'stub present but not provisioned - will repair via PSGallery'} elseif ($NeedWinget) {'will install via PSGallery'} else {'not needed'})"
Write-Host "   Node.js     $(if ($NodeInstalled) {$NodeVersion} elseif ($InstallNode) {'will install (current)'} else {'missing (will fail)'})"
Write-Host "   Git Bash    $(if ($GitInstalled) {$GitBash} elseif ($InstallGit) {'will install Git for Windows'} else {'missing (will fail)'})"
Write-Host "   Claude Code $(if ($NeedClaude) {'will install'} else {'already installed'})"
Write-Host "   jq          $(if ($JqInstalled) {'already installed'} elseif ($InstallJq) {'will install'} else {'missing (skipped)'})"

Write-Host "`nWill apply:" -ForegroundColor Yellow
Write-Host "   - Default model alias  : $(if ($DefaultModel) {"claude => claude.exe --model $DefaultModel"} else {'(none)'})"
Write-Host "   - Status line script   : ~/.claude/statusline.sh"
Write-Host "   - Claude settings.json : ~/.claude/settings.json (merge if exists)"
Write-Host "   - User PATH            : add $ClaudeBin if missing"
Write-Host "   - Git Bash PATH        : add jq path to ~/.bashrc if needed"
Write-Host ""

$go = Read-Host "Proceed? [Y/n]"
if ($go -and $go -notmatch '^[Yy]') { Write-Host "Aborted." -ForegroundColor Yellow; exit 0 }

# ---------------------------------------------------------------------------
# 1. Bootstrap winget if missing (needed for Node/jq installs)
# ---------------------------------------------------------------------------

Write-Step "winget"
if ($NeedWinget) {
    $IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host "   Bootstrapping via PowerShell Gallery (can take a minute)..." -ForegroundColor DarkGray
    Write-Host "   Mode: $(if ($IsAdmin) {'-AllUsers (elevated)'} else {'CurrentUser (not elevated)'})" -ForegroundColor DarkGray

    # TLS 1.2 required for PSGallery on older Server images
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
    if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.Client)) {
        Install-Module -Name Microsoft.WinGet.Client -Force -Scope CurrentUser -Repository PSGallery -AllowClobber | Out-Null
    }
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop

    $repairArgs = @{ Latest = $true; Force = $true }
    if ($IsAdmin) { $repairArgs['AllUsers'] = $true }

    try {
        Repair-WinGetPackageManager @repairArgs | Out-Host
    } catch {
        Write-Host ""
        Write-Host "   Repair-WinGetPackageManager failed: $($_.Exception.Message)" -ForegroundColor Red
        if (-not $IsAdmin) {
            Write-Host "   This usually means winget needs machine-wide provisioning (-AllUsers), which requires admin." -ForegroundColor Yellow
            Write-Host "   Re-run this script from an elevated PowerShell:" -ForegroundColor Yellow
            Write-Host "       Start-Process powershell -Verb RunAs -ArgumentList '-ExecutionPolicy','Bypass','-File','`"$PSCommandPath`"'" -ForegroundColor Yellow
        } else {
            Write-Host "   Already elevated. Manual fallback: download App Installer from https://aka.ms/getwinget and re-run." -ForegroundColor Yellow
        }
        exit 1
    }

    Update-SessionPath
    if (-not (Test-Cmd 'winget')) {
        Write-Host "winget bootstrap completed but 'winget' still not found in PATH. Open a new PowerShell window and re-run." -ForegroundColor Red
        exit 1
    }
    Write-OK "installed $(Get-CmdVersion 'winget')"
} elseif ($WingetInstalled) {
    Write-Skip "already installed ($WingetVersion)"
} else {
    Write-Skip "not needed"
}

# ---------------------------------------------------------------------------
# 2. Install Node.js if missing
# ---------------------------------------------------------------------------

Write-Step "Node.js"
if ($NeedNode) {
    winget install OpenJS.NodeJS --accept-source-agreements --accept-package-agreements | Out-Host
    Update-SessionPath
    if (-not (Test-Cmd 'node')) {
        Write-Host "Node install completed but 'node' still not found in PATH. Open a new PowerShell window and re-run." -ForegroundColor Red
        exit 1
    }
    Write-OK "installed $(Get-CmdVersion 'node')"
} else {
    Write-Skip "already installed ($NodeVersion)"
}

# ---------------------------------------------------------------------------
# 3. Install Git for Windows if missing
# ---------------------------------------------------------------------------

Write-Step "Git for Windows"
if ($NeedGit) {
    winget install Git.Git --accept-source-agreements --accept-package-agreements | Out-Host
    Update-SessionPath
    $GitBash = Find-GitBash
    if (-not $GitBash) {
        Write-Host "Git install completed but bash.exe not found in any expected location. Open a new PowerShell window and re-run." -ForegroundColor Red
        exit 1
    }
    Write-OK "installed (Git Bash at $GitBash)"
} else {
    Write-Skip "already installed (Git Bash at $GitBash)"
}

# ---------------------------------------------------------------------------
# 4. Install Claude Code if missing
# ---------------------------------------------------------------------------

Write-Step "Claude Code"
if ($NeedClaude) {
    irm https://claude.ai/install.ps1 | iex
    Write-OK "installed"
} else {
    Write-Skip "already installed at $ClaudeExe"
}

# ---------------------------------------------------------------------------
# 5. User PATH
# ---------------------------------------------------------------------------

Write-Step "User PATH"
$UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if (-not $UserPath) { $UserPath = '' }
if (($UserPath -split ';') -notcontains $ClaudeBin) {
    $NewPath = if ($UserPath) { "$UserPath;$ClaudeBin" } else { $ClaudeBin }
    [Environment]::SetEnvironmentVariable('PATH', $NewPath, 'User')
    Write-OK "added $ClaudeBin"
} else {
    Write-Skip "$ClaudeBin already in User PATH"
}

# ---------------------------------------------------------------------------
# 6. jq
# ---------------------------------------------------------------------------

Write-Step "jq"
if ($NeedJq) {
    winget install jqlang.jq --accept-source-agreements --accept-package-agreements | Out-Host
    Write-OK "installed"
} else {
    Write-Skip "already installed or skipped"
}

# ---------------------------------------------------------------------------
# 7. Claude config files (statusline.sh, settings.json) + chmod
# ---------------------------------------------------------------------------

Write-Step "Claude config (~/.claude)"

$ClaudeDir = "$env:USERPROFILE\.claude"
New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null

# statusline.sh -- write with LF endings, no BOM
$StatuslinePath = "$ClaudeDir\statusline.sh"
$Statusline = @'
#!/bin/bash
input=$(cat)
MODEL=$(echo "$input" | jq -r '.model.display_name')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')

color_for() {
  local p=$1
  if [ "$p" -lt 50 ]; then echo $'\033[32m'
  elif [ "$p" -lt 80 ]; then echo $'\033[33m'
  else echo $'\033[91m'; fi
}
RESET=$'\033[0m'

printf "[%s] Ctx: %s%s%%%s | Cost: \$%.2f" \
  "$MODEL" \
  "$(color_for "$PCT")" "$PCT" "$RESET" \
  "$COST"
'@
$StatuslineLF = $Statusline -replace "`r`n", "`n"
[System.IO.File]::WriteAllText($StatuslinePath, $StatuslineLF, [System.Text.UTF8Encoding]::new($false))
Write-OK "wrote $StatuslinePath"

# settings.json -- merge if exists, create otherwise
$SettingsPath = "$ClaudeDir\settings.json"
$StatusLineBlock = [PSCustomObject]@{
    type    = 'command'
    command = '~/.claude/statusline.sh'
    padding = 0
}

if (Test-Path $SettingsPath) {
    try {
        $Settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        $Settings | Add-Member -MemberType NoteProperty -Name 'statusLine' -Value $StatusLineBlock -Force
    } catch {
        $Backup = "$SettingsPath.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $SettingsPath $Backup
        Write-Host "   [!] could not parse existing settings.json - backed up to $Backup" -ForegroundColor Yellow
        $Settings = [PSCustomObject]@{ statusLine = $StatusLineBlock }
    }
} else {
    $Settings = [PSCustomObject]@{ statusLine = $StatusLineBlock }
}

$SettingsJson = $Settings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($SettingsPath, $SettingsJson, [System.Text.UTF8Encoding]::new($false))
Write-OK "wrote $SettingsPath"

# chmod via Git Bash
& $GitBash -c "chmod +x ~/.claude/statusline.sh"
Write-OK "chmod +x statusline.sh"

# ---------------------------------------------------------------------------
# 8. ~/.bashrc entries (idempotent)
# ---------------------------------------------------------------------------

Write-Step "Git Bash config (~/.bashrc)"

$BashrcPath = "$env:USERPROFILE\.bashrc"
if (-not (Test-Path $BashrcPath)) { New-Item -ItemType File -Path $BashrcPath -Force | Out-Null }
$Bashrc = Get-Content $BashrcPath -Raw -ErrorAction SilentlyContinue
if (-not $Bashrc) { $Bashrc = '' }

$LinesToAdd = @()

if ($DefaultModel) {
    $AliasLine = "alias claude='claude.exe --model $DefaultModel'"
    if ($Bashrc -notmatch [regex]::Escape("--model $DefaultModel")) {
        $LinesToAdd += $AliasLine
    }
}

# jq PATH fallback - test from bash, add if jq isn't found there
$JqCheck = (& $GitBash -c "command -v jq >/dev/null 2>&1 && echo yes || echo no").Trim()
if ($JqCheck -eq 'no') {
    if ($Bashrc -notmatch [regex]::Escape('Program Files/jq')) {
        $LinesToAdd += 'export PATH="$PATH:/c/Program Files/jq"'
    }
}

if ($LinesToAdd.Count -gt 0) {
    $Block = "`n# Claude Code setup`n" + ($LinesToAdd -join "`n") + "`n"
    [System.IO.File]::AppendAllText($BashrcPath, $Block, [System.Text.UTF8Encoding]::new($false))
    Write-OK "appended $($LinesToAdd.Count) line(s)"
} else {
    Write-Skip "already configured"
}

# ---------------------------------------------------------------------------
# Sanity check
# ---------------------------------------------------------------------------

Write-Step "Status line sanity check"
$TestJson = '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":34},"cost":{"total_cost_usd":0.4123}}'
# Pipe via PowerShell stdin -- bash -c with embedded quotes mangles JSON
$Output = $TestJson | & $GitBash -c "~/.claude/statusline.sh"
Write-Host "   $Output"
Write-Host ""

# ---------------------------------------------------------------------------
# Final
# ---------------------------------------------------------------------------

Write-Host "=== Done ===" -ForegroundColor Green
Write-Host ""
Write-Host "Manual step (one time): in VS Code, Ctrl+Shift+P -> 'Terminal: Select Default Profile' -> Git Bash" -ForegroundColor Yellow
Write-Host "Then close VS Code completely and reopen."
Write-Host ""
Write-Host "First Claude run: open Git Bash, type 'claude', then '/login'."
