const std = @import("std");
const fs = std.fs;
const testing = std.testing;
const Bitcask = @import("main.zig").Bitcask;

test "Bitcask basic operations" {
    const allocator = testing.allocator;

    // Create a temporary directory for the test
    const test_dir = "test_bitcask_basic";
    defer fs.cwd().deleteTree(test_dir) catch {};

    // Initialize Bitcask
    var db = try Bitcask.init(allocator, test_dir, .{});
    defer db.deinit();

    // Test put and get
    try db.put("key1", "value1", .{});
    try db.put("key2", "value2", .{});

    // Test get and free the returned value
    const value1 = try db.get("key1");
    defer if (value1) |v| allocator.free(v);
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try db.get("key2");
    defer if (value2) |v| allocator.free(v);
    try testing.expectEqualStrings("value2", value2.?);

    // Test non-existent key
    const value3 = try db.get("key3");
    defer if (value3) |v| allocator.free(v);
    try testing.expect(value3 == null);

    // Test delete
    _ = try db.delete("key1");
    const deleted_value = try db.get("key1");
    defer if (deleted_value) |v| allocator.free(v);
    try testing.expect(deleted_value == null);

    // Test list keys
    const keys = try db.listKeys();
    defer {
        for (keys) |key| {
            allocator.free(key);
        }
        allocator.free(keys);
    }

    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("key2", keys[0]);

    // Test sync
    try db.sync();
}

test "Bitcask file rotation" {
    const allocator = testing.allocator;

    // Create a temporary directory for the test
    const test_dir = "test_bitcask_rotation";
    defer fs.cwd().deleteTree(test_dir) catch {};

    // Initialize Bitcask with a small max file size to trigger rotation
    var db = try Bitcask.init(allocator, test_dir, .{
        .max_file_size = 100, // Small size to trigger rotation
    });
    defer db.deinit();

    // Add enough data to trigger file rotation
    const num_entries = 10;
    for (0..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        defer allocator.free(value);

        try db.put(key, value, .{
            .max_file_size = 100, // Small size to trigger rotation
        });
    }

    // Verify all data is still accessible
    for (0..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const expected_value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        defer allocator.free(expected_value);

        const value = try db.get(key);
        defer if (value) |v| allocator.free(v);

        try testing.expectEqualStrings(expected_value, value.?);
    }

    // Verify we have multiple data files
    var dir = try fs.cwd().openDir(test_dir, .{ .iterate = true });
    defer dir.close();

    var data_file_count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "data.")) {
            data_file_count += 1;
        }
    }

    try testing.expect(data_file_count > 1);
}

test "Bitcask merge/compaction" {
    const allocator = testing.allocator;

    // Create a temporary directory for the test
    const test_dir = "test_bitcask_merge";
    defer fs.cwd().deleteTree(test_dir) catch {};

    // Initialize Bitcask with a small max file size
    var db = try Bitcask.init(allocator, test_dir, .{
        .max_file_size = 100, // Small size to trigger rotation
    });
    defer db.deinit();

    // Add data
    const num_entries = 10;
    for (0..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        defer allocator.free(value);

        try db.put(key, value, .{
            .max_file_size = 100,
        });
    }

    // Update some keys to create stale entries
    for (0..5) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try std.fmt.allocPrint(allocator, "updated{d}", .{i});
        defer allocator.free(value);

        try db.put(key, value, .{
            .max_file_size = 100,
        });
    }

    // Delete some keys
    for (5..8) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        _ = try db.delete(key);
    }

    // Perform merge
    try db.sync();
    try db.merge();

    // Verify data after merge
    // Updated keys (0-4)
    for (0..5) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try db.get(key);
        defer if (value) |v| allocator.free(v);

        // Verify it starts with "updated"
        try testing.expect(value != null);
        try testing.expect(std.mem.startsWith(u8, value.?, "updated"));
    }

    // Deleted keys (5-7)
    for (5..8) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try db.get(key);
        defer if (value) |v| allocator.free(v);

        try testing.expect(value == null);
    }

    for (8..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try db.get(key);
        defer if (value) |v| allocator.free(v);

        try testing.expect(value != null);
    }

    // Verify we have only one data file after merge
    var dir = try fs.cwd().openDir(test_dir, .{ .iterate = true });
    defer dir.close();

    var data_file_count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "data.")) {
            data_file_count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 1), data_file_count);
}

test "Bitcask file ID tracking" {
    const allocator = testing.allocator;

    // Create a temporary directory for the test
    const test_dir = "test_bitcask_file_id";
    defer fs.cwd().deleteTree(test_dir) catch {};

    // Initialize Bitcask with a small max file size to trigger rotation
    var db = try Bitcask.init(allocator, test_dir, .{
        .max_file_size = 100, // Small size to trigger rotation
    });
    defer db.deinit();

    // Add data to create multiple files
    var file_ids = std.ArrayList(u32).init(allocator);
    defer file_ids.deinit();

    // Add 20 entries to ensure multiple files are created
    const num_entries = 20;
    for (0..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        defer allocator.free(value);

        // Store the current active file ID before putting the value
        try file_ids.append(db.active_file_id);

        try db.put(key, value, .{
            .max_file_size = 100, // Small size to trigger rotation
        });
    }

    // Verify each entry has the correct file ID
    for (0..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const entry_opt = db.keydir.get(key);
        try testing.expect(entry_opt != null);

        // Verify we can get the value
        const value = try db.get(key);
        defer if (value) |v| allocator.free(v);

        const expected_value = try std.fmt.allocPrint(allocator, "value{d}", .{i});
        defer allocator.free(expected_value);

        try testing.expectEqualStrings(expected_value, value.?);
    }
}
