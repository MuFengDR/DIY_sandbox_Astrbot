# DIY Sandbox AstrBot Skin

这是 AstrBot DIY Sandbox 使用的 Lua 皮肤，为应用提供界面和环境管理功能。

新安装 AstrBot 的初始账号、密码均为 `astrbot`。启动前仅在配置尚无密码时初始化，已有密码（包括之前生成的随机密码）及恢复的数据保持原样；在线、离线安装均适用，五个离线包无需重新制作。

## 更新

皮肤通常由应用内的“Lua 皮肤更新”功能检查并更新。更新器读取仓库最新 Release 的 tag，先从该 tag 获取 `skin-update-manifest.json`，验证清单格式、版本号和相对路径，再按目标版本清单下载所有皮肤文件，包括新增模块和资源。下载全部成功后才开始写入并重载；清单获取或验证失败时停止更新，不回退到本地旧清单。

每次发布前运行 `local-package/build-local-skin.bat`，它会按 `main.lua` 的 `LUA_SCRIPT_VERSION` 生成根目录的清单，并按同一份清单打包。将生成的 `skin-update-manifest.json` 和对应运行文件一并提交到发布 tag，Release 版本号去掉前缀 `v` 后须与皮肤版本一致。也可只运行 `scripts/generate-update-manifest.ps1` 生成清单。清单自动收集根目录 Lua 模块、README 和运行资源子目录，排除隐藏文件、`AGENTS.md`、`scripts/`、`local-package/`、`keys/`；新增运行文件无需再修改更新器。

已删除的资源不再下载，手机中历史文件暂不自动清理。旧版仍使用本地固定清单，无法自行切换到目标清单机制，需手动导入一次新版完整 ZIP。若要让旧版通过在线更新过渡，过渡 Release 必须保留旧清单要求的全部文件（包括旧版请求的 `assets/linuxqq.png`）。

如果应用内更新无法完成，可以从本仓库的 [Releases](https://github.com/MuFengDR/DIY_sandbox_Astrbot/releases) 下载源码 ZIP，再通过沙盒本体的皮肤导入功能安装。

## 相关仓库

Linux 环境安装脚本由 [AstrBot-Android-Scripts](https://github.com/MuFengDR/AstrBot-Android-Scripts) 单独维护，和 Lua 皮肤更新相互独立。

## 组件离线安装

基础环境、uv、LinuxQQ、NapCat、AstrBot 的“安装/重装”支持在线安装、选择离线文件和使用缓存包。组件包与泡泡版完全通用，使用 `astrbot-offline-package-v1` 格式、ARM64 架构，不需要为沙盒版重新打包。OpenCode 和插件依赖仍走原有在线流程。

建议顺序：基础环境 → uv → LinuxQQ → NapCat → AstrBot；AstrBot 仅依赖基础环境和 uv。先停止 AstrBot 和所有 NapCat 账号，把 `.tar.gz` / `.tgz` 组件包放到手机 Download 目录，在离线安装文件列表中选择，也可输入共享存储或 Ubuntu `/root/` 下的绝对路径。首次访问共享存储需授权，授权后点击刷新。

在线“基础命令”安装后可直接离线安装 uv、AstrBot，不要求先具备 QQ 系统库。LinuxQQ、NapCat 会单独检查其系统运行依赖，缺少时列出具体缺项；先离线安装基础环境包补齐，再继续安装。在线、离线安装按实际文件和包状态识别依赖。

离线安装不要求下载共享在线安装脚本。皮肤自带与泡泡版相同的可信安装引擎和 bootstrap 最小工具包，先在本地补齐工具，再验证组件包的完整性、类型、架构、依赖和目录结构。安装器不执行组件包内脚本，不访问 apt 网络源、GitHub 或 PyPI。Ubuntu rootfs 的首次解压继续由沙盒本体使用内置资源完成。

bootstrap 工具安装被强制终止后，下一次离线安装会先修复 dpkg 中断状态，必要时使用内置 deb 补齐依赖，全程不需要联网。

有效包缓存在 Ubuntu `/root/.astrbot-android/offline-packages/<component>/package.tar.gz`。失败后可选“使用已缓存的离线包”重试。重装保留 AstrBot `data` 和 NapCat 配置、账号目录；普通文件组件支持失败回滚，系统 deb 由 apt/dpkg 管理，失败后需根据终端提示重试。

主页“管理 → 删除离线包缓存”可删除五种组件的包缓存及未完成的导入文件，显示释放空间。安装进行中禁止清理；已安装组件、账号、数据及中断恢复记录保留。清理后离线重装需重新选择文件。

## 本地打包与同步

运行 `local-package/build-local-skin.bat`，或 PowerShell 执行 `local-package/build-local-skin.ps1`，自动生成目标更新清单及可直接导入的 `local-package/astrbot-lua-skin-local.zip`。ZIP 包含清单中的全部运行文件，不要只拷贝 main.lua。

本地打包脚本使用 `/` 作为 ZIP 内部路径分隔符，兼容 Android。不要改用 Windows PowerShell 的 `Compress-Archive`，其生成的反斜杠路径可能导致导入后提示资源缺失。遇到此前版本的该问题，重新导入修正版完整 ZIP 即可。

与泡泡版放在当前工作区布局下时，运行 `scripts/sync-bubble-offline.ps1` 可同步离线安装引擎、在线 LinuxQQ 安装分支和 bootstrap；其他位置可传入 `-BubbleRoot` 指定泡泡版源码根目录。五个大组件包由用户另行下载，均不打入皮肤 ZIP。

LinuxQQ 使用与其他组件一致的状态图标，不再需要 `assets/linuxqq.png`。旧版更新器仍会请求该文件，需手动导入一次新版完整皮肤 ZIP，之后在线更新不再下载该图标。
