#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gdtf_fetch.py — 下载真实厂家 GDTF 文件到 data/gdtf/

用法：
    python3 src/gdtf_fetch.py            # 下载 data/fixtures.yaml 里缺的文件
    python3 src/gdtf_fetch.py --force    # 全部重下

来源是 gdtf-lights.com 的公开 catalog API，无需登录。
下载后按 manufacturer@fixture.gdtf 命名存盘，并校验 zip 完整性。

失败即报错退出（不静默跳过）—— 缺符号就不要出图。
"""
import argparse
import os
import sys
import urllib.request
import zipfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BASE = "https://gdtf-lights.com"
UA = {"User-Agent": "Mozilla/5.0 (compatible; dos-lx-workspace)"}


def cache_path(key, entry):
    """本地缓存文件名：<key>__<slug>.gdtf"""
    return os.path.join(ROOT, "data", "gdtf", f"{key}__{entry['slug']}.gdtf")


def download(url, dest, force=False):
    if os.path.exists(dest) and not force:
        if valid(dest):
            return "cached"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    req = urllib.request.Request(BASE + url, headers=UA)
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    tmp = dest + ".part"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, dest)
    return f"{len(data) // 1024} KB"


def valid(path):
    """确认是完整 zip 且含 description.xml。"""
    try:
        with zipfile.ZipFile(path) as z:
            return "description.xml" in z.namelist()
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--manifest", default=os.path.join(ROOT, "data", "fixtures.yaml"))
    a = ap.parse_args()

    man = yaml.safe_load(open(a.manifest, encoding="utf-8"))
    fixtures = man.get("fixtures", {})

    ok = fail = 0
    print("=" * 64)
    print(" 下载真实 GDTF 灯具文件")
    print("=" * 64)
    for key, entry in fixtures.items():
        if "gdtf" not in entry:      # USITT 规范符号，无需下载
            print(f"  [SKIP] {key:10s} USITT 规范符号")
            continue
        dest = cache_path(key, entry)
        try:
            status = download(entry["gdtf"], dest, a.force)
            if not valid(dest):
                raise RuntimeError("下载的文件不是有效 GDTF（缺 description.xml）")
            print(f"  [ OK ] {key:10s} {entry['name'][:40]:42s} {status}")
            ok += 1
        except Exception as e:
            print(f"  [FAIL] {key:10s} {e}")
            fail += 1

    print("-" * 64)
    print(f" 成功 {ok}，失败 {fail}")
    if fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
