#!/usr/bin/env python3
"""生成 AltStore / SideStore 的源（altstore.json），随每个正式 Release 一起发布。

  scripts/altstore-source.py <ipa> <版本说明.md> > altstore.json

用户添加的地址是 releases/latest/download/altstore.json，永远指向最新的正式版，所以只列当前这一个版本。

版本号、构建号、最低系统、大小、sha256 和权限全部从 ipa 里读，不另抄一份：
AltStore 安装前会逐项核对，版本对不上、或者 ipa 里有源里没声明的权限（包括每一个 *UsageDescription），都会拒装。
字段说明：https://faq.altstore.io/developers/make-a-source

环境变量：GITHUB_REPOSITORY（默认 xheiop/Peerdeck）。
只依赖标准库和 macOS 自带的 codesign。
"""

import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

APP = "Payload/Peerdeck.app/"
TINT = "#B25000"  # 图标里的琥珀色菱形
SCREENSHOTS = ["ios-overview.png", "ios-attention.png", "ios-sites.png", "ios-overview-dark.png"]


def fail(message):
    sys.exit(f"altstore-source: {message}")


def entitlement_keys(binary):
    """二进制签名里带的 entitlements。没签名就是空的；其他错误不能当成「没有」吞掉。"""
    r = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", binary], capture_output=True)
    if r.returncode != 0:
        if b"not signed at all" in r.stderr:
            return set()
        fail(r.stderr.decode(errors="replace").strip())
    if not r.stdout.strip():
        return set()
    # AltStore 核对时不看这两项
    return set(plistlib.loads(r.stdout)) - {"application-identifier", "com.apple.developer.team-identifier"}


def inspect_ipa(path):
    """返回 (主 app 的 Info.plist, entitlements, 隐私说明)，后两项包括所有扩展。"""
    entitlements, privacy = set(), {}
    with zipfile.ZipFile(path) as z, tempfile.TemporaryDirectory() as tmp:
        bundle = re.compile(re.escape(APP) + r"(PlugIns/[^/]+\.appex/)?Info\.plist")
        plists = sorted((n for n in z.namelist() if bundle.fullmatch(n)), key=len)
        if not plists or plists[0] != APP + "Info.plist":
            fail(f"{path} 里没有 {APP}Info.plist")
        info = None
        for name in plists:
            p = plistlib.loads(z.read(name))
            info = info or p
            privacy.update({k: v for k, v in p.items() if k.endswith("UsageDescription")})
            binary = z.extract(name[: -len("Info.plist")] + p["CFBundleExecutable"], tmp)
            entitlements |= entitlement_keys(binary)
    return info, sorted(entitlements), dict(sorted(privacy.items()))


def plain_text(markdown):
    """AltStore 按纯文本显示版本说明。"""
    s = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", markdown)
    s = re.sub(r"^#{1,6} +", "", s, flags=re.M)
    s = re.sub(r"^(\s*)[-*] +", r"\1• ", s, flags=re.M)
    s = s.replace("**", "").replace("`", "")
    return s.strip()


def main():
    if len(sys.argv) != 3:
        fail("用法：altstore-source.py <ipa> <版本说明.md>")
    ipa, notes_file = sys.argv[1:]
    with open(notes_file, encoding="utf-8") as f:
        notes = plain_text(f.read())
    if not notes:
        fail("版本说明是空的")
    with open(ipa, "rb") as f:
        data = f.read()
    info, entitlements, privacy = inspect_ipa(ipa)

    repo = os.environ.get("GITHUB_REPOSITORY") or "xheiop/Peerdeck"
    version = info["CFBundleShortVersionString"]
    tag = f"v{version}"
    # 图标和截图钉在这个 tag 上，主分支以后改名或换图都不影响已发布的源
    raw = f"https://raw.githubusercontent.com/{repo}/{tag}/assets"
    subtitle = "A remote for qBittorrent and Transmission"
    description = (
        "Manage several qBittorrent and Transmission servers in one list, see tracker problems first, "
        "and clean up unregistered torrents without losing cross-seeded data.\n\n"
        "在一张列表里管理多台 qBittorrent / Transmission，先看到 tracker 的问题，"
        "清理未注册种子时保留还有辅种的数据。"
    )

    source = {
        "name": "Peerdeck",
        "subtitle": subtitle,
        "description": description,
        "iconURL": f"{raw}/icon.png",
        "website": f"https://github.com/{repo}",
        "tintColor": TINT,
        "featuredApps": [info["CFBundleIdentifier"]],
        "apps": [
            {
                "name": "Peerdeck",
                "bundleIdentifier": info["CFBundleIdentifier"],
                "developerName": repo.split("/")[0],
                "subtitle": subtitle,
                "localizedDescription": description,
                "iconURL": f"{raw}/icon.png",
                "tintColor": TINT,
                "category": "utilities",
                "screenshots": [f"{raw}/screenshots/{name}" for name in SCREENSHOTS],
                "versions": [
                    {
                        "version": version,
                        "buildVersion": info["CFBundleVersion"],
                        "marketingVersion": version,
                        # AltStore 的日期解析不接受小数秒
                        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                        "localizedDescription": notes,
                        "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(ipa)}",
                        "size": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "minOSVersion": info["MinimumOSVersion"],
                    }
                ],
                "appPermissions": {"entitlements": entitlements, "privacy": privacy},
            }
        ],
        "news": [],
    }
    json.dump(source, sys.stdout, ensure_ascii=False, indent=2)
    print()


if __name__ == "__main__":
    main()
