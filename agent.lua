-- agent.lua · OpenCode 引擎模块 (独立于界面, 可热更新)
-- 职责: 通过共享安装器安装/升级 OpenCode，并用 `opencode web` 一键启动 (自带 WebUI/自动免密/本机),
-- 就绪后在 WebView 标签打开其地址。界面编排在 main.lua; 本模块只暴露纯逻辑函数。
-- API 详见 docs/lua_api.md

local M = {}
local installer = require("installer")

M.version = "由共享安装器管理"

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\"'\"'") .. "'"
end

local function bin_host() return host.ubuntu_path() .. "/root/.local/bin/opencode" end

-- 是否已安装 opencode 二进制
function M.installed() return host.exists(bin_host()) end

-- 安装与更新统一交由共享安装器实现，后续可无缝迁移为应用市场应用。
function M.install(reinstall)
  installer.run("opencode", {
    reinstall = reinstall == true,
    title = "OpenCode 安装",
    key = "opencode_install",
  })
end

-- ==================== 运行 / 启动 ====================
-- `opencode web` 自带 WebUI, 本机免密。它本身没有 --directory 参数(工作目录取自 cwd),
-- 但 WebUI 支持用 URL 路径 /<base64url(dir)> 深链到某工作目录。我们据此直接把 WebView
-- 打开到指定工作目录, 既绑定了工作目录, 又避开 opencode 文件选择器拒绝 home/根目录的限制。
local S = { port = nil, running = false }

M.running = function() return S.running == true end

-- 工作目录 (容器内绝对路径); 可用设置 opencode_workdir 覆盖, 默认 /root。
local function workdir()
  local w = host.get("opencode_workdir")
  if not w or w == "" then return "/root" end
  return w
end

-- base64url (与 opencode core 的 base64Encode 一致: +→- /→_ 去掉 =)
local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64url(data)
  local r = ((data:gsub('.', function(x)
    local b = x:byte(); local s = ''
    for i = 8, 1, -1 do s = s .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
    return s
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
    return B64:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
  return (r:gsub('%+', '-'):gsub('/', '_'):gsub('=', ''))
end

local function open_webui(target_dir, tab_name)
  local dir = target_dir or workdir()
  host.webview_open("http://127.0.0.1:" .. S.port .. "/" .. b64url(dir), tab_name or "opencode")
end

local function wait_ready(tries, target_dir, tab_name)
  if not S.running or not S.port then return end
  if tries > 60 then host.toast("opencode 启动超时, 可在终端查看日志"); return end
  host.http({
    url = "http://127.0.0.1:" .. S.port .. "/",
    timeout = 4,
    on_done = function(res)
      if res and res.status == 200 then
        open_webui(target_dir, tab_name)
      else
        host.delay(1000, function() wait_ready(tries + 1, target_dir, tab_name) end)
      end
    end,
    on_error = function() host.delay(1000, function() wait_ready(tries + 1, target_dir, tab_name) end) end,
  })
end

-- 启动 (幂等): 未装 -> 引导安装; 已运行 -> 直接开界面; 否则起 `opencode web` 并就绪后开 WebView。
-- target_dir: 要打开的深链工作目录, 省略则用默认 (/root)
-- tab_name: WebView 标签页名称, 默认 "opencode"
function M.launch(target_dir, tab_name)
  if not M.installed() then
    host.confirm("opencode 引擎尚未安装。是否前往「环境管理」查看安装步骤?", function(yes)
      if yes then host.nav.go(0) end
    end, { title = "未安装 opencode", ok_text = "前往安装", cancel_text = "取消" })
    return
  end
  if S.running and S.port then
    -- 防御式健康检查: 引擎进程可能在终端内被 Ctrl+C 但 PTY 未退出,
    -- 或 spwan tab 被手动关掉后 onExit 未必及时回调。发一个简短的 HTTP 探测
    -- 确认服务确实在响应,避免打开空/错误页面。
    host.http({
      url = "http://127.0.0.1:" .. S.port .. "/",
      timeout = 3,
      on_done = function(res)
        if res and res.status == 200 then open_webui(target_dir, tab_name) else
          S.running = false; S.port = nil
          host.toast("opencode 引擎已离线，正在重新启动…")
          M.launch(target_dir, tab_name)
        end
      end,
      on_error = function()
        S.running = false; S.port = nil
        host.toast("opencode 引擎已离线，正在重新启动…")
        M.launch(target_dir, tab_name)
      end,
    })
    return
  end
  host.toast("正在启动 opencode…")
  host.free_port(41000, 45000, {}, function(p)
    if not p then host.toast("无可用端口"); return end
    S.port = p
    local wd = target_dir or workdir()
    local cmd = table.concat({
      'export PATH="$HOME/.local/bin:$PATH"',
      'mkdir -p ' .. shell_quote(wd),
      -- opencode 启动后会尝试用 xdg-open 自动开浏览器; 容器内无桌面, 放个空桩避免报错
      'mkdir -p "$HOME/.local/bin"',
      'printf "#!/bin/sh\\nexit 0\\n" > "$HOME/.local/bin/xdg-open" && chmod +x "$HOME/.local/bin/xdg-open"',
      "echo " .. shell_quote("opencode 引擎启动 (127.0.0.1:" .. p .. "), 工作目录 " .. wd),
      "opencode web --hostname 127.0.0.1 --port " .. p,
    }, "\n")
    host.spawn(cmd, "opencode 引擎", "opencode_web", function()
      S.running = false
    end)
    S.running = true
    wait_ready(0, target_dir, tab_name)
  end)
end

-- 停止引擎
function M.stop()
  host.stop("opencode_web")
  S.running = false
end

function M.open(target_dir, tab_name)
  if S.running and S.port then
    open_webui(target_dir, tab_name)
  else
    M.launch(target_dir, tab_name)
  end
end

return M
