# Exchangine — Architecture Document

## Table of Contents
1. [Project Overview](#1-project-overview)
2. [System Architecture](#2-system-architecture)
3. [Memory Hierarchy](#3-memory-hierarchy)
4. [Module Descriptions](#4-module-descriptions)
5. [Data Types and Package](#5-data-types-and-package)
6. [Challenges and Race Conditions](#6-challenges-and-race-conditions)
7. [Design Choices](#7-design-choices)
8. [Current Implementation Status](#8-current-implementation-status)
9. [Remaining Plan](#9-remaining-plan)

---

## 1. Project Overview

Exchangine is an FPGA-based price-time priority limit order book engine implemented in synthesizable SystemVerilog. It targets the AMD Virtex UltraScale+ VU47P (AWS F2 FPGA instance) and is designed to demonstrate RTL discipline and domain understanding relevant to high-frequency trading exchange infrastructure.

**Key design goals:**
- Deterministic, synthesizable RTL — no dynamic memory, no unbounded loops
- Realistic memory hierarchy modeled after FPGA primitives (registers, BRAM, HBM)
- Price-time priority matching with linked-list per-level order FIFOs
- Correct handling of concurrent operations and race conditions between pipeline stages

---

## 2. System Architecture

### Pipeline Overview

```
AXI-Stream In (64-bit order messages)
        │
        ▼
┌───────────────────┐
│   msg_decoder     │  Combinational — 64-bit word → order_msg_t struct
└────────┬──────────┘
         │ order_msg_t + msg_valid/msg_ready
         ▼
┌───────────────────┐
│  level_manager    │
│                   │
│  Owns:            │
│  - L1 registers   │──────── op_out/op_valid/op_ready ──────►┐
│  - L1 bitmaps     │                                         │
│  - L2 HBM         │         (operation buffer FIFO          │
│  - L2 bitmap      │          in order_book.sv parent)       │
│  - Free list FIFO │                                         ▼
│  - Taker counter  │                              ┌───────────────────┐
└───────────────────┘                              │   order_pool      │
         ▲                                         │                   │
         │  pool_update_valid + pool_update_t      │  Owns:            │
         └──────────────────────────────────────── │  - BRAM (L3)      │
              pool_update (writeback)              │  - Op state mach  │
                                                   └─────────┬─────────┘
                                                             │
                                              exec_out / ack_out
                                                             │
                                                             ▼
                                                   AXI-Stream Out
```

### Top-Level Module: `order_book.sv`

Instantiates and connects:
- `msg_decoder` → `level_manager` → operation buffer FIFO → `order_pool`
- Operation buffer FIFO lives in `order_book.sv` (not inside either module)
- Output FIFOs for `execution_t` and `ack_t`

### Order ID Namespaces

Two separate namespaces:
- **Maker order IDs** — assigned by `level_manager`, index pool slots in BRAM, persist until order is fully consumed or cancelled
- **Taker order IDs** — assigned by a wrapping counter in `level_manager`, ephemeral, never stored in pool

Maker ID allocation uses a two-phase scheme:
- **Phase 1:** Simple counter from 1 to `NUM_ORDERS-1` — no free list overhead at startup (0 is reserved for NULL_PTR)
- **Phase 2:** After counter exhausts, pop from free list FIFO — IDs recycled via `pool_update`

---

## 3. Memory Hierarchy

| Layer | Contents | Implementation | Read Latency |
|---|---|---|---|
| L1 | Top `L1_DEPTH` price levels per side | Registers | 0 cycles (combinational) |
| L1 bitmap | Valid bits for L1 window | `logic [L1_DEPTH-1:0]` registers per side | 0 cycles |
| L2 | Full `2^PRICE_WIDTH` price level array | HBM (`hbm_model.sv`) | `READ_LATENCY` cycles |
| L2 bitmap | Valid bits for all price levels | `logic [L1_DEPTH-1:0]` register array, `L2_DEPTH/L1_DEPTH` chunks | 0 cycles (register array) |
| Order pool | Per-order resting order data | BRAM (`bram_model.sv`) | 1 cycle |

### L1 Circular Buffer

L1 is implemented as a circular buffer — a fixed register array with a `head_idx` pointer tracking which slot holds the current best price. This avoids shifting all entries on window slide — only the pointer moves.

```
bid_l1_head_idx — array index of current best bid
ask_l1_head_idx — array index of current best ask

array_idx = (head_idx + offset) % L1_DEPTH
offset = bid_head - price  (bid side)
offset = price - ask_head  (ask side)
```

### L2 Bitmap Structure

```systemverilog
localparam int L2_DEPTH = 2 ** PRICE_WIDTH;  // 65536 at default
logic [L1_DEPTH-1:0] l2_bitmap [0:(L2_DEPTH/L1_DEPTH)-1];  // 1024 chunks of 64 bits

// Coarse reduction — purely combinational
logic [(L2_DEPTH/L1_DEPTH)-1:0] l2_bitmap_coarse;
always_comb begin
    for (int i = 0; i < (L2_DEPTH/L1_DEPTH); i++)
        l2_bitmap_coarse[i] = |l2_bitmap[i];
end
```

Single bit updates are one cycle — no read-modify-write needed. Priority encoding uses two-level hierarchical search (coarse then fine).

### L2 Write Policy

**Write-back:** L1 is the authoritative copy. L2 is updated when:
- A price level is evicted from L1 during window slide
- A new resting order needs to be added to an out-of-window price level
- A pool_update arrives for an out-of-window price level

### HBM Port Assignment (in `level_manager`)

| Port | Purpose |
|---|---|
| Port A (burst) | L1 window slide — simultaneous burst write (eviction) and burst read (fetch) |
| Port B (regular read + byte-enable write) | Out-of-window MSG_ADD — read-modify-write for `total_qty` and `tail_order_id` |
| Port C (regular read + byte-enable write) | Pool update handling — byte-enable write for `head_order_id`, full write for `PU_CANCEL` |

### BRAM Port Assignment (in `order_pool`)

| Port | Purpose |
|---|---|
| Port A read | All reads during CANCEL_EXEC and MATCH_EXEC walks |
| Port A write | OP_ADD new slot write, OP_CANCEL qty zeroing |
| Port B byte-enable write | OP_ADD `next_order_id` link update, OP_MATCH slot invalidation and qty update |

---

## 4. Module Descriptions

### `ob_pkg.sv`
Package containing all shared types, parameters, and localparams. No module declaration.

### `msg_decoder.sv`
Pure combinational decode of 64-bit AXI-Stream word into `order_msg_t`. No clock or reset.

### `level_manager.sv`
Core order book management module. Owns L1, L2, free list, and taker counter. Processes incoming messages and dispatches operations to `order_pool`.

**Internal state machine:**
```
LM_READY          — accepting new messages
LM_CANCEL_WAIT    — stalled, waiting for PU_CANCEL pool_update
LM_L2_WAIT        — stalled, waiting for Port B L2 read (out-of-window MSG_ADD)
LM_L2_CANCEL_WAIT — stalled, waiting for Port C L2 read (PU_CANCEL out-of-window)
LM_SLIDE          — window sliding, one slot per cycle
LM_DRAIN_SLIDE_BUF— draining buffered pool_updates deferred during slide
```

### `order_pool.sv`
Owns resting order BRAM (via `bram_model`). Processes operations from `level_manager` via valid/ready handshake. Generates `execution_t`, `ack_t`, and `pool_update_t` outputs.

**Internal state machine:**
```
IDLE         — ready for next operation
CANCEL_EXEC  — waiting for BRAM read response (OP_CANCEL)
MATCH_EXEC   — walking linked list, waiting for BRAM read response per hop
```

### `fifo.sv`
Generic synchronous circular FIFO parameterized by type `T` and depth. Used for operation buffer, free list, slide buffer, and output queues. Depth must be power of 2.

### `bram_model.sv`
Behavioral model of true dual-port BRAM. Port A: shared address bus, read or write per cycle. Port B: byte-enable write only. `READ_LATENCY` parameterized (default 1). Storage as `T mem[0:DEPTH-1]`.

### `hbm_model.sv`
Behavioral model of HBM with three independent port sets and parameterized read latency (default 10). Port A: burst read/write. Ports B and C: regular read + byte-enable write. Non-overlapping simultaneous Port B and Port C writes to same address are merged.

### `order_book.sv`
Top-level module. Wires all submodules, instantiates operation buffer FIFO, output FIFOs for `execution_t` and `ack_t`.

---

## 5. Data Types and Package

### Parameters

| Name | Type | Default | Derived From |
|---|---|---|---|
| `PRICE_WIDTH` | `parameter int` | 16 | — |
| `QTY_WIDTH` | `parameter int` | 16 | — |
| `ORDER_ID_WIDTH` | `parameter int` | 8 | Must be multiple of 8 |
| `L1_DEPTH` | `parameter int` | 64 | Must be power of 2 |
| `OP_BUFFER_DEPTH` | `parameter int` | 8 | Must be power of 2 |
| `NUM_ORDERS` | `localparam int` | 256 | `2**ORDER_ID_WIDTH` |
| `L2_DEPTH` | `localparam int` | 65536 | `2 ** PRICE_WIDTH` |
| `NULL_PTR` | `localparam logic [ORDER_ID_WIDTH-1:0]` | 8'h00 | — |

### Key Types

```systemverilog
typedef enum logic [1:0] { MSG_ADD=2'b00, MSG_CANCEL=2'b01, MSG_MARKET=2'b10 } msg_type_t;
typedef enum logic        { SIDE_BID=1'b0, SIDE_ASK=1'b1 } side_t;

typedef struct packed {
    msg_type_t                 msg_type;
    side_t                     side;
    logic [PRICE_WIDTH-1:0]    price;      // don't-care for CANCEL, MARKET
    logic [QTY_WIDTH-1:0]      qty;        // don't-care for CANCEL
    logic [ORDER_ID_WIDTH-1:0] order_id;   // don't-care for ADD, MARKET
} order_msg_t;

typedef struct packed {
    logic [QTY_WIDTH-1:0]      total_qty;
    logic [ORDER_ID_WIDTH-1:0] tail_order_id;
    logic [ORDER_ID_WIDTH-1:0] head_order_id;  // LSBs — HBM Port C byte-enable target
} price_level_t;

typedef struct packed {
    // MSBs — padding added for byte alignment
    logic                      valid;
    side_t                     side;
    logic [PRICE_WIDTH-1:0]    price;
    logic [QTY_WIDTH-1:0]      qty;
    logic [ORDER_ID_WIDTH-1:0] next_order_id;  // LSBs — BRAM Port B byte-enable target
                                               // NULL_PTR = tail indicator
} resting_order_t;

typedef struct packed {
    logic [ORDER_ID_WIDTH-1:0] maker_id;
    logic [ORDER_ID_WIDTH-1:0] taker_id;
    logic [QTY_WIDTH-1:0]      fill_qty;
    logic [PRICE_WIDTH-1:0]    fill_price;
    side_t                     maker_side;
} execution_t;

typedef struct packed {
    logic [ORDER_ID_WIDTH-1:0] order_id;
    logic                      accepted;
    msg_type_t                 msg_type;
    logic [QTY_WIDTH-1:0]      remaining_qty;
} ack_t;

typedef enum logic [2:0] {
    OP_ADD         = 3'b000,
    OP_MATCH       = 3'b001,
    OP_CANCEL      = 3'b010,
    OP_MARKET_FAIL = 3'b011,
    OP_ADD_FAIL    = 3'b100,
    OP_ADD_FIRST   = 3'b101
} op_type_t;

typedef struct packed {
    op_type_t                    op_type;
    logic [ORDER_ID_WIDTH-1:0]   order_id;   // OP_ADD: new slot index; OP_CANCEL: slot to zero; OP_MATCH: taker_id; OP_MARKET_FAIL: don't-care
    logic [QTY_WIDTH-1:0]        qty;        // OP_ADD: qty of new order; OP_MATCH: incoming qty; OP_CANCEL: don't-care; OP_MARKET_FAIL: wasted remainder
    logic [ORDER_ID_WIDTH-1:0]   list_ptr;   // OP_ADD: tail slot; OP_MATCH: head slot to walk; OP_CANCEL: don't-care; OP_MARKET_FAIL: don't-care
    logic [PRICE_WIDTH-1:0]      fill_price; // OP_ADD: price of new order; OP_MATCH: fill price; OP_CANCEL: don't-care; OP_MARKET_FAIL: don't-care
    side_t                       maker_side; // OP_ADD: side of new order; OP_MATCH: maker side for execution_t; OP_CANCEL: don't-care; OP_MARKET_FAIL: don't-care
    // OP_ADD_FAIL and OP_ADD_FIRST are same as OP_ADD except for OP_ADD_FAIL a taker order_id is used and list_ptr is don't-care
} pool_op_t;

typedef enum logic [1:0] {
    PU_CANCEL = 2'b00,  // decrement total_qty
    PU_FREE   = 2'b01,  // push freed_order_id to free list
    PU_HEAD   = 2'b10,  // update head pointer
    PU_BOTH   = 2'b11   // free slot + update head pointer
} pool_update_type_t;

typedef struct packed {
    pool_update_type_t         update_type;
    logic [PRICE_WIDTH-1:0]    price;
    side_t                     side;
    logic [ORDER_ID_WIDTH-1:0] head_order_id;   // PU_HEAD, PU_BOTH
    logic [ORDER_ID_WIDTH-1:0] freed_order_id;  // PU_FREE, PU_BOTH
    logic [QTY_WIDTH-1:0]      qty;             // PU_CANCEL
} pool_update_t;
```

### Struct Layout Constraints

- `resting_order_t`: `next_order_id` at LSBs — BRAM Port B byte-enable target. Padding at MSBs for byte alignment. Assert `RESTING_ORDER_PAD != 0` in `order_book.sv`.
- `price_level_t`: `head_order_id` at LSBs — HBM Port C byte-enable target. Assert `$bits(price_level_t) % 8 == 0` in `order_book.sv`.

---

## 6. Challenges and Race Conditions

### 6.1 CANCEL Metadata Problem
**Problem:** A `MSG_CANCEL` arrives with only `order_id`. To update `total_qty` in L1/L2, `level_manager` needs `price`, `side`, and current `qty` — none of which it has without looking up the order.

**Solution:** `level_manager` stalls on CANCEL (enters `LM_CANCEL_WAIT`), issues `OP_CANCEL` to `order_pool`. Order_pool reads the BRAM slot, gets `{price, side, qty}`, zeroes `qty` (keeps `valid=1` to preserve chain), sends `PU_CANCEL` writeback. Level_manager updates `total_qty` then resumes. Since level_manager stalls, no new operations can race with the cancel.

### 6.2 CANCEL Race with Concurrent MATCH
**Problem:** If a MATCH is walking the FIFO and a CANCEL arrives for an order the walk hasn't reached yet, two problems arise: (a) the cancelled order still has non-zero qty visible to the walker, (b) `total_qty` in L1/L2 may be incorrectly decremented.

**Solution:** Level_manager stalls all incoming messages during `LM_CANCEL_WAIT`. The operation buffer serializes CANCEL and MATCH — they cannot overlap. When the walker encounters a `qty=0` slot (cancelled), it skips it naturally. No concurrent operations possible.

### 6.3 Out-of-Window MSG_ADD Race with Pool Update
**Problem:** An MSG_ADD targets a price level outside the L1 window. Level_manager issues a Port B read to L2. While the read is in flight, a `pool_update` arrives and updates `head_order_id` of the same price level via Port C. When the Port B write-back arrives, it would overwrite the updated `head_order_id` with the stale read value.

**Solution:** Port B write uses byte-enable masking to write only `total_qty` and `tail_order_id` bytes, never touching `head_order_id` bytes. `head_order_id` sits at the LSBs of `price_level_t` — its bytes are excluded from the Port B byte-enable mask. Simultaneously, Port C byte-enable writes only the `head_order_id` bytes. The HBM model supports merging non-overlapping simultaneous Port B and Port C writes to the same address.

### 6.4 Stale Head Pointer After MATCH
**Problem:** `order_pool` walks the linked list and frees slots. It sends `pool_update` to update the head pointer in `level_manager`. If a second MATCH arrives at `level_manager` before the `pool_update` is received, it uses the stale head pointer — pointing to an already-freed slot.

**Solution:** Freed slots retain `valid=0` but their `next_order_id` pointer remains intact. The walker skips `valid=0` slots silently (no pool_update, no free list push) and continues to the next slot. The chain remains navigable through freed slots.

### 6.5 Tail Detection in MATCH Walk
**Problem:** How does `order_pool` know when it has reached the tail of the linked list?

**Solution:** Reserving an order id value for `NULL_PTR`: New resting orders set `next_order_id = NULL_PTR`. The tail is detected when `a_rd_data.next_order_id == NULL_PTR`.

### 6.6 OP_ADD Two-Write Problem
**Problem:** Adding a new resting order requires two BRAM writes: (1) write the new slot at `order_id`, (2) update the previous tail's `next_order_id` to link the new order. Two writes to different addresses in one cycle on a single-port BRAM is impossible.

**Solution:** True dual-port BRAM. Port A writes the new slot (full write). Port B writes only the `next_order_id` bytes of the previous tail slot using byte-enable. Both happen in the same cycle to different addresses — no conflict.

### 6.7 Pool Update During Window Slide
**Problem:** During `LM_SLIDE`, price levels are in transition — being evicted to L2 or fetched from L2. A `pool_update` arriving for an in-transit price level could corrupt the transition if applied immediately.

**Solution:** Combination of immediate processing and buffering:
- `PU_FREE`: always processed immediately — only pushes to free list, no memory write
- `PU_HEAD`/`PU_BOTH` for prices **outside** transition range: processed immediately
- `PU_HEAD`/`PU_BOTH` for prices **inside** transition range: buffered in `slide_buf` FIFO
- `PU_CANCEL`: cannot arrive during `LM_SLIDE` — level_manager stalls before entering slide on any cancel. Assertion enforces this.

After `LM_SLIDE` completes, `LM_DRAIN_SLIDE_BUF` state processes buffered updates one per cycle before returning to `LM_READY`.

**Transition range** (both always active during any slide of k levels):
- Eviction range: k slots being written back to L2
- Fetch range: k slots being read from L2

### 6.8 Simultaneous Port B and Port C Writes to Same L2 Address
**Problem:** An out-of-window MSG_ADD (Port B) and a pool_update head update (Port C) can target the same L2 address in the same cycle. Standard write priority would drop one write, corrupting the price level.

**Solution:** `hbm_model` detects simultaneous Port B and Port C writes to the same address with non-overlapping byte enables and merges them into a single write. Port B writes `total_qty`/`tail_order_id` bytes; Port C writes `head_order_id` bytes — these are guaranteed non-overlapping by the `price_level_t` layout.

### 6.9 L2 Bitmap Byte-Enable Problem
**Problem:** Storing the L2 bitmap in BRAM would require a read-modify-write cycle to update a single bit — adding latency and complexity for the most frequent operation (updating valid bits on every match/cancel/slide).

**Solution:** Store L2 bitmap as a register array partitioned into `L1_DEPTH`-bit chunks. Single bit updates are one cycle with no read needed. A coarse reduction bitmap (`l2_bitmap_coarse`) is computed purely combinationally for fast chunk-level priority encoding.

### 6.10 Stale Head Pointer After Sweeping Match with Concurrent Add
**Problem:** When a match operation sweeps all orders from a price level X, the `order_pool` sends multiple `pool_update` messages to update the head pointer (eventually setting it to NULL_PTR). If, before all these head updates are processed by `level_manager`, a new order is added to the same price level X, it becomes the new head. If another match then arrives for X, it might use the old head pointer from before the sweep, which points to the old (now invalid) FIFO chain.

**Solution:** Connect the tail of the old FIFO to the head of the new FIFO. This is done by setting the `next_order_id` of the previous tail (if any) to the new order's ID, ensuring the linked list remains contiguous even if head updates are delayed. To be able to have the old head, we need to keep the heads and tails valid and consistent between L1 and L2, even if their curresponing valid bits of the price levels are cleared (aka total_qty=0).

### 6.11 Race Condition on NULL_PTR Head Update with Delayed Attachment
**Problem:** Similar to 6.10, but if a new match arrives for price level X after the pool_updates have updated the head to NULL_PTR, and the new FIFO head has not yet attached itself to the old FIFO tail. Even if we set the head pointer of price level X to the new FIFO head, the pool_update will write over it.

**Solution:** Introduce a distinct `OP_ADD_FIRST` operation that sends a `pool_update` to update the head of the price level X. If a match reads NULL_PTR as head, and the price level is valid (total_qty > 0), then it means the mentioned pool_update is on its way and we need to stall until it arrives.

### 6.12 Distinguishing First-Ever ADD from Post-Sweep ADD
**Problem:** When `OP_ADD_FIRST` processes on price level X, we want to attach the tail of the old sweeped FIFO to the new FIFO head (as per 6.10). However, if this is the first-ever order added to price level X (never had any orders before), there is no old tail to link. Writing to an uninitialized tail pointer in L2 could corrupt an unrelated price level's FIFO. We need to distinguish between these two cases without adding extra metadata to each price level.

**Solution:** Pre-initialize all price levels in L2 (and by extension, L1 at startup) with `tail_order_id = NULL_PTR`. The initialization sequence writes every L2 price level's `tail_order_id` field to `NULL_PTR` via HBM writes. This is a one-time startup cost. Now, when `OP_ADD_FIRST` occurs:
- If the price level has never had orders: `tail_order_id == NULL_PTR` (from initialization)
- If the price level is post-sweep: `tail_order_id == NULL_PTR` (from pool_update that cleared the head during sweep)

In both cases, `tail_order_id` is a safe, known value. When order_pool links the "old tail" to the new head by updating `next_order_id` of the slot at `tail_order_id`, it will either update `NULL_PTR` (which is a no-op that does nothing useful but is harmless) or update a valid slot. L1 is initialized by reading its consistent values from L2 during startup, so L1 inherits the NULL_PTR initialization for all price levels not yet visited.

---

## 7. Design Choices

### 7.1 Three-Layer Memory Hierarchy
- **L1 (registers):** Immediate access for matching decisions — best prices always available combinationally
- **L2 (HBM):** Full price range storage with burst replenishment — avoids BRAM resource exhaustion
- **Order pool (BRAM):** Per-order linked list — 1-2 cycle access, byte-enable partial writes

### 7.2 Linked List for Per-Level Order FIFO
Fixed-depth arrays per price level would require `NUM_ORDERS_PER_LEVEL` as a compile-time bound, limiting book depth and coupling match engine complexity to order count. A linked list in BRAM gives unbounded depth per level with O(1) enqueue/dequeue.

### 7.3 Matching Against Aggregates, Not Individual Orders
The match decision (does incoming order cross the spread? is there enough total qty?) is made against `total_qty` in L1 head (best bid/ask). Individual order records in the BRAM are only accessed for fill sequencing after the match decision. This keeps match latency fixed and independent of per-level order count.

### 7.4 Circular Buffer for L1
A sliding window implemented as a circular buffer avoids O(L1_DEPTH) register writes on every slide. Only the head pointer register changes; array contents stay in place. Modulo arithmetic on indices is free since `L1_DEPTH` is a power of 2.

### 7.5 L2 Bitmap as Register Array
65,536-bit register array (64-bit chunks) enables single-cycle bit updates and combinational reads. Avoids BRAM read-modify-write latency that would occur with BRAM-backed bitmap. Coarse reduction bitmap computed combinationally enables two-level priority encoding without additional registers.

### 7.6 Write-Back Policy for L1/L2
Write-through to HBM on every L1 update would consume HBM bandwidth proportional to every market event. Write-back defers L2 updates to eviction time, concentrating HBM writes to burst operations during window slides. This aligns with HBM's strength — high-bandwidth burst transfers rather than random single-word updates.

### 7.7 Two-Phase Maker ID Allocation
Pre-loading a free list FIFO with all `NUM_ORDERS` IDs at reset requires a reset state machine running for `NUM_ORDERS` cycles. The counter-then-freelist scheme avoids this — the counter allocates IDs sequentially until exhausted, then the free list takes over. The free list accumulates recycled IDs naturally during Phase 1.

### 7.8 HBM Port B/C Merge for Non-Overlapping Writes
Rather than arbitrating Port B and Port C writes with a strict priority that silently drops one, `hbm_model` detects non-overlapping byte-enable writes to the same address and merges them. This is safe when the two writers target structurally distinct fields — which is guaranteed by the `price_level_t` layout (`head_order_id` at LSBs for Port C, other fields at higher bytes for Port B).

---

## 8. Current Implementation Status (Step 12)

### Completed Modules

| Module | File | Testbench | Status |
|---|---|---|---|
| Package | `rtl/ob_pkg.sv` | `rtl/pkg_test.sv` (deleted) | ✓ Complete |
| Message Decoder | `rtl/msg_decoder.sv` | Skipped (trivial) | ✓ Complete |
| Generic FIFO | `rtl/fifo.sv` | `tb/tb_fifo.sv` | ✓ Complete |
| HBM Model | `rtl/hbm_model.sv` | `tb/tb_hbm_model.sv` | ✓ Complete |
| BRAM Model | `rtl/bram_model.sv` | `tb/tb_bram_model.sv` | ✓ Complete |
| Order Pool | `rtl/order_pool.sv` | `tb/tb_order_pool.sv` | ✓ Complete |
| Level Manager | `rtl/level_manager.sv` | — | 🔄 In Progress |
| Order Book | `rtl/order_book.sv` | — | ⬜ Not Started |

### Current Position in Level Manager

The following have been implemented in `level_manager.sv`:
- Module skeleton, port declarations, internal type definitions
- L1 register arrays (`l1_bid`, `l1_ask`) and bitmaps
- Circular buffer head indices (`bid_l1_head_idx`, `ask_l1_head_idx`)
- Rotated bitmap logic for priority encoding
- L1 priority encoders (`bid_l1_next_offset`, `ask_l1_next_offset`)
- Free list FIFO instantiation
- HBM model instantiation (three-port)
- `l1_lookup` helper function
- `pu_in_window`/`pu_idx` combinational block
- Pool update handler (`always_comb` for HBM/free list signals, `always_ff` for L1 updates)
- L2 bitmap register array and coarse reduction
- L2 priority encoders (bid and ask, two-level hierarchical)
- Slide state registers and `bid_slide_needed`/`ask_slide_needed` signals
- `LM_L2_WAIT` and `LM_L2_CANCEL_WAIT` state definitions

**Still to implement in `level_manager.sv`:**
- `LM_DRAIN_SLIDE_BUF` state definition
- `LM_DRAIN_SLIDE_BUF` drain logic
- Window slide state machine (`LM_SLIDE` state, `slide_buf` FIFO)
- `LM_L2_CANCEL_WAIT` full implementation
- Taker counter increment logic
- Full slide trigger logic connected to add/match/cancel outcomes
- MSG_ADD/MSG_MARKET logic is stubbed and op_out/op_valid are not yet emitted (to be done in next steps)
- level_manager is mid-refactor and contains unresolved naming/state-machine cleanup, so architecture sections 6.7/8 should be treated as target behavior.

---

## 9. Remaining Plan

### Phase 4 — Level Manager (Steps 13–20)

**Step 13 — MSG_ADD within L1 window:**
- Pop maker ID from free list (or counter)
- Update `total_qty` and `tail_order_id` in L1
- Set bitmap bit
- Issue `OP_ADD` to operation buffer
- Write-back to L2 (Port B byte-enable, `total_qty` + `tail_order_id` bytes)
- Emit `ack_t` via order_pool (`OP_ADD` → order_pool emits ack)

**Step 14 — Testbench: MSG_ADD within L1 window**
- Two ADDs to same price level, assert L1 state and `op_push` correct

**Step 15 — MSG_CANCEL:**
- Issue `OP_CANCEL` to order_pool
- Enter `LM_CANCEL_WAIT`
- On `PU_CANCEL`: update L1 or issue Port C read → `LM_L2_CANCEL_WAIT` → write back

**Step 16 — MSG_ADD crossing spread (limit order match):**
- Assign taker ID from counter
- Decrement `total_qty` in L1 for matched level
- Issue `OP_MATCH` to order_pool
- Handle `pool_update` writeback (head update, free list push, bitmap)
- Handle residual: if partial fill, issue `OP_ADD` for remaining qty

**Step 17 — MSG_MARKET:**
- Same match path as crossing limit
- On book exhaustion with remaining qty: issue `OP_MARKET_FAIL`

**Step 18 — Testbench: crossing limit and market orders**
- Resting ASK, crossing BID → assert execution and L1 update
- MARKET BID sweeping two levels → assert correct executions
- MARKET BID exhausting book → assert `OP_MARKET_FAIL` and correct ack

**Step 19 — Proactive bitmap-driven sweep and window slide:**
- Connect `bid_slide_needed`/`ask_slide_needed` to slide trigger
- Implement full `LM_SLIDE` state: clear slots, write-back to L2, fetch from L2
- Implement `LM_DRAIN_SLIDE_BUF`

**Step 20 — Testbench: sweep and window slide**
- MARKET order sweeping two full levels → assert window slide
- Exhaust all L1 bitmap bits → assert L2 fallback

---

### Phase 5 — Top Level Integration (Steps 21–26)

**Step 21 — Wire all modules in `order_book.sv`:**
- Instantiate `msg_decoder`, `level_manager`, operation buffer FIFO, `order_pool`
- Instantiate output FIFOs for `execution_t` and `ack_t`
- AXI-Stream in/out

**Steps 22–26 — End-to-end testbench scenarios:**
- Scenario 1: Three ADDs, no match
- Scenario 2: Full match, single resting order
- Scenario 3: Partial match, residual rests
- Scenario 4: MARKET sweeps two price levels
- Scenario 5: ADD then CANCEL
- Regression: all scenarios pass

---

### Phase 6 — Verilator C++ Driver (Steps 27–30)

- `tb/sim_main.cpp` — Verilator driver replacing SV testbench
- CSV test vector reader
- Port all scenarios to CSV
- VCD waveform dump

---

### Phase 7 — L2 Full Implementation (Steps 31–34)

- Connect L2 HBM reads/writes to real price level data
- Implement window replenishment from L2 on slide
- Testbench: pre-load L2 with out-of-window levels, trigger sweep → assert replenishment
- Regression

---

### Phase 8 — Protocol Layer (if time allows, Steps 35–38)

- Define `.proto` file for `OrderMessage` and `ExecutionReport`
- C++ encoder/decoder using protobuf
- Drive Verilator from protobuf-encoded messages
- Decode and verify execution reports in C++

---

### Phase 9 — On-Chip Notification Bus (if time allows, Steps 39–42)

- Add `notify_bus` output to `level_manager` — fires on match event
- Stub `strategy_engine.sv` — receives notification, produces response order
- Wire into `order_book.sv`
- Testbench: match event → notification → follow-on order

---

### Known Limitations and Future Work

| Limitation | Notes |
|---|---|
| Single outstanding HBM read per port | Pipelined multiple outstanding reads deferred |
| Cancelled slot accumulation in FIFO | Background compaction deferred |
| Stall on every CANCEL | Could be improved with a per-order metadata cache at smaller scale |
| Single operation at a time in order_pool | Multiple operation type buffers for concurrency deferred |
| L2 HBM not modeling 32-byte line granularity | Simplified model — real HBM line size optimization deferred |

---
