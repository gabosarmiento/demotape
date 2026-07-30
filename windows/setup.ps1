<#
.SYNOPSIS
    Agent-assisted setup for DemoTape on Windows 11 — the Windows counterpart of the macOS
    "Agent-assisted setup for a tester" runbook in ../AGENTS.md.

.DESCRIPTION
    Builds DemoTape from this checkout, produces a self-contained (no-runtime-install) app, drops
    a Start Menu + Desktop shortcut, and optionally registers it to open at login. Designed to be
    run by a coding agent (or a human) on a tester's own machine: it verifies each precondition,
    prints a clear STOP message when a manual step is required (e.g. installing the Windows SDK
    needs an elevated GUI installer), and never proceeds past a failed step.

    Building locally produces a native-arch binary, needs no code signing / SmartScreen bypass
    (nothing is downloaded and run), and — because Windows screen capture needs no persistent
    permission grant — the app just works after install.

.PARAMETER SkipTests
    Skip the unit-test gate (not recommended; tests are pure logic and take seconds).

.PARAMETER Startup
    Register DemoTape to start automatically at login (per-user Run key).

.PARAMETER NoLaunch
    Build and install, but don't launch the app at the end.

.PARAMETER Configuration
    Build configuration. Default: Release.

.EXAMPLE
    windows\setup.ps1

.EXAMPLE
    windows\setup.ps1 -Startup          # also open at login
#>
[CmdletBinding()]
param(
    [switch] $SkipTests,
    [switch] $Startup,
    [switch] $NoLaunch,
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Helpers ----------------------------------------------------------------
function Write-Step ($m) { Write-Host ('' + [Environment]::NewLine + '=== ' + $m + ' ===') -ForegroundColor Cyan }
function Write-Ok   ($m) { Write-Host ('  [ok] ' + $m) -ForegroundColor Green }
function Write-Info ($m) { Write-Host ('  ' + $m) -ForegroundColor Gray }
function Fail-Stop  ([string[]] $lines) {
    Write-Host ''
    Write-Host ('STOP: ' + $lines[0]) -ForegroundColor Red
    foreach ($l in ($lines | Select-Object -Skip 1)) { Write-Host $l -ForegroundColor Red }
    exit 1
}

$WindowsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $WindowsDir
$AppProj    = Join-Path $WindowsDir 'src\App\DemoTape.App.csproj'
$TestProj   = Join-Path $WindowsDir 'tests\DemoTape.Tests\DemoTape.Tests.csproj'

Write-Host 'DemoTape for Windows — agent-assisted setup' -ForegroundColor White
Write-Info ('repo:   ' + $RepoRoot)
Write-Info ('config: ' + $Configuration)

# --- 0. Preconditions -------------------------------------------------------
Write-Step '0. Preconditions'

$osBuild = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
Write-Info ('Windows build: ' + $osBuild)
if ($osBuild -lt 22000) {
    Write-Host '  [warn] DemoTape targets Windows 11 (build 22000+). Continuing, but capture is unvalidated here.' -ForegroundColor Yellow
}

$arch = $env:PROCESSOR_ARCHITECTURE
$rid  = if ($arch -eq 'ARM64') { 'win-arm64' } else { 'win-x64' }
$plat = if ($arch -eq 'ARM64') { 'ARM64' } else { 'x64' }
Write-Info ('architecture: ' + $arch + ' -> RID ' + $rid + ', Platform ' + $plat)

# Locate the .NET 8 SDK. dotnet is often not on PATH; check the default install dir too.
$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
$dotnet = if ($dotnetCmd) { $dotnetCmd.Source } else { $null }
if (-not $dotnet) {
    $candidate = Join-Path $env:ProgramFiles 'dotnet\dotnet.exe'
    if (Test-Path $candidate) {
        $dotnet = $candidate
        $dotnetDir = Split-Path $candidate
        $env:Path = $dotnetDir + ';' + $env:Path
    }
}
if (-not $dotnet) {
    Fail-Stop @(
        'The .NET 8 SDK was not found. Install it, then re-run this script:',
        '    winget install Microsoft.DotNet.SDK.8',
        "(If winget isn't available, download from https://dotnet.microsoft.com/download/dotnet/8.0)"
    )
}
$sdks = & $dotnet --list-sdks
if (-not ($sdks | Select-String -SimpleMatch '8.')) {
    Fail-Stop @(
        'A .NET SDK was found but not the 8.x line (needed by this project). Install it and re-run:',
        '    winget install Microsoft.DotNet.SDK.8',
        'Installed SDKs:',
        ($sdks -join [Environment]::NewLine)
    )
}
Write-Ok ('.NET 8 SDK present (' + $dotnet + ')')

# --- 1. Unit-test gate (pure logic; no GUI, no Windows SDK) -----------------
if (-not $SkipTests) {
    Write-Step '1. Unit tests (business logic)'
    & $dotnet test $TestProj -c Release --nologo
    if ($LASTEXITCODE -ne 0) { Fail-Stop @('Unit tests failed. Fix them before installing.') }
    Write-Ok 'unit tests passed'
} else {
    Write-Info 'skipping tests (-SkipTests)'
}

# --- 2. Publish the self-contained app --------------------------------------
Write-Step '2. Build + publish (self-contained, no runtime install needed)'
Stop-Process -Name DemoTape -Force -ErrorAction SilentlyContinue

$publishDir = Join-Path $WindowsDir 'dist\DemoTape'
& $dotnet publish $AppProj -c $Configuration -p:Platform=$plat -r $rid --self-contained true `
    -p:WindowsPackageType=None -p:WindowsAppSDKSelfContained=true `
    -o $publishDir --nologo
if ($LASTEXITCODE -ne 0) {
    Fail-Stop @(
        'The WinUI app failed to build/publish. The most common cause is a missing Windows 11 SDK',
        '(10.0.22621+) or Windows App SDK tooling — the pure-.NET projects and tests build without it,',
        'but the app shell needs it. Install it (an elevated GUI/installer step an agent cannot click):',
        '',
        '  Option A (recommended): Visual Studio 2022 17.8+ with ".NET Desktop Development" +',
        '    "Windows 11 SDK (10.0.26100)" + "Windows App SDK C# Templates".',
        '',
        '  Option B (standalone SDK, run elevated):',
        '    Invoke-WebRequest "https://go.microsoft.com/fwlink/?linkid=2196241" -OutFile "$env:TEMP\winsdksetup.exe"',
        "    Start-Process `"`$env:TEMP\winsdksetup.exe`" -ArgumentList '/features','OptionId.WindowsSoftwareDevelopmentKit','/quiet','/norestart' -Verb RunAs -Wait",
        '',
        'Then re-run this script.'
    )
}
$exe = Join-Path $publishDir 'DemoTape.exe'
if (-not (Test-Path $exe)) { Fail-Stop @('Publish reported success but DemoTape.exe is missing at ' + $exe) }
Write-Ok ('published to ' + $publishDir)

# --- 3. Shortcuts -----------------------------------------------------------
Write-Step '3. Desktop + Start Menu shortcuts'
$icon = Join-Path $publishDir 'Assets\demotape.ico'
if (-not (Test-Path $icon)) { $icon = $exe }

function New-Shortcut ([string] $linkPath) {
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($linkPath)
    $lnk.TargetPath       = $exe
    $lnk.WorkingDirectory = $publishDir
    $lnk.IconLocation     = ($icon + ',0')
    $lnk.Description       = 'DemoTape — local-first screen recorder'
    $lnk.Save()
}

$desktopLnk   = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DemoTape.lnk'
$startMenuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'DemoTape.lnk'
New-Shortcut $desktopLnk
New-Shortcut $startMenuLnk
Write-Ok ('Desktop:    ' + $desktopLnk)
Write-Ok ('Start Menu: ' + $startMenuLnk)

# --- 4. Optional: open at login --------------------------------------------
if ($Startup) {
    Write-Step '4. Open at login'
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Set-ItemProperty -Path $runKey -Name 'DemoTape' -Value ('"' + $exe + '"')
    Write-Ok 'registered to start at login (remove any time from Task Manager > Startup)'
}

# --- 5. Launch --------------------------------------------------------------
if (-not $NoLaunch) {
    Write-Step '5. Launch'
    Start-Process $exe
    Write-Ok 'DemoTape launched — look for the tape icon in the system tray (near the clock)'
    Write-Info 'Right-click the tray icon for the menu; the floating bar''s ••• button has recording setup.'
} else {
    Write-Info 'not launching (-NoLaunch). Run it any time from the Desktop shortcut.'
}

Write-Host ('' + [Environment]::NewLine + 'Done. DemoTape is installed at:') -ForegroundColor White
Write-Host ('  ' + $publishDir) -ForegroundColor White
$notes = @(
    '',
    'Notes for a tester:',
    '  - Windows screen capture needs no persistent permission grant, so recording works right away.',
    '  - Microphone / Camera are prompted the first time you enable them (Settings > Privacy).',
    '  - AI features are opt-in and bring-your-own-key (stored in Windows Credential Manager).',
    '  - To update later: git pull, then re-run this script.'
)
foreach ($n in $notes) { Write-Host $n -ForegroundColor Gray }
