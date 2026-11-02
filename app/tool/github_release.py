#!/usr/bin/env python3
"""Puts files on the GitHub release of a version of this repository, making the release when it is not there yet.

usage: github_release.py <tag> <notes file> <file>...
       github_release.py --check       is there a token that can write to the releases? (makes and deletes a draft)

The token is read from $SAPOCHE_GITHUB_TOKEN_FILE (default ~/.config/sapoche/github-token): a fine-grained token with
"Contents: read and write" on this one repository, in a file only its owner can read. It is never printed. Without the
token nothing is done and the exit status says so (3), so that a release does not fail for want of it.
The CI job of the iOS build puts its own files on the same release, whichever of the two comes first.
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"


def repository() -> str:
    url = subprocess.check_output(["git", "remote", "get-url", "origin"], text=True).strip()
    match = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    if not match:
        sys.exit(f"cannot tell the repository from {url}")
    return match.group(1)


def call(method: str, url: str, token: str, body=None, raw: bytes | None = None, content_type: str | None = None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "sapoche-release",
        **({"Content-Type": content_type or "application/json"} if data is not None else {}),
    })
    try:
        with urllib.request.urlopen(request, timeout=600) as reply:
            text = reply.read().decode()
            return json.loads(text) if text else None
    except urllib.error.HTTPError as error:
        if error.code == 404 and method == "GET":
            return None
        sys.exit(f"{method} {url.split('?')[0]} failed: {error.code} {error.read().decode()[:300]}")


def read_token(what: str) -> str:
    token_file = os.path.expanduser(os.environ.get("SAPOCHE_GITHUB_TOKEN_FILE", "~/.config/sapoche/github-token"))
    if not os.path.exists(token_file):
        print(f"no GitHub token at {token_file}: {what}", file=sys.stderr)
        sys.exit(3)
    return open(token_file).read().strip()


def check() -> None:
    """Finds out before a release is built whether it can be put on GitHub: a draft is the one thing that tests writing without leaving a tag."""
    token = read_token("a release could not be put on GitHub")
    repo = repository()
    draft = call("POST", f"{API}/repos/{repo}/releases", token,
                 {"tag_name": "token-check", "name": "token check", "body": "", "draft": True})
    call("DELETE", f"{API}/repos/{repo}/releases/{draft['id']}", token)
    print(f"the token can write the releases of {repo}")


def main() -> None:
    if sys.argv[1:] == ["--check"]:
        return check()
    tag, notes_file, *files = sys.argv[1:]
    token = read_token(f"the files are NOT put on the release of {tag}")
    repo = repository()
    notes = open(notes_file, encoding="utf-8").read().strip()
    version = tag.lstrip("v")

    release = call("GET", f"{API}/repos/{repo}/releases/tags/{tag}", token)
    if release is None:
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        try:
            release = call("POST", f"{API}/repos/{repo}/releases", token,
                           {"tag_name": tag, "target_commitish": commit, "name": f"Sapoche {version}", "body": notes})
        except SystemExit:
            # The CI job made it a moment ago
            release = call("GET", f"{API}/repos/{repo}/releases/tags/{tag}", token)
            if release is None:
                raise
    upload = release["upload_url"].split("{")[0]
    existing = {asset["name"]: asset["id"] for asset in release.get("assets", [])}
    for path in files:
        name = os.path.basename(path)
        if name in existing:
            call("DELETE", f"{API}/repos/{repo}/releases/assets/{existing[name]}", token)
        kind = "application/vnd.android.package-archive" if name.endswith(".apk") else "application/octet-stream"
        asset = call("POST", f"{upload}?name={urllib.parse.quote(name)}", token, raw=open(path, "rb").read(), content_type=kind)
        print(f"on the release of {tag}: {asset['browser_download_url']}")


main()
