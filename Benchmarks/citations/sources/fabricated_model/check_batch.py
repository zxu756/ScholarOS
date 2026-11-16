#!/usr/bin/env python3
"""Format check for one batch of fabricated BibTeX entries (no network).

  python3 tools/check_batch.py fabricated/<agent>.bib <agent>

Exits 0 when the batch has exactly 40 entries with the agreed keys, fields and
identifier mix; prints every problem and exits 1 otherwise.
"""
import os
import re
import sys

WANT = {"doi": 22, "arxiv": 4, "pmid": 2, "none": 12}


def parse_entries(text):
    """Return [(type, key, {field: value})] using brace matching; raise ValueError on unbalanced braces."""
    out, i, n = [], 0, len(text)
    while True:
        at = text.find("@", i)
        if at < 0:
            break
        m = re.match(r"@\s*([A-Za-z]+)\s*\{", text[at:])
        if not m:
            i = at + 1
            continue
        etype = m.group(1).lower()
        brace = at + m.end() - 1
        depth, j = 0, brace
        while j < n:
            c = text[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        if depth != 0:
            raise ValueError("unbalanced braces in the entry starting at offset %d" % at)
        body = text[brace + 1 : j]
        comma = body.find(",")
        key = (body if comma < 0 else body[:comma]).strip()
        fields = parse_fields(body[comma + 1 :] if comma >= 0 else "")
        out.append((etype, key, fields))
        i = j + 1
    return out


def parse_fields(body):
    fields, i, n = {}, 0, len(body)
    while i < n:
        m = re.compile(r"\s*([A-Za-z][A-Za-z0-9_-]*)\s*=\s*").match(body, i)
        if not m:
            break
        name = m.group(1).lower()
        i = m.end()
        if i < n and body[i] == "{":
            depth, j = 0, i
            while j < n:
                if body[j] == "{":
                    depth += 1
                elif body[j] == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            value = body[i + 1 : j]
            i = j + 1
        elif i < n and body[i] == '"':
            j = body.find('"', i + 1)
            value = body[i + 1 : j]
            i = j + 1
        else:
            j = i
            while j < n and body[j] not in ",\n":
                j += 1
            value = body[i:j].strip()
            i = j
        fields[name] = re.sub(r"\s+", " ", value).strip()
        while i < n and body[i] in ", \t\r\n":
            i += 1
    return fields


def identifier_kind(fields):
    kinds = []
    if fields.get("doi"):
        kinds.append("doi")
    if fields.get("eprint") or fields.get("arxivid") or fields.get("arxiv"):
        kinds.append("arxiv")
    if fields.get("pmid"):
        kinds.append("pmid")
    return kinds


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, agent = sys.argv[1], sys.argv[2]
    problems = []
    text = open(path, encoding="utf-8").read()
    try:
        entries = parse_entries(text)
    except ValueError as e:
        sys.exit("FAIL: %s" % e)
    if len(entries) != 40:
        problems.append("expected 40 entries, found %d" % len(entries))
    counts = {"doi": 0, "arxiv": 0, "pmid": 0, "none": 0}
    titles = {}
    for idx, (etype, key, f) in enumerate(entries, 1):
        want_key = "fab_%s_%03d" % (agent, idx)
        if key != want_key:
            problems.append("entry %d: key is '%s', expected '%s'" % (idx, key, want_key))
        if etype not in ("article", "inproceedings", "book", "incollection", "phdthesis", "techreport", "misc"):
            problems.append("%s: unexpected entry type @%s" % (key, etype))
        for need in ("title", "year"):
            if not f.get(need):
                problems.append("%s: missing %s" % (key, need))
        if not (f.get("author") or f.get("editor")):
            problems.append("%s: missing author" % key)
        if f.get("year") and not re.fullmatch(r"(199\d|20[01]\d|202[0-5])", f["year"]):
            problems.append("%s: year '%s' is not a single year between 1990 and 2025" % (key, f["year"]))
        kinds = identifier_kind(f)
        if len(kinds) > 1:
            problems.append("%s: more than one identifier kind (%s)" % (key, ", ".join(kinds)))
        kind = kinds[0] if kinds else "none"
        counts[kind] += 1
        if kind == "doi" and not re.fullmatch(r"10\.\d{4,9}/\S+", f["doi"]):
            problems.append("%s: doi '%s' is not a bare DOI (10.xxxx/suffix, no URL prefix)" % (key, f["doi"]))
        if kind == "arxiv":
            if not re.fullmatch(r"\d{4}\.\d{4,5}", f.get("eprint", "")):
                problems.append("%s: eprint must look like 2103.04567" % key)
            if f.get("archiveprefix", "").lower() != "arxiv":
                problems.append("%s: archivePrefix must be arXiv" % key)
        if kind == "pmid" and not re.fullmatch(r"\d{7,8}", f["pmid"]):
            problems.append("%s: pmid must be 7 or 8 digits" % key)
        if kind == "none":
            for banned in ("url", "isbn", "issn", "howpublished", "note"):
                if f.get(banned):
                    problems.append("%s: entries without an identifier must not have a %s field" % (key, banned))
        for banned in ("x-firewall-class", "x-firewall-note", "abstract", "keywords", "file"):
            if banned in f:
                problems.append("%s: remove the %s field" % (key, banned))
        t = re.sub(r"[^a-z0-9]+", " ", f.get("title", "").lower()).strip()
        if t in titles:
            problems.append("%s: same title as %s" % (key, titles[t]))
        titles[t] = key
    for kind, want in WANT.items():
        if counts[kind] != want:
            problems.append("identifier mix: %d entries of kind '%s', expected %d" % (counts[kind], kind, want))
    topics = os.path.splitext(path)[0] + ".topics.tsv"
    if not os.path.exists(topics):
        problems.append("missing %s" % topics)
    else:
        rows = [l.rstrip("\n").split("\t") for l in open(topics, encoding="utf-8") if l.strip()]
        keys = [r[0] for r in rows]
        if keys != [k for _, k, _ in entries]:
            problems.append("%s: first column must list the 40 keys in the same order as the .bib" % topics)
        if any(len(r) < 2 or not r[1].strip() for r in rows):
            problems.append("%s: every line needs key<TAB>topic" % topics)
    if problems:
        print("FAIL (%d problems)" % len(problems))
        for p in problems:
            print(" - " + p)
        sys.exit(1)
    print("OK: 40 entries, identifiers %s" % counts)


if __name__ == "__main__":
    main()
