const std = @import("std");
const fs = std.fs;
const os = std.os;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const Mutex = std.Thread.Mutex;
const ArrayList = std.ArrayList;
const time = std.time;

/// Entry represents a key-value pair stored in the store
const Entry = struct {
    key: []const u8,
    value: []const u8,
    timestamp: i64,
    value_pos: u64, // the position (offset) of the value in the data file on disk
    value_size: u32,
    file_id: u32,
};

/// KeyDir is an in-memory index mapping keys to their file positions
const KeyDir = struct {
    map: StringHashMap(Entry),
    allocator: Allocator,
    mutex: Mutex,

    pub fn init(allocator: Allocator) KeyDir {
        return KeyDir{
            .map = StringHashMap(Entry).init(allocator),
            .allocator = allocator,
            .mutex = Mutex{},
        };
    }

    pub fn deinit(self: *KeyDir) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.value);
        }
        self.map.deinit();
    }

    pub fn put(self: *KeyDir, key: []const u8, value: []const u8, timestamp: i64, value_pos: u64, value_size: u32, file_id: u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
    
        // Create copies of key and value
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
    
        // If key exists, free both the old key and value
        if (self.map.get(key)) |old_entry| {
            const old_key = old_entry.key;
            const old_value = old_entry.value;
            
            // Remove from map first
            _ = self.map.remove(key);
            
            // Then free the memory
            self.allocator.free(old_key);
            self.allocator.free(old_value);
        }
    
        try self.map.put(key_copy, Entry{
            .key = key_copy,
            .value = value_copy,
            .timestamp = timestamp,
            .value_pos = value_pos,
            .value_size = value_size,
            .file_id = file_id,
        });
    }

    pub fn get(self: *KeyDir, key: []const u8) ?Entry {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.map.get(key);
    }

    pub fn delete(self: *KeyDir, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.map.get(key)) |entry| {
            // Get a copy of the key and value before removing from map
            const key_to_free = entry.key;
            const value_to_free = entry.value;

            // Remove from map first
            const result = self.map.remove(key);

            // Then free from the memory
            self.allocator.free(key_to_free);
            self.allocator.free(value_to_free);

            return result;
        }

        return false;
    }
};

/// Bitcask is the database store structure
pub const Bitcask = struct {
    dir_path: []const u8, // Where DB files are stored
    active_file: fs.File,
    active_file_id: u32,
    keydir: KeyDir,
    allocator: Allocator,
    active_file_size: u64,
    file_sizes: std.AutoHashMap(u32, u64), // Maps file IDs to their sizes

    const EntryHeader = struct {
        crc: u32,
        timestamp: i64,
        key_size: u32,
        value_size: u32,
    };

    pub const Config = struct {
        max_file_size: u64 = 1024 * 1024 * 10, // 10MB default
        sync_on_put: bool = false,
    };

    pub fn init(allocator: Allocator, dir_path: []const u8, config: Config) !Bitcask {
        _ = config; // Unused parameter, but kept for future use

        // Ensure directory exists
        try fs.cwd().makePath(dir_path);

        // Find the highest file ID or start with 1
        var dir = try fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();

        var data_files = ArrayList([]const u8).init(allocator);
        defer {
            for (data_files.items) |item| {
                allocator.free(item);
            }
            data_files.deinit();
        }

        var max_file_id: u32 = 0;
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;

            // Parse file ID from filename (format: data.{id})
            if (std.mem.startsWith(u8, entry.name, "data.")) {
                const id_str = entry.name[5..];
                const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
                if (id > max_file_id) max_file_id = id;

                // Append file to data files
                const file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                try data_files.append(file_path);
            }
        }

        const active_file_id = max_file_id + 1;
        const file_path = try std.fmt.allocPrint(allocator, "{s}/data.{d}", .{ dir_path, active_file_id });
        defer allocator.free(file_path);

        // Create and Open active file for writing
        const active_file = try fs.cwd().createFile(file_path, .{});

        const dir_path_copy = try allocator.dupe(u8, dir_path);

        var db = Bitcask{
            .dir_path = dir_path_copy,
            .active_file = active_file,
            .active_file_id = active_file_id,
            .keydir = KeyDir.init(allocator),
            .allocator = allocator,
            .active_file_size = 0,
            .file_sizes = std.AutoHashMap(u32, u64).init(allocator),
        };

        try db.loadExistingFiles(data_files);

        return db;
    }

    pub fn deinit(self: *Bitcask) void {
        self.active_file.close();
        self.keydir.deinit();
        self.file_sizes.deinit();
        self.allocator.free(self.dir_path);
    }

    fn loadExistingFiles(self: *Bitcask, data_files: ArrayList([]const u8)) !void {
        // Sort files by ID to process them in order
        std.mem.sort([]const u8, data_files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                const a_id = std.fmt.parseInt(u32, std.mem.sliceTo(a[4..], '.'), 10) catch return false;
                const b_id = std.fmt.parseInt(u32, std.mem.sliceTo(b[4..], '.'), 10) catch return false;
                return a_id < b_id;
            }
        }.lessThan);

        // Process each file
        for (data_files.items) |file_path| {
            var file = try fs.cwd().openFile(file_path, .{});
            defer file.close();

            try self.loadEntriesFromFile(file, file_path);
        }
    }

    fn loadEntriesFromFile(self: *Bitcask, file: fs.File, file_path: []const u8) !void {
        // Extract file ID from path
        const file_name = std.fs.path.basename(file_path);
        const id_str = file_name[5..]; // Skip "data."
        const file_id = try std.fmt.parseInt(u32, id_str, 10);

        // Increase buffer size to match EntryHeader size
        var buf: [24]u8 = undefined;
        // Keep track of the position of the file
        var pos: u64 = 0;

        while (true) {
            // Read header
            const header_size = @sizeOf(EntryHeader);
            const header_bytes = try file.read(buf[0..header_size]);
            if (header_bytes < header_size) break; // EOF

            // Cast header into entry header
            const header = @as(*align(1) EntryHeader, @ptrCast(&buf[0])).*;
            pos += header_size;

            // Read key
            const key_buf = try self.allocator.alloc(u8, header.key_size);
            defer self.allocator.free(key_buf);

            const key_bytes = try file.read(key_buf);
            if (key_bytes < header.key_size) return error.InvalidFile;
            pos += header.key_size;

            // Read value
            const value_buf = try self.allocator.alloc(u8, header.value_size);
            const value_bytes = try file.read(value_buf);
            if (value_bytes < header.value_size) {
                self.allocator.free(value_buf);
                return error.InvalidFile;
            }
            pos += header.value_size;

            try self.keydir.put(key_buf, value_buf, header.timestamp, pos - header.value_size, header.value_size, file_id);
        }

        // Store the file size
        try self.file_sizes.put(file_id, pos);
    }

    pub fn put(self: *Bitcask, key: []const u8, value: []const u8, config: Config) !void {
        const timestamp = time.milliTimestamp();

        const header = EntryHeader{
            .crc = 0, // TODO: Implement CRC
            .timestamp = timestamp,
            .key_size = @intCast(key.len),
            .value_size = @intCast(value.len),
        };

        // Write to active file
        const header_size = @sizeOf(EntryHeader);
        const entry_size = header_size + key.len + value.len;

        // Check if we need to rotate the file (if we have more size to fit)
        if (self.active_file_size + entry_size > config.max_file_size) {
            try self.rotateActiveFile();
        }

        // Write header
        _ = try self.active_file.write(std.mem.asBytes(&header));

        // Write key
        _ = try self.active_file.write(key);

        // Write value
        _ = try self.active_file.write(value);

        // Update file size
        self.active_file_size += entry_size;

        // Sync if configured
        if (config.sync_on_put) {
            try self.active_file.sync();
        }

        // Update keydir
        const value_pos = self.active_file_size - value.len;
        try self.keydir.put(key, value, timestamp, value_pos, @intCast(value.len), self.active_file_id);
    }

    fn rotateActiveFile(self: *Bitcask) !void {
        // Store the size of the current active file
        try self.file_sizes.put(self.active_file_id, self.active_file_size);

        // Close current active file
        try self.active_file.sync();
        self.active_file.close();

        // Create new active file
        self.active_file_id += 1;
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/data.{d}", .{ self.dir_path, self.active_file_id });
        defer self.allocator.free(file_path);

        self.active_file = try fs.cwd().createFile(file_path, .{});
        self.active_file_size = 0;
    }

    pub fn get(self: *Bitcask, key: []const u8) !?[]const u8 {
        // Check if key exists in keydir
        const entry_opt = self.keydir.get(key);
        if (entry_opt == null) return null;

        const entry = entry_opt.?;

        // Open the file containing the value
        const file_path = try std.fmt.allocPrint(self.allocator, "{s}/data.{d}", .{ self.dir_path, entry.file_id });
        defer self.allocator.free(file_path);

        var file = try fs.cwd().openFile(file_path, .{});
        defer file.close();

        // Seek to value position
        try file.seekTo(entry.value_pos);

        // Read value
        const value_buf = try self.allocator.alloc(u8, entry.value_size);
        const bytes_read = try file.read(value_buf);

        if (bytes_read < entry.value_size) {
            self.allocator.free(value_buf);
            return error.InvalidFile;
        }

        return value_buf;
    }

    pub fn getFileIdFromPosition(self: *Bitcask, position: u64) !u32 {
        // Iterate through all files to find which one contains the position
        var it = self.file_sizes.iterator();

        while (it.next()) |entry| {
            const file_id = entry.key_ptr.*;
            const file_size = entry.value_ptr.*;

            if (position < file_size) {
                return file_id;
            }
        }

        // If we couldn't find the file, return the active file ID as a fallback
        return self.active_file_id;
    }

    pub fn delete(self: *Bitcask, key: []const u8) !bool {
        // In Bitcask, deletion is implemented by writing a tombstone value
        // For simplicity, we'll just remove from keydir and write a special tombstone entry
        const timestamp = time.milliTimestamp();

        // Prepare header with zero value size to indicate tombstone
        const header = EntryHeader{
            .crc = 0,
            .timestamp = timestamp,
            .key_size = @intCast(key.len),
            .value_size = 0, // Tombstone
        };

        // Write to active file
        const header_size = @sizeOf(EntryHeader);
        const entry_size = header_size + key.len;

        // Write header
        const header_bytes = std.mem.asBytes(&header);
        _ = try self.active_file.write(header_bytes);

        // Write key
        _ = try self.active_file.write(key);

        // Update file size
        self.active_file_size += entry_size;

        // Remove from keydir
        return self.keydir.delete(key);
    }

    pub fn sync(self: *Bitcask) !void {
        try self.active_file.sync();
    }

    pub fn listKeys(self: *Bitcask) ![][]const u8 {
        var keys = ArrayList([]const u8).init(self.allocator);

        self.keydir.mutex.lock();
        defer self.keydir.mutex.unlock();

        var it = self.keydir.map.iterator();
        while (it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            try keys.append(key_copy);
        }

        return keys.toOwnedSlice();
    }

    // Merge function to compact the database by removing stale entries
    pub fn merge(self: *Bitcask) !void {
        // Create a new merge file
        const merge_path = try std.fmt.allocPrint(self.allocator, "{s}/merge.{d}", .{ self.dir_path, self.active_file_id });
        defer self.allocator.free(merge_path);

        var merge_file = try fs.cwd().createFile(merge_path, .{});

        var merge_size: u64 = 0;

        // Write all current entries to the merge file
        self.keydir.mutex.lock();
        defer self.keydir.mutex.unlock();

        var it = self.keydir.map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*.value;
            const timestamp = entry.value_ptr.*.timestamp;

            // Prepare header
            const header = EntryHeader{
                .crc = 0, // TODO: Implement CRC
                .timestamp = timestamp,
                .key_size = @intCast(key.len),
                .value_size = @intCast(value.len),
            };

            // Write header
            const header_bytes = std.mem.asBytes(&header);
            _ = try merge_file.write(header_bytes);

            // Write key
            _ = try merge_file.write(key);

            // Write value
            _ = try merge_file.write(value);

            merge_size += @sizeOf(EntryHeader) + key.len + value.len;
        }

        try merge_file.sync();
        merge_file.close();

        // Close current active file
        try self.active_file.sync();
        self.active_file.close();

        // Replace old files with merged file
        // TODO: what if one merge file is not enough?
        var dir = try fs.cwd().openDir(self.dir_path, .{ .iterate = true });
        defer dir.close();

        var file_it = dir.iterate();
        while (try file_it.next()) |entry| {
            if (entry.kind != .file) continue;

            if (std.mem.startsWith(u8, entry.name, "data.")) {
                const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.dir_path, entry.name });
                defer self.allocator.free(file_path);

                try fs.cwd().deleteFile(file_path);
            }
        }

        // Rename merge file to data.1
        const new_path = try std.fmt.allocPrint(self.allocator, "{s}/data.1", .{self.dir_path});
        defer self.allocator.free(new_path);

        try fs.cwd().rename(merge_path, new_path);

        // Open new active file
        self.active_file_id = 1;
        self.active_file = try fs.cwd().openFile(new_path, .{ .mode = .read_write });
        self.active_file_size = merge_size;

        // Clear file_sizes and add the new file
        self.file_sizes.clearRetainingCapacity();
        try self.file_sizes.put(1, merge_size);

        // Update all entries in keydir to use the new file ID
        it = self.keydir.map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.file_id = 1;
        }
    }
};
