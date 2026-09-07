# RustDesk 自定义客户端一键部署工具

基于 RustDesk 官方源码（当前基线 **1.4.9**）定制：内置自建服务器、固定密码、完全访问、禁用更新、移除提示，并通过 GitHub Actions 在线编译，产物发布到你的仓库 Release。

## 一、定制功能总览

| 需求 | 修改位置 | 效果 |
|---|---|---|
| 自定义服务器 | `hbb_common/src/config.rs`：`RENDEZVOUS_SERVERS` 常量 + 默认选项 `custom-rendezvous-server`（ID）、`relay-server`（中继） | 客户端开箱直连 hbbs/hbbr，无需手填 |
| 公钥 | `RS_PUB_KEY` 常量 + 默认选项 `key` | 内置服务器密钥，防中间人 |
| API 服务器 | 默认选项 `api-server` + `src/common.rs` 兜底地址 | Web 控制台/地址簿 |
| 固定密码 | `get_preset_password_storage_and_salt()` 硬编码预设密码 | 被控端开箱即用；走官方挑战-应答验证；本机可改（改后覆盖预设） |
| 完全访问 | 默认选项 `access-mode=full`、`approve-mode=password`、`verification-method=use-both`（永久密码与一次性密码两种方式同时启用）、`allow-hide-cm=Y` | 密码验证通过直接接入，无逐项确认弹窗、无被控确认窗口 |
| 禁止更新检查/自动更新 | `check_software_update()`、`updater.rs::check_update()` 直接返回 + 默认 `enable-check-update=N` | 彻底禁用，无"新版本可用"卡片 |
| 移除提示 | 默认 `show-scam-warning=N`（移动端 12 秒防诈倒计时）；公网服务器购买引导因使用自定义服务器自动隐藏 | 无广告类弹窗 |
| 私仓 CI 修复 | workflows：checkout 加 `SUBMODULE_TOKEN`、`secrets: inherit`、顶层 `permissions: contents: write`、签名空值判断 `!= ''` | GitHub Actions 私有仓库可正常编译 |

## 二、文件清单

| 文件 | 说明 |
|---|---|
| `rustdesk-custom.ps1` | 一键构建脚本（幂等，可重复运行） |
| `rustdesk-download.ps1` | Release 产物一键下载脚本（支持公共仓/私仓） |
| `rustdesk-clean.ps1` | Windows 残留清理脚本（服务/程序/配置/注册表） |
| `rustdesk-custom-<版本>/` | 构建脚本创建的工作目录（克隆 + 补丁后的源码） |

## 三、一键构建

前置条件：Windows 10/11，已安装 Git、Python 3（脚本会自动安装 pynacl）；有仓库写权限的 GitHub Token（classic PAT，`repo` scope）。

```powershell
cd C:\path\to\project
.\rustdesk-custom.ps1 -Token ghp_你的Token
```

全参数示例（所有参数均可覆盖默认值）：

```powershell
.\rustdesk-custom.ps1 `
    -Token ghp_你的Token `
    -Version 1.4.9 `
    -Tag v1.4.9 `
    -TargetOrg your-github-username `
    -CommitUser "Your Name" `
    -CommitEmail your-email@example.com `
    -IdServer your-server.example.com:21116 `
    -RelayServer your-server.example.com:21117 `
    -ApiServer http://your-server.example.com:21114 `
    -PublicKey "你的服务器公钥(Base64)" `
    -PresetPassword YourPasswordHere `
    -LockPassword `
    -AccessMode full `
    -ApproveMode password `
    -VerificationMethod use-permanent-password `
    -HideCm:$true `
    -EnableCheckUpdate:$false `
    -ShowScamWarning:$false
```

> 若执行策略限制：`powershell -ExecutionPolicy Bypass -File .\rustdesk-custom.ps1 -Token ghp_xxx`

脚本跑完即完成：源码补丁 → 提交 → tag `v<Version>` → 推送两个私仓 → 写入 `SUBMODULE_TOKEN` Secret → 默认分支设为 master → 触发 Actions 在线构建。

### 参数速查

| 参数 | 默认值 | 说明 |
|---|---|---|
| `-Token` | (必填) | GitHub PAT（classic，需 Contents 写权限） |
| `-Version` | `1.4.9` | 官方源码 tag（不带 v 前缀），如 `1.4.2` |
| `-Tag` | `v<Version>` | 覆盖目标 tag 名 |
| `-TargetOrg` | `your-github-username` | 目标 GitHub 组织/用户名 |
| `-CommitUser` | `your-github-username` | git 提交作者名 |
| `-CommitEmail` | `your-email@example.com` | git 提交作者邮箱 |
| `-IdServer` | `your-server.example.com:21116` | 自建 hbbs/rendezvous（ID）服务器（可带端口） |
| `-RelayServer` | `your-server.example.com:21117` | 自建 hbbr 中继服务器（可带端口） |
| `-ApiServer` | `http://your-server.example.com:21114` | API 服务器（Web 控制台/地址簿） |
| `-PublicKey` | (你的服务器公钥) | 服务器公钥（hbbs -k _ 输出的公钥） |
| `-PresetPassword` | `YourPasswordHere` | 内置固定永久密码 |
| `-LockPassword` | 关 | 开启后客户端 UI 不可修改永久密码 |
| `-AccessMode` | `full` | 接入权限：full / input / view |
| `-ApproveMode` | `password` | 确认模式：password / input / allow / refuse |
| `-VerificationMethod` | `use-both` | 验证方式：use-permanent-password / use-once-password / use-both（两种密码同时启用） |
| `-HideCm` | `$true` | 隐藏连接管理窗口（静默接入） |
| `-EnableCheckUpdate` | 关 | 允许检查与自动更新 |
| `-ShowScamWarning` | 关 | 显示移动端防诈 12 秒倒计时 |
| `-UpstreamRepo` | `https://github.com/rustdesk/rustdesk` | 源仓库 |
| `-TargetRepoName` | `rustdesk` | 目标主仓库名 |
| `-TargetHbRepoName` | `hbb_common` | 目标子模块仓库名 |
| `-SubmoduleToken` | (复用 `-Token`) | 子模块拉取专用 token（仅需对子模块仓 Contents 读权限），不传则用主 token |

> **注意**：上表中的默认值仅为示例。使用前请将 `-TargetOrg`、`-IdServer`、`-RelayServer`、`-ApiServer`、`-PublicKey`、`-PresetPassword` 等参数替换为你自己的服务器配置。公钥通过在服务器上运行 `hbbs -k _` 获取。

## 四、脚本执行内容（9 步）

1. **前置检查**：git、python、pynacl（缺则自动 `pip install pynacl`）。
2. **获取源码**：克隆 `rustdesk/rustdesk` 并 checkout 指定 tag + 递归子模块；目录已存在则强制重置到该 tag（幂等）。
3. **补丁 hbb_common**（`libs/hbb_common/src/config.rs`）：
   - `RENDEZVOUS_SERVERS` / `RS_PUB_KEY` 换成自建值；
   - `DEFAULT_SETTINGS` / `DEFAULT_LOCAL_SETTINGS` 注入服务器、公钥、完全访问、禁更新、防诈提示默认值；
   - `get_preset_password_storage_and_salt()` 硬编码固定密码（优先保留 HARD_SETTINGS 注入逻辑，不破坏官方单元测试）。
4. **补丁 rustdesk 主程序**：API 兜底地址、`check_software_update()` 与 `updater.rs::check_update()` 开头直接 return。
5. **`.gitmodules`**：子模块 URL 指向你的 `hbb_common` 仓库。
6. **修复 CI**：4 个 workflow 的 recursive checkout 注入 `SUBMODULE_TOKEN`；`flutter-build.yml` 加 `secrets: inherit`（bridge 子任务）、顶层 `permissions: contents: write`（私仓默认只读，不设则发 Release 403）、macOS/Android 签名判断 `!= null` → `!= ''`（secret 缺失时跳过签名出未签名包，而不是构建失败）。同时禁用非必要 workflow（CI / Flutter CI / Fdroid / nightly / winget 等）避免重复触发浪费 Actions 分钟数。修复 GitHub 退役的 macOS 13 runner（iOS → macos-latest，macOS x86_64 → macos-15-intel）并注入 NASM 2.16.03 安装步骤。
7. **提交 + tag**：两个仓库 `master` 分支提交，打 annotated tag `v<Version>`（"Release <Version>"）。
8. **仓库配置**：API 加密写入 `SUBMODULE_TOKEN` Secret（容器加密，token 不出现在明文/URL）；默认分支设为 `master`；启用 Actions 全权限（Allow all actions）与 Workflow 读写权限。
9. **推送 + 触发构建**：推送 `master` 与 tag `v<Version>`；`flutter-tag.yml` 监听 `v*` tag push，**自动触发构建**（不调用 dispatch，避免重复跑两条、双倍消耗 Actions 分钟数）。

## 五、手动执行方式（排查用）

如需逐步执行定位问题，按脚本内步骤对应的命令：

```powershell
# 1. 源码
git clone https://github.com/rustdesk/rustdesk rustdesk-custom-1.4.9
cd rustdesk-custom-1.4.9; git checkout 1.4.9; git submodule update --init --recursive

# 2. 手工修改文件（见第四节第 3~6 步内容，或直接对比已打补丁目录）

# 3. 提交
git config user.name your-name; git config user.email your-email@example.com
git checkout -B master; git add -A; git commit -m "customize"
git tag -a v1.4.9 -m "Release 1.4.9"
cd libs\hbb_common; git checkout -B master; git add -A; git commit -m "customize"; git tag -a v1.4.9 -m "Release 1.4.9"

# 4. 推送（Token 换成你的）
git push https://x-access-token:TOKEN@github.com/your-org/hbb_common.git master v1.4.9
cd ..\..; git push https://x-access-token:TOKEN@github.com/your-org/rustdesk.git master v1.4.9

# 5. Actions 页面手动触发 Flutter Tag Build（ref 选 v1.4.9）
```

## 六、构建与产物

- 在线构建：`https://github.com/<your-org>/rustdesk/actions` → `Flutter Tag Build`，约 1~2 小时。
- 产物：构建完成后自动发布到 `https://github.com/<your-org>/rustdesk/releases/tag/v1.4.9`（prerelease），含 Windows exe/msi、Linux deb/appimage/flatpak、Android apk、macOS dmg（未签名）等。
- 本地构建（可选）：在打补丁后的目录按官方文档执行，如 Windows：`python build.py --flutter --skip-cargo`（需 Flutter 3.24.5 + Rust 1.75）。

### 一键下载产物

构建完成后，使用 `rustdesk-download.ps1` 从 Release 下载安装包：

```powershell
# 私仓：需 Token
.\rustdesk-download.ps1 -Token ghp_你的Token

# 公共仓：免 Token
.\rustdesk-download.ps1 -Repo rustdesk/rustdesk -List

# 指定 tag 和资产
.\rustdesk-download.ps1 -Token ghp_xxx -Tag v1.4.9 -Asset *x86_64*windows*.exe

# 下载全部（含 Source code zip/tar.gz）
.\rustdesk-download.ps1 -Token ghp_xxx -All

# 粘贴 Release 页面 URL
.\rustdesk-download.ps1 -Token ghp_xxx -Repo https://github.com/your-org/rustdesk/releases/tag/v1.4.9
```

脚本自动识别当前平台并推荐对应安装包（Windows x64/ARM64、macOS、Linux），支持交互菜单、通配符筛选、源码包下载（含魔数校验与兜底地址）。

## 七、升级到新版本 / 更换服务器

**换版本**（会创建新工作目录，不影响旧版本目录）：

```powershell
.\rustdesk-custom.ps1 -Token ghp_xxx -Version 1.4.10
```

**换服务器/帐号**（同一版本换配置）：

```powershell
.\rustdesk-custom.ps1 -Token ghp_xxx -Version 1.4.9 `
    -IdServer new.example.com:21116 -RelayServer new.example.com:21117 `
    -ApiServer https://new.example.com:21114 `
    -PublicKey "新公钥" -PresetPassword NewPass `
    -TargetOrg anotherorg -CommitUser "Another Name"
```

脚本自动克隆/重置 → 应用补丁 → 提交 → tag `v<Version>` → 推送 → 触发构建。若官方代码结构变化导致锚点失配，脚本会明确报出"锚点未找到"及所在文件，按报错微调脚本中的 `Replace-Once` 锚点即可。

## 八、Windows 残留清理

重装或卸载自定义客户端前，使用 `rustdesk-clean.ps1` 清理本机残留：

```powershell
# 只读扫描，先看有什么残留
.\rustdesk-clean.ps1 -List

# 全部清理（含设备 ID/密码/服务器配置，重装后生成全新 ID）
.\rustdesk-clean.ps1

# 升级重装：清理程序与服务，但保留设备 ID/密码/服务器配置
.\rustdesk-clean.ps1 -KeepConfig

# 仅重置配置与身份（保留程序，清理后自动重启服务）
.\rustdesk-clean.ps1 -ConfigOnly

# 跳过确认直接执行
.\rustdesk-clean.ps1 -Force
```

清理范围：服务、进程、程序目录、配置目录（含服务模式 `LocalService` 配置）、注册表、防火墙规则、快捷方式、自启动项。服务配置目录 ACL 严格时自动 takeown/icacls 接管后重试。

## 九、常见问题

| 现象 | 原因/处理 |
|---|---|
| `Input required and not supplied: token` | 仓库缺少 `SUBMODULE_TOKEN` Secret，脚本第 8 步会自动写入 |
| Release 上传 403 | 缺 `permissions: contents: write`（脚本已加；新建私仓默认 GITHUB_TOKEN 只读） |
| runs 列表里 "submodules in /. - Update" 红色失败 | GitHub 对含 `.gitmodules` 仓库的内部校验（匿名访问私仓子模块必然失败），不影响构建，忽略 |
| git push 输出 `To https://...` 报 NativeCommandError | PowerShell 把 git stderr 进度当错误显示，实际成功，看 ref 状态即可 |
| `python -c "import nacl"` 报 NativeCommandError | PowerShell 5.1 在 Stop 模式下把 Python stderr 当错误终止脚本；脚本已修复（临时切 Continue，仅以退出码判断） |
| 脚本乱码/一堆语法错误 | 脚本含中文，Windows PowerShell 5.1 要求 UTF-8 **with BOM** 编码（当前文件已带 BOM；用编辑器修改后注意保留 BOM） |
| `锚点未找到(版本可能不匹配)` | 官方新版本代码结构变化。脚本已自动适配 1.4.2（明文密码）与 1.4.9+（h1 哈希密码）两套机制；若更新版本报错，按提示文件微调 `Replace-Once` 锚点 |
| 想锁定密码不可被客户端修改 | 加 `-LockPassword` 参数 |
| 构建全平台太久 | Actions 页面可只手动跑单个 job 的 workflow_dispatch 版本，或本地构建；ARM64 Windows runner 容量小，排队正常 |
| PAT 能自动创建吗 | **不能**。GitHub 安全限制，PAT 必须在网页手动创建（Settings → Developer settings → Personal access tokens）。脚本只负责把 token 写入 Secret、启用 Actions 权限等可 API 化的步骤 |
| Actions 权限配置失败（403） | 主 token 缺少仓库 `Administration` 权限。可手动：仓库 Settings → Actions → General → 勾选 Allow all actions 与 Read and write permissions |
| `windows-11-arm` runner 一直排队 | GitHub ARM64 Windows runner 容量小，排队是常见现象；不影响 x64 产物，不需要 ARM 包可取消该作业 |

## 十、安全须知

- Token 只通过参数传入，脚本输出中自动打码为 `***`，不写入任何文件。
- 文档与脚本中不含任何真实 Token、密码或服务器地址；使用前请将所有占位符替换为你自己的配置。
- 私有仓库 + 内置公钥的客户端只应分发给可信用户：任何拿到客户端的人都能用固定密码接入被控端，请定期轮换服务器密钥或在服务端限制 IP。
- 内置固定密码属于部署配置的一部分，如需更换直接改 `-PresetPassword` 参数重新构建。
- 建议在服务端配置 `hbbs` / `hbbr` 的访问控制（IP 白名单、防火墙规则），避免公网未授权访问。

---

**免责声明**：本项目仅提供 RustDesk 自定义构建的自动化工具，使用者需自行承担部署风险并遵守当地法律法规。RustDesk 是开源软件，本项目不修改其核心协议，仅注入自定义配置默认值。
