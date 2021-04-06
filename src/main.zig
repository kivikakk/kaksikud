const std = @import("std");
const Server = @import("server.zig").Server;
const Config = @import("config.zig").Config;
const mimes = @import("mimes.zig");

pub const io_mode = .evented;

const Handler = struct {
    const MAX_FILE_SIZE = 10 * 1024 * 1024;

    config: *const Config,
    context: *Server.Context,

    pub fn handle(config: *const Config, context: *Server.Context) !void {
        var handler = Handler{
            .config = config,
            .context = context,
        };
        try handler.handleEntry();
    }

    fn handleEntry(self: *Handler) !void {
        const cwd = std.fs.cwd();

        if (!std.ascii.eqlIgnoreCase(self.context.request.url.scheme, "gemini"))
            return self.context.status(Server.ResponseStatus.NO_NON_GEMINI);

        var it = self.config.vhosts.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key, self.context.request.url.host)) {
                var root = try cwd.openDir(entry.value.root, .{ .iterate = true });
                defer root.close();

                if (self.context.request.url.path.len == 0) return self.handleDir(root, true, &entry.value);
                if (root.openDir(self.context.request.url.path, .{ .iterate = true })) |*subdir| {
                    defer subdir.close();
                    return self.handleDir(subdir.*, false, &entry.value);
                } else |err| {}

                if (try self.maybeReadFile(root, self.context.request.url.path)) return;

                return self.context.status(Server.ResponseStatus.NOT_FOUND);
            }
        }

        return self.context.status(Server.ResponseStatus.NO_MATCHING_VHOST);
    }

    fn handleDir(self: *Handler, dir: std.fs.Dir, at_root: bool, vhost: *const Config.VHost) !void {
        if (try self.maybeReadFile(dir, vhost.index)) return;

        var dirs_al = std.ArrayList([]u8).init(&self.context.arena.allocator);
        var files_al = std.ArrayList([]u8).init(&self.context.arena.allocator);

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            try (switch (entry.kind) {
                .Directory => dirs_al,
                else => files_al,
            }).append(try self.context.arena.allocator.dupe(u8, entry.name));
        }

        var dirs = dirs_al.toOwnedSlice();
        std.sort.sort([]u8, dirs, {}, sortFn);
        var files = files_al.toOwnedSlice();
        std.sort.sort([]u8, files, {}, sortFn);

        self.context.status(.{ .code = .Success, .meta = "text/gemini" });
        var writer = self.context.writer();

        if (!at_root) try writer.writeAll("=> .. ../\r\n");

        for (dirs) |name| {
            try writer.writeAll("=> ");
            try writer.writeAll(name);
            try writer.writeAll("/\r\n");
        }

        for (files) |name| {
            try writer.writeAll("=> ");
            try writer.writeAll(name);
            try writer.writeAll("\r\n");
        }
    }

    fn sortFn(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.lessThan(u8, lhs, rhs);
    }

    fn maybeReadFile(self: *Handler, dir: std.fs.Dir, path: []const u8) !bool {
        if (dir.readFileAlloc(&self.context.arena.allocator, path, MAX_FILE_SIZE)) |s| {
            const basename = std.fs.path.basename(path);
            const mime_type = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |ix|
                mimes.lookup(basename[ix + 1 ..])
            else
                null;
            self.context.status(.{ .code = .Success, .meta = mime_type orelse "text/plain" });
            try self.context.writer().writeAll(s);
            return true;
        } else |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    }
};

usingnamespace if (std.io.is_async)
    struct {
        pub const AsyncClient = struct {
            frame: @Frame(handle),

            fn handle(self: *AsyncClient, config: *Config, connection: std.net.StreamServer.Connection) void {
                handleConnection(config, connection);
                finished_clients.append(self) catch |err| {
                    std.debug.print("handle: error appending to finished_clients: {}\n", .{err});
                };
            }
        };

        pub var clients: std.AutoHashMap(*AsyncClient, void) = undefined;
        pub var finished_clients: std.ArrayList(*AsyncClient) = undefined;

        pub fn cleanupFinished(allocator: *std.mem.Allocator) void {
            for (finished_clients.items) |fin| {
                _ = clients.remove(fin);
                allocator.destroy(fin);
            }
            finished_clients.items.len = 0;
        }
    };

fn handleConnection(config: *Config, connection: std.net.StreamServer.Connection) void {
    var context = Server.readRequest(connection) catch |err| {
        std.debug.print("readRequest failed: {}\n", .{err});
        connection.stream.close();
        return;
    };
    defer context.deinit();

    Handler.handle(config, &context) catch |err| {
        std.debug.print("{s} -> {}\n", .{ context.request.original_url, err });
        return;
    };

    std.debug.print("{s} -> {s} {s}\n", .{ context.request.original_url, @tagName(context.response_status.code), context.response_status.meta });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = &gpa.allocator;

    try mimes.init(allocator);
    defer mimes.deinit(allocator);

    var config = blk: {
        var raw_config = try std.fs.cwd().readFileAlloc(allocator, "config.zzz", 1024 * 100);
        errdefer gpa.allocator.free(raw_config);
        break :blk try Config.init(allocator, raw_config);
    };
    defer config.deinit();

    var server = try Server.init(config.bind, config.port);
    defer server.deinit();

    try std.io.getStdOut().writer().print("kaksikud listening on {s}:{}\n", .{ config.bind, config.port });

    if (std.io.is_async) {
        clients = std.AutoHashMap(*AsyncClient, void).init(allocator);
        finished_clients = std.ArrayList(*AsyncClient).init(allocator);
    }
    defer if (std.io.is_async) {
        finished_clients.deinit();
        clients.deinit();
    };

    while (true) {
        var connection = server.getConnection() catch |err| {
            std.debug.print("getConnection failed: {}\n", .{err});
            continue;
        };

        if (std.io.is_async) {
            cleanupFinished(allocator);
            var client = try allocator.create(AsyncClient);
            client.* = .{
                .frame = async client.handle(&config, connection),
            };
            try clients.putNoClobber(client, {});
        } else {
            handleConnection(&config, connection);
        }
    }

    var it = clients.iterator();
    while (it.next()) |client| {
        await client.key.frame;
    }
    cleanupFinished(allocator);
}
