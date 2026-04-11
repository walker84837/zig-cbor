const std = @import("std");
const cbor = @import("cbor.zig");

const CborValue = cbor.CborValue;
const io = std.io;

test "CBOR integer serialization" {
    var buffer: [100]u8 = undefined; // Fixed-size buffer
    var fixed_writer = io.Writer.fixed(&buffer);

    // Test a small integer
    const val_small: i64 = 10;
    try CborValue.initInteger(val_small).serialize(&fixed_writer);
    const expected_small = [_]u8{0x0a};
    try std.testing.expectEqualSlices(u8, &expected_small, fixed_writer.buffered());
    fixed_writer.end = 0; // Reset writer for next test

    // Test a larger integer (u8 max + 1)
    const val_u8_plus_1: i64 = 24;
    try CborValue.initInteger(val_u8_plus_1).serialize(&fixed_writer);
    const expected_u8_plus_1 = [_]u8{ 0x18, 0x18 };
    try std.testing.expectEqualSlices(u8, &expected_u8_plus_1, fixed_writer.buffered());
    fixed_writer.end = 0;

    // Test a negative integer
    const val_neg: i64 = -1;
    try CborValue.initInteger(val_neg).serialize(&fixed_writer);
    const expected_neg = [_]u8{0x20};
    try std.testing.expectEqualSlices(u8, &expected_neg, fixed_writer.buffered());
    fixed_writer.end = 0;

    // Test a larger negative integer
    const val_neg_large: i64 = -42;
    try CborValue.initInteger(val_neg_large).serialize(&fixed_writer);
    const expected_neg_large = [_]u8{ 0x38, 0x29 }; // Major type 1, 1-byte integer, value 41 (abs(-42) - 1)
    try std.testing.expectEqualSlices(u8, &expected_neg_large, fixed_writer.buffered());
    fixed_writer.end = 0;
}
