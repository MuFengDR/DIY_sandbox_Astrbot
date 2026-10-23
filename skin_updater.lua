-- Lua skin updater.
-- Read the target Release's manifest before downloading its skin files.
-- The Linux installer keeps its separate signature flow.

local M = {}

local OWNER = "MuFengDR"
local REPOSITORY = "DIY_sandbox_Astrbot"
local RELEASE_API = "https://api.github.com/repos/" .. OWNER .. "/" .. REPOSITORY .. "/releases/latest"
-- The sandbox runtime exposes the active skin directory as the global SCRIPTS.
local SCRIPTS = SCRIPTS

local MANIFEST_PATH = "skin-update-manifest.json"

local operation_state = { checking = false, updating = false }
local current_http_id = nil
local update_generation = 0
local update_dialog_state = nil

local function github_url(url, proxy)
  proxy = tostring(proxy or "direct")
  if proxy == "" or proxy == "direct" or proxy == "auto" then return url end
  if proxy:match("^https?://") then return proxy:gsub("/$", "") .. "/" .. url end
  return url
end

local function raw_url(tag, path, proxy)
  return github_url(
    "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPOSITORY .. "/" .. tag .. "/" .. path,
    proxy
  )
end

local function request_bytes(url, callback, headers)
  local request_id = host.http({
    url = url,
    method = "GET",
    headers = headers,
    timeout = 45,
    response_type = "bytes",
    on_done = function(res)
      if not res or not res.ok or type(res.body) ~= "string" then
        callback(nil, "HTTP " .. tostring(res and res.status or "?"))
        return
      end
      callback(res.body)
    end,
    on_error = function(err) callback(nil, tostring(err or "网络请求失败")) end,
  })
  return request_id
end

local function bump_update_dialog()
  if update_dialog_state and update_dialog_state.rev then
    update_dialog_state.rev.set(update_dialog_state.rev.get() + 1)
  end
end

local function close_update_dialog()
  update_dialog_state = nil
  host.close_dialog()
end

local function cancel_update()
  update_generation = update_generation + 1
  if current_http_id then
    host.http_cancel(current_http_id)
    current_http_id = nil
  end
  operation_state.updating = false
  update_dialog_state = nil
  host.close_dialog()
  host.toast("Lua 皮肤更新已取消")
end

local function show_update_dialog()
  local progress = {
    phase = "正在获取目标版本的更新清单",
    current = 0,
    total = 0,
    rev = state("lua.skin.update.rev", 0),
  }
  update_dialog_state = progress
  host.dialog({
    title = "Lua 皮肤更新",
    build = function()
      progress.rev.get()
      local detail = progress.phase
      if progress.total > 0 and progress.current > 0 then
        detail = detail .. "\n" .. tostring(progress.current) .. "/" .. tostring(progress.total)
      end
      return column({
        row({ spinner({ size = 24 }), expanded(text(detail)) }, { gap = 16, cross = "center" }),
        text("更新期间请勿关闭应用", { size = 13, color = "grey" }),
      }, { gap = 12 })
    end,
    actions = {
      { label = "取消", variant = "text", onTap = cancel_update },
    },
  })
end

local function response_bytes(value)
  if type(value) ~= "string" or value == "" then return nil, nil end
  local decoded = host.base64_decode(value, true)
  if (type(decoded) == "table" or type(decoded) == "string") and #decoded > 0 then
    return decoded, value
  end
  -- Text responses may be returned directly by some host/proxy combinations.
  return value, host.base64_encode(value)
end

local function manifest_files(encoded, version)
  local body = host.base64_decode(encoded)
  if type(body) ~= "string" then return nil, "更新清单无法解码" end
  local ok, manifest = pcall(json.decode, body)
  if not ok or type(manifest) ~= "table" or manifest.format ~= "astrbot-skin-update-v1" then
    return nil, "更新清单格式无效"
  end
  if manifest.version ~= version then return nil, "更新清单版本与目标 Release 不一致" end
  if type(manifest.files) ~= "table" or #manifest.files == 0 or #manifest.files > 512 then
    return nil, "更新清单文件列表无效"
  end
  local files, seen = {}, {}
  for _, path in ipairs(manifest.files) do
    if type(path) ~= "string" or #path > 240 or
        not path:match("^[%w_%-][%w%._%-%/]*$") or path:sub(-1) == "/" or
        path:find("//", 1, true) or path == MANIFEST_PATH or seen[path] then
      return nil, "更新清单包含无效或重复路径"
    end
    for segment in path:gmatch("[^/]+") do
      if segment:sub(1, 1) == "." then return nil, "更新清单包含不安全路径" end
    end
    local root = path:match("^([^/]+)/")
    if root == "scripts" or root == "local-package" or root == "keys" then
      return nil, "更新清单包含开发目录"
    end
    seen[path] = true
    files[#files + 1] = path
  end
  local count = 0
  for key in pairs(manifest.files) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #files then
      return nil, "更新清单文件列表必须为数组"
    end
    count = count + 1
  end
  if count ~= #files or not seen["main.lua"] or not seen["skin_updater.lua"] then
    return nil, "更新清单缺少皮肤入口或更新器"
  end
  for _, path in ipairs(files) do
    local parent = path:match("^(.*)/[^/]+$")
    while parent do
      if seen[parent] then return nil, "更新清单的文件与目录路径冲突" end
      parent = parent:match("^(.*)/[^/]+$")
    end
  end
  return files
end

local function parse_version(value)
  local text = tostring(value or "")
  local a, b, c, prerelease = text:match("^v?(%d+)%.(%d+)%.(%d+)%-([%w%.%-]+)$")
  if not a then a, b, c = text:match("^v?(%d+)%.(%d+)%.(%d+)$") end
  if not a then return nil end
  return { tonumber(a), tonumber(b), tonumber(c), prerelease }
end

local function compare_versions(left, right)
  local lhs, rhs = parse_version(left), parse_version(right)
  if not lhs or not rhs then return nil end
  for index = 1, 3 do
    if lhs[index] ~= rhs[index] then return lhs[index] < rhs[index] and -1 or 1 end
  end
  local lp, rp = lhs[4], rhs[4]
  if lp == rp then return 0 end
  if lp == nil then return 1 end
  if rp == nil then return -1 end
  return lp < rp and -1 or (lp > rp and 1 or 0)
end

local function load_latest_release(proxy, callback)
  local headers = {
    ["Accept"] = "application/vnd.github+json",
    ["User-Agent"] = "AstrBot-Android-Lua-Skin",
    ["X-GitHub-Api-Version"] = "2022-11-28",
  }

  local function parse_release(body_b64, error_message)
    if not body_b64 then callback(nil, error_message); return end
    local body = host.base64_decode(body_b64)
    if type(body) ~= "string" then body = body_b64 end
    if type(body) ~= "string" then callback(nil, "无法读取 GitHub Release 信息"); return end
    local release, decode_error = json.decode(body)
    if type(release) ~= "table" then
      callback(nil, tostring(decode_error or "GitHub Release 信息格式无效"))
      return
    end
    local tag = tostring(release.tag_name or "")
    local version = tag:gsub("^v", "")
    if not parse_version(version) then
      callback(nil, "最新 Release 的版本号无效")
      return
    end
    callback({ tag = tag, version = version })
  end

  local api_url = github_url(RELEASE_API, proxy)
  request_bytes(api_url, function(body_b64, error_message)
    if body_b64 or api_url == RELEASE_API then
      parse_release(body_b64, error_message)
      return
    end
    -- Some acceleration nodes proxy raw/release files but reject api.github.com.
    -- Retry the metadata request directly before reporting failure.
    request_bytes(RELEASE_API, parse_release, headers)
  end, headers)
end

local function update_files(release, proxy)
  local payloads = {}
  local files = {}
  local index = 1
  local generation = update_generation

  local function fail(message)
    operation_state.updating = false
    close_update_dialog()
    host.toast(message)
  end

  local function fetch_file(path, callback)
    local function request(url, allow_direct_retry)
      current_http_id = request_bytes(url, function(content_b64, error_message)
        current_http_id = nil
        if generation ~= update_generation then return end
        if content_b64 then
          local bytes, encoded = response_bytes(content_b64)
          if (type(bytes) == "table" or type(bytes) == "string") and #bytes > 0 then
            callback(encoded, nil)
            return
          end
          error_message = "响应内容无法解码"
        end
        if allow_direct_retry and tostring(proxy or "direct") ~= "direct" then
          request(raw_url(release.tag, path, "direct"), false)
          return
        end
        callback(nil, error_message)
      end)
    end
    request(raw_url(release.tag, path, proxy), true)
  end

  local function finish()
    if generation ~= update_generation then return end
    local ok, error_message = pcall(function()
      for _, path in ipairs(files) do
        local directory = path:match("^(.*)/[^/]+$")
        if directory then host.mkdirs(SCRIPTS .. "/" .. directory) end
        assert(host.write_bytes(SCRIPTS .. "/" .. path, payloads[path]), "无法写入 " .. path)
      end
      assert(host.write_bytes(SCRIPTS .. "/" .. MANIFEST_PATH, payloads[MANIFEST_PATH]), "无法写入更新清单")
    end)
    if not ok then fail("应用皮肤更新失败: " .. tostring(error_message)); return end
    operation_state.updating = false
    if update_dialog_state then
      update_dialog_state.phase = "更新完成，正在重载"
      update_dialog_state.current = update_dialog_state.total
      bump_update_dialog()
    end
    host.delay(120, function()
      if generation ~= update_generation then return end
      close_update_dialog()
      host.request_reload()
    end)
  end

  local function next_file()
    local path = files[index]
    if not path then finish(); return end
    fetch_file(path, function(content_b64, error_message)
      if not content_b64 then
        fail("下载 " .. path .. " 失败: " .. tostring(error_message))
        return
      end
      payloads[path] = content_b64
      if update_dialog_state then
        update_dialog_state.current = index
        update_dialog_state.phase = "已下载 " .. path
        bump_update_dialog()
      end
      index = index + 1
      next_file()
    end)
  end

  fetch_file(MANIFEST_PATH, function(encoded, error_message)
    if not encoded then
      fail("获取目标版本更新清单失败，请确认发布时包含 " .. MANIFEST_PATH .. ": " .. tostring(error_message))
      return
    end
    local target_files, manifest_error = manifest_files(encoded, release.version)
    if not target_files then fail("目标版本更新清单无效: " .. tostring(manifest_error)); return end
    files = target_files
    payloads[MANIFEST_PATH] = encoded
    if update_dialog_state then
      update_dialog_state.phase = "已获取目标版本更新清单，正在下载"
      update_dialog_state.total = #files
      bump_update_dialog()
    end
    next_file()
  end)
end

function M.check(current_version, proxy)
  if operation_state.checking or operation_state.updating then
    host.toast("Lua 皮肤更新操作正在进行")
    return
  end
  operation_state.checking = true
  load_latest_release(proxy, function(release, error_message)
    operation_state.checking = false
    if not release then
      host.toast("检查 Lua 皮肤更新失败: " .. tostring(error_message))
      return
    end
    local comparison = compare_versions(release.version, current_version)
    if comparison == nil then
      host.toast("当前 Lua 皮肤版本格式无效")
      return
    end
    if comparison <= 0 then
      host.toast("Lua 皮肤已经是最新版 (v" .. tostring(current_version) .. ")")
      return
    end
    host.confirm(
      "发现 Lua 皮肤 v" .. release.version .. "，是否下载并重载？",
      function(confirmed)
        if not confirmed then return end
        update_generation = update_generation + 1
        operation_state.updating = true
        show_update_dialog()
        update_files(release, proxy)
      end,
      { title = "Lua 皮肤更新", ok_text = "更新", cancel_text = "取消" }
    )
  end)
end

return M
