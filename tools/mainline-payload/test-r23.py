#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Host tests of the R23 tools: contentmanifest.py (the format, the exclusion
list, the forbidden search, the difference) and bundle.py (repo, make, check,
profiles, the refusals). No container, no root, no network.

  test-r23.py                 run the tests
  test-r23.py --write-vectors write r23/testvectors.json (the shared vectors
                              of the content manifest for the Go side,
                              uc-pxx-installer internal/clone)

The vectors file is checked too: the tests fail when it is not what this code
makes. Standard library only. Run with python3 -I.
"""
import base64
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bundle  # noqa: E402
import contentmanifest as cm  # noqa: E402

N = F = 0


def ok(msg):
    global N
    N += 1
    print("  ok: " + msg)


def bad(msg):
    global F
    F += 1
    print("  FAIL: " + msg)


def eq(got, want, msg):
    if got == want:
        ok(msg)
    else:
        bad("%s (got %r, want %r)" % (msg, got, want))


def refuses(fn, msg, *a):
    try:
        fn(*a)
    except (cm.Refuse, bundle.Refuse) as e:
        ok("%s (%s)" % (msg, str(e)[:90]))
        return
    bad(msg + ": no refusal")


EXCL = os.path.join(HERE, "r23", "content-exclude.txt")
DELTA = os.path.join(HERE, "r23", "clone-delta.json")
VECTORS = os.path.join(HERE, "r23", "testvectors.json")
# the Go gate's ExcludeSHA256 and DeltaPin (uc-pxx-installer internal/clone, the
# draft of 2026-11-15); the files here must be byte-identical with the Go side
GO_EXCLUDE_SHA256 = "ddb397d8dedbd86b3c0cd9d596dfcbad1c6479b60866b543ebeca56142e3d1cc"
GO_DELTA_PIN = "d3044ca39279c866d81543edf70d9d80e8a3220ac41df84ce7d71fbca44a556d"


# ---- a virtual tree (the shared vectors) -------------------------------------

def h(b):
    return b.hex()


def vtree():
    """(path bytes, type, mode, uid, gid, content or target bytes, major, minor)"""
    d, f, l = "d", "f", "l"
    return [
        (b"/", d, 0o755, 0, 0, None),
        (b"/bin", d, 0o755, 0, 0, None),
        (b"/bin/busybox", f, 0o755, 0, 0, b"\x7fELF busybox"),
        (b"/bin/sh", l, 0o777, 0, 0, b"/bin/busybox"),
        (b"/bin/su", f, 0o4755, 0, 0, b"su"),
        (b"/data", d, 0o755, 0, 0, None),
        (b"/data/tsx", d, 0o700, 0, 0, None),
        (b"/data/tsx/panel.conf", f, 0o600, 0, 0, b"SSH=1\n"),
        (b"/dev", d, 0o755, 0, 0, None),
        (b"/dev/null", "c", 0o666, 0, 0, None, 1, 3),
        (b"/etc", d, 0o755, 0, 0, None),
        (b"/etc/a b", f, 0o644, 0, 0, b""),
        (b"/etc/a-b", f, 0o644, 0, 0, b"x"),
        (b"/etc/a", d, 0o755, 0, 0, None),
        (b"/etc/a/b", f, 0o644, 0, 0, b"y"),
        (b"/etc/back\\slash\xff\x7f", f, 0o644, 0, 0, b"z"),
        (b"/etc/apk", d, 0o755, 0, 0, None),
        (b"/etc/apk/repositories", f, 0o644, 0, 0, b"https://x/v3.24/main\n"),
        (b"/etc/apk/world", f, 0o644, 0, 0, b"busybox\n"),
        (b"/etc/hostname", f, 0o644, 0, 0, b"tsx-kiosk\n"),
        (b"/etc/hosts", f, 0o644, 0, 0, b"127.0.0.1 localhost\n"),
        (b"/etc/machine-id", f, 0o444, 0, 0, b"0123\n"),
        (b"/etc/runlevels", d, 0o755, 0, 0, None),
        (b"/etc/runlevels/default", d, 0o755, 0, 0, None),
        (b"/etc/runlevels/default/kiosk", l, 0o777, 0, 0, b"/etc/init.d/kiosk"),
        (b"/etc/runlevels/default/sshd", l, 0o777, 0, 0, b"/etc/init.d/sshd"),
        (b"/etc/shadow", f, 0o640, 0, 42, b"root:*:20000:0:::::\n"),
        (b"/etc/shadow-", f, 0o640, 0, 42, b"root:*:19000:0:::::\n"),
        (b"/etc/ssh", d, 0o755, 0, 0, None),
        (b"/etc/ssh/ssh_host_ed25519_key", f, 0o600, 0, 0, b"KEY"),
        (b"/etc/ssh/sshd_config", f, 0o644, 0, 0, b"PermitRootLogin yes\n"),
        (b"/etc/tsx", d, 0o755, 0, 0, None),
        (b"/etc/tsx/link with space", l, 0o777, 0, 0, b"../a b\\c"),
        (b"/lost+found", d, 0o700, 0, 0, None),
        (b"/proc", d, 0o555, 0, 0, None),
        (b"/root", d, 0o700, 0, 0, None),
        (b"/root/.ssh", d, 0o700, 0, 0, None),
        (b"/run", d, 0o755, 0, 0, None),
        (b"/run/x.pid", f, 0o644, 0, 0, b"1\n"),
        (b"/srv", d, 0o755, 0, 0, None),
        (b"/srv/fifo", "p", 0o600, 0, 0, None),
        (b"/srv/sock", "s", 0o755, 0, 0, None),
        (b"/srv/sda", "b", 0o660, 0, 6, None, 8, 0),
        (b"/sys", d, 0o555, 0, 0, None),
        (b"/tmp", d, 0o1777, 0, 0, None),
        (b"/tmp/t", f, 0o644, 0, 0, b"t"),
        (b"/usr", d, 0o755, 0, 0, None),
        (b"/usr/lib", d, 0o755, 0, 0, None),
        (b"/usr/lib/python3.12", d, 0o755, 0, 0, None),
        (b"/usr/lib/python3.12/__pycache__", d, 0o755, 0, 0, None),
        (b"/usr/lib/python3.12/__pycache__/os.cpython-312.pyc", f, 0o644, 0, 0, b"pyc"),
        (b"/usr/lib/python3.12/os.py", f, 0o644, 0, 0, b"import sys\n"),
        (b"/usr/share", d, 0o755, 0, 0, None),
        (b"/usr/share/uc-pxx-provision", d, 0o755, 0, 0, None),
        (b"/usr/share/uc-pxx-provision/profile.sh", f, 0o755, 0, 0, b"#!/bin/sh\n"),
        (b"/usr/share/uc-pxx-provision/profiles.json", f, 0o644, 0, 0, b"{}\n"),
        (b"/var", d, 0o755, 0, 0, None),
        (b"/var/cache", d, 0o755, 0, 0, None),
        (b"/var/cache/fontconfig", d, 0o755, 0, 0, None),
        (b"/var/cache/fontconfig/x-le64.cache-9", f, 0o644, 0, 0, b"cache"),
        (b"/var/lib", d, 0o755, 0, 0, None),
        (b"/var/lib/chrony", d, 0o750, 102, 103, None),
        (b"/var/lib/kiosk", d, 0o755, 1000, 1000, None),
        (b"/var/lib/tsx", d, 0o755, 0, 0, None),
        (b"/var/lib/tsx/autoupdate", d, 0o755, 0, 0, None),
        (b"/var/lib/tsx/autoupdate/fields", f, 0o644, 0, 0, b"mode=manual\n"),
        (b"/var/lib/tsxfoo", d, 0o755, 0, 0, None),
        (b"/var/log", d, 0o755, 0, 0, None),
        (b"/var/log/apk.log", f, 0o644, 0, 0, b"Running `apk add` at 2026\n"),
    ]


class VSource:
    def __init__(self, entries):
        self.e = {}
        for t in entries:
            p, k, mode, uid, gid, data = t[:6]
            mj, mn = (t[6], t[7]) if len(t) > 6 else (0, 0)
            self.e[p] = (k, mode, uid, gid, data, mj, mn)

    def lstat(self, p):
        k, mode, uid, gid, data, mj, mn = self.e[p]
        return k, mode, uid, gid, (len(data) if k == "f" else 0), mj, mn, 1

    def readdir(self, p):
        pre = p.rstrip(b"/") + b"/"
        return [q[len(pre):] for q in self.e if q.startswith(pre) and b"/" not in q[len(pre):] and q != p]

    def readlink(self, p):
        return self.e[p][4]

    def hash(self, p):
        data = self.e[p][4]
        return len(data), hashlib.sha256(data).hexdigest()


def vectors():
    rules, sha = cm.read_rules(EXCL)
    x = cm.Excluder(rules)
    tree = vtree()
    man, n = cm.build(VSource(tree), x)
    dec = []
    for t in tree:
        dec.append([h(t[0]), t[0] != b"/" and x.excluded(t[0]), x.kept_below(t[0])])
    for p in (b"/var/lib/tsx", b"/var/lib/tsxfoo/x", b"/etc/ssh/ssh_host_", b"/etc/sshx", b"/a/__pycache__/b",
              b"/a/__pycache__x", b"/dev", b"/devx", b"/data/x", b"/usr/share/uc-pxx-provision/profiles.json.x"):
        dec.append([h(p), x.excluded(p), x.kept_below(p)])
    vt = []
    for t in tree:
        e = {"path_hex": h(t[0]), "type": t[1], "mode": "%04o" % t[2], "uid": t[3], "gid": t[4]}
        if t[1] in "fl":
            e["data_hex"] = h(t[5])
        if t[1] in "cb":
            e["major"], e["minor"] = t[6], t[7]
        vt.append(e)
    fbad = (b"/var/log/apk.log", b"Running `apk add` at 2026\n")
    return {
        "format": cm.FORMAT,
        "note": ("Shared vectors of uc-pxx-linux tools/mainline-payload/contentmanifest.py and uc-pxx-installer "
                 "internal/clone/manifest.go. tree: a virtual tree (path_hex: the path bytes; data_hex: the content "
                 "of a regular file or the target of a link; mode: 4 octal digits). manifest: the manifest of the "
                 "tree with the exclusion list exclude (Options{}); excluded: [path_hex, Excluded(p), keptBelow(p)]. "
                 "forbidden: Build with Options{Full: true, Forbidden: [the pin]} must fail on that path, which is "
                 "under an excluded folder."),
        "exclude": rules,
        "exclude_sha256": sha,
        "tree": vt,
        "excluded": dec,
        "manifest": man.decode("ascii"),
        "manifest_sha256": hashlib.sha256(man).hexdigest(),
        "entries": n,
        "forbidden": {"what": "test", "size": len(fbad[1]), "sha256": hashlib.sha256(fbad[1]).hexdigest(),
                      "path_hex": h(fbad[0])},
    }


def test_manifest():
    print("== contentmanifest: the format and the exclusion list ==")
    rules, sha = cm.read_rules(EXCL)
    eq(sha, GO_EXCLUDE_SHA256, "the exclusion list is the Go gate's (ExcludeSHA256)")
    with open(DELTA, "rb") as f:
        eq(hashlib.sha256(f.read()).hexdigest(), GO_DELTA_PIN, "clone-delta.json is the Go gate's (DeltaPin)")
    v = vectors()
    man = v["manifest"]
    want = [
        "/ d 0755 0 0 0 -",
        "/bin d 0755 0 0 0 -",
        "/bin/busybox f 0755 0 0 12 " + hashlib.sha256(b"\x7fELF busybox").hexdigest(),
        "/bin/sh l 0777 0 0 12 /bin/busybox",
        "/bin/su f 4755 0 0 2 " + hashlib.sha256(b"su").hexdigest(),
        "/etc d 0755 0 0 0 -",
        "/etc/a d 0755 0 0 0 -",
        "/etc/a\\x20b f 0644 0 0 0 " + hashlib.sha256(b"").hexdigest(),
        "/etc/a-b f 0644 0 0 1 " + hashlib.sha256(b"x").hexdigest(),
        "/etc/a/b f 0644 0 0 1 " + hashlib.sha256(b"y").hexdigest(),
        "/etc/apk d 0755 0 0 0 -",
        "/etc/apk/world f 0644 0 0 8 " + hashlib.sha256(b"busybox\n").hexdigest(),
        "/etc/back\\x5cslash\\xff\\x7f f 0644 0 0 1 " + hashlib.sha256(b"z").hexdigest(),
        "/etc/runlevels d 0755 0 0 0 -",
        "/etc/runlevels/default d 0755 0 0 0 -",
        "/etc/runlevels/default/kiosk l 0777 0 0 17 /etc/init.d/kiosk",
        "/etc/ssh d 0755 0 0 0 -",
        "/etc/ssh/sshd_config f 0644 0 0 20 " + hashlib.sha256(b"PermitRootLogin yes\n").hexdigest(),
        "/etc/tsx d 0755 0 0 0 -",
        "/etc/tsx/link\\x20with\\x20space l 0777 0 0 8 ../a\\x20b\\x5cc",
        "/srv d 0755 0 0 0 -",
        "/srv/fifo p 0600 0 0 0 -",
        "/srv/sda b 0660 0 6 0 8:0",
        "/srv/sock s 0755 0 0 0 -",
        "/usr d 0755 0 0 0 -",
        "/usr/lib d 0755 0 0 0 -",
        "/usr/lib/python3.12 d 0755 0 0 0 -",
        "/usr/lib/python3.12/os.py f 0644 0 0 11 " + hashlib.sha256(b"import sys\n").hexdigest(),
        "/usr/share d 0755 0 0 0 -",
        "/usr/share/uc-pxx-provision d 0755 0 0 0 -",
        "/usr/share/uc-pxx-provision/profile.sh f 0755 0 0 10 " + hashlib.sha256(b"#!/bin/sh\n").hexdigest(),
        "/var d 0755 0 0 0 -",
        "/var/lib d 0755 0 0 0 -",
        "/var/lib/tsx d 0755 0 0 0 -",
    ]
    got = man.splitlines()
    eq(got, want, "the manifest of the virtual tree: lines, order by the unescaped bytes, escapes, exclusions")
    with open(VECTORS) as f:
        eq(json.load(f), v, "r23/testvectors.json is what this code makes (test-r23.py --write-vectors)")
    x = cm.Excluder(rules)
    refuses(cm.build, "the forbidden search finds a pinned file under an excluded folder (full)",
            VSource(vtree()), x, True, [("test", v["forbidden"]["size"], v["forbidden"]["sha256"])])
    m2, _ = cm.build(VSource(vtree()), x, False, [("test", v["forbidden"]["size"], v["forbidden"]["sha256"])])
    eq(m2.decode(), man, "the forbidden search without --full does not enter the excluded /var/log (as Go)")
    for r in ("var/log", "/var//log", "/var/log/", "**/a/b", "/x/*y*", "!/", "/"):
        refuses(cm.Excluder, "a bad rule %r" % r, [r])


def test_installer_vector():
    print("== contentmanifest: the installer's vector (R23-FORMATS §1.2, TestManifestFormat) ==")
    d = "d"
    tree = [(b"/", d, 0o755, 0, 0, None), (b"/etc", d, 0o755, 0, 0, None),
            (b"/etc/tsx", d, 0o755, 0, 0, None), (b"/etc/tsx/build-id", "f", 0o644, 0, 0, b"0.2.0-rc10-kiosk-ha\n"),
            (b"/etc/sh link", "l", 0o777, 0, 0, b"../usr/bin/sh x"), (b"/etc/fifo", "p", 0o600, 0, 0, None),
            (b"/usr", d, 0o755, 0, 0, None), (b"/usr/bin", d, 0o755, 0, 0, None),
            (b"/usr/bin/su", "f", 0o4755, 0, 0, b"su"), (b"/usr/bin/su2", "f", 0o4755, 0, 0, b"su"),
            (b"/usr/lib", d, 0o755, 0, 0, None), (b"/usr/lib/py", d, 0o755, 0, 0, None),
            (b"/usr/lib/py/__pycache__", d, 0o755, 0, 0, None),
            (b"/usr/lib/py/__pycache__/a.pyc", "f", 0o644, 0, 0, b"pyc"),
            (b"/var", d, 0o755, 0, 0, None), (b"/var/log", d, 0o755, 0, 0, None),
            (b"/var/log/messages", "f", 0o644, 0, 0, b"boot\n"), (b"/var/lib", d, 0o755, 0, 0, None),
            (b"/var/lib/tsx", d, 0o755, 0, 0, None), (b"/var/lib/tsx/autoupdate", d, 0o755, 0, 0, None),
            (b"/var/lib/other", d, 0o755, 0, 0, None)]
    x = cm.Excluder(["/var/log", "/var/lib/*", "!/var/lib/tsx", "**/__pycache__", "/etc/ss*"])
    man, n = cm.build(VSource(tree), x)
    eq((hashlib.sha256(man).hexdigest(), n), ("c1aec0a4bdacf8ed443d49ec4e5bc23f69feb12e520c961734a0652f595174c9", 15),
       "the installer's TestManifestFormat vector: the same manifest (sha256 c1aec0a4..., 15 lines)")


def mktree(top):
    def w(p, data=b"", mode=0o644):
        os.makedirs(os.path.dirname(top + p), exist_ok=True)
        with open(top + p, "wb") as f:
            f.write(data)
        os.chmod(top + p, mode)
    for d in ("/usr/libexec/uc-pxx-step2", "/var/log/sub", "/var/lib/tsx/autoupdate/holds", "/var/lib/uc-pxx-provision",
              "/data/tsx", "/etc/tsx", "/etc/init.d", "/etc/conf.d", "/etc/runlevels/default", "/usr/share/uc-pxx-provision"):
        os.makedirs(top + d, exist_ok=True)
    w("/usr/libexec/uc-pxx-step2/uc-pxx-step2", b"step2", 0o700)
    w("/etc/init.d/uc-pxx-step2", b"#!/sbin/openrc-run\n", 0o755)
    w("/etc/tsx/build-id", b"0.2.0-rc10-base\n")
    w("/etc/tsx/step2-bootctl-inst", b"STEP-2 BUILD\n")
    w("/var/log/apk.log", b"log")
    w("/var/log/sub/x", b"x")
    w("/var/lib/tsx/autoupdate/fields", b"f")
    w("/data/tsx/panel.conf", b"SSH=1\n", 0o600)
    w("/usr/share/uc-pxx-provision/profiles.json", b"{}")
    os.symlink("/etc/init.d/uc-pxx-step2", top + "/etc/runlevels/default/uc-pxx-step2")
    os.chmod(top + "/data", 0o711)


def test_delta():
    print("== contentmanifest: the difference (clone-delta.json) ==")
    with open(DELTA, "rb") as f:
        d = cm.parse_delta(f.read())
    if os.getuid() != 0:
        # a test as a user: the owner of the emptied and written entries is the user
        for e in d["empty"] + d["write"]:
            e["uid"], e["gid"] = os.getuid(), os.getgid()
    t = tempfile.mkdtemp()
    try:
        mktree(t)
        cm.apply_delta(d, t, "0.2.0-rc10-kiosk-ha")
        for p in ("/usr/libexec/uc-pxx-step2", "/etc/init.d/uc-pxx-step2", "/etc/runlevels/default/uc-pxx-step2",
                  "/etc/tsx/step2-bootctl-inst", "/var/lib/uc-pxx-provision", "/usr/share/uc-pxx-provision"):
            eq(os.path.lexists(t + p), False, "removed %s" % p)
        eq(sorted(os.listdir(t + "/var/log")), [], "/var/log is empty")
        eq(sorted(os.listdir(t + "/data")), [], "/data is emptied")
        eq("%o" % (os.lstat(t + "/data").st_mode & 0o7777), "755", "/data is 0755")
        eq(sorted(os.listdir(t + "/var/lib/tsx")), [], "/var/lib/tsx is emptied")
        with open(t + "/etc/tsx/build-id", "rb") as f:
            eq(f.read(), b"0.2.0-rc10-kiosk-ha\n", "the build id is VERSION and a newline")
        eq("%o" % (os.lstat(t + "/etc/tsx/build-id").st_mode & 0o7777), "644", "the build id is 0644")
        eq(os.path.exists(t + "/etc/tsx/build-id.clone-tmp"), False, "no temporary file stays")
        cm.apply_delta(d, t, "0.2.0-rc10-kiosk-ha")
        ok("the difference applies twice (idempotent)")
    finally:
        shutil.rmtree(t)
    t = tempfile.mkdtemp()
    try:
        mktree(t)
        shutil.rmtree(t + "/var/log")
        os.symlink("/tmp", t + "/var/log")
        refuses(cm.apply_delta, "remove_children refuses a link (/var/log -> /tmp)", d, t, "v")
    finally:
        shutil.rmtree(t)
    t = tempfile.mkdtemp()
    try:
        mktree(t)
        shutil.rmtree(t + "/var/lib/uc-pxx-provision")
        os.makedirs(t + "/elsewhere")
        os.symlink(t + "/elsewhere", t + "/var/lib/x")
        os.rename(t + "/var/lib", t + "/varlib")
        os.symlink(t + "/varlib", t + "/var/lib")
        refuses(cm.apply_delta, "a link as a parent folder (/var/lib -> elsewhere) is refused", d, t, "v")
    finally:
        shutil.rmtree(t)
    for bad_doc in (b'{"schema": 2}', b'{"schema": 1, "remove": ["/a", "/a/b"]}', b'{"schema": 1, "x": 1}',
                    b'{"schema": 1, "remove": ["a"]}', b'{"schema": 1, "write": [{"path": "/a", "mode": "644", "from": "build-id"}]}',
                    b'{"schema": 1, "write": [{"path": "/a", "mode": "0644", "from": "file"}]}'):
        refuses(cm.parse_delta, "a bad difference %s" % bad_doc.decode(), bad_doc)


# ---- bundle.py ------------------------------------------------------------------

def gz(b):
    o = io.BytesIO()
    with __import__("gzip").GzipFile(fileobj=o, mode="wb", mtime=0) as g:
        g.write(b)
    return o.getvalue()


def tar_of(files, end=True):
    o = io.BytesIO()
    with tarfile.open(fileobj=o, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for n, b in files:
            ti = tarfile.TarInfo(n)
            ti.size = len(b)
            tf.addfile(ti, io.BytesIO(b))
    v = o.getvalue()
    if not end:
        v = v.rstrip(b"\0")
        v += b"\0" * (-len(v) % 512)
    return v


def mkapk(path, name, ver, scripts=()):
    ctl = tar_of([(".PKGINFO", ("pkgname = %s\npkgver = %s\ntriggers = /usr/share/x/*\n" % (name, ver)).encode())]
                 + [(s, b"#!/bin/sh\n") for s in scripts], end=False)
    sig = gz(tar_of([(".SIGN.RSA.test.rsa.pub", b"sig")], end=False))
    c = gz(ctl)
    data = gz(tar_of([("usr/bin/" + name, b"bin")]))
    with open(path, "wb") as f:
        f.write(sig + c + data)
    return "Q1" + base64.b64encode(hashlib.sha1(c).digest()).decode(), os.path.getsize(path)


def mkindex(path, pkgs):
    text = "".join("C:%s\nP:%s\nV:%s\nA:aarch64\nS:%d\n\n" % (c, n, v, s) for n, v, c, s in pkgs).encode()
    idx = gz(tar_of([("DESCRIPTION", b"t"), ("APKINDEX", text)]))
    sig = gz(tar_of([(".SIGN.RSA.test.rsa.pub", b"sig")], end=False))
    with open(path, "wb") as f:
        f.write(sig + idx)


def run(*a):
    p = subprocess.run([sys.executable, "-I"] + list(a), capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def test_bundle():
    print("== bundle.py ==")
    t = tempfile.mkdtemp()
    B = os.path.join(HERE, "bundle.py")
    try:
        al, ts = t + "/alpine", t + "/tsx"
        repos = {"main": (al, [("libfoo", "1.0-r0", ()), ("chromium", "142.0-r1", (".post-install",))]),
                 "community": (al, [("sway", "1.10-r0", (".pre-install", ".trigger"))]),
                 "common": (ts, [("tsx-kiosk", "0.3.13-r0", (".pre-install",))]),
                 "uc-pxx": (ts, [("uc-pxx-kiosk", "0.1.0-r1", ())])}
        for repo, (top, pk) in repos.items():
            d = "%s/v3.24/%s/aarch64" % (top, repo)
            os.makedirs(d)
            lines = []
            for n, v, sc in pk:
                c, s = mkapk("%s/%s-%s.apk" % (d, n, v), n, v, sc)
                lines.append((n, v, c, s))
            mkindex(d + "/APKINDEX.tar.gz", lines)
        with open(t + "/sim.log", "w") as f:
            f.write("(1/4) Installing libfoo (1.0-r0)\n(2/4) Installing chromium (142.0-r1)\n"
                    "(3/4) Installing sway (1.10-r0)\n( 4/4) Installing tsx-kiosk (0.3.13-r0)\n"
                    "Executing busybox-1.37.0-r0.trigger\nOK: 5 MiB in 4 packages\n")
        rc, out = run(B, "simulate-list", t + "/sim.log", t + "/list")
        eq(rc, 0, "simulate-list " + out.strip())
        with open(t + "/list", "a") as f:
            f.write("uc-pxx-kiosk 0.1.0-r1\n")
        rc, out = run(B, "repo", "--alpine-dir", al, "--tsx-dir", ts, "--branch", "v3.24", "--list", t + "/list",
                      "--out", t + "/repo")
        eq(rc, 0, "repo: " + out.strip())
        eq(open(t + "/repo/repositories").read(), "v3.24/main\nv3.24/community\nv3.24/common\nv3.24/uc-pxx\n",
           "repo: the repositories file")
        with open(t + "/before", "w") as f:
            f.write("P:busybox\nV:1.37.0-r0\n\nP:musl\nV:1.2.5-r10\n\n")
        with open(t + "/after", "w") as f:
            f.write("P:busybox\nV:1.37.0-r0\n\nP:musl\nV:1.2.5-r10\n\nP:libfoo\nV:1.0-r0\n\nP:chromium\nV:142.0-r1\n\n"
                    "P:sway\nV:1.10-r0\n\nP:tsx-kiosk\nV:0.3.13-r0\n\nP:uc-pxx-kiosk\nV:0.1.0-r1\n\n")
        with open(t + "/world", "w") as f:
            f.write("busybox\nchromium\nuc-pxx-kiosk\n")
        with open(t + "/add", "w") as f:
            f.write("chromium\nuc-pxx-kiosk\n")
        mk = ["make", "--repo", t + "/repo", "--list", t + "/list", "--before", t + "/before", "--after", t + "/after",
              "--world", t + "/world", "--add", t + "/add", "--profile", "kiosk", "--release", "0.2.0-rc10"]
        rc, out = run(B, *(mk + ["--out", t + "/b1.tar"]))
        eq(rc, 0, "make: " + out.strip().replace("\n", "; "))
        rc, out = run(B, *(mk + ["--out", t + "/b2.tar"]))
        eq(open(t + "/b1.tar", "rb").read() == open(t + "/b2.tar", "rb").read(), True, "make twice: the same bytes")
        rc, out = run(B, "check", t + "/b1.tar")
        eq(rc, 0, "check: " + out.strip())
        with tarfile.open(t + "/b1.tar") as tf:
            names = tf.getnames()
            mem = tf.getmembers()
            doc = json.loads(tf.extractfile("bundle.json").read())
        eq(names[:5], ["bundle.json", "v3.24/main/aarch64/APKINDEX.tar.gz", "v3.24/community/aarch64/APKINDEX.tar.gz",
                       "v3.24/common/aarch64/APKINDEX.tar.gz", "v3.24/uc-pxx/aarch64/APKINDEX.tar.gz"],
           "the member order: bundle.json, then the four indexes")
        eq(names[5:], sorted(names[5:]), "then the .apk files sorted by path")
        eq({(m.mode, m.uid, m.gid, m.mtime, m.uname, m.gname, m.type) for m in mem},
           {(0o644, 0, 0, 0, "", "", tarfile.REGTYPE)}, "every member: 0644, 0:0, mtime 0, no names, a file")
        eq(doc["base"], ["busybox=1.37.0-r0", "musl=1.2.5-r10"], "bundle.json: the base set")
        eq([p["name"] for p in doc["packages"] if p["scripts"]], ["tsx-kiosk", "sway", "chromium"],
           "bundle.json: the packages with scripts (sorted by path)")
        eq([p["scripts"] for p in doc["packages"] if p["name"] == "sway"], [[".pre-install", ".trigger"]],
           "bundle.json: the scripts of a package")
        eq(doc["packages"][0]["triggers"], ["/usr/share/x/*"], "bundle.json: the triggers")
        eq(doc["lva"], None, "kiosk: no lva.tar")
        # refusals
        with open(t + "/after2", "w") as f:
            f.write(open(t + "/after").read().replace("P:musl\nV:1.2.5-r10", "P:musl\nV:1.2.5-r11"))
        rc, out = run(B, *(mk[:7] + ["--after", t + "/after2"] + mk[9:] + ["--out", t + "/x.tar"]))
        eq((rc, "changed the base package" in out), (1, True), "make refuses a changed base package")
        with open(t + "/after3", "w") as f:
            f.write(open(t + "/after").read() + "P:extra\nV:1-r0\n\n")
        rc, out = run(B, *(mk[:7] + ["--after", t + "/after3"] + mk[9:] + ["--out", t + "/x.tar"]))
        eq((rc, "not the base plus the list" in out), (1, True), "make refuses a package that is not in the list")
        rc, out = run(B, *(mk + ["--lva", t + "/list", "--out", t + "/x.tar"]))
        eq(rc, 1, "make refuses lva.tar in the kiosk bundle")
        shutil.copy(al + "/v3.24/main/aarch64/libfoo-1.0-r0.apk", t + "/libfoo.apk")
        with open(al + "/v3.24/main/aarch64/libfoo-1.0-r0.apk", "r+b") as f:
            f.seek(-3, 2)
            f.write(b"XYZ")
        rc, out = run(B, "repo", "--alpine-dir", al, "--tsx-dir", ts, "--branch", "v3.24", "--list", t + "/list",
                      "--out", t + "/repo2")
        eq(rc, 0, "repo: a changed data part keeps the control part (the signature covers it on the unit)")
        mkapk(al + "/v3.24/main/aarch64/libfoo-1.0-r0.apk", "libfoo", "1.0-r0", (".post-install",))
        rc, out = run(B, "repo", "--alpine-dir", al, "--tsx-dir", ts, "--branch", "v3.24", "--list", t + "/list",
                      "--out", t + "/repo3")
        eq((rc, "control part" in out or "bytes" in out), (1, True), "repo refuses a file that is not the index's")
        shutil.copy(t + "/libfoo.apk", al + "/v3.24/main/aarch64/libfoo-1.0-r0.apk")
        shutil.copy(al + "/v3.24/main/aarch64/libfoo-1.0-r0.apk", ts + "/v3.24/common/aarch64/libfoo-1.0-r0.apk")
        mkindex(ts + "/v3.24/common/aarch64/APKINDEX.tar.gz",
                [("tsx-kiosk", "0.3.13-r0", mkapk(ts + "/v3.24/common/aarch64/tsx-kiosk-0.3.13-r0.apk", "tsx-kiosk",
                                                  "0.3.13-r0", (".pre-install",))[0],
                  os.path.getsize(ts + "/v3.24/common/aarch64/tsx-kiosk-0.3.13-r0.apk")),
                 ("libfoo", "1.0-r0", bundle.control_info(t + "/libfoo.apk")[0]["Q1"], os.path.getsize(t + "/libfoo.apk"))])
        rc, out = run(B, "repo", "--alpine-dir", al, "--tsx-dir", ts, "--branch", "v3.24", "--list", t + "/list",
                      "--out", t + "/repo4")
        eq((rc, "exactly one" in out), (1, True), "repo refuses a package that is in two indexes")
        # a cut or changed bundle, as the unit reads it
        b = open(t + "/b1.tar", "rb").read()
        with open(t + "/cut.tar", "wb") as f:
            f.write(b[:len(b) // 2])
        rc, out = run(B, "check", t + "/cut.tar")
        eq(rc, 1, "check refuses a cut bundle")
        i = b.index(b"v3.24/uc-pxx/aarch64/uc-pxx-kiosk")
        bb = bytearray(b)
        bb[i + 512 + 600] ^= 1
        with open(t + "/flip.tar", "wb") as f:
            f.write(bytes(bb))
        rc, out = run(B, "check", t + "/flip.tar")
        eq(rc, 1, "check refuses a changed member")
        rc, out = run(B, "check", t + "/b1.tar", "--sha256", "0" * 64)
        eq(rc, 1, "check refuses another pin")
        # profiles.json
        for n in ("console", "kiosk"):
            open(t + "/ref-" + n, "w").close()
        s = "a" * 64
        rc, out = run(B, "profiles", "--release", "0.2.0-rc10", "--base-version", "0.2.0-rc10-base", "--alpine", "v3.24",
                      "--exclude-sha256", GO_EXCLUDE_SHA256, "--delta-sha256", GO_DELTA_PIN,
                      "--url", "http://mirror.example:8137/r23/", "--profile", "console:console:%s:%s:%s" % (s, s, s),
                      "--profile", "kiosk:kiosk:%s:%s:%s:%s:%s" % (s, s, s, t + "/b1.tar", t + "/b1.tar.json"),
                      "--out", t + "/profiles.json")
        eq(rc, 0, "profiles: " + out.strip())
        p = json.load(open(t + "/profiles.json"))
        eq((p["profiles"]["console"]["bundle"], p["profiles"]["kiosk"]["bundle"]["file"], p["profiles"]["kiosk"]["packages"],
            p["profiles"]["kiosk"]["index_sha256"], p["profiles"]["kiosk"]["build_id"]),
           (None, "b1.tar", 5, hashlib.sha256(open(t + "/b1.tar.json", "rb").read()).hexdigest(), "0.2.0-rc10-kiosk"),
           "profiles.json: the console and kiosk entries")
        rc, out = run(B, "profiles", "--release", "0.2.0-rc10", "--base-version", "b", "--alpine", "v3.24",
                      "--exclude-sha256", s, "--delta-sha256", s, "--url", "ftp://x/", "--profile",
                      "console:console:%s:%s:%s" % (s, s, s), "--out", t + "/p2.json")
        eq(rc, 1, "profiles refuses a URL that is not http(s)")
        rc, out = run(B, "profiles", "--release", "0.2.0-rc10", "--base-version", "b", "--alpine", "v3.24",
                      "--exclude-sha256", s, "--delta-sha256", s, "--url", "https://x/", "--profile",
                      "kiosk:kiosk:%s:%s:%s" % (s, s, s), "--out", t + "/p2.json")
        eq(rc, 1, "profiles refuses kiosk without its bundle")
    finally:
        shutil.rmtree(t)


def main():
    if sys.argv[1:] == ["--write-vectors"]:
        with open(VECTORS, "w") as f:
            json.dump(vectors(), f, indent=1, sort_keys=True)
            f.write("\n")
        print("wrote", VECTORS)
        return 0
    test_manifest()
    test_installer_vector()
    test_delta()
    test_bundle()
    print("%d ok, %d failed" % (N, F))
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main())
