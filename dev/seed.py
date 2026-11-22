"""往开发环境的下载器里灌测试种子。只依赖标准库，种子在内存里生成，不落盘。

  python3 dev/seed.py trackers            # 每个下载器加 6 个各种 tracker 状态的种子（启动状态）
  python3 dev/seed.py bulk 20000 qb53 tr41 # 批量加种子（先在容器卷里写好数据，加进去就是做种状态）

种子内容是确定性的（由 prefix 和序号算出），所以数据文件可以提前在卷里生成：
  python3 dev/seed.py write-data <dir> <prefix> <count>   # 在 helper 容器里跑
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
PIECE = 16384
SIZE = 1024
SERVERS = {
    "qb53": ("qb", "http://127.0.0.1:18080"),
    "qb46": ("qb", "http://127.0.0.1:18081"),
    "qbx": ("qb", "http://127.0.0.1:18082"),
    "tr41": ("tr", "http://127.0.0.1:19091"),
    "tr40": ("tr", "http://127.0.0.1:19092"),
}
USER, PASSWORD = "admin", "adminadmin"

# 场景种子：名字 -> announce-list（每个内层列表是一个 tier）
SCENARIOS = {
    "scn-ok": [["http://pt-a.test:6969/ok/announce"]],
    "scn-unreg": [["http://pt-b.test:6969/unreg/announce"]],
    "scn-warn": [["http://pt-c.test:6969/warn/announce"]],
    "scn-err500": [["http://pt-a.test:6969/err500/announce"]],
    "scn-dead": [["http://dead.invalid:6969/announce"]],
    "scn-mixed": [["http://pt-b.test:6969/unreg/announce"], ["http://pt-a.test:6969/ok/announce"]],
}

# 批量种子的站点分布（累计到 100）
BULK_MIX = [
    (60, "http://pt-a.test:6969/ok/announce"),
    (25, "http://pt-b.test:6969/ok/announce"),
    (10, "http://pt-c.test:6969/warn/announce"),
    (4, "http://pt-b.test:6969/unreg/announce"),
    (1, "http://pt-a.test:6969/err500/announce"),
]


# ---------- 种子生成 ----------

def bencode(v) -> bytes:
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, str):
        v = v.encode()
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, list):
        return b"l" + b"".join(bencode(x) for x in v) + b"e"
    if isinstance(v, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, x) for k, x in v.items())
        return b"d" + b"".join(bencode(k) + bencode(x) for k, x in items) + b"e"
    raise TypeError(type(v))


def content(name: str) -> bytes:
    seed = hashlib.sha256(name.encode()).digest()
    return (seed * (SIZE // len(seed) + 1))[:SIZE]


def make_torrent(name: str, tiers: list[list[str]]) -> bytes:
    data = content(name)
    info = {
        "name": name,
        "length": len(data),
        "piece length": PIECE,
        "pieces": hashlib.sha1(data).digest(),
        "private": 1,
        "source": "transclient-dev",
    }
    meta = {"announce": tiers[0][0], "info": info}
    if len(tiers) > 1 or len(tiers[0]) > 1:
        meta["announce-list"] = tiers
    return bencode(meta)


def bulk_name(prefix: str, i: int) -> str:
    return f"{prefix}-{i:05d}.bin"


def bulk_tracker(i: int) -> str:
    slot = i % 100
    acc = 0
    for share, url in BULK_MIX:
        acc += share
        if slot < acc:
            return url
    return BULK_MIX[0][1]


# ---------- qB ----------

class QB:
    def __init__(self, base: str):
        self.base = base
        req = urllib.request.Request(
            base + "/api/v2/auth/login",
            data=urllib.parse.urlencode({"username": USER, "password": PASSWORD}).encode(),
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            self.cookie = next(
                c.split(";", 1)[0] for c in r.headers.get_all("Set-Cookie") if "SID" in c.split("=", 1)[0]
            )

    def add(self, files: list[tuple[str, bytes]], fields: dict):
        boundary = uuid.uuid4().hex
        parts = []
        for k, v in fields.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        for fname, blob in files:
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="torrents"; filename="{fname}"\r\n'
                f"Content-Type: application/x-bittorrent\r\n\r\n".encode() + blob + b"\r\n"
            )
        parts.append(f"--{boundary}--\r\n".encode())
        req = urllib.request.Request(
            self.base + "/api/v2/torrents/add",
            data=b"".join(parts),
            headers={"Cookie": self.cookie, "Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, r.read().decode()


# ---------- TR ----------

class TR:
    def __init__(self, base: str):
        self.url = base + "/transmission/rpc"
        self.auth = "Basic " + base64.b64encode(f"{USER}:{PASSWORD}".encode()).decode()
        self.sid = ""

    def call(self, method: str, args: dict):
        body = json.dumps({"method": method, "arguments": args}).encode()
        for _ in range(3):
            req = urllib.request.Request(
                self.url, data=body,
                headers={"Authorization": self.auth, "X-Transmission-Session-Id": self.sid},
            )
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    return json.loads(r.read())
            except urllib.error.HTTPError as e:
                if e.code == 409:
                    self.sid = e.headers["X-Transmission-Session-Id"]
                    continue
                raise
        raise RuntimeError("409 loop")

    def add(self, blob: bytes, download_dir: str, paused: bool):
        res = self.call("torrent-add", {
            "metainfo": base64.b64encode(blob).decode(),
            "download-dir": download_dir,
            "paused": paused,
        })
        if res.get("result") != "success":
            raise RuntimeError(res)
        return res


# ---------- 命令 ----------

def cmd_trackers(targets):
    for name in targets:
        kind, base = SERVERS[name]
        blobs = [(f"{n}.torrent", make_torrent(f"{n}.bin", tiers)) for n, tiers in SCENARIOS.items()]
        if kind == "qb":
            print(name, QB(base).add(blobs, {"savepath": "/downloads/scn", "paused": "false", "stopped": "false"}))
        else:
            tr = TR(base)
            for _, blob in blobs:
                tr.add(blob, "/downloads/scn", paused=False)
            print(name, "added", len(blobs))


def volume_for(name: str) -> str:
    return f"transclient-dev_{name}-downloads"


def write_data_in_volume(name: str, prefix: str, count: int):
    subprocess.run([
        "docker", "run", "--rm",
        "-v", f"{volume_for(name)}:/downloads",
        "-v", f"{HERE}:/dev-scripts:ro",
        "python:3.13-alpine",
        "sh", "-c",
        f"python -I /dev-scripts/seed.py write-data /downloads/bulk {prefix} {count} && chown -R 1000:1000 /downloads/bulk",
    ], check=True)


def cmd_bulk(count: int, targets):
    prefix = "bulk"
    blobs = [(bulk_name(prefix, i), make_torrent(bulk_name(prefix, i), [[bulk_tracker(i)]])) for i in range(count)]
    for name in targets:
        kind, base = SERVERS[name]
        write_data_in_volume(name, prefix, count)
        if kind == "qb":
            qb = QB(base)
            step = 500
            for off in range(0, count, step):
                chunk = [(f"{n}.torrent", b) for n, b in blobs[off:off + step]]
                # 数据已经在卷里了，跳过校验：不跳的话 qB 一个个校验 2 万个种子要好几个小时
                qb.add(chunk, {"savepath": "/downloads/bulk", "paused": "false", "stopped": "false", "skip_checking": "true"})
                print(f"\r{name}: {min(off + step, count)}/{count}", end="", flush=True)
        else:
            tr = TR(base)
            done = 0

            def one(item):
                TR_local = TR(base)
                TR_local.sid = tr.sid
                TR_local.add(item[1], "/downloads/bulk", paused=False)

            tr.call("session-get", {"fields": ["version"]})  # 先拿 session id
            with ThreadPoolExecutor(8) as pool:
                for _ in pool.map(one, blobs):
                    done += 1
                    if done % 500 == 0 or done == count:
                        print(f"\r{name}: {done}/{count}", end="", flush=True)
        print()


def cmd_write_data(directory: str, prefix: str, count: int):
    os.makedirs(directory, exist_ok=True)
    for i in range(count):
        n = bulk_name(prefix, i)
        with open(os.path.join(directory, n), "wb") as f:
            f.write(content(n))
    print(f"wrote {count} files to {directory}")


if __name__ == "__main__":
    cmd, *rest = sys.argv[1:] or ["help"]
    if cmd == "trackers":
        cmd_trackers(rest or ["qb53", "qb46", "tr41", "tr40"])
    elif cmd == "bulk":
        cmd_bulk(int(rest[0]), rest[1:] or ["qb53", "tr41"])
    elif cmd == "write-data":
        cmd_write_data(rest[0], rest[1], int(rest[2]))
    else:
        print(__doc__)
