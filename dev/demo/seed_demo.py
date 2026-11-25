"""给 README 截图用的演示 qB（dev/demo/compose.yaml）加一批名字像真实发布的种子。
数据是容器卷里的稀疏文件，piece 哈希按全零算，qB 校验通过后就是做种状态。Shogun 那个不建文件，留作「下载中」。"""
import hashlib, json, re, subprocess, sys, urllib.parse, urllib.request, uuid, os

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = "http://127.0.0.1:18090"
GB = 1024 ** 3
MB = 1024 ** 2
PL = 16 * MB

def bencode(v):
    if isinstance(v, int): return b"i%de" % v
    if isinstance(v, str): v = v.encode()
    if isinstance(v, bytes): return b"%d:%s" % (len(v), v)
    if isinstance(v, list): return b"l" + b"".join(bencode(x) for x in v) + b"e"
    if isinstance(v, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, x) for k, x in v.items())
        return b"d" + b"".join(bencode(k) + bencode(x) for k, x in items) + b"e"

ZERO = hashlib.sha1(bytes(PL)).digest()

def pieces(seed, total):
    # 数据是稀疏文件（全零），按全零算哈希，qB 校验就能通过
    n, rest = divmod(total, PL)
    return ZERO * n + (hashlib.sha1(bytes(rest)).digest() if rest else b"")

# (名字, 分类, 站点, 文件 [(相对路径, 大小)] 或 None 表示单文件, 单文件大小, 是否已完成[, tracker 路径])
# tracker 路径见 ../fake_tracker.py：ok 正常，unreg 回「Unregistered torrent」（进「需要处理 › 疑似未注册」）
T = [
    ("Spirited.Away.2001.1080p.BluRay.x264.DTS-HD.MA.5.1-NOVA", "movies", "orbit", None, int(14.6 * GB), True),
    ("The.Shawshank.Redemption.1994.1080p.BluRay.x264.DTS-NOVA", "movies", "nebula", None, int(13.9 * GB), True),
    ("ubuntu-24.04.1-desktop-amd64.iso", "software", "orbit", None, int(5.9 * GB), True),
    ("Interstellar.2014.IMAX.2160p.UHD.BluRay.REMUX.HDR.HEVC.DTS-HD.MA.5.1-ARTEMIS", "movies", "aurora", None, int(81.2 * GB), True),
    ("[NC-Raws] 葬送的芙莉莲 - 28 (B-Global 1920x1080 HEVC AAC MKV).mkv", "anime", "nebula", None, int(612 * MB), True),
    ("繁花.Blossoms.Shanghai.S01.2023.2160p.WEB-DL.H265.AAC-Kestrel", "tv", "nebula", [(f"繁花.Blossoms.Shanghai.S01E{e:02d}.2023.2160p.WEB-DL.H265.AAC-Kestrel.mkv", int(3.1 * GB)) for e in range(1, 31)], 0, True),
    ("Severance.S02E10.Cold.Harbor.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DV.H.265-NOVA.mkv", "tv", "aurora", None, int(9.4 * GB), True),
    ("Shogun.2024.S01.2160p.DSNP.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-Kestrel", "tv", "orbit", [(f"Shogun.2024.S01E{e:02d}.2160p.DSNP.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-Kestrel.mkv", int(7.2 * GB)) for e in range(1, 11)], 0, False),
    ("流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.DDP5.1-Kestrel", "movies", "nebula", [("流浪地球2.The.Wandering.Earth.II.2023.2160p.WEB-DL.H265.DDP5.1-Kestrel.mkv", int(19.8 * GB))], 0, True),
    ("House.of.the.Dragon.S02.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.H.265-ARTEMIS", "tv", "aurora", [(f"House.of.the.Dragon.S02E{e:02d}.2160p.MAX.WEB-DL.DDP5.1.Atmos.DV.H.265-ARTEMIS.mkv", int(7.8 * GB)) for e in range(1, 9)], 0, True),
    ("Oppenheimer.2023.2160p.UHD.BluRay.REMUX.HDR.HEVC.TrueHD.7.1.Atmos-NOVA", "movies", "aurora", [("Oppenheimer.2023.2160p.UHD.BluRay.REMUX.HDR.HEVC.TrueHD.7.1.Atmos-NOVA.mkv", int(78.4 * GB))], 0, True),
    ("Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.H.265-ARTEMIS", "movies", "aurora", [("Dune.Part.Two.2024.2160p.WEB-DL.DDP5.1.Atmos.DV.H.265-ARTEMIS.mkv", int(24.6 * GB))], 0, True),
    ("Mr.Robot.S01.1080p.BluRay.x264-NOVA", "tv", "nebula", [(f"Mr.Robot.S01E{e:02d}.1080p.BluRay.x264-NOVA.mkv", int(2.4 * GB)) for e in range(1, 11)], 0, True, "unreg"),
    ("The.Matrix.1999.1080p.BluRay.x264.DTS-NOVA", "movies", "aurora", None, int(12.7 * GB), True, "unreg"),
]

# 给了参数时只加名字里含这些字样的（补加个别种子用）
if sys.argv[1:]:
    T = [t for t in T if any(a in t[0] for a in sys.argv[1:])]

def sh(*args):
    subprocess.run(["docker", "compose", "exec", "-T", "qb", *args], cwd=HERE, check=True, capture_output=True)

def req(path, data=None, cookie=None, files=None):
    headers = {"Cookie": cookie} if cookie else {}
    body = None
    if files is not None:
        b = uuid.uuid4().hex
        parts = []
        for k, v in data.items():
            parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        for fname, blob in files:
            parts.append(f'--{b}\r\nContent-Disposition: form-data; name="torrents"; filename="{fname}"\r\nContent-Type: application/x-bittorrent\r\n\r\n'.encode() + blob + b"\r\n")
        body = b"".join(parts) + f"--{b}--\r\n".encode()
        headers["Content-Type"] = f"multipart/form-data; boundary={b}"
    elif data is not None:
        body = urllib.parse.urlencode(data).encode()
    r = urllib.request.urlopen(urllib.request.Request(BASE + path, data=body, headers=headers), timeout=30)
    return r.read().decode(), r.headers.get_all("Set-Cookie") or []

def login(pw):
    try:
        body, cookies = req("/api/v2/auth/login", {"username": "admin", "password": pw})
    except urllib.error.HTTPError:
        return None
    for c in cookies:
        pair = c.split(";", 1)[0]
        if "SID" in pair.split("=", 1)[0]: return pair
    return None

cookie = login("adminadmin")
if not cookie:
    logs = subprocess.run(["docker", "compose", "logs", "--no-log-prefix", "qb"], cwd=HERE, capture_output=True, text=True).stdout
    tmp = re.findall(r"temporary password is provided for this session: (\S+)", logs)[-1]
    cookie = login(tmp)
    req("/api/v2/app/setPreferences", {"json": json.dumps({"web_ui_password": "adminadmin", "queueing_enabled": False, "dht": False, "pex": False, "lsd": False})}, cookie)
print("登录", bool(cookie))

for name, cat, site, files, size, done, *rest in T:
    path = rest[0] if rest else "ok"
    seed = hashlib.sha256(name.encode()).hexdigest()
    root = f"/downloads/{cat}"
    if files is None:
        info = {"name": name, "piece length": PL, "length": size, "pieces": pieces(seed, size), "private": 1}
        paths = [(f"{root}/{name}", size)]
    else:
        total = sum(s for _, s in files)
        info = {"name": name, "piece length": PL, "files": [{"length": s, "path": [p]} for p, s in files], "pieces": pieces(seed, total), "private": 1}
        paths = [(f"{root}/{name}/{p}", s) for p, s in files]
    if done:
        for p, s in paths:
            sh("mkdir", "-p", os.path.dirname(p))
            sh("truncate", "-s", str(s), p)
    t = {"announce": f"http://tracker.{site}.test:6969/{path}/announce", "info": {**info, "source": seed[:8]}, "created by": "demo"}
    out, _ = req("/api/v2/torrents/add", {"savepath": root, "category": cat, "skip_checking": "true" if done else "false", "paused": "false", "stopped": "false"}, cookie, files=[(name + ".torrent", bencode(t))])
    print(out.strip() or "ok", name)
