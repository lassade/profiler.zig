A capable 200 lines profiler. It features a very simple API, supports multiple threads and dumps to a profile in the [Trace Event Format](https://docs.google.com/document/d/1CvAClvFfyA5R-PhYUmn5OOQtYMH4h6I0nSsKchNAySU/preview#heading=h.yr4qxyxotyw)

*Keep in mind `profile.zig` has hard limits like `max_frames` and `max_threads`, this is done to cap the memory usage, you can increase or decrese them as nescesary to your project.

```zig
const P = if (enable_profiling) @import("profiler.zig") else @import("profiler_mock.zig");

pub fn main() !void {
    P.init(.{});
    defer {
        P.dump("profile.json") catch |err| log.err("profile dump failed: {}", .{err});
        P.deinit();
    }

    const zone = P.begin(@src(), "main_fn");
    defer zone.end();

    // ... your code
}
```