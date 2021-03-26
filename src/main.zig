const std = @import("std");
const Server = @import("server.zig").Server;
const Config = @import("config.zig").Config;
const mimes = @import("mimes.zig");

const MAX_FILE_SIZE = 10 * 1024 * 1024;

const Handler = struct {
    arena: *std.heap.ArenaAllocator,
    config: *const Config,

    pub fn init(arena: *std.heap.ArenaAllocator, config: *const Config) Handler {
        return .{
            .arena = arena,
            .config = config,
        };
    }

    pub fn handle(self: *Handler, context: *Server.Context) !void {
        const cwd = std.fs.cwd();

        if (!std.ascii.eqlIgnoreCase(context.request.url.scheme, "gemini"))
            return context.status(Server.ResponseStatus.NO_NON_GEMINI);

        var it = self.config.vhosts.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key, context.request.url.host)) {
                var root = try cwd.openDir(entry.value.root, .{ .iterate = true });
                defer root.close();

                if (context.request.url.path.len == 0) return self.handleDir(root, true, &entry.value, context);
                if (root.openDir(context.request.url.path, .{ .iterate = true })) |*subdir| {
                    defer subdir.close();
                    return self.handleDir(subdir.*, false, &entry.value, context);
                } else |err| {}

                if (try self.maybeReadFile(root, context.request.url.path, context)) return;

                return context.status(Server.ResponseStatus.NOT_FOUND);
            }
        }

        return context.status(Server.ResponseStatus.NO_MATCHING_VHOST);
    }

    fn handleDir(self: *Handler, dir: std.fs.Dir, at_root: bool, vhost: *const Config.VHost, context: *Server.Context) !void {
        if (try self.maybeReadFile(dir, vhost.index, context)) return;

        var dirs_al = std.ArrayList([]u8).init(&self.arena.allocator);
        var files_al = std.ArrayList([]u8).init(&self.arena.allocator);

        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            try (switch (entry.kind) {
                .Directory => dirs_al,
                else => files_al,
            }).append(try self.arena.allocator.dupe(u8, entry.name));
        }

        var dirs = dirs_al.toOwnedSlice();
        std.sort.sort([]u8, dirs, {}, sortFn);
        var files = files_al.toOwnedSlice();
        std.sort.sort([]u8, files, {}, sortFn);

        context.status(.{ .code = .Success, .meta = "text/gemini" });
        var writer = context.writer();

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

    fn maybeReadFile(self: *Handler, dir: std.fs.Dir, path: []const u8, context: *Server.Context) !bool {
        if (dir.readFileAlloc(&self.arena.allocator, path, MAX_FILE_SIZE)) |s| {
            const basename = std.fs.path.basename(path);
            const mime_type = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |ix|
                mimes.lookup(basename[ix + 1 ..])
            else
                null;
            context.status(.{ .code = .Success, .meta = mime_type orelse "text/plain" });
            try context.writer().writeAll(s);
            return true;
        } else |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var config = blk: {
        var raw_config = try std.fs.cwd().readFileAlloc(&gpa.allocator, "config.zzz", 1024 * 100);
        errdefer gpa.allocator.free(raw_config);
        break :blk try Config.init(&gpa.allocator, raw_config);
    };
    defer config.deinit();

    var server = try Server.init(config.bind, config.port);
    defer server.deinit();

    var work_buf: [1500]u8 = undefined;

    try std.io.getStdOut().writer().print("kaksikud listening on {s}:{}\n", .{ config.bind, config.port });

    while (true) {
        var context = try server.getContext();
        defer context.deinit();

        var handler = Handler.init(&context.arena, &config);
        try handler.handle(&context);
        std.debug.print("{s} -> {s} {s}\n", .{ context.request.original_url, @tagName(context.response_status.code), context.response_status.meta });
    }
}
