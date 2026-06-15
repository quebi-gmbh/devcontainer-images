#!/usr/bin/env python3
"""Discover which upstream tags to mirror and emit the build matrix.

Reads images.yaml, queries each repo's MCR tag list, applies the include/exclude
policy, and prints a JSON array of {source, name, tag} objects to stdout — the
matrix consumed by .github/workflows/mirror.yml. A human-readable summary is
written to stderr (visible in the Actions log without affecting the output).

Usage:
    python scripts/discover.py            # JSON to stdout, summary to stderr
    python scripts/discover.py --pretty   # indented JSON (for eyeballing locally)

No third-party deps beyond PyYAML (preinstalled on GitHub-hosted runners).
"""
from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request

import yaml

CONFIG = "images.yaml"
TIMEOUT = 30
RETRIES = 3


def fetch_tags(registry: str, repo_path: str) -> list[str]:
    """Return all tags for <registry>/v2/<repo_path>/tags/list, following any
    Link-header pagination (MCR currently returns everything in one page, but
    this stays correct if that changes)."""
    url = f"https://{registry}/v2/{repo_path}/tags/list?n=1000"
    tags: list[str] = []
    while url:
        body, link = _get(url)
        tags.extend(json.loads(body).get("tags") or [])
        url = _next_link(link, registry)
    return tags


def _get(url: str) -> tuple[bytes, str | None]:
    last: Exception | None = None
    for attempt in range(RETRIES):
        try:
            req = urllib.request.Request(url, headers={"Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.read(), resp.headers.get("Link")
        except (urllib.error.URLError, TimeoutError) as exc:  # pragma: no cover
            last = exc
    raise SystemExit(f"error: failed to fetch {url}: {last}")


def _next_link(link: str | None, registry: str) -> str | None:
    if not link:
        return None
    m = re.search(r'<([^>]+)>\s*;\s*rel="next"', link)
    if not m:
        return None
    nxt = m.group(1)
    return nxt if nxt.startswith("http") else f"https://{registry}{nxt}"


def as_list(value) -> list[str]:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def select(tags: list[str], include: list[str], exclude: list[str]) -> list[str]:
    inc = [re.compile(p) for p in include]
    exc = [re.compile(p) for p in exclude]
    keep = [
        t for t in tags
        if any(p.fullmatch(t) for p in inc) and not any(p.search(t) for p in exc)
    ]
    # Stable, readable ordering: shorter/simpler tags first, then alphabetical.
    return sorted(set(keep), key=lambda t: (len(t), t))


def main() -> int:
    with open(CONFIG) as fh:
        cfg = yaml.safe_load(fh)

    registry = cfg["registry"]
    namespace = cfg["namespace"]
    defaults = cfg.get("defaults", {})
    def_inc = as_list(defaults.get("include", ".+"))
    def_exc = as_list(defaults.get("exclude"))

    matrix: list[dict[str, str]] = []
    print(f"Discovering tags from {registry}/{namespace}:", file=sys.stderr)

    for entry in cfg["repos"]:
        repo = entry["repo"]
        name = entry["name"]
        include = as_list(entry.get("include")) or def_inc
        exclude = as_list(entry.get("exclude")) if "exclude" in entry else def_exc

        all_tags = fetch_tags(registry, f"{namespace}/{repo}")
        chosen = select(all_tags, include, exclude)
        print(
            f"  {namespace}/{repo}: {len(chosen)}/{len(all_tags)} tags -> "
            f"ghcr.io/.../{name}\n    {', '.join(chosen)}",
            file=sys.stderr,
        )
        for tag in chosen:
            matrix.append({
                "source": f"{registry}/{namespace}/{repo}:{tag}",
                "name": name,
                "tag": tag,
            })

    print(f"Total: {len(matrix)} image builds", file=sys.stderr)

    if not matrix:
        print("error: no tags selected — check include/exclude in images.yaml", file=sys.stderr)
        return 1
    if len(matrix) > 256:
        # GitHub Actions caps a matrix at 256 jobs.
        print(
            f"error: {len(matrix)} builds exceeds the 256-job matrix cap; "
            "tighten include/exclude in images.yaml",
            file=sys.stderr,
        )
        return 1

    indent = 2 if "--pretty" in sys.argv else None
    print(json.dumps(matrix, indent=indent))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
