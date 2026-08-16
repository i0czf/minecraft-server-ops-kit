#!/usr/bin/env python3
import argparse
import functools
import os
import posixpath
import socket
import ssl
import sys
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


class SecureUpdateHandler(SimpleHTTPRequestHandler):
    server_version = "TFCRUpdateServer/1.0"

    def __init__(self, *args, token="", kitdir="", **kwargs):
        self.token = token.strip("/")
        # kitdir: public tokenless channel at /kit/ for toolkit self-update files
        # (the kit itself is meant to be public; only flat .zip/.txt basenames are served).
        self.kitdir = kitdir
        super().__init__(*args, **kwargs)

    def _kit_file(self, decoded):
        if not self.kitdir:
            return None
        parts = [part for part in decoded.split("/") if part]
        if len(parts) != 2 or parts[0] != "kit":
            return None
        name = parts[1]
        if name in ("", ".", "..") or os.path.dirname(name):
            return None
        if not (name.endswith(".zip") or name.endswith(".txt")):
            return None
        return os.path.join(self.kitdir, name)

    def list_directory(self, path):
        self.send_error(HTTPStatus.NOT_FOUND, "No directory listing")
        return None

    def do_POST(self):
        self.send_error(HTTPStatus.METHOD_NOT_ALLOWED, "Only GET and HEAD are allowed")

    def do_PUT(self):
        self.send_error(HTTPStatus.METHOD_NOT_ALLOWED, "Only GET and HEAD are allowed")

    def do_DELETE(self):
        self.send_error(HTTPStatus.METHOD_NOT_ALLOWED, "Only GET and HEAD are allowed")

    def translate_path(self, path):
        raw_path = urlsplit(path).path
        decoded = unquote(raw_path)
        kit_file = self._kit_file(decoded)
        if kit_file is not None:
            return kit_file
        parts = [part for part in decoded.split("/") if part]
        if not parts or parts[0] != self.token:
            return "__blocked__"
        safe_parts = []
        for part in parts[1:]:
            if part in ("", ".", "..") or os.path.dirname(part):
                continue
            safe_parts.append(part)
        return os.path.join(self.directory, *safe_parts)

    def send_head(self):
        raw_path = urlsplit(self.path).path
        decoded = unquote(raw_path)
        clean = posixpath.normpath(decoded)
        if "/.." in clean or clean.endswith("/.."):
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return None
        if self._kit_file(clean) is not None:
            return super().send_head()
        expected_prefix = "/" + self.token
        if clean != expected_prefix and not clean.startswith(expected_prefix + "/"):
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return None
        if "/.." in clean or clean.endswith("/.."):
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return None
        return super().send_head()

    # Read the whole file into memory and close the handle immediately instead of
    # streaming from the open handle for the entire (possibly slow) transfer.
    # A long-held handle blocks the publish script from replacing/deleting the file
    # on Windows (2026-07-08: a player download made portable-publish.ps1 abort
    # mid-delete and left the update source half-broken). Files here are small
    # (mods/resourcepacks, tens of MB); cap guards against pathological sizes.
    _BUFFER_CAP = 256 * 1024 * 1024

    def do_GET(self):
        f = self.send_head()
        if f is None:
            return
        try:
            try:
                size = os.fstat(f.fileno()).st_size
            except (OSError, AttributeError, ValueError):
                size = None
            if size is not None and size <= self._BUFFER_CAP:
                data = f.read()
                f.close()
                f = None
                self.wfile.write(data)
            else:
                self.copyfile(f, self.wfile)
        finally:
            if f is not None:
                f.close()

    def end_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, format, *args):
        return

class QuietThreadingHTTPServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        exc_type = sys.exc_info()[0]
        if exc_type in (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, TimeoutError):
            return
        if exc_type is not None and issubclass(exc_type, ssl.SSLError):
            return
        super().handle_error(request, client_address)


class DualStackThreadingHTTPServer(QuietThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()

def main():
    parser = argparse.ArgumentParser(description="Serve TFCR update files behind a secret URL prefix.")
    parser.add_argument("--directory", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--token", required=True)
    parser.add_argument("--certfile", default="", help="PEM cert chain; enables HTTPS when set")
    parser.add_argument("--keyfile", default="", help="PEM private key; defaults to certfile if omitted")
    parser.add_argument("--kitdir", default="", help="serve toolkit self-update files at tokenless /kit/ when set")
    args = parser.parse_args()

    handler = functools.partial(SecureUpdateHandler, directory=args.directory, token=args.token, kitdir=args.kitdir)
    server_class = DualStackThreadingHTTPServer if ":" in args.bind else QuietThreadingHTTPServer
    with server_class((args.bind, args.port), handler) as httpd:
        if args.certfile:
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.load_cert_chain(args.certfile, args.keyfile or None)
            httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()




