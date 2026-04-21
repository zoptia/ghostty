///! ghostty-web module root.
///!
///! Provides CellPacket encoding/decoding with 3/5-bit cell_map
///! compression and UTF-8 codepoints in the overflow stream.
///! See DESIGN.md for the full protocol specification.

pub const protocol = @import("protocol.zig");
pub const compression = @import("compression.zig");
pub const frame_encoder = @import("frame_encoder.zig");
pub const frame_decoder = @import("frame_decoder.zig");

// Re-export key types.
pub const PacketEncoder = frame_encoder.PacketEncoder;
pub const ClientState = frame_decoder.ClientState;
pub const decodePacket = frame_decoder.decodePacket;

pub const CellPacketHeader = protocol.CellPacketHeader;
pub const CellCode = protocol.CellCode;
pub const CellBg = protocol.CellBg;
pub const FgStyle = protocol.FgStyle;
pub const CursorInfo = protocol.CursorInfo;
pub const DictSizes = protocol.DictSizes;

test {
    _ = protocol;
    _ = compression;
    _ = frame_encoder;
    _ = frame_decoder;
}
