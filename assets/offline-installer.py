#!/usr/bin/env python3
"""APK-bundled offline installer; never executes package/install scripts."""
import argparse
import fcntl
import gzip
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import uuid

FORMAT = "astrbot-offline-package-v1"
DEPENDENCIES = {
    "base": [], "uv": ["base"], "linuxqq": ["base"],
    "napcat": ["base", "linuxqq"], "astrbot": ["base", "uv"],
}
HOME = Path("/root")
STATE = HOME / ".astrbot-android"


def run(args, **kwargs):
    print("[offline] " + " ".join(str(x) for x in args), flush=True)
    return subprocess.run([str(x) for x in args], check=True, **kwargs)


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".new")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    os.replace(temporary, path)


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def unpack(archive, destination):
    """Validate the entire archive before extracting; links may stay inside it."""
    # tar stops at its end marker; consume gzip to EOF to also verify its
    # checksum/trailer and detect interrupted file imports.
    with gzip.open(archive, "rb") as compressed:
        while compressed.read(1024 * 1024):
            pass
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        names = set()
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or ".." in path.parts or "\\" in member.name
                    or not path.parts or path.parts[0] != "package"):
                raise ValueError("离线包包含非法路径：" + member.name)
            if member.name in names:
                raise ValueError("离线包包含重复文件：" + member.name)
            names.add(member.name)
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("离线包包含不支持的文件类型：" + member.name)
            if member.issym() or member.islnk():
                target = (PurePosixPath(member.name).parent / member.linkname
                          if member.issym() else PurePosixPath(member.linkname))
                resolved = os.path.normpath(str(target)).replace("\\", "/")
                if (PurePosixPath(member.linkname).is_absolute()
                        or not resolved.startswith("package/") or "\\" in member.linkname):
                    raise ValueError("离线包链接指向包外：" + member.name)
        needed = sum(m.size for m in members if m.isfile())
        if shutil.disk_usage(destination).free < needed + 64 * 1024 * 1024:
            raise ValueError("空间不足，无法解压离线包")
        # Python 3.12 ships in the APK rootfs; data_filter also guards link chains.
        bundle.extractall(destination, members=members, filter="data")
    return needed


def validate(root, component):
    manifest = json.loads((root / "manifest.json").read_text())
    if not isinstance(manifest, dict):
        raise ValueError("manifest.json 必须是元数据对象")
    if manifest.get("format") != FORMAT:
        raise ValueError("不支持的离线包格式")
    if manifest.get("component") != component:
        raise ValueError("选择的离线包不是 " + component + " 组件")
    if manifest.get("architecture") != "arm64":
        raise ValueError("离线包必须为 ARM64 架构")
    if not isinstance(manifest.get("version"), str) or not manifest["version"].strip():
        raise ValueError("离线包缺少版本信息")
    if manifest.get("requires") != DEPENDENCIES[component]:
        raise ValueError("离线包依赖声明不正确")
    paths = {
        "base": ["debs"], "uv": ["uv/uv", "uv/uvx"],
        "linuxqq": ["linuxqq.deb", "debs"],
        "napcat": ["napcat/napcat.mjs", "launcher.sh", "libnapcat_launcher.so", "debs"],
        "astrbot": ["astrbot/main.py", "astrbot/pyproject.toml", "astrbot/uv.lock",
                    "python/bin/python3", "wheels", "requirements-offline.txt", "dashboard/index.html"],
    }
    files = root / "files"
    for name in paths[component]:
        required = files / name
        directory = name in ("debs", "wheels")
        if not (required.is_dir() if directory else required.is_file()):
            raise ValueError("离线包缺少文件：" + name)
    if component == "base" and not list((files / "debs").glob("*.deb")):
        raise ValueError("基础包中没有 deb 安装文件")
    if component == "linuxqq" and not list((files / "debs").glob("*.deb")):
        raise ValueError("LinuxQQ 包中没有运行依赖 deb")
    if component == "napcat" and not list((files / "debs").glob("*.deb")):
        raise ValueError("NapCat 包中没有 Xvfb 离线依赖")
    if component == "astrbot":
        if not list((files / "wheels").glob("*.whl")):
            raise ValueError("AstrBot 包缺少 Python wheel 依赖")
        requirements = (files / "requirements-offline.txt").read_text()
        if not requirements.strip() or any(s in requirements for s in ("://", "--index", "--extra-index", "--find-links", "-e ", " @ ")):
            raise ValueError("Python 离线清单包含远程源或未锁定依赖")
    return manifest


def dpkg_ready(package):
    result = subprocess.run(["dpkg-query", "-W", "-f=${Status}", package],
                            capture_output=True, text=True)
    return result.returncode == 0 and result.stdout.strip() == "install ok installed"


def ready(component):
    if component == "base":
        return all(shutil.which(x) for x in ("sudo", "git", "curl", "tar")) and (
            Path("/etc/ssl/certs/ca-certificates.crt").is_file())
    if component == "uv":
        return all(os.access(HOME / ".local/bin" / x, os.X_OK) for x in ("uv", "uvx"))
    if component == "linuxqq":
        return bool(shutil.which("qq")) and dpkg_ready("linuxqq") and not qq_runtime_missing()
    return False


def qq_runtime_missing(with_display=False):
    missing = [name for name in ("libnss3", "libnspr4", "libgbm1") if not dpkg_ready(name)]
    if not (dpkg_ready("libasound2t64") or dpkg_ready("libasound2")):
        missing.append("libasound2t64/libasound2")
    if with_display:
        missing += [name for name in ("Xvfb", "xvfb-run") if not shutil.which(name)]
    return missing


def check_dependencies(component):
    missing = [x for x in DEPENDENCIES[component] if not ready(x)]
    if missing:
        raise ValueError("请先安装依赖组件：" + "、".join(missing))
def install_debs(files):
    for file in files:
        arch = subprocess.check_output(["dpkg-deb", "-f", file, "Architecture"], text=True).strip()
        if arch not in ("arm64", "all"):
            raise ValueError("deb 架构不匹配：" + str(file))
    # Never load network sources, nor download missing packages.
    updates = Path("/var/lib/dpkg/updates")
    if updates.exists() and any(path.name.isdigit() for path in updates.iterdir()):
        # dpkg refuses apt after being killed mid-configuration. Configure
        # what is already unpacked, then let apt repair from this local pack.
        subprocess.run(["dpkg", "--configure", "-a"], check=False,
                       env=dict(os.environ, DEBIAN_FRONTEND="noninteractive"))
    args = ["apt-get", "--no-download", "--fix-broken", "-y", "-o", "Dir::Etc::sourcelist=/dev/null",
            "-o", "Dir::Etc::sourceparts=-", "-o", "Dir::Cache::archives=" + str(files[0].parent),
            "-o", "DPkg::Lock::Timeout=30", "install"]
    env = dict(os.environ, DEBIAN_FRONTEND="noninteractive")
    run(args + ["--simulate"] + files, env=env)
    run(args + files, env=env)


def recover(journal):
    if not journal.exists():
        return
    transaction = json.loads(journal.read_text())
    if transaction["committed"]:
        for entry in transaction["entries"]:
            remove(Path(entry["backup"]))
    else:
        for entry in reversed(transaction["entries"]):
            target, backup = Path(entry["target"]), Path(entry["backup"])
            if backup.exists() or backup.is_symlink():
                remove(target)
                os.replace(backup, target)
            elif not entry["existed"]:
                remove(target)
    journal.unlink()


def commit_files(replacements, journal):
    """Persist intent before each rename so next launch can recover a killed install."""
    transaction = {"committed": False, "entries": []}
    try:
        for source, target in replacements:
            target.parent.mkdir(parents=True, exist_ok=True)
            backup = target.with_name(target.name + ".offline-previous")
            if backup.exists() or backup.is_symlink():
                raise ValueError("请先处理遗留备份：" + str(backup))
            existed = target.exists() or target.is_symlink()
            transaction["entries"].append({"target": str(target), "backup": str(backup), "existed": existed})
            write_json(journal, transaction)
            if existed:
                os.replace(target, backup)
            os.replace(source, target)
        transaction["committed"] = True
        write_json(journal, transaction)
    finally:
        recover(journal)


def clean_runtimes(component):
    roots = STATE / "runtimes"
    if not roots.exists():
        return
    references = [HOME / "AstrBot", HOME / ".local/bin/uv", HOME / ".local/bin/uvx"]
    for directory in roots.glob(component + "-*"):
        if any(path.resolve().is_relative_to(directory.resolve()) for path in references):
            continue
        shutil.rmtree(directory, ignore_errors=True)


def install_files(root, component, journal):
    files = root / "files"
    if component in ("base", "linuxqq"):
        debs = sorted((files / "debs").glob("*.deb"))
        if component == "linuxqq":
            linuxqq_deb = files / "linuxqq.deb"
            name = subprocess.check_output(["dpkg-deb", "-f", linuxqq_deb, "Package"], text=True).strip()
            if name != "linuxqq":
                raise ValueError("LinuxQQ 包内的 deb 不是 linuxqq")
            version = subprocess.check_output(["dpkg-deb", "-f", linuxqq_deb, "Version"], text=True).strip()
            arch = subprocess.check_output(["dpkg-deb", "-f", linuxqq_deb, "Architecture"], text=True).strip()
            if arch != "arm64" or not re.fullmatch(r"[0-9][A-Za-z0-9.+:~\-]*", version):
                raise ValueError("LinuxQQ deb 的架构或版本字段不正确")
            # apt --no-download finds package archives by their canonical names.
            canonical = files / "debs" / ("linuxqq_" + version.replace(":", "%3a") + "_" + arch + ".deb")
            shutil.copy2(linuxqq_deb, canonical)
            if canonical not in debs:
                debs.append(canonical)
        install_debs(debs)
        if component == "base":
            missing = [name for name in ("sudo", "git", "curl", "tar") if not shutil.which(name)]
            if not Path("/etc/ssl/certs/ca-certificates.crt").is_file():
                missing.append("ca-certificates")
            if missing:
                raise ValueError("基础环境包安装后仍缺少：" + "、".join(missing))
        elif not ready(component):
            if component == "linuxqq":
                missing = qq_runtime_missing()
                raise ValueError("LinuxQQ 安装后仍缺少运行依赖：" + "、".join(missing or ["qq 命令或 dpkg 状态"]))
            raise ValueError("安装后的组件检查失败：" + component)
        return

    runtime = STATE / "runtimes" / (component + "-" + uuid.uuid4().hex)
    runtime.mkdir(parents=True)
    try:
        replacements = []
        if component == "uv":
            for name in ("uv", "uvx"):
                binary = runtime / name
                shutil.copy2(files / "uv" / name, binary)
                binary.chmod(0o755)
                run([binary, "--version"])
                link = runtime / (name + ".link")
                # Calculate relative path from its *final* location.
                link.symlink_to(os.path.relpath(binary, HOME / ".local/bin"))
                replacements.append((link, HOME / ".local/bin" / name))
        elif component == "napcat":
            napcat_debs = sorted((files / "debs").glob("*.deb"))
            if not napcat_debs:
                raise ValueError("NapCat 包中没有 Xvfb 离线依赖")
            install_debs(napcat_debs)
            missing = [name for name in ("Xvfb", "xvfb-run") if not shutil.which(name)]
            if missing:
                raise ValueError("NapCat 包安装 Xvfb 依赖后仍缺少：" + "、".join(missing))
            shutil.copytree(files / "napcat", runtime / "napcat", symlinks=True)
            old_config = HOME / "napcat/config"
            if old_config.exists():
                shutil.copytree(old_config, runtime / "napcat/config", dirs_exist_ok=True)
            config = runtime / "napcat/config/onebot11.json"
            if not config.exists():
                config.parent.mkdir(parents=True, exist_ok=True)
                write_json(config, {"network": {"httpServers": [], "httpClients": [], "websocketServers": [], "websocketClients": [{
                    "name": "WsClient", "enable": True, "url": "ws://localhost:" + os.environ.get("ASTRBOT_ONEBOT_WS_PORT", "6199") + "/ws",
                    "messagePostFormat": "array", "token": "kasdkfljsadhlskdjhasdlkfshdlafksjdhf", "reconnectInterval": 5000}]}})
            script = runtime / "napcat/napcat.mjs"
            script.write_text(re.sub(r"static MAX_CREDENTIAL_VALID_SECONDS = \d+", "static MAX_CREDENTIAL_VALID_SECONDS = 604800", script.read_text()))
            for name in ("launcher.sh", "libnapcat_launcher.so"):
                shutil.copy2(files / name, runtime / name)
                (runtime / name).chmod(0o755)
            replacements = [(runtime / name, HOME / name) for name in ("napcat", "launcher.sh", "libnapcat_launcher.so")]
        elif component == "astrbot":
            source = runtime / "AstrBot"
            shutil.copytree(files / "astrbot", source, symlinks=True)
            shutil.copytree(files / "python", runtime / "python", symlinks=True)
            python = runtime / "python/bin/python3"
            python.resolve().chmod(0o755)
            python_version = subprocess.check_output([python, "-c", "import platform; print(platform.python_version())"], text=True).strip()
            (source / ".python-version").write_text(python_version + "\n")
            # Keep the stable runtime path: venv scripts embed absolute paths.
            uv = HOME / ".local/bin/uv"
            env = dict(os.environ, UV_OFFLINE="1", UV_NO_INDEX="1", UV_PYTHON_DOWNLOADS="never", UV_LINK_MODE="copy")
            run([uv, "venv", "--python", python, source / ".venv"], env=env)
            run([uv, "pip", "install", "--python", source / ".venv/bin/python", "--offline", "--no-index",
                 "--find-links", files / "wheels", "-r", files / "requirements-offline.txt"], env=env)
            run([source / ".venv/bin/python", "-c", "import aiohttp; import astrbot"], cwd=source, env=env)
            old_data = HOME / "AstrBot/data"
            if old_data.exists():
                shutil.copytree(old_data, source / "data", dirs_exist_ok=True)
            else:
                (source / "data").mkdir(exist_ok=True)
                default = HOME / "cmd_config.json"
                if default.exists():
                    shutil.copy2(default, source / "data/cmd_config.json")
            # First launch must not download its frontend. Preserve all
            # existing data, including a user-provided dashboard, on reinstall.
            if not (source / "data/dist").exists():
                shutil.copytree(files / "dashboard", source / "data/dist")
            # Newer releases can use bundled assets when an existing user
            # dashboard belongs to an older core, without fetching a repair.
            shutil.copytree(files / "dashboard", source / "astrbot/dashboard/dist", dirs_exist_ok=True)
            link = runtime / "AstrBot.link"
            # This link moves to /root; its target must be relative to /root.
            link.symlink_to(os.path.relpath(source, HOME))
            replacements = [(link, HOME / "AstrBot")]
        commit_files(replacements, journal)
    except BaseException:
        shutil.rmtree(runtime, ignore_errors=True)
        raise


def install(archive, component):
    if platform.machine() not in ("aarch64", "arm64"):
        raise ValueError("离线安装只支持 ARM64 Ubuntu")
    state = STATE / "offline-packages"
    state.mkdir(parents=True, exist_ok=True)
    with (state / "install.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("另一个离线安装正在进行，请稍后重试")
        journal = state / "transaction.json"
        recover(journal)
        # A killed process cannot run TemporaryDirectory cleanup. The global
        # lock guarantees these staging directories no longer belong to a job.
        for stale in state.glob(".stage-*"):
            remove(stale)
        clean_runtimes(component)
        with tempfile.TemporaryDirectory(prefix=".stage-", dir=state) as temporary:
            stage = Path(temporary)
            print("[offline] 正在检查并解压离线包…", flush=True)
            needed = unpack(archive, stage)
            root = stage / "package"
            manifest = validate(root, component)
            check_dependencies(component)
            if shutil.disk_usage(state).free < needed + archive.stat().st_size + 64 * 1024 * 1024:
                raise ValueError("空间不足，无法保留缓存并安装组件")
            # Cache only a valid package; retain it when installation fails.
            cached = state / component / "package.tar.gz"
            cached.parent.mkdir(exist_ok=True)
            if archive.resolve() != cached.resolve():
                incoming = cached.with_suffix(".incoming")
                shutil.copyfile(archive, incoming)
                os.replace(incoming, cached)
            write_json(cached.parent / "manifest.json", manifest)
            install_files(root, component, journal)
            write_json(cached.parent / "installed.json", manifest)
            clean_runtimes(component)
            print("[offline] 安装完成：" + component + " " + manifest["version"], flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--step", choices=list(DEPENDENCIES), required=True)
    parser.add_argument("--package", type=Path, default=os.environ.get("ASTRBOT_OFFLINE_PACKAGE"))
    args = parser.parse_args()
    if args.package is None:
        parser.error("需要 --package 或 ASTRBOT_OFFLINE_PACKAGE")
    try:
        install(args.package, args.step)
    except (OSError, EOFError, ValueError, KeyError, tarfile.TarError, subprocess.SubprocessError) as error:
        print("[offline] 安装失败：" + str(error), file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
