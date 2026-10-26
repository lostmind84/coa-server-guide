"""Tests for scripts/coa-lab-packets. Run: python3 -m unittest discover -s scripts/tests -p 'test_*.py'"""
import importlib.machinery
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "coa-lab-packets"
loader = importlib.machinery.SourceFileLoader("coa_lab_packets", str(SCRIPT))
spec = importlib.util.spec_from_loader("coa_lab_packets", loader)
pkt = importlib.util.module_from_spec(spec)
loader.exec_module(pkt)

OPCODES_TEXT = """
enum Opcodes : uint16
{
    SMSG_AURA_UPDATE_ALL                            = 0x495,
    SMSG_AURA_UPDATE                                = 0x496,
    CMSG_PING                                       = 0x1DC,
    SMSG_SPELL_START                                = 0x131,
    NUM_MSG_TYPES                                   = 0x700
};
"""


def pack_guid(guid: int) -> bytes:
    mask = 0
    body = b""
    for i in range(8):
        byte = (guid >> (8 * i)) & 0xFF
        if byte:
            mask |= 1 << i
            body += bytes([byte])
    return bytes([mask]) + body


def build_log_header(sniff_start_unixtime=1_700_000_000, sniff_start_ticks=1000):
    return struct.pack(pkt.LOG_HEADER_FORMAT, b"PKT", 0x0301, ord("T"), 12340, b"enUS", b"\x00" * 40,
                       sniff_start_unixtime, sniff_start_ticks, 0)


def build_packet(opcode, payload, direction=pkt.DIRECTION_TAG_SERVER_TO_CLIENT, arrival_ticks=1000):
    header = struct.pack(pkt.PACKET_HEADER_FORMAT, direction, 0, arrival_ticks, 20, len(payload) + 4,
                         b"\x7f\x00\x00\x01" + b"\x00" * 12, 7978, opcode)
    return header + payload


class PacketLogReadTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.file_path = Path(self.tmp.name) / "lab-world.pkt"

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, *packets):
        self.file_path.write_bytes(build_log_header() + b"".join(packets))

    def test_reads_header_and_packets_in_order(self):
        self.write(
            build_packet(0x1DC, b"\x01\x02\x03\x04", direction=pkt.DIRECTION_TAG_CLIENT_TO_SERVER,
                        arrival_ticks=1000),
            build_packet(0x131, b"\xaa\xbb", arrival_ticks=1500),
        )
        records = list(pkt.read_packets(self.file_path))
        self.assertEqual(len(records), 2)
        index0, header0, payload0, log_header = records[0]
        self.assertEqual(index0, 0)
        self.assertEqual(header0["opcode"], 0x1DC)
        self.assertEqual(header0["direction"], pkt.DIRECTION_TAG_CLIENT_TO_SERVER)
        self.assertEqual(payload0, b"\x01\x02\x03\x04")
        self.assertEqual(log_header["sniff_start_unixtime"], 1_700_000_000)
        index1, header1, payload1, _ = records[1]
        self.assertEqual(index1, 1)
        self.assertEqual(header1["opcode"], 0x131)
        self.assertEqual(payload1, b"\xaa\xbb")

    def test_tolerates_truncated_last_packet_header(self):
        full = build_packet(0x131, b"\xaa\xbb")
        self.file_path.write_bytes(build_log_header() + full + b"\x01\x02\x03")  # 3 of 44 header bytes
        records = list(pkt.read_packets(self.file_path))
        self.assertEqual(len(records), 1)

    def test_tolerates_truncated_last_packet_payload(self):
        full = build_packet(0x131, b"\xaa\xbb\xcc\xdd")
        truncated = full[:-2]  # header complete, only 2 of 4 payload bytes written
        self.file_path.write_bytes(build_log_header() + truncated)
        records = list(pkt.read_packets(self.file_path))
        self.assertEqual(len(records), 0)

    def test_rejects_non_pkt_file(self):
        self.file_path.write_bytes(b"not a packet log" + b"\x00" * 64)
        with self.assertRaises(pkt.PacketLogError):
            list(pkt.read_packets(self.file_path))

    def test_packet_time_anchored_to_sniff_start(self):
        self.write(build_packet(0x131, b"", arrival_ticks=1000 + 2500))
        _, header, _, log_header = next(pkt.read_packets(self.file_path))
        when = pkt.packet_time(header, log_header)
        self.assertEqual(when.timestamp(), 1_700_000_000 + 2.5)

    def test_direction_tag_decoding(self):
        self.write(
            build_packet(0x131, b"", direction=pkt.DIRECTION_TAG_SERVER_TO_CLIENT),
            build_packet(0x1DC, b"", direction=pkt.DIRECTION_TAG_CLIENT_TO_SERVER),
        )
        records = [pkt.packet_record(i, h, p, lh, {}) for i, h, p, lh in pkt.read_packets(self.file_path)]
        self.assertEqual(records[0]["direction"], "s2c")
        self.assertEqual(records[1]["direction"], "c2s")


class OpcodeNamesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.opcodes_path = Path(self.tmp.name) / "Opcodes.h"
        self.opcodes_path.write_text(OPCODES_TEXT)

    def tearDown(self):
        self.tmp.cleanup()

    def test_parses_hex_enumerators_only(self):
        names = pkt.load_opcode_names(self.opcodes_path)
        self.assertEqual(names[0x496], "SMSG_AURA_UPDATE")
        self.assertEqual(names[0x495], "SMSG_AURA_UPDATE_ALL")
        self.assertNotIn(0x700, names)  # NUM_MSG_TYPES is not a CMSG_/SMSG_ opcode

    def test_resolve_opcode_filters_by_name_and_number(self):
        names = pkt.load_opcode_names(self.opcodes_path)
        self.assertEqual(pkt.resolve_opcode_filters(["SMSG_AURA_UPDATE"], names), {0x496})
        self.assertEqual(pkt.resolve_opcode_filters(["0x495"], names), {0x495})
        self.assertEqual(pkt.resolve_opcode_filters(["302"], names), {0x12E})
        with self.assertRaises(pkt.PacketLogError):
            pkt.resolve_opcode_filters(["SMSG_NOT_A_REAL_OPCODE"], names)


class PackedGuidTest(unittest.TestCase):
    def test_round_trips_sparse_guid(self):
        guid = 0x00000001_0C000123
        reader = pkt.PayloadReader(pack_guid(guid))
        self.assertEqual(reader.read_packed_guid(), guid)

    def test_round_trips_zero_guid(self):
        reader = pkt.PayloadReader(pack_guid(0))
        self.assertEqual(reader.read_packed_guid(), 0)


class AuraDecodeTest(unittest.TestCase):
    def test_decodes_removed_slot(self):
        payload = bytes([3]) + struct.pack("<I", 0)
        reader = pkt.PayloadReader(payload)
        record = pkt.decode_aura_application(reader)
        self.assertEqual(record, {"slot": 3, "removed": True})

    def test_decodes_full_record_with_caster_and_duration(self):
        caster_guid = 0x0000000000000F00
        payload = (
            bytes([5]) + struct.pack("<I", 12345) + bytes([pkt.AFLAG_POSITIVE | pkt.AFLAG_DURATION, 80, 1])
            + pack_guid(caster_guid) + struct.pack("<II", 20000, 15000)
        )
        reader = pkt.PayloadReader(payload)
        record = pkt.decode_aura_application(reader)
        self.assertEqual(record["slot"], 5)
        self.assertEqual(record["spell_id"], 12345)
        self.assertEqual(set(record["flag_names"]), {"POSITIVE", "DURATION"})
        self.assertEqual(record["level"], 80)
        self.assertEqual(record["stack_or_charges"], 1)
        self.assertEqual(record["caster_guid"], f"0x{caster_guid:016X}")
        self.assertEqual(record["max_duration"], 20000)
        self.assertEqual(record["duration"], 15000)

    def test_self_cast_omits_caster_guid(self):
        payload = bytes([0]) + struct.pack("<I", 999) + bytes([pkt.AFLAG_CASTER, 1, 1])
        reader = pkt.PayloadReader(payload)
        record = pkt.decode_aura_application(reader)
        self.assertNotIn("caster_guid", record)
        self.assertEqual(record["flag_names"], ["CASTER"])

    def test_decode_aura_update_single_slot(self):
        target_guid = 0x0000000000001234
        aura_payload = bytes([2]) + struct.pack("<I", 111) + bytes([pkt.AFLAG_CASTER, 1, 1])
        payload = pack_guid(target_guid) + aura_payload
        decoded = pkt.decode_aura_packet(pkt.SMSG_AURA_UPDATE_NAME, payload)
        self.assertEqual(decoded["target_guid"], f"0x{target_guid:016X}")
        self.assertEqual(len(decoded["auras"]), 1)
        self.assertEqual(decoded["auras"][0]["spell_id"], 111)

    def test_decode_aura_update_all_multiple_slots(self):
        target_guid = 0x0000000000005678
        first = bytes([0]) + struct.pack("<I", 100) + bytes([pkt.AFLAG_CASTER, 60, 1])
        second = bytes([1]) + struct.pack("<I", 200) + bytes([pkt.AFLAG_CASTER, 60, 3])
        payload = pack_guid(target_guid) + first + second
        decoded = pkt.decode_aura_packet(pkt.SMSG_AURA_UPDATE_ALL_NAME, payload)
        self.assertEqual(decoded["target_guid"], f"0x{target_guid:016X}")
        self.assertEqual([a["spell_id"] for a in decoded["auras"]], [100, 200])


class FilterTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.file_path = Path(self.tmp.name) / "lab-world.pkt"
        self.file_path.write_bytes(build_log_header() + b"".join([
            build_packet(0x131, b"", direction=pkt.DIRECTION_TAG_SERVER_TO_CLIENT, arrival_ticks=1000),
            build_packet(0x1DC, b"", direction=pkt.DIRECTION_TAG_CLIENT_TO_SERVER, arrival_ticks=2000),
            build_packet(0x496, b"", direction=pkt.DIRECTION_TAG_SERVER_TO_CLIENT, arrival_ticks=3000),
        ]))

    def tearDown(self):
        self.tmp.cleanup()

    def test_after_index_filter(self):
        records = list(pkt.iter_filtered_packets(self.file_path, after_index=0))
        self.assertEqual([r[0] for r in records], [1, 2])

    def test_direction_filter(self):
        records = list(pkt.iter_filtered_packets(self.file_path, direction="c2s"))
        self.assertEqual([r[0] for r in records], [1])

    def test_opcode_filter(self):
        records = list(pkt.iter_filtered_packets(self.file_path, opcode_numbers={0x496}))
        self.assertEqual([r[0] for r in records], [2])


class DefaultFileResolutionTest(unittest.TestCase):
    def test_default_file_for_slot(self):
        path = pkt.default_file_for_slot(2)
        self.assertTrue(str(path).endswith("CoaServer/slots/s2/logs/lab-world.pkt"))


if __name__ == "__main__":
    unittest.main()
