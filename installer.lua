-- Shared installer bridge for the Lua skin.
-- The runtime implementation itself is fetched only after the embedded
-- bootstrap has verified its signed release manifest.

local bootstrap = require("installer_bootstrap")

local M = {}

local STEPS = {
  base = true,
  uv = true,
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

local function bootstrap_host_path()
  return host.ubuntu_path() .. "/root/astrbot-installer-bootstrap.sh"
end

function M.ensure_bootstrap()
  local root = host.ubuntu_path() .. "/root"
  host.mkdirs(root)
  local path = bootstrap_host_path()
  if not host.exists(path) or host.read_file(path) ~= bootstrap then
    host.write_file(path, bootstrap)
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
  local path = M.ensure_bootstrap()
  local command = table.concat({
    command_prefix(options),
    "chmod 700 " .. shell_quote(path),
    "bash " .. shell_quote(path) .. " " .. arguments,
  }, "\n")
  host.spawn(
    command,
    options and options.title or "安装脚本",
    options and options.key or "installer",
    options and options.on_exit
  )
end

function M.run(step, options)
  if not STEPS[step] then
    host.toast("未知安装步骤: " .. tostring(step))
    return false
  end
  options = options or {}
  options.step = step
  spawn("--run --step " .. shell_quote(step), options)
  return true
end

function M.check(options)
  options = options or {}
  local path = M.ensure_bootstrap()
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
  spawn("--update", options or { title = "更新安装脚本", key = "installer-update" })
end

function M.import(package_path, options)
  if not package_path or package_path == "" then
    host.toast("请输入离线安装脚本包路径")
    return false
  end
  spawn("--import " .. shell_quote(package_path), options or {
    title = "导入安装脚本包",
    key = "installer-import",
  })
  return true
end

return M
