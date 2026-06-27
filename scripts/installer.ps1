#!/usr/bin/env pwsh
<#
.SYNOPSIS
    构建「第二大脑」Windows 安装包。

.DESCRIPTION
    先复用 scripts/publish.ps1 生成 Windows Release 目录，再调用 Inno Setup
    编译标准安装程序。安装包会安装到 Program Files，创建开始菜单快捷方式，
    并可通过参数创建桌面快捷方式。

.PARAMETER Clean
    构建前执行 flutter clean。

.PARAMETER DesktopShortcut
    安装时默认创建桌面快捷方式。

.PARAMETER SkipBuild
    跳过 Flutter 构建，直接使用 dist 下已有的 Windows 发布目录。

.PARAMETER InnoSetupPath
    手动指定 ISCC.exe 路径。

.EXAMPLE
    pwsh ./scripts/installer.ps1
    pwsh ./scripts/installer.ps1 -Clean -DesktopShortcut
    pwsh ./scripts/installer.ps1 -SkipBuild
#>

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$DesktopShortcut,
    [switch]$SkipBuild,
    [string]$InnoSetupPath
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} else {
    $OutputEncoding = New-Object System.Text.UTF8Encoding
}
[Console]::OutputEncoding = $OutputEncoding

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
$DistRoot    = Join-Path $ProjectRoot 'dist'
$BuildRoot   = Join-Path $DistRoot 'installer-build'

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Fail($msg)       { Write-Host "[X]  $msg" -ForegroundColor Red; exit 1 }

function Get-DisplayName {
    return -join @([char]0x7B2C, [char]0x4E8C, [char]0x5927, [char]0x8111)
}

function Get-AppInfo {
    $pubspec = Join-Path $ProjectRoot 'pubspec.yaml'
    if (-not (Test-Path $pubspec)) { Fail "pubspec.yaml was not found: $pubspec" }
    $content = Get-Content $pubspec -Raw
    $name = if ($content -match '(?m)^name:\s*(\S+)') { $Matches[1] } else { 'mind' }
    $version = if ($content -match '(?m)^version:\s*([^\s+]+)') { $Matches[1] } else { '0.0.0' }
    [pscustomobject]@{
        Name = $name
        DisplayName = Get-DisplayName
        Version = $version
        Exe = "$name.exe"
        Publisher = Get-DisplayName
    }
}

function Resolve-InnoCompiler {
    if ($InnoSetupPath) {
        if (Test-Path $InnoSetupPath) { return (Resolve-Path $InnoSetupPath).Path }
        Fail "Specified Inno Setup compiler was not found: $InnoSetupPath"
    }

    $cmd = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        'C:\Program Files (x86)\Inno Setup 5\ISCC.exe',
        'C:\Program Files\Inno Setup 5\ISCC.exe'
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }

    Fail "Inno Setup compiler ISCC.exe was not found. Install it with: winget install JRSoftware.InnoSetup"
}

function Invoke-Publish($app) {
    $publish = Join-Path $ScriptDir 'publish.ps1'
    if (-not (Test-Path $publish)) { Fail "publish.ps1 was not found: $publish" }

    Write-Step "Generating Windows release directory..."
    if ($Clean) {
        & $publish -Platform windows -Clean
    } else {
        & $publish -Platform windows
    }
    if ($LASTEXITCODE -ne 0) { Fail "publish.ps1 failed" }
}

function Resolve-WindowsPackageDir($app) {
    $expected = Join-Path $DistRoot "$($app.Name)-windows-v$($app.Version)"
    if (Test-Path $expected) { return (Resolve-Path $expected).Path }

    $package = Get-ChildItem $DistRoot -Directory -Filter "$($app.Name)-windows-v*" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($package) { return $package.FullName }

    Fail "Windows package directory was not found. Run without -SkipBuild first."
}

function NewInnoScript($app, $sourceDir, $outputDir) {
    if (Test-Path $BuildRoot) { Remove-Item $BuildRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $BuildRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

    $issPath = Join-Path $BuildRoot "$($app.Name)-installer.iss"
    $sourceWildcard = (Join-Path $sourceDir '*').Replace('\', '\\')
    $outputDirEsc = $outputDir.Replace('\', '\\')
    $outputBase = "$($app.DisplayName)-Setup-v$($app.Version)"
    $desktopTaskFlag = if ($DesktopShortcut) { 'checkedonce' } else { 'unchecked' }

    $languageBlock = ''
    $languageFile = Join-Path (Split-Path -Parent $iscc) 'Languages\ChineseSimplified.isl'
    if (Test-Path $languageFile) {
        $languageBlock = @'
[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

'@
    }

    $content = @"
#define MyAppName "$($app.DisplayName)"
#define MyAppVersion "$($app.Version)"
#define MyAppPublisher "$($app.Publisher)"
#define MyAppExeName "$($app.Exe)"

[Setup]
AppId={{F7D7F0A9-18C1-4C3E-A606-02B8A84C2043}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=$outputDirEsc
OutputBaseFilename=$outputBase
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=lowest
SetupIconFile=$((Join-Path $ProjectRoot 'windows\runner\resources\app_icon.ico').Replace('\', '\\'))
UninstallDisplayIcon={app}\{#MyAppExeName}

$languageBlock
[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional tasks:"; Flags: $desktopTaskFlag

[Files]
Source: "$sourceWildcard"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
"@

    Set-Content -Path $issPath -Value $content -Encoding UTF8
    return $issPath
}

if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
    Fail "installer.ps1 only supports building Windows installers on Windows."
}

$app = Get-AppInfo
Write-Step "App: $($app.DisplayName)  Version: $($app.Version)"

$iscc = Resolve-InnoCompiler

if (-not $SkipBuild) {
    Invoke-Publish $app
}

$sourceDir = Resolve-WindowsPackageDir $app
$exePath = Join-Path $sourceDir $app.Exe
if (-not (Test-Path $exePath)) {
    Fail "Main executable was not found in package directory: $exePath"
}

$outputDir = Join-Path $DistRoot 'installer'
$iss = NewInnoScript $app $sourceDir $outputDir

Write-Step "Compiling Inno Setup installer..."
& $iscc $iss
if ($LASTEXITCODE -ne 0) { Fail "Inno Setup compile failed" }

$installer = Join-Path $outputDir "$($app.DisplayName)-Setup-v$($app.Version).exe"
if (-not (Test-Path $installer)) { Fail "Installer output was not found: $installer" }

Write-Host ""
Write-Ok "Installer generated: $installer"
