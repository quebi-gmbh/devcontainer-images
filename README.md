# devcontainer-images

Mirrors upstream **devcontainer / base images** into this org's GitHub Container
Registry (GHCR) so our devcontainers and CI never hit MCR / Docker Hub
**pull rate limits**. A scheduled GitHub Actions workflow scrapes the newest
upstream tags weekly, rebuilds them, and republishes to
`ghcr.io/quebi-gmbh/<name>:<tag>`.

## Use a mirrored image

In `.devcontainer/devcontainer.json`:

```jsonc
{
  // was: mcr.microsoft.com/devcontainers/typescript-node:22-bookworm
  "image": "ghcr.io/quebi-gmbh/devcontainer-typescript-node:22-bookworm"
}
```

The GHCR packages are **public**, so pulls need no `docker login`.

## How it works

```
images.yaml ──▶ scripts/discover.py ──▶ build matrix ──▶ buildx ──▶ ghcr.io/quebi-gmbh/*
   (what)         (scrape MCR tags)        (per tag)     (multi-arch)
```

- **`images.yaml`** — which upstream families to mirror and the tag-selection
  policy (`include` / `exclude` regexes). Defaults keep only the *rolling*
  tags (e.g. `22-bookworm`, `latest`) and drop frozen pins (`4.0.10-…`),
  `dev-` channels, and EOL Node/Debian. The policy auto-extends to future
  releases (e.g. Node 26) with no edits.
- **`scripts/discover.py`** — queries `mcr.microsoft.com/v2/<ns>/<repo>/tags/list`
  and emits the `{source, name, tag}` build matrix. Run it locally to preview:
  ```bash
  python scripts/discover.py --pretty   # JSON on stdout, summary on stderr
  ```
- **`Dockerfile`** — a thin `FROM ${BASE_IMAGE}` passthrough. Identical to
  upstream today; a seam for org tooling (certs, apt packages) later.
- **`.github/workflows/mirror.yml`** — runs weekly (`cron`), on demand
  (`workflow_dispatch`), and on changes to the config. Authenticates to GHCR
  with the built-in `GITHUB_TOKEN` (no PAT), builds `linux/amd64,linux/arm64`,
  and tags each image `:<tag>` plus `:<tag>-<YYYYMMDD>` for pinning/rollback.

> **Why not Docker Hub?** The devcontainer images live on **MCR**;
> `hub.docker.com/r/microsoft/devcontainers` is effectively empty.

## Add another image

Append to `images.yaml`:

```yaml
repos:
  - repo: typescript-node
    name: devcontainer-typescript-node
  - repo: python                  # mcr.microsoft.com/devcontainers/python
    name: devcontainer-python
    # include: '^(3|3-bookworm|latest)$'   # optional per-repo override
```

Commit to `main` (triggers a build) or run the workflow manually. Preview the
selected tags with `python scripts/discover.py` first — the matrix is capped at
GitHub's 256-job limit; tighten `include`/`exclude` if you exceed it.

## One-time setup

First push creates the packages as **private**. Make each public so pulls need
no auth: org → *Packages* → package → *Package settings* → *Change visibility →
Public* (and, optionally, *Manage Actions access* → link this repo).
