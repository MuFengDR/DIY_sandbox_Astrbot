#!/usr/bin/env python3
"""Initialize Android's dashboard credentials only when no password is stored."""
import hashlib
import json
import os
from pathlib import Path
import secrets
import tempfile


def initialize(config_path):
    config = json.loads(config_path.read_text(encoding="utf-8-sig")) if config_path.exists() else {}
    if not isinstance(config, dict):
        raise ValueError("AstrBot 配置必须为 JSON 对象")
    dashboard = config.setdefault("dashboard", {})
    if not isinstance(dashboard, dict):
        raise ValueError("AstrBot dashboard 配置必须为 JSON 对象")
    if dashboard.get("pbkdf2_password") or dashboard.get("password"):
        return

    # Preseed the supported stored-hash format. The upstream initial-password
    # environment variable rejects the requested seven-character default.
    password = "astrbot"
    salt = secrets.token_hex(16)
    iterations = 600_000
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), iterations).hex()
    dashboard.update({
        "pbkdf2_password": f"pbkdf2_sha256${iterations}${salt}${digest}",
        "password": hashlib.md5(password.encode()).hexdigest(),
        "password_storage_upgraded": True,
        "password_change_required": False,
    })
    dashboard.setdefault("username", "astrbot")
    config_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=config_path.parent,
                                         prefix=".dashboard-init-", delete=False) as stream:
            temporary = Path(stream.name)
            json.dump(config, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, config_path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    print("Initial username: " + str(dashboard["username"]), flush=True)
    print("Initial password: astrbot", flush=True)


if __name__ == "__main__":
    initialize(Path("data/cmd_config.json"))
