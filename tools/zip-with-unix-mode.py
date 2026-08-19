#!/usr/bin/env python3
import os
import pathlib
import stat
import sys
import time
import zipfile

if len(sys.argv) != 3:
    raise SystemExit("usage: zip-with-unix-mode.py <source_dir> <zip_path>")

source = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
if not source.is_dir():
    raise SystemExit(f"source is not a directory: {source}")
out.parent.mkdir(parents=True, exist_ok=True)
if out.exists():
    out.unlink()

def validate_command_script(arcname, data):
    if data.startswith(b"\xef\xbb\xbf"):
        raise SystemExit(f"{arcname}: .command must be UTF-8 without BOM")
    if not data.startswith(b"#!"):
        first = data[:8].hex(" ")
        raise SystemExit(f"{arcname}: .command must start with shebang '#!' (first bytes: {first})")
    if b"\r" in data:
        raise SystemExit(f"{arcname}: .command must use LF line endings only; CR/CRLF found")

def validate_cmd_batch(arcname, data):
    # cmd + chcp 65001 + LF desyncs the byte reader on multibyte text and flash-exits.
    lf_only = 0
    for i, byte in enumerate(data):
        if byte == 10 and (i == 0 or data[i - 1] != 13):
            lf_only += 1
    if lf_only:
        raise SystemExit(
            f"{arcname}: .bat/.cmd must use CRLF; found {lf_only} LF-only newline(s)"
        )

files = sorted(p for p in source.rglob("*") if p.is_file())
with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
    for idx, path in enumerate(files, 1):
        rel = path.relative_to(source).as_posix()
        st = path.stat()
        info = zipfile.ZipInfo(rel, time.localtime(st.st_mtime)[:6])
        info.create_system = 3
        mode = 0o100755 if rel.endswith(".command") else 0o100644
        info.external_attr = (mode & 0xFFFF) << 16
        data = path.read_bytes()
        if rel.endswith(".command"):
            validate_command_script(rel, data)
        elif rel.lower().endswith((".bat", ".cmd")):
            validate_cmd_batch(rel, data)
        zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        if idx == 1 or idx == len(files) or idx % 100 == 0:
            print(f"  Processed {idx}/{len(files)} files")
print(f"zip complete: {out} ({len(files)} files)")
