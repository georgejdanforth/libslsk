//! Server messages (see "Server Messages" in docs/SLSKPROTOCOL.md).
//!
//! The same code has a different layout in each direction, so each direction has its own union:
//! `ToServer` holds the messages that a client sends, and `FromServer` holds the messages that
//! the server sends. Both unions encode and decode. A client encodes `ToServer` and decodes
//! `FromServer`. A test server does the reverse.
//!
//! - A code that a direction does not implement decodes to `.unknown` with the raw body. This
//!   includes a known code in the wrong direction.
//! - Slices in a decoded message point into the frame body.
//! - The decoder ignores bytes after the last field. Nicotine+ does the same, and it lets the
//!   server add fields in a later version.
//! - Ports, tokens, and other numbers keep their wire types. The core checks their ranges.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const frame = @import("frame.zig");
const wire = @import("wire.zig");

/// The server message codes that libslsk implements. Other codes decode to `.unknown`.
pub const Code = enum(u32) {
    login = 1,
    set_wait_port = 2,
    get_peer_address = 3,
    watch_user = 5,
    get_user_status = 7,
    connect_to_peer = 18,
    message_user = 22,
    message_acked = 23,
    file_search = 26,
    server_ping = 32,
    relogged = 41,
    cant_connect_to_peer = 1001,
    _,
};

pub const DecodeError = wire.Reader.Error || error{
    /// A connection type string is not "P", "F", or "D".
    InvalidConnectionType,
};

/// See "User Status Codes" in the specification.
pub const UserStatus = enum(u32) {
    offline = 0,
    away = 1,
    online = 2,
    _,
};

/// See "Obfuscation Types" in the specification.
pub const ObfuscationType = enum(u32) {
    none = 0,
    rotated = 1,
    _,
};

/// See "Connection Types" in the specification. On the wire, the type is a string.
pub const ConnectionType = enum {
    peer,
    file,
    distributed,

    pub fn string(connection_type: ConnectionType) []const u8 {
        return switch (connection_type) {
            .peer => "P",
            .file => "F",
            .distributed => "D",
        };
    }

    pub fn parse(bytes: []const u8) error{InvalidConnectionType}!ConnectionType {
        if (bytes.len != 1) return error.InvalidConnectionType;
        return switch (bytes[0]) {
            'P' => .peer,
            'F' => .file,
            'D' => .distributed,
            else => error.InvalidConnectionType,
        };
    }
};

/// A message with a code that the direction does not implement.
pub const Unknown = struct {
    code: u32,
    body: []const u8,
};

/// The size of the checksum in `ToServer.Login`.
pub const login_checksum_size = 2 * std.crypto.hash.Md5.digest_length;

/// Returns the `Login` checksum: the MD5 hash of the username and the password, in lowercase hex.
pub fn loginChecksum(username: []const u8, password: []const u8) [login_checksum_size]u8 {
    var md5: std.crypto.hash.Md5 = .init(.{});
    md5.update(username);
    md5.update(password);
    return std.fmt.bytesToHex(md5.finalResult(), .lower);
}

/// The messages that a client sends to the server. Fields are in wire order.
pub const ToServer = union(enum) {
    login: Login,
    set_wait_port: SetWaitPort,
    get_peer_address: Username,
    watch_user: Username,
    get_user_status: Username,
    connect_to_peer: ConnectToPeer,
    message_user: MessageUser,
    message_acked: MessageAcked,
    file_search: FileSearch,
    server_ping,
    cant_connect_to_peer: CantConnectToPeer,
    unknown: Unknown,

    pub const Login = struct {
        username: []const u8,
        password: []const u8,
        version_major: u32,
        /// Use `loginChecksum`.
        checksum: []const u8,
        version_minor: u32,
    };

    pub const SetWaitPort = struct {
        port: u32,
        obfuscated: ?ObfuscatedPort,
    };

    pub const ObfuscatedPort = struct {
        obfuscation_type: ObfuscationType,
        port: u32,
    };

    /// The body of `GetPeerAddress`, `WatchUser`, and `GetUserStatus`.
    pub const Username = struct {
        username: []const u8,
    };

    pub const ConnectToPeer = struct {
        token: u32,
        username: []const u8,
        connection_type: ConnectionType,
    };

    pub const MessageUser = struct {
        username: []const u8,
        message: []const u8,
    };

    pub const MessageAcked = struct {
        message_id: u32,
    };

    pub const FileSearch = struct {
        token: u32,
        search_term: []const u8,
    };

    pub const CantConnectToPeer = struct {
        token: u32,
        username: []const u8,
    };

    pub fn code(message: ToServer) u32 {
        return messageCode(ToServer, message);
    }

    /// Appends the complete frame, with the length and the code.
    pub fn encode(message: ToServer, writer: wire.Writer) Allocator.Error!void {
        const header_offset = try frame.begin(writer, .code_u32, message.code());
        switch (message) {
            .login => |login| {
                try writer.writeString(login.username);
                try writer.writeString(login.password);
                try writer.writeInt(u32, login.version_major);
                try writer.writeString(login.checksum);
                try writer.writeInt(u32, login.version_minor);
            },
            .set_wait_port => |set_wait_port| {
                try writer.writeInt(u32, set_wait_port.port);
                if (set_wait_port.obfuscated) |obfuscated| {
                    try writer.writeInt(u32, @backingInt(obfuscated.obfuscation_type));
                    try writer.writeInt(u32, obfuscated.port);
                }
            },
            .get_peer_address, .watch_user, .get_user_status => |body| {
                try writer.writeString(body.username);
            },
            .connect_to_peer => |connect| {
                try writer.writeInt(u32, connect.token);
                try writer.writeString(connect.username);
                try writer.writeString(connect.connection_type.string());
            },
            .message_user => |message_user| {
                try writer.writeString(message_user.username);
                try writer.writeString(message_user.message);
            },
            .message_acked => |acked| try writer.writeInt(u32, acked.message_id),
            .file_search => |search| {
                try writer.writeInt(u32, search.token);
                try writer.writeString(search.search_term);
            },
            .server_ping => {},
            .cant_connect_to_peer => |cant_connect| {
                try writer.writeInt(u32, cant_connect.token);
                try writer.writeString(cant_connect.username);
            },
            .unknown => |unknown| {
                // A known code would decode to a different tag, so the round trip would fail.
                assert(!isKnownCode(ToServer, unknown.code));
                try writer.writeRaw(unknown.body);
            },
        }
        frame.end(writer, header_offset);
    }

    pub fn decode(message_frame: frame.Frame) DecodeError!ToServer {
        var reader: wire.Reader = .init(message_frame.body);
        const message_code: Code = @fromBackingInt(message_frame.code);
        switch (message_code) {
            .login => return .{ .login = .{
                .username = try reader.readString(),
                .password = try reader.readString(),
                .version_major = try reader.readInt(u32),
                .checksum = try reader.readString(),
                .version_minor = try reader.readInt(u32),
            } },
            .set_wait_port => {
                const port = try reader.readInt(u32);
                // The obfuscated port is optional. Clients that do not use it, such as
                // Nicotine+, send the port only.
                if (reader.remaining() == 0) {
                    return .{ .set_wait_port = .{ .port = port, .obfuscated = null } };
                } else {
                    return .{ .set_wait_port = .{ .port = port, .obfuscated = .{
                        .obfuscation_type = @fromBackingInt(try reader.readInt(u32)),
                        .port = try reader.readInt(u32),
                    } } };
                }
            },
            .get_peer_address => return .{ .get_peer_address = try decodeUsername(&reader) },
            .watch_user => return .{ .watch_user = try decodeUsername(&reader) },
            .get_user_status => return .{ .get_user_status = try decodeUsername(&reader) },
            .connect_to_peer => return .{ .connect_to_peer = .{
                .token = try reader.readInt(u32),
                .username = try reader.readString(),
                .connection_type = try ConnectionType.parse(try reader.readString()),
            } },
            .message_user => return .{ .message_user = .{
                .username = try reader.readString(),
                .message = try reader.readString(),
            } },
            .message_acked => return .{ .message_acked = .{
                .message_id = try reader.readInt(u32),
            } },
            .file_search => return .{ .file_search = .{
                .token = try reader.readInt(u32),
                .search_term = try reader.readString(),
            } },
            .server_ping => return .server_ping,
            .cant_connect_to_peer => return .{ .cant_connect_to_peer = .{
                .token = try reader.readInt(u32),
                .username = try reader.readString(),
            } },
            // The server sends these, but a client does not.
            .relogged => return .{ .unknown = unknownMessage(message_frame) },
            _ => return .{ .unknown = unknownMessage(message_frame) },
        }
    }

    fn decodeUsername(reader: *wire.Reader) DecodeError!Username {
        return .{ .username = try reader.readString() };
    }
};

/// The messages that the server sends to a client. Fields are in wire order.
pub const FromServer = union(enum) {
    login: Login,
    get_peer_address: PeerAddress,
    watch_user: WatchUser,
    get_user_status: UserStatusUpdate,
    connect_to_peer: ConnectToPeer,
    message_user: MessageUser,
    file_search: FileSearch,
    /// Obsolete. Old servers answered `ServerPing` with an empty message.
    server_ping,
    relogged,
    cant_connect_to_peer: CantConnectToPeer,
    unknown: Unknown,

    pub const Login = union(enum) {
        accepted: Accepted,
        rejected: Rejected,

        pub const Accepted = struct {
            motd: []const u8,
            /// Our own IP address, as the server sees it.
            ip: wire.Ip4,
            /// The MD5 hash of the password.
            password_checksum: []const u8,
            is_supporter: bool,
        };

        pub const Rejected = struct {
            /// See "Login Rejection Reasons" in the specification.
            reason: []const u8,
            /// See "Login Rejection Details". The official server sends a detail only for
            /// `INVALIDUSERNAME`.
            detail: ?[]const u8,
        };
    };

    pub const PeerAddress = struct {
        username: []const u8,
        ip: wire.Ip4,
        port: u32,
        obfuscation_type: ObfuscationType,
        /// A `u16`, unlike the obfuscated port in `ConnectToPeer`.
        obfuscated_port: u16,
    };

    pub const WatchUser = struct {
        username: []const u8,
        /// Null if the user does not exist.
        stats: ?UserStats,
    };

    pub const UserStats = struct {
        status: UserStatus,
        upload_speed: u32,
        upload_count: u32,
        /// The specification does not give a meaning for this field.
        unknown: u32,
        file_count: u32,
        folder_count: u32,
        /// The server sends a country code only if the user is away or online.
        country_code: ?[]const u8,
    };

    pub const UserStatusUpdate = struct {
        username: []const u8,
        status: UserStatus,
        privileged: bool,
    };

    pub const ConnectToPeer = struct {
        username: []const u8,
        connection_type: ConnectionType,
        ip: wire.Ip4,
        port: u32,
        /// Send this token back in `PierceFireWall`.
        token: u32,
        privileged: bool,
        obfuscation_type: ObfuscationType,
        obfuscated_port: u32,
    };

    pub const MessageUser = struct {
        message_id: u32,
        /// Seconds since the Unix epoch.
        timestamp: u32,
        username: []const u8,
        message: []const u8,
        /// False if the server sends the message again, for example because we were offline.
        is_new: bool,
    };

    pub const FileSearch = struct {
        username: []const u8,
        token: u32,
        search_term: []const u8,
    };

    pub const CantConnectToPeer = struct {
        token: u32,
    };

    pub fn code(message: FromServer) u32 {
        return messageCode(FromServer, message);
    }

    /// Appends the complete frame, with the length and the code.
    pub fn encode(message: FromServer, writer: wire.Writer) Allocator.Error!void {
        const header_offset = try frame.begin(writer, .code_u32, message.code());
        switch (message) {
            .login => |login| switch (login) {
                .accepted => |accepted| {
                    try writer.writeBool(true);
                    try writer.writeString(accepted.motd);
                    try writer.writeIp4(accepted.ip);
                    try writer.writeString(accepted.password_checksum);
                    try writer.writeBool(accepted.is_supporter);
                },
                .rejected => |rejected| {
                    try writer.writeBool(false);
                    try writer.writeString(rejected.reason);
                    if (rejected.detail) |detail| try writer.writeString(detail);
                },
            },
            .get_peer_address => |address| {
                try writer.writeString(address.username);
                try writer.writeIp4(address.ip);
                try writer.writeInt(u32, address.port);
                try writer.writeInt(u32, @backingInt(address.obfuscation_type));
                try writer.writeInt(u16, address.obfuscated_port);
            },
            .watch_user => |watch| {
                try writer.writeString(watch.username);
                try writer.writeBool(watch.stats != null);
                if (watch.stats) |stats| {
                    try writer.writeInt(u32, @backingInt(stats.status));
                    try writer.writeInt(u32, stats.upload_speed);
                    try writer.writeInt(u32, stats.upload_count);
                    try writer.writeInt(u32, stats.unknown);
                    try writer.writeInt(u32, stats.file_count);
                    try writer.writeInt(u32, stats.folder_count);
                    if (stats.country_code) |country_code| try writer.writeString(country_code);
                }
            },
            .get_user_status => |update| {
                try writer.writeString(update.username);
                try writer.writeInt(u32, @backingInt(update.status));
                try writer.writeBool(update.privileged);
            },
            .connect_to_peer => |connect| {
                try writer.writeString(connect.username);
                try writer.writeString(connect.connection_type.string());
                try writer.writeIp4(connect.ip);
                try writer.writeInt(u32, connect.port);
                try writer.writeInt(u32, connect.token);
                try writer.writeBool(connect.privileged);
                try writer.writeInt(u32, @backingInt(connect.obfuscation_type));
                try writer.writeInt(u32, connect.obfuscated_port);
            },
            .message_user => |message_user| {
                try writer.writeInt(u32, message_user.message_id);
                try writer.writeInt(u32, message_user.timestamp);
                try writer.writeString(message_user.username);
                try writer.writeString(message_user.message);
                try writer.writeBool(message_user.is_new);
            },
            .file_search => |search| {
                try writer.writeString(search.username);
                try writer.writeInt(u32, search.token);
                try writer.writeString(search.search_term);
            },
            .server_ping, .relogged => {},
            .cant_connect_to_peer => |cant_connect| try writer.writeInt(u32, cant_connect.token),
            .unknown => |unknown| {
                // A known code would decode to a different tag, so the round trip would fail.
                assert(!isKnownCode(FromServer, unknown.code));
                try writer.writeRaw(unknown.body);
            },
        }
        frame.end(writer, header_offset);
    }

    pub fn decode(message_frame: frame.Frame) DecodeError!FromServer {
        var reader: wire.Reader = .init(message_frame.body);
        const message_code: Code = @fromBackingInt(message_frame.code);
        switch (message_code) {
            .login => return .{ .login = try decodeLogin(&reader) },
            .get_peer_address => return .{ .get_peer_address = .{
                .username = try reader.readString(),
                .ip = try reader.readIp4(),
                .port = try reader.readInt(u32),
                .obfuscation_type = @fromBackingInt(try reader.readInt(u32)),
                .obfuscated_port = try reader.readInt(u16),
            } },
            .watch_user => return .{ .watch_user = try decodeWatchUser(&reader) },
            .get_user_status => return .{ .get_user_status = .{
                .username = try reader.readString(),
                .status = @fromBackingInt(try reader.readInt(u32)),
                .privileged = try reader.readBool(),
            } },
            .connect_to_peer => return .{ .connect_to_peer = .{
                .username = try reader.readString(),
                .connection_type = try ConnectionType.parse(try reader.readString()),
                .ip = try reader.readIp4(),
                .port = try reader.readInt(u32),
                .token = try reader.readInt(u32),
                .privileged = try reader.readBool(),
                .obfuscation_type = @fromBackingInt(try reader.readInt(u32)),
                .obfuscated_port = try reader.readInt(u32),
            } },
            .message_user => return .{ .message_user = .{
                .message_id = try reader.readInt(u32),
                .timestamp = try reader.readInt(u32),
                .username = try reader.readString(),
                .message = try reader.readString(),
                .is_new = try reader.readBool(),
            } },
            .file_search => return .{ .file_search = .{
                .username = try reader.readString(),
                .token = try reader.readInt(u32),
                .search_term = try reader.readString(),
            } },
            .server_ping => return .server_ping,
            .relogged => return .relogged,
            .cant_connect_to_peer => return .{ .cant_connect_to_peer = .{
                .token = try reader.readInt(u32),
            } },
            // A client sends these, but the server does not.
            .set_wait_port, .message_acked => {
                return .{ .unknown = unknownMessage(message_frame) };
            },
            _ => return .{ .unknown = unknownMessage(message_frame) },
        }
    }

    fn decodeLogin(reader: *wire.Reader) DecodeError!Login {
        const success = try reader.readBool();
        if (success) {
            return .{ .accepted = .{
                .motd = try reader.readString(),
                .ip = try reader.readIp4(),
                .password_checksum = try reader.readString(),
                .is_supporter = try reader.readBool(),
            } };
        } else {
            const reason = try reader.readString();
            // Read a detail if there is one, the same as Nicotine+. Then a detail for a new
            // reason does not break the decoder.
            const detail = if (reader.remaining() == 0) null else try reader.readString();
            return .{ .rejected = .{ .reason = reason, .detail = detail } };
        }
    }

    fn decodeWatchUser(reader: *wire.Reader) DecodeError!WatchUser {
        const username = try reader.readString();
        const exists = try reader.readBool();
        if (!exists) return .{ .username = username, .stats = null };

        var stats: UserStats = .{
            .status = @fromBackingInt(try reader.readInt(u32)),
            .upload_speed = try reader.readInt(u32),
            .upload_count = try reader.readInt(u32),
            .unknown = try reader.readInt(u32),
            .file_count = try reader.readInt(u32),
            .folder_count = try reader.readInt(u32),
            .country_code = null,
        };
        // The specification sends a country code only for away and online users. Read it if it
        // is there, the same as Nicotine+, and do not depend on the status.
        if (reader.remaining() > 0) stats.country_code = try reader.readString();
        return .{ .username = username, .stats = stats };
    }
};

fn messageCode(comptime Message: type, message: Message) u32 {
    return switch (message) {
        .unknown => |unknown| unknown.code,
        inline else => |_, tag| @backingInt(@field(Code, @tagName(tag))),
    };
}

/// Returns true if `Message` has its own tag for `code`.
fn isKnownCode(comptime Message: type, code: u32) bool {
    inline for (@typeInfo(Message).@"union".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "unknown")) continue;
        if (code == @backingInt(@field(Code, name))) return true;
    }
    return false;
}

fn unknownMessage(message_frame: frame.Frame) Unknown {
    return .{ .code = message_frame.code, .body = message_frame.body };
}

comptime {
    // Each code goes in at least one direction.
    for (@typeInfo(Code).@"enum".field_names) |name| {
        assert(@hasField(ToServer, name) or @hasField(FromServer, name));
    }
    // Each direction has a tag for each code that it implements, and `unknown`.
    assert(@typeInfo(ToServer).@"union".field_names.len == 12);
    assert(@typeInfo(FromServer).@"union".field_names.len == 11);
}

const testing = std.testing;
const test_support = @import("test_support.zig");

fn Golden(comptime Message: type) type {
    return struct {
        message: Message,
        /// The complete frame.
        bytes: []const u8,
    };
}

fn serverFrame(comptime code: Code, comptime body: []const u8) []const u8 {
    return test_support.frameBytes(.code_u32, @backingInt(code), body);
}

/// The frame header of `bytes`, split off.
fn splitFrame(bytes: []const u8) frame.Frame {
    assert(bytes.len >= frame.header_size_max);
    const length = std.mem.readInt(u32, bytes[0..frame.length_size], .little);
    assert(length == bytes.len - frame.length_size);
    return .{
        .code = std.mem.readInt(u32, bytes[frame.length_size..][0..4], .little),
        .body = bytes[frame.header_size_max..],
    };
}

fn expectGolden(comptime Message: type, golden: []const Golden(Message)) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    for (golden) |entry| {
        list.clearRetainingCapacity();
        try entry.message.encode(writer);
        try testing.expectEqualSlices(u8, entry.bytes, list.items);
        try testing.expectEqualDeep(entry.message, try Message.decode(splitFrame(entry.bytes)));
    }
}

/// Encodes `message`, decodes the bytes, and checks that the result is the same.
fn expectRoundTrip(comptime Message: type, message: Message) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));
    try testing.expectEqualDeep(message, try Message.decode(splitFrame(list.items)));
}

const login_example_checksum = "d51c9a7e9353746a6020f9602d452929";

test loginChecksum {
    // The checksum from the "Sending Login Example" in the specification.
    try testing.expectEqualStrings(login_example_checksum, &loginChecksum("username", "password"));
    // The checksum from the Nicotine+ Login test.
    try testing.expectEqualStrings(
        "dbc93f24d8f3f109deed23c3e2f8b74c",
        &loginChecksum("test", "s33cr3t"),
    );
}

// The Nicotine+ vectors below are from https://github.com/nicotine-plus/nicotine-plus,
// file pynicotine/tests/unit/protocol/test_slskmessages.py,
// commit 5489edd7a508e475c3541345d7100e674f1322ed.
// SPDX-FileCopyrightText: 2020-2026 Nicotine+ Contributors
// SPDX-License-Identifier: GPL-3.0-or-later
// Nicotine+ tests only the message body. These vectors add the frame header.
const to_server_golden = [_]Golden(ToServer){
    // The "Sending Login Example" from the specification.
    .{
        .message = .{ .login = .{
            .username = "username",
            .password = "password",
            .version_major = 177,
            .checksum = login_example_checksum,
            .version_minor = 1,
        } },
        .bytes = &test_support.login_example,
    },
    // Nicotine+ LoginMessageTest.
    .{
        .message = .{ .login = .{
            .username = "test",
            .password = "s33cr3t",
            .version_major = 157,
            .checksum = "dbc93f24d8f3f109deed23c3e2f8b74c",
            .version_minor = 19,
        } },
        .bytes = serverFrame(
            .login,
            "\x04\x00\x00\x00test\x07\x00\x00\x00s33cr3t\x9d\x00\x00\x00 " ++
                "\x00\x00\x00dbc93f24d8f3f109deed23c3e2f8b74c\x13\x00\x00\x00",
        ),
    },
    // Nicotine+ SetWaitPortMessageTest.
    .{
        .message = .{ .set_wait_port = .{ .port = 1337, .obfuscated = null } },
        .bytes = serverFrame(.set_wait_port, "9\x05\x00\x00"),
    },
    // Nicotine+ GetPeerAddressMessageTest.
    .{
        .message = .{ .get_peer_address = .{ .username = "user1" } },
        .bytes = serverFrame(.get_peer_address, "\x05\x00\x00\x00user1"),
    },
    // Nicotine+ WatchUserMessageTest.
    .{
        .message = .{ .watch_user = .{ .username = "user2" } },
        .bytes = serverFrame(.watch_user, "\x05\x00\x00\x00user2"),
    },
    // Nicotine+ GetUserStatusMessageTest.
    .{
        .message = .{ .get_user_status = .{ .username = "user4" } },
        .bytes = serverFrame(.get_user_status, "\x05\x00\x00\x00user4"),
    },
    // Nicotine+ FileSearchTest.
    .{
        .message = .{ .file_search = .{ .token = 524700074, .search_term = "70 gwen auto" } },
        .bytes = serverFrame(.file_search, "\xaaIF\x1f\x0c\x00\x00\x0070 gwen auto"),
    },
    // The vectors after this line are from the data order in the specification.
    .{
        .message = .{ .set_wait_port = .{
            .port = 2234,
            .obfuscated = .{ .obfuscation_type = .rotated, .port = 2235 },
        } },
        .bytes = serverFrame(.set_wait_port, &([_]u8{ 0xba, 0x08, 0x00, 0x00 } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0xbb, 0x08, 0x00, 0x00 })),
    },
    .{
        .message = .{ .connect_to_peer = .{
            .token = 0x12345678,
            .username = "bob",
            .connection_type = .peer,
        } },
        .bytes = serverFrame(.connect_to_peer, &([_]u8{ 0x78, 0x56, 0x34, 0x12 } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00, 'P' })),
    },
    .{
        .message = .{ .message_user = .{ .username = "bob", .message = "hello" } },
        .bytes = serverFrame(.message_user, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x05, 0x00, 0x00, 0x00, 'h', 'e', 'l', 'l', 'o' })),
    },
    .{
        .message = .{ .message_acked = .{ .message_id = 7 } },
        .bytes = serverFrame(.message_acked, &.{ 0x07, 0x00, 0x00, 0x00 }),
    },
    .{
        .message = .server_ping,
        .bytes = serverFrame(.server_ping, ""),
    },
    .{
        .message = .{ .cant_connect_to_peer = .{ .token = 0x12345678, .username = "bob" } },
        .bytes = serverFrame(.cant_connect_to_peer, &([_]u8{ 0x78, 0x56, 0x34, 0x12 } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' })),
    },
};

/// Vectors from the data order in the specification. Nicotine+ has no vectors for messages from
/// the server.
const from_server_golden = [_]Golden(FromServer){
    .{
        .message = .{ .login = .{ .accepted = .{
            .motd = "hi",
            .ip = .{ 127, 0, 0, 1 },
            .password_checksum = "abc",
            .is_supporter = true,
        } } },
        .bytes = serverFrame(.login, &([_]u8{0x01} ++
            [_]u8{ 0x02, 0x00, 0x00, 0x00, 'h', 'i' } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x7f } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'a', 'b', 'c' } ++
            [_]u8{0x01})),
    },
    .{
        .message = .{ .login = .{ .rejected = .{ .reason = "INVALIDPASS", .detail = null } } },
        .bytes = serverFrame(.login, &([_]u8{0x00} ++
            [_]u8{ 0x0b, 0x00, 0x00, 0x00 } ++ "INVALIDPASS".*)),
    },
    .{
        .message = .{ .login = .{ .rejected = .{
            .reason = "INVALIDUSERNAME",
            .detail = "Nick empty.",
        } } },
        .bytes = serverFrame(.login, &([_]u8{0x00} ++
            [_]u8{ 0x0f, 0x00, 0x00, 0x00 } ++ "INVALIDUSERNAME".* ++
            [_]u8{ 0x0b, 0x00, 0x00, 0x00 } ++ "Nick empty.".*)),
    },
    .{
        .message = .{ .get_peer_address = .{
            .username = "bob",
            .ip = .{ 192, 168, 1, 20 },
            .port = 2234,
            .obfuscation_type = .none,
            .obfuscated_port = 0,
        } },
        .bytes = serverFrame(.get_peer_address, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x14, 0x01, 0xa8, 0xc0 } ++
            [_]u8{ 0xba, 0x08, 0x00, 0x00 } ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x00, 0x00 })),
    },
    .{
        .message = .{ .watch_user = .{ .username = "bob", .stats = .{
            .status = .online,
            .upload_speed = 1000,
            .upload_count = 5,
            .unknown = 0,
            .file_count = 300,
            .folder_count = 20,
            .country_code = "US",
        } } },
        .bytes = serverFrame(.watch_user, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{0x01} ++
            [_]u8{ 0x02, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0xe8, 0x03, 0x00, 0x00 } ++
            [_]u8{ 0x05, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x2c, 0x01, 0x00, 0x00 } ++
            [_]u8{ 0x14, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x02, 0x00, 0x00, 0x00, 'U', 'S' })),
    },
    .{
        .message = .{ .watch_user = .{ .username = "bob", .stats = null } },
        .bytes = serverFrame(.watch_user, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{0x00})),
    },
    .{
        .message = .{ .get_user_status = .{
            .username = "bob",
            .status = .away,
            .privileged = false,
        } },
        .bytes = serverFrame(.get_user_status, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00 } ++
            [_]u8{0x00})),
    },
    .{
        .message = .{ .connect_to_peer = .{
            .username = "bob",
            .connection_type = .peer,
            .ip = .{ 10, 0, 0, 1 },
            .port = 2234,
            .token = 0x12345678,
            .privileged = true,
            .obfuscation_type = .none,
            .obfuscated_port = 0,
        } },
        .bytes = serverFrame(.connect_to_peer, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x00, 'P' } ++
            [_]u8{ 0x01, 0x00, 0x00, 0x0a } ++
            [_]u8{ 0xba, 0x08, 0x00, 0x00 } ++
            [_]u8{ 0x78, 0x56, 0x34, 0x12 } ++
            [_]u8{0x01} ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x00, 0x00, 0x00, 0x00 })),
    },
    .{
        .message = .{ .message_user = .{
            .message_id = 7,
            .timestamp = 1700000000,
            .username = "bob",
            .message = "hello",
            .is_new = true,
        } },
        .bytes = serverFrame(.message_user, &([_]u8{ 0x07, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x00, 0xf1, 0x53, 0x65 } ++
            [_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x05, 0x00, 0x00, 0x00, 'h', 'e', 'l', 'l', 'o' } ++
            [_]u8{0x01})),
    },
    .{
        .message = .{ .file_search = .{ .username = "bob", .token = 42, .search_term = "song" } },
        .bytes = serverFrame(.file_search, &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x2a, 0x00, 0x00, 0x00 } ++
            [_]u8{ 0x04, 0x00, 0x00, 0x00, 's', 'o', 'n', 'g' })),
    },
    .{
        .message = .server_ping,
        .bytes = serverFrame(.server_ping, ""),
    },
    .{
        .message = .relogged,
        .bytes = serverFrame(.relogged, ""),
    },
    .{
        .message = .{ .cant_connect_to_peer = .{ .token = 0x12345678 } },
        .bytes = serverFrame(.cant_connect_to_peer, &.{ 0x78, 0x56, 0x34, 0x12 }),
    },
};

comptime {
    // Each tag except `unknown` has at least one golden vector.
    for (.{ ToServer, FromServer }, .{ &to_server_golden, &from_server_golden }) |Message, golden| {
        for (@typeInfo(Message).@"union".field_names) |name| {
            if (std.mem.eql(u8, name, "unknown")) continue;
            for (golden) |entry| {
                if (std.mem.eql(u8, @tagName(entry.message), name)) break;
            } else @compileError("no golden vector for " ++ @typeName(Message) ++ "." ++ name);
        }
    }
}

test "ToServer golden vectors" {
    try expectGolden(ToServer, &to_server_golden);
}

test "FromServer golden vectors" {
    try expectGolden(FromServer, &from_server_golden);
}

test "round trips with other values" {
    // Extreme values, empty strings, raw bytes that are not UTF-8, and unknown enum values.
    try expectRoundTrip(ToServer, .{ .login = .{
        .username = "",
        .password = &.{ 0xc3, 0x28 },
        .version_major = std.math.maxInt(u32),
        .checksum = "",
        .version_minor = 0,
    } });
    try expectRoundTrip(ToServer, .{ .set_wait_port = .{
        .port = std.math.maxInt(u32),
        .obfuscated = .{ .obfuscation_type = @fromBackingInt(9), .port = 0 },
    } });
    inline for (.{ .peer, .file, .distributed }) |connection_type| {
        try expectRoundTrip(ToServer, .{ .connect_to_peer = .{
            .token = 0,
            .username = "",
            .connection_type = connection_type,
        } });
        try expectRoundTrip(FromServer, .{ .connect_to_peer = .{
            .username = "bob",
            .connection_type = connection_type,
            .ip = .{ 255, 255, 255, 255 },
            .port = std.math.maxInt(u32),
            .token = std.math.maxInt(u32),
            .privileged = false,
            .obfuscation_type = .rotated,
            .obfuscated_port = std.math.maxInt(u32),
        } });
    }
    try expectRoundTrip(FromServer, .{ .get_peer_address = .{
        .username = "bob",
        .ip = .{ 0, 0, 0, 0 },
        .port = 0,
        .obfuscation_type = @fromBackingInt(std.math.maxInt(u32)),
        .obfuscated_port = std.math.maxInt(u16),
    } });
    try expectRoundTrip(FromServer, .{ .watch_user = .{ .username = "bob", .stats = .{
        .status = .offline,
        .upload_speed = 0,
        .upload_count = 0,
        .unknown = std.math.maxInt(u32),
        .file_count = 0,
        .folder_count = 0,
        .country_code = null,
    } } });
    try expectRoundTrip(FromServer, .{ .get_user_status = .{
        .username = "bob",
        .status = @fromBackingInt(3),
        .privileged = true,
    } });
    try expectRoundTrip(FromServer, .{ .login = .{ .rejected = .{
        .reason = "INVALIDUSERNAME",
        .detail = "",
    } } });
}

test "unknown codes decode to unknown" {
    const unknown_code = 9999;
    try testing.expect(!isKnownCode(ToServer, unknown_code));
    try testing.expect(!isKnownCode(FromServer, unknown_code));

    const body = "any body";
    const message_frame: frame.Frame = .{ .code = unknown_code, .body = body };
    try testing.expectEqualDeep(
        ToServer{ .unknown = .{ .code = unknown_code, .body = body } },
        try ToServer.decode(message_frame),
    );
    try testing.expectEqualDeep(
        FromServer{ .unknown = .{ .code = unknown_code, .body = body } },
        try FromServer.decode(message_frame),
    );

    // An unknown message encodes to the same frame.
    try expectRoundTrip(ToServer, .{ .unknown = .{ .code = unknown_code, .body = body } });
    try expectRoundTrip(FromServer, .{ .unknown = .{ .code = 0, .body = "" } });
}

test "a code in the wrong direction decodes to unknown" {
    // Only the server sends Relogged. Only a client sends SetWaitPort and MessageAcked.
    const relogged: frame.Frame = .{ .code = @backingInt(Code.relogged), .body = "" };
    try testing.expectEqual(.unknown, std.meta.activeTag(try ToServer.decode(relogged)));

    const one_way_to_server = [_]Code{ .set_wait_port, .message_acked };
    for (one_way_to_server) |code| {
        const message_frame: frame.Frame = .{
            .code = @backingInt(code),
            .body = &.{ 0x07, 0x00, 0x00, 0x00 },
        };
        const message = try FromServer.decode(message_frame);
        try testing.expectEqual(@backingInt(code), message.unknown.code);
        try testing.expectEqualSlices(u8, message_frame.body, message.unknown.body);
    }
    try testing.expect(!isKnownCode(ToServer, @backingInt(Code.relogged)));
    try testing.expect(isKnownCode(FromServer, @backingInt(Code.relogged)));
}

test "bytes after the last field are ignored" {
    const message_frame: frame.Frame = .{
        .code = @backingInt(Code.get_user_status),
        .body = &([_]u8{ 0x03, 0x00, 0x00, 0x00, 'b', 'o', 'b' } ++
            [_]u8{ 0x02, 0x00, 0x00, 0x00 } ++
            [_]u8{0x01} ++
            [_]u8{ 0xaa, 0xbb }),
    };
    try testing.expectEqualDeep(FromServer{ .get_user_status = .{
        .username = "bob",
        .status = .online,
        .privileged = true,
    } }, try FromServer.decode(message_frame));
}

test "invalid connection types" {
    // "X" is not a type, and "PF" is longer than one character.
    for ([_][]const u8{ "X", "PF", "", "p" }) |connection_type| {
        try testing.expectError(error.InvalidConnectionType, ConnectionType.parse(connection_type));
    }

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);
    try writer.writeInt(u32, 1);
    try writer.writeString("bob");
    try writer.writeString("X");
    const message_frame: frame.Frame = .{
        .code = @backingInt(Code.connect_to_peer),
        .body = list.items,
    };
    try testing.expectError(error.InvalidConnectionType, ToServer.decode(message_frame));
}

/// Checks each prefix of each golden body. A prefix must give `EndOfMessage`, or a message that
/// encodes back to the same prefix. The second case happens where an optional field starts.
fn expectPrefixes(comptime Message: type, golden: []const Golden(Message)) !void {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    const writer: wire.Writer = .init(testing.allocator, &list);

    for (golden) |entry| {
        const full = splitFrame(entry.bytes);
        for (0..full.body.len) |prefix_size| {
            const prefix: frame.Frame = .{ .code = full.code, .body = full.body[0..prefix_size] };
            const message = Message.decode(prefix) catch |err| {
                try testing.expectEqual(error.EndOfMessage, err);
                continue;
            };
            list.clearRetainingCapacity();
            try message.encode(writer);
            try testing.expectEqualSlices(u8, prefix.body, splitFrame(list.items).body);
        }
    }
}

test "truncated bodies" {
    try expectPrefixes(ToServer, &to_server_golden);
    try expectPrefixes(FromServer, &from_server_golden);
}

test "fuzz decode" {
    // Random bodies with random codes, decoded in both directions, must give a message or an
    // error. A decoded message must encode to a frame that decodes to the same message.
    try testing.fuzz({}, fuzzDecode, .{ .corpus = fuzz_decode_corpus });
}

/// The codes for `fuzzDecode`. The last entry stands for a random code.
const fuzz_codes = codes: {
    const names = @typeInfo(Code).@"enum".field_names;
    var codes: [names.len + 1]?Code = undefined;
    for (names, 0..) |name, index| codes[index] = @field(Code, name);
    codes[names.len] = null;
    break :codes codes;
};

const FuzzDirection = enum(u8) { to_server, from_server };

/// Encodes a corpus entry for `fuzzDecode` from a golden frame, in the order of its `Smith`
/// calls.
fn fuzzDecodeInput(comptime direction: FuzzDirection, comptime bytes: []const u8) []const u8 {
    comptime {
        const message_frame = splitFrame(bytes);
        const code_index = for (fuzz_codes, 0..) |code, index| {
            if (@backingInt(code.?) == message_frame.code) break index;
        } else unreachable;
        return test_support.fuzzInput(&.{
            .{ .int = @backingInt(direction) },
            .{ .int = code_index },
            .{ .slice = message_frame.body },
        });
    }
}

const fuzz_decode_corpus: []const []const u8 = corpus: {
    var corpus: []const []const u8 = &.{};
    for (to_server_golden) |entry| {
        corpus = corpus ++ [_][]const u8{fuzzDecodeInput(.to_server, entry.bytes)};
    }
    for (from_server_golden) |entry| {
        corpus = corpus ++ [_][]const u8{fuzzDecodeInput(.from_server, entry.bytes)};
    }
    break :corpus corpus;
};

fn fuzzDecode(_: void, smith: *testing.Smith) anyerror!void {
    const direction = smith.value(FuzzDirection);
    const code_index = smith.valueRangeAtMost(u32, 0, fuzz_codes.len - 1);
    const code: u32 = if (fuzz_codes[code_index]) |code| @backingInt(code) else smith.value(u32);
    var body_buffer: [256]u8 = undefined;
    const body = body_buffer[0..smith.slice(&body_buffer)];

    const message_frame: frame.Frame = .{ .code = code, .body = body };
    switch (direction) {
        .to_server => try expectDecodeStable(ToServer, message_frame),
        .from_server => try expectDecodeStable(FromServer, message_frame),
    }
}

fn expectDecodeStable(comptime Message: type, message_frame: frame.Frame) !void {
    const message = Message.decode(message_frame) catch |err| switch (err) {
        error.EndOfMessage, error.InvalidConnectionType => return,
    };
    try testing.expectEqual(message_frame.code, message.code());

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try message.encode(.init(testing.allocator, &list));

    const encoded = splitFrame(list.items);
    // The decoder ignores extra bytes, so the encoded body is never longer.
    try testing.expect(encoded.body.len <= message_frame.body.len);
    try testing.expectEqualDeep(message, try Message.decode(encoded));
}
