const std = @import("std");
const Config = @import("config.zig").Config;
const resolvePath = @import("resolvePath.zig").resolvePath;
const mimes = @import("mimes.zig");

const MAX_FILE_SIZE = 10 * 1024 * 1024;

const GeminiStatus = enum(u8) {
    Input = 10,
    SensitiveInput = 11,
    Success = 20,
    RedirectTemporary = 30,
    RedirectPermanent = 31,
    TemporaryFailure = 40,
    ServerUnavailable = 41,
    CgiError = 42,
    ProxyError = 43,
    SlowDown = 44,
    PermanentFailure = 50,
    NotFound = 51,
    Gone = 52,
    ProxyRequestRefused = 53,
    BadRequest = 59,
    ClientCertificateRequired = 60,
    CertificateNotAuthorised = 61,
    CertificateNotValid = 62,
};

fn readCrLf(in: anytype, buf: []u8) ?[]u8 {
    const line = (in.readUntilDelimiterOrEof(buf, '\n') catch |_| null) orelse
        return null;
    if (line.len == 0 or line[line.len - 1] != '\r')
        return null;
    return line[0 .. line.len - 1];
}

const Handler = struct {
    arena: std.heap.ArenaAllocator,
    config: *const Config,

    pub fn init(config: *const Config) Handler {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *Handler) void {
        self.arena.deinit();
    }

    pub fn handle(self: *Handler, url: []const u8) !Result {
        const cwd = std.fs.cwd();

        if (!std.mem.startsWith(u8, url, "gemini://"))
            return Result.NO_NON_GEMINI;

        const without_scheme = url["gemini://".len..];
        const indeks = std.mem.indexOf(u8, without_scheme, "/");
        const host = if (indeks) |ix| without_scheme[0..ix] else without_scheme;
        const dangerous_uri = if (indeks) |ix| without_scheme[ix + 1 ..] else "";

        var path_buffer: [1024]u8 = undefined;
        const path = (try resolvePath(&path_buffer, dangerous_uri))[1..];

        var it = self.config.vhosts.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key, host)) {
                var root = try cwd.openDir(entry.value.root, .{ .iterate = true });
                defer root.close();

                if (path.len == 0) return self.handleDir(root, true, &entry.value);
                if (root.openDir(path, .{ .iterate = true })) |*subdir| {
                    defer subdir.close();
                    return self.handleDir(subdir.*, false, &entry.value);
                } else |err| {}

                if (try self.maybeReadFile(root, path)) |r| return r;

                return Result.NOT_FOUND;
            }
        }

        return Result.NO_MATCHING_VHOST;
    }

    fn handleDir(self: *Handler, dir: std.fs.Dir, at_root: bool, vhost: *const Config.VHost) !Result {
        if (try self.maybeReadFile(dir, vhost.index)) |r| return r;

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

        var buf = try std.ArrayList(u8).initCapacity(&self.arena.allocator, 4096);
        if (!at_root) try buf.appendSlice("=> .. ../\r\n");

        for (dirs) |name| {
            try buf.appendSlice("=> ");
            try buf.appendSlice(name);
            try buf.appendSlice("/\r\n");
        }

        for (files) |name| {
            try buf.appendSlice("=> ");
            try buf.appendSlice(name);
            try buf.appendSlice("\r\n");
        }

        return Result{
            .status = .Success,
            .meta = "text/gemini",
            .body = buf.toOwnedSlice(),
        };
    }

    fn sortFn(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.lessThan(u8, lhs, rhs);
    }

    fn maybeReadFile(self: *Handler, dir: std.fs.Dir, path: []const u8) !?Result {
        if (dir.readFileAlloc(&self.arena.allocator, path, MAX_FILE_SIZE)) |s| {
            const basename = std.fs.path.basename(path);
            const mime_type = if (std.mem.lastIndexOfScalar(u8, basename, '.')) |ix|
                mimes.lookup(basename[ix + 1 ..])
            else
                null;

            return Result{
                .status = .Success,
                .meta = mime_type orelse "text/plain",
                .body = s,
            };
        } else |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        }
    }

    const Result = struct {
        status: GeminiStatus,
        meta: []const u8,
        body: ?[]const u8 = null,

        const TEMPORARY_FAILURE: Result = .{ .status = .TemporaryFailure, .meta = "internal error" };
        const NO_NON_GEMINI: Result = .{ .status = .ProxyRequestRefused, .meta = "no non-gemini requests" };
        const NO_MATCHING_VHOST: Result = .{ .status = .ProxyRequestRefused, .meta = "no matching vhost" };
        const BAD_REQUEST: Result = .{ .status = .BadRequest, .meta = "bad request" };
        const NOT_FOUND: Result = .{ .status = .NotFound, .meta = "not found" };
    };
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

    var serv = std.net.StreamServer.init(.{
        .reuse_address = true,
    });
    defer serv.deinit();
    try serv.listen(try std.net.Address.parseIp(config.bind, config.port));

    var work_buf: [1500]u8 = undefined;

    try std.io.getStdOut().writer().print("kaksikud listening on {s}:{}\n", .{ config.bind, config.port });

    while (true) {
        var conn = try serv.accept();
        defer conn.stream.close();

        var in = conn.stream.reader();
        var out = conn.stream.writer();

        const url = readCrLf(in, &work_buf) orelse continue;

        var handler = Handler.init(&config);
        defer handler.deinit();

        const result = handler.handle(url) catch |err| Handler.Result.TEMPORARY_FAILURE;
        std.debug.print("{s} -> {s} {s}\n", .{ url, @tagName(result.status), result.meta });
        out.print("{} {s}\r\n", .{ @enumToInt(result.status), result.meta }) catch continue;

        if (result.body) |body| {
            out.writeAll(body) catch continue;
        }
    }
}
