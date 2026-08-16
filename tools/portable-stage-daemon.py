#!/usr/bin/env python3
# portable-stage-daemon.py —— 客户端后台"暂存 daemon"（macOS / Linux 版，与 Windows 的 .ps1 对应）
#
# 把整合包更新的下载耗时，从"下次启动前干等"提前到"玩家在线正在游戏时后台悄悄拉"。
# 管理员在线发布更新后，本进程后台把变更文件下到 .portable-staging/；玩家下次重启游戏时，
# 由 --mode promote 就地落位，再交给 player-update-generic.py 正常对账（补下/删旧/去重/校验）。
#
# 设计铁律（与 .ps1 完全一致）：
#   1) 只写 .portable-staging/，绝不改运行中的 mods/*.jar；player-update-generic.py 仍是唯一权威对账器。
#   2) 只在清单变化时才 diff（条件请求 If-Modified-Since，未变回 304，几乎零负担）。
#   3) 生命周期自管：检测本实例的 java 进程 + 最大时长 + 单例锁自退，不残留后台进程。
#   4) macOS 用 osascript 弹原生系统通知（可靠）；另写 READY.json + 更新已就绪.txt。
#   5) 保持 LF 换行 + UTF-8 无 BOM。
import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

# 家宽更新源必须直连：macOS Clash 系统代理会把非标端口请求整齐变成 503。
# 官方 CDN 有系统代理就走代理（国内直连经常能通但很慢）。
_DIRECT_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
urllib.request.install_opener(_DIRECT_OPENER)
_STAGE_UA = "portable-server-kit-stage/1.0"
_OFFICIAL_TIMEOUT_SEC = 8
_OFFICIAL_MIN_BYTES = 256 * 1024
_PROXY_URL = None
_PROXY_OPENER = None
_OFFICIAL_SKIP = False


META_SKIP = {"server-manifest.json", "update-log.txt"}
STAGE_META = {"READY.json", "daemon.lock", "daemon.log"}


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
    if not rel:
        raise ValueError("empty")
    parts = rel.split("/")
    if any(p in ("", ".", "..") for p in parts) or ":" in parts[0]:
        raise ValueError(f"unsafe: {rel}")
    return rel


def join_safe(root: pathlib.Path, rel: str) -> pathlib.Path:
    return root.joinpath(*safe_rel(rel).split("/"))


def glob_match(rel: str, globs) -> bool:
    rel = str(rel).replace("\\", "/").lstrip("/")
    return any(fnmatch.fnmatchcase(rel, str(g).replace("\\", "/").lstrip("/")) for g in globs or [])


def read_update_url(root: pathlib.Path, override: str) -> str:
    if override:
        return override.strip()
    for rel in ("UPDATE-URL.txt", "PORTABLE-UPDATE-URL.txt", "TFCR-update-url.txt",
                "_updater/UPDATE-URL.txt", "_updater/PORTABLE-UPDATE-URL.txt"):
        p = root.joinpath(*rel.split("/"))
        if p.is_file():
            v = p.read_text(encoding="utf-8-sig", errors="ignore").strip()
            if v:
                return v
    return ""


def log(log_path: pathlib.Path, msg: str):
    line = f"[{dt.datetime.now().strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with log_path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def notify_mac(text: str):
    # macOS 原生系统通知（可靠、不抢焦点）。非 macOS 静默跳过。
    if sys.platform != "darwin":
        return
    safe = text.replace('"', "'").replace("\\", "")
    try:
        subprocess.run(
            ["osascript", "-e",
             f'display notification "{safe}" with title "整合包更新已就绪" sound name "Glass"'],
            check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        pass


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def game_running(instance_root: pathlib.Path) -> bool:
    # 严格：只认命令行精确含本实例路径的进程 = 本实例的游戏在跑。守 A 实例的 daemon 绝不会被
    # 主客户端/别的实例带偏。macOS 的 ps 一定读得到完整命令行，没命中就是没在跑；ps 本身失败才保守当作在跑。
    try:
        out = subprocess.run(["ps", "-axww", "-o", "command="],
                             capture_output=True, text=True, timeout=15).stdout
    except Exception:
        return True
    needle = str(instance_root)
    for line in out.splitlines():
        if "java" in line.lower() and needle in line:
            return True
    return False


class Manifest:
    def __init__(self):
        self.last_modified = None

    def if_changed(self, url: str):
        # 条件请求：带上一版 Last-Modified，未变服务器回 304（urllib 抛 HTTPError code=304）。
        req = urllib.request.Request(url)
        if self.last_modified:
            req.add_header("If-Modified-Since", self.last_modified)
        req.add_header("Cache-Control", "no-cache")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                lm = resp.headers.get("Last-Modified")
                if lm:
                    self.last_modified = lm
                data = resp.read()
            return True, data.decode("utf-8-sig", errors="ignore")
        except urllib.error.HTTPError as exc:
            if exc.code == 304:
                return False, None
            raise


def is_official_https_url(url: str) -> bool:
    try:
        parsed = urllib.parse.urlparse(str(url).strip())
    except Exception:
        return False
    if parsed.scheme != "https" or not parsed.netloc:
        return False
    host = (parsed.hostname or "").lower()
    return host not in ("", "localhost", "127.0.0.1", "::1")


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


def detect_system_proxy() -> str:
    flag = str(os.environ.get("PORTABLE_SYNC_NOPROXY") or "").strip().lower()
    if flag in ("1", "true", "yes", "on"):
        return ""
    override = str(os.environ.get("PORTABLE_SYNC_PROXY") or "").strip()
    if override:
        if "://" not in override:
            override = "http://" + override
        if override.lower().startswith("socks"):
            return ""
        return override
    for key in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"):
        value = str(os.environ.get(key) or "").strip()
        if value:
            if "://" not in value:
                value = "http://" + value
            if value.lower().startswith("socks"):
                continue
            return value
    return ""


def get_proxy_url() -> str:
    global _PROXY_URL
    if _PROXY_URL is None:
        _PROXY_URL = detect_system_proxy()
    return _PROXY_URL


def official_opener_for(url: str):
    proxy = get_proxy_url()
    if not proxy:
        return _DIRECT_OPENER
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    if host in ("localhost", "127.0.0.1", "::1") or host.startswith("192.168.") or host.startswith("10."):
        return _DIRECT_OPENER
    global _PROXY_OPENER
    if _PROXY_OPENER is None:
        _PROXY_OPENER = urllib.request.build_opener(
            urllib.request.ProxyHandler({"http": proxy, "https": proxy})
        )
    return _PROXY_OPENER


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


def download_verify(url: str, dest: pathlib.Path, expected: str, opener=None, timeout=120, min_bytes_after_timeout=0):
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix="portable-stage-", suffix=".tmp")
    os.close(fd)
    tmp = pathlib.Path(tmp_name)
    opener = opener or _DIRECT_OPENER
    req = urllib.request.Request(url, headers={"User-Agent": _STAGE_UA})
    try:
        with opener.open(req, timeout=timeout) as resp, tmp.open("wb") as out:
            copy_response(resp, out, timeout, min_bytes_after_timeout)
        actual = sha1(tmp)
        if actual != expected.lower():
            raise RuntimeError(f"SHA1 mismatch expected={expected} actual={actual}")
        shutil.move(str(tmp), dest)
    finally:
        if tmp.exists():
            tmp.unlink()


def download_fail_reason(exc: BaseException) -> str:
    msg = str(exc)
    if "SHA1" in msg:
        return "哈希不符"
    if "too slow" in msg.lower() or "太慢" in msg:
        return "太慢"
    if "timed out" in msg.lower() or "timeout" in msg.lower():
        return "超时"
    if "404" in msg:
        return "404"
    if "403" in msg:
        return "403"
    return "连接失败"


def download_staged_entry(item, base: str, dest: pathlib.Path, expected: str, rel: str, log_path: pathlib.Path) -> str:
    global _OFFICIAL_SKIP
    urls = [] if _OFFICIAL_SKIP else official_urls(item if isinstance(item, dict) else {})
    for url in urls:
        started = time.time()
        try:
            download_verify(
                url, dest, expected,
                opener=official_opener_for(url),
                timeout=_OFFICIAL_TIMEOUT_SEC,
                min_bytes_after_timeout=_OFFICIAL_MIN_BYTES,
            )
            return "official"
        except Exception as exc:
            log(log_path, f"[预下载] 官方源不可用（{time.time() - started:.1f}s，{download_fail_reason(exc)}），改走更新服务：{rel}")
            if not _OFFICIAL_SKIP:
                _OFFICIAL_SKIP = True
                log(log_path, "[预下载] 官方源本轮不再尝试，其余文件直接走更新服务。")
            break
    download_verify(url_for(base, rel), dest, expected, opener=_DIRECT_OPENER)
    return "home"


def url_for(base: str, rel: str) -> str:
    return base + "/".join(urllib.parse.quote(p) for p in safe_rel(rel).split("/"))


def load_sync_baseline(instance_root: pathlib.Path) -> dict:
    # 基线 = 上次同步写入状态文件的清单哈希（rel 小写 → sha1）。
    baseline = {}
    state_path = instance_root / ".portable-sync-state.json"
    if state_path.is_file():
        try:
            state = json.loads(state_path.read_text(encoding="utf-8-sig"))
            for item in state.get("files") or []:
                p, h = item.get("path"), item.get("sha1")
                if p and h:
                    try:
                        baseline[safe_rel(str(p)).lower()] = str(h).lower()
                    except ValueError:
                        continue
        except Exception:
            pass
    return baseline


def run_promote(instance_root: pathlib.Path, stage_root: pathlib.Path, notice_path: pathlib.Path):
    if not stage_root.is_dir():
        return
    # 落位前三方判断：目标文件与基线不符说明玩家本地改过，绝不直接覆盖
    # （丢弃暂存件，交给权威同步器按保留规则裁决）。没有这层防护时，
    # Promote 会无备份地清掉玩家自改的 config（2026-07-21 玩家实锤）。
    baseline = load_sync_baseline(instance_root)
    promoted = 0
    for f in stage_root.rglob("*"):
        if not f.is_file():
            continue
        rel = f.relative_to(stage_root).as_posix()
        if rel in STAGE_META:
            continue
        try:
            dest = join_safe(instance_root, rel)
            # 目标缺失但上次同步基线里有它：交给权威同步器按清单的
            # preserveLocalDeletionGlobs / forceSyncGlobs 裁决，绝不能让
            # 暂存件绕过删除保护直接复活（尤其是玩家删掉的 mods/*.jar）。
            if not dest.is_file() and rel.lower() in baseline:
                f.unlink()
                print(f"[暂存落位] 目标缺失且已有同步基线，交给同步器裁决：{rel}")
                continue
            if dest.is_file():
                dest_hash = sha1(dest)
                if dest_hash != sha1(f) and dest_hash != baseline.get(rel.lower(), ""):
                    f.unlink()
                    print(f"[暂存落位] 检测到本地修改，跳过：{rel}")
                    continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(f), dest)
            promoted += 1
        except Exception as exc:
            print(f"[暂存落位] 跳过（可能被占用）：{rel}；{exc}")
    if promoted:
        print(f"[暂存落位] 已落位 {promoted} 个预下载文件，交给同步器校验。")
    # 清空暂存区元文件 + 空目录，下个会话重来。
    for p in (stage_root / "READY.json", notice_path):
        try:
            p.unlink()
        except Exception:
            pass
    for d in sorted(stage_root.rglob("*"), key=lambda x: len(str(x)), reverse=True):
        if d.is_dir():
            try:
                d.rmdir()
            except Exception:
                pass


def run_watch(instance_root, stage_root, ready_path, notice_path, lock_path, log_path,
              manifest_url, interval, max_runtime_min, grace_min, idle_exit_checks):
    # 单例锁
    if lock_path.is_file():
        try:
            old = int(lock_path.read_text().strip())
        except Exception:
            old = 0
        if pid_alive(old):
            print(f"[暂存] 已有 daemon 在运行（PID {old}），本次退出。")
            return
    lock_path.write_text(str(os.getpid()))

    base = manifest_url.rsplit("/", 1)[0] + "/"
    log(log_path, f"暂存 daemon 启动 (PID {os.getpid()})，间隔 {interval}s，最长 {max_runtime_min} 分钟。")
    proxy = get_proxy_url()
    if proxy:
        log(log_path, f"已检测到系统代理，官方源走代理；家宽更新服务始终直连。")
    else:
        log(log_path, "未检测到系统代理，官方源直连（太慢则回落更新服务）。")

    local_cache = {}

    def local_sha(path: pathlib.Path) -> str:
        if not path.is_file():
            return ""
        st = path.stat()
        key = (str(path), st.st_size, st.st_mtime_ns)
        if key in local_cache:
            return local_cache[key]
        h = sha1(path)
        local_cache[key] = h
        return h

    manifest = Manifest()
    start = time.time()
    last_text = ""
    idle = 0
    staged_total = 0
    first = True
    try:
        while True:
            time.sleep(3 if first else interval)
            first = False

            elapsed_min = (time.time() - start) / 60.0
            if elapsed_min >= max_runtime_min:
                log(log_path, "达到最长运行时间，退出。")
                break
            if elapsed_min >= grace_min:
                if game_running(instance_root):
                    idle = 0
                else:
                    idle += 1
                    if idle >= idle_exit_checks:
                        log(log_path, "检测到游戏已退出，暂存 daemon 收工。")
                        break
            try:
                try:
                    changed, text = manifest.if_changed(manifest_url)
                except Exception as exc:
                    log(log_path, f"清单获取失败：{exc}")
                    continue
                if not changed or not text:
                    continue
                if text == last_text:
                    continue
                try:
                    data = json.loads(text)
                except Exception:
                    log(log_path, "清单解析失败，跳过本轮。")
                    continue
                files = data.get("files") or []
                if not files:
                    last_text = text
                    continue
                last_text = text
                preserve = data.get("preserveLocalChangeGlobs") or []
                preserve_deletions = data.get("preserveLocalDeletionGlobs") or []
                force_sync = data.get("forceSyncGlobs") or []
                preserve_player = bool(data.get("preservePlayerCustomizations", True))
                plat = "mac" if sys.platform == "darwin" else ("windows" if sys.platform.startswith("win") else "linux")
                platform_excludes = (data.get("platformExcludeGlobs") or {}).get(plat) or []
                # 基线 = 上次同步的清单哈希：本地文件与基线不符即玩家改过，不预下载（与 Promote 同一防线）。
                baseline = load_sync_baseline(instance_root)

                log(log_path, "检测到新清单，开始比对并后台预下载……")
                new_staged = 0
                staged_list = []
                for item in files:
                    try:
                        rel = safe_rel(str(item.get("path", "")))
                    except ValueError:
                        continue
                    if rel in META_SKIP:
                        continue
                    expected = str(item.get("sha1", "")).lower()
                    if not expected:
                        continue
                    is_force_sync = glob_match(rel, force_sync)
                    if not is_force_sync and glob_match(rel, preserve):
                        continue
                    if platform_excludes and glob_match(rel, platform_excludes):
                        continue
                    local_hash = local_sha(join_safe(instance_root, rel))
                    if local_hash == expected:
                        continue
                    base_hash = baseline.get(rel.lower(), "")
                    # 与 player-update-generic.py 保持同一语义：已在上次清单中、
                    # 当前被玩家删除、且命中删除保留规则的文件不预下载。
                    # 若旧 daemon 已留下暂存件，也在这里丢弃，避免下一次落位复活。
                    if (not local_hash and base_hash and preserve_player and
                            not is_force_sync and glob_match(rel, preserve_deletions)):
                        stage_path = join_safe(stage_root, rel)
                        if stage_path.is_file():
                            try:
                                stage_path.unlink()
                                log(log_path, f"[预下载] 保留玩家删除，丢弃旧暂存：{rel}")
                            except Exception as exc:
                                log(log_path, f"[预下载] 无法清理旧暂存：{rel}；{exc}")
                        continue
                    if not is_force_sync and local_hash:
                        # 本地存在但与基线不符（或没有基线记录）= 玩家改过：不预下载，交给权威同步器裁决。
                        if not base_hash or local_hash != base_hash:
                            continue
                    stage_path = join_safe(stage_root, rel)
                    if stage_path.is_file() and sha1(stage_path) == expected:
                        continue
                    try:
                        source = download_staged_entry(item, base, stage_path, expected, rel, log_path)
                        log(log_path, f"[预下载/官方源] {rel}" if source == "official" else f"[预下载] {rel}")
                        new_staged += 1
                        staged_list.append(rel)
                    except Exception as exc:
                        log(log_path, f"[预下载失败] {rel}；{exc}")

                if new_staged > 0:
                    staged_total += new_staged
                    version = str(data.get("version") or "")
                    ready_path.write_text(json.dumps({
                        "version": version,
                        "stagedAt": dt.datetime.now().isoformat(timespec="seconds"),
                        "count": staged_total,
                        "lastBatch": staged_list,
                    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                    notice_path.write_text(
                        f"整合包有更新，已在后台下载完成 {staged_total} 个文件。\n"
                        f"重启游戏即可自动生效（无需再等下载）。\n版本：{version}\n",
                        encoding="utf-8")
                    log(log_path, f"本轮预下载完成 {new_staged} 个，累计 {staged_total} 个；已写就绪标记。")
                    notify_mac(f"整合包更新已在后台下载完成（{staged_total} 个文件），退出游戏重开即可生效")
                else:
                    log(log_path, "清单有变化，但无需预下载的新文件（可能只是元数据/被保留项）。")
            except Exception as exc:
                log(log_path, f"本轮异常已跳过：{exc}")
    finally:
        try:
            lock_path.unlink()
        except Exception:
            pass
        log(log_path, "暂存 daemon 已退出。")


def main() -> int:
    ap = argparse.ArgumentParser(description="Portable staging daemon (macOS/Linux)")
    ap.add_argument("--instance-dir", default=".")
    ap.add_argument("--manifest-url", default="")
    ap.add_argument("--mode", choices=("watch", "promote"), default="watch")
    ap.add_argument("--interval-seconds", type=int, default=30)
    ap.add_argument("--max-runtime-minutes", type=int, default=720)
    ap.add_argument("--grace-minutes", type=int, default=15)
    ap.add_argument("--idle-exit-checks", type=int, default=3)
    args = ap.parse_args()

    instance_root = pathlib.Path(args.instance_dir).resolve()
    stage_root = instance_root / ".portable-staging"
    ready_path = stage_root / "READY.json"
    notice_path = instance_root / "更新已就绪.txt"
    lock_path = stage_root / "daemon.lock"
    log_path = stage_root / "daemon.log"

    if args.mode == "promote":
        run_promote(instance_root, stage_root, notice_path)
        return 0

    stage_root.mkdir(parents=True, exist_ok=True)
    manifest_url = read_update_url(instance_root, args.manifest_url)
    if not manifest_url:
        log(log_path, "未找到 UPDATE-URL，暂存 daemon 退出。")
        return 0
    run_watch(instance_root, stage_root, ready_path, notice_path, lock_path, log_path,
              manifest_url, args.interval_seconds, args.max_runtime_minutes,
              args.grace_minutes, args.idle_exit_checks)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
