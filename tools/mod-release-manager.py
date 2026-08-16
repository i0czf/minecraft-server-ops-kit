#!/usr/bin/env python3
"""Transactional Minecraft mod release manager.

The QQ bridge only writes authenticated group-upload envelopes to an inbox.
This process owns validation, hashing, deployment, health gates and rollback.
It intentionally defaults to ``observe`` mode; executable JARs must not be
installed merely because somebody uploaded one to a chat group.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import logging
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any, Callable, Iterable

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python 3.10 fallback
    tomllib = None


APP_NAME = "mod-release-manager"
JAR_MAGIC = b"PK"
ZIP_MAGIC = b"PK"
DEFAULT_MAX_BYTES = 512 * 1024 * 1024
DEFAULT_CONFIG = "tools/ops-config.json"
PROGRESS_STAGES = (
    "文件校验与双端候选",
    "回滚快照与完整性复核",
    "服务端变更策略与回滚保护",
    "服务端模组替换",
    "仅发布玩家更新",
    "发布后服务端交接",
    "事务完成",
)


def now_utc() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_now() -> str:
    return now_utc().replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value: Any) -> dt.datetime | None:
    if not value:
        return None
    text = str(value).strip()
    try:
        if text.endswith("Z"):
            text = text[:-1] + "+00:00"
        parsed = dt.datetime.fromisoformat(text)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed.astimezone(dt.timezone.utc)
    except ValueError:
        return None


def safe_rel(root: Path, value: str | Path) -> Path:
    """Resolve a configured path and reject paths outside the server root."""
    candidate = Path(value)
    full = candidate if candidate.is_absolute() else root / candidate
    full = full.resolve()
    try:
        full.relative_to(root.resolve())
    except ValueError as exc:
        raise ValueError(f"path escapes server root: {value}") from exc
    return full


def json_write_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def text_write_atomic(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(value.rstrip() + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def sha256_file(path: Path, max_bytes: int | None = None) -> tuple[str, int]:
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if max_bytes is not None and total > max_bytes:
                raise ValueError(f"file exceeds configured limit ({max_bytes} bytes)")
            digest.update(chunk)
    return digest.hexdigest().lower(), total


def copy_limited(source: Path, destination: Path, max_bytes: int) -> int:
    destination.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    with source.open("rb") as src, destination.open("wb") as dst:
        while True:
            chunk = src.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise ValueError(f"file exceeds configured limit ({max_bytes} bytes)")
            dst.write(chunk)
    return total


def safe_filename(name: str, fallback: str = "upload.jar") -> str:
    value = Path(str(name or "")).name
    value = re.sub(r"[\x00-\x1f\\/:*?\"<>|]", "_", value).strip().strip(".")
    if not value:
        value = fallback
    return value[:180]


def normalize_download_url(value: str) -> str:
    """Percent-encode non-ASCII path/query characters returned by QQ file APIs.

    Some OneBot implementations return a raw Chinese ``fname`` query while
    others return an already escaped URL.  ``urllib`` ultimately encodes the
    request target as ASCII, so normalising here prevents a UnicodeEncodeError
    before the download even starts.  Existing percent escapes are decoded and
    re-encoded once to avoid double escaping.
    """
    parsed = urllib.parse.urlsplit(str(value).strip())
    if parsed.scheme.lower() not in {"http", "https"} or not parsed.netloc:
        return str(value)
    path = urllib.parse.quote(
        urllib.parse.unquote(parsed.path),
        safe="/%:@-._~!$&'()*+,;=",
    )
    query = urllib.parse.quote(
        urllib.parse.unquote(parsed.query),
        safe="=&/?@:;,+%$-._~!()*'",
    )
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path, query, parsed.fragment))


def numeric_version(value: str) -> tuple[int, ...]:
    # NeoForge version strings commonly contain a Minecraft suffix. Numeric
    # comparison is only a guard against obvious downgrades; equal/ambiguous
    # versions are handled by the configured policy below.
    nums = re.findall(r"\d+", str(value or ""))
    return tuple(int(item) for item in nums[:16])


def first_text(value: Any) -> str:
    return "" if value is None else str(value).strip()


def parse_toml_mods(raw: bytes) -> list[dict[str, Any]]:
    text = raw.decode("utf-8-sig", errors="replace")
    result: list[dict[str, Any]] = []
    parsed: dict[str, Any] | None = None
    if tomllib is not None:
        try:
            parsed = tomllib.loads(text)
        except Exception:
            parsed = None
    if parsed:
        entries = parsed.get("mods") or []
        if isinstance(entries, dict):
            entries = [entries]
        for item in entries:
            if not isinstance(item, dict):
                continue
            mod_id = first_text(item.get("modId") or item.get("modid"))
            if not mod_id:
                continue
            result.append(
                {
                    "id": mod_id,
                    "version": first_text(item.get("version")),
                    "name": first_text(item.get("displayName") or item.get("displayname")),
                }
            )
    if result:
        return result
    # A conservative fallback for a malformed TOML parser or an old format.
    blocks = re.split(r"(?m)^\s*\[\[mods\]\]\s*$", text)
    for block in blocks[1:]:
        mod_match = re.search(r"(?m)^\s*modId\s*=\s*['\"]([^'\"]+)", block)
        if not mod_match:
            continue
        ver_match = re.search(r"(?m)^\s*version\s*=\s*['\"]([^'\"]*)", block)
        name_match = re.search(r"(?m)^\s*displayName\s*=\s*['\"]([^'\"]*)", block)
        result.append(
            {
                "id": mod_match.group(1).strip(),
                "version": ver_match.group(1).strip() if ver_match else "",
                "name": name_match.group(1).strip() if name_match else "",
            }
        )
    return result


def parse_fabric_mod(raw: bytes) -> list[dict[str, Any]]:
    try:
        data = json.loads(raw.decode("utf-8-sig"))
    except Exception:
        return []
    if not isinstance(data, dict) or not data.get("id"):
        return []
    return [
        {
            "id": first_text(data.get("id")),
            "version": first_text(data.get("version")),
            "name": first_text(data.get("name")),
        }
    ]


def inspect_jar(path: Path, digest: str | None = None, size: int | None = None) -> dict[str, Any]:
    if path.suffix.lower() != ".jar":
        raise ValueError("only .jar files are accepted")
    with path.open("rb") as handle:
        if handle.read(2) != JAR_MAGIC:
            raise ValueError("file does not look like a ZIP/JAR")
    metadata: list[dict[str, Any]] = []
    with zipfile.ZipFile(path, "r") as archive:
        bad = archive.testzip()
        if bad:
            raise ValueError(f"JAR CRC check failed at {bad}")
        names = set(archive.namelist())
        if "META-INF/neoforge.mods.toml" in names:
            metadata = parse_toml_mods(archive.read("META-INF/neoforge.mods.toml"))
        if not metadata and "META-INF/mods.toml" in names:
            metadata = parse_toml_mods(archive.read("META-INF/mods.toml"))
        if not metadata and "fabric.mod.json" in names:
            metadata = parse_fabric_mod(archive.read("fabric.mod.json"))
    if not metadata:
        raise ValueError("JAR has no readable NeoForge/Fabric mod metadata")
    if digest is None or size is None:
        digest, size = sha256_file(path)
    return {
        "file": path.name,
        "size": size,
        "sha256": digest,
        "mods": metadata,
        "modIds": sorted({first_text(item.get("id")) for item in metadata if item.get("id")}),
    }


class ReleaseError(RuntimeError):
    pass


class Manager:
    def __init__(self, root: Path, config_path: Path, dry_run: bool = False, once: bool = False):
        self.root = root.resolve()
        self.config_path = config_path.resolve()
        self.config = json.loads(self.config_path.read_text(encoding="utf-8-sig"))
        self.cfg = self.config.get("modRelease") or {}
        self.qq = self.config.get("qq") or {}
        self.dry_run = dry_run
        self.once = once

        base = self.cfg.get("stateDirectory", "tmp/mod-release")
        self.base = safe_rel(self.root, base)
        self.inbox = safe_rel(self.root, self.cfg.get("inboxDirectory", f"{base}/inbox"))
        self.processed = safe_rel(self.root, self.cfg.get("processedDirectory", f"{base}/processed"))
        self.rejected = safe_rel(self.root, self.cfg.get("rejectedDirectory", f"{base}/rejected"))
        self.staging = safe_rel(self.root, self.cfg.get("stagingDirectory", f"{base}/staging"))
        self.state_path = safe_rel(self.root, self.cfg.get("statePath", f"{base}/state.json"))
        self.hold_path = safe_rel(self.root, self.cfg.get("holdPath", f"{base}/deploy.hold"))
        self.lock_path = safe_rel(self.root, self.cfg.get("lockPath", f"{base}/manager.lock"))
        self.progress_path = safe_rel(self.root, self.cfg.get("progressPath", f"{base}/progress.json"))
        self.progress_text_path = safe_rel(
            self.root, self.cfg.get("progressTextPath", f"{base}/progress.txt")
        )
        self.object_dir = safe_rel(self.root, self.cfg.get("objectDirectory", "backups/mod-releases/objects"))
        self.release_dir = safe_rel(self.root, self.cfg.get("releaseDirectory", "backups/mod-releases/releases"))
        self.log_path = safe_rel(self.root, self.cfg.get("logPath", "logs/mod-release.log"))
        self.server_mods_dir = safe_rel(self.root, self.cfg.get("serverModsDirectory", "mods"))
        self.client_mods_dir = safe_rel(
            self.root,
            self.cfg.get(
                "clientModsDirectory",
                "CHANGE-ME-client-mods",
            ),
        )
        if self.server_mods_dir == self.client_mods_dir:
            raise ValueError("serverModsDirectory and clientModsDirectory must be different")
        self.targets: dict[str, Path] = {
            "server": self.server_mods_dir,
            "client": self.client_mods_dir,
        }
        # Backward-compatible alias for older diagnostic helpers.
        self.mods_dir = self.server_mods_dir
        self.wrapper_path = self.root / "tools" / "portable-run-server.ps1"
        self.rcon_path = self.root / "tools" / "rcon-command.ps1"
        self.max_bytes = int(self.cfg.get("maxFileBytes", DEFAULT_MAX_BYTES))
        self.max_archive_expanded_bytes = int(
            self.cfg.get("maxArchiveExpandedBytes", max(self.max_bytes, 1024 * 1024 * 1024))
        )
        self.max_archive_entry_count = max(1, int(self.cfg.get("maxArchiveEntryCount", 256)))
        self.max_archive_jar_count = max(1, int(self.cfg.get("maxArchiveJarCount", 64)))
        self.max_archive_compression_ratio = max(1.0, float(self.cfg.get("maxArchiveCompressionRatio", 100.0)))
        self.poll_seconds = max(1, int(self.cfg.get("pollSeconds", 5)))
        self.debounce_seconds = max(0, int(self.cfg.get("debounceSeconds", 30)))
        self.boot_timeout = max(30, int(self.cfg.get("bootTimeoutSeconds", 240)))
        self.soak_seconds = max(0, int(self.cfg.get("soakSeconds", 120)))
        self.final_restart_soak_seconds = max(0, int(self.cfg.get("finalRestartSoakSeconds", 0)))
        # Runtime crash monitoring is deliberately opt-in.  A committed release
        # must not be reverted merely because a later crash report appears.
        self.runtime_crash_rollback = bool(self.cfg.get("runtimeCrashRollback", False))
        self.runtime_observation_seconds = max(
            0, int(self.cfg.get("runtimeObservationSeconds", 300))
        )
        self.rollback_boot_timeout = max(30, int(self.cfg.get("rollbackBootTimeoutSeconds", 180)))
        self.mode = str(self.cfg.get("mode", "observe")).strip().lower()
        self.source_groups = self._ids(self.cfg.get("sourceGroupIds"))
        self.publisher_ids = self._ids(self.cfg.get("publisherIds"))
        self.trigger_ids = self._ids(self.cfg.get("triggerIds"))
        self.allow_group_managers = bool(self.cfg.get("allowGroupManagers", True))
        self.require_client_approval = bool(self.cfg.get("requireClientApproval", True))
        self.onebot_url = str(self.qq.get("onebotUrl", "http://127.0.0.1:3001")).rstrip("/")
        self.notification_groups = self._ids(self.cfg.get("notifyGroupIds")) or self._ids(self.qq.get("groupId"))
        # 进度卡仍持续写入 progress.txt，供 !模组进度查询；主动推送默认关闭，
        # 避免把内部阶段拆成多条长消息刷屏。需要现场观察时可显式打开。
        self.notify_progress = bool(self.cfg.get("notifyProgress", False))
        self.publish_after_success = bool(self.cfg.get("publishAfterSuccess", True))
        # When false, the manager only replaces the server/client files and
        # publishes the player update.  It never sends save/stop or starts the
        # wrapper; the group owner/admin handles the server lifecycle manually.
        # Keep the default true for backward compatibility with older configs.
        self.manage_server_lifecycle = bool(self.cfg.get("manageServerLifecycle", True))
        self.restart_after_publish = bool(self.cfg.get("restartAfterPublish", True))
        # If a rollback is explicitly requested, keep the published update
        # manifest by default.  Transaction-failure rollback overrides this
        # below so a partial publish cannot remain advertised as complete.
        self.restore_publish_on_rollback = bool(self.cfg.get("restorePublishOnRollback", False))
        self.publish_config_path = safe_rel(
            self.root, self.cfg.get("publishConfigPath", "tools/portable-pack.json")
        )
        self.publish_script_path = safe_rel(
            self.root, self.cfg.get("publishScriptPath", "tools/portable-publish.ps1")
        )
        self.publish_timeout = max(60, int(self.cfg.get("publishTimeoutSeconds", 1800)))
        self.publish_dir: Path | None = None
        if self.publish_config_path.is_file():
            publish_cfg = json.loads(self.publish_config_path.read_text(encoding="utf-8-sig"))
            publish_raw = str(publish_cfg.get("publishDir", "modpack-public/hmcl-serverpack"))
            self.publish_dir = safe_rel(self.root, publish_raw)
        self._lock_handle: Any = None
        self._last_progress_notify_at = 0.0
        self._last_progress_notify_key = ""

    @staticmethod
    def _ids(value: Any) -> set[str]:
        values: list[Any]
        if isinstance(value, list):
            values = value
        else:
            values = [value]
        result: set[str] = set()
        for item in values:
            for part in re.split(r"[\s,;，；]+", str(item or "")):
                part = part.strip()
                if part.isdigit() and 5 <= len(part) <= 15:
                    result.add(part)
        return result

    def log(self, message: str) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        line = f"{dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')} {message}"
        with self.log_path.open("a", encoding="utf-8") as handle:
            handle.write(line + "\n")
        if self.dry_run or self.once:
            print(line)

    def ensure_dirs(self) -> None:
        for path in (self.base, self.inbox, self.processed, self.rejected, self.staging, self.object_dir, self.release_dir):
            path.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def pid_is_running(pid: int) -> bool:
        if pid <= 0:
            return False
        if os.name == "nt":
            # Do not use os.kill(pid, 0) on Windows: unlike POSIX it can map to
            # TerminateProcess. Query a limited-information handle instead.
            try:
                import ctypes
                from ctypes import wintypes

                process_query_limited_information = 0x1000
                still_active = 259
                kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
                kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
                kernel32.OpenProcess.restype = wintypes.HANDLE
                kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
                kernel32.GetExitCodeProcess.restype = wintypes.BOOL
                kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
                kernel32.CloseHandle.restype = wintypes.BOOL
                handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
                if not handle:
                    # Access denied means a process exists but is above our
                    # integrity level; never reclaim such a lock.
                    return ctypes.get_last_error() == 5
                try:
                    code = wintypes.DWORD()
                    if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                        return True
                    return code.value == still_active
                finally:
                    kernel32.CloseHandle(handle)
            except Exception:
                return True
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def acquire_lock(self) -> bool:
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        for attempt in range(2):
            try:
                self._lock_handle = self.lock_path.open("x", encoding="ascii")
                self._lock_handle.write(str(os.getpid()))
                self._lock_handle.flush()
                return True
            except FileExistsError:
                try:
                    pid = int(self.lock_path.read_text(encoding="ascii").strip())
                except Exception:
                    pid = 0
                if self.pid_is_running(pid):
                    self.log(f"已有发布管理器锁，pid={pid or '未知'}，本实例退出")
                    return False
                if attempt > 0:
                    self.log("发布管理器陈旧锁竞争未解决，本实例退出")
                    return False
                try:
                    self.lock_path.unlink()
                    self.log(f"已回收陈旧发布管理器锁，旧 pid={pid or '未知'}")
                except FileNotFoundError:
                    pass
                except OSError as exc:
                    self.log(f"无法回收陈旧发布管理器锁：{exc}")
                    return False
        return False

    def release_lock(self) -> None:
        if self._lock_handle is not None:
            try:
                self._lock_handle.close()
            finally:
                self._lock_handle = None
        try:
            self.lock_path.unlink()
        except FileNotFoundError:
            pass

    def load_state(self) -> dict[str, Any]:
        if not self.state_path.exists():
            return {"seenEvents": {}, "failedHashes": {}, "lastKnownGood": None, "pending": None, "history": []}
        try:
            state = json.loads(self.state_path.read_text(encoding="utf-8-sig"))
            if not isinstance(state, dict):
                raise ValueError("state is not an object")
            state.setdefault("seenEvents", {})
            state.setdefault("failedHashes", {})
            state.setdefault("history", [])
            return state
        except Exception as exc:
            raise ReleaseError(f"无法读取发布状态：{exc}") from exc

    def save_state(self, state: dict[str, Any]) -> None:
        state["seenEvents"] = dict(list((state.get("seenEvents") or {}).items())[-500:])
        state["history"] = list((state.get("history") or [])[-100:])
        json_write_atomic(self.state_path, state)

    def post_json(self, action: str, payload: dict[str, Any], timeout: int = 15) -> dict[str, Any]:
        request = urllib.request.Request(
            f"{self.onebot_url}/{action.lstrip('/')}",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json; charset=utf-8", "User-Agent": "PortableServerKit-ModRelease/1.0"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read(2 * 1024 * 1024)
        data = json.loads(raw.decode("utf-8", errors="replace"))
        if isinstance(data, dict) and data.get("retcode") not in (None, 0):
            raise ReleaseError(f"OneBot {action} retcode={data.get('retcode')} status={data.get('status')}")
        return data if isinstance(data, dict) else {}

    def send_text(self, text: str, groups: Iterable[str] | None = None) -> None:
        destinations = {str(item) for item in (groups or self.notification_groups) if str(item).isdigit()}
        if not bool(self.cfg.get("notify", True)) or not destinations:
            return
        text = text.strip()
        if len(text) > 1500:
            text = text[:1497] + "..."
        for group in sorted(destinations):
            try:
                self.post_json("send_group_msg", {"group_id": int(group), "message": text})
            except Exception as exc:
                self.log(f"QQ 文本通知失败 group={group}: {exc}")

    @staticmethod
    def compact_notice_text(value: Any, limit: int = 220) -> str:
        """Keep an actionable error/status reason on one short QQ line."""
        text = re.sub(r"\s+", " ", str(value or "")).strip()
        if len(text) > limit:
            return text[: max(1, limit - 1)] + "…"
        return text

    @staticmethod
    def changed_file_names(record: dict[str, Any]) -> list[str]:
        return sorted(
            {
                safe_filename(str(item.get("fileName", "")))
                for item in record.get("changes", [])
                if str(item.get("fileName", "")).strip()
            }
        )

    @staticmethod
    def compact_name_list(names: Iterable[str], max_items: int = 5, max_chars: int = 180) -> str:
        unique = list(dict.fromkeys(str(name).strip() for name in names if str(name).strip()))
        if not unique:
            return "模组文件"
        shown = "、".join(unique[:max_items])
        if len(shown) > max_chars:
            shown = shown[: max(1, max_chars - 1)] + "…"
        if len(unique) > max_items:
            shown += f" 等共 {len(unique)} 项"
        return shown

    def format_success_notice(self, record: dict[str, Any]) -> str:
        release_id = str(record.get("releaseId", "未知发布"))
        names = self.changed_file_names(record)
        if self.publish_after_success:
            publish_note = "玩家更新已发布"
        else:
            publish_note = "玩家更新未发布"
        if not self.manage_server_lifecycle:
            lifecycle_note = "服务端需手动重启后生效"
        elif self.restart_after_publish:
            lifecycle_note = "服务端已重启并通过基础检查"
        else:
            lifecycle_note = "服务端需手动重启后生效"
        return (
            f"【模组升级完成】{release_id}\n"
            f"已更新 {len(names)} 项：{self.compact_name_list(names)}\n"
            f"{publish_note}；{lifecycle_note}。"
        )

    def format_rollback_notice(
        self,
        release_id: str,
        reason: str,
        publish_state_note: str,
        lifecycle_managed: bool,
    ) -> str:
        if not lifecycle_managed:
            lifecycle_note = "服务端未自动停服/起服，需手动重启确认"
        elif self.restart_after_publish:
            lifecycle_note = "旧版已重新上线"
        else:
            lifecycle_note = "服务端需手动重启确认旧版"
        return (
            f"【模组升级失败】{release_id} 已回滚\n"
            f"原因：{self.compact_notice_text(reason)}\n"
            f"{publish_state_note}；{lifecycle_note}。"
        )

    def format_rollback_failed_notice(self, release_id: str, reason: str, lifecycle_managed: bool) -> str:
        action = "请立即人工停服并检查文件" if lifecycle_managed else "请立即人工检查文件并按需重启"
        return (
            f"【模组升级失败】{release_id} 自动回滚失败\n"
            f"原因：{self.compact_notice_text(reason)}\n{action}。"
        )

    def update_progress(
        self,
        release_id: str,
        step: int,
        title: str,
        detail: str = "",
        groups: Iterable[str] | None = None,
        *,
        status: str = "running",
        notify: bool = False,
        force_notify: bool = False,
    ) -> str:
        """Persist a human-readable progress card before optionally notifying QQ.

        The QQ bridge reads ``progress.txt`` directly, so ``!模组进度`` remains
        responsive even while this single-threaded manager is copying a world
        snapshot, publishing, or waiting for the final server restart.
        """
        total = len(PROGRESS_STAGES)
        step = max(1, min(total, int(step)))
        status = str(status or "running").strip().lower()
        now = iso_now()
        started_at = now
        try:
            old = json.loads(self.progress_path.read_text(encoding="utf-8-sig"))
            if isinstance(old, dict) and str(old.get("releaseId", "")) == release_id:
                started_at = str(old.get("startedAt") or now)
        except Exception:
            pass

        if status in {"success", "completed"}:
            completed = list(PROGRESS_STAGES)
            icon = "✅"
            current_line = f"✅ 结果：{title}"
            filled = 10
        elif status in {"failed", "rollback-failed"}:
            completed = list(PROGRESS_STAGES[: max(0, step - 1)])
            icon = "❌"
            current_line = f"❌ 当前：{title}"
            filled = max(0, min(10, round((step - 1) * 10 / total)))
        elif status in {"rollback", "rolled-back", "cancelled"}:
            completed = list(PROGRESS_STAGES[: max(0, step - 1)])
            icon = "↩"
            current_line = f"↩ 当前：{title}"
            filled = max(0, min(10, round(step * 10 / total)))
        else:
            completed = list(PROGRESS_STAGES[: max(0, step - 1)])
            icon = "⏳" if status == "running" else "⌛"
            current_line = f"{icon} 当前：{title}"
            filled = max(0, min(10, round(step * 10 / total)))
        percent = 100 if status in {"success", "completed"} else round(step * 100 / total)
        bar = "█" * filled + "░" * (10 - filled)
        lines = [
            f"【模组升级进度】{release_id}",
            f"[{bar}] {step}/{total}  {percent}%",
        ]
        if completed:
            lines.append("✅ 已完成：" + " → ".join(completed))
        lines.append(current_line)
        if detail:
            lines.append("说明：" + str(detail).strip()[:700])
        lines.append("更新：" + dt.datetime.now().strftime("%H:%M:%S") + "（发送 !模组进度 可随时查询）")
        message = "\n".join(lines)
        payload = {
            "format": 1,
            "releaseId": release_id,
            "step": step,
            "total": total,
            "percent": percent,
            "status": status,
            "title": title,
            "detail": str(detail),
            "startedAt": started_at,
            "updatedAt": now,
            "message": message,
        }
        json_write_atomic(self.progress_path, payload)
        text_write_atomic(self.progress_text_path, message)

        key = f"{release_id}:{step}:{status}:{title}"
        monotonic_now = time.monotonic()
        should_send = self.notify_progress and notify and (
            force_notify
            or key != self._last_progress_notify_key
            or monotonic_now - self._last_progress_notify_at >= 60
        )
        if should_send:
            self.send_text(message, groups)
            self._last_progress_notify_at = monotonic_now
            self._last_progress_notify_key = key
        return message

    def upload_file(self, path: Path, name: str, groups: Iterable[str] | None = None) -> None:
        destinations = {str(item) for item in (groups or self.notification_groups) if str(item).isdigit()}
        if not bool(self.cfg.get("notify", True)) or not destinations:
            return
        for group in sorted(destinations):
            try:
                self.post_json("upload_group_file", {"group_id": int(group), "file": str(path), "name": name})
                self.log(f"QQ 诊断包已上传 group={group} file={name}")
            except Exception as exc:
                self.log(f"QQ 诊断包上传失败 group={group}: {exc}")

    def read_envelope(self, path: Path) -> dict[str, Any]:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
        if not isinstance(value, dict):
            raise ValueError("envelope is not an object")
        return value

    def eligible(self, envelope: dict[str, Any]) -> tuple[bool, str]:
        group = str(envelope.get("groupId", ""))
        trigger_user = str(envelope.get("userId", ""))
        original_uploader = str(envelope.get("originalUserId", "")) or trigger_user
        trigger = str(envelope.get("trigger", ""))
        trigger_role = str(envelope.get("triggerRole", "")).strip().lower()
        if not self.source_groups:
            return False, "未配置 sourceGroupIds"
        if group not in self.source_groups:
            return False, "来源群不在 sourceGroupIds"
        if not self.publisher_ids:
            return False, "未配置 publisherIds"
        if original_uploader not in self.publisher_ids:
            return False, "原文件上传者不在 publisherIds"
        require_quoted = bool(self.cfg.get("requireQuotedCommand", True))
        if require_quoted and trigger != "quoted-command":
            return False, "必须引用文件并发送明确升级指令"
        if trigger == "quoted-command":
            manager_role = trigger_role in {"owner", "admin"}
            if trigger_user not in self.trigger_ids and not (
                self.allow_group_managers and manager_role
            ):
                return False, "触发者不是群主/管理员，也不在 triggerIds"
        elif trigger != "upload-notice":
            return False, "未知的升级触发类型"
        name = safe_filename(str(envelope.get("fileName", "")))
        if not name.lower().endswith((".zip", ".jar")):
            return False, "不是 ZIP/JAR 文件"
        try:
            declared_size = int(envelope.get("size", 0) or 0)
        except (TypeError, ValueError):
            return False, "文件大小字段无效"
        if declared_size < 0 or declared_size > self.max_bytes:
            return False, "文件大小超过 maxFileBytes"
        return True, "ok"

    def control_eligible(self, envelope: dict[str, Any]) -> tuple[bool, str]:
        group = str(envelope.get("groupId", ""))
        trigger_user = str(envelope.get("userId", ""))
        trigger_role = str(envelope.get("triggerRole", "")).strip().lower()
        action = str(envelope.get("action", "")).strip().lower()
        if group not in self.source_groups:
            return False, "控制命令来源群不在 sourceGroupIds"
        if str(envelope.get("trigger", "")) != "control-command":
            return False, "不是模组升级控制命令"
        if action not in {"approve", "cancel"}:
            return False, "未知的模组升级控制动作"
        manager_role = trigger_role in {"owner", "admin"}
        if trigger_user not in self.trigger_ids and not (
            self.allow_group_managers and manager_role
        ):
            return False, "控制命令触发者不是群主/管理员，也不在 triggerIds"
        return True, "ok"

    def download_envelope(self, envelope: dict[str, Any]) -> Path:
        event_id = safe_filename(str(envelope.get("eventId", "event"))).replace(".", "_")
        name = safe_filename(str(envelope.get("fileName", "upload.jar")))
        final = self.staging / f"{event_id}-{name}"
        if final.exists():
            return final
        file_id = str(envelope.get("fileId", "")).strip()
        if not file_id:
            raise ReleaseError("OneBot 事件没有 fileId")
        data: dict[str, Any] = {}
        get_file_error = ""
        try:
            response = self.post_json("get_file", {"file_id": file_id, "download": True}, timeout=30)
            candidate_data = response.get("data") or {}
            if isinstance(candidate_data, dict):
                data = candidate_data
        except Exception as exc:
            # LLBot 的 get_file 依赖近期消息缓存；群文件稍旧时可能已无缓存，
            # 此时用 group_id + file_id 向 QQ 文件系统重新取直链。
            get_file_error = str(exc)
            self.log(f"get_file 未命中，尝试 get_group_file_url：{get_file_error}")
        source = data.get("file") or data.get("path") or data.get("url")
        if not source:
            group_id = str(envelope.get("groupId", "")).strip()
            if not group_id.isdigit():
                raise ReleaseError("信封缺少有效 groupId，不能获取群文件直链")
            try:
                response = self.post_json(
                    "get_group_file_url",
                    {"group_id": int(group_id), "file_id": file_id},
                    timeout=30,
                )
                candidate_data = response.get("data") or {}
                if isinstance(candidate_data, dict):
                    data = candidate_data
                    source = data.get("url") or data.get("file") or data.get("path")
            except Exception as exc:
                detail = f"get_file={get_file_error or '无可用路径'}; get_group_file_url={exc}"
                raise ReleaseError(f"OneBot 无法取得群文件：{detail}") from exc
        temp = final.with_suffix(final.suffix + ".part")
        try:
            if isinstance(source, str) and source.startswith(("http://", "https://")):
                source = normalize_download_url(source)
                request = urllib.request.Request(source, headers={"User-Agent": "PortableServerKit-ModRelease/1.0"})
                with urllib.request.urlopen(request, timeout=60) as stream, temp.open("wb") as out:
                    total = 0
                    while True:
                        chunk = stream.read(1024 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > self.max_bytes:
                            raise ReleaseError("远程文件超过 maxFileBytes")
                        out.write(chunk)
            elif isinstance(source, str):
                local_source = Path(source)
                if not local_source.is_absolute():
                    local_source = self.root / local_source
                if not local_source.is_file():
                    raise ReleaseError("get_file 返回的本地路径不存在")
                copy_limited(local_source, temp, self.max_bytes)
            else:
                encoded = data.get("base64")
                if not isinstance(encoded, str) or not encoded:
                    raise ReleaseError("OneBot 没有返回本地路径、URL 或 base64")
                decoded = base64.b64decode(encoded, validate=False)
                if len(decoded) > self.max_bytes:
                    raise ReleaseError("base64 文件超过 maxFileBytes")
                temp.write_bytes(decoded)
            os.replace(temp, final)
            return final
        finally:
            try:
                temp.unlink()
            except FileNotFoundError:
                pass

    def inventory_for_target(self, target: str, mods_dir: Path) -> list[dict[str, Any]]:
        if not mods_dir.exists():
            return []
        result: list[dict[str, Any]] = []
        for path in sorted(mods_dir.iterdir(), key=lambda item: item.name.lower()):
            if not path.is_file() or path.suffix.lower() != ".jar":
                continue
            if path.is_symlink():
                raise ReleaseError(f"{target} mods 包含符号链接，拒绝自动发布：{path.name}")
            digest, size = sha256_file(path, self.max_bytes)
            try:
                item = inspect_jar(path, digest, size)
            except Exception as exc:
                # Some servers keep helper/core JARs in mods without a
                # NeoForge/Fabric descriptor.  Keep them in the snapshot and
                # inventory, but never treat them as an automatic replacement
                # target; an uploaded candidate still must have readable
                # metadata and an unambiguous mod ID.
                item = {
                    "file": path.name,
                    "size": size,
                    "sha256": digest,
                    "mods": [],
                    "modIds": [],
                    "metadataError": str(exc),
                }
            item["relativePath"] = str(path.relative_to(self.root)).replace("\\", "/")
            item["target"] = target
            result.append(item)
        return result

    def inventory(self) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        for target, mods_dir in self.targets.items():
            result.extend(self.inventory_for_target(target, mods_dir))
        return result

    def snapshot_mods(self, destination: Path, only_targets: set[str] | None = None) -> None:
        destination.mkdir(parents=True, exist_ok=True)
        for target, mods_dir in self.targets.items():
            if only_targets is not None and target not in only_targets:
                continue
            target_snapshot = destination / target
            if target_snapshot.exists():
                raise ReleaseError(f"{target} 模组快照已存在，拒绝覆盖")
            temp_snapshot = destination / f".{target}-snapshot-{os.getpid()}-{time.time_ns()}"
            temp_snapshot.mkdir(parents=True, exist_ok=False)
            try:
                if mods_dir.exists():
                    for path in mods_dir.iterdir():
                        if path.is_symlink():
                            raise ReleaseError(f"{target} mods 包含符号链接，拒绝制作事务快照：{path.name}")
                        if path.is_file():
                            shutil.copy2(path, temp_snapshot / path.name)
                os.replace(temp_snapshot, target_snapshot)
            finally:
                if temp_snapshot.exists():
                    shutil.rmtree(temp_snapshot)

    def ensure_mod_snapshots(self, destination: Path, targets: set[str]) -> None:
        """Create missing target snapshots and safely reuse complete ones.

        Reuse is required for an authenticated retry after the manager stopped
        between an atomic JAR replacement and its status write.  Existing
        snapshots are never overwritten.
        """
        unknown_targets = set(targets) - set(self.targets)
        if unknown_targets:
            raise ReleaseError(f"未知快照目标：{sorted(unknown_targets)}")
        for target in sorted(targets):
            target_snapshot = destination / target
            if target_snapshot.exists():
                if not target_snapshot.is_dir() or target_snapshot.is_symlink():
                    raise ReleaseError(f"{target} 模组快照不是普通目录，拒绝复用")
                for path in target_snapshot.iterdir():
                    if path.is_symlink() or not path.is_file():
                        raise ReleaseError(f"{target} 模组快照含非普通文件：{path.name}")
                self.log(f"复用已有 {target} 模组回滚快照：{destination.parent.name}")
                continue
            self.snapshot_mods(destination, {target})

    def store_object(self, source: Path, digest: str) -> Path:
        destination = self.object_dir / f"{digest}.jar"
        if not destination.exists():
            temp = destination.with_suffix(".jar.part")
            copy_limited(source, temp, self.max_bytes)
            os.replace(temp, destination)
        return destination

    def archive_jar_paths(self, archive_path: Path, envelope: dict[str, Any]) -> list[tuple[Path, str]]:
        """Validate an outer ZIP and stream only its JAR members into staging.

        Never call ZipFile.extract: member paths are untrusted, and only the
        basename of a validated JAR is materialized under our fixed staging
        directory.  All limits are checked before decompression begins.
        """
        with archive_path.open("rb") as handle:
            if handle.read(2) != ZIP_MAGIC:
                raise ReleaseError("压缩包没有 ZIP 文件头")
        event_id = safe_filename(str(envelope.get("eventId", "event"))).replace(".", "_")
        extract_dir = self.staging / f"{event_id}-archive"
        extract_dir.mkdir(parents=True, exist_ok=True)
        try:
            archive = zipfile.ZipFile(archive_path, "r")
        except (OSError, zipfile.BadZipFile) as exc:
            raise ReleaseError(f"ZIP 无法读取：{exc}") from exc
        with archive:
            infos = archive.infolist()
            if len(infos) > self.max_archive_entry_count:
                raise ReleaseError(
                    f"ZIP 条目过多：{len(infos)} > {self.max_archive_entry_count}"
                )
            expanded = 0
            jar_infos: list[zipfile.ZipInfo] = []
            jar_names: set[str] = set()
            for info in infos:
                raw_name = info.filename.replace("\\", "/")
                member = PurePosixPath(raw_name)
                if (
                    not raw_name
                    or raw_name.startswith("/")
                    or member.is_absolute()
                    or ".." in member.parts
                    or (member.parts and ":" in member.parts[0])
                    or "\x00" in raw_name
                ):
                    raise ReleaseError(f"ZIP 含不安全路径：{info.filename!r}")
                unix_mode = (info.external_attr >> 16) & 0o170000
                if stat.S_ISLNK(unix_mode):
                    raise ReleaseError(f"ZIP 含符号链接，拒绝：{info.filename}")
                if info.flag_bits & 0x1:
                    raise ReleaseError(f"ZIP 含加密条目，拒绝：{info.filename}")
                if info.is_dir():
                    continue
                if info.file_size < 0 or info.compress_size < 0:
                    raise ReleaseError(f"ZIP 条目大小异常：{info.filename}")
                expanded += info.file_size
                if expanded > self.max_archive_expanded_bytes:
                    raise ReleaseError(
                        f"ZIP 解压总量超过限制：{expanded} > {self.max_archive_expanded_bytes}"
                    )
                if info.file_size > 1024 * 1024:
                    if info.compress_size == 0:
                        raise ReleaseError(f"ZIP 条目压缩率异常：{info.filename}")
                    ratio = info.file_size / info.compress_size
                    if ratio > self.max_archive_compression_ratio:
                        raise ReleaseError(
                            f"ZIP 条目疑似解压炸弹：{info.filename}，压缩率 {ratio:.1f}"
                        )
                if member.suffix.lower() != ".jar":
                    continue
                base_name = safe_filename(member.name)
                name_key = base_name.lower()
                if name_key in jar_names:
                    raise ReleaseError(f"ZIP 中存在重名 JAR：{base_name}")
                jar_names.add(name_key)
                jar_infos.append(info)
            if not jar_infos:
                raise ReleaseError("ZIP 中没有 JAR 模组")
            if len(jar_infos) > self.max_archive_jar_count:
                raise ReleaseError(
                    f"ZIP 中 JAR 过多：{len(jar_infos)} > {self.max_archive_jar_count}"
                )

            result: list[tuple[Path, str]] = []
            for index, info in enumerate(jar_infos, start=1):
                file_name = safe_filename(PurePosixPath(info.filename.replace("\\", "/")).name)
                destination = extract_dir / f"{index:03d}-{file_name}"
                temp = destination.with_suffix(destination.suffix + ".part")
                try:
                    total = 0
                    with archive.open(info, "r") as source, temp.open("wb") as out:
                        while True:
                            chunk = source.read(1024 * 1024)
                            if not chunk:
                                break
                            total += len(chunk)
                            if total > self.max_bytes:
                                raise ReleaseError(f"JAR 超过 maxFileBytes：{file_name}")
                            out.write(chunk)
                    if total != info.file_size:
                        raise ReleaseError(
                            f"JAR 解压大小不一致：{file_name}，期望 {info.file_size}，实际 {total}"
                        )
                    os.replace(temp, destination)
                except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
                    raise ReleaseError(f"解压 JAR 失败 {file_name}：{exc}") from exc
                finally:
                    try:
                        temp.unlink()
                    except FileNotFoundError:
                        pass
                result.append((destination, file_name))
            return result

    def build_candidates(self, envelopes: list[dict[str, Any]]) -> list[dict[str, Any]]:
        candidates: list[dict[str, Any]] = []
        for envelope in envelopes:
            downloaded = self.download_envelope(envelope)
            lower_name = safe_filename(str(envelope.get("fileName", downloaded.name))).lower()
            if lower_name.endswith(".zip"):
                sources = self.archive_jar_paths(downloaded, envelope)
            else:
                sources = [(downloaded, safe_filename(str(envelope.get("fileName", downloaded.name))))]
            for index, (path, file_name) in enumerate(sources, start=1):
                digest, size = sha256_file(path, self.max_bytes)
                metadata = inspect_jar(path, digest, size)
                metadata.update(
                    {
                        "eventId": str(envelope.get("eventId", "")),
                        "candidateId": f"{envelope.get('eventId', '')}:{index}",
                        "groupId": str(envelope.get("groupId", "")),
                        "userId": str(envelope.get("userId", "")),
                        "fileName": safe_filename(file_name),
                        "sourcePath": str(path),
                        "sourceArchive": safe_filename(str(envelope.get("fileName", downloaded.name))),
                    }
                )
                candidates.append(metadata)

        seen_ids: dict[str, str] = {}
        for candidate in candidates:
            for mod_id in candidate.get("modIds") or []:
                key = str(mod_id).lower()
                previous = seen_ids.get(key)
                if previous is not None:
                    raise ReleaseError(
                        f"压缩包内多个 JAR 声明了同一 modId {mod_id}：{previous} / {candidate['fileName']}"
                    )
                seen_ids[key] = str(candidate["fileName"])
        return candidates

    def compare_candidates(self, candidates: list[dict[str, Any]], old_inventory: list[dict[str, Any]]) -> list[dict[str, Any]]:
        allow_new = bool(self.cfg.get("allowNewMods", False))
        allow_same = bool(self.cfg.get("allowSameVersionRepack", False))
        allow_down = bool(self.cfg.get("allowDowngrade", False))
        used_old: set[tuple[str, str]] = set()
        planned: list[dict[str, Any]] = []
        inventory_by_target = {
            target: [item for item in old_inventory if item.get("target") == target]
            for target in self.targets
        }
        for candidate in candidates:
            digest = str(candidate["sha256"])
            candidate_ids = {str(item).lower() for item in (candidate.get("modIds") or [])}
            matched_any = False
            changes_for_candidate: list[dict[str, Any]] = []
            for target, mods_dir in self.targets.items():
                matches = [
                    item
                    for item in inventory_by_target[target]
                    if candidate_ids.intersection(
                        {str(mod_id).lower() for mod_id in (item.get("modIds") or [])}
                    )
                ]
                if len(matches) > 1:
                    # Multiple active JARs declaring the same modId are stale
                    # duplicate versions.  They may be consolidated only when
                    # every old JAR's complete modId set is covered by the new
                    # candidate; otherwise a bundled extra mod could be lost.
                    uncovered = [
                        item
                        for item in matches
                        if not {str(value).lower() for value in (item.get("modIds") or [])}.issubset(candidate_ids)
                    ]
                    if uncovered:
                        names = ", ".join(str(item.get("file")) for item in matches)
                        raise ReleaseError(
                            f"{candidate['fileName']} 在 {target} 端命中多个含额外 modId 的 JAR：{names}"
                        )
                if not matches:
                    continue
                matched_any = True
                if len(matches) == 1 and digest == str(matches[0].get("sha256")):
                    continue
                for old in matches:
                    old_path = str(old.get("relativePath", ""))
                    old_key = (target, old_path.lower())
                    if old_key in used_old:
                        raise ReleaseError(f"同一旧 JAR 被多个候选文件替换：{target}:{old_path}")
                    used_old.add(old_key)
                    if digest == str(old.get("sha256")):
                        continue
                    old_versions = [
                        first_text(item.get("version"))
                        for item in old.get("mods", [])
                        if str(item.get("id", "")).lower() in candidate_ids
                    ]
                    old_ids = {str(value).lower() for value in (old.get("modIds") or [])}
                    new_versions = [
                        first_text(item.get("version"))
                        for item in candidate.get("mods", [])
                        if str(item.get("id", "")).lower() in old_ids
                    ]
                    old_v = numeric_version(old_versions[0] if old_versions else "")
                    new_v = numeric_version(new_versions[0] if new_versions else "")
                    if old_v and new_v:
                        if new_v < old_v and not allow_down:
                            raise ReleaseError(
                                f"{target} 候选版本低于当前版本：{old_versions[0]} -> {new_versions[0]}"
                            )
                        if new_v == old_v and not allow_same:
                            raise ReleaseError(
                                f"{target} 版本号相同但二进制不同；需要 allowSameVersionRepack=true"
                            )
                target_name = safe_filename(str(candidate["fileName"]))
                target_path = mods_dir / target_name
                old_full_paths = {
                    safe_rel(self.root, str(item.get("relativePath", ""))).resolve()
                    for item in matches
                }
                if target_path.exists() and target_path.resolve() not in old_full_paths:
                    raise ReleaseError(
                        f"{target} 目标文件名与未接管文件冲突：{target_name}"
                    )
                exact = [item for item in matches if digest == str(item.get("sha256"))]
                primary_old = exact[0] if exact else matches[0]
                change = dict(candidate)
                change.update(
                    {
                        "decision": "replace",
                        "target": target,
                        "old": primary_old,
                        "oldFiles": matches,
                        "targetRelativePath": str(target_path.relative_to(self.root)).replace("\\", "/"),
                    }
                )
                changes_for_candidate.append(change)

            if not matched_any:
                if not allow_new:
                    raise ReleaseError(f"{candidate['fileName']} 是新 mod，allowNewMods=false")
                configured_targets = self.cfg.get("newModTargets") or []
                if isinstance(configured_targets, str):
                    configured_targets = [configured_targets]
                new_targets = [str(item).lower() for item in configured_targets if str(item).lower() in self.targets]
                if not new_targets:
                    raise ReleaseError(
                        f"{candidate['fileName']} 是新 mod，但未配置明确的 newModTargets"
                    )
                for target in new_targets:
                    target_path = self.targets[target] / safe_filename(str(candidate["fileName"]))
                    if target_path.exists():
                        raise ReleaseError(f"{target} 新模组目标已存在：{target_path.name}")
                    change = dict(candidate)
                    change.update(
                        {
                            "decision": "add",
                            "target": target,
                            "old": None,
                            "targetRelativePath": str(target_path.relative_to(self.root)).replace("\\", "/"),
                        }
                    )
                    changes_for_candidate.append(change)

            if not changes_for_candidate:
                candidate["decision"] = "duplicate"
                continue
            candidate["decision"] = "replace" if matched_any else "add"
            planned.extend(changes_for_candidate)
        if not planned:
            return []
        return planned

    def release_id(self, planned: list[dict[str, Any]]) -> str:
        seed = "|".join(
            sorted(f"{item.get('target')}:{item['sha256']}:{item.get('targetRelativePath')}" for item in planned)
        )
        # targetRelativePath 会包含主客户端目录和模组文件的中文名；发布编号只需要
        # 对稳定字节序列做摘要，UTF-8 才是正确且跨机器一致的编码。
        short = hashlib.sha256(seed.encode("utf-8")).hexdigest()[:12]
        return f"{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}-{short}"

    def create_release_record(self, release_id: str, planned: list[dict[str, Any]], old_inventory: list[dict[str, Any]]) -> tuple[Path, dict[str, Any]]:
        release = self.release_dir / release_id
        release.mkdir(parents=True, exist_ok=False)
        new_dir = release / "new"
        new_dir.mkdir()
        for item in planned:
            source = Path(str(item["sourcePath"]))
            destination = new_dir / f"{str(item['sha256'])[:16]}-{safe_filename(str(item['fileName']))}"
            if not destination.exists():
                shutil.copy2(source, destination)
            self.store_object(source, str(item["sha256"]))
            item["releasePath"] = str(destination)
        record = {
            "format": 2,
            "releaseId": release_id,
            "createdAt": iso_now(),
            "mode": self.mode,
            "manageServerLifecycle": self.manage_server_lifecycle,
            "serverLifecycleMode": "automatic" if self.manage_server_lifecycle else "manual",
            "restartAfterPublish": self.restart_after_publish,
            "minecraftVersion": self.cfg.get("minecraftVersion", ""),
            "loader": self.cfg.get("loader", "neoforge"),
            "oldInventory": old_inventory,
            "changes": planned,
            "sourceGroupIds": sorted({str(item.get("groupId")) for item in planned if item.get("groupId")}),
            "status": "validated",
        }
        json_write_atomic(release / "release.json", record)
        return release, record

    def run_rcon(self, command: str, timeout: int = 20) -> str:
        if not self.rcon_path.exists():
            raise ReleaseError("缺少 tools/rcon-command.ps1")
        completed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(self.rcon_path), "-Command", command],
            cwd=self.root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
        )
        output = ((completed.stdout or "") + "\n" + (completed.stderr or "")).strip()
        if completed.returncode != 0:
            raise ReleaseError(output[-500:] or f"RCON 命令失败：{command}")
        return output

    def rcon_alive(self) -> bool:
        try:
            self.run_rcon("list", timeout=8)
            return True
        except Exception:
            return False

    def set_hold(self, reason: str) -> None:
        json_write_atomic(self.hold_path, {"reason": reason, "createdAt": iso_now(), "pid": os.getpid()})

    def clear_hold(self) -> None:
        try:
            self.hold_path.unlink()
        except FileNotFoundError:
            pass

    def server_down(self, timeout: int = 90) -> bool:
        deadline = time.monotonic() + timeout
        failures = 0
        while time.monotonic() < deadline:
            if self.rcon_alive():
                failures = 0
            else:
                failures += 1
                if failures >= 3:
                    return True
            time.sleep(2)
        return False

    def stop_server(self) -> None:
        self.set_hold("mod-release deployment")
        try:
            try:
                self.run_rcon("save-all flush", timeout=30)
            except Exception as exc:
                self.log(f"save-all 失败，继续请求停服：{exc}")
            try:
                self.run_rcon("stop", timeout=20)
            except Exception as exc:
                self.log(f"RCON stop 未成功：{exc}")
            if not self.server_down(120):
                raise ReleaseError("服务端未在 120 秒内停止，保持部署锁，不强杀 Java")
        except Exception:
            raise

    def start_wrapper(self) -> int:
        if not self.wrapper_path.exists():
            raise ReleaseError("缺少 tools/portable-run-server.ps1")
        child_log = self.root / "logs" / "mod-release-wrapper.child.log"
        child_log.parent.mkdir(parents=True, exist_ok=True)
        handle = child_log.open("a", encoding="utf-8")
        flags = 0
        if os.name == "nt":
            # Keep a real child process while the manager verifies the final
            # restart.  DETACHED_PROCESS previously let PowerShell disappear
            # silently, leaving the manager to wait the full boot timeout with
            # an empty child log.
            flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) | getattr(subprocess, "CREATE_NO_WINDOW", 0)
        try:
            process = subprocess.Popen(
                [
                    "powershell.exe",
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(self.wrapper_path),
                    "-NoPause",
                    "-RestartOnCleanExit",
                    "-SkipOpsMonitor",
                ],
                cwd=self.root,
                stdin=subprocess.DEVNULL,
                stdout=handle,
                stderr=subprocess.STDOUT,
                creationflags=flags,
                close_fds=(os.name != "nt"),
            )
            time.sleep(1)
            code = process.poll()
            if code is not None:
                tail = ""
                try:
                    tail = child_log.read_text(encoding="utf-8", errors="replace")[-800:].strip()
                except OSError:
                    pass
                raise ReleaseError(
                    f"服务端启动器提前退出（exit={code}）" + (f"：{tail}" if tail else "")
                )
            self.log(f"已提交最终服务端启动，wrapper PID={process.pid}")
            return int(process.pid)
        finally:
            handle.close()

    def log_size(self, path: Path) -> int:
        try:
            return path.stat().st_size
        except FileNotFoundError:
            return 0

    def new_log_text(self, path: Path, offset: int) -> str:
        if not path.exists():
            return ""
        try:
            with path.open("rb") as handle:
                size = path.stat().st_size
                if size < offset:
                    offset = 0
                handle.seek(offset)
                return handle.read().decode("utf-8", errors="replace")
        except OSError:
            return ""

    def recent_crashes(self, since: float) -> list[Path]:
        crash_dir = self.root / str((self.config.get("crashWatch") or {}).get("directory", "crash-reports"))
        if not crash_dir.exists():
            return []
        return [
            path
            for path in crash_dir.glob("*.txt")
            if path.is_file() and path.stat().st_mtime >= since - 2
        ]

    def wait_health(
        self,
        log_offset: int,
        timeout: int | None = None,
        soak: int | None = None,
        progress_callback: Callable[[str, int, int], None] | None = None,
    ) -> tuple[bool, str]:
        timeout = self.boot_timeout if timeout is None else timeout
        soak = self.soak_seconds if soak is None else soak
        log_path = self.root / str((self.config.get("logWatch") or {}).get("logPath", "logs/latest.log"))
        started = time.time()
        done_seen = False
        rcon_deadline = 0.0
        next_boot_report = 0
        while time.time() - started < timeout:
            elapsed = int(time.time() - started)
            if progress_callback is not None and elapsed >= next_boot_report:
                try:
                    progress_callback("boot", elapsed, timeout)
                except Exception as exc:
                    self.log(f"写入启动进度失败：{exc}")
                next_boot_report = elapsed + 30
            if self.recent_crashes(started):
                return False, "启动期间生成新的 crash-report"
            text = self.new_log_text(log_path, log_offset)
            if re.search(r"Done \([^\n]+\)! For help, type", text):
                done_seen = True
                rcon_deadline = time.time() + 30
                if progress_callback is not None:
                    try:
                        progress_callback("rcon", elapsed, 30)
                    except Exception as exc:
                        self.log(f"写入 RCON 进度失败：{exc}")
                break
            time.sleep(2)
        if not done_seen:
            return False, f"{timeout} 秒内没有看到服务器 Done 标志"
        while time.time() < rcon_deadline and not self.rcon_alive():
            time.sleep(2)
        if not self.rcon_alive():
            return False, "Done 后 RCON 仍不可用"
        soak_started = time.time()
        next_soak_report = 0
        while time.time() - soak_started < soak:
            elapsed = int(time.time() - soak_started)
            if progress_callback is not None and elapsed >= next_soak_report:
                try:
                    progress_callback("soak", elapsed, soak)
                except Exception as exc:
                    self.log(f"写入观察期进度失败：{exc}")
                next_soak_report = elapsed + 30
            if self.recent_crashes(started):
                return False, "健康观察期生成新的 crash-report"
            if not self.rcon_alive():
                return False, "健康观察期 RCON 失联"
            time.sleep(2)
        return True, f"Done + RCON + {soak} 秒观察期通过"

    def snapshot_world(self, release_id: str) -> Path | None:
        if not bool(self.cfg.get("worldSnapshot", True)):
            return None
        script = self.root / "tools" / "backup-world.ps1"
        if not script.exists():
            self.log("缺少 backup-world.ps1，跳过世界快照")
            return None
        try:
            completed = subprocess.run(
                [
                    "powershell.exe",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(script),
                    "-NoRcon",
                    "-KeepRolling",
                    "0",
                    "-BackupPrefix",
                    f"mod-release-{release_id}",
                    "-SuppressWatchNotification",
                ],
                cwd=self.root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=900,
            )
            output = (completed.stdout or "") + "\n" + (completed.stderr or "")
            match = re.search(r"backup created:\s*(.+?)\s+\(", output)
            if completed.returncode != 0 or not match:
                raise ReleaseError(output[-800:] or "世界快照脚本失败")
            path = Path(match.group(1).strip())
            if not path.is_absolute():
                path = self.root / path
            path = path.resolve()
            path.relative_to(self.root.resolve())
            self.log(f"世界快照已创建：{path.name}")
            return path
        except Exception as exc:
            raise ReleaseError(f"世界快照失败：{exc}") from exc

    def apply_release(
        self,
        release: Path,
        record: dict[str, Any],
        only_targets: set[str] | None = None,
    ) -> None:
        selected_targets = set(self.targets) if only_targets is None else set(only_targets)
        unknown_targets = selected_targets - set(self.targets)
        if unknown_targets:
            raise ReleaseError(f"未知部署目标：{sorted(unknown_targets)}")
        for target, mods_dir in self.targets.items():
            if target not in selected_targets:
                continue
            if mods_dir.exists() and (not mods_dir.is_dir() or mods_dir.is_symlink()):
                raise ReleaseError(f"{target} mods 不是普通目录：{mods_dir}")
            mods_dir.mkdir(parents=True, exist_ok=True)
        old_files_dir = release / "old-files"
        old_files_dir.mkdir(exist_ok=True)
        for target in selected_targets:
            (old_files_dir / target).mkdir(exist_ok=True)
        for item in record["changes"]:
            target = str(item.get("target", ""))
            if target not in self.targets:
                raise ReleaseError(f"未知部署目标：{target}")
            if target not in selected_targets:
                continue
            old = item.get("old")
            old_files = item.get("oldFiles") or ([old] if old else [])
            for old_item in old_files:
                if not isinstance(old_item, dict):
                    raise ReleaseError(f"{target} 旧 JAR 记录格式异常")
                old_path = safe_rel(self.root, old_item["relativePath"])
                if old_path.parent.resolve() != self.targets[target].resolve():
                    raise ReleaseError(f"旧 JAR 不在 {target} mods 目录：{old_path}")
                if old_path.exists():
                    old_destination = old_files_dir / target / old_path.name
                    if old_destination.exists():
                        retry_dir = release / "old-files-retry" / str(time.time_ns()) / target
                        retry_dir.mkdir(parents=True, exist_ok=False)
                        old_destination = retry_dir / old_path.name
                    shutil.move(str(old_path), str(old_destination))
            source = Path(str(item["releasePath"]))
            target_path = safe_rel(self.root, str(item["targetRelativePath"]))
            if target_path.parent.resolve() != self.targets[target].resolve():
                raise ReleaseError(f"目标 JAR 越出 {target} mods 目录：{target_path}")
            if target_path.exists():
                digest, _ = sha256_file(target_path, self.max_bytes)
                if digest == str(item["sha256"]).lower():
                    # A manager restart may happen after the target was atomically
                    # installed but before the release record advanced.  Treat the
                    # exact expected hash as already applied; any other file still
                    # fails closed.
                    continue
                raise ReleaseError(f"目标 JAR 已存在且内容不是本发布版本：{target_path.name}")
            temp_target = target_path.with_suffix(target_path.suffix + ".mod-release-part")
            shutil.copy2(source, temp_target)
            digest, _ = sha256_file(temp_target, self.max_bytes)
            if digest != str(item["sha256"]).lower():
                raise ReleaseError(f"写入后 SHA-256 不匹配：{target}:{target_path.name}")
            os.replace(temp_target, target_path)

    def restore_mods(self, release: Path, only_targets: set[str] | None = None) -> None:
        selected_targets = set(self.targets) if only_targets is None else set(only_targets)
        unknown_targets = selected_targets - set(self.targets)
        if unknown_targets:
            raise ReleaseError(f"未知恢复目标：{sorted(unknown_targets)}")
        failed_live = release / "failed-live"
        failed_live.mkdir(exist_ok=True)
        attempt_dir = failed_live / (dt.datetime.now().strftime("%Y%m%d-%H%M%S") + f"-{time.time_ns()}")
        attempt_dir.mkdir(exist_ok=False)
        snapshots = release / "old-mods-snapshot"
        for target, mods_dir in self.targets.items():
            if target not in selected_targets:
                continue
            target_failed = attempt_dir / target
            target_failed.mkdir(exist_ok=True)
            target_snapshot = snapshots / target
            if not target_snapshot.is_dir():
                raise ReleaseError(f"缺少 {target} 模组回滚快照")
            mods_dir.mkdir(parents=True, exist_ok=True)
            for path in list(mods_dir.iterdir()):
                if path.is_file() or path.is_symlink():
                    shutil.move(str(path), str(target_failed / path.name))
            for path in target_snapshot.iterdir():
                if path.is_file() and not path.is_symlink():
                    shutil.copy2(path, mods_dir / path.name)

    def snapshot_publish_state(self, release: Path) -> None:
        if not self.publish_after_success:
            return
        if self.publish_dir is None:
            raise ReleaseError("无法从 portable-pack.json 解析 publishDir")
        snapshot = release / "old-publish-snapshot"
        if snapshot.exists():
            marker = snapshot / "snapshot.json"
            if snapshot.is_dir() and not snapshot.is_symlink() and marker.is_file() and not marker.is_symlink():
                self.log(f"复用已有发布源回滚快照：{release.name}")
                return
            raise ReleaseError("发布源回滚快照已存在但不完整，拒绝覆盖")
        snapshot.mkdir()
        mods_snapshot = snapshot / "mods"
        mods_snapshot.mkdir()
        metadata_snapshot = snapshot / "metadata"
        metadata_snapshot.mkdir()
        publish_mods = self.publish_dir / "mods"
        marker: dict[str, Any] = {
            "publishDir": str(self.publish_dir),
            "publishDirExisted": self.publish_dir.is_dir(),
            "modsExisted": publish_mods.is_dir(),
            "metadata": {},
        }
        if publish_mods.exists():
            if not publish_mods.is_dir() or publish_mods.is_symlink():
                raise ReleaseError(f"发布源 mods 不是普通目录：{publish_mods}")
            for path in publish_mods.iterdir():
                if path.is_symlink() or not path.is_file():
                    raise ReleaseError(f"发布源 mods 含非普通文件：{path.name}")
                shutil.copy2(path, mods_snapshot / path.name)
        metadata_names = (
            "server-manifest.json",
            "update-log.txt",
            "UPDATE-URL.txt",
            "PORTABLE-UPDATE-URL.txt",
            "SERVER.txt",
            "README-sync.txt",
        )
        for name in metadata_names:
            source = self.publish_dir / name
            existed = source.is_file() and not source.is_symlink()
            marker["metadata"][name] = existed
            if existed:
                shutil.copy2(source, metadata_snapshot / name)
        json_write_atomic(snapshot / "snapshot.json", marker)

    def restore_publish_state(self, release: Path) -> None:
        snapshot = release / "old-publish-snapshot"
        marker_path = snapshot / "snapshot.json"
        if not marker_path.is_file():
            return
        marker = json.loads(marker_path.read_text(encoding="utf-8-sig"))
        if self.publish_dir is None:
            raise ReleaseError("无法解析 publishDir，不能恢复发布源")
        publish_mods = self.publish_dir / "mods"
        failed_publish = release / "failed-publish"
        failed_mods = failed_publish / "mods"
        failed_mods.mkdir(parents=True, exist_ok=True)
        if publish_mods.exists():
            if not publish_mods.is_dir() or publish_mods.is_symlink():
                raise ReleaseError("当前发布源 mods 不是普通目录，停止恢复")
            for path in list(publish_mods.iterdir()):
                if path.is_symlink() or not path.is_file():
                    raise ReleaseError(f"当前发布源 mods 含非普通文件：{path.name}")
                shutil.move(str(path), str(failed_mods / path.name))
        else:
            publish_mods.mkdir(parents=True, exist_ok=True)
        mods_snapshot = snapshot / "mods"
        for path in mods_snapshot.iterdir():
            if path.is_file() and not path.is_symlink():
                shutil.copy2(path, publish_mods / path.name)

        metadata_snapshot = snapshot / "metadata"
        metadata = marker.get("metadata") or {}
        for name, existed in metadata.items():
            destination = self.publish_dir / safe_filename(str(name), "metadata.txt")
            backup = metadata_snapshot / safe_filename(str(name), "metadata.txt")
            if bool(existed):
                if not backup.is_file():
                    raise ReleaseError(f"发布源元数据快照缺失：{name}")
                temp = destination.with_suffix(destination.suffix + ".rollback-part")
                shutil.copy2(backup, temp)
                os.replace(temp, destination)
            else:
                try:
                    destination.unlink()
                except FileNotFoundError:
                    pass

    def run_publish(self, release: Path, release_id: str) -> str:
        if not self.publish_after_success:
            return "publishAfterSuccess=false"
        if not self.publish_script_path.is_file():
            raise ReleaseError(f"缺少仅发布更新脚本：{self.publish_script_path}")
        if not self.publish_config_path.is_file():
            raise ReleaseError(f"缺少发布配置：{self.publish_config_path}")
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(self.publish_script_path),
                "-ConfigPath",
                str(self.publish_config_path),
                "-Version",
                release_id,
            ],
            cwd=self.root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=self.publish_timeout,
        )
        output = ((completed.stdout or "") + "\n" + (completed.stderr or "")).strip()
        (release / "publish.log").write_text(output + "\n", encoding="utf-8")
        if completed.returncode != 0:
            raise ReleaseError(
                "仅发布更新失败：" + (output[-1200:] if output else f"exit={completed.returncode}")
            )
        return output[-2000:]

    def create_diagnostic(self, release: Path, reason: str) -> Path:
        diag = release / "diagnostics.zip"
        summary = release / "diagnostics-summary.txt"
        lines = [
            f"发布事务：{release.name}",
            f"时间：{iso_now()}",
            f"原因：{reason}",
            "",
        ]
        files: list[tuple[Path, str, bytes]] = []
        crash_files = sorted(self.recent_crashes(time.time() - 3600), key=lambda p: p.stat().st_mtime, reverse=True)[:3]
        sources: list[tuple[Path, str]] = []
        for path in crash_files:
            sources.append((path, f"crash-reports/{path.name}"))
        for rel, arc in (
            ("logs/latest.log", "logs/latest.log"),
            ("logs/server-wrapper.log", "logs/server-wrapper.log"),
            ("logs/mod-release.log", "logs/mod-release.log"),
            (str(release / "release.json"), "release.json"),
        ):
            path = Path(rel) if Path(rel).is_absolute() else self.root / rel
            if path.exists() and path.is_file():
                sources.append((path, arc))
        for path, arc in sources:
            try:
                data = path.read_bytes()
                if len(data) > 2 * 1024 * 1024 and path.name.endswith(".log"):
                    data = data[-2 * 1024 * 1024 :]
                if path.suffix.lower() in {".log", ".txt", ".json"}:
                    text = data.decode("utf-8", errors="replace")
                    text = re.sub(
                        r"(?i)([\"']?(?:rcon\.)?password|[\"']?[\w.-]*(?:token|apikey|secret|webhookurl)[\"']?)\s*[=:]\s*[\"']?[^\s,}\]]+",
                        r"\1=***REDACTED***",
                        text,
                    )
                    data = text.encode("utf-8")
                lines.append(f"已收集：{arc}（{len(data)} bytes）")
                files.append((path, arc, data))
            except Exception as exc:
                lines.append(f"读取失败：{arc}：{exc}")
        summary.write_text("\n".join(lines) + "\n", encoding="utf-8")
        with zipfile.ZipFile(diag, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(summary, "diagnostics-summary.txt")
            for path, arc, data in files:
                archive.writestr(arc, data)
        return diag

    def runtime_crash_for(self, state: dict[str, Any]) -> tuple[Path, dict[str, Any]] | None:
        """Return a crash report created after the currently committed release.

        The wrapper may restart Java after a crash and Java can exit with code 0,
        so a crash-report timestamp is the reliable post-commit signal.  Runtime
        rollback is opt-in and bounded by ``runtimeObservationSeconds``.  The
        cursor is persisted in ``lastKnownGood`` so restarting this manager does
        not make old reports trigger a rollback.
        """
        # In manual lifecycle mode the JVM keeps running the already-loaded
        # classes until an administrator restarts it.  A crash before that
        # restart cannot be attributed to the new JARs, so never auto-rollback
        # from a post-release crash report in this mode.
        if (
            not self.runtime_crash_rollback
            or not self.manage_server_lifecycle
            or self.mode not in {"auto", "automatic", "signed-auto"}
        ):
            return None
        lkg = state.get("lastKnownGood") or {}
        raw_release_id = lkg.get("releaseId")
        if raw_release_id is None:
            return None
        release_id = str(raw_release_id).strip()
        if not release_id:
            return None
        try:
            since = float(lkg.get("runtimeWatchSinceEpoch", 0) or 0)
        except (TypeError, ValueError):
            since = 0.0
        if since <= 0:
            parsed = parse_time(lkg.get("runtimeWatchSince"))
            since = parsed.timestamp() if parsed else time.time()
        if self.runtime_observation_seconds <= 0 or time.time() >= since + self.runtime_observation_seconds:
            return None
        handled = {str(item) for item in (lkg.get("handledCrashKeys") or [])}
        reports = sorted(self.recent_crashes(since), key=lambda path: path.stat().st_mtime)
        for path in reports:
            try:
                key = f"{path.name}:{path.stat().st_mtime_ns}"
            except OSError:
                continue
            if key not in handled:
                lkg["handledCrashKeys"] = list((handled | {key}))[-32:]
                state["lastKnownGood"] = lkg
                return path, lkg
        return None

    def rollback_release(
        self,
        release: Path,
        record: dict[str, Any],
        state: dict[str, Any],
        reason: str,
        envelopes: list[tuple[Path, dict[str, Any]]] | None = None,
        *,
        restore_publish: bool | None = None,
    ) -> None:
        """Restore the pre-release snapshot while respecting lifecycle policy."""
        envelopes = envelopes or []
        if restore_publish is None:
            restore_publish = self.restore_publish_on_rollback
        release_id = str(record["releaseId"])
        notify_groups = self._ids(record.get("sourceGroupIds")) or self.notification_groups
        lifecycle_managed = self.manage_server_lifecycle
        record["status"] = "rollback"
        record["failureReason"] = reason
        record["failedAt"] = iso_now()
        json_write_atomic(release / "release.json", record)
        self.update_progress(
            release_id,
            6,
            "正式提交失败，正在回滚文件与发布源",
            reason,
            notify_groups,
            status="rollback",
        )
        diag = self.create_diagnostic(release, reason)
        self.upload_file(diag, f"mod-release-{release_id}-diagnostics.zip", notify_groups)
        try:
            if lifecycle_managed:
                self.set_hold("mod-release rollback")
                try:
                    self.run_rcon("stop", timeout=20)
                except Exception:
                    pass
                if not self.server_down(120):
                    raise ReleaseError("回滚前服务端未停止")
            else:
                self.log("手动服务端生命周期模式：回滚不执行停服或起服；若 JAR 被占用将转人工处理。")
            self.restore_mods(release)
            if bool(record.get("publishAttempted", False)) and restore_publish:
                self.restore_publish_state(release)
            elif bool(record.get("publishAttempted", False)):
                record["publishRollbackSkipped"] = True
                self.log(f"保留当前发布源，未恢复更新清单：{release_id}")
            if lifecycle_managed:
                self.clear_hold()
            publish_state_note = (
                "发布源已恢复"
                if restore_publish
                else "发布源保持当前版本，更新清单未回退"
            )
            if lifecycle_managed and self.restart_after_publish:
                self.update_progress(
                    release_id,
                    6,
                    f"旧模组已恢复；{publish_state_note}，正在重启旧版服务端",
                    "回滚启动只用于确认旧版服务端可以恢复在线。",
                    notify_groups,
                    status="rollback",
                    notify=True,
                )
                rollback_offset = self.log_size(
                    self.root / str((self.config.get("logWatch") or {}).get("logPath", "logs/latest.log"))
                )
                self.start_wrapper()
                ok, rollback_reason = self.wait_health(
                    rollback_offset,
                    timeout=self.rollback_boot_timeout,
                    soak=30,
                    progress_callback=lambda phase, elapsed, limit: self.update_progress(
                        release_id,
                        6,
                        "正在验证回滚后的服务端",
                        f"{phase}：{elapsed}/{limit} 秒",
                        notify_groups,
                        status="rollback",
                        notify=elapsed > 0,
                    ),
                )
                if not ok:
                    raise ReleaseError(rollback_reason)
                rollback_health_gate = rollback_reason
            elif not lifecycle_managed:
                rollback_health_gate = (
                    "manageServerLifecycle=false；旧模组与发布源已恢复；"
                    "服务端未自动停服或起服，需群主/管理员手动重启使回滚生效"
                )
                self.update_progress(
                    release_id,
                    6,
                    f"旧模组已恢复；{publish_state_note}；等待人工重启",
                    "按当前配置不自动停服/起服；请群主或管理员手动重启后观察旧版健康状态。",
                    notify_groups,
                    status="rollback",
                    notify=True,
                )
            else:
                rollback_health_gate = (
                    f"restartAfterPublish=false；旧模组已恢复；{publish_state_note}；"
                    "服务端保持停服，等待手动重启"
                )
                self.update_progress(
                    release_id,
                    6,
                    f"旧模组已恢复；{publish_state_note}；服务端保持停服",
                    "按当前配置不自动起服；请人工重启后再观察旧版健康状态。",
                    notify_groups,
                    status="rollback",
                    notify=True,
                )
            record["status"] = "rolled-back"
            record["rollbackAt"] = iso_now()
            record["rollbackReason"] = reason
            record["healthGate"] = rollback_health_gate
            json_write_atomic(release / "release.json", record)
            state["pending"] = None
            failed_hashes = state.setdefault("failedHashes", {})
            for item in record.get("changes", []):
                failed_hashes[str(item["sha256"])] = {
                    "releaseId": release_id,
                    "at": iso_now(),
                    "reason": reason,
                }
            state["lastKnownGood"] = {
                "releaseId": None,
                "at": iso_now(),
                "inventory": record.get("oldInventory", []),
                "restoredFrom": release_id,
            }
            state["history"] = state.get("history", []) + [
                {"releaseId": release_id, "status": "rolled-back", "at": iso_now(), "reason": reason}
            ]
            for path, envelope in envelopes:
                event_id = str(envelope.get("eventId", path.stem))
                self.finalize_event(path, state, "failed", f"发布失败并已回滚：{reason}", event_id)
            self.save_state(state)
            self.update_progress(
                release_id,
                7,
                (
                    f"旧模组已恢复并重新上线；{publish_state_note}"
                    if lifecycle_managed and self.restart_after_publish
                    else (
                        f"旧模组已恢复；服务端未自动停服/起服，等待手动重启；{publish_state_note}"
                        if not lifecycle_managed
                        else f"旧模组已恢复，服务端等待手动重启；{publish_state_note}"
                    )
                ),
                (
                    f"原失败原因：{reason}"
                    if lifecycle_managed and self.restart_after_publish
                    else (
                        f"原失败原因：{reason}；服务端未自动停服/起服，请群主或管理员手动重启。"
                        if not lifecycle_managed
                        else f"原失败原因：{reason}；服务端保持停服，请手动重启。"
                    )
                ),
                notify_groups,
                status="rolled-back",
                notify=True,
                force_notify=True,
            )
            self.send_text(
                self.format_rollback_notice(
                    release_id,
                    reason,
                    publish_state_note,
                    lifecycle_managed,
                ),
                notify_groups,
            )
            self.log(f"发布回滚完成：{release_id}；{publish_state_note}")
        except Exception as rollback_exc:
            self.set_hold("mod-release rollback failed; manual intervention required")
            record["status"] = "rollback-failed"
            record["rollbackFailure"] = str(rollback_exc)
            json_write_atomic(release / "release.json", record)
            state["pending"] = {"releaseId": release_id, "status": "rollback-failed", "at": iso_now()}
            self.save_state(state)
            self.update_progress(
                release_id,
                6,
                "自动回滚失败，需要人工介入",
                str(rollback_exc),
                notify_groups,
                status="rollback-failed",
            )
            self.send_text(
                self.format_rollback_failed_notice(release_id, str(rollback_exc), lifecycle_managed),
                notify_groups,
            )
            raise

    def check_runtime_crash(self, state: dict[str, Any]) -> bool:
        """Optionally roll back a committed release during its bounded watch window."""
        hit = self.runtime_crash_for(state)
        if not hit:
            return False
        crash_path, lkg = hit
        release_id = str(lkg.get("releaseId", ""))
        release = self.release_dir / safe_filename(release_id)
        record_path = release / "release.json"
        try:
            record = json.loads(record_path.read_text(encoding="utf-8-sig"))
            if not isinstance(record, dict) or str(record.get("status")) != "committed":
                return False
            reason = f"提交后检测到崩溃报告：{crash_path.name}"
            self.log(f"当前发布 {release_id} 运行期崩溃：{crash_path.name}，触发自动回滚")
            self.rollback_release(release, record, state, reason)
            return True
        except Exception as exc:
            self.log(f"运行期崩溃回滚失败：{exc}")
            return True

    def finalize_event(self, envelope_path: Path, state: dict[str, Any], status: str, reason: str = "", event_id: str | None = None) -> None:
        event_id = event_id or envelope_path.stem
        state.setdefault("seenEvents", {})[event_id] = {"status": status, "at": iso_now(), "reason": reason}
        target_dir = self.rejected if status in {"rejected", "failed", "duplicate"} else self.processed
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / envelope_path.name
        if not self.dry_run:
            try:
                os.replace(envelope_path, target)
            except FileNotFoundError:
                pass

    def verify_staged_client(self, record: dict[str, Any]) -> int:
        expected = {
            str(item.get("relativePath", "")): str(item.get("sha256", "")).lower()
            for item in record.get("oldInventory", [])
            if str(item.get("target", "")) == "client" and item.get("relativePath")
        }
        client_changes = [
            item for item in record.get("changes", []) if str(item.get("target", "")) == "client"
        ]
        for item in client_changes:
            old = item.get("old")
            old_files = item.get("oldFiles") or ([old] if old else [])
            for old_item in old_files:
                if isinstance(old_item, dict):
                    expected.pop(str(old_item.get("relativePath", "")), None)
            expected[str(item.get("targetRelativePath", ""))] = str(item.get("sha256", "")).lower()
        current = {
            str(item.get("relativePath", "")): str(item.get("sha256", "")).lower()
            for item in self.inventory_for_target("client", self.client_mods_dir)
            if item.get("relativePath")
        }
        if current != expected:
            names = sorted(set(current) ^ set(expected))
            changed = sorted(path for path in set(current) & set(expected) if current[path] != expected[path])
            detail = "、".join((names + changed)[:8]) or "未知差异"
            raise ReleaseError(f"主客户端测试期间出现计划外模组变化：{detail}")
        return len(client_changes)

    def stage_client_release(
        self,
        release: Path,
        record: dict[str, Any],
        state: dict[str, Any],
        envelopes: list[tuple[Path, dict[str, Any]]],
    ) -> None:
        release_id = str(record["releaseId"])
        notify_groups = self._ids(record.get("sourceGroupIds")) or self.notification_groups
        if state.get("pending"):
            raise ReleaseError("已有一笔模组升级等待处理，不能覆盖")
        snapshot = release / "old-mods-snapshot"
        record["status"] = "staging-client"
        record["clientStageStartedAt"] = iso_now()
        json_write_atomic(release / "release.json", record)
        try:
            self.snapshot_mods(snapshot, {"client"})
            self.apply_release(release, record, {"client"})
            client_change_count = self.verify_staged_client(record)
        except Exception as exc:
            try:
                if (snapshot / "client").is_dir():
                    self.restore_mods(release, {"client"})
            except Exception as restore_exc:
                raise ReleaseError(f"主客户端候选写入失败且恢复失败：{exc}; restore={restore_exc}") from exc
            raise ReleaseError(f"主客户端候选写入失败，已恢复旧版：{exc}") from exc
        record["status"] = "awaiting-client-approval"
        record["clientStagedAt"] = iso_now()
        record["clientChangeCount"] = client_change_count
        json_write_atomic(release / "release.json", record)
        state["pending"] = {
            "releaseId": release_id,
            "status": "awaiting-client-approval",
            "at": iso_now(),
        }
        for path, envelope in envelopes:
            event_id = str(envelope.get("eventId", path.stem))
            self.finalize_event(path, state, "staged", release_id, event_id)
        state["history"] = state.get("history", []) + [
            {"releaseId": release_id, "status": "awaiting-client-approval", "at": iso_now()}
        ]
        self.save_state(state)
        self.update_progress(
            release_id,
            1,
            "等待主客户端人工启动测试",
            f"已写入 {client_change_count} 项客户端变更；服务端和玩家更新源尚未修改。",
            notify_groups,
            status="waiting",
        )
        self.send_text(
            f"【模组升级】客户端候选已就位：{client_change_count} 项，服务端未改。\n"
            "测试通过发 !确认升级模组；不采用发 !取消升级模组。",
            notify_groups,
        )
        self.log(f"主客户端候选已就位，等待人工测试确认：{release_id}")

    @staticmethod
    def release_event_ids(record: dict[str, Any]) -> set[str]:
        return {str(item.get("eventId")) for item in record.get("changes", []) if item.get("eventId")}

    def process_control(
        self,
        path: Path,
        envelope: dict[str, Any],
        state: dict[str, Any],
    ) -> None:
        event_id = str(envelope.get("eventId", path.stem))
        pending = state.get("pending") or {}
        release_id = str(pending.get("releaseId", ""))
        if str(pending.get("status", "")) != "awaiting-client-approval" or not release_id:
            reason = "当前没有等待主客户端测试确认的模组升级"
            self.send_text(f"【模组升级】{reason}。", {str(envelope.get("groupId", ""))})
            self.finalize_event(path, state, "rejected", reason, event_id)
            self.save_state(state)
            return
        release = self.release_dir / safe_filename(release_id)
        record_path = release / "release.json"
        if not record_path.is_file():
            reason = f"待确认发布记录缺失：{release_id}"
            self.finalize_event(path, state, "failed", reason, event_id)
            self.save_state(state)
            self.send_text(f"【模组升级失败】{reason}", {str(envelope.get("groupId", ""))})
            return
        record = json.loads(record_path.read_text(encoding="utf-8-sig"))
        source_groups = self._ids(record.get("sourceGroupIds"))
        group = str(envelope.get("groupId", ""))
        if source_groups and group not in source_groups:
            reason = "确认命令与原升级请求不在同一来源群"
            self.finalize_event(path, state, "rejected", reason, event_id)
            self.save_state(state)
            self.send_text(f"【模组升级】{reason}，已拒绝。", {group})
            return
        action = str(envelope.get("action", "")).lower()
        if action == "cancel":
            try:
                self.restore_mods(release, {"client"})
                record["status"] = "cancelled"
                record["cancelledAt"] = iso_now()
                record["cancelledBy"] = str(envelope.get("userId", ""))
                json_write_atomic(record_path, record)
                state["pending"] = None
                for original_id in self.release_event_ids(record):
                    state.setdefault("seenEvents", {})[original_id] = {
                        "status": "cancelled",
                        "at": iso_now(),
                        "reason": release_id,
                    }
                state["history"] = state.get("history", []) + [
                    {"releaseId": release_id, "status": "cancelled", "at": iso_now()}
                ]
                self.finalize_event(path, state, "processed", f"cancelled {release_id}", event_id)
                self.save_state(state)
                self.update_progress(
                    release_id,
                    1,
                    "已取消并恢复主客户端旧版",
                    "服务端和玩家发布源均未改动。",
                    source_groups or {group},
                    status="cancelled",
                )
                self.send_text(
                    f"【模组升级已取消】{release_id}；客户端已恢复，服务端和玩家更新源未改。",
                    source_groups or {group},
                )
                self.log(f"主客户端候选已取消并恢复：{release_id}")
            except Exception as exc:
                reason = f"恢复主客户端旧版失败：{exc}"
                record["status"] = "client-cancel-failed"
                record["failureReason"] = reason
                json_write_atomic(record_path, record)
                self.finalize_event(path, state, "failed", reason, event_id)
                self.save_state(state)
                self.send_text(f"【模组取消失败】{reason}\n请人工检查主客户端 mods。", source_groups or {group})
            return
        try:
            self.update_progress(
                release_id,
                2,
                "正在复核确认人、客户端哈希与候选版本",
                "复核通过后才会安全停服；此阶段不会修改服务端。",
                source_groups or {group},
                notify=True,
                force_notify=True,
            )
            self.verify_staged_client(record)
            record["clientApprovedAt"] = iso_now()
            record["clientApprovedBy"] = str(envelope.get("userId", ""))
            json_write_atomic(record_path, record)
            self.deploy_release(release, record, state, [], client_already_staged=True)
            final_record = json.loads(record_path.read_text(encoding="utf-8-sig"))
            final_status = str(final_record.get("status", ""))
            control_status = "processed" if final_status == "committed" else "failed"
            self.finalize_event(path, state, control_status, f"{final_status} {release_id}", event_id)
            for original_id in self.release_event_ids(final_record):
                state.setdefault("seenEvents", {})[original_id] = {
                    "status": final_status,
                    "at": iso_now(),
                    "reason": release_id,
                }
            self.save_state(state)
        except Exception as exc:
            reason = str(exc)
            self.finalize_event(path, state, "failed", reason, event_id)
            self.save_state(state)
            self.send_text(
                f"【模组升级失败】确认未执行：{self.compact_notice_text(reason)}；主客户端候选未变。",
                source_groups or {group},
            )

    def recover_interrupted_pending(self, state: dict[str, Any]) -> bool:
        """Turn an orphaned in-flight transaction back into explicit approval.

        A new manager process must never silently continue a stop/deploy action
        authorized before the crash.  If the server is currently healthy, no
        deployment hold remains, and the tested client still matches exactly,
        preserve all immutable snapshots but require a fresh manager command.
        """
        pending = state.get("pending") or {}
        pending_status = str(pending.get("status", ""))
        release_id = str(pending.get("releaseId", ""))
        if pending_status not in {"deploying", "booting", "publishing", "restarting", "rollback"} or not release_id:
            return False
        if self.hold_path.exists():
            return False
        if self.manage_server_lifecycle and not self.rcon_alive():
            return False
        release = self.release_dir / safe_filename(release_id)
        record_path = release / "release.json"
        if not record_path.is_file():
            return False
        record = json.loads(record_path.read_text(encoding="utf-8-sig"))
        if str(record.get("status", "")) in {"committed", "rolled-back", "rollback-failed", "cancelled"}:
            return False
        try:
            self.verify_staged_client(record)
        except Exception as exc:
            self.update_progress(
                release_id,
                2,
                "检测到中断事务，但主客户端已发生变化",
                f"不会自动续跑：{exc}",
                self._ids(record.get("sourceGroupIds")) or self.notification_groups,
                status="failed",
            )
            return False
        previous_status = str(record.get("status", ""))
        record["interruptedStatus"] = previous_status
        record["interruptedRecoveredAt"] = iso_now()
        record["status"] = "awaiting-client-approval"
        record["approvalBlockedReason"] = "上一次正式提交进程中断，必须重新确认后才续跑"
        first_notice = not bool(record.get("interruptedRecoveryNoticeAt"))
        if first_notice:
            record["interruptedRecoveryNoticeAt"] = iso_now()
        json_write_atomic(record_path, record)
        state["pending"] = {
            "releaseId": release_id,
            "status": "awaiting-client-approval",
            "at": iso_now(),
        }
        state["history"] = state.get("history", []) + [
            {"releaseId": release_id, "status": "interrupted-awaiting-reconfirm", "at": iso_now()}
        ]
        self.save_state(state)
        groups = self._ids(record.get("sourceGroupIds")) or self.notification_groups
        self.update_progress(
            release_id,
            2,
            "上一次事务中断，等待管理员重新确认",
            "当前服务端在线且主客户端候选哈希一致；发送 !确认更新 后按新流程安全续跑。",
            groups,
            status="waiting",
            notify=first_notice,
            force_notify=first_notice,
        )
        if first_notice:
            self.send_text(
                "【模组升级】上次事务中断，已暂停；客户端候选未变，确认后继续。",
                groups,
            )
        self.log(f"中断事务已恢复为等待重新确认：{release_id}（原状态={previous_status}）")
        return True

    def process_once(self) -> int:
        state = self.load_state()
        if self.recover_interrupted_pending(state):
            return 0
        # A leftover hold is a deliberate fail-safe (for example after a
        # manager crash during replacement or an unsuccessful rollback).  Do
        # not consume a new upload while the server is waiting for review.
        if self.hold_path.exists():
            return 0
        if self.check_runtime_crash(state):
            self.save_state(state)
            return 0
        envelopes: list[tuple[Path, dict[str, Any]]] = []
        controls: list[tuple[Path, dict[str, Any]]] = []
        for path in sorted(self.inbox.glob("*.json"), key=lambda p: p.name):
            try:
                envelope = self.read_envelope(path)
            except Exception as exc:
                self.log(f"忽略损坏的入站信封 {path.name}: {exc}")
                if not self.dry_run:
                    path.replace(self.rejected / path.name)
                continue
            event_id = str(envelope.get("eventId", path.stem))
            if event_id in state.get("seenEvents", {}):
                continue
            if str(envelope.get("trigger", "")) == "control-command":
                accepted, why = self.control_eligible(envelope)
                if not accepted:
                    self.log(f"拒绝 {path.name}: {why}")
                    self.finalize_event(path, state, "rejected", why, event_id)
                    continue
                controls.append((path, envelope))
                continue
            accepted, why = self.eligible(envelope)
            if not accepted:
                self.log(f"拒绝 {path.name}: {why}")
                self.finalize_event(path, state, "rejected", why)
                continue
            received = parse_time(envelope.get("receivedAt"))
            if not self.once and received and (now_utc() - received).total_seconds() < self.debounce_seconds:
                continue
            envelopes.append((path, envelope))
        if controls:
            self.process_control(controls[0][0], controls[0][1], state)
            return 1
        pending = state.get("pending") or {}
        if str(pending.get("status", "")) == "awaiting-client-approval":
            if envelopes:
                reason = f"已有发布 {pending.get('releaseId')} 等待主客户端测试确认"
                groups = {str(envelope.get("groupId", "")) for _, envelope in envelopes}
                for path, envelope in envelopes:
                    self.finalize_event(
                        path,
                        state,
                        "rejected",
                        reason,
                        str(envelope.get("eventId", path.stem)),
                    )
                self.save_state(state)
                self.send_text(f"【模组升级】{reason}；请先确认或取消当前发布。", groups)
                return len(envelopes)
            return 0
        if not envelopes:
            return 0
        # 每条显式引用命令本身就是一个事务边界。ZIP 已能承载多个 JAR，
        # 不把两位发布者的独立请求偶然合并成一次停服部署。
        envelopes = envelopes[:1]
        request_groups = {
            str(envelope.get("groupId"))
            for _, envelope in envelopes
            if str(envelope.get("groupId", "")).isdigit()
        }
        try:
            candidates = self.build_candidates([item[1] for item in envelopes])
            old_inventory = self.inventory()
            failed_hashes = state.get("failedHashes") or {}
            blocked = [item for item in candidates if str(item.get("sha256")) in failed_hashes]
            if blocked:
                names = "、".join(str(item.get("fileName")) for item in blocked)
                raise ReleaseError(f"压缩包含已因失败发布熔断的 JAR：{names}")
            planned = self.compare_candidates(candidates, old_inventory)
            planned_ids = {str(item.get("eventId")) for item in planned}
            if not planned:
                for path, envelope in envelopes:
                    event_id = str(envelope.get("eventId", path.stem))
                    self.finalize_event(path, state, "duplicate", "所有 JAR 均与对应端当前文件相同", event_id)
                self.save_state(state)
                self.send_text("【模组升级】无需更新：上传文件与当前模组一致。", request_groups)
                return len(envelopes)
            release_id = self.release_id(planned)
            release, record = self.create_release_record(release_id, planned, old_inventory)
            flow = "主客户端人工确认" if self.require_client_approval else "自动双端提交"
            self.log(f"发现候选发布 {release_id}: {len(planned)} 个 JAR，模式={self.mode}，流程={flow}")
            # 引用命令已经由 QQ 桥即时回执；只有兼容旧的“上传即触发”模式时，
            # 管理器才补一条开始通知，避免同一事务出现两条重复的开场白。
            if not any(str(envelope.get("trigger", "")) == "quoted-command" for _, envelope in envelopes):
                self.send_text(
                    f"【模组升级】开始处理：{len(planned)} 项；完成后通知。",
                    request_groups,
                )
            if self.mode not in {"auto", "automatic", "signed-auto"} or self.dry_run:
                record["status"] = "observed"
                json_write_atomic(release / "release.json", record)
                for path, envelope in envelopes:
                    event_id = str(envelope.get("eventId", path.stem))
                    if event_id in planned_ids:
                        self.finalize_event(path, state, "observed", release_id, event_id)
                state["history"] = state.get("history", []) + [{"releaseId": release_id, "status": "observed", "at": iso_now()}]
                self.save_state(state)
                self.send_text(
                    f"【模组升级】已检查 {len(planned)} 项；当前为观察模式，未修改线上文件。",
                    request_groups,
                )
                return len(envelopes)
            if self.require_client_approval:
                self.stage_client_release(release, record, state, envelopes)
            else:
                self.deploy_release(release, record, state, envelopes)
            return len(envelopes)
        except Exception as exc:
            self.log(f"候选处理失败：{exc}")
            self.log(traceback.format_exc().strip())
            self.send_text(
                f"【模组升级失败】校验未通过，线上文件未改。原因：{self.compact_notice_text(exc)}",
                request_groups,
            )
            for path, envelope in envelopes:
                event_id = str(envelope.get("eventId", path.stem))
                self.finalize_event(path, state, "failed", str(exc), event_id)
            self.save_state(state)
            return len(envelopes)

    def deploy_release(
        self,
        release: Path,
        record: dict[str, Any],
        state: dict[str, Any],
        envelopes: list[tuple[Path, dict[str, Any]]],
        *,
        client_already_staged: bool = False,
    ) -> None:
        release_id = str(record["releaseId"])
        notify_groups = self._ids(record.get("sourceGroupIds")) or self.notification_groups
        lifecycle_managed = self.manage_server_lifecycle
        record["manageServerLifecycle"] = lifecycle_managed
        record["serverLifecycleMode"] = "automatic" if lifecycle_managed else "manual"
        record["restartAfterPublish"] = self.restart_after_publish
        record["status"] = "pending"
        record["deploymentStartedAt"] = iso_now()
        json_write_atomic(release / "release.json", record)
        snapshot = release / "old-mods-snapshot"
        world_backup: Path | None = None
        state["pending"] = {"releaseId": release_id, "status": "deploying", "at": iso_now()}
        self.save_state(state)
        stop_attempted = False
        apply_started = False
        try:
            if lifecycle_managed and not bool(self.cfg.get("allowWhenStopped", False)) and not self.rcon_alive():
                raise ReleaseError("服务端当前不可由 RCON 确认在线，拒绝自动部署")
            self.update_progress(
                release_id,
                2,
                "正在制作可回退快照并复核主客户端",
                "此阶段服务端仍在线；任何快照不完整都会停止事务。",
                notify_groups,
            )
            if client_already_staged:
                self.verify_staged_client(record)
                self.ensure_mod_snapshots(snapshot, {"server"})
            else:
                self.ensure_mod_snapshots(snapshot, set(self.targets))
            self.snapshot_publish_state(release)
            record["publishAttempted"] = False
            json_write_atomic(release / "release.json", record)
            if lifecycle_managed:
                self.update_progress(
                    release_id,
                    3,
                    "正在安全存盘并停止服务端",
                    "依次执行 save-all flush、RCON stop；绝不强杀 Java。",
                    notify_groups,
                    notify=True,
                )
                stop_attempted = True
                self.stop_server()
                if bool(self.cfg.get("worldSnapshot", True)):
                    self.update_progress(
                        release_id,
                        3,
                        "服务端已停止，正在创建世界快照",
                        "大存档压缩可能需要数分钟；完成前不会替换模组。",
                        notify_groups,
                        notify=True,
                    )
                    world_backup = self.snapshot_world(release_id)
                else:
                    self.log("按配置跳过世界快照：worldSnapshot=false；保留模组与发布源回滚快照。")
                    self.update_progress(
                        release_id,
                        3,
                        "服务端已停止，已跳过世界快照",
                        "worldSnapshot=false：保留模组与发布源回滚快照；世界由定时备份负责。重大世界迁移前可临时开启。",
                        notify_groups,
                        notify=True,
                    )
                    world_backup = None
            else:
                self.update_progress(
                    release_id,
                    3,
                    "保留服务端当前状态，准备替换模组",
                    "manageServerLifecycle=false：不执行 save-all、停服、起服或世界快照；新 JAR 需下次人工重启后由 NeoForge 加载。",
                    notify_groups,
                    notify=True,
                )
                if bool(self.cfg.get("worldSnapshot", False)):
                    self.log("手动服务端生命周期模式跳过世界快照：在线世界不在本事务中压缩；请依赖定时备份。")
                else:
                    self.log("按配置跳过世界快照：worldSnapshot=false；保留模组与发布源回滚快照。")
                self.update_progress(
                    release_id,
                    3,
                    "服务端保持当前状态，已跳过世界快照",
                    "仅保留模组与发布源回滚快照；如需让新模组生效，由群主或管理员手动停服并重启。",
                    notify_groups,
                    notify=True,
                )
                world_backup = None
            record["worldBackup"] = str(world_backup) if world_backup else None
            json_write_atomic(release / "release.json", record)
            self.update_progress(
                release_id,
                4,
                "正在替换服务端模组并校验 SHA-256",
                (
                    "只处理候选记录对应的 modId；同哈希文件允许中断后安全续跑。"
                    if lifecycle_managed
                    else "只处理候选记录对应的 modId；当前 JVM 不热加载模组，替换结果在下次人工重启后生效。"
                ),
                notify_groups,
                notify=True,
            )
            apply_started = True
            self.apply_release(release, record, {"server"} if client_already_staged else None)
            record["status"] = "publishing"
            record["serverAppliedAt"] = iso_now()
            record["publishAttempted"] = self.publish_after_success
            record["publishStartedAt"] = iso_now() if self.publish_after_success else None
            json_write_atomic(release / "release.json", record)
            self.update_progress(
                release_id,
                5,
                "服务端换包完成，正在执行【仅发布更新】",
                (
                    "玩家清单以已人工测试的主客户端 mods 为准；发布完成前保持停服。"
                    if lifecycle_managed
                    else "玩家清单以主客户端 mods 为准；本次不操作服务端进程，发布后由管理员手动重启使新模组生效。"
                ),
                notify_groups,
                notify=True,
            )
            publish_output = self.run_publish(release, release_id)
            record["publishCompletedAt"] = iso_now() if self.publish_after_success else None
            record["publishOutputTail"] = publish_output

            if lifecycle_managed and self.restart_after_publish:
                record["status"] = "restarting"
                json_write_atomic(release / "release.json", record)
                self.update_progress(
                    release_id,
                    6,
                    "发布已完成，正在执行最终一次服务端重启",
                    "不再进行换包后的中间起服；这里只启动最终对外版本。",
                    notify_groups,
                    notify=True,
                )
                self.clear_hold()
                log_path = self.root / str((self.config.get("logWatch") or {}).get("logPath", "logs/latest.log"))
                final_log_offset = self.log_size(log_path)
                wrapper_pid = self.start_wrapper()
                record["restartRequestedAt"] = iso_now()
                record["restartWrapperPid"] = wrapper_pid
                json_write_atomic(release / "release.json", record)

                def final_restart_progress(phase: str, elapsed: int, limit: int) -> None:
                    if phase == "boot":
                        detail = f"等待 Done：{elapsed}/{limit} 秒"
                    elif phase == "rcon":
                        detail = "已看到 Done，正在确认 RCON 可用"
                    else:
                        detail = f"启动观察：{elapsed}/{limit} 秒"
                    self.update_progress(
                        release_id,
                        6,
                        "正在确认最终重启状态",
                        detail,
                        notify_groups,
                        notify=elapsed >= 60,
                    )

                ok, reason = self.wait_health(
                    final_log_offset,
                    soak=self.final_restart_soak_seconds,
                    progress_callback=final_restart_progress,
                )
                if not ok:
                    raise ReleaseError(reason)
                record["healthGate"] = reason
            else:
                if lifecycle_managed:
                    self.clear_hold()
                record["status"] = "committed"
                record["restartRequestedAt"] = None
                record["restartWrapperPid"] = None
                record["restartDeferred"] = True
                record["restartDeferredAt"] = iso_now()
                record["healthGate"] = (
                    "manageServerLifecycle=false；双端替换与仅发布更新已完成，未执行停服/起服或运行健康检查；"
                    "等待群主/管理员手动重启"
                    if not lifecycle_managed
                    else "restartAfterPublish=false；双端替换与仅发布更新已完成，服务端保持停服，等待手动重启"
                )
                json_write_atomic(release / "release.json", record)
                self.update_progress(
                    release_id,
                    6,
                    (
                        "仅发布已完成，等待管理员手动重启"
                        if not lifecycle_managed
                        else "仅发布已完成，服务端等待手动重启"
                    ),
                    (
                        "客户端与服务端模组已替换，玩家更新清单已刷新；服务端未自动停服/起服。"
                        if not lifecycle_managed
                        else "客户端与服务端模组已替换，玩家更新清单已刷新；按配置不自动起服。"
                    ),
                    notify_groups,
                    notify=True,
                )
            record["status"] = "committed"
            record["committedAt"] = iso_now()
            json_write_atomic(release / "release.json", record)
            state["pending"] = None
            state["lastKnownGood"] = {
                "releaseId": release_id,
                "at": iso_now(),
                "inventory": self.inventory(),
                "runtimeWatchSince": iso_now() if lifecycle_managed else None,
                "runtimeWatchSinceEpoch": time.time() if lifecycle_managed else 0,
                "handledCrashKeys": [],
                "manualRestartPending": not lifecycle_managed,
            }
            state["history"] = state.get("history", []) + [{"releaseId": release_id, "status": "committed", "at": iso_now()}]
            self.save_state(state)
            planned_event_ids = {str(item.get("eventId")) for item in record.get("changes", [])}
            for path, envelope in envelopes:
                event_id = str(envelope.get("eventId", path.stem))
                if event_id in planned_event_ids:
                    self.finalize_event(path, state, "committed", release_id, event_id)
            self.save_state(state)
            self.update_progress(
                release_id,
                7,
                (
                    "客户端、服务端与玩家更新已替换；等待管理员手动重启"
                    if not lifecycle_managed
                    else (
                        "客户端、服务端与玩家更新已一致；服务端等待手动重启"
                        if not self.restart_after_publish
                        else "客户端、服务端与玩家更新已一致"
                    )
                ),
                (
                    "仅发布更新完成；服务端未自动停服/起服，请群主或管理员手动重启使新模组生效。"
                    if not lifecycle_managed
                    else (
                        "仅发布更新完成；服务端保持停服，请手动重启。"
                        if not self.restart_after_publish
                        else "仅发布更新完成，服务端最终重启已通过 Done 与 RCON 基础确认。"
                    )
                ),
                notify_groups,
                status="success",
                notify=True,
                force_notify=True,
            )
            self.send_text(self.format_success_notice(record), notify_groups)
            self.log(f"发布提交成功：{release_id}")
        except Exception as exc:
            reason = str(exc)
            self.log(f"发布 {release_id} 失败，准备一次性回滚：{reason}")
            if not stop_attempted and not apply_started:
                if client_already_staged:
                    # 客户端候选已经人工验证，但服务端预检尚未通过；此时没有动
                    # 服务端，也不能把一次临时 RCON/快照问题误判成客户端失败。
                    record["status"] = "awaiting-client-approval"
                    record["approvalBlockedReason"] = reason
                    json_write_atomic(release / "release.json", record)
                    state["pending"] = {
                        "releaseId": release_id,
                        "status": "awaiting-client-approval",
                        "at": iso_now(),
                    }
                    self.save_state(state)
                    self.update_progress(
                        release_id,
                        2,
                        "确认暂未执行，仍等待再次确认",
                        reason,
                        notify_groups,
                        status="waiting",
                    )
                    self.send_text(
                        f"【模组升级】确认暂未执行：{self.compact_notice_text(reason)}；"
                        "客户端候选保留，可排除问题后再次确认。",
                        notify_groups,
                    )
                    return
                # 预检阶段没有发出停服请求，也没有改动线上 mods；不要因为
                # RCON 暂时不可用而把一个原本停着的服务端意外启动起来。
                record["status"] = "failed-no-change"
                record["failureReason"] = reason
                record["failedAt"] = iso_now()
                json_write_atomic(release / "release.json", record)
                state["pending"] = None
                state["history"] = state.get("history", []) + [
                    {"releaseId": release_id, "status": "failed-no-change", "at": iso_now(), "reason": reason}
                ]
                self.clear_hold()
                for path, envelope in envelopes:
                    event_id = str(envelope.get("eventId", path.stem))
                    self.finalize_event(path, state, "failed", reason, event_id)
                self.save_state(state)
                self.send_text(
                    f"【模组升级失败】{release_id} 未执行；线上文件和服务端均未改。\n"
                    f"原因：{self.compact_notice_text(reason)}",
                    notify_groups,
                )
                return
            # A failed transaction must restore the published source as well;
            # otherwise a partially-written manifest can advertise an update
            # whose server/client files were rolled back.
            self.rollback_release(release, record, state, reason, envelopes, restore_publish=True)

    def run(self) -> int:
        if not bool(self.cfg.get("enabled", False)):
            self.log("modRelease.enabled=false，管理器退出")
            return 0
        if not self.source_groups or not self.publisher_ids:
            self.log("未配置 sourceGroupIds 或 publisherIds，管理器保持安全停用")
            return 0
        if bool(self.cfg.get("requireQuotedCommand", True)) and not (
            self.allow_group_managers or self.trigger_ids
        ):
            self.log("既未允许群主/管理员，也未配置 triggerIds，管理器保持安全停用")
            return 0
        for target, mods_dir in self.targets.items():
            if not mods_dir.is_dir() or mods_dir.is_symlink():
                self.log(f"{target} mods 目录缺失或不安全，管理器保持停用：{mods_dir}")
                return 0
        if self.publish_after_success and (
            not self.publish_config_path.is_file() or not self.publish_script_path.is_file() or self.publish_dir is None
        ):
            self.log("仅发布更新脚本、配置或 publishDir 缺失，管理器保持停用")
            return 0
        self.ensure_dirs()
        if not self.acquire_lock():
            return 0
        try:
            if self.once:
                return self.process_once()
            self.log(
                f"{APP_NAME} started mode={self.mode} poll={self.poll_seconds}s "
                f"requireClientApproval={self.require_client_approval} "
                f"manageServerLifecycle={self.manage_server_lifecycle}"
            )
            while True:
                try:
                    self.process_once()
                except Exception:
                    self.log(traceback.format_exc().strip())
                time.sleep(self.poll_seconds)
        finally:
            self.release_lock()


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except AttributeError:
        pass
    parser = argparse.ArgumentParser(description="Transactional Minecraft mod release manager")
    parser.add_argument("--config", default=DEFAULT_CONFIG)
    parser.add_argument("--once", action="store_true", help="process one inbox pass and exit")
    parser.add_argument("--dry-run", action="store_true", help="validate and report, never deploy or move envelopes")
    parser.add_argument("--inventory", action="store_true", help="print current active mod inventory and exit")
    args = parser.parse_args(argv)
    config_path = Path(args.config).resolve()
    root = config_path.parent.parent
    manager = Manager(root, config_path, dry_run=args.dry_run, once=args.once)
    if args.inventory:
        print(json.dumps(manager.inventory(), ensure_ascii=False, indent=2))
        return 0
    return manager.run()


if __name__ == "__main__":
    raise SystemExit(main())
