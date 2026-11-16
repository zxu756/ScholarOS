#!/usr/bin/env python3
"""Independent "does this work exist?" check for the fabricated group (does not use the product).

  python3 -I tools/search_check.py <out-dir> <a.bib> [<b.bib> ...]

For every entry it asks the public registries directly:
  - DOI:   api.crossref.org/works/<doi>, api.openalex.org/works/https://doi.org/<doi>, doi.org/api/handles/<doi>
  - arXiv: export.arxiv.org/api/query?id_list=<id>
  - PMID:  eutils.ncbi.nlm.nih.gov esummary
  - title: Crossref query.bibliographic (title, first author surname, year; 5 rows) and OpenAlex search (title; 5 rows)
and writes <out-dir>/evidence/<key>.json, <out-dir>/raw/<sha1>.json (every raw response, reused on reruns)
and <out-dir>/search-summary.tsv.

Requests carry only a generic User-Agent: no e-mail address, no key. One request at a time, spaced per source.
"""
import datetime
import difflib
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_batch import parse_entries  # noqa: E402

UA = "ScholarOS-benchmark/1.0"
SPACING = {"api.crossref.org": 1.1, "api.openalex.org": 0.3, "doi.org": 0.3,
           "export.arxiv.org": 3.2, "eutils.ncbi.nlm.nih.gov": 0.5}
ALLOWED = set(SPACING)
last_request = {}
stats = {"network": 0, "reused": 0, "openalex_first": None, "openalex_last": None}


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def fetch(url, raw_dir):
    """GET with on-disk reuse. Returns dict(url, status, fetched_at, headers, body, error)."""
    host = urllib.parse.urlsplit(url).hostname
    if host not in ALLOWED:
        raise SystemExit("refusing to contact %s" % host)
    path = os.path.join(raw_dir, hashlib.sha1(url.encode()).hexdigest() + ".json")
    if os.path.exists(path):
        rec = json.load(open(path, encoding="utf-8"))
        if rec.get("status") in (200, 404):
            stats["reused"] += 1
            return rec
    rec = None
    for attempt in range(4):
        wait = SPACING[host] - (time.time() - last_request.get(host, 0))
        if wait > 0:
            time.sleep(wait)
        req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
        status, body, headers, error = None, b"", {}, None
        try:
            with urllib.request.urlopen(req, timeout=40) as resp:
                status, body, headers = resp.status, resp.read(), dict(resp.headers.items())
        except urllib.error.HTTPError as e:
            status, body, headers = e.code, e.read(), dict(e.headers.items())
        except Exception as e:  # timeout, connection reset, DNS
            error = "%s: %s" % (type(e).__name__, e)
        last_request[host] = time.time()
        stats["network"] += 1
        keep = {k.lower(): v for k, v in headers.items()
                if k.lower() in ("date", "retry-after", "x-ratelimit-remaining", "x-ratelimit-limit",
                                 "x-rate-limit-limit", "x-rate-limit-interval", "content-type")}
        rec = {"url": url, "status": status, "fetched_at": now(), "headers": keep,
               "body": body.decode("utf-8", "replace"), "error": error}
        if host == "api.openalex.org" and "x-ratelimit-remaining" in keep:
            if stats["openalex_first"] is None:
                stats["openalex_first"] = keep["x-ratelimit-remaining"]
            stats["openalex_last"] = keep["x-ratelimit-remaining"]
        if status in (429, 503) or error:
            if attempt == 3:
                break
            try:
                pause = min(60.0, float(keep.get("retry-after", "")))
            except ValueError:
                pause = [5.0, 15.0, 30.0][attempt]
            time.sleep(pause)
            continue
        break
    json.dump(rec, open(path, "w", encoding="utf-8"), ensure_ascii=False)
    return rec


def plain(text):
    text = re.sub(r"\$[^$]*\$", " ", text or "")
    text = re.sub(r"\\[a-zA-Z]+\s*", "", text)
    text = re.sub(r"\\.", "", text)
    text = text.replace("{", "").replace("}", "")
    return re.sub(r"\s+", " ", text).strip()


def norm(text):
    return re.sub(r"[^a-z0-9]+", " ", plain(text).lower()).strip()


def first_surname(author_field):
    first = re.split(r"\s+and\s+", author_field or "", maxsplit=1)[0]
    first = plain(first)
    if "," in first:
        return first.split(",")[0].strip()
    return first.split()[-1] if first.split() else ""


def similarity(a, b):
    a, b = norm(a), norm(b)
    if not a or not b:
        return 0.0
    return round(difflib.SequenceMatcher(None, a, b).ratio(), 3)


def body_json(rec):
    try:
        return json.loads(rec["body"])
    except Exception:
        return None


def check_doi(doi, raw_dir):
    q = urllib.parse.quote(doi, safe="/")
    out = {"kind": "doi", "value": doi, "requests": []}
    cr = fetch("https://api.crossref.org/works/" + q, raw_dir)
    oa = fetch("https://api.openalex.org/works/https://doi.org/" + q, raw_dir)
    hd = fetch("https://doi.org/api/handles/" + q, raw_dir)
    for name, rec in (("Crossref", cr), ("OpenAlex", oa), ("doi.org", hd)):
        out["requests"].append({"source": name, "url": rec["url"], "status": rec["status"],
                                "fetched_at": rec["fetched_at"], "error": rec["error"]})
    handle = body_json(hd) or {}
    out["doi_org_response_code"] = handle.get("responseCode")
    real_title = None
    if cr["status"] == 200:
        msg = (body_json(cr) or {}).get("message", {})
        real_title = (msg.get("title") or [None])[0]
        out["registered_work"] = {"source": "Crossref", "title": real_title,
                                  "container": (msg.get("container-title") or [None])[0],
                                  "year": ((msg.get("issued") or {}).get("date-parts") or [[None]])[0][0]}
    elif oa["status"] == 200:
        w = body_json(oa) or {}
        real_title = w.get("title") or w.get("display_name")
        out["registered_work"] = {"source": "OpenAlex", "title": real_title, "year": w.get("publication_year")}
    if real_title is not None or handle.get("responseCode") == 1:
        out["outcome"] = "exists"
    elif cr["status"] == 404 and oa["status"] == 404 and handle.get("responseCode") == 100:
        out["outcome"] = "not_registered"
    else:
        out["outcome"] = "inconclusive"
    return out


def check_arxiv(arxiv_id, raw_dir):
    rec = fetch("https://export.arxiv.org/api/query?id_list=" + urllib.parse.quote(arxiv_id), raw_dir)
    out = {"kind": "arxiv", "value": arxiv_id,
           "requests": [{"source": "arXiv", "url": rec["url"], "status": rec["status"],
                         "fetched_at": rec["fetched_at"], "error": rec["error"]}]}
    body = rec["body"] or ""
    entry = re.search(r"<entry>(.*?)</entry>", body, re.S)
    title = re.search(r"<title>(.*?)</title>", entry.group(1), re.S) if entry else None
    if rec["status"] == 200 and entry and title and "<id>" in entry.group(1):
        out["outcome"] = "exists"
        authors = re.findall(r"<name>(.*?)</name>", entry.group(1), re.S)
        out["registered_work"] = {"source": "arXiv", "title": re.sub(r"\s+", " ", title.group(1)).strip(),
                                  "first_author": authors[0] if authors else None,
                                  "year": (re.search(r"<published>(\d{4})", entry.group(1)) or [None, None])[1]}
    elif rec["status"] == 200:
        out["outcome"] = "not_registered"
    else:
        out["outcome"] = "inconclusive"
    return out


def check_pmid(pmid, raw_dir):
    rec = fetch("https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&id=%s&retmode=json" % pmid, raw_dir)
    out = {"kind": "pmid", "value": pmid,
           "requests": [{"source": "PubMed", "url": rec["url"], "status": rec["status"],
                         "fetched_at": rec["fetched_at"], "error": rec["error"]}]}
    doc = ((body_json(rec) or {}).get("result") or {}).get(pmid)
    if rec["status"] == 200 and isinstance(doc, dict) and doc.get("title") and not doc.get("error"):
        out["outcome"] = "exists"
        out["registered_work"] = {"source": "PubMed", "title": doc.get("title"),
                                  "first_author": (doc.get("authors") or [{}])[0].get("name"),
                                  "year": (doc.get("pubdate") or "")[:4], "container": doc.get("source")}
    elif rec["status"] == 200:
        out["outcome"] = "not_registered"
    else:
        out["outcome"] = "inconclusive"
    return out


def title_search(fields, raw_dir, use_openalex):
    title = plain(fields.get("title", ""))
    surname = first_surname(fields.get("author") or fields.get("editor") or "")
    year = fields.get("year", "")
    out = {"requests": [], "candidates": []}
    query = " ".join(x for x in (title, surname, year) if x)
    cr = fetch("https://api.crossref.org/works?" + urllib.parse.urlencode(
        {"query.bibliographic": query, "rows": 5,
         "select": "DOI,title,author,issued,container-title,type"}), raw_dir)
    out["requests"].append({"source": "Crossref", "url": cr["url"], "status": cr["status"],
                            "fetched_at": cr["fetched_at"], "error": cr["error"]})
    for item in ((body_json(cr) or {}).get("message") or {}).get("items") or []:
        cand_title = (item.get("title") or [""])[0]
        out["candidates"].append({
            "source": "Crossref", "title": cand_title, "doi": item.get("DOI"),
            "first_author": ((item.get("author") or [{}])[0]).get("family"),
            "year": ((item.get("issued") or {}).get("date-parts") or [[None]])[0][0],
            "container": (item.get("container-title") or [None])[0],
            "similarity": similarity(title, cand_title)})
    if use_openalex:
        oa = fetch("https://api.openalex.org/works?" + urllib.parse.urlencode(
            {"search": title, "per-page": 5,
             "select": "id,doi,title,publication_year,authorships"}), raw_dir)
        out["requests"].append({"source": "OpenAlex", "url": oa["url"], "status": oa["status"],
                                "fetched_at": oa["fetched_at"], "error": oa["error"]})
        for item in (body_json(oa) or {}).get("results") or []:
            auth = (item.get("authorships") or [{}])[0].get("author") or {}
            out["candidates"].append({
                "source": "OpenAlex", "title": item.get("title") or "", "doi": item.get("doi"),
                "first_author": auth.get("display_name"), "year": item.get("publication_year"),
                "similarity": similarity(title, item.get("title") or "")})
    else:
        out["requests"].append({"source": "OpenAlex", "url": None, "status": None, "fetched_at": None,
                                "error": "skipped: daily budget too low"})
    out["searched_ok"] = all(r["status"] == 200 for r in out["requests"])
    best = max(out["candidates"], key=lambda c: c["similarity"], default=None)
    out["best"] = best
    return out


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out_dir = sys.argv[1]
    raw_dir = os.path.join(out_dir, "raw")
    ev_dir = os.path.join(out_dir, "evidence")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(ev_dir, exist_ok=True)
    rows = []
    for bib in sys.argv[2:]:
        for etype, key, fields in parse_entries(open(bib, encoding="utf-8").read()):
            if fields.get("doi"):
                ident = check_doi(fields["doi"], raw_dir)
            elif fields.get("eprint"):
                ident = check_arxiv(fields["eprint"], raw_dir)
            elif fields.get("pmid"):
                ident = check_pmid(fields["pmid"], raw_dir)
            else:
                ident = {"kind": "none", "value": "", "outcome": "none", "requests": []}
            budget = stats["openalex_last"]
            use_oa = budget is None or int(budget) >= 50
            search = title_search(fields, raw_dir, use_oa)
            best = search["best"] or {}
            sim = best.get("similarity", 0.0)
            same_author = bool(best) and norm(first_surname(fields.get("author", ""))) != "" and \
                norm(first_surname(fields.get("author", ""))) in norm(str(best.get("first_author") or ""))
            if ident["outcome"] == "inconclusive" or not search["searched_ok"]:
                flag = "inconclusive"
            elif sim >= 0.8 and same_author:
                flag = "possible_real_work"
            elif sim >= 0.8:
                flag = "title_close"
            elif ident["outcome"] == "exists":
                flag = "identifier_collision"
            else:
                flag = "clean"
            evidence = {"key": key, "source_file": os.path.basename(bib), "entry_type": etype, "fields": fields,
                        "identifier": ident, "title_search": search, "flag": flag, "checked_at": now(),
                        "method": "tools/search_check.py; title similarity = difflib ratio on lower-cased alphanumerics"}
            json.dump(evidence, open(os.path.join(ev_dir, key + ".json"), "w", encoding="utf-8"),
                      ensure_ascii=False, indent=1)
            reg = ident.get("registered_work") or {}
            rows.append([key, ident["kind"], ident["value"], ident["outcome"], plain(str(reg.get("title") or "")),
                         "%.3f" % sim, best.get("source", ""), plain(str(best.get("title") or "")),
                         str(best.get("first_author") or ""), str(best.get("year") or ""), flag,
                         plain(fields.get("title", ""))])
            print("%-16s %-5s %-15s best=%.2f %s" % (key, ident["kind"], ident["outcome"], sim, flag), flush=True)
    with open(os.path.join(out_dir, "search-summary.tsv"), "w", encoding="utf-8") as f:
        f.write("\t".join(["key", "identifier_kind", "identifier", "identifier_outcome", "registered_title",
                           "best_title_similarity", "best_source", "best_candidate_title", "best_first_author",
                           "best_year", "flag", "fabricated_title"]) + "\n")
        for r in rows:
            f.write("\t".join(x.replace("\t", " ") for x in r) + "\n")
    flags = {}
    for r in rows:
        flags[r[10]] = flags.get(r[10], 0) + 1
    print("entries: %d  flags: %s" % (len(rows), flags))
    print("requests sent: %d  responses reused from disk: %d  OpenAlex x-ratelimit-remaining: %s -> %s" % (
        stats["network"], stats["reused"], stats["openalex_first"], stats["openalex_last"]))


if __name__ == "__main__":
    main()
