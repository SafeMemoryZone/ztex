const std = @import("std");

pub const GapBuffer = struct {
    gap_len: usize,
    buf: []u8,
    alloc: std.mem.Allocator,

    gap_begin_idx: usize = 0,
    pos_idx: usize = 0,

    pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!GapBuffer {
        const buffer = try allocator.alloc(u8, 1);
        return GapBuffer{ .gap_len = 1, .buf = buffer, .alloc = allocator };
    }

    pub fn deinit(self: *GapBuffer) void {
        self.alloc.free(self.buf);
    }

    pub fn insert(self: *GapBuffer, char: u8) std.mem.Allocator.Error!void {
        if (self.gap_len == 0) {
            try self.expand_gap();
        }

        self.move_gap_to_cursor();
        self.buf[self.pos_idx] = char;
        self.gap_begin_idx += 1;
        self.gap_len -= 1;
    }

    pub fn load_text(self: *GapBuffer, text: []const u8) std.mem.Allocator.Error!void {
        if (text.len != self.buf.len) {
            self.alloc.free(self.buf);
            self.buf = try self.alloc.alloc(u8, text.len);
        }

        @memcpy(self.buf, text);
        self.gap_begin_idx = text.len;
        self.gap_len = 0;
    }

    pub fn delete(self: *GapBuffer) void {
        self.move_gap_to_cursor();
        self.gap_begin_idx -= 1;
        self.gap_len += 1;
    }

    pub fn set_pos_idx(self: *GapBuffer, idx: usize) void {
        if (idx < self.gap_begin_idx) {
            self.pos_idx = idx;
        } else {
            self.pos_idx = idx + self.gap_len;
        }
    }

    fn expand_gap(self: *GapBuffer) std.mem.Allocator.Error!void {
        std.debug.assert(self.gap_len == 0);

        const text_size = self.buf.len - self.gap_len;

        const new_gap_len = (self.gap_len + 1) * 2;

        var new_buf = try self.alloc.alloc(u8, text_size + new_gap_len);
        @memcpy(new_buf[0..self.pos_idx], self.buf[0..self.pos_idx]);
        @memcpy(new_buf[self.pos_idx + new_gap_len ..], self.buf[self.pos_idx..]);

        self.alloc.free(self.buf);
        self.gap_begin_idx = self.pos_idx;
        self.gap_len = new_gap_len;
        self.buf = new_buf;
    }

    fn move_gap_to_cursor(self: *GapBuffer) void {
        if (self.gap_begin_idx == self.pos_idx) {
            return;
        }

        if (self.pos_idx > self.gap_begin_idx) {
            const gap_end_idx = self.gap_begin_idx + self.gap_len;
            const diff = self.pos_idx - gap_end_idx;
            std.mem.copyForwards(u8, self.buf[self.gap_begin_idx .. self.gap_begin_idx + diff], self.buf[gap_end_idx .. gap_end_idx + diff]);
            self.gap_begin_idx = self.gap_begin_idx + diff;
            self.pos_idx = self.gap_begin_idx;
        } else {
            const diff = self.gap_begin_idx - self.pos_idx;
            const save_pos = self.pos_idx + self.gap_len;
            std.mem.copyBackwards(u8, self.buf[save_pos .. save_pos + diff], self.buf[self.pos_idx .. self.pos_idx + diff]);
            self.gap_begin_idx = self.pos_idx;
        }
    }
};
