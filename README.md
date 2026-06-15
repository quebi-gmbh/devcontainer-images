# devcontainer-images

Rebuilds Microsoft's **devcontainer images from upstream source** and publishes
them to this org's GitHub Container Registry (GHCR), so our devcontainers and CI
never hit **MCR pull rate limits** (`429 Too Many Requests`).

We **build**, not mirror, on purpose: copying the published images straight from
MCR 429s on GitHub's shared runner IPs — even a single pull, even the token
fetch. Rebuilding from the upstream recipe never touches MCR (the base comes from
Docker Hub via `mirror.gcr.io`), so it sidesteps the limit entirely.

## Use a built image

In `.devcontainer/devcontainer.json`:

```jsonc
{
  // was: mcr.microsoft.com/devcontainers/typescript-node:22-bookworm
  "image": "ghcr.io/quebi-gmbh/devcontainer-typescript-node:22-bookworm"
}
```

GHCR packages are **public**, so pulls need no `docker login`.

## How identical is it?

**Functionally identical**, not byte-identical. Each image is built from the
*same* upstream `Dockerfile` at a pinned commit, with the *same* devcontainer
features (`common-utils`, `node`, `git`) at the *same* digests locked in
upstream's `devcontainer-lock.json`, on the *same* Docker Hub `node` base. What
differs from MCR's published bytes: apt may pull newer patch versions and build
timestamps change — exactly what happens on upstream's own next rebuild. If you
ever need bit-for-bit MCR bytes, that requires copying MCR (which is what the
rate limit blocks).

## How it works

```
                  ┌─ patch FROM → mirror.gcr.io/library/node  (Docker Hub, no rate limit)
  javascript-node ┤  devcontainer build (applies locked features) ──▶ ghcr.io/…/devcontainer-javascript-node
                  └─ tier 1

                  ┌─ patch FROM → ghcr.io/…/devcontainer-javascript-node  (our tier-1 image)
  typescript-node ┤  devcontainer build (applies locked features) ──▶ ghcr.io/…/devcontainer-typescript-node
                  └─ tier 2 (needs tier 1)
```

- **`chain.json`** — upstream repo + pinned SHA, the base mirror, the variant
  list, the floating-tag aliases (`latest`, `22`, `bookworm`, …, matching
  upstream's tag scheme), and the image chain (build order via `needs`).
- **`scripts/build-image.sh`** — builds one image variant: fetches the pinned
  upstream source, **patches the Dockerfile** (pin `VARIANT`, retarget the base
  `FROM` off MCR — and hard-fails if any `mcr.microsoft.com` reference survives),
  runs the devcontainer CLI to apply the locked features, pushes multi-arch
  (`amd64` + `arm64`), then adds the dated tag and floating aliases as GHCR→GHCR
  copies.
- **`.github/workflows/build.yml`** — weekly (`cron`), on demand
  (`workflow_dispatch`, with `only_variant` / `platforms` inputs for cheap test
  runs), and on config changes. Authenticates to GHCR with the built-in
  `GITHUB_TOKEN` (no PAT).

> **Why not Docker Hub or a plain copy?** The devcontainer images live only on
> MCR (`hub.docker.com/r/microsoft/devcontainers` is empty), and copying from MCR
> is exactly what the rate limit blocks.

## Variants & tags

9 variants — `{20,22,24}-{trixie,bookworm,bullseye}` — per `chain.json`, each
published as `:<node>-<distro>`, `:<node>-<distro>-<YYYYMMDD>` (pinnable), plus
floating aliases (`latest`, `trixie`, `24`, `22`, `20`, `bookworm`, `bullseye`).

## Updating

- **Track new upstream releases:** bump `upstream.sha` in `chain.json` (and the
  feature digests follow from upstream's lock file). Pushing to `main` rebuilds.
- **Add an image family** (e.g. `python`, `go`): add an entry to `images` in
  `chain.json` and a matching matrix job in `build.yml`. If it depends on another
  image, set `needs` and wire the job ordering.

## Testing a change cheaply

```bash
# One variant, amd64 only — fast smoke test before a full multi-arch run.
gh workflow run build.yml -R quebi-gmbh/devcontainer-images \
  -f only_variant=24-trixie -f platforms=linux/amd64
```

## One-time setup

First push creates the packages as **private**. Make each public so pulls need
no auth: org → *Packages* → package → *Package settings* → *Change visibility →
Public*.
