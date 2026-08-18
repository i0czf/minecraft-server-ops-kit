#!/usr/bin/env python3
"""Small, token-authenticated local image host for QQ -> Minecraft relay.

The service intentionally uses only Python's standard library.  It accepts the
multipart request emitted by QQConsoleBridge, stores content-addressed image
files, and serves them back from /i/<sha256>.<ext>.  The default bind address
is loopback; expose it to Minecraft clients only after changing bindHost and
the firewall deliberately.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import mimetypes
import os
import re
import tempfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple
from urllib.parse import unquote, urlsplit


DEFAULT_MAX_BYTES = 20 * 1024 * 1024
REQUEST_OVERHEAD_LIMIT = 1024 * 1024
IMAGE_NAME_PATTERN = re.compile(r"^[0-9a-f]{64}\.(?:png|jpg|gif|bmp|webp)$")


def read_json(path: Optional[Path]) -> dict:
    if path is None or not path.is_file():
        return {}
    try:
        with path.open("r", encoding="utf-8") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def resolve_path(base_dir: Path, raw: object, default: Path) -> Path:
    text = str(raw or "").strip()
    if not text:
        return default
    candidate = Path(text)
    return candidate if candidate.is_absolute() else (base_dir / candidate)


def configured_tokens(config_path: Optional[Path], token_file: Optional[Path]) -> List[str]:
    """Read tokens on demand so rotating the token file does not require a restart."""

    values: List[str] = []
    config = read_json(config_path)
    image_host = config.get("imageHost") if isinstance(config.get("imageHost"), dict) else {}
    direct = image_host.get("token")
    if isinstance(direct, str) and direct.strip():
        values.append(direct.strip())

    configured_file = image_host.get("tokensFile")
    base_dir = config_path.parent.parent if config_path is not None else Path.cwd()
    file_path = token_file
    if file_path is None and configured_file:
        file_path = resolve_path(base_dir, configured_file, base_dir / "tools" / "image-host-tokens.json")
    token_data = read_json(file_path)
    token_list = token_data.get("tokens")
    if isinstance(token_list, list):
        for item in token_list:
            if not isinstance(item, dict):
                continue
            if item.get("active", True) is False:
                continue
            value = item.get("token")
            if isinstance(value, str) and value.strip():
                values.append(value.strip())
    token_value = token_data.get("token")
    if isinstance(token_value, str) and token_value.strip():
        values.append(token_value.strip())

    environment_token = os.environ.get("IMAGE_HOST_TOKEN", "").strip()
    if environment_token:
        values.append(environment_token)

    # Preserve order for diagnostics while removing duplicates.
    return list(dict.fromkeys(values))


def image_extension(data: bytes) -> Optional[str]:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if len(data) >= 6 and data[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if data.startswith(b"BM"):
        return ".bmp"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    return None


def parse_multipart(content_type: str, body: bytes) -> List[Tuple[str, str, bytes]]:
    match = re.search(r"boundary=(?:\"([^\"]+)\"|([^;]+))", content_type, re.IGNORECASE)
    if not match:
        raise ValueError("multipart boundary missing")
    boundary_text = (match.group(1) or match.group(2)).strip()
    if not boundary_text or len(boundary_text) > 200:
        raise ValueError("invalid multipart boundary")
    boundary = b"--" + boundary_text.encode("utf-8", "strict")
    result: List[Tuple[str, str, bytes]] = []
    for part in body.split(boundary)[1:]:
        if part.startswith(b"--"):
            break
        if part.startswith(b"\r\n"):
            part = part[2:]
        if part.endswith(b"\r\n"):
            part = part[:-2]
        separator = part.find(b"\r\n\r\n")
        if separator < 0:
            continue
        raw_headers = part[:separator].decode("iso-8859-1", "replace")
        content = part[separator + 4:]
        disposition = ""
        for line in raw_headers.split("\r\n"):
            key, split, value = line.partition(":")
            if split and key.strip().lower() == "content-disposition":
                disposition = value.strip()
                break
        name_match = re.search(r"(?:^|;)\s*name=\"([^\"]*)\"", disposition, re.IGNORECASE)
        if not name_match:
            name_match = re.search(r"(?:^|;)\s*name=([^;\s]+)", disposition, re.IGNORECASE)
        if not name_match:
            continue
        filename_match = re.search(r"(?:^|;)\s*filename=\"([^\"]*)\"", disposition, re.IGNORECASE)
        filename = filename_match.group(1) if filename_match else ""
        result.append((name_match.group(1), filename, content))
    return result


class ImageHostHandler(BaseHTTPRequestHandler):
    server_version = "PortableImageHost/1.0"
    protocol_version = "HTTP/1.1"

    @property
    def image_server(self) -> "ImageHostServer":
        return self.server  # type: ignore[return-value]

    def _send_json(self, status: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _error(self, status: int, message: str) -> None:
        self._send_json(status, {"ok": False, "error": message})

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path = urlsplit(self.path).path
        if path == "/status":
            self._send_json(HTTPStatus.OK, {"ok": True, "service": "image-host"})
            return
        if path.startswith("/i/"):
            self._serve_image(unquote(path[3:]))
            return
        self._error(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        if urlsplit(self.path).path != "/upload":
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        raw_length = self.headers.get("Content-Length", "")
        try:
            content_length = int(raw_length)
        except ValueError:
            self._error(HTTPStatus.LENGTH_REQUIRED, "content-length required")
            return
        if content_length <= 0:
            self._error(HTTPStatus.BAD_REQUEST, "empty request")
            return
        request_limit = self.image_server.max_bytes + REQUEST_OVERHEAD_LIMIT
        if content_length > request_limit:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request too large")
            return
        body = self.rfile.read(content_length)
        if len(body) != content_length:
            self._error(HTTPStatus.BAD_REQUEST, "incomplete request")
            return
        try:
            parts = parse_multipart(self.headers.get("Content-Type", ""), body)
        except (UnicodeError, ValueError) as exc:
            self._error(HTTPStatus.BAD_REQUEST, str(exc))
            return

        token = ""
        file_data: Optional[bytes] = None
        for name, _filename, content in parts:
            if name == "token" and not token:
                token = content.decode("utf-8", "replace").strip()
            elif name == "file" and file_data is None:
                file_data = content
        if not token or not self.image_server.token_matches(token):
            self._error(HTTPStatus.UNAUTHORIZED, "invalid token")
            return
        if file_data is None or not file_data:
            self._error(HTTPStatus.BAD_REQUEST, "file missing")
            return
        if len(file_data) > self.image_server.max_bytes:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "image too large")
            return
        extension = image_extension(file_data)
        if extension is None:
            self._error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "unsupported image")
            return

        digest = hashlib.sha256(file_data).hexdigest()
        name = digest + extension
        target = self.image_server.root / name
        try:
            self.image_server.store_image(target, file_data)
        except OSError as exc:
            self._error(HTTPStatus.INTERNAL_SERVER_ERROR, "store failed: " + str(exc))
            return
        self._send_json(HTTPStatus.OK, {"ok": True, "name": name, "size": len(file_data)})

    def _serve_image(self, name: str) -> None:
        if not IMAGE_NAME_PATTERN.fullmatch(name):
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        target = self.image_server.root / name
        try:
            if target.parent != self.image_server.root or not target.is_file():
                raise FileNotFoundError(name)
            data = target.read_bytes()
        except (OSError, FileNotFoundError):
            self._error(HTTPStatus.NOT_FOUND, "not found")
            return
        content_type = mimetypes.types_map.get(target.suffix.lower(), "application/octet-stream")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format_string: str, *args: object) -> None:
        # Keep the hidden process diagnosable without ever printing tokens.
        print("[image-host] " + (format_string % args), flush=True)


class ImageHostServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, bind: Tuple[str, int], root: Path, max_bytes: int,
                 config_path: Optional[Path], token_file: Optional[Path],
                 pid_file: Optional[Path]) -> None:
        super().__init__(bind, ImageHostHandler)
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self.max_bytes = max(1024, max_bytes)
        self.config_path = config_path.resolve() if config_path else None
        self.token_file = token_file.resolve() if token_file else None
        self.pid_file = pid_file.resolve() if pid_file else None
        if self.pid_file:
            self.pid_file.parent.mkdir(parents=True, exist_ok=True)
            self.pid_file.write_text(str(os.getpid()), encoding="ascii")

    def token_matches(self, candidate: str) -> bool:
        return any(hmac.compare_digest(candidate, configured)
                   for configured in configured_tokens(self.config_path, self.token_file))

    def store_image(self, target: Path, data: bytes) -> None:
        if target.exists():
            return
        descriptor, temporary_name = tempfile.mkstemp(prefix=".upload-", suffix=".tmp",
                                                       dir=str(self.root))
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, str(target))
        finally:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass

    def server_close(self) -> None:
        if self.pid_file:
            try:
                if self.pid_file.read_text(encoding="ascii").strip() == str(os.getpid()):
                    self.pid_file.unlink()
            except (OSError, UnicodeError):
                pass
        super().server_close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Portable local image host")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=38080)
    parser.add_argument("--root", type=Path, default=Path("tmp/image-host"))
    parser.add_argument("--config", type=Path)
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--pid-file", type=Path)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    base_dir = args.config.resolve().parent.parent if args.config else Path.cwd()
    root = args.root if args.root.is_absolute() else base_dir / args.root
    token_file = args.token_file
    if token_file is not None and not token_file.is_absolute():
        token_file = base_dir / token_file
    pid_file = args.pid_file
    if pid_file is not None and not pid_file.is_absolute():
        pid_file = base_dir / pid_file
    try:
        server = ImageHostServer((args.bind, args.port), root, args.max_bytes,
                                 args.config, token_file, pid_file)
    except OSError as exc:
        print("[image-host] failed to start: " + str(exc), flush=True)
        return 1
    print("[image-host] listening on %s:%d, root=%s" % (args.bind, args.port, server.root), flush=True)
    if not configured_tokens(server.config_path, server.token_file):
        print("[image-host] warning: no upload token configured", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
