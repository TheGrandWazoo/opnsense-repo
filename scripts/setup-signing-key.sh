#!/bin/sh
#
# Create a repository signing key, or stage a new one for rotation.
#
# The private key is generated in a private temp directory, stored only as
# a secret of this repo's `publish` environment, and deleted. It is never
# printed or written anywhere else. The public key and its sha256
# fingerprint are written into the repo: keys/<name>.pub, and the bootstrap
# package's trusted fingerprints.
#
#   First key:   scripts/setup-signing-key.sh          (slot KSA_SIGNING_KEY)
#   Rotation:    SECRET=<unused slot> scripts/setup-signing-key.sh
#                slots: KSA_SIGNING_KEY, KSA_SIGNING_KEY_NEXT; then follow
#                "Rotating the signing key" in README.md
#
# Needs: openssl, gh (logged in with admin rights on the repo).

set -eu

REPO="${REPO:-TheGrandWazoo/opnsense-repo}"
# Once a key exists, the slot must be named explicitly so the key in use
# is never overwritten by accident.
EXISTING=0
# KEY_NAME, not NAME: login shells (WSL, many distros) set NAME to the hostname.
KEY_NAME="${KEY_NAME:-pkg.ksatechnologies.$(date -u +%Y%m%d)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRUSTED="${ROOT}/bootstrap/src/etc/pkg/fingerprints/KSA/trusted"

[ -n "$(ls -A "${TRUSTED}" 2>/dev/null)" ] && EXISTING=1
if [ "${EXISTING}" = "1" ] && [ -z "${SECRET:-}" ]; then
    echo "A signing key already exists. Name the slot that is NOT in use:" >&2
    echo "  SECRET=KSA_SIGNING_KEY_NEXT $0   (or SECRET=KSA_SIGNING_KEY)" >&2
    exit 1
fi
SECRET="${SECRET:-KSA_SIGNING_KEY}"
case "${SECRET}" in
    KSA_SIGNING_KEY|KSA_SIGNING_KEY_NEXT) ;;
    *) echo "SECRET must be KSA_SIGNING_KEY or KSA_SIGNING_KEY_NEXT" >&2; exit 1 ;;
esac
[ -e "${TRUSTED}/${KEY_NAME}" ] && { echo "${TRUSTED}/${KEY_NAME} already exists; set KEY_NAME=..." >&2; exit 1; }

umask 077
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

openssl genrsa -out "${TMP}/key" 4096 2>/dev/null
openssl rsa -in "${TMP}/key" -pubout -out "${TMP}/pub" 2>/dev/null

gh secret set "${SECRET}" --repo "${REPO}" --env publish < "${TMP}/key"

umask 022
mkdir -p "${ROOT}/keys" "${TRUSTED}"
cp "${TMP}/pub" "${ROOT}/keys/${KEY_NAME}.pub"
FP="$(openssl dgst -sha256 -r "${TMP}/pub" | cut -d' ' -f1)"
printf 'function: "sha256"\nfingerprint: "%s"\n' "${FP}" > "${TRUSTED}/${KEY_NAME}"

echo "Stored ${SECRET} in ${REPO} (environment: publish)"
echo "Public key:  keys/${KEY_NAME}.pub"
echo "Fingerprint: ${FP} (${TRUSTED#"${ROOT}"/}/${KEY_NAME})"
