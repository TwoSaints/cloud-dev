#!/usr/bin/env python3
"""Generate iTerm2 Dynamic Profiles for the Terra colour scheme.

Usage:
    python3 generate-iterm-profiles.py > ~/Library/Application\ Support/iTerm2/DynamicProfiles/Terra.json
"""

import json

def hex_to_iterm(h):
    h = h.lstrip("#")
    return {
        "Red Component": int(h[0:2], 16) / 255.0,
        "Green Component": int(h[2:4], 16) / 255.0,
        "Blue Component": int(h[4:6], 16) / 255.0,
        "Color Space": "sRGB",
    }

# Shared ANSI palette
ANSI = {
    0: "#2a2118",   # black
    1: "#b65a3e",   # red (terracotta)
    2: "#7a8c5e",   # green (sage)
    3: "#c8a96e",   # yellow (gold)
    4: "#6b8c8e",   # blue (muted teal)
    5: "#917068",   # magenta (dusty mauve)
    6: "#8a9e7a",   # cyan (eucalyptus)
    7: "#d4c4a8",   # white (parchment)
    8: "#4a3c2e",   # bright black
    9: "#d4735e",   # bright red
    10: "#9aac7e",  # bright green
    11: "#e0c88e",  # bright yellow
    12: "#8aacae",  # bright blue
    13: "#b08e86",  # bright magenta
    14: "#aabe9a",  # bright cyan
    15: "#efe0c8",  # bright white
}

FOREGROUND = "#d4c4a8"

# (name, guid, background, cursor, selection)
VARIANTS = [
    ("Terra",          "terra-base-0000", "#1c1612", "#c8a96e", "#3d3226"),
    ("Terra-Velais",   "terra-velais-001", "#121622", "#6b9bc0", "#1e2a38"),
    ("Terra-Personal", "terra-pers-0002", "#1e1a10", "#7a8c5e", "#3d3226"),
    ("Terra-M2",       "terra-m2-00003", "#0e0e0a", "#c8a96e", "#2a2518"),
    ("Terra-System",   "terra-sys-0004", "#1c1216", "#917068", "#2e2228"),
]

profiles = []
for name, guid, bg, cursor, sel in VARIANTS:
    p = {
        "Name": name,
        "Guid": guid,
        "Custom Window Title": name,
        "Foreground Color": hex_to_iterm(FOREGROUND),
        "Background Color": hex_to_iterm(bg),
        "Cursor Color": hex_to_iterm(cursor),
        "Cursor Text Color": hex_to_iterm(bg),
        "Selection Color": hex_to_iterm(sel),
        "Selected Text Color": hex_to_iterm(FOREGROUND),
        "Bold Color": hex_to_iterm("#efe0c8"),
        "Cursor Guide Color": {**hex_to_iterm("#3d3226"), "Alpha Component": 0.25},
        "Badge Color": {**hex_to_iterm(cursor), "Alpha Component": 0.5},
        "Minimum Contrast": 0,
        "Use Cursor Guide": False,
        "ASCII Anti Aliased": True,
        "Non-ASCII Anti Aliased": True,
        "Use Non-ASCII Font": False,
        "Transparency": 0.04,
        "Blend": 0.3,
    }
    for i, color in ANSI.items():
        p[f"Ansi {i} Color"] = hex_to_iterm(color)
    profiles.append(p)

print(json.dumps({"Profiles": profiles}, indent=2))
