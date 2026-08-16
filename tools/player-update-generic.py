#!/usr/bin/env python3
import argparse
import datetime as dt
import fnmatch
import hashlib
import http.client
import json
import os
import pathlib
import re
import shutil
import socket
import struct
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

# 家宽更新源是 DDNS 直连地址，绝不该走系统代理。macOS 上 urllib 会自动读取系统代理
# （如 Clash 的“设为系统代理”），而代理节点到不了 18088 端口就会对每个请求整齐回 503。
# 官方 CDN（cdn.modrinth.com）相反：国内直连经常能通但很慢，有系统代理就该走代理。
# 默认 opener 仍强制直连，避免清单/家宽误入代理；官方源单独选 opener。
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
urllib.request.install_opener(_DIRECT_OPENER)
_SYNC_UA = "portable-server-kit-sync/1.0"
_OFFICIAL_TIMEOUT_SEC = 8
# 官方源 8 秒内拿不到这么多字节，视为「能通但太慢」，立刻回落家宽。
# 纯空闲超时拦不住国内直连那种 10~30 KB/s 的细水长流。
_OFFICIAL_MIN_BYTES = 256 * 1024
_PROXY_URL = None
_PROXY_OPENER = None
_OFFICIAL_SKIP = False
_OFFICIAL_SKIP_NOTIFIED = False


def fetch_bytes(url: str, timeout: int = 20) -> bytes:
    """直连下载。优先 IPv4，避免 macOS 先卡在不通的 AAAA 上直到超时。"""
    req = urllib.request.Request(url, headers={"User-Agent": _SYNC_UA})
    parsed = urllib.parse.urlparse(url)
    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path += "?" + parsed.query
    last_err = None
    families = (socket.AF_INET, socket.AF_INET6)
    for family in families:
        try:
            infos = socket.getaddrinfo(host, port, family, socket.SOCK_STREAM)
        except Exception as exc:
            last_err = exc
            continue
        if not infos:
            continue
        ip = infos[0][4][0]
        try:
            if parsed.scheme == "https":
                conn = http.client.HTTPSConnection(ip, port, timeout=timeout)
            else:
                conn = http.client.HTTPConnection(ip, port, timeout=timeout)
            try:
                conn.request("GET", path, headers={"Host": host, "User-Agent": _SYNC_UA})
                resp = conn.getresponse()
                if resp.status != 200:
                    raise OSError(f"HTTP {resp.status} from {ip}")
                return resp.read()
            finally:
                conn.close()
        except Exception as exc:
            last_err = exc
    if last_err:
        raise last_err
    with _DIRECT_OPENER.open(req, timeout=timeout) as resp:
        return resp.read()


def sha1(path: pathlib.Path) -> str:
    if not path.is_file():
        return ""
    h = hashlib.sha1()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def safe_rel(rel: str) -> str:
    rel = str(rel).replace("\\", "/").strip().lstrip("/")
    if not rel or rel.startswith("/") or ":" in pathlib.PurePosixPath(rel).parts[0]:
        raise ValueError(f"unsafe manifest path: {rel}")
    parts = rel.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"unsafe manifest path: {rel}")
    return rel


def rel_key(rel: str) -> str:
    return safe_rel(rel).lower()


def join_safe(root: pathlib.Path, rel: str) -> pathlib.Path:
    return root.joinpath(*safe_rel(rel).split("/"))


def read_update_url(root: pathlib.Path, override: str) -> str:
    if override:
        return override.strip()
    for rel in ("UPDATE-URL.txt", "PORTABLE-UPDATE-URL.txt", "TFCR-update-url.txt", "_updater/UPDATE-URL.txt", "_updater/PORTABLE-UPDATE-URL.txt"):
        p = root.joinpath(*rel.split("/"))
        if p.is_file():
            value = p.read_text(encoding="utf-8-sig").strip()
            if value:
                return value
    raise SystemExit("找不到 UPDATE-URL.txt。请确认玩家包没有被拆散，或使用 --manifest-url 手动指定 server-manifest.json 地址。")


def url_for(base_url: str, rel: str) -> str:
    parts = [urllib.parse.quote(part) for part in safe_rel(rel).split("/")]
    return base_url + "/".join(parts)


def mask_url(url: str) -> str:
    # 更新地址首个路径段是访问 token，玩家截图求助时容易泄漏，打印前掩码。
    return re.sub(r"(?<=://)([^/]+/)[^/]+(?=/)", r"\1***", str(url), count=1)


def is_protected_rel(rel: str) -> bool:
    # 同步自身生成的备份/归档目录，任何清理规则都不得删除。
    rel = str(rel).replace("\\", "/").lstrip("/")
    first = rel.split("/", 1)[0]
    return "/" in rel and (first == ".portable-sync-backups" or first.startswith("_disabled_"))


def glob_match(rel: str, globs) -> bool:
    rel = safe_rel(rel)
    return any(fnmatch.fnmatchcase(rel, str(g).replace("\\", "/").lstrip("/")) for g in globs or [])


def file_map(files) -> dict:
    out = {}
    for item in files or []:
        path = item.get("path")
        digest = item.get("sha1")
        if path and digest:
            out[rel_key(str(path))] = str(digest).lower()
    return out


def is_optional_helper(rel: str) -> bool:
    rel = safe_rel(rel)
    return rel in {
        "_updater/Windows-sync.bat", "更新mod-Windows端.bat", "更新mod-Mac端.command", "更新mod.bat", "启动游戏-Windows端.bat", "Windows-sync.bat",
        "_updater/macOS-sync.command", "启动游戏-Mac端.command", "macOS-sync.command",
        "_updater/portable-stage-daemon.ps1", "_updater/portable-stage-daemon.py",
    }

def ensure_executable_if_needed(path: pathlib.Path, rel: str):
    if safe_rel(rel).endswith(".command") and path.is_file():
        path.chmod(path.stat().st_mode | 0o755)

def backup_file(path: pathlib.Path, root: pathlib.Path, rel: str, backup_root: pathlib.Path):
    if not path.is_file():
        return
    dest = join_safe(backup_root, rel)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)


def is_official_https_url(url: str) -> bool:
    try:
        parsed = urllib.parse.urlparse(str(url).strip())
    except Exception:
        return False
    if parsed.scheme != "https" or not parsed.netloc:
        return False
    host = (parsed.hostname or "").lower()
    return host not in ("", "localhost", "127.0.0.1", "::1")


def reset_download_policy():
    """测试和每次 main() 开头清空缓存，避免上次运行的跳过/代理结果串台。"""
    global _PROXY_URL, _PROXY_OPENER, _OFFICIAL_SKIP, _OFFICIAL_SKIP_NOTIFIED
    _PROXY_URL = None
    _PROXY_OPENER = None
    _OFFICIAL_SKIP = False
    _OFFICIAL_SKIP_NOTIFIED = False


def normalize_proxy_url(raw: str) -> str:
    raw = str(raw or "").strip()
    if not raw:
        return ""
    lower = raw.lower()
    if lower.startswith("socks"):
        return ""
    if "://" not in raw:
        raw = "http://" + raw
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return ""
    return raw


def parse_win_proxy_server(server: str) -> str:
    server = str(server or "").strip()
    if not server:
        return ""
    if "=" in server:
        parts = {}
        for item in server.split(";"):
            if "=" not in item:
                continue
            key, value = item.split("=", 1)
            parts[key.strip().lower()] = value.strip()
        for key in ("https", "http"):
            if parts.get(key):
                return normalize_proxy_url(parts[key])
        return ""
    return normalize_proxy_url(server)


def detect_system_proxy() -> str:
    flag = str(os.environ.get("PORTABLE_SYNC_NOPROXY") or "").strip().lower()
    if flag in ("1", "true", "yes", "on"):
        return ""
    override = normalize_proxy_url(os.environ.get("PORTABLE_SYNC_PROXY") or "")
    if override:
        return override
    for key in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"):
        value = normalize_proxy_url(os.environ.get(key) or "")
        if value:
            return value
    if sys.platform.startswith("win"):
        try:
            import winreg
            with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Internet Settings",
            ) as key:
                enable, _ = winreg.QueryValueEx(key, "ProxyEnable")
                if int(enable) == 1:
                    server, _ = winreg.QueryValueEx(key, "ProxyServer")
                    parsed = parse_win_proxy_server(str(server or ""))
                    if parsed:
                        return parsed
        except Exception:
            pass
    return ""


def get_proxy_url() -> str:
    global _PROXY_URL
    if _PROXY_URL is None:
        _PROXY_URL = detect_system_proxy()
    return _PROXY_URL


def describe_proxy(url: str = "") -> str:
    parsed = urllib.parse.urlparse(url or get_proxy_url())
    host = parsed.hostname or ""
    if not host:
        return ""
    return f"{host}:{parsed.port}" if parsed.port else host


def is_local_or_private_host(host: str) -> bool:
    host = (host or "").lower().strip("[]")
    if host in ("", "localhost", "127.0.0.1", "::1"):
        return True
    parts = host.split(".")
    if len(parts) == 4 and all(part.isdigit() for part in parts):
        a, b = int(parts[0]), int(parts[1])
        if a == 127 or a == 10 or (a == 192 and b == 168) or (a == 172 and 16 <= b <= 31):
            return True
    return False


def proxy_bypass_hosts() -> list:
    raw = os.environ.get("NO_PROXY") or os.environ.get("no_proxy") or ""
    return [item.strip().lower() for item in raw.split(",") if item.strip()]


def url_bypasses_proxy(url: str) -> bool:
    host = (urllib.parse.urlparse(str(url)).hostname or "").lower()
    if is_local_or_private_host(host):
        return True
    for item in proxy_bypass_hosts():
        if item == "*":
            return True
        if item.startswith("."):
            if host.endswith(item) or host == item[1:]:
                return True
        elif host == item or host.endswith("." + item):
            return True
    return False


def official_opener():
    proxy = get_proxy_url()
    if not proxy:
        return _DIRECT_OPENER
    global _PROXY_OPENER
    if _PROXY_OPENER is None:
        _PROXY_OPENER = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return _PROXY_OPENER


def opener_for_official_url(url: str):
    if get_proxy_url() and not url_bypasses_proxy(url):
        return official_opener()
    return _DIRECT_OPENER


def official_urls(item) -> list:
    raw = []
    if isinstance(item, dict):
        url = item.get("url")
        if url:
            raw.append(str(url).strip())
        for extra in item.get("downloads") or []:
            if extra:
                raw.append(str(extra).strip())
    seen = set()
    out = []
    for url in raw:
        key = url.lower()
        if key in seen or not is_official_https_url(url):
            continue
        seen.add(key)
        out.append(url)
    return out


def download_fail_reason(exc: BaseException) -> str:
    msg = str(exc)
    if "SHA1" in msg:
        return "哈希不符"
    if "too slow" in msg.lower() or "太慢" in msg:
        return "太慢"
    if "timed out" in msg.lower() or "timeout" in msg.lower() or "超时" in msg:
        return "超时"
    if "404" in msg:
        return "404"
    if "403" in msg:
        return "403"
    if "name or service" in msg.lower() or "nodename" in msg.lower() or "getaddrinfo" in msg.lower():
        return "DNS"
    return "连接失败"


def copy_response(resp, out, timeout: int, min_bytes_after_timeout: int = 0):
    started = time.time()
    got = 0
    checked_slow = False
    while True:
        chunk = resp.read(64 * 1024)
        if not chunk:
            break
        out.write(chunk)
        got += len(chunk)
        if min_bytes_after_timeout and not checked_slow and (time.time() - started) >= timeout:
            if got < min_bytes_after_timeout:
                raise TimeoutError("official source too slow")
            checked_slow = True


def download_file(url: str, dest: pathlib.Path, expected_sha1: str, opener=None, timeout=60, retries=1, min_bytes_after_timeout=0):
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="portable-sync-", suffix=".tmp")
    os.close(fd)
    tmp = pathlib.Path(tmp_name)
    opener = opener or _DIRECT_OPENER
    req = urllib.request.Request(url, headers={"User-Agent": _SYNC_UA})
    try:
        last_exc = None
        for attempt in range(retries + 1):
            try:
                with opener.open(req, timeout=timeout) as resp, tmp.open("wb") as out:
                    copy_response(resp, out, timeout, min_bytes_after_timeout)
                last_exc = None
                break
            except Exception as exc:
                last_exc = exc
                if attempt < retries:
                    time.sleep(2)
                    continue
                raise
        if last_exc is not None:
            raise last_exc
        actual = sha1(tmp)
        if actual != expected_sha1.lower():
            raise RuntimeError(f"SHA1 mismatch for {mask_url(url)}. expected={expected_sha1} actual={actual}")
        shutil.move(str(tmp), dest)
    finally:
        if tmp.exists():
            tmp.unlink()


def mark_official_skip():
    global _OFFICIAL_SKIP, _OFFICIAL_SKIP_NOTIFIED
    _OFFICIAL_SKIP = True
    if not _OFFICIAL_SKIP_NOTIFIED:
        _OFFICIAL_SKIP_NOTIFIED = True
        print("[同步] 官方源本轮不再尝试，其余文件直接走更新服务。")


def download_manifest_entry(item, base_url: str, dest: pathlib.Path, expected_sha1: str, rel: str) -> str:
    # 官方源：有系统代理就走代理（国内直连 Modrinth 经常能通但很慢）。
    # 8 秒内字节太少或失败，立刻回落家宽；本轮后面的文件不再试官方，避免 90 次白等。
    # 家宽始终直连，绝不进 Clash。
    urls = [] if _OFFICIAL_SKIP else official_urls(item if isinstance(item, dict) else {})
    for url in urls:
        started = time.time()
        try:
            download_file(
                url, dest, expected_sha1,
                opener=opener_for_official_url(url),
                timeout=_OFFICIAL_TIMEOUT_SEC,
                retries=0,
                min_bytes_after_timeout=_OFFICIAL_MIN_BYTES,
            )
            return "official"
        except Exception as exc:
            print(
                f"[同步] 官方源不可用（{time.time() - started:.1f}s，{download_fail_reason(exc)}），改走更新服务：{rel}"
            )
            mark_official_skip()
            break
    download_file(url_for(base_url, rel), dest, expected_sha1, opener=_DIRECT_OPENER)
    return "home"


def existing_hash_index(root: pathlib.Path) -> dict:
    # One SHA1 can map to several local files (TACZ gun-pack sounds are duplicated
    # across assets/ccrp and assets/classicr), so keep a list per hash instead of
    # only the first. Keeping only one made later entries with the same hash point
    # at a path an earlier adopt had already moved away -> "does not exist" crash
    # (2026-07-08 player-reported).
    out = {}
    for dirname in ("mods", "config", "defaultconfigs", "kubejs", "scripts", "resourcepacks", "shaderpacks", "data"):
        base = root / dirname
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            if rel.startswith("mods/.connector/") or "/.connector/" in rel:
                continue
            digest = sha1(path)
            if not digest:
                continue
            out.setdefault(digest, []).append(path)
    return out


def adopt_source(index: dict, expected: str, target: pathlib.Path, manifest_targets: set):
    """Pick a local file with matching sha1 to satisfy `target` without re-downloading.
    Returns (path, mode): 'move' for a spare copy safe to consume, or 'copy' when the
    only matches are themselves files the manifest needs (duplicate instead of stealing).
    Prunes stale entries so a hash shared by many identical files can't point at a path
    an earlier adopt already moved away."""
    paths = index.get(expected)
    if not paths:
        return None
    alive = [p for p in paths if p.is_file()]
    index[expected] = alive
    target_res = str(target.resolve()).lower()
    spare = None
    twin = None
    for p in alive:
        pr = str(p.resolve()).lower()
        if pr == target_res:
            continue
        if pr in manifest_targets:
            if twin is None:
                twin = p
        elif spare is None:
            spare = p
    if spare is not None:
        index[expected] = [p for p in alive if p is not spare]
        return spare, "move"
    if twin is not None:
        return twin, "copy"
    return None


def set_option_line(path: pathlib.Path, key: str, value: str):
    lines = []
    found = False
    if path.is_file():
        lines = path.read_text(encoding="utf-8-sig", errors="ignore").splitlines()
    out = []
    for line in lines:
        if ":" in line and line.split(":", 1)[0] == key:
            out.append(f"{key}:{value}")
            found = True
        else:
            out.append(line)
    if not found:
        out.append(f"{key}:{value}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(out) + "\n", encoding="utf-8")


def apply_option_defaults(root: pathlib.Path, manifest: dict, backup_root: pathlib.Path, preserved_deletions=None, initial_sync=False) -> int:
    preserved_deletions = preserved_deletions or set()
    config = manifest.get("playerOptions") or {}
    defaults = config.get("defaults") or {}
    if not defaults:
        return 0
    mode = str(config.get("apply") or "missing")
    targets = config.get("targets") or ["options.txt"]
    changed = 0
    for rel in targets:
        rel = safe_rel(rel)
        if rel.lower() in preserved_deletions:
            continue
        path = join_safe(root, rel)
        exists = path.is_file()
        if mode == "missing" and (exists or not initial_sync):
            continue
        if exists:
            backup_file(path, root, rel, backup_root)
        for key, value in defaults.items():
            set_option_line(path, str(key), str(value))
            changed += 1
    if changed:
        print(f"[修复] 已写入安全默认选项：{changed} 项")
    return changed


def nbt_string(value: str) -> bytes:
    raw = value.encode("utf-8")
    return struct.pack(">H", len(raw)) + raw


def named_tag(tag_type: int, name: str) -> bytes:
    return bytes([tag_type]) + nbt_string(name)


def write_servers_dat(path: pathlib.Path, name: str, ip: str):
    data = bytearray()
    data += named_tag(10, "")
    data += named_tag(9, "servers")
    data += bytes([10])
    data += struct.pack(">i", 1)
    data += named_tag(8, "name") + nbt_string(name)
    data += named_tag(8, "ip") + nbt_string(ip)
    data += named_tag(1, "acceptTextures") + bytes([1])
    data += bytes([0])
    data += bytes([0])
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(bytes(data))


def show_launcher_hints(root: pathlib.Path):
    launcher_root = root / "_launchers"
    if not launcher_root.is_dir():
        return
    items = [
        ("PCL", launcher_root / "PCL.exe"),
        ("PCL 最近启动脚本", launcher_root / "PCL" / "LatestLaunch.bat"),
        ("HMCL", launcher_root / "HMCL.jar"),
    ]
    found = [(name, path) for name, path in items if path.is_file()]
    if not found:
        return
    print("[启动器] 已同步启动器文件：")
    for name, path in found:
        print(f"[启动器] {name}: {path}")


def launcher_instance_name(root: pathlib.Path, manifest: dict) -> str:
    launcher = manifest.get("launcher") or {}
    pcl = manifest.get("pcl") or {}
    name = str(launcher.get("instanceName") or "").strip()
    if not name:
        name = str(pcl.get("instanceName") or "").strip()
    if name:
        return name
    candidates = [p for p in root.glob("*.json") if p.name not in {"launcher_profiles.json", ".portable-sync-state.json"}]
    if candidates:
        return max(candidates, key=lambda p: p.stat().st_size).stem
    return root.name


def minecraft_home_for_instance(root: pathlib.Path):
    parent = root.parent
    grandparent = parent.parent if parent else None
    if grandparent and parent.name.lower() == "versions" and grandparent.name.lower() == ".minecraft":
        return grandparent.parent
    return None


def stable_path_cache(path: pathlib.Path) -> int:
    # Python 内建 hash() 受哈希随机化影响，每次运行都变；用 SHA1 保证跨运行稳定。
    digest = hashlib.sha1(str(path).encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % 2147483647


def write_pcl_global_config(home: pathlib.Path, mc_dir_value: str, instance_name: str, backup_root: pathlib.Path, backup_prefix: str = ""):
    # 温和写入：PCL.ini 缺失才创建；Setup.ini 只维护 LaunchFolderSelect 一行，
    # 保留玩家自己的其他 PCL 设置，避免每次同步重置启动器个人配置。
    pcl_ini = home / "PCL.ini"
    if not pcl_ini.is_file():
        cache = stable_path_cache(home)
        pcl_ini.write_text(
            f"InstanceCache:{cache}\nVersion:{instance_name}\nCardKey1:2\nCardValue1:2:{instance_name}:1:\nCardCount:1\n",
            encoding="utf-8",
        )

    pcl_dir = home / "PCL"
    pcl_dir.mkdir(parents=True, exist_ok=True)
    setup = pcl_dir / "Setup.ini"
    desired = f"LaunchFolderSelect:{mc_dir_value}"
    if setup.is_file():
        lines = setup.read_text(encoding="utf-8-sig", errors="ignore").splitlines()
        if desired in lines:
            return
        backup_file(setup, home, backup_prefix + "PCL/Setup.ini", backup_root)
        kept = [ln for ln in lines if not ln.startswith("LaunchFolderSelect:")]
        setup.write_text("\n".join([desired] + kept) + "\n", encoding="utf-8")
    else:
        setup.write_text(desired + "\n", encoding="utf-8")


def copy_launcher_to_root(root: pathlib.Path, rel: str, backup_root: pathlib.Path):
    source = join_safe(root / "_launchers", rel)
    if not source.is_file():
        return None
    dest = join_safe(root, rel)
    # 启动器（HMCL / PCL 等）会自我升级：玩家在启动器里点了“升级”后，本地 jar/exe 比包内
    # 自带的更新。这里只做「首次落位」——缺失才复制，已存在就保留玩家自己的版本，绝不用包内
    # 旧版覆盖回去，否则每次同步都把玩家升级好的 HMCL 打回原形（2026-07-11 实锤）。
    if dest.is_file():
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)
    if dest.suffix == ".command":
        dest.chmod(dest.stat().st_mode | 0o755)
    return dest


def apply_launcher_profile(root: pathlib.Path, manifest: dict, backup_root: pathlib.Path):
    if not (root / "_launchers").is_dir():
        return
    instance_name = launcher_instance_name(root, manifest)
    pack_name = str(manifest.get("packName") or instance_name).strip() or instance_name
    mc_version = str(manifest.get("minecraftVersion") or "").strip()
    loader = manifest.get("loader") or {}
    loader_type = str(loader.get("type") or "").strip()
    loader_version = str(loader.get("version") or "").strip()

    for rel in ("PCL.exe", "Plain Craft Launcher.exe", "SakuraLauncher.exe", "HMCL.jar"):
        copy_launcher_to_root(root, rel, backup_root)

    mc_home = minecraft_home_for_instance(root)
    if mc_home:
        for rel in ("PCL.exe", "Plain Craft Launcher.exe", "SakuraLauncher.exe", "HMCL.jar"):
            source = join_safe(root / "_launchers", rel)
            if source.is_file():
                dest = mc_home / rel
                # 同 copy_launcher_to_root：启动器自升级后不回退，缺失才落位。
                if dest.is_file():
                    continue
                shutil.copy2(source, dest)

    profile_path = root / "launcher_profiles.json"
    backup_file(profile_path, root, "launcher_profiles.json", backup_root)
    profile = {
        "profiles": {
            "Portable": {
                "icon": "Furnace",
                "name": pack_name,
                "lastVersionId": instance_name,
                "type": "custom",
                "lastUsed": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.0000Z"),
            }
        },
        "selectedProfile": "Portable",
        "clientToken": "23323323323323323323323323323333",
    }
    profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    pcl_ini = root / "PCL.ini"
    backup_file(pcl_ini, root, "PCL.ini", backup_root)
    cache = stable_path_cache(root)
    pcl_ini.write_text(
        f"InstanceCache:{cache}\nVersion:{instance_name}\nCardKey1:2\nCardValue1:2:{instance_name}:1:\nCardCount:1\n",
        encoding="utf-8",
    )

    pcl_dir = root / "PCL"
    pcl_dir.mkdir(parents=True, exist_ok=True)
    setup = pcl_dir / "Setup.ini"
    backup_file(setup, root, "PCL/Setup.ini", backup_root)
    loader_label = loader_type[:1].upper() + loader_type[1:] if loader_type else ""
    info = f"正式版 {mc_version}, {loader_label} {loader_version}".strip().rstrip(",") if mc_version else pack_name
    lines = [
        "State:9",
        f"VersionVanillaName:{mc_version}" if mc_version else "",
        "VersionArgumentIndieV2:True",
        f"Info:{info}",
        "VersionLiteLoader:False",
    ]
    if loader_type.lower() == "forge" and loader_version:
        lines.append(f"VersionForge:{loader_version}")
    if loader_type.lower() == "fabric" and loader_version:
        lines.append(f"VersionFabric:{loader_version}")
    lines.extend([
        "Logo:pack://application:,,,/Plain Craft Launcher 2;component/Images/Blocks/Anvil.png",
        f"LaunchFolderSelect:{root}",
    ])
    setup.write_text("\n".join(line for line in lines if line) + "\n", encoding="utf-8")

    if mc_home:
        profile_home = mc_home / ".minecraft" / "launcher_profiles.json"
        backup_file(profile_home, mc_home, ".minecraft/launcher_profiles.json", backup_root)
        profile_home.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        write_pcl_global_config(mc_home, "$.minecraft\\", instance_name, backup_root)

    # Mirror launcher config for older wrappers that still start from _launchers.
    for rel in ("launcher_profiles.json", "PCL.ini", "PCL/Setup.ini"):
        src = join_safe(root, rel)
        dst = join_safe(root / "_launchers", rel)
        if src.is_file():
            backup_file(dst, root, "_launchers/" + rel, backup_root)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
    print(f"[启动器] 已写入本地实例配置：{instance_name}")

def apply_server_list(root: pathlib.Path, manifest: dict, backup_root: pathlib.Path, preserved_deletions=None, initial_sync=False):
    preserved_deletions = preserved_deletions or set()
    config = manifest.get("serverList") or {}
    if not config.get("enabled", False):
        return
    target = safe_rel(config.get("target") or "servers.dat")
    name = str(config.get("name") or manifest.get("serverName") or "Minecraft Server")
    address = str(config.get("address") or manifest.get("serverAddress") or "")
    if not address:
        return
    if target.lower() in preserved_deletions:
        return
    path = join_safe(root, target)
    if bool(config.get("writeIfMissingOnly", True)):
        if path.is_file():
            return
        if not initial_sync:
            return
    backup_file(path, root, target, backup_root)
    write_servers_dat(path, name, address)
    print(f"[修复] 已写入服务器列表：{name} / {address}")


def move_to_disabled(path: pathlib.Path, disabled: pathlib.Path) -> pathlib.Path:
    disabled.mkdir(parents=True, exist_ok=True)
    dest = disabled / path.name
    if dest.exists():
        dest = disabled / f"{path.stem}.{dt.datetime.now().strftime('%Y%m%d%H%M%S')}{path.suffix}"
    shutil.move(str(path), dest)
    return dest


def remove_connector_cache(root: pathlib.Path):
    cache = root / "mods" / ".connector"
    if cache.is_dir():
        shutil.rmtree(cache, ignore_errors=True)
        print("[修复] 已清理 Connector 运行缓存：mods/.connector")


def disable_launcher_repair_index(*roots: pathlib.Path):
    for root in roots:
        index = root / "modrinth.index.json"
        if index.is_file():
            dest = move_to_disabled(index, root / "_disabled_launcher_repair")
            print(f"[修复] 已禁用启动器修包索引：{dest}")


def jar_mod_id(path: pathlib.Path):
    try:
        with zipfile.ZipFile(path) as zf:
            for name in ("fabric.mod.json", "quilt.mod.json"):
                try:
                    data = json.loads(zf.read(name).decode("utf-8-sig"))
                    if data.get("id"):
                        return str(data["id"]).lower()
                    if isinstance(data.get("quilt_loader"), dict) and data["quilt_loader"].get("id"):
                        return str(data["quilt_loader"]["id"]).lower()
                except KeyError:
                    pass
            for name in ("META-INF/mods.toml", "META-INF/neoforge.mods.toml"):
                try:
                    text = zf.read(name).decode("utf-8", "ignore")
                except KeyError:
                    continue
                for line in text.splitlines():
                    line = line.strip()
                    if line.startswith("modId") and "=" in line:
                        return line.split("=", 1)[1].strip().strip('"\'').lower()
            try:
                info = json.loads(zf.read("mcmod.info").decode("utf-8-sig"))
                if isinstance(info, list) and info and info[0].get("modid"):
                    return str(info[0]["modid"]).lower()
            except Exception:
                pass
    except Exception:
        return None
    return None


def disable_duplicate_mods(root: pathlib.Path, manifest: dict):
    mods = root / "mods"
    if not mods.is_dir():
        return
    managed_paths = set()
    managed_sha1 = {}
    for item in manifest.get("files") or []:
        rel = safe_rel(item.get("path", ""))
        if fnmatch.fnmatchcase(rel, "mods/*.jar"):
            managed_paths.add(rel.lower())
            managed_sha1[str(item.get("sha1", "")).lower()] = rel
    disabled = root / "_disabled_mod_duplicates"
    moved = 0
    for jar in sorted(mods.glob("*.jar")):
        rel = jar.relative_to(root).as_posix()
        digest = sha1(jar)
        if digest in managed_sha1 and rel.lower() not in managed_paths:
            dest = move_to_disabled(jar, disabled)
            moved += 1
            print(f"[修复] 已按 SHA1 归档旧重复 mod：{rel} -> {dest.name}")
    groups = {}
    for jar in sorted(mods.glob("*.jar")):
        mod_id = jar_mod_id(jar)
        if mod_id:
            groups.setdefault(mod_id, []).append(jar)
    for mod_id, jars in groups.items():
        if len(jars) <= 1:
            continue
        keep = sorted(jars, key=lambda p: ((p.relative_to(root).as_posix().lower() in managed_paths), p.stat().st_mtime), reverse=True)[0]
        for jar in jars:
            if jar == keep:
                continue
            dest = move_to_disabled(jar, disabled)
            moved += 1
            print(f"[修复] 已归档重复 modId={mod_id}；保留 {keep.name}，移动 {jar.name}")
    if moved:
        print(f"[修复] 重复 mod 清理完成，移动 {moved} 个")


def main() -> int:
    parser = argparse.ArgumentParser(description="Portable Minecraft player updater")
    parser.add_argument("--instance-dir", default=".")
    parser.add_argument("--manifest-url", default="")
    args = parser.parse_args()

    root = pathlib.Path(args.instance_dir).resolve()
    root.mkdir(parents=True, exist_ok=True)
    reset_download_policy()
    manifest_url = read_update_url(root, args.manifest_url)
    print(f"[同步] 清单：{mask_url(manifest_url)}")
    proxy = get_proxy_url()
    if proxy:
        print(f"[同步] 已检测到系统代理 {describe_proxy(proxy)}，官方源走代理；家宽更新服务始终直连。")
    else:
        print("[同步] 未检测到系统代理，官方源直连（国内较慢会在 8 秒内回落更新服务）。")
    # 更新源重启/隧道瞬断会短暂 503，重试几次；最终失败给干净提示而不是吓人的 traceback。
    manifest = None
    last_exc = None
    for attempt in range(3):
        try:
            raw = fetch_bytes(manifest_url, timeout=12)
            manifest = json.loads(raw.decode("utf-8-sig"))
            break
        except Exception as exc:
            last_exc = exc
            if attempt < 2:
                print(f"[同步] 清单获取失败（第 {attempt + 1} 次）：{exc}；3 秒后重试...")
                time.sleep(3)
    if manifest is None:
        raise SystemExit(
            f"[同步] 清单获取失败：{last_exc}。"
            "若你和服务器在同一局域网，路由器回环（访问自家公网 IP）常常会超时，可把 UPDATE-URL 临时改成服机局域网地址后再试；"
            "若在外网，请管理员确认路由器已把 TCP 18088 转到服机，并等 DDNS 生效后再试。"
        )
    files = manifest.get("files") or []
    if not files:
        raise SystemExit("清单没有 files 文件列表。")
    base_url = manifest_url.rsplit("/", 1)[0] + "/"
    state_path = root / ".portable-sync-state.json"
    state = {}
    if state_path.is_file():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8-sig"))
        except Exception:
            state = {}
    initial_sync = not bool(state)
    previous = file_map(state.get("files"))
    # key 是小写化的，删除旧文件时要还原状态文件里的原始大小写（大小写敏感卷才找得到文件）。
    previous_rel = {}
    for item in state.get("files") or []:
        p = item.get("path")
        if p and item.get("sha1"):
            try:
                previous_rel[rel_key(str(p))] = safe_rel(str(p))
            except ValueError:
                continue
    new = file_map(files)
    preserve_changes = manifest.get("preserveLocalChangeGlobs") or []
    preserve_deletions = manifest.get("preserveLocalDeletionGlobs") or []
    force_delete_globs = manifest.get("forceDeleteGlobs") or []
    # 强制同步：匹配的文件无视保留规则、一律以服务端为准（覆盖前照常备份）。
    # 服务端确需推送玩家常改的配置时，临时把路径加进 forceSyncGlobs 发布一版即可。
    force_sync_globs = manifest.get("forceSyncGlobs") or []
    # 按操作系统跳过的文件（如 YSM 不支持 macOS）：本平台不下载，本地已有则备份后移除。
    plat = "mac" if sys.platform == "darwin" else ("windows" if sys.platform.startswith("win") else "linux")
    platform_excludes = (manifest.get("platformExcludeGlobs") or {}).get(plat) or []
    additive_dirs = manifest.get("additiveDirs") or ["shaderpacks", "resourcepacks", "schematics", "saves", "screenshots"]
    cleanup = manifest.get("cleanup") or {}
    preserve_player = bool(manifest.get("preservePlayerCustomizations", True))
    adopt_existing = bool(manifest.get("adoptExistingFiles", True))
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_root = root / ".portable-sync-backups" / stamp

    if cleanup.get("removeConnectorCache", True):
        remove_connector_cache(root)
    if cleanup.get("disableLauncherRepairIndex", True):
        disable_launcher_repair_index(pathlib.Path.cwd(), root)

    # 接管索引惰性构建：日常同步通常没有缺失文件，这时不必对 mods/config/resourcepacks 等
    # 目录做全量 SHA1 扫描（大包一次要几十秒）。只在真的遇到缺失文件需要接管时才建一次。
    existing = None

    def adopt_index():
        nonlocal existing
        if existing is None:
            print("[同步] 有文件缺失，正在建立本地文件哈希索引（仅本次需要）...")
            existing = existing_hash_index(root)
        return existing
    # All manifest target paths: lets adopt tell a spare copy (movable) from a twin
    # the manifest still needs elsewhere (copy instead of steal).
    manifest_targets = set()
    for item in files:
        try:
            manifest_targets.add(str(join_safe(root, str(item["path"])).resolve()).lower())
        except (ValueError, KeyError):
            continue
    downloaded = adopted = skipped = preserved = removed = 0
    preserved_deletions = set()
    # 保留了玩家修改、但服务端同一文件本次其实也有更新的清单：结尾集中提醒一次。
    preserved_conflicts = []
    for item in files:
        rel = safe_rel(str(item["path"]))
        key = rel.lower()
        expected = str(item["sha1"]).lower()
        target = join_safe(root, rel)
        exists = target.is_file()
        if platform_excludes and glob_match(rel, platform_excludes):
            # 本平台不适用（如 macOS 不支持 YSM）：不下载。本地残留由下方扫描统一清除。
            continue
        current = sha1(target) if exists else ""
        if exists and current == expected:
            ensure_executable_if_needed(target, rel)
            skipped += 1
            continue
        had_previous = key in previous
        previous_hash = previous.get(key, "")
        force_sync = glob_match(rel, force_sync_globs)
        if not exists and had_previous and preserve_player and not force_sync and glob_match(rel, preserve_deletions):
            print(f"[保留玩家删除] {rel}")
            preserved_deletions.add(key)
            preserved += 1
            continue
        if exists and preserve_player and not force_sync and glob_match(rel, preserve_changes):
            # 三方对比：current==previous_hash 说明玩家没改过，照常走下面的更新；
            # 改过（或没有基线）就保留。若服务端同一文件本次也变了，记下来结尾集中提醒。
            if not previous_hash or current != previous_hash:
                if had_previous and expected != previous_hash:
                    preserved_conflicts.append(rel)
                print(f"[保留玩家修改] {rel}")
                preserved += 1
                continue
        if not exists and adopt_existing:
            picked = adopt_source(adopt_index(), expected, target, manifest_targets)
            if picked is not None:
                src, mode = picked
                target.parent.mkdir(parents=True, exist_ok=True)
                if mode == "move":
                    shutil.move(str(src), target)
                else:
                    shutil.copy2(str(src), target)
                if sha1(target) == expected:
                    ensure_executable_if_needed(target, rel)
                    print(f"[接管本地文件] {rel}")
                    adopted += 1
                    continue
                # adopted content didn't verify (rare); fall through to a normal download
        if exists:
            backup_file(target, root, rel, backup_root)
        try:
            source = download_manifest_entry(item, base_url, target, expected, rel)
            ensure_executable_if_needed(target, rel)
            print(f"[官方源] {rel}" if source == "official" else f"[更新] {rel}")
            downloaded += 1
        except Exception as exc:
            if is_optional_helper(rel):
                print(f"[警告] 辅助脚本未更新：{rel}；{exc}")
                preserved += 1
                continue
            raise

    for old_key, old_hash in previous.items():
        if old_key in new:
            continue
        old_rel = previous_rel.get(old_key, old_key)
        try:
            target = join_safe(root, old_rel)
        except ValueError:
            continue
        if not target.is_file():
            continue
        # tacz 等大件：清单撤下也不删。mods/** 虽也在删除保留里，
        # 但官方换版本时未改过的旧 jar 仍要清掉，避免双模组。
        keep_by_glob = preserve_player and glob_match(old_rel, preserve_deletions)
        is_pack_mod = old_rel.replace("\\", "/").lower().startswith("mods/")
        if keep_by_glob and not is_pack_mod:
            print(f"[保留本地额外文件] {old_rel}")
            preserved += 1
            continue
        if sha1(target) != old_hash:
            print(f"[保留本地额外文件] {old_rel}")
            preserved += 1
            continue
        backup_file(target, root, old_rel, backup_root)
        target.unlink()
        print(f"[删除旧文件] {old_rel}")
        removed += 1

    # 每个 pattern 现场枚举，避免用过期快照对已删文件二次 unlink；
    # 并跳过同步自身的备份/归档目录。
    for pattern in force_delete_globs:
        pattern = str(pattern).replace("\\", "/").lstrip("/")
        safe_rel(pattern.replace("*", "x").replace("?", "x"))
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            if is_protected_rel(rel):
                continue
            if fnmatch.fnmatchcase(rel, pattern):
                backup_file(path, root, rel, backup_root)
                path.unlink()
                print(f"[强制删除] {rel}")
                removed += 1

    # 本平台排除项：清除本地任何匹配文件（含清单外的孤儿，如 macOS 上 YSM 残留的 builtin 模型）。
    if platform_excludes:
        for path in sorted(root.rglob("*")):
            if not path.is_file():
                continue
            rel = path.relative_to(root).as_posix()
            if is_protected_rel(rel):
                continue
            if glob_match(rel, platform_excludes):
                backup_file(path, root, rel, backup_root)
                path.unlink()
                print(f"[跳过本平台并清除] {rel}")
                removed += 1

    for dirname in additive_dirs:
        try:
            join_safe(root, dirname).mkdir(parents=True, exist_ok=True)
        except ValueError:
            pass

    apply_option_defaults(root, manifest, backup_root, preserved_deletions, initial_sync)
    apply_server_list(root, manifest, backup_root, preserved_deletions, initial_sync)
    apply_launcher_profile(root, manifest, backup_root)
    show_launcher_hints(root)
    if cleanup.get("removeConnectorCache", True):
        remove_connector_cache(root)
    if cleanup.get("disableDuplicateMods", True):
        disable_duplicate_mods(root, manifest)
    if cleanup.get("disableLauncherRepairIndex", True):
        disable_launcher_repair_index(pathlib.Path.cwd(), root)

    state_out = {
        "format": 2,
        "packId": manifest.get("packId") or manifest.get("pack") or "",
        "packName": manifest.get("packName") or manifest.get("name") or "",
        "version": manifest.get("version") or "",
        "manifestUrl": manifest_url,
        "syncedAt": dt.datetime.now().isoformat(timespec="seconds"),
        "files": files,
    }
    state_path.write_text(json.dumps(state_out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"[同步] 完成。更新={downloaded} 接管={adopted} 跳过={skipped} 保留={preserved} 删除={removed} 备份={backup_root}")
    if preserved_conflicts:
        print(f"[提示] 以下 {len(preserved_conflicts)} 个文件保留了你的本地修改，但服务端本次也更新了它们（未应用服务端版）：")
        for rel in preserved_conflicts:
            print(f"  - {rel}")
        print("[提示] 如相关模组出现异常，删除对应文件后重新同步，即可取回服务端最新版本。")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
