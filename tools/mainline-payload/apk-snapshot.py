#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The Alpine package snapshot of a reproducible payload build.

  apk-snapshot.py serve DIR UPSTREAM --bind ADDR --port N
  apk-snapshot.py digest DIR

serve: a small HTTP server for the priming build (build.sh --prime). Each GET
of a path under /alpine/ answers from DIR when DIR has the file. Otherwise the
server gets the file from UPSTREAM (for example
https://dl-cdn.alpinelinux.org/alpine), keeps it in DIR and answers with it. So
DIR ends up with every APKINDEX.tar.gz and every package file that the build
asked for, in the layout of the mirror (DIR/v3.24/main/aarch64/...). The
first copy of a file stays: a later APKINDEX of the mirror never replaces it.
The offline builds then read DIR as a local repository (MIRROR=/mirror) with
no network. The server writes only below DIR. It refuses a path with "..",
an absolute part or a byte outside [A-Za-z0-9._+~/-].

digest: one sha256 over the sorted list "sha256  relative-path" of every file
below DIR (symbolic links are refused). The inputs file of the build records it.

Standard library only. Run with python3 -I.
"""
import hashlib
import http.server
import os
import re
import shutil
import sys
import tempfile
import threading
import urllib.request

SAFE = re.compile(r"^[A-Za-z0-9._+~/-]+$")


def digest(top):
    lines = []
    for root, dirs, files in os.walk(top):
        dirs.sort()
        for d in dirs:
            if os.path.islink(os.path.join(root, d)):
                sys.exit("apk-snapshot: %s is a symbolic link" % os.path.join(root, d))
        for f in sorted(files):
            p = os.path.join(root, f)
            if os.path.islink(p) or not os.path.isfile(p):
                sys.exit("apk-snapshot: %s is not a regular file" % p)
            h = hashlib.sha256()
            with open(p, "rb") as fh:
                for b in iter(lambda: fh.read(1 << 20), b""):
                    h.update(b)
            lines.append("%s  %s\n" % (h.hexdigest(), os.path.relpath(p, top)))
    lines.sort(key=lambda l: l[66:])
    return hashlib.sha256("".join(lines).encode()).hexdigest(), len(lines)


class Handler(http.server.BaseHTTPRequestHandler):
    top = None
    upstream = None
    lock = threading.Lock()

    def log_message(self, fmt, *args):
        sys.stderr.write("apk-snapshot: " + (fmt % args) + "\n")

    def local(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith("/alpine/"):
            return None, None
        rel = path[len("/alpine/"):]
        if not rel or not SAFE.match(rel) or any(p in ("", ".", "..") for p in rel.split("/")):
            return None, None
        return rel, os.path.join(self.top, rel)

    def fetch(self, rel, dest):
        with self.lock:
            if os.path.isfile(dest):
                return True
            url = self.upstream.rstrip("/") + "/" + rel
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(dest), prefix=".part-")
            try:
                with os.fdopen(fd, "wb") as out, urllib.request.urlopen(url, timeout=120) as r:
                    shutil.copyfileobj(r, out)
                os.replace(tmp, dest)
                self.log_message("kept %s", rel)
                return True
            except Exception as e:  # the client gets a 404 and apk reports it
                self.log_message("cannot get %s: %s", url, e)
                if os.path.exists(tmp):
                    os.unlink(tmp)
                return False

    def answer(self, body):
        rel, dest = self.local()
        if rel is None:
            self.send_error(404)
            return
        if not os.path.isfile(dest) and not self.fetch(rel, dest):
            self.send_error(404)
            return
        size = os.path.getsize(dest)
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        if body:
            with open(dest, "rb") as fh:
                shutil.copyfileobj(fh, self.wfile)

    def do_GET(self):
        self.answer(True)

    def do_HEAD(self):
        self.answer(False)


def main(argv):
    if len(argv) >= 2 and argv[0] == "digest":
        d, n = digest(argv[1])
        print("%s %d" % (d, n))
        return 0
    if len(argv) == 7 and argv[0] == "serve" and argv[3] == "--bind" and argv[5] == "--port":
        Handler.top = os.path.abspath(argv[1])
        Handler.upstream = argv[2]
        os.makedirs(Handler.top, exist_ok=True)
        srv = http.server.ThreadingHTTPServer((argv[4], int(argv[6])), Handler)
        sys.stderr.write("apk-snapshot: serving %s on %s:%s (upstream %s)\n" % (Handler.top, argv[4], argv[6], argv[2]))
        srv.serve_forever()
        return 0
    sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
