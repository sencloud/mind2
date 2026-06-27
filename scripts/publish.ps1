#!/usr/bin/env pwsh
<#
.SYNOPSIS
    根据当前平台发布 mind 应用，生成可直接分发的可执行程序包。

.DESCRIPTION
    自动识别运行平台（Windows / macOS / Linux），调用对应的 flutter build，
    并将构建产物整理到 dist/ 目录。
    在 Windows 上会额外打包 VC++ 运行时与 UCRT 相关 DLL，
    使程序在未安装 Visual C++ 运行库的机器上也能直接运行。

.PARAMETER Platform
    指定目标平台：windows / macos / linux / auto（默认 auto，按当前系统判断）。

.PARAMETER Clean
    构建前执行 flutter clean。

.PARAMETER Zip
    发布完成后将产物压缩为 zip 包。

.EXAMPLE
    pwsh ./scripts/publish.ps1
    pwsh ./scripts/publish.ps1 -Clean -Zip
    pwsh ./scripts/publish.ps1 -Platform windows
#>

[CmdletBinding()]
param(
    [ValidateSet('auto', 'windows', 'macos', 'linux')]
    [string]$Platform = 'auto',
    [switch]$Clean,
    [switch]$Zip
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} else {
    $OutputEncoding = New-Object System.Text.UTF8Encoding
}
[Console]::OutputEncoding = $OutputEncoding

# ---------- 基础信息 ----------
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
$DistRoot    = Join-Path $ProjectRoot 'dist'
$EnvFile     = Join-Path $ProjectRoot '.env'

function Write-Step($msg)  { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)    { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }
function Fail($msg)        { Write-Host "[X]  $msg" -ForegroundColor Red; exit 1 }

# ---------- 本地环境变量 ----------
function Read-LocalEnv {
    $values = @{}
    if (-not (Test-Path $EnvFile)) { return $values }

    foreach ($line in Get-Content $EnvFile) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) { continue }

        $idx = $trimmed.IndexOf('=')
        if ($idx -le 0) { continue }

        $key = $trimmed.Substring(0, $idx).Trim()
        $value = $trimmed.Substring($idx + 1).Trim()
        if ($value.Length -ge 2) {
            $first = $value[0]
            $last = $value[$value.Length - 1]
            if (($first -eq [char]34 -and $last -eq [char]34) -or ($first -eq [char]39 -and $last -eq [char]39)) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $values[$key] = $value
    }

    return $values
}

function Get-DartDefineArgs {
    $localEnv = Read-LocalEnv
    $keys = @('DEEPSEEK_API_KEY', 'DEEPSEEK_BASE_URL', 'DEEPSEEK_MODEL')
    $args = @()

    foreach ($key in $keys) {
        $value = $null
        if ($localEnv.ContainsKey($key)) {
            $value = $localEnv[$key]
        } else {
            $value = [Environment]::GetEnvironmentVariable($key)
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $args += ("--dart-define={0}={1}" -f $key, $value)
        }
    }

    $envApiKey = [Environment]::GetEnvironmentVariable('DEEPSEEK_API_KEY')
    $hasApiKey = $localEnv.ContainsKey('DEEPSEEK_API_KEY') -or -not [string]::IsNullOrWhiteSpace($envApiKey)
    if (-not $hasApiKey) {
        Write-Warn2 '未找到 DEEPSEEK_API_KEY。请在项目根目录 .env 中配置，或设置同名系统环境变量。'
    }

    return $args
}

# ---------- 解析平台 ----------
function Resolve-Platform {
    if ($Platform -ne 'auto') { return $Platform }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    if ($IsLinux) { return 'linux' }
    Fail '无法识别当前平台，请通过 -Platform 显式指定。'
}

# ---------- 读取应用信息 ----------
function Get-AppInfo {
    $pubspec = Join-Path $ProjectRoot 'pubspec.yaml'
    if (-not (Test-Path $pubspec)) { Fail "未找到 pubspec.yaml: $pubspec" }
    $content = Get-Content $pubspec -Raw
    $name = if ($content -match '(?m)^name:\s*(\S+)') { $Matches[1] } else { 'app' }
    $version = if ($content -match '(?m)^version:\s*([^\s+]+)') { $Matches[1] } else { '0.0.0' }
    [pscustomobject]@{ Name = $name; Version = $version }
}

# ---------- 复制目录 ----------
function Copy-Tree($src, $dst) {
    if (-not (Test-Path $src)) { Fail "构建产物不存在: $src" }
    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
}

# ---------- Windows: 收集运行时 DLL ----------
function Get-WindowsRuntimeDllPaths {
    # 与参考发布目录一致：VC++ 运行时 + UCRT(api-ms-win-*)
    $vcRuntime = @(
        'concrt140.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
        'vcruntime140.dll', 'vcruntime140_1.dll', 'ucrtbase.dll'
    )
    $apiMs = @(
        'api-ms-win-core-console-l1-1-0', 'api-ms-win-core-console-l1-2-0',
        'api-ms-win-core-datetime-l1-1-0', 'api-ms-win-core-debug-l1-1-0',
        'api-ms-win-core-errorhandling-l1-1-0', 'api-ms-win-core-file-l1-1-0',
        'api-ms-win-core-file-l1-2-0', 'api-ms-win-core-file-l2-1-0',
        'api-ms-win-core-handle-l1-1-0', 'api-ms-win-core-heap-l1-1-0',
        'api-ms-win-core-interlocked-l1-1-0', 'api-ms-win-core-libraryloader-l1-1-0',
        'api-ms-win-core-localization-l1-2-0', 'api-ms-win-core-memory-l1-1-0',
        'api-ms-win-core-namedpipe-l1-1-0', 'api-ms-win-core-processenvironment-l1-1-0',
        'api-ms-win-core-processthreads-l1-1-0', 'api-ms-win-core-processthreads-l1-1-1',
        'api-ms-win-core-profile-l1-1-0', 'api-ms-win-core-rtlsupport-l1-1-0',
        'api-ms-win-core-string-l1-1-0', 'api-ms-win-core-synch-l1-1-0',
        'api-ms-win-core-synch-l1-2-0', 'api-ms-win-core-sysinfo-l1-1-0',
        'api-ms-win-core-timezone-l1-1-0', 'api-ms-win-core-util-l1-1-0',
        'api-ms-win-crt-conio-l1-1-0', 'api-ms-win-crt-convert-l1-1-0',
        'api-ms-win-crt-environment-l1-1-0', 'api-ms-win-crt-filesystem-l1-1-0',
        'api-ms-win-crt-heap-l1-1-0', 'api-ms-win-crt-locale-l1-1-0',
        'api-ms-win-crt-math-l1-1-0', 'api-ms-win-crt-multibyte-l1-1-0',
        'api-ms-win-crt-private-l1-1-0', 'api-ms-win-crt-process-l1-1-0',
        'api-ms-win-crt-runtime-l1-1-0', 'api-ms-win-crt-stdio-l1-1-0',
        'api-ms-win-crt-string-l1-1-0', 'api-ms-win-crt-time-l1-1-0',
        'api-ms-win-crt-utility-l1-1-0'
    ) | ForEach-Object { "$_.dll" }

    $names = $vcRuntime + $apiMs

    # 候选搜索目录：VS Redist 优先，其次系统目录
    $searchDirs = New-Object System.Collections.Generic.List[string]

    # 1) Visual Studio VC Redist（含 VC14x.CRT）
    $vsRedistRoots = @(
        'C:\Program Files\Microsoft Visual Studio',
        'C:\Program Files (x86)\Microsoft Visual Studio'
    )
    foreach ($root in $vsRedistRoots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Recurse -Directory -Filter 'Microsoft.VC*.CRT' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '\\x64\\' } |
                ForEach-Object { $searchDirs.Add($_.FullName) }
        }
    }

    # 2) Windows Kits UCRT Redist
    Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Redist\*\ucrt\DLLs\x64' -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $searchDirs.Add($_.FullName) }

    # 3) 系统目录回退
    $searchDirs.Add("$env:WINDIR\System32")
    $searchDirs.Add("$env:WINDIR\System32\downlevel")

    # 逐个解析
    $resolved = @{}
    $missing  = @()
    foreach ($name in $names) {
        $found = $null
        foreach ($dir in $searchDirs) {
            $candidate = Join-Path $dir $name
            if (Test-Path $candidate) { $found = $candidate; break }
        }
        if ($found) { $resolved[$name] = $found } else { $missing += $name }
    }

    [pscustomobject]@{ Resolved = $resolved; Missing = $missing }
}

function Publish-Windows($app, $outDir) {
    Write-Step '构建 Windows Release...'
    $dartDefines = Get-DartDefineArgs
    & flutter build windows --release @dartDefines
    if ($LASTEXITCODE -ne 0) { Fail 'flutter build windows 失败' }

    $releaseDir = Join-Path $ProjectRoot 'build\windows\x64\runner\Release'
    Copy-Tree $releaseDir $outDir
    Write-Ok "已复制构建产物到 $outDir"

    Write-Step '打包运行时 DLL（VC++ / UCRT）...'
    $dll = Get-WindowsRuntimeDllPaths
    $copied = 0
    foreach ($name in $dll.Resolved.Keys) {
        $target = Join-Path $outDir $name
        if (-not (Test-Path $target)) {
            Copy-Item $dll.Resolved[$name] $target -Force
            $copied++
        }
    }
    Write-Ok "已补充运行时 DLL：$copied 个"
    if ($dll.Missing.Count -gt 0) {
        Write-Warn2 "以下 DLL 未在本机找到（多数 Windows 10/11 已内置，可忽略）：`n    $($dll.Missing -join ', ')"
    }
}

function Publish-MacOS($app, $outDir) {
    Write-Step '构建 macOS Release...'
    $dartDefines = Get-DartDefineArgs
    & flutter build macos --release @dartDefines
    if ($LASTEXITCODE -ne 0) { Fail 'flutter build macos 失败' }

    $appBundle = Get-ChildItem (Join-Path $ProjectRoot 'build/macos/Build/Products/Release') -Filter '*.app' -Directory |
        Select-Object -First 1
    if (-not $appBundle) { Fail '未找到 .app 产物' }
    if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    Copy-Item $appBundle.FullName (Join-Path $outDir $appBundle.Name) -Recurse -Force
    Write-Ok "已复制 $($appBundle.Name) 到 $outDir"
}

function Publish-Linux($app, $outDir) {
    Write-Step '构建 Linux Release...'
    $dartDefines = Get-DartDefineArgs
    & flutter build linux --release @dartDefines
    if ($LASTEXITCODE -ne 0) { Fail 'flutter build linux 失败' }

    $bundle = Join-Path $ProjectRoot 'build/linux/x64/release/bundle'
    Copy-Tree $bundle $outDir
    Write-Ok "已复制构建产物到 $outDir"
}

# ============ 主流程 ============
$target = Resolve-Platform
$app = Get-AppInfo
Write-Step "应用: $($app.Name)  版本: $($app.Version)  目标平台: $target"

if ($Clean) {
    Write-Step 'flutter clean...'
    & flutter clean | Out-Null
}

$pkgName = "$($app.Name)-$target-v$($app.Version)"
$outDir  = Join-Path $DistRoot $pkgName

switch ($target) {
    'windows' { Publish-Windows $app $outDir }
    'macos'   { Publish-MacOS   $app $outDir }
    'linux'   { Publish-Linux   $app $outDir }
}

if ($Zip) {
    Write-Step '压缩为 zip...'
    $zipPath = "$outDir.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $outDir '*') -DestinationPath $zipPath -Force
    Write-Ok "已生成压缩包: $zipPath"
}

Write-Host ''
Write-Ok "发布完成 -> $outDir"
