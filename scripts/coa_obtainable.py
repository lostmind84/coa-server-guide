#!/usr/bin/env python3
"""Answer "could a player acquire this spell?" for CoA custom-class spells.

The CoA server is a reconstruction, so the shipped database is not authority: a missing acquisition row is what
lost data looks like. This tool therefore never reports a bare absence. Every source is calibrated first against
the spells the checkout already knows are obtainable for the same class, and the calibration is printed with the
verdict, so a reader can tell a meaningful silence from an empty source.

Usage:
  coa-obtainable 300503 705249 ...          # spell IDs
  coa-obtainable --class 19                 # calibration report for one class
  coa-obtainable --issues issues.json       # [{"issue":N,"spellId":S}, ...]
Options:
  --repo PATH   CoA checkout (default: ~/Projects/azerothcore-wotlk-coa)
  --dbc PATH    server DBC directory (default: /srv/coa/server-data/dbc)
  --json        machine-readable output
Environment: COA_REFERENCE_DIR holds snapshots/ and MANIFEST.json (default ~/CoaServer/reference).
"""
import argparse, csv, json, os, re, struct, sys
from pathlib import Path

REF = Path(os.environ.get('COA_REFERENCE_DIR', '~/CoaServer/reference')).expanduser()
SNAP = REF / 'snapshots'
HDR = struct.Struct('<4sIIII')


class Dbc:
    def __init__(self, path):
        d = Path(path).read_bytes()
        magic, self.rows, self.fields, self.rsize, self.ssize = HDR.unpack_from(d)
        if magic != b'WDBC':
            raise ValueError(f'{path}: not a WDBC file')
        self.d, self.sstart = d, HDR.size + self.rows * self.rsize
        self.fi = struct.Struct(f'<{self.fields}i')

    def ints(self, i):
        return self.fi.unpack_from(self.d, HDR.size + i * self.rsize)

    def s(self, off):
        if off <= 0 or off >= self.ssize:
            return ''
        start = self.sstart + off
        end = self.d.find(b'\0', start)
        return self.d[start:end].decode('utf-8', 'replace')


# CharacterAdvancement.dbc DWORD layout, mirroring AscensionCoATalentData.cpp.
ADV_SPELLS, ADV_LEVEL, ADV_CLASS_TYPE = 5, 26, 32


class Local:
    """What the installed checkout says."""

    def __init__(self, dbc, repo):
        self.dbc, self.repo = Path(dbc), Path(repo)
        self.spell = Dbc(self.dbc / 'Spell.dbc')
        self.spell_idx = {}
        for i in range(self.spell.rows):
            self.spell_idx.setdefault(self.spell.ints(i)[0], i)
        self.class_token = {}
        chr_classes = Dbc(self.dbc / 'ChrClasses.dbc')
        for i in range(chr_classes.rows):
            v = chr_classes.ints(i)
            self.class_token[v[0]] = chr_classes.s(v[55])
        class_types = Dbc(self.dbc / 'CharacterAdvancementClassTypes.dbc')
        by_type = {}
        for i in range(class_types.rows):
            v = class_types.ints(i)
            by_type[v[0]] = v[2]
        adv = Dbc(self.dbc / 'CharacterAdvancement.dbc')
        self.adv_by_class, self.adv_spells = {}, {}
        for i in range(adv.rows):
            v = adv.ints(i)
            cls = by_type.get(v[ADV_CLASS_TYPE])
            if cls is None:
                continue
            for f in range(ADV_SPELLS, ADV_SPELLS + 5):
                if v[f]:
                    self.adv_by_class.setdefault(cls, set()).add(v[f])
                    self.adv_spells.setdefault(v[f], []).append({'class': cls, 'level': v[ADV_LEVEL]})
        sla = Dbc(self.dbc / 'SkillLineAbility.dbc')
        skill_line = Dbc(self.dbc / 'SkillLine.dbc')
        self.skill_name = {}
        for i in range(skill_line.rows):
            v = skill_line.ints(i)
            self.skill_name[v[0]] = skill_line.s(v[3])
        self.sla = {}
        for i in range(sla.rows):
            v = sla.ints(i)
            self.sla.setdefault(v[2], []).append({'line': v[1], 'line_name': self.skill_name.get(v[1], '?'),
                                                 'acquire': v[9]})
        self.grants = set()
        src = self.repo / 'modules/mod-ascension-compat/src'
        for name in ('AscensionCustomClassData.h', 'AscensionSpellProgressionData.h', 'AscensionTaughtAbilityData.h'):
            path = src / name
            if path.exists():
                self.grants |= {int(m) for m in re.findall(r'\b(\d{5,7})\b', path.read_text())}
        self.reachable = self._closure()

    def _closure(self):
        roots = set(self.adv_spells) | self.grants
        roots |= {sid for sid, rows in self.sla.items() if any(r['acquire'] for r in rows)}
        edges = {}
        for i in range(self.spell.rows):
            v = self.spell.ints(i)
            t = [v[116 + e] for e in range(3) if v[116 + e]]
            if t:
                edges[v[0]] = t
        seen, stack = set(), [r for r in roots if r in self.spell_idx]
        while stack:
            s = stack.pop()
            if s in seen:
                continue
            seen.add(s)
            stack.extend(t for t in edges.get(s, ()) if t not in seen)
        return seen

    def name(self, sid):
        i = self.spell_idx.get(sid)
        return self.spell.s(self.spell.ints(i)[136]) if i is not None else None

    def class_of(self, sid):
        rows = self.adv_spells.get(sid)
        if rows:
            return rows[0]['class']
        for r in self.sla.get(sid, []):
            for cls, ids in self.adv_by_class.items():
                pass
        return None


class Capture:
    """advancement.tsv: CharacterAdvancement harvested through the live client's GetAllEntries API.

    The strongest source here: it is what a running client answered, not a parse of a shipped DBC.
    """

    path = SNAP / 'ascension-data/extracted/advancement.tsv'

    def __init__(self):
        self.by_class, self.all = {}, set()
        if not self.path.exists():
            self.available = False
            return
        self.available = True
        with self.path.open() as fh:
            for row in csv.DictReader(fh, delimiter='\t'):
                ids = {int(m) for m in re.findall(r'"id":\s*(\d+)', row.get('Spells') or '')}
                if not ids:
                    continue
                self.by_class.setdefault((row.get('Class') or '').upper(), set()).update(ids)
                self.all |= ids


class ClassSpell:
    """exiles-db class_spell.csv: a server-side acquisition table, but it only carries 'ability' rows."""

    path = SNAP / 'ascension-data/tables/class_spell.csv'

    def __init__(self):
        self.by_class, self.all = {}, set()
        self.available = self.path.exists()
        if not self.available:
            return
        with self.path.open() as fh:
            for row in csv.DictReader(fh):
                sid = int(row['spell_id'])
                self.by_class.setdefault(int(row['class_id']), set()).add(sid)
                self.all.add(sid)


class Trainer:
    path = SNAP / 'ascension-data/tables/npc_trainer.csv'

    def __init__(self):
        self.all = set()
        self.available = self.path.exists()
        if self.available:
            with self.path.open() as fh:
                self.all = {int(r['spell_id']) for r in csv.DictReader(fh)}


class Calculator:
    """bindmysoul talents.normalized.json: a snapshot of the fan-maintained CoA talent calculator."""

    path = SNAP / 'bindmysoul/talents.normalized.json'

    def __init__(self):
        self.by_class, self.all, self.fetched = {}, set(), None
        self.available = self.path.exists()
        if not self.available:
            return
        data = json.loads(self.path.read_text())
        self.fetched = (data.get('metadata') or {}).get('fetchedAt')
        for node in data.get('nodes') or []:
            sid = node.get('spellId')
            if not sid:
                continue
            self.by_class.setdefault((node.get('className') or '').upper(), set()).add(sid)
            self.all.add(sid)


def calibrate(local, cls, capture, calculator, class_spell):
    """How much of what we KNOW is obtainable for this class does each source contain?"""
    ours = local.adv_by_class.get(cls, set())
    token = local.class_token.get(cls, '').upper()
    out = {'class': cls, 'token': token, 'ours': len(ours)}
    if capture.available:
        theirs = capture.by_class.get(token, set())
        got = ours & theirs
        out['capture'] = {'covers': len(got), 'of': len(ours), 'extra_in_capture': len(theirs - ours),
                          'identical': bool(ours) and ours == theirs}
    if calculator.available:
        hit = max((len(ours & ids) for ids in calculator.by_class.values()), default=0)
        out['calculator'] = {'covers': hit, 'of': len(ours)}
    if class_spell.available:
        out['class_spell'] = {'covers': len(ours & class_spell.by_class.get(cls, set())), 'of': len(ours)}
    return out


def verdict(cal):
    cap = cal.get('capture') or {}
    if cap.get('identical'):
        return ('The live-client capture and the shipped acquisition table hold the same spells for this class, '
                'so a spell absent from both was not acquirable.')
    if cap.get('of') and cap['covers'] == cap['of'] and cap.get('extra_in_capture'):
        return (f"The live-client capture holds every one of the {cap['of']} spells this class can already "
                f"acquire, and {cap['extra_in_capture']} more that the shipped table lacks. A spell absent from "
                'the capture was not acquirable; the extras are a real gap in this fork worth its own report.')
    if cap.get('of') and cap['covers'] / cap['of'] >= 0.9:
        return (f"The live-client capture holds {cap['covers']} of the {cap['of']} spells this class can already "
                'acquire, so its silence is meaningful but not conclusive.')
    return ('No source covers this class well enough for an absence to mean anything. Treat every "not found" '
            'below as unknown, not as proof.')


def look_up(sid, local, capture, calculator, class_spell, trainer):
    rows = local.adv_spells.get(sid, [])
    cls = rows[0]['class'] if rows else None
    token = local.class_token.get(cls, '').upper() if cls else None
    return {
        'spell': sid,
        'name': local.name(sid),
        'advancement': [{'class': r['class'], 'class_token': local.class_token.get(r['class']), 'level': r['level']}
                        for r in rows],
        'skill_lines': local.sla.get(sid, []),
        'module_grant': sid in local.grants,
        'trigger_reachable': sid in local.reachable,
        'live_capture': (sid in capture.all) if capture.available else None,
        'live_capture_class': (sid in capture.by_class.get(token, set())) if (capture.available and token) else None,
        'calculator': (sid in calculator.all) if calculator.available else None,
        'server_class_spell': (sid in class_spell.all) if class_spell.available else None,
        'server_trainer': (sid in trainer.all) if trainer.available else None,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('spells', nargs='*', type=int)
    ap.add_argument('--repo', default=os.path.expanduser('~/Projects/azerothcore-wotlk-coa'))
    ap.add_argument('--dbc', default='/srv/coa/server-data/dbc')
    ap.add_argument('--issues')
    ap.add_argument('--class', dest='cls', type=int)
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args(argv)

    local = Local(args.dbc, args.repo)
    capture, calculator, class_spell, trainer = Capture(), Calculator(), ClassSpell(), Trainer()

    missing = [n for n, s in (('advancement.tsv', capture), ('talents.normalized.json', calculator),
                              ('class_spell.csv', class_spell), ('npc_trainer.csv', trainer)) if not s.available]
    if missing:
        print(f'# snapshots missing, run coa-reference: {", ".join(missing)}', file=sys.stderr)

    spells, issue_of = list(args.spells), {}
    if args.issues:
        for entry in json.loads(Path(args.issues).read_text()):
            spells.append(entry['spellId'])
            issue_of[entry['spellId']] = entry.get('issue')

    if args.cls is not None and not spells:
        cal = calibrate(local, args.cls, capture, calculator, class_spell)
        print(json.dumps(cal, indent=1) if args.json else
              f"class {cal['class']} ({cal['token']}): {json.dumps({k: v for k, v in cal.items() if k not in ('class', 'token')})}\n{verdict(cal)}")
        return 0

    results = [look_up(s, local, capture, calculator, class_spell, trainer) for s in spells]
    classes = {r['advancement'][0]['class'] for r in results if r['advancement']}
    if args.cls is not None:
        classes.add(args.cls)
    cals = {c: calibrate(local, c, capture, calculator, class_spell) for c in sorted(classes)}

    if args.json:
        print(json.dumps({'calibration': cals, 'spells': results}, indent=1))
        return 0

    for c, cal in cals.items():
        print(f"calibration for class {c} ({cal['token']}): {json.dumps({k: v for k, v in cal.items() if k not in ('class', 'token')})}")
        print(f'  {verdict(cal)}')
    if not cals:
        print('calibration: none of the queried spells has an acquisition row, so no class could be calibrated.')
        print('  Pass --class N to calibrate against the class you believe they belong to.')
    print()
    for r in results:
        issue = f"#{issue_of[r['spell']]} " if issue_of.get(r['spell']) else ''
        lines = ', '.join(f"{s['line_name']}({s['line']}) acquire={s['acquire']}" for s in r['skill_lines']) or 'none'
        print(f"{issue}{r['spell']} {r['name']}")
        print(f"  advancement={r['advancement'] or 'none'} skill_lines=[{lines}] module_grant={r['module_grant']} "
              f"trigger_reachable={r['trigger_reachable']}")
        print(f"  live_capture={r['live_capture']} (same class={r['live_capture_class']}) "
              f"calculator={r['calculator']} server_class_spell={r['server_class_spell']} "
              f"server_trainer={r['server_trainer']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
