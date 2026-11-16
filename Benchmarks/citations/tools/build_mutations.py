#!/usr/bin/env python3
"""Build the 7 deterministic mutation groups from 'real_clean' and its Crossref raw records.

Usage:
  # Offline deterministic generation of 6 groups (120 entries: real_typo, mut_year1,
  # mut_year3, mut_author, mut_title, mut_doi_swap):
  python3 -I Benchmarks/citations/tools/build_mutations.py [--seed 20261116]

  # Generate all 7 groups (140 entries), confirming mut_doi_missing against doi.org Handle API
  # (accepting only responseCode == 100; saves raw responses in sources/mut_doi_missing/raw/):
  python3 -I Benchmarks/citations/tools/build_mutations.py [--seed 20261116] --confirm-missing

  # Rebuild all 7 groups offline from saved doi.org responses (zero network requests):
  python3 -I Benchmarks/citations/tools/build_mutations.py [--seed 20261116] --confirm-missing --offline
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from _common import (  # noqa: E402
    BenchmarkHTTPClient,
    BenchmarkToolError,
    ParsedBibEntry,
    crossref_work_url,
    default_bench_dir,
    doi_handle_url,
    doi_prefix,
    extract_all_crossref_years,
    extract_author_surname,
    has_balanced_braces,
    normalize_alnum_words,
    normalize_doi,
    parse_bibtex_entries,
    split_bibtex_authors,
    strip_latex_accents,
    update_gold_jsonl,
    url_sha1_filename,
)

DEFAULT_SEED = 20261116
PER_GROUP_COUNT = 20
MAX_HANDLE_ATTEMPTS_PER_ENTRY = 50
_SUFFIX_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"
_AUXILIARY_WORDS = frozenset({
    "is", "are", "was", "were", "can", "could", "will", "would",
    "should", "may", "might", "do", "does", "did", "has", "have",
})


class CleanSourceRecord:
    def __init__(
        self,
        entry: ParsedBibEntry,
        gold_row: Dict[str, Any],
        crossref_msg: Dict[str, Any],
    ) -> None:
        self.entry = entry
        self.key = entry.key
        self.gold_row = gold_row
        self.crossref_msg = crossref_msg
        prov = gold_row.get("provenance") or {}
        self.stratum = str(prov.get("stratum") or "")
        self.field_name = str(prov.get("field") or "")
        self.field_slug = str(prov.get("field_slug") or self.field_name)
        self.doi = entry.fields.get("doi", "").strip()
        self.title = entry.fields.get("title", "").strip()
        self.year = int(entry.fields["year"].strip())
        self.authors = split_bibtex_authors(entry.fields.get("author", ""))
        self.first_author_full = self.authors[0] if self.authors else ""
        self.first_surname = extract_author_surname(self.first_author_full)
        self.all_record_years = sorted(
            set(extract_all_crossref_years(crossref_msg)) | {self.year}
        )


def load_real_clean_sources(bench_dir: str) -> List[CleanSourceRecord]:
    bib_path = os.path.join(bench_dir, "entries", "real_clean.bib")
    gold_path = os.path.join(bench_dir, "gold.jsonl")
    raw_dir = os.path.join(bench_dir, "sources", "real_clean", "raw")

    if not os.path.exists(bib_path):
        raise BenchmarkToolError("Missing %s (run build_real_clean.py first)" % bib_path)
    if not os.path.exists(gold_path):
        raise BenchmarkToolError("Missing %s" % gold_path)

    with open(bib_path, encoding="utf-8") as f:
        parsed_entries = parse_bibtex_entries(f.read())

    gold_by_key: Dict[str, Dict[str, Any]] = {}
    with open(gold_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if obj.get("group") == "real_clean":
                gold_by_key[obj["key"]] = obj

    if not parsed_entries:
        raise BenchmarkToolError("entries/real_clean.bib has 0 entries")

    records: List[CleanSourceRecord] = []
    for entry in parsed_entries:
        if entry.key not in gold_by_key:
            raise BenchmarkToolError(
                "Key %s in entries/real_clean.bib is missing from gold.jsonl" % entry.key
            )
        grow = gold_by_key[entry.key]
        prov = grow.get("provenance") or {}
        cr_url = prov.get("crossref_url") or crossref_work_url(entry.fields.get("doi", ""))
        raw_path = os.path.join(raw_dir, url_sha1_filename(cr_url))
        if not os.path.exists(raw_path):
            raise BenchmarkToolError(
                "Missing Crossref raw record for %s at %s" % (entry.key, raw_path)
            )
        with open(raw_path, encoding="utf-8") as rf:
            envelope = json.load(rf)
        body_obj = json.loads(envelope["body"])
        msg = body_obj.get("message")
        if not isinstance(msg, dict):
            raise BenchmarkToolError(
                "Invalid Crossref message in raw record for %s" % entry.key
            )
        records.append(CleanSourceRecord(entry, grow, msg))

    return records


# ---------------------------------------------------------------------------
# Individual Deterministic String Mutation Helpers
# ---------------------------------------------------------------------------


def mutate_single_letter_title_typo(title: str, rng: random.Random) -> str:
    """Introduce a deterministic 1-letter substitution in an alphabetic word of title."""
    tokens = title.split(" ")
    eligible_indices = [
        idx
        for idx, tok in enumerate(tokens)
        if re.fullmatch(r"[A-Za-z]{4,}[.,:;?!]?", tok)
    ]
    if not eligible_indices:
        eligible_indices = [
            idx
            for idx, tok in enumerate(tokens)
            if re.search(r"[A-Za-z]{2,}", tok) and "{" not in tok and "\\" not in tok
        ]
    if not eligible_indices:
        raise BenchmarkToolError("Cannot introduce single-letter typo into title %r" % title)

    orig_norm = normalize_alnum_words(title)
    shuffled = list(eligible_indices)
    rng.shuffle(shuffled)

    for idx in shuffled:
        tok = tokens[idx]
        letter_positions = [i for i, c in enumerate(tok) if c.isascii() and c.isalpha()]
        if len(letter_positions) >= 3:
            interior = letter_positions[1:-1]
        else:
            interior = letter_positions
        pos = rng.choice(interior)
        orig_ch = tok[pos]
        alpha = "abcdefghijklmnopqrstuvwxyz"
        repl_lower = alpha[(alpha.index(orig_ch.lower()) + 5) % 26]
        repl_ch = repl_lower.upper() if orig_ch.isupper() else repl_lower
        mutated_tok = tok[:pos] + repl_ch + tok[pos + 1 :]
        new_tokens = list(tokens)
        new_tokens[idx] = mutated_tok
        candidate = " ".join(new_tokens)
        if normalize_alnum_words(candidate) != orig_norm:
            return candidate

    raise BenchmarkToolError("Failed to mutate title %r" % title)


def surname_has_removable_accent(surname: str) -> bool:
    stripped = strip_latex_accents(surname)
    return bool(surname and stripped and stripped != surname)


def strip_first_author_surname_accent(author_field: str) -> str:
    authors = split_bibtex_authors(author_field)
    if not authors:
        raise BenchmarkToolError("Empty author field")
    first = authors[0]
    if "," in first:
        fam, giv = first.split(",", 1)
        new_first = "%s, %s" % (strip_latex_accents(fam.strip()), giv.strip())
    else:
        parts = first.split()
        parts[-1] = strip_latex_accents(parts[-1])
        new_first = " ".join(parts)
    authors[0] = new_first
    return " and ".join(authors)


def replace_first_author(target_author_field: str, donor_first_author: str) -> str:
    authors = split_bibtex_authors(target_author_field)
    if not authors:
        return donor_first_author
    authors[0] = donor_first_author
    return " and ".join(authors)


def clean_plain_words(title: str) -> List[str]:
    cleaned = title.replace("{", "").replace("}", "")
    return [w for w in cleaned.split() if w]


def splice_title_halves(
    src_title: str,
    donor_title: str,
    rng: random.Random,
) -> Optional[str]:
    src_words = clean_plain_words(src_title)
    donor_words = clean_plain_words(donor_title)
    if len(src_words) < 3 or len(donor_words) < 4:
        return None
    keep_n = rng.choice([3, 4]) if len(src_words) >= 5 else min(3, len(src_words) - 1)
    tail_start = max(1, len(donor_words) // 2)
    tail = donor_words[tail_start:]
    if len(tail) < 2:
        tail = donor_words[-2:]
    candidate = " ".join(src_words[:keep_n] + tail)
    if not has_balanced_braces(candidate):
        return None
    if normalize_alnum_words(candidate) == normalize_alnum_words(src_title):
        return None
    return candidate


def insert_not_in_title(src_title: str) -> Optional[str]:
    words = clean_plain_words(src_title)
    if not words:
        return None
    insert_after = None
    for idx, w in enumerate(words):
        bare = re.sub(r"[^a-z]", "", w.lower())
        if bare in _AUXILIARY_WORDS:
            next_bare = (
                re.sub(r"[^a-z]", "", words[idx + 1].lower())
                if idx + 1 < len(words)
                else ""
            )
            if next_bare != "not":
                insert_after = idx
                break
    if insert_after is None:
        insert_after = min(1, len(words) - 1)
    mutated_words = words[: insert_after + 1] + ["not"] + words[insert_after + 1 :]
    candidate = " ".join(mutated_words)
    if normalize_alnum_words(candidate) == normalize_alnum_words(src_title):
        return None
    return candidate


def swap_word_order_in_title(src_title: str, rng: random.Random) -> Optional[str]:
    words = clean_plain_words(src_title)
    content_positions = [
        idx
        for idx, w in enumerate(words)
        if len(re.sub(r"[^A-Za-z0-9]", "", w)) >= 3
    ]
    if len(content_positions) < 2:
        content_positions = list(range(len(words)))
    if len(content_positions) < 2:
        return None

    pairs: List[Tuple[int, int]] = []
    for a_i in range(len(content_positions)):
        for b_i in range(a_i + 1, len(content_positions)):
            i, j = content_positions[a_i], content_positions[b_i]
            wi_norm = normalize_alnum_words(words[i])
            wj_norm = normalize_alnum_words(words[j])
            if wi_norm and wj_norm and wi_norm != wj_norm:
                pairs.append((i, j))
    if not pairs:
        return None

    i, j = rng.choice(pairs)
    swapped = list(words)
    # Strip trailing punctuation when swapping so punctuation doesn't land mid-phrase awkwardly
    wi_core = words[i].rstrip(",:;.")
    wj_core = words[j].rstrip(",:;.")
    swapped[i] = wj_core
    swapped[j] = wi_core
    candidate = " ".join(swapped)
    if normalize_alnum_words(candidate) == normalize_alnum_words(src_title):
        return None
    return candidate


# ---------------------------------------------------------------------------
# Group Builders
# ---------------------------------------------------------------------------


def _write_group_files(
    bench_dir: str,
    group_name: str,
    entries: Sequence[ParsedBibEntry],
    tsv_header: Sequence[str],
    tsv_rows: Sequence[Sequence[str]],
) -> None:
    entries_dir = os.path.join(bench_dir, "entries")
    os.makedirs(entries_dir, exist_ok=True)
    bib_path = os.path.join(entries_dir, "%s.bib" % group_name)
    with open(bib_path, "w", encoding="utf-8", newline="\n") as out:
        out.write("\n".join(e.to_bibtex().rstrip("\n") for e in entries) + "\n")

    src_dir = os.path.join(bench_dir, "sources", group_name)
    os.makedirs(src_dir, exist_ok=True)
    tsv_path = os.path.join(src_dir, "mutations.tsv")
    with open(tsv_path, "w", encoding="utf-8", newline="\n") as out:
        out.write("\t".join(tsv_header) + "\n")
        for r in tsv_rows:
            out.write("\t".join(r) + "\n")


def _build_real_typo(
    sources: Sequence[CleanSourceRecord],
    seed: int,
    per_group: int,
) -> Tuple[List[ParsedBibEntry], List[Dict[str, Any]], List[List[str]]]:
    if per_group % 4 != 0:
        raise BenchmarkToolError("per_group (%d) must be divisible by 4 for real_typo" % per_group)
    if len(sources) < per_group:
        raise BenchmarkToolError(
            "Need at least %d real_clean entries for real_typo, got %d"
            % (per_group, len(sources))
        )
    quarter = per_group // 4
    rng = random.Random(seed + 101)
    pool = list(sources)
    rng.shuffle(pool)

    accented: List[CleanSourceRecord] = []
    remaining_after_accent: List[CleanSourceRecord] = []
    for rec in pool:
        if len(accented) < quarter and surname_has_removable_accent(rec.first_surname):
            accented.append(rec)
        else:
            remaining_after_accent.append(rec)

    upper_candidates: List[CleanSourceRecord] = []
    remaining_pool: List[CleanSourceRecord] = []
    for rec in remaining_after_accent:
        if len(upper_candidates) < quarter and rec.doi != rec.doi.upper():
            upper_candidates.append(rec)
        else:
            remaining_pool.append(rec)
    while len(upper_candidates) < quarter and remaining_pool:
        upper_candidates.append(remaining_pool.pop(0))

    title_typo_srcs = remaining_pool[:quarter]
    rem = remaining_pool[quarter:]
    need_space_fallback = quarter - len(accented)
    space_srcs = rem[:need_space_fallback]
    rem = rem[need_space_fallback:]
    url_doi_srcs = rem[:quarter]

    out_entries: List[ParsedBibEntry] = []
    gold_rows: List[Dict[str, Any]] = []
    tsv_rows: List[List[str]] = []
    seq = 0

    # 1..quarter: 1-letter title typo -> DRIFT, insertable=False
    for src in title_typo_srcs:
        seq += 1
        key = "real_typo_%03d" % seq
        new_title = mutate_single_letter_title_typo(src.title, rng)
        out_entries.append(src.entry.clone_with(key, {"title": new_title}))
        gold_rows.append({
            "key": key,
            "group": "real_typo",
            "truth": "mutated",
            "expected": ["DRIFT"],
            "insertable": False,
            "provenance": {
                "doi": src.doi,
                "mutated_title": new_title,
                "mutation": "title_single_letter_typo",
                "original_title": src.title,
                "seed": seed,
                "source_key": src.key,
            },
            "note": "Single-letter typo in title; must be caught as DRIFT.",
        })
        tsv_rows.append([key, src.key, "title_single_letter_typo", "DRIFT", src.title, new_title])

    # (quarter+1)..(2*quarter): strip surname accents, with DOI surrounding spaces fallback -> VERIFIED
    for src in accented:
        seq += 1
        key = "real_typo_%03d" % seq
        orig_author = src.entry.fields["author"]
        new_author = strip_first_author_surname_accent(orig_author)
        out_entries.append(src.entry.clone_with(key, {"author": new_author}))
        gold_rows.append({
            "key": key,
            "group": "real_typo",
            "truth": "real",
            "expected": ["VERIFIED"],
            "insertable": True,
            "provenance": {
                "doi": src.doi,
                "mutated_first_surname": extract_author_surname(split_bibtex_authors(new_author)[0]),
                "mutation": "strip_first_author_surname_accents",
                "original_first_surname": src.first_surname,
                "seed": seed,
                "source_key": src.key,
            },
            "note": "First-author surname diacritics stripped; normalized surname still matches.",
        })
        tsv_rows.append([
            key, src.key, "strip_first_author_surname_accents", "VERIFIED",
            src.first_surname, extract_author_surname(split_bibtex_authors(new_author)[0]),
        ])

    for src in space_srcs:
        seq += 1
        key = "real_typo_%03d" % seq
        padded_doi = "  %s  " % src.doi
        out_entries.append(src.entry.clone_with(key, {"doi": padded_doi}))
        gold_rows.append({
            "key": key,
            "group": "real_typo",
            "truth": "real",
            "expected": ["VERIFIED"],
            "insertable": True,
            "provenance": {
                "doi": src.doi,
                "mutated_doi": padded_doi,
                "mutation": "doi_surrounding_whitespace",
                "seed": seed,
                "source_key": src.key,
            },
            "note": "Fallback for accent slot: surrounding spaces around DOI; normalizes cleanly to VERIFIED.",
        })
        tsv_rows.append([key, src.key, "doi_surrounding_whitespace", "VERIFIED", src.doi, padded_doi])

    # (2*quarter+1)..(3*quarter): https://doi.org/ prefix -> VERIFIED
    for src in url_doi_srcs:
        seq += 1
        key = "real_typo_%03d" % seq
        bare = re.sub(r"^https?://(dx\.)?doi\.org/", "", src.doi, flags=re.I)
        url_doi = "https://doi.org/" + bare
        out_entries.append(src.entry.clone_with(key, {"doi": url_doi}))
        gold_rows.append({
            "key": key,
            "group": "real_typo",
            "truth": "real",
            "expected": ["VERIFIED"],
            "insertable": True,
            "provenance": {
                "doi": src.doi,
                "mutated_doi": url_doi,
                "mutation": "doi_https_prefix",
                "seed": seed,
                "source_key": src.key,
            },
            "note": "DOI written with https://doi.org/ prefix; normalizes cleanly to VERIFIED.",
        })
        tsv_rows.append([key, src.key, "doi_https_prefix", "VERIFIED", src.doi, url_doi])

    # (3*quarter+1)..(4*quarter): uppercase DOI -> VERIFIED
    for src in upper_candidates:
        seq += 1
        key = "real_typo_%03d" % seq
        up_doi = src.doi.upper()
        out_entries.append(src.entry.clone_with(key, {"doi": up_doi}))
        gold_rows.append({
            "key": key,
            "group": "real_typo",
            "truth": "real",
            "expected": ["VERIFIED"],
            "insertable": True,
            "provenance": {
                "doi": src.doi,
                "mutated_doi": up_doi,
                "mutation": "doi_uppercase",
                "seed": seed,
                "source_key": src.key,
            },
            "note": "DOI written in all uppercase (ISO 26324 case-insensitive); normalizes cleanly to VERIFIED.",
        })
        tsv_rows.append([key, src.key, "doi_uppercase", "VERIFIED", src.doi, up_doi])

    return out_entries, gold_rows, tsv_rows


def _build_mut_year1(
    sources: Sequence[CleanSourceRecord],
    seed: int,
    per_group: int,
) -> Tuple[List[ParsedBibEntry], List[Dict[str, Any]], List[List[str]]]:
    rng = random.Random(seed + 202)
    pool = list(sources)
    rng.shuffle(pool)

    out_entries: List[ParsedBibEntry] = []
    gold_rows: List[Dict[str, Any]] = []
    tsv_rows: List[List[str]] = []

    for src in pool:
        if len(out_entries) >= per_group:
            break
        deltas = [-1, 1]
        rng.shuffle(deltas)
        chosen_year: Optional[int] = None
        for d in deltas:
            cand = src.year + d
            if cand not in src.all_record_years and 1450 <= cand <= 2030:
                chosen_year = cand
                break
        if chosen_year is None:
            continue

        key = "mut_year1_%03d" % (len(out_entries) + 1)
        out_entries.append(src.entry.clone_with(key, {"year": str(chosen_year)}))
        prov = src.gold_row.get("provenance") or {}
        gold_rows.append({
            "key": key,
            "group": "mut_year1",
            "truth": "mutated",
            "expected": ["DRIFT"],
            "insertable": False,
            "provenance": {
                "all_record_years": src.all_record_years,
                "doi": src.doi,
                "issued": prov.get("issued"),
                "mutated_year": chosen_year,
                "mutation": "year_shift_1",
                "original_year": src.year,
                "published-online": prov.get("published-online"),
                "published-print": prov.get("published-print"),
                "seed": seed,
                "source_key": src.key,
            },
            "note": "Year shifted by 1 and unequal to published-print, published-online, and issued.",
        })
        tsv_rows.append([
            key, src.key, "year_shift_1", str(src.year), str(chosen_year),
            ",".join(str(y) for y in src.all_record_years),
        ])

    if len(out_entries) < per_group:
        raise BenchmarkToolError(
            "Could only construct %d/%d mut_year1 entries" % (len(out_entries), per_group)
        )
    return out_entries, gold_rows, tsv_rows


def _build_mut_year3(
    sources: Sequence[CleanSourceRecord],
    seed: int,
    per_group: int,
) -> Tuple[List[ParsedBibEntry], List[Dict[str, Any]], List[List[str]]]:
    rng = random.Random(seed + 303)
    pool = list(sources)
    rng.shuffle(pool)

    out_entries: List[ParsedBibEntry] = []
    gold_rows: List[Dict[str, Any]] = []
    tsv_rows: List[List[str]] = []

    for src in pool:
        if len(out_entries) >= per_group:
            break
        deltas = [-5, -4, -3, 3, 4, 5]
        rng.shuffle(deltas)
        chosen_year: Optional[int] = None
        for d in deltas:
            cand = src.year + d
            if 1900 <= cand <= 2025 and all(
                abs(cand - y) >= 3 for y in src.all_record_years
            ):
                chosen_year = cand
                break
        if chosen_year is None:
            continue

        key = "mut_year3_%03d" % (len(out_entries) + 1)
        out_entries.append(src.entry.clone_with(key, {"year": str(chosen_year)}))
        gold_rows.append({
            "key": key,
            "group": "mut_year3",
            "truth": "mutated",
            "expected": ["DRIFT"],
            "insertable": False,
            "provenance": {
                "all_record_years": src.all_record_years,
                "doi": src.doi,
                "mutated_year": chosen_year,
                "mutation": "year_shift_3_to_5",
                "original_year": src.year,
                "seed": seed,
                "source_key": src.key,
            },
            "note": "Year shifted by 3 to 5 years from all publication dates on record.",
        })
        tsv_rows.append([
            key, src.key, "year_shift_3_to_5", str(src.year), str(chosen_year),
            ",".join(str(y) for y in src.all_record_years),
        ])

    if len(out_entries) < per_group:
        raise BenchmarkToolError(
            "Could only construct %d/%d mut_year3 entries" % (len(out_entries), per_group)
        )
    return out_entries, gold_rows, tsv_rows


def _build_mut_author(
    sources: Sequence[CleanSourceRecord],
    seed: int,
    per_group: int,
) -> Tuple[List[ParsedBibEntry], List[Dict[str, Any]], List[List[str]]]:
    rng = random.Random(seed + 404)
    by_field: Dict[str, List[CleanSourceRecord]] = {}
    for s in sources:
        by_field.setdefault(s.field_slug, []).append(s)

    pool = list(sources)
    rng.shuffle(pool)

    out_entries: List[ParsedBibEntry] = []
    gold_rows: List[Dict[str, Any]] = []
    tsv_rows: List[List[str]] = []

    for src in pool:
        if len(out_entries) >= per_group:
            break
        src_norm_sur = "".join(normalize_alnum_words(src.first_surname))
        donors = [
            d
            for d in by_field.get(src.field_slug, [])
            if d.key != src.key
            and "".join(normalize_alnum_words(d.first_surname)) != src_norm_sur
            and d.first_author_full
        ]
        if not donors:
            continue
        donor = rng.choice(donors)
        new_author_field = replace_first_author(
            src.entry.fields["author"], donor.first_author_full
        )
        key = "mut_author_%03d" % (len(out_entries) + 1)
        out_entries.append(src.entry.clone_with(key, {"author": new_author_field}))
        gold_rows.append({
            "key": key,
            "group": "mut_author",
            "truth": "mutated",
            "expected": ["DRIFT"],
            "insertable": False,
            "provenance": {
                "doi": src.doi,
                "donor_key": donor.key,
                "field": src.field_name,
                "mutated_first_author": donor.first_author_full,
                "mutation": "swap_same_field_first_author",
                "original_first_author": src.first_author_full,
                "seed": seed,
                "source_key": src.key,
            },
            "note": "First author replaced with first author of another real_clean entry in the same field.",
        })
        tsv_rows.append([
            key, src.key, donor.key, src.field_name,
            src.first_author_full, donor.first_author_full,
        ])

    if len(out_entries) < per_group:
        raise BenchmarkToolError(
            "Could only construct %d/%d mut_author entries" % (len(out_entries), per_group)
        )
    return out_entries, gold_rows, tsv_rows


def _build_mut_title(
    sources: Sequence[CleanSourceRecord],
    seed: int,
    per_group: int,
) -> Tuple[List[ParsedBibEntry], List[Dict[str, Any]], List[List[str]]]:
    if per_group % 2 != 0:
        raise BenchmarkToolError("per_group (%d) must be even for mut_title" % per_group)
    half = per_group // 2
    rng = random.Random(seed + 505)

    by_field: Dict[str, List[CleanSourceRecord]] = {}
    for s in sources:
        by_field.setdefault(s.field_slug, []).append(s)

    pool = list(sources)
    rng.shuffle(pool)

    out_entries: List[ParsedBibEntry] = []
    gold_rows: List[Dict[str, Any]] = []
    tsv_rows: List[List[str]] = []
    used_src_keys: Set[str] = set()

    # First half (10): keep opening 3-4 words + second half of another title in the same field
    for src in pool:
        if len(out_entries) >= half:
            break
        donors = [d for d in by_field.get(src.field_slug, []) if d.key != src.key]
        rng.shuffle(donors)
        spliced: Optional[str] = None
        chosen_donor: Optional[CleanSourceRecord] = None
        for d in donors:
            cand = splice_title_halves(src.title, d.title, rng)
            if cand is not None:
                spliced = cand
                chosen_donor = d
                break
        if spliced is None or chosen_donor is None:
            continue
        used_src_keys.add(src.key)
        key = "mut_title_%03d" % (len(out_entries) + 1)
        out_entries.append(src.entry.clone_with(key, {"title": spliced}))
        gold_rows.append({
            "key": key,
            "group": "mut_title",
            "truth": "mutated",
            "expected": ["DRIFT"],
            "insertable": False,
            "provenance": {
                "doi": src.doi,
                "donor_key": chosen_donor.key,
                "field": src.field_name,
                "mutated_title": spliced,
                "mutation": "title_prefix_plus_same_field_tail",
                "original_title": src.title,
                "seed": seed,
                "source_key": src.key,
            },
            "note": "Opening 3-4 words retained, remainder spliced from another same-field title.",
        })
        tsv_rows.append([
            key, src.key, "title_prefix_plus_same_field_tail", src.title, spliced,
        ])

    if len(out_entries) < half:
        raise BenchmarkToolError(
            "Could only construct %d/%d spliced mut_title entries"
            % (len(out_entries), half)
        )

    # Second half (10): alternate word-order swap and inserting "not"
    rem_pool = [s for s in pool if s.key not in used_src_keys]
    want_not = half // 2
    want_swap = half - want_not
    made_not = 0
    made_swap = 0

    for src in rem_pool:
        if len(out_entries) >= per_group:
            break
        mut_kind = ""
        new_title: Optional[str] = None
        if made_not < want_not:
            new_title = insert_not_in_title(src.title)
            if new_title is not None:
                mut_kind = "title_insert_not"
                made_not += 1
        if new_title is None and made_swap < want_swap:
            new_title = swap_word_order_in_title(src.title, rng)
            if new_title is not None:
                mut_kind = "title_word_order_swap"
                made_swap += 1
        if new_title is None:
            # Fallback to whichever of the two succeeds on this title
            new_title = insert_not_in_title(src.title)
            if new_title is not None:
                mut_kind = "title_insert_not"
        if new_title is None:
            continue

        used_src_keys.add(src.key)
        key = "mut_title_%03d" % (len(out_entries) + 1)
        out_entries.append(src.entry.clone_with(key, {"title": new_title}))
        gold_rows.append({
            "key": key,
            "group": "mut_title",
            "truth": "mutated",
            "expected": ["DRIFT"],
            "insertable": False,
            "provenance": {
                "doi": src.doi,
                "mutated_title": new_title,
                "mutation": mut_kind,
                "original_title": src.title,
                "seed": seed,
                "source_key": src.key,
            },
            "note": "Title altered via %s while keeping original DOI." % mut_kind,
        })
        tsv_rows.append([key, src.key, mut_kind, src.title, new_title])

    if len(out_entries) < per_group:
        raise BenchmarkToolError(
            "Could only construct %d/%d mut_title entries" % (len(out_entries), per_group)
        )
    return out_entries, gold_rows, tsv_rows


def _build_mut_doi_swap(
    sources: Sequence[CleanSourceRecord],
    seed: int,
    per_group: int,
) -> Tuple[List[ParsedBibEntry], List[Dict[str, Any]], List[List[str]]]:
    rng = random.Random(seed + 606)
    pool = list(sources)
    rng.shuffle(pool)

    used_donor_keys: Set[str] = set()
    out_entries: List[ParsedBibEntry] = []
    gold_rows: List[Dict[str, Any]] = []
    tsv_rows: List[List[str]] = []

    for src in pool:
        if len(out_entries) >= per_group:
            break
        donors = [
            d
            for d in sources
            if d.stratum != src.stratum
            and normalize_doi(d.doi) != normalize_doi(src.doi)
            and d.key not in used_donor_keys
        ]
        if not donors:
            donors = [
                d
                for d in sources
                if d.stratum != src.stratum
                and normalize_doi(d.doi) != normalize_doi(src.doi)
            ]
        if not donors:
            continue
        donor = rng.choice(donors)
        used_donor_keys.add(donor.key)

        key = "mut_doi_swap_%03d" % (len(out_entries) + 1)
        out_entries.append(src.entry.clone_with(key, {"doi": donor.doi}))
        gold_rows.append({
            "key": key,
            "group": "mut_doi_swap",
            "truth": "mutated",
            "expected": ["DRIFT"],
            "insertable": False,
            "provenance": {
                "donor_key": donor.key,
                "donor_stratum": donor.stratum,
                "mutation": "swap_other_stratum_doi",
                "seed": seed,
                "source_key": src.key,
                "source_stratum": src.stratum,
                "swapped_doi": donor.doi,
                "true_doi": src.doi,
            },
            "note": "DOI replaced with the DOI of an entry from a different field/decade stratum.",
        })
        tsv_rows.append([
            key, src.key, src.stratum, donor.key, donor.stratum, src.doi, donor.doi,
        ])

    if len(out_entries) < per_group:
        raise BenchmarkToolError(
            "Could only construct %d/%d mut_doi_swap entries"
            % (len(out_entries), per_group)
        )
    return out_entries, gold_rows, tsv_rows


def _build_mut_doi_missing(
    bench_dir: str,
    sources: Sequence[CleanSourceRecord],
    seed: int,
    per_group: int,
    offline: bool,
    http_client: Optional[BenchmarkHTTPClient] = None,
) -> Tuple[List[ParsedBibEntry], List[Dict[str, Any]], List[List[str]], Dict[str, int]]:
    src_dir = os.path.join(bench_dir, "sources", "mut_doi_missing")
    raw_dir = os.path.join(src_dir, "raw")
    req_log = os.path.join(src_dir, "requests.log")
    os.makedirs(src_dir, exist_ok=True)

    client = http_client or BenchmarkHTTPClient(
        raw_dir=raw_dir,
        requests_log_path=req_log,
        offline=offline,
    )

    rng = random.Random(seed + 707)
    pool = list(sources)
    rng.shuffle(pool)

    if len(pool) < per_group:
        raise BenchmarkToolError(
            "Need at least %d real_clean entries for mut_doi_missing, got %d"
            % (per_group, len(pool))
        )

    used_missing_dois: Set[str] = set()
    out_entries: List[ParsedBibEntry] = []
    gold_rows: List[Dict[str, Any]] = []
    tsv_rows: List[List[str]] = []

    for src in pool[:per_group]:
        if "/" not in src.doi:
            raise BenchmarkToolError("Invalid DOI without '/' in %s: %s" % (src.key, src.doi))
        orig_prefix_exact = src.doi.split("/", 1)[0]
        confirmed_doi: Optional[str] = None
        confirmed_url: Optional[str] = None
        attempts_used = 0

        for attempt in range(1, MAX_HANDLE_ATTEMPTS_PER_ENTRY + 1):
            rand_tok = "".join(rng.choice(_SUFFIX_ALPHABET) for _ in range(10))
            cand_doi = "%s/m1missing.%s" % (orig_prefix_exact, rand_tok)
            norm_cand = normalize_doi(cand_doi)
            if norm_cand == normalize_doi(src.doi) or norm_cand in used_missing_dois:
                continue

            h_url = doi_handle_url(cand_doi)
            resp = client.get(h_url)
            attempts_used = attempt
            try:
                handle_obj = json.loads(resp["body"])
            except Exception:
                handle_obj = {}

            if isinstance(handle_obj, dict) and handle_obj.get("responseCode") == 100:
                confirmed_doi = cand_doi
                confirmed_url = h_url
                used_missing_dois.add(norm_cand)
                break

        if confirmed_doi is None or confirmed_url is None:
            raise BenchmarkToolError(
                "Could not find unregistered random DOI suffix (responseCode==100) for %s after %d attempts"
                % (src.key, MAX_HANDLE_ATTEMPTS_PER_ENTRY)
            )

        key = "mut_doi_missing_%03d" % (len(out_entries) + 1)
        out_entries.append(src.entry.clone_with(key, {"doi": confirmed_doi}))
        gold_rows.append({
            "key": key,
            "group": "mut_doi_missing",
            "truth": "mutated",
            "expected": ["DRIFT", "NOT_FOUND"],
            "insertable": False,
            "provenance": {
                "attempts": attempts_used,
                "doi_handle_response_code": 100,
                "doi_handle_url": confirmed_url,
                "doi_prefix": doi_prefix(src.doi),
                "mutated_doi": confirmed_doi,
                "mutation": "doi_unregistered_random_suffix",
                "seed": seed,
                "source_key": src.key,
                "true_doi": src.doi,
            },
            "note": "Real metadata paired with unregistered same-prefix DOI (confirmed responseCode 100 on doi.org); DRIFT must recover true_doi.",
        })
        tsv_rows.append([
            key, src.key, src.doi, confirmed_doi, "100", str(attempts_used), confirmed_url,
        ])

    return (
        out_entries,
        gold_rows,
        tsv_rows,
        {
            "network_requests": client.network_requests,
            "reused_responses": client.reused_responses,
        },
    )


def build_mutations(
    bench_dir: str,
    seed: int = DEFAULT_SEED,
    confirm_missing: bool = False,
    offline: bool = False,
    per_group: int = PER_GROUP_COUNT,
    http_client: Optional[BenchmarkHTTPClient] = None,
) -> Dict[str, Any]:
    sources = load_real_clean_sources(bench_dir)
    gold_updates: Dict[str, Sequence[Dict[str, Any]]] = {}

    typo_entries, typo_gold, typo_tsv = _build_real_typo(sources, seed, per_group)
    _write_group_files(
        bench_dir,
        "real_typo",
        typo_entries,
        ["key", "source_key", "mutation", "expected", "before", "after"],
        typo_tsv,
    )
    gold_updates["real_typo"] = typo_gold

    y1_entries, y1_gold, y1_tsv = _build_mut_year1(sources, seed, per_group)
    _write_group_files(
        bench_dir,
        "mut_year1",
        y1_entries,
        ["key", "source_key", "mutation", "original_year", "mutated_year", "record_years"],
        y1_tsv,
    )
    gold_updates["mut_year1"] = y1_gold

    y3_entries, y3_gold, y3_tsv = _build_mut_year3(sources, seed, per_group)
    _write_group_files(
        bench_dir,
        "mut_year3",
        y3_entries,
        ["key", "source_key", "mutation", "original_year", "mutated_year", "record_years"],
        y3_tsv,
    )
    gold_updates["mut_year3"] = y3_gold

    au_entries, au_gold, au_tsv = _build_mut_author(sources, seed, per_group)
    _write_group_files(
        bench_dir,
        "mut_author",
        au_entries,
        ["key", "source_key", "donor_key", "field", "original_first_author", "mutated_first_author"],
        au_tsv,
    )
    gold_updates["mut_author"] = au_gold

    ti_entries, ti_gold, ti_tsv = _build_mut_title(sources, seed, per_group)
    _write_group_files(
        bench_dir,
        "mut_title",
        ti_entries,
        ["key", "source_key", "mutation", "original_title", "mutated_title"],
        ti_tsv,
    )
    gold_updates["mut_title"] = ti_gold

    sw_entries, sw_gold, sw_tsv = _build_mut_doi_swap(sources, seed, per_group)
    _write_group_files(
        bench_dir,
        "mut_doi_swap",
        sw_entries,
        ["key", "source_key", "source_stratum", "donor_key", "donor_stratum", "true_doi", "swapped_doi"],
        sw_tsv,
    )
    gold_updates["mut_doi_swap"] = sw_gold

    missing_stats = {"network_requests": 0, "reused_responses": 0}
    if confirm_missing:
        miss_entries, miss_gold, miss_tsv, missing_stats = _build_mut_doi_missing(
            bench_dir=bench_dir,
            sources=sources,
            seed=seed,
            per_group=per_group,
            offline=offline,
            http_client=http_client,
        )
        _write_group_files(
            bench_dir,
            "mut_doi_missing",
            miss_entries,
            ["key", "source_key", "true_doi", "mutated_doi", "response_code", "attempts", "handle_url"],
            miss_tsv,
        )
        gold_updates["mut_doi_missing"] = miss_gold

    gold_path = os.path.join(bench_dir, "gold.jsonl")
    update_gold_jsonl(gold_path, gold_updates)

    return {
        "groups_built": sorted(gold_updates.keys()),
        "entries_written": sum(len(v) for v in gold_updates.values()),
        "missing_confirmed": confirm_missing,
        "network_requests": missing_stats["network_requests"],
        "reused_responses": missing_stats["reused_responses"],
    }


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build deterministic mutation groups from real_clean."
    )
    parser.add_argument(
        "--bench-dir",
        default=default_bench_dir(),
        help="Path to Benchmarks/citations directory (default: %(default)s)",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=DEFAULT_SEED,
        help="Random seed recorded in provenance (default: %(default)s)",
    )
    parser.add_argument(
        "--confirm-missing",
        action="store_true",
        help="Also generate mut_doi_missing by confirming responseCode==100 against doi.org",
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help="With --confirm-missing, read only saved responses in sources/mut_doi_missing/raw/",
    )
    parser.add_argument(
        "--per-group",
        type=int,
        default=PER_GROUP_COUNT,
        help="Entries per mutation group (default: %(default)s)",
    )
    args = parser.parse_args(argv)

    try:
        summary = build_mutations(
            bench_dir=args.bench_dir,
            seed=args.seed,
            confirm_missing=args.confirm_missing,
            offline=args.offline,
            per_group=args.per_group,
        )
    except BenchmarkToolError as err:
        sys.stderr.write("ERROR: %s\n" % err)
        return 2

    print(
        "mutations complete: %d groups (%s), %d entries written (live requests=%d, reused=%d)"
        % (
            len(summary["groups_built"]),
            ", ".join(summary["groups_built"]),
            summary["entries_written"],
            summary["network_requests"],
            summary["reused_responses"],
        )
    )
    if not summary["missing_confirmed"]:
        print(
            "NOTE: mut_doi_missing was not built; pass --confirm-missing to verify unregistered DOIs via doi.org."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
