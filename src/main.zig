const std = @import("std");
const Config = @import("config.zig").Config;

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

const HandleResult = struct {
    status: GeminiStatus,
    meta: []const u8,
    body: ?[]const u8 = null,

    const NO_NON_GEMINI: HandleResult = .{ .status = .ProxyRequestRefused, .meta = "no non-gemini requests" };
    const NO_MATCHING_VHOST: HandleResult = .{ .status = .ProxyRequestRefused, .meta = "no matching vhost" };
    const BAD_REQUEST: HandleResult = .{ .status = .BadRequest, .meta = "bad request" };
};

fn handle(config: *const Config, url: []const u8) HandleResult {
    if (!std.mem.startsWith(u8, url, "gemini://")) {
        return HandleResult.NO_NON_GEMINI;
    }

    const without_scheme = url["gemini://".len..];
    const indeks = std.mem.indexOf(u8, without_scheme, "/") orelse return HandleResult.BAD_REQUEST;
    const host = without_scheme[0..indeks];

    var it = config.vhosts.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key, host)) {
            return .{
                .status = .Success,
                .meta = "text/gemini",
                .body = "# tere, maailma!!\r\n",
            };
        }
    }

    return .{ .status = .ProxyRequestRefused, .meta = "no matching vhost" };
}

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
    try serv.listen(try std.net.Address.parseIp4("127.0.0.1", 4003));

    var work_buf: [1500]u8 = undefined;

    while (true) {
        var conn = try serv.accept();
        defer conn.stream.close();

        var in = conn.stream.reader();
        var out = conn.stream.writer();

        // <URL> is a UTF-8 encoded absolute URL, including a scheme, of
        // maximum length 1024 bytes.
        const url = readCrLf(in, &work_buf) orelse continue;

        const result = handle(&config, url);
        std.debug.print("{s} -> {s} {s}\n", .{ url, @tagName(result.status), result.meta });

        // <STATUS><SPACE><META><CR><LF>
        //
        // <STATUS> is a two-digit numeric status code, as described below in
        // 3.2 and in Appendix 1.
        //
        // <SPACE> is a single space character, i.e. the byte 0x20.
        //
        // <META> is a UTF-8 encoded string of maximum length 1024 bytes, whose
        // meaning is <STATUS> dependent.
        //
        // <STATUS> and <META> are separated by a single space character.
        //
        // If <STATUS> does not belong to the "SUCCESS" range of codes, then
        // the server MUST close the connection after sending the header and
        // MUST NOT send a response body.

        out.print("{} {s}\r\n", .{ @enumToInt(result.status), result.meta }) catch continue;

        if (result.body) |body| {
            out.writeAll(body) catch continue;
        }
    }
}
