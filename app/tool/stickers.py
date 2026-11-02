#!/usr/bin/env python3
"""Builds the sticker packs the apps fetch as static files (served from server/web-dist/stickers).

    python3 tool/stickers.py [--out build/stickers] [--cache build/stickers-cache] [--count 96]

The artwork is not in this repository. It is downloaded from its authors (Noto Animated Emoji by Google, CC BY 4.0;
Fluent Emoji 3D by Microsoft, MIT), shrunk to WebP of 192 px and written as

    stickers/index.json            the packs: id, names, number of stickers, bytes, credit
    stickers/<pack>/pack.json      the stickers of a pack: id, emoji, keywords, group
    stickers/<pack>/<id>.webp      one picture each (animated for Noto)

A new pack is a new folder and a line in `index.json`: no release of the app is needed. Needs Python 3 with Pillow built
with animated WebP. Downloads are kept in --cache, so a second run is quick. The Fluent files are taken from a fixed
commit so that a pack does not change under the people who have it.
"""
import argparse
import concurrent.futures
import io
import json
import re
import sys
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

from PIL import Image, features

SIZE = 192
# An animated sticker weighs far more than a still one, so they are drawn smaller, with fewer frames, and there are fewer
ANIMATED_SIZE = 160
ANIMATED_COUNT = 64
MAX_FRAMES = 18
NOTO_API = "https://googlefonts.github.io/noto-emoji-animation/data/api.json"
NOTO_FILE = "https://fonts.gstatic.com/s/e/notoemoji/latest/{cp}/512.webp"
FLUENT_COMMIT = "1ffb34c752ecf5d402f04cfb4b392c77f57c54bc"
FLUENT_RAW = f"https://raw.githubusercontent.com/microsoft/fluentui-emoji/{FLUENT_COMMIT}/"
FLUENT_TREE = f"https://api.github.com/repos/microsoft/fluentui-emoji/git/trees/{FLUENT_COMMIT}?recursive=1"
# An animated sticker that is bigger than this loses frames until it is not
MAX_ANIMATED_BYTES = 60_000

GROUPS = {
    "Smileys and emotions": "faces",
    "People and body": "people",
    "Animals and nature": "animals",
    "Food and drink": "food",
    "Activities": "fun",
    "Objects": "objects",
}

PACKS = {
    "noto": {
        "name": {"en": "Animated emoji", "vi": "Emoji động"},
        "credit": {"name": "Noto Animated Emoji", "by": "Google", "license": "CC BY 4.0", "url": "https://googlefonts.github.io/noto-emoji-animation/"},
    },
    "fluent": {
        "name": {"en": "3D emoji", "vi": "Emoji 3D"},
        "credit": {"name": "Fluent Emoji", "by": "Microsoft", "license": "MIT", "url": "https://github.com/microsoft/fluentui-emoji"},
    },
}


def fetch(url, cache, binary=True):
    """The body of [url], kept under [cache] so that a second run does not download it again."""
    target = cache / re.sub(r"[^A-Za-z0-9._-]+", "_", url)[-180:]
    if target.exists():
        data = target.read_bytes()
    else:
        request = urllib.request.Request(url, headers={"User-Agent": "sapoche-stickers"})
        with urllib.request.urlopen(request, timeout=60) as reply:
            data = reply.read()
        target.write_bytes(data)
    return data if binary else data.decode("utf-8")


def glyph(codepoint):
    return "".join(chr(int(part, 16)) for part in codepoint.split("_"))


def strip_variation(text):
    return text.replace("️", "")


def noto_choice(cache, count):
    """The most popular single emoji of the animated set, as [(codepoint, groups, keywords)]."""
    icons = json.loads(fetch(NOTO_API, cache, binary=False))["icons"]
    chosen = []
    for icon in sorted(icons, key=lambda i: -i["popularity"]):
        codepoint = icon["codepoint"]
        group = next((GROUPS[c] for c in icon["categories"] if c in GROUPS), None)
        if "_" in codepoint or group is None:
            continue
        words = sorted({w for tag in icon["tags"] for w in tag.strip(":").split("-") if len(w) > 2})
        chosen.append((codepoint, group, words))
        if len(chosen) == count:
            break
    return chosen


def shrink_animated(data):
    image = Image.open(io.BytesIO(data))
    count = getattr(image, "n_frames", 1)
    frames, durations = [], []
    for index in range(count):
        image.seek(index)
        frames.append(image.convert("RGBA").resize((ANIMATED_SIZE, ANIMATED_SIZE), Image.LANCZOS))
        durations.append(image.info.get("duration") or 40)
    # Every n-th frame, each held n times as long: the same motion at a lower frame rate
    step = max(1, -(-count // MAX_FRAMES))
    while True:
        kept = frames[::step]
        held = [sum(durations[i:i + step]) for i in range(0, count, step)]
        out = io.BytesIO()
        kept[0].save(out, "WEBP", save_all=True, append_images=kept[1:], duration=held, loop=0, quality=40, method=6)
        if out.tell() <= MAX_ANIMATED_BYTES or len(kept) <= 8:
            return out.getvalue()
        step += 1


def shrink_still(data):
    image = Image.open(io.BytesIO(data)).convert("RGBA")
    image.thumbnail((SIZE, SIZE), Image.LANCZOS)
    out = io.BytesIO()
    image.save(out, "WEBP", quality=82, method=6)
    return out.getvalue()


def fluent_index(cache):
    """glyph -> path of its 3D picture in the Fluent repository, for the emoji that have one."""
    tree = json.loads(fetch(FLUENT_TREE, cache, binary=False))["tree"]
    folders = {}
    for item in tree:
        match = re.fullmatch(r"assets/([^/]+)/(metadata\.json|3D/[^/]+\.png)", item["path"])
        if match:
            folders.setdefault(match.group(1), {"pictures": []})
            if match.group(2) == "metadata.json":
                folders[match.group(1)]["meta"] = item["path"]
            else:
                folders[match.group(1)]["pictures"].append(item["path"])

    def meta(folder):
        info = folders[folder]
        if not info["pictures"] or "meta" not in info:
            return None
        url = FLUENT_RAW + urllib.parse.quote(info["meta"])
        return strip_variation(json.loads(fetch(url, cache, binary=False)).get("glyph", "")), folder

    found = {}
    with concurrent.futures.ThreadPoolExecutor(16) as pool:
        for result in pool.map(meta, list(folders)):
            if result and result[0]:
                pictures = folders[result[1]]["pictures"]
                default = [p for p in pictures if p.endswith("_3d_default.png")]
                found[result[0]] = (default or pictures)[0] if (default or len(pictures) == 1) else None
    return {key: value for key, value in found.items() if value}


def write_pack(out, pack_id, stickers, files):
    folder = out / pack_id
    folder.mkdir(parents=True, exist_ok=True)
    for sticker_id, data in files.items():
        (folder / f"{sticker_id}.webp").write_bytes(data)
    (folder / "pack.json").write_text(json.dumps({"id": pack_id, "stickers": stickers}, ensure_ascii=False, separators=(",", ":")))
    return sum(len(d) for d in files.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", default="build/stickers")
    parser.add_argument("--cache", default="build/stickers-cache")
    parser.add_argument("--count", type=int, default=96)
    args = parser.parse_args()
    if not features.check("webp_anim"):
        sys.exit("Pillow was built without animated WebP")
    out, cache = Path(args.out), Path(args.cache)
    cache.mkdir(parents=True, exist_ok=True)
    out.mkdir(parents=True, exist_ok=True)

    choice = noto_choice(cache, args.count)
    packs = []

    # Animated: the most popular of them
    animated_choice = choice[:ANIMATED_COUNT]

    def animated(item):
        return item[0], shrink_animated(fetch(NOTO_FILE.format(cp=item[0]), cache))

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        files = dict(pool.map(animated, animated_choice))
    stickers = [{"id": cp, "e": glyph(cp), "k": words, "g": group} for cp, group, words in animated_choice]
    packs.append(("noto", stickers, write_pack(out, "noto", stickers, files)))

    # The same emoji as 3D pictures, where Fluent has them
    paths = fluent_index(cache)

    def still(item):
        path = paths.get(strip_variation(glyph(item[0])))
        return (item, shrink_still(fetch(FLUENT_RAW + urllib.parse.quote(path), cache))) if path else None

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        made = [m for m in pool.map(still, choice) if m]
    stickers = [{"id": cp, "e": glyph(cp), "k": words, "g": group} for (cp, group, words), _ in made]
    files = {item[0]: data for item, data in made}
    packs.append(("fluent", stickers, write_pack(out, "fluent", stickers, files)))

    index = {
        "v": 1,
        "packs": [
            {"id": pid, "name": PACKS[pid]["name"], "icon": stickers[0]["id"], "count": len(stickers), "bytes": size, "v": 1, "credit": PACKS[pid]["credit"]}
            for pid, stickers, size in packs
        ],
    }
    (out / "index.json").write_text(json.dumps(index, ensure_ascii=False, separators=(",", ":")))
    for pid, stickers, size in packs:
        print(f"{pid}: {len(stickers)} stickers, {size / 1024:.0f} KB")


if __name__ == "__main__":
    main()
