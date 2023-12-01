const std = @import("std");

const os = std.os;
const http = @import("httpz.zig");

const Self = @This();

const Url = @import("url.zig").Url;
const Conn = @import("conn.zig").Conn;
const Params = @import("params.zig").Params;
const KeyValue = @import("key_value.zig").KeyValue;

const Stream = std.net.Stream;
const Address = std.net.Address;
const Allocator = std.mem.Allocator;

// this approach to matching method name comes from zhp
const GET_ = @as(u32, @bitCast([4]u8{'G', 'E', 'T', ' '}));
const PUT_ = @as(u32, @bitCast([4]u8{'P', 'U', 'T', ' '}));
const POST = @as(u32, @bitCast([4]u8{'P', 'O', 'S', 'T'}));
const HEAD = @as(u32, @bitCast([4]u8{'H', 'E', 'A', 'D'}));
const PATC = @as(u32, @bitCast([4]u8{'P', 'A', 'T', 'C'}));
const DELE = @as(u32, @bitCast([4]u8{'D', 'E', 'L', 'E'}));
const OPTI = @as(u32, @bitCast([4]u8{'O', 'P', 'T', 'I'}));
const HTTP = @as(u32, @bitCast([4]u8{'H', 'T', 'T', 'P'}));
const V1P0 = @as(u32, @bitCast([4]u8{'/', '1', '.', '0'}));
const V1P1 = @as(u32, @bitCast([4]u8{'/', '1', '.', '1'}));

pub const Config = struct {
	max_body_size: ?usize = null,
	buffer_size: ?usize = null,
	max_header_count: ?usize = null,
	max_param_count: ?usize = null,
	max_query_count: ?usize = null,
	read_header_timeout: ?u32 = null,
	read_body_timeout: ?u32 = null,
};

// Each parsing step (method, target, protocol, headers, body)
// return (a) how much data they've read from the socket and
// (b) how much data they've consumed. This informs the next step
// about what's available and where to start.
fn ParseResult(comptime R: type) type {
	return struct {
		// the value that we parsed
		value: R,

		// how much the step used of the buffer
		used: usize,

		// total data read from the socket (by a particular step)
		read: usize,
	};
}

const zero_timeval = std.mem.toBytes(os.timeval{
	.tv_sec = 0,
	.tv_usec = 0,
});

pub const Request = struct {
	// The URL of the request
	url: Url,

	// the address of the client
	address: Address,

	// the underlying socket to read from
	stream: Stream,

	// Path params (extracted from the URL based on the route).
	// Using req.param(NAME) is preferred.
	params: Params,

	// The headers of the request. Using req.header(NAME) is preferred.
	headers: KeyValue,

	// The request method.
	method: http.Method,

	// The request protocol.
	protocol: http.Protocol,

	// The maximum body that we'll allow, take from the config object when the
	// request is first created.
	max_body_size: usize,

	// The body of the request, if any.
	bd: ?[]const u8 = null,

	// cannot use an optional on qs, because it's pre-allocated so always exists
	qs_read: bool = false,

	// The query string lookup.
	qs: KeyValue,

	// Where in static we currently are. This is needed so that we can tell if
	// the body can be read directly in static or not (if there's enough space).
	pos: usize,

	// When parsing our header, we're reading as much data as possible from the
	// the socket. This means we might read some of the body into our static buffer
	// as part of the "header" parsing. We need to know how much of static is the
	// already-read body so that when it comes time to actually read the body, we
	// know how much we've already done.
	header_overread: usize,

	// A buffer that exists for the entire lifetime of the request. The sized
	// is defined by the request.buffer_size configuration. The request header MUST
	// fit in this size (requests with headers larger than this will be rejected).
	// If possible, this space will also be used for the body.
	static: []u8,

	// An arena that will be reset at the end of each request. Can be used
	// internally by this framework. The application is also free to make use of
	// this arena. This is the same arena as response.arena.
	arena: Allocator,

	// whether or not, from the server's point of view, we should keep this connection
	// alive or not
	keepalive: bool,

	pub const State = Self.State;
	pub const Config = Self.Config;
	pub const Reader = Self.Reader;

	pub fn init(arena: Allocator, conn: *Conn, will_close: bool) Request {
		const reader = &conn.reader;
		const state = conn.req_state;

		return .{
			.pos = reader.pos,
			.url = Url.parse(reader.url.?),
			.arena = arena,
			.stream = conn.stream,
			.method = reader.method.?,
			.keepalive = !will_close,
			.protocol = reader.protocol.?,
			.address = conn.address,
			.header_overread = reader.len - reader.pos,
			.max_body_size = state.max_body_size,
			.qs = state.qs,
			.static = state.buf,
			.params = state.params,
			.headers = state.headers,
		};
	}

	pub fn header(self: *const Request, name: []const u8) ?[]const u8 {
		return self.headers.get(name);
	}

	pub fn param(self: *const Request, name: []const u8) ?[]const u8 {
		return self.params.get(name);
	}

	pub fn query(self: *Request) !KeyValue {
		if (self.qs_read) {
			return self.qs;
		}
		return self.parseQuery();
	}

	pub fn body(self: *Request) !?[]const u8 {
		if (self.bd) |bd| {
			return bd;
		}

		const stream = self.stream;

		if (self.header("content-length")) |cl| {
			const length = atoi(cl) orelse return error.InvalidContentLength;
			if (length == 0) {
				self.bd = null;
				return null;
			}

			if (length > self.max_body_size) {
				return error.BodyTooBig;
			}

			const pos = self.pos;

			// some (or all) of the body might have already been read into static
			// when we were loading data as part of reading the header.
			var read = self.header_overread;

			if (read == length) {
				// we're already read the entire body into static
				self.bd = self.static[pos..(pos+read)];
				self.pos += read;
				return self.bd;
			}

			var buffer = self.static[pos..];
			if (buffer.len >= length) {
				self.pos = pos + length;
			} else {
				buffer = try self.arena.alloc(u8, length);
				@memcpy(buffer[0..read], self.static[pos..(pos+read)]);
			}

			while (read < length) {
				const n = try stream.read(buffer[read..]);
				if (n == 0) {
					return error.ConnectionClosed;
				}
				read += n;
			}
			buffer = buffer[0..length];
			self.bd = buffer;
			return buffer;
		}
		// TODO: support chunked encoding
		return self.bd;
	}

	pub fn json(self: *Request, comptime T: type) !?T {
		const b = try self.body() orelse return null;
		return try std.json.parseFromSliceLeaky(T, self.arena, b, .{});
	}

	pub fn jsonValue(self: *Request) !?std.json.Value {
		const b = try self.body() orelse return null;
		return try std.json.parseFromSliceLeaky(std.json.Value, self.arena, b, .{});
	}

	pub fn jsonObject(self: *Request) !?std.json.ObjectMap {
		const value = try self.jsonValue() orelse return null;
		switch (value) {
			.object => |o| return o,
			else => return null,
		}
	}

	// OK, this is a bit complicated.
	// We might need to allocate memory to parse the querystring. Specifically, if
	// there's a url-escaped component (a key or value), we need memory to store
	// the un-escaped version. Ideally, we'd like to use our static buffer for this
	// but, and this is where it gets complicated, we might:
	// 1 - Not have enough space
	// 2 - Might have over-read the header and have part (or all) of the body in there
	// The 1st case is easy: if we have space in the static buffer, we use it. If
	// we don't, we allocate space in our arena. The space of an un-escaped component
	// is always < than space of the original, so we can determine this easily.
	// The 2nd case, where the static buffer is being used by the body as well, is
	// where things get tricky. We could try to be smart and figure out: is there
	// a body? Did we read it all? Did we partially read it but have the length?
	// Instead, for now, we just load the body. The net result is that whatever
	// free space we have left in the static buffer, we can use for this.
	// It's a simple solution and it causes virtually no overhead in the two most
	// common cases: (1) there is no body (2) there is a body and the app wants it.
	// The only case where this makes it inefficient is where:
	//    (there is a body AND the app doesn't want it) AND
	//       (no keepalive OR (keepalive AND body > buffer)).
	// If you're wondering why keepalive matters? It's because, with keepalive
	// (which we generally expect to be set), the body needs to be read anyways.
	fn parseQuery(self: *Request) !KeyValue {
		const raw = self.url.query;
		if (raw.len == 0) {
			self.qs_read = true;
			return self.qs;
		}

		_ = try self.body();

		var qs = &self.qs;
		var pos = self.pos;
		const allocator = self.arena;
		var buffer = self.static[pos..];

		var it = std.mem.splitScalar(u8, raw, '&');
		while (it.next()) |pair| {
			if (std.mem.indexOfScalar(u8, pair, '=')) |sep| {
				const key_res = try Url.unescape(allocator, buffer, pair[0..sep]);
				if (key_res.buffered) {
					const n = key_res.value.len;
					pos += n;
					buffer = buffer[n..];
				}

				const value_res = try Url.unescape(allocator, buffer, pair[sep+1..]);
				if (value_res.buffered) {
					const n = value_res.value.len;
					pos += n;
					buffer = buffer[n..];
				}
				qs.add(key_res.value, value_res.value);
			} else {
				const key_res = try Url.unescape(allocator, buffer, pair);
				if (key_res.buffered) {
					const n = key_res.value.len;
					pos += n;
					buffer = buffer[n..];
				}
				qs.add(key_res.value, "");
			}
		}

		self.pos = pos;
		self.qs_read = true;
		return self.qs;
	}

	// Drains the body from the socket (if it hasn't already been read). This is
	// only necessary during keepalive requests. We don't care about the contents
	// of the body, we just want to move the socket to end of this request (which
	// would be the start of the next one).
	// We assume the request will be reset after this is called, so its ok for us
	// to clear the static buffer (which various header elements point to)
	pub fn drain(self: *Request) !void {
		if (self.bd != null) {
			// body has already been read
			return;
		}

		const stream = self.stream;
		if (self.header("content-length")) |value| {
			var buffer = self.static;
			var length = atoi(value) orelse return error.InvalidContentLength;

			const header_overread = self.header_overread;
			if (header_overread > length) {
				return error.TooMuchData;
			}

			length -= header_overread;
			while (length > 0) {
				const n = if (buffer.len > length) buffer[0..length] else buffer;
				length -= try stream.read(n);
			}
		} else {
			// TODO: support chunked encoding
		}
	}

	pub fn canKeepAlive(self: *const Request) bool {
		if (self.keepalive == false) {
			return false;
		}

		return switch (self.protocol) {
			http.Protocol.HTTP11 => {
				if (self.headers.get("connection")) |conn| {
					return !std.mem.eql(u8, conn, "close");
				}
				return true;
			},
			http.Protocol.HTTP10 => return false, // TODO: support this in the cases where it can be
		};
	}
};

// All the upfront memory allocation that we can do. Gets re-used from request
// to request.
pub const State = struct {
	buf: []u8,
	qs: KeyValue,
	headers: KeyValue,
	params: Params,
	max_body_size: usize,

	pub fn init(allocator: Allocator, config: *const Config) !Request.State {
		return .{
			.max_body_size = config.max_body_size orelse 1_048_576,
			.qs = try KeyValue.init(allocator, config.max_query_count orelse 32),
			.buf = try allocator.alloc(u8, config.buffer_size orelse 32_768),
			.headers = try KeyValue.init(allocator, config.max_header_count orelse 32),
			.params = try Params.init(allocator, config.max_param_count orelse 10),
		};
	}

	pub fn deinit(self: *State, allocator: Allocator) void {
		allocator.free(self.buf);
		self.qs.deinit(allocator);
		self.params.deinit(allocator);
		self.headers.deinit(allocator);
	}

	pub fn reset(self: *State) void {
		self.qs.reset();
		self.params.reset();
		self.headers.reset();
	}
};

pub const Reader = struct {
	// position in state.buf that we've parsed up to
	pos: usize,

	// length of state.buffer for which we have valid data
	len: usize,

	state: *Request.State,

	url: ?[]u8,
	method: ?http.Method,
	protocol: ?http.Protocol,

	pub fn init(state: *State) Reader {
		return .{
			.pos = 0,
			.len = 0,
			.url = null,
			.method = null,
			.protocol = null,
			.state = state,
		};
	}

	pub fn reset(self: *Reader) void {
		self.pos = 0;
		self.len = 0;
		self.url = null;
		self.method = null;
		self.protocol = null;
	}

	// returns true if the header has been fully parsed
	pub fn parse(self: *Reader, stream: anytype) !bool {
		var len = self.len;
		const buf = self.state.buf;
		const n = try stream.read(buf[len..]);
		if (n == 0) {
			return error.ConnectionClosed;
		}
		len = len + n;
		self.len = len;

		blk: {
			// I know I could fallthrough, but that would be more conditional checks
			if (self.method == null) {
				self.method = (try self.parseMethod(buf[0..len])) orelse break :blk;
				self.url = (try self.parseURL(buf[self.pos..len])) orelse break :blk;
				self.protocol = (try self.parseProtocol(buf[self.pos..len])) orelse break :blk;
				return (try self.parseHeaders(buf[self.pos..len])) orelse break :blk;
			}

			if (self.url == null) {
				self.url = (try self.parseURL(buf[self.pos..len])) orelse break :blk;
				self.protocol = (try self.parseProtocol(buf[self.pos..len])) orelse break :blk;
				return (try self.parseHeaders(buf[self.pos..len])) orelse break :blk;
			}

			if (self.protocol == null) {
				self.protocol = (try self.parseProtocol(buf[self.pos..len])) orelse break :blk;
				return (try self.parseHeaders(buf[self.pos..len])) orelse break :blk;
			}

			return (try self.parseHeaders(buf[self.pos..len])) orelse break :blk;
		}

		if (len == buf.len) {
			return error.HeaderTooBig;
		}
		return false;
	}

	fn parseMethod(self: *Reader, buf: []u8) !?http.Method {
		const buf_len = buf.len;
		if (buf_len < 4) return null;

		switch (@as(u32, @bitCast(buf[0..4].*))) {
			GET_ => {
				self.pos = 4;
				return .GET;
			},
			PUT_ => {
				self.pos = 4;
				return .PUT;
			},
			POST => {
				if (buf_len < 5) return null;
				if (buf[4] != ' ') return error.UnknownMethod;
				self.pos = 5;
				return .POST;
			},
			HEAD => {
				if (buf_len < 5) return null;
				if (buf[4] != ' ') return error.UnknownMethod;
				self.pos = 5;
				return .HEAD;
			},
			PATC => {
				if (buf_len < 6) return null;
				if (buf[4] != 'H' or buf[5] != ' ') return error.UnknownMethod;
				self.pos = 6;
				return .PATCH;
			},
			DELE => {
				if (buf_len < 7) return null;
				if (buf[4] != 'T' or buf[5] != 'E' or buf[6] != ' ' ) return error.UnknownMethod;
				self.pos = 7;
				return .DELETE;
			},
			OPTI => {
				if (buf_len < 8) return null;
				if (buf[4] != 'O' or buf[5] != 'N' or buf[6] != 'S' or buf[7] != ' ' ) return error.UnknownMethod;
				self.pos = 8;
				return .OPTIONS;
			},
			else => return error.UnknownMethod,
		}
	}

	fn parseURL(self: *Reader, buf: []u8) !?[]u8 {
		const buf_len = buf.len;
		if (buf_len == 0) return null;

		switch (buf[0]) {
			'/' => {
				const end_index = std.mem.indexOfScalar(u8, buf[1..buf_len], ' ') orelse return null;
				// +1 since we skipped the leading / in our indexOfScalar and +1 to consume the space
				self.pos += end_index + 2;
				return buf[0..end_index+1];
			},
			'*' => {
				if (buf_len == 1) return null;
				// Read never returns 0, so if we're here, buf.len >= 1
				if (buf[1] != ' ') return error.InvalidRequestTarget;
				self.pos += 2;
				return buf[0..1];
			},
			// TODO: Support absolute-form target (e.g. http://....)
			else => return error.InvalidRequestTarget,
		}
	}

	fn parseProtocol(self: *Reader, buf: []u8) !?http.Protocol {
		const buf_len = buf.len;
		if (buf_len < 10) return null;

		if (@as(u32, @bitCast(buf[0..4].*)) != HTTP) {
			return error.UnknownProtocol;
		}

		const proto = switch (@as(u32, @bitCast(buf[4..8].*))) {
			V1P1 => http.Protocol.HTTP11,
			V1P0 => http.Protocol.HTTP10,
			else => return error.UnsupportedProtocol,
		};

		if (buf[8] != '\r' or buf [9] != '\n') {
			return error.UnknownProtocol;
		}

		self.pos += 10;
		return proto;
	}

	fn parseHeaders(self: *Reader, full: []u8) !?bool {
		var pos = self.pos;
		var headers = &self.state.headers;

		var buf = full;
		while (true) {
			const buf_len = buf.len;
			const header_end = std.mem.indexOfScalar(u8, buf, '\r') orelse return null;

			const next = header_end + 1;
			if (next == buf_len) return null;
			if (buf[next] != '\n') return error.InvalidHeaderLine;

			// means this follows the last \r\n, which means it's the end of our headers
			if (header_end == 0) {
				self.pos += 2;
				return true;
			}

			var valid = false;
			for (buf[0..header_end], 0..) |b, i| {
				// find the colon and lowercase the header while we're iterating
				if ('A' <= b and b <= 'Z') {
					buf[i] = b + 32;
					continue;
				}
				if (b != ':') {
					continue;
				}

				const name = buf[0..i];
				const value = trimLeadingSpace(buf[i+1..header_end]);
				headers.add(name, value);
				valid = true;
				break;
			}
			if (!valid) {
				return error.InvalidHeaderLine;
			}

			// skip \n
			pos = next + 1;
			self.pos += pos;
			buf = buf[pos..];
		}
	}
};


inline fn trimLeadingSpace(in: []const u8) []const u8 {
	// very common case where we have a single space after our colon
	if (in.len >= 2 and in[0] == ' ' and in[1] != ' ') return in[1..];

	for (in, 0..) |b, i| {
		if (b != ' ') return in[i..];
	}
	return "";
}

fn readForHeader(stream: Stream, buffer: []u8) !usize {
	const n = try stream.read(buffer);
	if (n == 0) {
		if (buffer.len == 0) {
			return error.HeaderTooBig;
		}
		return error.ConnectionClosed;
	}
	return n;
}

fn atoi(str: []const u8) ?usize {
	if (str.len == 0) {
		return null;
	}

	var n: usize = 0;
	for (str) |b| {
		const d = b - '0';
		if (d > 9) {
			return null;
		}
		n = n * 10 + @as(usize, @intCast(d));
	}
	return n;
}

const t = @import("t.zig");
test "atoi" {
	var buf: [5]u8 = undefined;
	for (0..99999) |i| {
		const n = std.fmt.formatIntBuf(&buf, i, 10, .lower, .{});
		try t.expectEqual(i, atoi(buf[0..n]).?);
	}

	try t.expectEqual(null, atoi(""));
	try t.expectEqual(null, atoi("392a"));
	try t.expectEqual(null, atoi("b392"));
	try t.expectEqual(null, atoi("3c92"));
}

test "request: header too big" {
	try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\n\r\n", .{.buffer_size = 17});
	try expectParseError(error.HeaderTooBig, "GET / HTTP/1.1\r\nH: v\r\n\r\n", .{.buffer_size = 23});
}

test "request: parse method" {
	{
		try expectParseError(error.UnknownMethod, "GETT ", .{});
		try expectParseError(error.UnknownMethod, " PUT ", .{});
	}

	{
		const r = testParse("GET / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.GET, r.method);
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.PUT, r.method);
	}

	{
		const r = testParse("POST / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.POST, r.method);
	}

	{
		const r = testParse("HEAD / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.HEAD, r.method);
	}

	{
		const r = testParse("PATCH / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.PATCH, r.method);
	}

	{
		const r = testParse("DELETE / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.DELETE, r.method);
	}

	{
		const r = testParse("OPTIONS / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Method.OPTIONS, r.method);
	}
}

test "request: parse request target" {
	{
		try expectParseError(error.InvalidRequestTarget, "GET NOPE", .{});
		try expectParseError(error.InvalidRequestTarget, "GET nope ", .{});
		try expectParseError(error.InvalidRequestTarget, "GET http://www.pondzpondz.com/test ", .{}); // this should be valid
		try expectParseError(error.InvalidRequestTarget, "PUT hello ", .{});
		try expectParseError(error.InvalidRequestTarget, "POST  /hello ", .{});
		try expectParseError(error.InvalidRequestTarget, "POST *hello ", .{});
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectString("/", r.url.raw);
	}

	{
		const r = testParse("PUT /api/v2 HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectString("/api/v2", r.url.raw);
	}

	{
		const r = testParse("DELETE /API/v2?hack=true&over=9000%20!! HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectString("/API/v2?hack=true&over=9000%20!!", r.url.raw);
	}

	{
		const r = testParse("PUT * HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectString("*", r.url.raw);
	}
}

test "request: parse protocol" {
	{
		try expectParseError(error.UnknownProtocol, "GET / http/1.1\r\n", .{});
		try expectParseError(error.UnsupportedProtocol, "GET / HTTP/2.0\r\n", .{});
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Protocol.HTTP10, r.protocol);
	}

	{
		const r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(http.Protocol.HTTP11, r.protocol);
	}
}

test "request: parse headers" {
	{
		try expectParseError(error.InvalidHeaderLine, "GET / HTTP/1.1\r\nHost\r\n", .{});
	}

	{
		const r = testParse("PUT / HTTP/1.0\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(0, r.headers.len);
	}

	{
		var r = testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\n\r\n", .{});
		defer testCleanup(r);

		try t.expectEqual(1, r.headers.len);
		try t.expectString("pondzpondz.com", r.headers.get("host").?);
	}

	{
		var r = testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nMisc:  Some-Value\r\nAuthorization:none\r\n\r\n", .{});
		defer testCleanup(r);

		try t.expectEqual(3, r.headers.len);
		try t.expectString("pondzpondz.com", r.header("host").?);
		try t.expectString("Some-Value", r.header("misc").?);
		try t.expectString("none", r.header("authorization").?);
	}
}

test "request: canKeepAlive" {
	{
		// implicitly keepalive for 1.1
		var r = testParse("GET / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(true, r.canKeepAlive());
	}

	{
		// explicitly keepalive for 1.1
		var r = testParse("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(true, r.canKeepAlive());
	}

	{
		// explicitly not keepalive for 1.1
		var r = testParse("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(false, r.canKeepAlive());
	}
}

test "request: query" {
	{
		// none
		var r = testParse("PUT / HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(0, (try r.query()).len);
	}

	{
		// none with path
		var r = testParse("PUT /why/would/this/matter HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		try t.expectEqual(0, (try r.query()).len);
	}

	{
		// value-less
		var r = testParse("PUT /?a HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		const query = try r.query();
		try t.expectEqual(1, query.len);
		try t.expectString("", query.get("a").?);
		try t.expectEqual(null, query.get("b"));
	}

	{
		// single
		var r = testParse("PUT /?a=1 HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		const query = try r.query();
		try t.expectEqual(1, query.len);
		try t.expectString("1", query.get("a").?);
		try t.expectEqual(null, query.get("b"));
	}

	{
		// multiple
		var r = testParse("PUT /path?Teg=Tea&it%20%20IS=over%209000%24&ha%09ck HTTP/1.1\r\n\r\n", .{});
		defer testCleanup(r);
		const query = try r.query();
		try t.expectEqual(3, query.len);
		try t.expectString("Tea", query.get("Teg").?);
		try t.expectString("over 9000$", query.get("it  IS").?);
		try t.expectString("", query.get("ha\tck").?);
	}
}

test "request: body content-length" {
	{
		// too big
		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{.max_body_size = 9});
		defer testCleanup(r);
		try t.expectError(error.BodyTooBig, r.body());
	}

	{
		// no body
		var r = testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{.max_body_size = 10});
		defer testCleanup(r);
		try t.expectEqual(null, try r.body());
		try t.expectEqual(null, try r.body());
	}

	{
		// fits into static buffer
		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
		defer testCleanup(r);
		try t.expectString("Over 9000!", (try r.body()).?);
		try t.expectString("Over 9000!", (try r.body()).?);
	}

	{
		// Requires dynamic buffer
		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 11\r\n\r\nOver 9001!!", .{.buffer_size = 40 });
		defer testCleanup(r);
		try t.expectString("Over 9001!!", (try r.body()).?);
		try t.expectString("Over 9001!!", (try r.body()).?);
	}
}

// // the query and body both (can) occupy space in our static buffer, so we want
// // to make sure they both work regardless of the order they're useds
// test "request: query & body" {
// 	{
// 		// query then body
// 		var r = testParse("POST /?search=keemun%20tea HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
// 		defer testCleanup(r);
// 		try t.expectString("keemun tea", (try r.query()).get("search").?);
// 		try t.expectString("Over 9000!", (try r.body()).?);

// 		// results should be cached internally, but let's double check
// 		try t.expectString("keemun tea", (try r.query()).get("search").?);
// 		try t.expectString("Over 9000!", (try r.body()).?);
// 	}

// 	{
// 		// body then query
// 		var r = testParse("POST /?search=keemun%20tea HTTP/1.0\r\nContent-Length: 10\r\n\r\nOver 9000!", .{});
// 		defer testCleanup(r);
// 		try t.expectString("Over 9000!", (try r.body()).?);
// 		try t.expectString("keemun tea", (try r.query()).get("search").?);

// 		// results should be cached internally, but let's double check
// 		try t.expectString("Over 9000!", (try r.body()).?);
// 		try t.expectString("keemun tea", (try r.query()).get("search").?);
// 	}
// }

// test "body: json" {
// 	const Tea = struct {
// 		type: []const u8,
// 	};

// 	{
// 		// too big
// 		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{.max_body_size = 16});
// 		defer testCleanup(r);
// 		try t.expectError(error.BodyTooBig, r.json(Tea));
// 	}

// 	{
// 		// no body
// 		var r = testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{.max_body_size = 10});
// 		defer testCleanup(r);
// 		try t.expectEqual(null, try r.json(Tea));
// 		try t.expectEqual(null, try r.json(Tea));
// 	}

// 	{
// 		// parses json
// 		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
// 		defer testCleanup(r);
// 		try t.expectString("keemun", (try r.json(Tea)).?.type);
// 		try t.expectString("keemun", (try r.json(Tea)).?.type);
// 	}
// }

// test "body: jsonValue" {
// 	{
// 		// too big
// 		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{.max_body_size = 16});
// 		defer testCleanup(r);
// 		try t.expectError(error.BodyTooBig, r.jsonValue());
// 	}

// 	{
// 		// no body
// 		var r = testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{.max_body_size = 10});
// 		defer testCleanup(r);
// 		try t.expectEqual(null, try r.jsonValue());
// 		try t.expectEqual(null, try r.jsonValue());
// 	}

// 	{
// 		// parses json
// 		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
// 		defer testCleanup(r);
// 		try t.expectString("keemun", (try r.jsonValue()).?.object.get("type").?.string);
// 		try t.expectString("keemun", (try r.jsonValue()).?.object.get("type").?.string);
// 	}
// }

// test "body: jsonObject" {
// 	{
// 		// too big
// 		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{.max_body_size = 16});
// 		defer testCleanup(r);
// 		try t.expectError(error.BodyTooBig, r.jsonObject());
// 	}

// 	{
// 		// no body
// 		var r = testParse("PUT / HTTP/1.0\r\nHost: pondzpondz.com\r\nContent-Length: 0\r\n\r\n", .{.max_body_size = 10});
// 		defer testCleanup(r);
// 		try t.expectEqual(null, try r.jsonObject());
// 		try t.expectEqual(null, try r.jsonObject());
// 	}

// 	{
// 		// not an object
// 		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 7\r\n\r\n\"hello\"", .{});
// 		defer testCleanup(r);
// 		try t.expectEqual(null, try r.jsonObject());
// 		try t.expectEqual(null, try r.jsonObject());
// 	}

// 	{
// 		// parses json
// 		var r = testParse("POST / HTTP/1.0\r\nContent-Length: 17\r\n\r\n{\"type\":\"keemun\"}", .{});
// 		defer testCleanup(r);
// 		try t.expectString("keemun", (try r.jsonObject()).?.get("type").?.string);
// 		try t.expectString("keemun", (try r.jsonObject()).?.get("type").?.string);
// 	}
// }

// // our t.Stream already simulates random TCP fragmentation.
// test "request: fuzz" {
// 	// We have a bunch of data to allocate for testing, like header names and
// 	// values. Easier to use this arena and reset it after each test run.
// 	var arena = std.heap.ArenaAllocator.init(t.allocator);
// 	const aa = arena.allocator();
// 	defer arena.deinit();

// 	var r = t.getRandom();
// 	const random = r.random();
// 	for (0..100) |_| {

// 		var s = t.Stream.init();
// 		defer s.deinit();

// 		// important to test with different buffer sizes, since there's a lot of
// 		// special handling for different cases (e.g the buffer is full and has
// 		// some of the body in it, so we need to copy that to a dynamically allocated
// 		// buffer)
// 		const buffer_size = random.uintAtMost(u16, 1024) + 1024;

// 		// how many requests should we make on this 1 individual socket (simulating
// 		// keepalive AND the request pool)
// 		const number_of_requests = random.uintAtMost(u8, 10) + 1;

// 		for (0..number_of_requests) |_| {
// 			defer _ = arena.reset(.free_all);

// 			const method = randomMethod(random);
// 			const url = t.randomString(random, aa, 20);

// 			s.write(method);
// 			s.write(" /");
// 			s.write(url);

// 			const number_of_qs = random.uintAtMost(u8, 4);
// 			if (number_of_qs != 0) {
// 				s.write("?");
// 			}
// 			var query = std.StringHashMap([]const u8).init(aa);
// 			for (0..number_of_qs) |_| {
// 				const key = t.randomString(random, aa, 20);
// 				const value = t.randomString(random, aa, 20);
// 				if (!query.contains(key)) {
// 					// TODO: figure out how we want to handle duplicate query values
// 					// (the spec doesn't specifiy what to do)
// 					query.put(key, value) catch unreachable;
// 					s.write(key);
// 					s.write("=");
// 					s.write(value);
// 					s.write("&");
// 				}
// 			}

// 			_ = s.write(" HTTP/1.1\r\n");

// 			var headers = std.StringHashMap([]const u8).init(aa);
// 			for (0..random.uintAtMost(u8, 4)) |_| {
// 				const name = t.randomString(random, aa, 20);
// 				const value = t.randomString(random, aa, 20);
// 				if (!headers.contains(name)) {
// 					// TODO: figure out how we want to handle duplicate query values
// 					// Note, the spec says we should merge these!
// 					headers.put(name, value) catch unreachable;
// 					s.write(name);
// 					s.write(": ");
// 					s.write(value);
// 					s.write("\r\n");
// 				}
// 			}

// 			var body: ?[]u8 = null;
// 			if (random.uintAtMost(u8, 4) == 0) {
// 				s.write("\r\n"); // no body
// 			} else {
// 				body = t.randomString(random, aa, 8000);
// 				const cl = std.fmt.allocPrint(aa, "{d}", .{body.?.len}) catch unreachable;
// 				headers.put("content-length", cl) catch unreachable;
// 				s.write("content-length: ");
// 				s.write(cl);
// 				s.write("\r\n\r\n");
// 				s.write(body.?);
// 			}

// 			var request = testRequest(.{.buffer_size = buffer_size}, s) catch |err| {
// 				std.debug.print("\nParse Error: {}", .{err});
// 				unreachable;
// 			};
// 			defer _ = t.aa.reset(.free_all);

// 			// assert the headers
// 			var it = headers.iterator();
// 			while (it.next()) |entry| {
// 				try t.expectString(entry.value_ptr.*, request.header(entry.key_ptr.*).?);
// 			}

// 			// assert the querystring
// 			var actualQuery = request.query() catch unreachable;
// 			it = query.iterator();
// 			while (it.next()) |entry| {
// 				try t.expectString(entry.value_ptr.*, actualQuery.get(entry.key_ptr.*).?);
// 			}

// 			// We dont' read the body by defalt. We donly read the body when the app
// 			// calls req.body(). It's important that we test both cases. When the body
// 			// isn't read, we still need to drain the bytes from the socket for when
// 			// the socket is reused.
// 			if (random.uintAtMost(u8, 4) != 0) {
// 				const actual = request.body() catch unreachable;
// 				if (body) |b| {
// 					try t.expectString(b, actual.?);
// 				} else {
// 					try t.expectEqual(null, actual);
// 				}
// 			}

// 			request.drain() catch unreachable;
// 		}
// 	}
// }

// test "request: extra socket data" {
// 	var s = t.Stream.init();

// 	s.write("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\nHello!");

// 	var request = testRequest(.{.buffer_size = 50}, s) catch |err| {
// 		std.debug.print("\nParse Error: {}", .{err});
// 		unreachable;
// 	};
// 	defer testCleanup(request);

// 	try t.expectError(error.TooMuchData, request.drain());
// }

fn testParse(input: []const u8, config: Config) Request {
	var s = t.Stream.init();
	s.write(input);
	return testRequest(config,s) catch |err| {
		s.deinit();
		_ = t.aa.reset(.free_all);
		std.debug.print("\nParse Error: {}\nInput: {s}", .{err, input});
		unreachable;
	};
}

fn expectParseError(expected: anyerror, input: []const u8, config: Config) !void {
	defer _ = t.aa.reset(.free_all);

	var s = t.Stream.init();
	s.write(input);

	var state = State.init(t.arena, config) catch unreachable;
	var reader = Reader.init(&state);
	try t.expectError(expected, reader.parse(s.stream));
}

fn testRequest(config: Config, stream: t.Stream) !Request {
	const state = t.arena.create(State) catch unreachable;
	state.* = State.init(t.arena, config) catch unreachable;

	var reader = Reader.init(state);
	while (true) {
		if (try reader.parse(stream.stream)) break;
	}

	const conn = t.arena.create(Conn) catch unreachable;
	conn.* = .{
		.last_request = 0,
		.reader = reader,
		.req_state = state,
		.stream = stream.stream,
		.address = stream.conn.address,
	};

	return Request.init(t.arena, conn, false);
}

fn testCleanup(r: Request) void {
	r.stream.close();
	_ = t.aa.reset(.free_all);
}

fn randomMethod(random: std.rand.Random) []const u8 {
	return switch (random.uintAtMost(usize, 6)) {
		0 => "GET",
		1 => "PUT",
		2 => "POST",
		3 => "PATCH",
		4 => "DELETE",
		5 => "OPTIONS",
		6 => "HEAD",
		else => unreachable,
	};
}
