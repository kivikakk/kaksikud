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
            config: *Config,
            connection: std.net.StreamServer.Connection,

            handle_frame: @Frame(handle) = undefined,
            timeout_frame: @Frame(timeout) = undefined,

            status: enum { started, finished, hit_timeout, finish_pushed } = .started,

            pub fn create(allocator: *std.mem.Allocator, config: *Config, connection: std.net.StreamServer.Connection) !*AsyncClient {
                var self = try allocator.create(AsyncClient);
                self.* = .{ .config = config, .connection = connection };
                self.handle_frame = async self.handle();
                self.timeout_frame = async self.timeout();
                return self;
            }

            fn handle(self: *AsyncClient) void {
                handleConnection(self.config, self.connection);
                // State transitions for post-handle:
                // * started -> finished           (We completed work here; signal timeout frame to exit)
                // * finished -X                   (Only we should set this here)
                // * hit_timeout -> finish_pushed  (Timeout was hit and connection force-closed for us; exit)
                // * finish_pushed -X              (We should never observe this; implies our frame was dealloced)
                switch (self.status) {
                    .started => self.status = .finished,
                    .hit_timeout => return self.finished(),
                    else => unreachable,
                }
            }

            fn timeout(self: *AsyncClient) void {
                var seconds_remaining: usize = self.config.client_timeout_seconds;
                while (seconds_remaining > 0) : (seconds_remaining -= 1) {
                    std.event.Loop.instance.?.sleep(1 * std.time.ns_per_s);
                    // State transitions for mid-timeout loop:
                    // * started -> started         (Still working ...)
                    // * finished -> finish_pushed  (Normal completion, exit)
                    // * hit_timeout -X             (Only we should set this later)
                    // * finish_pushed -X           (We should never observe this; implies our frame was dealloced)
                    switch (self.status) {
                        .started => {},
                        .finished => return self.finished(),
                        else => unreachable,
                    }
                }

                // State transitions for post-timeout:
                // * started -> hit_timeout    (Signal handle frame that we've exited here; kill connection)
                // * finished -X               (This should've been handled above, as execution proceeds straight down)
                // * hit_timeout -X            (Only we should set this here)
                // * finish_pushed -X          (We should never observe this; implies our frame was dealloced)
                switch (self.status) {
                    .started => {
                        std.debug.print("timeout handling request\n", .{});
                        self.status = .hit_timeout;
                        std.os.shutdown(self.connection.stream.handle, .both) catch {};
                    },
                    else => unreachable,
                }
            }

            fn finished(self: *AsyncClient) void {
                self.status = .finish_pushed;
                finished_clients.append(self) catch |err| {
                    std.debug.print("{*}: finished(): error appending to finished_clients: {}\n", .{ self, err });
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
    }
else
    struct {};

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
        var it = clients.iterator();
        while (it.next()) |entry| {
            await entry.key.handle_frame;
            await entry.key.timeout_frame;
        }
        cleanupFinished(allocator);

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
            if (clients.count() >= config.max_concurrent_clients) {
                connection.stream.close();
                continue;
            }
            var client = try AsyncClient.create(allocator, &config, connection);
            try clients.putNoClobber(client, {});
        } else {
            handleConnection(&config, connection);
        }
    }
}
