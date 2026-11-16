#!/usr/bin/env python3
"""Build the "real_human" BibTeX group for the ScholarOS citation-checker benchmark.

Run with:  python3 -I fetch_human_bib.py [--stage listing|fetch|select|all]

Standard library only. Network: export.arxiv.org / oaipmh.arxiv.org / arxiv.org only,
single-threaded, >= 3 s between requests, UA "ScholarOS-benchmark/1.0".
Cached listing pages (listing/), outcomes (state/outcomes.json) and saved originals
(originals/) are reused when present, so reruns do not hit the network.
"""
import argparse
import datetime
import gzip
import hashlib
import io
import json
import os
import random
import re
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
BASE = os.path.dirname(HERE)
RAW = os.path.join(BASE, "raw")
LISTING = os.path.join(HERE, "listing")
ORIG = os.path.join(HERE, "originals")
STATE = os.path.join(HERE, "state")
REQLOG = os.path.join(HERE, "requests.log")

UA = "ScholarOS-benchmark/1.0"
ALLOWED_HOSTS = {"export.arxiv.org", "oaipmh.arxiv.org", "arxiv.org"}
OAI_URL = "https://oaipmh.arxiv.org/oai"  # export.arxiv.org/oai2 answers 301 -> this (verified, logged)
MIN_GAP = 3.2
MAX_PKG = 25 * 1024 * 1024
TOTAL_CAP = 600 * 1024 * 1024
SEED = 20261116
LICENSE = "http://creativecommons.org/licenses/by/4.0/"

# (set spec, label) in the order of the brief.
FIELDS = ["cs", "math", "physics:astro-ph", "physics:cond-mat", "q-bio", "stat", "econ", "eess"]
# A paper cross-listed in several sets is assigned to the FIRST of these (small sets first),
# so that small sets are not emptied by large ones.
ASSIGN_ORDER = ["econ", "q-bio", "eess", "physics:astro-ph", "physics:cond-mat", "stat", "math", "cs"]
DEFAULT_WINDOW = ("2024-03-04", "2024-03-06")
WINDOWS = {}  # per-field overrides, filled from state/windows.json if present
PER_FIELD_ACCEPT = 3
PER_FIELD_TRY = 25
MIN_ENTRIES = 15
MAX_PER_PAPER = 8
N_DOI, N_NODOI = 65, 35

USABLE_TYPES = {"article", "inproceedings", "conference", "book", "incollection", "inbook",
                "phdthesis", "mastersthesis", "techreport"}
NEED_ID_TYPES = {"misc", "unpublished"}
MONTHS = {"jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"}

_last_req = [0.0]


# ---------------------------------------------------------------- HTTP

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


class CI(dict):
    """case-insensitive header dict"""
    def __init__(self, items=()):
        super().__init__((k.lower(), v) for k, v in items)

    def get(self, k, d=None):
        return super().get(k.lower(), d)


_opener = urllib.request.build_opener(_NoRedirect)


def _log(url, status, nbytes):
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(REQLOG, "a") as f:
        f.write("%s\t%s\t%s\t%s\n" % (ts, url, status, nbytes))


def _wait():
    d = time.time() - _last_req[0]
    if d < MIN_GAP:
        time.sleep(MIN_GAP - d)


def http_get(url, maxbytes=None, accept_not_found=True):
    """Return (status, headers, data|None, note). Follows redirects manually (logged, host-checked)."""
    retries = 0
    hops = 0
    cur = url
    while True:
        host = urllib.parse.urlparse(cur).hostname
        if host not in ALLOWED_HOSTS:
            return (0, {}, None, "blocked host " + str(host))
        _wait()
        req = urllib.request.Request(cur, headers={"User-Agent": UA})
        status, headers, data, note = None, {}, None, ""
        try:
            r = _opener.open(req, timeout=120)
            status = r.status
            headers = CI(r.headers.items())
            cl = headers.get("Content-Length")
            if maxbytes and cl and cl.isdigit() and int(cl) > maxbytes:
                _last_req[0] = time.time()
                _log(cur, status, 0)
                r.close()
                return (status, headers, None, "too large (Content-Length %s)" % cl)
            chunks, n = [], 0
            while True:
                c = r.read(65536)
                if not c:
                    break
                n += len(c)
                chunks.append(c)
                if maxbytes and n > maxbytes:
                    _last_req[0] = time.time()
                    _log(cur, status, n)
                    r.close()
                    return (status, headers, None, "too large (>%d bytes read)" % maxbytes)
            data = b"".join(chunks)
            _last_req[0] = time.time()
            _log(cur, status, len(data))
            return (status, headers, data, "")
        except urllib.error.HTTPError as e:
            status = e.code
            headers = CI(e.headers.items()) if e.headers else CI()
            body = b""
            try:
                body = e.read(65536)
            except Exception:
                pass
            _last_req[0] = time.time()
            _log(cur, status, len(body))
            if status in (301, 302, 303, 307, 308):
                loc = headers.get("Location")
                hops += 1
                if not loc or hops > 5:
                    return (status, headers, None, "redirect problem")
                cur = urllib.parse.urljoin(cur, loc)
                continue
            if status in (429, 503):
                retries += 1
                if retries > 3:
                    return (status, headers, None, "gave up after 3 retries")
                ra = headers.get("Retry-After", "")
                wait = int(ra) if ra.strip().isdigit() else 30
                time.sleep(wait)
                continue
            return (status, headers, None, "HTTP %d" % status)
        except Exception as e:  # network error / timeout
            _last_req[0] = time.time()
            _log(cur, "ERR", 0)
            retries += 1
            if retries > 3:
                return (0, {}, None, "network error: %r" % (e,))
            time.sleep(30)


# ---------------------------------------------------------------- OAI listing

NS = {"o": "http://www.openarchives.org/OAI/2.0/", "a": "http://arxiv.org/OAI/arXiv/"}


def safe(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", s)


def get_listsets():
    p = os.path.join(LISTING, "ListSets.xml")
    if not os.path.exists(p):
        st, h, d, note = http_get(OAI_URL + "?verb=ListSets")
        if d is None:
            sys.exit("ListSets failed: %s %s" % (st, note))
        open(p, "wb").write(d)
    root = ET.parse(p).getroot()
    sets = {}
    for s in root.iter("{%s}set" % NS["o"]):
        sets[s.findtext("o:setSpec", namespaces=NS)] = s.findtext("o:setName", namespaces=NS)
    return sets


def parse_page(data):
    root = ET.fromstring(data)
    err = root.find("o:error", NS)
    if err is not None:
        return [], None, err.get("code")
    recs = []
    for r in root.iter("{%s}record" % NS["o"]):
        h = r.find("o:header", NS)
        if h is not None and h.get("status") == "deleted":
            continue
        a = r.find("o:metadata/a:arXiv", NS)
        if a is None:
            continue
        authors = []
        for au in a.findall("a:authors/a:author", NS):
            fn = (au.findtext("a:forenames", namespaces=NS) or "").strip()
            kn = (au.findtext("a:keyname", namespaces=NS) or "").strip()
            authors.append((fn + " " + kn).strip())
        recs.append({
            "id": a.findtext("a:id", namespaces=NS),
            "title": re.sub(r"\s+", " ", a.findtext("a:title", namespaces=NS) or "").strip(),
            "authors": "; ".join(authors),
            "license": (a.findtext("a:license", namespaces=NS) or "").strip(),
            "categories": (a.findtext("a:categories", namespaces=NS) or "").strip(),
        })
    tok = root.find("o:ListRecords/o:resumptionToken", NS)
    token = (tok.text or "").strip() if tok is not None and tok.text else None
    return recs, token, None


def list_field(setspec, frm, until):
    recs, page, token = [], 0, None
    while True:
        page += 1
        fn = os.path.join(LISTING, "%s_%s_%s_p%02d.xml" % (safe(setspec), frm, until, page))
        if os.path.exists(fn):
            data = open(fn, "rb").read()
        else:
            if token is None:
                url = "%s?verb=ListRecords&metadataPrefix=arXiv&set=%s&from=%s&until=%s" % (
                    OAI_URL, urllib.parse.quote(setspec, safe=":"), frm, until)
            else:
                url = "%s?verb=ListRecords&resumptionToken=%s" % (OAI_URL, urllib.parse.quote(token, safe=""))
            st, h, data, note = http_get(url)
            if data is None:
                sys.exit("listing failed for %s page %d: %s %s" % (setspec, page, st, note))
            open(fn, "wb").write(data)
        r, token, err = parse_page(data)
        if err and err != "noRecordsMatch":
            sys.exit("OAI error %s for %s" % (err, setspec))
        recs.extend(r)
        if not token:
            break
    return recs


def window_for(setspec):
    return tuple(WINDOWS.get(setspec, DEFAULT_WINDOW))


def build_candidates():
    """field -> sorted list of CC BY 4.0 records (deduplicated across fields via ASSIGN_ORDER)."""
    counts, kept_by_field, taken = {}, {}, set()
    allrecs = {}
    for f in FIELDS:
        frm, until = window_for(f)
        recs = list_field(f, frm, until)
        allrecs[f] = recs
    for f in ASSIGN_ORDER:
        if f not in allrecs:
            continue
        seen, keep = set(), []
        for r in allrecs[f]:
            if r["id"] in seen:
                continue
            seen.add(r["id"])
            if r["license"] == LICENSE and r["id"] not in taken:
                keep.append(r)
        for r in keep:
            taken.add(r["id"])
        kept_by_field[f] = sorted(keep, key=lambda r: r["id"])
    for f in FIELDS:
        ids = {r["id"] for r in allrecs[f]}
        n_all = len(ids)
        n_by = len({r["id"] for r in allrecs[f] if r["license"] == LICENSE})
        counts[f] = {"window": "%s..%s" % window_for(f), "records": n_all,
                     "cc_by_4_0": n_by, "cc_by_4_0_after_cross_list_dedupe": len(kept_by_field.get(f, []))}
    return kept_by_field, counts


# ---------------------------------------------------------------- BibTeX

def match_brace(s, i):
    """s[i] == '{'. Return index of matching '}' or -1 (all braces counted literally)."""
    depth = 0
    n = len(s)
    j = i
    while j < n:
        c = s[j]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return j
        j += 1
    return -1


_HDR = re.compile(r"^[ \t]*@([A-Za-z]+)[ \t]*([{(])", re.M)
_NAME = re.compile(r"[A-Za-z0-9_:.\-+/]+")
_BARE = re.compile(r"[^\s,#{}\"=]+")


def parse_fields(body):
    """body = text after 'key,' up to (excluding) the final '}'. Return (fields, has_macro) or None."""
    fields, macro = {}, False
    i, n = 0, len(body)
    while True:
        while i < n and body[i] in " \t\r\n,":
            i += 1
        if i >= n:
            return fields, macro
        m = _NAME.match(body, i)
        if not m:
            return None
        name = m.group(0).lower()
        i = m.end()
        while i < n and body[i] in " \t\r\n":
            i += 1
        if i >= n or body[i] != "=":
            return None
        i += 1
        pieces = []
        while True:
            while i < n and body[i] in " \t\r\n":
                i += 1
            if i >= n:
                return None
            c = body[i]
            if c == "{":
                e = match_brace(body, i)
                if e < 0:
                    return None
                pieces.append(body[i + 1:e])
                i = e + 1
            elif c == '"':
                j, depth = i + 1, 0
                while j < n:
                    cj = body[j]
                    if cj == "{":
                        depth += 1
                    elif cj == "}":
                        depth -= 1
                    elif cj == '"' and depth == 0:
                        break
                    j += 1
                if j >= n:
                    return None
                pieces.append(body[i + 1:j])
                i = j + 1
            else:
                m2 = _BARE.match(body, i)
                if not m2:
                    return None
                tok = m2.group(0)
                if not re.fullmatch(r"\d+", tok) and tok.lower() not in MONTHS:
                    macro = True
                pieces.append(tok)
                i = m2.end()
            while i < n and body[i] in " \t\r\n":
                i += 1
            if i < n and body[i] == "#":
                i += 1
                continue
            break
        if name not in fields:
            fields[name] = "".join(pieces)


def parse_bib(text):
    """Yield dicts for every @entry in text (text is latin-1 decoded bytes)."""
    out, pos = [], 0
    while True:
        m = _HDR.search(text, pos)
        if not m:
            break
        at = text.index("@", m.start())
        typ = m.group(1).lower()
        delim = m.group(2)
        open_i = m.end() - 1
        if delim == "(":
            pos = m.end()
            continue
        close = match_brace(text, open_i)
        if close < 0:
            pos = m.end()
            out.append({"type": typ, "bad": "unbalanced braces", "key": None})
            continue
        pos = close + 1
        if typ in ("string", "preamble", "comment"):
            continue
        inner = text[open_i + 1:close]
        km = re.match(r"\s*([^,\s{}=]+)\s*,", inner)
        if not km:
            out.append({"type": typ, "bad": "no key/fields", "key": None})
            continue
        key = km.group(1)
        kstart = open_i + 1 + km.start(1)
        kend = open_i + 1 + km.end(1)
        pf = parse_fields(inner[km.end():])
        ent = {"type": typ, "key": key, "text": text[at:close + 1],
               "kspan": (kstart - at, kend - at)}
        if pf is None:
            ent["bad"] = "unparseable fields"
        else:
            ent["fields"], ent["macro"] = pf
        out.append(ent)
    return out


def usable(ent):
    if ent.get("bad") or "fields" not in ent:
        return False
    if ent["macro"]:
        return False
    t, f = ent["type"], ent["fields"]
    if t in USABLE_TYPES:
        pass
    elif t in NEED_ID_TYPES:
        if not (f.get("doi", "").strip() or f.get("eprint", "").strip()):
            return False
    else:
        return False
    if not f.get("title", "").strip():
        return False
    if not (f.get("author", "").strip() or f.get("editor", "").strip()):
        return False
    yr = f.get("year", "") + " " + (f.get("date", "") if not f.get("year", "").strip() else "")
    if not re.search(r"\b\d{4}\b", yr):
        return False
    return True


def norm_title(t):
    return re.sub(r"[^a-z0-9]", "", t.lower())


def norm_doi(d):
    d = d.strip().lower()
    d = re.sub(r"^(https?://(dx\.)?doi\.org/|doi:)", "", d)
    return d.strip("{} ")


def usable_entries(bibbytes):
    text = bibbytes.decode("latin-1")
    res = []
    for e in parse_bib(text):
        if usable(e):
            f = e["fields"]
            e["has_doi"] = bool(f.get("doi", "").strip())
            e["has_eprint"] = bool(f.get("eprint", "").strip())
            res.append(e)
    return res


# ---------------------------------------------------------------- packages

def sha256(b):
    return hashlib.sha256(b).hexdigest()


def read_bibs_from_tar(data):
    """Return list of (member_name, bytes) for .bib members; never extracts to disk."""
    bibs = []
    tf = tarfile.open(fileobj=io.BytesIO(data), mode="r:*")
    while True:
        m = tf.next()
        if m is None:
            break
        if tf.offset > 1_500_000_000:
            break
        name = m.name
        if not m.isfile() or not name.lower().endswith(".bib"):
            continue
        if name.startswith("/") or ".." in name.replace("\\", "/").split("/"):
            continue
        if m.size > 20 * 1024 * 1024:
            continue
        fh = tf.extractfile(m)
        if fh is None:
            continue
        bibs.append((name, fh.read()))
    return bibs


def load_outcomes():
    p = os.path.join(STATE, "outcomes.json")
    return json.load(open(p)) if os.path.exists(p) else {}


def save_outcomes(o):
    os.makedirs(STATE, exist_ok=True)
    json.dump(o, open(os.path.join(STATE, "outcomes.json"), "w"), indent=1, sort_keys=True)


def total_downloaded():
    n = 0
    if os.path.exists(REQLOG):
        for line in open(REQLOG):
            p = line.rstrip("\n").split("\t")
            if len(p) == 4 and "/e-print/" in p[1] or (len(p) == 4 and "/src/" in p[1]):
                try:
                    n += int(p[3])
                except ValueError:
                    pass
    return n


TEMPLATE_NAMES = {"ieeeexample.bib", "ieeeabrv.bib", "ieeefull.bib", "ieeebcpat.bib", "sample.bib",
                  "sample-base.bib", "example.bib", "template.bib"}
SEEN_BIB_HASHES = set()  # SHA-256 of every .bib seen in earlier candidate packages (template files repeat)


def evaluate_package(aid, data, out):
    """Fill outcome dict `out` from tarball bytes. Saves chosen .bib to originals/."""
    out["sha256"] = sha256(data)
    out["size"] = len(data)
    try:
        bibs = read_bibs_from_tar(data)
    except Exception as e:
        out["outcome"] = "not a tarball"
        out["detail"] = type(e).__name__
        return
    if not bibs:
        out["outcome"] = "no .bib"
        return
    best = None
    ncounts = []
    ignored = []
    own_hashes = []
    for name, b in bibs:
        h = sha256(b)
        own_hashes.append(h)
        if os.path.basename(name).lower() in TEMPLATE_NAMES:
            ignored.append(os.path.basename(name) + "(template name)")
            continue
        if h in SEEN_BIB_HASHES:
            ignored.append(os.path.basename(name) + "(same hash as .bib of earlier package)")
            continue
        ue = usable_entries(b)
        ncounts.append("%s:%d" % (os.path.basename(name), len(ue)))
        if len(ue) >= MIN_ENTRIES and (best is None or len(b) > len(best[1])):
            best = (name, b, len(ue))
    out["detail"] = (" ".join(ncounts) + (" IGNORED: " + ", ".join(ignored) if ignored else ""))[:400]
    out["bib_hashes"] = own_hashes
    SEEN_BIB_HASHES.update(own_hashes)
    if best is None:
        if ignored and not ncounts:
            out["outcome"] = "no usable .bib (template files only)"
        else:
            out["outcome"] = "too few entries"
        return
    name, b, n = best
    bn = safe(os.path.basename(name))
    d = os.path.join(ORIG, safe(aid))
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, bn), "wb").write(b)
    out["outcome"] = "accepted"
    out["bib"] = bn
    out["usable"] = n


def process_candidate(rec, field, outcomes):
    aid = rec["id"]
    if aid in outcomes:
        return outcomes[aid]
    out = {"field": field}
    # downloaded budget
    if total_downloaded() > TOTAL_CAP - MAX_PKG:
        out["outcome"] = "download failed"
        out["detail"] = "total download cap reached"
        outcomes[aid] = out
        save_outcomes(outcomes)
        return out
    data, hdrs, note = None, {}, ""
    for url in ("https://export.arxiv.org/e-print/" + aid,
                "https://arxiv.org/e-print/" + aid,
                "https://arxiv.org/src/" + aid):
        st, hdrs, data, note = http_get(url, maxbytes=MAX_PKG)
        if data is not None:
            break
        if note.startswith("too large"):
            break
    if data is None:
        out["outcome"] = "too large" if note.startswith("too large") else "download failed"
        out["detail"] = note
        outcomes[aid] = out
        save_outcomes(outcomes)
        return out
    cd = hdrs.get("Content-Disposition", "")
    m = re.search(r"v(\d+)(?:\.|\")", cd)
    out["version"] = "v" + m.group(1) if m else "v?"
    out["ctype"] = hdrs.get("Content-Type", "")
    ext = ".tar.gz"
    if data[:4] == b"%PDF":
        ext = ".pdf"
    elif data[:2] != b"\x1f\x8b":
        ext = ".bin"
    open(os.path.join(RAW, safe(aid) + ext), "wb").write(data)
    if ext != ".tar.gz":
        out["sha256"], out["size"] = sha256(data), len(data)
        out["outcome"] = "not a tarball"
        out["detail"] = "pdf" if ext == ".pdf" else "unknown format"
    else:
        evaluate_package(aid, data, out)
        if out["outcome"] == "not a tarball":
            # single gzip'd file (e.g. lone .tex)
            out["detail"] = out.get("detail", "") + " (gzip, not tar)"
    outcomes[aid] = out
    save_outcomes(outcomes)
    return out


def fetch_stage(cands):
    os.makedirs(RAW, exist_ok=True)
    outcomes = load_outcomes()
    order = []  # (field, rec) tried in order
    accepted = []  # (field, rec)
    for f in FIELDS:
        tried = 0
        acc = 0
        rng = random.Random(SEED)
        lst = list(cands.get(f, []))  # sorted by id
        rng.shuffle(lst)
        for rec in lst:
            if acc >= PER_FIELD_ACCEPT or tried >= PER_FIELD_TRY:
                break
            tried += 1
            c = outcomes.get(rec["id"])
            if c is not None:
                if c.get("outcome") == "accepted":
                    hs = c.get("bib_hashes") or [sha256(open(os.path.join(ORIG, safe(rec["id"]), c["bib"]), "rb").read())]
                    if c["bib"].lower() in TEMPLATE_NAMES or (set(hs) & SEEN_BIB_HASHES):
                        del outcomes[rec["id"]]  # re-evaluate under the template rule (re-download)
                        c = None
                    else:
                        SEEN_BIB_HASHES.update(hs)
                elif c.get("bib_hashes"):
                    SEEN_BIB_HASHES.update(c["bib_hashes"])
            out = process_candidate(rec, f, outcomes)
            order.append((f, rec, out))
            print("%-18s %-14s %s" % (f, rec["id"], out["outcome"]), flush=True)
            if out["outcome"] == "accepted":
                acc += 1
                accepted.append((f, rec, out))
    return order, accepted


# ---------------------------------------------------------------- selection

def select(accepted, dropped):
    papers = []
    for idx, (f, rec, out) in enumerate(accepted):
        b = open(os.path.join(ORIG, safe(rec["id"]), out["bib"]), "rb").read()
        ents = usable_entries(b)
        random.Random(SEED + idx).shuffle(ents)
        papers.append({"idx": idx, "field": f, "rec": rec, "out": out, "ents": ents, "ptr": 0, "n": 0})
    picked, seen_doi, seen_title = [], set(), set()
    need = {"doi": N_DOI, "nodoi": N_NODOI}
    progress = True
    while len(picked) < N_DOI + N_NODOI and progress:
        progress = False
        for p in papers:
            if len(picked) >= N_DOI + N_NODOI:
                break
            if p["n"] >= MAX_PER_PAPER:
                continue
            while p["ptr"] < len(p["ents"]):
                e = p["ents"][p["ptr"]]
                p["ptr"] += 1
                if (p["rec"]["id"], e["key"]) in dropped:
                    continue
                cat = "doi" if e["has_doi"] else "nodoi"
                if need[cat] <= 0:
                    # keep for possible later use? categories only shrink, so skip permanently
                    continue
                d = norm_doi(e["fields"].get("doi", "")) if e["has_doi"] else None
                t = norm_title(e["fields"]["title"])
                if (d and d in seen_doi) or t in seen_title:
                    continue
                if d:
                    seen_doi.add(d)
                seen_title.add(t)
                need[cat] -= 1
                p["n"] += 1
                picked.append((p, e))
                progress = True
                break
    return papers, picked, need


def write_outputs(papers, picked, order, counts, need):
    bibout = []
    sel = []
    for i, (p, e) in enumerate(picked, 1):
        nk = "real_human_%03d" % i
        a, b = e["kspan"]
        txt = e["text"][:a] + nk + e["text"][b:]
        bibout.append(txt)
        sel.append((nk, p["rec"]["id"], p["out"]["bib"], e["key"], e["type"],
                    "yes" if e["has_doi"] else "no", "yes" if e["has_eprint"] else "no"))
    with open(os.path.join(HERE, "real_human.bib"), "wb") as f:
        f.write(("\n\n".join(bibout) + "\n").encode("latin-1"))
    def tsv(path, header, rows):
        with open(os.path.join(HERE, path), "w", encoding="utf-8") as f:
            f.write("\t".join(header) + "\n")
            for r in rows:
                f.write("\t".join(str(x).replace("\t", " ").replace("\n", " ") for x in r) + "\n")
    tsv("selection.tsv", ["new_key", "arxiv_id", "bib_file", "original_key", "entry_type", "has_doi", "has_eprint"], sel)
    rows = []
    for p in papers:
        r, o = p["rec"], p["out"]
        rows.append((r["id"] + o.get("version", ""), p["field"], r["title"], r["authors"], LICENSE,
                     o["sha256"], o["size"], o["bib"], o["usable"], p["n"]))
    tsv("papers.tsv", ["arxiv_id_version", "field_set", "title", "authors", "license", "source_sha256",
                       "source_size_bytes", "bib_file", "usable_entries", "picked"], rows)
    rows = []
    for k, (f, rec, o) in enumerate(order, 1):
        rows.append((k, f, rec["id"] + o.get("version", ""), o["outcome"], o.get("size", ""),
                     o.get("sha256", ""), o.get("detail", "")))
    tsv("candidates.tsv", ["order", "field_set", "arxiv_id", "outcome", "size_bytes", "sha256", "detail"], rows)
    stats = {"field_counts": counts, "need_left": need, "picked": len(picked),
             "doi": sum(1 for _, e in picked if e["has_doi"]),
             "nodoi": sum(1 for _, e in picked if not e["has_doi"]),
             "papers": len(papers)}
    json.dump(stats, open(os.path.join(HERE, "run_stats.json"), "w"), indent=1)
    print(json.dumps(stats, indent=1))


def load_dropped(p):
    s = set()
    if os.path.exists(p):
        for line in open(p, encoding="utf-8").read().splitlines()[1:]:
            c = line.split("\t")
            if len(c) >= 2:
                s.add((c[0], c[1]))
    return s


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dropped", default=None, help="optional TSV (arxiv_id, original_key, ...) of entries to exclude")
    ap.add_argument("--stage", default="all", choices=["listing", "fetch", "select", "all"])
    a = ap.parse_args()
    for d in (LISTING, ORIG, STATE, RAW):
        os.makedirs(d, exist_ok=True)
    wp = os.path.join(STATE, "windows.json")
    if os.path.exists(wp):
        WINDOWS.update({k: tuple(v) for k, v in json.load(open(wp)).items()})
    sets = get_listsets()
    missing = [f for f in FIELDS if f not in sets]
    if missing:
        sys.exit("set specs not found in ListSets: %s" % missing)
    cands, counts = build_candidates()
    print(json.dumps(counts, indent=1))
    if a.stage == "listing":
        return
    order, accepted = fetch_stage(cands)
    if a.stage == "fetch":
        return
    papers, picked, need = select(accepted, load_dropped(a.dropped) if a.dropped else set())
    write_outputs(papers, picked, order, counts, need)


if __name__ == "__main__":
    main()
