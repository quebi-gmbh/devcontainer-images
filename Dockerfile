# Thin passthrough image: same as upstream today, but a seam to add
# org-specific tooling later (CA certs, apt packages, dotfiles, etc.).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

# Example of org customization — uncomment / extend as needed:
# RUN apt-get update \
#  && apt-get install -y --no-install-recommends ca-certificates \
#  && rm -rf /var/lib/apt/lists/*
