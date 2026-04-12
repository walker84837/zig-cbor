# zig-cbor :zap:

> A RFC 8949 compliant CBOR (Concise Binary Object Representation) serializer/deserializer for Zig 0.15+.

## Features

- :arrow_right: **Serialization** Encode Zig values to CBOR bytes
- :arrow_left: **Deserialization** Decode CBOR bytes to CborValue
- :arrows_clockwise: **Streaming** Writer/Reader for incremental processing
- :white_check_mark: **Validation Modes** well_formed, strict, deterministic
- :wrench: **Custom Allocators** Pass your own allocator
- :key: **Heterogeneous Maps** CborMap with any CBOR value as key
- :label: **Tag Support** Tagged values with content validation

## Compatibility

Requires Zig 0.15.2 or later.

## Installation

You can add `zig-cbor` as a dependency to your project using `zig fetch`.

```sh
zig fetch --save=cbor git+https://github.com/walker84837/zig-cbor#main
```

### Add to `build.zig`

Next, make the module available to your application by modifying your `build.zig` file:

```zig
const cbor_dep = b.dependency("cbor", .{
    .target = target,
    .optimize = optimize,
});
const cbor_module = cbor_dep.module("cbor");

exe.root_module.addImport("cbor", cbor_module);
```

## Quick Start

### Usage

Import the library and use it in your Zig project:

```zig
const std = @import("std");
const cbor = @import("cbor");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a map with string keys
    var obj = cbor.ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("message", cbor.CborValue.initString("Hello"));
    try obj.put("count", cbor.CborValue.initInteger(42));
    try obj.put("enabled", cbor.CborValue.initBoolean(true));

    // Serialize to bytes
    const encoded = try cbor.serialize(allocator, cbor.CborValue.initObject(obj), .{});
    defer allocator.free(encoded);

    std.debug.print("Encoded: {x}\n", .{encoded});

    // Deserialize back
    const decoded = try cbor.deserialize(allocator, encoded, .well_formed);
    std.debug.print("Decoded: {}\n", .{decoded});
}
```

### Streaming API

```zig
// Writer for incremental serialization
var buffer: [256]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buffer);
var w = cbor.makeWriter(fbs.writer());

try w.map(2);
try w.text("key");
try w.text("value");

// Reader for incremental deserialization
var r = cbor.makeReader(fbs.reader(), allocator);
const value = try r.read();
```

### Builder Patterns

```zig
const v = cbor.CborValue;

const str = v.initString("hello");
const num = v.initInteger(42);
const flag = v.initBoolean(true);
const nil = v.initNull();
const undef = v.initUndefined();
const flt = v.initFloat(3.14);
const bin = v.initBytes(&[_]u8{1,2,3});
const arr = v.initArray(&[_]cbor.CborValue{ v.initInteger(1), v.initInteger(2) });
```

## Testing

```sh
zig build test
```

## Building

```sh
zig build # Build static library
```

## License :scroll:

This project is licensed under the MIT License.
