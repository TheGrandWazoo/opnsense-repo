#!/usr/bin/env python3
"""Collect plugin packages from GitHub releases into the site tree.

Stateless: the site is rebuilt from scratch on every run, so gh-pages is
pure output. Layout: site/<ABI>/<series>/<track>/All/*.pkg, the same shape
as OPNsense's own repository (<ABI>/<series>/latest).

Writes site/state.json (what was selected) and, when running in GitHub
Actions, `changed=true|false` to $GITHUB_OUTPUT by comparing with the state
of the currently published site.

Usage: fetch_sources.py --site site [--published-state path] [--force]
Standard library only. Uses $GITHUB_TOKEN when set (rate limits).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tomllib
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = "https://api.github.com"
TAG_RC = re.compile(r"^v(\d+)\.\d+\.\d+-rc\.\d+$")
TAG_FINAL = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
PKG_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.+-]*\.pkg$")


def request(url: str, accept: str = "application/vnd.github+json") -> bytes:
    req = urllib.request.Request(url, headers={"Accept": accept, "User-Agent": "opnsense-repo-publisher"})
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def releases(repo: str) -> list[dict]:
    out: list[dict] = []
    page = 1
    while True:
        batch = json.loads(request(f"{API}/repos/{repo}/releases?per_page=100&page={page}"))
        out += [r for r in batch if not r.get("draft")]
        if len(batch) < 100:
            return out
        page += 1


def semver(tag: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.findall(r"\d+", tag))


def pick(rels: list[dict], tracks: list[str]) -> dict[str, dict]:
    """Return {track: release} for each track that has a matching release."""
    chosen: dict[str, dict] = {}
    for rel in rels:
        tag = rel["tag_name"]
        targets: list[str] = []
        if tag == "devel":
            targets = ["devel"]
        elif tag == "deps":
            continue  # handled separately: goes to every track
        elif m := TAG_RC.match(tag):
            targets = [f"v{m.group(1)}/testing"]
        elif m := TAG_FINAL.match(tag):
            targets = [f"v{m.group(1)}/stable", f"v{m.group(1)}/testing"]
        for track in targets:
            if track not in tracks:
                print(f"note: {tag} maps to undeclared track {track}; add it to sources.toml", file=sys.stderr)
                continue
            best = chosen.get(track)
            if best is None or newer(rel, best):
                chosen[track] = rel
    return chosen


def newer(a: dict, b: dict) -> bool:
    if a["tag_name"] == b["tag_name"] == "devel":
        return a["published_at"] > b["published_at"]
    # A final release beats a release candidate of the same version.
    return (semver(a["tag_name"].split("-")[0]), "-rc" not in a["tag_name"]) > \
           (semver(b["tag_name"].split("-")[0]), "-rc" not in b["tag_name"])


def manifest(rel: dict) -> list[dict]:
    assets = {a["name"]: a for a in rel.get("assets", [])}
    if "manifest.json" not in assets:
        print(f"warning: {rel['tag_name']} has no manifest.json; skipped", file=sys.stderr)
        return []
    data = json.loads(request(assets["manifest.json"]["browser_download_url"], "application/octet-stream"))
    entries = data if isinstance(data, list) else [data]
    out = []
    for e in entries:
        for name in e.get("packages", []):
            if not PKG_NAME.match(name) or name not in assets:
                print(f"warning: {rel['tag_name']}: bad or missing asset {name!r}; skipped", file=sys.stderr)
                continue
            out.append({"series": e["series"], "abi": e["abi"], "name": name, "asset": assets[name]})
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--site", type=Path, required=True)
    ap.add_argument("--published-state", type=Path, help="state.json of the currently published site")
    ap.add_argument("--force", action="store_true", help="report changed=true regardless")
    args = ap.parse_args()

    conf = tomllib.loads((ROOT / "sources.toml").read_text())
    tracks: list[str] = conf["tracks"]
    site: Path = args.site
    if site.exists():
        shutil.rmtree(site)
    site.mkdir(parents=True)

    selected: list[dict] = []
    abis: set[tuple[str, str]] = set()
    for source in conf.get("source", []):
        rels = releases(source["repo"])
        plan = {t: [r] for t, r in pick(rels, tracks).items()}
        deps = [r for r in rels if r["tag_name"] == "deps"]
        for track in tracks:
            for rel in plan.get(track, []) + deps:
                for item in manifest(rel):
                    abis.add((item["abi"], item["series"]))
                    dest = site / item["abi"] / item["series"] / track / "All" / item["name"]
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    dest.write_bytes(request(item["asset"]["url"], "application/octet-stream"))
                    selected.append({"repo": source["repo"], "tag": rel["tag_name"], "track": track,
                                     "abi": item["abi"], "series": item["series"], "package": item["name"],
                                     "asset_id": item["asset"]["id"], "updated_at": item["asset"]["updated_at"]})
                    print(f"{track:12} {item['abi']}/{item['series']}  {item['name']}  ({rel['tag_name']})")

    # Every declared track exists for every ABI/series seen, even if empty.
    for abi, series in abis or {("FreeBSD:15:amd64", "26.7")}:
        for track in tracks:
            (site / abi / series / track / "All").mkdir(parents=True, exist_ok=True)

    bootstrap = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "bootstrap").rglob("*") if p.is_file())
    digest = hashlib.sha256()
    for f in bootstrap:
        digest.update(f.encode() + b"\0" + (ROOT / f).read_bytes())
    state = {"selected": sorted(selected, key=lambda s: (s["track"], s["package"])),
             "bootstrap_sha256": digest.hexdigest(), "tracks": tracks}
    (site / "state.json").write_text(json.dumps(state, indent=2) + "\n")

    def comparable(s: dict) -> dict:
        return {"selected": [{k: v for k, v in x.items()} for x in s.get("selected", [])],
                "bootstrap_sha256": s.get("bootstrap_sha256"), "tracks": s.get("tracks")}

    changed = True
    if args.published_state and args.published_state.exists() and not args.force:
        changed = comparable(json.loads(args.published_state.read_text())) != comparable(state)
    print(f"changed={str(changed).lower()}")
    if out := os.environ.get("GITHUB_OUTPUT"):
        with open(out, "a") as fh:
            fh.write(f"changed={str(changed).lower()}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
