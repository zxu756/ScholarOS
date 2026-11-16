#!/usr/bin/env python3
"""Shared stdlib-only helpers for Benchmarks/citations/tools/.

Provides:
- Group definitions, expected counts, and canonical key sequences (480 total)
- Built-in retracted DOI list (kept in lockstep with CitationVerificationFirewall.swift)
- Single-threaded, rate-spaced, raw-caching HTTP client (ScholarOS-benchmark/1.0)
- Crossref work validation and deterministic BibTeX @article / @inproceedings conversion
- Tolerant BibTeX reader (CRLF/LF, nested braces, quoted strings, # concatenation)
- Idempotent gold.jsonl group updater
"""
from __future__ import annotations

import datetime
import email.utils
import hashlib
import json
import os
import re
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, Iterable, List, Optional, Sequence, Tuple

USER_AGENT = "ScholarOS-benchmark/1.0"

ALLOWED_HOSTS = frozenset({
    "api.openalex.org",
    "api.crossref.org",
    "doi.org",
})

VALID_VERDICTS = frozenset({
    "VERIFIED",
    "DRIFT",
    "NOT_FOUND",
    "RETRACTED",
    "UNVERIFIED",
})

VALID_TRUTHS = frozenset({
    "real",
    "fabricated",
    "mutated",
    "retracted",
})

REQUIRED_GOLD_FIELDS = (
    "key",
    "group",
    "truth",
    "expected",
    "insertable",
    "provenance",
    "note",
)

# Must match CitationVerificationFirewall.defaultRetractedDOIs in
# Sources/ScholarBibAndCSL/CitationVerificationFirewall.swift (verified by unit tests).
BUILTIN_RETRACTED_DOIS = frozenset({
    "10.1016/s0140-6736(97)11096-0",
    "10.1016/s0140-6736(20)31180-6",
    "10.1056/nejmoa2007621",
    "10.1038/nature12968",
    "10.1038/nature12969",
    "10.1126/science.287.5455.1022",
    "10.1038/s41586-020-2801-z",
    "10.1038/s41586-023-05742-0",
})


def expected_keys_for_group(group: str, count: int) -> List[str]:
    if group == "audit_manual":
        return ["audit_%03d" % i for i in range(1, count + 1)]
    if group == "fabricated_model":
        half = count // 2
        return (
            ["fab_codex_%03d" % i for i in range(1, half + 1)]
            + ["fab_vibe_%03d" % i for i in range(1, count - half + 1)]
        )
    return ["%s_%03d" % (group, i) for i in range(1, count + 1)]


GROUP_SPECS: Tuple[Tuple[str, int], ...] = (
    ("audit_manual", 30),
    ("real_clean", 100),
    ("real_human", 100),
    ("real_typo", 20),
    ("fabricated_model", 80),
    ("mut_year1", 20),
    ("mut_year3", 20),
    ("mut_author", 20),
    ("mut_title", 20),
    ("mut_doi_swap", 20),
    ("mut_doi_missing", 20),
    ("retracted", 30),
)

GROUP_ORDER: Tuple[str, ...] = tuple(g for g, _ in GROUP_SPECS)
GROUP_COUNTS: Dict[str, int] = dict(GROUP_SPECS)
TOTAL_BENCHMARK_COUNT: int = sum(c for _, c in GROUP_SPECS)


def default_bench_dir() -> str:
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ---------------------------------------------------------------------------
# Exceptions & HTTP Client
# ---------------------------------------------------------------------------


class BenchmarkToolError(RuntimeError):
    """Base error for benchmark build and validation scripts."""


class OfflineCacheMissError(BenchmarkToolError):
    """Raised when --offline is active and a required raw response is missing."""

    def __init__(self, url: str, raw_path: str) -> None:
        super().__init__(
            "Offline mode cache miss for URL %s (expected saved response at %s)"
            % (url, raw_path)
        )
        self.url = url
        self.raw_path = raw_path


class OpenAlexBudgetLowError(BenchmarkToolError):
    """Raised when OpenAlex x-ratelimit-remaining drops below 50."""

    def __init__(self, remaining: int, reset_seconds: Optional[str] = None) -> None:
        reset_note = (
            " (x-ratelimit-reset=%ss)" % reset_seconds if reset_seconds is not None else ""
        )
        super().__init__(
            "Stopping safely: OpenAlex x-ratelimit-remaining=%d is below 50%s. "
            "All responses fetched so far are saved in raw/; re-run after quota reset to resume."
            % (remaining, reset_note)
        )
        self.remaining = remaining
        self.reset_seconds = reset_seconds


class RateLimitExhaustedError(BenchmarkToolError):
    """Raised when 429/503 retries are exhausted."""


class _ValidatedRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        host = (parsed.hostname or "").lower()
        if parsed.scheme.lower() != "https" or host not in ALLOWED_HOSTS:
            raise BenchmarkToolError(
                "Refusing redirect from %s to disallowed target %s"
                % (req.full_url, newurl)
            )
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def url_sha1_filename(url: str) -> str:
    return hashlib.sha1(url.encode("utf-8")).hexdigest() + ".json"


def validate_safe_request_url(url: str) -> Tuple[str, str]:
    parsed = urllib.parse.urlsplit(url)
    scheme = (parsed.scheme or "").lower()
    host = (parsed.hostname or "").lower()
    if scheme != "https":
        raise BenchmarkToolError("Only https:// URLs are allowed: %s" % url)
    if host not in ALLOWED_HOSTS:
        raise BenchmarkToolError(
            "Host '%s' is not in allowed benchmark hosts %s"
            % (host, sorted(ALLOWED_HOSTS))
        )
    if parsed.username or parsed.password:
        raise BenchmarkToolError("Credentials in URL are forbidden: %s" % url)
    lower = url.lower()
    decoded_lower = urllib.parse.unquote(url).lower()
    forbidden_tokens = (
        "mail" + "to",
        "api_" + "key",
        "apikey",
        "polite",
        "/" + "users" + "/",
        "/" + "home" + "/",
    )
    for candidate in (lower, decoded_lower):
        if "@" in candidate:
            raise BenchmarkToolError("Email or '@' in request URL is forbidden: %s" % url)
        for bad in forbidden_tokens:
            if bad in candidate:
                raise BenchmarkToolError(
                    "Forbidden token '%s' in request URL: %s" % (bad, url)
                )
    return host, parsed.path or "/"


def _min_spacing_for_url(host: str, url: str) -> float:
    if host == "api.crossref.org":
        parsed = urllib.parse.urlsplit(url)
        # Crossref list/search endpoints (/works?... or bare /works) require >= 1.1s;
        # single-work lookups (/works/<DOI>) require >= 0.25s.
        if parsed.query or parsed.path.rstrip("/") == "/works":
            return 1.1
        return 0.25
    if host in ("api.openalex.org", "doi.org"):
        return 0.3
    raise BenchmarkToolError("Unsupported host: %s" % host)


def _parse_retry_after(value: Optional[str], default_wait: float) -> float:
    if not value:
        return default_wait
    raw = value.strip()
    if not raw:
        return default_wait
    try:
        secs = float(raw)
        if secs >= 0:
            return min(secs, 120.0)
    except ValueError:
        pass
    try:
        dt = email.utils.parsedate_to_datetime(raw)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        now = datetime.datetime.now(datetime.timezone.utc)
        delta = (dt - now).total_seconds()
        return min(max(0.0, delta), 120.0)
    except Exception:
        return default_wait


class BenchmarkHTTPClient:
    """Single-threaded, rate-limited, on-disk caching HTTP client."""

    def __init__(
        self,
        raw_dir: str,
        requests_log_path: str,
        offline: bool = False,
        timeout: float = 30.0,
        sleep_fn: Callable[[float], None] = time.sleep,
        clock_fn: Callable[[], float] = time.monotonic,
        utc_now_fn: Optional[Callable[[], str]] = None,
        opener: Optional[Any] = None,
    ) -> None:
        self.raw_dir = raw_dir
        self.requests_log_path = requests_log_path
        self.offline = offline
        self.timeout = timeout
        self._sleep = sleep_fn
        self._clock = clock_fn
        self._utc_now = utc_now_fn or self._default_utc_now
        self._opener = opener or urllib.request.build_opener(_ValidatedRedirectHandler)
        self._last_request_by_bucket: Dict[str, float] = {}
        self.network_requests = 0
        self.reused_responses = 0
        self.last_openalex_remaining: Optional[int] = None

    @staticmethod
    def _default_utc_now() -> str:
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    def raw_path_for(self, url: str) -> str:
        return os.path.join(self.raw_dir, url_sha1_filename(url))

    def _append_request_log(self, url: str, status: Any, byte_len: int) -> None:
        os.makedirs(os.path.dirname(self.requests_log_path), exist_ok=True)
        with open(self.requests_log_path, "a", encoding="utf-8", newline="\n") as f:
            f.write("%s\t%s\t%s\t%d\n" % (self._utc_now(), url, status, byte_len))

    def _respect_spacing(self, host: str, url: str, min_gap: float) -> None:
        wait_needed = 0.0
        prev_host = self._last_request_by_bucket.get(host)
        if prev_host is not None:
            wait_needed = max(wait_needed, min_gap - (self._clock() - prev_host))
        if host == "api.crossref.org" and min_gap > 0.25:
            prev_search = self._last_request_by_bucket.get("api.crossref.org:search")
            if prev_search is not None:
                wait_needed = max(wait_needed, 1.1 - (self._clock() - prev_search))
        if wait_needed > 0:
            self._sleep(wait_needed)

    def get(self, url: str) -> Dict[str, Any]:
        """Return dict(url, status, headers, body). Reads/writes raw/<sha1>.json."""
        host, _ = validate_safe_request_url(url)
        raw_path = self.raw_path_for(url)

        if os.path.exists(raw_path):
            with open(raw_path, encoding="utf-8") as f:
                saved = json.load(f)
            if isinstance(saved, dict) and "status" in saved and "body" in saved:
                self.reused_responses += 1
                return saved

        if self.offline:
            raise OfflineCacheMissError(url, raw_path)

        os.makedirs(self.raw_dir, exist_ok=True)
        min_gap = _min_spacing_for_url(host, url)

        max_retries = 3
        for attempt in range(max_retries + 1):
            self._respect_spacing(host, url, min_gap)
            req = urllib.request.Request(
                url,
                headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "application/json",
                },
                method="GET",
            )
            status: Optional[int] = None
            raw_bytes = b""
            headers_lc: Dict[str, str] = {}

            try:
                with self._opener.open(req, timeout=self.timeout) as resp:
                    status = int(getattr(resp, "status", None) or resp.getcode())
                    raw_bytes = resp.read()
                    headers_lc = {k.lower(): v for k, v in resp.headers.items()}
            except urllib.error.HTTPError as err:
                status = int(err.code)
                try:
                    raw_bytes = err.read()
                except Exception:
                    raw_bytes = b""
                if err.headers is not None:
                    headers_lc = {k.lower(): v for k, v in err.headers.items()}
            except Exception as err:
                now_ts = self._clock()
                self._last_request_by_bucket[host] = now_ts
                if host == "api.crossref.org" and min_gap > 0.25:
                    self._last_request_by_bucket["api.crossref.org:search"] = now_ts
                self.network_requests += 1
                self._append_request_log(url, "ERR", 0)
                raise BenchmarkToolError(
                    "Transport error requesting %s: %s" % (url, err)
                ) from err

            now_ts = self._clock()
            self._last_request_by_bucket[host] = now_ts
            if host == "api.crossref.org" and min_gap > 0.25:
                self._last_request_by_bucket["api.crossref.org:search"] = now_ts
            self.network_requests += 1
            self._append_request_log(url, status, len(raw_bytes))

            if status in (429, 503):
                if attempt >= max_retries:
                    raise RateLimitExhaustedError(
                        "HTTP %d persisted after %d retries for %s"
                        % (status, max_retries, url)
                    )
                fallback_wait = [2.0, 4.0, 8.0][attempt]
                wait_secs = _parse_retry_after(headers_lc.get("retry-after"), fallback_wait)
                self._sleep(wait_secs)
                continue

            kept_headers = {
                k: v
                for k, v in headers_lc.items()
                if k
                in (
                    "content-type",
                    "date",
                    "retry-after",
                    "x-rate-limit-limit",
                    "x-rate-limit-interval",
                    "x-concurrency-limit",
                    "x-ratelimit-limit",
                    "x-ratelimit-remaining",
                    "x-ratelimit-reset",
                    "x-ratelimit-credits-used",
                    "x-ratelimit-cost-usd",
                )
            }

            record = {
                "url": url,
                "status": status,
                "fetched_at": self._utc_now(),
                "headers": kept_headers,
                "body": raw_bytes.decode("utf-8", "replace"),
            }

            if status in (200, 404):
                with open(raw_path, "w", encoding="utf-8", newline="\n") as out:
                    json.dump(record, out, ensure_ascii=False, sort_keys=True)
                    out.write("\n")

            if host == "api.openalex.org" and "x-ratelimit-remaining" in headers_lc:
                try:
                    rem = int(float(headers_lc["x-ratelimit-remaining"].strip()))
                    self.last_openalex_remaining = rem
                except ValueError:
                    rem = None
                if rem is not None and rem < 50:
                    raise OpenAlexBudgetLowError(
                        rem, headers_lc.get("x-ratelimit-reset")
                    )

            if status not in (200, 404):
                raise BenchmarkToolError(
                    "Unexpected HTTP status %s for %s" % (status, url)
                )

            return record

        raise RateLimitExhaustedError("Retries exhausted for %s" % url)


# ---------------------------------------------------------------------------
# DOI & Crossref Helpers
# ---------------------------------------------------------------------------


def normalize_doi(raw: Optional[str]) -> str:
    if not raw:
        return ""
    s = raw.strip()
    lower = s.lower()
    for prefix in (
        "https://doi.org/",
        "http://doi.org/",
        "https://dx.doi.org/",
        "http://dx.doi.org/",
        "doi:",
    ):
        if lower.startswith(prefix):
            s = s[len(prefix):].strip()
            break
    return s.lower()


def doi_prefix(raw_doi: str) -> str:
    norm = normalize_doi(raw_doi)
    if "/" not in norm:
        return norm
    return norm.split("/", 1)[0]


def crossref_work_url(raw_doi: str) -> str:
    norm = normalize_doi(raw_doi)
    return "https://api.crossref.org/works/" + urllib.parse.quote(norm, safe="/")


def openalex_work_url(raw_doi: str) -> str:
    norm = normalize_doi(raw_doi)
    return "https://api.openalex.org/works/https://doi.org/" + urllib.parse.quote(
        norm, safe="/"
    )


def doi_handle_url(raw_doi: str) -> str:
    norm = normalize_doi(raw_doi)
    return "https://doi.org/api/handles/" + urllib.parse.quote(norm, safe="/")


def extract_crossref_date_str(date_obj: Any) -> Optional[str]:
    if not isinstance(date_obj, dict):
        return None
    parts = date_obj.get("date-parts")
    if not isinstance(parts, list) or not parts or not isinstance(parts[0], list):
        return None
    row = parts[0]
    if not row or row[0] is None:
        return None
    try:
        year = int(row[0])
    except (TypeError, ValueError):
        return None
    if not (1000 <= year <= 2100):
        return None
    if len(row) >= 3 and row[1] is not None and row[2] is not None:
        try:
            return "%04d-%02d-%02d" % (year, int(row[1]), int(row[2]))
        except (TypeError, ValueError):
            pass
    if len(row) >= 2 and row[1] is not None:
        try:
            return "%04d-%02d" % (year, int(row[1]))
        except (TypeError, ValueError):
            pass
    return "%04d" % year


def extract_crossref_year(date_obj: Any) -> Optional[int]:
    ds = extract_crossref_date_str(date_obj)
    if not ds:
        return None
    return int(ds[:4])


def extract_all_crossref_years(msg: Dict[str, Any]) -> List[int]:
    years: List[int] = []
    for key in ("published-print", "published-online", "issued", "published"):
        yr = extract_crossref_year(msg.get(key))
        if yr is not None and yr not in years:
            years.append(yr)
    return years


_HTML_OR_MATHML_TAG_RE = re.compile(r"<[A-Za-z/!?][^>]*>")


def has_html_or_mathml_tags(text: str) -> bool:
    if not text:
        return False
    if _HTML_OR_MATHML_TAG_RE.search(text):
        return True
    if "<mml:" in text.lower() or "</mml:" in text.lower():
        return True
    return False


def has_balanced_braces(text: str) -> bool:
    depth = 0
    for ch in text:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def sanitize_bibtex_value(text: str) -> str:
    collapsed = re.sub(r"\s+", " ", text or "").strip()
    if not has_balanced_braces(collapsed):
        collapsed = collapsed.replace("{", "").replace("}", "")
    return collapsed


def crossref_has_updated_by_retraction(msg: Dict[str, Any]) -> bool:
    updated_by = msg.get("updated-by")
    if not isinstance(updated_by, list):
        return False
    for item in updated_by:
        if isinstance(item, dict) and "retraction" in str(item.get("type", "")).lower():
            return True
    return False


def crossref_has_any_retraction_marker(msg: Dict[str, Any]) -> bool:
    if crossref_has_updated_by_retraction(msg):
        return True
    update_to = msg.get("update-to")
    if isinstance(update_to, list):
        for item in update_to:
            if isinstance(item, dict) and "retraction" in str(item.get("type", "")).lower():
                return True
    rel = msg.get("relation")
    if isinstance(rel, dict) and rel.get("is-retracted-by"):
        return True
    titles = msg.get("title")
    first_title = ""
    if isinstance(titles, list) and titles:
        first_title = str(titles[0] or "").strip().lower()
    elif isinstance(titles, str):
        first_title = titles.strip().lower()
    if first_title.startswith(("retracted:", "retraction:", "[retracted]", "withdrawn:")):
        return True
    return False


def order_crossref_authors(raw_authors: Sequence[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Put sequence=='first' at index 0 (matching CitationVerificationFirewall), keeping rest in order."""
    first_idx = 0
    for idx, au in enumerate(raw_authors):
        if str(au.get("sequence", "")).strip().lower() == "first":
            first_idx = idx
            break
    ordered = [raw_authors[first_idx]]
    for idx, au in enumerate(raw_authors):
        if idx != first_idx:
            ordered.append(au)
    return ordered


def validate_clean_crossref_article(msg: Any) -> Tuple[bool, str]:
    """Check all eligibility criteria for build_real_clean.py."""
    if not isinstance(msg, dict):
        return False, "not a Crossref message object"
    if msg.get("type") != "journal-article":
        return False, "type is %r, expected 'journal-article'" % (msg.get("type"),)
    raw_doi = str(msg.get("DOI") or "").strip()
    if not raw_doi:
        return False, "missing DOI"
    if normalize_doi(raw_doi) in BUILTIN_RETRACTED_DOIS:
        return False, "in built-in retracted list"
    if crossref_has_any_retraction_marker(msg):
        return False, "carries retraction marker"

    titles = msg.get("title")
    if not isinstance(titles, list) or not titles or not str(titles[0] or "").strip():
        return False, "missing title"
    title = re.sub(r"\s+", " ", str(titles[0])).strip()
    if has_html_or_mathml_tags(title):
        return False, "title contains HTML or MathML tags"
    if not has_balanced_braces(title):
        return False, "title has unbalanced braces"

    containers = msg.get("container-title")
    if not isinstance(containers, list) or not containers or not str(containers[0] or "").strip():
        return False, "missing container-title"
    journal = re.sub(r"\s+", " ", str(containers[0])).strip()
    if has_html_or_mathml_tags(journal) or not has_balanced_braces(journal):
        return False, "container-title contains tags or unbalanced braces"

    raw_authors = msg.get("author")
    if not isinstance(raw_authors, list) or not raw_authors:
        return False, "missing author list"
    ordered_authors = order_crossref_authors(
        [a for a in raw_authors if isinstance(a, dict)]
    )
    if not ordered_authors:
        return False, "empty author list"
    first_fam = str(ordered_authors[0].get("family") or "").strip()
    if not first_fam:
        return False, "first author missing family name"
    for au in ordered_authors:
        fam = str(au.get("family") or "").strip()
        giv = str(au.get("given") or "").strip()
        if not fam:
            return False, "an author entry is missing family name"
        if has_html_or_mathml_tags(fam) or has_html_or_mathml_tags(giv):
            return False, "author contains HTML tags"
        if not has_balanced_braces(fam) or not has_balanced_braces(giv):
            return False, "author has unbalanced braces"
        if re.search(r"\band\b", fam, re.I) or re.search(r"\band\b", giv, re.I):
            return False, "author field contains literal 'and' separator word"

    issued_year = extract_crossref_year(msg.get("issued"))
    if issued_year is None:
        return False, "missing issued year"

    return True, "ok"


def format_crossref_authors_bibtex(raw_authors: Sequence[Dict[str, Any]]) -> str:
    ordered = order_crossref_authors([a for a in raw_authors if isinstance(a, dict)])
    parts: List[str] = []
    for au in ordered:
        fam = sanitize_bibtex_value(str(au.get("family") or ""))
        giv = sanitize_bibtex_value(str(au.get("given") or ""))
        corp = sanitize_bibtex_value(str(au.get("name") or ""))
        if fam and giv:
            parts.append("%s, %s" % (fam, giv))
        elif fam:
            parts.append(fam)
        elif corp:
            parts.append("{%s}" % corp)
    return " and ".join(parts)


def crossref_message_to_bibtex(
    key: str,
    msg: Dict[str, Any],
    require_issued_year: bool = True,
) -> str:
    """Convert a Crossref work message dict into a deterministic BibTeX entry."""
    c_type = str(msg.get("type") or "journal-article").lower()
    bib_type = "inproceedings" if c_type == "proceedings-article" else "article"

    author_str = format_crossref_authors_bibtex(msg.get("author") or [])
    titles = msg.get("title") or [""]
    raw_title = titles[0] if isinstance(titles, list) and titles else str(titles or "")
    title_str = sanitize_bibtex_value(str(raw_title))

    containers = msg.get("container-title") or []
    raw_venue = (
        containers[0]
        if isinstance(containers, list) and containers
        else (containers if isinstance(containers, str) else "")
    )
    venue_str = sanitize_bibtex_value(str(raw_venue or ""))

    year_val = extract_crossref_year(msg.get("issued"))
    if year_val is None and not require_issued_year:
        all_years = extract_all_crossref_years(msg)
        year_val = all_years[0] if all_years else None
    if year_val is None:
        raise BenchmarkToolError("Cannot determine publication year for %s" % key)

    volume = sanitize_bibtex_value(str(msg.get("volume") or ""))
    issue = sanitize_bibtex_value(str(msg.get("issue") or ""))
    if not issue and isinstance(msg.get("journal-issue"), dict):
        issue = sanitize_bibtex_value(str(msg["journal-issue"].get("issue") or ""))
    pages = sanitize_bibtex_value(
        str(msg.get("page") or msg.get("article-number") or "")
    )
    doi_exact = str(msg.get("DOI") or "").strip()

    fields: List[Tuple[str, str]] = [
        ("author", author_str),
        ("title", title_str),
    ]
    if venue_str:
        fields.append(("booktitle" if bib_type == "inproceedings" else "journal", venue_str))
    fields.append(("year", str(year_val)))
    if volume:
        fields.append(("volume", volume))
    if issue:
        fields.append(("number", issue))
    if pages:
        fields.append(("pages", pages))
    if doi_exact:
        fields.append(("doi", doi_exact))

    return serialize_bibtex_entry(bib_type, key, fields)


def serialize_bibtex_entry(
    entry_type: str,
    key: str,
    fields: Sequence[Tuple[str, str]],
) -> str:
    lines = ["@%s{%s," % (entry_type, key)]
    for idx, (fname, fval) in enumerate(fields):
        comma = "," if idx + 1 < len(fields) else ""
        lines.append("  %s = {%s}%s" % (fname, fval, comma))
    lines.append("}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Tolerant BibTeX Parser (for check_benchmark.py & build_mutations.py)
# ---------------------------------------------------------------------------


class BibTeXSyntaxError(BenchmarkToolError):
    """Raised when a .bib file has malformed syntax or unbalanced braces."""


class ParsedBibEntry:
    def __init__(
        self,
        entry_type: str,
        key: str,
        ordered_fields: List[Tuple[str, str]],
    ) -> None:
        self.entry_type = entry_type
        self.key = key
        self.ordered_fields = list(ordered_fields)
        self.fields: Dict[str, str] = {}
        for name, val in ordered_fields:
            self.fields[name.lower()] = val

    def clone_with(
        self,
        new_key: str,
        overrides: Dict[str, str],
    ) -> "ParsedBibEntry":
        lower_overrides = {k.lower(): (k, v) for k, v in overrides.items()}
        seen = set()
        new_ordered: List[Tuple[str, str]] = []
        for orig_name, orig_val in self.ordered_fields:
            lk = orig_name.lower()
            if lk in lower_overrides:
                new_ordered.append((orig_name, lower_overrides[lk][1]))
                seen.add(lk)
            else:
                new_ordered.append((orig_name, orig_val))
        for lk, (orig_k, val) in lower_overrides.items():
            if lk not in seen:
                new_ordered.append((orig_k, val))
        return ParsedBibEntry(self.entry_type, new_key, new_ordered)

    def to_bibtex(self) -> str:
        return serialize_bibtex_entry(self.entry_type, self.key, self.ordered_fields)


def _skip_ws_and_comments(text: str, pos: int) -> int:
    n = len(text)
    while pos < n:
        ch = text[pos]
        if ch in " \t\r\n":
            pos += 1
        elif ch == "%":
            nl = text.find("\n", pos)
            pos = n if nl < 0 else nl + 1
        else:
            break
    return pos


def _read_balanced_delimited(text: str, open_pos: int, close_char: str) -> int:
    """Return index of matching close_char ('}' or ')') starting at open_pos."""
    n = len(text)
    brace_depth = 0
    in_quotes = False
    i = open_pos + 1
    while i < n:
        ch = text[i]
        if ch == "\\" and i + 1 < n:
            i += 2
            continue
        if in_quotes:
            if ch == "{":
                brace_depth += 1
            elif ch == "}" and brace_depth > 0:
                brace_depth -= 1
            elif ch == '"' and brace_depth == 0:
                in_quotes = False
        else:
            if ch == '"' and brace_depth == 0:
                in_quotes = True
            elif ch == "{":
                brace_depth += 1
            elif ch == "}":
                if brace_depth == 0 and close_char == "}":
                    return i
                if brace_depth == 0:
                    raise BibTeXSyntaxError("Unexpected '}' at offset %d" % i)
                brace_depth -= 1
            elif ch == ")" and brace_depth == 0 and close_char == ")":
                return i
        i += 1
    raise BibTeXSyntaxError("Unclosed entry starting at offset %d" % open_pos)


def _parse_single_value_atom(body: str, pos: int) -> Tuple[str, int]:
    n = len(body)
    if pos >= n:
        raise BibTeXSyntaxError("Expected field value at end of entry body")
    ch = body[pos]
    if ch == "{":
        depth = 1
        i = pos + 1
        while i < n and depth > 0:
            c = body[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return body[pos + 1 : i], i + 1
            i += 1
        raise BibTeXSyntaxError("Unclosed '{' in field value")
    if ch == '"':
        brace_depth = 0
        i = pos + 1
        while i < n:
            c = body[i]
            if c == "\\" and i + 1 < n:
                i += 2
                continue
            if c == "{":
                brace_depth += 1
            elif c == "}" and brace_depth > 0:
                brace_depth -= 1
            elif c == '"' and brace_depth == 0:
                return body[pos + 1 : i], i + 1
            i += 1
        raise BibTeXSyntaxError("Unclosed '\"' in field value")
    # Bare number or macro identifier
    i = pos
    while i < n and body[i] not in ",}# \t\r\n":
        i += 1
    tok = body[pos:i].strip()
    if not tok:
        raise BibTeXSyntaxError("Empty bare field value near %r" % body[pos : pos + 20])
    return tok, i


def _parse_entry_fields(body: str) -> List[Tuple[str, str]]:
    fields: List[Tuple[str, str]] = []
    pos = 0
    n = len(body)
    name_re = re.compile(r"[A-Za-z0-9_.:+/-]+")

    while True:
        pos = _skip_ws_and_comments(body, pos)
        while pos < n and body[pos] == ",":
            pos = _skip_ws_and_comments(body, pos + 1)
        if pos >= n:
            break
        m = name_re.match(body, pos)
        if not m:
            raise BibTeXSyntaxError(
                "Expected field name near %r" % body[pos : pos + 30]
            )
        fname = m.group(0)
        pos = _skip_ws_and_comments(body, m.end())
        if pos >= n or body[pos] != "=":
            raise BibTeXSyntaxError("Expected '=' after field name '%s'" % fname)
        pos = _skip_ws_and_comments(body, pos + 1)

        parts: List[str] = []
        while True:
            atom, pos = _parse_single_value_atom(body, pos)
            parts.append(atom)
            pos = _skip_ws_and_comments(body, pos)
            if pos < n and body[pos] == "#":
                pos = _skip_ws_and_comments(body, pos + 1)
                continue
            break

        val = re.sub(r"\s+", " ", "".join(parts)).strip()
        fields.append((fname, val))
        if pos < n and body[pos] == ",":
            pos += 1

    return fields


def parse_bibtex_entries(raw_text: str) -> List[ParsedBibEntry]:
    """Parse a BibTeX string into a list of ParsedBibEntry objects."""
    # Normalize CRLF/CR to LF internally for parsing only
    text = raw_text.replace("\r\n", "\n").replace("\r", "\n")
    entries: List[ParsedBibEntry] = []
    pos = 0
    n = len(text)
    header_re = re.compile(r"@\s*([A-Za-z]+)\s*([{(])")

    while pos < n:
        pos = _skip_ws_and_comments(text, pos)
        if pos >= n:
            break
        at = text.find("@", pos)
        if at < 0:
            break
        # Check if '@' is inside a '%' line comment
        line_start = text.rfind("\n", 0, at) + 1
        if "%" in text[line_start:at]:
            nl = text.find("\n", at)
            pos = n if nl < 0 else nl + 1
            continue
        m = header_re.match(text, at)
        if not m:
            raise BibTeXSyntaxError(
                "Malformed BibTeX '@' construct near %r" % text[at : at + 30]
            )
        etype = m.group(1)
        etype_lc = etype.lower()
        open_ch = m.group(2)
        close_ch = "}" if open_ch == "{" else ")"
        open_pos = m.end() - 1
        close_pos = _read_balanced_delimited(text, open_pos, close_ch)
        inner = text[open_pos + 1 : close_pos]
        pos = close_pos + 1

        if etype_lc in ("comment", "preamble", "string"):
            continue

        comma = inner.find(",")
        if comma < 0:
            raise BibTeXSyntaxError("Missing comma after citation key in @%s" % etype)
        cite_key = inner[:comma].strip()
        if not cite_key or any(c.isspace() for c in cite_key):
            raise BibTeXSyntaxError("Invalid citation key %r in @%s" % (cite_key, etype))
        ordered_fields = _parse_entry_fields(inner[comma + 1 :])
        entries.append(ParsedBibEntry(etype_lc, cite_key, ordered_fields))

    return entries


# ---------------------------------------------------------------------------
# Diacritic Folding & Text Helpers
# ---------------------------------------------------------------------------

_LIGATURE_MAP = {
    "ß": "ss",
    "ẞ": "SS",
    "æ": "ae",
    "Æ": "AE",
    "œ": "oe",
    "Œ": "OE",
    "ø": "o",
    "Ø": "O",
    "ł": "l",
    "Ł": "L",
    "đ": "d",
    "Đ": "D",
    "ı": "i",
}


def strip_diacritics_preserve_case(text: str) -> str:
    """Strip Unicode accents/diacritics and expand Latin ligatures while preserving case."""
    out: List[str] = []
    for ch in text:
        if ch in _LIGATURE_MAP:
            out.append(_LIGATURE_MAP[ch])
        else:
            decomp = unicodedata.normalize("NFD", ch)
            base = "".join(c for c in decomp if unicodedata.category(c) != "Mn")
            out.append(base)
    return "".join(out)


def strip_latex_accents(text: str) -> str:
    """Convert common LaTeX accent sequences like {\\\"u} or \\'e to plain ASCII."""
    s = re.sub(
        r"\{\\[`'\"^~=.uvHckbdrt]\s*\{?([A-Za-z])\}?\}",
        r"\1",
        text,
    )
    s = re.sub(r"\\[`'\"^~=.uvHckbdrt]\s*\{([A-Za-z])\}", r"\1", s)
    s = re.sub(r"\\[`'\"^~=.]\s*([A-Za-z])", r"\1", s)
    s = re.sub(r"\{\\(aa|AA|o|O|l|L|ss|ae|AE|oe|OE)\}", lambda m: {
        "aa": "a", "AA": "A", "o": "o", "O": "O", "l": "l", "L": "L",
        "ss": "ss", "ae": "ae", "AE": "AE", "oe": "oe", "OE": "OE",
    }[m.group(1)], s)
    return strip_diacritics_preserve_case(s)


def normalize_alnum_words(text: str) -> List[str]:
    folded = strip_latex_accents(text).lower()
    return re.findall(r"[a-z0-9]+", folded)


def split_bibtex_authors(author_field: str) -> List[str]:
    return [part.strip() for part in re.split(r"\s+and\s+", author_field.strip()) if part.strip()]


def extract_author_surname(first_author: str) -> str:
    if "," in first_author:
        return first_author.split(",", 1)[0].strip()
    parts = first_author.split()
    return parts[-1].strip() if parts else ""


# ---------------------------------------------------------------------------
# Idempotent gold.jsonl Updater
# ---------------------------------------------------------------------------


def update_gold_jsonl(
    gold_path: str,
    replacements_by_group: Dict[str, Sequence[Dict[str, Any]]],
) -> None:
    """Update one or more groups in gold.jsonl, preserving untouched groups verbatim."""
    existing_by_group: Dict[str, List[str]] = {}
    extra_groups_order: List[str] = []

    if os.path.exists(gold_path):
        with open(gold_path, encoding="utf-8") as f:
            for raw_line in f:
                stripped = raw_line.rstrip("\r\n")
                if not stripped:
                    continue
                obj = json.loads(stripped)
                grp = obj.get("group", "")
                if grp not in existing_by_group:
                    existing_by_group[grp] = []
                    if grp not in GROUP_ORDER:
                        extra_groups_order.append(grp)
                existing_by_group[grp].append(stripped)

    for grp, rows in replacements_by_group.items():
        sorted_rows = sorted(rows, key=lambda r: r["key"])
        existing_by_group[grp] = [
            json.dumps(r, ensure_ascii=False, sort_keys=True) for r in sorted_rows
        ]
        if grp not in GROUP_ORDER and grp not in extra_groups_order:
            extra_groups_order.append(grp)

    os.makedirs(os.path.dirname(gold_path), exist_ok=True)
    with open(gold_path, "w", encoding="utf-8", newline="\n") as out:
        for grp in list(GROUP_ORDER) + extra_groups_order:
            for line in existing_by_group.get(grp, []):
                out.write(line + "\n")
