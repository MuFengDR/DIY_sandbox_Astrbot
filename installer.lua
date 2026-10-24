-- Shared installer bridge for the Lua skin.
-- Online runtime releases retain signature verification. Offline components
-- use the bundled Bubble engine and never fetch an installer release.

local bootstrap = require("installer_bootstrap")

local M = {}

local STEPS = {
  base = true,
  uv = true,
  linuxqq = true,
  napcat = true,
  astrbot = true,
  opencode = true,
  all = true,
}

local function shell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "'\"'\"'") .. "'"
end

local function github_proxy()
  local value = tostring(host.get("environment_github_proxy") or "auto")
  if value == "" or value == "direct" or value == "auto" or value:match("^https?://") then
    return value
  end
  return "direct"
end

local BOOTSTRAP_CONTAINER_PATH = "/root/astrbot-installer-bootstrap.sh"
local CHECK_STATE_DIR = "/root/.astrbot-android/installer"
local CHECK_LOG_PATH = CHECK_STATE_DIR .. "/last-check.log"
local CHECK_CODE_PATH = CHECK_STATE_DIR .. "/last-check.code"
local OFFLINE_STEPS = { base = true, uv = true, linuxqq = true, napcat = true, astrbot = true }
local running = false
local clearing_cache = false

function M.offline_supported(step) return OFFLINE_STEPS[step] == true end

function M.cached_package(step)
  if not OFFLINE_STEPS[step] then return nil end
  local path = "/root/.astrbot-android/offline-packages/" .. step .. "/package.tar.gz"
  if host.exists(host.ubuntu_path() .. path) then return path end
end

function M.clear_cache(callback)
  if running or clearing_cache then
    host.toast("离线包正在安装或清理，请结束后再重试")
    return false
  end
  clearing_cache = true
  -- Use the engine's flock so a surviving install or a skin reload cannot race
  -- cache deletion. Keep installed receipts and recovery journals untouched.
  local script = [==[
import fcntl
from pathlib import Path
import sys

root = Path('/root/.astrbot-android/offline-packages')
try:
    if not root.exists():
        print('OFFLINE_CACHE_CLEARED:0')
    else:
        with (root / 'install.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError('离线安装正在进行，请结束后再清理缓存')
            files = [root / component / name
                     for component in ('base', 'uv', 'linuxqq', 'napcat', 'astrbot')
                     for name in ('package.tar.gz', 'package.incoming', 'manifest.json')]
            files += list(root.glob('.import-*.tar.gz'))
            freed = 0
            for path in files:
                if path.is_file() and not path.is_symlink():
                    size = path.stat().st_size
                    path.unlink()
                    freed += size
            print('OFFLINE_CACHE_CLEARED:' + str(freed))
except (OSError, ValueError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
]==]
  host.exec("python3 -c " .. shell_quote(script), function(result)
    clearing_cache = false
    local output = tostring(result and result.output or "")
    local bytes = output:match("OFFLINE_CACHE_CLEARED:(%d+)")
    if result and result.code == 0 and bytes then
      callback(tonumber(bytes))
    else
      callback(nil, output ~= "" and output or "无法清理离线包缓存，请重试")
    end
  end)
  return true
end

-- Only the small skin resource is copied here. Component archives are streamed
-- by Python in the container, never decoded into a Lua/base64 string.
local function copy_resource(name, target)
  local source = SCRIPTS .. "/assets/" .. name
  local input, err = io.open(source, "rb")
  if not input then error("皮肤缺少资源 " .. name .. ": " .. tostring(err)) end
  local output
  output, err = io.open(target .. ".incoming", "wb")
  if not output then input:close(); error(tostring(err)) end
  local ok, failure = pcall(function()
    while true do
      local chunk = input:read(256 * 1024)
      if not chunk then break end
      assert(output:write(chunk))
    end
    assert(output:flush())
  end)
  input:close()
  output:close()
  if not ok then os.remove(target .. ".incoming"); error(failure) end
  assert(os.rename(target .. ".incoming", target))
end

local function bootstrap_host_path()
  return host.ubuntu_path() .. "/root/astrbot-installer-bootstrap.sh"
end

function M.ensure_dashboard_initializer()
  local root = host.ubuntu_path() .. "/root"
  host.mkdirs(root)
  local name = "initialize-dashboard.py"
  local content = host.read_file(SCRIPTS .. "/assets/" .. name)
  assert(content and content ~= "", "皮肤缺少资源 " .. name .. "，请重新导入完整皮肤包")
  if host.read_file(root .. "/" .. name) ~= content then
    assert(host.write_file(root .. "/" .. name, content), "无法写入 " .. name)
  end
end

function M.ensure_bootstrap()
  local root = host.ubuntu_path() .. "/root"
  host.mkdirs(root)
  local path = bootstrap_host_path()
  if not host.exists(path) or host.read_file(path) ~= bootstrap then
    assert(host.write_file(path, bootstrap), "无法写入安装引导脚本")
  end
  for _, name in ipairs({ "offline-installer.py", "bundled-component-installer.sh" }) do
    local content = host.read_file(SCRIPTS .. "/assets/" .. name)
    assert(content and content ~= "", "皮肤缺少资源 " .. name .. "，请重新导入完整皮肤包")
    if host.read_file(root .. "/" .. name) ~= content then
      assert(host.write_file(root .. "/" .. name, content), "无法写入 " .. name)
    end
  end
  local resource_version = "astrbot-offline-package-v1-bootstrap-1"
  if not host.exists(root .. "/bootstrap-offline.tar.gz") or
      host.read_file(root .. "/.skin-bootstrap-version") ~= resource_version then
    copy_resource("bootstrap-offline.tar.gz", root .. "/bootstrap-offline.tar.gz")
    assert(host.write_file(root .. "/.skin-bootstrap-version", resource_version))
  end
  return BOOTSTRAP_CONTAINER_PATH
end

local function command_prefix(options)
  options = options or {}
  local values = {
    "export TMPDIR=" .. shell_quote(host.tmp_path()),
    "export ASTRBOT_DASHBOARD_PORT=" .. shell_quote(options.dashboard_port or 6185),
    "export ASTRBOT_ONEBOT_WS_PORT=" .. shell_quote(options.onebot_ws_port or 6199),
    "export ASTRBOT_GITHUB_PROXY=" .. shell_quote(github_proxy()),
    "export ASTRBOT_FORCE_REINSTALL_STEP=" .. shell_quote(options.reinstall and options.step or ""),
    "export ASTRBOT_LINUXQQ_FORCE_INSTALL=" .. shell_quote(options.reinstall_linuxqq and 1 or 0),
    "export ASTRBOT_OFFLINE=" .. shell_quote(options.offline and 1 or 0),
    "export ASTRBOT_OFFLINE_PACKAGE=" .. shell_quote(options.package_path or ""),
    "export L_NOT_INSTALLED=" .. shell_quote("未安装"),
    "export L_INSTALLING=" .. shell_quote("安装中"),
    "export L_INSTALLED=" .. shell_quote("已安装"),
  }
  if options.reinstall_plugins then
    values[#values + 1] = "mkdir -p /root/.config/astrbot-android/flags"
    values[#values + 1] = ": > /root/.config/astrbot-android/flags/reinstall-plugins"
  end
  return table.concat(values, "\n")
end

local function spawn(arguments, options)
  local ok, path = pcall(M.ensure_bootstrap)
  if not ok then host.toast(tostring(path)); return false end
  local command = table.concat({
    "set -e",
    command_prefix(options),
    "chmod 700 " .. shell_quote(path),
    options and options.offline and ("bash " .. shell_quote(path) .. " --prepare") or ":",
    "bash " .. shell_quote(path) .. " " .. arguments,
  }, "\n")
  host.spawn(
    command,
    options and options.title or "安装脚本",
    options and options.key or "installer",
    options and options.on_exit
  )
  return true
end

function M.run(step, options)
  if clearing_cache then host.toast("正在清理离线包缓存，请稍后安装"); return false end
  if running then host.toast("另一个安装任务正在进行，请稍后重试"); return false end
  if not STEPS[step] then
    host.toast("未知安装步骤: " .. tostring(step))
    return false
  end
  options = options or {}
  options.step = step
  if options.offline and not OFFLINE_STEPS[step] then
    host.toast("此组件暂不支持离线安装")
    return false
  end
  local on_exit = options.on_exit
  options.on_exit = function()
    running = false
    if on_exit then on_exit() end
  end
  running = true
  local started = spawn("--run --step " .. shell_quote(step), options)
  if not started then running = false end
  return started
end

function M.check(options)
  options = options or {}
  local ok, path = pcall(M.ensure_bootstrap)
  if not ok then host.toast(tostring(path)); return false end
  local command = table.concat({
    command_prefix(options),
    "chmod 700 " .. shell_quote(path),
    "mkdir -p " .. shell_quote(CHECK_STATE_DIR),
    "status=0",
    "bash " .. shell_quote(path) .. " --check > " .. shell_quote(CHECK_LOG_PATH) .. " 2>&1 || status=$?",
    "cat " .. shell_quote(CHECK_LOG_PATH),
    "printf '%s\\n' \"$status\" > " .. shell_quote(CHECK_CODE_PATH),
    "exit \"$status\"",
  }, "\n")
  host.spawn(
    command,
    options.title or "检查安装脚本更新",
    options.key or "installer-check",
    options.on_exit
  )
end

function M.read_check_result()
  local root = host.ubuntu_path() .. CHECK_STATE_DIR
  local output = host.read_file(root .. "/last-check.log") or ""
  local code = tonumber((host.read_file(root .. "/last-check.code") or ""):match("%d+"))
  return { code = code, output = output }
end

function M.update(options)
  return spawn("--update", options or { title = "更新安装脚本", key = "installer-update" })
end

function M.import(package_path, options)
  if not package_path or package_path == "" then
    host.toast("请输入离线安装脚本包路径")
    return false
  end
  return spawn("--import " .. shell_quote(package_path), options or {
    title = "导入安装脚本包",
    key = "installer-import",
  })
end

return M
