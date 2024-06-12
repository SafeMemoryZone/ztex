const std = @import("std");
const ncurses = @cImport({
    @cInclude("ncurses.h");
});
const editor = @import("editor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    defer {
        _ = gpa.detectLeaks();
        _ = gpa.deinit();
    }

    var e: editor.Editor = try editor.Editor.init(gpa.allocator());
    defer e.deinit();

    const args = try std.process.argsAlloc(gpa.allocator());
    defer std.process.argsFree(gpa.allocator(), args);

    if (args.len >= 2) {
        try e.load_file_to_buf(args[1]);
        e.render_main_win();
    }

    var key: c_int = 0;

    while (true) {
        key = ncurses.wgetch(e.main_win);
        try e.handle_key(key);
        e.render_main_win();

        if (try e.check_quit())
            break;
    }
}
