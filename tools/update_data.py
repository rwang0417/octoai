#!/usr/bin/env python3
"""Download the OctoWoW quest database into tools/data (stdlib only, Python 3.8+).

Source: https://github.com/FrancisEgan/OctoQuestDatabase (MIT, see data/NOTICE.md)

  python update_data.py              latest version (branch main)
  python update_data.py --ref <sha>  a specific commit, branch or tag
  python update_data.py --check      only show installed vs latest version
"""
import argparse
import json
import os
import shutil
import sys
import tempfile
import urllib.request

REPO = "FrancisEgan/OctoQuestDatabase"
HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
UA = {"User-Agent": "OctoAI-update-data", "Accept": "application/vnd.github+json"}


def get(url, timeout=60):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def resolve(ref):
    info = json.loads(get("https://api.github.com/repos/%s/commits/%s" % (REPO, ref)))
    return info["sha"], info["commit"]["committer"]["date"]


def installed():
    p = os.path.join(DATA, "VERSION.txt")
    if os.path.isfile(p):
        with open(p, encoding="utf-8") as f:
            return f.read().strip()
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ref", default="main", help="commit sha, branch or tag (default: main)")
    ap.add_argument("--check", action="store_true", help="only compare installed and remote versions")
    a = ap.parse_args()

    sha, date = resolve(a.ref)
    have = installed()
    print("installed: %s" % (have or "none"))
    print("remote:    OctoQuestDatabase commit %s (%s)" % (sha, date))
    if a.check:
        return 0
    if have and sha in have:
        print("already up to date")
        return 0

    listing = json.loads(get("https://api.github.com/repos/%s/contents/source?ref=%s" % (REPO, sha)))
    files = [(x["name"], x["download_url"]) for x in listing if x["type"] == "file" and x["name"].endswith(".json")]
    extra = [("LICENSE.txt", "https://raw.githubusercontent.com/%s/%s/LICENSE" % (REPO, sha)),
             ("NOTICE.md", "https://raw.githubusercontent.com/%s/%s/NOTICE.md" % (REPO, sha))]
    if not files:
        print("no database files found in the repository, nothing changed")
        return 1

    tmp = tempfile.mkdtemp(prefix="octo_data_", dir=HERE)
    try:
        for name, url in files + extra:
            sys.stdout.write("  %-26s" % name)
            sys.stdout.flush()
            body = get(url, timeout=300)
            if name.endswith(".json"):
                json.loads(body.decode("utf-8"))  # refuse broken downloads
            with open(os.path.join(tmp, name), "wb") as f:
                f.write(body)
            print("%8.0f KB" % (len(body) / 1024.0))
        with open(os.path.join(tmp, "VERSION.txt"), "w", encoding="utf-8") as f:
            f.write("OctoQuestDatabase commit %s (%s)\n" % (sha, date))
        if os.path.isdir(DATA):
            old = DATA + ".old"
            if os.path.isdir(old):
                shutil.rmtree(old)
            os.rename(DATA, old)
            os.rename(tmp, DATA)
            shutil.rmtree(old, ignore_errors=True)
        else:
            os.rename(tmp, DATA)
    except Exception:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    print("done: %d files in %s" % (len(files), DATA))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # network errors etc.
        print("failed: %s (the existing data folder was left unchanged)" % e)
        sys.exit(1)
