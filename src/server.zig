const std = @import("std");
const resolvePath = @import("resolvePath.zig").resolvePath;

pub const Server = struct {
    server: std.net.StreamServer,

    pub fn init(ip: []const u8, port: u16) !Server {
        var server = std.net.StreamServer.init(.{
            .reuse_address = true,
        });
        errdefer server.deinit();
        try server.listen(try std.net.Address.parseIp(ip, port));

        return Server{
            .server = server,
        };
    }

    pub fn deinit(self: *Server) void {
        self.server.deinit();
    }

    pub fn getContext(self: *Server) !Context {
        var connection = try self.server.accept();
        errdefer connection.stream.close();

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer arena.deinit();

        var url_buf: [1200]u8 = undefined;
        const url = try arena.allocator.dupe(u8, readCrLf(connection.stream.reader(), &url_buf) orelse return error.BadRequest);

        const css = std.mem.indexOf(u8, url, "://") orelse return error.BadRequest;
        const scheme = url[0..css];

        const without_scheme = url[(scheme.len + "://".len)..];
        const indeks = std.mem.indexOf(u8, without_scheme, "/");
        const host = if (indeks) |ix| without_scheme[0..ix] else without_scheme;
        const dangerous_uri = if (indeks) |ix| without_scheme[ix + 1 ..] else "";

        var path_buf: [1024]u8 = undefined;
        const path = try arena.allocator.dupe(u8, (try resolvePath(&path_buf, dangerous_uri))[1..]);

        return Context{
            .request = .{
                .original_url = url,
                .url = .{
                    .scheme = scheme,
                    .host = host,
                    .path = path,
                },
            },
            .response_status = ResponseStatus.TEMPORARY_FAILURE,
            .arena = arena,
            .connection = connection,
            .headers_written = false,
        };
    }

    fn readCrLf(in: anytype, buf: []u8) ?[]u8 {
        const line = (in.readUntilDelimiterOrEof(buf, '\n') catch |_| null) orelse
            return null;
        if (line.len == 0 or line[line.len - 1] != '\r')
            return null;
        return line[0 .. line.len - 1];
    }

    pub const Context = struct {
        pub const Writer = std.io.Writer(*Context, std.os.WriteError, write);

        request: Request,
        response_status: ResponseStatus,

        arena: std.heap.ArenaAllocator,
        connection: std.net.StreamServer.Connection,
        headers_written: bool,

        pub fn deinit(self: *Context) void {
            defer self.arena.deinit();
            defer self.connection.stream.close();

            self.ensureResponseStatusWritten() catch {};
        }

        pub fn status(self: *Context, response_status: ResponseStatus) void {
            self.response_status = response_status;
        }

        pub fn writer(self: *Context) Writer {
            return .{ .context = self };
        }

        fn ensureResponseStatusWritten(self: *Context) !void {
            if (self.headers_written) return;
            try self.connection.stream.writer().print("{} {s}\r\n", .{ @enumToInt(self.response_status.code), self.response_status.meta });
            self.headers_written = true;
        }

        fn write(self: *Context, buffer: []const u8) std.os.WriteError!usize {
            try self.ensureResponseStatusWritten();
            return self.connection.stream.write(buffer);
        }
    };

    pub const Request = struct {
        original_url: []u8,
        url: struct {
            scheme: []const u8,
            host: []const u8,
            path: []u8,
        },
    };

    pub const ResponseStatus = struct {
        code: enum(u8) {
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
        },
        meta: []const u8,

        pub const TEMPORARY_FAILURE: ResponseStatus = .{ .code = .TemporaryFailure, .meta = "internal error" };
        pub const NO_NON_GEMINI: ResponseStatus = .{ .code = .ProxyRequestRefused, .meta = "no non-gemini requests" };
        pub const NO_MATCHING_VHOST: ResponseStatus = .{ .code = .ProxyRequestRefused, .meta = "no matching vhost" };
        pub const BAD_REQUEST: ResponseStatus = .{ .code = .BadRequest, .meta = "bad request" };
        pub const NOT_FOUND: ResponseStatus = .{ .code = .NotFound, .meta = "not found" };
    };
};
