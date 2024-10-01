const P = @import("profiler");
const std = @import("std");

pub fn main() !void {
    P.init(.{});
    defer {
        P.dump("profile.json") catch |err| std.log.err("profile dump failed: {}", .{err});
        P.deinit();
    }

    const zone = P.begin(@src(), "main_fn");
    defer zone.end();

    // ... your code
    var sum: f64 = 1;
    for (0..10000) |_| {
        sum *= 3.1215;
    }
}
