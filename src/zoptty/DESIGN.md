# Ghostty Web Terminal — Design Document

## Overview

This document describes the design of `ghostty-web`, a system for rendering
Ghostty terminal sessions in a web browser. The native server manages PTY and
terminal state; the browser client renders via WebGL2. Data is
transmitted over QUIC (WebTransport) using a custom binary protocol optimized
for low bandwidth and packet loss tolerance.

---

## Architecture

```
┌─────────────────────┐              ┌──────────────────────────────┐
│  ghostty-web-server  │  WebTransport │         Browser              │
│  (native binary)     │   (QUIC)     │                              │
│                     │              │  Wasm (libghostty-vt)        │
│  PTY <-> Termio     │  CellPackets │  ├── decode CellPacket       │
│         |           │ -----------> │  ├── codepoint -> atlas lookup│
│  Terminal           │              │  └── output bg[]/fg[] buffers │
│         |           │              │         |                     │
│  RenderState        │  <---------- │  WebGL2 Renderer             │
│         |           │  input/resize│  ├── font atlas texture        │
│  8-bit preprocess   │              │  ├── bg pass (background)     │
│         |           │              │  └── fg pass (text)           │
│  encode + packetize │              │                              │
└─────────────────────┘              └──────────────────────────────┘
```

### Server (native)

- Manages PTY subprocess via existing `termio.Exec` backend (no modifications
  to core Ghostty code).
- Maintains `terminal.Terminal` and `terminal.RenderState`.
- Encodes terminal state into `CellPacket` datagrams.
- Serves WebTransport connections via QUIC (using `quiche` C library).

### Client (browser)

- Receives `CellPacket` datagrams and decodes them in Wasm.
- Maintains local `bg_cells[]` and `fg_cells[]` buffers.
- Looks up glyph metrics (position, size, bearings) from its local font atlas
  — the server never sends glyph rendering information.
- Renders via WebGL2 in two passes: background colors, then text.
- Captures keyboard/mouse/paste input and sends to server over reliable stream.

---

## Transport Layer

### QUIC Reliable Stream

| Direction        | Content                          |
|------------------|----------------------------------|
| client -> server | `InputEvent`, `ResizeEvent`      |
| server -> client | `Handshake` (once per connection)|

### QUIC Datagram (unreliable, unordered)

| Direction        | Content      |
|------------------|--------------|
| server -> client | `CellPacket` |

Datagrams may be lost or arrive out of order. The client uses sequence numbers
to discard stale packets. Lost packets are naturally repaired by subsequent
updates or the periodic full refresh.

### QUIC Library

Transport uses [ZoptiaQUIC](../zoptiaquic-dev), a pure-Zig QUIC implementation.
Key features used:
- `Listener.accept()` / `Dialer.dial()` for connection setup (TLS 1.3)
- `Connection.sendDatagram()` / `Connection.recvDatagram()` for CellPackets
- `Connection.sendStreamData()` / stream recv for keyboard input
- `Connection.buildShortPacket()` for custom frame construction

### Verification Stages

1. **In-process roundtrip** (`roundtrip.zig`): encode → decode in same process,
   validates protocol correctness without network.
2. **QUIC roundtrip** (`quic_test.zig`): encode → QUIC datagram → decode over
   localhost, validates protocol + transport integration.
3. **Browser client** (future): WebTransport from browser to QUIC server.

---

## Connection Lifecycle

All state synchronization is driven by `ResizeEvent` from the client. There is
no concept of I-frames or P-frames. There is no server-initiated resize
notification.

```
Connect:    client opens WebTransport session
            server sends Handshake (atlas, glyph metrics)
            client sends ResizeEvent { cols, rows }
            server marks all rows dirty, sends CellPackets

Reconnect:  same as Connect (client sends ResizeEvent, server sends all rows)

Resize:     client sends ResizeEvent { new_cols, new_rows }
            server calls terminal.resize()
            all rows become dirty, server sends CellPackets

Keepalive:  server every 5-10s gradually re-sends all rows
            (spread across ticks to avoid burst)
```

---

## Handshake

Sent once on the reliable stream when a client connects.

```
Handshake:
  version:        u32            # protocol version (currently 1)
  cell_width:     f32            # cell width in pixels
  cell_height:    f32            # cell height in pixels
  font_data_len:  u32            # font file size in bytes
  font_data:      [len]u8        # font file (TTF/OTF, or woff2 compressed)
```

### Font Delivery

The server sends the terminal's font file directly in the handshake. The
client uses the font with its native rendering system:

- **Browser**: loads via `FontFace` API, renders glyphs on demand using
  Canvas 2D `fillText()`, extracts pixel data via `getImageData()`, and
  uploads to a WebGL texture atlas.
- **Ghostty test mode**: uses the existing `font_grid` for glyph lookup.

This approach:
- Covers all codepoints the font supports (CJK, emoji, symbols) with no
  atlas pre-generation or incremental requests.
- Requires no build-time dependencies (no msdf-atlas-gen).
- A typical terminal font is 50-200 KB (woff2 compressed), sent once.

### No Palette

There is no palette in the handshake. All colors are transmitted as resolved
RGBA values in `CellBg` and `FgStyle.color`. The server resolves palette
indices to RGB before encoding. Palette changes (via OSC 4) are automatically
reflected — the encoder compares resolved RGBA values, so any change causes
the affected cells to be re-sent.

---

## CellPacket

The only data packet type. Represents one row of the terminal (or a segment of
a row if the encoded size exceeds the QUIC datagram MTU).

### Wire Format

```
CellPacket:
  sequence:    u32           # monotonically increasing counter
  row:         u16           # row number (0 = top)
  flags:       u8            # bit 0: has_cursor
  [cursor]:    optional      # present if flags.bit0 = 1
  dict_sizes:  u8            # packed dictionary sizes
  bg_dict:     [n][4]u8      # background color dictionary
  fg_dict:     [n]FgStyle    # foreground style dictionary
  cell_map:    [cols]u8      # one byte per column
  overflow:    []u8          # variable-length data stream
```

Total header overhead: 8 bytes (sequence + row + flags + dict_sizes).

### Cursor (4 bytes, optional)

Present only when `flags & 0x01 != 0`.

```
  cursor_x:     u16          # column position
  cursor_style: u8           # 0=block, 1=bar, 2=underline, 3=block_hollow
  cursor_flags: u8           # bit0: visible, bit1: blinking
```

### dict_sizes (1 byte)

```
  bits [2:0] = bg dictionary size (0-6)
  bits [7:3] = fg dictionary size (0-30)
```

### FgStyle (6 bytes)

```
  color:  [4]u8    # RGBA foreground color
  atlas:  u8       # 0 = grayscale (text), 1 = color (emoji)
  flags:  u8       # text decoration and style flags
```

FgStyle.flags bit layout:

```
  bit 0:   bold
  bit 1:   italic
  bit 2:   faint
  bit 3:   strikethrough
  bit 4:   overline
  bit 5-6: underline (00=none, 01=single, 10=double, 11=dotted)
  bit 7:   reserved
```

---

## cell_map Encoding

Each column is encoded as one byte in `cell_map`. The byte is split into two
fields:

```
  bits [2:0] = bg code (3 bits, 8 values)
  bits [7:3] = fg code (5 bits, 32 values)
```

### bg code (3 bits)

| Value | Meaning                                            | Overflow consumed |
|-------|----------------------------------------------------|-------------------|
| 0     | skip — do not update this cell's background        | 0 bytes           |
| 1-6   | use `bg_dict[code - 1]`                            | 0 bytes           |
| 7     | overflow — read 4 bytes (RGBA) from overflow stream| 4 bytes           |

### fg code (5 bits)

| Value | Meaning                                            | Overflow consumed            |
|-------|----------------------------------------------------|------------------------------|
| 0     | skip — do not update this cell's foreground        | 0 bytes                      |
| 1-30  | use `fg_dict[code - 1]` for style                  | 1-4 bytes (UTF-8 codepoint) |
| 31    | overflow — read style from overflow stream          | 1-4 bytes (UTF-8 codepoint) + 6 bytes (FgStyle) |

When `fg != 0`, a UTF-8 encoded codepoint is always consumed from the overflow
stream. The codepoint identifies which character to render; the client looks up
the glyph's atlas position from its local font atlas.

---

## Overflow Stream

The overflow section is a tightly packed byte stream with no internal framing.
Its structure is entirely driven by `cell_map`: the decoder reads `cell_map`
left to right, and for each byte, consumes 0 to 13 bytes from the overflow
stream based on the bg and fg codes.

### Consumption Table

| bg     | fg       | Bytes consumed from overflow              |
|--------|----------|-------------------------------------------|
| skip   | skip     | 0                                         |
| dict   | skip     | 0                                         |
| dict   | dict     | 1-4 (UTF-8 codepoint)                     |
| dict   | overflow | 1-4 (UTF-8) + 6 (FgStyle)                |
| ovf    | skip     | 4 (bg color)                              |
| ovf    | dict     | 4 (bg) + 1-4 (UTF-8)                      |
| ovf    | overflow | 4 (bg) + 1-4 (UTF-8) + 6 (FgStyle)       |

Maximum per cell: 4 + 4 + 6 = 14 bytes.

### Example

```
bg_dict = [black, white]
fg_dict = [style_white, style_green]
cell_map = [0x09, 0x01, 0x48, 0xF9]
             |      |      |      |
             |      |      |      bg=1(white), fg=31(ovf)
             |      |      bg=0(skip), fg=9(dict[8]... wait)

Let's decode byte by byte:

byte 0x09: bg = 0x09 & 0x07 = 1 (bg_dict[0] = black)
           fg = 0x09 >> 3   = 1 (fg_dict[0] = style_white)
           overflow: read UTF-8 codepoint -> 'H' (1 byte)

byte 0x01: bg = 0x01 & 0x07 = 1 (bg_dict[0] = black)
           fg = 0x01 >> 3   = 0 (skip)
           overflow: nothing

byte 0x48: bg = 0x48 & 0x07 = 0 (skip)
           fg = 0x48 >> 3   = 9 (fg_dict[8])
           overflow: read UTF-8 codepoint -> 'e' (1 byte)

byte 0xF9: bg = 0xF9 & 0x07 = 1 (bg_dict[0] = black)
           fg = 0xF9 >> 3   = 31 (overflow)
           overflow: read UTF-8 -> U+4F60 '你' (3 bytes)
                     read FgStyle (5 bytes)
```

---

## Server Encoding Flow

### Step 1: 8-bit Preprocessing

Scan each cell in the row. Compute a type ID for each cell by hashing its
visual properties:

```
bg_type = hash(bg_color)          -> 0-255
fg_type = hash(fg_color, atlas)   -> 0-255
```

Compare with the previous frame to mark changed cells. Produce an internal
preprocessing map (not transmitted).

### Step 2: Size Estimation and Packetization

Scan the preprocessing map left to right, accumulating the encoded size:

- Each cell: 1 byte in `cell_map`
- bg dictionary hit: 0 bytes overflow
- bg overflow: 4 bytes
- fg skip: 0 bytes
- fg dictionary hit: 1-4 bytes (UTF-8 codepoint)
- fg overflow: 1-4 bytes (UTF-8) + 5 bytes (FgStyle)
- Unchanged cell: 0 bytes (skip)

If the accumulated size exceeds `MTU * 0.85` (~1020 bytes), split the row at
the current position. Prefer splitting at type-change boundaries where the
preprocessing map shows a transition between different type IDs, as this
maximizes dictionary hit rates in each segment.

When splitting, each segment becomes an independent `CellPacket` with its own
dictionaries. The segment uses `col_start` and `col_count` fields (added only
when the row is split) so the client knows which columns the packet covers.

Most rows fit in a single packet. Splitting only occurs with very wide
terminals (200+ columns) and dense content.

### Step 3: Encoding

For each segment (or the whole row if no split):

1. Count frequencies of bg types, select top-6 as bg dictionary.
2. Count frequencies of fg style types, select top-30 as fg dictionary.
3. For each cell:
   - If unchanged from previous frame: bg=0, fg=0 (skip).
   - If bg matches dictionary: bg=1-6. Else: bg=7, write color to overflow.
   - If fg has content and style matches dictionary: fg=1-30, write UTF-8
     codepoint to overflow. Else: fg=31, write codepoint + FgStyle to overflow.
   - If cell has no foreground character: fg=0.
4. Pack bg (3 bits) and fg (5 bits) into one byte per cell.
5. Prepend header, dictionaries. Append cell_map and overflow.
6. Send as QUIC datagram.

---

## Client Decoding

### Sequence Control

```
row_seq[rows]: u32    # highest applied sequence per row

on receive CellPacket:
  if packet.sequence > row_seq[packet.row]:
    decode and apply
    row_seq[packet.row] = packet.sequence
  else:
    discard (stale)
```

### Decode Algorithm

```
ptr = 0  // overflow read pointer

for col in 0..cols:
    byte = cell_map[col]
    bg = byte & 0x07
    fg = byte >> 3

    // background
    switch bg:
      0:   // skip
      1-6: bg_cells[col] = bg_dict[bg - 1]
      7:   bg_cells[col] = overflow[ptr..ptr+4]; ptr += 4

    // foreground
    switch fg:
      0:   // skip
      1-30:
        cp_len = utf8_byte_length(overflow[ptr])
        codepoint = utf8_decode(overflow[ptr..ptr+cp_len]); ptr += cp_len
        fg_cells[col] = { codepoint, fg_dict[fg - 1] }
      31:
        cp_len = utf8_byte_length(overflow[ptr])
        codepoint = utf8_decode(overflow[ptr..ptr+cp_len]); ptr += cp_len
        style = read_fg_style(overflow[ptr..ptr+5]); ptr += 5
        fg_cells[col] = { codepoint, style }
```

### Rendering

After decoding, the client has updated `bg_cells` and `fg_cells` arrays. For
each `fg_cell`, the client looks up the codepoint in its local font atlas
to obtain `glyph_pos`, `glyph_size`, and `bearings`. These are combined
into GPU vertex data.

WebGL2 rendering:

- **Pass 1 (background):** Upload `bg_cells` as a 2D texture
  (`cols x rows`, `RGBA8`). Draw a full-screen triangle. The fragment shader
  uses `texelFetch()` to read the background color for each pixel's grid cell.

- **Pass 2 (text):** Upload fg cells as an instanced vertex buffer. Each
  instance is a 4-vertex triangle strip representing one glyph quad. The vertex
  shader positions the quad using grid position + glyph bearings. The fragment
  shader samples the font atlas texture for the glyph alpha mask.

---

## Input Events

Sent from client to server on the reliable QUIC stream.

```
InputEvent:
  event_type:  u8
  modifiers:   u8     # bit0=ctrl, bit1=alt, bit2=shift, bit3=super
  payload:     variable (depends on event_type)
```

### Event Types

| Type | Value | Payload                                         |
|------|-------|-------------------------------------------------|
| key_press   | 0 | codepoint: u32, utf8_len: u16, utf8: [len]u8  |
| key_release | 1 | codepoint: u32, utf8_len: u16, utf8: [len]u8  |
| mouse       | 2 | x: u16, y: u16, button: u8, action: u8        |
| paste       | 3 | data_len: u32, data: [len]u8                   |
| resize      | 4 | cols: u16, rows: u16, width_px: u32, height_px: u32 |

Mouse actions: 0=press, 1=release, 2=motion, 3=scroll.

---

## Server Encoding Pipeline (bridge.zig)

The bridge module connects Ghostty's `terminal.RenderState` to the web
protocol encoder. It depends on the `ghostty-vt` Zig module for terminal
types but does not modify any core Ghostty code.

### Data Flow

```
Terminal.vtWrite(pty_bytes)
  |
RenderState.update(&terminal)        -- snapshot terminal state
  |
bridge.extractRow(&render_state, y)  -- per row:
  |  - read page.Cell content_tag -> codepoint (u21)
  |  - resolve style.bg_color via palette -> [4]u8 RGBA
  |  - resolve style.fg_color via palette -> [4]u8 RGBA
  |  - detect color glyphs (emoji heuristic)
  |
bridge.extractCursor(&render_state, y)  -- optional cursor
  |
PacketEncoder.encodeRowSplit(row, cols, bg, cp, styles, cursor)
  |
[]CellPacket  -- ready for QUIC datagram / reliable stream
```

### Color Resolution

Terminal cells store colors as either palette indices or direct RGB values.
The bridge resolves all colors to RGBA before encoding:

```
style.fg_color / style.bg_color:
  .none    -> use default fg/bg from RenderState.colors
  .palette -> look up RenderState.colors.palette[index]
  .rgb     -> use directly

Special cases (bg-only cells):
  content_tag == .bg_color_rgb     -> use embedded RGB
  content_tag == .bg_color_palette -> look up palette
```

Because the bridge resolves colors every frame using the current palette,
palette changes (via OSC 4) are automatically detected by the encoder's
change comparison — the resolved RGBA will differ from the previous frame,
causing the cell to be re-sent.

### Emoji Detection

The bridge uses a simple heuristic to set `FgStyle.atlas = 1` (color) for
emoji codepoints:

```
U+1F300..1F5FF  Misc Symbols and Pictographs
U+1F600..1F64F  Emoticons
U+1F680..1F6FF  Transport and Map
U+1F900..1F9FF  Supplemental Symbols
U+2600..26FF    Misc Symbols
U+2700..27BF    Dingbats
```

This is a heuristic, not a full Unicode Emoji_Presentation check. It covers
the most common emoji ranges. The client uses this flag to select the
appropriate atlas texture (grayscale vs. color) for rendering.

### Build Integration

The bridge module is tested via `zig build test-web`. This build step:
- Creates a test module rooted at `src/web/bridge.zig`
- Imports the `ghostty-vt` Zig module (same module used by `example/zig-vt/`)
- Runs end-to-end tests: Terminal -> RenderState -> bridge -> encode -> decode

---

## Size Estimates

### Typical interactive use (128 cols, 5 cells changed, ASCII)

```
  header + dict_sizes:    8 bytes
  bg_dict (2 types):      8 bytes
  fg_dict (3 types):      15 bytes
  cell_map:               128 bytes
  overflow (5 codepoints): 5 bytes
  ─────────────────────────────────
  total:                  164 bytes
```

### Full row refresh (128 cols, 60 ASCII chars, all changed)

```
  header + dict_sizes:    8 bytes
  bg_dict (2 types):      8 bytes
  fg_dict (3 types):      15 bytes
  cell_map:               128 bytes
  overflow (60 codepoints): 60 bytes
  ─────────────────────────────────
  total:                  219 bytes
```

### Full-width CJK row (216 cols, 200 chars, all changed)

```
  header + dict_sizes:    8 bytes
  bg_dict (2 types):      8 bytes
  fg_dict (3 types):      15 bytes
  cell_map:               216 bytes
  overflow (200 x 3-byte UTF-8): 600 bytes
  ─────────────────────────────────
  total:                  847 bytes
```

### Idle cursor blink (128 cols, 1 cell changed)

```
  header + dict_sizes:    8 bytes
  bg_dict (1 type):       4 bytes
  fg_dict (1 type):       5 bytes
  cell_map:               128 bytes
  overflow (1 codepoint): 1 byte
  ─────────────────────────────────
  total:                  146 bytes
```

All cases fit within the QUIC datagram MTU (~1200 bytes).

---

## Cell-Level Sequence Numbers

The client tracks a sequence number per cell, not per row:

```
  cell_seq[rows * cols]: u32
```

When applying a `CellPacket`, each non-skip cell is individually checked:

```
  for each cell in cell_map:
      if cell is skip: continue
      if packet.sequence > cell_seq[row][col]:
          apply cell data
          cell_seq[row][col] = packet.sequence
      else:
          discard (stale)
```

This provides:
- **Fine-grained loss recovery** — a lost packet only leaves specific cells
  stale, and any future packet updating those cells will repair them.
- **Safe out-of-order delivery** — cells from newer packets are never
  overwritten by older ones.
- **Split-packet support** — multiple packets covering different columns of
  the same row work without coordination.

Memory overhead: 216 cols x 64 rows x 4 bytes = ~54 KB. Negligible.

---

## Row Splitting (when exceeding MTU)

When a single row's encoded size exceeds the QUIC datagram MTU (~1200 bytes),
the encoder splits the row into multiple `CellPacket`s grouped by type
similarity.

**All split packets share the same sequence number** — they represent the same
row at the same point in time. The client's cell-level sequence tracking
handles them independently.

### Splitting Algorithm

1. Encode the row as a single packet. If it fits in the MTU, send it (the
   common case).

2. If it exceeds the MTU, compute an 8-bit type ID for each cell:
   `type_id = hash(bg_color, fg_style)`.

3. Count the frequency of each type ID. Sort by frequency descending.

4. Greedily assign types to groups: starting from the most frequent type,
   accumulate types into a group until the estimated encoded size approaches
   `MTU * 0.85`. Then start a new group.

5. For each group, produce a `CellPacket` covering the full row. Columns
   belonging to the group have their actual cell data; all other columns are
   encoded as skip (`0x00`). Each packet has its own dictionaries optimized
   for the types in its group.

### Why full-row cell_map with skip (not column subsets)

Each split packet contains a full `cell_map[cols]` with non-group columns set
to skip. This means the client decodes every packet identically — no special
handling for split vs. non-split packets.

An earlier design considered compressing the skip-heavy cell_map with a bitmap
(27 bytes bitmap + 16 bytes data vs. 216 bytes cell_map). This was rejected
because:
- The splitting scenario is already rare (wide terminal + dense content + many
  colors simultaneously).
- The added encoding/decoding complexity and flag bits are not justified by
  saving ~170 bytes in an edge case.
- The uniform full-row cell_map keeps the decoder simple and branchless.

### Example

```
216 cols, 3 visual groups (white code, green diff, blue headers):

Single packet: 1050 bytes — exceeds MTU

Split into 3 packets (same sequence):
  pkt (white):  216-byte map, 150 cells active, 66 skip — dict {white} — ~400 bytes
  pkt (green):  216-byte map, 50 cells active, 166 skip — dict {green} — ~300 bytes
  pkt (blue):   216-byte map, 16 cells active, 200 skip — dict {blue}  — ~250 bytes
```

Each packet fits in the MTU. Each has a pure dictionary with near-zero
overflow.

---

## Periodic Full Refresh

To recover from accumulated packet loss, the server periodically re-sends all
rows. This is spread across multiple ticks to avoid burst:

```
  tick interval:    16ms (60 fps)
  rows per tick:    1-2
  full cycle:       rows / 2 ticks = ~0.5s for 64 rows
  cycle interval:   every 5-10 seconds
```

The refresh simply marks rows as dirty and lets the normal encoding path handle
them. Cells that haven't changed since the last successful delivery will be
encoded as `skip` (code 0), so the overhead is minimal.

---

## Key Design Properties

1. **Unified packet format** — No I-frame/P-frame distinction. Only
   `CellPacket`. Every packet is self-contained with its own dictionaries.

2. **Cell-level delta** — Each cell independently skips or updates via the
   `cell_map`. No frame-level state machine.

3. **Server is rendering-agnostic** — Server sends codepoints (UTF-8), not
   glyph atlas coordinates. All rendering data (glyph_pos, glyph_size,
   bearings) is resolved client-side from the font atlas.

4. **Self-driven overflow** — The `cell_map` byte completely determines how
   many bytes to consume from the overflow stream. No length prefixes, no
   delimiters, no framing within the overflow.

5. **Byte-aligned cell encoding** — One byte per cell (3-bit bg + 5-bit fg).
   No nibble splitting, no bit shifting across byte boundaries in the main
   loop.

6. **Packet loss tolerance** — Each `CellPacket` is independent. Lost packets
   only affect the cells they cover. Cell-level sequence numbers ensure stale
   data is never applied. Periodic refresh provides eventual consistency.

7. **Reconnection via ResizeEvent** — Client simply sends `ResizeEvent` after
   reconnecting. Server treats it the same as a resize: marks all rows dirty
   and sends everything. No special reconnection protocol.

8. **No global dictionary** — Each packet carries its own dictionaries. No
   cross-packet synchronization, no dictionary versioning, no ordering
   dependencies between packets.

9. **Adaptive encoding** — The 8-bit preprocessing map enables accurate size
   estimation and intelligent split-point selection based on type boundaries,
   maximizing compression within each segment.

---

## Dependencies

| Component        | Library               | Purpose                          |
|------------------|-----------------------|----------------------------------|
| QUIC server      | quiche (Cloudflare)   | WebTransport/QUIC + BoringSSL    |
| Terminal core    | libghostty-vt         | Existing Ghostty terminal engine |

No build-time font generation tools needed. The font file is sent directly
in the handshake. No modifications to Ghostty's core terminal, termio, or
renderer code.

---

## File Structure

### Implemented

```
src/web/
  DESIGN.md              # this document
  main.zig               # module root (standalone tests, no ghostty-vt dep)
  protocol.zig           # wire format data structures
  compression.zig        # cell_map encoding/decoding (3-bit bg + 5-bit fg)
  frame_encoder.zig      # PacketEncoder: change detection, split, sequence
  frame_decoder.zig      # ClientState: cell-level sequence, decoding
  bridge.zig             # RenderState -> CellPacket bridge (ghostty-vt dep)

build.zig                # test-web step added
```

### Planned

```
src/web/
  server.zig             # session management, PTY lifecycle
  transport.zig          # WebTransport/QUIC server wrapper

src/web/frontend/
  terminal.ts            # main entry, glue
  transport.ts           # WebTransport client + reconnection
  renderer.ts            # WebGL2 renderer
  input.ts               # keyboard/mouse/paste capture
  atlas.ts               # font atlas texture management (Canvas 2D rendering)
  shaders/
    cell_text.vert       # WebGL2 vertex shader
    cell_text.frag       # WebGL2 fragment shader
    cell_bg.frag         # WebGL2 background shader
    common.glsl          # color space utilities

src/build/
  GhosttyWebServer.zig   # build target for server binary
  GhosttyWebClient.zig   # build target for client wasm
```

---

## Current Protocol Coverage

What FgStyle transmits vs. what the terminal supports:

### Transmitted (in FgStyle)

| Attribute      | Field              | Bits |
|----------------|--------------------|------|
| Foreground RGBA | color [4]u8       | 32   |
| Atlas type      | atlas u8          | 8    |
| Bold            | flags bit 0       | 1    |
| Italic          | flags bit 1       | 1    |
| Faint           | flags bit 2       | 1    |
| Strikethrough   | flags bit 3       | 1    |
| Overline        | flags bit 4       | 1    |
| Underline       | flags bits 5-6    | 2    |

### Not Yet Transmitted

| Attribute         | Complexity | Notes                                    |
|-------------------|------------|------------------------------------------|
| Underline color   | Low        | Extra [4]u8 only when underline is set. Could use a separate overflow field or extend FgStyle conditionally. Most underline colors match fg. |
| Grapheme clusters | Medium     | Multi-codepoint characters (e.g. 'é' = 'e' + U+0301). Need variable-length encoding in overflow. Use 0xC0 (invalid UTF-8 start byte) as continuation marker after the base codepoint: `[base_utf8, 0xC0, extra_cp_utf8..., 0x00]`. Uncommon in typical terminal use. |
| Hyperlinks        | Medium     | OSC 8 links. Not cell rendering data — needs a separate control message to transmit URL + cell range. Independent of CellPacket encoding. |
| Selection         | None       | Client-side UI state. Not transmitted. The client manages selection highlighting locally. |
| Cursor color      | Low        | Currently CursorInfo has position + style + flags but no color. Could add [4]u8 (from RenderState.colors.cursor). |
| Blink             | Low        | Cell-level blink attribute. Could add to flags bit 7. Blink animation is client-side. |

### Priority for Implementation

1. **Underline color** and **cursor color** — low effort, add when needed
2. **Grapheme clusters** — medium effort, needed for correct rendering of combining characters and some emoji sequences
3. **Hyperlinks** — separate control message, not part of CellPacket
4. **Blink** — trivial, add to flags when needed
