#!/usr/bin/env python3
"""Regression tests for incremental mixed-source downloads.

Covers URL policy and official-then-home fallback. Uses only a local HTTP
server and temporary files; never touches the live update source or world.
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).with_name("player-update-generic.py")
SPEC = importlib.util.spec_from_file_location("player_update_generic", MODULE_PATH)
assert SPEC and SPEC.loader
UPD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPD)


def sha1_bytes(data: bytes) -> str:
    return hashlib.sha1(data).hexdigest()


class _Handler(BaseHTTPRequestHandler):
    hits = None
    payloads = None
    hang_paths = None

    def log_message(self, format, *args):
        return

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        self.hits.append(path)
        if self.hang_paths and path in self.hang_paths:
            time.sleep(60)
            return
        body = self.payloads.get(path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class MixedSourceTests(unittest.TestCase):
    def setUp(self):
        UPD.reset_download_policy()

    def test_official_url_policy(self):
        self.assertTrue(UPD.is_official_https_url("https://cdn.modrinth.com/data/aa/file.jar"))
        self.assertFalse(UPD.is_official_https_url("http://cdn.modrinth.com/data/aa/file.jar"))
        self.assertFalse(UPD.is_official_https_url("https://localhost/x.jar"))
        self.assertFalse(UPD.is_official_https_url("https://127.0.0.1/x.jar"))
        self.assertFalse(UPD.is_official_https_url("file:///tmp/x.jar"))
        self.assertFalse(UPD.is_official_https_url(""))
        self.assertFalse(UPD.is_official_https_url("not-a-url"))

    def test_official_urls_from_url_and_downloads(self):
        item = {
            "url": "https://cdn.modrinth.com/a.jar",
            "downloads": [
                "https://cdn.modrinth.com/a.jar",
                "http://evil.example/a.jar",
                "https://cdn.modrinth.com/b.jar",
            ],
        }
        self.assertEqual(
            UPD.official_urls(item),
            ["https://cdn.modrinth.com/a.jar", "https://cdn.modrinth.com/b.jar"],
        )
        self.assertEqual(UPD.official_urls({"path": "mods/x.jar"}), [])
        self.assertEqual(UPD.official_urls({"url": "http://example/x.jar"}), [])

    def test_download_official_success_skips_home(self):
        good = b"official-bytes-v1"
        home = b"home-should-not-be-read"
        digest = sha1_bytes(good)
        hits, base = self._serve({"/cdn/good.jar": good, "/mods/good.jar": home})
        dest = Path(self._tmpdir()) / "mods" / "good.jar"
        with mock.patch.object(UPD, "official_urls", return_value=[base + "cdn/good.jar"]):
            source = UPD.download_manifest_entry(
                {"path": "mods/good.jar", "sha1": digest},
                base,
                dest,
                digest,
                "mods/good.jar",
            )
        self.assertEqual(source, "official")
        self.assertEqual(dest.read_bytes(), good)
        self.assertEqual(hits, ["/cdn/good.jar"])

    def test_official_404_falls_back_home(self):
        good = b"home-bytes-v2"
        digest = sha1_bytes(good)
        hits, base = self._serve({"/mods/priv.jar": good})
        dest = Path(self._tmpdir()) / "mods" / "priv.jar"
        with mock.patch.object(UPD, "official_urls", return_value=[base + "cdn/missing.jar"]):
            source = UPD.download_manifest_entry(
                {"path": "mods/priv.jar", "sha1": digest},
                base,
                dest,
                digest,
                "mods/priv.jar",
            )
        self.assertEqual(source, "home")
        self.assertEqual(dest.read_bytes(), good)
        self.assertIn("/cdn/missing.jar", hits)
        self.assertIn("/mods/priv.jar", hits)

    def test_official_hash_mismatch_falls_back_home(self):
        official = b"wrong-payload"
        home = b"correct-payload"
        digest = sha1_bytes(home)
        hits, base = self._serve({"/cdn/bad.jar": official, "/mods/need.jar": home})
        dest = Path(self._tmpdir()) / "mods" / "need.jar"
        with mock.patch.object(UPD, "official_urls", return_value=[base + "cdn/bad.jar"]):
            source = UPD.download_manifest_entry(
                {"path": "mods/need.jar", "sha1": digest},
                base,
                dest,
                digest,
                "mods/need.jar",
            )
        self.assertEqual(source, "home")
        self.assertEqual(dest.read_bytes(), home)
        self.assertIn("/cdn/bad.jar", hits)
        self.assertIn("/mods/need.jar", hits)

    def test_official_hang_falls_back_quickly(self):
        good = b"home-after-hang"
        digest = sha1_bytes(good)
        hits, base = self._serve({"/mods/hang.jar": good}, hang_paths={"/cdn/hang.jar"})
        dest = Path(self._tmpdir()) / "mods" / "hang.jar"
        started = __import__("time").time()
        with mock.patch.object(UPD, "official_urls", return_value=[base + "cdn/hang.jar"]):
            source = UPD.download_manifest_entry(
                {"path": "mods/hang.jar", "sha1": digest},
                base,
                dest,
                digest,
                "mods/hang.jar",
            )
        elapsed = __import__("time").time() - started
        self.assertEqual(source, "home")
        self.assertEqual(dest.read_bytes(), good)
        self.assertLess(elapsed, 15, f"official hang took {elapsed:.1f}s, expected fail-fast")
        self.assertIn("/mods/hang.jar", hits)

    def test_detect_proxy_from_env_and_override(self):
        env = {
            "PORTABLE_SYNC_NOPROXY": "",
            "PORTABLE_SYNC_PROXY": "",
            "HTTPS_PROXY": "http://127.0.0.1:7890",
            "https_proxy": "http://127.0.0.1:7890",
            "HTTP_PROXY": "http://127.0.0.1:7890",
            "http_proxy": "http://127.0.0.1:7890",
        }
        with mock.patch.dict(os.environ, env, clear=False):
            self.assertEqual(UPD.detect_system_proxy(), "http://127.0.0.1:7890")
        with mock.patch.dict(os.environ, {**env, "PORTABLE_SYNC_PROXY": "127.0.0.1:10809"}, clear=False):
            self.assertEqual(UPD.detect_system_proxy(), "http://127.0.0.1:10809")
        with mock.patch.dict(os.environ, {**env, "PORTABLE_SYNC_NOPROXY": "1"}, clear=False):
            self.assertEqual(UPD.detect_system_proxy(), "")
        self.assertEqual(UPD.normalize_proxy_url("socks5://127.0.0.1:7891"), "")
        self.assertEqual(UPD.parse_win_proxy_server("http=127.0.0.1:7890;https=127.0.0.1:7890"), "http://127.0.0.1:7890")

    def test_localhost_and_lan_bypass_proxy(self):
        self.assertTrue(UPD.url_bypasses_proxy("http://127.0.0.1:18088/a.jar"))
        self.assertTrue(UPD.url_bypasses_proxy("http://192.168.10.10:18088/a.jar"))
        self.assertFalse(UPD.url_bypasses_proxy("https://cdn.modrinth.com/data/aa/file.jar"))

    def test_official_uses_proxy_opener_for_cdn(self):
        good = b"via-proxy"
        digest = sha1_bytes(good)
        dest = Path(self._tmpdir()) / "mods" / "proxied.jar"
        fake_opener = object()
        with mock.patch.object(UPD, "official_urls", return_value=["https://cdn.modrinth.com/data/aa/file.jar"]):
            with mock.patch.object(UPD, "get_proxy_url", return_value="http://127.0.0.1:7890"):
                with mock.patch.object(UPD, "url_bypasses_proxy", return_value=False):
                    with mock.patch.object(UPD, "official_opener", return_value=fake_opener):
                        with mock.patch.object(UPD, "download_file") as dl:
                            dl.side_effect = [None]
                            source = UPD.download_manifest_entry(
                                {"path": "mods/proxied.jar", "sha1": digest},
                                "http://127.0.0.1:9/",
                                dest,
                                digest,
                                "mods/proxied.jar",
                            )
        self.assertEqual(source, "official")
        self.assertEqual(dl.call_count, 1)
        self.assertIs(dl.call_args.kwargs.get("opener") or dl.call_args[1].get("opener"), fake_opener)

    def test_home_download_always_uses_direct_opener(self):
        good = b"home-direct"
        digest = sha1_bytes(good)
        hits, base = self._serve({"/mods/priv.jar": good})
        dest = Path(self._tmpdir()) / "mods" / "priv.jar"
        with mock.patch.object(UPD, "get_proxy_url", return_value="http://127.0.0.1:7890"):
            source = UPD.download_manifest_entry(
                {"path": "mods/priv.jar", "sha1": digest},
                base,
                dest,
                digest,
                "mods/priv.jar",
            )
        self.assertEqual(source, "home")
        self.assertEqual(dest.read_bytes(), good)
        self.assertEqual(hits, ["/mods/priv.jar"])

    def test_first_official_fail_skips_later_official(self):
        good = b"home-after-skip"
        digest = sha1_bytes(good)
        hits, base = self._serve({
            "/mods/one.jar": good,
            "/mods/two.jar": good,
            "/cdn/two.jar": b"should-not-fetch",
        })
        dest1 = Path(self._tmpdir()) / "mods" / "one.jar"
        dest2 = Path(self._tmpdir()) / "mods" / "two.jar"
        with mock.patch.object(UPD, "official_urls", side_effect=[
            [base + "cdn/missing.jar"],
            [base + "cdn/two.jar"],
        ]):
            first = UPD.download_manifest_entry(
                {"path": "mods/one.jar", "sha1": digest}, base, dest1, digest, "mods/one.jar",
            )
            second = UPD.download_manifest_entry(
                {"path": "mods/two.jar", "sha1": digest}, base, dest2, digest, "mods/two.jar",
            )
        self.assertEqual(first, "home")
        self.assertEqual(second, "home")
        self.assertIn("/cdn/missing.jar", hits)
        self.assertNotIn("/cdn/two.jar", hits)
        self.assertIn("/mods/two.jar", hits)

    def test_no_official_url_uses_home_only(self):
        good = b"private-port-jar"
        digest = sha1_bytes(good)
        hits, base = self._serve({"/mods/port.jar": good})
        dest = Path(self._tmpdir()) / "mods" / "port.jar"
        source = UPD.download_manifest_entry(
            {"path": "mods/port.jar", "sha1": digest},
            base,
            dest,
            digest,
            "mods/port.jar",
        )
        self.assertEqual(source, "home")
        self.assertEqual(dest.read_bytes(), good)
        self.assertEqual(hits, ["/mods/port.jar"])

    def test_order_manifest_urls_drops_lan(self):
        public = "http://updates.example.test:18088/t/server-manifest.json"
        lan = "http://192.168.10.10:18088/t/server-manifest.json"
        self.assertEqual(UPD.order_manifest_urls([public, lan], last_good=lan), [public])
        self.assertEqual(UPD.order_manifest_urls([public, lan], last_good=""), [public])
        self.assertEqual(UPD.order_manifest_urls([lan], last_good=""), [lan])
        self.assertEqual(UPD.probe_timeout_for_url(public), UPD._PUBLIC_PROBE_TIMEOUT_SEC)

    def test_looks_like_current_file_trusts_last_sync(self):
        tmp = Path(self._tmpdir()) / "mods" / "a.jar"
        tmp.parent.mkdir(parents=True, exist_ok=True)
        payload = b"already-synced-bytes"
        tmp.write_bytes(payload)
        digest = sha1_bytes(payload)
        self.assertTrue(UPD.looks_like_current_file(tmp, digest, len(payload), digest, None))
        self.assertFalse(UPD.looks_like_current_file(tmp, digest, len(payload) + 1, digest, None))
        self.assertFalse(UPD.looks_like_current_file(tmp, "deadbeef", len(payload), "", None))
        verified = UPD.file_verify_record(tmp, digest)
        self.assertTrue(UPD.looks_like_current_file(tmp, digest, len(payload), digest, verified))
        tmp.write_bytes(payload + b"x")
        os.utime(tmp, (tmp.stat().st_atime, verified["mtime"] + 5))
        self.assertFalse(UPD.looks_like_current_file(tmp, digest, len(payload), digest, verified))

    def test_official_slow_trickle_aborts_by_rate(self):
        class SlowResp:
            def __init__(self):
                self.left = 8

            def read(self, _n):
                if self.left <= 0:
                    return b""
                self.left -= 1
                time.sleep(0.25)
                return b"x" * 1024

        out = tempfile.SpooledTemporaryFile()
        started = time.time()
        with self.assertRaises(TimeoutError):
            UPD.copy_response(SlowResp(), out, timeout=1, min_bytes_after_timeout=256 * 1024, min_rate_bps=128 * 1024)
        self.assertLess(time.time() - started, 4)
        out.close()

    def _tmpdir(self) -> str:
        tmp = tempfile.mkdtemp(prefix="mixed-source-")
        self.addCleanup(lambda: __import__("shutil").rmtree(tmp, ignore_errors=True))
        return tmp

    def _serve(self, payloads: dict, hang_paths=None):
        hits = []

        class Handler(_Handler):
            pass

        Handler.hits = hits
        Handler.payloads = payloads
        Handler.hang_paths = set(hang_paths or [])
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.shutdown)
        host, port = server.server_address
        return hits, f"http://{host}:{port}/"


if __name__ == "__main__":
    unittest.main(verbosity=2)
