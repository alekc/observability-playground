#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./build-and-publish.sh
#   DEST_IMAGE=ghcr.io/acme/observability-demo TAG=v1.2.3 ./build-and-publish.sh

DEST_IMAGE="${DEST_IMAGE:-al3kc/observability-demo}"
TAG="${TAG:-v0.0.2}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER_NAME="${BUILDER_NAME:-observability-multiarch}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Multi-platform builds require a builder that is not the default docker driver.
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER_NAME" --driver docker-container --use
else
  docker buildx use "$BUILDER_NAME"
fi

docker buildx inspect --bootstrap >/dev/null

docker buildx build \
  --platform "$PLATFORMS" \
  -t "${DEST_IMAGE}:${TAG}" \
  --push \
  .
