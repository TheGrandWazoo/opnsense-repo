#!/usr/bin/env python3
"""Write a plain index.html for the published site (human-readable view)."""

from __future__ import annotations

import html
import json
import sys
from pathlib import Path

BASE = "https://thegrandwazoo.github.io/opnsense-repo"


def main(site: Path) -> int:
    state = json.loads((site / "state.json").read_text())
    rows = []
    for track_dir in sorted(p.parent for p in site.rglob("All")):
        rel = track_dir.relative_to(site).as_posix()
        pkgs = sorted(p.name for p in (track_dir / "All").glob("*.pkg"))
        items = "".join(f"<li><code>{html.escape(p)}</code></li>" for p in pkgs) or "<li><em>empty</em></li>"
        rows.append(f"<h3><code>{html.escape(rel)}</code></h3><ul>{items}</ul>")
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>KSA Technologies OPNsense package repository</title>
<style>body{{font-family:system-ui,sans-serif;max-width:52rem;margin:2rem auto;padding:0 1rem;line-height:1.5}}
code,pre{{background:#f3f3f3;padding:.1rem .3rem;border-radius:3px}}pre{{padding:.8rem;overflow-x:auto}}</style>
</head><body>
<h1>KSA Technologies OPNsense package repository</h1>
<p>Signed FreeBSD package repository for KSA Technologies OPNsense plugins.
Source and documentation: <a href="https://github.com/TheGrandWazoo/opnsense-repo">TheGrandWazoo/opnsense-repo</a>.</p>
<h2>Install on OPNsense</h2>
<pre>pkg add {BASE}/os-ksa-repo.pkg</pre>
<p>Then refresh <b>System &gt; Firmware &gt; Plugins</b>.</p>
<h2>Tracks</h2>
{''.join(rows)}
<p><small>{len(state.get('selected', []))} plugin package(s) from {len({s['repo'] for s in state.get('selected', [])})} source(s).</small></p>
</body></html>
"""
    (site / "index.html").write_text(page)
    (site / ".nojekyll").write_text("")
    return 0


if __name__ == "__main__":
    sys.exit(main(Path(sys.argv[1] if len(sys.argv) > 1 else "site")))
