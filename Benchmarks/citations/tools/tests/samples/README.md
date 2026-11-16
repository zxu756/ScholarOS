# Handwritten Synthetic Samples (`tools/tests/samples/`)

All `.json` files in this directory are **handwritten minimal structural samples** modeled after the public JSON schemas of Crossref (`/works/<DOI>` and `/works?filter=update-type:retraction`), OpenAlex (`/works`), and the `doi.org` Handle API (`/api/handles/<DOI>`).

They exist solely to test the benchmark generation and validation scripts under `Benchmarks/citations/tools/` completely offline (`unittest`), without network access. They are never referenced by ScholarOS's Swift product or product unit tests.
