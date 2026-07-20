-- AstrBot Android 默认脚本 v0.1.8 (位于 {configPath}/scripts/main.lua, 可直接编辑, 主页顶栏刷新键重载)
-- API 详见同目录 AGENTS.md

-- 独立 agent 模块 (opencode 引擎: 安装/启动/WebUI 托管), 界面在本文件编排
local agent = require("agent")

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
  { label = "直连 (GitHub 原始)", value = "direct" },
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
local function gh_proxy() return host.get("environment_github_proxy") or "direct" end
local function gh_proxy_label(v)
  for _, p in ipairs(GH_PROXIES) do if p.value == v then return p.label end end
  return v
end

-- 镜像测速 (纯 Lua 端): value -> { ms=数字 | err=字符串 | testing=true }
local gh_speed = {}
local GH_TEST_PATH = "/https://raw.githubusercontent.com/astral-sh/uv/main/README.md"
local function gh_test_all()
  local rev = state("gh.speed.rev", 0)
  for _, p in ipairs(GH_PROXIES) do
    if p.value ~= "direct" then
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
          expanded(text("点选一个镜像作为下载代理", { size = 12, color = "grey" })),
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

local ENV_STEPS = {
  { id = "base",    title = "基础命令", sub = "sudo / git / curl" },
  { id = "uv",      title = "uv",       sub = "Python 依赖管理工具" },
  { id = "astrbot", title = "AstrBot",  sub = "克隆 AstrBot 并同步依赖" },
  { id = "napcat",  title = "NapCat",   sub = "安装或修复 NapCatQQ" },
  { id = "opencode", title = "OpenCode", sub = "DIY AI coding agent" },
}

-- ============================================================
-- 安装命令: 每个按钮直接下发自己那一步的命令 (无中央分发器)。
-- 共享的辅助函数 (progress/network/各 install_*) 作为 verbatim 常量复用,
-- 每个步骤按钮显式列出自己要执行的调用序列。
-- ============================================================

-- 进容器执行时需要的环境变量前缀
local function env_pre(force)
  return table.concat({
    'export TMPDIR="' .. host.tmp_path() .. '"',
    'export ASTRBOT_DASHBOARD_PORT=' .. tostring(ports.get("dashboard")),
    'export ASTRBOT_ONEBOT_WS_PORT=' .. tostring(ports.get("onebot")),
    'export ASTRBOT_GITHUB_PROXY="' .. gh_proxy() .. '"',
    'export ASTRBOT_FORCE_REINSTALL_STEP="' .. (force or "") .. '"',
    'export L_NOT_INSTALLED=未安装',
    'export L_INSTALLING=安装中',
    'export L_INSTALLED=已安装',
    'export UV_LINK_MODE=copy',
    'export UV_DEFAULT_INDEX="https://pypi.tuna.tsinghua.edu.cn/simple"',
    'export UV_PYTHON_INSTALL_MIRROR="' ..
      gh_prefix("https://github.com/astral-sh/python-build-standalone/releases/download") .. '"',
  }, "\n")
end

-- 共享辅助 (verbatim)
local SH_HELPERS = [==[
progress_echo(){
  echo -e "\033[31m- $@\033[0m"
  echo "$@" > "$TMPDIR/progress_des"
}
prepare_reinstall_step(){
  case "$1" in
    uv)
      progress_echo "uv 重装准备中"
      rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
      ;;
    napcat)
      progress_echo "NapCat 重装准备中"
      if [ -d "$HOME/napcat/config" ]; then
        rm -rf "$HOME/napcat_config_backup"
        cp -r "$HOME/napcat/config" "$HOME/napcat_config_backup"
      fi
      pkill -f 'qq --no-sandbox' 2>/dev/null || true
      pkill -f 'NapCat' 2>/dev/null || true
      pkill -f 'napcat' 2>/dev/null || true
      rm -rf "$HOME/napcat" "$HOME/napcat.sh" "$HOME/launcher.sh"
      ;;
    astrbot)
      progress_echo "AstrBot 重装准备中"
      killall uv 2>/dev/null || true
      rm -rf "$HOME/AstrBot_data_reinstall_backup"
      if [ -d "$HOME/AstrBot/data" ]; then
        cp -r "$HOME/AstrBot/data" "$HOME/AstrBot_data_reinstall_backup"
      fi
      rm -rf "$HOME/AstrBot" "$HOME/AstrBot_tmp"
      ;;
  esac
}
maybe_prepare_reinstall(){
  if [ "$ASTRBOT_FORCE_REINSTALL_STEP" = "$1" ]; then
    prepare_reinstall_step "$1"
  fi
}
]==]

local SH_NET = [==[
network_test() {
  target_proxy=""
  case "$ASTRBOT_GITHUB_PROXY" in
    ""|direct|auto) echo "Github 直连"; return 0 ;;
    *) target_proxy="$ASTRBOT_GITHUB_PROXY"; echo "使用代理: $target_proxy"; return 0 ;;
  esac
}
]==]

local SH_BASE = [==[
install_sudo_curl_git(){
  missing=()
  for cmd in sudo git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then missing+=("$cmd"); fi
  done
  if [ ${#missing[@]} -eq 0 ]; then progress_echo "基础命令已安装"; return 0; fi
  progress_echo "基础命令缺失: ${missing[*]}, 开始安装..."
  export DEBIAN_FRONTEND=noninteractive
  apt_opts="-o Acquire::ForceIPv4=true"
  if ! apt-get $apt_opts update; then echo "apt-get update 失败，继续尝试安装..."; fi
  if ! apt-get $apt_opts install -y sudo git curl; then echo "基础命令安装失败"; return 1; fi
  for cmd in sudo git curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then echo "基础命令安装后仍缺少: $cmd"; return 1; fi
  done
  progress_echo "基础命令安装完成"
}
]==]

local SH_UV = [==[
install_uv(){
  INSTALL_DIR="$HOME/.local/bin"
  ARCHIVE_FILE="uv-aarch64-unknown-linux-gnu.tar.gz"
  mkdir -p "$INSTALL_DIR"
  network_test

  # 探测最新版本: 走 releases/latest 的 302 重定向, 取最终 URL 末段 tag (无需 api.github.com)
  progress_echo "检测 uv 最新版本..."
  LATEST_URL=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${target_proxy:+${target_proxy}/}https://github.com/astral-sh/uv/releases/latest" 2>/dev/null)
  APP_VERSION="${LATEST_URL##*/}"
  case "$APP_VERSION" in
    ""|*latest*) APP_VERSION="0.9.9"; echo "无法获取最新版本, 回退到 $APP_VERSION" ;;
    *) echo "最新 uv 版本: $APP_VERSION" ;;
  esac

  # 已安装同版本 -> 跳过 (重装时按钮已在 prepare_reinstall_step 删除旧二进制)
  if [ -x "$INSTALL_DIR/uv" ]; then
    CUR=$("$INSTALL_DIR/uv" --version 2>/dev/null | awk '{print $2}')
    if [ -n "$CUR" ] && [ "$CUR" = "$APP_VERSION" ]; then
      progress_echo "uv 已是最新 ($CUR)"
      return 0
    fi
    echo "当前 uv ${CUR:-未知}, 将更新到 $APP_VERSION..."
  fi

  progress_echo "uv $L_INSTALLING ($APP_VERSION)..."
  DOWNLOAD_URL="${target_proxy:+${target_proxy}/}https://github.com/astral-sh/uv/releases/download/${APP_VERSION}/${ARCHIVE_FILE}"
  TMP_DIR=$(mktemp -d)
  echo "正在下载 uv $APP_VERSION..."
  if ! curl -fL "$DOWNLOAD_URL" -o "$TMP_DIR/$ARCHIVE_FILE"; then echo "下载失败"; rm -rf "$TMP_DIR"; exit 1; fi
  if ! tar -C "$TMP_DIR" -xf "$TMP_DIR/$ARCHIVE_FILE" --strip-components 1; then echo "解压失败"; rm -rf "$TMP_DIR"; exit 1; fi
  cp "$TMP_DIR/uv" "$TMP_DIR/uvx" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/uv" "$INSTALL_DIR/uvx"
  grep -q "$INSTALL_DIR" "$HOME/.bashrc" 2>/dev/null || echo "export PATH=$INSTALL_DIR:\$PATH" >> "$HOME/.bashrc"
  rm -rf "$TMP_DIR"
  progress_echo "uv 安装完成 ($APP_VERSION)"
}
]==]

local SH_NAPCAT = [==[
configure_napcat_token_ttl(){
  if [ -f "$HOME/napcat/napcat.mjs" ]; then
    sed -i -E "s#static MAX_CREDENTIAL_VALID_SECONDS = [0-9]+#static MAX_CREDENTIAL_VALID_SECONDS = 604800#g" "$HOME/napcat/napcat.mjs"
    sed -i -E 's#Rp\.set\(`revoked:\$\{r\}`, !0, [0-9]+\)#Rp.set(`revoked:${r}`, !0, 604800)#g' "$HOME/napcat/napcat.mjs"
  fi
}
linuxqq_ready(){
  command -v qq >/dev/null 2>&1 &&
    dpkg-query -W -f='${Status}\n' linuxqq 2>/dev/null | grep -qx 'install ok installed'
}
prepare_apt_downloads(){
  local file changed=0
  export DEBIAN_FRONTEND=noninteractive
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::ForceIPv4 "true";\nAcquire::Retries "3";\n' > /etc/apt/apt.conf.d/99astrbot-force-ipv4
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [ -f "$file" ] || continue
    if grep -q 'http://mirrors\.tuna\.tsinghua\.edu\.cn' "$file"; then
      sed -i 's#http://mirrors\.tuna\.tsinghua\.edu\.cn#https://mirrors.tuna.tsinghua.edu.cn#g' "$file"
      changed=1
    fi
  done
  if [ "$changed" -eq 1 ]; then
    echo "已将 Ubuntu 清华软件源切换为 HTTPS，正在刷新索引..."
    apt-get -o Acquire::ForceIPv4=true update
  fi
}
use_local_linuxqq_deb(){
  local dest="$1" candidate arch package
  for candidate in "${ASTRBOT_LINUXQQ_FILE:-}" /sdcard/Download/*.deb /storage/emulated/0/Download/*.deb; do
    [ -n "$candidate" ] && [ -f "$candidate" ] || continue
    dpkg-deb --info "$candidate" >/dev/null 2>&1 || continue
    arch=$(dpkg-deb -f "$candidate" Architecture 2>/dev/null)
    package=$(dpkg-deb -f "$candidate" Package 2>/dev/null)
    case "$arch" in arm64|aarch64) ;; *) continue ;; esac
    [ "$package" = "linuxqq" ] || continue
    echo "发现本地 LinuxQQ 安装包: $candidate"
    cp -f "$candidate" "$dest"
    return $?
  done
  return 1
}
get_linuxqq_signed_url(){
  local bare_url="$1"
  local api_url="https://im.qq.com/http2rpc/gotrpc/noauth/trpc.qqntv2.urlsign.UrlSign/GetSign"
  local response_file="$TMPDIR/linuxqq-sign.json"
  local normalized_file="$TMPDIR/linuxqq-sign-normalized.json"
  local payload
  LINUXQQ_SIGNED_URL=""
  payload=$(printf '{"url":"%s"}' "$bare_url")
  echo "正在向 LinuxQQ 官网申请临时下载签名..."
  if ! curl -fL --connect-timeout 15 --max-time 30 \
      -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
      -e 'https://im.qq.com/' \
      -H 'Accept: application/json, text/plain, */*' \
      -H 'Content-Type: application/json' \
      -H 'x-oidb: {"uint32_command":"0x9b8e","uint32_service_type":1}' \
      --data "$payload" "$api_url" -o "$response_file"; then
    echo "获取 LinuxQQ 临时下载签名失败"
    return 1
  fi
  sed 's#\\/#/#g; s#\\u0026#\&#g; s#\\u003d#=#g' "$response_file" > "$normalized_file"
  LINUXQQ_SIGNED_URL=$(grep -Eo '"url"[[:space:]]*:[[:space:]]*"[^"]+"' "$normalized_file" |
    head -n 1 | sed -E 's/^"url"[[:space:]]*:[[:space:]]*"//; s/"$//')
  case "$LINUXQQ_SIGNED_URL" in
    https://*\?*sign=*\&t=*) return 0 ;;
    *)
      echo "LinuxQQ 签名接口未返回有效下载地址"
      cat "$response_file" 2>/dev/null || true
      LINUXQQ_SIGNED_URL=""
      return 1
      ;;
  esac
}
install_linuxqq(){
  if linuxqq_ready; then echo "LinuxQQ 已安装"; return 0; fi
  local config_url="${ASTRBOT_LINUXQQ_CONFIG_URL:-https://cdn-go.cn/qq-web/im.qq.com_new/latest/rainbow/linuxConfig.js}"
  local config_file="$TMPDIR/linuxqq-config.js"
  local normalized_config="$TMPDIR/linuxqq-config-normalized.js"
  local qq_deb="$HOME/QQ.deb"
  local qq_url="${ASTRBOT_LINUXQQ_URL:-}"
  local package_arch package_name sound_package download_url
  echo "[AstrBot Android] LinuxQQ 修复流程 v8"
  progress_echo "LinuxQQ 安装中"
  rm -f "$config_file" "$normalized_config"
  if [ -z "$qq_url" ]; then
    echo "正在读取 LinuxQQ 官方发布配置..."
    if ! curl -fL --connect-timeout 15 --max-time 60 "$config_url" -o "$config_file"; then
      echo "获取 LinuxQQ 官方发布配置失败: $config_url"; return 1
    fi
    sed 's#\\/#/#g' "$config_file" > "$normalized_config"
    qq_url=$(grep -Eo "(https?:)?//[^\"'[:space:]]+" "$normalized_config" |
      grep -Ei '(arm64|aarch64)[^[:space:]]*\.deb([?#][^[:space:]]*)?' | head -n 1)
    if [ -z "$qq_url" ]; then
      echo "官方发布配置中未找到 ARM64 LinuxQQ deb 下载地址"
      echo "可临时通过 ASTRBOT_LINUXQQ_URL 指定可信的 ARM64 deb 地址后重试"
      return 1
    fi
    case "$qq_url" in //*) qq_url="https:$qq_url" ;; esac
  fi
  package_arch=$(dpkg-deb -f "$qq_deb" Architecture 2>/dev/null)
  package_name=$(dpkg-deb -f "$qq_deb" Package 2>/dev/null)
  if dpkg-deb --info "$qq_deb" >/dev/null 2>&1 &&
      { [ "$package_arch" = "arm64" ] || [ "$package_arch" = "aarch64" ]; } &&
      [ "$package_name" = "linuxqq" ]; then
    echo "复用上次已下载并校验通过的 LinuxQQ 安装包"
  else
    rm -f "$qq_deb"
    if get_linuxqq_signed_url "$qq_url"; then download_url="$LINUXQQ_SIGNED_URL"; else download_url=""; fi
    echo "正在下载 LinuxQQ ARM64 安装包..."
    if [ -z "$download_url" ] || ! curl -fL --connect-timeout 20 --max-time 600 \
        -A 'Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 Chrome/124 Safari/537.36' \
        -e 'https://im.qq.com/' "$download_url" -o "$qq_deb"; then
      rm -f "$qq_deb"
      if ! use_local_linuxqq_deb "$qq_deb"; then echo "LinuxQQ 签名下载失败"; return 1; fi
    fi
  fi
  if ! dpkg-deb --info "$qq_deb" >/dev/null 2>&1; then
    echo "LinuxQQ 下载文件不是有效的 deb 包"; rm -f "$qq_deb"; return 1
  fi
  package_arch=$(dpkg-deb -f "$qq_deb" Architecture 2>/dev/null)
  package_name=$(dpkg-deb -f "$qq_deb" Package 2>/dev/null)
  case "$package_arch" in arm64|aarch64) ;; *)
    echo "LinuxQQ 安装包架构不匹配: ${package_arch:-未知} (需要 arm64)"; rm -f "$qq_deb"; return 1 ;;
  esac
  if [ "$package_name" != "linuxqq" ]; then
    echo "LinuxQQ 安装包名称异常: ${package_name:-未知}"; rm -f "$qq_deb"; return 1
  fi
  if apt-cache show libasound2t64 >/dev/null 2>&1; then sound_package=libasound2t64; else sound_package=libasound2; fi
  if ! apt-get install -y libnss3 libgbm1 "$sound_package"; then echo "LinuxQQ 运行依赖安装失败"; return 1; fi
  if ! apt-get install -y "$qq_deb"; then echo "LinuxQQ deb 安装失败"; return 1; fi
  if ! linuxqq_ready; then echo "LinuxQQ 安装后的命令/包状态验收失败"; return 1; fi
  rm -f "$config_file" "$normalized_config" "$qq_deb"
  progress_echo "LinuxQQ 安装完成"
}
patch_napcat_installer(){
  local installer="$1"
  sed -i -E 's/curl[[:space:]]+-k[[:space:]]+-L/curl -fL/g; s/curl[[:space:]]+-kL/curl -fL/g' "$installer"
  if apt-cache show libasound2t64 >/dev/null 2>&1; then
    sed -i -E 's/(^|[^[:alnum:]_])libasound2([^[:alnum:]_]|$)/\1libasound2t64\2/g' "$installer"
  fi
  sed -i -E 's/^[[:space:]]*install_linuxqq[[:space:]]*$/log "LinuxQQ 已由 AstrBot Android 安装，跳过上游重复安装"/' "$installer"
  if grep -qE '^[[:space:]]*install_linuxqq[[:space:]]*$' "$installer"; then
    echo "修补 NapCat 上游 LinuxQQ 重复安装步骤失败"
    return 1
  fi
}
check_napcat_ready(){
  local missing=0
  command -v qq >/dev/null 2>&1 || { echo "[AstrBot Android] missing NapCat dependency: qq"; missing=1; }
  command -v Xvfb >/dev/null 2>&1 || { echo "[AstrBot Android] missing NapCat dependency: Xvfb"; missing=1; }
  dpkg-query -W -f='${Status}\n' linuxqq 2>/dev/null | grep -qx 'install ok installed' || { echo "[AstrBot Android] missing or broken NapCat dependency: linuxqq"; missing=1; }
  dpkg-query -W -f='${Status}\n' libnss3 2>/dev/null | grep -qx 'install ok installed' || { echo "[AstrBot Android] missing or broken NapCat dependency: libnss3"; missing=1; }
  dpkg-query -W -f='${Status}\n' libnspr4 2>/dev/null | grep -qx 'install ok installed' || { echo "[AstrBot Android] missing or broken NapCat dependency: libnspr4"; missing=1; }
  { dpkg-query -W -f='${Status}\n' libasound2t64 2>/dev/null || dpkg-query -W -f='${Status}\n' libasound2 2>/dev/null; } | grep -qx 'install ok installed' || { echo "[AstrBot Android] missing or broken NapCat dependency: libasound2/libasound2t64"; missing=1; }
  [ -f "$HOME/launcher.sh" ] || { echo "[AstrBot Android] missing NapCat launcher: $HOME/launcher.sh"; missing=1; }
  [ -f "$HOME/libnapcat_launcher.so" ] || { echo "[AstrBot Android] missing NapCat launcher library: $HOME/libnapcat_launcher.so"; missing=1; }
  [ -d "$HOME/napcat" ] || { echo "[AstrBot Android] missing NapCat directory: $HOME/napcat"; missing=1; }
  [ "$missing" -eq 0 ]
}
install_napcat(){
  if ! check_napcat_ready >/dev/null 2>&1; then
    progress_echo "Napcat $L_NOT_INSTALLED，$L_INSTALLING..."
    if ! prepare_apt_downloads; then echo "Ubuntu 软件源刷新失败，请检查上方 apt 输出"; exit 1; fi
    if ! apt --fix-broken install -y; then echo "apt 修复依赖失败，继续安装并在结束时验收"; fi
    if ! install_linuxqq; then echo "LinuxQQ 安装失败，NapCat 安装已中止"; exit 1; fi
    if [ -d "$HOME/napcat/config" ]; then
      echo "备份 NapCat 配置目录..."
      cp -r "$HOME/napcat/config" "$HOME/napcat_config_backup"
    fi
    rm -rf "$HOME/napcat" "$HOME/napcat.sh" "$HOME/launcher.sh" "$HOME/launcher.cpp" "$HOME/libnapcat_launcher.so"
    cd $HOME
    if ! curl -fL -o napcat.sh https://raw.githubusercontent.com/NapNeko/napcat-linux-installer/refs/heads/main/install.sh; then
      echo "下载 napcat.sh 失败"; exit 1
    fi
    if ! chmod +x napcat.sh; then echo "设置 napcat.sh 执行权限失败"; exit 1; fi
    if ! patch_napcat_installer napcat.sh; then echo "修补 napcat.sh 失败"; exit 1; fi
    if ! bash napcat.sh; then echo "NapCat 上游安装脚本执行失败"; exit 1; fi
    pkill -f 'qq --no-sandbox' 2>/dev/null || true
    pkill -f 'NapCat' 2>/dev/null || true
    pkill -f 'napcat' 2>/dev/null || true
    if [ -d "$HOME/napcat_config_backup" ]; then
      echo "恢复 NapCat 配置目录..."
      mkdir -p "$HOME/napcat/config"
      cp -r "$HOME/napcat_config_backup"/* "$HOME/napcat/config/"
      rm -rf "$HOME/napcat_config_backup"
    fi
  if [ ! -f "$HOME/napcat/config/onebot11.json" ]; then
    echo "写入 onebot11.json 默认配置文件"
    cat > "$HOME/napcat/config/onebot11.json" <<EOF
{
  "network": {
    "httpServers": [],
    "httpClients": [],
    "websocketServers": [],
    "websocketClients": [
      {
        "name": "WsClient",
        "enable": true,
        "url": "ws://localhost:${ASTRBOT_ONEBOT_WS_PORT:-6199}/ws",
        "messagePostFormat": "array",
        "reportSelfMessage": false,
        "reconnectInterval": 5000,
        "token": "kasdkfljsadhlskdjhasdlkfshdlafksjdhf",
        "debug": false,
        "heartInterval": 30000
      }
    ]
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": false,
  "parseMultMsg": false
}
EOF
  fi
fi
  configure_napcat_token_ttl
  if ! check_napcat_ready; then
    echo "NapCat 安装不完整，请查看上方 apt/dpkg/curl 错误后重试"
    exit 1
  fi
  progress_echo "Napcat $L_INSTALLED"
}
]==]

local SH_ASTRBOT = [==[
install_astrbot(){
  local INSTALL_DIR="$HOME/AstrBot"
  local CLONE_TEMP_DIR="$HOME/AstrBot_tmp"
  local BACKUP_DIR="/sdcard/Download/AstrBotBubble"
  rm -rf "$CLONE_TEMP_DIR"
  killall uv 2>/dev/null
  if [ -d "$INSTALL_DIR" ] && { [ ! -f "$INSTALL_DIR/pyproject.toml" ] || [ ! -f "$INSTALL_DIR/main.py" ]; }; then
    echo "AstrBot 安装目录不完整，准备重新安装..."
    rm -rf "$HOME/AstrBot_data_reinstall_backup"
    if [ -d "$INSTALL_DIR/data" ]; then cp -r "$INSTALL_DIR/data" "$HOME/AstrBot_data_reinstall_backup"; fi
    rm -rf "$INSTALL_DIR"
  fi
  if [ ! -d "$INSTALL_DIR" ]; then
    cd $HOME
    progress_echo "AstrBot $L_NOT_INSTALLED，$L_INSTALLING..."
    echo "正在获取 AstrBot 最新版本..."
    if [ -n "$CUSTOM_GIT_CLONE" ]; then
      echo "使用自定义 Git Clone 命令..."
      if ! eval "$CUSTOM_GIT_CLONE"; then echo "自定义 Git Clone 命令执行失败"; exit 1; fi
      if [ -d "AstrBot" ]; then mv "AstrBot" "$CLONE_TEMP_DIR"; else echo "错误: 未找到 AstrBot 目录"; exit 1; fi
    else
      network_test
      LATEST_TAG=$(git ls-remote --tags --sort='-v:refname' ${target_proxy:+${target_proxy}/}https://github.com/AstrBotDevs/AstrBot.git | awk -F'/' '{print $3}' | sed 's/\^{}//g' | grep -E '^v?[0-9]+(\.[0-9]+){1,2}$' | head -n 1)
      if [ -z "$LATEST_TAG" ]; then echo "警告: 无法获取最新 tag，使用 master 分支"; CLONE_BRANCH="master"; else echo "最新正式版: $LATEST_TAG"; CLONE_BRANCH="$LATEST_TAG"; fi
      echo "正在克隆 AstrBot 仓库，分支/标签: $CLONE_BRANCH..."
      if ! git clone --depth=1 --branch "$CLONE_BRANCH" ${target_proxy:+${target_proxy}/}https://github.com/AstrBotDevs/AstrBot.git "$CLONE_TEMP_DIR"; then
        echo "克隆 AstrBot 仓库失败"; rm -rf "$CLONE_TEMP_DIR"; exit 1
      fi
    fi
    mv "$CLONE_TEMP_DIR" "$INSTALL_DIR"
  else
    progress_echo "AstrBot $L_INSTALLED"
  fi
  progress_echo "AstrBot 初始化中"
  cd "$INSTALL_DIR"
  if [ ! -d "$INSTALL_DIR/data" ]; then
    echo "检测到 data 目录不存在，初始化数据目录..."
    mkdir "$INSTALL_DIR/data"
    if [ -d "$HOME/AstrBot_data_reinstall_backup" ]; then
      echo "恢复重装前 AstrBot 数据..."
      rm -rf "$INSTALL_DIR/data"
      mv "$HOME/AstrBot_data_reinstall_backup" "$INSTALL_DIR/data"
      REINSTALL_PLUGINS_FLAG=1
    else
      LATEST_BACKUP=""
      [ -d "$BACKUP_DIR" ] && LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/AstrBotBubble-backup-*.tar.gz 2>/dev/null | head -n 1)
      if [ -n "$LATEST_BACKUP" ]; then
        echo "找到备份文件: $LATEST_BACKUP"
        if tar -xzf "$LATEST_BACKUP" -C "$INSTALL_DIR"; then
          echo "备份恢复成功"; REINSTALL_PLUGINS_FLAG=1
        else
          echo "备份恢复失败，将使用 AstrBot 默认配置 (首次启动自动生成)"
        fi
      else
        # 不再替换预置 cmd_config.json: AstrBot 首次启动会生成默认配置,
        # NapCat 的 aiocqhttp 适配器改由「创建 NapCat 账号」时自动写入 (见 NC.sync_adapter)。
        echo "无备份，使用 AstrBot 默认配置 (NapCat 适配器在创建账号时自动绑定)"
      fi
    fi
    rm -rf "$INSTALL_DIR/.venv"
  fi
  if [ ! -d "$INSTALL_DIR/.venv" ] || ! $HOME/.local/bin/uv run --no-sync python -c "import aiohttp" >/dev/null 2>&1; then
    echo "同步 AstrBot 依赖..."
    if ! $HOME/.local/bin/uv sync; then echo "依赖同步失败"; exit 1; fi
    REINSTALL_PLUGINS_FLAG=1
  fi
  if [ "$REINSTALL_PLUGINS_FLAG" -eq 1 ]; then
    echo "检测到重装插件依赖标记，开始重装..."
    if [ -d "$INSTALL_DIR/data/plugins" ]; then
      for plugin_dir in "$INSTALL_DIR/data/plugins"/*; do
        if [ -d "$plugin_dir" ] && [ -f "$plugin_dir/requirements.txt" ]; then
          echo "安装插件依赖: $(basename "$plugin_dir")..."
          cd "$INSTALL_DIR"
          $HOME/.local/bin/uv pip install -r "$plugin_dir/requirements.txt" 2>/dev/null || echo "警告: 插件依赖安装失败，将在启动时重试"
        fi
      done
    fi
  fi
  progress_echo "AstrBot 安装完成"
}
]==]

-- 每个按钮下面就是它自己那一步的命令序列:
local function step_base(reinstall)
  host.spawn(env_pre(reinstall and "base" or "") .. "\n" .. SH_HELPERS .. SH_BASE .. [==[
maybe_prepare_reinstall base
install_sudo_curl_git
]==], "基础命令")
  host.nav.go(2)
end

local function step_uv(reinstall)
  host.spawn(env_pre(reinstall and "uv" or "") .. "\n" .. SH_HELPERS .. SH_NET .. SH_BASE .. SH_UV .. [==[
maybe_prepare_reinstall uv
install_sudo_curl_git
install_uv
]==], "uv")
  host.nav.go(2)
end

local function step_napcat(reinstall)
  host.spawn(env_pre(reinstall and "napcat" or "") .. "\n" .. SH_HELPERS .. SH_BASE .. SH_NAPCAT .. [==[
maybe_prepare_reinstall napcat
install_sudo_curl_git
install_napcat
]==], "NapCat")
  host.nav.go(2)
end

local function step_astrbot(reinstall, force_plugins)
  local pre = env_pre(reinstall and "astrbot" or "")
  local flag = force_plugins and "1" or "0"
  host.spawn(pre .. "\nexport REINSTALL_PLUGINS_FLAG=" .. flag .. "\nCUSTOM_GIT_CLONE=\"\"\n"
    .. SH_HELPERS .. SH_NET .. SH_BASE .. SH_UV .. SH_ASTRBOT .. [==[
maybe_prepare_reinstall astrbot
install_sudo_curl_git
install_uv
install_astrbot
]==], "AstrBot")
  host.nav.go(2)
end

local STEP_RUN = {
  base = step_base,
  uv = step_uv,
  napcat = step_napcat,
  astrbot = step_astrbot,
  opencode = function(reinstall) agent.install(reinstall) end,
}

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

-- 从 rootfs 里探测该实例已登录的 QQ (通过 onebot11_<qq>.json 文件名)
function NC.detect_qq(id)
  for _, e in ipairs(host.list_dir(nc_configdir(id))) do
    local qq = tostring(e.name):match("^onebot11_(%d+)%.json$")
    if qq then return qq end
  end
  return nil
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

-- 绑定状态: "configured" 端口/token 一致 | "mismatch" 存在但不一致 |
--           "unbound" 无适配器 | "nocfg" AstrBot 未安装
function NC.binding_state(ins)
  if not read_astrbot_config() then return "nocfg" end
  local port = ins.oneBotPort or ONEBOT_FIRST
  local token = ins.wsToken or ""
  for _, a in ipairs(NC.list_adapters()) do
    if a.id == ins.boundAdapterId and ins.boundAdapterId ~= "" then
      if a.enabled and a.port == port and token ~= "" and a.token == token then return "configured" end
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
  local list = NC.load(); local _, ins = NC.find(list, id)
  if not ins then return end
  NC.ensure_ws(ins)
  NC.sync_adapter(ins)   -- 补绑: 若创建时 AstrBot 尚未安装, 此处补上适配器
  NC.write_launcher(ins)
  local cmd = "echo [napcat] run launcher_" .. id .. ".sh; " ..
    "chmod +x /root/launcher_" .. id .. ".sh; bash /root/launcher_" .. id .. ".sh"
  host.spawn(cmd, ins.name or id, "napcat:" .. id)
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
    ins.qq = ""; ins.token = ""; ins.boundWebSocketName = ""; ins.boundAdapterId = ""
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
  local children = {
    tile("GitHub 代理", {
      icon = "cloud_sync_outlined",
      subtitle = "当前: " .. gh_proxy_label(gh_proxy()) .. " · 点击测速并选择镜像",
      trailing = icon("chevron_right"),
      onTap = open_gh_dialog,
    }),
  }
  for _, s in ipairs(ENV_STEPS) do
    local done = env_installed(s.id)
    children[#children + 1] = tile(s.title, {
      icon = done and "check_circle" or "error_outline",
      iconColor = done and "green" or "orange",
      subtitle = s.sub,
      trailing = button(done and "重装" or "安装", function()
        STEP_RUN[s.id](done)
      end, { variant = "tonal" }),
    })
  end
  return expansion("环境管理", children, { icon = "build_outlined" })
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

local function manage_section()
  return expansion("AstrBot 管理", {
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
    manage_section(),
  }
end)

-- 主页顶栏的两个 Agent 入口按钮已移至受保护的 agent/main.lua,
-- 与本文件解耦: 即使这里被改坏, agent 启动入口依然稳定存在。
