#!/usr/bin/env python3
"""
自研铁威马 TOS tpk 打包器
================================
依据 TOS 社区公开验证的 tpk 二进制规范，独立实现三段式封装：
  Section 1: JSON 头，空格填充到 2048 字节
  Section 2: 本地化 .lang 文件，从 2048 起，\x00 填充到偏移 10240
  Section 3: XZ(LZMA2, CRC64) 压缩的 GNU TAR 归档（应用负载）

不依赖任何第三方打包工具成品；仅按公开格式规范自主实现。
"""
import argparse
import hashlib
import json
import lzma
import os
import tarfile
from io import BytesIO
from pathlib import Path

JSON_HEADER_SIZE = 2048
XZ_ARCHIVE_OFFSET = 10240
MTIME = 1734138336


def compress_xz(data: bytes, preset: int = 6) -> bytes:
    return lzma.compress(data, format=lzma.FORMAT_XZ, check=lzma.CHECK_CRC64, preset=preset)


def build_tar(src_root: Path, manifest: list) -> bytes:
    """按显式清单构建确定性 GNU TAR。
    manifest: list of (arcname, fs_relpath, type, mode, linktarget)
      type in f/d/l
    """
    buf = BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tar:
        for arcname, rel, typ, mode, link in manifest:
            ti = tarfile.TarInfo(name=arcname)
            ti.uid = 0; ti.gid = 0; ti.uname = "root"; ti.gname = "root"
            ti.mtime = MTIME; ti.mode = mode
            if typ == "d":
                ti.type = tarfile.DIRTYPE
                tar.addfile(ti)
            elif typ == "l":
                ti.type = tarfile.SYMTYPE
                ti.linkname = link or ""
                tar.addfile(ti)
            else:
                p = src_root / rel
                if not p.exists():
                    print(f"  WARN missing: {rel}")
                    continue
                ti.type = tarfile.REGTYPE
                ti.size = p.stat().st_size
                with open(p, "rb") as fh:
                    tar.addfile(ti, fh)
    return buf.getvalue()


def make_info(manifest: list, src_root: Path) -> bytes:
    """生成 INFO 文件：对每个文件写 md5，对每个目录写 folder 行（符号链接不写）。"""
    lines = []
    for arcname, rel, typ, mode, link in manifest:
        if typ == "f":
            p = src_root / rel
            if p.exists():
                h = hashlib.md5(p.read_bytes()).hexdigest()
                lines.append(f"1:file:{arcname}:{h}")
        elif typ == "d":
            lines.append(f"1:folder:{arcname}:")
    return ("\n".join(lines) + "\n").encode()


def build(args):
    src = Path(args.src).resolve()
    out = Path(args.out)
    app = args.app
    version = args.version
    port = args.port
    appid = args.id

    # ---- 生成 INFO（写入 src 临时文件，纳入归档） ----
    # 先构造基础 manifest（不含 INFO），生成 INFO 后追加
    base_manifest = []
    # 顶层配置文件
    for name in ["config.ini", f"{appid}.lang", "install", "version"]:
        rel = name
        if (src / rel).exists():
            base_manifest.append((name, rel, "f", 0o755 if name in ("install",) else 0o644, None))
    # 目录
    for d in ["bin/", "bin/program/", "images/", "images/icons/", "init.d/", "functions/", "sysroot/", "sysroot/usr/", "sysroot/usr/local/", "sysroot/usr/local/bin/", "sysroot/var/", "sysroot/var/lib/", "update/"]:
        base_manifest.append((d, d.rstrip('/'), "d", 0o755, None))
    # 应用负载：bin/program 下所有文件（递归）
    prog = src / "bin" / "program"
    for p in sorted(prog.rglob("*")):
        rel = str(p.relative_to(src))
        arc = str(p.relative_to(prog))
        arcname = f"bin/program/{arc}"
        if p.is_dir():
            base_manifest.append((arcname + "/", rel, "d", 0o755, None))
        elif p.is_symlink():
            base_manifest.append((arcname, rel, "l", 0o777, os.readlink(p)))
        else:
            mode = 0o755 if os.access(p, os.X_OK) else 0o644
            base_manifest.append((arcname, rel, "f", mode, None))
    # 关键单文件
    simple = {
        "init.d/service": ("init.d/service", 0o755),
        "functions/dependapps.sh": ("functions/dependapps.sh", 0o744),
        "images/icons/icon.png": ("images/icons/icon.png", 0o644),
    }
    for arc, (rel, mode) in simple.items():
        if (src / rel).exists():
            base_manifest.append((arc, rel, "f", mode, None))
    # sysroot 符号链接：把 bin/program 里的启动器链到 /usr/local/bin
    if (src / "bin/program/launcher").exists():
        base_manifest.append(("sysroot/usr/local/bin/launcher", "", "l", 0o777,
                              f"/usr/local/{appid}/bin/program/launcher"))

    info_bytes = make_info(base_manifest, src)
    (src / "INFO").write_bytes(info_bytes)
    manifest = [("INFO", "INFO", "f", 0o755, None)] + base_manifest

    # ---- Section 3: TAR + XZ ----
    tar_data = build_tar(src, manifest)
    xz_data = compress_xz(tar_data)
    md5 = hashlib.md5(xz_data).hexdigest()
    print(f"  TAR {len(tar_data):,} -> XZ {len(xz_data):,} bytes, md5={md5}")

    # ---- Section 1: JSON header ----
    header = {
        "id": appid,
        "md5": md5,
        "icon": f"/images/icons/icon.png",
        "path": f"/{appid}/",
        "name": "",
        "publisher": "nanxi9899",
        "exec": True,
        "open_path": False,
        "resize": True,
        "maxmin": True,
        "state": False,
        "type": "iframe",
        "help": f"https://github.com/nanxi9899/EF-media",
        "version": version,
        "recommend": False,
        "beta": args.beta,
        "category": "Multimedia",
        "depend": [],
        "relation": ["", ""],
        "platform": "x86_64",
        "low_version": "7.0",
        "reset": False,
        "official": f"/{appid}/",
    }
    js = json.dumps(header, separators=(",", ":")).encode("utf-8")
    assert len(js) <= JSON_HEADER_SIZE, "JSON header too large"

    # ---- Section 2: lang ----
    lang = (src / f"{appid}.lang").read_bytes()

    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "wb") as f:
        f.write(js)
        f.write(b" " * (JSON_HEADER_SIZE - len(js)))
        f.write(lang)
        f.write(b"\x00" * (XZ_ARCHIVE_OFFSET - JSON_HEADER_SIZE - len(lang)))
        f.write(xz_data)
    print(f"  WROTE {out} ({out.stat().st_size:,} bytes)")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--app", required=True, choices=["jellyfin", "emby"])
    ap.add_argument("--id", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--port", required=True)
    ap.add_argument("--beta", type=lambda x: x.lower() in ("true", "1", "yes"), default=False)
    build(ap.parse_args())
