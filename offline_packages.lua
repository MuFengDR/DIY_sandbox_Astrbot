-- Component archives use exactly the Bubble APK's v1 format and cache layout.
-- The current sandbox exposes directory access, but no native file picker to Lua.
local installer = require("installer")
local M = {}

local function is_archive(path)
  local lower = tostring(path or ""):lower()
  return lower:match("%.tar%.gz$") or lower:match("%.tgz$")
end

local function container_path(path)
  local ubuntu = host.ubuntu_path()
  if path:sub(1, #ubuntu + 1) == ubuntu .. "/" then return path:sub(#ubuntu + 1) end
  if path:sub(1, #SCRIPTS + 1) == SCRIPTS .. "/" then
    return "/app-lua-runtime/" .. path:sub(#SCRIPTS + 2)
  end
  if path:sub(1, 8) == "/sdcard/" or path:sub(1, 20) == "/storage/emulated/0/" or
      path:sub(1, 6) == "/root/" then return path end
end

local function select_archive(step, options)
  local directory = host.get("offline_package_directory") or (host.storage_path() .. "/Download")
  local revision = state("offline.browser." .. step, 0)
  local function accept(path)
    path = tostring(path or ""):match("^%s*(.-)%s*$")
    if not is_archive(path) then host.toast("请选择 .tar.gz 或 .tgz 离线包"); return end
    local mapped = container_path(path)
    if not mapped then host.toast("请把离线包放到手机共享存储或 Ubuntu 的 /root 目录"); return end
    local native = path:sub(1, 6) == "/root/" and (host.ubuntu_path() .. path) or path
    if not host.exists(native) then host.toast("无法访问文件，请授权存储权限后重试"); return end
    host.set("offline_package_directory", path:match("^(.*)/[^/]+$") or directory)
    host.close_dialog()
    host.delay(100, function() options.on_offline(mapped) end)
  end
  host.dialog({
    title = "选择 " .. options.title .. " 离线包",
    build = function()
      revision.get()
      local ok, entries = pcall(host.list_dir, directory)
      local rows = {
        text(directory, { size = 12, color = "grey" }),
        row({
          button("上一级", function()
            directory = directory:match("^(.*)/[^/]+/?$") or host.storage_path()
            if directory == "" then directory = "/" end
            revision.set(revision.get() + 1)
          end, { variant = "text", icon = "arrow_upward" }),
          button("下载目录", function()
            directory = host.storage_path() .. "/Download"
            revision.set(revision.get() + 1)
          end, { variant = "text", icon = "download" }),
          iconbutton("refresh", function() revision.set(revision.get() + 1) end),
        }, { gap = 4 }),
      }
      local visible = {}
      for _, entry in ipairs(ok and entries or {}) do
        if entry.isDir or is_archive(entry.name) then visible[#visible + 1] = entry end
      end
      table.sort(visible, function(a, b)
        if a.isDir ~= b.isDir then return a.isDir end
        return a.name:lower() < b.name:lower()
      end)
      for _, entry in ipairs(visible) do
        local selected = entry
        rows[#rows + 1] = tile(selected.name, {
          icon = selected.isDir and "folder_outlined" or "archive_outlined",
          onTap = function()
            if selected.isDir then
              directory = selected.path
              revision.set(revision.get() + 1)
            else
              accept(selected.path)
            end
          end,
        })
      end
      if #visible == 0 then
        rows[#rows + 1] = text("未找到离线包。请把文件放到下载目录；首次授权存储权限后点击刷新。", { size = 13 })
      end
      return box({ height = 380, child = scroll(rows) })
    end,
    actions = {
      { label = "取消", variant = "text" },
      { label = "输入路径", variant = "text", onTap = function()
        host.delay(100, function()
          host.input({ title = "离线组件包路径", hint = directory .. "/astrbot-offline-" .. step .. "-arm64.tar.gz" }, accept)
        end)
      end },
    },
  })
end

function M.choose(step, options)
  local cached = installer.cached_package(step)
  local function later(action)
    return function() host.close_dialog(); host.delay(100, action) end
  end
  host.dialog({
    title = (options.reinstall and "重装 " or "安装 ") .. options.title,
    build = function()
      local choices = {
        text("选择安装方式。离线包与泡泡版通用，导入安装后保留缓存。", { size = 13 }),
        button("在线安装", later(options.on_online), { icon = "cloud_download_outlined" }),
        button("离线安装 · 选择文件", later(function() select_archive(step, options) end),
          { variant = "tonal", icon = "folder_open" }),
      }
      if cached then
        choices[#choices + 1] = button("使用已缓存的离线包", later(function() options.on_offline(cached) end),
          { variant = "tonal", icon = "inventory_2_outlined" })
      end
      choices[#choices + 1] = text("请先停止 AstrBot 和所有 NapCat 账号。重装会保留 AstrBot data 和 NapCat 账号配置。", { size = 12, color = "grey" })
      return column(choices, { gap = 12, cross = "stretch" })
    end,
    actions = { { label = "取消", variant = "text" } },
  })
end

return M
