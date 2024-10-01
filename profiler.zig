const std = @import("std");
const Allocator = std.mem.Allocator;
const SourceLocation = std.builtin.SourceLocation;
const Instant = std.time.Instant;
const Thread = std.Thread;

const max_frames = 1024;
const max_threads = 128;
// const invalid_index = std.math.maxInt(usize);

fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

const Zone = struct {
    src: SourceLocation,
    name: [:0]const u8,
    depth: u64,
    t0: Instant,
    t1: Instant,
};

const ThreadFrame = struct {
    depth: u16 = 0,
    zones: std.MultiArrayList(Zone) = .{},
};

const Frame = struct {
    t0: Instant,
    threads: std.MultiArrayList(struct { tid: u64, tf: ThreadFrame }),

    fn find(self: *@This(), tid: u64) *ThreadFrame {
        const s = self.threads.slice();
        const tids = s.items(.tid);
        const tfs = s.items(.tf);
        return &tfs.ptr[
            std.mem.indexOfScalar(u64, tids, tid) orelse blk: {
                assert(self.threads.len < self.threads.capacity);
                const i = self.threads.len;
                self.threads.len += 1;
                tids.ptr[i] = tid;
                tfs.ptr[i] = .{};
                break :blk i;
            }
        ];
    }
};

var allocator: Allocator = undefined;
var t_startup: Instant = undefined;
var frame_index: u64 = undefined;
var len: u64 = undefined;
var frames: [max_frames]Frame = undefined;

const ZoneScope = struct {
    depth: u64,
    tid: u64,
    src: SourceLocation,
    name: [:0]const u8,
    t0: Instant,

    pub fn end(z: @This()) void {
        const t1 = Instant.now() catch unreachable;
        assert(z.tid == Thread.getCurrentId()); // ended in the same thread it started
        const f = &frames[frame_index];
        const t = f.find(z.tid);
        assert(z.depth + 1 == t.depth); // sane begin/end
        t.depth -= 1;
        t.zones.append(
            allocator,
            Zone{
                .depth = z.depth,
                .src = z.src,
                .name = z.name,
                .t0 = z.t0,
                .t1 = t1,
            },
        ) catch unreachable;
    }
};

const InitOptions = struct {
    allocator: Allocator = std.heap.page_allocator,
};

pub fn init(opt: InitOptions) void {
    allocator = opt.allocator;
    t_startup = Instant.now() catch unreachable;

    const f = &frames[0];
    f.t0 = t_startup;
    f.threads = .{};
    f.threads.ensureTotalCapacity(allocator, max_threads) catch unreachable;
    frame_index = 0;
    len = 1;
}

pub fn deinit() void {
    // for each allocated frame
    for (frames[0..len]) |*f| {
        // for each thread in the frame
        for (f.threads.items(.tf)) |*tf| tf.zones.deinit(allocator);
        f.threads.deinit(allocator);
    }
}

pub fn frameMark() void {
    frame_index += 1;
    var f1: *Frame = undefined;
    if (len == max_frames) {
        // reusing previous frames
        if (frame_index >= max_frames) frame_index -= max_frames;
        f1 = &frames[frame_index];
        // clear zones in all threads but kee
        for (f1.threads.items(.tf)) |*tf| tf.zones.len = 0;
    } else {
        // allocate a new frame
        len += 1;
        f1 = &frames[frame_index];
        f1.threads = .{};
        f1.threads.ensureTotalCapacity(allocator, max_threads) catch unreachable;
    }
    f1.t0 = Instant.now() catch unreachable;
}

pub fn begin(src: SourceLocation, name: [:0]const u8) ZoneScope {
    const tid = Thread.getCurrentId();
    const tf = frames[frame_index].find(tid);
    const depth = tf.depth;
    tf.depth += 1;
    return ZoneScope{
        .depth = depth,
        .tid = tid,
        .src = src,
        .name = name,
        .t0 = Instant.now() catch unreachable,
    };
}

pub fn dump(file_name: []const u8) !void {
    // const t_dump = Instant.now() catch unreachable;

    const file = try std.fs.cwd().createFile(file_name, .{});
    defer file.close();

    var comma = false;

    var depth: u16 = 0;
    var zone_stack: [256]usize = undefined;

    const writer = file.writer();
    try writer.writeAll("[\n");
    for (frames[0..len]) |*f| {
        // todo: add frames scopes

        // todo: not ideal, the events phases must be sorted BBEEBE to get a good trace print on chrome
        for (f.threads.items(.tf), 1..) |*tf, tid| {
            const s = tf.zones.slice();

            // higher depth zones are located first than their enclosed zones
            const Sort = struct {
                t: [*]Instant,
                pub inline fn lessThan(c: @This(), a: usize, b: usize) bool {
                    return c.t[a].order(c.t[b]) == .lt;
                }
            };
            tf.zones.sort(Sort{ .t = s.items(.t0).ptr });

            for (0..s.len) |i| {
                const zone_depth = s.items(.depth).ptr[i] + 1;

                // pop preivous scope
                while (zone_depth <= depth) {
                    depth -= 1;
                    const j = zone_stack[depth];
                    try writer.print(
                        \\,
                        \\  {{ "name": "{s}", "ph": "E", "pid": 0, "tid": {}, "ts": {} }}
                    , .{
                        s.items(.name).ptr[j],
                        tid,
                        @as(f64, @floatFromInt(s.items(.t1).ptr[j].since(t_startup))) / 1000.0,
                    });
                }

                zone_stack[depth] = i;
                depth += 1;
                assert(zone_depth == depth);

                if (comma) try writer.writeAll(",\n");
                comma = true;
                try writer.print(
                    \\  {{ "name": "{s}", "ph": "B", "pid": 0, "tid": {}, "ts": {} }}
                , .{
                    s.items(.name).ptr[i],
                    tid,
                    @as(f64, @floatFromInt(s.items(.t0).ptr[i].since(t_startup))) / 1000.0,
                });
            }

            // pop last zones
            while (depth > 0) {
                depth -= 1;
                const j = zone_stack[depth];
                try writer.print(
                    \\,
                    \\  {{ "name": "{s}", "ph": "E", "pid": 0, "tid": {}, "ts": {} }}
                , .{
                    s.items(.name).ptr[j],
                    tid,
                    @as(f64, @floatFromInt(s.items(.t1).ptr[j].since(t_startup))) / 1000.0,
                });
            }
        }
    }
    try writer.writeAll("\n]\n");
}

test {
    const Test = struct {
        fn foo() void {
            const zone = begin(@src(), "foo");
            defer zone.end();
            std.time.sleep(100);
        }
    };

    init(.{ .allocator = std.testing.allocator });
    defer deinit();

    const setup_zone = begin(@src(), "testSetup");
    std.time.sleep(100);
    setup_zone.end();

    for (0..4) |_| {
        defer frameMark(); // invalidates main zone

        const meat_zone = begin(@src(), "meat");
        Test.foo();
        std.time.sleep(10);
        meat_zone.end();

        std.time.sleep(10);
    }

    try dump("profile.json");
}
