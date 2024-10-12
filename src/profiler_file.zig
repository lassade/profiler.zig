const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const SourceLocation = std.builtin.SourceLocation;
const Timer = std.time.Timer;
const Thread = std.Thread;
const Id = Thread.Id;

pub const enabled = true;

pub const max_threads = 8;

fn assert(ok: bool) void {
    if (!ok) unreachable; // assertion failure
}

const Zone = struct {
    // src: SourceLocation,
    name: [:0]const u8,
    depth: u32,
    time_begin: u64,
    time_end: u64,
};

const ZoneList = std.ArrayListUnmanaged(Zone);

const Frame = struct {
    time_begin: u64,
    time_end: u64,
    tz: [max_threads]ZoneList,
};

var allocator: Allocator = undefined;
pub var time_scale: f64 = undefined;
pub var time_startup: u64 = undefined;
pub var timer: Timer = undefined;
pub var frame_index: u64 = undefined;
pub var len: u64 = undefined;
pub var frame: Frame = undefined;
var file: std.fs.File = undefined;
var dump_buffer: std.ArrayListUnmanaged(u8) = undefined;

const ThreadMeta = struct {
    id: Id = 0,
    depth: u32 = 0,
};
threadlocal var tmeta: ThreadMeta = .{};
var tida: std.atomic.Value(Id) = .{ .raw = 1 };

// todo: not quite sure when `rdtsc` is available
const hwtsc = builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86;

inline fn sample() u64 {
    // losely based on tracy Profiler::GetTime() TracyProfiler.hpp:190
    if (hwtsc) {
        // rdtscp includes the processor id and coobers ecx as well
        return asm volatile (
            \\rdtsc
            \\shlq    $32, %rdx
            \\orq     %rdx, %rax
            : [ret] "={rax}" (-> u64),
            : // inputs
            : "rax", "rdx" // clobbers
        );
    } else {
        // fallback, not as acurate when dealing with nanosecond scale
        return timer.read();
    }
}

const ZoneScope = struct {
    tid: Id,
    depth: u32,
    // src: SourceLocation,
    name: [:0]const u8,
    time_begin: u64,

    pub fn end(z: @This()) void {
        const t_end = sample();
        assert(z.tid == tmeta.id); // ended in the same thread it started
        assert(z.depth + 1 == tmeta.depth); // ordered begin/end
        tmeta.depth -= 1;
        frame.tz[(z.tid -% 1)].append(
            allocator,
            Zone{
                .depth = z.depth,
                // .src = z.src,
                .name = z.name,
                .time_begin = z.time_begin,
                .time_end = t_end,
            },
        ) catch unreachable;
    }
};

const InitOptions = struct {
    allocator: Allocator = std.heap.page_allocator,
    file_name: []const u8 = "profile.json",
};

pub fn init(opt: InitOptions) !void {
    allocator = opt.allocator;
    timer = try Timer.start();
    time_startup = sample();

    file = try std.fs.cwd().createFile(opt.file_name, .{});
    try file.writeAll("[\n");
    dump_buffer = .{};

    frame.time_begin = time_startup;
    frame.time_end = time_startup;
    @memset(&frame.tz, ZoneList{});
    frame_index = 0;
    len = 1;

    calibrate();
}

/// can take up to 200ms to calibrate
fn calibrate() void {
    // copied from tracy Profiler::CalibrateTimer() TracyProfiler.cpp:3519
    if (hwtsc) {
        const zone = begin(@src(), "calibrate");
        defer zone.end();

        @fence(.acq_rel);
        const t0 = std.time.Instant.now() catch unreachable;
        const r0 = sample();
        @fence(.acq_rel);
        std.time.sleep(std.time.ns_per_ms * 200);
        @fence(.acq_rel);
        const t1 = std.time.Instant.now() catch unreachable;
        const r1 = sample();
        @fence(.acq_rel);

        const dt = t1.since(t0);
        const dr = r1 - r0;

        time_scale = @as(f64, @floatFromInt(dt)) / (@as(f64, @floatFromInt(dr)) * 1000.0);
    } else {
        time_scale = 1.0 / 1000.0;
    }
}

pub fn deinit() void {
    dump() catch {};
    file.writeAll("\n]\n") catch {};
    file.close();

    // free memory
    for (&frame.tz) |*zones| zones.deinit(allocator);
    dump_buffer.deinit(allocator);
}

pub fn frameMark() void {
    frame.time_end = sample();

    // todo: jobified dump
    dump() catch {};

    const time = sample();
    frame.time_begin = time;
    frame.time_end = time;
    for (0..max_threads) |t| frame.tz[t].items.len = 0;
    frame_index += 1;
}

pub fn begin(comptime _: SourceLocation, name: [:0]const u8) ZoneScope {
    if (tmeta.id == 0) tmeta.id = tida.fetchAdd(1, .monotonic);
    const tid = tmeta.id;
    const depth = tmeta.depth;
    tmeta.depth += 1;
    return ZoneScope{
        .depth = depth,
        .tid = tid,
        // .src = src,
        .name = name,
        .time_begin = sample(),
    };
}

fn dump() !void {
    const time_dump = sample();

    dump_buffer.items.len = 0; // clear buffer
    const writer = dump_buffer.writer(allocator);

    if (frame_index != 0) try writer.writeAll(",\n");

    try writer.print(
        \\  {{ "name": "frame", "ph": "X", "pid": 0, "tid": 1, "ts": {}, "dur": {} }},
        \\
    , .{
        @as(f64, @floatFromInt(frame.time_begin - time_startup)) * time_scale,
        @as(f64, @floatFromInt(frame.time_end - frame.time_begin)) * time_scale,
    });

    for (&frame.tz, 1..) |zones, tid| {
        var i = zones.items.len -% 1;
        while (i < zones.items.len) : (i -%= 1) {
            const zone = zones.items[i];
            try writer.print(
                \\  {{ "name": "{s}", "ph": "X", "pid": 0, "tid": {}, "ts": {}, "dur": {} }},
                \\
            , .{
                zone.name,
                tid,
                @as(f64, @floatFromInt(zone.time_begin - time_startup)) * time_scale,
                @as(f64, @floatFromInt(zone.time_end - zone.time_begin)) * time_scale,
            });
        }
    }

    // write and fush the buffer contents in here ti the get a more acurate time mesure of this operation
    try file.writeAll(dump_buffer.items);
    try file.sync();

    const t_end = sample();
    try file.writer().print(
        \\  {{ "name": "dump", "ph": "X", "pid": 0, "tid": 1, "ts": {}, "dur": {} }}
    , .{
        @as(f64, @floatFromInt(time_dump - time_startup)) * time_scale,
        @as(f64, @floatFromInt(t_end - time_dump)) * time_scale,
    });
}
