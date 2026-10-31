"""Tests for scripts/coa-lab-mem. Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'

Every memory-reading function is exercised against a FakeMemory image (a sparse byte store) by monkeypatching
the module's `read_bytes`, so no live process or process_vm_readv call is needed.
"""
import importlib.machinery
import importlib.util
import struct
import tempfile
import unittest
import unittest.mock
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "coa-lab-mem"
loader = importlib.machinery.SourceFileLoader("coa_lab_mem", str(SCRIPT))
spec = importlib.util.spec_from_loader("coa_lab_mem", loader)
mem = importlib.util.module_from_spec(spec)
loader.exec_module(mem)


class FakeMemory:
    """A sparse byte store addressed like a process's virtual memory. write() stages bytes at an address;
    read() raises mem.MemoryError_ for any address not covered by a write (an unmapped-page read)."""

    def __init__(self):
        self.chunks = []  # list of (start, bytes)

    def write(self, addr: int, data: bytes):
        self.chunks.append((addr, data))

    def write_u32(self, addr: int, value: int):
        self.write(addr, struct.pack("<I", value & 0xFFFFFFFF))

    def write_u64(self, addr: int, value: int):
        self.write(addr, struct.pack("<Q", value & 0xFFFFFFFFFFFFFFFF))

    def read(self, pid, addr, size):
        for start, data in self.chunks:
            if start <= addr and addr + size <= start + len(data):
                return data[addr - start: addr - start + size]
        raise mem.MemoryError_(f"unmapped read at {addr:#x} size {size}")


def patch_memory(test_case, fake: FakeMemory):
    original = mem.read_bytes
    mem.read_bytes = fake.read
    test_case.addCleanup(lambda: setattr(mem, "read_bytes", original))


class ReadPrimitivesTest(unittest.TestCase):
    def test_read_cstring_stops_at_nul(self):
        fake = FakeMemory()
        fake.write(0x1000, (b"Coalabone\x00garbage").ljust(32, b"\x00"))
        patch_memory(self, fake)
        self.assertEqual(mem.read_cstring(None, 0x1000, 32), "Coalabone")

    def test_read_cstring_of_null_pointer_is_empty(self):
        self.assertEqual(mem.read_cstring(None, 0, 32), "")

    def test_unmapped_read_raises(self):
        fake = FakeMemory()
        patch_memory(self, fake)
        with self.assertRaises(mem.MemoryError_):
            mem.read_u32(None, 0x5000)


class BuildIdentityTest(unittest.TestCase):
    def test_found_and_validated(self):
        fake = FakeMemory()
        fake.write(mem.IMAGE_BASE, b"MZ\x90\x00")
        blob = bytearray(mem.BUILD_SCAN_CHUNK)
        blob[0x50000:0x50000 + len(mem.BUILD_STRING)] = mem.BUILD_STRING
        fake.write(mem.IMAGE_BASE, bytes(blob))
        patch_memory(self, fake)
        result = mem.check_build_identity(None)
        self.assertTrue(result["mz_header"])
        self.assertEqual(result["build_string_found_at"], mem.IMAGE_BASE + 0x50000)
        self.assertTrue(result["validated"])

    def test_missing_string_is_not_validated(self):
        fake = FakeMemory()
        fake.write(mem.IMAGE_BASE, b"MZ\x90\x00")
        fake.write(mem.IMAGE_BASE, bytes(mem.BUILD_SCAN_CHUNK))
        patch_memory(self, fake)
        result = mem.check_build_identity(None)
        self.assertIsNone(result["build_string_found_at"])
        self.assertFalse(result["validated"])


def build_fake_pe(fake: FakeMemory, image_base: int, tls_rva: int, start_rva: int, end_rva: int,
                   index_addr_rva: int, tls_index: int):
    e_lfanew = 0x80
    fake.write(image_base, b"MZ" + b"\x00" * 0x3A + struct.pack("<I", e_lfanew))
    machine, nsections, ts, ptst, nsym, opt_size, chars = 0x14C, 0, 0, 0, 0, 224, 0
    coff = struct.pack("<HHIIIHH", machine, nsections, ts, ptst, nsym, opt_size, chars)
    fake.write(image_base + e_lfanew, b"PE\x00\x00" + coff)
    opt = bytearray(opt_size)
    struct.pack_into("<II", opt, 96 + 9 * 8, tls_rva, 24)
    fake.write(image_base + e_lfanew + 24, bytes(opt))
    fake.write(image_base + tls_rva, struct.pack("<IIIIII", start_rva, end_rva, index_addr_rva, 0, 0, 0))
    fake.write(index_addr_rva, struct.pack("<I", tls_index))


class TlsDirectoryTest(unittest.TestCase):
    def test_resolves_index_and_delta(self):
        fake = FakeMemory()
        build_fake_pe(fake, mem.IMAGE_BASE, tls_rva=0x6AEF70, start_rva=0xDD2000, end_rva=0xDD2018,
                      index_addr_rva=0xD439BC, tls_index=0)
        patch_memory(self, fake)
        result = mem.parse_tls_directory(None)
        self.assertEqual(result["tls_index"], 0)
        self.assertEqual(result["s_curmgr_delta"], mem.TLS_S_CURMGR_RVA - 0xDD2000)
        self.assertTrue(result["validated"])

    def test_curmgr_outside_tls_block_raises(self):
        fake = FakeMemory()
        build_fake_pe(fake, mem.IMAGE_BASE, tls_rva=0x6AEF70, start_rva=0x100, end_rva=0x110,
                      index_addr_rva=0xD439BC, tls_index=0)
        patch_memory(self, fake)
        with self.assertRaises(mem.MemoryError_):
            mem.parse_tls_directory(None)


class TebDiscoveryTest(unittest.TestCase):
    def test_finds_self_pointing_teb64(self):
        fake = FakeMemory()
        teb_addr = 0x200000
        data = bytearray(0x38)
        struct.pack_into("<Q", data, 0x30, teb_addr)
        fake.write(teb_addr, bytes(data))
        # a neighbouring page that is not a TEB
        fake.write(teb_addr + mem.PAGE, b"\x00" * 0x38)
        patch_memory(self, fake)
        found = mem.find_teb64_candidates(None, regions=[(teb_addr, teb_addr + 2 * mem.PAGE)])
        self.assertEqual(found, [teb_addr])


def build_object_manager(fake: FakeMemory, mgr: int, player_guid: int, map_id: int, nodes: list):
    """nodes: list of (node_addr, link_offset_within_node_to_next, obj_data_addr, guid, type_mask, entry,
    type_id). All nodes must share the same link_offset (the hash table's TSList.m_linkoffset is global)."""
    link_offset = nodes[0][1] if nodes else 0x24
    list_base = mgr + mem.OBJ_FULLLIST_OFF
    terminator_addr = list_base + 4
    fake.write_u32(list_base, link_offset)
    fake.write_u64(mgr + mem.OBJ_PLAYER_GUID_OFF, player_guid)
    fake.write_u32(mgr + mem.OBJ_TYPE_OFF, 0)
    fake.write_u32(mgr + mem.OBJ_MAPID_OFF, map_id)
    chain = [n[0] for n in nodes] + [terminator_addr]
    fake.write_u32(terminator_addr + 4, chain[0] if nodes else terminator_addr)
    for i, (node_addr, _link, obj_addr, guid, type_mask, entry, type_id) in enumerate(nodes):
        fake.write_u32(node_addr + mem.CGOBJECT_MOBJ_OFF, obj_addr)
        fake.write_u32(node_addr + mem.CGOBJECT_TYPEID_OFF, type_id)
        fake.write_u64(obj_addr + mem.CGOBJECTDATA_GUID_OFF, guid)
        fake.write_u32(obj_addr + mem.CGOBJECTDATA_TYPE_OFF, type_mask)
        fake.write_u32(obj_addr + mem.CGOBJECTDATA_ENTRY_OFF, entry)
        fake.write_u32(node_addr + link_offset + 4, chain[i + 1])


class ObjectManagerTest(unittest.TestCase):
    def test_summary_reads_player_guid_and_map(self):
        fake = FakeMemory()
        mgr = 0x3000000
        build_object_manager(fake, mgr, player_guid=1, map_id=1, nodes=[])
        patch_memory(self, fake)
        summary = mem.object_manager_summary(None, mgr)
        self.assertEqual(summary["active_player_guid"], 1)
        self.assertEqual(summary["map_id"], 1)

    def test_walk_objects_flat_list(self):
        fake = FakeMemory()
        mgr = 0x3000000
        nodes = [
            (0x4000000, 0x24, 0x4000100, 1, 0x19, 0, 4),
            (0x4001000, 0x24, 0x4001100, 0xF130007F9A002C0A, 0x09, 32666, 3),
        ]
        build_object_manager(fake, mgr, player_guid=1, map_id=1, nodes=nodes)
        patch_memory(self, fake)
        found = mem.walk_objects(None, mgr)
        self.assertEqual(found, [0x4000000, 0x4001000])

    def test_find_node_by_guid(self):
        fake = FakeMemory()
        mgr = 0x3000000
        nodes = [
            (0x4000000, 0x24, 0x4000100, 1, 0x19, 0, 4),
            (0x4001000, 0x24, 0x4001100, 42, 0x09, 32666, 3),
        ]
        build_object_manager(fake, mgr, player_guid=1, map_id=1, nodes=nodes)
        patch_memory(self, fake)
        node = mem.find_node_by_guid(None, mgr, 42)
        self.assertEqual(node, 0x4001000)
        with self.assertRaises(mem.MemoryError_):
            mem.find_node_by_guid(None, mgr, 999)

    def test_single_node_list_terminates_through_the_tag_bit(self):
        # The live client's TSExplicitList stores the wraparound next pointer with its low bit set
        # (observed on g_nameDBCache with exactly one entry); walk_objects must mask it off.
        fake = FakeMemory()
        mgr = 0x3000000
        list_base = mgr + mem.OBJ_FULLLIST_OFF
        terminator_addr = list_base + 4
        link_offset = 0x24
        node = 0x4000000
        fake.write_u32(list_base, link_offset)
        fake.write_u32(terminator_addr + 4, node)
        fake.write_u32(node + link_offset + 4, terminator_addr | 1)
        fake.write_u32(node + mem.CGOBJECT_MOBJ_OFF, 0x4000100)
        fake.write_u32(node + mem.CGOBJECT_TYPEID_OFF, 4)
        fake.write_u64(0x4000100 + mem.CGOBJECTDATA_GUID_OFF, 1)
        patch_memory(self, fake)
        self.assertEqual(mem.walk_objects(None, mgr), [node])


class GameObjectTest(unittest.TestCase):
    def build(self, dynamic=0x0008, type_id=5):
        fake = FakeMemory()
        mgr = 0x3000000
        build_object_manager(fake, mgr, player_guid=1, map_id=0, nodes=[
            (0x4000000, 0x24, 0x4000100, 1, 0x19, 0, 4),
            (0x4001000, 0x24, 0x4001100, 0xF11000003D0000FF, 0x21, 61, type_id),
        ])
        obj = 0x4001100
        fake.write_u32(obj + mem.GAMEOBJECT_DISPLAYID_OFF, 301)
        fake.write_u32(obj + mem.GAMEOBJECT_FLAGS_OFF, 0x20)
        fake.write_u32(obj + mem.GAMEOBJECT_DYNAMIC_OFF, dynamic)
        fake.write_u32(obj + mem.GAMEOBJECT_BYTES_1_OFF, 0x00000A01)
        patch_memory(self, fake)
        return mgr

    def test_reads_sparkle_dynflag_by_entry(self):
        result = mem.cmd_gameobject(None, self.build(dynamic=0x00050009), "61")
        self.assertEqual(result["dynflags"], 0x09)
        self.assertEqual(result["dynflag_names"], ["activate", "sparkle"])
        self.assertEqual(result["path_progress"], 5)
        self.assertEqual((result["state"], result["go_type"]), (1, 10))
        self.assertEqual((result["display_id"], result["flags"]), (301, 0x20))

    def test_dynflags_clear_when_no_sparkle(self):
        result = mem.cmd_gameobject(None, self.build(dynamic=0), "0xF11000003D0000FF")
        self.assertEqual(result["dynflag_names"], [])

    def test_unknown_entry_raises(self):
        with self.assertRaises(mem.MemoryError_):
            mem.cmd_gameobject(None, self.build(), "999")

    def test_non_gameobject_guid_is_refused(self):
        with self.assertRaises(mem.MemoryError_):
            mem.cmd_gameobject(None, self.build(type_id=3), "0xF11000003D0000FF")


class UnitDataTest(unittest.TestCase):
    def test_reads_health_powers_and_target(self):
        fake = FakeMemory()
        node, cgd = 0x5000000, 0x5000200
        fake.write_u32(node + mem.CGUNIT_MUNIT_OFF, cgd)
        fake.write_u64(cgd + mem.CGUNITDATA_TARGET_OFF, 0xF130007F9A002C0A)
        fake.write_u32(cgd + mem.CGUNITDATA_HEALTH_OFF, 144)
        fake.write_u32(cgd + mem.CGUNITDATA_MAXHEALTH_OFF, 144)
        for i, value in enumerate([0, 0, 0, 100, 0, 0, 0]):
            fake.write_u32(cgd + mem.CGUNITDATA_POWER_OFF + 4 * i, value)
        patch_memory(self, fake)
        unit = mem.read_unit_data(None, node)
        self.assertEqual(unit["health"], 144)
        self.assertEqual(unit["max_health"], 144)
        self.assertEqual(unit["powers"]["energy"], 100)
        self.assertEqual(unit["target_guid"], 0xF130007F9A002C0A)


class AurasTest(unittest.TestCase):
    def write_aura(self, fake, entry_addr, caster, spell_id, flags, level, stacks, duration, end_time):
        fake.write_u64(entry_addr, caster)
        fake.write(entry_addr + 8, struct.pack("<i", spell_id))
        fake.write(entry_addr + 0xC, bytes([flags, level, stacks, 0]))
        fake.write(entry_addr + 0x10, struct.pack("<ii", duration, end_time))

    def test_no_auras(self):
        fake = FakeMemory()
        node = 0x6000000
        fake.write_u32(node + mem.AURAS_OFF + mem.AURA_COUNT_OFF, 0)
        patch_memory(self, fake)
        result = mem.read_auras(None, node)
        self.assertEqual(result["slots"], 0)
        self.assertEqual(result["mode"], "inline")
        self.assertEqual(result["entries"], [])

    def test_inline_auras(self):
        fake = FakeMemory()
        node = 0x6000000
        base = node + mem.AURAS_OFF
        self.write_aura(fake, base + 0 * mem.AURA_ENTRY_SIZE, 1, 589, 169, 1, 0, 18000, 262167288)
        self.write_aura(fake, base + 1 * mem.AURA_ENTRY_SIZE, 1, 1130, 171, 1, 0, 300000, 262451179)
        fake.write_u32(base + mem.AURA_COUNT_OFF, 2)
        patch_memory(self, fake)
        result = mem.read_auras(None, node)
        self.assertEqual(result["mode"], "inline")
        self.assertEqual(result["slots"], 2)
        self.assertEqual([e["spell_id"] for e in result["entries"]], [589, 1130])
        self.assertEqual(result["entries"][1]["duration"], 300000)
        self.assertEqual(result["entries"][1]["end_time"], 262451179)

    def test_dynamic_auras_over_sixteen(self):
        fake = FakeMemory()
        node = 0x6000000
        base = node + mem.AURAS_OFF
        heap = 0x7000000
        spell_ids = list(range(100, 119))  # 19 entries, matches the live >16 case observed
        for i, spell_id in enumerate(spell_ids):
            self.write_aura(fake, heap + i * mem.AURA_ENTRY_SIZE, 1, spell_id, 57, 1, 0, 0, 0)
        fake.write_u32(base + mem.AURA_COUNT_OFF, 0xFFFFFFFF)  # stale outer count once dynamic (observed live)
        fake.write_u32(base + mem.AURA_AC_ALLOC_OFF, 20)
        fake.write_u32(base + mem.AURA_AC_COUNT_OFF, 19)
        fake.write_u32(base + mem.AURA_AC_DATA_OFF, heap)
        patch_memory(self, fake)
        result = mem.read_auras(None, node)
        self.assertEqual(result["mode"], "dynamic")
        self.assertEqual(result["slots"], 19)
        self.assertEqual([e["spell_id"] for e in result["entries"]], spell_ids)

    def test_removed_aura_slots_are_not_auras(self):
        fake = FakeMemory()
        node = 0x6000000
        base = node + mem.AURAS_OFF
        self.write_aura(fake, base + 0 * mem.AURA_ENTRY_SIZE, 1, 54428, 63, 1, 0, 15000, 263185541)
        self.write_aura(fake, base + 1 * mem.AURA_ENTRY_SIZE, 1, 0, 171, 1, 0, 40000, 262363951)
        self.write_aura(fake, base + 2 * mem.AURA_ENTRY_SIZE, 1, 1459, 59, 1, 0, 1800000, 264971443)
        fake.write_u32(base + mem.AURA_COUNT_OFF, 3)
        patch_memory(self, fake)
        result = mem.read_auras(None, node)
        self.assertEqual(result["slots"], 3)
        self.assertEqual(result["empty_slots"], 1)
        self.assertEqual([(e["slot"], e["spell_id"]) for e in result["entries"]], [(0, 54428), (2, 1459)])


class NameCacheTest(unittest.TestCase):
    def test_creature_name_via_creature_cache(self):
        fake = FakeMemory()
        node, cache, name_ptr = 0x8000000, 0x8000100, 0x8000200
        fake.write_u32(node + mem.CREATURE_CACHE_OFF, cache)
        fake.write_u32(cache + mem.CREATURE_NAME_OFF, name_ptr)
        fake.write(name_ptr, b"Training Dummy\x00".ljust(64, b"\x00"))
        patch_memory(self, fake)
        self.assertEqual(mem.read_creature_name(None, node), "Training Dummy")

    def test_player_name_via_name_cache_single_entry(self):
        fake = FakeMemory()
        list_base = mem.NAME_CACHE + mem.NAME_CACHE_HT_OFF + mem.NAME_CACHE_LIST_OFF
        terminator_addr = list_base + 4
        link_offset = 0xC
        entry = 0x9000000
        fake.write_u32(list_base, link_offset)
        # the live client tags the wraparound pointer's low bit when the list holds one entry
        fake.write_u32(terminator_addr + 4, entry)
        fake.write_u32(entry + link_offset + 4, terminator_addr | 1)
        fake.write_u32(entry + mem.NAME_CACHE_GUID_LOW_OFF, 1)
        fake.write_u32(entry + mem.NAME_CACHE_GUID_HIGH_OFF, 0)
        fake.write(entry + mem.NAME_CACHE_NAME_OFF, b"Coalabone\x00".ljust(mem.NAME_CACHE_NAME_MAXLEN, b"\x00"))
        patch_memory(self, fake)
        self.assertEqual(mem.read_player_name(None, 1), "Coalabone")
        self.assertEqual(mem.read_player_name(None, 2), "")


class SpellDbTest(unittest.TestCase):
    def test_summary_reads_counts_and_bounds(self):
        fake = FakeMemory()
        fake.write_u32(mem.G_SPELLDB + mem.SPELLDB_NUMRECORDS_OFF, 209510)
        fake.write_u32(mem.G_SPELLDB + mem.SPELLDB_MAXID_OFF, 13977920)
        fake.write_u32(mem.G_SPELLDB + mem.SPELLDB_MINID_OFF, 1)
        fake.write_u32(mem.G_SPELLDB + mem.SPELLDB_RECORDSBYID_OFF, 0x2B1BC9B8)
        patch_memory(self, fake)
        result = mem.read_spell_db(None)
        self.assertEqual(result["num_records"], 209510)
        self.assertEqual(result["max_id"], 13977920)
        self.assertEqual(result["min_id"], 1)
        self.assertEqual(result["records_by_id"], 0x2B1BC9B8)
        self.assertTrue(all(result["validated"].values()))


def write_spell_record(fake: FakeMemory, rec_addr: int, strings_base: int, spell_id: int, name: str,
                        rank: str, description: str, tooltip: str, school_mask: int, duration_index: int,
                        power_type: int, mana_cost: int, spell_icon_id: int, range_index: int):
    fake.write_u32(rec_addr + mem.SPELLREC_ID_OFF, spell_id)
    fake.write_u32(rec_addr + mem.SPELLREC_ICON_OFF, spell_icon_id)
    fake.write_u32(rec_addr + mem.SPELLREC_DURATION_INDEX_OFF, duration_index)
    fake.write_u32(rec_addr + mem.SPELLREC_POWER_TYPE_OFF, power_type)
    fake.write_u32(rec_addr + mem.SPELLREC_MANA_COST_OFF, mana_cost)
    fake.write_u32(rec_addr + mem.SPELLREC_RANGE_INDEX_OFF, range_index)
    fake.write_u32(rec_addr + mem.SPELLREC_SCHOOL_MASK_OFF, school_mask)
    strings = [name, rank, description, tooltip]
    offsets = [mem.SPELLREC_NAME_PTR_OFF, mem.SPELLREC_RANK_PTR_OFF, mem.SPELLREC_DESCRIPTION_PTR_OFF,
               mem.SPELLREC_TOOLTIP_PTR_OFF]
    cursor = strings_base
    for text, ptr_off in zip(strings, offsets):
        if text == "":
            fake.write_u32(rec_addr + ptr_off, 0)
            continue
        fake.write_u32(rec_addr + ptr_off, cursor)
        encoded = (text.encode("latin1") + b"\x00").ljust(mem.SPELLREC_STRING_MAXLEN, b"\x00")
        fake.write(cursor, encoded)
        cursor += len(encoded)


def build_spell_db(fake: FakeMemory, db_addr: int, records_by_id: int, strings_base: int, min_id: int,
                    max_id: int, records: dict):
    """records: {spell_id: kwargs for write_spell_record (minus fake/rec_addr/strings_base/spell_id)}."""
    fake.write_u32(db_addr + mem.SPELLDB_NUMRECORDS_OFF, len(records))
    fake.write_u32(db_addr + mem.SPELLDB_MAXID_OFF, max_id)
    fake.write_u32(db_addr + mem.SPELLDB_MINID_OFF, min_id)
    fake.write_u32(db_addr + mem.SPELLDB_RECORDSBYID_OFF, records_by_id)
    rec_cursor = db_addr + 0x100000
    str_cursor = strings_base
    for spell_id, kwargs in records.items():
        rec_addr = rec_cursor
        write_spell_record(fake, rec_addr, str_cursor, spell_id, **kwargs)
        fake.write_u32(records_by_id + (spell_id - min_id) * 4, rec_addr)
        rec_cursor += 0x1000
        str_cursor += 0x10000


class SpellRecordTest(unittest.TestCase):
    DB_ADDR = mem.G_SPELLDB
    RECORDS_BY_ID = 0x2B1BC9B8
    STRINGS_BASE = 0x21C00000

    def setUp(self):
        self.fake = FakeMemory()

    def test_reads_a_stock_spell(self):
        build_spell_db(self.fake, self.DB_ADDR, self.RECORDS_BY_ID, self.STRINGS_BASE, min_id=1,
                        max_id=13977920, records={
                            1459: dict(name="Arcane Intellect", rank="Rank 1",
                                       description="Increases the target's Intellect by $s1 and spell "
                                                    "power by $s2 for $d.",
                                       tooltip="Increases Intellect by $s1 and spell power by $s2.",
                                       school_mask=64, duration_index=30, power_type=0, mana_cost=0,
                                       spell_icon_id=125, range_index=4),
                        })
        patch_memory(self, self.fake)
        result = mem.read_spell_record(None, 1459)
        self.assertTrue(result["loaded"])
        self.assertEqual(result["record_id"], 1459)
        self.assertTrue(result["id_matches_record_id"])
        self.assertEqual(result["name"], "Arcane Intellect")
        self.assertEqual(result["rank"], "Rank 1")
        self.assertEqual(result["tooltip"], "Increases Intellect by $s1 and spell power by $s2.")
        self.assertEqual(result["school_mask"], 64)
        self.assertEqual(result["duration_index"], 30)
        self.assertEqual(result["power_type"], 0)
        self.assertEqual(result["mana_cost"], 0)
        self.assertEqual(result["spell_icon_id"], 125)
        self.assertEqual(result["range_index"], 4)
        self.assertTrue(all(result["validated"].values()))

    def test_reads_a_coa_custom_spell_with_empty_tooltip(self):
        build_spell_db(self.fake, self.DB_ADDR, self.RECORDS_BY_ID, self.STRINGS_BASE, min_id=1,
                        max_id=13977920, records={
                            501281: dict(name="Fel Fireball", rank="Rank 2",
                                         description="Unleash a powerful fel fireball at an enemy.",
                                         tooltip="", school_mask=4, duration_index=0, power_type=3,
                                         mana_cost=35, spell_icon_id=24725, range_index=4),
                        })
        patch_memory(self, self.fake)
        result = mem.read_spell_record(None, 501281)
        self.assertTrue(result["loaded"])
        self.assertEqual(result["name"], "Fel Fireball")
        self.assertEqual(result["rank"], "Rank 2")
        self.assertEqual(result["tooltip"], "")
        self.assertEqual(result["power_type"], 3)
        self.assertEqual(result["mana_cost"], 35)

    def test_index_is_id_minus_min_id_not_id(self):
        # Live calibration (reports/t6): m_recordsById is indexed by (id - m_minID); a plain id index into
        # 1459's slot returned spell 1460's own record. min_id=1 here makes the two indices differ by one.
        build_spell_db(self.fake, self.DB_ADDR, self.RECORDS_BY_ID, self.STRINGS_BASE, min_id=1,
                        max_id=13977920, records={
                            1459: dict(name="Arcane Intellect", rank="Rank 1", description="", tooltip="",
                                       school_mask=64, duration_index=30, power_type=0, mana_cost=0,
                                       spell_icon_id=125, range_index=4),
                            1460: dict(name="Arcane Intellect", rank="Rank 2", description="", tooltip="",
                                       school_mask=64, duration_index=30, power_type=0, mana_cost=0,
                                       spell_icon_id=125, range_index=4),
                        })
        patch_memory(self, self.fake)
        self.assertEqual(mem.read_spell_record(None, 1459)["rank"], "Rank 1")
        self.assertEqual(mem.read_spell_record(None, 1460)["rank"], "Rank 2")

    def test_id_outside_range_is_not_loaded(self):
        build_spell_db(self.fake, self.DB_ADDR, self.RECORDS_BY_ID, self.STRINGS_BASE, min_id=1,
                        max_id=13977920, records={})
        patch_memory(self, self.fake)
        result = mem.read_spell_record(None, 999999999)
        self.assertFalse(result["loaded"])
        self.assertIn("range", result["reason"])

    def test_max_id_is_a_loaded_spell(self):
        build_spell_db(self.fake, self.DB_ADDR, self.RECORDS_BY_ID, self.STRINGS_BASE, min_id=1,
                        max_id=13977920, records={
                            13977920: dict(name="Last Row", rank="", description="", tooltip="",
                                           school_mask=1, duration_index=0, power_type=0, mana_cost=0,
                                           spell_icon_id=1, range_index=1),
                        })
        patch_memory(self, self.fake)
        result = mem.read_spell_record(None, 13977920)
        self.assertTrue(result["loaded"])
        self.assertEqual(result["name"], "Last Row")
        self.assertFalse(mem.read_spell_record(None, 13977921)["loaded"])

    def test_null_record_pointer_is_not_loaded(self):
        build_spell_db(self.fake, self.DB_ADDR, self.RECORDS_BY_ID, self.STRINGS_BASE, min_id=1,
                        max_id=13977920, records={})
        # id within [min_id, max_id] but g_spellDB.m_recordsById[index] was never written -> unmapped read,
        # so simulate the live "null slot" case by writing an explicit zero pointer instead.
        self.fake.write_u32(self.RECORDS_BY_ID + (1459 - 1) * 4, 0)
        patch_memory(self, self.fake)
        result = mem.read_spell_record(None, 1459)
        self.assertFalse(result["loaded"])
        self.assertIn("null", result["reason"])


class GlueTest(unittest.TestCase):
    def _write_character_list(self, fake, names):
        data = 0x6000000
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_ALLOC_OFF, max(len(names), 1))
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_COUNT_OFF, len(names))
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_DATA_OFF, data if names else 0)
        for index, name in enumerate(names):
            entry = data + index * mem.GLUE_CHARLIST_ENTRY_SIZE
            fake.write(entry + mem.GLUE_CHARLIST_NAME_OFF, (name.encode() + b"\x00").ljust(48, b"\x00"))

    def _write_login_state(self, fake, login_result=-1, login_state=-1, last_login_result=-1,
                            last_login_state=-1, disconnect_pending=0, reconnect=0, account_name="",
                            displaying_queue_dialog=0, showed_disconnect=0, server_alert=""):
        fake.write_u32(mem.GLUE_LOGIN_RESULT, login_result & 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_LOGIN_STATE, login_state & 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_LAST_LOGIN_RESULT, last_login_result & 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_LAST_LOGIN_STATE, last_login_state & 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_DISCONNECT_PENDING, disconnect_pending)
        fake.write_u32(mem.GLUE_RECONNECT, reconnect)
        fake.write(mem.GLUE_ACCOUNT_NAME, (account_name.encode() + b"\x00").ljust(1280, b"\x00"))
        fake.write_u32(mem.GLUE_DISPLAYING_QUEUE_DIALOG, displaying_queue_dialog)
        fake.write_u32(mem.GLUE_SHOWED_DISCONNECT, showed_disconnect)
        fake.write(mem.GLUE_SERVER_ALERT, (server_alert.encode() + b"\x00").ljust(2048, b"\x00"))

    def test_account_login_screen_not_in_world_empty_list(self):
        fake = FakeMemory()
        fake.write(mem.GLUE_CURRENT_SCREEN, b"login\x00".ljust(64, b"\x00"))
        fake.write_u32(mem.GLUE_SELECTION_INDEX, 0xFFFFFFFF)  # -1 as i32
        self._write_character_list(fake, [])
        self._write_login_state(fake)
        patch_memory(self, fake)
        with unittest.mock.patch.object(mem, "parse_tls_directory", side_effect=mem.MemoryError_("no tls")):
            result = mem.cmd_glue(None)
        self.assertEqual(result["current_screen"], "login")
        self.assertFalse(result["in_world"])
        self.assertEqual(result["selection_index"], -1)
        self.assertEqual(result["characters"], [])

    def test_character_select_screen_lists_names_and_index(self):
        fake = FakeMemory()
        fake.write(mem.GLUE_CURRENT_SCREEN, b"charselect\x00".ljust(64, b"\x00"))
        fake.write_u32(mem.GLUE_SELECTION_INDEX, 1)
        self._write_character_list(fake, ["Memdedi", "Memtwo"])
        self._write_login_state(fake)
        patch_memory(self, fake)
        with unittest.mock.patch.object(mem, "parse_tls_directory", side_effect=mem.MemoryError_("no tls")):
            result = mem.cmd_glue(None)
        self.assertEqual(result["current_screen"], "charselect")
        self.assertFalse(result["in_world"])
        self.assertEqual(result["selection_index"], 1)
        self.assertEqual(result["characters"], ["Memdedi", "Memtwo"])

    def test_in_world_flag_true_when_object_manager_resolves(self):
        fake = FakeMemory()
        # m_currentScreen is not cleared on entering the world (validated live): it keeps the stale
        # glue screen name, which is exactly why `in_world` must come from the object manager, not
        # from the screen string.
        fake.write(mem.GLUE_CURRENT_SCREEN, b"charselect\x00".ljust(64, b"\x00"))
        fake.write_u32(mem.GLUE_SELECTION_INDEX, 0)
        self._write_character_list(fake, [])  # cleared on entering the world, validated live
        self._write_login_state(fake)
        patch_memory(self, fake)
        with unittest.mock.patch.object(mem, "parse_tls_directory", return_value={"tls_index": 0, "s_curmgr_delta": 0}), \
             unittest.mock.patch.object(mem, "resolve_object_manager", return_value={"address": 0x3000000}), \
             unittest.mock.patch.object(mem, "object_manager_summary", return_value={"active_player_guid": 7}):
            result = mem.cmd_glue(None)
        self.assertEqual(result["current_screen"], "charselect")
        self.assertTrue(result["in_world"])
        self.assertEqual(result["characters"], [])

    def test_character_list_not_read_when_data_pointer_is_null(self):
        fake = FakeMemory()
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_ALLOC_OFF, 0)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_COUNT_OFF, 0)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_DATA_OFF, 0)
        patch_memory(self, fake)
        self.assertEqual(mem.read_glue_character_list(None), [])


class GuardsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_lab_slot_accepts_slot_one(self):
        state_dir = self.root / "state"
        state_dir.mkdir()
        (state_dir / "lock").write_text("slot 1 since 2026-10-26T00:00:00+00:00\n")
        self.assertEqual(mem.check_lab_slot(state_dir), 1)

    def test_lab_slot_reads_the_lock(self):
        state_dir = self.root / "state"
        state_dir.mkdir()
        (state_dir / "lock").write_text("slot 2 since 2026-10-26T00:00:00+00:00\n")
        self.assertEqual(mem.check_lab_slot(state_dir), 2)

    def test_slot_worldserver_conf_uses_coa_slot_etc(self):
        completed = mem.subprocess.CompletedProcess([], 0, stdout="SLOT=1\nETC=/srv/coa/etc\nLOGS=/srv/coa/logs\n")
        with unittest.mock.patch.object(mem.subprocess, "run", return_value=completed):
            self.assertEqual(mem.slot_worldserver_conf(1), Path("/srv/coa/etc/worldserver.conf"))

    def test_slot_worldserver_conf_without_etc_is_refused(self):
        completed = mem.subprocess.CompletedProcess([], 0, stdout="SLOT=9\n")
        with unittest.mock.patch.object(mem.subprocess, "run", return_value=completed):
            with self.assertRaises(mem.GuardError):
                mem.slot_worldserver_conf(9)

    def test_pid_is_lab_client_rejects_user_client(self):
        proc_root = self.root / "proc"
        lab_root = self.root / "CoaServer/client-lab"
        user_client = self.root / "CoaServer/client/ascension-live"
        lab_root.mkdir(parents=True)
        user_client.mkdir(parents=True)
        (proc_root / "123").mkdir(parents=True)
        (proc_root / "123" / "maps").write_text(
            f"00400000-00401000 r-xp 00000000 08:01 1 {user_client}/Ascension.exe\n")
        with self.assertRaises(mem.GuardError):
            mem.check_pid_is_lab_client(123, lab_root, proc_root)

    def test_pid_is_lab_client_accepts_lab_path(self):
        proc_root = self.root / "proc"
        lab_root = self.root / "CoaServer/client-lab"
        lab_exe_dir = lab_root / "ascension-lab"
        lab_exe_dir.mkdir(parents=True)
        (proc_root / "123").mkdir(parents=True)
        (proc_root / "123" / "maps").write_text(
            f"00400000-00401000 r-xp 00000000 08:01 1 {lab_exe_dir}/Ascension.exe\n")
        result = mem.check_pid_is_lab_client(123, lab_root, proc_root)
        self.assertEqual(result, (lab_exe_dir / "Ascension.exe").resolve())

    def test_check_warden_disabled_passes_when_zero(self):
        conf = self.root / "worldserver.conf"
        conf.write_text("SomeOption = 1\nWarden.Enabled = 0\nOther = 2\n")
        with unittest.mock.patch.object(mem, "slot_worldserver_conf", return_value=conf):
            mem.check_warden_disabled(2)  # does not raise

    def test_check_warden_disabled_raises_when_one(self):
        conf = self.root / "worldserver.conf"
        conf.write_text("Warden.Enabled = 1\n")
        with unittest.mock.patch.object(mem, "slot_worldserver_conf", return_value=conf):
            with self.assertRaises(mem.GuardError):
                mem.check_warden_disabled(4)

    def test_check_warden_disabled_raises_when_missing(self):
        conf = self.root / "worldserver.conf"
        conf.write_text("Other = 2\n")
        with unittest.mock.patch.object(mem, "slot_worldserver_conf", return_value=conf):
            with self.assertRaises(mem.GuardError):
                mem.check_warden_disabled(5)


class WardenStatusCommandTest(unittest.TestCase):
    """L15 problem 2: `coa-lab-mem warden-status --slot N` reuses check_warden_disabled directly and
    needs no running lab client/lock, so preflight/start can report it before any read is attempted."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)

    def test_warden_off_reports_false(self):
        conf = self.root / "worldserver.conf"
        conf.write_text("Warden.Enabled = 0\n")
        with unittest.mock.patch.object(mem, "slot_worldserver_conf", return_value=conf), \
             unittest.mock.patch.object(mem.sys, "argv", ["coa-lab-mem", "warden-status", "--slot", "2"]):
            with unittest.mock.patch("builtins.print") as fake_print:
                rc = mem.main(["warden-status", "--slot", "2"])
        self.assertEqual(rc, 0)
        printed = fake_print.call_args[0][0]
        self.assertIn('"slot": 2', printed)
        self.assertIn('"warden_enabled": false', printed)

    def test_warden_on_reports_true_and_detail(self):
        conf = self.root / "worldserver.conf"
        conf.write_text("Warden.Enabled = 1\n")
        with unittest.mock.patch.object(mem, "slot_worldserver_conf", return_value=conf):
            with unittest.mock.patch("builtins.print") as fake_print:
                rc = mem.main(["warden-status", "--slot", "4"])
        self.assertEqual(rc, 0)
        printed = fake_print.call_args[0][0]
        self.assertIn('"warden_enabled": true', printed)
        self.assertIn("does not have Warden.Enabled", printed)

    def test_missing_conf_reports_unknown_not_enabled(self):
        conf = self.root / "missing-worldserver.conf"
        with unittest.mock.patch.object(mem, "slot_worldserver_conf", return_value=conf):
            with unittest.mock.patch("builtins.print") as fake_print:
                rc = mem.main(["warden-status", "--slot", "5"])
        self.assertEqual(rc, 0)
        self.assertIn('"warden_enabled": null', fake_print.call_args[0][0])

    def test_warden_status_needs_no_lock_or_pid(self):
        # No $COA_LAB_ROOT/state/lock anywhere under self.root: run_guards would refuse this (no lab
        # slot recorded), but warden-status must not call run_guards at all.
        conf = self.root / "worldserver.conf"
        conf.write_text("Warden.Enabled = 0\n")
        with unittest.mock.patch.object(mem, "slot_worldserver_conf", return_value=conf), \
             unittest.mock.patch.object(mem, "run_guards", side_effect=AssertionError("must not be called")):
            rc = mem.main(["warden-status", "--slot", "3"])
        self.assertEqual(rc, 0)


class TebCacheTest(unittest.TestCase):
    """resolve_object_manager's persistent cache (reports/l7): a candidate found once must not be
    rescanned on a later call for the same (pid, process start time), and a null mgr -- "not in world
    right now" -- must neither be cached as a failure nor trigger a rescan on its own."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.state_dir = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.tls = {"tls_index": 0, "s_curmgr_delta": 0}

    def test_second_call_uses_cache_without_rescanning(self):
        scans = []
        with unittest.mock.patch.object(mem, "find_teb64_candidates", side_effect=lambda *a, **k: scans.append(1)), \
             unittest.mock.patch.object(mem, "_proc_starttime", return_value=111), \
             unittest.mock.patch.object(mem, "_candidate_tls_arrays", return_value=[(0x200000, 0x300000)]), \
             unittest.mock.patch.object(mem, "_mgr_from_tls_array", return_value=0x400000):
            first = mem.resolve_object_manager(1234, self.tls, state_dir=self.state_dir)
            self.assertEqual(first["via"], "tls")
            self.assertTrue(mem._teb_cache_path(self.state_dir).exists())
            second = mem.resolve_object_manager(1234, self.tls, state_dir=self.state_dir)
        self.assertEqual(second["via"], "tls_cached")
        self.assertEqual(second["address"], 0x400000)
        self.assertEqual(len(scans), 1)

    def test_null_mgr_is_not_cached(self):
        with unittest.mock.patch.object(mem, "find_teb64_candidates", return_value=[0x200000]), \
             unittest.mock.patch.object(mem, "_proc_starttime", return_value=111), \
             unittest.mock.patch.object(mem, "_candidate_tls_arrays", return_value=[(0x200000, 0x300000)]), \
             unittest.mock.patch.object(mem, "_mgr_from_tls_array", return_value=0):
            with self.assertRaises(mem.MemoryError_):
                mem.resolve_object_manager(1234, self.tls, state_dir=self.state_dir)
        self.assertFalse(mem._teb_cache_path(self.state_dir).exists())

    def test_cached_candidate_mgr_null_raises_without_rescanning(self):
        mem._save_teb_cache(self.state_dir, 1234, 111, 0x200000, 0x300000)
        scans = []
        with unittest.mock.patch.object(mem, "find_teb64_candidates", side_effect=lambda *a, **k: scans.append(1)), \
             unittest.mock.patch.object(mem, "_proc_starttime", return_value=111), \
             unittest.mock.patch.object(mem, "_mgr_from_tls_array", return_value=0):
            with self.assertRaises(mem.MemoryError_):
                mem.resolve_object_manager(1234, self.tls, state_dir=self.state_dir)
        self.assertEqual(scans, [])

    def test_cache_for_different_starttime_is_ignored(self):
        mem._save_teb_cache(self.state_dir, 1234, 111, 0x200000, 0x300000)
        with unittest.mock.patch.object(mem, "find_teb64_candidates", return_value=[0x500000]), \
             unittest.mock.patch.object(mem, "_proc_starttime", return_value=222), \
             unittest.mock.patch.object(mem, "_candidate_tls_arrays", return_value=[(0x500000, 0x600000)]), \
             unittest.mock.patch.object(mem, "_mgr_from_tls_array", return_value=0x700000):
            result = mem.resolve_object_manager(1234, self.tls, state_dir=self.state_dir)
        self.assertEqual(result["teb64"], 0x500000)


class GlueMatchesTest(unittest.TestCase):
    def test_login_needs_the_login_screen(self):
        self.assertTrue(mem.glue_matches(
            {"current_screen": "login", "in_world": False, "characters": []}, "login"))
        self.assertFalse(mem.glue_matches(
            {"current_screen": "charselect", "in_world": False, "characters": []}, "login"))

    def test_charselect_requires_not_in_world(self):
        self.assertFalse(mem.glue_matches(
            {"current_screen": "charselect", "in_world": True, "characters": []}, "charselect"))
        self.assertTrue(mem.glue_matches(
            {"current_screen": "charselect", "in_world": False, "characters": []}, "charselect"))

    def test_charselect_loaded_requires_a_character_list(self):
        self.assertFalse(mem.glue_matches(
            {"current_screen": "charselect", "in_world": False, "characters": []}, "charselect-loaded"))
        self.assertTrue(mem.glue_matches(
            {"current_screen": "charselect", "in_world": False, "characters": ["Coalabone"]},
            "charselect-loaded"))

    def test_in_world_ignores_the_stale_screen_name(self):
        self.assertTrue(mem.glue_matches(
            {"current_screen": "charselect", "in_world": True, "characters": []}, "in-world"))

    def test_unknown_state_raises(self):
        with self.assertRaises(ValueError):
            mem.glue_matches({"current_screen": "login", "in_world": False, "characters": []}, "bogus")

    def test_login_clean_requires_no_recorded_failure(self):
        self.assertTrue(mem.glue_matches(
            {"current_screen": "login", "in_world": False, "characters": [], "login_state": -1},
            "login-clean"))
        self.assertFalse(mem.glue_matches(
            {"current_screen": "login", "in_world": False, "characters": [], "login_state": mem.LOGIN_STATE_FAILED},
            "login-clean"))
        self.assertFalse(mem.glue_matches(
            {"current_screen": "charselect", "in_world": False, "characters": [], "login_state": -1},
            "login-clean"))

    def test_login_settled_on_charselect_loaded_or_login_failed(self):
        self.assertTrue(mem.glue_matches(
            {"current_screen": "charselect", "in_world": False, "characters": ["Coalabone"],
             "login_state": 4}, "login-settled"))
        self.assertTrue(mem.glue_matches(
            {"current_screen": "login", "in_world": False, "characters": [],
             "login_state": mem.LOGIN_STATE_FAILED}, "login-settled"))
        self.assertFalse(mem.glue_matches(
            {"current_screen": "login", "in_world": False, "characters": [], "login_state": 3},
            "login-settled"))
        self.assertFalse(mem.glue_matches(
            {"current_screen": "charselect", "in_world": False, "characters": [], "login_state": 4},
            "login-settled"))


class GlueLoginStateTest(unittest.TestCase):
    """L11 (2026-10-27): m_loginResult/m_loginState/... fields, live-validated against
    WoW/Source/WowServices/Types.h's LOGIN_STATE/LOGIN_RESULT enums (see coa-lab-mem's own comment)."""

    def test_fresh_client_reads_minus_one(self):
        fake = FakeMemory()
        fake.write(mem.GLUE_CURRENT_SCREEN, b"login\x00".ljust(64, b"\x00"))
        fake.write_u32(mem.GLUE_SELECTION_INDEX, 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_ALLOC_OFF, 0)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_COUNT_OFF, 0)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_DATA_OFF, 0)
        fake.write_u32(mem.GLUE_LOGIN_RESULT, 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_LOGIN_STATE, 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_LAST_LOGIN_RESULT, 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_LAST_LOGIN_STATE, 0xFFFFFFFF)
        fake.write_u32(mem.GLUE_DISCONNECT_PENDING, 0)
        fake.write_u32(mem.GLUE_RECONNECT, 0)
        fake.write(mem.GLUE_ACCOUNT_NAME, b"\x00" * 1280)
        fake.write_u32(mem.GLUE_DISPLAYING_QUEUE_DIALOG, 0)
        fake.write_u32(mem.GLUE_SHOWED_DISCONNECT, 0)
        fake.write(mem.GLUE_SERVER_ALERT, b"\x00" * 2048)
        patch_memory(self, fake)
        with unittest.mock.patch.object(mem, "parse_tls_directory", side_effect=mem.MemoryError_("no tls")):
            result = mem.cmd_glue(None)
        self.assertEqual(result["login_state"], -1)
        self.assertEqual(result["login_result"], -1)
        self.assertEqual(result["login_result_name"], "-1")

    def test_disconnected_dialog_decodes_login_disconnected(self):
        # Live, slot 2, 2026-10-27: a duplicate-session disconnect during a login attempt read
        # login_state=5, login_result=21 on a confirmed "You have been disconnected from the server" dialog.
        fake = FakeMemory()
        fake.write(mem.GLUE_CURRENT_SCREEN, b"login\x00".ljust(64, b"\x00"))
        fake.write_u32(mem.GLUE_SELECTION_INDEX, 1)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_ALLOC_OFF, 0)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_COUNT_OFF, 0)
        fake.write_u32(mem.GLUE_CHARACTER_LIST + mem.GLUE_CHARLIST_DATA_OFF, 0)
        fake.write_u32(mem.GLUE_LOGIN_RESULT, 21)
        fake.write_u32(mem.GLUE_LOGIN_STATE, 5)
        fake.write_u32(mem.GLUE_LAST_LOGIN_RESULT, 21)
        fake.write_u32(mem.GLUE_LAST_LOGIN_STATE, 5)
        fake.write_u32(mem.GLUE_DISCONNECT_PENDING, 0)
        fake.write_u32(mem.GLUE_RECONNECT, 0)
        fake.write(mem.GLUE_ACCOUNT_NAME, b"\x00" * 1280)
        fake.write_u32(mem.GLUE_DISPLAYING_QUEUE_DIALOG, 0)
        fake.write_u32(mem.GLUE_SHOWED_DISCONNECT, 0)
        fake.write(mem.GLUE_SERVER_ALERT, b"\x00" * 2048)
        patch_memory(self, fake)
        with unittest.mock.patch.object(mem, "parse_tls_directory", side_effect=mem.MemoryError_("no tls")):
            result = mem.cmd_glue(None)
        self.assertEqual(result["login_state"], mem.LOGIN_STATE_FAILED)
        self.assertEqual(result["login_result_name"], "LOGIN_DISCONNECTED")
        self.assertFalse(mem.glue_matches(result, "login-clean"))
        self.assertTrue(mem.glue_matches(result, "login-settled"))


class PollGlueUntilTest(unittest.TestCase):
    def test_returns_as_soon_as_the_state_matches(self):
        statuses = iter([
            {"current_screen": "charselect", "in_world": False, "selection_index": 0, "characters": []},
            {"current_screen": "login", "in_world": False, "selection_index": -1, "characters": []},
        ])
        with unittest.mock.patch.object(mem, "cmd_glue", side_effect=lambda *a, **k: next(statuses)), \
             unittest.mock.patch.object(mem.time, "sleep"):
            result, matched = mem.poll_glue_until(1234, None, "login", timeout=5)
        self.assertTrue(matched)
        self.assertEqual(result["current_screen"], "login")

    def test_timeout_returns_the_last_status_unmatched(self):
        status = {"current_screen": "charselect", "in_world": False, "selection_index": 0, "characters": []}
        times = iter([0, 0, 10])
        with unittest.mock.patch.object(mem, "cmd_glue", return_value=status), \
             unittest.mock.patch.object(mem.time, "sleep"), \
             unittest.mock.patch.object(mem.time, "monotonic", side_effect=lambda: next(times)):
            result, matched = mem.poll_glue_until(1234, None, "login", timeout=5)
        self.assertFalse(matched)
        self.assertEqual(result, status)

    def test_in_world_wait_shares_one_scan_cache_across_ticks(self):
        statuses = [
            {"current_screen": "charselect", "in_world": False, "selection_index": 0, "characters": []},
            {"current_screen": "charselect", "in_world": True, "selection_index": 0, "characters": []},
        ]
        seen_scan_caches = []

        def fake_cmd_glue(pid, state_dir=None, need_world=True, scan_cache=None):
            seen_scan_caches.append(scan_cache)
            return statuses.pop(0)

        with unittest.mock.patch.object(mem, "cmd_glue", side_effect=fake_cmd_glue), \
             unittest.mock.patch.object(mem.time, "sleep"):
            mem.poll_glue_until(1234, None, "in-world", timeout=5)
        self.assertEqual(len(seen_scan_caches), 2)
        self.assertIsNotNone(seen_scan_caches[0])
        self.assertIs(seen_scan_caches[0], seen_scan_caches[1])

    def test_login_charselect_wait_passes_no_scan_cache(self):
        status = {"current_screen": "login", "in_world": False, "selection_index": -1, "characters": []}
        seen = []

        def fake_cmd_glue(pid, state_dir=None, need_world=True, scan_cache=None):
            seen.append(scan_cache)
            return status

        with unittest.mock.patch.object(mem, "cmd_glue", side_effect=fake_cmd_glue), \
             unittest.mock.patch.object(mem.time, "sleep"):
            mem.poll_glue_until(1234, None, "login", timeout=5)
        self.assertEqual(seen, [None])


if __name__ == "__main__":
    unittest.main()
