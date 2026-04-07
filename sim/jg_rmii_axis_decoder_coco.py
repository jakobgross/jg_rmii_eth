"""cocotb testbench for jg_rmii_axis_decoder.

This bench uses:
- Scapy to build Ethernet frame bytes.
- Python/zlib to append Ethernet FCS bytes.
- A custom RMII driver to serialize bytes into dibits on rmii_rxd/crs_dv.
- cocotbext-axi's AxiStreamSink to receive the DUT's AXI-Stream output.

The helpers are intentionally written so we can extend them with more RMII fault
injection later without rewriting the tests.
"""

from __future__ import annotations

import zlib
from dataclasses import dataclass, field
from typing import Dict, List, Sequence

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge, Timer, with_timeout

try:
    from cocotb.triggers import SimTimeoutError
except ImportError:
    from cocotb.result import SimTimeoutError

from cocotbext.axi import AxiStreamBus, AxiStreamSink


def _import_scapy_offline():
    """Import only the packet-building parts of Scapy without host net probing.

    Scapy's normal Linux import path reloads interfaces and routes eagerly.
    That is unnecessary for packet construction and breaks in sandboxed/CI
    environments that deny raw netlink socket access.
    """

    import scapy.interfaces

    scapy.interfaces.NetworkInterfaceDict.reload = lambda self: None
    scapy.interfaces.NetworkInterfaceDict.load_confiface = lambda self: None

    import scapy.arch

    scapy.arch.read_routes = lambda: []
    scapy.arch.read_routes6 = lambda: []
    scapy.arch.get_if_raw_addr = lambda iff: b"\x00\x00\x00\x00"
    scapy.arch.in6_getifaddr = lambda: []

    from scapy.compat import raw as scapy_raw
    from scapy.layers.inet import ICMP, IP, TCP, UDP
    from scapy.layers.l2 import Ether
    from scapy.packet import Raw

    return Ether, ICMP, IP, Raw, TCP, UDP, scapy_raw


Ether, ICMP, IP, Raw, TCP, UDP, raw = _import_scapy_offline()


C_CLK_PERIOD_NS = 20
C_AXIS_BYTE_LANES = 4


@dataclass
class RmiiConfig:
    """RMII-specific stimulus controls."""

    add_preamble: bool = True
    sfd_byte: int = 0xD5
    corrupt_crc: bool = False
    corrupt_bits: List[int] = field(default_factory=list)
    truncate_tail_dibits: int = 0
    idle_cycles_before: int = 0
    idle_cycles_after: int = 8
    force_last_dibit_crs_low: bool = True
    dibit_overrides: Dict[int, int] = field(default_factory=dict)
    crs_overrides: Dict[int, int] = field(default_factory=dict)


async def clock_gen(signal, period_ns: int) -> None:
    half_period = period_ns / 2
    while True:
        signal.value = 0
        await Timer(half_period, units="ns")
        signal.value = 1
        await Timer(half_period, units="ns")


async def reset_dut(dut) -> None:
    dut.resetn.value = 0
    dut.rmii_crs_dv.value = 0
    dut.rmii_rxd.value = 0
    await ClockCycles(dut.clk, 5)
    dut.resetn.value = 1
    await ClockCycles(dut.clk, 5)


def ethernet_fcs(frame_without_fcs: bytes) -> bytes:
    """Return the 4 FCS bytes as transmitted on Ethernet (little-endian CRC)."""

    crc = zlib.crc32(frame_without_fcs) & 0xFFFFFFFF
    return crc.to_bytes(4, byteorder="little")


def build_wire_bytes(frame_without_fcs: bytes, config: RmiiConfig) -> bytes:
    preamble = b""
    if config.add_preamble:
        preamble = (b"\x55" * 7) + bytes([config.sfd_byte])

    fcs = bytearray(ethernet_fcs(frame_without_fcs))
    if config.corrupt_crc:
        # Corrupt the first bit of the first FCS byte to force a bad CRC.
        fcs[0] ^= 0x01

    return preamble + frame_without_fcs + bytes(fcs)


def apply_bit_flips_to_bytes(data: bytes, bit_idxs: List[int]) -> bytes:
    mutable = bytearray(data)

    for bit_idx in bit_idxs:
        if bit_idx < 0 or bit_idx >= len(mutable) * 8:
            raise ValueError(
                f"Invalid bit index {bit_idx}, expected 0..{len(mutable) * 8 - 1}"
            )
        mutable[bit_idx // 8] ^= 1 << (bit_idx % 8)

    return bytes(mutable)


def bytes_to_rmii_dibits(data: bytes) -> List[int]:
    """Serialize bytes into RMII dibits, LSB dibit first."""

    dibits = []
    for byte in data:
        for shift in range(0, 8, 2):
            dibits.append((byte >> shift) & 0x3)
    return dibits


def build_rmii_stream(
    frame_without_fcs: bytes, config: RmiiConfig | None = None
) -> List[tuple[int, int]]:
    config = config or RmiiConfig()

    dibits = bytes_to_rmii_dibits(build_wire_bytes(frame_without_fcs, config))

    for bit_idx in config.corrupt_bits:
        if bit_idx < 0 or bit_idx >= len(dibits) * 2:
            raise ValueError(
                f"Invalid RMII bit index {bit_idx}, expected 0..{len(dibits) * 2 - 1}"
            )
        dibit_idx = bit_idx // 2
        bit_in_dibit = bit_idx % 2
        dibits[dibit_idx] ^= 1 << bit_in_dibit

    if config.truncate_tail_dibits:
        if config.truncate_tail_dibits >= len(dibits):
            raise ValueError("truncate_tail_dibits removes the whole stream")
        dibits = dibits[: -config.truncate_tail_dibits]

    stream = [(1, dibit) for dibit in dibits]

    for index, dibit in config.dibit_overrides.items():
        if 0 <= index < len(stream):
            crs, _ = stream[index]
            stream[index] = (crs, dibit & 0x3)

    for index, crs in config.crs_overrides.items():
        if 0 <= index < len(stream):
            _, dibit = stream[index]
            stream[index] = (1 if crs else 0, dibit)

    if (
        stream
        and config.force_last_dibit_crs_low
        and (len(stream) - 1) not in config.crs_overrides
    ):
        _, dibit = stream[-1]
        stream[-1] = (0, dibit)

    return stream


async def drive_rmii_stream(
    dut, stream: Sequence[tuple[int, int]], config: RmiiConfig | None = None
) -> None:
    config = config or RmiiConfig()

    dut.rmii_crs_dv.value = 0
    dut.rmii_rxd.value = 0

    for _ in range(config.idle_cycles_before):
        await RisingEdge(dut.clk)

    for crs_dv, dibit in stream:
        dut.rmii_crs_dv.value = crs_dv
        dut.rmii_rxd.value = dibit
        await RisingEdge(dut.clk)

    dut.rmii_crs_dv.value = 0
    dut.rmii_rxd.value = 0

    for _ in range(config.idle_cycles_after):
        await RisingEdge(dut.clk)


def make_axis_sink(dut) -> AxiStreamSink:
    return AxiStreamSink(
        AxiStreamBus.from_prefix(dut, "m_axis"),
        dut.clk,
        dut.resetn,
        reset_active_level=False,
    )


def normalize_sideband(value, count: int, default: int) -> List[int]:
    if value is None:
        return [default] * count
    if isinstance(value, int):
        return [value] * count
    items = list(value)
    if not items:
        return [default] * count
    if len(items) < count:
        items.extend([items[-1]] * (count - len(items)))
    return items[:count]


def axis_beats(frame) -> List[dict]:
    data = list(frame.tdata)
    tkeep = normalize_sideband(frame.tkeep, len(data), 1)
    tuser = normalize_sideband(frame.tuser, len(data), 0)

    beats = []
    for idx in range(0, len(data), C_AXIS_BYTE_LANES):
        beats.append(
            {
                "data": data[idx : idx + C_AXIS_BYTE_LANES],
                "tkeep": tkeep[idx : idx + C_AXIS_BYTE_LANES],
                "tuser": tuser[idx : idx + C_AXIS_BYTE_LANES],
            }
        )
    return beats


def valid_axis_bytes(frame) -> bytes:
    tkeep = normalize_sideband(frame.tkeep, len(frame.tdata), 1)
    return bytes(byte for byte, keep in zip(frame.tdata, tkeep) if keep)


def expected_last_keep(length_bytes: int) -> List[int]:
    valid_bytes = length_bytes % C_AXIS_BYTE_LANES
    if valid_bytes == 0:
        valid_bytes = C_AXIS_BYTE_LANES
    return [1 if idx < valid_bytes else 0 for idx in range(C_AXIS_BYTE_LANES)]


def expected_error_payload(frame_without_fcs: bytes) -> bytes:
    """Model current DUT behavior on CRC error: final output byte is zeroed."""

    if not frame_without_fcs:
        return b""
    return frame_without_fcs[:-1] + b"\x00"


def expected_frame_after_config(frame_without_fcs: bytes, config: RmiiConfig) -> bytes:
    """Model the payload bytes expected at the AXIS output for a given config."""

    if not config.corrupt_bits:
        return (
            frame_without_fcs
            if not config.corrupt_crc
            else expected_error_payload(frame_without_fcs)
        )

    wire_bytes = build_wire_bytes(frame_without_fcs, config)
    corrupted_wire_bytes = apply_bit_flips_to_bytes(wire_bytes, config.corrupt_bits)

    preamble_len = 8 if config.add_preamble else 0
    corrupted_frame = corrupted_wire_bytes[preamble_len:-4]
    return expected_error_payload(corrupted_frame)


def parse_ethernet_frame(frame_bytes: bytes):
    """Parse Ethernet bytes with Scapy for protocol-level checks."""

    return Ether(frame_bytes)


def raw_payload_bytes(packet) -> bytes:
    """Return the Raw payload bytes if present, else empty bytes."""

    if packet.haslayer(Raw):
        return bytes(packet[Raw].load)
    return b""


def protocol_name(packet) -> str:
    if packet.haslayer(UDP):
        return "UDP"
    if packet.haslayer(TCP):
        return "TCP"
    if packet.haslayer(ICMP):
        return "ICMP"
    return packet.lastlayer().name


def check_protocol_payloads(observed_payload: bytes, expected_payload: bytes) -> None:
    observed_pkt = parse_ethernet_frame(observed_payload)
    expected_pkt = parse_ethernet_frame(expected_payload)

    assert protocol_name(observed_pkt) == protocol_name(expected_pkt), (
        f"Protocol mismatch: got {protocol_name(observed_pkt)}, "
        f"expected {protocol_name(expected_pkt)}"
    )

    assert raw_payload_bytes(observed_pkt) == raw_payload_bytes(expected_pkt), (
        f"Protocol payload mismatch\n"
        f"got      {raw_payload_bytes(observed_pkt)!r}\n"
        f"expected {raw_payload_bytes(expected_pkt)!r}"
    )


def check_axis_frame(frame, expected_payload: bytes, expected_tuser_last: int) -> None:
    beats = axis_beats(frame)
    observed_payload = valid_axis_bytes(frame)

    assert observed_payload == expected_payload, (
        f"AXIS payload mismatch\n"
        f"got      {observed_payload.hex()}\n"
        f"expected {expected_payload.hex()}"
    )

    check_protocol_payloads(observed_payload, expected_payload)

    assert beats, "Expected at least one AXIS beat"

    for beat in beats[:-1]:
        assert beat["tkeep"] == [
            1,
            1,
            1,
            1,
        ], f"Non-final beat had partial tkeep: {beat['tkeep']}"
        assert all(
            user == 0 for user in beat["tuser"]
        ), f"Non-final beat had tuser asserted: {beat['tuser']}"

    last = beats[-1]
    assert last["tkeep"] == expected_last_keep(len(expected_payload)), (
        f"Last-beat tkeep mismatch: got {last['tkeep']}, "
        f"expected {expected_last_keep(len(expected_payload))}"
    )
    assert all(
        user == expected_tuser_last for user in last["tuser"]
    ), f"Last-beat tuser mismatch: got {last['tuser']}, expected all {expected_tuser_last}"


async def recv_axis_frame(axis_sink: AxiStreamSink, timeout_ns: int = 20_000):
    return await with_timeout(axis_sink.recv(compact=False), timeout_ns, "ns")


async def run_protocol_frame_test(
    dut, frame, config: RmiiConfig | None = None, expected_tuser_last: int = 0
) -> None:
    axis_sink = make_axis_sink(dut)
    await reset_dut(dut)

    frame_bytes = raw(frame)
    config = config or RmiiConfig()
    expected_payload = (
        frame_bytes
        if expected_tuser_last == 0
        else expected_frame_after_config(frame_bytes, config)
    )

    await drive_rmii_stream(dut, build_rmii_stream(frame_bytes, config), config)
    rx_frame = await recv_axis_frame(axis_sink)

    check_axis_frame(
        rx_frame, expected_payload, expected_tuser_last=expected_tuser_last
    )


@cocotb.test()
async def test_good_header_only_frame(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))
    frame = Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
    await run_protocol_frame_test(dut, frame)


@cocotb.test()
async def test_good_udp_payload_roundtrip(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="192.168.1.10", dst="192.168.1.20")
        / UDP(sport=1234, dport=5678)
        / Raw(b"udp-roundtrip-ok")
    )
    await run_protocol_frame_test(dut, frame)


@cocotb.test()
async def test_bad_udp_payload_roundtrip(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="192.168.1.10", dst="192.168.1.20")
        / UDP(sport=1234, dport=5678)
        / Raw(b"udp-roundtrip-bad")
    )
    await run_protocol_frame_test(
        dut, frame, config=RmiiConfig(corrupt_crc=True), expected_tuser_last=1
    )


@cocotb.test()
async def test_good_tcp_payload_roundtrip(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="10.1.1.1", dst="10.1.1.2")
        / TCP(sport=4000, dport=80, seq=100, ack=50, flags="PA")
        / Raw(b"tcp-roundtrip-ok")
    )
    await run_protocol_frame_test(dut, frame)


@cocotb.test()
async def test_bad_tcp_payload_roundtrip(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="10.1.1.1", dst="10.1.1.2")
        / TCP(sport=4000, dport=80, seq=100, ack=50, flags="PA")
        / Raw(b"tcp-roundtrip-bad")
    )
    await run_protocol_frame_test(
        dut, frame, config=RmiiConfig(corrupt_crc=True), expected_tuser_last=1
    )


@cocotb.test()
async def test_good_icmp_payload_roundtrip(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="172.16.0.1", dst="172.16.0.2")
        / ICMP(type=8, code=0)
        / Raw(b"icmp-roundtrip-ok")
    )
    await run_protocol_frame_test(dut, frame)


@cocotb.test()
async def test_bad_icmp_payload_roundtrip(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="172.16.0.1", dst="172.16.0.2")
        / ICMP(type=8, code=0)
        / Raw(b"icmp-roundtrip-bad")
    )
    await run_protocol_frame_test(
        dut, frame, config=RmiiConfig(corrupt_crc=True), expected_tuser_last=1
    )


@cocotb.test()
async def test_single_rmii_bit_corruption_udp_payload(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="192.168.2.10", dst="192.168.2.20")
        / UDP(sport=1111, dport=2222)
        / Raw(b"udp-single-bit")
    )
    # Flip one payload bit after preamble/SFD, header, and UDP header.
    config = RmiiConfig(corrupt_bits=[(8 + 14 + 20 + 8) * 8 + 3])
    await run_protocol_frame_test(dut, frame, config=config, expected_tuser_last=1)


@cocotb.test()
async def test_multi_rmii_bit_corruption_udp_payload(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="192.168.3.10", dst="192.168.3.20")
        / UDP(sport=3333, dport=4444)
        / Raw(b"udp-multi-bit")
    )
    # Flip several bits across the UDP payload while keeping frame detection intact.
    config = RmiiConfig(
        corrupt_bits=[
            (8 + 14 + 20 + 8) * 8 + 0,
            (8 + 14 + 20 + 8) * 8 + 11,
            (8 + 14 + 20 + 8 + 2) * 8 + 5,
        ]
    )
    await run_protocol_frame_test(dut, frame, config=config, expected_tuser_last=1)


@cocotb.test()
async def test_bad_crc_sets_tuser(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="192.168.1.10", dst="192.168.1.20")
        / UDP(sport=1234, dport=5678)
        / Raw(b"cocotb-rmii-crc")
    )
    await run_protocol_frame_test(
        dut, frame, config=RmiiConfig(corrupt_crc=True), expected_tuser_last=1
    )


@cocotb.test()
async def test_bad_sfd_produces_no_axis_frame(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))
    axis_sink = make_axis_sink(dut)
    await reset_dut(dut)

    frame = Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800) / Raw(
        b"bad-sfd"
    )
    frame_bytes = raw(frame)
    config = RmiiConfig(sfd_byte=0xD4)

    await drive_rmii_stream(dut, build_rmii_stream(frame_bytes, config), config)

    try:
        await with_timeout(axis_sink.recv(compact=False), 5_000, "ns")
    except SimTimeoutError:
        pass
    else:
        raise AssertionError("Unexpected AXI frame received after invalid SFD")


@cocotb.test()
async def test_backpressure_increments_words_dropped(dut):
    cocotb.start_soon(clock_gen(dut.clk, C_CLK_PERIOD_NS))
    axis_sink = make_axis_sink(dut)
    await reset_dut(dut)

    frame = (
        Ether(dst="da:da:da:da:da:da", src="bb:bb:bb:bb:bb:bb", type=0x0800)
        / IP(src="10.0.0.1", dst="10.0.0.2")
        / UDP(sport=1000, dport=2000)
        / Raw(b"backpressure-check-" * 4)
    )
    frame_bytes = raw(frame)

    axis_sink.pause = True
    await drive_rmii_stream(dut, build_rmii_stream(frame_bytes))
    await ClockCycles(dut.clk, 200)

    dropped = int(dut.words_dropped_o.value)
    assert dropped > 0, f"Expected words_dropped_o > 0, got {dropped}"

    axis_sink.pause = False
    await ClockCycles(dut.clk, 50)
