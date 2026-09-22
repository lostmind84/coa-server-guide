#!/usr/bin/env python3
"""Print the CoA issue triage table in seconds: sync the open issues incrementally, group deterministically.

Audit reports ('<Class>: "<Spell>" (Spell ID: N) ...') are grouped by class; the rest by keyword theme.
The first run fetches every open issue; later runs ask GitHub only for issues updated since the last sync
(`since=`), upsert the open ones and drop the closed ones. Cache: ~/.cache/coa-triage/issues.json.
Usage: coa-triage-table.py [--refresh] [--repo owner/name]   (--refresh discards the cache and refetches all)
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


CACHE = Path.home() / ".cache" / "coa-triage" / "issues.json"
FIELDS = "{number, title, state, assignees: [.assignees[].login]}"


def api_issues(repo, query):
    out = subprocess.check_output(
        ["gh", "api", f"repos/{repo}/issues?per_page=100&{query}", "--paginate",
         "--jq", f".[] | select(.pull_request == null) | {FIELDS}"],
        text=True)
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def row(r):
    return {"number": r["number"], "title": r["title"], "assignees": r["assignees"]}


def fetch(repo, refresh):
    """Return the open issues as [{number, title, assignees}], syncing the cache incrementally."""
    cache = None
    if CACHE.exists() and not refresh:
        try:
            cache = json.loads(CACHE.read_text())
        except json.JSONDecodeError:
            cache = None
        if not isinstance(cache, dict) or "synced_at" not in cache:
            cache = None  # pre-incremental cache (a bare list): refetch everything
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if cache is None:
        rows = api_issues(repo, "state=open")
        issues = {str(r["number"]): row(r) for r in rows}
        print(f"synced: full fetch, {len(issues)} open issues", file=sys.stderr)
    else:
        issues = cache["issues"]
        changed = api_issues(repo, f"state=all&sort=updated&since={cache['synced_at']}")
        added = removed = 0
        for r in changed:
            key = str(r["number"])
            if r["state"] == "open":
                added += 1
                issues[key] = row(r)
            elif issues.pop(key, None) is not None:
                removed += 1
        print(f"synced: +{added} new/updated, -{removed} closed since {cache['synced_at']}", file=sys.stderr)
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    CACHE.write_text(json.dumps({"synced_at": started, "issues": issues}))
    return list(issues.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="jealous-sound/azerothcore-wotlk-coa")
    parser.add_argument("--refresh", action="store_true")
    args = parser.parse_args()
    rows = fetch(args.repo, args.refresh)

    by_class = collections.defaultdict(list)
    themes = collections.defaultdict(list)
    assigned = []
    assignees_by_number = {}
    for r in rows:
        if r["assignees"]:
            assigned.append(r)
            assignees_by_number[r["number"]] = r["assignees"]
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

    def assigned_in(values):
        per = collections.Counter(
            login for n in values for login in assignees_by_number.get(n, ()))
        return ", ".join(f"{login} ({n})" for login, n in per.most_common()) or "—"

    print(f"Open issues: {len(rows)} (audit reports {sum(map(len, by_class.values()))}, "
          f"other {sum(map(len, themes.values()))}, assigned {len(assigned)}).\n")
    print("| Batch | Total | Why it matters | Proof | Assigned |")
    print("|---|---|---|---|---|")
    for cls, values in sorted(by_class.items(), key=lambda kv: -len(kv[1])):
        print(f"| audit {cls} | {len(values)} | spell audit reports, verify each spell's real value "
              f"before calling it a bug | gameplay-test | {assigned_in(values)} |")
    for key, _, why in THEMES:
        if themes.get(key):
            proof = {"client-ui": "client lab", "systems-modes": "gameplay-test + Ghost",
                     "crashes": "gameplay-test + Ghost", "talents-specs": "gameplay-test + Ghost"}.get(key, "gameplay-test")
            print(f"| {key} | {len(themes[key])} | {why} | {proof} | {assigned_in(themes[key])} |")
    for key in sorted(k for k in themes if k.startswith("class ")):
        print(f"| {key} mechanics | {len(themes[key])} | class-specific reports outside the audit "
              f"(title-based) | gameplay-test | {assigned_in(themes[key])} |")
    if themes.get("unsorted"):
        print(f"| unsorted | {len(themes['unsorted'])} | title gave no theme | to read | {assigned_in(themes['unsorted'])} |")
    print("\nAssigned overall (skip unless yours):")
    per = collections.Counter((a["assignees"][0]) for a in assigned)
    print("  " + ", ".join(f"{login}: {n}" for login, n in per.most_common()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
