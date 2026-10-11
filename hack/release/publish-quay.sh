#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
repository=quay.io/hydracz/karpenter-controller
image_tag="${IMAGE_TAG:-v$(date -u +%Y%m%d)-dev}"
if [[ ! "$image_tag" =~ ^v[0-9]{8}-dev([2-9]|[1-9][0-9]+)?$ ]]; then
  printf 'Expected vYYYYMMDD-dev, dev2, dev3, ...; got %s\n' "$image_tag" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  printf 'Commit changes before publishing a traceable image.\n' >&2
  exit 1
fi
for tool in ko docker curl jq; do
  command -v "$tool" > /dev/null
done
source_sha=$(git rev-parse HEAD)
source_date=$(git show -s --format=%ct HEAD)
for candidate in "$image_tag" "$source_sha"; do
  tags=$(curl --fail --silent --show-error "https://quay.io/api/v1/repository/hydracz/karpenter-controller/tag/?specificTag=$candidate&onlyActiveTags=true")
  if jq -e --arg tag "$candidate" '.tags | any(.name == $tag)' <<< "$tags" > /dev/null; then
    printf 'Refusing to overwrite existing image tag %s:%s\n' "$repository" "$candidate" >&2
    exit 1
  fi
done
mkdir -p dist/quay
tarball="$PWD/dist/quay/controller-$image_tag.tar"
KO_CONFIG_PATH="$PWD/hack/release/ko-amd64.yaml" \
  KO_DOCKER_REPO="$repository" SOURCE_DATE_EPOCH="$source_date" KO_DATA_DATE_EPOCH="$source_date" \
  GOFLAGS="-ldflags=-X=sigs.k8s.io/karpenter/pkg/operator.Version=$image_tag" \
  ko build --bare --platform=linux/amd64 --sbom none --push=false \
    --tarball="$tarball" --tags="$image_tag,$source_sha" \
    --image-label="org.opencontainers.image.revision=$source_sha" \
    --image-label="org.opencontainers.image.version=$image_tag" ./cmd/controller
docker load --input "$tarball"
[[ "$(docker image inspect "$repository:$image_tag" --format '{{.Os}}/{{.Architecture}}')" == linux/amd64 ]]
docker run --rm --platform=linux/amd64 "$repository:$image_tag" --help > /dev/null
if [[ "${BUILD_ONLY:-false}" == true ]]; then
  printf 'Verified local image %s:%s (linux/amd64)\n' "$repository" "$image_tag"
  exit 0
fi
docker push "$repository:$image_tag"
docker push "$repository:$source_sha"
docker buildx imagetools inspect "$repository:$image_tag"