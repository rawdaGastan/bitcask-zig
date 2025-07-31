const std = @import("std");
const Bitcask = @import("../src/main.zig").Bitcask;

pub fn main() !void {
    // Initialize a general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create a directory for our database
    const db_dir = "rotation_example_db";
    defer std.fs.cwd().deleteTree(db_dir) catch {}; // Clean up after ourselves

    std.debug.print("Initializing Bitcask database with small file size limit...\n", .{});

    // Initialize Bitcask with a small max file size to trigger rotation
    var db = try Bitcask.init(allocator, db_dir, .{
        .max_file_size = 1024, // 1KB - small size to trigger rotation
    });
    defer db.deinit();

    // Insert enough data to trigger file rotation
    const num_entries = 50;
    std.debug.print("Inserting {d} entries to trigger file rotation...\n", .{num_entries});

    for (0..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try std.fmt.allocPrint(allocator, "This is value {d} with some extra data to make it larger", .{i});
        defer allocator.free(value);

        try db.put(key, value, .{
            .max_file_size = 1024, // 1KB
        });
    }

    // Count data files
    var dir = try std.fs.cwd().openDir(db_dir, .{ .iterate = true });
    defer dir.close();

    var data_file_count: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "data.")) {
            data_file_count += 1;
        }
    }

    std.debug.print("After insertions, we have {d} data files\n", .{data_file_count});

    // Update some values to create stale entries
    std.debug.print("\nUpdating first 20 entries to create stale data...\n", .{});
    for (0..20) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try std.fmt.allocPrint(allocator, "UPDATED value {d}", .{i});
        defer allocator.free(value);

        try db.put(key, value, .{
            .max_file_size = 1024,
        });
    }

    // Delete some entries
    std.debug.print("Deleting entries 20-29...\n", .{});
    for (20..30) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        _ = try db.delete(key);
    }

    // Perform merge/compaction
    std.debug.print("\nPerforming merge/compaction...\n", .{});
    try db.merge();

    // Count data files after merge
    dir = try std.fs.cwd().openDir(db_dir, .{ .iterate = true });
    defer dir.close();

    data_file_count = 0;
    it = dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, "data.")) {
            data_file_count += 1;
        }
    }

    std.debug.print("After merge, we have {d} data file(s)\n", .{data_file_count});

    // Verify data integrity after merge
    var success_count: usize = 0;
    var missing_count: usize = 0;

    // Check updated entries (0-19)
    for (0..20) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const expected = try std.fmt.allocPrint(allocator, "UPDATED value {d}", .{i});
        defer allocator.free(expected);

        const value = try db.get(key);
        if (value) |v| {
            if (std.mem.eql(u8, v, expected)) {
                success_count += 1;
            }
            allocator.free(v);
        } else {
            missing_count += 1;
        }
    }

    // Check deleted entries (20-29)
    for (20..30) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const value = try db.get(key);
        if (value) |v| {
            // Should be deleted
            allocator.free(v);
        } else {
            success_count += 1;
        }
    }

    // Check untouched entries (30-49)
    for (30..num_entries) |i| {
        const key = try std.fmt.allocPrint(allocator, "key{d}", .{i});
        defer allocator.free(key);

        const expected = try std.fmt.allocPrint(allocator, "This is value {d} with some extra data to make it larger", .{i});
        defer allocator.free(expected);

        const value = try db.get(key);
        if (value) |v| {
            if (std.mem.eql(u8, v, expected)) {
                success_count += 1;
            }
            allocator.free(v);
        } else {
            missing_count += 1;
        }
    }

    std.debug.print("\nData verification after merge:\n", .{});
    std.debug.print("- Successful verifications: {d}\n", .{success_count});
    std.debug.print("- Missing entries: {d}\n", .{missing_count});
    std.debug.print("- Expected successful verifications: {d}\n", .{num_entries - 0});

    if (success_count == num_entries - 0) {
        std.debug.print("\nMerge operation successful! All data verified.\n", .{});
    } else {
        std.debug.print("\nSome data verification failed.\n", .{});
    }
}