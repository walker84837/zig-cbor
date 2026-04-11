# CBOR Serializer in Zig

A lightweight and efficient CBOR (Concise Binary Object Representation) serializer implemented in Zig.

## Features

- Fast and compact serialization of data into CBOR format
- Fully written in Zig for high performance and low memory usage
- Supports encoding basic data types (integers, strings, arrays, maps, etc.)
- Minimal dependencies

## Compatibility

This library requires Zig version 0.15.2 or later. It has been tested with Zig 0.15.2.

## Installation

You can add `zig-cbor` as a dependency to your project using `zig fetch`.

```sh
zig fetch --save=cbor git+https://github.com/solenopsys/zig-cbor#main
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

## Building
To build the library:
```sh
zig build
```

## Testing
To run the tests:
```sh
zig build test
```

## Usage

Import the serializer and use it in your Zig project:
```zig
const std = @import("std");
const cbor = @import("cbor");

const CborValue = cbor.CborValue;
const ObjectMap = cbor.ObjectMap;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var obj = ObjectMap.init(allocator);
    defer obj.deinit();

    try obj.put("message", CborValue.initString("Hello, CBOR!"));
    try obj.put("number", CborValue.initInteger(42));
    try obj.put("flag", CborValue.initBoolean(true));

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try CborValue.initObject(&obj).serialize(buf.writer());
    std.debug.print("Serialized CBOR: {any}\n", .{buf.items});
}
```

## Roadmap

- [ ] Support for floating-point numbers
- [ ] CBOR decoding functionality
- [ ] Support for custom data types

## License

This project is licensed under the MIT License.
