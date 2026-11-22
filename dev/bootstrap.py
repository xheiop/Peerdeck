"""初始化 compose 里的 qB：把 linuxserver 镜像生成的临时密码改成 adminadmin，并关掉排队。

用法：python3 dev/bootstrap.py
可以重复跑：已经能用 adminadmin 登录的实例只更新偏好设置。
"""

import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PASSWORD = "adminadmin"
INSTANCES = {"qb53": 18080, "qb46": 18081}
# 额外实例：python3 dev/bootstrap.py qbx
EXTRA = {"qbx": 18082}
PREFS = {
    "web_ui_password": PASSWORD,
    "queueing_enabled": False,
    "dht": False,
    "pex": False,
    "lsd": False,
}


def post(base: str, path: str, data: dict, cookie: str | None = None):
    req = urllib.request.Request(
        base + path,
        data=urllib.parse.urlencode(data).encode(),
        headers={"Cookie": cookie} if cookie else {},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return r.read().decode(), r.headers.get_all("Set-Cookie") or []


def login(base: str, password: str) -> str | None:
    try:
        body, cookies = post(base, "/api/v2/auth/login", {"username": "admin", "password": password})
    except urllib.error.HTTPError as e:
        if e.code == 401:  # 4.6.7 / 5.3.0 密码错误都是 401，不是旧文档说的 200 "Fails."
            return None
        raise
    # 4.x：200 "Ok." + SID=...；5.3：204 空 body + QBT_SID_<port>=...
    if body.strip() not in ("Ok.", ""):
        return None
    for c in cookies:
        pair = c.split(";", 1)[0]
        if "SID" in pair.split("=", 1)[0]:
            return pair
    return None


def temp_password(service: str) -> str | None:
    logs = subprocess.run(
        ["docker", "compose", "logs", "--no-log-prefix", service],
        capture_output=True, text=True, cwd=sys.path[0],
    ).stdout
    found = re.findall(r"temporary password is provided for this session: (\S+)", logs)
    return found[-1] if found else None


def main():
    targets = {k: {**INSTANCES, **EXTRA}[k] for k in sys.argv[1:]} or INSTANCES
    for service, port in targets.items():
        base = f"http://127.0.0.1:{port}"
        for _ in range(60):
            try:
                urllib.request.urlopen(base + "/api/v2/app/version", timeout=2)
            except urllib.error.HTTPError:
                break  # 403 也说明 WebUI 起来了
            except OSError:
                time.sleep(1)
        cookie = login(base, PASSWORD)
        if cookie is None:
            tmp = temp_password(service)
            cookie = login(base, tmp) if tmp else None
        if cookie is None:
            sys.exit(f"{service}: 登录失败（既不是 {PASSWORD} 也拿不到临时密码）")
        post(base, "/api/v2/app/setPreferences", {"json": json.dumps(PREFS)}, cookie)
        assert login(base, PASSWORD), f"{service}: 改密码后仍无法登录"
        print(f"{service}: ok ({base})")


if __name__ == "__main__":
    main()
