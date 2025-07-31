const std = @import("std");
const net = std.net;
const Bitcask = @import("../src/main.zig").Bitcask;

const Command = enum {
    Get,
    Put,
    Delete,
    List,
    Unknown,
};

pub fn main() !void {
    // Initialize a general purpose allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Create a directory for our database
    const db_dir = "server_db";
    std.fs.cwd().makeDir(db_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    std.debug.print("Initializing Bitcask database in '{s}'...\n", .{db_dir});

    // Initialize Bitcask
    var db = try Bitcask.init(allocator, db_dir, .{
        .sync_on_put = true, // Ensure durability for server use case
    });
    defer db.deinit();

    // Create TCP server
    const address = try net.Address.parseIp("127.0.0.1", 8080);
    var server = try address.listen(.{
        .reuse_address = true,
    });
    defer server.deinit();

    std.debug.print("Server listening on 127.0.0.1:8080\n", .{});
    std.debug.print("Commands: GET <key>, PUT <key> <value>, DELETE <key>, LIST\n", .{});
    std.debug.print("Press Ctrl+C to exit\n\n", .{});

    // Accept connections
    while (true) {
        var conn = server.accept() catch |err| {
            std.debug.print("Error accepting connection: {}\n", .{err});
            continue;
        };
        defer conn.stream.close();

        std.debug.print("Client connected\n", .{});

        // Handle client
        try handleClient(allocator, &db, conn.stream);
    }
}

fn handleClient(allocator: std.mem.Allocator, db: *Bitcask, stream: net.Stream) !void {
    var buf: [1024]u8 = undefined;

    while (true) {
        // Read client request
        const bytes_read = try stream.read(&buf);
        if (bytes_read == 0) break; // Client disconnected

        const request = buf[0..bytes_read];
        std.debug.print("Received: {s}\n", .{request});

        // Parse command
        const response = try processRequest(allocator, db, request);
        defer allocator.free(response);

        // Send response
        _ = try stream.write(response);
    }
}

fn processRequest(allocator: std.mem.Allocator, db: *Bitcask, request: []const u8) ![]const u8 {
    var iter = std.mem.tokenizeScalar(u8, request, ' ');
    
    const cmd_str = iter.next() orelse return try allocator.dupe(u8, "ERROR: Empty command\n");
    
    const cmd = if (std.ascii.eqlIgnoreCase(cmd_str, "GET"))
        Command.Get
    else if (std.ascii.eqlIgnoreCase(cmd_str, "PUT"))
        Command.Put
    else if (std.ascii.eqlIgnoreCase(cmd_str, "DELETE"))
        Command.Delete
    else if (std.ascii.eqlIgnoreCase(cmd_str, "LIST"))
        Command.List
    else
        Command.Unknown;

    switch (cmd) {
        .Get => {
            const key = iter.next() orelse 
                return try allocator.dupe(u8, "ERROR: Missing key\n");
            
            const value = try db.get(key);
            if (value) |v| {
                defer allocator.free(v);
                return try std.fmt.allocPrint(allocator, "OK: {s}\n", .{v});
            } else {
                return try allocator.dupe(u8, "ERROR: Key not found\n");
            }
        },
        .Put => {
            const key = iter.next() orelse 
                return try allocator.dupe(u8, "ERROR: Missing key\n");
            
            // The rest of the request is the value
            const value_start = cmd_str.len + 1 + key.len + 1;
            if (value_start >= request.len) {
                return try allocator.dupe(u8, "ERROR: Missing value\n");
            }
            
            const value = request[value_start..];
            try db.put(key, value, .{});
            
            return try std.fmt.allocPrint(allocator, "OK: Stored {s}\n", .{key});
        },
        .Delete => {
            const key = iter.next() orelse 
                return try allocator.dupe(u8, "ERROR: Missing key\n");
            
            const result = try db.delete(key);
            if (result) {
                return try allocator.dupe(u8, "OK: Deleted\n");
            } else {
                return try allocator.dupe(u8, "ERROR: Key not found\n");
            }
        },
        .List => {
            const keys = try db.listKeys();
            defer {
                for (keys) |key| {
                    allocator.free(key);
                }
                allocator.free(keys);
            }
            
            var response = std.ArrayList(u8).init(allocator);
            defer response.deinit();
            
            try response.appendSlice("OK: Keys found: ");
            try response.appendSlice(try std.fmt.allocPrint(allocator, "{d}\n", .{keys.len}));
            
            for (keys) |key| {
                try response.appendSlice("- ");
                try response.appendSlice(key);
                try response.appendSlice("\n");
            }
            
            return response.toOwnedSlice();
        },
        .Unknown => {
            return try std.fmt.allocPrint(allocator, 
                "ERROR: Unknown command. Use GET, PUT, DELETE, or LIST\n", .{});
        },
    }
}