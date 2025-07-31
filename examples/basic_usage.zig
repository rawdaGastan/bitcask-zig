const std = @import("std");
const Bitcask = @import("../src/main.zig").Bitcask;

pub fn main() !void {
    // Initialize a general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create a directory for our database
    const db_dir = "example_db";
    defer std.fs.cwd().deleteTree(db_dir) catch {}; // Clean up after ourselves

    std.debug.print("Initializing Bitcask database in '{s}'...\n", .{db_dir});

    // Initialize Bitcask with default configuration
    var db = try Bitcask.init(allocator, db_dir, .{});
    defer db.deinit();

    // Put some key-value pairs
    try db.put("hello", "world", .{});
    try db.put("foo", "bar", .{});
    try db.put("number", "42", .{});

    std.debug.print("Added 3 key-value pairs\n", .{});

    // Get values
    const value1 = try db.get("hello");
    if (value1) |v| {
        std.debug.print("hello -> {s}\n", .{v});
        allocator.free(v); // Remember to free the value
    }

    const value2 = try db.get("foo");
    if (value2) |v| {
        std.debug.print("foo -> {s}\n", .{v});
        allocator.free(v);
    }

    const value3 = try db.get("number");
    if (value3) |v| {
        std.debug.print("number -> {s}\n", .{v});
        allocator.free(v);
    }

    // Try a non-existent key
    const missing = try db.get("missing");
    if (missing) |v| {
        std.debug.print("missing -> {s}\n", .{v});
        allocator.free(v);
    } else {
        std.debug.print("Key 'missing' not found, as expected\n", .{});
    }

    // Delete a key
    _ = try db.delete("foo");
    std.debug.print("Deleted key 'foo'\n", .{});

    // Verify it's gone
    const deleted = try db.get("foo");
    if (deleted) |v| {
        std.debug.print("foo -> {s} (unexpected!)\n", .{v});
        allocator.free(v);
    } else {
        std.debug.print("Key 'foo' was successfully deleted\n", .{});
    }

    // List all keys
    const keys = try db.listKeys();
    defer {
        for (keys) |key| {
            allocator.free(key);
        }
        allocator.free(keys);
    }

    std.debug.print("\nRemaining keys ({d}):\n", .{keys.len});
    for (keys) |key| {
        std.debug.print("- {s}\n", .{key});
    }

    // Sync to ensure data is written to disk
    try db.sync();
    std.debug.print("\nDatabase synced to disk\n", .{});
}