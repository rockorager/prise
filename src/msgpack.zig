const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const EncodeError = error{
    OutOfMemory,
    IntegerTooLarge,
    StringTooLong,
    ArrayTooLong,
    MapTooLong,
};

pub const DecodeError = error{
    OutOfMemory,
    UnexpectedEndOfInput,
    InvalidFormat,
    InvalidUtf8,
    IntegerOverflow,
};

pub fn encode(allocator: Allocator, value: anytype) EncodeError![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try encodeValue(allocator, &buf, value);
    return buf.toOwnedSlice(allocator);
}

pub fn encodeFromValue(allocator: Allocator, value: Value) EncodeError![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try encodeValueType(allocator, &buf, value);
    return buf.toOwnedSlice(allocator);
}

fn encodeValueType(allocator: Allocator, buf: *std.ArrayList(u8), value: Value) EncodeError!void {
    switch (value) {
        .nil => try encodeNil(allocator, buf),
        .boolean => |b| try encodeBool(allocator, buf, b),
        .integer => |i| try encodeInt(allocator, buf, i),
        .unsigned => |u| try encodeInt(allocator, buf, u),
        .float => |f| try encodeFloat(allocator, buf, f),
        .string => |s| try encodeString(allocator, buf, s),
        .binary => |b| try encodeString(allocator, buf, b),
        .array => |arr| {
            const len = arr.len;
            if (len > 0xffffffff) return error.ArrayTooLong;

            if (len <= 15) {
                try buf.append(allocator, 0x90 | @as(u8, @intCast(len)));
            } else if (len <= 0xffff) {
                try buf.append(allocator, 0xdc);
                const bytes = std.mem.toBytes(@as(u16, @intCast(len)));
                try buf.append(allocator, bytes[1]);
                try buf.append(allocator, bytes[0]);
            } else {
                try buf.append(allocator, 0xdd);
                const bytes = std.mem.toBytes(@as(u32, @intCast(len)));
                try buf.append(allocator, bytes[3]);
                try buf.append(allocator, bytes[2]);
                try buf.append(allocator, bytes[1]);
                try buf.append(allocator, bytes[0]);
            }

            for (arr) |item| {
                try encodeValueType(allocator, buf, item);
            }
        },
        .map => |m| {
            const len = m.len;
            if (len > 0xffffffff) return error.MapTooLong;

            if (len <= 15) {
                try buf.append(allocator, 0x80 | @as(u8, @intCast(len)));
            } else if (len <= 0xffff) {
                try buf.append(allocator, 0xde);
                const bytes = std.mem.toBytes(@as(u16, @intCast(len)));
                try buf.append(allocator, bytes[1]);
                try buf.append(allocator, bytes[0]);
            } else {
                try buf.append(allocator, 0xdf);
                const bytes = std.mem.toBytes(@as(u32, @intCast(len)));
                try buf.append(allocator, bytes[3]);
                try buf.append(allocator, bytes[2]);
                try buf.append(allocator, bytes[1]);
                try buf.append(allocator, bytes[0]);
            }

            for (m) |kv| {
                try encodeValueType(allocator, buf, kv.key);
                try encodeValueType(allocator, buf, kv.value);
            }
        },
    }
}

fn encodeValue(allocator: Allocator, buf: *std.ArrayList(u8), value: anytype) EncodeError!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .null => try encodeNil(allocator, buf),
        .bool => try encodeBool(allocator, buf, value),
        .int, .comptime_int => try encodeInt(allocator, buf, value),
        .float, .comptime_float => try encodeFloat(allocator, buf, value),
        .pointer => |ptr| {
            switch (ptr.size) {
                .slice => {
                    if (ptr.child == u8) {
                        try encodeString(allocator, buf, value);
                    } else {
                        try encodeArray(allocator, buf, value);
                    }
                },
                .one => {
                    if (ptr.child == u8) {
                        @compileError("Use slices for strings, not single-item pointers");
                    } else if (@typeInfo(ptr.child) == .array) {
                        const arr_info = @typeInfo(ptr.child).array;
                        if (arr_info.child == u8) {
                            try encodeString(allocator, buf, value);
                        } else {
                            try encodeArray(allocator, buf, value);
                        }
                    } else {
                        @compileError("Unsupported pointer to " ++ @typeName(ptr.child));
                    }
                },
                else => @compileError("Unsupported pointer type"),
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                try encodeString(allocator, buf, &value);
            } else {
                try encodeArray(allocator, buf, &value);
            }
        },
        .@"struct" => |s| {
            if (s.is_tuple) {
                try encodeArray(allocator, buf, value);
            } else {
                @compileError("Struct encoding not yet supported");
            }
        },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

fn encodeNil(allocator: Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.append(allocator, 0xc0);
}

fn encodeBool(allocator: Allocator, buf: *std.ArrayList(u8), value: bool) !void {
    try buf.append(allocator, if (value) 0xc3 else 0xc2);
}

fn encodeInt(allocator: Allocator, buf: *std.ArrayList(u8), value: anytype) !void {
    const val: i64 = @intCast(value);

    if (val >= 0) {
        const uval: u64 = @intCast(val);
        if (uval <= 0x7f) {
            try buf.append(allocator, @intCast(uval));
        } else if (uval <= 0xff) {
            try buf.append(allocator, 0xcc);
            try buf.append(allocator, @intCast(uval));
        } else if (uval <= 0xffff) {
            try buf.append(allocator, 0xcd);
            const bytes = std.mem.toBytes(@as(u16, @intCast(uval)));
            try buf.append(allocator, bytes[1]);
            try buf.append(allocator, bytes[0]);
        } else if (uval <= 0xffffffff) {
            try buf.append(allocator, 0xce);
            const bytes = std.mem.toBytes(@as(u32, @intCast(uval)));
            try buf.append(allocator, bytes[3]);
            try buf.append(allocator, bytes[2]);
            try buf.append(allocator, bytes[1]);
            try buf.append(allocator, bytes[0]);
        } else {
            try buf.append(allocator, 0xcf);
            const bytes = std.mem.toBytes(uval);
            try buf.append(allocator, bytes[7]);
            try buf.append(allocator, bytes[6]);
            try buf.append(allocator, bytes[5]);
            try buf.append(allocator, bytes[4]);
            try buf.append(allocator, bytes[3]);
            try buf.append(allocator, bytes[2]);
            try buf.append(allocator, bytes[1]);
            try buf.append(allocator, bytes[0]);
        }
    } else {
        if (val >= -32) {
            try buf.append(allocator, @bitCast(@as(i8, @intCast(val))));
        } else if (val >= -128) {
            try buf.append(allocator, 0xd0);
            try buf.append(allocator, @bitCast(@as(i8, @intCast(val))));
        } else if (val >= -32768) {
            try buf.append(allocator, 0xd1);
            const bytes = std.mem.toBytes(@as(i16, @intCast(val)));
            try buf.append(allocator, bytes[1]);
            try buf.append(allocator, bytes[0]);
        } else if (val >= -2147483648) {
            try buf.append(allocator, 0xd2);
            const bytes = std.mem.toBytes(@as(i32, @intCast(val)));
            try buf.append(allocator, bytes[3]);
            try buf.append(allocator, bytes[2]);
            try buf.append(allocator, bytes[1]);
            try buf.append(allocator, bytes[0]);
        } else {
            try buf.append(allocator, 0xd3);
            const bytes = std.mem.toBytes(val);
            try buf.append(allocator, bytes[7]);
            try buf.append(allocator, bytes[6]);
            try buf.append(allocator, bytes[5]);
            try buf.append(allocator, bytes[4]);
            try buf.append(allocator, bytes[3]);
            try buf.append(allocator, bytes[2]);
            try buf.append(allocator, bytes[1]);
            try buf.append(allocator, bytes[0]);
        }
    }
}

fn encodeFloat(allocator: Allocator, buf: *std.ArrayList(u8), value: anytype) !void {
    const val: f64 = @floatCast(value);
    try buf.append(allocator, 0xcb);
    const bytes = std.mem.toBytes(@as(u64, @bitCast(val)));
    try buf.append(allocator, bytes[7]);
    try buf.append(allocator, bytes[6]);
    try buf.append(allocator, bytes[5]);
    try buf.append(allocator, bytes[4]);
    try buf.append(allocator, bytes[3]);
    try buf.append(allocator, bytes[2]);
    try buf.append(allocator, bytes[1]);
    try buf.append(allocator, bytes[0]);
}

fn encodeString(allocator: Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    const len = value.len;
    if (len > 0xffffffff) return error.StringTooLong;

    if (len <= 31) {
        try buf.append(allocator, 0xa0 | @as(u8, @intCast(len)));
    } else if (len <= 0xff) {
        try buf.append(allocator, 0xd9);
        try buf.append(allocator, @intCast(len));
    } else if (len <= 0xffff) {
        try buf.append(allocator, 0xda);
        const bytes = std.mem.toBytes(@as(u16, @intCast(len)));
        try buf.append(allocator, bytes[1]);
        try buf.append(allocator, bytes[0]);
    } else {
        try buf.append(allocator, 0xdb);
        const bytes = std.mem.toBytes(@as(u32, @intCast(len)));
        try buf.append(allocator, bytes[3]);
        try buf.append(allocator, bytes[2]);
        try buf.append(allocator, bytes[1]);
        try buf.append(allocator, bytes[0]);
    }
    try buf.appendSlice(allocator, value);
}

fn encodeArray(allocator: Allocator, buf: *std.ArrayList(u8), value: anytype) !void {
    const len = value.len;
    if (len > 0xffffffff) return error.ArrayTooLong;

    if (len <= 15) {
        try buf.append(allocator, 0x90 | @as(u8, @intCast(len)));
    } else if (len <= 0xffff) {
        try buf.append(allocator, 0xdc);
        const bytes = std.mem.toBytes(@as(u16, @intCast(len)));
        try buf.append(allocator, bytes[1]);
        try buf.append(allocator, bytes[0]);
    } else {
        try buf.append(allocator, 0xdd);
        const bytes = std.mem.toBytes(@as(u32, @intCast(len)));
        try buf.append(allocator, bytes[3]);
        try buf.append(allocator, bytes[2]);
        try buf.append(allocator, bytes[1]);
        try buf.append(allocator, bytes[0]);
    }

    inline for (value) |item| {
        try encodeValue(allocator, buf, item);
    }
}

test "encode nil" {
    const result = try encode(testing.allocator, null);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{0xc0}, result);
}

test "encode bool" {
    {
        const result = try encode(testing.allocator, false);
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u8, &[_]u8{0xc2}, result);
    }
    {
        const result = try encode(testing.allocator, true);
        defer testing.allocator.free(result);
        try testing.expectEqualSlices(u8, &[_]u8{0xc3}, result);
    }
}

test "encode positive fixint" {
    const result = try encode(testing.allocator, 42);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{42}, result);
}

test "encode negative fixint" {
    const result = try encode(testing.allocator, -5);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{0xfb}, result);
}

test "encode uint8" {
    const result = try encode(testing.allocator, 200);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xcc, 200 }, result);
}

test "encode uint16" {
    const result = try encode(testing.allocator, 1000);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xcd, 0x03, 0xe8 }, result);
}

test "encode int8" {
    const result = try encode(testing.allocator, -100);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xd0, 0x9c }, result);
}

test "encode float64" {
    const result = try encode(testing.allocator, 3.14);
    defer testing.allocator.free(result);
    try testing.expect(result.len == 9);
    try testing.expect(result[0] == 0xcb);
}

test "encode fixstr" {
    const result = try encode(testing.allocator, "hello");
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' }, result);
}

test "encode str8" {
    const str = "a" ** 50;
    const result = try encode(testing.allocator, str);
    defer testing.allocator.free(result);
    try testing.expect(result[0] == 0xd9);
    try testing.expect(result[1] == 50);
}

test "encode fixarray" {
    const arr = [_]i32{ 1, 2, 3 };
    const result = try encode(testing.allocator, &arr);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x93, 1, 2, 3 }, result);
}

test "encode nested array" {
    const arr = [_][]const u8{ "a", "b" };
    const result = try encode(testing.allocator, &arr);
    defer testing.allocator.free(result);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x92, 0xa1, 'a', 0xa1, 'b' }, result);
}

pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    unsigned: u64,
    float: f64,
    string: []const u8,
    binary: []const u8,
    array: []Value,
    map: []KeyValue,

    pub const KeyValue = struct {
        key: Value,
        value: Value,
    };

    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .binary => |b| allocator.free(b),
            .array => |arr| {
                for (arr) |item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
            },
            .map => |m| {
                for (m) |kv| {
                    kv.key.deinit(allocator);
                    kv.value.deinit(allocator);
                }
                allocator.free(m);
            },
            else => {},
        }
    }
};

pub const Decoder = struct {
    data: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, data: []const u8) Decoder {
        return .{
            .data = data,
            .pos = 0,
            .allocator = allocator,
        };
    }

    pub fn decode(self: *Decoder) DecodeError!Value {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;

        const byte = self.data[self.pos];
        self.pos += 1;

        if (byte <= 0x7f) {
            return Value{ .unsigned = byte };
        } else if (byte >= 0xe0) {
            return Value{ .integer = @as(i8, @bitCast(byte)) };
        } else if (byte >= 0xa0 and byte <= 0xbf) {
            const len = byte & 0x1f;
            return try self.decodeStringWithLen(len);
        } else if (byte >= 0x90 and byte <= 0x9f) {
            const len = byte & 0x0f;
            return try self.decodeArrayWithLen(len);
        } else if (byte >= 0x80 and byte <= 0x8f) {
            const len = byte & 0x0f;
            return try self.decodeMapWithLen(len);
        }

        return switch (byte) {
            0xc0 => Value.nil,
            0xc2 => Value{ .boolean = false },
            0xc3 => Value{ .boolean = true },
            0xcc => Value{ .unsigned = try self.readByte() },
            0xcd => Value{ .unsigned = try self.readU16() },
            0xce => Value{ .unsigned = try self.readU32() },
            0xcf => Value{ .unsigned = try self.readU64() },
            0xd0 => Value{ .integer = try self.readI8() },
            0xd1 => Value{ .integer = try self.readI16() },
            0xd2 => Value{ .integer = try self.readI32() },
            0xd3 => Value{ .integer = try self.readI64() },
            0xca => Value{ .float = @floatCast(try self.readF32()) },
            0xcb => Value{ .float = try self.readF64() },
            0xd9 => blk: {
                const len = try self.readByte();
                break :blk try self.decodeStringWithLen(len);
            },
            0xda => blk: {
                const len = try self.readU16();
                break :blk try self.decodeStringWithLen(len);
            },
            0xdb => blk: {
                const len = try self.readU32();
                break :blk try self.decodeStringWithLen(len);
            },
            0xc4 => blk: {
                const len = try self.readByte();
                break :blk try self.decodeBinaryWithLen(len);
            },
            0xc5 => blk: {
                const len = try self.readU16();
                break :blk try self.decodeBinaryWithLen(len);
            },
            0xc6 => blk: {
                const len = try self.readU32();
                break :blk try self.decodeBinaryWithLen(len);
            },
            0xdc => blk: {
                const len = try self.readU16();
                break :blk try self.decodeArrayWithLen(len);
            },
            0xdd => blk: {
                const len = try self.readU32();
                break :blk try self.decodeArrayWithLen(len);
            },
            0xde => blk: {
                const len = try self.readU16();
                break :blk try self.decodeMapWithLen(len);
            },
            0xdf => blk: {
                const len = try self.readU32();
                break :blk try self.decodeMapWithLen(len);
            },
            else => error.InvalidFormat,
        };
    }

    pub fn decodeTyped(self: *Decoder, comptime T: type) DecodeError!T {
        if (T == Value) {
            return self.decode();
        }

        const info = @typeInfo(T);
        switch (info) {
            .bool => {
                const byte = try self.peekByte();
                if (byte == 0xc2) {
                    _ = try self.readByte();
                    return false;
                }
                if (byte == 0xc3) {
                    _ = try self.readByte();
                    return true;
                }
                return error.InvalidFormat;
            },
            .int => {
                const val = try self.readInt();
                return std.math.cast(T, val) orelse error.IntegerOverflow;
            },
            .float => {
                const val = try self.readFloat();
                return @floatCast(val);
            },
            .optional => |opt| {
                const byte = try self.peekByte();
                if (byte == 0xc0) {
                    _ = try self.readByte();
                    return null;
                }
                return try self.decodeTyped(opt.child);
            },
            .@"enum" => {
                // We assume enums are encoded as integers (their tag value)
                // unless they are string-backed?
                // For now let's support integer serialization for enums
                const int_val = try self.readInt();
                // We need to cast this back to the enum
                // This checks if the integer is a valid tag
                return std.meta.intToEnum(T, int_val) catch return error.InvalidFormat;
            },
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    if (ptr.child == u8) {
                        // String
                        return self.readString();
                    } else {
                        // Array
                        const len = try self.readArrayLen();
                        const slice = try self.allocator.alloc(ptr.child, len);
                        errdefer self.allocator.free(slice);
                        for (slice) |*item| {
                            item.* = try self.decodeTyped(ptr.child);
                        }
                        return slice;
                    }
                }
            },
            .array => |arr| {
                // Fixed size array
                if (arr.child == u8) {
                    // Fixed string? No, usually strings are slices.
                    // But if it is [N]u8, it might be a string or byte array.
                    // Let's treat as string for now if we can read enough bytes.
                    const str = try self.readString();
                    defer self.allocator.free(str);
                    if (str.len != arr.len) return error.InvalidFormat;
                    var result: T = undefined;
                    @memcpy(&result, str);
                    return result;
                } else {
                    const len = try self.readArrayLen();
                    if (len != arr.len) return error.InvalidFormat;
                    var result: T = undefined;
                    for (&result) |*item| {
                        item.* = try self.decodeTyped(arr.child);
                    }
                    return result;
                }
            },
            .@"struct" => |s| {
                // Check if it's a Map or Array on the wire
                const byte = try self.peekByte();
                if (isMap(byte)) {
                    // Decode map into struct fields
                    const len = try self.readMapLen();
                    var result: T = undefined;

                    // Initialize optional fields to null
                    inline for (s.fields) |field| {
                        if (@typeInfo(field.type) == .optional) {
                            @field(result, field.name) = null;
                        }
                    }

                    // We have to loop through the map entries
                    var i: usize = 0;
                    while (i < len) : (i += 1) {
                        const key = try self.readString();
                        defer self.allocator.free(key);

                        var matched = false;
                        inline for (s.fields) |field| {
                            if (std.mem.eql(u8, key, field.name)) {
                                @field(result, field.name) = try self.decodeTyped(field.type);
                                matched = true;
                                break; // Break inline loop? No, this is compile time unroll.
                                // We need runtime logic.
                            }
                        }
                        // To make this work at runtime with optimized search:
                        // switch on string?
                        if (!matched) {
                            // Skip value
                            const val = try self.decode(); // decode generic value
                            val.deinit(self.allocator);
                        }
                    }
                    return result;
                } else if (isArray(byte)) {
                    // Decode array into struct fields (positional)
                    const len = try self.readArrayLen();
                    // If tuple, we expect exact match or prefix?
                    // Neovim often sends [type, msgid, method, params] which maps to a struct.
                    // Let's assume if struct is a tuple, or just normal struct, we map fields in order.

                    var result: T = undefined;
                    var field_idx: usize = 0;
                    inline for (s.fields) |field| {
                        if (field_idx >= len) {
                            // Missing fields. If optional, null. Else error.
                            if (@typeInfo(field.type) == .optional) {
                                @field(result, field.name) = null;
                            } else {
                                return error.InvalidFormat;
                            }
                        } else {
                            @field(result, field.name) = try self.decodeTyped(field.type);
                        }
                        field_idx += 1;
                    }
                    // Consume remaining items if any?
                    while (field_idx < len) : (field_idx += 1) {
                        const val = try self.decode();
                        val.deinit(self.allocator);
                    }
                    return result;
                } else {
                    return error.InvalidFormat;
                }
            },
            else => @compileError("Unsupported type for msgpack decoding: " ++ @typeName(T)),
        }
    }

    pub fn skipValue(self: *Decoder) DecodeError!void {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;

        const byte = self.data[self.pos];
        self.pos += 1;

        if (byte <= 0x7f) return;
        if (byte >= 0xe0) return;
        if (byte == 0xc0 or byte == 0xc2 or byte == 0xc3) return;

        // Float/Int fixed size
        if (byte == 0xcc or byte == 0xd0) {
            self.pos += 1;
            return;
        }
        if (byte == 0xcd or byte == 0xd1 or byte == 0xd4) {
            self.pos += 2;
            return;
        }
        if (byte == 0xce or byte == 0xd2 or byte == 0xca) {
            self.pos += 4;
            return;
        }
        if (byte == 0xcf or byte == 0xd3 or byte == 0xcb) {
            self.pos += 8;
            return;
        }
        if (byte == 0xd4) {
            self.pos += 1;
            return;
        } // fixext1
        if (byte == 0xd5) {
            self.pos += 2;
            return;
        } // fixext2
        if (byte == 0xd6) {
            self.pos += 4;
            return;
        } // fixext4
        if (byte == 0xd7) {
            self.pos += 8;
            return;
        } // fixext8
        if (byte == 0xd8) {
            self.pos += 16;
            return;
        } // fixext16

        // Str/Bin
        if (byte >= 0xa0 and byte <= 0xbf) { // fixstr
            const len = byte & 0x1f;
            self.pos += len;
            return;
        }
        if (byte == 0xd9 or byte == 0xc4) { // str8/bin8
            if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;
            const len = self.data[self.pos];
            self.pos += 1;
            self.pos += len;
            return;
        }
        if (byte == 0xda or byte == 0xc5) { // str16/bin16
            const len = try self.readU16();
            self.pos += len;
            return;
        }
        if (byte == 0xdb or byte == 0xc6) { // str32/bin32
            const len = try self.readU32();
            self.pos += len;
            return;
        }

        // Ext (variable)
        if (byte == 0xc7) { // ext8
            if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;
            const len = self.data[self.pos];
            self.pos += 1;
            self.pos += 1; // type
            self.pos += len;
            return;
        }
        if (byte == 0xc8) { // ext16
            const len = try self.readU16();
            self.pos += 1; // type
            self.pos += len;
            return;
        }
        if (byte == 0xc9) { // ext32
            const len = try self.readU32();
            self.pos += 1; // type
            self.pos += len;
            return;
        }

        // Array
        if (byte >= 0x90 and byte <= 0x9f) { // fixarray
            const len = byte & 0x0f;
            var i: usize = 0;
            while (i < len) : (i += 1) try self.skipValue();
            return;
        }
        if (byte == 0xdc) { // array16
            const len = try self.readU16();
            var i: usize = 0;
            while (i < len) : (i += 1) try self.skipValue();
            return;
        }
        if (byte == 0xdd) { // array32
            const len = try self.readU32();
            var i: usize = 0;
            while (i < len) : (i += 1) try self.skipValue();
            return;
        }

        // Map
        if (byte >= 0x80 and byte <= 0x8f) { // fixmap
            const len = byte & 0x0f;
            var i: usize = 0;
            while (i < len * 2) : (i += 1) try self.skipValue();
            return;
        }
        if (byte == 0xde) { // map16
            const len = try self.readU16();
            var i: usize = 0;
            while (i < len * 2) : (i += 1) try self.skipValue();
            return;
        }
        if (byte == 0xdf) { // map32
            const len = try self.readU32();
            var i: usize = 0;
            while (i < len * 2) : (i += 1) try self.skipValue();
            return;
        }

        return error.InvalidFormat;
    }

    pub fn peekByte(self: *Decoder) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;
        return self.data[self.pos];
    }

    pub fn isMap(byte: u8) bool {
        return (byte >= 0x80 and byte <= 0x8f) or byte == 0xde or byte == 0xdf;
    }

    pub fn isArray(byte: u8) bool {
        return (byte >= 0x90 and byte <= 0x9f) or byte == 0xdc or byte == 0xdd;
    }

    pub fn readInt(self: *Decoder) !i64 {
        const byte = try self.readByte();
        if (byte <= 0x7f) {
            return @intCast(byte);
        } else if (byte >= 0xe0) {
            return @intCast(@as(i8, @bitCast(byte)));
        }

        return switch (byte) {
            0xcc => @intCast(try self.readByte()),
            0xcd => @intCast(try self.readU16()),
            0xce => @intCast(try self.readU32()),
            0xcf => @intCast(try self.readU64()), // Might overflow i64 if huge unsigned
            0xd0 => @intCast(try self.readI8()),
            0xd1 => @intCast(try self.readI16()),
            0xd2 => @intCast(try self.readI32()),
            0xd3 => try self.readI64(),
            else => error.InvalidFormat,
        };
    }

    pub fn readFloat(self: *Decoder) !f64 {
        const byte = try self.readByte();
        return switch (byte) {
            0xca => @floatCast(try self.readF32()),
            0xcb => try self.readF64(),
            else => error.InvalidFormat,
        };
    }

    pub fn readString(self: *Decoder) ![]u8 {
        const byte = try self.readByte();
        var len: u64 = 0;
        if (byte >= 0xa0 and byte <= 0xbf) {
            len = byte & 0x1f;
        } else if (byte == 0xd9) {
            len = try self.readByte();
        } else if (byte == 0xda) {
            len = try self.readU16();
        } else if (byte == 0xdb) {
            len = try self.readU32();
        } else {
            return error.InvalidFormat;
        }

        const bytes = try self.readBytes(@intCast(len));
        return self.allocator.dupe(u8, bytes);
    }

    pub fn readArrayLen(self: *Decoder) !usize {
        const byte = try self.readByte();
        if (byte >= 0x90 and byte <= 0x9f) {
            return byte & 0x0f;
        } else if (byte == 0xdc) {
            return try self.readU16();
        } else if (byte == 0xdd) {
            return try self.readU32();
        }
        return error.InvalidFormat;
    }

    pub fn readMapLen(self: *Decoder) !usize {
        const byte = try self.readByte();
        if (byte >= 0x80 and byte <= 0x8f) {
            return byte & 0x0f;
        } else if (byte == 0xde) {
            return try self.readU16();
        } else if (byte == 0xdf) {
            return try self.readU32();
        }
        return error.InvalidFormat;
    }

    pub fn readByte(self: *Decoder) !u8 {
        if (self.pos >= self.data.len) return error.UnexpectedEndOfInput;
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    fn readBytes(self: *Decoder, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.UnexpectedEndOfInput;
        const bytes = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return bytes;
    }

    pub fn readU16(self: *Decoder) !u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], .big);
    }

    pub fn readU32(self: *Decoder) !u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .big);
    }

    pub fn readU64(self: *Decoder) !u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .big);
    }

    pub fn readI8(self: *Decoder) !i8 {
        return @bitCast(try self.readByte());
    }

    pub fn readI16(self: *Decoder) !i16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(i16, bytes[0..2], .big);
    }

    pub fn readI32(self: *Decoder) !i32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(i32, bytes[0..4], .big);
    }

    pub fn readI64(self: *Decoder) !i64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(i64, bytes[0..8], .big);
    }

    pub fn readF32(self: *Decoder) !f32 {
        const bytes = try self.readBytes(4);
        const bits = std.mem.readInt(u32, bytes[0..4], .big);
        return @bitCast(bits);
    }

    pub fn readF64(self: *Decoder) !f64 {
        const bytes = try self.readBytes(8);
        const bits = std.mem.readInt(u64, bytes[0..8], .big);
        return @bitCast(bits);
    }

    fn decodeStringWithLen(self: *Decoder, len: u64) !Value {
        const bytes = try self.readBytes(@intCast(len));
        const str = try self.allocator.dupe(u8, bytes);
        return Value{ .string = str };
    }

    fn decodeBinaryWithLen(self: *Decoder, len: u64) !Value {
        const bytes = try self.readBytes(@intCast(len));
        const bin = try self.allocator.dupe(u8, bytes);
        return Value{ .binary = bin };
    }

    fn decodeArrayWithLen(self: *Decoder, len: u64) !Value {
        const arr = try self.allocator.alloc(Value, @intCast(len));
        errdefer self.allocator.free(arr);

        for (arr, 0..) |*item, i| {
            item.* = self.decode() catch |err| {
                for (arr[0..i]) |prev| {
                    prev.deinit(self.allocator);
                }
                return err;
            };
        }

        return Value{ .array = arr };
    }

    fn decodeMapWithLen(self: *Decoder, len: u64) !Value {
        const map = try self.allocator.alloc(Value.KeyValue, @intCast(len));
        errdefer self.allocator.free(map);

        for (map, 0..) |*kv, i| {
            kv.key = self.decode() catch |err| {
                for (map[0..i]) |prev| {
                    prev.key.deinit(self.allocator);
                    prev.value.deinit(self.allocator);
                }
                self.allocator.free(map);
                return err;
            };

            kv.value = self.decode() catch |err| {
                kv.key.deinit(self.allocator);
                for (map[0..i]) |prev| {
                    prev.key.deinit(self.allocator);
                    prev.value.deinit(self.allocator);
                }
                self.allocator.free(map);
                return err;
            };
        }

        return Value{ .map = map };
    }
};

pub fn decode(allocator: Allocator, data: []const u8) !Value {
    var decoder = Decoder.init(allocator, data);
    return decoder.decode();
}

pub fn decodeTyped(allocator: Allocator, data: []const u8, comptime T: type) !T {
    var decoder = Decoder.init(allocator, data);
    return decoder.decodeTyped(T);
}

test "decode typed int" {
    const data = [_]u8{42};
    const val = try decodeTyped(testing.allocator, &data, u32);
    try testing.expectEqual(@as(u32, 42), val);
}

test "decode typed struct from array" {
    // [10, 20] -> struct { x: u32, y: u32 }
    const data = [_]u8{ 0x92, 10, 20 };
    const Point = struct { x: u32, y: u32 };
    const p = try decodeTyped(testing.allocator, &data, Point);
    try testing.expectEqual(@as(u32, 10), p.x);
    try testing.expectEqual(@as(u32, 20), p.y);
}

test "decode typed struct from map" {
    var map_items = [_]Value.KeyValue{
        .{ .key = .{ .string = "x" }, .value = .{ .unsigned = 10 } },
        .{ .key = .{ .string = "y" }, .value = .{ .unsigned = 20 } },
    };
    const val = Value{ .map = &map_items };
    const data = try encodeFromValue(testing.allocator, val);
    defer testing.allocator.free(data);

    const Point = struct { x: u32, y: u32 };
    const p = try decodeTyped(testing.allocator, data, Point);
    try testing.expectEqual(@as(u32, 10), p.x);
    try testing.expectEqual(@as(u32, 20), p.y);
}

test "decode typed mixed" {
    const Msg = struct { id: u32, val: Value };
    // [1, "hello"]
    const data = [_]u8{ 0x92, 1, 0xa5, 'h', 'e', 'l', 'l', 'o' };
    const msg = try decodeTyped(testing.allocator, &data, Msg);
    defer msg.val.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 1), msg.id);
    try testing.expectEqualStrings("hello", msg.val.string);
}

test "decode nil" {
    const data = [_]u8{0xc0};
    const val = try decode(testing.allocator, &data);
    defer val.deinit(testing.allocator);
    try testing.expect(val == .nil);
}

test "decode bool" {
    {
        const data = [_]u8{0xc2};
        const val = try decode(testing.allocator, &data);
        defer val.deinit(testing.allocator);
        try testing.expect(val == .boolean);
        try testing.expect(val.boolean == false);
    }
    {
        const data = [_]u8{0xc3};
        const val = try decode(testing.allocator, &data);
        defer val.deinit(testing.allocator);
        try testing.expect(val == .boolean);
        try testing.expect(val.boolean == true);
    }
}

test "decode positive fixint" {
    const data = [_]u8{42};
    const val = try decode(testing.allocator, &data);
    defer val.deinit(testing.allocator);
    try testing.expect(val == .unsigned);
    try testing.expect(val.unsigned == 42);
}

test "decode negative fixint" {
    const data = [_]u8{0xfb};
    const val = try decode(testing.allocator, &data);
    defer val.deinit(testing.allocator);
    try testing.expect(val == .integer);
    try testing.expect(val.integer == -5);
}

test "decode uint8" {
    const data = [_]u8{ 0xcc, 200 };
    const val = try decode(testing.allocator, &data);
    defer val.deinit(testing.allocator);
    try testing.expect(val == .unsigned);
    try testing.expect(val.unsigned == 200);
}

test "decode int8" {
    const data = [_]u8{ 0xd0, 0x9c };
    const val = try decode(testing.allocator, &data);
    defer val.deinit(testing.allocator);
    try testing.expect(val == .integer);
    try testing.expect(val.integer == -100);
}

test "decode fixstr" {
    const data = [_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' };
    const val = try decode(testing.allocator, &data);
    defer val.deinit(testing.allocator);
    try testing.expect(val == .string);
    try testing.expectEqualStrings("hello", val.string);
}

test "decode fixarray" {
    const data = [_]u8{ 0x93, 1, 2, 3 };
    const val = try decode(testing.allocator, &data);
    defer val.deinit(testing.allocator);
    try testing.expect(val == .array);
    try testing.expect(val.array.len == 3);
    try testing.expect(val.array[0].unsigned == 1);
    try testing.expect(val.array[1].unsigned == 2);
    try testing.expect(val.array[2].unsigned == 3);
}

test "encode/decode roundtrip" {
    const original = [_]i32{ 1, 2, 3 };
    const encoded = try encode(testing.allocator, &original);
    defer testing.allocator.free(encoded);

    const decoded = try decode(testing.allocator, encoded);
    defer decoded.deinit(testing.allocator);

    try testing.expect(decoded == .array);
    try testing.expect(decoded.array.len == 3);
}
