/*
 * main.c - jg_rmii_eth example application
 *
 * Demonstrates:
 *   - LAN8720 PHY register readback via jg_mdio_axi
 *   - Raw Ethernet frame capture via AXI DMA scatter-gather (S2MM only)
 *   - LED status indication via GPIO
 *   - Words-dropped counter readback via GPIO
 *
 * Peripherals:
 *   DMA        0x40400000  AXI DMA (scatter-gather, S2MM only)
 *   GPIO0      0x41200000  4-bit LED output
 *   GPIO1      0x41210000  16-bit words_dropped input
 *   MDIO_AXI   0x43C00000  jg_mdio_axi (PHY addr 1, addr[6:2] = reg index)
 *
 * Main loop:
 *   - Poll DMA for completed frames, print bytes and TUSER status over UART
 *   - Read MDIO BSR every second, print on change
 *
 * LED mapping:
 *   LED[0]  PHY link up (BSR bit 2)
 *   LED[1]  Frame received (toggles per frame)
 *   LED[2]  CRC error seen (TUSER = 1 on last beat)
 *   LED[3]  Words dropped > 0
 */

#include <stdio.h>
#include <string.h>
#include "xaxidma.h"
#include "xaxidma_bd.h"
#include "xparameters.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xtime_l.h"

/* ---------------------------------------------------------------------------
 * Hardware addresses
 * ---------------------------------------------------------------------------*/
#define DMA_BASE_ADDR       0x40400000
#define GPIO0_BASE_ADDR     0x41200000  /* 4-bit LED output */
#define GPIO1_BASE_ADDR     0x41210000  /* 16-bit words_dropped input */
#define MDIO_AXI_BASE_ADDR  0x43C00000

/* GPIO register offsets (AXI GPIO) */
#define GPIO_DATA_OFFSET    0x0000
#define GPIO_TRI_OFFSET     0x0004

/* MDIO AXI: address bits [6:2] select MDIO register 0-31 */
#define MDIO_REG_ADDR(n)    (MDIO_AXI_BASE_ADDR + ((n) << 2))

/* LAN8720 MDIO register indices */
#define MDIO_REG_BSR        1   /* Basic Status Register */
#define MDIO_REG_ID1        2   /* PHY Identifier 1 */
#define MDIO_REG_ID2        3   /* PHY Identifier 2 */
#define MDIO_REG_PSCSR      31  /* PHY Special Control/Status */

/* BSR bit masks */
#define BSR_LINK_UP         (1 << 2)
#define BSR_AN_COMPLETE     (1 << 5)

/* ---------------------------------------------------------------------------
 * DMA configuration
 * ---------------------------------------------------------------------------*/
#define NUM_BDS             4
#define MAX_FRAME_LEN       1520  /* 1518 rounded up to 4-byte boundary */

/*
 * BD ring memory: XAxiDma_BdRingMemCalc(align, count) gives the exact size.
 * We use a safe static buffer: XAXIDMA_BD_MINIMUM_ALIGNMENT bytes per BD
 * plus one extra for alignment padding.
 */
#define BD_RING_BYTES  ((NUM_BDS + 1) * XAXIDMA_BD_MINIMUM_ALIGNMENT)

/*
 * BD ring and frame buffers must be in non-cached memory or explicitly
 * flushed/invalidated. We use __attribute__((aligned)) and call
 * Xil_DCacheFlushRange / Xil_DCacheInvalidateRange explicitly.
 */
static u8 bd_ring_mem[BD_RING_BYTES]
    __attribute__((aligned(XAXIDMA_BD_MINIMUM_ALIGNMENT)));

static u8 rx_bufs[NUM_BDS][MAX_FRAME_LEN]
    __attribute__((aligned(32)));

/* DMA driver instance */
static XAxiDma dma;

/* ---------------------------------------------------------------------------
 * GPIO helpers
 * ---------------------------------------------------------------------------*/
static void leds_set(u8 val)
{
    Xil_Out32(GPIO0_BASE_ADDR + GPIO_DATA_OFFSET, (u32)(val & 0x0F));
}

static u16 words_dropped_read(void)
{
    return (u16)(Xil_In32(GPIO1_BASE_ADDR + GPIO_DATA_OFFSET) & 0xFFFF);
}

/* ---------------------------------------------------------------------------
 * MDIO helper — read a PHY register via jg_mdio_axi
 * AXI read to offset (reg << 2) triggers an MDIO read transaction.
 * jg_mdio_axi stalls the AXI bus until the MDIO transaction completes.
 * ---------------------------------------------------------------------------*/
static u16 mdio_read(u32 reg)
{
    return (u16)(Xil_In32(MDIO_REG_ADDR(reg)) & 0xFFFF);
}

/* ---------------------------------------------------------------------------
 * Print PHY identity — called once at startup only
 * ---------------------------------------------------------------------------*/
static void print_phy_identity(void)
{
    u16 id1   = mdio_read(MDIO_REG_ID1);
    u16 id2   = mdio_read(MDIO_REG_ID2);
    xil_printf("\r\n=== LAN8720 PHY ===\r\n");
    xil_printf("  ID1=0x%04X  ID2=0x%04X\r\n", id1, id2);
}

/* ---------------------------------------------------------------------------
 * Print BSR + PSCSR status — called on BSR change only
 * ---------------------------------------------------------------------------*/
static void print_phy_status(u16 bsr)
{
    u16 pscsr = mdio_read(MDIO_REG_PSCSR);
    xil_printf("  BSR=0x%04X  Link=%s  AN=%s\r\n",
               bsr,
               (bsr & BSR_LINK_UP)     ? "UP"       : "DOWN",
               (bsr & BSR_AN_COMPLETE) ? "complete" : "pending");
    xil_printf("  PSCSR=0x%04X\r\n", pscsr);
}

/* ---------------------------------------------------------------------------
 * DMA RX ring setup
 * ---------------------------------------------------------------------------*/
static int dma_rx_setup(void)
{
    XAxiDma_BdRing *rx_ring;
    XAxiDma_Bd      bd_template;
    XAxiDma_Bd     *bd_ptr;
    XAxiDma_Bd     *bd_cur;
    int             status;
    int             i;

    rx_ring = XAxiDma_GetRxRing(&dma);

    /* Polling mode: disable all RX interrupts */
    XAxiDma_BdRingIntDisable(rx_ring, XAXIDMA_IRQ_ALL_MASK);

    /* Coalesce after every 1 frame, no delay timer */
    XAxiDma_BdRingSetCoalesce(rx_ring, 1, 0);

    /*
     * Create the BD ring in bd_ring_mem.
     * Both physical and virtual addresses are the same in standalone mode.
     */
    status = XAxiDma_BdRingCreate(rx_ring,
                                  (UINTPTR)bd_ring_mem,
                                  (UINTPTR)bd_ring_mem,
                                  XAXIDMA_BD_MINIMUM_ALIGNMENT,
                                  NUM_BDS);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: BdRingCreate failed %d\r\n", status);
        return XST_FAILURE;
    }

    /* Clone a zeroed BD template across all ring entries */
    XAxiDma_BdClear(&bd_template);
    status = XAxiDma_BdRingClone(rx_ring, &bd_template);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: BdRingClone failed %d\r\n", status);
        return XST_FAILURE;
    }

    /* Allocate all BDs at once from the free pool */
    status = XAxiDma_BdRingAlloc(rx_ring, NUM_BDS, &bd_ptr);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: BdRingAlloc failed %d\r\n", status);
        return XST_FAILURE;
    }

    /* Configure each BD: point at a frame buffer, set max receive length */
    bd_cur = bd_ptr;
    for (i = 0; i < NUM_BDS; i++) {
        status = XAxiDma_BdSetBufAddr(bd_cur, (UINTPTR)rx_bufs[i]);
        if (status != XST_SUCCESS) {
            xil_printf("ERROR: BdSetBufAddr[%d] failed %d\r\n", i, status);
            return XST_FAILURE;
        }
        status = XAxiDma_BdSetLength(bd_cur, MAX_FRAME_LEN,
                                     rx_ring->MaxTransferLen);
        if (status != XST_SUCCESS) {
            xil_printf("ERROR: BdSetLength[%d] failed %d\r\n", i, status);
            return XST_FAILURE;
        }
        /* No TX control flags needed for S2MM receive */
        XAxiDma_BdSetCtrl(bd_cur, 0);

        /* Store buffer index in the BD ID field for later retrieval */
        XAxiDma_BdSetId(bd_cur, (UINTPTR)i);

        bd_cur = (XAxiDma_Bd *)XAxiDma_BdRingNext(rx_ring, bd_cur);
    }

    /* Flush BD ring to DDR before handing ownership to hardware */
    Xil_DCacheFlushRange((UINTPTR)bd_ring_mem, BD_RING_BYTES);

    /* Hand BDs to hardware and start the ring */
    status = XAxiDma_BdRingToHw(rx_ring, NUM_BDS, bd_ptr);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: BdRingToHw failed %d\r\n", status);
        return XST_FAILURE;
    }

    status = XAxiDma_BdRingStart(rx_ring);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: BdRingStart failed %d\r\n", status);
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

/* ---------------------------------------------------------------------------
 * Protocol decoder
 * ---------------------------------------------------------------------------*/

/* EtherType values */
#define ETHERTYPE_IPV4  0x0800
#define ETHERTYPE_ARP   0x0806
#define ETHERTYPE_IPV6  0x86DD

/* IP protocol numbers */
#define IP_PROTO_ICMP   1
#define IP_PROTO_TCP    6
#define IP_PROTO_UDP    17
#define IP_PROTO_ICMPv6 58

static void print_hex_ascii(const u8 *data, int len)
{
    int i;
    for (i = 0; i < len; i++) {
        xil_printf("%02X ", data[i]);
        if ((i + 1) % 16 == 0) {
            xil_printf("  ");
            for (int j = i - 15; j <= i; j++)
                xil_printf("%c", (data[j] >= 0x20 && data[j] < 0x7F) ? data[j] : '.');
            xil_printf("\r\n");
        }
    }
    /* Print remaining partial line */
    if (len % 16 != 0) {
        int rem = len % 16;
        for (i = 0; i < (16 - rem); i++) xil_printf("   ");
        xil_printf("  ");
        for (i = len - rem; i < len; i++)
            xil_printf("%c", (data[i] >= 0x20 && data[i] < 0x7F) ? data[i] : '.');
        xil_printf("\r\n");
    }
}

static void decode_frame(const u8 *buf, int len, int tuser)
{
    u16 ethertype;
    const u8 *payload;
    int payload_len;

    if (len < 14) {
        xil_printf("[RUNT frame %d bytes]\r\n", len);
        return;
    }

    /* Ethernet header */
    xil_printf("ETH  DST=%02X:%02X:%02X:%02X:%02X:%02X  "
               "SRC=%02X:%02X:%02X:%02X:%02X:%02X  ",
               buf[0], buf[1], buf[2], buf[3], buf[4],  buf[5],
               buf[6], buf[7], buf[8], buf[9], buf[10], buf[11]);

    ethertype = ((u16)buf[12] << 8) | buf[13];
    payload     = buf + 14;
    payload_len = len - 14;

    /* -----------------------------------------------------------------------
     * IPv4
     * -----------------------------------------------------------------------*/
    if (ethertype == ETHERTYPE_IPV4) {
        u8  ihl, proto, ttl;
        u16 total_len, src_port, dst_port;
        const u8 *ip_payload;
        int ip_payload_len;

        if (payload_len < 20) { xil_printf("IPv4 [truncated]\r\n"); return; }

        ihl       = (payload[0] & 0x0F) * 4;
        total_len = ((u16)payload[2] << 8) | payload[3];
        ttl       = payload[8];
        proto     = payload[9];

        xil_printf("IPv4\r\n");
        xil_printf("     SRC=%d.%d.%d.%d  DST=%d.%d.%d.%d  TTL=%d  ",
                   payload[12], payload[13], payload[14], payload[15],
                   payload[16], payload[17], payload[18], payload[19],
                   ttl);

        ip_payload     = payload + ihl;
        ip_payload_len = total_len - ihl;
        if (ip_payload_len < 0) ip_payload_len = 0;

        if (proto == IP_PROTO_UDP && ip_payload_len >= 8) {
            src_port = ((u16)ip_payload[0] << 8) | ip_payload[1];
            dst_port = ((u16)ip_payload[2] << 8) | ip_payload[3];
            xil_printf("UDP  SRC_PORT=%d  DST_PORT=%d\r\n", src_port, dst_port);
            /* UDP payload */
            if (ip_payload_len > 8) {
                xil_printf("     Payload %d bytes:\r\n", ip_payload_len - 8);
                print_hex_ascii(ip_payload + 8, ip_payload_len - 8);
            }
        } else if (proto == IP_PROTO_TCP && ip_payload_len >= 20) {
            src_port = ((u16)ip_payload[0] << 8) | ip_payload[1];
            dst_port = ((u16)ip_payload[2] << 8) | ip_payload[3];
            xil_printf("TCP  SRC_PORT=%d  DST_PORT=%d\r\n", src_port, dst_port);
        } else if (proto == IP_PROTO_ICMP) {
            xil_printf("ICMP  type=%d  code=%d\r\n",
                       ip_payload[0], ip_payload[1]);
        } else {
            xil_printf("IP_PROTO=0x%02X\r\n", proto);
        }

    /* -----------------------------------------------------------------------
     * ARP
     * -----------------------------------------------------------------------*/
    } else if (ethertype == ETHERTYPE_ARP) {
        xil_printf("ARP\r\n");
        if (payload_len >= 28) {
            u16 op = ((u16)payload[6] << 8) | payload[7];
            xil_printf("     %s  SPA=%d.%d.%d.%d  TPA=%d.%d.%d.%d\r\n",
                       (op == 1) ? "REQUEST" : "REPLY",
                       payload[14], payload[15], payload[16], payload[17],
                       payload[24], payload[25], payload[26], payload[27]);
        }

    /* -----------------------------------------------------------------------
     * IPv6
     * -----------------------------------------------------------------------*/
    } else if (ethertype == ETHERTYPE_IPV6) {
        u8  proto;
        u16 src_port, dst_port;
        const u8 *ip_payload;

        xil_printf("IPv6\r\n");
        if (payload_len < 40) return;

        proto      = payload[6];
        ip_payload = payload + 40;

        xil_printf("     SRC=%02X%02X:%02X%02X:%02X%02X:%02X%02X:"
                       "%02X%02X:%02X%02X:%02X%02X:%02X%02X\r\n",
                   payload[8],  payload[9],  payload[10], payload[11],
                   payload[12], payload[13], payload[14], payload[15],
                   payload[16], payload[17], payload[18], payload[19],
                   payload[20], payload[21], payload[22], payload[23]);
        xil_printf("     DST=%02X%02X:%02X%02X:%02X%02X:%02X%02X:"
                       "%02X%02X:%02X%02X:%02X%02X:%02X%02X\r\n",
                   payload[24], payload[25], payload[26], payload[27],
                   payload[28], payload[29], payload[30], payload[31],
                   payload[32], payload[33], payload[34], payload[35],
                   payload[36], payload[37], payload[38], payload[39]);

        if (proto == IP_PROTO_UDP && (payload_len - 40) >= 8) {
            src_port = ((u16)ip_payload[0] << 8) | ip_payload[1];
            dst_port = ((u16)ip_payload[2] << 8) | ip_payload[3];
            xil_printf("     UDP  SRC_PORT=%d  DST_PORT=%d\r\n",
                       src_port, dst_port);
        } else if (proto == IP_PROTO_ICMPv6) {
            xil_printf("     ICMPv6  type=%d  code=%d\r\n",
                       ip_payload[0], ip_payload[1]);
        } else if (proto == IP_PROTO_TCP) {
            src_port = ((u16)ip_payload[0] << 8) | ip_payload[1];
            dst_port = ((u16)ip_payload[2] << 8) | ip_payload[3];
            xil_printf("     TCP  SRC_PORT=%d  DST_PORT=%d\r\n",
                       src_port, dst_port);
        } else {
            xil_printf("     PROTO=0x%02X\r\n", proto);
        }

    /* -----------------------------------------------------------------------
     * Unknown EtherType — print raw hex+ascii
     * -----------------------------------------------------------------------*/
    } else {
        xil_printf("EtherType=0x%04X\r\n", ethertype);
        print_hex_ascii(payload, payload_len);
    }

    if (tuser)
        xil_printf("     [CRC ERROR]\r\n");
}

/* ---------------------------------------------------------------------------
 * Poll for completed frames, decode and print, resubmit BDs
 * ---------------------------------------------------------------------------*/
static u8 led_val      = 0;
static u8 frame_toggle = 0;

static void dma_poll(void)
{
    XAxiDma_BdRing *rx_ring;
    XAxiDma_Bd     *bd_ptr;
    XAxiDma_Bd     *bd_cur;
    int             bd_count;
    int             i;
    u32             bd_sts;
    u32             tuser;
    int             frame_len;
    u8             *buf;
    int             buf_idx;
    int             status;

    rx_ring = XAxiDma_GetRxRing(&dma);

    /* Invalidate BD ring cache before reading status */
    Xil_DCacheInvalidateRange((UINTPTR)bd_ring_mem, BD_RING_BYTES);

    bd_count = XAxiDma_BdRingFromHw(rx_ring, NUM_BDS, &bd_ptr);
    if (bd_count <= 0)
        return;

    bd_cur = bd_ptr;
    for (i = 0; i < bd_count; i++) {
        bd_sts   = XAxiDma_BdGetSts(bd_cur);
        tuser    = XAxiDma_BdGetTUser(bd_cur);
        frame_len = (int)XAxiDma_BdGetActualLength(bd_cur,
                                                   rx_ring->MaxTransferLen);
        buf_idx  = (int)(UINTPTR)XAxiDma_BdGetId(bd_cur);
        buf      = rx_bufs[buf_idx];

        /* Invalidate frame buffer cache before reading received data */
        Xil_DCacheInvalidateRange((UINTPTR)buf, MAX_FRAME_LEN);

        /* Check for DMA errors (distinct from TUSER frame errors) */
        if (bd_sts & XAXIDMA_BD_STS_ALL_ERR_MASK) {
            xil_printf("ERROR: DMA error on BD %d, sts=0x%08X\r\n",
                       i, bd_sts);
        }

        xil_printf("\r\n--- Frame %d bytes  TUSER=%d ---\r\n",
                   frame_len, tuser ? 1 : 0);

        decode_frame(buf, frame_len, (int)tuser);

        /* Update LED state */
        frame_toggle ^= 1;
        if (frame_toggle)
            led_val |=  (1 << 1);
        else
            led_val &= ~(1 << 1);

        if (tuser)
            led_val |=  (1 << 2);   /* CRC error */
        else
            led_val &= ~(1 << 2);

        bd_cur = (XAxiDma_Bd *)XAxiDma_BdRingNext(rx_ring, bd_cur);
    }

    /* Return completed BDs to the free pool */
    XAxiDma_BdRingFree(rx_ring, bd_count, bd_ptr);

    /* Reallocate and resubmit the same number of BDs */
    status = XAxiDma_BdRingAlloc(rx_ring, bd_count, &bd_ptr);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: BdRingAlloc (resubmit) failed %d\r\n", status);
        return;
    }

    bd_cur = bd_ptr;
    for (i = 0; i < bd_count; i++) {
        buf_idx = (int)(UINTPTR)XAxiDma_BdGetId(bd_cur);
        XAxiDma_BdSetBufAddr(bd_cur, (UINTPTR)rx_bufs[buf_idx]);
        XAxiDma_BdSetLength(bd_cur, MAX_FRAME_LEN, rx_ring->MaxTransferLen);
        XAxiDma_BdSetCtrl(bd_cur, 0);
        bd_cur = (XAxiDma_Bd *)XAxiDma_BdRingNext(rx_ring, bd_cur);
    }

    Xil_DCacheFlushRange((UINTPTR)bd_ring_mem, BD_RING_BYTES);

    status = XAxiDma_BdRingToHw(rx_ring, bd_count, bd_ptr);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: BdRingToHw (resubmit) failed %d\r\n", status);
    }
}

/* ---------------------------------------------------------------------------
 * main
 * ---------------------------------------------------------------------------*/
int main(void)
{
    XAxiDma_Config *dma_cfg;
    int             status;
    XTime           last_mdio_time = 0;
    XTime           now;
    u16             last_bsr   = 0xFFFF;  /* force print on first poll */
    u16             bsr;
    u16             last_dropped = 0;
    u16             dropped;

    xil_printf("\r\n=== jg_rmii_eth example ===\r\n");

    /* GPIO0: all outputs */
    Xil_Out32(GPIO0_BASE_ADDR + GPIO_TRI_OFFSET, 0x00);
    leds_set(0x00);

    /* DMA initialisation */
    dma_cfg = XAxiDma_LookupConfig(XPAR_AXIDMA_0_DEVICE_ID);
    if (!dma_cfg) {
        xil_printf("ERROR: DMA config lookup failed\r\n");
        return XST_FAILURE;
    }

    status = XAxiDma_CfgInitialize(&dma, dma_cfg);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA init failed %d\r\n", status);
        return XST_FAILURE;
    }

    if (!XAxiDma_HasSg(&dma)) {
        xil_printf("ERROR: DMA not configured in scatter-gather mode\r\n");
        return XST_FAILURE;
    }

    /* Disable interrupts — polling only */
    XAxiDma_IntrDisable(&dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);

    /* Setup S2MM receive ring */
    status = dma_rx_setup();
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: DMA RX setup failed\r\n");
        return XST_FAILURE;
    }

    xil_printf("DMA ready. Waiting for frames...\r\n");

    /* Print PHY identity once at startup */
    print_phy_identity();

    /* Seed last_bsr and print initial link status */
    last_bsr = mdio_read(MDIO_REG_BSR);
    print_phy_status(last_bsr);
    XTime_GetTime(&last_mdio_time);

    /* -----------------------------------------------------------------------
     * Main loop
     * -----------------------------------------------------------------------*/
    while (1) {

        /* Poll DMA for completed receive frames */
        dma_poll();

        /* Update LED[3]: words dropped */
        dropped = words_dropped_read();
        if (dropped > 0)
            led_val |=  (1 << 3);
        else
            led_val &= ~(1 << 3);

        /* Poll MDIO BSR every second, print on change */
        XTime_GetTime(&now);
        if ((now - last_mdio_time) >= COUNTS_PER_SECOND) {
            last_mdio_time = now;

            bsr = mdio_read(MDIO_REG_BSR);

            /* Update LED[0]: link status */
            if (bsr & BSR_LINK_UP)
                led_val |=  (1 << 0);
            else
                led_val &= ~(1 << 0);

            if (bsr != last_bsr) {
                last_bsr = bsr;
                print_phy_status(bsr);

                if (dropped != last_dropped) {
                    last_dropped = dropped;
                    xil_printf("  words_dropped=%u\r\n", dropped);
                }
            }
        }

        leds_set(led_val);
    }

    return 0;
}