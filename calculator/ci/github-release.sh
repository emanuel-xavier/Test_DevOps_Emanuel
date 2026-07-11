#!/usr/bin/env sh
# Create (or reuse) a GitHub Release and upload build artifacts to it.
#
# Uses only curl (already present in the Jenkins agent) + the GitHub REST API,
# so no `gh` CLI or agent image rebuild is needed.
#
# Required environment:
#   GITHUB_TOKEN   PAT / fine-grained token with `contents:write` on the repo.
#   REPO_SLUG      owner/name, e.g. emanuel-xavier/Test_DevOps_Emanuel
#   REL_VERSION    release tag + name, e.g. build-42 or v1.2.0
#   GIT_COMMIT     commit SHA the release/tag points at
# Optional:
#   ASSETS         space-separated file paths to upload (default: none)
set -eu

: "${GITHUB_TOKEN:?GITHUB_TOKEN required}"
: "${REPO_SLUG:?REPO_SLUG required}"
: "${REL_VERSION:?REL_VERSION required}"
: "${GIT_COMMIT:?GIT_COMMIT required}"
ASSETS="${ASSETS:-}"

API="https://api.github.com/repos/${REPO_SLUG}"
UPLOAD="https://uploads.github.com/repos/${REPO_SLUG}"
AUTH="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT="Accept: application/vnd.github+json"

echo "Creating release ${REL_VERSION} on ${REPO_SLUG} @ ${GIT_COMMIT}"

# target_commitish uses the SHA so the tag is created on the exact built commit.
body=$(cat <<JSON
{
  "tag_name": "${REL_VERSION}",
  "target_commitish": "${GIT_COMMIT}",
  "name": "${REL_VERSION}",
  "body": "Automated release from Jenkins build. Commit ${GIT_COMMIT}.",
  "draft": false,
  "prerelease": false
}
JSON
)

resp=$(curl -sS -X POST "${API}/releases" \
    -H "${AUTH}" -H "${ACCEPT}" -d "${body}")

release_id=$(echo "${resp}" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | head -n1)

# Tag may already exist (re-run / already-released commit). Reuse it.
if [ -z "${release_id}" ]; then
    echo "Create failed or tag exists; fetching existing release for ${REL_VERSION}"
    resp=$(curl -sS "${API}/releases/tags/${REL_VERSION}" -H "${AUTH}" -H "${ACCEPT}")
    release_id=$(echo "${resp}" | sed -n 's/.*"id": *\([0-9]*\).*/\1/p' | head -n1)
fi

if [ -z "${release_id}" ]; then
    echo "ERROR: could not create or find release ${REL_VERSION}" >&2
    echo "${resp}" >&2
    exit 1
fi
echo "Release id: ${release_id}"

for f in ${ASSETS}; do
    [ -f "${f}" ] || { echo "skip missing asset ${f}"; continue; }
    name=$(basename "${f}")
    echo "Uploading ${name}"
    curl -sS -X POST "${UPLOAD}/releases/${release_id}/assets?name=${name}" \
        -H "${AUTH}" -H "${ACCEPT}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary @"${f}" >/dev/null
done

echo "Release ${REL_VERSION} ready: https://github.com/${REPO_SLUG}/releases/tag/${REL_VERSION}"
