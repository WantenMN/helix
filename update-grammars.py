#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 nix-prefetch-git
"""Regenerate grammars.lock.json for grammars.nix.

Reads languages.toml git grammars, prefetches (url, rev) pairs that are
missing or stale in the lock, and writes back {url, rev, hash} per grammar
name. Repos shared by several grammars (e.g. typescript/tsx) are prefetched
once and the hash is reused.

Usage:
    nix run nixpkgs#python3 -- ./update-grammars.py [--check] [-j N]

--check exits 1 (without writing) if any entry is missing or stale.
"""
import concurrent.futures as fut
import json
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).parent
TOML = ROOT / "languages.toml"
LOCK = ROOT / "grammars.lock.json"
WORKERS = 8
RETRIES = 3


def load_toml():
    with open(TOML, "rb") as f:
        data = tomllib.load(f)
    out = []
    for g in data.get("grammar", []):
        src = g.get("source", {})
        if "git" in src and "rev" in src:
            out.append((g["name"], src["git"], src["rev"]))
    return out


def load_lock():
    if LOCK.exists():
        with open(LOCK) as f:
            return json.load(f)
    return {"version": 1, "grammars": {}}


def prefetch(url, rev):
    cmd = ["nix", "run", "nixpkgs#nix-prefetch-git", "--",
           "--url", url, "--rev", rev]
    for attempt in range(1, RETRIES + 1):
        try:
            p = subprocess.run(
                cmd, capture_output=True, text=True, timeout=600,
            )
        except subprocess.TimeoutExpired:
            print(f"  timeout {url}@{rev[:12]} (attempt {attempt})", flush=True)
            continue
        if p.returncode == 0:
            return json.loads(p.stdout)["hash"]
        print(f"  prefetch failed {url}@{rev[:12]} (attempt {attempt}): "
              f"{p.stderr.strip().splitlines()[-1:]})", flush=True)
    raise RuntimeError(f"prefetch failed: {url}@{rev}")


def main():
    check = "--check" in sys.argv
    jobs = WORKERS
    for i, a in enumerate(sys.argv):
        if a == "-j" and i + 1 < len(sys.argv):
            jobs = int(sys.argv[i + 1])

    grammars = load_toml()
    lock = load_lock()
    entries = lock.setdefault("grammars", {})

    # Dedupe shared repos: one prefetch per (url, rev).
    by_repo = {}
    for name, url, rev in grammars:
        by_repo.setdefault((url, rev), []).append(name)

    todo = {}
    for (url, rev), names in by_repo.items():
        if all(n in entries and entries[n].get("url") == url
               and entries[n].get("rev") == rev
               and entries[n].get("hash") for n in names):
            continue
        todo[(url, rev)] = names

    if not todo:
        print(f"lock up to date: {len(grammars)} grammars, "
              f"{len(by_repo)} distinct repos")
        return 0

    print(f"need prefetch: {len(todo)} repos "
          f"({sum(len(v) for v in todo.values())} grammars)")
    if check:
        stale = sorted(n for names in todo.values() for n in names)
        print("missing/stale:", ", ".join(stale))
        return 1

    hashes = {}
    with fut.ThreadPoolExecutor(max_workers=jobs) as ex:
        future_map = {ex.submit(prefetch, u, r): (u, r) for (u, r) in todo}
        done = 0
        for f in fut.as_completed(future_map):
            url, rev = future_map[f]
            hashes[(url, rev)] = f.result()
            done += 1
            print(f"[{done}/{len(todo)}] {url}@{rev[:12]}", flush=True)

    for (url, rev), h in hashes.items():
        for name in by_repo[(url, rev)]:
            entries[name] = {"url": url, "rev": rev, "hash": h}

    # Drop grammars removed from languages.toml.
    for name in list(entries):
        if name not in {n for n, _, _ in grammars}:
            del entries[name]

    with open(LOCK, "w") as f:
        json.dump({"version": 1, "grammars": entries}, f, indent=2,
                  sort_keys=True)
        f.write("\n")
    print(f"wrote {LOCK} ({len(entries)} grammars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
