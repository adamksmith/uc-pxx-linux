#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The content manifest of a slot tree (DESIGN-R23 §4.6, format
"uc-pxx-content-manifest-1"), and the clone's pinned difference.

  contentmanifest.py build ROOT --exclude FILE [--out FILE] [--full]
                     [--forbid WHAT:SIZE:SHA256 ...] [--onefs]
      List the tree under ROOT (a folder: "/" of the slot) and print
      "SHA256 ENTRIES". --out writes the manifest. --forbid: a regular file
      anywhere in the tree (excluded or not) with that size and sha256 is an
      error (exit 1). --full enters every folder (the forbidden search of A).
      --onefs: an entry on another device than ROOT is an error unless it is
      excluded (a live root).
  contentmanifest.py exclude-sha256 FILE
      The sha256 of the exclusion list (one rule per line), as the Go gate's
      ExcludeSHA256.
  contentmanifest.py apply-delta DELTA ROOT VERSION
      Apply clone-delta.json (schema 1) to the tree under ROOT, in its order:
      remove, remove_children, empty, write. Every "write" entry with from
      "build-id" gets VERSION plus a newline (the bytes of /etc/tsx/build-id
      that mkrootfs.sh writes). No symbolic link is followed.
  contentmanifest.py diff A B [--max N]
      The lines only in A ("- ") and only in B ("+ "), sorted (at most N, 200).

The format (the same as uc-pxx-installer internal/clone/manifest.go):

  PATH TYPE MODE UID GID SIZE DATA\\n

one line per entry that the exclusion list keeps, the root "/" included,
sorted by the bytes of PATH (unescaped), one space between the fields, no
times. PATH is absolute; every byte outside 0x21..0x7e, and "\\", is written
\\xHH (two lowercase hex digits). TYPE: f d l c b p s. MODE: the low 12 bits,
4 octal digits. UID, GID: decimal. SIZE: the bytes of a regular file, the
length of a link's target, else 0. DATA: f the sha256 of the content, l the
target (escaped as PATH), c and b MAJOR:MINOR, else "-". Hard links are
listed once per name. The manifest's sha256 is ref_a / ref_b.

The exclusion list, one rule per line ("#" lines and empty lines are not
rules here; the Go list has none): "/x/y" = /x/y and everything under it;
"/x/y/*" = everything under /x/y (the folder stays); "/x/pre*" = every entry
of /x whose name starts with pre, with everything under it; "**/name" =
every entry whose last component is name, with everything under it;
"!/x/y" = /x/y itself is kept. An entry is left out when a rule matches it,
unless a "!" rule names exactly its path. An excluded folder is not entered
unless --full or a "!" rule names a path under it.

Standard library only. Run with python3 -I.
"""
import errno
import hashlib
import json
import os
import posixpath
import shutil
import stat
import sys

FORMAT = "uc-pxx-content-manifest-1"
MAX_ENTRIES = 400000
MAX_DEPTH = 64


class Refuse(Exception):
    pass


def escape(b):
    out = []
    for c in b:
        if c < 0x21 or c > 0x7E or c == 0x5C:
            out.append("\\x%02x" % c)
        else:
            out.append(chr(c))
    return "".join(out)


def clean_abs(p):
    # Go: strings.HasPrefix(p, "/") && p != "/" && path.Clean(p) == p && no NUL or newline
    return (p.startswith("/") and p != "/" and "//" not in p and posixpath.normpath(p) == p
            and "\x00" not in p and "\n" not in p)


class Excluder:
    def __init__(self, rules):
        self.subtree, self.children, self.names, self.keep = [], [], [], set()
        for r in rules:
            if r.startswith("!"):
                if not clean_abs(r[1:]):
                    raise Refuse("rule %r" % r)
                self.keep.add(r[1:].encode())
            elif r.startswith("**/"):
                n = r[3:]
                if n == "" or any(c in n for c in "/*\x00") or n in (".", ".."):
                    raise Refuse("rule %r" % r)
                self.names.append(n.encode())
            elif r.endswith("*"):
                i = r.rfind("/")
                d, pre = r[:i], r[i + 1:-1]
                if i < 0 or (d != "" and not clean_abs(d)) or "*" in pre or "\x00" in pre or pre in (".", ".."):
                    raise Refuse("rule %r" % r)
                self.children.append((d.encode(), pre.encode()))
            else:
                if not clean_abs(r) or "*" in r:
                    raise Refuse("rule %r" % r)
                self.subtree.append(r.encode())

    @staticmethod
    def under(p, d):
        return p.startswith(d + b"/")

    def matched(self, p):
        for s in self.subtree:
            if p == s or self.under(p, s):
                return True
        for d, pre in self.children:
            if self.under(p, d):
                first = p[len(d) + 1:].split(b"/", 1)[0]
                if first.startswith(pre):
                    return True
        for n in self.names:
            if n in p.split(b"/"):
                return True
        return False

    def excluded(self, p):
        return self.matched(p) and p not in self.keep

    def kept_below(self, p):
        for k in self.keep:
            if self.under(k, p) or p == b"/":
                return True
        return False


def read_rules(path):
    with open(path, "rb") as f:
        data = f.read()
    try:
        text = data.decode("ascii")
    except UnicodeDecodeError:
        raise Refuse("%s: not ASCII" % path)
    if not text.endswith("\n"):
        raise Refuse("%s: the last line has no newline" % path)
    rules = [l for l in text.split("\n")[:-1]]
    for l in rules:
        if l == "" or l.startswith("#") or l != l.strip():
            raise Refuse("%s: an empty, comment or padded line %r (the list holds rules only)" % (path, l))
    Excluder(rules)
    return rules, hashlib.sha256(data).hexdigest()


class OSSource:
    """The tree under a folder (bytes paths). No link is followed."""

    def __init__(self, root):
        st = os.lstat(root)
        if not stat.S_ISDIR(st.st_mode):
            raise Refuse("the root is not a folder")
        self.root = root

    def real(self, p):
        return self.root if p == b"/" else self.root.rstrip(b"/") + p

    def lstat(self, p):
        """(type, mode, uid, gid, size, major, minor, dev) of p."""
        st = os.lstat(self.real(p))
        m = st.st_mode
        for t, k in ((stat.S_ISREG, "f"), (stat.S_ISDIR, "d"), (stat.S_ISLNK, "l"), (stat.S_ISCHR, "c"),
                     (stat.S_ISBLK, "b"), (stat.S_ISFIFO, "p"), (stat.S_ISSOCK, "s")):
            if t(m):
                break
        else:
            raise Refuse("%s: unknown file type %o" % (escape(p), stat.S_IFMT(m)))
        size = st.st_size if k == "f" else 0
        mj = mn = 0
        if k in "cb":
            mj, mn = os.major(st.st_rdev), os.minor(st.st_rdev)
        return k, stat.S_IMODE(m), st.st_uid, st.st_gid, size, mj, mn, st.st_dev

    def readdir(self, p):
        fd = os.open(self.real(p), os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
        try:
            return [os.fsencode(n) for n in os.listdir(fd)]
        finally:
            os.close(fd)

    def readlink(self, p):
        return os.readlink(self.real(p))

    def hash(self, p):
        """(size, sha256) of a regular file, opened without following a link."""
        fd = os.open(self.real(p), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise Refuse("%s: not a regular file" % escape(p))
            h, n = hashlib.sha256(), 0
            while True:
                b = os.read(fd, 1 << 20)
                if not b:
                    break
                h.update(b)
                n += len(b)
        finally:
            os.close(fd)
        return n, h.hexdigest()


def build(src, x, full=False, forbidden=(), onefs=False):
    """The manifest bytes of the tree of src and its entry count (Build of manifest.go)."""
    lines = []
    sizes = {f[1] for f in forbidden}
    count = [0]
    root = src.lstat(b"/")
    if root[0] != "d":
        raise Refuse("the root is not a folder")

    def walk(p, st, depth):
        count[0] += 1
        if count[0] > MAX_ENTRIES:
            raise Refuse("more than %d entries" % MAX_ENTRIES)
        if depth > MAX_DEPTH:
            raise Refuse("%s: deeper than %d folders" % (escape(p), MAX_DEPTH))
        excl = p != b"/" and x.excluded(p)
        k, mode, uid, gid, ssize, mj, mn, _ = st
        size, data = 0, "-"
        if k == "f":
            if not excl or ssize in sizes:
                n, sha = src.hash(p)
                if n != ssize:
                    raise Refuse("%s: %d bytes read, the stat says %d (it changed)" % (escape(p), n, ssize))
                for what, fsize, fsha in forbidden:
                    if fsize == n and fsha == sha:
                        raise Refuse("%s is %s (%d bytes, sha256 %.16s...): it must not be in this tree"
                                     % (escape(p), what, fsize, fsha))
                size, data = n, sha
        elif k == "l":
            if not excl:
                t = src.readlink(p)
                size, data = len(t), escape(t)
        elif k in "cb":
            data = "%d:%d" % (mj, mn)
        elif k not in "dps":
            raise Refuse("%s: unknown type %r" % (escape(p), k))
        if not excl:
            lines.append((p, "%s %s %04o %d %d %d %s\n" % (escape(p), k, mode & 0o7777, uid, gid, size, data)))
        if k != "d":
            return
        if excl and not full and not x.kept_below(p):
            return
        for nm in sorted(src.readdir(p)):
            if nm in (b"", b".", b"..") or b"/" in nm or b"\x00" in nm:
                raise Refuse("%s: the name %r" % (escape(p), nm))
            c = p.rstrip(b"/") + b"/" + nm
            cs = src.lstat(c)
            if onefs and cs[7] != root[7]:
                if x.excluded(c):
                    continue
                raise Refuse("%s is on another file system" % escape(c))
            walk(c, cs, depth + 1)

    walk(b"/", root, 0)
    lines.sort(key=lambda t: t[0])
    out = "".join(l for _, l in lines).encode("ascii")
    return out, len(lines)


# ---- clone-delta.json -------------------------------------------------------

DELTA_KEYS = {"schema", "remove", "remove_children", "empty", "write"}


def parse_mode(s):
    if not isinstance(s, str) or len(s) != 4 or any(c not in "01234567" for c in s):
        raise Refuse("mode %r is not 4 octal digits" % (s,))
    return int(s, 8)


def parse_delta(data):
    try:
        d = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as e:
        raise Refuse("clone-delta.json: %s" % e)
    if not isinstance(d, dict) or set(d) - DELTA_KEYS:
        raise Refuse("clone-delta.json: unknown keys %s" % sorted(set(d) - DELTA_KEYS if isinstance(d, dict) else []))
    if d.get("schema") != 1:
        raise Refuse("clone-delta.json: schema %r, want 1" % d.get("schema"))
    rem, kids = d.get("remove") or [], d.get("remove_children") or []
    emp, wr = d.get("empty") or [], d.get("write") or []
    allp = []
    for p in rem + kids:
        if not isinstance(p, str):
            raise Refuse("clone-delta.json: a path that is not a string")
        allp.append(p)
    for e in emp:
        if not isinstance(e, dict) or set(e) - {"path", "mode", "uid", "gid"}:
            raise Refuse("clone-delta.json: empty entry %r" % (e,))
        parse_mode(e.get("mode"))
        allp.append(e.get("path"))
    for f in wr:
        if not isinstance(f, dict) or set(f) - {"path", "mode", "uid", "gid", "from"}:
            raise Refuse("clone-delta.json: write entry %r" % (f,))
        parse_mode(f.get("mode"))
        if f.get("from") != "build-id":
            raise Refuse("clone-delta.json: write %s: from %r (only build-id)" % (f.get("path"), f.get("from")))
        allp.append(f.get("path"))
    for e in emp + wr:
        for k in ("uid", "gid"):
            v = e.get(k, 0)
            if not isinstance(v, int) or isinstance(v, bool) or v < 0 or v > 0xFFFFFFFF:
                raise Refuse("clone-delta.json: %s %s %r" % (e.get("path"), k, v))
    for i, p in enumerate(allp):
        if not isinstance(p, str) or not clean_abs(p):
            raise Refuse("clone-delta.json: path %r is not absolute and clean, or is /" % (p,))
        for j, q in enumerate(allp):
            if i != j and (p == q or q.startswith(p + "/")):
                raise Refuse("clone-delta.json: the paths %s and %s overlap" % (p, q))
    return {"remove": rem, "remove_children": kids, "empty": emp, "write": wr}


class Tree:
    """Paths of the delta, relative to the folder root; no link is followed."""

    def __init__(self, root):
        st = os.lstat(root)
        if not stat.S_ISDIR(st.st_mode):
            raise Refuse("%s is not a folder" % root)
        self.root = root.rstrip("/") or "/"

    def at(self, rel):
        return self.root if rel in ("", ".") else os.path.join(self.root, rel)

    def parents(self, p):
        """p relative to the root; every component before the last a folder (OSError ENOENT when missing)."""
        if not clean_abs(p):
            raise Refuse("path %r" % p)
        rel = p[1:]
        parts = rel.split("/")
        for i in range(1, len(parts)):
            q = "/".join(parts[:i])
            st = os.lstat(self.at(q))
            if not stat.S_ISDIR(st.st_mode):
                raise Refuse("/%s is not a folder" % q)
        return rel

    def remove_all(self, rel):
        path = self.at(rel)
        try:
            st = os.lstat(path)
        except FileNotFoundError:
            return
        if stat.S_ISDIR(st.st_mode):
            shutil.rmtree(path)
        else:
            os.unlink(path)

    def remove(self, p):
        try:
            rel = self.parents(p)
        except FileNotFoundError:
            return
        self.remove_all(rel)

    def children(self, p):
        rel = self.parents(p)
        st = os.lstat(self.at(rel))
        if not stat.S_ISDIR(st.st_mode):
            raise Refuse("%s is not a folder" % p)
        fd = os.open(self.at(rel), os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
        try:
            names = os.listdir(fd)
        finally:
            os.close(fd)
        for n in names:
            self.remove_all(rel + "/" + n)

    def own(self, rel, uid, gid):
        st = os.lstat(self.at(rel))
        if st.st_uid != uid or st.st_gid != gid:
            os.lchown(self.at(rel), uid, gid)

    def chmod(self, rel, mode):
        st = os.lstat(self.at(rel))
        if stat.S_ISLNK(st.st_mode):
            raise Refuse("%s is a symbolic link" % rel)
        os.chmod(self.at(rel), mode)

    def empty(self, e):
        m = parse_mode(e["mode"])
        rel = self.parents(e["path"])
        try:
            os.lstat(self.at(rel))
        except FileNotFoundError:
            os.mkdir(self.at(rel), 0o700)
        self.children(e["path"])
        self.own(rel, e.get("uid", 0), e.get("gid", 0))
        self.chmod(rel, m)

    def write(self, f, data):
        m = parse_mode(f["mode"])
        rel = self.parents(f["path"])
        try:
            st = os.lstat(self.at(rel))
            if not stat.S_ISREG(st.st_mode):
                raise Refuse("%s is there and not a regular file" % f["path"])
        except FileNotFoundError:
            pass
        tmp = rel + ".clone-tmp"
        try:
            os.unlink(self.at(tmp))
        except FileNotFoundError:
            pass
        fd = os.open(self.at(tmp), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        self.own(tmp, f.get("uid", 0), f.get("gid", 0))
        self.chmod(tmp, m)
        os.rename(self.at(tmp), self.at(rel))
        dfd = os.open(self.at(os.path.dirname(rel) or "."), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)


def apply_delta(d, root, version):
    t = Tree(root)
    for p in d["remove"]:
        t.remove(p)
    for p in d["remove_children"]:
        t.children(p)
    for e in d["empty"]:
        t.empty(e)
    for f in d["write"]:
        t.write(f, (version + "\n").encode("ascii"))


# ---- the command line -------------------------------------------------------

def cmd_build(a):
    if not a:
        raise Refuse("build: ROOT is required")
    root, rest = a[0], a[1:]
    excl, out, full, onefs, forbid = None, None, False, False, []
    i = 0
    while i < len(rest):
        o = rest[i]
        if o in ("--exclude", "--out", "--forbid") and i + 1 < len(rest):
            v = rest[i + 1]
            i += 2
            if o == "--exclude":
                excl = v
            elif o == "--out":
                out = v
            else:
                w = v.rsplit(":", 2)
                if len(w) != 3 or not w[1].isdigit() or len(w[2]) != 64 or any(c not in "0123456789abcdef" for c in w[2]):
                    raise Refuse("--forbid %r: WHAT:SIZE:SHA256" % v)
                forbid.append((w[0], int(w[1]), w[2]))
        elif o == "--full":
            full, i = True, i + 1
        elif o == "--onefs":
            onefs, i = True, i + 1
        else:
            raise Refuse("build: unknown option %s" % o)
    if excl is None:
        raise Refuse("build: --exclude FILE is required")
    rules, _ = read_rules(excl)
    man, n = build(OSSource(os.fsencode(root)), Excluder(rules), full, forbid, onefs)
    if out:
        with open(out, "wb") as f:
            f.write(man)
    print("%s %d" % (hashlib.sha256(man).hexdigest(), n))
    return 0


def cmd_exclude_sha(a):
    if len(a) != 1:
        raise Refuse("exclude-sha256 FILE")
    print(read_rules(a[0])[1])
    return 0


def cmd_apply_delta(a):
    if len(a) != 3:
        raise Refuse("apply-delta DELTA ROOT VERSION")
    with open(a[0], "rb") as f:
        d = parse_delta(f.read())
    v = a[2]
    if not v or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-" for c in v) or len(v) > 64:
        raise Refuse("the version %r" % v)
    apply_delta(d, a[1], v)
    print("delta applied: %d removed, %d emptied below, %d emptied, %d written"
          % (len(d["remove"]), len(d["remove_children"]), len(d["empty"]), len(d["write"])))
    return 0


def cmd_diff(a):
    mx = 200
    if len(a) == 4 and a[2] == "--max" and a[3].isdigit():
        mx = int(a[3])
    elif len(a) != 2:
        raise Refuse("diff A B [--max N]")
    with open(a[0], "rb") as f:
        wa = set(f.read().decode("ascii").splitlines())
    with open(a[1], "rb") as f:
        wb = set(f.read().decode("ascii").splitlines())
    out = sorted(["- " + l for l in wa - wb] + ["+ " + l for l in wb - wa])
    for l in out[:mx]:
        print(l)
    print("%d lines differ" % len(out))
    return 0 if not out else 3


def main(argv):
    cmds = {"build": cmd_build, "exclude-sha256": cmd_exclude_sha, "apply-delta": cmd_apply_delta, "diff": cmd_diff}
    if not argv or argv[0] not in cmds:
        sys.stderr.write(__doc__.split("The format")[0])
        return 2
    try:
        return cmds[argv[0]](argv[1:])
    except Refuse as e:
        print("contentmanifest: %s" % e, file=sys.stderr)
        return 1
    except OSError as e:
        print("contentmanifest: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
