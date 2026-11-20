"""Print `name<TAB>rev<TAB>url` for each package in a lake-manifest.json.

Usage: python3 -I scripts/manifest_revs.py <lake-manifest.json>
"""
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    manifest = json.load(f)
for pkg in manifest.get("packages", []):
    print(f"{pkg['name']}\t{pkg.get('rev', '')}\t{pkg.get('url', '')}")
