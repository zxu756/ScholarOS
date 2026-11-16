"""Helper for m2-regen-expected.sh (conductor-only; never called by tests). Run with python3 -I.

  fetch <id> <version> <dest.pkg>        download an arXiv source package (User-Agent ScholarOS-benchmark/1.0, 3 s spacing)
  sha256 <file>                          print the SHA-256
  extract <pkg> <dest-dir>               safe extraction (regular files only, no paths leaving the target) into a new directory
  expected <id> <outdir> <base> <generator> <dest.json>
                                         build expected.json from a Tectonic output dir (.aux sets + LaTeX/BibTeX logs)
  compare <new.json> <committed.json>    print differences; exit 1 on any (generated_utc is ignored)

The .aux logic is the one used to produce the committed files: follow \\@input chains, collect \\citation,
\\bibcite and \\newlabel keys; labels containing '@' (and a few known patterns) are package-internal and are
listed under excluded_internal_labels instead of labels.
"""
import sys, os, re, json, io, gzip, tarfile, hashlib, time, datetime, urllib.request, urllib.parse

INTERNAL = [r"@cref$", r"^sub@", r"^tocindent-?\d+$", r"^LastPage$", r"^LastPages$", r"^TotPages$", r"^\\?.*@.*$"]
UA = "ScholarOS-benchmark/1.0"
HOSTS = {"arxiv.org", "export.arxiv.org"}


def read_aux(path, seen, acc):
    if not os.path.exists(path):
        acc["missing_aux"].append(os.path.relpath(path, acc["_root"]))
        return
    if path in seen:
        return
    seen.add(path)
    acc["aux_files"].append(os.path.relpath(path, acc["_root"]))
    text = open(path, encoding="utf-8", errors="replace").read()
    for m in re.finditer(r"\\citation\{([^}]*)\}", text):
        for k in m.group(1).split(","):
            k = k.strip()
            if k and k != "*":
                acc["cites"].add(k)
            elif k == "*":
                acc["nocite_star"] = True
    for m in re.finditer(r"\\abx@aux@cite\{[^}]*\}\{([^}]*)\}", text):
        acc["cites"].add(m.group(1).strip())
    for m in re.finditer(r"\\bibcite\{([^}]*)\}", text):
        acc["bibcite"].add(m.group(1).strip())
    for m in re.finditer(r"\\newlabel\{((?:[^{}]|\{[^{}]*\})*)\}", text):
        k = m.group(1)
        (acc["internal_labels"] if any(re.search(p, k) for p in INTERNAL) else acc["labels"]).add(k)
    for m in re.finditer(r"\\@input\{([^}]*)\}", text):
        read_aux(os.path.join(acc["_root"], m.group(1)), seen, acc)


def build_expected(pid, outdir, base, generator):
    acc = {"_root": outdir, "aux_files": [], "missing_aux": [], "cites": set(), "bibcite": set(),
           "labels": set(), "internal_labels": set(), "nocite_star": False}
    read_aux(os.path.join(outdir, base + ".aux"), set(), acc)
    log = open(os.path.join(outdir, base + ".log"), encoding="utf-8", errors="replace").read()
    blg_path = os.path.join(outdir, base + ".blg")
    blg = open(blg_path, encoding="utf-8", errors="replace").read() if os.path.exists(blg_path) else ""
    errs = re.findall(r"\(There (?:was|were) (\d+) error messages?\)", blg)
    return {
        "paper": pid,
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "generator": generator,
        "aux_files": acc["aux_files"],
        "cite_keys": sorted(acc["cites"]),
        "nocite_star": acc["nocite_star"],
        "bibcite_keys": sorted(acc["bibcite"]),
        "labels": sorted(acc["labels"]),
        "excluded_internal_labels": sorted(acc["internal_labels"]),
        "latex_log": {
            "undefined_citations": sorted(set(re.findall(r"Citation `([^']*)' (?:on page \d+ )?undefined", log))),
            "undefined_references": sorted(set(re.findall(r"Reference `([^']*)' on page \d+ undefined", log))),
            "multiply_defined_labels": sorted(set(re.findall(r"Label `([^']*)' multiply defined", log))),
        },
        "bibtex_log": {
            "missing_entries": sorted(set(re.findall(r"I didn't find a database entry for \"([^\"]*)\"", blg))),
            "error_messages": int(errs[0]) if errs else 0,
            "ran": bool(blg),
        },
    }


def compare(a, b):
    diffs = []
    for k in sorted(set(a) | set(b)):
        if k == "generated_utc":
            continue
        va, vb = a.get(k), b.get(k)
        if va == vb:
            continue
        if isinstance(va, list) and isinstance(vb, list):
            diffs.append(f"{k}: only regenerated {sorted(set(map(json.dumps, va)) - set(map(json.dumps, vb)))}; "
                         f"only committed {sorted(set(map(json.dumps, vb)) - set(map(json.dumps, va)))}")
        elif isinstance(va, dict) and isinstance(vb, dict):
            diffs += [f"{k}.{d}" for d in compare(va, vb)]
        else:
            diffs.append(f"{k}: regenerated {va!r}; committed {vb!r}")
    return diffs


def fetch(pid, ver, dest):
    url = f"https://arxiv.org/src/{pid}{ver}"
    stamp = os.path.join(os.path.dirname(os.path.abspath(dest)), ".last_arxiv_request")
    try:
        last = float(open(stamp).read())
    except Exception:
        last = 0.0
    if time.time() - last < 3.2:
        time.sleep(3.2 - (time.time() - last))

    class Guard(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            if urllib.parse.urlsplit(newurl).hostname not in HOSTS or not newurl.startswith("https://"):
                raise SystemExit("refused redirect: " + newurl)
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    op = urllib.request.build_opener(urllib.request.ProxyHandler({}), Guard())
    try:
        data = op.open(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=120).read(60 * 1024 * 1024)
    finally:
        open(stamp, "w").write(repr(time.time()))
    open(dest, "wb").write(data)


def extract(pkg, dest):
    os.makedirs(dest, exist_ok=False)
    raw = open(pkg, "rb").read()
    data = gzip.decompress(raw) if raw[:2] == b"\x1f\x8b" else raw
    try:
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            root = os.path.realpath(dest)
            for m in tf.getmembers():  # regular files and directories only, nothing may leave dest
                target = os.path.realpath(os.path.join(dest, m.name))
                if not (m.isfile() or m.isdir()) or os.path.isabs(m.name) or not (target == root or target.startswith(root + os.sep)):
                    continue
                m.mode = 0o644 if m.isfile() else 0o755
                m.uid = m.gid = 0
                tf.extract(m, dest)
    except tarfile.TarError:
        open(os.path.join(dest, "main.tex"), "wb").write(data)


def main(argv):
    cmd, a = argv[0], argv[1:]
    if cmd == "sha256":
        print(hashlib.sha256(open(a[0], "rb").read()).hexdigest())
    elif cmd == "fetch":
        fetch(*a)
    elif cmd == "extract":
        extract(*a)
    elif cmd == "expected":
        pid, outdir, base, gen, dest = a
        json.dump(build_expected(pid, outdir, base, gen), open(dest, "w"), indent=1, ensure_ascii=False)
    elif cmd == "compare":
        d = compare(json.load(open(a[0])), json.load(open(a[1])))
        for x in d:
            print("  " + x)
        return 1 if d else 0
    else:
        raise SystemExit("unknown command " + cmd)
    return 0


sys.exit(main(sys.argv[1:]))
