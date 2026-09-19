#!/usr/bin/env python3
"""Print the CoA issue triage table in seconds: fetch every open issue (cached), group deterministically.

Audit reports ('<Class>: "<Spell>" (Spell ID: N) ...') are grouped by class; the rest by keyword theme.
Usage: coa-triage-table.py [--refresh] [--repo owner/name]   (cache: ~/.cache/coa-triage/issues.json, 1 h)
"""
import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

AUDIT = re.compile(r'^\s*([A-Za-z\' ]+?)\s*:\s*"(.+?)"\s*\((?:Spell ID:\s*\d+|\d+ ranks?:)')
CLASS_PREFIX = re.compile(r'^\s*(Barbarian|Witch ?Doctor|Felsworn|Demon ?Hunter|Witch ?Hunter|Stormbringer|Knight ?of ?Xoroth|'
                          r'Guardian|Templar|Bloodmage|Son ?of ?Arugal|Ranger|Chronomancer|Necromancer|Pyromancer|Cultist|'
                          r'Starcaller|Sun ?Cleric|Tinker|Venomancer|Reaper|Primalist|Runemaster)\b', re.I)
CLASS_ALIASES = {"WitchDoctor": "Witch Doctor", "Witchhunter": "Witch Hunter", "Suncleric": "Sun Cleric", "Knightofxoroth": "Knight of Xoroth", "Witchdoctor": "Witch Doctor", "Demonhunter": "Felsworn", "SonOfArugal": "Bloodmage", "KnightOfXoroth": "Knight of Xoroth",
                 "SunCleric": "Sun Cleric", "WitchHunter": "Witch Hunter", "DemonHunter": "Felsworn"}
THEMES = [
    ("crashes", r"crash|freeze|segfault|assert|disconnect(?!ed talents)|kick", "server stability first"),
    ("resources", r"\brage\b|\bmana\b|energy|runic|focus|essence|heat|static|soul|combo|cost|resource|regen",
     "power and aura costs and gains"),
    ("summons-pets", r"\bpet\b|summon|minion|companion|imp\b|hound|totem|guardian(?! class)|ghoul", "pets and summons"),
    ("talents-specs", r"talent|spec\b|specializ|tree\b|passive", "talent trees and specialization state"),
    ("items-bank-vanity", r"item|bank|vault|vanity|mount|appearance|outfit|wardrobe|transmog|gear|weapon|armor",
     "items, bank and cosmetics"),
    ("quests-world", r"quest|npc|creature|spawn|zone|loot|drop|boss|instance|dungeon|raid|flight|portal|vendor|trainer",
     "quests, world and creatures"),
    ("systems-modes", r"rdf|lfg|dungeon finder|manastorm|war mode|warmode|\bgm\b|rest|xp|experience|scaling|level|"
                      r"challenge|pvp|arena|battleground|group|guild|mail|auction", "game systems and modes"),
    ("client-ui", r"\bui\b|tooltip|icon|model|display|visual|nameplate|frame|addon|lua|interface|chooser|popup",
     "displayed in the client, not testable by a protocol bot"),
]


def fetch(repo, refresh):
    cache = Path.home() / ".cache" / "coa-triage" / "issues.json"
    if cache.exists() and not refresh and time.time() - cache.stat().st_mtime < 3600:
        return json.loads(cache.read_text())
    out = subprocess.check_output(
        ["gh", "api", f"repos/{repo}/issues?state=open&per_page=100", "--paginate",
         "--jq", ".[] | select(.pull_request == null) | {number, title, assignees: [.assignees[].login]}"],
        text=True)
    rows = [json.loads(line) for line in out.splitlines() if line.strip()]
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps(rows))
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="jealous-sound/azerothcore-wotlk-coa")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    rows = fetch(args.repo, args.refresh)

    by_class = collections.defaultdict(list)
    themes = collections.defaultdict(list)
    assigned = []
    for r in rows:
        if r["assignees"]:
            assigned.append(r)
        m = AUDIT.match(r["title"])
        if m:
            by_class[CLASS_ALIASES.get(m.group(1).strip(), m.group(1).strip())].append(r["number"])
            continue
        title = r["title"].lower()
        cm = CLASS_PREFIX.match(r["title"])
        if cm and not re.search(THEMES[0][1], title):
            themes["class " + CLASS_ALIASES.get(cm.group(1).title().replace(" ", ""), cm.group(1).title())].append(r["number"])
            continue
        for key, pattern, _ in THEMES:
            if re.search(pattern, title):
                themes[key].append(r["number"])
                break
        else:
            themes["unsorted"].append(r["number"])

    def nums(values, limit=14):
        values = sorted(values)
        text = ", ".join(map(str, values[:limit]))
        return text + (f" … (+{len(values) - limit})" if len(values) > limit else "")

    print(f"Open issues: {len(rows)} (audit reports {sum(map(len, by_class.values()))}, "
          f"other {sum(map(len, themes.values()))}, assigned {len(assigned)}).\n")
    print("| Batch | Issues | Why it matters | Proof |")
    print("|---|---|---|---|")
    for cls, values in sorted(by_class.items(), key=lambda kv: -len(kv[1])):
        print(f"| audit {cls} ({len(values)}) | {nums(values)} | spell audit reports, verify each spell's real value "
              f"before calling it a bug | gameplay-test |")
    for key, _, why in THEMES:
        if themes.get(key):
            proof = {"client-ui": "client lab", "systems-modes": "gameplay-test + Ghost",
                     "crashes": "gameplay-test + Ghost", "talents-specs": "gameplay-test + Ghost"}.get(key, "gameplay-test")
            print(f"| {key} ({len(themes[key])}) | {nums(themes[key])} | {why} | {proof} |")
    for key in sorted(k for k in themes if k.startswith("class ")):
        print(f"| {key} mechanics ({len(themes[key])}) | {nums(themes[key])} | class-specific reports outside the audit "
              f"(title-based) | gameplay-test |")
    if themes.get("unsorted"):
        print(f"| unsorted ({len(themes['unsorted'])}) | {nums(themes['unsorted'])} | title gave no theme | to read |")
    print("\nAssigned (skip unless yours):")
    per = collections.Counter((a["assignees"][0]) for a in assigned)
    print("  " + ", ".join(f"{login}: {n}" for login, n in per.most_common()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
