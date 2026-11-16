#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""The profile bundle of R23 (DESIGN-R23 §3.2, §5): the exact signed .apk
files that a profile adds to the base, the four signed indexes of the
snapshot, the lock list bundle.json, and lva.tar (Kiosk + HA), as one
deterministic tar. And profiles.json, the base's pinned list of them.

  bundle.py simulate-list LOG OUT
      Read the output of `apk add --simulate` ("(N/M) Installing NAME (VERSION)"
      lines) and write OUT: one "NAME VERSION" line per package, in that order.
  bundle.py repo --alpine-dir DIR --tsx-dir DIR --branch v3.24 --list FILE --out DIR
      Stage the repository of a bundle: the indexes main, community (DIR of
      the Alpine snapshot) and common, uc-pxx (DIR of the tsx-aports tree) and
      the .apk file of each package of FILE, under BRANCH/REPO/aarch64/, as
      byte copies. Each package must be in exactly one index, its file must
      have the index's size and the index's checksum (C:, the sha1 or sha256
      of the control part). Writes DIR/repositories (the four folders).
  bundle.py make --repo DIR --list FILE --before DB --after DB --world FILE
                 --add FILE --profile NAME --release R [--lva FILE] --out TAR
      Check the install (the packages of AFTER = those of BEFORE plus those of
      FILE, each package of BEFORE unchanged; no package of FILE in BEFORE),
      write bundle.json and the bundle TAR. Prints "bundle SHA256 SIZE" and
      "index SHA256 SIZE" (index = bundle.json).
  bundle.py installed-sha256 DB
      The sha256 of an apk installed db file (the done record's and
      profiles.json's installed_sha256: the file's bytes) and its package count.
  bundle.py profiles --release R --base-version V --alpine v3.24 --exclude-sha256 S
                     --delta-sha256 S --url URL [--url URL ...]
                     --profile NAME:APPLY:REF_B:REF_A:INSTALLED[:BUNDLE_TAR:INDEX_JSON] ... --out FILE
      Write profiles.json.
  bundle.py check TAR [--sha256 S]
      Read a bundle as the unit does: bundle.json first, each member against
      its line in order, nothing else; print the summary.

The tar (bundle.json format "uc-pxx-profile-bundle", schema 1): ustar, every
member a regular file, mode 0644, uid and gid 0, no user or group name,
mtime 0, in this order: bundle.json; the four indexes (main, community,
common, uc-pxx); the .apk files sorted by path; lva.tar (Kiosk + HA only).
The .apk files and the indexes are the snapshot's bytes (never rebuilt or
re-signed). Standard library only. Run with python3 -I.
"""
import base64
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tarfile
import zlib

ARCH = "aarch64"
REPOS = (("main", "alpine"), ("community", "alpine"), ("common", "tsx"), ("uc-pxx", "tsx"))
BUNDLE_KIND = "uc-pxx-profile-bundle"
PROFILES_KIND = "uc-pxx-provision-profiles"
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
VER_RE = re.compile(r"^[0-9][A-Za-z0-9._+~-]*$")
PROFILE_RE = re.compile(r"^(console|kiosk|kiosk-ha)$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


class Refuse(Exception):
    pass


def sha256_file(path):
    h, n = hashlib.sha256(), 0
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
            n += len(b)
    return h.hexdigest(), n


def read_index(path):
    """The packages of an APKINDEX.tar.gz: {(name, version): fields}."""
    with tarfile.open(path, "r:gz") as tf:
        m = tf.getmember("APKINDEX")
        text = tf.extractfile(m).read().decode("utf-8")
    pk = {}
    for block in text.split("\n\n"):
        f = {}
        for line in block.split("\n"):
            if len(line) >= 2 and line[1] == ":":
                f.setdefault(line[0], line[2:])
        if "P" in f and "V" in f:
            k = (f["P"], f["V"])
            if k in pk:
                raise Refuse("%s lists %s-%s twice" % (path, k[0], k[1]))
            pk[k] = f
    return pk


def gzip_members(path, count):
    """The byte ranges of the first count gzip members of a file, and each one's decompressed bytes."""
    out = []
    with open(path, "rb") as f:
        data = f.read()
    off = 0
    for _ in range(count):
        if off >= len(data):
            raise Refuse("%s: only %d gzip parts" % (path, len(out)))
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        pos, plain = off, []
        while not d.eof:
            chunk = data[pos:pos + 65536]
            if not chunk:
                raise Refuse("%s: a gzip part does not end" % path)
            plain.append(d.decompress(chunk))
            pos += len(chunk)
        end = pos - len(d.unused_data)
        out.append((off, end, b"".join(plain)))
        off = end
    return data, out


def control_info(path):
    """The identity (Q1 sha1 / Q2 sha256 of the control part), the scripts and the triggers of an .apk."""
    data, parts = gzip_members(path, 2)
    o, e, plain = parts[1]
    seg = data[o:e]
    ident = {"Q1": "Q1" + base64.b64encode(hashlib.sha1(seg).digest()).decode(),
             "Q2": "Q2" + base64.b64encode(hashlib.sha256(seg).digest()).decode()}
    scripts, triggers, pkginfo = [], [], None
    with tarfile.open(fileobj=io.BytesIO(plain), mode="r:") as tf:
        for m in tf:
            n = m.name
            if n == ".PKGINFO":
                pkginfo = tf.extractfile(m).read().decode("utf-8")
            elif n.startswith(".") and not n.startswith(".SIGN."):
                scripts.append(n)
    if pkginfo is None:
        raise Refuse("%s: no .PKGINFO in the control part" % path)
    for line in pkginfo.splitlines():
        if line.startswith("triggers = "):
            triggers.extend(line[len("triggers = "):].split())
    return ident, sorted(scripts), triggers


def read_db(path):
    """The packages of an apk installed db: {name: version}."""
    with open(path, "rb") as f:
        text = f.read().decode("utf-8")
    pk, cur = {}, None
    for line in text.split("\n"):
        if line == "":
            cur = None
            continue
        if line.startswith("P:"):
            cur = line[2:]
            if cur in pk:
                raise Refuse("%s lists %s twice" % (path, cur))
            pk[cur] = None
        elif line.startswith("V:") and cur is not None:
            pk[cur] = line[2:]
    for n, v in pk.items():
        if v is None:
            raise Refuse("%s: %s has no version" % (path, n))
    return pk


def installed_sha(db):
    """installed_sha256 (R23-FORMATS §3): the sha256 of /lib/apk/db/installed itself."""
    pk = read_db(db)
    return sha256_file(db)[0], len(pk)


def read_list(path):
    out = []
    with open(path) as f:
        for line in f:
            w = line.split()
            if not w:
                continue
            if len(w) != 2 or not NAME_RE.match(w[0]) or not VER_RE.match(w[1]):
                raise Refuse("%s: a bad line %r" % (path, line))
            out.append((w[0], w[1]))
    if len(set(out)) != len(out):
        raise Refuse("%s names a package twice" % path)
    return out


def read_names(path):
    with open(path) as f:
        names = f.read().split()
    for n in names:
        if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$", n):
            raise Refuse("%s: the name %r" % (path, n))
    return names


def opts(a, single, multi=(), flags=()):
    o, i = {k: [] for k in multi}, 0
    while i < len(a):
        k = a[i]
        if k in flags:
            o[k] = True
            i += 1
            continue
        if (k not in single and k not in multi) or i + 1 >= len(a):
            raise Refuse("unknown or incomplete option %s" % k)
        if k in multi:
            o[k].append(a[i + 1])
        else:
            if k in o:
                raise Refuse("%s given twice" % k)
            o[k] = a[i + 1]
        i += 2
    return o


def need(o, *keys):
    for k in keys:
        if k not in o:
            raise Refuse("%s is required" % k)


# ---- simulate-list ------------------------------------------------------------

def cmd_simulate_list(a):
    if len(a) != 2:
        raise Refuse("simulate-list LOG OUT")
    rx = re.compile(r"^\(\s*\d+/\s*\d+\) (Installing|Upgrading|Downgrading|Replacing|Purging|Reinstalling) (\S+) \((\S+?)\)")
    got = []
    with open(a[0]) as f:
        for line in f:
            m = rx.match(line)
            if not m:
                continue
            if m.group(1) != "Installing":
                raise Refuse("the simulated install changes a package of the base: %s" % line.strip())
            got.append((m.group(2), m.group(3)))
    with open(a[1], "w") as f:
        for n, v in got:
            f.write("%s %s\n" % (n, v))
    print("%d packages" % len(got))
    return 0


# ---- repo -----------------------------------------------------------------------

def index_paths(alpine_dir, tsx_dir, branch):
    out = []
    for repo, where in REPOS:
        top = alpine_dir if where == "alpine" else tsx_dir
        rel = "%s/%s/%s/APKINDEX.tar.gz" % (branch, repo, ARCH)
        out.append((repo, rel, os.path.join(top, rel)))
    return out


def cmd_repo(a):
    o = opts(a, ("--alpine-dir", "--tsx-dir", "--branch", "--list", "--out"))
    need(o, "--alpine-dir", "--tsx-dir", "--branch", "--list", "--out")
    br = o["--branch"]
    if not re.match(r"^v[0-9]+\.[0-9]+$", br):
        raise Refuse("--branch %r" % br)
    pkgs = read_list(o["--list"])
    out = o["--out"]
    if os.path.exists(out):
        raise Refuse("--out %s exists" % out)
    idx = index_paths(o["--alpine-dir"], o["--tsx-dir"], br)
    found = {}
    for repo, rel, src in idx:
        for k, f in read_index(src).items():
            found.setdefault(k, []).append((repo, rel, src, f))
    for repo, rel, src in idx:
        os.makedirs(os.path.dirname(os.path.join(out, rel)))
        shutil.copyfile(src, os.path.join(out, rel))
    for n, v in pkgs:
        hits = found.get((n, v), [])
        if len(hits) != 1:
            raise Refuse("%s-%s is in %d of the four indexes (exactly one is required)" % (n, v, len(hits)))
        repo, rel, src, f = hits[0]
        fname = "%s-%s.apk" % (n, v)
        s = os.path.join(os.path.dirname(src), fname)
        if not os.path.isfile(s) or os.path.islink(s):
            raise Refuse("the snapshot has no %s/%s" % (os.path.dirname(rel), fname))
        size = os.path.getsize(s)
        if str(size) != f.get("S"):
            raise Refuse("%s: %d bytes, the index says %s" % (fname, size, f.get("S")))
        ident, _, _ = control_info(s)
        c = f.get("C", "")
        if c[:2] not in ident or ident[c[:2]] != c:
            raise Refuse("%s: the control part is not the index's %s" % (fname, c))
        shutil.copyfile(s, os.path.join(out, os.path.dirname(rel), fname))
    with open(os.path.join(out, "repositories"), "w") as f:
        for repo, rel, src in idx:
            f.write(os.path.dirname(os.path.dirname(rel)) + "\n")
    print("repo: %d packages, %d indexes" % (len(pkgs), len(idx)))
    return 0


# ---- make ---------------------------------------------------------------------------

def tarinfo(name, size):
    ti = tarfile.TarInfo(name)
    ti.size, ti.mtime, ti.mode, ti.uid, ti.gid = size, 0, 0o644, 0, 0
    ti.uname = ti.gname = ""
    ti.type = tarfile.REGTYPE
    return ti


def write_bundle(out, members):
    """members: [(name, path or bytes)] in their order."""
    tmp = out + ".part"
    with open(tmp, "wb") as raw:
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tf:
            for name, src in members:
                if isinstance(src, bytes):
                    tf.addfile(tarinfo(name, len(src)), io.BytesIO(src))
                else:
                    with open(src, "rb") as f:
                        tf.addfile(tarinfo(name, os.path.getsize(src)), f)
    os.replace(tmp, out)


def cmd_make(a):
    o = opts(a, ("--repo", "--list", "--before", "--after", "--world", "--add", "--profile", "--release", "--lva",
                 "--out"))
    need(o, "--repo", "--list", "--before", "--after", "--world", "--add", "--profile", "--release", "--out")
    prof, rel = o["--profile"], o["--release"]
    if not PROFILE_RE.match(prof) or prof == "console":
        raise Refuse("--profile %r (kiosk or kiosk-ha: console has no bundle)" % prof)
    if not re.match(r"^[A-Za-z0-9._+-]{1,64}$", rel):
        raise Refuse("--release %r" % rel)
    if (prof == "kiosk-ha") != ("--lva" in o):
        raise Refuse("lva.tar is in the kiosk-ha bundle and in no other")
    pkgs = read_list(o["--list"])
    before, after = read_db(o["--before"]), read_db(o["--after"])
    for n, v in before.items():
        if after.get(n) != v:
            raise Refuse("the install changed the base package %s-%s (now %s)" % (n, v, after.get(n)))
    for n, v in pkgs:
        if n in before:
            raise Refuse("the bundle holds %s, a package of the base" % n)
    added = {n: v for n, v in after.items() if n not in before}
    if added != dict(pkgs):
        extra = sorted(set(added.items()) ^ set(pkgs))
        raise Refuse("the installed packages are not the base plus the list: %s" % extra[:10])
    world = sorted(read_names(o["--world"]))
    add = read_names(o["--add"])
    hits = [d for d in os.listdir(o["--repo"]) if re.match(r"^v[0-9]+\.[0-9]+$", d)]
    if len(hits) != 1:
        raise Refuse("the repo %s has not exactly one branch folder" % o["--repo"])
    br = hits[0]
    idx = []
    found = {}
    for repo, _ in REPOS:
        relp = "%s/%s/%s/APKINDEX.tar.gz" % (br, repo, ARCH)
        p = os.path.join(o["--repo"], relp)
        s, size = sha256_file(p)
        idx.append({"repo": repo, "path": relp, "size": size, "sha256": s})
        for k, f in read_index(p).items():
            found.setdefault(k, []).append((repo, f))
    lines = []
    for n, v in pkgs:
        hits = found.get((n, v), [])
        if len(hits) != 1:
            raise Refuse("%s-%s is in %d indexes of the repo" % (n, v, len(hits)))
        repo, f = hits[0]
        relp = "%s/%s/%s/%s-%s.apk" % (br, repo, ARCH, n, v)
        p = os.path.join(o["--repo"], relp)
        s, size = sha256_file(p)
        ident, scripts, triggers = control_info(p)
        if ident.get(f["C"][:2]) != f["C"] or str(size) != f.get("S"):
            raise Refuse("%s is not the file of its index" % relp)
        lines.append({"name": n, "version": v, "repo": repo, "path": relp, "size": size, "sha256": s,
                      "checksum": f["C"], "scripts": scripts, "triggers": triggers})
    lines.sort(key=lambda d: d["path"])
    lva = None
    if "--lva" in o:
        s, size = sha256_file(o["--lva"])
        lva = {"path": "lva.tar", "size": size, "sha256": s}
    doc = {
        "schema": 1, "kind": BUNDLE_KIND, "release": rel, "profile": prof, "alpine": br, "arch": ARCH,
        "indexes": idx, "packages": lines, "lva": lva, "add": add, "world": world,
        "base": sorted("%s=%s" % (n, v) for n, v in before.items()),
    }
    js = (json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=True) + "\n").encode("ascii")
    members = [("bundle.json", js)] + [(i["path"], os.path.join(o["--repo"], i["path"])) for i in idx]
    members += [(d["path"], os.path.join(o["--repo"], d["path"])) for d in lines]
    if lva:
        members.append(("lva.tar", o["--lva"]))
    write_bundle(o["--out"], members)
    bs, bsize = sha256_file(o["--out"])
    with open(o["--out"] + ".json", "wb") as f:
        f.write(js)
    print("bundle %s %d" % (bs, bsize))
    print("index %s %d" % (hashlib.sha256(js).hexdigest(), len(js)))
    print("packages %d" % len(lines))
    return 0


# ---- check (the unit's reading) --------------------------------------------------

def cmd_check(a):
    o = opts(a[1:], ("--sha256",))
    if not a:
        raise Refuse("check TAR [--sha256 S]")
    with open(a[0], "rb") as raw:
        tf = tarfile.open(fileobj=raw, mode="r:", format=tarfile.USTAR_FORMAT)
        first = tf.next()
        if first is None or first.name != "bundle.json" or not first.isreg():
            raise Refuse("the first member is not bundle.json")
        js = tf.extractfile(first).read()
        doc = json.loads(js.decode("ascii"))
        if doc.get("schema") != 1 or doc.get("kind") != BUNDLE_KIND:
            raise Refuse("bundle.json: schema %r kind %r" % (doc.get("schema"), doc.get("kind")))
        want = [(i["path"], i["size"], i["sha256"]) for i in doc["indexes"]]
        want += [(p["path"], p["size"], p["sha256"]) for p in doc["packages"]]
        if doc.get("lva"):
            want.append((doc["lva"]["path"], doc["lva"]["size"], doc["lva"]["sha256"]))
        for path, size, sha in want:
            m = tf.next()
            if m is None or m.name != path or not m.isreg() or m.size != size or m.mode != 0o644 or m.uid or m.gid or m.mtime:
                raise Refuse("member %r is not the next line %s (%d bytes)" % (m and m.name, path, size))
            h = hashlib.sha256()
            f = tf.extractfile(m)
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
            if h.hexdigest() != sha:
                raise Refuse("%s: sha256 %s, the line says %s" % (path, h.hexdigest(), sha))
        if tf.next() is not None:
            raise Refuse("a member after the last line")
    s, size = sha256_file(a[0])
    if "--sha256" in o and s != o["--sha256"]:
        raise Refuse("the bundle is %s, the pin is %s" % (s, o["--sha256"]))
    print("bundle ok: %s %d bytes, bundle.json %s, %d packages, %d indexes, lva %s"
          % (s, size, hashlib.sha256(js).hexdigest(), len(doc["packages"]), len(doc["indexes"]),
             "yes" if doc.get("lva") else "no"))
    return 0


# ---- profiles.json ----------------------------------------------------------------

def cmd_profiles(a):
    o = opts(a, ("--release", "--base-version", "--alpine", "--exclude-sha256", "--delta-sha256", "--out"),
             multi=("--url", "--profile"))
    need(o, "--release", "--base-version", "--alpine", "--exclude-sha256", "--delta-sha256", "--out")
    if not re.match(r"^v[0-9]+\.[0-9]+$", o["--alpine"]):
        raise Refuse("--alpine %r" % o["--alpine"])
    if not o["--url"] or not o["--profile"]:
        raise Refuse("at least one --url and one --profile")
    for u in o["--url"]:
        if not re.match(r"^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+-]*)?/$", u):
            raise Refuse("--url %r (http or https, ends with /)" % u)
    for k in ("--exclude-sha256", "--delta-sha256"):
        if not SHA_RE.match(o[k]):
            raise Refuse("%s %r" % (k, o[k]))
    profs = {}
    for spec in o["--profile"]:
        w = spec.split(":")
        if len(w) not in (5, 7):
            raise Refuse("--profile %r" % spec)
        name, apply, refb, refa, inst = w[:5]
        if not PROFILE_RE.match(name) or name in profs or apply not in ("console", "kiosk", "ha"):
            raise Refuse("--profile %r" % spec)
        for s in (refb, refa, inst):
            if not SHA_RE.match(s):
                raise Refuse("--profile %r: %r is not a sha256" % (spec, s))
        ent = {"apply": apply, "build_id": "%s-%s" % (o["--release"], name), "ref_b_sha256": refb,
               "ref_a_sha256": refa, "installed_sha256": inst, "bundle": None, "index_sha256": None, "packages": 0}
        if len(w) == 7:
            if name == "console":
                raise Refuse("console has no bundle")
            s, size = sha256_file(w[5])
            with open(w[6], "rb") as f:
                js = f.read()
            doc = json.loads(js.decode("ascii"))
            if doc.get("profile") != name or doc.get("release") != o["--release"]:
                raise Refuse("%s is not the bundle of %s %s" % (w[6], name, o["--release"]))
            ent["bundle"] = {"file": os.path.basename(w[5]), "size": size, "sha256": s}
            ent["index_sha256"] = hashlib.sha256(js).hexdigest()
            ent["packages"] = len(doc["packages"])
        elif name != "console":
            raise Refuse("%s needs its bundle" % name)
        profs[name] = ent
    doc = {"schema": 1, "kind": PROFILES_KIND, "release": o["--release"], "base_version": o["--base-version"],
           "alpine": o["--alpine"], "arch": ARCH, "content_exclude_sha256": o["--exclude-sha256"],
           "clone_delta_sha256": o["--delta-sha256"], "urls": o["--url"], "profiles": profs}
    js = (json.dumps(doc, indent=1, sort_keys=True, ensure_ascii=True) + "\n").encode("ascii")
    with open(o["--out"], "wb") as f:
        f.write(js)
    print("profiles.json %s %d (%s)" % (hashlib.sha256(js).hexdigest(), len(js), " ".join(sorted(profs))))
    return 0


def cmd_installed(a):
    if len(a) != 1:
        raise Refuse("installed-sha256 DB")
    s, n = installed_sha(a[0])
    print("%s %d" % (s, n))
    return 0


def main(argv):
    cmds = {"simulate-list": cmd_simulate_list, "repo": cmd_repo, "make": cmd_make, "check": cmd_check,
            "profiles": cmd_profiles, "installed-sha256": cmd_installed}
    if not argv or argv[0] not in cmds:
        sys.stderr.write(__doc__.split("The tar (")[0])
        return 2
    try:
        return cmds[argv[0]](argv[1:])
    except Refuse as e:
        print("bundle: %s" % e, file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, tarfile.TarError, zlib.error) as e:
        print("bundle: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
