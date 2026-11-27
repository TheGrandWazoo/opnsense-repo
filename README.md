# KSA Technologies OPNsense package repository

> **In short:** A signed FreeBSD package repository for KSA Technologies
> OPNsense plugins, starting with os-sbc. Install one small package on a
> firewall and the plugins appear under **System > Firmware > Plugins** and
> update with normal firmware updates. This repo holds the bootstrap
> package, the publishing scripts and the public signing key; the
> repository itself is served from GitHub Pages.

Site: <https://thegrandwazoo.github.io/opnsense-repo/>

## Install on an OPNsense firewall

From a shell on the firewall (console option 8, or SSH):

```sh
pkg add https://thegrandwazoo.github.io/opnsense-repo/os-ksa-repo.pkg
```

Then open **System > Firmware > Plugins**, click **Check for updates**, and
install the plugin you want (for example `os-sbc-devel`).

`os-ksa-repo` follows the pattern of OPNsense's official vendor plugins
(`os-sunnyvalley`): it installs the repository configuration and the
signing fingerprint, and the firmware keeps them in place across updates.
Remove it the same way you remove any plugin.

### Manual install (without the bootstrap package)

```sh
mkdir -p /usr/local/etc/pkg/fingerprints/KSA/trusted /usr/local/etc/pkg/fingerprints/KSA/revoked
fetch -o /usr/local/etc/pkg/fingerprints/KSA/trusted/ \
    https://thegrandwazoo.github.io/opnsense-repo/<fingerprint-file>   # name listed on the site
```

and create `/usr/local/etc/pkg/repos/KSA.conf` with the contents of
[`bootstrap/src/etc/pkg/repos/KSA.conf.shadow.in`](bootstrap/src/etc/pkg/repos/KSA.conf.shadow.in),
replacing `%%PLUGIN_ABI%%` with your OPNsense series (e.g. `26.7`).

## Tracks

Packages live at `<ABI>/<OPNsense series>/<track>/`, the same shape as
OPNsense's own repository, so a 26.7 build is never offered to a 27.1
firewall.

| Track | Repo name on the firewall | Contents | Enabled by `os-ksa-repo` |
|---|---|---|---|
| `devel` | `KSA-devel` | Latest build of each plugin's `next` branch (`os-sbc-devel`) | yes |
| `v1/testing` | — | Release candidates and releases of major version 1 | no (opt in by hand) |
| `v1/stable` | `KSA` | Releases of major version 1 (`os-sbc`) | yes |

Each major version gets its own track, so a firewall is never upgraded
across a major version without someone choosing to (os-SBC ADR-SBC-0005).
Priority is 5, below OPNsense's own repository (11) and other vendors, so
this repository can never replace an OPNsense package.

## How publishing works

```
plugin repo (e.g. os-SBC)                 this repo (publish workflow)
-------------------------                 ----------------------------
CI on next  -> release "devel"     --->   every 30 min, on push, or by hand:
CI on vX.Y.Z tag -> release vX.Y.Z        1. read sources.toml, list releases
   (.pkg files + manifest.json)           2. rebuild site/ from scratch
                                          3. FreeBSD VM: build os-ksa-repo,
                                             `pkg repo` sign each track,
                                             verify against the fingerprint
                                          4. force-push one commit to gh-pages
```

- **No cross-repo secrets.** Plugin repos publish releases with their own
  `GITHUB_TOKEN`; this repo pulls public release assets. The signing key
  exists only here, as a secret of the `publish` environment, which only
  `main` can use.
- **Stateless.** gh-pages is rebuilt each time; nothing is lost if it is
  deleted. It is published only when the selection of packages or the
  bootstrap package changed (`state.json`).

### Adding a plugin

1. In the plugin's CI, publish GitHub releases with the `.pkg` files and a
   `manifest.json`: `{"series": "26.7", "abi": "FreeBSD:15:amd64", "packages": ["..."]}`.
   os-SBC's `publish` job is the reference.
2. Add a `[[source]]` entry to [`sources.toml`](sources.toml).
3. Mention the plugin in [`bootstrap/pkg-descr`](bootstrap/pkg-descr) and
   bump `PLUGIN_VERSION` in [`bootstrap/Makefile`](bootstrap/Makefile).

## Rotating the signing key

Firewalls must trust the new key **before** anything is signed with it,
otherwise they cannot verify the update that would teach them the new
fingerprint.

There are two secret slots, `KSA_SIGNING_KEY` and `KSA_SIGNING_KEY_NEXT`.
The repository variable `KSA_SIGNING_SECRET` says which one signs (unset
means `KSA_SIGNING_KEY`). A rotation stages the new key in the slot that is
**not** in use:

1. Stage: `SECRET=<unused slot> scripts/setup-signing-key.sh`. This stores
   the new key in that slot and adds its fingerprint to `trusted/` next to
   the old one. Bump `PLUGIN_VERSION` in `bootstrap/Makefile`, PR, merge.
   Publishing still signs with the old key, and firewalls pick up an
   `os-ksa-repo` that trusts both.
2. Switch: after firewalls have updated (allow a few weeks), set
   `KSA_SIGNING_SECRET` to the new slot. The next publish signs with the
   new key.
3. Revoke: move the old fingerprint file from `trusted/` to `revoked/`,
   bump `PLUGIN_VERSION`, merge.

If the key is ever exposed, do steps 1 and 3 immediately and treat every
package signed after the exposure as suspect.

## Layout of this repo

| Path | What |
|---|---|
| `bootstrap/` | The `os-ksa-repo` package, built inside an opnsense/plugins tree like any vendor plugin |
| `sources.toml` | Which plugin repos publish here, and which tracks exist |
| `scripts/fetch_sources.py` | Rebuilds `site/` from release assets |
| `scripts/sign-and-index.sh` | FreeBSD: builds the bootstrap, signs and verifies each track |
| `scripts/make_index.py` | Writes the human-readable index page |
| `scripts/setup-signing-key.sh` | Creates or stages a signing key |
| `keys/` | Public keys, for reference |

Licence: BSD 2-Clause, KSA Technologies, LLC.
