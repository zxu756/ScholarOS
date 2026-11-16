#!/usr/bin/env bash
#
# Conductor-only tool (never called by tests): regenerate the expected.json files of
# Benchmarks/manuscripts/ from the arXiv source packages and compare them with the committed ones.
#
# Usage:
#   Scripts/acceptance/m2-regen-expected.sh [--check] [--packages DIR] [--tectonic-cache DIR]
#                                           [--tectonic PATH] [--only ID[,ID]] [--keep-work] [--warm-cache]
#
#   --check            print differences against the committed expected.json (ignoring generated_utc)
#                      and exit 1 on any; without it the regenerated files overwrite the committed ones.
#   --packages DIR     use local packages DIR/<id><version>.pkg or DIR/raw/<id><version>.pkg instead of
#                      downloading from arXiv. Without it each package is downloaded from
#                      https://arxiv.org/src/<id><version> (User-Agent ScholarOS-benchmark/1.0, 3 s apart).
#                      Either way the SHA-256 must equal the package_sha256 column of papers.tsv.
#   --tectonic-cache DIR   TECTONIC_CACHE_DIR to use. The directory is copied to a temporary directory
#                      first, so it is not modified. Default: an empty temporary directory (then the
#                      network-denied compile cannot fetch the bundle; add --warm-cache).
#   --warm-cache       one trivial compile WITHOUT the network sandbox, to fill an empty cache.
#   --tectonic PATH    Tectonic executable (default: from PATH, then /opt/homebrew/bin/tectonic).
#
# Exit codes: 0 all rows done (and no differences with --check); 1 differences or a failed row;
# 2 Tectonic missing ("没跑") or bad usage.
# Never writes to ~/Library: HOME is a temporary directory for Tectonic, and the cache is a temporary copy.
# Package sources are data: they are only extracted and compiled inside `sandbox-exec ... (deny network*)`;
# nothing from them is executed by this script, and python runs with -I.

set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
bench="$repo/Benchmarks/manuscripts"
helper="$here/m2_expected.py"

check=0; pkgdir=""; cache_arg=""; tectonic=""; only=""; keep=0; warm=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1 ;;
    --packages) pkgdir="${2:-}"; shift ;;
    --tectonic-cache) cache_arg="${2:-}"; shift ;;
    --tectonic) tectonic="${2:-}"; shift ;;
    --only) only="${2:-}"; shift ;;
    --keep-work) keep=1 ;;
    --warm-cache) warm=1 ;;
    -h|--help) sed -n '3,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$tectonic" ]; then
  tectonic="$(command -v tectonic || true)"
  [ -z "$tectonic" ] && [ -x /opt/homebrew/bin/tectonic ] && tectonic=/opt/homebrew/bin/tectonic
fi
if [ -z "$tectonic" ] || [ ! -x "$tectonic" ]; then
  echo "没跑: Tectonic not found (install Tectonic 0.17 or pass --tectonic PATH)"
  exit 2
fi
command -v sandbox-exec >/dev/null || { echo "没跑: sandbox-exec not found"; exit 2; }
[ -f "$bench/papers.tsv" ] || { echo "missing $bench/papers.tsv" >&2; exit 2; }
[ -z "$cache_arg" ] || [ -d "$cache_arg" ] || { echo "no such cache directory: $cache_arg" >&2; exit 2; }
[ -z "$pkgdir" ] || [ -d "$pkgdir" ] || { echo "no such packages directory: $pkgdir" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/m2-regen.XXXXXX")" || exit 2
cleanup() { [ "$keep" = 1 ] && echo "work directory kept: $work" || rm -rf "$work"; }
trap cleanup EXIT
mkdir -p "$work/home" "$work/cache" "$work/pkg"
if [ -n "$cache_arg" ]; then cp -R "$cache_arg/." "$work/cache/"; fi
tenv=(env -i PATH=/opt/homebrew/bin:/usr/bin:/bin HOME="$work/home" TECTONIC_CACHE_DIR="$work/cache")
gen="$("$tectonic" --version), bundle https://relay.fullyjustified.net/default_bundle_v33.tar, --untrusted --keep-intermediates --keep-logs"
sbprofile='(version 1)(allow default)(deny network*)'

if [ "$warm" = 1 ]; then
  mkdir -p "$work/warm"
  printf '\\documentclass{article}\\begin{document}x\\end{document}\n' > "$work/warm/w.tex"
  (cd "$work/warm" && "${tenv[@]}" "$tectonic" --color never -o . w.tex >/dev/null 2>&1) \
    || echo "warning: cache warm-up compile failed" >&2
fi

total=0; bad=0; diffs=0
# columns: 1 id, 2 version, 5 main_file, 7 sha256 (header row skipped; only chosen rows are in this file)
while IFS=$'\t' read -r aid ver _lic _tpl mainf _bk sha _rest; do
  [ "$aid" = "arxiv_id" ] && continue
  [ -z "$aid" ] && continue
  if [ -n "$only" ] && ! printf ',%s,' "$only" | grep -q ",$aid,\|,$aid$ver,"; then continue; fi
  idv="$aid$ver"; total=$((total+1))
  pkg=""
  if [ -n "$pkgdir" ]; then
    for c in "$pkgdir/$idv.pkg" "$pkgdir/raw/$idv.pkg"; do [ -f "$c" ] && pkg="$c" && break; done
    [ -n "$pkg" ] || { echo "FAIL $idv: package not found in $pkgdir"; bad=$((bad+1)); continue; }
  else
    pkg="$work/pkg/$idv.pkg"
    python3 -I "$helper" fetch "$aid" "$ver" "$pkg" || { echo "FAIL $idv: download failed"; bad=$((bad+1)); continue; }
  fi
  got="$(python3 -I "$helper" sha256 "$pkg")"
  if [ "$got" != "$sha" ]; then echo "FAIL $idv: SHA-256 $got != papers.tsv $sha"; bad=$((bad+1)); continue; fi
  src="$work/src/$idv"; out="$work/out/$idv"; mkdir -p "$work/src" "$out"
  python3 -I "$helper" extract "$pkg" "$src" || { echo "FAIL $idv: extraction failed"; bad=$((bad+1)); continue; }
  base="${mainf%.tex}"
  ( cd "$src" && "${tenv[@]}" sandbox-exec -p "$sbprofile" "$tectonic" --untrusted --keep-intermediates \
      --keep-logs --color never -o "$out" "$mainf" >"$out/_stdout" 2>"$out/_stderr" )
  rc=$?
  if [ "$rc" != 0 ] || [ ! -f "$out/$base.aux" ]; then
    echo "FAIL $idv: Tectonic exit $rc (see --keep-work)"; bad=$((bad+1)); continue
  fi
  new="$work/new-$idv.json"
  python3 -I "$helper" expected "$idv" "$out" "$base" "$gen" "$new" || { echo "FAIL $idv: expected.json build"; bad=$((bad+1)); continue; }
  dest="$bench/$idv/expected.json"
  if [ "$check" = 1 ]; then
    if python3 -I "$helper" compare "$new" "$dest" > "$work/diff.txt"; then
      echo "ok   $idv"
    else
      echo "DIFF $idv"; cat "$work/diff.txt"; diffs=$((diffs+1))
    fi
  else
    cp "$new" "$dest"; echo "wrote $idv"
  fi
done < "$bench/papers.tsv"

[ "$total" -gt 0 ] || { echo "no rows selected" >&2; exit 2; }
if [ "$check" = 1 ]; then echo "checked $total, differences in $diffs, failed $bad"; else echo "regenerated $total, failed $bad"; fi
[ "$bad" = 0 ] && [ "$diffs" = 0 ] || exit 1
exit 0
