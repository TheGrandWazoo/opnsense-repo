#!/bin/sh
#
# Build the os-ksa-repo bootstrap package, add it to every track, then sign
# each track with `pkg repo` and prove the signature verifies against the
# fingerprint the bootstrap package installs. Runs on FreeBSD (the publish
# workflow's VM) from the repository root, after scripts/fetch_sources.py.
#
#   OPNSENSE_SERIES  opnsense/plugins branch used to build the bootstrap (default 26.7)
#   KSA_SIGNING_KEY  PEM private key (the `publish` environment secret)

set -eu

SERIES="${OPNSENSE_SERIES:-26.7}"
ROOT="$(pwd)"
SITE="${ROOT}/site"
WORK="${ROOT}/work"
KEY="$(mktemp /tmp/ksa.key.XXXXXX)"
trap 'rm -f "${KEY}"' EXIT

: "${KSA_SIGNING_KEY:?KSA_SIGNING_KEY is not set}"
umask 077
printf '%s\n' "${KSA_SIGNING_KEY}" > "${KEY}"
umask 022

echo ">>> Building os-ksa-repo with opnsense/plugins stable/${SERIES}"
rm -rf "${WORK}"
mkdir -p "${WORK}"
git clone -q --depth 1 -b "stable/${SERIES}" https://github.com/opnsense/plugins.git "${WORK}/plugins"
mkdir -p "${WORK}/plugins/vendor/ksa"
cp -R "${ROOT}/bootstrap/." "${WORK}/plugins/vendor/ksa/"
make -C "${WORK}/plugins/vendor/ksa" package
BOOT="$(find "${WORK}/plugins/vendor/ksa" -name 'os-ksa-repo-*.pkg' | head -n 1)"
[ -n "${BOOT}" ] || { echo "bootstrap package not built"; exit 1; }
pkg info -F "${BOOT}"

# Stable URL for first-time installs: pkg add <site>/os-ksa-repo.pkg
cp "${BOOT}" "${SITE}/os-ksa-repo.pkg"
cp "${ROOT}"/bootstrap/src/etc/pkg/fingerprints/KSA/trusted/* "${SITE}/" 2>/dev/null || true

echo ">>> Signing tracks"
for ALL in $(find "${SITE}" -type d -name All | sort); do
    TRACK="$(dirname "${ALL}")"
    cp "${BOOT}" "${ALL}/"
    pkg repo -q "${TRACK}" "${KEY}"
    echo "signed ${TRACK#"${SITE}"/} ($(find "${ALL}" -name '*.pkg' | wc -l | tr -d ' ') packages)"
done

echo ">>> Verifying every track against the bootstrap fingerprint"
TEST="$(mktemp -d /tmp/ksa-verify.XXXXXX)"
mkdir -p "${TEST}/repos" "${TEST}/db"
cp -R "${ROOT}/bootstrap/src/etc/pkg/fingerprints/KSA" "${TEST}/fingerprints"
for ALL in $(find "${SITE}" -type d -name All | sort); do
    TRACK="$(dirname "${ALL}")"
    cat > "${TEST}/repos/ksa.conf" <<EOF
FreeBSD: { enabled: no }
FreeBSD-ports: { enabled: no }
FreeBSD-ports-kmods: { enabled: no }
FreeBSD-base: { enabled: no }
KSA-verify: {
  url: "file://${TRACK}",
  signature_type: "fingerprints",
  fingerprints: "${TEST}/fingerprints",
  enabled: yes
}
EOF
    pkg -o REPOS_DIR="${TEST}/repos" -o PKG_DBDIR="${TEST}/db" -o ABI="$(echo "${TRACK#"${SITE}"/}" | cut -d/ -f1)" update -f -q
    echo "verified ${TRACK#"${SITE}"/}"
done
rm -rf "${TEST}"
