const std = @import("std");

inline fn extractDigits(comptime N: usize, value: u64) [N]u8 {
    var digits: [N]u8 = undefined;
    var v = value;
    inline for (0..N) |i| {
        digits[i] = @intCast(v % 10);
        v /= 10;
    }
    return digits;
}

pub fn cpuUsage(input: u64) [3]u8 {
    if (input == 0) return " --".*;
    if (input >= 100) return "100".*;

    const tens: u8 = @intCast(input / 10);
    const ones: u8 = @intCast(input % 10);
    return .{ ' ', '0' + tens, '0' + ones };
}

pub const MemoryString = struct {
    buf: [10]u8,
    len: usize,

    pub fn slice(self: *const MemoryString) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn memory(input: u64) MemoryString {
    var result: MemoryString = .{
        .buf = @splat('\n'),
        .len = 6,
    };

    if (input >= 1000) {
        const d = extractDigits(5, @min(input, 99_999));
        result.buf[0] = '0' + d[4];
        result.buf[1] = '0' + d[3];
        // result.buf[2] stays '\n' to preserve the static ',' glyph
        result.buf[3] = '0' + d[2];
        result.buf[4] = '0' + d[1];
        result.buf[5] = '0' + d[0];
        result.len = 6;
    } else {
        // Low-memory warning icons (U+E017, U+E018) + '\n' comma skip
        const d = extractDigits(3, input);
        const prefix = "\u{e017}\u{e018}\n";
        @memcpy(result.buf[0..prefix.len], prefix);
        result.buf[7] = '0' + d[2];
        result.buf[8] = '0' + d[1];
        result.buf[9] = '0' + d[0];
        result.len = 10;
    }
    return result;
}

pub fn systemLoad(input: u64) [5]u8 {
    const d = extractDigits(4, @min(input, 9999));
    return .{
        if (d[3] != 0) '0' + d[3] else ' ',
        '0' + d[2],
        '\n',
        '0' + d[1],
        '0' + d[0],
    };
}

pub fn freeSpace(input_raw: u64) [8]u8 {
    const scaled = ((input_raw >> 20) * 1000) >> 10;
    const d = extractDigits(7, @min(scaled, 9_999_999));

    // Leading-zero suppression using '\x02' Tamzen spacer glyph
    const b0: u8 = if (d[6] == 0) '\x02' else '0' + d[6];
    const b1: u8 = if (d[5] == 0 and b0 == '\x02') '\x02' else '0' + d[5];
    const b2: u8 = if (d[4] == 0 and b1 == '\x02') '\x02' else '0' + d[4];
    const b3: u8 = if (d[3] == 0 and b2 == '\x02') '\x02' else '0' + d[3];

    return .{
        b0,
        b1,
        b2,
        b3,
        '\n',
        '0' + d[2],
        '0' + d[1],
        '0' + d[0],
    };
}

pub fn generic(num_in: u64) [6]u8 {
    var num = num_in;
    var suffix: u8 = ' ';

    switch (num) {
        0...999 => {
            num = num * 10;
            suffix = 'B';
        },
        1000...999_999 => {
            num = (num * 10) >> 10;
            suffix = 'K';
        },
        1_000_000...999_999_999 => {
            num = ((num >> 10) * 10) >> 10;
            suffix = 'M';
        },
        1_000_000_000...999_999_999_999 => {
            num = ((num >> 20) * 10) >> 10;
            suffix = 'G';
        },
        1_000_000_000_000...999_999_999_999_999 => {
            num = ((num >> 30) * 10) >> 10;
            suffix = 'T';
        },
        1_000_000_000_000_000...999_999_999_999_999_999 => {
            num = ((num >> 40) * 10) >> 10;
            suffix = 'P';
        },
        else => {
            num = ((num >> 50) * 10) >> 10;
            suffix = 'E';
        },
    }

    const d = extractDigits(4, @min(num, 9999));
    return .{
        '0' + d[3],
        '0' + d[2],
        '0' + d[1],
        '\n',
        '0' + d[0],
        suffix,
    };
}

pub fn temperature(input: u64) [2]u8 {
    const clamped = @min(input, 99);
    const tens: u8 = @intCast(clamped / 10);
    const ones: u8 = @intCast(clamped % 10);
    return .{
        if (clamped >= 10) '0' + tens else ' ',
        '0' + ones,
    };
}

test "Pure integer metric formatters" {
    try std.testing.expectEqualStrings(" --", &cpuUsage(0));
    try std.testing.expectEqualStrings(" 05", &cpuUsage(5));
    try std.testing.expectEqualStrings(" 13", &cpuUsage(13));
    try std.testing.expectEqualStrings("100", &cpuUsage(100));

    const mem_hi = memory(19072);
    try std.testing.expectEqualStrings("19\n072", mem_hi.slice());
    try std.testing.expectEqual(@as(usize, 6), try std.unicode.utf8CountCodepoints(mem_hi.slice()));

    const mem_100g = memory(100_000);
    try std.testing.expectEqualStrings("99\n999", mem_100g.slice());

    const mem_lo = memory(512);
    try std.testing.expectEqualStrings("\u{e017}\u{e018}\n512", mem_lo.slice());
    try std.testing.expectEqual(@as(usize, 6), try std.unicode.utf8CountCodepoints(mem_lo.slice()));

    try std.testing.expectEqualStrings(" 1\n34", &systemLoad(134));
    try std.testing.expectEqualStrings("12\n34", &systemLoad(1234));
    try std.testing.expectEqualStrings("000\n0B", &generic(0));
    try std.testing.expectEqualStrings(" 9", &temperature(9));
    try std.testing.expectEqualStrings("54", &temperature(54));
}
