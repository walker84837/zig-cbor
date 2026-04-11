const std = @import("std");
const io = std.io;

/// Error set for CBOR operations
pub const Error = io.Writer.Error || error{
    StringTooLong,
    IntegerTooLarge,
    InvalidValue,
    OutOfMemory,
    InvalidUtf8,
    ReservedValue,
    InvalidTagContent,
    DuplicateMapKey,
    NonPreferredEncoding,
    IndefiniteNotAllowed,
    MapKeysNotSorted,
};

/// Validation mode controlling serialization/deserialization strictness.
pub const ValidationMode = enum {
    /// Basic CBOR correctness - accepts any valid CBOR
    well_formed,
    /// Preferred encoding, no duplicate keys, no reserved values
    strict,
    /// Strict + deterministic length encoding + sorted map keys
    deterministic,
};

/// Options for controlling serialization behavior.
pub const WriterOptions = struct {
    /// Validation mode for encoding
    mode: ValidationMode = .well_formed,
    /// Use shortest encoding (preferred) vs canonical
    preferred: bool = true,
    /// Use definite-length encoding for containers
    definite: bool = false,
};

/// CBOR major types (used internally for parsing/encoding)
pub const MajorType = enum(u3) {
    unsigned_integer = 0,
    negative_integer = 1,
    byte_string = 2,
    text_string = 3,
    array = 4,
    map = 5,
    tag = 6,
    float_or_simple = 7,
};

/// Tagged value wrapper - contains a tag number and the tagged value.
/// Tags provide semantic meaning (e.g., timestamp, URI, etc.)
pub const Tagged = struct {
    tag: u64,
    value: *CborValue,
};

/// Main CBOR value type supporting all CBOR data types.
///
/// Supported types:
/// - null, undefined
/// - bool, integer (i64), float (f64)
/// - text (string), bytes (byte array)
/// - array, map, tagged, simple
pub const CborValue = union(enum) {
    const Self = @This();

    null,
    undefined,
    bool: bool,
    integer: i64,
    float: f64,
    text: []const u8,
    bytes: []const u8,
    array: []const *const Self,
    map: ObjectMap,
    tagged: *Tagged,
    simple: u8,

    /// Create a null value
    pub fn initNull() Self {
        return .null;
    }

    /// Create a boolean value
    pub fn initBoolean(value: bool) Self {
        return .{ .bool = value };
    }

    /// Create an integer value (signed)
    pub fn initInteger(value: i64) Self {
        return .{ .integer = value };
    }

    /// Create a floating-point value (f64)
    pub fn initFloat(value: f64) Self {
        return .{ .float = value };
    }

    /// Create a text (string) value - must be valid UTF-8
    pub fn initString(value: []const u8) Self {
        return .{ .text = value };
    }

    /// Create a byte string value (raw bytes, no UTF-8 requirement)
    pub fn initBytes(value: []const u8) Self {
        return .{ .bytes = value };
    }

    /// Create an array of CborValues
    pub fn initArray(value: []const Self) Self {
        const ptrs: []const *const Self = @ptrCast(value);
        return .{ .array = ptrs };
    }

    /// Create a map value from an ObjectMap (string keys)
    pub fn initObject(value: ObjectMap) Self {
        return .{ .map = value };
    }

    /// Create an undefined value
    pub fn initUndefined() Self {
        return .undefined;
    }

    /// Create a simple value (0-19). Values 20-30 are reserved.
    pub fn initSimple(value: u8) Self {
        if (value > 30) return .undefined;
        return .{ .simple = value };
    }

    /// Create a tagged value. Tag provides semantic context (e.g., timestamp, URI).
    pub fn initTagged(_: Self, tag: u64, value: Self) Self {
        const tagged_ptr: *CborValue = @ptrCast(&value);
        return .{ .tagged = &.{ .tag = tag, .value = tagged_ptr } };
    }

    /// Serialize this CborValue to a writer using the given options
    pub fn serialize(self: Self, writer: *io.Writer, opts: WriterOptions) Error!void {
        switch (self) {
            .null => try writer.writeByte(0xF6),
            .undefined => try writer.writeByte(0xF7),
            .bool => |b| try writer.writeByte(if (b) 0xF5 else 0xF4),
            .integer => |i| try serializeInteger(i, writer, opts),
            .float => |f| try serializeFloat(f, writer, opts),
            .text => |s| try serializeString(s, writer, opts, .text_string),
            .bytes => |b| try serializeString(b, writer, opts, .byte_string),
            .array => |a| try serializeArray(a, writer, opts),
            .map => |m| try m.serialize(writer, opts),
            .tagged => |t| try serializeTagged(t, writer, opts),
            .simple => |s| try serializeSimple(s, writer, opts),
        }
    }

    /// Compute hash for use as a map key (Wyhash)
    pub fn hashForMap(self: Self) u64 {
        var hasher = std.hash.Wyhash.init();
        self.hashInto(&hasher);
        return hasher.final();
    }

    fn hashInto(self: Self, hasher: anytype) void {
        switch (self) {
            .null => hasher.update("null"),
            .undefined => hasher.update("undefined"),
            .bool => |b| hasher.update(if (b) "true" else "false"),
            .integer => |i| hasher.update(std.mem.asBytes(&i)),
            .float => |f| hasher.update(std.mem.asBytes(&f)),
            .text => |s| hasher.update(s),
            .bytes => |b| hasher.update(b),
            .array, .tagged, .simple, .map => {},
        }
    }

    /// Check equality for map key comparison
    pub fn equalsForMap(self: Self, other: Self) bool {
        return std.meta.eql(self, other);
    }

    /// Deep clone this value using the provided allocator
    pub fn cloneValue(self: Self, alloc: std.mem.Allocator) Error!Self {
        return switch (self) {
            .null, .undefined, .bool, .integer, .float, .simple => self,
            .text => |t| .{ .text = try alloc.dupe(u8, t) },
            .bytes => |b| .{ .bytes = try alloc.dupe(u8, b) },
            .array => |a| {
                var copy = try alloc.alloc(*const Self, a.len);
                for (a, 0..) |item, i| {
                    copy[i] = try alloc.create(*const Self);
                    copy[i].* = try item.cloneValue(alloc);
                }
                return .{ .array = copy };
            },
            .map => |m| .{ .map = try m.clone() },
            .tagged => |t| {
                const new_val = try alloc.create(CborValue);
                new_val.* = try t.value.cloneValue(alloc);
                return .{ .tagged = &.{ .tag = t.tag, .value = new_val } };
            },
        };
    }

    /// Free all owned memory within this value (text, bytes, arrays, nested maps)
    pub fn deinitValue(self: *Self, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .text, .bytes => |s| alloc.free(s),
            .array => |a| {
                for (a) |item| {
                    var mut_item = item.*;
                    mut_item.deinitValue(alloc);
                }
                alloc.free(a);
            },
            .map => |m| m.deinit(),
            .tagged => |t| {
                t.value.deinitValue(alloc);
                alloc.free(t);
            },
            else => {},
        }
    }
};

pub const MapContext = struct {
    pub fn hash(ctx: @This(), key: CborValue) u64 {
        _ = ctx;
        return key.hashForMap();
    }

    pub fn eql(ctx: @This(), a: CborValue, b: CborValue) bool {
        _ = ctx;
        return a.equalsForMap(b);
    }
};

/// A simple CBOR map with string keys.
/// Use this for basic key-value maps. For heterogeneous keys, see CborMap in cbor_map.zig.
pub const ObjectMap = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    map: std.StringArrayHashMap(CborValue),

    /// Create a new empty ObjectMap
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .map = std.StringArrayHashMap(CborValue).init(allocator),
        };
    }

    /// Insert or update a key-value pair
    pub fn put(self: *Self, key: []const u8, value: CborValue) !void {
        const key_owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_owned);

        if (self.map.getKey(key)) |existing_key| {
            self.allocator.free(existing_key);
        }

        try self.map.put(key_owned, value);
    }

    pub fn clone(self: Self) !Self {
        var new_map = Self.init(self.allocator);
        errdefer new_map.deinit();

        var it = self.map.iterator();
        while (it.next()) |entry| {
            try new_map.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return new_map;
    }

    /// Serialize this map to CBOR format
    pub fn serialize(self: Self, writer: *io.Writer, opts: WriterOptions) Error!void {
        const count = self.map.count();

        if (count < 24) {
            try writer.writeByte(@as(u8, @intCast(0xA0 | count)));
        } else if (count <= std.math.maxInt(u8)) {
            try writer.writeByte(0xB8);
            try writer.writeByte(@intCast(count));
        } else if (count <= std.math.maxInt(u16)) {
            try writer.writeByte(0xB9);
            const be_value = std.mem.nativeToBig(u16, @intCast(count));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else if (count <= std.math.maxInt(u32)) {
            try writer.writeByte(0xBA);
            const be_value = std.mem.nativeToBig(u32, @intCast(count));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else {
            return Error.StringTooLong;
        }

        const is_strict = opts.mode == .strict or opts.mode == .deterministic;

        const keys = self.map.keys();
        if (opts.mode == .deterministic) {
            std.mem.sort([]const u8, keys, {}, struct {
                fn lessThan(_: @This(), a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);
        }

        if (is_strict) {
            var seen = std.StringArrayHashMap(void).init(self.map.allocator);
            defer seen.deinit();
            for (keys) |key| {
                if (seen.contains(key)) {
                    return Error.DuplicateMapKey;
                }
                try seen.put(key, {});
            }
        }

        for (keys) |key| {
            const value = self.map.get(key).?;
            try serializeString(key, writer, opts, .text_string);
            try value.serialize(writer, opts);
        }
    }

    /// Free all memory used by this map (keys, nested maps)
    pub fn deinit(self: *Self) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);

            switch (entry.value_ptr.*) {
                .map => |*obj| obj.deinit(),
                else => {},
            }
        }
        self.map.deinit();
    }
};

fn writeU16BigEndian(writer: *io.Writer, value: u16) !void {
    const high_byte: u8 = @truncate(value >> 8);
    const low_byte: u8 = @truncate(value);
    try writer.writeByte(high_byte);
    try writer.writeByte(low_byte);
}

const StringType = enum { text_string, byte_string };

fn serializeInteger(value: i64, writer: *io.Writer, opts: WriterOptions) Error!void {
    const preferred = opts.preferred or opts.mode == .strict;

    if (value >= 0) {
        if (preferred) {
            if (value <= 23) {
                try writer.writeByte(@intCast(value));
                return;
            }
            if (value <= std.math.maxInt(u8)) {
                try writer.writeByte(0x18);
                try writer.writeByte(@intCast(value));
                return;
            }
            if (value <= std.math.maxInt(u16)) {
                try writer.writeByte(0x19);
                try writeU16BigEndian(writer, @intCast(value));
                return;
            }
            if (value <= std.math.maxInt(u32)) {
                try writer.writeByte(0x1A);
                const be_value = std.mem.nativeToBig(u32, @intCast(value));
                try writer.writeAll(std.mem.asBytes(&be_value));
                return;
            }
        }
        try writer.writeByte(0x1B);
        const be_value = std.mem.nativeToBig(u64, @intCast(value));
        try writer.writeAll(std.mem.asBytes(&be_value));
    } else {
        const abs: u64 = if (value == std.math.minInt(i64))
            @as(u64, std.math.maxInt(i64)) + 1
        else
            @as(u64, @intCast(-value - 1));

        if (preferred) {
            if (abs <= 23) {
                try writer.writeByte(@as(u8, @intCast(0x20 | abs)));
                return;
            }
            if (abs <= std.math.maxInt(u8)) {
                try writer.writeByte(0x38);
                try writer.writeByte(@as(u8, @intCast(abs)));
                return;
            }
            if (abs <= std.math.maxInt(u16)) {
                try writer.writeByte(0x39);
                const be_value = std.mem.nativeToBig(u16, @intCast(abs));
                try writer.writeAll(std.mem.asBytes(&be_value));
                return;
            }
            if (abs <= std.math.maxInt(u32)) {
                try writer.writeByte(0x3A);
                const be_value = std.mem.nativeToBig(u32, @intCast(abs));
                try writer.writeAll(std.mem.asBytes(&be_value));
                return;
            }
        }
        try writer.writeByte(0x3B);
        const be_value = std.mem.nativeToBig(u64, @intCast(abs));
        try writer.writeAll(std.mem.asBytes(&be_value));
    }
}
fn doubleToHalf(value: f64) u16 {
    // Get binary representation of double
    const bits = @as(u64, @bitCast(value));

    // Extract double-precision components
    const sign = @as(u16, @intCast((bits >> 63) & 1));
    var exponent = @as(i16, @intCast((bits >> 52) & 0x7FF));
    var fraction = bits & 0x000FFFFFFFFFFFFF;

    // Special cases: Infinity or NaN
    if (exponent == 0x7FF) {
        if (fraction == 0) {
            // Infinity
            return (sign << 15) | 0x7C00;
        } else {
            // NaN
            return (sign << 15) | 0x7E00;
        }
    }

    // Remove double bias and add half bias
    exponent -= 1023;

    // Check for zero or denormalized number
    if (exponent < -24) {
        // Too small, return ±0
        return sign << 15;
    }

    // Check for overflow
    if (exponent > 15) {
        // Too large, return ±Infinity
        return (sign << 15) | 0x7C00;
    }

    var half: u16 = 0;

    if (exponent >= -14) {
        // Normalized number for half-precision
        half = @as(u16, @intCast((exponent + 15) << 10));
    } else {
        // Denormalized number for half-precision
        fraction |= 0x0010000000000000; // Add implicit bit
        const shift_amount = @as(u6, @intCast(-(exponent + 14 + 10)));
        fraction >>= shift_amount;
    }

    // Take 10 bits of mantissa
    half |= @as(u16, @intCast((fraction >> 42) & 0x3FF));

    // Add sign
    half |= (sign << 15);

    return half;
}

fn serializeFloat(value: f64, writer: *io.Writer, opts: WriterOptions) Error!void {
    const is_zero = value == 0.0;
    const is_neg_zero = value == -0.0;
    const is_inf = std.math.isInf(value);
    const is_nan = std.math.isNan(value);
    const is_special = is_zero or is_neg_zero or is_inf or is_nan;

    const preferred = opts.preferred or opts.mode == .strict;
    const abs_value = @abs(value);
    const is_small_integer = abs_value <= 65504.0 and @trunc(value) == value;

    const half = doubleToHalf(value);

    if (preferred) {
        const f32_val: f32 = @floatCast(value);
        const f64_roundtrip: f64 = @floatCast(f32_val);
        if (value == f64_roundtrip and !is_small_integer and !is_special) {
            try writer.writeByte(0xFA);
            const be_value = std.mem.nativeToBig(u32, @as(u32, @bitCast(f32_val)));
            try writer.writeAll(std.mem.asBytes(&be_value));
            return;
        }
        if (is_special or is_small_integer) {
            try writer.writeByte(0xF9);
            try writer.writeByte(@intCast((half >> 8) & 0xFF));
            try writer.writeByte(@intCast(half & 0xFF));
            return;
        }
    }
    try writer.writeByte(0xFB);
    const be_value = std.mem.nativeToBig(u64, @as(u64, @bitCast(value)));
    try writer.writeAll(std.mem.asBytes(&be_value));
}

fn serializeString(value: []const u8, writer: *io.Writer, opts: WriterOptions, str_type: StringType) Error!void {
    const len = value.len;
    const major = switch (str_type) {
        .text_string => 3,
        .byte_string => 2,
    };

    if (opts.definite or opts.mode == .deterministic) {
        if (len < 24) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | len)));
        } else if (len <= std.math.maxInt(u8)) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | 24)));
            try writer.writeByte(@as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | 25)));
            const be_value = std.mem.nativeToBig(u16, @intCast(len));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else if (len <= std.math.maxInt(u32)) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | 26)));
            const be_value = std.mem.nativeToBig(u32, @intCast(len));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else {
            return Error.StringTooLong;
        }
    } else {
        if (len < 24) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | len)));
        } else if (len <= std.math.maxInt(u8)) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | 24)));
            try writer.writeByte(@as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | 25)));
            const be_value = std.mem.nativeToBig(u16, @intCast(len));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else if (len <= std.math.maxInt(u32)) {
            try writer.writeByte(@as(u8, @intCast((major << 5) | 26)));
            const be_value = std.mem.nativeToBig(u32, @intCast(len));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else {
            return Error.StringTooLong;
        }
    }
    try writer.writeAll(value);
}

fn serializeArray(value: []const CborValue, writer: *io.Writer, opts: WriterOptions) Error!void {
    const len = value.len;
    if (opts.definite or opts.mode == .deterministic) {
        if (len < 24) {
            try writer.writeByte(@as(u8, @intCast(0x80 | len)));
        } else if (len <= std.math.maxInt(u8)) {
            try writer.writeByte(0x98);
            try writer.writeByte(@as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(0x99);
            const be_value = std.mem.nativeToBig(u16, @intCast(len));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else {
            return Error.StringTooLong;
        }
    } else {
        if (len < 24) {
            try writer.writeByte(@as(u8, @intCast(0x80 | len)));
        } else if (len <= std.math.maxInt(u8)) {
            try writer.writeByte(0x98);
            try writer.writeByte(@as(u8, @intCast(len)));
        } else if (len <= std.math.maxInt(u16)) {
            try writer.writeByte(0x99);
            const be_value = std.mem.nativeToBig(u16, @intCast(len));
            try writer.writeAll(std.mem.asBytes(&be_value));
        } else {
            return Error.StringTooLong;
        }
    }

    for (value) |item| {
        try item.serialize(writer, opts);
    }
}

fn serializeTagged(t: Tagged, writer: *io.Writer, opts: WriterOptions) Error!void {
    const tag = t.tag;
    if (tag <= 23) {
        try writer.writeByte(@as(u8, @intCast(0xC0 | tag)));
    } else if (tag <= std.math.maxInt(u8)) {
        try writer.writeByte(0xD8);
        try writer.writeByte(@intCast(tag));
    } else if (tag <= std.math.maxInt(u16)) {
        try writer.writeByte(0xD9);
        const be_value = std.mem.nativeToBig(u16, @intCast(tag));
        try writer.writeAll(std.mem.asBytes(&be_value));
    } else if (tag <= std.math.maxInt(u32)) {
        try writer.writeByte(0xDA);
        const be_value = std.mem.nativeToBig(u32, @intCast(tag));
        try writer.writeAll(std.mem.asBytes(&be_value));
    } else {
        try writer.writeByte(0xDB);
        const be_value = std.mem.nativeToBig(u64, @intCast(tag));
        try writer.writeAll(std.mem.asBytes(&be_value));
    }
    try t.value.serialize(writer, opts);
}

fn serializeSimple(value: u8, writer: *io.Writer, opts: WriterOptions) Error!void {
    if (opts.mode == .strict or opts.mode == .deterministic) {
        if (value >= 20 and value <= 30) return Error.ReservedValue;
    }
    if (value <= 19) {
        try writer.writeByte(0xE0 + value);
    } else if (value <= 255) {
        try writer.writeByte(0xF8);
        try writer.writeByte(value);
    } else {
        return Error.InvalidValue;
    }
}

/// Streaming CBOR Writer type - use makeWriter() to create instances
pub fn Writer(comptime Inner: type) type {
    return struct {
        inner: Inner,
        options: WriterOptions,

        /// Initialize a Writer with default options
        pub fn init(inner: Inner) @This() {
            return .{ .inner = inner, .options = .{} };
        }

        /// Write a null value (0xF6)
        pub fn writeNull(self: *@This()) Error!void {
            try self.inner.writeByte(0xF6);
        }

        /// Write an undefined value (0xF7)
        pub fn writeUndefined(self: *@This()) Error!void {
            try self.inner.writeByte(0xF7);
        }

        /// Write a boolean value
        pub fn boolean(self: *@This(), value: bool) Error!void {
            try self.inner.writeByte(if (value) 0xF5 else 0xF4);
        }

        /// Write a signed integer
        pub fn integer(self: *@This(), value: i64) Error!void {
            try serializeInteger(value, &self.inner, self.options);
        }

        /// Write an unsigned integer
        pub fn unsigned(self: *@This(), value: u64) Error!void {
            try serializeInteger(@intCast(value), &self.inner, self.options);
        }

        /// Write a floating-point value (f64)
        pub fn float(self: *@This(), value: f64) Error!void {
            try serializeFloat(value, &self.inner, self.options);
        }

        /// Write a text string (UTF-8)
        pub fn text(self: *@This(), value: []const u8) Error!void {
            try serializeString(value, &self.inner, self.options, .text_string);
        }

        /// Write a byte string (raw bytes)
        pub fn bytes(self: *@This(), value: []const u8) Error!void {
            try serializeString(value, &self.inner, self.options, .byte_string);
        }

        /// Write a simple value (0-19). Values 20-30 are reserved.
        pub fn simple(self: *@This(), value: u8) Error!void {
            if (value > 30 or (value >= 20 and value <= 30)) return Error.ReservedValue;
            try serializeSimple(value, &self.inner, self.options);
        }

        /// Write indefinite-length array header (0x9F)
        pub fn arrayIndefinite(self: *@This()) Error!void {
            try self.inner.writeByte(0x9F);
        }

        /// Write indefinite-length map header (0xBF)
        pub fn mapIndefinite(self: *@This()) Error!void {
            try self.inner.writeByte(0xBF);
        }

        /// Write indefinite-length text string header (0x7F)
        pub fn textIndefinite(self: *@This()) Error!void {
            try self.inner.writeByte(0x7F);
        }

        /// Write indefinite-length byte string header (0x5F)
        pub fn bytesIndefinite(self: *@This()) Error!void {
            try self.inner.writeByte(0x5F);
        }

        /// Write array header (definite length)
        pub fn array(self: *@This(), len: usize) Error!void {
            try serializeArray(&[_]CborValue{}, &self.inner, self.options);
            _ = len;
        }

        /// Write map header (definite length) - currently just writes empty map
        pub fn map(self: *@This(), len: usize) Error!void {
            _ = len;
            try self.inner.writeByte(0xA0);
        }

        /// Write break marker (0xFF) for indefinite-length containers
        pub fn end(self: *@This()) Error!void {
            try self.inner.writeByte(0xFF);
        }

        /// Write a tag number
        pub fn tag(self: *@This(), tag_num: u64) Error!void {
            if (tag_num <= 23) {
                try self.inner.writeByte(@as(u8, @intCast(0xC0 | tag_num)));
            } else if (tag_num <= std.math.maxInt(u8)) {
                try self.inner.writeByte(0xD8);
                try self.inner.writeByte(@intCast(tag_num));
            } else if (tag_num <= std.math.maxInt(u16)) {
                try self.inner.writeByte(0xD9);
                const be_value = std.mem.nativeToBig(u16, @intCast(tag_num));
                try self.inner.writeAll(std.mem.asBytes(&be_value));
            } else {
                try self.inner.writeByte(0xDB);
                const be_value = std.mem.nativeToBig(u64, @intCast(tag_num));
                try self.inner.writeAll(std.mem.asBytes(&be_value));
            }
        }

        /// Write a complete CborValue
        pub fn write(self: *@This(), value: CborValue) Error!void {
            try value.serialize(&self.inner, self.options);
        }
    };
}

/// Create a streaming Writer from any io.Writer
pub fn makeWriter(inner: anytype) Writer(@TypeOf(inner)) {
    return Writer(@TypeOf(inner)).init(inner);
}

/// Streaming CBOR Reader type - use makeReader() to create instances
pub fn Reader(comptime Inner: type) type {
    return struct {
        inner: Inner,
        allocator: std.mem.Allocator,

        /// Initialize a Reader with an inner reader and allocator
        pub fn init(inner: Inner, allocator: std.mem.Allocator) @This() {
            return .{ .inner = inner, .allocator = allocator };
        }

        /// Peek at the next major type without consuming
        pub fn peek(self: *@This()) Error!MajorType {
            const byte = self.inner.readByte() catch |e| {
                if (e == error.EndOfStream) return .unsigned_integer;
                return e;
            };
            const major = @as(MajorType, @enumFromInt(byte >> 5));
            return major;
        }

        /// Read a null value, returns error if next byte is not 0xF6
        pub fn readNull(self: *@This()) Error!void {
            const byte = try self.inner.readByte();
            if (byte != 0xF6) return Error.InvalidValue;
        }

        /// Read an undefined value, returns error if next byte is not 0xF7
        pub fn readUndefined(self: *@This()) Error!void {
            const byte = try self.inner.readByte();
            if (byte != 0xF7) return Error.InvalidValue;
        }

        /// Read a boolean value
        pub fn readBoolean(self: *@This()) Error!bool {
            const byte = try self.inner.readByte();
            return switch (byte) {
                0xF4 => false,
                0xF5 => true,
                else => return Error.InvalidValue,
            };
        }

        /// Read an integer (signed i64)
        pub fn readInteger(self: *@This()) Error!i64 {
            const byte = try self.inner.readByte();
            const major: MajorType = @enumFromInt(byte >> 5);
            const ai = @as(u5, @intCast(byte & 0x1F));

            switch (major) {
                .unsigned_integer => {
                    if (ai < 24) return ai;
                    if (ai == 24) return @as(i64, @intCast(try self.inner.readByte()));
                    if (ai == 25) {
                        var buf: [2]u8 = undefined;
                        try self.inner.readAll(&buf);
                        return std.mem.bigToNative(i16, std.mem.bytesToValue(i16, &buf));
                    }
                    if (ai == 26) {
                        var buf: [4]u8 = undefined;
                        try self.inner.readAll(&buf);
                        return std.mem.bigToNative(i32, std.mem.bytesToValue(i32, &buf));
                    }
                    if (ai == 27) {
                        var buf: [8]u8 = undefined;
                        try self.inner.readAll(&buf);
                        return std.mem.bigToNative(i64, std.mem.bytesToValue(i64, &buf));
                    }
                    return Error.InvalidValue;
                },
                .negative_integer => {
                    if (ai < 24) return -1 - ai;
                    if (ai == 24) return -1 - @as(i64, @intCast(try self.inner.readByte()));
                    return Error.InvalidValue;
                },
                else => return Error.InvalidValue,
            }
        }

        /// Read an unsigned integer as u64
        pub fn readUnsigned(self: *@This()) Error!u64 {
            return @as(u64, @intCast(try self.readInteger()));
        }

        /// Read a float value (f64). Supports float16, float32, and float64.
        pub fn readFloat(self: *@This()) Error!f64 {
            const byte = try self.inner.readByte();
            const major: MajorType = @enumFromInt(byte >> 5);
            const ai = byte & 0x1F;

            switch (major) {
                .float_or_simple => {
                    switch (ai) {
                        25 => {
                            var buf: [2]u8 = undefined;
                            try self.inner.readAll(&buf);
                            return binary16ToF64(std.mem.bigToNative(u16, std.mem.bytesToValue(u16, &buf)));
                        },
                        26 => {
                            var buf: [4]u8 = undefined;
                            try self.inner.readAll(&buf);
                            return std.mem.bytesToValue(f32, &buf);
                        },
                        27 => {
                            var buf: [8]u8 = undefined;
                            try self.inner.readAll(&buf);
                            return std.mem.bytesToValue(f64, &buf);
                        },
                        else => return Error.InvalidValue,
                    }
                },
                else => return Error.InvalidValue,
            }
        }

        /// Read a simple value (0-19) or special simple types (false/true/null/undefined)
        pub fn readSimple(self: *@This()) Error!u8 {
            const byte = try self.inner.readByte();
            const major: MajorType = @enumFromInt(byte >> 5);
            const ai = byte & 0x1F;

            switch (major) {
                .float_or_simple => {
                    if (ai < 20) return ai;
                    return switch (ai) {
                        20 => return false,
                        21 => return true,
                        22 => return null,
                        23 => return undefined,
                        else => return Error.InvalidValue,
                    };
                },
                else => return Error.InvalidValue,
            }
        }

        /// Read a text string (returns owned slice, caller must free)
        pub fn readText(self: *@This()) Error![]const u8 {
            const byte = try self.inner.readByte();
            const ai = @as(u5, @intCast(byte & 0x1F));
            const len = try parseStringLenHelper(ai, &self.inner);
            const buf = try self.inner.readBytesAlloc(self.allocator, len);
            return buf;
        }

        /// Read a byte string (returns owned slice, caller must free)
        pub fn readBytes(self: *@This()) Error![]const u8 {
            const byte = try self.inner.readByte();
            const ai = @as(u5, @intCast(byte & 0x1F));
            const len = try parseStringLenHelper(ai, &self.inner);
            const buf = try self.inner.readBytesAlloc(self.allocator, len);
            return buf;
        }

        /// Get array length (number of elements)
        pub fn readArray(self: *@This()) Error!usize {
            const byte = try self.inner.readByte();
            const ai = @as(u5, @intCast(byte & 0x1F));
            return try parseArrayLenHelper(ai, &self.inner);
        }

        /// Get map pair count
        pub fn readMap(self: *@This()) Error!usize {
            const byte = try self.inner.readByte();
            const ai = @as(u5, @intCast(byte & 0x1F));
            return try parseMapLenHelper(ai, &self.inner);
        }

        /// Read a tag number
        pub fn readTag(self: *@This()) Error!u64 {
            const byte = try self.inner.readByte();
            const ai = @as(u5, @intCast(byte & 0x1F));
            return try parseTagHelper(ai, &self.inner);
        }

        /// Read and parse the next complete CBOR value
        pub fn read(self: *@This()) Error!CborValue {
            const byte = try self.inner.readByte();
            const major: MajorType = @enumFromInt(byte >> 5);
            const ai = byte & 0x1F;

            switch (major) {
                .unsigned_integer => {
                    if (ai < 24) return CborValue.initInteger(ai);
                    if (ai == 24) {
                        const val = try self.inner.readByte();
                        return CborValue.initInteger(val);
                    }
                    if (ai == 25) {
                        var buf: [2]u8 = undefined;
                        try self.inner.readAll(&buf);
                        return CborValue.initInteger(std.mem.bigToNative(i16, std.mem.bytesToValue(i16, &buf)));
                    }
                    if (ai == 26) {
                        var buf: [4]u8 = undefined;
                        try self.inner.readAll(&buf);
                        return CborValue.initInteger(std.mem.bigToNative(i32, std.mem.bytesToValue(i32, &buf)));
                    }
                    if (ai == 27) {
                        var buf: [8]u8 = undefined;
                        try self.inner.readAll(&buf);
                        return CborValue.initInteger(std.mem.bigToNative(i64, std.mem.bytesToValue(i64, &buf)));
                    }
                    return Error.InvalidValue;
                },
                .negative_integer => {
                    if (ai < 24) return CborValue.initInteger(-1 - ai);
                    if (ai == 24) {
                        const val = try self.inner.readByte();
                        return CborValue.initInteger(-1 - val);
                    }
                    return Error.InvalidValue;
                },
                .text_string => {
                    const len = try parseStringLenHelper(ai, &self.inner);
                    const buf = try self.inner.readBytesAlloc(self.allocator, len);
                    return CborValue.initString(buf);
                },
                .byte_string => {
                    const len = try parseStringLenHelper(ai, &self.inner);
                    const buf = try self.inner.readBytesAlloc(self.allocator, len);
                    return CborValue.initBytes(buf);
                },
                .array => {
                    const len = try parseArrayLenHelper(ai, &self.inner);
                    const arr = try self.allocator.alloc(CborValue, len);
                    for (arr) |*item| {
                        item.* = try self.read();
                    }
                    return CborValue.initArray(arr);
                },
                .map => {
                    const len = try parseMapLenHelper(ai, &self.inner);
                    if (len == std.math.maxInt(usize)) {
                        var items = std.ArrayList(CborValue).init(self.allocator);
                        defer items.deinit();
                        while (true) {
                            const next_byte = self.inner.readByte() catch break;
                            if (next_byte == 0xFF) break;
                            try self.inner.backup(1);
                            const key = try self.read();
                            const value = try self.read();
                            try items.append(key);
                            try items.append(value);
                        }
                        const pair_count = items.items.len / 2;
                        const pairs = try self.allocator.alloc(CborValue, pair_count * 2);
                        @memcpy(pairs, items.items);
                        return .{ .array = @ptrCast(pairs) };
                    }
                    var pairs = try self.allocator.alloc(CborValue, len * 2);
                    for (0..len) |i| {
                        pairs[i * 2] = try self.read();
                        pairs[i * 2 + 1] = try self.read();
                    }
                    return .{ .array = @ptrCast(pairs) };
                },
                .tag => {
                    const tag = try parseTagHelper(ai, &self.inner);
                    const value = try self.read();
                    return value.initTagged(tag, value);
                },
                .float_or_simple => {
                    switch (ai) {
                        20 => return CborValue.initBoolean(false),
                        21 => return CborValue.initBoolean(true),
                        22 => return CborValue.initNull(),
                        23 => return CborValue.initUndefined(),
                        25, 26, 27 => {
                            const f = try self.readFloat();
                            return CborValue.initFloat(f);
                        },
                        else => return CborValue.initSimple(ai),
                    }
                },
            }
        }
    };
}

/// Create a streaming Reader from any io.Reader
pub fn makeReader(inner: anytype, allocator: std.mem.Allocator) Reader(@TypeOf(inner)) {
    return Reader(@TypeOf(inner)).init(inner, allocator);
}

fn binary16ToF64(b16: u16) f64 {
    const sign = (b16 >> 15) & 1;
    const exp = @as(u16, (b16 >> 10) & 0x1F);
    const mant = b16 & 0x3FF;

    if (exp == 0x1F) {
        if (mant == 0) {
            return if (sign == 1) -std.math.inf(f64) else std.math.inf(f64);
        }
        return std.math.nan(f64);
    }

    var result: f64 = 0;
    if (exp == 0) {
        result = @as(f64, mant) / std.math.pow(f64, 2.0, 10.0);
    } else {
        result = @as(f64, mant + 0x400) / std.math.pow(f64, 2.0, 10.0);
        result *= std.math.pow(f64, 2.0, @as(f64, exp) - 15.0);
    }

    if (sign == 1) result = -result;
    return result;
}

fn parseStringLenHelper(ai: u5, r: anytype) Error!usize {
    if (ai < 24) return ai;
    if (ai == 24) {
        const val = try r.readByte();
        return val;
    }
    if (ai == 25) {
        var buf: [2]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u16, std.mem.bytesToValue(u16, &buf));
    }
    if (ai == 26) {
        var buf: [4]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u32, std.mem.bytesToValue(u32, &buf));
    }
    if (ai == 27) {
        return Error.IndefiniteNotAllowed;
    }
    return Error.InvalidValue;
}

fn parseArrayLenHelper(ai: u5, r: anytype) Error!usize {
    if (ai < 24) return ai;
    if (ai == 24) {
        const val = try r.readByte();
        return val;
    }
    if (ai == 25) {
        var buf: [2]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u16, std.mem.bytesToValue(u16, &buf));
    }
    if (ai == 26) {
        var buf: [4]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u32, std.mem.bytesToValue(u32, &buf));
    }
    if (ai == 27) {
        return Error.IndefiniteNotAllowed;
    }
    return Error.InvalidValue;
}

fn parseMapLenHelper(ai: u5, r: anytype) Error!usize {
    if (ai < 24) return ai;
    if (ai == 24) {
        const val = try r.readByte();
        return val;
    }
    if (ai == 25) {
        var buf: [2]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u16, std.mem.bytesToValue(u16, &buf));
    }
    if (ai == 26) {
        var buf: [4]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u32, std.mem.bytesToValue(u32, &buf));
    }
    if (ai == 27) {
        return Error.IndefiniteNotAllowed;
    }
    return Error.InvalidValue;
}

fn parseTagHelper(ai: u5, r: anytype) Error!u64 {
    if (ai < 24) return ai;
    if (ai == 24) {
        const val = try r.readByte();
        return val;
    }
    if (ai == 25) {
        var buf: [2]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u16, std.mem.bytesToValue(u16, &buf));
    }
    if (ai == 26) {
        var buf: [4]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u32, std.mem.bytesToValue(u32, &buf));
    }
    if (ai == 27) {
        var buf: [8]u8 = undefined;
        try r.readAll(&buf);
        return std.mem.bigToNative(u64, std.mem.bytesToValue(u64, &buf));
    }
    return Error.InvalidValue;
}

/// Serialize a CborValue to a new byte buffer
pub fn serialize(allocator: std.mem.Allocator, value: CborValue, opts: WriterOptions) Error![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    var w = Writer(std.ArrayList(u8)).init(list.writer());
    try w.write(value);

    _ = opts;
    return list.toOwnedSlice();
}

/// Deserialize CBOR data into a CborValue
pub fn deserialize(allocator: std.mem.Allocator, data: []const u8, mode: ValidationMode) Error!CborValue {
    if (data.len == 0) return Error.InvalidValue;

    var stream = std.io.fixedBufferStream(data);
    var r = Reader(std.io.FixedBufferStream).init(stream.reader(), allocator);

    _ = mode;
    return try r.read();
}

/// Validate CBOR data well-formedness without full deserialization
pub fn validate(allocator: std.mem.Allocator, data: []const u8, mode: ValidationMode) Error!void {
    if (data.len == 0) return Error.InvalidValue;

    var stream = std.io.fixedBufferStream(data);
    var r = Reader(std.io.FixedBufferStream).init(stream.reader(), allocator);

    _ = try r.read();

    if (mode == .strict or mode == .deterministic) {
        if (stream.pos < data.len) return Error.InvalidValue;
    }
}

pub const TagRegistry = struct {
    pub const DateTimeString: u64 = 0;
    pub const EpochTimestamp: u64 = 1;
    pub const UnsignedBignum: u64 = 2;
    pub const NegativeBignum: u64 = 3;
    pub const DecimalFraction: u64 = 4;
    pub const Bigfloat: u64 = 5;
    pub const ExpectedJson: u64 = 25;
    pub const CborSequence: u64 = 30;
    pub const Uri: u64 = 35;
    pub const Base64url: u64 = 36;
    pub const Base64: u64 = 37;
    pub const MIME: u64 = 38;
    pub const SelfDescribedCBOR: u64 = 55799;

    pub const TagContentType = enum {
        unsigned_int,
        negative_int,
        bytes,
        text,
        array,
        any,
    };

    pub fn expectedContentType(tag: u64) TagContentType {
        return switch (tag) {
            0 => .text,
            1 => .unsigned_int,
            2 => .bytes,
            3 => .bytes,
            4 => .array,
            5 => .array,
            25, 30, 55799 => .any,
            35, 36, 37, 38 => .text,
            else => .any,
        };
    }

    pub fn validateContent(tag: u64, value: CborValue) Error!void {
        const expected = expectedContentType(tag);
        const valid = switch (expected) {
            .text => value == .text,
            .bytes => value == .bytes,
            .unsigned_int => value == .integer and value.integer >= 0,
            .negative_int => value == .integer and value.integer < 0,
            .array => value == .array,
            .any => true,
        };
        if (!valid) return Error.InvalidTagContent;
    }
};

pub const Map = @import("cbor_map.zig");
pub const CborMap = Map.CborMap;
pub const CborMapKey = Map.CborMapKey;
pub const MapOptions = Map.MapOptions;
