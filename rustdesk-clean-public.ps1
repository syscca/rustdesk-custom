#Requires -Version 5.1
<#
.SYNOPSIS
    RustDesk Windows 残留清理脚本（服务 / 程序 / 配置 / 注册表 / 防火墙 / 快捷方式）。

.DESCRIPTION
    卸载或重装自定义 RustDesk 前，一键清理本机残留：
    - 默认（无参数）：交互确认后全部清理（含设备 ID、密码、服务器配置，不可恢复）；
    - -List      ：只读扫描并显示本机残留，不做任何修改；
    - -KeepConfig：清理程序与服务，但保留设备 ID/密码/服务器配置（升级重装用）；
    - -ConfigOnly：仅清理配置与身份（保留程序与服务，清理后自动重启服务）；
    - -Force     ：跳过交互确认，直接执行。

.EXAMPLE
    .\rustdesk-clean.ps1 -List
.EXAMPLE
    .\rustdesk-clean.ps1 -Force
.EXAMPLE
    .\rustdesk-clean.ps1 -KeepConfig -Force
#>
param(
    [switch]$Force,
    [switch]$ConfigOnly,
    [switch]$KeepConfig,
    [switch]$List
)

$ErrorActionPreference = "Continue"

# ---------- 管理员自提权（-List 只读可免） ----------
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $List) {
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    foreach ($sw in @("-Force", "-ConfigOnly", "-KeepConfig")) {
        $v = Get-Variable -Name $sw.TrimStart("-") -ErrorAction SilentlyContinue
        if ($v -and $v.Value) { $argList += " $sw" }
    }
    Write-Host "需要管理员权限，正在请求提权 ..." -ForegroundColor Yellow
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit
}

# ---------- 清理目标定义 ----------
$svcName = "RustDesk"
$procName = "rustdesk"

# 程序目录（安装目录 + 用户级目录）
$programDirs = @(
    "$env:ProgramFiles\RustDesk",
    "${env:ProgramFiles(x86)}\RustDesk",
    "$env:LOCALAPPDATA\RustDesk"
)
# 配置目录（用户模式 + 服务模式，含设备 ID/密码/服务器配置）
$configDirs = @(
    "$env:APPDATA\RustDesk",
    "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\RustDesk"
)
# 注册表：配置类（保留 ID/密码时跳过）与程序类
$regConfigKeys = @("HKCU:\Software\RustDesk")
$regProgramKeys = @(
    "HKLM:\SOFTWARE\RustDesk",
    "HKLM:\SOFTWARE\WOW6432Node\RustDesk",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\RustDesk"
)
# 快捷方式
$shortcuts = @(
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\RustDesk.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\RustDesk.lnk",
    "$env:PUBLIC\Desktop\RustDesk.lnk",
    "$env:USERPROFILE\Desktop\RustDesk.lnk"
)
# 便携版开机自启 Run 键值
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValue = "RustDesk"

function Remove-Target {
    param([string]$Path)
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) {
        # 权限不足时接管所有权并授予 Administrators 完全控制后重试（服务配置目录常见）
        cmd.exe /c "echo Y| takeown /F `"$Path`" /R" | Out-Null
        icacls.exe "$Path" /grant "*S-1-5-32-544:(OI)(CI)F" /T /C | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $Path -ErrorAction SilentlyContinue) {
        Write-Host "  [warn] 未能完全删除 $Path（文件可能被占用，重启后重跑本脚本）" -ForegroundColor Yellow
    } else {
        Write-Host "  [ok] $Path" -ForegroundColor Green
    }
}

# ---------- 1. 扫描 ----------
Write-Host "==== RustDesk 残留扫描 ====" -ForegroundColor Cyan

$svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
$procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
$fwRules = @()
try { $fwRules = @(Get-NetFirewallRule -DisplayName "RustDesk*" -ErrorAction SilentlyContinue) } catch {}

$foundProgram = @($programDirs | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue })
$foundConfig = @($configDirs | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue })
$foundRegCfg = @($regConfigKeys | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue })
$foundRegPrg = @($regProgramKeys | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue })
$foundShortcuts = @($shortcuts | Where-Object { Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue })
$hasRunEntry = $false
try { $hasRunEntry = $null -ne (Get-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue) } catch {}

if ($svc) { Write-Host "  [服务] $($svc.Name)（$($svc.DisplayName)）- $($svc.Status)" -ForegroundColor Cyan }
if ($procs.Count -gt 0) { Write-Host "  [进程] $($procs.Count) 个 rustdesk 进程正在运行" -ForegroundColor Cyan }
foreach ($d in $foundProgram) { Write-Host "  [程序目录] $d" -ForegroundColor Cyan }
foreach ($d in $foundConfig) { Write-Host "  [配置目录] $d" -ForegroundColor Cyan }
foreach ($k in $foundRegCfg) { Write-Host "  [注册表-配置] $k" -ForegroundColor Cyan }
foreach ($k in $foundRegPrg) { Write-Host "  [注册表-程序] $k" -ForegroundColor Cyan }
foreach ($s in $foundShortcuts) { Write-Host "  [快捷方式] $s" -ForegroundColor Cyan }
if ($hasRunEntry) { Write-Host "  [自启动] $runKey（值：$runValue）" -ForegroundColor Cyan }
if ($fwRules.Count -gt 0) { Write-Host "  [防火墙规则] $($fwRules.Count) 条（RustDesk*）" -ForegroundColor Cyan }

$total = $foundProgram.Count + $foundConfig.Count + $foundRegCfg.Count + $foundRegPrg.Count + $foundShortcuts.Count + $fwRules.Count +
    $(if ($svc) { 1 } else { 0 }) + $(if ($hasRunEntry) { 1 } else { 0 }) + $(if ($procs.Count -gt 0) { 1 } else { 0 })
if (-not $isAdmin) {
    Write-Host "  [提示] 当前非管理员运行，系统服务配置目录可能未完整显示" -ForegroundColor DarkGray
}
if ($total -eq 0) {
    Write-Host "`n未发现任何 RustDesk 残留，无需清理。" -ForegroundColor Green
    return
}
if ($List) {
    Write-Host "`n[-List 只读模式，未做任何修改]" -ForegroundColor DarkGray
    return
}

# ---------- 2. 模式确认 ----------
if ($ConfigOnly -and $KeepConfig) { throw "参数冲突：-ConfigOnly 与 -KeepConfig 不可同时使用" }
$modeText = if ($ConfigOnly) { "仅清理配置与身份（保留程序与服务，清理后自动重启服务）" }
    elseif ($KeepConfig) { "清理程序与服务，保留设备 ID/密码/服务器配置（升级重装用）" }
    else { "全部清理（含设备 ID/密码/服务器配置，不可恢复）" }
Write-Host "`n清理模式：$modeText" -ForegroundColor Yellow
if (-not $Force) {
    $answer = Read-Host "确认执行清理？(y/N)"
    if ($answer -notmatch '^(y|Y|yes)$') { Write-Host "已取消。" -ForegroundColor DarkGray; return }
}

# ---------- 3. 执行清理 ----------
Write-Host "`n==== 开始清理 ====" -ForegroundColor Cyan
$step = 1

# 进程与服务
if (-not $ConfigOnly) {
    if ($procs.Count -gt 0) {
        Write-Host "  [$step] 结束 $($procs.Count) 个 rustdesk 进程 ..."
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        $step++
    }
    if ($svc) {
        Write-Host "  [$step] 停止并删除服务 $svcName ..."
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        sc.exe delete $svcName | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  [ok] 服务已删除" -ForegroundColor Green }
        else { Write-Host "  [warn] sc.exe delete 返回码 $LASTEXITCODE" -ForegroundColor Yellow }
        $step++
    }
} else {
    if ($svc) {
        Write-Host "  [$step] 临时停止服务 $svcName（清理完成后自动重启）..."
        Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        $step++
    }
}

# 配置目录与配置注册表（-KeepConfig 时保留）
if (-not $KeepConfig) {
    foreach ($d in $foundConfig) {
        Write-Host "  [$step] 删除配置目录 ..."
        Remove-Target $d
        $step++
    }
    foreach ($k in $foundRegCfg) {
        Write-Host "  [$step] 删除配置注册表 $k ..."
        Remove-Target $k
        $step++
    }
} else {
    Write-Host "  [-] 按要求保留配置目录与配置注册表（设备 ID/密码/服务器配置）" -ForegroundColor DarkGray
}

# 程序目录与程序注册表（-ConfigOnly 时保留）
if (-not $ConfigOnly) {
    foreach ($d in $foundProgram) {
        Write-Host "  [$step] 删除程序目录 ..."
        Remove-Target $d
        $step++
    }
    foreach ($k in $foundRegPrg) {
        Write-Host "  [$step] 删除注册表 $k ..."
        Remove-Target $k
        $step++
    }
}

# 快捷方式 / 自启动 / 防火墙（-ConfigOnly 时保留）
if (-not $ConfigOnly) {
    foreach ($s in $foundShortcuts) {
        Write-Host "  [$step] 删除快捷方式 $s ..."
        Remove-Target $s
        $step++
    }
    if ($hasRunEntry) {
        Write-Host "  [$step] 移除自启动 Run 键值 ..."
        Remove-ItemProperty -Path $runKey -Name $runValue -ErrorAction SilentlyContinue
        Write-Host "  [ok] $runValue" -ForegroundColor Green
        $step++
    }
    if ($fwRules.Count -gt 0) {
        Write-Host "  [$step] 删除 $($fwRules.Count) 条防火墙规则（RustDesk*）..."
        $fwRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-Host "  [ok] 防火墙规则已删除" -ForegroundColor Green
        $step++
    }
}

# ConfigOnly 模式：恢复服务运行
if ($ConfigOnly -and $svc -and $svc.Status -eq "Running") {
    Write-Host "  [$step] 重启服务 $svcName ..."
    Start-Service -Name $svcName -ErrorAction SilentlyContinue
    $step++
}

# ---------- 4. 完成 ----------
Write-Host "`n==== 清理完成 ====" -ForegroundColor Green
if ($ConfigOnly) {
    Write-Host "配置已重置：下次启动将重新生成设备 ID 与密码（服务器配置按客户端内置或重新填写）。"
} elseif ($KeepConfig) {
    Write-Host "已保留设备 ID/密码/服务器配置；重新安装自定义客户端后自动生效。"
} else {
    Write-Host "本机 RustDesk 痕迹已全部清除；重新安装自定义客户端后将生成全新设备 ID。"
}
if (-not $Force) {
    Read-Host "`n按回车键退出"
}
