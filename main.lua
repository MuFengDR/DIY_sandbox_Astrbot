-- AstrBot Android 默认脚本 (位于 {configPath}/scripts/main.lua, 可直接编辑, 主页顶栏刷新键重载)
-- API 详见同目录 AGENTS.md

local LUA_SCRIPT_VERSION = "0.1.0-beta5.5"

-- 独立 agent 模块 (OpenCode 引擎启动/WebUI 托管), 界面在本文件编排
local agent = require("agent")
local installer = require("installer")
local skin_updater = require("skin_updater")
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then pcall(ffi.cdef, "int access(const char *pathname, int mode);") end

-- 端口管理: 纯 Lua, 基于通用设置存储 host.get/set (无 Dart 特定端口逻辑)
local ports = {
  key = { dashboard = "astrbot_dashboard_port", onebot = "astrbot_onebot_ws_port", napcat = "napcat_webui_port" },
  def = { dashboard = 6185, onebot = 6199, napcat = 6099 },
}
function ports.get(name)
  local v = tonumber(host.get(ports.key[name]))
  if v and v >= 1024 and v <= 65535 then return v end
  return ports.def[name]
end
function ports.set(name, v) host.set(ports.key[name], v) end

nav.tabs({
  { title = "主页",  icon = "home_outlined",     page = "home" },
  { title = "WebUI", icon = "language", page = webview() },
  { title = "终端",  icon = "terminal", page = terminal() },
})

-- GitHub 代理: 直连 + 一组镜像, 由 Lua 端测速后择优 (下方 open_gh_dialog)
local GH_PROXIES = {
  { label = "自动选择", value = "auto" },
  { label = "直连", value = "direct" },
  { label = "Ghfast",     value = "https://ghfast.top" },
  { label = "Gh-Proxy",   value = "https://gh-proxy.com" },
  { label = "GhProxyNet", value = "https://ghproxy.net" },
  { label = "GhProxyCc",  value = "https://ghproxy.cc" },
  { label = "Dpik",       value = "https://gh.dpik.top" },
  { label = "Monlor",     value = "https://gh.monlor.com" },
  { label = "Chjina",     value = "https://gh.chjina.com" },
  { label = "BokiMoe",    value = "https://github.boki.moe" },
  { label = "JasonZeng",  value = "https://gh.jasonzeng.dev" },
  { label = "GeekerTao",  value = "https://gh.geekertao.top" },
  { label = "Nxnow",      value = "https://gh.nxnow.top" },
  { label = "Npee",       value = "https://down.npee.cn" },
}
local function gh_proxy() return host.get("environment_github_proxy") or "auto" end
local function gh_proxy_label(v)
  for _, p in ipairs(GH_PROXIES) do if p.value == v then return p.label end end
  return v
end
local function gh_selected_label()
  local selected = gh_proxy()
  if selected == "auto" then return "AUTO" end
  if selected == "direct" then return "直连" end
  return gh_proxy_label(selected)
end

-- 镜像测速 (纯 Lua 端): value -> { ms=数字 | err=字符串 | testing=true }
local gh_speed = {}
local GH_TEST_PATH = "/https://raw.githubusercontent.com/astral-sh/uv/main/README.md"
local function gh_test_all()
  local rev = state("gh.speed.rev", 0)
  for _, p in ipairs(GH_PROXIES) do
    if p.value ~= "direct" and p.value ~= "auto" then
      gh_speed[p.value] = { testing = true }
      local t0 = host.now_ms()
      host.http({
        url = p.value .. GH_TEST_PATH, method = "GET", timeout = 10,
        on_done = function(res)
          if res and res.ok then
            gh_speed[p.value] = { ms = host.now_ms() - t0 }
          else
            gh_speed[p.value] = { err = "HTTP " .. tostring(res and res.status or "?") }
          end
          rev.set(rev.get() + 1)
        end,
        on_error = function() gh_speed[p.value] = { err = "失败" }; rev.set(rev.get() + 1) end,
      })
    end
  end
  rev.set(rev.get() + 1)
end
-- 直连置顶, 其余按延迟升序 (未测/失败沉底)
local function gh_sorted()
  local list = {}
  for _, p in ipairs(GH_PROXIES) do list[#list + 1] = p end
  table.sort(list, function(a, b)
    if a.value == "direct" then return true end
    if b.value == "direct" then return false end
    local sa, sb = gh_speed[a.value], gh_speed[b.value]
    local ma = (sa and sa.ms) or math.huge
    local mb = (sb and sb.ms) or math.huge
    if ma ~= mb then return ma < mb end
    return a.label < b.label
  end)
  return list
end
local function gh_status_widget(p)
  if p.value == "direct" then return text("默认", { size = 12, color = "grey" }) end
  if p.value == "auto" then return text("自动测速", { size = 12, color = "grey" }) end
  local s = gh_speed[p.value]
  if not s or s.testing then
    return row({ spinner({ size = 14 }), spacer(6), text("测速中", { size = 12, color = "grey" }) }, { cross = "center" })
  elseif s.ms then
    local col = s.ms < 800 and "green" or (s.ms < 2000 and "orange" or "grey")
    return text(s.ms .. " ms", { size = 12, color = col, weight = "bold" })
  else
    return text(s.err or "失败", { size = 12, color = "red" })
  end
end
local function open_gh_dialog()
  gh_test_all()
  host.dialog({
    title = "GitHub 代理测速",
    build = function()
      local rows = {
        row({
          expanded(text("当前选择节点：" .. gh_selected_label(), { size = 12, color = "grey" })),
          button("重新测速", gh_test_all, { variant = "text", icon = "refresh" }),
        }, { cross = "center" }),
        divider(),
      }
      for _, p in ipairs(gh_sorted()) do
        local sel = gh_proxy() == p.value
        rows[#rows + 1] = tile(p.label, {
          icon = sel and "radio_button_checked" or "radio_button_unchecked",
          trailing = gh_status_widget(p),
          onTap = function()
            host.set("environment_github_proxy", p.value)
            host.close_dialog()
            host.toast("已选择: " .. p.label)
          end,
        })
      end
      return box({ height = 400, child = scroll({ column(rows) }) })
    end,
    actions = { { label = "关闭", variant = "text" } },
  })
end

-- 选中代理时给下载 URL 加前缀 (direct 则直接 github.com)
local function gh_prefix(url)
  local p = gh_proxy()
  if p == "direct" or p == "auto" then return url end
  return p .. "/" .. url
end

-- 页面构建保持轻量: 这里只查 dpkg 安装清单标记，不同步读取/解析整个 status 文件。
-- 安装结束处的 check_napcat_ready 仍会用 dpkg-query 做权威校验并在缺项时返回失败。
local function dpkg_marker(ub, name)
  local base = ub .. "/var/lib/dpkg/info/" .. name
  return host.exists(base .. ".list") or host.exists(base .. ":arm64.list") or
    host.exists(base .. ":all.list")
end

local function env_installed(step)
  local ub = host.ubuntu_path()
  if step == "base" then
    return host.exists(ub .. "/usr/bin/git") and host.exists(ub .. "/usr/bin/curl") and host.exists(ub .. "/usr/bin/sudo")
  elseif step == "uv" then
    return host.exists(ub .. "/root/.local/bin/uv")
  elseif step == "napcat" then
    local qq = host.exists(ub .. "/usr/bin/qq") or host.exists(ub .. "/usr/local/bin/qq") or
      host.exists(ub .. "/opt/QQ/qq")
    local xvfb = host.exists(ub .. "/usr/bin/Xvfb") or host.exists(ub .. "/usr/local/bin/Xvfb")
    return qq and xvfb and dpkg_marker(ub, "linuxqq") and dpkg_marker(ub, "libnss3") and
      dpkg_marker(ub, "libnspr4") and (dpkg_marker(ub, "libasound2t64") or dpkg_marker(ub, "libasound2")) and
      host.exists(ub .. "/root/launcher.sh") and host.exists(ub .. "/root/libnapcat_launcher.so") and
      host.exists(ub .. "/root/napcat")
  elseif step == "astrbot" then
    return host.exists(ub .. "/root/AstrBot/main.py") and host.exists(ub .. "/root/AstrBot/.venv")
  elseif step == "opencode" then
    return agent.installed()
  end
  return false
end

local function installer_script_info()
  local root = host.ubuntu_path() .. "/root"
  local state_dir = root .. "/.astrbot-android/installer"
  local runtime_script = state_dir .. "/current/astrbot-startup.sh"
  local raw_version = host.read_file(state_dir .. "/version")
  local version = raw_version and raw_version:match("^%s*(.-)%s*$") or nil

  local executable = false
  if ffi_ok and host.exists(runtime_script) then
    local checked, result = pcall(function() return ffi.C.access(runtime_script, 1) == 0 end)
    executable = checked and result
  end
  if version and version:match("^%d+%.%d+%.%d+$") and executable then
    return { state = "valid", version = version }
  end
  if host.exists(root .. "/astrbot-startup.sh") then
    return { state = "unknown" }
  end
  return { state = "missing" }
end

local function env_step_enabled(step, installed, script_ready)
  if not script_ready then return false end
  if step == "base" then return true end
  if step == "uv" or step == "napcat" or step == "opencode" then
    return installed.base == true
  end
  if step == "astrbot" then return installed.uv == true end
  return false
end

local ENV_STEPS = {
  { id = "base",    title = "基础命令", sub = "sudo / git / curl" },
  { id = "uv",      title = "uv",       sub = "Python 依赖管理工具" },
  { id = "astrbot", title = "AstrBot",  sub = "克隆 AstrBot 并同步依赖" },
  { id = "napcat",  title = "NapCat",   sub = "安装或修复 NapCatQQ" },
  { id = "opencode", title = "OpenCode", sub = "DIY AI coding agent" },
}

-- ============================================================
-- 所有 Linux 安装步骤均通过同一份已签名的远端安装器运行。
-- 此处只保留 UI 需要的参数与终端入口，安装实现不再复制到皮肤内。
-- ============================================================
local STEP_TITLES = {
  base = "基础命令",
  uv = "uv",
  napcat = "NapCat",
  astrbot = "AstrBot",
  opencode = "OpenCode",
}

local function run_installer_step(step, reinstall, reinstall_plugins)
  if installer_script_info().state ~= "valid" then
    host.toast("请先下载或更新脚本")
    return false
  end
  installer.run(step, {
    reinstall = reinstall == true,
    reinstall_plugins = reinstall_plugins == true,
    dashboard_port = ports.get("dashboard"),
    onebot_ws_port = ports.get("onebot"),
    title = STEP_TITLES[step] or "安装脚本",
    key = "installer-" .. step,
  })
  host.nav.go(2)
  return true
end

local function step_base(reinstall)
  run_installer_step("base", reinstall)
end

local function step_uv(reinstall)
  run_installer_step("uv", reinstall)
end

local function step_napcat(reinstall)
  run_installer_step("napcat", reinstall)
end

local function step_astrbot(reinstall, force_plugins)
  run_installer_step("astrbot", reinstall, force_plugins)
end

local STEP_RUN = {
  base = step_base,
  uv = step_uv,
  napcat = step_napcat,
  astrbot = step_astrbot,
  opencode = function(reinstall) run_installer_step("opencode", reinstall) end,
}

local function update_installer(on_exit)
  installer.update({
    title = "更新安装脚本",
    key = "installer-update",
    on_exit = on_exit,
  })
  host.nav.go(2)
end

local function compare_versions(left, right)
  local function parts(value)
    local a, b, c = tostring(value or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) }
  end
  local l, r = parts(left), parts(right)
  if not l or not r then return nil end
  for i = 1, 3 do
    if l[i] ~= r[i] then return l[i] < r[i] and -1 or 1 end
  end
  return 0
end

local installer_check_generation = 0
local check_then_offer_installer_update
local INSTALLER_REPOSITORY_URL = "https://github.com/MuFengDR/AstrBot-Android-Scripts/releases/latest"

local function show_installer_check_failure(timed_out, on_updated)
  host.dialog({
    title = "安装脚本更新",
    build = function()
      return row({
        icon(timed_out and "timer_off_outlined" or "error_outline"),
        expanded(text(timed_out and
          "检查超过 60 秒，已停止。可前往脚本仓库下载离线包，然后使用“导入脚本”手动导入。" or
          "检查失败。可前往脚本仓库下载离线包，然后使用“导入脚本”手动导入。")),
      }, { gap = 16, cross = "center" })
    end,
    actions = {
      { label = "关闭", variant = "text" },
      { label = "打开脚本仓库", variant = "text", onTap = function()
        host.open_url(INSTALLER_REPOSITORY_URL)
      end },
      { label = "重试", variant = "tonal", onTap = function()
        host.close_dialog()
        host.delay(50, function() check_then_offer_installer_update(on_updated) end)
      end },
    },
  })
end

local function show_installer_check_result(script, on_updated)
  local checked = installer.read_check_result()
  local output = checked.output or ""
  local current = output:match("Current version:%s*([^%s]+)")
  local remote = output:match("Verified remote version:%s*([^%s]+)")

  if checked.code ~= 0 or not remote then
    show_installer_check_failure(false, on_updated)
    return
  end

  local update_available = current == "not-installed" or
    compare_versions(current, remote) == -1
  if not update_available then
    host.dialog({
      title = "安装脚本更新",
      build = function()
        return row({
          icon("check_circle_outline", { color = "green" }),
          expanded(text("当前已是最新安装脚本。")),
        }, { gap = 16, cross = "center" })
      end,
      actions = { { label = "关闭", variant = "text" } },
    })
    return
  end

  local first_download = script.state == "missing"
  host.dialog({
    title = "安装脚本更新",
    build = function()
      return row({
        icon("system_update_alt"),
        expanded(text(first_download and "已找到可用安装脚本，是否立即下载？" or
          "发现新版安装脚本，是否立即更新？")),
      }, { gap = 16, cross = "center" })
    end,
    actions = {
      { label = "关闭", variant = "text" },
      { label = first_download and "立即下载" or "立即更新", variant = "filled", onTap = function()
        host.close_dialog()
        update_installer(on_updated)
      end },
    },
  })
end

check_then_offer_installer_update = function(on_updated)
  local script = installer_script_info()
  installer_check_generation = installer_check_generation + 1
  local generation = installer_check_generation
  host.dialog({
    title = "安装脚本更新",
    build = function()
      return row({
        spinner({ size = 24 }),
        expanded(text("正在检查安装脚本更新，请稍候…")),
      }, { gap = 16, cross = "center" })
    end,
    actions = {
      { label = "取消", variant = "text", onTap = function()
        installer_check_generation = installer_check_generation + 1
        host.stop("installer-check")
        host.close_dialog()
      end },
    },
  })
  installer.check({
    title = "检查安装脚本更新",
    key = "installer-check",
    on_exit = function()
      if generation ~= installer_check_generation then return end
      installer_check_generation = installer_check_generation + 1
      host.close_dialog()
      show_installer_check_result(script, on_updated)
    end,
  })
  host.delay(60000, function()
    if generation ~= installer_check_generation then return end
    installer_check_generation = installer_check_generation + 1
    host.stop("installer-check")
    host.close_dialog()
    show_installer_check_failure(true, on_updated)
  end)
end

local function import_installer_package(on_exit)
  host.input({
    title = "导入离线安装脚本包",
    hint = "/sdcard/Download/astrbot-installer-offline.tar.gz",
  }, function(path)
    if not path or path == "" then return end
    if installer.import(path, {
      title = "导入安装脚本包",
      key = "installer-import",
      on_exit = on_exit,
    }) then
      host.nav.go(2)
    end
  end)
end

-- ============================================================
-- AstrBot 启停: 纯 Lua, 通过通用原语 host.spawn/host.stop, 运行态读 ctx.running
-- 一操作一终端标签页, 手动模式, 无进度/webview 监听
-- ============================================================
local function astrbot_start_command()
  return table.concat({
    "export TMPDIR='" .. host.tmp_path() .. "'",
    "export ASTRBOT_DASHBOARD_PORT='" .. tostring(ports.get("dashboard")) .. "'",
    "if [ ! -x /root/.local/bin/uv ] || [ ! -d /root/AstrBot ] || [ ! -f /root/AstrBot/pyproject.toml ] || [ ! -f /root/AstrBot/main.py ] || [ ! -d /root/AstrBot/.venv ]; then echo 'AstrBot 环境未安装完整，请到主页环境管理安装。'; exit 1; fi",
    "cd /root/AstrBot",
    "echo 'AstrBot 启动中'",
    "/root/.local/bin/uv run --no-sync main.py",
  }, "; ")
end

function astrbot_toggle(running)
  if running then
    host.stop("astrbot")
  else
    host.spawn(astrbot_start_command(), "AstrBot", "astrbot")
    host.nav.go(2)
  end
end

-- ============================================================
-- NapCat: 实例管理 / 启停 / BOT 绑定 —— 全部纯 Lua
-- 数据存 host.get/set("napcat_instances") (JSON), 配置文件直接读写 rootfs,
-- 启停走 host.spawn/host.stop (key = "napcat:<id>"), 运行态读 ctx.running。
-- Dart 侧不含任何 NapCat 逻辑。
-- ============================================================
local NC = {}
local WEBUI_FIRST, WEBUI_LAST = 6099, 6149
local DISPLAY_FIRST = 22
local ONEBOT_FIRST, ONEBOT_LAST = 6199, 6249
local WS_NAME = "WsClient"
-- 每个 NapCat 实例使用独立随机 token (创建时生成并持久化到实例), NapCat 反向 ws 与
-- AstrBot 适配器共用同一个, 保证一一对应、互不串号。
local function gen_token() return host.random_bytes(16, "hex") end
local function nc_token(ins)
  if not ins.wsToken or ins.wsToken == "" then
    ins.wsToken = gen_token()
    local list = NC.load(); local _, cur = NC.find(list, ins.id)
    if cur and cur ~= ins then cur.wsToken = ins.wsToken; NC.save(list) end
  end
  return ins.wsToken
end

local function nc_root() return host.ubuntu_path() .. "/root" end
local function nc_workdir(id) return nc_root() .. "/napcat_instances/" .. id .. "_napcat" end
local function nc_configdir(id) return nc_workdir(id) .. "/config" end

local function napcat_x_display()
  local d, o, n = ports.get("dashboard"), ports.get("onebot"), ports.get("napcat")
  if d == 6185 and o == 6199 and n == 6099 then return 1 end
  return 10 + d % 80
end

function NC.load()
  local raw = host.get("napcat_instances")
  if type(raw) == "string" and raw ~= "" then
    local ok, v = pcall(json.decode, raw)
    if ok and type(v) == "table" then return v end
  end
  return {}
end

function NC.save(list) host.set("napcat_instances", json.encode(list)) end

function NC.find(list, id)
  for i, v in ipairs(list) do if v.id == id then return i, v end end
end

local function looks_like_qq(value)
  local qq = tostring(value or ""):match("^%s*([1-9]%d+)%s*$")
  return qq and #qq >= 5 and #qq <= 12 and qq or nil
end

local function qq_from_name(name)
  name = tostring(name or "")
  local lower = name:lower()
  for _, prefix in ipairs({ "napcat_", "napcat_protocol_", "onebot11_" }) do
    local qq = lower:match("^" .. prefix .. "([1-9]%d+)%.json$")
    if looks_like_qq(qq) then return qq end
  end
  for _, key in ipairs({ "uin", "account", "user", "qq", "napcat", "onebot" }) do
    local qq = lower:match(key .. "[_-]?([1-9]%d+)")
    if looks_like_qq(qq) then return qq end
  end
  return nil
end

local function qq_from_config(text)
  if type(text) ~= "string" then return nil end
  local qq = text:match('"[Uu][Ii][Nn]"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"self_[Uu][Ii][Nn]"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"self[Uu][Ii][Nn]"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"self_[Ii][Dd]"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"self[Ii]d"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"user_[Ii][Dd]"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"user[Ii]d"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"account[Uu][Ii][Nn]"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"account"%s*:%s*"?([1-9]%d+)"?') or
    text:match('"[Qq][Qq]"%s*:%s*"?([1-9]%d+)"?') or
    text:match('[Uu][Ii][Nn]%s*=%s*"?([1-9]%d+)"?') or
    text:match('[Qq][Qq]%s*=%s*"?([1-9]%d+)"?')
  return looks_like_qq(qq)
end

local function scan_qq_tree(root, budget)
  if not host.exists(root) or budget.files >= 120 or budget.dirs >= 200 then return nil end
  budget.dirs = budget.dirs + 1
  for _, entry in ipairs(host.list_dir(root) or {}) do
    local qq = qq_from_name(entry.name)
    if qq then return qq end
    local lower = tostring(entry.path or entry.name or ""):lower():gsub("\\", "/")
    local entryName = tostring(entry.name or ""):lower()
    local ignored = entryName == "log" or entryName == "logs" or entryName == "cache" or
      entryName == "chat" or entryName == "message" or entryName == "messages" or
      lower:find("/logs/", 1, true) or lower:find("/cache/", 1, true) or
      lower:find("/chat/", 1, true) or lower:find("/messages/", 1, true)
    if entry.isDir then
      if not ignored then
        qq = scan_qq_tree(entry.path, budget)
        if qq then return qq end
      end
    elseif not ignored and budget.files < 120 and
        (lower:match("%.json$") or lower:match("%.ini$") or lower:match("%.conf$") or lower:match("%.config$")) then
      budget.files = budget.files + 1
      qq = qq_from_config(host.read_file(entry.path))
      if qq then return qq end
    end
  end
  return nil
end

-- 与泡泡版一致：优先读 NapCat 的快速登录账号，再从实例登录态文件中识别 QQ。
function NC.detect_qq(id)
  local webui = host.read_file(nc_configdir(id) .. "/webui.json")
  if webui then
    local ok, cfg = pcall(json.decode, webui)
    local qq = ok and type(cfg) == "table" and looks_like_qq(cfg.autoLoginAccount) or nil
    if qq then return qq end
  end
  for _, entry in ipairs(host.list_dir(nc_configdir(id)) or {}) do
    local qq = qq_from_name(entry.name)
    if qq then return qq end
  end
  local budget = { files = 0, dirs = 0 }
  return scan_qq_tree(nc_root() .. "/napcat_instances/" .. id .. "_home", budget) or
    scan_qq_tree(nc_workdir(id), budget)
end

-- ---------- onebot 配置 ----------
local function ws_url(port) return "ws://localhost:" .. port .. "/ws" end
local function ws_port_of(url) return tonumber((tostring(url or "")):match("^wss?://[^/:]+:(%d+)")) end

local function build_onebot_config(port, token)
  return {
    network = {
      httpServers = {}, httpClients = {}, websocketServers = {},
      websocketClients = {
        { name = WS_NAME, enable = true, url = ws_url(port), messagePostFormat = "array",
          reportSelfMessage = false, reconnectInterval = 5000, token = token,
          debug = false, heartInterval = 30000 },
      },
    },
    musicSignUrl = "", enableLocalFile2Url = false, parseMultMsg = false,
  }
end

-- 确保该实例的 onebot 反向 ws 客户端配置正确 (模板 + 已登录账号文件都写)。
-- 每个实例固定一个 ws client (WS_NAME), 指向本实例 oneBotPort, 用本实例随机 token。
function NC.ensure_ws(ins)
  local id = ins.id
  local port = ins.oneBotPort or ONEBOT_FIRST
  local token = nc_token(ins)
  host.mkdirs(nc_configdir(id))
  local client = {
    name = WS_NAME, enable = true, url = ws_url(port), messagePostFormat = "array",
    reportSelfMessage = false, reconnectInterval = 5000, token = token,
    debug = false, heartInterval = 30000,
  }
  local files = { nc_configdir(id) .. "/onebot11.json" }
  local qq = NC.detect_qq(id)
  if qq then files[#files + 1] = nc_configdir(id) .. "/onebot11_" .. qq .. ".json" end
  for _, p in ipairs(files) do
    local cfg
    local t = host.read_file(p)
    if t then local ok, v = pcall(json.decode, t); if ok and type(v) == "table" then cfg = v end end
    if not cfg then cfg = build_onebot_config(port, token) end
    cfg.network = type(cfg.network) == "table" and cfg.network or {}
    cfg.network.httpServers      = cfg.network.httpServers or {}
    cfg.network.httpClients      = cfg.network.httpClients or {}
    cfg.network.websocketServers = cfg.network.websocketServers or {}
    cfg.network.websocketClients = { client }
    host.write_file(p, json.encode(cfg))
  end
end

-- 初始化模板 (不存在才写); 已存在则交给 ensure_ws 修正
function NC.ensure_onebot(ins)
  NC.ensure_ws(ins)
end

-- ---------- AstrBot cmd_config (aiocqhttp 适配器) ----------
-- 绑定模型 (多实例, 全自动): 每个 NapCat 账号在 AstrBot 里独占一条 aiocqhttp 适配器,
--   ws_reverse_port = 本账号 oneBotPort, ws_reverse_token = 固定 token。
--   创建账号 → 自动写入; 退出/删除账号 → 自动移除。不再替换预置 cmd_config.json。
local function astrbot_config_path()
  return host.ubuntu_path() .. "/root/AstrBot/data/cmd_config.json"
end

local function read_astrbot_config()
  local t = host.read_file(astrbot_config_path())
  if not t then return nil end
  local ok, v = pcall(json.decode, t)
  if ok and type(v) == "table" then return v end
  return nil
end

local function write_astrbot_config(cfg)
  host.write_file(astrbot_config_path(), json.encode(cfg))
end

function NC.list_adapters()
  local cfg = read_astrbot_config()
  local res = {}
  if not cfg or type(cfg.platform) ~= "table" then return res end
  for _, item in ipairs(cfg.platform) do
    if type(item) == "table" and item.type == "aiocqhttp" then
      res[#res + 1] = {
        id = tostring(item.id or ""), enabled = item.enable ~= false,
        port = tonumber(item.ws_reverse_port) or -1,
        token = tostring(item.ws_reverse_token or ""),
      }
    end
  end
  return res
end

local function unique_adapter_id(base, cfg)
  base = (base and base:gsub("^%s+", ""):gsub("%s+$", "") ~= "") and base or "NapCat"
  local used = {}
  if type(cfg.platform) == "table" then
    for _, it in ipairs(cfg.platform) do if type(it) == "table" and it.id then used[tostring(it.id)] = true end end
  end
  if not used[base] then return base end
  local i = 2
  while used[base .. i] do i = i + 1 end
  return base .. i
end

-- ---------- 绑定 (全自动: 创建账号即写入适配器) ----------
-- 在 AstrBot 配置里为该实例建/改适配器 (端口/token 对齐本实例)。
-- 返回: "created" 新建 | "ok" 已同步 | "nocfg" AstrBot 尚未安装/无配置
function NC.sync_adapter(ins)
  local cfg = read_astrbot_config()
  if not cfg then return "nocfg" end
  if type(cfg.platform) ~= "table" then cfg.platform = {} end
  local port = ins.oneBotPort or ONEBOT_FIRST
  local token = nc_token(ins)
  local target
  if ins.boundAdapterId and ins.boundAdapterId ~= "" then
    for _, item in ipairs(cfg.platform) do
      if type(item) == "table" and item.id == ins.boundAdapterId then target = item; break end
    end
  end
  local created = false
  if not target then
    local aid = unique_adapter_id(ins.name, cfg)
    target = { id = aid, type = "aiocqhttp" }
    cfg.platform[#cfg.platform + 1] = target
    ins.boundAdapterId = aid
    created = true
  end
  target.type = "aiocqhttp"
  target.enable = true
  target.ws_reverse_host = "0.0.0.0"
  target.ws_reverse_port = port
  target.ws_reverse_token = token
  write_astrbot_config(cfg)
  -- 回写 boundAdapterId 到持久列表
  local list = NC.load(); local _, cur = NC.find(list, ins.id)
  if cur then
    cur.boundAdapterId = ins.boundAdapterId
    cur.boundWebSocketName = WS_NAME
    NC.save(list)
  end
  return created and "created" or "ok"
end

-- 从 AstrBot 配置移除该实例的适配器 (退出登录 / 删除账号时)
function NC.unbind_adapter(ins)
  if not ins.boundAdapterId or ins.boundAdapterId == "" then return end
  local cfg = read_astrbot_config()
  if not cfg or type(cfg.platform) ~= "table" then return end
  local changed = false
  for i = #cfg.platform, 1, -1 do
    local item = cfg.platform[i]
    if type(item) == "table" and item.id == ins.boundAdapterId then
      table.remove(cfg.platform, i); changed = true
    end
  end
  if changed then write_astrbot_config(cfg) end
end

local function NC_ws_client(ins)
  local qq = looks_like_qq(ins.qq) or NC.detect_qq(ins.id)
  local paths = {}
  if qq then paths[#paths + 1] = nc_configdir(ins.id) .. "/onebot11_" .. qq .. ".json" end
  paths[#paths + 1] = nc_configdir(ins.id) .. "/onebot11.json"
  local wanted = tostring(ins.boundWebSocketName or WS_NAME)
  for _, path in ipairs(paths) do
    local raw = host.read_file(path)
    if raw then
      local ok, cfg = pcall(json.decode, raw)
      local network = ok and type(cfg) == "table" and cfg.network or nil
      local clients = type(network) == "table" and network.websocketClients or nil
      if type(clients) == "table" then
        for _, client in ipairs(clients) do
          if type(client) == "table" and tostring(client.name or "") == wanted then
            return {
              enabled = client.enable ~= false,
              port = ws_port_of(client.url),
              token = tostring(client.token or ""),
            }
          end
        end
      end
    end
  end
  return nil
end

-- 绑定状态: "configured" 两边已启用且端口/token 一致 | "disabled" 配置一致但至少一边已禁用 |
--           "mismatch" 两边配置存在但端口/token 不一致 | "unbound" 任一边配置不存在 |
--           "nocfg" AstrBot 未安装
function NC.binding_state(ins)
  if not read_astrbot_config() then return "nocfg" end
  local client = NC_ws_client(ins)
  if not client then return "unbound" end
  for _, a in ipairs(NC.list_adapters()) do
    if a.id == ins.boundAdapterId and ins.boundAdapterId ~= "" then
      if a.port == client.port and a.token == client.token then
        return (a.enabled and client.enabled) and "configured" or "disabled"
      end
      return "mismatch"
    end
  end
  return "unbound"
end

-- ---------- launcher 脚本 ----------
local LAUNCHER_TMPL = [==[
#!/bin/bash
set -u

BASE_HOME="/root"
INSTANCE_ID='__ID__'
INSTANCE_HOME="$BASE_HOME/napcat_instances/${INSTANCE_ID}_home"
INSTANCE_WORKDIR="$BASE_HOME/napcat_instances/${INSTANCE_ID}_napcat"
INSTANCE_DISPLAY="__DISPLAY__"
WEBUI_PORT="__PORT__"

mkdir -p "$INSTANCE_HOME" "$INSTANCE_WORKDIR/config" "$INSTANCE_WORKDIR/logs" "$INSTANCE_WORKDIR/cache"
mkdir -p "$INSTANCE_HOME/.config" "$INSTANCE_HOME/.cache" "$INSTANCE_HOME/.local/share"

if [ -d "$BASE_HOME/napcat/config" ]; then
  cp -n "$BASE_HOME/napcat/config/"*.json "$INSTANCE_WORKDIR/config/" 2>/dev/null || true
fi

cat > "$INSTANCE_WORKDIR/config/webui.json" <<'WEBUIEOF'
__WEBUI_JSON__
WEBUIEOF

echo "[napcat-instance] id=$INSTANCE_ID"
echo "[napcat-instance] DISPLAY=:$INSTANCE_DISPLAY"
echo "[napcat-instance] NAPCAT_WORKDIR=$INSTANCE_WORKDIR"
echo "[napcat-instance] WEBUI_PORT=$WEBUI_PORT"

if [ -f "$INSTANCE_WORKDIR/xvfb.pid" ]; then
  kill "$(cat "$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null || true
fi
pkill -f "Xvfb :$INSTANCE_DISPLAY" 2>/dev/null || true
rm -f "/tmp/.X${INSTANCE_DISPLAY}-lock" "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

Xvfb ":$INSTANCE_DISPLAY" -screen 0 800x600x16 +extension GLX +render > "$INSTANCE_WORKDIR/xvfb.log" 2>&1 &
echo "$!" > "$INSTANCE_WORKDIR/xvfb.pid"
for i in $(seq 1 50); do
  if [ -S "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" ]; then
    break
  fi
  if ! kill -0 "$(cat "$INSTANCE_WORKDIR/xvfb.pid")" 2>/dev/null; then
    echo "[napcat-instance] Xvfb 启动失败"
    cat "$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
    exit 1
  fi
  sleep 0.1
done
if [ ! -S "/tmp/.X11-unix/X${INSTANCE_DISPLAY}" ]; then
  echo "[napcat-instance] Xvfb 未就绪，无法启动 QQ"
  cat "$INSTANCE_WORKDIR/xvfb.log" 2>/dev/null || true
  exit 1
fi
export DISPLAY=":$INSTANCE_DISPLAY"
export NAPCAT_WORKDIR="$INSTANCE_WORKDIR"
export HOME="$INSTANCE_HOME"
export XDG_CONFIG_HOME="$INSTANCE_HOME/.config"
export XDG_CACHE_HOME="$INSTANCE_HOME/.cache"
export XDG_DATA_HOME="$INSTANCE_HOME/.local/share"

mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"

cd "$BASE_HOME"
trap "" SIGPIPE
LD_PRELOAD=./libnapcat_launcher.so qq --no-sandbox
]==]

function NC.write_launcher(ins)
  local webui = json.encode({
    host = "0.0.0.0", port = ins.webUiPort, prefix = "", token = "",
    loginRate = 3, autoLoginAccount = ins.qq or "",
  })
  local s = LAUNCHER_TMPL
  s = s:gsub("__ID__", (ins.id:gsub("%%", "%%%%")))
  s = s:gsub("__DISPLAY__", tostring(ins.display))
  s = s:gsub("__PORT__", tostring(ins.webUiPort))
  s = s:gsub("__WEBUI_JSON__", (webui:gsub("%%", "%%%%")))
  host.write_file(nc_root() .. "/launcher_" .. ins.id .. ".sh", s)
end

-- 保留 NapCat 自己写入的 token 等字段，只同步端口与快速登录账号。
function NC.patch_webui(ins)
  local path = nc_configdir(ins.id) .. "/webui.json"
  local raw = host.read_file(path)
  if not raw then return false end
  local ok, cfg = pcall(json.decode, raw)
  if not ok or type(cfg) ~= "table" then return false end
  cfg.port = ins.webUiPort
  cfg.autoLoginAccount = ins.qq or ""
  host.write_file(path, json.encode(cfg))
  return true
end

-- 扫码成功后把 QQ 回写到实例存储；下次启动器会将其写入 autoLoginAccount。
function NC.capture_login(id, notify)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return nil end
  local saved = looks_like_qq(ins.qq)
  if saved then return saved end
  local qq = NC.detect_qq(id)
  if not qq then return nil end
  ins.qq = qq
  ins.autoLogin = true
  ins.qqAutoDetected = true
  NC.save(list)
  NC.patch_webui(ins)
  NC.ensure_ws(ins)
  NC.write_launcher(ins)
  host.log("NapCat " .. (ins.name or id) .. " 已保存快速登录账号 " .. qq)
  if notify then host.toast("已保存 QQ " .. qq .. "，下次可快速登录") end
  return qq
end

function NC.schedule_qq_probe(id)
  -- Lua 层拿不到泡泡版的终端登录事件，因此覆盖完整二维码有效期继续探测。
  for _, delay in ipairs({ 3000, 10000, 30000, 60000, 90000, 120000 }) do
    host.delay(delay, function() NC.capture_login(id, true) end)
  end
end

-- ---------- 生命周期 ----------
function NC.add(name)
  local list = NC.load()
  local usedDisp = { [napcat_x_display()] = true }
  for _, v in ipairs(list) do usedDisp[v.display] = true end
  local display
  for d = DISPLAY_FIRST, 99 do if not usedDisp[d] then display = d; break end end
  if not display then host.toast("没有可用 DISPLAY"); return end

  local wexcl = { ports.get("dashboard"), ports.get("onebot") }
  for _, v in ipairs(list) do wexcl[#wexcl + 1] = v.webUiPort end
  host.free_port(WEBUI_FIRST, WEBUI_LAST, wexcl, function(webPort)
    if not webPort then host.toast("没有可用 WebUI 端口"); return end
    local oexcl = { ports.get("dashboard") }
    for _, v in ipairs(list) do if v.oneBotPort then oexcl[#oexcl + 1] = v.oneBotPort end end
    host.free_port(ONEBOT_FIRST, ONEBOT_LAST, oexcl, function(obPort)
      if not obPort then host.toast("没有可用 OneBot 端口"); return end
      local idx = #list + 1
      local nm = (name and name:gsub("^%s+", ""):gsub("%s+$", "") ~= "") and name or ("账号" .. idx)
      local ins = {
        id = "qq" .. idx .. "_" .. tostring(os.time()) .. tostring(math.random(1000, 9999)),
        name = nm, qq = "", webUiPort = webPort, display = display,
        oneBotPort = obPort, token = "", wsToken = gen_token(),
        autoLogin = false, qqAutoDetected = false,
        boundWebSocketName = WS_NAME, boundAdapterId = "",
      }
      list[#list + 1] = ins
      NC.save(list)
      NC.ensure_onebot(ins)
      -- 创建即绑定: 在 AstrBot 里写入对应 aiocqhttp 适配器 (AstrBot 未装则跳过, 启动时补绑)
      local r = NC.sync_adapter(ins)
      if r == "created" or r == "ok" then host.toast("已创建 " .. nm .. " 并绑定 AstrBot 适配器")
      else host.toast("已创建 " .. nm .. " (AstrBot 未安装, 启动后自动绑定)") end
    end)
  end)
end

function NC.edit(id, name, webPort)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return end
  if name and name ~= "" then ins.name = name end
  if webPort and webPort ~= ins.webUiPort then
    if webPort < WEBUI_FIRST or webPort > WEBUI_LAST then
      host.toast("WebUI 端口需在 " .. WEBUI_FIRST .. "-" .. WEBUI_LAST); return
    end
    for _, v in ipairs(list) do
      if v.id ~= id and v.webUiPort == webPort then host.toast("端口已被占用"); return end
    end
    ins.webUiPort = webPort
  end
  NC.save(list)
  NC.write_launcher(ins)
end

function NC.start(id)
  -- 若脚本曾在扫码后重载，先从仍在磁盘上的登录态补一次账号识别。
  NC.capture_login(id, false)
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return end
  NC.ensure_ws(ins)
  NC.sync_adapter(ins)   -- 补绑: 若创建时 AstrBot 尚未安装, 此处补上适配器
  NC.patch_webui(ins)
  NC.write_launcher(ins)
  local cmd = "echo [napcat] run launcher_" .. id .. ".sh; " ..
    "chmod +x /root/launcher_" .. id .. ".sh; bash /root/launcher_" .. id .. ".sh"
  host.spawn(cmd, ins.name or id, "napcat:" .. id)
  if not looks_like_qq(ins.qq) then NC.schedule_qq_probe(id) end
  host.nav.go(2)
end

local function nc_cleanup_cmd(id, display)
  local c = {
    'if [ -f /root/napcat_instances/' .. id .. '_napcat/qq.pid ]; then kill "$(cat /root/napcat_instances/' .. id .. '_napcat/qq.pid)" 2>/dev/null || true; fi',
    'if [ -f /root/napcat_instances/' .. id .. '_napcat/xvfb.pid ]; then kill "$(cat /root/napcat_instances/' .. id .. '_napcat/xvfb.pid)" 2>/dev/null || true; fi',
    'pkill -f "launcher_' .. id .. '.sh" || true',
    'pkill -f "napcat_instances/' .. id .. '_napcat" || true',
    'pkill -f "napcat_instances/' .. id .. '_home" || true',
  }
  if display and display > 0 then c[#c + 1] = 'pkill -f "Xvfb :' .. display .. '" || true' end
  c[#c + 1] = 'rm -f /root/napcat_instances/' .. id .. '_napcat/qq.pid'
  c[#c + 1] = 'rm -f /root/napcat_instances/' .. id .. '_napcat/xvfb.pid'
  return table.concat(c, "; ")
end

function NC.stop(id)
  host.stop("napcat:" .. id)
  -- 停止前后登录态文件仍在，兜底保存错过定时探测的扫码账号。
  NC.capture_login(id, false)
  local list = NC.load(); local _, ins = NC.find(list, id)
  host.exec(nc_cleanup_cmd(id, ins and ins.display or -1))
end

function NC.logout(id)
  NC.stop(id)
  host.exec('rm -rf /root/napcat_instances/' .. id .. '_napcat; ' ..
    'rm -rf /root/napcat_instances/' .. id .. '_home; rm -f /root/launcher_' .. id .. '.sh')
  local list = NC.load(); local _, ins = NC.find(list, id)
  if ins then
    NC.unbind_adapter(ins)   -- 从 AstrBot 移除该账号的适配器
    ins.qq = ""; ins.token = ""; ins.autoLogin = false; ins.qqAutoDetected = false
    ins.boundWebSocketName = ""; ins.boundAdapterId = ""
    NC.save(list)
  end
end

function NC.delete(id)
  NC.logout(id)
  local list = NC.load(); local i = NC.find(list, id)
  if i then table.remove(list, i); NC.save(list) end
end

-- NapCat 会把 WebUI 登录 token 写入实例配置文件。每次需要打开/复制
-- WebUI 时直接读取文件，避免依赖容易漏日志或串实例的终端输出监听。
function NC.read_webui_token(ins)
  if not ins or not ins.id then return "" end
  local body = host.read_file(nc_configdir(ins.id) .. "/webui.json")
  if not body or body == "" then return tostring(ins.token or "") end

  local ok, cfg = pcall(json.decode, body)
  if not ok or type(cfg) ~= "table" then return tostring(ins.token or "") end
  local token = tostring(cfg.token or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if token == "" then return tostring(ins.token or "") end

  if ins.token ~= token then
    ins.token = token
    local list = NC.load()
    local _, saved = NC.find(list, ins.id)
    if saved and saved.token ~= token then
      saved.token = token
      NC.save(list)
    end
  end
  return token
end

function NC.webui_url(ins)
  local token = NC.read_webui_token(ins)
  local url = "http://127.0.0.1:" .. ins.webUiPort .. "/webui"
  if token ~= "" then url = url .. "?token=" .. token end
  return url
end

-- ============================================================
-- 主页 UI
-- ============================================================

local function quick_start_card(ctx)
  local running = ctx.running and ctx.running["astrbot"]
  local dash = ports.get("dashboard")
  return card("AstrBot", {
    tile("监听端口", {
      icon = "settings_ethernet",
      subtitle = "127.0.0.1:" .. dash,
      trailing = iconbutton("edit_outlined", function()
        host.input({ title = "AstrBot 监听端口", default = tostring(dash), hint = "6185" }, function(v)
          if v and v ~= "" and tonumber(v) then
            ports.set("dashboard", tonumber(v))
            host.toast("端口已保存，重启 AstrBot 后生效")
          end
        end)
      end),
    }),
    spacer(12),
    row({
      expanded(button(running and "停止" or "启动 AstrBot", function()
        astrbot_toggle(running)
      end, { icon = running and "stop" or "play_arrow" })),
      expanded(button("打开 WebUI", function()
        host.webview_open("http://127.0.0.1:" .. dash .. "/", "AstrBot")
      end, { variant = "tonal", icon = "language" })),
    }, { gap = 12 }),
  })
end

local function env_card()
  local revision = state("environment.rev", 0)
  revision.get()
  local script = installer_script_info()
  local script_ready = script.state == "valid"
  local script_label = script_ready and ("v" .. script.version) or
    (script.state == "unknown" and "未知版本" or "脚本未下载")
  local installed = {}
  for _, step in ipairs(ENV_STEPS) do installed[step.id] = env_installed(step.id) end
  local function refresh_after_exit()
    revision.set(revision.get() + 1)
  end
  local children = {
    tile("GitHub 代理", {
      icon = "cloud_sync_outlined",
      subtitle = "当前: " .. gh_proxy_label(gh_proxy()) .. " · 点击测速并选择镜像",
      trailing = icon("chevron_right"),
      onTap = open_gh_dialog,
    }),
    row({
      expanded(button(script.state == "missing" and "下载脚本" or "更新脚本", function()
        check_then_offer_installer_update(refresh_after_exit)
      end, { variant = "filled", icon = "system_update_alt" })),
      expanded(button("导入脚本", function()
        import_installer_package(refresh_after_exit)
      end, { variant = "outlined", icon = "upload_file" })),
    }, { gap = 12 }),
  }
  for _, s in ipairs(ENV_STEPS) do
    local done = installed[s.id]
    local enabled = env_step_enabled(s.id, installed, script_ready)
    children[#children + 1] = tile(s.title, {
      icon = not enabled and "lock_outline" or (done and "check_circle" or "error_outline"),
      iconColor = not enabled and "grey" or (done and "green" or "orange"),
      subtitle = enabled and s.sub or
        (script_ready and "请先安装上方依赖项" or "请先下载或更新脚本"),
      trailing = button(done and "重装" or "安装", enabled and function()
        STEP_RUN[s.id](done)
      end or nil, { variant = "tonal" }),
    })
  end
  return expansion("环境管理 · " .. script_label, children, { icon = "build_outlined" })
end

local function add_napcat()
  host.input({ title = "新建 NapCat 账号", hint = "账号备注名 (留空自动命名)" }, function(name)
    NC.add(name or "")
  end)
end

-- BOT 绑定对话框: 现在绑定是全自动的 (创建账号即写入适配器)。
-- 这里只展示绑定状态, 并提供「重新对齐」以应对刚扫码登录 / 手动改过配置的情况。
local function bind_bot_dialog(ins)
  local id = ins.id
  host.dialog({
    title = "BOT 绑定",
    build = function()
      local list = NC.load(); local _, cur = NC.find(list, id)
      cur = cur or ins
      local st = NC.binding_state(cur)
      local map = {
        configured = { "已绑定 · 端口/令牌一致", "green" },
        disabled   = { "已禁用 · websocket 或 AstrBot 适配器开关未开启", "red" },
        mismatch   = { "适配器与账号端口/令牌不一致, 点下方重新对齐", "orange" },
        unbound    = { "AstrBot 中尚无该账号适配器, 点下方创建", "grey" },
        nocfg      = { "AstrBot 尚未安装 (启动后自动绑定)", "red" },
      }
      local info = map[st] or map.unbound
      return column({
        chip(info[1], { color = info[2] }),
        text(cur.name or id, { weight = "bold" }),
        text("反向 WS 端口 " .. tostring(cur.oneBotPort or "?"), { size = 12, color = "grey" }),
        text("适配器 " .. ((cur.boundAdapterId ~= "" and cur.boundAdapterId) or "(未创建)")
          .. " · token " .. ((cur.wsToken and cur.wsToken ~= "") and "随机(已设置)" or "空"),
          { size = 12, color = "grey" }),
        text("创建账号时已自动在 AstrBot 写入 aiocqhttp 适配器; 无需手动配置 pre-config。",
          { size = 12, color = "grey" }),
      }, { cross = "stretch", gap = 8 })
    end,
    actions = {
      { label = "关闭", variant = "text" },
      { label = "重新对齐", variant = "filled", onTap = function()
        local list = NC.load(); local _, cur = NC.find(list, id)
        if not cur then return end
        NC.ensure_ws(cur)
        local r = NC.sync_adapter(cur)
        if r == "nocfg" then host.toast("AstrBot 尚未安装, 启动后会自动绑定")
        else host.toast("已重新对齐, 重启 AstrBot 生效") end
      end },
    },
  })
end

local function napcat_tile(ins)
  local running = ins.running
  local logged = ins.qq and ins.qq ~= ""
  local webuiToken = NC.read_webui_token(ins)
  return tile(ins.name, {
    icon = running and "play_circle" or "pause_circle_outline",
    iconColor = running and "green" or nil,
    subtitle = "QQ " .. (logged and ins.qq or "未登录，启动后扫码") .. "\nWebUI " .. tostring(ins.webUiPort),
    trailing = row({
      iconbutton("language", function() host.webview_open(NC.webui_url(ins), ins.name) end, { tooltip = "打开 WebUI" }),
      iconbutton(running and "stop" or "play_arrow", function()
        if running then NC.stop(ins.id) else NC.start(ins.id) end
      end, { tooltip = running and "停止" or "启动" }),
      menu("more_vert", {
        { label = "编辑", onTap = function()
          host.input({ title = "编辑账号名", default = ins.name }, function(name)
            if name and name ~= "" then NC.edit(ins.id, name, ins.webUiPort) end
          end)
        end },
        { label = "绑定 BOT", onTap = function() bind_bot_dialog(ins) end },
        { label = "复制 token", enabled = webuiToken ~= "", onTap = function()
          local token = NC.read_webui_token(ins)
          if token == "" then host.toast("尚未读取到 WebUI token"); return end
          host.clipboard.copy(token); host.toast("已复制 token")
        end },
        { label = "复制完整链接", onTap = function()
          host.clipboard.copy(NC.webui_url(ins)); host.toast("已复制链接")
        end },
        { label = "退出登录", onTap = function()
          host.confirm("确定退出该账号登录?", function(y) if y then NC.logout(ins.id) end end)
        end },
        { label = "删除", onTap = function()
          host.confirm("确定删除该账号?", function(y) if y then NC.delete(ins.id) end end)
        end },
      }),
    }, { main = "end" }),
  })
end

local function napcat_card(ctx)
  local children = {
    row({
      icon("pets"),
      spacer(8),
      expanded(text("NapCat 账号", { weight = "bold", size = 16 })),
      iconbutton("add", function() add_napcat() end, { tooltip = "添加账号" }),
    }, { cross = "center" }),
  }
  local list = NC.load()
  if #list == 0 then
    children[#children + 1] = padding(text("暂无账号，点击右上角 + 添加", { color = "grey" }), 8)
  else
    for _, ins in ipairs(list) do
      ins.running = ctx.running and ctx.running["napcat:" .. ins.id] or false
      children[#children + 1] = napcat_tile(ins)
    end
  end
  return card(nil, children)
end

local function do_backup(cb)
  local ub = host.ubuntu_path()
  if not host.exists(ub .. "/root/AstrBot/data") then
    host.toast("AstrBot 数据目录不存在"); if cb then cb(false) end; return
  end
  local dir = host.backup_dir()
  host.mkdirs(dir)
  local name = "AstrBotBubble-backup-" .. os.date("%Y%m%d-%H%M%S") .. ".tar.gz"
  local path = dir .. "/" .. name
  host.run(host.bin_path() .. "/busybox",
    { "tar", "-czf", path, "-C", ub .. "/root/AstrBot", "data" },
    function(res)
      if res.code == 0 then
        host.toast("备份成功: " .. name); if cb then cb(true) end
      else
        host.toast("备份失败: " .. (res.stderr or "")); if cb then cb(false) end
      end
    end)
end

local function do_restore()
  local dir = host.backup_dir()
  local files = {}
  for _, e in ipairs(host.list_dir(dir)) do
    if (not e.isDir) and e.name:match("^AstrBotBubble%-backup%-") and e.name:match("%.tar%.gz$") then
      files[#files + 1] = e
    end
  end
  if #files == 0 then host.toast("未找到备份文件"); return end
  host.dialog({
    title = "选择备份还原",
    build = function()
      local kids = {}
      for _, f in ipairs(files) do
        kids[#kids + 1] = tile(f.name, {
          icon = "restore",
          onTap = function()
            host.confirm("还原将覆盖当前数据，确定?", function(y)
              if y then
                local ub = host.ubuntu_path()
                host.run(host.bin_path() .. "/busybox",
                  { "tar", "-xzf", f.path, "-C", ub .. "/root/AstrBot" },
                  function(res)
                    host.close_dialog()
                    if res.code == 0 then
                      host.toast("还原成功，应用即将退出"); host.exit_app()
                    else
                      host.toast("还原失败: " .. (res.stderr or ""))
                    end
                  end)
              end
            end)
          end,
        })
      end
      return column(kids, { cross = "stretch" })
    end,
  })
end

local DIAG_PREF = "astrbot_diagnostic_model_preference"
local DIAG_TITLES = {
  "应用状态", "后台运行权限", "运行环境检查", "AstrBot 和 NapCat 运行状态",
  "NapCat 连接检查", "AstrBot 配置检查", "模型连通性测试",
}
local diag = { items = {}, configs = {}, cancelled = false, completed = false, request = nil, report = "" }

local function diag_safe_error(err)
  local s = tostring(err or "未知错误")
  s = s:gsub("[Aa][Pp][Ii][_%-%s]?[Kk][Ee][Yy][^,;%s]*", "[敏感信息已隐藏]")
  s = s:gsub("[Tt][Oo][Kk][Ee][Nn][^,;%s]*", "[敏感信息已隐藏]")
  s = s:gsub("[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][^,;%s]*", "[敏感信息已隐藏]")
  s = s:gsub("https?://[^%s]+", "[地址已隐藏]")
  if #s > 180 then s = s:sub(1, 180) .. "…" end
  return s
end

local function diag_b64url(data)
  return host.base64_encode(data):gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
end

local function diag_jwt(username, secret)
  local header = diag_b64url(json.encode({ alg = "HS256", typ = "JWT" }))
  local payload = diag_b64url(json.encode({ username = username, exp = os.time() + 600 }))
  local unsigned = header .. "." .. payload
  local signature = host.hmac_sha256(secret, unsigned, true)
  return unsigned .. "." .. signature:gsub("%+", "-"):gsub("/", "_"):gsub("=", "")
end

local function diag_set(index, status, detail, rev)
  diag.items[index].status = status
  diag.items[index].detail = detail or ""
  rev.set(rev.get() + 1)
end

local function diag_read_configs()
  local root = host.ubuntu_path() .. "/root/AstrBot/data"
  local paths = { { id = "default", name = "默认配置", path = root .. "/cmd_config.json" } }
  for _, entry in ipairs(host.list_dir(root .. "/config") or {}) do
    if not entry.isDir and entry.name:match("^abconf_.*%.json$") then
      local id = entry.name:gsub("^abconf_", ""):gsub("%.json$", "")
      paths[#paths + 1] = { id = id, name = id, path = entry.path }
    end
  end
  local result = {}
  for _, info in ipairs(paths) do
    local raw = host.read_file(info.path)
    if not raw or raw == "" then return nil, "找不到或无法读取 " .. info.path:match("[^/]+$") end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= "table" then return nil, info.path:match("[^/]+$") .. " 格式错误" end
    info.data = data
    result[#result + 1] = info
  end
  return result
end

local function diag_config_name(id)
  return (diag.configNames and diag.configNames[id]) or (id == "default" and "default" or id)
end

local function diag_config_ids(adapterId)
  local ids, seen = {}, {}
  for umo, configId in pairs(diag.routes or {}) do
    local platformId = tostring(umo):match("^([^:]*):")
    if platformId == adapterId or platformId == "" or platformId == "*" then
      configId = tostring(configId)
      if not seen[configId] then ids[#ids + 1] = configId; seen[configId] = true end
    end
  end
  if #ids == 0 then ids[1] = "default" end
  return ids
end

local function diag_fetch_routing(done)
  diag.configNames, diag.routes = { default = "default" }, {}
  for _, cfg in ipairs(diag.allConfigs or {}) do
    if cfg.id ~= "default" then diag.configNames[cfg.id] = cfg.name end
  end
  local defaultCfg
  for _, cfg in ipairs(diag.allConfigs or {}) do if cfg.id == "default" then defaultCfg = cfg; break end end
  local dashboard = defaultCfg and defaultCfg.data.dashboard
  local username = type(dashboard) == "table" and tostring(dashboard.username or "") or ""
  local secret = type(dashboard) == "table" and tostring(dashboard.jwt_secret or "") or ""
  if username == "" or secret == "" then done(); return end
  local token = diag_jwt(username, secret)
  local base = "http://127.0.0.1:" .. ports.get("dashboard") .. "/api/config/"
  local function get(path, cb)
    diag.request = host.http({
      url = base .. path, method = "GET", headers = { Authorization = "Bearer " .. token }, timeout = 10,
      on_done = function(res)
        diag.request = nil
        local ok, body = pcall(json.decode, res and res.body or "")
        cb(ok and type(body) == "table" and type(body.data) == "table" and body.data or {})
      end,
      on_error = function() diag.request = nil; cb({}) end,
    })
  end
  get("abconfs", function(data)
    if type(data.info_list) == "table" then
      for _, info in ipairs(data.info_list) do
        if type(info) == "table" and info.id then
          local id, name = tostring(info.id), tostring(info.name or "")
          diag.configNames[id] = name ~= "" and name or id
        end
      end
    end
    get("umo_abconf_routes", function(routeData)
      if type(routeData.routing) == "table" then diag.routes = routeData.routing end
      done()
    end)
  end)
end

local function diag_accounts(ctx)
  local accounts = {}
  for _, ins in ipairs(NC.load()) do
    local qq = looks_like_qq(ins.qq)
    if qq then
      accounts[#accounts + 1] = {
        instance = ins,
        name = tostring(ins.name or "未命名账号"),
        qq = qq,
        running = ctx and ctx.running and ctx.running["napcat:" .. ins.id] == true,
        bindingState = NC.binding_state(ins),
      }
    end
  end
  return accounts
end

local function diag_first_non_empty(first, second, third)
  local values = { [1] = first, [2] = second, [3] = third }
  for i = 1, 3 do
    local value = values[i]
    if type(value) == "string" then
      if value:match("%S") then return value end
    elseif type(value) == "table" then
      if #value > 0 then return value end
    elseif value ~= nil then
      return value
    end
  end
  return nil
end

local function diag_value(value)
  if type(value) == "table" then
    if #value == 0 then return "未配置" end
    local values = {}
    for _, entry in ipairs(value) do values[#values + 1] = tostring(entry) end
    return table.concat(values, "、")
  end
  local text = tostring(value or "")
  return text ~= "" and text or "未配置"
end

local function diag_switch(value)
  if value == true then return "开" end
  if value == false then return "关" end
  return "未配置"
end

local function diag_wake_value(value)
  if type(value) ~= "table" then return diag_value(value) end
  local values = {}
  for _, entry in ipairs(value) do
    values[#values + 1] = '"' .. tostring(entry):gsub('"', '\\"') .. '"'
  end
  return "[" .. table.concat(values, "、") .. "]"
end

local function diag_plugin_names(pluginSet)
  local configured = type(pluginSet) == "table" and pluginSet or { "*" }
  local all = false
  for _, name in ipairs(configured) do if tostring(name) == "*" then all = true; break end end
  if not all then
    local names = {}
    for _, name in ipairs(configured) do names[#names + 1] = tostring(name) end
    return names
  end

  local names = {}
  local root = host.ubuntu_path() .. "/root/AstrBot/data/plugins"
  for _, entry in ipairs(host.list_dir(root) or {}) do
    if entry.isDir and tostring(entry.name):sub(1, 1) ~= "." then names[#names + 1] = tostring(entry.name) end
  end
  table.sort(names, function(a, b) return a:lower() < b:lower() end)
  return names
end

local function diag_config_report(cfg, providers, enabled, defaultId, defaultOk, admins, wake, settings)
  local platform = type(cfg.data.platform_settings) == "table" and cfg.data.platform_settings or {}
  local proactive = type(settings.proactive_capability) == "table" and settings.proactive_capability or {}
  local active = type(settings.active_reply) == "table" and settings.active_reply or {}
  local whitelist = type(active.whitelist) == "table" and active.whitelist or {}
  local plugins = diag_plugin_names(cfg.data.plugin_set)
  local defaultModel = defaultId ~= "" and (defaultId .. (defaultOk and "" or "（不可用）")) or "未配置"
  local lines = {
    "\t" .. diag_config_name(cfg.id) .. "：",
    "\t\t模型：" .. enabled .. "/" .. #providers,
    "\t\t默认模型：" .. defaultModel,
    "\t\t管理员：" .. admins,
    "\t\t唤醒词：" .. diag_wake_value(wake),
    "\t\t额外唤醒词：" .. diag_value(settings.wake_prefix),
    "\t\t电脑能力：",
    "\t\t\t运行环境：" .. diag_value(settings.computer_use_runtime),
    "\t\t\t需要管理员权限：" .. diag_switch(settings.computer_use_require_admin),
    "\t\t主动型能力：" .. diag_switch(proactive.add_cron_tools),
    "\t\t隔离会话：" .. diag_switch(platform.unique_session),
    "\t\t主动回复：",
    "\t\t\t开关：" .. diag_switch(active.enable),
    "\t\t\t概率：" .. diag_value(active.possibility_reply),
    "\t\t\t白名单数量：" .. #whitelist,
    "\t\t插件列表：",
  }
  if #plugins == 0 then
    lines[#lines + 1] = "\t\t\t（无）"
  else
    for _, name in ipairs(plugins) do lines[#lines + 1] = "\t\t\t" .. name end
  end
  return table.concat(lines, "\n")
end

local function diag_config_summary(configs)
  local lines, reports, bad = {}, {}, false
  for _, cfg in ipairs(configs) do
    local providers = type(cfg.data.provider) == "table" and cfg.data.provider or {}
    local settings = type(cfg.data.provider_settings) == "table" and cfg.data.provider_settings or {}
    local defaultId = tostring(settings.default_provider_id or "")
    local enabled, defaultOk = 0, false
    for _, provider in ipairs(providers) do
      if type(provider) == "table" and provider.enable ~= false then enabled = enabled + 1 end
      if type(provider) == "table" and tostring(provider.id or "") == defaultId and provider.enable ~= false then defaultOk = true end
    end
    if defaultId == "" or not defaultOk then bad = true end
    local admins = 0
    for _, id in ipairs(type(cfg.data.admins_id) == "table" and cfg.data.admins_id or {}) do
      if tostring(id) ~= "astrbot" then admins = admins + 1 end
    end
    local wake = diag_first_non_empty(cfg.data.wake_prefix, cfg.data.wake_prefixes, settings.wake_prefix) or "未配置"
    local wakeDisplay = diag_value(wake)
    lines[#lines + 1] = diag_config_name(cfg.id) .. "：模型 " .. enabled .. "/" .. #providers ..
      "，默认模型 " .. (defaultId ~= "" and defaultId or "未配置") ..
      ((defaultId ~= "" and not defaultOk) and "（不可用）" or "") .. "，管理员 " .. admins .. "，唤醒词 " .. tostring(wakeDisplay)
    reports[#reports + 1] = diag_config_report(cfg, providers, enabled, defaultId, defaultOk, admins, wake, settings)
  end
  return table.concat(lines, "\n"), bad, table.concat(reports, "\n\n")
end

local function diag_make_report(skipped)
  local marks = { pass = "[正常]", warn = "[注意]", fail = "[异常]", pending = "[未完成]", running = "[未完成]" }
  local lines = { "AstrBot 诊断报告", "时间：" .. os.date("%Y-%m-%d %H:%M:%S"), "模型测试：" .. (skipped and "已跳过" or "已执行") }
  for _, item in ipairs(diag.items) do
    local mark = marks[item.status] or "[未完成]"
    if item.reportDetail and item.reportDetail ~= "" then
      lines[#lines + 1] = mark .. " " .. item.title .. "：" .. (item.reportSummary or "") .. "\n" .. item.reportDetail
    else
      lines[#lines + 1] = mark .. " " .. item.title .. (item.detail ~= "" and "：" .. item.detail or "")
    end
  end
  return table.concat(lines, "\n")
end

local function diag_finish(skipped, rev)
  diag.completed = true
  diag.report = diag_make_report(skipped)
  rev.set(rev.get() + 1)
end

local function diag_test_models(index, rev, done)
  local defaultCfg
  for _, cfg in ipairs(diag.allConfigs or {}) do if cfg.id == "default" then defaultCfg = cfg; break end end
  local dashboard = defaultCfg and defaultCfg.data.dashboard
  local username = type(dashboard) == "table" and tostring(dashboard.username or "") or ""
  local secret = type(dashboard) == "table" and tostring(dashboard.jwt_secret or "") or ""
  if username == "" or secret == "" then diag_set(7, "fail", "AstrBot 登录配置不完整", rev); done(); return end
  local token = diag_jwt(username, secret)
  local results, failed, indeterminate, tested = {}, false, false, 0
  local function next_model()
    if diag.cancelled then done(); return end
    local cfg = diag.configs[index]
    if not cfg then
      diag_set(7, failed and "fail" or ((indeterminate or tested == 0) and "warn" or "pass"), table.concat(results, "\n"), rev)
      done(); return
    end
    index = index + 1
    local configName = diag_config_name(cfg.id)
    local settings = type(cfg.data.provider_settings) == "table" and cfg.data.provider_settings or {}
    local providerId = tostring(settings.default_provider_id or "")
    if providerId == "" then failed = true; results[#results + 1] = configName .. "：未配置默认模型"; next_model(); return end
    tested = tested + 1
    diag.request = host.http({
      url = "http://127.0.0.1:" .. ports.get("dashboard") .. "/api/config/provider/check_one?id=" .. host.url_encode(providerId, true),
      method = "GET", headers = { Authorization = "Bearer " .. token }, timeout = 120,
      on_done = function(res)
        diag.request = nil
        local ok, body = pcall(json.decode, res and res.body or "")
        local data = ok and type(body) == "table" and body.data or nil
        if res and res.status == 404 then
          indeterminate = true
          results[#results + 1] = configName .. "：当前 AstrBot 版本不支持自动测试"
        elseif res and (res.status == 401 or res.status == 403) then
          failed = true
          results[#results + 1] = configName .. "：AstrBot 登录验证失败"
        elseif res and res.ok and type(data) == "table" and data.status == "available" then
          results[#results + 1] = configName .. "：" .. providerId .. " 连接正常"
        else
          failed = true
          results[#results + 1] = configName .. "：" .. providerId .. " 连接失败" ..
            (type(data) == "table" and data.error and "，" .. diag_safe_error(data.error) or "")
        end
        next_model()
      end,
      on_error = function(err)
        diag.request = nil; failed = true
        local msg = tostring(err or "")
        results[#results + 1] = configName .. "：" .. providerId .. (msg:lower():find("timeout", 1, true) and " 测试超过 120 秒" or " 连接失败")
        next_model()
      end,
    })
  end
  next_model()
end

local function diag_check_processes(ctx, rev)
  local astr = ctx and ctx.running and ctx.running["astrbot"] == true
  diag.accounts = diag_accounts(ctx)
  local running = 0
  for _, account in ipairs(diag.accounts) do if account.running then running = running + 1 end end
  local napDetail
  if #diag.accounts == 0 then napDetail = "NapCat 没有已登录账号"
  elseif running == 0 then napDetail = "NapCat 未运行（0/" .. #diag.accounts .. "）"
  else napDetail = "NapCat 运行正常（" .. running .. "/" .. #diag.accounts .. "）" end
  local summary = "AstrBot " .. (astr and "运行正常" or "未运行") .. "；" .. napDetail
  local report = { "\tAstrBot " .. ports.get("dashboard") .. " " .. (astr and "正常运行" or "未运行") }
  for _, account in ipairs(diag.accounts) do
    local ins = account.instance
    report[#report + 1] = "\t" .. account.name .. " " .. account.qq .. " " ..
      tostring(ins.webUiPort or "端口未配置") .. " " .. (account.running and "正常运行" or "未运行")
  end
  diag_set(4, astr and running > 0 and "pass" or "fail", summary, rev)
  diag.items[4].reportSummary = summary .. "："
  diag.items[4].reportDetail = table.concat(report, "\n")
end

local function diag_check_bindings(ctx, rev)
  local astr = ctx and ctx.running and ctx.running["astrbot"] == true
  local running, bad = 0, 0
  for _, account in ipairs(diag.accounts or {}) do
    if account.running then
      running = running + 1
      if account.bindingState ~= "configured" then bad = bad + 1 end
    end
  end
  local passed = astr and running > 0 and bad == 0
  local detail = passed and ("连接正常（" .. running .. " 个运行账号）") or
    (running == 0 and "连接异常：没有已登录且正在运行的账号" or "连接异常：" .. bad .. " 个运行账号连接异常")
  local report = { "\tAstrBot适配器：" }
  local adapters = NC.list_adapters()
  if #adapters == 0 then report[#report + 1] = "\t\t（无）" end
  for _, adapter in ipairs(adapters) do
    local configNames = {}
    for _, id in ipairs(diag_config_ids(adapter.id)) do configNames[#configNames + 1] = diag_config_name(id) end
    report[#report + 1] = "\t\t" .. adapter.id .. " " .. adapter.port .. " " ..
      table.concat(configNames, "、") .. " " .. (adapter.enabled and "已启用" or "未启用")
  end
  report[#report + 1] = "\twebsocket适配器："
  if #(diag.accounts or {}) == 0 then report[#report + 1] = "\t\t（无已登录账号）" end
  for _, account in ipairs(diag.accounts or {}) do
    local ins = account.instance
    local labels = {
      configured = "已绑定BOT", disabled = "已禁用BOT", mismatch = "BOT绑定异常",
      unbound = "未绑定BOT", nocfg = "AstrBot未配置",
    }
    local state = not account.running and "未运行" or (labels[account.bindingState] or "连接异常")
    report[#report + 1] = "\t\t" .. account.name .. " " .. account.qq .. " " ..
      tostring(ins.oneBotPort or "端口未配置") .. " " .. state
  end
  diag_set(5, passed and "pass" or "fail", detail, rev)
  diag.items[5].reportSummary = passed and "连接正常" or "连接异常"
  diag.items[5].reportDetail = table.concat(report, "\n")
end

local function diag_select_active_configs()
  local ids = {}
  for _, account in ipairs(diag.accounts or {}) do
    local adapterId = tostring(account.instance.boundAdapterId or "")
    if account.running and adapterId ~= "" then
      for _, id in ipairs(diag_config_ids(adapterId)) do ids[id] = true end
    end
  end
  local selected, found = {}, {}
  for _, cfg in ipairs(diag.allConfigs or {}) do
    if ids[cfg.id] then selected[#selected + 1] = cfg; found[cfg.id] = true end
  end
  local missing = {}
  for id in pairs(ids) do if not found[id] then missing[#missing + 1] = id end end
  return selected, missing
end

local function diag_run(ctx, testModel, rev)
  diag = { items = {}, configs = {}, allConfigs = {}, accounts = {}, configNames = {}, routes = {}, cancelled = false, completed = false, request = nil, report = "" }
  for _, title in ipairs(DIAG_TITLES) do
    diag.items[#diag.items + 1] = { title = title, status = "pending", detail = "", reportDetail = "" }
  end
  local step = 1
  local function next_step()
    if diag.cancelled then return end
    if step > 7 then diag_finish(not testModel, rev); return end
    diag_set(step, "running", "", rev)
    if step == 1 then
      diag_set(step, "pass", "沙盒版运行正常", rev)
    elseif step == 2 then
      diag_set(step, "warn", "请确认已允许应用在后台持续运行", rev)
    elseif step == 3 then
      local missing = {}
      local checks = { { "base", "基础环境" }, { "uv", "uv" }, { "astrbot", "AstrBot" }, { "napcat", "NapCat" } }
      for _, check in ipairs(checks) do if not env_installed(check[1]) then missing[#missing + 1] = check[2] end end
      diag_set(step, #missing == 0 and "pass" or "fail", #missing == 0 and "所有环境均已安装" or "未安装完整：" .. table.concat(missing, "、"), rev)
    elseif step == 4 then
      diag_check_processes(ctx, rev)
    elseif step == 5 then
      local configs, err = diag_read_configs()
      if not configs then
        diag.configReadError = err
        diag_check_bindings(ctx, rev)
        step = 6; host.delay(50, next_step); return
      end
      diag.allConfigs = configs
      diag_fetch_routing(function()
        if diag.cancelled then return end
        local ok, err = pcall(diag_check_bindings, ctx, rev)
        if not ok then
          diag_set(step, "fail", "连接检查失败：" .. diag_safe_error(err), rev)
        end
        step = 6; host.delay(50, next_step)
      end)
      return
    elseif step == 6 then
      local ok, err = pcall(function()
        if diag.configReadError then diag_set(step, "fail", diag.configReadError, rev)
        else
          local configs, missing = diag_select_active_configs()
          diag.configs = configs
          local detail, bad, reportDetail = "", #configs == 0, ""
          if #configs > 0 then detail, bad, reportDetail = diag_config_summary(configs) end
          for _, id in ipairs(missing) do
            local line = diag_config_name(id) .. "：配置文件不存在"
            detail = detail ~= "" and (detail .. "\n" .. line) or line
            reportDetail = reportDetail ~= "" and (reportDetail .. "\n\n\t" .. line) or ("\t" .. line)
            bad = true
          end
          if detail == "" then
            detail = "没有已运行账号可映射到配置文件"
            reportDetail = "\t（没有已运行账号可映射到配置文件）"
          end
          diag_set(step, bad and "fail" or "pass", detail, rev)
          diag.items[step].reportDetail = reportDetail
        end
      end)
      if not ok then
        local detail = "配置检查失败：" .. diag_safe_error(err)
        diag_set(step, "fail", detail, rev)
        diag.items[step].reportDetail = "\t" .. detail
      end
    elseif step == 7 then
      if not testModel then diag_set(step, "warn", "已按你的选择跳过", rev)
      elseif #diag.configs == 0 then diag_set(step, "fail", "没有已运行账号可测试模型", rev)
      else diag_test_models(1, rev, function() step = 8; next_step() end); return end
    end
    step = step + 1
    host.delay(50, next_step)
  end
  next_step()
end

local function diag_open_progress(ctx, testModel)
  local rev = state("diagnostic.rev", 0); rev.get()
  diag_run(ctx, testModel, rev)
  host.dialog({
    title = "AstrBot 自诊断",
    build = function()
      rev.get()
      local rows = { text(diag.completed and "诊断完成" or "正在诊断", { size = 20, weight = "bold" }) }
      local icons = { pending = "circle", pass = "check_circle", warn = "warning", fail = "error" }
      local colors = { pending = "grey", running = "black", pass = "green", warn = "orange", fail = "red" }
      for _, item in ipairs(diag.items) do
        local marker = item.status == "running" and spinner({ size = 20 }) or icon(icons[item.status], { color = colors[item.status] })
        rows[#rows + 1] = padding(row({
          marker, spacer(12), expanded(column({ text(item.title), item.detail ~= "" and text(item.detail, { size = 12, color = "grey" }) or spacer(0) }, { gap = 3 })),
        }, { cross = "center" }), { h = 8, v = 6 })
      end
      if diag.completed then
        rows[#rows + 1] = row({
          expanded(button("复制报告", function() host.clipboard.copy(diag.report); host.toast("报告已复制") end, { variant = "tonal" })),
          expanded(button("导出报告", function()
            local dir = host.backup_dir(); host.mkdirs(dir)
            local path = dir .. "/AstrBot-diagnostic-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
            host.write_file(path, diag.report)
            host.toast("报告已导出到：\n" .. path)
          end, { variant = "tonal" })),
        }, { gap = 8 })
      end
      return box({ height = 520, child = scroll({ column(rows, { cross = "stretch", gap = 4 }) }) })
    end,
    actions = {
      { label = "关闭", variant = "text", onTap = function()
        diag.cancelled = true
        if diag.request then host.http_cancel(diag.request); diag.request = nil end
      end },
    },
  })
end

local function open_diagnostic_dialog(ctx)
  local remembered = host.get(DIAG_PREF)
  if remembered == "skip" or remembered == "agree" then diag_open_progress(ctx, remembered == "agree"); return end
  local remember = false
  host.dialog({
    title = "开始自诊断",
    build = function() return column({
      text("将检查运行环境、后台权限、AstrBot、NapCat 和模型配置。模型测试会消耗少量 Token，单个模型最多等待 120 秒。"),
      checkbox({ title = "下次不再提示", value = remember, onChanged = function(v) remember = v == true end }),
    }, { gap = 12 }) end,
    actions = {
      { label = "取消", variant = "text" },
      { label = "跳过模型测试", variant = "text", onTap = function()
        if remember then host.set(DIAG_PREF, "skip") end
        host.delay(100, function() diag_open_progress(ctx, false) end)
      end },
      { label = "同意并继续", variant = "filled", onTap = function()
        if remember then host.set(DIAG_PREF, "agree") end
        host.delay(100, function() diag_open_progress(ctx, true) end)
      end },
    },
  })
end

local function manage_section(ctx)
  return expansion("AstrBot 管理", {
    tile("Lua 皮肤更新", {
      icon = "system_update_alt",
      subtitle = "当前版本 v" .. LUA_SCRIPT_VERSION,
      trailing = button("检查", function()
        skin_updater.check(LUA_SCRIPT_VERSION, gh_proxy())
      end, { variant = "tonal" }),
    }),
    tile("自诊断", {
      icon = "health_and_safety_outlined",
      subtitle = "检查环境、进程、连接和各 AstrBot 配置",
      trailing = button("开始", function() open_diagnostic_dialog(ctx) end, { variant = "tonal" }),
    }),
    tile("覆盖安装插件依赖", {
      icon = "build_outlined", subtitle = "重新安装 AstrBot 并覆盖插件依赖",
      trailing = button("执行", function() step_astrbot(false, true) end, { variant = "tonal" }),
    }),
    tile("备份 AstrBot 数据", {
      icon = "backup_outlined", subtitle = "打包 data 到下载目录",
      trailing = button("备份", function() do_backup() end, { variant = "tonal" }),
    }),
    tile("还原 AstrBot 数据", {
      icon = "restore", subtitle = "从备份文件恢复 data",
      trailing = button("还原", do_restore, { variant = "tonal" }),
    }),
    tile("清除 AstrBot 数据", {
      icon = "delete_outline", subtitle = "删除 data 数据目录 (不可恢复)",
      trailing = button("清除", function()
        host.confirm("确定要清除 AstrBot 数据吗?", function(yes)
          if yes then host.delete_dir(host.ubuntu_path() .. "/root/AstrBot/data"); host.exit_app() end
        end)
      end, { danger = true }),
    }),
    tile("重置 Python 环境", {
      icon = "refresh", subtitle = "删除 .venv 并重建依赖",
      trailing = button("重置", function()
        host.confirm("确定要重置 Python 环境吗?", function(yes)
          if yes then host.delete_dir(host.ubuntu_path() .. "/root/AstrBot/.venv"); host.exit_app() end
        end)
      end, { danger = true }),
    }),
  }, { icon = "settings_outlined" })
end

app.page("home", function(ctx)
  return {
    quick_start_card(ctx),
    napcat_card(ctx),
    env_card(),
    manage_section(ctx),
    padding(text("Lua 皮肤 v" .. LUA_SCRIPT_VERSION, {
      size = 11, color = "grey", align = "center",
    }), { v = 8 }),
  }
end)

-- 主页顶栏的两个 Agent 入口按钮已移至受保护的 agent/main.lua,
-- 与本文件解耦: 即使这里被改坏, agent 启动入口依然稳定存在。
