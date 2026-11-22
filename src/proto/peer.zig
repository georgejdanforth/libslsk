//! Peer init messages and peer messages (see "Peer Init Messages" and "Peer Messages" in
//! docs/SLSKPROTOCOL.md).
//!
//! - `Init` holds the first message of each connection to a peer (`P`, `F`, or `D`). These
//!   frames have a `u8` code.
//! - `Message` holds the messages on a `P` connection. These frames have a `u32` code. Each
//!   message has the same layout in both directions, so one union encodes and decodes both.
//!
//! The rules of `server.zig` also apply here: an unknown code decodes to `.unknown`, the decoder
//! ignores bytes after the last field, and numbers keep their wire types.
//!
//! `SharedFileListResponse`, `FileSearchResponse`, and `FolderContentsResponse` have a zlib
//! compressed body. To decode them, `Message.decode` takes an arena. The decoded message points
//! into the frame body and into memory from the arena.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const common = @import("common.zig");
const frame = @import("frame.zig");
const wire = @import("wire.zig");
const zlib = @import("zlib.zig");

const ConnectionType = common.ConnectionType;
const Unknown = common.Unknown;

/// The peer init message codes. Other codes decode to `.unknown`.
pub const InitCode = enum(u8) {
    pierce_firewall = 0,
    peer_init = 1,
    _,
};

/// The peer message codes that libslsk implements. Other codes, for example the obsolete ones,
/// decode to `.unknown`.
pub const Code = enum(u32) {
    shared_file_list_request = 4,
    shared_file_list_response = 5,
    file_search_response = 9,
    user_info_request = 15,
    user_info_response = 16,
    folder_contents_request = 36,
    folder_contents_response = 37,
    transfer_request = 40,
    transfer_response = 41,
    queue_upload = 43,
    place_in_queue_response = 44,
    upload_failed = 46,
    upload_denied = 50,
    place_in_queue_request = 51,
    _,

    /// Returns true if the body of the message is zlib compressed.
    pub fn isCompressed(code: Code) bool {
        return switch (code) {
            .shared_file_list_response, .file_search_response, .folder_contents_response => true,
            else => false,
        };
    }
};

pub const InitDecodeError = wire.Reader.Error || error{
    /// A connection type string is not "P", "F", or "D".
    InvalidConnectionType,
};

pub const DecodeError = wire.Reader.Error || zlib.DecompressError;

pub const DecodeOptions = struct {
    /// The largest body of a compressed message, after decompression. A larger body gives
    /// `error.DecompressedTooLarge`.
    decompressed_size_max: u32,
};

/// See "File Attribute Types" in the specification.
pub const FileAttributeCode = enum(u32) {
    /// Kilobits per second.
    bitrate = 0,
    /// Seconds.
    duration = 1,
    /// 0 or 1.
    vbr = 2,
    /// Obsolete.
    encoder = 3,
    /// Hertz.
    sample_rate = 4,
    /// Bits.
    bit_depth = 5,
    _,
};

pub const FileAttribute = struct {
    code: FileAttributeCode,
    value: u32,
};

/// A file in a file list or in a search result.
pub const File = struct {
    /// The basename in a folder list. The full path in a search result. See "Reserved Path
    /// Specifiers" in the specification.
    path: []const u8,
    size: u64,
    /// SoulseekQt sends an empty extension.
    extension: []const u8,
    attributes: []const FileAttribute,
};

pub const Folder = struct {
    path: []const u8,
    files: []const File,
};

/// See "Transfer Directions" in the specification.
pub const TransferDirection = enum(u32) {
    download = 0,
    upload = 1,
    _,
};

/// See "Upload Permissions" in the specification.
pub const UploadPermission = enum(u32) {
    no_one = 0,
    everyone = 1,
    users_in_list = 2,
    permitted_users = 3,
    _,
};

/// The smallest encoded size of each list element. The decoder uses these sizes to reject a
/// count that the body cannot hold, before it allocates the list.
const attribute_size_min = @sizeOf(u32) + @sizeOf(u32);
/// The code, the path, the size, the extension, and the attribute count.
const file_size_min = @sizeOf(u8) + @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32);
/// The path and the file count.
const folder_size_min = @sizeOf(u32) + @sizeOf(u32);

comptime {
    assert(attribute_size_min == 8);
    assert(file_size_min == 21);
    assert(folder_size_min == 8);
}

/// The first message on a connection to a peer. Fields are in wire order.
pub const Init = union(enum) {
    pierce_firewall: PierceFirewall,
    peer_init: PeerInit,
    unknown: Unknown,

    /// The answer to an indirect connection request.
    pub const PierceFirewall = struct {
        /// The token from the `ConnectToPeer` server message.
        token: u32,
    };

    /// A direct connection request.
    pub const PeerInit = struct {
        /// The username of the peer that opens the connection.
        username: []const u8,
        connection_type: ConnectionType,
        /// Always 0 today.
        token: u32,
    };

    pub fn code(message: Init) u32 {
        return common.code(InitCode, Init, message);
    }

    /// Appends the complete frame, with the length and the code.
    pub fn encode(message: Init, writer: wire.Writer) Allocator.Error!void {
        const header_offset = try frame.begin(writer, .code_u8, message.code());
        switch (message) {
            .pierce_firewall => |pierce| try writer.writeInt(u32, pierce.token),
            .peer_init => |peer_init| {
                try writer.writeString(peer_init.username);
                try writer.writeString(peer_init.connection_type.string());
                try writer.writeInt(u32, peer_init.token);
            },
            .unknown => |unknown| {
                assert(unknown.code <= std.math.maxInt(u8));
                // A known code would decode to a different tag, so the round trip would fail.
                assert(!common.isKnownCode(InitCode, Init, unknown.code));
                try writer.writeRaw(unknown.body);
            },
        }
        frame.end(writer, header_offset);
    }

    /// Decodes a frame with a `u8` code. Slices point into the frame body.
    pub fn decode(message_frame: frame.Frame) InitDecodeError!Init {
        assert(message_frame.code <= std.math.maxInt(u8));
        var reader: wire.Reader = .init(message_frame.body);
        const message_code: InitCode = @fromBackingInt(@as(u8, @intCast(message_frame.code)));
        switch (message_code) {
            .pierce_firewall => return .{ .pierce_firewall = .{
                .token = try reader.readInt(u32),
            } },
            .peer_init => return .{ .peer_init = .{
                .username = try reader.readString(),
                .connection_type = try ConnectionType.parse(try reader.readString()),
                .token = try reader.readInt(u32),
            } },
            _ => return .{ .unknown = common.unknownMessage(message_frame) },
        }
    }
};

/// The messages on a `P` connection. Fields are in wire order.
pub const Message = union(enum) {
    shared_file_list_request,
    shared_file_list_response: SharedFileListResponse,
    file_search_response: FileSearchResponse,
    user_info_request,
    user_info_response: UserInfoResponse,
    folder_contents_request: FolderContentsRequest,
    folder_contents_response: FolderContentsResponse,
    transfer_request: TransferRequest,
    transfer_response: TransferResponse,
    queue_upload: FilePath,
    place_in_queue_response: PlaceInQueueResponse,
    upload_failed: FilePath,
    upload_denied: UploadDenied,
    place_in_queue_request: FilePath,
    unknown: Unknown,

    /// Compressed.
    pub const SharedFileListResponse = struct {
        folders: []const Folder,
        /// Official clients send 0. Old clients do not send this field.
        unknown: ?u32,
        /// Folders that only some users can download. Old clients do not send this field. It
        /// needs `unknown`.
        private_folders: ?[]const Folder,
    };

    /// Compressed.
    pub const FileSearchResponse = struct {
        username: []const u8,
        /// The token of the search.
        token: u32,
        results: []const File,
        slot_available: bool,
        upload_speed: u32,
        queued_upload_count: u32,
        /// Official clients send 0. Old clients do not send this field.
        unknown: ?u32,
        /// Results that only some users can download. Old clients do not send this field. It
        /// needs `unknown`.
        private_results: ?[]const File,
    };

    pub const UserInfoResponse = struct {
        description: []const u8,
        /// Null if the user has no picture.
        picture: ?[]const u8,
        upload_slot_count: u32,
        queued_upload_count: u32,
        slot_available: bool,
        /// SoulseekQt does not send this field.
        upload_permission: ?UploadPermission,
    };

    pub const FolderContentsRequest = struct {
        token: u32,
        folder_path: []const u8,
    };

    /// Compressed.
    pub const FolderContentsResponse = struct {
        token: u32,
        folder_path: []const u8,
        /// The folder and its subfolders.
        folders: []const Folder,
    };

    pub const TransferRequest = struct {
        direction: TransferDirection,
        token: u32,
        file_path: []const u8,
        /// Only in an upload request, and required there.
        file_size: ?u64,
    };

    pub const TransferResponse = struct {
        token: u32,
        result: Result,

        pub const Result = union(enum) {
            allowed: Allowed,
            rejected: Rejected,
        };

        pub const Allowed = struct {
            /// Only in the deprecated answer to a download request.
            file_size: ?u64,
        };

        pub const Rejected = struct {
            /// See "Transfer Rejection Reasons" in the specification.
            reason: []const u8,
        };
    };

    /// The body of `QueueUpload`, `UploadFailed`, and `PlaceInQueueRequest`.
    pub const FilePath = struct {
        file_path: []const u8,
    };

    pub const PlaceInQueueResponse = struct {
        file_path: []const u8,
        place: u32,
    };

    pub const UploadDenied = struct {
        file_path: []const u8,
        /// See "Transfer Rejection Reasons" in the specification.
        reason: []const u8,
    };

    pub fn code(message: Message) u32 {
        return common.code(Code, Message, message);
    }

    /// Appends the complete frame, with the length and the code. Memory for compression comes
    /// from `writer.gpa` and is freed before the function returns.
    pub fn encode(message: Message, writer: wire.Writer) Allocator.Error!void {
        const header_offset = try frame.begin(writer, .code_u32, message.code());
        const message_code: Code = @fromBackingInt(message.code());
        if (message_code.isCompressed()) {
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(writer.gpa);
            try message.encodeBody(.init(writer.gpa, &body));
            try zlib.compress(writer, body.items);
        } else {
            try message.encodeBody(writer);
        }
        frame.end(writer, header_offset);
    }

    /// Decodes a frame with a `u32` code. Slices point into the frame body, or into memory from
    /// `arena` for a compressed message. On error, the arena can hold partial results.
    pub fn decode(
        arena: Allocator,
        message_frame: frame.Frame,
        options: DecodeOptions,
    ) DecodeError!Message {
        const message_code: Code = @fromBackingInt(message_frame.code);
        if (message_code.isCompressed()) {
            const body = try zlib.decompress(
                arena,
                message_frame.body,
                options.decompressed_size_max,
            );
            return decodeBody(arena, .{ .code = message_frame.code, .body = body });
        } else {
            return decodeBody(arena, message_frame);
        }
    }

    /// Appends the body before compression.
    fn encodeBody(message: Message, writer: wire.Writer) Allocator.Error!void {
        switch (message) {
            .shared_file_list_request, .user_info_request => {},
            .shared_file_list_response => |response| {
                try encodeFolders(writer, response.folders);
                if (response.unknown) |unknown| {
                    try writer.writeInt(u32, unknown);
                } else {
                    assert(response.private_folders == null);
                }
                if (response.private_folders) |folders| try encodeFolders(writer, folders);
            },
            .file_search_response => |response| {
                try writer.writeString(response.username);
                try writer.writeInt(u32, response.token);
                try encodeFiles(writer, response.results);
                try writer.writeBool(response.slot_available);
                try writer.writeInt(u32, response.upload_speed);
                try writer.writeInt(u32, response.queued_upload_count);
                if (response.unknown) |unknown| {
                    try writer.writeInt(u32, unknown);
                } else {
                    assert(response.private_results == null);
                }
                if (response.private_results) |results| try encodeFiles(writer, results);
            },
            .user_info_response => |response| {
                try writer.writeString(response.description);
                try writer.writeBool(response.picture != null);
                if (response.picture) |picture| try writer.writeBytes(picture);
                try writer.writeInt(u32, response.upload_slot_count);
                try writer.writeInt(u32, response.queued_upload_count);
                try writer.writeBool(response.slot_available);
                if (response.upload_permission) |permission| {
                    try writer.writeInt(u32, @backingInt(permission));
                }
            },
            .folder_contents_request => |request| {
                try writer.writeInt(u32, request.token);
                try writer.writeString(request.folder_path);
            },
            .folder_contents_response => |response| {
                try writer.writeInt(u32, response.token);
                try writer.writeString(response.folder_path);
                try encodeFolders(writer, response.folders);
            },
            .transfer_request => |request| {
                try writer.writeInt(u32, @backingInt(request.direction));
                try writer.writeInt(u32, request.token);
                try writer.writeString(request.file_path);
                if (request.direction == .upload) {
                    try writer.writeInt(u64, request.file_size.?);
                } else {
                    assert(request.file_size == null);
                }
            },
            .transfer_response => |response| {
                try writer.writeInt(u32, response.token);
                switch (response.result) {
                    .allowed => |allowed| {
                        try writer.writeBool(true);
                        if (allowed.file_size) |file_size| try writer.writeInt(u64, file_size);
                    },
                    .rejected => |rejected| {
                        try writer.writeBool(false);
                        try writer.writeString(rejected.reason);
                    },
                }
            },
            .queue_upload, .upload_failed, .place_in_queue_request => |body| {
                try writer.writeString(body.file_path);
            },
            .place_in_queue_response => |response| {
                try writer.writeString(response.file_path);
                try writer.writeInt(u32, response.place);
            },
            .upload_denied => |denied| {
                try writer.writeString(denied.file_path);
                try writer.writeString(denied.reason);
            },
            .unknown => |unknown| {
                // A known code would decode to a different tag, so the round trip would fail.
                assert(!common.isKnownCode(Code, Message, unknown.code));
                try writer.writeRaw(unknown.body);
            },
        }
    }

    /// Decodes a body after decompression.
    fn decodeBody(arena: Allocator, message_frame: frame.Frame) DecodeError!Message {
        var reader: wire.Reader = .init(message_frame.body);
        const message_code: Code = @fromBackingInt(message_frame.code);
        switch (message_code) {
            .shared_file_list_request => return .shared_file_list_request,
            .shared_file_list_response => return .{
                .shared_file_list_response = try decodeSharedFileList(arena, &reader),
            },
            .file_search_response => return .{
                .file_search_response = try decodeFileSearchResponse(arena, &reader),
            },
            .user_info_request => return .user_info_request,
            .user_info_response => return .{
                .user_info_response = try decodeUserInfoResponse(&reader),
            },
            .folder_contents_request => return .{ .folder_contents_request = .{
                .token = try reader.readInt(u32),
                .folder_path = try reader.readString(),
            } },
            .folder_contents_response => return .{ .folder_contents_response = .{
                .token = try reader.readInt(u32),
                .folder_path = try reader.readString(),
                .folders = try decodeFolders(arena, &reader),
            } },
            .transfer_request => {
                const direction: TransferDirection = @fromBackingInt(try reader.readInt(u32));
                const token = try reader.readInt(u32);
                const file_path = try reader.readString();
                const file_size = if (direction == .upload) try reader.readInt(u64) else null;
                return .{ .transfer_request = .{
                    .direction = direction,
                    .token = token,
                    .file_path = file_path,
                    .file_size = file_size,
                } };
            },
            .transfer_response => return .{
                .transfer_response = try decodeTransferResponse(&reader),
            },
            .queue_upload => return .{ .queue_upload = try decodeFilePath(&reader) },
            .place_in_queue_response => return .{ .place_in_queue_response = .{
                .file_path = try reader.readString(),
                .place = try reader.readInt(u32),
            } },
            .upload_failed => return .{ .upload_failed = try decodeFilePath(&reader) },
            .upload_denied => return .{ .upload_denied = .{
                .file_path = try reader.readString(),
                .reason = try reader.readString(),
            } },
            .place_in_queue_request => return .{
                .place_in_queue_request = try decodeFilePath(&reader),
            },
            _ => return .{ .unknown = common.unknownMessage(message_frame) },
        }
    }

    fn decodeSharedFileList(
        arena: Allocator,
        reader: *wire.Reader,
    ) DecodeError!SharedFileListResponse {
        var response: SharedFileListResponse = .{
            .folders = try decodeFolders(arena, reader),
            .unknown = null,
            .private_folders = null,
        };
        // Old clients end the message after the folders. Read each optional field if there are
        // bytes left, the same as Nicotine+.
        if (reader.remaining() > 0) response.unknown = try reader.readInt(u32);
        if (reader.remaining() > 0) response.private_folders = try decodeFolders(arena, reader);
        return response;
    }

    fn decodeFileSearchResponse(
        arena: Allocator,
        reader: *wire.Reader,
    ) DecodeError!FileSearchResponse {
        var response: FileSearchResponse = .{
            .username = try reader.readString(),
            .token = try reader.readInt(u32),
            .results = try decodeFiles(arena, reader),
            .slot_available = try reader.readBool(),
            .upload_speed = try reader.readInt(u32),
            .queued_upload_count = try reader.readInt(u32),
            .unknown = null,
            .private_results = null,
        };
        // Old clients end the message after the queue size. Read each optional field if there
        // are bytes left, the same as Nicotine+.
        if (reader.remaining() > 0) response.unknown = try reader.readInt(u32);
        if (reader.remaining() > 0) response.private_results = try decodeFiles(arena, reader);
        return response;
    }

    fn decodeUserInfoResponse(reader: *wire.Reader) DecodeError!UserInfoResponse {
        const description = try reader.readString();
        const has_picture = try reader.readBool();
        var response: UserInfoResponse = .{
            .description = description,
            .picture = if (has_picture) try reader.readBytes() else null,
            .upload_slot_count = try reader.readInt(u32),
            .queued_upload_count = try reader.readInt(u32),
            .slot_available = try reader.readBool(),
            .upload_permission = null,
        };
        // Museek+ sends `slot_available` as a u32, so 3 bytes of that u32 follow the bool. Read
        // the permission only if a complete u32 is left, the same as Nicotine+.
        if (reader.remaining() >= @sizeOf(u32)) {
            response.upload_permission = @fromBackingInt(try reader.readInt(u32));
        }
        return response;
    }

    fn decodeTransferResponse(reader: *wire.Reader) DecodeError!TransferResponse {
        const token = try reader.readInt(u32);
        const allowed = try reader.readBool();
        if (allowed) {
            // Only the deprecated answer to a download request has a file size.
            const file_size = if (reader.remaining() > 0) try reader.readInt(u64) else null;
            return .{ .token = token, .result = .{ .allowed = .{ .file_size = file_size } } };
        } else {
            const reason = try reader.readString();
            return .{ .token = token, .result = .{ .rejected = .{ .reason = reason } } };
        }
    }

    fn decodeFilePath(reader: *wire.Reader) DecodeError!FilePath {
        return .{ .file_path = try reader.readString() };
    }
};

fn encodeFolders(writer: wire.Writer, folders: []const Folder) Allocator.Error!void {
    try writeCount(writer, folders.len);
    for (folders) |folder| {
        try writer.writeString(folder.path);
        try encodeFiles(writer, folder.files);
    }
}

fn encodeFiles(writer: wire.Writer, files: []const File) Allocator.Error!void {
    try writeCount(writer, files.len);
    for (files) |file| {
        // The specification gives no meaning for this code, and its value is always 1.
        try writer.writeInt(u8, 1);
        try writer.writeString(file.path);
        try writer.writeInt(u64, file.size);
        try writer.writeString(file.extension);
        try writeCount(writer, file.attributes.len);
        for (file.attributes) |attribute| {
            try writer.writeInt(u32, @backingInt(attribute.code));
            try writer.writeInt(u32, attribute.value);
        }
    }
}

fn writeCount(writer: wire.Writer, count: usize) Allocator.Error!void {
    // A longer list cannot be encoded. The caller must check the length of foreign data.
    assert(count <= std.math.maxInt(u32));
    try writer.writeInt(u32, @intCast(count));
}

fn decodeFolders(arena: Allocator, reader: *wire.Reader) DecodeError![]const Folder {
    const folders = try arena.alloc(Folder, try readCount(reader, folder_size_min));
    for (folders) |*folder| {
        folder.* = .{
            .path = try reader.readString(),
            .files = try decodeFiles(arena, reader),
        };
    }
    return folders;
}

fn decodeFiles(arena: Allocator, reader: *wire.Reader) DecodeError![]const File {
    const files = try arena.alloc(File, try readCount(reader, file_size_min));
    for (files) |*file| {
        // The code is always 1. Ignore it, the same as Nicotine+.
        _ = try reader.readInt(u8);
        const path = try reader.readString();
        const size = try reader.readInt(u64);
        const extension = try reader.readString();
        const attribute_count = try readCount(reader, attribute_size_min);
        const attributes = try arena.alloc(FileAttribute, attribute_count);
        for (attributes) |*attribute| {
            attribute.* = .{
                .code = @fromBackingInt(try reader.readInt(u32)),
                .value = try reader.readInt(u32),
            };
        }
        file.* = .{ .path = path, .size = size, .extension = extension, .attributes = attributes };
    }
    return files;
}

/// Reads a list count. Each element takes at least `element_size_min` bytes, so a count that
/// the rest of the body cannot hold gives `EndOfMessage`. Then a bad count cannot cause an
/// allocation that is larger than the body.
fn readCount(reader: *wire.Reader, comptime element_size_min: u32) wire.Reader.Error!u32 {
    comptime assert(element_size_min > 0);
    const count = try reader.readInt(u32);
    if (count <= reader.remaining() / element_size_min) {
        return count;
    } else {
        return error.EndOfMessage;
    }
}

comptime {
    // Each code has a tag, and each union has an `unknown` tag.
    for (@typeInfo(InitCode).@"enum".field_names) |name| assert(@hasField(Init, name));
    for (@typeInfo(Code).@"enum".field_names) |name| assert(@hasField(Message, name));
    assert(@typeInfo(Init).@"union".field_names.len == 3);
    assert(@typeInfo(Message).@"union".field_names.len == 15);
}

const testing = std.testing;
const test_support = @import("test_support.zig");
const intBytes = test_support.intBytes;
const stringBytes = test_support.stringBytes;

/// The options for the tests. Each test body is much smaller.
const test_options: DecodeOptions = .{ .decompressed_size_max = 64 * 1024 };

fn Golden(comptime T: type) type {
    return struct {
        message: T,
        /// The complete frame.
        bytes: []const u8,
    };
}

/// A golden vector for a compressed message.
const CompressedGolden = struct {
    message: Message,
    /// The body before compression.
    body: []const u8,
    /// The complete frame. The body is compressed with Python `zlib.compress(body, 4)`, the
    /// same function and level as Nicotine+.
    bytes: []const u8,
};

fn initFrame(comptime code: InitCode, comptime body: []const u8) []const u8 {
    return test_support.frameBytes(.code_u8, @backingInt(code), body);
}

fn peerFrame(comptime code: Code, comptime body: []const u8) []const u8 {
    return test_support.frameBytes(.code_u32, @backingInt(code), body);
}

fn splitFrame(bytes: []const u8) frame.Frame {
    return test_support.splitFrame(.code_u32, bytes);
}

/// Vectors from the data order in the specification. Nicotine+ has no vectors for peer
/// messages.
const init_golden = [_]Golden(Init){
    .{
        .message = .{ .pierce_firewall = .{ .token = 0x12345678 } },
        .bytes = initFrame(.pierce_firewall, &.{ 0x78, 0x56, 0x34, 0x12 }),
    },
    .{
        .message = .{ .peer_init = .{ .username = "bob", .connection_type = .peer, .token = 0 } },
        .bytes = initFrame(.peer_init, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00, 'P' } ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 })),
    },
    .{
        .message = .{ .peer_init = .{ .username = "al", .connection_type = .file, .token = 0 } },
        .bytes = initFrame(.peer_init, &([_]u8{ 0x02, 0x00, 0x00, 0x00, 'a', 'l' } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00, 'F' } ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 })),
    },
};

/// Vectors from the data order in the specification, for messages that are not compressed.
const message_golden = [_]Golden(Message){
    .{
        .message = .shared_file_list_request,
        .bytes = peerFrame(.shared_file_list_request, ""),
    },
    .{
        .message = .user_info_request,
        .bytes = peerFrame(.user_info_request, ""),
    },
    .{
        .message = .{ .user_info_response = .{
            .description = "hi",
            .picture = &.{ 0x89, 'P', 'N', 'G' },
            .upload_slot_count = 2,
            .queued_upload_count = 5,
            .slot_available = true,
            .upload_permission = .everyone,
        } },
        .bytes = peerFrame(.user_info_response, &([_]u8{ 0x02, 0x00, 0x00, 0x00, 'h', 'i' } ++
            [_]u8{0x01} ++
            [_]u8{ 0x04, 0x00, 0x00, 0x00, 0x89, 'P', 'N', 'G' } ++
            [_]u8{ 0x02, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x05, 0x00, 0x00, 0x00 } ++
            [_]u8{0x01} ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00 })),
    },
    // No picture, and no upload permission (SoulseekQt).
    .{
        .message = .{ .user_info_response = .{
            .description = "",
            .picture = null,
            .upload_slot_count = 0,
            .queued_upload_count = 0,
            .slot_available = false,
            .upload_permission = null,
        } },
        .bytes = peerFrame(.user_info_response, &([_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
            [_]u8{0x00} ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
            [_]u8{0x00})),
    },
    .{
        .message = .{ .folder_contents_request = .{ .token = 7, .folder_path = "@@ab\\M" } },
        .bytes = peerFrame(.folder_contents_request, &([_]u8{ 0x07, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x06, 0x00, 0x00, 0x00, '@', '@', 'a', 'b', '\\', 'M' })),
    },
    .{
        .message = .{ .transfer_request = .{
            .direction = .upload,
            .token = 0x12345678,
            .file_path = "a\\b",
            .file_size = 0x0000000123456789,
        } },
        .bytes = peerFrame(.transfer_request, &([_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x78, 0x56, 0x34, 0x12 } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'a', '\\', 'b' } ++
            [_]u8{ 0x89, 0x67, 0x45, 0x23, 0x01, 0x00, 0x00, 0x00 })),
    },
    // A download request has no file size.
    .{
        .message = .{ .transfer_request = .{
            .direction = .download,
            .token = 1,
            .file_path = "a\\b",
            .file_size = null,
        } },
        .bytes = peerFrame(.transfer_request, &([_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'a', '\\', 'b' })),
    },
    // The upload response.
    .{
        .message = .{ .transfer_response = .{
            .token = 0x12345678,
            .result = .{ .allowed = .{ .file_size = null } },
        } },
        .bytes = peerFrame(.transfer_response, &([_]u8{ 0x78, 0x56, 0x34, 0x12 } ++
            [_]u8{0x01})),
    },
    .{
        .message = .{ .transfer_response = .{
            .token = 0x12345678,
            .result = .{ .rejected = .{ .reason = "Queued" } },
        } },
        .bytes = peerFrame(.transfer_response, &([_]u8{ 0x78, 0x56, 0x34, 0x12 } ++
            [_]u8{0x00} ++
            [_]u8{ 0x06, 0x00, 0x00, 0x00, 'Q', 'u', 'e', 'u', 'e', 'd' })),
    },
    // The deprecated download response.
    .{
        .message = .{ .transfer_response = .{
            .token = 2,
            .result = .{ .allowed = .{ .file_size = 1000 } },
        } },
        .bytes = peerFrame(.transfer_response, &([_]u8{ 0x02, 0x00, 0x00, 0x00 } ++
            [_]u8{0x01} ++
            [_]u8{ 0xe8, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 })),
    },
    .{
        .message = .{ .queue_upload = .{ .file_path = "a\\b" } },
        .bytes = peerFrame(.queue_upload, &.{ 0x03, 0x00, 0x00, 0x00, 'a', '\\', 'b' }),
    },
    .{
        .message = .{ .place_in_queue_response = .{ .file_path = "a\\b", .place = 12 } },
        .bytes = peerFrame(.place_in_queue_response, &([_]u8{ 0x03, 0x00, 0x00, 0x00 } ++
            [_]u8{ 'a', '\\', 'b' } ++
            [_]u8{ 0x0c, 0x00, 0x00, 0x00 })),
    },
    .{
        .message = .{ .upload_failed = .{ .file_path = "a\\b" } },
        .bytes = peerFrame(.upload_failed, &.{ 0x03, 0x00, 0x00, 0x00, 'a', '\\', 'b' }),
    },
    .{
        .message = .{ .upload_denied = .{ .file_path = "a\\b", .reason = "Banned" } },
        .bytes = peerFrame(.upload_denied, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'a', '\\', 'b' } ++
            [_]u8{ 0x06, 0x00, 0x00, 0x00, 'B', 'a', 'n', 'n', 'e', 'd' })),
    },
    .{
        .message = .{ .place_in_queue_request = .{ .file_path = "a\\b" } },
        .bytes = peerFrame(.place_in_queue_request, &.{ 0x03, 0x00, 0x00, 0x00, 'a', '\\', 'b' }),
    },
};

const song_attributes = [_]FileAttribute{
    .{ .code = .bitrate, .value = 320 },
    .{ .code = .duration, .value = 200 },
};

/// A file in a folder list.
const song: File = .{
    .path = "song.mp3",
    .size = 4000000,
    .extension = "mp3",
    .attributes = &song_attributes,
};

const song_bytes = intBytes(u8, 1) ++ stringBytes("song.mp3") ++ intBytes(u64, 4000000) ++
    stringBytes("mp3") ++ intBytes(u32, 2) ++
    intBytes(u32, 0) ++ intBytes(u32, 320) ++
    intBytes(u32, 1) ++ intBytes(u32, 200);

const flac_attributes = [_]FileAttribute{
    .{ .code = .duration, .value = 180 },
    .{ .code = .sample_rate, .value = 44100 },
    .{ .code = .bit_depth, .value = 16 },
};

/// A file of more than 4 GiB, with an empty extension (as from SoulseekQt).
const flac: File = .{
    .path = "a.flac",
    .size = 5000000000,
    .extension = "",
    .attributes = &flac_attributes,
};

const flac_bytes = intBytes(u8, 1) ++ stringBytes("a.flac") ++ intBytes(u64, 5000000000) ++
    stringBytes("") ++ intBytes(u32, 3) ++
    intBytes(u32, 1) ++ intBytes(u32, 180) ++
    intBytes(u32, 4) ++ intBytes(u32, 44100) ++
    intBytes(u32, 5) ++ intBytes(u32, 16);

const search_result_attributes = [_]FileAttribute{
    .{ .code = .bitrate, .value = 320 },
    .{ .code = .vbr, .value = 0 },
};

/// Vectors from the data order in the specification. The compressed bytes were made with this
/// Python code, where `body` is the `body` field of the vector:
///
///     zlib.compress(body, 4)
const compressed_golden = [_]CompressedGolden{
    .{
        .message = .{ .shared_file_list_response = .{
            .folders = &.{
                .{ .path = "@@abcde\\Music", .files = &.{song} },
                .{ .path = "@@abcde\\Empty", .files = &.{} },
            },
            .unknown = 0,
            .private_folders = &.{
                .{ .path = "@@abcde\\Buddies", .files = &.{flac} },
            },
        } },
        .body = intBytes(u32, 2) ++
            stringBytes("@@abcde\\Music") ++ intBytes(u32, 1) ++ song_bytes ++
            stringBytes("@@abcde\\Empty") ++ intBytes(u32, 0) ++
            intBytes(u32, 0) ++
            intBytes(u32, 1) ++
            stringBytes("@@abcde\\Buddies") ++ intBytes(u32, 1) ++ flac_bytes,
        .bytes = peerFrame(.shared_file_list_response, "" ++
            "\x78\x5e\x63\x62\x60\x60\xe0\x05\x62\x07\x87\xc4\xa4\xe4\x94\xd4" ++
            "\x18\xdf\xd2\xe2\xcc\x64\x46\xa0\x00\x23\x07\x90\x28\xce\xcf\x4b" ++
            "\xd7\xcb\x2d\x30\x66\xe0\xb4\x65\x00\x01\x66\x20\x06\x72\x99\xc0" ++
            "\x1c\xa0\x26\xa0\x42\x90\xda\x13\x68\x86\xb8\xe6\x16\x94\x54\x42" ++
            "\xd5\x80\x15\xf0\x23\x49\x3a\x95\xa6\xa4\x64\xa6\x16\x83\xed\x60" ++
            "\x03\x12\x89\x7a\x69\x39\x89\xc9\x0c\x9f\x58\xb5\x40\x42\x20\x00" ++
            "\xb2\x05\xc4\xde\x02\xc4\x2c\x40\xec\xb2\x86\x81\x81\x15\x48\x0b" ++
            "\x00\x31\x00\xa6\x28\x19\xd2"),
    },
    // An old client sends only the folders.
    .{
        .message = .{ .shared_file_list_response = .{
            .folders = &.{},
            .unknown = null,
            .private_folders = null,
        } },
        .body = intBytes(u32, 0),
        .bytes = peerFrame(
            .shared_file_list_response,
            "\x78\x5e\x63\x60\x60\x60\x00\x00\x00\x04\x00\x01",
        ),
    },
    // The unknown field, but no private folders.
    .{
        .message = .{ .shared_file_list_response = .{
            .folders = &.{.{ .path = "@@abcde\\Music", .files = &.{song} }},
            .unknown = 0,
            .private_folders = null,
        } },
        .body = intBytes(u32, 1) ++
            stringBytes("@@abcde\\Music") ++ intBytes(u32, 1) ++ song_bytes ++
            intBytes(u32, 0),
        .bytes = peerFrame(.shared_file_list_response, "" ++
            "\x78\x5e\x63\x64\x60\x60\xe0\x05\x62\x07\x87\xc4\xa4\xe4\x94\xd4" ++
            "\x18\xdf\xd2\xe2\xcc\x64\x46\xa0\x00\x23\x07\x90\x28\xce\xcf\x4b" ++
            "\xd7\xcb\x2d\x30\x66\xe0\xb4\x65\x00\x01\x66\x20\x06\x72\x99\xc0" ++
            "\x1c\xa0\x26\xa0\x42\x90\xda\x13\x50\x3e\x00\xe5\x30\x0a\x3f"),
    },
    .{
        .message = .{ .file_search_response = .{
            .username = "bob",
            .token = 0x12345678,
            .results = &.{.{
                .path = "@@abcde\\Music\\song.mp3",
                .size = 4000000,
                .extension = "mp3",
                .attributes = &search_result_attributes,
            }},
            .slot_available = true,
            .upload_speed = 1000,
            .queued_upload_count = 3,
            .unknown = 0,
            .private_results = &.{.{
                .path = "@@abcde\\Buddies\\a.flac",
                .size = 123,
                .extension = "",
                .attributes = &.{},
            }},
        } },
        .body = stringBytes("bob") ++ intBytes(u32, 0x12345678) ++
            intBytes(u32, 1) ++
            intBytes(u8, 1) ++ stringBytes("@@abcde\\Music\\song.mp3") ++
            intBytes(u64, 4000000) ++ stringBytes("mp3") ++ intBytes(u32, 2) ++
            intBytes(u32, 0) ++ intBytes(u32, 320) ++
            intBytes(u32, 2) ++ intBytes(u32, 0) ++
            intBytes(u8, 1) ++ intBytes(u32, 1000) ++ intBytes(u32, 3) ++
            intBytes(u32, 0) ++
            intBytes(u32, 1) ++
            intBytes(u8, 1) ++ stringBytes("@@abcde\\Buddies\\a.flac") ++
            intBytes(u64, 123) ++ stringBytes("") ++ intBytes(u32, 0),
        .bytes = peerFrame(.file_search_response, "" ++
            "\x78\x5e\x63\x66\x60\x60\x48\xca\x4f\xaa\x08\x33\x11\x62\x04\x32" ++
            "\x19\xc5\x80\x84\x83\x43\x62\x52\x72\x4a\x6a\x8c\x6f\x69\x71\x66" ++
            "\x72\x4c\x71\x7e\x5e\xba\x5e\x6e\x81\x31\x03\xa7\x2d\x03\x08\x30" ++
            "\x03\x31\x90\xcb\x04\xe6\x00\x15\x03\xb5\xc1\xd8\x8c\x2f\x98\x21" ++
            "\xf2\x60\x0e\x08\x23\x1b\xe7\x54\x9a\x92\x92\x99\x5a\x1c\x93\xa8" ++
            "\x97\x96\x93\x98\x5c\x0d\x55\x06\x03\x00\x39\x8c\x15\xac"),
    },
    // An old client ends the message after the queue size.
    .{
        .message = .{ .file_search_response = .{
            .username = "bob",
            .token = 42,
            .results = &.{},
            .slot_available = false,
            .upload_speed = 0,
            .queued_upload_count = 0,
            .unknown = null,
            .private_results = null,
        } },
        .body = stringBytes("bob") ++ intBytes(u32, 42) ++ intBytes(u32, 0) ++
            intBytes(u8, 0) ++ intBytes(u32, 0) ++ intBytes(u32, 0),
        .bytes = peerFrame(
            .file_search_response,
            "\x78\x5e\x63\x66\x60\x60\x48\xca\x4f\xd2\x62\x40\x03\x00\x19\xf3\x01\x61",
        ),
    },
    .{
        .message = .{ .folder_contents_response = .{
            .token = 7,
            .folder_path = "@@abcde\\Music",
            .folders = &.{
                .{ .path = "@@abcde\\Music", .files = &.{song} },
                .{ .path = "@@abcde\\Music\\Sub", .files = &.{} },
            },
        } },
        .body = intBytes(u32, 7) ++ stringBytes("@@abcde\\Music") ++
            intBytes(u32, 2) ++
            stringBytes("@@abcde\\Music") ++ intBytes(u32, 1) ++ song_bytes ++
            stringBytes("@@abcde\\Music\\Sub") ++ intBytes(u32, 0),
        .bytes = peerFrame(.folder_contents_response, "" ++
            "\x78\x5e\x63\x67\x60\x60\xe0\x05\x62\x07\x87\xc4\xa4\xe4\x94\xd4" ++
            "\x18\xdf\xd2\xe2\xcc\x64\x26\x6c\x82\x8c\x40\x01\x46\x0e\x20\x51" ++
            "\x9c\x9f\x97\xae\x97\x5b\x60\xcc\xc0\x69\xcb\x00\x02\xcc\x40\x0c" ++
            "\xe4\x82\x34\x81\x80\x03\x50\x21\x48\xed\x09\x20\x16\x44\x37\x24" ++
            "\x26\xb8\x34\x09\xa4\x08\x00\x0d\x64\x15\x83"),
    },
};

comptime {
    // Each tag except `unknown` has at least one golden vector.
    for (@typeInfo(Init).@"union".field_names) |name| {
        if (std.mem.eql(u8, name, "unknown")) continue;
        for (init_golden) |entry| {
            if (std.mem.eql(u8, @tagName(entry.message), name)) break;
        } else @compileError("no golden vector for Init." ++ name);
    }
    for (@typeInfo(Message).@"union".field_names) |name| {
        if (std.mem.eql(u8, name, "unknown")) continue;
        const code: Code = @field(Code, name);
        if (code.isCompressed()) {
            for (compressed_golden) |entry| {
                if (std.mem.eql(u8, @tagName(entry.message), name)) break;
            } else @compileError("no golden vector for Message." ++ name);
        } else {
            for (message_golden) |entry| {
                if (std.mem.eql(u8, @tagName(entry.message), name)) break;
            } else @compileError("no golden vector for Message." ++ name);
        }
    }
    // The compressed vectors are only in `compressed_golden`.
    for (message_golden) |entry| {
        const code: Code = @fromBackingInt(entry.message.code());
        assert(!code.isCompressed());
    }
}

test "Init golden vectors" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    for (init_golden) |entry| {
        list.clearRetainingCapacity();
        try entry.message.encode(writer);
        try testing.expectEqualSlices(u8, entry.bytes, list.items);
        const message_frame = test_support.splitFrame(.code_u8, entry.bytes);
        try testing.expectEqualDeep(entry.message, try Init.decode(message_frame));
    }
}

test "Message golden vectors" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    for (message_golden) |entry| {
        list.clearRetainingCapacity();
        try entry.message.encode(writer);
        try testing.expectEqualSlices(u8, entry.bytes, list.items);
        const message_frame = splitFrame(entry.bytes);
        const decoded = try Message.decode(arena_state.allocator(), message_frame, test_options);
        try testing.expectEqualDeep(entry.message, decoded);
    }
}

test "compressed golden vectors" {
    // The compressed bytes depend on the compressor, so the encoder output cannot equal the
    // Python bytes. Instead, the test checks the body before compression, and checks that the
    // encoder output decompresses to that body.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);
    const size_max = test_options.decompressed_size_max;

    for (compressed_golden) |entry| {
        // The vector is consistent: the Python bytes decompress to the body.
        const python_frame = splitFrame(entry.bytes);
        const python_body = try zlib.decompress(arena, python_frame.body, size_max);
        try testing.expectEqualSlices(u8, entry.body, python_body);

        const decoded = try Message.decode(arena, python_frame, test_options);
        try testing.expectEqualDeep(entry.message, decoded);

        list.clearRetainingCapacity();
        try entry.message.encodeBody(writer);
        try testing.expectEqualSlices(u8, entry.body, list.items);

        list.clearRetainingCapacity();
        try entry.message.encode(writer);
        const encoded = splitFrame(list.items);
        try testing.expectEqual(python_frame.code, encoded.code);
        const encoded_body = try zlib.decompress(arena, encoded.body, size_max);
        try testing.expectEqualSlices(u8, entry.body, encoded_body);
    }
}

/// Encodes `message`, decodes the bytes, and checks that the result is the same.
fn expectRoundTrip(message: Message) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));
    const message_frame = splitFrame(list.items);
    const decoded = try Message.decode(arena_state.allocator(), message_frame, test_options);
    try testing.expectEqualDeep(message, decoded);
}

fn expectInitRoundTrip(message: Init) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));
    const decoded = try Init.decode(test_support.splitFrame(.code_u8, list.items));
    try testing.expectEqualDeep(message, decoded);
}

test "round trips with other values" {
    // Extreme values, empty strings, raw bytes that are not UTF-8, and unknown enum values.
    try expectInitRoundTrip(.{ .pierce_firewall = .{ .token = std.math.maxInt(u32) } });
    inline for (.{ .peer, .file, .distributed }) |connection_type| {
        try expectInitRoundTrip(.{ .peer_init = .{
            .username = &.{ 0xc3, 0x28 },
            .connection_type = connection_type,
            .token = std.math.maxInt(u32),
        } });
    }

    const attributes = [_]FileAttribute{
        .{ .code = @fromBackingInt(std.math.maxInt(u32)), .value = std.math.maxInt(u32) },
        .{ .code = .encoder, .value = 0 },
    };
    const files = [_]File{
        .{ .path = "", .size = std.math.maxInt(u64), .extension = "", .attributes = &attributes },
        .{ .path = &.{ 0xff, 0xfe }, .size = 0, .extension = "flac", .attributes = &.{} },
    };
    try expectRoundTrip(.{ .shared_file_list_response = .{
        .folders = &.{ .{ .path = "", .files = &files }, .{ .path = "x", .files = &.{} } },
        .unknown = std.math.maxInt(u32),
        .private_folders = &.{},
    } });
    try expectRoundTrip(.{ .file_search_response = .{
        .username = "",
        .token = std.math.maxInt(u32),
        .results = &files,
        .slot_available = true,
        .upload_speed = std.math.maxInt(u32),
        .queued_upload_count = std.math.maxInt(u32),
        .unknown = 0,
        .private_results = null,
    } });
    try expectRoundTrip(.{ .folder_contents_response = .{
        .token = 0,
        .folder_path = "",
        .folders = &.{},
    } });
    try expectRoundTrip(.{
        .user_info_response = .{
            .description = &.{ 0xc3, 0x28 },
            // An empty picture is not the same as no picture.
            .picture = "",
            .upload_slot_count = std.math.maxInt(u32),
            .queued_upload_count = std.math.maxInt(u32),
            .slot_available = true,
            .upload_permission = @fromBackingInt(9),
        },
    });
    try expectRoundTrip(.{ .transfer_request = .{
        .direction = .upload,
        .token = 0,
        .file_path = "",
        .file_size = std.math.maxInt(u64),
    } });
    // An unknown direction has no file size.
    try expectRoundTrip(.{ .transfer_request = .{
        .direction = @fromBackingInt(2),
        .token = 0,
        .file_path = "",
        .file_size = null,
    } });
    try expectRoundTrip(.{ .transfer_response = .{
        .token = 0,
        .result = .{ .allowed = .{ .file_size = std.math.maxInt(u64) } },
    } });
    try expectRoundTrip(.{ .transfer_response = .{
        .token = 0,
        .result = .{ .rejected = .{ .reason = "" } },
    } });
    try expectRoundTrip(.{ .place_in_queue_response = .{
        .file_path = "",
        .place = std.math.maxInt(u32),
    } });
}

test "large shared file list" {
    // A list of more than 64 KiB, so that the compressed stream has many blocks.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const folders = try arena.alloc(Folder, 100);
    for (folders, 0..) |*folder, folder_index| {
        const files = try arena.alloc(File, 50);
        for (files, 0..) |*file, file_index| {
            file.* = .{
                .path = try arena.print("track {d:0>2}.flac", .{file_index}),
                .size = folder_index * 1000 + file_index,
                .extension = "flac",
                .attributes = &flac_attributes,
            };
        }
        const path = try arena.print("@@abcde\\Music\\{d}", .{folder_index});
        folder.* = .{ .path = path, .files = files };
    }
    const message: Message = .{ .shared_file_list_response = .{
        .folders = folders,
        .unknown = 0,
        .private_folders = &.{},
    } };

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));
    const options: DecodeOptions = .{ .decompressed_size_max = 1024 * 1024 };
    const message_frame = splitFrame(list.items);
    try testing.expectEqualDeep(message, try Message.decode(arena, message_frame, options));

    // The same list with a smaller limit.
    try testing.expectError(
        error.DecompressedTooLarge,
        Message.decode(arena, splitFrame(list.items), .{ .decompressed_size_max = 64 * 1024 }),
    );
}

test "unknown codes decode to unknown" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body = "any body";

    // Unknown and obsolete codes: PrivateMessage (1), FileSearchRequest (8), PlaceholdUpload
    // (42), and UploadQueueNotification (52). FileSearchRequest is a compressed code in no
    // version of the protocol, so its body is not decompressed.
    for ([_]u32{ 1, 8, 42, 52, 9999 }) |code| {
        try testing.expect(!common.isKnownCode(Code, Message, code));
        const message_frame: frame.Frame = .{ .code = code, .body = body };
        try testing.expectEqualDeep(
            Message{ .unknown = .{ .code = code, .body = body } },
            try Message.decode(arena, message_frame, test_options),
        );
        try expectRoundTrip(.{ .unknown = .{ .code = code, .body = body } });
    }

    for ([_]u32{ 2, 0xff }) |code| {
        try testing.expect(!common.isKnownCode(InitCode, Init, code));
        const message_frame: frame.Frame = .{ .code = code, .body = body };
        try testing.expectEqualDeep(
            Init{ .unknown = .{ .code = code, .body = body } },
            try Init.decode(message_frame),
        );
        try expectInitRoundTrip(.{ .unknown = .{ .code = code, .body = "" } });
    }
}

test "bytes after the last field are ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const message_frame: frame.Frame = .{
        .code = @backingInt(Code.upload_denied),
        .body = comptime stringBytes("a") ++ stringBytes("Banned") ++ "\xaa\xbb",
    };
    try testing.expectEqualDeep(
        Message{ .upload_denied = .{ .file_path = "a", .reason = "Banned" } },
        try Message.decode(arena_state.allocator(), message_frame, test_options),
    );

    const init_frame: frame.Frame = .{
        .code = @backingInt(InitCode.pierce_firewall),
        .body = comptime intBytes(u32, 5) ++ "\xaa",
    };
    try testing.expectEqualDeep(
        Init{ .pierce_firewall = .{ .token = 5 } },
        try Init.decode(init_frame),
    );
}

test "UserInfoResponse from Museek+" {
    // Museek+ sends `slot_available` as a u32 and no upload permission. The 3 bytes after the
    // bool are not a complete permission, so the decoder ignores them.
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const message_frame: frame.Frame = .{
        .code = @backingInt(Code.user_info_response),
        .body = comptime stringBytes("hi") ++ intBytes(u8, 0) ++
            intBytes(u32, 1) ++ intBytes(u32, 0) ++ intBytes(u32, 1),
    };
    try testing.expectEqualDeep(Message{ .user_info_response = .{
        .description = "hi",
        .picture = null,
        .upload_slot_count = 1,
        .queued_upload_count = 0,
        .slot_available = true,
        .upload_permission = null,
    } }, try Message.decode(arena_state.allocator(), message_frame, test_options));
}

test "invalid connection type in PeerInit" {
    const message_frame: frame.Frame = .{
        .code = @backingInt(InitCode.peer_init),
        .body = comptime stringBytes("bob") ++ stringBytes("X") ++ intBytes(u32, 0),
    };
    try testing.expectError(error.InvalidConnectionType, Init.decode(message_frame));
}

test "bad zlib data in compressed messages" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const compressed_codes = [_]Code{
        .shared_file_list_response,
        .file_search_response,
        .folder_contents_response,
    };
    for (compressed_codes) |code| {
        // Bodies that are not valid zlib streams.
        for ([_][]const u8{ "", "not zlib data", "\x78\x5e", "\x78\x5e\x07\x00" }) |body| {
            const message_frame: frame.Frame = .{ .code = @backingInt(code), .body = body };
            try testing.expectError(
                error.InvalidCompressedData,
                Message.decode(arena, message_frame, test_options),
            );
        }
        // A body that is not compressed. The first entry of each list is a valid message.
        for (compressed_golden) |entry| {
            if (entry.message.code() != @backingInt(code)) continue;
            const message_frame: frame.Frame = .{ .code = @backingInt(code), .body = entry.body };
            try testing.expectError(
                error.InvalidCompressedData,
                Message.decode(arena, message_frame, test_options),
            );
        }
    }

    // Each golden vector, truncated or with a wrong checksum.
    for (compressed_golden) |entry| {
        const python_frame = splitFrame(entry.bytes);
        const truncated: frame.Frame = .{
            .code = python_frame.code,
            .body = python_frame.body[0 .. python_frame.body.len - 1],
        };
        try testing.expectError(
            error.InvalidCompressedData,
            Message.decode(arena, truncated, test_options),
        );

        const body = try arena.dupe(u8, python_frame.body);
        body[body.len - 1] ^= 0x01;
        try testing.expectError(
            error.InvalidCompressedData,
            Message.decode(arena, .{ .code = python_frame.code, .body = body }, test_options),
        );
    }
}

/// Compresses `body` as the body of a frame with `code`.
fn compressedFrame(list: *std.ArrayList(u8), code: Code, body: []const u8) !frame.Frame {
    list.clearRetainingCapacity();
    try zlib.compress(.init(testing.allocator, list), body);
    return .{ .code = @backingInt(code), .body = list.items };
}

test "a valid zlib stream with a bad body" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);

    // A count of 0xffffffff folders must give an error before the decoder allocates the list.
    // The decompressor fits in a buffer of 256 KiB, but the list (about 128 GiB) does not. So
    // `EndOfMessage` (not `OutOfMemory`) proves that the decoder does not try to allocate it.
    const count_max: [4]u8 = .{ 0xff, 0xff, 0xff, 0xff };
    var message_frame = try compressedFrame(&list, .shared_file_list_response, &count_max);
    const small_buffer = try testing.allocator.alloc(u8, 256 * 1024);
    defer testing.allocator.free(small_buffer);
    var small: std.heap.FixedBufferAllocator = .init(small_buffer);
    try testing.expectError(
        error.EndOfMessage,
        Message.decode(small.allocator(), message_frame, test_options),
    );

    // A count that is one more than the files in the body.
    message_frame = try compressedFrame(
        &list,
        .folder_contents_response,
        comptime intBytes(u32, 7) ++ stringBytes("f") ++ intBytes(u32, 1) ++ stringBytes("f") ++
            intBytes(u32, 2) ++ song_bytes,
    );
    try testing.expectError(error.EndOfMessage, Message.decode(arena, message_frame, test_options));

    // An empty body.
    message_frame = try compressedFrame(&list, .file_search_response, "");
    try testing.expectError(error.EndOfMessage, Message.decode(arena, message_frame, test_options));
}

test "readCount limits the count to the rest of the body" {
    // 16 bytes after the count hold at most 2 elements of 8 bytes.
    const elements: [16]u8 = comptime @splat(0);
    var reader: wire.Reader = .init(comptime intBytes(u32, 2) ++ elements);
    try testing.expectEqual(2, try readCount(&reader, 8));
    reader = .init(comptime intBytes(u32, 3) ++ elements);
    try testing.expectError(error.EndOfMessage, readCount(&reader, 8));
    reader = .init(comptime intBytes(u32, 0));
    try testing.expectEqual(0, try readCount(&reader, 8));
    reader = .init(comptime intBytes(u32, std.math.maxInt(u32)) ++ elements);
    try testing.expectError(error.EndOfMessage, readCount(&reader, 1));
}

/// Checks each prefix of a body (before compression). A prefix must give `EndOfMessage`, or a
/// message that encodes to a prefix of the prefix. The second case happens where an optional
/// field starts, and in a `UserInfoResponse` with 1 to 3 bytes of the upload permission.
fn expectMessagePrefixes(arena: Allocator, code: u32, body: []const u8) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    for (0..body.len) |prefix_size| {
        const prefix: frame.Frame = .{ .code = code, .body = body[0..prefix_size] };
        const message = Message.decodeBody(arena, prefix) catch |err| {
            try testing.expectEqual(error.EndOfMessage, err);
            continue;
        };
        list.clearRetainingCapacity();
        try message.encodeBody(writer);
        try testing.expect(std.mem.startsWith(u8, prefix.body, list.items));
    }
}

test "truncated bodies" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (message_golden) |entry| {
        const message_frame = splitFrame(entry.bytes);
        try expectMessagePrefixes(arena, message_frame.code, message_frame.body);
    }
    for (compressed_golden) |entry| {
        try expectMessagePrefixes(arena, entry.message.code(), entry.body);
    }

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    for (init_golden) |entry| {
        const full = test_support.splitFrame(.code_u8, entry.bytes);
        for (0..full.body.len) |prefix_size| {
            const prefix: frame.Frame = .{ .code = full.code, .body = full.body[0..prefix_size] };
            // Each init message ends with a required field, so each prefix is an error.
            try testing.expectError(error.EndOfMessage, Init.decode(prefix));
        }
    }
}

test "fuzz decode" {
    // Random bodies with random codes must give a message or an error. A decoded message must
    // encode to a frame that decodes to the same message. The `compressed` kind compresses the
    // random body first, so that the fuzzer reaches the list decoder.
    try testing.fuzz({}, fuzzDecode, .{ .corpus = fuzz_decode_corpus });
}

const FuzzKind = enum(u8) { init, message, compressed };

/// The codes for the `message` kind. The last entry stands for a random code.
const fuzz_codes = codes: {
    const names = @typeInfo(Code).@"enum".field_names;
    var codes: [names.len + 1]?Code = undefined;
    for (names, 0..) |name, index| codes[index] = @field(Code, name);
    codes[names.len] = null;
    break :codes codes;
};

const fuzz_compressed_codes = [_]Code{
    .shared_file_list_response,
    .file_search_response,
    .folder_contents_response,
};

comptime {
    for (fuzz_compressed_codes) |code| assert(code.isCompressed());
}

/// Encodes a corpus entry for `fuzzDecode`, in the order of its `Smith` calls.
fn fuzzDecodeInput(
    comptime kind: FuzzKind,
    comptime code: u32,
    comptime body: []const u8,
) []const u8 {
    comptime {
        const code_value: u64 = switch (kind) {
            .init => code,
            .message => for (fuzz_codes, 0..) |fuzz_code, index| {
                if (@backingInt(fuzz_code.?) == code) break index;
            } else unreachable,
            .compressed => for (fuzz_compressed_codes, 0..) |fuzz_code, index| {
                if (@backingInt(fuzz_code) == code) break index;
            } else unreachable,
        };
        return test_support.fuzzInput(&.{
            .{ .int = @backingInt(kind) },
            .{ .int = code_value },
            .{ .slice = body },
        });
    }
}

const fuzz_decode_corpus: []const []const u8 = corpus: {
    var corpus: []const []const u8 = &.{};
    for (init_golden) |entry| {
        const message_frame = test_support.splitFrame(.code_u8, entry.bytes);
        corpus = corpus ++ [_][]const u8{
            fuzzDecodeInput(.init, message_frame.code, message_frame.body),
        };
    }
    for (message_golden) |entry| {
        const message_frame = splitFrame(entry.bytes);
        corpus = corpus ++ [_][]const u8{
            fuzzDecodeInput(.message, message_frame.code, message_frame.body),
        };
    }
    for (compressed_golden) |entry| {
        const message_frame = splitFrame(entry.bytes);
        corpus = corpus ++ [_][]const u8{
            fuzzDecodeInput(.message, message_frame.code, message_frame.body),
            fuzzDecodeInput(.compressed, message_frame.code, entry.body),
        };
    }
    break :corpus corpus;
};

fn fuzzDecode(_: void, smith: *testing.Smith) anyerror!void {
    const kind = smith.value(FuzzKind);
    const code: u32 = switch (kind) {
        .init => smith.value(u8),
        .message => code: {
            const index = smith.valueRangeAtMost(u32, 0, fuzz_codes.len - 1);
            break :code if (fuzz_codes[index]) |code| @backingInt(code) else smith.value(u32);
        },
        .compressed => code: {
            const index = smith.valueRangeAtMost(u32, 0, fuzz_compressed_codes.len - 1);
            break :code @backingInt(fuzz_compressed_codes[index]);
        },
    };
    var body_buffer: [512]u8 = undefined;
    const body = body_buffer[0..smith.slice(&body_buffer)];

    switch (kind) {
        .init => try expectInitDecodeStable(.{ .code = code, .body = body }),
        .message => try expectDecodeStable(.{ .code = code, .body = body }),
        .compressed => {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(testing.allocator);
            try zlib.compress(.init(testing.allocator, &list), body);
            try expectDecodeStable(.{ .code = code, .body = list.items });
        },
    }
}

fn expectInitDecodeStable(message_frame: frame.Frame) !void {
    const message = Init.decode(message_frame) catch |err| switch (err) {
        error.EndOfMessage, error.InvalidConnectionType => return,
    };
    try testing.expectEqual(message_frame.code, message.code());

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));

    const encoded = test_support.splitFrame(.code_u8, list.items);
    // The decoder ignores extra bytes, so the encoded body is never longer.
    try testing.expect(encoded.body.len <= message_frame.body.len);
    try testing.expectEqualDeep(message, try Init.decode(encoded));
}

fn expectDecodeStable(message_frame: frame.Frame) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = Message.decode(arena, message_frame, test_options) catch |err| switch (err) {
        error.EndOfMessage, error.InvalidCompressedData, error.DecompressedTooLarge => return,
        error.OutOfMemory => return err,
    };
    try testing.expectEqual(message_frame.code, message.code());

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));
    const encoded = splitFrame(list.items);
    try testing.expectEqualDeep(message, try Message.decode(arena, encoded, test_options));

    // The decoder ignores extra bytes, so the encoded body is never longer. For a compressed
    // message, compare the bodies before compression.
    const message_code: Code = @fromBackingInt(message_frame.code);
    if (message_code.isCompressed()) {
        const size_max = test_options.decompressed_size_max;
        const original = try zlib.decompress(arena, message_frame.body, size_max);
        const reencoded = try zlib.decompress(arena, encoded.body, size_max);
        try testing.expect(reencoded.len <= original.len);
    } else {
        try testing.expect(encoded.body.len <= message_frame.body.len);
    }
}
