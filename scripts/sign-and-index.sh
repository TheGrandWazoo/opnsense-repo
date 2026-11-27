#!/bin/sh
#
# Build the os-ksa-repo bootstrap package, add it to every track, then sign
# each track with `pkg repo` and prove the signature verifies against the
# fingerprint the bootstrap package installs. Runs on FreeBSD (the publish
# workflow's VM) from the repository root, after scripts/fetch_sources.py.
#
#   OPNSENSE_SERIES  opnsense/plugins branch used to build the bootstrap (default 26.7)
#   KSA_SIGNING_KEY_B64  PEM private key, base64 on one line (the workflow
#                        encodes the `publish` environment secret; multi-line
#                        values do not survive the trip into the VM intact)

set -eu

SERIES="${OPNSENSE_SERIES:-26.7}"
ROOT="$(pwd)"
SITE="${ROOT}/site"
WORK="${ROOT}/work"
KEY="$(mktemp /tmp/ksa.key.XXXXXX)"
trap 'rm -f "${KEY}"' EXIT

: "${KSA_SIGNING_KEY_B64:?KSA_SIGNING_KEY_B64 is not set}"
umask 077
printf '%s' "${KSA_SIGNING_KEY_B64}" | openssl base64 -d -A > "${KEY}"
umask 022
# Fail early, without printing anything secret, if the key did not arrive intact.
openssl pkey -in "${KEY}" -noout 2>/dev/null || { echo "signing key is not a valid private key"; exit 1; }
EXPECTED_FP="$(openssl pkey -in "${KEY}" -pubout 2>/dev/null | openssl dgst -sha256 -r | cut -d' ' -f1)"
grep -rqs "${EXPECTED_FP}" "${ROOT}/bootstrap/src/etc/pkg/fingerprints/KSA/trusted" || {
    echo "signing key's fingerprint ${EXPECTED_FP} is not in bootstrap trusted/"; exit 1; }
echo "signing key OK, fingerprint ${EXPECTED_FP}"

# Fingerprint-verified repositories (signature_type: "fingerprints", as used
# by OPNsense and FreeBSD) need the signature and the public key inside the
# catalogue, which pkg only writes when signing through a signing_command.
# This is the signing script from pkg-repo(8).
PUB="$(mktemp /tmp/ksa.pub.XXXXXX)"
SIGN="$(mktemp /tmp/ksa.sign.XXXXXX)"
trap 'rm -f "${KEY}" "${PUB}" "${SIGN}"' EXIT
openssl pkey -in "${KEY}" -pubout -out "${PUB}" 2>/dev/null
cat > "${SIGN}" <<SCRIPT
#!/bin/sh
read -t 2 sum
[ -z "\$sum" ] && exit 1
echo SIGNATURE
echo -n "\$sum" | /usr/bin/openssl dgst -sign "${KEY}" -sha256 -binary
echo
echo CERT
cat "${PUB}"
echo END
SCRIPT
chmod 700 "${SIGN}"

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
    pkg repo "${TRACK}" signing_command: "${SIGN}"
    echo "signed ${TRACK#"${SITE}"/} ($(find "${ALL}" -name '*.pkg' | wc -l | tr -d ' ') packages):" \
        "$(find "${TRACK}" -maxdepth 1 -type f -exec basename {} \; | sort | tr '\n' ' ')"
    echo "  packagesite.pkg holds: $(tar -tf "${TRACK}/packagesite.pkg" 2>/dev/null | tr '\n' ' ')"
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
    # pkg update can exit 0 even when it rejects a repository, so check the
    # messages and that the catalogue really lists the bootstrap package.
    rm -rf "${TEST}/db" && mkdir -p "${TEST}/db"
    OUT="$(pkg -o REPOS_DIR="${TEST}/repos" -o PKG_DBDIR="${TEST}/db" update -f 2>&1 || true)"
    printf '%s\n' "${OUT}"
    if printf '%s' "${OUT}" | grep -qiE 'no signature|signature.*(fail|invalid|mismatch)|untrusted|not trusted'; then
        echo "FAILED: ${TRACK#"${SITE}"/} signature not accepted"; exit 1
    fi
    FOUND="$(pkg -o REPOS_DIR="${TEST}/repos" -o PKG_DBDIR="${TEST}/db" rquery -r KSA-verify '%n' 2>/dev/null | grep -c '^os-ksa-repo$' || true)"
    [ "${FOUND}" = "1" ] || { echo "FAILED: ${TRACK#"${SITE}"/} catalogue does not list os-ksa-repo"; exit 1; }
    echo "verified ${TRACK#"${SITE}"/}"
done
rm -rf "${TEST}"
