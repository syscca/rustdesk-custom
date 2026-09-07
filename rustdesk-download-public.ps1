#Requires -Version 5.1
<#
.SYNOPSIS
    RustDesk Release 安装包一键下载（私有仓库需 Token，公共仓免 Token）。

.DESCRIPTION
    从 GitHub 私仓 Release 下载构建产物：
    - 默认自动识别当前平台（Windows x64 / ARM64 / macOS / Linux）并下载推荐安装包；
    - 无参数运行时进入交互菜单（列出全部资产，回车选推荐项）；
    - 支持 -Asset 关键字/通配符筛选、-All 全量下载（含源码包）、-List 仅查看清单；
    - GitHub 自动生成的 Source code (zip / tar.gz) 源码包也已补入清单。

.PARAMETER Token
    可选。GitHub PAT（classic，需 repo scope）。访问私有仓库必填；公共仓可省略（匿名模式）。

.PARAMETER Repo
    目标仓库（默认 your-github-username/rustdesk）。支持 owner/repo 或 GitHub 完整 URL
    （如 https://github.com/your-github-username/rustdesk/releases）；URL 含 /releases/tag/<tag>
    时自动识别 tag（显式 -Tag 优先）。

.PARAMETER Tag
    指定 Release tag（如 v1.4.9）。默认取最新一次 Release（含 prerelease）。

.PARAMETER Asset
    资产名关键字或通配符（如 apk、*x86_64*windows*.exe），匹配多个则全部下载。

.PARAMETER OutDir
    下载目录（默认当前目录），不存在自动创建。

.PARAMETER List
    仅列出资产清单，不下载。

.PARAMETER All
    下载全部资产。

.EXAMPLE
    .\rustdesk-download.ps1 -Token ghp_xxx
.EXAMPLE
    .\rustdesk-download.ps1 -Token ghp_xxx -Tag v1.4.9 -List
.EXAMPLE
    .\rustdesk-download.ps1 -Token ghp_xxx -Asset *x86_64*windows*.exe -OutDir D:\dist
.EXAMPLE
    .\rustdesk-download.ps1 -Token ghp_xxx -Repo https://github.com/someone/other/releases/tag/v1.0.0
.EXAMPLE
    .\rustdesk-download.ps1 -Token ghp_xxx -All
.EXAMPLE
    .\rustdesk-download.ps1 -Repo rustdesk/rustdesk -List
    # 公共仓无需 Token（匿名模式，API 限流 60 次/小时）
#>
param(
    [string]$Token = "",
    [string]$Repo = "your-github-username/rustdesk",
    [string]$Tag = "",
    [string]$Asset = "",
    [string]$OutDir = ".",
    [switch]$List,
    [switch]$All
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 规范化 -Repo：支持 owner/repo 或 GitHub 完整 URL（http/https、ssh、.git、/releases... 均可）
# URL 含 /releases/tag/<tag> 时自动识别为 -Tag（显式 -Tag 优先）
if ($Repo -match '^(?:https?://)?(?:[^/\s@]+@)?(?:github\.com[/:])?([^/\s]+)/([^/\s]+?)(?:\.git)?(?:/releases(?:/tag/([^/\s]+?))?)?/?$') {
    $Repo = "$($Matches[1])/$($Matches[2])"
    if (-not $Tag -and $Matches[3]) { $Tag = $Matches[3] }
}

$apiHeaders = @{
    Accept        = "application/vnd.github+json"
    "User-Agent"  = "rustdesk-download"
}
if ($Token) { $apiHeaders.Authorization = "Bearer $Token" }

# ---------- 工具 ----------
function Find-AssetIndex {
    param($Items, [string]$Pattern)
    for ($i = 0; $i -lt $Items.Count; $i++) { if ($Items[$i].name -match $Pattern) { return $i } }
    return -1
}

function Format-AssetList {
    param($Items, [int]$Pick = -1)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $mark = if ($i -eq $Pick) { "   <= 推荐" } else { "" }
        $sizeText = if ($Items[$i].size -gt 0) { "  ({0:N1} MB)" -f ($Items[$i].size / 1MB) } else { "  (源码包)" }
        ("{0,2}. {1}{2}{3}" -f ($i + 1), $Items[$i].name, $sizeText, $mark) | Write-Host
    }
}

# 分块下载 + 进度条（避免 Invoke-WebRequest 大文件慢、curl stderr 红字终止脚本等问题）
function Save-File {
    param([string]$Url, [string]$Dest, [string]$Name, [long]$Expected = 0, [string]$Bearer = "", [string]$Accept = "")
    # 手动跟随跳转：GitHub 自有域名保留 Token；第三方存储（如 S3）不外发 Token
    # 注意：Accept 需按端点显式传入（资产端点要 application/octet-stream；
    # zipball/tarball 端点带该头会被拒绝 415），默认不发送
    $url = $Url
    $resp = $null
    for ($hop = 0; $hop -lt 6; $hop++) {
        $req = [Net.HttpWebRequest]::Create($url)
        $req.AllowAutoRedirect = $false
        $req.UserAgent = "rustdesk-download"
        if ($Bearer) {
            if (([Uri]$url).Host -match 'github\.com$') {
                $req.Headers.Add([Net.HttpRequestHeader]::Authorization, "Bearer $Bearer")
            } else {
                $Bearer = ""
            }
        }
        if ($Accept) { $req.Accept = $Accept }
        try { $resp = $req.GetResponse() } catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 401) { throw "下载失败 401：Token 无效或已过期" }
            if ($code -eq 404) { throw "下载失败 404：资源不存在或服务端临时故障" }
            $msg = "$($_.Exception.Message)"
            if ($script:Token) { $msg = $msg.Replace($script:Token, "***") }
            throw ("下载失败：{0}" -f $msg)
        }
        $loc = $resp.Headers["Location"]
        if (-not $loc) { break }
        $resp.Close()
        $url = $loc
        if ($hop -eq 5) { throw "重定向次数过多：$Url" }
    }
    $stream = $resp.GetResponseStream()
    $total = if ($resp.ContentLength -gt 0) { $resp.ContentLength } else { $Expected }
    $fs = [IO.File]::Create($Dest)
    $buf = New-Object byte[] (4MB)
    $read = [long]0
    try {
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            $fs.Write($buf, 0, $n)
            $read += $n
            if ($total -gt 0) {
                Write-Progress -Activity "下载 $Name" -Status ("{0:N1} / {1:N1} MB" -f ($read / 1MB), ($total / 1MB)) -PercentComplete ([Math]::Min(100, [int]($read * 100 / $total)))
            } else {
                Write-Progress -Activity "下载 $Name" -Status ("已下载 {0:N1} MB" -f ($read / 1MB))
            }
        }
    } finally {
        $fs.Dispose(); $stream.Dispose(); $resp.Close()
        Write-Progress -Activity "下载 $Name" -Completed
    }
}

# 源码包下载：zipball/tarball 接口首选（重试一次）+ github.com archive 兜底 + 魔数校验
# （GitHub 偶发 Unicorn 错误页 / codeload 受网络干扰时，绝不把错误响应存成“源码包”）
function Save-SourceArchive {
    param([string]$SourceUrl, [string]$Kind, [string]$Dest)
    $fallback = ($SourceUrl -replace '^https://api\.github\.com/repos/', 'https://github.com/') -replace '/zipball/', '/archive/refs/tags/' -replace '/tarball/', '/archive/refs/tags/'
    $fallback += $(if ($Kind -eq "zip") { ".zip" } else { ".tar.gz" })
    $magic = if ($Kind -eq "zip") { @(0x50, 0x4B) } else { @(0x1F, 0x8B) }
    $kindText = if ($Kind -eq "zip") { "zip" } else { "tar.gz" }
    $urls = @($SourceUrl, $SourceUrl, $fallback)
    $lastErr = $null
    foreach ($u in $urls) {
        try {
            Save-File -Url $u -Dest $Dest -Name (Split-Path -Leaf $Dest) -Expected 0 -Bearer $Token
        } catch {
            $lastErr = $_.Exception.Message
            Write-Host "  [warn] $lastErr" -ForegroundColor Yellow
            continue
        }
        # 魔数校验：zip -> PK，tar.gz -> gzip
        $fs = [IO.File]::OpenRead($Dest)
        try {
            $head = New-Object byte[] 2
            $null = $fs.Read($head, 0, 2)
        } finally { $fs.Dispose() }
        if ($head[0] -eq $magic[0] -and $head[1] -eq $magic[1]) { return }
        Remove-Item $Dest -Force
        Write-Host "  [warn] 响应不是有效的 $kindText 文件，切换备用地址重试 ..." -ForegroundColor Yellow
    }
    throw "源码包下载失败（已含重试与备用地址）：$lastErr`n         可能是 codeload.github.com 不可达或网络干扰，请稍后重试或配置代理。"
}

function Save-Asset {
    param($AssetItem, [string]$DestDir)
    $fileName = if ($AssetItem.fileName) { $AssetItem.fileName } else { $AssetItem.name }
    $dest = Join-Path $DestDir $fileName
    $sizeText = if ($AssetItem.size -gt 0) { " ({0:N1} MB)" -f ($AssetItem.size / 1MB) } else { "" }
    Write-Host "  [down] $($AssetItem.name)$sizeText"

    if ($AssetItem.sourceUrl) {
        # 源码包：zipball/tarball 接口 + archive 兜底 + 魔数校验
        Save-SourceArchive -SourceUrl $AssetItem.sourceUrl -Kind $AssetItem.srcKind -Dest $dest
    } else {
        # 常规资产：先解析 GitHub 的 302 跳转，得到预签名直链（Token 不外发给第三方存储）
        $apiUrl = "https://api.github.com/repos/$Repo/releases/assets/$($AssetItem.id)"
        $req = [Net.HttpWebRequest]::Create($apiUrl)
        $req.AllowAutoRedirect = $false
        $req.UserAgent = "rustdesk-download"
        $req.Accept = "application/octet-stream"
        if ($Token) { $req.Headers.Add([Net.HttpRequestHeader]::Authorization, "Bearer $Token") }
        $direct = $null
        try {
            $resp = $req.GetResponse()
            $direct = $resp.Headers["Location"]
            $resp.Close()
        } catch {
            $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
            if ($code -eq 401) { throw "下载失败 401：Token 无效或已过期" }
            if ($code -eq 404) { throw "下载失败 404：资产不存在（私仓需 -Token）" }
            $msg = "$($_.Exception.Message)"
            if ($Token) { $msg = $msg.Replace($Token, "***") }
            throw ("解析下载链接失败：{0}" -f $msg)
        }

        if ($direct) { Save-File -Url $direct -Dest $dest -Name $AssetItem.name -Expected $AssetItem.size }
        else { Save-File -Url $apiUrl -Dest $dest -Name $AssetItem.name -Expected $AssetItem.size -Bearer $Token -Accept "application/octet-stream" }
    }

    $fi = Get-Item $dest
    if ($AssetItem.size -gt 0 -and $fi.Length -ne $AssetItem.size) {
        Write-Host "  [warn] 大小校验不一致：实际 $($fi.Length) B / 预期 $($AssetItem.size) B" -ForegroundColor Yellow
    } else {
        Write-Host "  [ok] $dest" -ForegroundColor Green
    }
    return $dest
}

# ---------- 1. 获取 Release ----------
$authText = if ($Token) { "Token 认证" } else { "匿名模式（公共仓）" }
Write-Host "==== RustDesk Release 下载 ($Repo)  [$authText] ====" -ForegroundColor Cyan
$path = if ($Tag) { "releases/tags/$Tag" } else { "releases?per_page=10" }
try {
    $rels = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/$path" -Headers $apiHeaders)
    # 兼容 PS 5.1/7 对 JSON 数组的不同包装方式：统一摊平为 Release 对象数组
    while ($rels.Count -gt 0 -and $rels[0] -is [System.Array]) { $rels = @($rels[0]) }
} catch {
    $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
    if ($code -eq 401) { throw "GitHub API 401：Token 无效或已过期" }
    if ($code -eq 404) { throw "GitHub API 404：仓库 $Repo 或 Tag '$Tag' 不存在；若是私有仓库，请提供 -Token（classic PAT，repo scope）" }
    $msg = "$($_.Exception.Message)"
    if ($Token) { $msg = $msg.Replace($Token, "***") }
    throw "获取 Release 失败：$msg"
}
if ($rels.Count -eq 0) { throw "未找到任何 Release" }
$release = $rels[0]
$assets = @($release.assets)
# GitHub 自动生成的源码包不在 assets API 列表中，补进清单（菜单 / -All 可下载）
$assets += [PSCustomObject]@{
    name      = "Source code (zip)"
    size      = 0
    id        = $null
    fileName  = "$($release.tag_name)-source-code.zip"
    srcKind   = "zip"
    sourceUrl = "https://api.github.com/repos/$Repo/zipball/$($release.tag_name)"
}
$assets += [PSCustomObject]@{
    name      = "Source code (tar.gz)"
    size      = 0
    id        = $null
    fileName  = "$($release.tag_name)-source-code.tar.gz"
    srcKind   = "targz"
    sourceUrl = "https://api.github.com/repos/$Repo/tarball/$($release.tag_name)"
}

$pubAt = $release.published_at
if ($pubAt -is [datetime]) {
    $pubAt = $pubAt.ToString("yyyy-MM-dd HH:mm")
} elseif ($pubAt) {
    $d = [datetime]::MinValue
    if ([datetime]::TryParse("$pubAt", [ref]$d)) { $pubAt = $d.ToString("yyyy-MM-dd HH:mm") }
}
Write-Host ("Release: {0}  [{1}]  {2}" -f $release.tag_name, ($(if ($release.prerelease) { "prerelease" } else { "stable" })), $pubAt) -ForegroundColor DarkGray

# ---------- 2. 平台自动推荐 ----------
# 兼容两种命名：自建 CI（x86_64-pc-windows-msvc.exe）与官方仓（x86_64.exe）；排除 sciter 变体
$isWindowsPS = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$autoIndex = -1
if ($isWindowsPS) {
    $pats = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") {
        @('(?i)^(?!.*sciter).*aarch64.*windows.*\.exe$', '(?i)^(?!.*sciter).*aarch64.*\.exe$')
    } else {
        @('(?i)^(?!.*sciter).*x86_64.*windows.*\.exe$', '(?i)^(?!.*sciter).*x86_64.*\.exe$')
    }
    foreach ($p in $pats) { if ($autoIndex -lt 0) { $autoIndex = Find-AssetIndex $assets $p } }
    if ($autoIndex -lt 0) { $autoIndex = Find-AssetIndex $assets '(?i)^(?!.*sciter).*windows.*(exe|msi)$' }
} elseif ($IsMacOS) {
    $autoIndex = Find-AssetIndex $assets '(?i)^(?!.*sciter).*aarch64.*\.dmg$'
    if ($autoIndex -lt 0) { $autoIndex = Find-AssetIndex $assets '(?i)^(?!.*sciter).*x86_64.*\.dmg$' }
} elseif ($IsLinux) {
    $autoIndex = Find-AssetIndex $assets '(?i)^(?!.*sciter).*x86_64.*\.deb$'
    if ($autoIndex -lt 0) { $autoIndex = Find-AssetIndex $assets '(?i)^(?!.*sciter).*aarch64.*\.deb$' }
}

# ---------- 3. 选择资产 ----------
if ($List) {
    Format-AssetList $assets $autoIndex
    Write-Host "`n提示：-Asset <关键字|通配符> 筛选下载；-All 下载全部；不带参数进入交互菜单" -ForegroundColor DarkGray
    return
}

$selected = @()
if ($All) {
    $selected = $assets
} elseif ($Asset) {
    $pattern = if ($Asset -match '[*?]') { $Asset } else { "*$Asset*" }
    $selected = @($assets | Where-Object { $_.name -like $pattern })
    if ($selected.Count -eq 0) { throw "没有资产匹配 -Asset '$Asset'（用 -List 查看清单）" }
} else {
    Format-AssetList $assets $autoIndex
    $hint = if ($autoIndex -ge 0) { "，回车 = 推荐 $($assets[$autoIndex].name)" } else { "" }
    $answer = Read-Host "输入要下载的序号$hint"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        if ($autoIndex -lt 0) { throw "当前平台无自动推荐，请输入序号" }
        $selected = @($assets[$autoIndex])
    } else {
        $idx = 0
        if (-not [int]::TryParse($answer, [ref]$idx) -or $idx -lt 1 -or $idx -gt $assets.Count) { throw "无效序号：$answer" }
        $selected = @($assets[$idx - 1])
    }
}

# ---------- 4. 下载 ----------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$destDir = (Get-Item $OutDir).FullName

$done = @()
foreach ($a in $selected) {
    $p = Save-Asset -AssetItem $a -DestDir $destDir
    if ($p) { $done += $p }
}

Write-Host "`n==== 完成：已下载 $($done.Count) 个文件到 $destDir ====" -ForegroundColor Green
