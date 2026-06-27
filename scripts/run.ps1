#!/usr/bin/env pwsh
<#
.SYNOPSIS
    从本地 .env 读取配置后运行 mind。

.DESCRIPTION
    Flutter 应用不能直接把项目根目录 .env 当作运行时配置读取。
    本脚本会读取 .env，并把 DeepSeek 配置转换为 --dart-define。
    这样本地运行和发布脚本使用同一套密钥注入方式。

.PARAMETER Device
    Flutter 目标设备，默认 windows。也可以传 android。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\run.ps1
    powershell -ExecutionPolicy Bypass -File .\scripts\run.ps1 -Device android
#>

[CmdletBinding()]
param(
    [string]$Device = "windows",

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArgs
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $OutputEncoding = [System.Text.UTF8Encoding]::new()
} else {
    $OutputEncoding = New-Object System.Text.UTF8Encoding
}
[Console]::OutputEncoding = $OutputEncoding

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
$EnvFile     = Join-Path $ProjectRoot ".env"

function Write-Warn2($msg) { Write-Host "[!]  $msg" -ForegroundColor Yellow }

function Read-LocalEnv {
    $values = @{}
    if (-not (Test-Path $EnvFile)) { return $values }

    foreach ($line in Get-Content $EnvFile) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) { continue }

        $idx = $trimmed.IndexOf("=")
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
    $keys = @("DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_MODEL")
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

    $envApiKey = [Environment]::GetEnvironmentVariable("DEEPSEEK_API_KEY")
    $hasApiKey = $localEnv.ContainsKey("DEEPSEEK_API_KEY") -or -not [string]::IsNullOrWhiteSpace($envApiKey)
    if (-not $hasApiKey) {
        Write-Warn2 "Missing DEEPSEEK_API_KEY. Configure it in .env."
    }

    return $args
}

Set-Location $ProjectRoot
$dartDefines = Get-DartDefineArgs
& flutter run -d $Device @dartDefines @FlutterArgs
