const std = @import("std");
const cbor = @import("cbor.zig");

test "basic cbor types exist" {
    _ = cbor.CborValue;
    _ = cbor.WriterOptions;
    _ = cbor.ValidationMode;
    _ = cbor.MajorType;
    _ = cbor.Error;
    _ = cbor.ObjectMap;
}

test "create simple values" {
    const null_val = cbor.CborValue.initNull();
    try std.testing.expect(null_val == .null);

    const bool_val = cbor.CborValue.initBoolean(true);
    try std.testing.expect(bool_val == .bool);

    const int_val = cbor.CborValue.initInteger(42);
    try std.testing.expect(int_val == .integer);

    const undef = cbor.CborValue.initUndefined();
    try std.testing.expect(undef == .undefined);
}

test "Writer create" {
    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const w = cbor.makeWriter(fbs.writer());
    _ = w;
}

test "Reader create" {
    var buffer: [100]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    const r = cbor.makeReader(fbs.reader(), std.testing.allocator);
    _ = r;
}
