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

# No upstream default: explicitly select a repository you are authorized to publish.
# Require a namespace/registry plus repository, without a tag, digest or URL scheme.
IMAGE="${DOCKER_IMAGE:-}"
component='[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*'
label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
registry="${label}(\.${label})*(:[0-9]{1,5})?"
if [[ ${#IMAGE} -gt 255 || ! "$IMAGE" =~ ^${registry}/${component}(/${component})*$ ]]; then
  echo "error: set DOCKER_IMAGE to an explicit untagged namespace/repository or registry[:port]/repository you own" >&2
  exit 1
fi
if [[ "${IMAGE%%/*}" == *:* ]]; then
  port="${IMAGE%%/*}"
  port="${port##*:}"
  if (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "error: DOCKER_IMAGE registry port must be between 1 and 65535" >&2
    exit 1
  fi
fi
VERSION="${1:-}"
PLATFORMS="linux/amd64,linux/arm64"
BUILDER="multiarch"

# Always resolve paths relative to this script so it can be called from anywhere
cd "$(dirname "$0")"

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
  --push \
  .

echo "✓ Done"
