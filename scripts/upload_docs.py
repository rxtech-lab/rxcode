#!/usr/bin/env python3
"""Upload markdown docs under docs/ to the autopilot docs service.

Stdlib-only. Walks docs/, parses YAML frontmatter, keeps files that declare a
`slug`, errors on duplicate slugs, and POSTs documents in batches of 50 to:

    {DOCS_ENDPOINT}/api/v1/docs/repositories/{url-encoded repo}/documents

with `Authorization: Bearer $DOCS_UPLOAD_TOKEN` and body:

    {"documents": [{"docId": slug, "content": body}, ...]}

Environment:
    DOCS_ENDPOINT        default https://autopilot.rxlab.app
    DOCS_REPOSITORY_ID   e.g. owner/repo  (required unless --dry-run)
    DOCS_UPLOAD_TOKEN    bearer token     (required unless --dry-run)

Usage:
    python scripts/upload_docs.py [--dry-run] [--docs-dir docs]
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_ENDPOINT = "https://autopilot.rxlab.app"
BATCH_SIZE = 50


def parse_frontmatter(text):
    """Return (frontmatter_dict, body) for a markdown file.

    Only a tiny, dependency-free subset of YAML is supported: a leading
    `---` fenced block of `key: value` lines. Returns ({}, text) when no
    frontmatter is present.
    """
    if not text.startswith("---"):
        return {}, text
    lines = text.splitlines()
    if lines[0].strip() != "---":
        return {}, text
    fm = {}
    body_start = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            body_start = i + 1
            break
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        fm[key.strip()] = value
    if body_start is None:
        return {}, text
    body = "\n".join(lines[body_start:]).lstrip("\n")
    return fm, body


def collect_documents(docs_dir):
    """Walk docs_dir and return a list of {docId, content}, erroring on dupes."""
    documents = []
    seen = {}
    for root, _dirs, files in os.walk(docs_dir):
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            path = os.path.join(root, name)
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
            fm, body = parse_frontmatter(text)
            slug = fm.get("slug")
            if not slug:
                print(f"  skip (no slug): {path}")
                continue
            if slug in seen:
                raise SystemExit(
                    f"Duplicate slug '{slug}' in {path} and {seen[slug]}"
                )
            seen[slug] = path
            documents.append({"docId": slug, "content": body})
            print(f"  + {slug}  ({path})")
    return documents


def post_batch(endpoint, repo_id, token, batch):
    url = "{}/api/v1/docs/repositories/{}/documents".format(
        endpoint.rstrip("/"), urllib.parse.quote(repo_id, safe="")
    )
    data = json.dumps({"documents": batch}).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req) as resp:
        status = resp.getcode()
        payload = resp.read().decode("utf-8", "replace")
    return status, payload


def main(argv=None):
    parser = argparse.ArgumentParser(description="Upload docs/ to autopilot.")
    parser.add_argument("--dry-run", action="store_true",
                        help="Parse and batch only; no network calls.")
    parser.add_argument("--docs-dir", default="docs",
                        help="Docs directory to walk (default: docs).")
    args = parser.parse_args(argv)

    endpoint = os.environ.get("DOCS_ENDPOINT", DEFAULT_ENDPOINT)
    repo_id = os.environ.get("DOCS_REPOSITORY_ID")
    token = os.environ.get("DOCS_UPLOAD_TOKEN")

    if not os.path.isdir(args.docs_dir):
        raise SystemExit(f"Docs directory not found: {args.docs_dir}")

    print(f"Collecting docs from {args.docs_dir}/ ...")
    documents = collect_documents(args.docs_dir)
    if not documents:
        raise SystemExit("No documents with a slug found; nothing to upload.")

    batches = [documents[i:i + BATCH_SIZE]
               for i in range(0, len(documents), BATCH_SIZE)]
    print(f"\n{len(documents)} document(s) in {len(batches)} batch(es) "
          f"of up to {BATCH_SIZE}.")

    if args.dry_run:
        print("\n[dry-run] No network calls made. Endpoint would be:")
        print(f"  {endpoint}/api/v1/docs/repositories/"
              f"{urllib.parse.quote(repo_id or '<DOCS_REPOSITORY_ID>', safe='')}"
              f"/documents")
        return 0

    if not repo_id:
        raise SystemExit("DOCS_REPOSITORY_ID is required (e.g. owner/repo).")
    if not token:
        raise SystemExit("DOCS_UPLOAD_TOKEN is required.")

    for idx, batch in enumerate(batches, start=1):
        try:
            status, payload = post_batch(endpoint, repo_id, token, batch)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            raise SystemExit(
                f"Batch {idx} failed: HTTP {exc.code} {exc.reason}\n{body}")
        except urllib.error.URLError as exc:
            raise SystemExit(f"Batch {idx} failed: {exc.reason}")
        print(f"Batch {idx}/{len(batches)}: HTTP {status} {payload}")

    print("\nDone. Uploads are async; docs become searchable once embedding "
          "finishes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
