const std = @import("std");

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

const valid_url_prefix = "gemini://localhost/";

const HandleResult = struct {
    status: GeminiStatus,
    meta: []const u8,
    body: ?[]const u8 = null,
};

fn handle(url: []const u8) HandleResult {
    if (!std.mem.startsWith(u8, url, valid_url_prefix)) {
        return .{
            .status = .ProxyRequestRefused,
            .meta = "only serves " ++ valid_url_prefix,
        };
    }

    return .{
        .status = .Success,
        .meta = "text/gemini",
        .body = "# tere, maailma!\r\n",
    };
}

pub fn main() !void {
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
        std.debug.print("url: '{s}'\n", .{url});

        const result = handle(url);

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
