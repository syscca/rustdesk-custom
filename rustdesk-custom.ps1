#Requires -Version 5.1
<#
.SYNOPSIS
    RustDesk 自定义构建一键脚本：克隆官方源码 -> 注入自建服务器/公钥/固定密码/访问控制/禁用更新
    -> 修复私有仓库 CI -> 推送到 GitHub 私仓 -> 自动触发 Actions 在线构建。

.DESCRIPTION
    全流程幂等：已应用过的补丁自动跳过，可安全重复执行。
    支持指定任意官方版本（tag）、任意 GitHub 组织/帐号、任意自建服务器配置。

.PARAMETER Token
    必填。GitHub PAT（classic token，需对目标私仓有 Contents 写权限）。

.PARAMETER Version
    官方源码 tag（不带 v 前缀），例如 1.4.9 或 1.4.2。脚本会在私仓打 tag v<Version>。

.PARAMETER Tag
    覆盖目标 tag 名（默认 v<Version>）。

.PARAMETER TargetOrg
    目标 GitHub 组织或用户名，仓库将推送到 https://github.com/<TargetOrg>/<repo>。

.PARAMETER CommitUser / CommitEmail
    Invoke-Git 提交作者身份（默认 <TargetOrg> / <TargetOrg>@users.noreply.github.com）。

.PARAMETER IdServer
    自建 hbbs/rendezvous（ID）服务器地址，可带端口，如 your-server.example.com:21116。

.PARAMETER RelayServer
    自建 hbbr 中继服务器地址，可带端口，如 your-server.example.com:21117。

.PARAMETER ApiServer
    自建 API 服务器地址（Web 控制台/地址簿）。

.PARAMETER PublicKey
    服务器公钥（hbbs -k _ 输出的公钥）。

.PARAMETER PresetPassword
    内置固定永久密码。

.PARAMETER LockPassword
    开关：开启后客户端无法在 UI 修改永久密码（强制使用内置密码）。

.PARAMETER AccessMode
    接入权限：full（完全）/ input（输入）/ view（仅查看）。

.PARAMETER ApproveMode
    确认模式：password（密码）/ input（输入）/ allow（允许）/ refuse（拒绝）。

.PARAMETER VerificationMethod
    验证方式：use-permanent-password / use-once-password / use-both。

.PARAMETER HideCm
    开关：隐藏连接管理窗口（静默接入）。

.PARAMETER EnableCheckUpdate
    开关：允许检查与自动更新（默认禁用）。

.PARAMETER ShowScamWarning
    开关：显示移动端防诈 12 秒倒计时提示（默认隐藏）。

.PARAMETER UpstreamRepo
    源仓库（默认官方 rustdesk/rustdesk）。

.PARAMETER TargetRepoName / TargetHbRepoName
    目标主仓库名 / 子模块仓库名（默认 rustdesk / hbb_common）。

.EXAMPLE
    .\rustdesk-custom.ps1 -Token ghp_xxx
.EXAMPLE
    .\rustdesk-custom.ps1 -Token ghp_xxx -Version 1.4.2 -IdServer my.example.com -PublicKey "xxx=" -PresetPassword mypass
.EXAMPLE
    .\rustdesk-custom.ps1 -Token ghp_xxx -TargetOrg myuser -CommitUser "My Name" -CommitEmail me@example.com -LockPassword
#>
param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Version = "1.4.9",
    [string]$Tag = "v1.4.9",
    [string]$TargetOrg = "your-github-username",
    [string]$CommitUser = "your-github-username",
    [string]$CommitEmail = "your-email@example.com",
    [string]$IdServer = "your-server.example.com:21116",
    [string]$RelayServer = "your-server.example.com:21117",
    [string]$ApiServer = "http://your-server.example.com:21114",
    [string]$PublicKey = "YOUR_SERVER_PUBLIC_KEY_BASE64",
    [string]$PresetPassword = "YourPasswordHere",
    [switch]$LockPassword,
    [ValidateSet("full","input","view")][string]$AccessMode = "full",
    [ValidateSet("password","input","allow","refuse")][string]$ApproveMode = "password",
    [ValidateSet("use-permanent-password","use-once-password","use-both")][string]$VerificationMethod = "use-both",
    [bool]$HideCm = $true,
    [switch]$EnableCheckUpdate,
    [switch]$ShowScamWarning,
    [string]$UpstreamRepo = "https://github.com/rustdesk/rustdesk",
    [string]$TargetRepoName = "rustdesk",
    [string]$TargetHbRepoName = "hbb_common",
    [string]$SubmoduleToken = ""
)

$ErrorActionPreference = "Stop"

# 规范化版本与 tag
$checkoutRef = $Version
if ([string]::IsNullOrEmpty($Tag)) { $customTag = "v$Version" } else { $customTag = $Tag }

# 默认提交身份
if ([string]::IsNullOrEmpty($CommitUser))  { $CommitUser  = $TargetOrg }
if ([string]::IsNullOrEmpty($CommitEmail)) { $CommitEmail = "$TargetOrg@users.noreply.github.com" }

# 布尔设置 -> 配置值
$optEnableCheckUpdate = if ($EnableCheckUpdate) { "Y" } else { "N" }
$optShowScamWarning   = if ($ShowScamWarning)   { "Y" } else { "N" }
$optHideCm            = if ($HideCm)            { "Y" } else { "N" }

# 子模块拉取 token：独立则用独立 token，否则复用主 token
if ([string]::IsNullOrEmpty($SubmoduleToken)) { $SubmoduleToken = $Token }

$workRoot  = Join-Path (Get-Location) "rustdesk-custom-$Version"
$hbDir     = Join-Path $workRoot "libs\hbb_common"
$ghHeaders = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json"; "Content-Type" = "application/json"; "User-Agent" = "rustdesk-custom" }

Write-Host "==== RustDesk custom build for $IdServer (base $Version -> tag $customTag) ====" -ForegroundColor Cyan
Write-Host "  relay: $RelayServer  api: $ApiServer" -ForegroundColor DarkGray
Write-Host "  target: $TargetOrg/$TargetRepoName + $TargetOrg/$TargetHbRepoName" -ForegroundColor DarkGray
Write-Host "  access=$AccessMode  approve=$ApproveMode  verify=$VerificationMethod  hide-cm=$optHideCm  lock-pwd=$($LockPassword.IsPresent)  update=$optEnableCheckUpdate" -ForegroundColor DarkGray

# ---------- 通用工具 ----------
# 包装 git 调用：临时关闭 Stop 模式，避免 native stderr 触发 NativeCommandError；失败时抛异常
# 注意：不使用 param(ValueFromRemainingArguments)，否则以 - 开头的 git 参数会被 PowerShell 吞掉
function Invoke-Git {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = & git @args 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# git diff --quiet：返回退出码（0=无差异，1=有差异），不抛异常
function Invoke-Git-Quiet {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $null = & git @args 2>&1
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

# 单次替换：old 不存在但 new 已存在 -> 跳过；old 不存在 -> 报错（版本锚点变动时快速定位）
function Replace-Once {
    param([string]$Path, [string[]]$OldLines, [string[]]$NewLines)
    $old = ($OldLines -join "`n"); $new = ($NewLines -join "`n")
    # 统一行尾为 LF，避免 CRLF/LF 差异导致锚点匹配失败
    $c = [IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
    if ($c.Contains($new)) { Write-Host "  [skip] already patched: $(Split-Path -Leaf $Path)"; return }
    if (-not $c.Contains($old)) { throw "锚点未找到(版本可能不匹配): $Path <- $($OldLines[0])" }
    [IO.File]::WriteAllText($Path, $c.Replace($old, $new))
    Write-Host "  [ok] patched: $(Split-Path -Leaf $Path)"
}

# 给所有 recursive 子模块 checkout 注入 SUBMODULE_TOKEN（幂等）
function Add-CheckoutToken {
    param([string]$Path)
    $lines = [IO.File]::ReadAllLines($Path)
    $out = New-Object System.Collections.Generic.List[string]
    $count = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $out.Add($lines[$i])
        if ($lines[$i] -match '^(\s+)submodules: recursive\s*$') {
            $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { "" }
            if ($next -notmatch 'token:') {
                $out.Add("$($Matches[1])token: `${{ secrets.SUBMODULE_TOKEN }}")
                $count++
            }
        }
    }
    if ($count -gt 0) { [IO.File]::WriteAllText($Path, ($out -join "`n") + "`n") }
    Write-Host "  [ok] checkout token lines added: $count -> $(Split-Path -Leaf $Path)"
}

function Push-Git {
    param([string]$RepoDir, [string]$RemoteRepo, [string[]]$Refs)
    $argList = @("-C", $RepoDir, "-c", "credential.helper=", "push", "--force", "https://x-access-token:$Token@github.com/$TargetOrg/$RemoteRepo.git") + $Refs
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & git @argList 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) { Write-Host ($out.Replace($Token, "***")) -ForegroundColor Red; throw "git push failed: $RemoteRepo" }
    Write-Host "  [ok] pushed $RemoteRepo -> $($Refs -join ', ')"
}

function Invoke-GhApi {
    param([string]$Method, [string]$Path, $Body)
    $uri = "https://api.github.com/$Path"
    $json = if ($null -ne $Body) { $Body | ConvertTo-Json -Compress } else { $null }
    if ($json) { Invoke-RestMethod -Method $Method -Uri $uri -Headers $ghHeaders -Body $json } else { Invoke-RestMethod -Method $Method -Uri $uri -Headers $ghHeaders }
}

# ---------- 1. 前置检查 ----------
Write-Host "`n[1/9] 前置检查" -ForegroundColor Cyan
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "未找到 git，请先安装" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "未找到 python（用于加密写入 GitHub Secret）" }
# 注意：python/pip 等原生命令的 stderr 在 Stop 模式下会被 PowerShell 包装成
# NativeCommandError 并终止脚本（import 失败的 traceback、pip 进度都走 stderr）。
# 临时切到 Continue，仅以退出码判断成败（与 Invoke-Git 同理）。
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
try {
    python -c "import nacl" 2>$null
    $naclMissing = ($LASTEXITCODE -ne 0)
} finally { $ErrorActionPreference = $prevEap }
if ($naclMissing) {
    Write-Host "  安装 pynacl ..."
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try {
        python -m pip install pynacl --quiet --disable-pip-version-check 2>&1 | Out-Host
        $pipCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap }
    if ($pipCode -ne 0) { throw "pynacl 安装失败" }
}
Write-Host "  [ok] git / python / pynacl 就绪"

# ---------- 2. 克隆源码（幂等：已存在则重置到目标 tag）----------
Write-Host "`n[2/9] 获取源码 rustdesk@$checkoutRef" -ForegroundColor Cyan
if (Test-Path $workRoot) {
    Invoke-Git -C $workRoot fetch origin --tags --force
    Invoke-Git -C $workRoot checkout -f $checkoutRef
    Invoke-Git -C $workRoot reset --hard $checkoutRef
    Invoke-Git -C $workRoot clean -fdx
    Invoke-Git -C $workRoot submodule foreach --recursive "git checkout -f; git reset --hard; git clean -fdx"
    Invoke-Git -C $workRoot submodule update --init --recursive
    Write-Host "  [ok] reset to tag $checkoutRef"
} else {
    Invoke-Git clone $UpstreamRepo $workRoot
    Invoke-Git -C $workRoot checkout $checkoutRef
    Invoke-Git -C $workRoot submodule update --init --recursive
    Write-Host "  [ok] cloned and checked out $checkoutRef"
}

# ---------- 3. hbb_common：服务器 / 公钥 / 默认配置 / 固定密码 ----------
Write-Host "`n[3/9] 补丁 hbb_common/src/config.rs" -ForegroundColor Cyan
$cfg = Join-Path $hbDir "src\config.rs"

Replace-Once -Path $cfg -OldLines @(
    "pub const RENDEZVOUS_SERVERS: &[&str] = &[`"rs-ny.rustdesk.com`"];",
    "pub const RS_PUB_KEY: &str = `"OeVuKk5nlHiXp+APNn0Y3pC1Iwpwn44JGqrQCsWqmBw=`";"
) -NewLines @(
    "pub const RENDEZVOUS_SERVERS: &[&str] = &[`"$IdServer`"];",
    "pub const RS_PUB_KEY: &str = `"$PublicKey`";"
)

Replace-Once -Path $cfg -OldLines @(
    "    pub static ref DEFAULT_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
    "    pub static ref OVERWRITE_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
    "    pub static ref DEFAULT_DISPLAY_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
    "    pub static ref OVERWRITE_DISPLAY_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
    "    pub static ref DEFAULT_LOCAL_SETTINGS: RwLock<HashMap<String, String>> = Default::default();"
) -NewLines @(
    "    pub static ref DEFAULT_SETTINGS: RwLock<HashMap<String, String>> = RwLock::new(",
    "        HashMap::from([",
    "            // Custom build defaults for $IdServer self-hosted deployment.",
    "            (keys::OPTION_CUSTOM_RENDEZVOUS_SERVER.to_owned(), `"$IdServer`".to_owned()),",
    "            (keys::OPTION_RELAY_SERVER.to_owned(), `"$RelayServer`".to_owned()),",
    "            (keys::OPTION_API_SERVER.to_owned(), `"$ApiServer`".to_owned()),",
    "            (keys::OPTION_KEY.to_owned(), RS_PUB_KEY.to_owned()),",
    "            // Access control and approval policy.",
    "            (keys::OPTION_ACCESS_MODE.to_owned(), `"$AccessMode`".to_owned()),",
    "            (keys::OPTION_APPROVE_MODE.to_owned(), `"$ApproveMode`".to_owned()),",
    "            (keys::OPTION_VERIFICATION_METHOD.to_owned(), `"$VerificationMethod`".to_owned()),",
    "            (`"allow-hide-cm`".to_owned(), `"$optHideCm`".to_owned()),",
    "            // Software update check.",
    "            (keys::OPTION_ENABLE_CHECK_UPDATE.to_owned(), `"$optEnableCheckUpdate`".to_owned()),",
    "        ]),",
    "    );",
    "    pub static ref OVERWRITE_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
    "    pub static ref DEFAULT_DISPLAY_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
    "    pub static ref OVERWRITE_DISPLAY_SETTINGS: RwLock<HashMap<String, String>> = Default::default();",
    "    pub static ref DEFAULT_LOCAL_SETTINGS: RwLock<HashMap<String, String>> = RwLock::new(",
    "        HashMap::from([",
    "            // Software update check.",
    "            (keys::OPTION_ENABLE_CHECK_UPDATE.to_owned(), `"$optEnableCheckUpdate`".to_owned()),",
    "            // Mobile scam warning prompt.",
    "            (`"show-scam-warning`".to_owned(), `"$optShowScamWarning`".to_owned()),",
    "        ]),",
    "    );"
)

# 预设密码：按版本适配（1.4.9+ 用 h1 哈希；1.4.2 用明文）
$cfgText = [IO.File]::ReadAllText($cfg).Replace("`r`n", "`n")
if ($cfgText.Contains("fn get_preset_password_storage_and_salt")) {
    # === 1.4.9+：h1 哈希预设密码机制 ===
    Replace-Once -Path $cfg -OldLines @(
        "    pub fn get_preset_password_storage_and_salt() -> (String, String) {",
        "        let hard_settings = HARD_SETTINGS.read().unwrap();",
        "        let storage = hard_settings.get(`"password`").cloned().unwrap_or_default();",
        "        let salt = hard_settings.get(`"salt`").cloned().unwrap_or_default();",
        "        (storage, salt)",
        "    }"
    ) -NewLines @(
        "    pub fn get_preset_password_storage_and_salt() -> (String, String) {",
        "        {",
        "            let hard_settings = HARD_SETTINGS.read().unwrap();",
        "            if let Some(storage) = hard_settings.get(`"password`") {",
        "                let salt = hard_settings.get(`"salt`").cloned().unwrap_or_default();",
        "                return (storage.clone(), salt);",
        "            }",
        "        }",
        "        // Custom build: fixed preset permanent password.",
        "        const PRESET_PERMANENT_PASSWORD: &str = `"$PresetPassword`";",
        "        const PRESET_PASSWORD_SALT: &str = `"$IdServer-preset-password-salt`";",
        "        let h1 = permanent_password::compute_permanent_password_h1(",
        "            PRESET_PERMANENT_PASSWORD,",
        "            PRESET_PASSWORD_SALT,",
        "        );",
        "        let storage = permanent_password::encode_permanent_password_storage_from_h1(&h1);",
        "        (storage, PRESET_PASSWORD_SALT.to_owned())",
        "    }"
    )
} else {
    # === 1.4.2：明文永久密码，get_permanent_password 为空时返回内置密码 ===
    Replace-Once -Path $cfg -OldLines @(
        "    pub fn get_permanent_password() -> String {",
        "        let mut password = CONFIG.read().unwrap().password.clone();",
        "        if password.is_empty() {",
        "            if let Some(v) = HARD_SETTINGS.read().unwrap().get(`"password`") {",
        "                password = v.to_owned();",
        "            }",
        "        }",
        "        password",
        "    }"
    ) -NewLines @(
        "    pub fn get_permanent_password() -> String {",
        "        let mut password = CONFIG.read().unwrap().password.clone();",
        "        if password.is_empty() {",
        "            if let Some(v) = HARD_SETTINGS.read().unwrap().get(`"password`") {",
        "                password = v.to_owned();",
        "            }",
        "        }",
        "        if password.is_empty() {",
        "            // Custom build: fixed preset permanent password.",
        "            password = `"$PresetPassword`".to_owned();",
        "        }",
        "        password",
        "    }"
    )
}

# 锁定永久密码：客户端 UI 不可修改
if ($LockPassword) {
    if ($cfgText.Contains("fn is_disable_change_permanent_password")) {
        # 1.4.9+：改 is_disable_change_permanent_password 恒返回 true
        Replace-Once -Path $cfg -OldLines @(
            "    pub fn is_disable_change_permanent_password() -> bool {",
            "        BUILTIN_SETTINGS",
            "            .read()",
            "            .unwrap()",
            "            .get(keys::OPTION_DISABLE_CHANGE_PERMANENT_PASSWORD)",
            "            .map(|v| v == `"Y`")",
            "            .unwrap_or(false)",
            "    }"
        ) -NewLines @(
            "    pub fn is_disable_change_permanent_password() -> bool {",
            "        // Custom build: permanent password is locked and cannot be changed in the UI.",
            "        true",
            "    }"
        )
    } else {
        # 1.4.2：无锁定函数，直接让 set_permanent_password 立即返回
        Replace-Once -Path $cfg -OldLines @(
            "    pub fn set_permanent_password(password: &str) {",
            "        if HARD_SETTINGS"
        ) -NewLines @(
            "    pub fn set_permanent_password(password: &str) {",
            "        // Custom build: permanent password is locked and cannot be changed.",
            "        return;",
            "        if HARD_SETTINGS"
        )
    }
}

# ---------- 4. rustdesk 主程序：API 回退 / 禁用更新 ----------
Write-Host "`n[4/9] 补丁 src/common.rs 与 src/updater.rs" -ForegroundColor Cyan
Replace-Once -Path (Join-Path $workRoot "src\common.rs") -OldLines @(
    "    `"https://admin.rustdesk.com`".to_owned()"
) -NewLines @(
    "    `"$ApiServer`".to_owned()"
)

if (-not $EnableCheckUpdate) {
    Replace-Once -Path (Join-Path $workRoot "src\common.rs") -OldLines @(
        "pub fn check_software_update() {",
        "    if is_custom_client() {",
        "        return;",
        "    }"
    ) -NewLines @(
        "#[allow(unreachable_code)]",
        "pub fn check_software_update() {",
        "    // Custom build: software update check is disabled.",
        "    return;",
        "    if is_custom_client() {",
        "        return;",
        "    }"
    )

    Replace-Once -Path (Join-Path $workRoot "src\updater.rs") -OldLines @(
        "fn check_update(manually: bool) -> ResultType<()> {",
        "    #[cfg(target_os = `"windows`")]"
    ) -NewLines @(
        "#[allow(unreachable_code, unused_variables)]",
        "fn check_update(manually: bool) -> ResultType<()> {",
        "    // Custom build: update check and auto-update are disabled.",
        "    return Ok(());",
        "    #[cfg(target_os = `"windows`")]"
    )
}

# ---------- 5. 子模块指向私仓 ----------
Write-Host "`n[5/9] 更新 .gitmodules" -ForegroundColor Cyan
Replace-Once -Path (Join-Path $workRoot ".gitmodules") -OldLines @(
    "`turl = https://github.com/rustdesk/hbb_common"
) -NewLines @(
    "`turl = https://github.com/$TargetOrg/$TargetHbRepoName"
)

# ---------- 6. 修复私有仓库 CI ----------
Write-Host "`n[6/9] 修复 .github/workflows（私仓子模块权限 / 发布权限 / 签名空值）" -ForegroundColor Cyan
$wfDir = Join-Path $workRoot ".github\workflows"
foreach ($f in @("flutter-build.yml", "bridge.yml", "ci.yml", "playground.yml")) {
    $p = Join-Path $wfDir $f
    if (Test-Path $p) { Add-CheckoutToken -Path $p }
}
# 禁用非必要 workflow：重命名为 *.disabled（GitHub Actions 忽略），避免 push/tag 重复触发
# 多个全平台构建（CI / Flutter CI / Fdroid / nightly / winget 等），浪费私仓 Actions 分钟数。
# 保留：flutter-tag.yml（tag 构建入口）、flutter-build.yml、bridge.yml、third-party-RustDeskTempTopMostWindow.yml（被 flutter-build 引用）
$keepWf = @("flutter-tag.yml", "flutter-build.yml", "bridge.yml", "third-party-RustDeskTempTopMostWindow.yml")
foreach ($f in (Get-ChildItem $wfDir -Filter *.yml)) {
    if ($keepWf -notcontains $f.Name) {
        Move-Item $f.FullName (Join-Path $wfDir ($f.Name + ".disabled")) -Force
        Write-Host "  [ok] disabled workflow: $($f.Name)"
    }
}
$fb = Join-Path $wfDir "flutter-build.yml"
if (Test-Path $fb) {
    Replace-Once -Path $fb -OldLines @(
        "  generate-bridge:",
        "    uses: ./.github/workflows/bridge.yml"
    ) -NewLines @(
        "  generate-bridge:",
        "    uses: ./.github/workflows/bridge.yml",
        "    secrets: inherit"
    )
    Replace-Once -Path $fb -OldLines @(
        "env:",
        "  SCITER_RUST_VERSION:"
    ) -NewLines @(
        "permissions:",
        "  contents: write",
        "",
        "env:",
        "  SCITER_RUST_VERSION:"
    )
    $c = [IO.File]::ReadAllText($fb)
    $c = $c.Replace("env.MACOS_P12_BASE64 != null", "env.MACOS_P12_BASE64 != ''")
    $c = $c.Replace("env.ANDROID_SIGNING_KEY != null", "env.ANDROID_SIGNING_KEY != ''")
    $c = $c.Replace("env.ANDROID_SIGNING_KEY == null", "env.ANDROID_SIGNING_KEY == ''")
    [IO.File]::WriteAllText($fb, $c)
    Write-Host "  [ok] signing empty-string guards applied"

    # macOS 13 runner 已被 GitHub 退役（job 会永远排队），按官方 1.4.9 迁移：
    # iOS 构建 -> macos-latest；macOS 桌面 x86_64 构建 -> macos-15-intel（保持 Intel 架构）
    $c = [IO.File]::ReadAllText($fb).Replace("`r`n", "`n")
    if ($c.Contains("macos-13")) {
        $c = $c.Replace("target: aarch64-apple-ios,`n              os: macos-13,", "target: aarch64-apple-ios,`n              os: macos-latest,")
        $c = $c.Replace("os: macos-13,", "os: macos-15-intel,")
        [IO.File]::WriteAllText($fb, $c)
        Write-Host "  [ok] retired macos-13 runner migrated (iOS -> macos-latest, macOS x86_64 -> macos-15-intel)"
    }

    # macos-15+ 镜像预装 NASM 3.x（CLI 不兼容重写版），libaom 等需要 2.x：
    # 在 build-for-macOS job 注入安装 NASM 2.16.03 的步骤（与官方 master 修复一致）
    $c = [IO.File]::ReadAllText($fb).Replace("`r`n", "`n")
    if (-not $c.Contains("Install NASM 2.16.x from official release")) {
        $nasmStep = @'
      - name: Install NASM
        run: |
          # Install NASM 2.16.x from official release.
          # Do NOT use `brew install nasm` which installs NASM 3.x.
          # NASM 3.x is a complete rewrite with incompatible CLI options and removed features.
          # aom and other multimedia libraries require NASM 2.x for x86/x86_64 assembly.
          wget https://www.nasm.us/pub/nasm/releasebuilds/2.16.03/macosx/nasm-2.16.03-macosx.zip
          unzip nasm-2.16.03-macosx.zip
          sudo cp nasm-2.16.03/nasm /usr/local/bin/nasm
          nasm --version

'@
        $marker = "      - name: Import the codesign cert"
        if ($c.Contains($marker)) {
            $c = $c.Replace($marker, ($nasmStep + $marker))
            [IO.File]::WriteAllText($fb, $c)
            Write-Host "  [ok] NASM 2.16.03 install step injected into build-for-macOS"
        } else {
            Write-Host "  [warn] codesign cert anchor not found; NASM step not injected" -ForegroundColor Yellow
        }
    }

    # build-for-macOS 的 brew install 含 nasm（镜像源现装 3.02），与注入的 NASM 2.16.03
    # 冲突：/usr/local/bin/nasm 已被占用 -> brew link 失败 -> 步骤 exit 1。移除之。
    $c = [IO.File]::ReadAllText($fb).Replace("`r`n", "`n")
    if ($c.Contains("brew install llvm create-dmg nasm")) {
        $c = $c.Replace("brew install llvm create-dmg nasm", "brew install llvm create-dmg")
        [IO.File]::WriteAllText($fb, $c)
        Write-Host "  [ok] removed nasm from brew install (conflicts with injected NASM 2.16.03)"
    }
}

# ---------- 7. 提交与打 tag ----------
Write-Host "`n[7/9] 提交并打 tag $customTag" -ForegroundColor Cyan
# hbb_common
Invoke-Git -C $hbDir config user.name $CommitUser
Invoke-Git -C $hbDir config user.email $CommitEmail
Invoke-Git -C $hbDir checkout -B master
Invoke-Git -C $hbDir add -A
if ((Invoke-Git-Quiet -C $hbDir diff --cached --quiet) -ne 0) {
    Invoke-Git -C $hbDir commit -m "Customize for ${IdServer}: built-in server and key, fixed preset password, full access defaults, disable update check"
    Write-Host "  [ok] hbb_common committed"
} else { Write-Host "  [skip] hbb_common no changes" }
try { Invoke-Git -C $hbDir tag -d $customTag } catch {}
Invoke-Git -C $hbDir tag -a $customTag -m "Release $Version"

# rustdesk
Invoke-Git -C $workRoot config user.name $CommitUser
Invoke-Git -C $workRoot config user.email $CommitEmail
Invoke-Git -C $workRoot checkout -B master
Invoke-Git -C $workRoot add -A
if ((Invoke-Git-Quiet -C $workRoot diff --cached --quiet) -ne 0) {
    Invoke-Git -C $workRoot commit -m "Customize for ${IdServer}: submodule to $TargetOrg/$TargetHbRepoName, custom API server, disable update check and auto-update, fix private repo CI"
    Write-Host "  [ok] rustdesk committed"
} else { Write-Host "  [skip] rustdesk no changes" }
try { Invoke-Git -C $workRoot tag -d $customTag } catch {}
Invoke-Git -C $workRoot tag -a $customTag -m "Release $Version"

# ---------- 8. 配置 GitHub 仓库（secret / 默认分支 / Actions 权限）----------
Write-Host "`n[8/9] 配置 GitHub 仓库" -ForegroundColor Cyan

# 8a. 写入 SUBMODULE_TOKEN secret（子模块拉取权限）
#     404 通常表示 token 缺少 Secrets 读权限（fine-grained token 需勾选 Secrets: Read）
$pyCode = @'
import base64, json, os, sys, urllib.request, urllib.error
token, repo = os.environ["GH_API_TOKEN"], os.environ["GH_REPO"]
h = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json", "User-Agent": "rustdesk-custom"}
def api(method, path, payload=None):
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/{path}",
        data=json.dumps(payload).encode() if payload is not None else None, headers=h, method=method)
    try:
        with urllib.request.urlopen(req) as r:
            b = r.read()
            return json.loads(b) if b else None
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print(f"  [warn] 无法写入 SUBMODULE_TOKEN secret：仓库 {repo} 返回 404。")
            print(f"         原因通常是 token 缺少 Secrets 读权限（fine-grained token 需勾选 Secrets: Read；classic token 需 repo 作用域）。")
            print(f"         请手动添加：仓库 Settings -> Secrets and variables -> Actions -> New repository secret，Name=SUBMODULE_TOKEN。")
            sys.exit(0)
        raise
pk = api("GET", "actions/secrets/public-key")
from nacl import encoding, public
sealed = public.SealedBox(public.PublicKey(pk["key"].encode(), encoding.Base64Encoder())).encrypt(token.encode())
api("PUT", "actions/secrets/SUBMODULE_TOKEN", {"encrypted_value": base64.b64encode(sealed).decode(), "key_id": pk["key_id"]})
print("  [ok] SUBMODULE_TOKEN secret written to", repo)
'@
$pyFile = Join-Path $env:TEMP "set_secret_$PID.py"
[IO.File]::WriteAllText($pyFile, $pyCode)
$env:GH_API_TOKEN = $SubmoduleToken; $env:GH_REPO = "$TargetOrg/$TargetRepoName"
$prevEap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
python $pyFile 2>&1 | Out-Host
$ErrorActionPreference = $prevEap
Remove-Item $pyFile -Force

# 8b. 启用 Actions 全权限 + Workflow 读写权限
$repoFull = "$TargetOrg/$TargetRepoName"
try {
    Invoke-GhApi -Method Put -Path "repos/$repoFull/actions/permissions" -Body @{ enabled = $true; allowed_actions = "all" } | Out-Null
    Write-Host "  [ok] Actions: Allow all actions and reusable workflows"
} catch { Write-Host "  [warn] 启用 Actions 全权限失败（需 Administration 权限，可在 Settings -> Actions -> General 手动设置）" -ForegroundColor Yellow }
try {
    Invoke-GhApi -Method Put -Path "repos/$repoFull/actions/permissions/workflow" -Body @{ default_workflow_permissions = "write" } | Out-Null
    Write-Host "  [ok] Workflow permissions: Read and write"
} catch { Write-Host "  [warn] 设置 Workflow 读写权限失败（需 Administration 权限，可在 Settings -> Actions -> General 手动设置）" -ForegroundColor Yellow }

# ---------- 9. 推送并触发在线构建 ----------
Write-Host "`n[9/9] 推送并触发 Flutter Tag Build" -ForegroundColor Cyan
Push-Git -RepoDir $hbDir -RemoteRepo $TargetHbRepoName -Refs @("master", $customTag)
Push-Git -RepoDir $workRoot -RemoteRepo $TargetRepoName -Refs @("master", $customTag)

# 9b. 默认分支设为 master（须在推送 master 之后，否则 422）
try {
    Invoke-GhApi -Method Patch -Path "repos/$TargetOrg/$TargetRepoName" -Body @{ default_branch = "master" } | Out-Null
    Write-Host "  [ok] default branch -> master"
} catch { Write-Host "  [warn] 设置默认分支失败（可能缺少 Administration 权限）：$($_.Exception.Message)" -ForegroundColor Yellow }

# 9c. 构建由 tag push 自动触发（flutter-tag.yml 监听 v* tag），无需手动 dispatch
#     不调用 workflow_dispatch，避免重复构建消耗双倍 Actions 分钟数
Write-Host "  [ok] build auto-triggered by tag $customTag push"

Write-Host "`n==== 完成 ====" -ForegroundColor Green
Write-Host "  主仓:  https://github.com/$TargetOrg/$TargetRepoName  (tag $customTag)"
Write-Host "  子仓:  https://github.com/$TargetOrg/$TargetHbRepoName (tag $customTag)"
Write-Host "  构建:  https://github.com/$TargetOrg/$TargetRepoName/actions"
Write-Host "  产物:  https://github.com/$TargetOrg/$TargetRepoName/releases/tag/$customTag"
