# jg_rmii_eth

LAN8720 MDIO controller and RMII-to-AXI-Stream decoder for Xilinx Zynq-7000, packaged as Vivado IPs. Includes frame detection and CRC-32 checking. Example project targets the Digilent Zybo Z7-20.

## Status

### jg_lan8720_mdio

- [x] MDIO controller (`jg_mdio_ctrl`)
- [x] MDIO controller testbench
- [x] LAN8720 readback module (`jg_lan8720_readback`)
- [x] LAN8720 bring-up state machine (`jg_lan8720_ctrl`)
- [x] LAN8720 ctrl testbench
- [ ] VUnit simulation flow
- [ ] Formal verification (SymbiYosys)
- [ ] Packaged as Vivado IP

### jg_rmii_axis_decoder

- [x] RMII dibit aligner and byte packer (`jg_rmii_to_bytes`)
- [x] `jg_rmii_to_bytes` testbench (8 edge case tests)
- [x] CRC-32 engine and FCS stripper (`jg_eth_crc`)
- [x] 32-bit AXI-Stream word builder (`jg_rmii_axis_decoder`)
- [x] `jg_rmii_axis_decoder` testbench (good frame, bad CRC, back-pressure, stress)
- [ ] VUnit simulation flow
- [ ] Formal verification — `jg_rmii_to_bytes`
- [ ] Formal verification — `jg_eth_crc`
- [ ] Formal verification — `jg_rmii_axis_decoder` (AXI-Stream PSL properties)
- [ ] Packaged as Vivado IP

### Example Project

- [ ] Vivado block design (TCL script)
- [ ] Vitis bare-metal application
- [ ] Running on hardware: MDIO polling over UART
- [ ] Running on hardware: AXI DMA scatter-gather frame capture over UART

---

## Hardware Setup

### Components

- Digilent Zybo Z7-20
- Waveshare LAN8720 ETH Board

### Wiring — LAN8720 to PMOD JE

The Waveshare LAN8720 board is connected **upside down** to PMOD JE so that the RJ45 connector faces away from the board and the module sits flush without mechanical interference.

| PMOD JE Pin | Package Pin | Signal      | Direction | LAN8720 Pin          |
| ----------- | ----------- | ----------- | --------- | -------------------- |
| JE2         | W16         | RXD[1]      | In        | RXD1                 |
| JE3         | J15         | CRS_DV      | In        | CRS_DV               |
| JE4         | H15         | MDC         | Out       | MDC                  |
| JE8         | U17         | RXD[0]      | In        | RXD0                 |
| JE9         | T17         | nINT/REFCLK | In        | nINT/REFCLK (50 MHz) |
| JE10        | Y17         | MDIO        | Bidir     | MDIO                 |

**PHY SMI address: 1** — The Waveshare board pulls RXER/PHYAD0 high via a resistor to VCC, setting the PHY address to 1 (not the default 0).

**MODE[2:0] = 111** — RXD0, RXD1 and CRS_DV are pulled high internally, enabling auto-negotiation. No BCR write required.

### Linux Test Machine

Any Linux machine with a spare Ethernet port connected directly to the Zybo LAN8720 via a straight-through cable. Auto-MDIX handles polarity automatically. No switch or router required. The interface must not be managed by NetworkManager during testing.

```sh
# Bring up the interface without IP assignment
ip link set eth0 up

# Send a test frame with Scapy
python3 -c "
from scapy.all import *
sendp(Ether(dst='ff:ff:ff:ff:ff:ff')/IP(dst='255.255.255.255')/UDP()/b'hello', iface='eth0')
"
```

---

## Repository Structure

```
jg_rmii_eth/
├── jg_lan8720_mdio_1.0/          Vivado IP: MDIO controller + LAN8720 bring-up
│   ├── component.xml
│   ├── xgui/
│   └── hdl/
├── jg_rmii_axis_decoder_1.0/     Vivado IP: RMII-to-AXI-Stream decoder
│   ├── component.xml
│   ├── xgui/
│   └── hdl/
├── sim/                          Testbenches (Vivado / VUnit)
├── formal/                       SymbiYosys proofs and PSL properties
├── example/
│   ├── constraints/              XDC pin assignments for Zybo Z7-20
│   ├── vivado/                   Block design TCL script (project gitignored)
│   ├── vitis/                    Vitis workspace TCL script (workspace gitignored)
│   └── sw/
│       └── src/                  Bare-metal C application sources
├── Makefile
├── LICENSE
└── README.md
```

---

## Documentation

- [LAN8720A/LAN8720Ai Datasheet](https://ww1.microchip.com/downloads/en/DeviceDoc/en557323.pdf) — Small Footprint RMII 10/100 Ethernet Transceiver with HP Auto-MDIX Support, SMSC
- [Waveshare LAN8720 ETH Board Schematic](https://www.waveshare.com/w/upload/0/08/LAN8720-ETH-Board-Schematic.pdf) — Board schematic showing RXER/PHYAD0 pull-up to VCC and MODE strap connections
- Ethernet: Reduced Media Independent Interface (RMII) specification Rev 1.2

---

## License

Apache 2.0 — see [LICENSE](LICENSE).