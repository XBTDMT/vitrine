#!/usr/bin/env python3
"""Writes the compose specs for Vitrine's launch and README pictures (S-17) and renders them with compose.swift.

  python3 -I app/tools/launch/make-launch.py <out folder> [look ...]      (looks: teal-light teal-dark neutral)

Inputs are the app's own renders in docs/media/ (drawn by `Vitrine --snapshot` from invented sample files) and the
app icon. Each look gives: social-card (1200×675, X), social-github (1280×640, GitHub's social preview), hero (2400×1350), every-file
(2400×1350), trust (2400×1350). roadmap: S-17
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
MEDIA = os.path.join(ROOT, "docs", "media")
ICON = os.path.join(ROOT, "app", "Vitrine", "Assets.xcassets", "AppIcon.appiconset", "icon_512x512@2x.png")

LOOKS = {
    # A soft mint ground lit by the icon's teal.
    "teal-light": {"top": "#f3f8f7", "bottom": "#e6efed", "glows": [[1900, 120, 1200, "#1f9e89", 0.20], [200, 1300, 1000, "#7fd6c4", 0.18]],
                   "ink": "#14211f", "soft": "#4f5f5c", "dark": False, "keycapDark": False},
    # Deep teal, like the Battery kit's dark green glow, with the dark renders.
    "teal-dark": {"top": "#16302c", "bottom": "#070d0c", "glows": [[1700, 300, 1300, "#22b39a", 0.32], [300, 1250, 900, "#0e5b4f", 0.35]],
                  "ink": "#f2f7f6", "soft": "#a7bcb8", "dark": True, "keycapDark": True},
    # A neutral light ground, like the News Feed kit, teal only in the app itself.
    "neutral": {"top": "#eef1f7", "bottom": "#f7f2ef", "glows": [[2100, 0, 1300, "#c9d8ff", 0.45], [0, 1350, 1100, "#ffe2d1", 0.40]],
                "ink": "#1d1d1f", "soft": "#5f6368", "dark": False, "keycapDark": False},
}


def media(name, look):
    dark = look["dark"]
    path = os.path.join(MEDIA, f"{name}-{'dark' if dark else 'light'}.png")
    return path if os.path.exists(path) else os.path.join(MEDIA, f"{name}-light.png")


def panel(path, crop, rect, look, radius=30):
    return {"image": path, "crop": crop, "rect": rect, "radius": radius, "shadow": 70 if not look["dark"] else 90,
            "shadowAlpha": 0.22 if not look["dark"] else 0.55, "stroke": None if not look["dark"] else "#2a3a37"}


def scale_ground(look, w, h):
    sx, sy = w / 2400, h / 1350
    return {"top": look["top"], "bottom": look["bottom"],
            "glows": [[g[0] * sx, g[1] * sy, g[2] * max(sx, sy), g[3], g[4]] for g in look["glows"]]}


def social(look):
    return {"size": [1200, 675], "ground": scale_ground(look, 1200, 675), "items": [
        {"image": ICON, "rect": [64, 96, 150, 150]},
        {"text": "Vitrine", "rect": [72, 262, 560, 130], "size": 104, "weight": "bold", "color": look["ink"]},
        {"text": "Press Space on any file in Finder and see inside it. Free and open source.",
         "rect": [74, 396, 520, 160], "size": 33, "color": look["soft"]},
        panel(media("markdown", look), [400, 0, 1200, 1520], [640, 70, 500, 633], look, radius=22),
    ]}


def social_github(look):
    # GitHub's social preview is 2:1 (1280×640 recommended); X's card is 16:9.
    return {"size": [1280, 640], "ground": scale_ground(look, 1280, 640), "items": [
        {"image": ICON, "rect": [68, 84, 144, 144]},
        {"text": "Vitrine", "rect": [76, 244, 600, 124], "size": 100, "weight": "bold", "color": look["ink"]},
        {"text": "Press Space on any file in Finder and see inside it. Free and open source.",
         "rect": [78, 372, 560, 150], "size": 32, "color": look["soft"]},
        panel(media("markdown", look), [400, 0, 1200, 1520], [700, 64, 516, 654], look, radius=22),
    ]}


def hero(look):
    return {"size": [2400, 1350], "ground": scale_ground(look, 2400, 1350), "items": [
        {"keycap": "space", "rect": [160, 150, 330, 120], "dark": look["keycapDark"]},
        {"text": "Press Space in Finder.", "rect": [530, 138, 1500, 90], "size": 72, "weight": "bold", "color": look["ink"]},
        {"text": "See inside any file. Nothing opens, nothing runs.", "rect": [532, 224, 1500, 60], "size": 40, "color": look["soft"]},
        panel(media("markdown", look), [400, 0, 1600, 1180], [160, 360, 1060, 782], look),
        panel(media("code", look), [0, 0, 1400, 834], [1300, 360, 940, 560], look),
        panel(media("compose" if look["dark"] else "csv", look), [0, 0, 1420, 500] if not look["dark"] else [200, 180, 1600, 563],
              [1300, 960, 940, 331], look),
    ]}


def every_file(look):
    return {"size": [2400, 1350], "ground": scale_ground(look, 2400, 1350), "items": [
        {"text": "One panel, every file.", "rect": [160, 110, 2080, 90], "size": 72, "weight": "bold", "color": look["ink"]},
        {"text": "Markdown with diagrams, code in colour, tables you can sort, archives, apps and more.",
         "rect": [162, 196, 2080, 60], "size": 40, "color": look["soft"]},
        panel(media("code", look), [0, 0, 1200, 1128], [160, 330, 1000, 940], look),
        panel(media("csv", look), [0, 0, 1500, 630], [1240, 330, 1000, 420], look),
        panel(media("compose", look), [0, 180, 2000, 940], [1240, 800, 1000, 470], look),
    ]}


def trust(look):
    return {"size": [2400, 1350], "ground": scale_ground(look, 2400, 1350), "items": [
        {"text": "It reads the file before you do.", "rect": [160, 150, 2080, 90], "size": 72, "weight": "bold", "color": look["ink"]},
        {"text": "Download-and-run lines, login items, hidden text and keys are called out. Apps get a plain-words card.",
         "rect": [162, 236, 2080, 60], "size": 40, "color": look["soft"]},
        panel(media("trust-lens", look), [0, 0, 2000, 1100], [160, 400, 1100, 605], look),
        panel(media("app-card", look), [0, 540, 2000, 600], [1320, 400, 920, 276], look),
        panel(media("compose", look), [0, 775, 2000, 640], [1320, 716, 920, 294], look),
    ]}


PICTURES = {"social-card": social, "social-github": social_github, "hero": hero, "every-file": every_file, "trust": trust}


def main():
    out = sys.argv[1]
    looks = sys.argv[2:] or list(LOOKS)
    only = os.environ.get("PICTURES", "").split(",") if os.environ.get("PICTURES") else list(PICTURES)
    os.makedirs(out, exist_ok=True)
    tool = os.path.join(out, "compose")
    subprocess.run(["swiftc", "-O", "-o", tool, os.path.join(HERE, "compose.swift")], check=True)
    for name in looks:
        for pic in only:
            spec = PICTURES[pic](LOOKS[name])
            spec["items"] = [{k: v for k, v in i.items() if v is not None} for i in spec["items"]]
            path = os.path.join(out, f"{name}-{pic}.json")
            with open(path, "w") as f:
                json.dump(spec, f)
            subprocess.run([tool, path, os.path.join(out, f"{name}-{pic}.png")], check=True)


if __name__ == "__main__":
    main()
