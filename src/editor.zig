const std = @import("std");
const gap_buf = @import("gap_buffer.zig");
const ncurses = @cImport({
    @cInclude("ncurses.h");
});

fn is_valid_char(key: c_int) bool {
    return key >= ' ' and key <= '~' or key == '\n';
}

fn is_delete(key: c_int) bool {
    return key == ncurses.KEY_BACKSPACE or key == 8 or key == 127;
}

fn ctrl(key: c_int) c_int {
    return key & 0x1f;
}

const LineMap = struct {
    lines: []Line,
    alloc: std.mem.Allocator,

    append_idx: usize = 0,

    const Line = struct {
        begin_idx: usize,
        len: usize,
    };

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!LineMap {
        return LineMap{ .lines = try allocator.alloc(Line, 1), .alloc = allocator };
    }

    pub fn deinit(self: *LineMap) void {
        self.alloc.free(self.lines);
    }

    pub fn reset(self: *LineMap) void {
        self.append_idx = 0;
    }

    pub fn add(self: *LineMap, begin_idx: usize, len: usize) std.mem.Allocator.Error!void {
        if (self.append_idx >= self.lines.len) {
            self.lines = try self.alloc.realloc(self.lines, self.lines.len * 2);
        }

        self.lines[self.append_idx] = Line{ .begin_idx = begin_idx, .len = len };
        self.append_idx += 1;
    }

    pub fn get_last_ln_added(self: *LineMap) *Line {
        return &self.lines[self.append_idx - 1];
    }
};

pub const Editor = struct {
    main_win: *ncurses.WINDOW,
    buf_win: *ncurses.WINDOW,
    buf: gap_buf.GapBuffer,
    alloc: std.mem.Allocator,
    ln_map: LineMap,

    pos_idx: usize = 0,
    target_pos_x: ?usize = null,
    orig_file_path: ?[]const u8 = null,
    orig_file_content: ?[]const u8 = null,
    requested_quit: bool = false,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!Editor {
        _ = ncurses.initscr();
        _ = ncurses.noecho();
        _ = ncurses.raw();

        const e = Editor{
            .buf = try gap_buf.GapBuffer.init(allocator),
            .alloc = allocator,
            .main_win = ncurses.newwin(ncurses.LINES - 1, ncurses.COLS, 0, 0).?,
            .buf_win = ncurses.newwin(1, ncurses.COLS, ncurses.LINES - 1, 0).?,
            .ln_map = try LineMap.init(allocator),
        };

        _ = ncurses.keypad(e.main_win, true);
        _ = ncurses.keypad(e.buf_win, true);
        _ = ncurses.box(e.buf_win, '8', '*');
        _ = ncurses.refresh();

        return e;
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit();

        if (self.orig_file_content) |c| {
            self.alloc.free(c);
        }

        self.ln_map.deinit();

        _ = ncurses.delwin(self.main_win);
        _ = ncurses.delwin(self.buf_win);
        _ = ncurses.endwin();
    }

    pub fn handle_key(self: *Editor, key: c_int) std.mem.Allocator.Error!void {
        var found = true;
        switch (key) {
            ncurses.KEY_LEFT => self.handle_key_left(),
            ncurses.KEY_RIGHT => self.handle_key_right(),
            ncurses.KEY_UP => self.handle_key_up(),
            ncurses.KEY_DOWN => self.handle_key_down(),
            ctrl('q') => self.requested_quit = true,
            else => found = false,
        }
        if (found) {
            return;
        }
        if (is_delete(key)) {
            try self.handle_delete();
        } else if (is_valid_char(key)) {
            try self.handle_insert(@intCast(key));
        }
    }

    pub fn load_file_to_buf(self: *Editor, file_path: []const u8) !void {
        const content = try std.fs.cwd().readFileAlloc(self.alloc, file_path, 1_000_000_000);
        self.orig_file_content = content;
        self.orig_file_path = file_path;
        try self.buf.load_text(content);
        try self.report_change();
    }

    pub fn save_buf_to(self: *Editor, file: std.fs.File) !void {
        const gbuf = self.buf;
        const after_gap_idx = gbuf.gap_begin_idx + gbuf.gap_len;

        try file.writeAll(gbuf.buf[0..gbuf.gap_begin_idx]);
        try file.writeAll(gbuf.buf[after_gap_idx..]);
    }

    pub fn render_main_win(self: *Editor) void {
        const gbuf = self.buf;

        if (gbuf.buf.len - gbuf.gap_len == 0) {
            _ = ncurses.wclear(self.main_win);
            _ = ncurses.wrefresh(self.main_win);
            return;
        }

        const n_lines = @as(usize, @intCast(ncurses.LINES - 1));

        const curr_ln = self.get_curr_ln();
        const y_pos: usize = curr_ln.@"1";
        const x_pos = self.pos_idx - curr_ln.@"0".begin_idx;

        const lines_before: usize = @min(@divFloor(n_lines, 2), y_pos);
        const lines_after_and_curr: usize = @min(n_lines - lines_before, self.ln_map.append_idx - y_pos);

        const start_ln_idx = y_pos - lines_before;
        const end_ln_idx = y_pos + lines_after_and_curr - 1;

        const start_idx = self.ln_map.lines[start_ln_idx].begin_idx;
        var end_idx = self.ln_map.lines[end_ln_idx].begin_idx + self.ln_map.lines[end_ln_idx].len - 1;

        if (end_ln_idx == self.ln_map.append_idx - 1) {
            end_idx -= 1;
        }

        var remaining_len = end_idx - start_idx + 1;

        _ = ncurses.wclear(self.main_win);
        _ = ncurses.move(0, 0);

        if (start_idx < gbuf.gap_begin_idx) {
            const arr = @as([*c]const u8, @ptrCast(gbuf.buf));
            const len_to_print = @min(gbuf.gap_begin_idx - start_idx, remaining_len);
            _ = ncurses.wprintw(self.main_win, "%.*s", len_to_print, arr + start_idx);
            remaining_len -= len_to_print;
        }

        if (remaining_len > 0) {
            const arr = @as([*c]const u8, @ptrCast(&gbuf.buf[gbuf.gap_begin_idx + gbuf.gap_len]));
            _ = ncurses.wprintw(self.main_win, "%.*s", remaining_len, arr);
        }

        const cursor_y = @min(@divFloor(n_lines, 2), y_pos);
        _ = ncurses.wmove(self.main_win, @intCast(cursor_y), @intCast(x_pos));
        _ = ncurses.wrefresh(self.main_win);
    }

    pub fn check_quit(self: *Editor) !bool {
        if (!self.requested_quit) {
            return false;
        }

        if (self.orig_file_path == null) {
            const res = try self.start_filename_prompt();
            if (!res) {
                _ = ncurses.wclear(self.buf_win);
                _ = ncurses.wrefresh(self.buf_win);
                self.render_main_win();
            }
            return res;
        }

        if (!self.did_modify_file()) {
            return true;
        }

        _ = ncurses.wclear(self.buf_win);
        _ = ncurses.mvwprintw(self.buf_win, 0, 0, "save changes (y/n) > ");
        _ = ncurses.wrefresh(self.buf_win);

        const char = ncurses.wgetch(self.buf_win);

        if (char == 'y') {
            const f = try std.fs.cwd().openFile(self.orig_file_path.?, .{});
            defer f.close();
            try self.save_buf_to(f);
            return true;
        }

        if (char == 'n') {
            return true;
        }

        self.requested_quit = false;

        _ = ncurses.wclear(self.buf_win);
        _ = ncurses.wrefresh(self.buf_win);
        self.render_main_win();

        return false;
    }

    fn start_filename_prompt(self: *Editor) !bool {
        var gbuf = try gap_buf.GapBuffer.init(self.alloc);
        defer gbuf.deinit();

        var pos_idx: usize = 0;
        var key: c_int = 0;

        _ = ncurses.wclear(self.buf_win);
        _ = ncurses.mvwprintw(self.buf_win, 0, 0, "filename > ");
        _ = ncurses.wrefresh(self.buf_win);

        while (true) {
            key = ncurses.wgetch(self.buf_win);
            var found = true;

            switch (key) {
                ncurses.KEY_LEFT => {
                    if (pos_idx > 0) {
                        pos_idx -= 1;
                    }
                },
                ncurses.KEY_RIGHT => {
                    if (pos_idx < gbuf.buf.len - gbuf.gap_len) {
                        pos_idx += 1;
                    }
                },
                ctrl('q') => break,
                '\n' => {
                    if (gbuf.buf.len - gbuf.gap_len == 0) {
                        self.requested_quit = false;
                        return false;
                    }

                    var file_path = try self.alloc.alloc(u8, gbuf.buf.len - gbuf.gap_len);
                    defer self.alloc.free(file_path);

                    const gap_end_idx: usize = gbuf.gap_begin_idx + gbuf.gap_len;
                    @memcpy(file_path[0..gbuf.gap_begin_idx], gbuf.buf[0..gbuf.gap_begin_idx]);
                    @memcpy(file_path[gbuf.gap_begin_idx..], gbuf.buf[gap_end_idx..]);

                    const f = try std.fs.cwd().createFile(file_path, .{});
                    defer f.close();

                    try self.save_buf_to(f);

                    return true;
                },
                else => found = false,
            }

            if (!found) {
                if (is_delete(key)) {
                    if (pos_idx > 0) {
                        gbuf.set_pos_idx(pos_idx);
                        gbuf.delete();
                        pos_idx -= 1;
                    }
                } else if (is_valid_char(key)) {
                    gbuf.set_pos_idx(pos_idx);
                    try gbuf.insert(@intCast(key));
                    pos_idx += 1;
                } else {
                    self.requested_quit = false;
                    return false;
                }
            }

            const p1 = gbuf.buf[0..gbuf.gap_begin_idx];
            const p2 = gbuf.buf[gbuf.gap_begin_idx + gbuf.gap_len ..];
            const x = pos_idx + 11;

            _ = ncurses.wclear(self.buf_win);
            _ = ncurses.mvwprintw(self.buf_win, 0, 0, "filename > ");
            _ = ncurses.wprintw(self.buf_win, "%.*s", p1.len, @as([*c]const u8, @ptrCast(p1)));
            _ = ncurses.wprintw(self.buf_win, "%.*s", p2.len, @as([*c]const u8, @ptrCast(p2)));
            _ = ncurses.wmove(self.buf_win, 0, @intCast(x));
            _ = ncurses.wrefresh(self.buf_win);
        }

        return true;
    }

    fn did_modify_file(self: *Editor) bool {
        const gbuf = self.buf;
        if (self.orig_file_content) |c| {
            const after_gap_idx = gbuf.gap_begin_idx + gbuf.gap_len;

            if (gbuf.buf.len - gbuf.gap_len != c.len)
                return true;

            const p1_match = std.mem.eql(u8, gbuf.buf[0..gbuf.gap_begin_idx], c[0..gbuf.gap_begin_idx]);
            const p2_match = std.mem.eql(u8, gbuf.buf[after_gap_idx..], c[gbuf.gap_begin_idx..]);

            return !(p1_match and p2_match);
        }
        return false;
    }

    fn handle_insert(self: *Editor, char: u8) std.mem.Allocator.Error!void {
        self.buf.set_pos_idx(self.pos_idx);
        try self.buf.insert(char);
        self.pos_idx += 1;
        try self.report_change();
    }

    fn handle_delete(self: *Editor) std.mem.Allocator.Error!void {
        if (self.pos_idx == 0) {
            return;
        }

        self.buf.set_pos_idx(self.pos_idx);
        self.buf.delete();
        self.pos_idx -= 1;
        try self.report_change();
    }

    fn handle_key_left(self: *Editor) void {
        if (self.pos_idx > 0) {
            self.pos_idx -= 1;
            self.target_pos_x = null;
        }
    }

    fn handle_key_right(self: *Editor) void {
        const gbuf = self.buf;
        if (self.pos_idx < gbuf.buf.len - gbuf.gap_len) {
            self.pos_idx += 1;
            self.target_pos_x = null;
        }
    }

    fn handle_key_up(self: *Editor) void {
        const curr_ln = self.get_curr_ln();
        const x = if (self.target_pos_x) |t| t else self.pos_idx - curr_ln.@"0".begin_idx;
        var prev_ln: ?*LineMap.Line = null;

        for (self.ln_map.lines[0..curr_ln.@"1"]) |*ln| {
            prev_ln = ln;
        }

        if (prev_ln == null) {
            return;
        }

        self.pos_idx = prev_ln.?.begin_idx + x;

        if (self.pos_idx >= prev_ln.?.begin_idx + prev_ln.?.len) {
            self.pos_idx = prev_ln.?.begin_idx + prev_ln.?.len - 1;
            self.target_pos_x = x;
        }
    }

    fn handle_key_down(self: *Editor) void {
        const curr_ln = self.get_curr_ln();
        const x = if (self.target_pos_x) |t| t else self.pos_idx - curr_ln.@"0".begin_idx;
        var next_ln: ?*LineMap.Line = null;

        for (self.ln_map.lines[0..self.ln_map.append_idx]) |*ln| {
            if (ln.begin_idx > self.pos_idx) {
                next_ln = ln;
                break;
            }
        }

        if (next_ln == null) {
            return;
        }

        self.pos_idx = next_ln.?.begin_idx + x;

        if (self.pos_idx >= next_ln.?.begin_idx + next_ln.?.len) {
            self.pos_idx = next_ln.?.begin_idx + next_ln.?.len - 1;
            self.target_pos_x = x;
        }
    }

    fn report_change(self: *Editor) std.mem.Allocator.Error!void {
        self.target_pos_x = null;
        try self.retokenize();
    }

    fn get_curr_ln(self: *Editor) struct { *LineMap.Line, usize } {
        const ls = struct { *LineMap.Line, usize };

        var curr_ln = ls{ &self.ln_map.lines[0], 0 };
        var idx: usize = 0;

        for (self.ln_map.lines[0..self.ln_map.append_idx]) |*ln| {
            if (ln.begin_idx <= self.pos_idx) {
                curr_ln = ls{ ln, idx };
                idx += 1;
            } else {
                break;
            }
        }

        return curr_ln;
    }

    fn retokenize(self: *Editor) std.mem.Allocator.Error!void {
        const gbuf = self.buf;
        var idx: usize = 0;

        self.ln_map.reset();
        try self.ln_map.add(0, 0);

        for (gbuf.buf[0..gbuf.gap_begin_idx]) |c| {
            const last_ln = self.ln_map.get_last_ln_added();
            last_ln.len += 1;
            if (c == '\n') {
                try self.ln_map.add(idx + 1, 0);
            }
            idx += 1;
        }

        for (gbuf.buf[gbuf.gap_begin_idx + gbuf.gap_len ..]) |c| {
            const last_ln = self.ln_map.get_last_ln_added();
            last_ln.len += 1;
            if (c == '\n') {
                try self.ln_map.add(idx + 1, 0);
            }
            idx += 1;
        }

        self.ln_map.get_last_ln_added().len += 1;
    }
};
