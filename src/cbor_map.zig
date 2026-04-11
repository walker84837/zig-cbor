const std = @import("std");
const cbor = @import("cbor.zig");

pub const MapOptions = struct {
    deterministic: bool = false,
    allow_duplicates: bool = true,
};

pub const CborMapKey = struct {
    encoding: []const u8,

    pub fn fromValue(val: cbor.CborValue, alloc: std.mem.Allocator) !@This() {
        var list = std.ArrayList(u8).init(alloc);
        errdefer list.deinit();
        try val.serialize(list.writer(), .{});
        return .{ .encoding = try list.toOwnedSlice() };
    }

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.encoding);
    }

    pub fn clone(self: @This(), alloc: std.mem.Allocator) !@This() {
        const copy = try alloc.dupe(u8, self.encoding);
        return .{ .encoding = copy };
    }
};

pub const CborMapContext = struct {
    pub fn hash(ctx: @This(), key: CborMapKey) u64 {
        _ = ctx;
        var hasher = std.hash.Wyhash.init();
        hasher.update(key.encoding);
        return hasher.final();
    }

    pub fn eql(ctx: @This(), a: CborMapKey, b: CborMapKey) bool {
        _ = ctx;
        return std.mem.eql(u8, a.encoding, b.encoding);
    }
};

pub const CborMap = std.ArrayHashMap(CborMapKey, cbor.CborValue, CborMapContext, true);

pub fn mapInit(alloc: std.mem.Allocator) CborMap {
    return CborMap.init(alloc);
}

pub fn mapPut(
    map: *CborMap,
    key: cbor.CborValue,
    value: cbor.CborValue,
    options: MapOptions,
) !void {
    const key_copy = try CborMapKey.fromValue(key, map.allocator);
    errdefer key_copy.deinit(map.allocator);

    if (!options.allow_duplicates) {
        const existing = map.get(key_copy);
        if (existing) |exp| {
            exp.key_ptr.*.deinit(map.allocator);
            _ = map.remove(&existing.key);
        }
    }

    const value_copy = try value.cloneValue(map.allocator);
    try map.put(key_copy, value_copy);
}

pub fn serializeMap(
    map: CborMap,
    writer: anytype,
    options: cbor.WriterOptions,
    map_options: MapOptions,
) !void {
    const count = map.count();

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
        return cbor.Error.StringTooLong;
    }

    var keys = try map.allocator.alloc(CborMapKey, count);
    defer map.allocator.free(keys);

    var i: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| {
        keys[i] = entry.key_ptr.*;
        i += 1;
    }

    if (map_options.deterministic) {
        std.sort.sort(CborMapKey, keys, {}, struct {
            fn lessThan(_: @This(), a: CborMapKey, b: CborMapKey) bool {
                return std.mem.order(u8, a.encoding, b.encoding) == .lt;
            }
        }.lessThan);
    }

    for (keys) |key| {
        if (map.get(key)) |entry| {
            try writer.writeAll(key.encoding);
            try entry.value_ptr.*.serialize(writer, options);
        }
    }
}

pub fn mapDeinit(map: *CborMap) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        entry.key_ptr.*.deinit(map.allocator);
        var mut_val = entry.value_ptr.*;
        mut_val.deinitValue(map.allocator);
    }
    map.deinit();
}
