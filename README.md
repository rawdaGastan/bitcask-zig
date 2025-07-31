# Bitcask-Zig

A Zig implementation of the Bitcask key-value store.

## What is Bitcask?

Bitcask is a log-structured key-value store with a simple design that provides high-performance operations. It was originally developed by Basho Technologies for Riak.

Key features of Bitcask:

- Fast reads and writes (O(1) complexity)
- Crash recovery
- Easy backup
- Relatively simple design

## How it works

Bitcask has a simple design:

1. All writes go to an append-only data file
2. An in-memory index maps each key to its location in the data files
3. When the active data file gets too large, it's closed and a new one is created
4. A merge process compacts old data files by removing stale entries

## Usage

```zig
const std = @import("std");
const Bitcask = @import("bitcask-zig").Bitcask;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize Bitcask with a directory path
    var db = try Bitcask.init(allocator, "my_database", .{});
    defer db.deinit();

    // Put a key-value pair
    try db.put("hello", "world", .{});

    // Get a value
    const value = try db.get("hello");
    if (value) |v| {
        std.debug.print("Value: {s}\n", .{v});
        allocator.free(v); // Remember to free the value
    }

    // Delete a key
    _ = try db.delete("hello");

    // List all keys
    const keys = try db.listKeys();
    defer {
        for (keys) |key| {
            allocator.free(key);
        }
        allocator.free(keys);
    }

    // Sync to disk
    try db.sync();

    // Merge/compact the database
    try db.merge();
}
```

## Building

```bash
zig build
```

## Running Tests

```bash
zig build test
```

## Features

- [x] Basic key-value operations (put, get, delete)
- [x] Persistence to disk
- [x] File rotation
- [x] Merge/compaction
- [x] List keys
- [ ] CRC checksums for data integrity
- [ ] Hint files for faster startup
- [ ] Configurable expiry

## License

MIT
