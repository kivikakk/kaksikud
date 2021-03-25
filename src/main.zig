const std = @import("std");
const Config = @import("config.zig").Config;

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
        const uri = if (indeks) |ix| without_scheme[ix + 1 ..] else "";

        if (std.mem.eql(u8, uri, "..") or
            std.mem.startsWith(u8, uri, "../") or
            std.mem.endsWith(u8, uri, "/..") or
            std.mem.indexOf(u8, uri, "/../") != null)
            return Result.BAD_REQUEST;

        var it = self.config.vhosts.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key, host)) {
                var root = try cwd.openDir(entry.value.root, .{});
                defer root.close();

                if (uri.len == 0) return self.handleDir(root, &entry.value);
                if (root.openDir(uri, .{})) |*subdir| {
                    defer subdir.close();
                    return self.handleDir(subdir.*, &entry.value);
                } else |err| {}

                if (try self.maybeReadFile(root, uri)) |r| return r;

                return Result{
                    .status = .NotFound,
                    .meta = "not found",
                };
            }
        }

        return Result.NO_MATCHING_VHOST;
    }

    fn handleDir(self: *Handler, dir: std.fs.Dir, vhost: *const Config.VHost) !Result {
        if (try self.maybeReadFile(dir, vhost.index)) |r| return r;

        return Result{
            .status = .Success,
            .meta = "text/gemini", // XXX
            .body = "todo: dir listing",
        };
    }

    fn maybeReadFile(self: *Handler, dir: std.fs.Dir, path: []const u8) !?Result {
        if (dir.readFileAlloc(&self.arena.allocator, path, MAX_FILE_SIZE)) |s| {
            return Result{
                .status = .Success,
                .meta = "text/gemini", // XXX
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
