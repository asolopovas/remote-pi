#!/usr/bin/env bash
# Build a multi-platform image and push it to an explicitly selected repository.
#
# Usage:
#   DOCKER_IMAGE=your-namespace/your-repository ./push-docker.sh              → tags as :latest
#   DOCKER_IMAGE=your-namespace/your-repository ./push-docker.sh v1.2.3       → tags as :v1.2.3 AND :latest
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
VERSION="${1:-}"
PLATFORMS="linux/amd64,linux/arm64"
BUILDER="multiarch"

# Always resolve paths relative to this script so it can be called from anywhere
cd "$SCRIPT_DIR"

# The default `docker` driver cannot build multi-platform images in one shot.
# Ensure a `docker-container` builder exists and is selected. Idempotent.
if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  echo "→ Creating buildx builder '$BUILDER' (docker-container driver)"
  docker buildx create --name "$BUILDER" --driver docker-container --bootstrap >/dev/null
fi
docker buildx use "$BUILDER"

if [[ -n "$VERSION" ]]; then
  TAGS=(--tag "$IMAGE:$VERSION" --tag "$IMAGE:latest")
  echo "→ Building $IMAGE:$VERSION + :latest ($PLATFORMS)"
else
  TAGS=(--tag "$IMAGE:latest")
  echo "→ Building $IMAGE:latest ($PLATFORMS)"
fi

docker buildx build \
  --platform "$PLATFORMS" \
  "${TAGS[@]}" \
  --build-arg "NEXT_PUBLIC_REPOSITORY_URL=${NEXT_PUBLIC_REPOSITORY_URL:-}" \
  --build-arg "NEXT_PUBLIC_SITE_URL=${NEXT_PUBLIC_SITE_URL:-}" \
  --push \
  .

echo "✓ Done"
