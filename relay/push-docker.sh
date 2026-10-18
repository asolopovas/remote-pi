#!/usr/bin/env bash
# Build a multi-platform image and push it to an explicitly selected repository.
# Version is read from Cargo.toml — bump `version = "..."` there before running.
#
# Usage:
#   DOCKER_IMAGE=your-namespace/your-repository ./push-docker.sh
#
# Always tags `:v<cargo-version>` and `:latest`.
#
# Requirements:
#   docker buildx (bundled with modern Docker).
#   Log in first with: docker login

set -euo pipefail

# Requires the monorepo checkout for the shared destination guard.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../scripts/docker-image-destination.sh"
# No upstream default: select a repository you are authorized to publish.
IMAGE="${DOCKER_IMAGE:-}"
validate_docker_image "$IMAGE"
PLATFORMS="linux/amd64,linux/arm64"
BUILDER="multiarch"

# Always resolve paths relative to this script so it can be called from anywhere
cd "$SCRIPT_DIR"

# Extract the [package] version from Cargo.toml.
VERSION=$(awk '
  /^\[package\]/ { in_pkg = 1; next }
  /^\[/          { in_pkg = 0 }
  in_pkg && /^version[[:space:]]*=/ {
    gsub(/[" ]/, "")
    sub(/^version=/, "")
    print
    exit
  }
' Cargo.toml)

if [[ -z "$VERSION" ]]; then
  echo "✗ Could not extract version from Cargo.toml" >&2
  exit 1
fi

TAG="v$VERSION"

# The default `docker` driver cannot build multi-platform images in one shot.
# Ensure a `docker-container` builder exists and is selected. Idempotent.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  echo "→ Creating buildx builder '$BUILDER' (docker-container driver)"
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi
docker buildx use "$BUILDER"

echo "→ Building $IMAGE:$TAG + :latest ($PLATFORMS)"

docker buildx build \
  --platform "$PLATFORMS" \
  --tag "$IMAGE:$TAG" \
  --tag "$IMAGE:latest" \
  --push \
  .

echo "✓ Pushed $IMAGE:$TAG and $IMAGE:latest"
