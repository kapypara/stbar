const std = @import("std");
const builtin = @import("builtin");

/// Bitwise selection: (ifTrue & -condition) | (ifFalse & ~(-condition))
/// In Zig, we cast the bool to a integer to create the mask.
fn bitSelect(condition: bool, ifTrue: u8, ifFalse: u8) u8 {
    const mask = if (@intFromBool(condition) == 1) @as(u8, 0xFF) else @as(u8, 0);
    return (ifTrue & mask) | (ifFalse & ~mask);
}

pub fn toBCD(binary_num: u64) u64 {
    if (comptime builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        var bcd: [10]u8 align(16) = @splat(0);
        var num: i64 = @intCast(@min(binary_num, std.math.maxInt(i64)));

        // Using x86 inline assembly for FBSTP (FPU BCD Store and Pop).
        // `bcd` must be an output memory operand so LLVM sees the write.
        asm volatile (
            \\ fildq (%[num])
            \\ fbstp (%[bcd])
            :
            : [bcd] "r" (&bcd),
              [num] "r" (&num),
            : .{ .memory = true, .st0 = true, .fpsr = true }
        );

        return std.mem.readInt(u64, bcd[0..8], .little);
    } else {
        var n = binary_num;
        var bcd: u64 = 0;
        var shift: u6 = 0;
        while (n != 0 and shift <= 60) : (shift += 4) {
            bcd |= (n % 10) << shift;
            n /= 10;
            if (shift == 60) break;
        }
        return bcd;
    }
}

pub fn fromBCD(bcd_num_in: u64) u64 {
    var bcd_num = bcd_num_in;
    var binary: u64 = 0;
    var digit_place: u64 = 1;
    while (bcd_num != 0) : ({
        digit_place *= 10;
        bcd_num >>= 4;
    }) {
        binary += (bcd_num & 0xf) * digit_place;
    }
    return binary;
}

pub fn cpuUsage(input: u64) [3]u8 {
    var buffer: [3]u8 = undefined;
    const digits = toBCD(input);

    buffer[2] = @intCast(digits & 0xf);
    buffer[2] += bitSelect(digits > 0, '0', '-');

    buffer[1] = @intCast((digits >> 4) & 0xf);
    buffer[1] += bitSelect(digits > 0, '0', '-');

    buffer[0] = bitSelect(digits > 0xff, '1', ' ');
    
    return buffer;
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

    const digits = toBCD(input);
    const d0: u8 = @intCast((digits & 0xf) + '0');
    const d1: u8 = @intCast(((digits >> 4) & 0xf) + '0');
    const d2: u8 = @intCast(((digits >> 8) & 0xf) + '0');

    if (((digits >> 12) & 0xff) != 0) {
        result.buf[0] = @intCast(((digits >> 16) & 0xf) + '0');
        result.buf[1] = @intCast(((digits >> 12) & 0xf) + '0');
        // result.buf[2] stays '\n' to preserve the static ',' glyph
        result.buf[3] = d2;
        result.buf[4] = d1;
        result.buf[5] = d0;
        result.len = 6;
    } else {
        // Low-memory warning icons (U+E017, U+E018) encoded as valid UTF-8 + '\n' comma skip
        const prefix = "\u{e017}\u{e018}\n";
        @memcpy(result.buf[0..prefix.len], prefix);
        result.buf[7] = d2;
        result.buf[8] = d1;
        result.buf[9] = d0;
        result.len = 10;
    }
    return result;
}

pub fn systemLoad(input: u64) [5]u8 {
    var buffer: [5]u8 = undefined;
    @memset(&buffer, '\n');

    const digits = toBCD(input);

    buffer[4] = @intCast((digits & 0xf) + '0');
    buffer[3] = @intCast(((digits >> 4) & 0xf) + '0');
    buffer[1] = @intCast(((digits >> 8) & 0xf) + '0');

    const first_digit: u8 = @intCast((digits >> 12) & 0xf);
    buffer[0] = first_digit + (if (first_digit != 0) @as(u8, '0') else @as(u8, ' '));

    return buffer;
}

pub fn freeSpace(input_raw: u64) [8]u8 {
    var buffer: [8]u8 = undefined;
    @memset(&buffer, '\n');

    const input = ((input_raw >> 20) * 1000) >> 10;
    const digits = toBCD(input);

    // Logic for leading zero suppression using '\2' special char
    const d0: u8 = @intCast((digits >> 24) & 0xf);
    buffer[0] = d0 + bitSelect(d0 == 0, '\x02', '0');

    const d1: u8 = @intCast((digits >> 20) & 0xf);
    buffer[1] = d1 + bitSelect(d1 == 0 and buffer[0] == '\x02', '\x02', '0');

    const d2: u8 = @intCast((digits >> 16) & 0xf);
    buffer[2] = d2 + bitSelect(d2 == 0 and buffer[1] == '\x02', '\x02', '0');

    const d3: u8 = @intCast((digits >> 12) & 0xf);
    buffer[3] = d3 + bitSelect(d3 == 0 and buffer[2] == '\x02', '\x02', '0');

    buffer[5] = @intCast(((digits >> 8) & 0xf) + '0');
    buffer[6] = @intCast(((digits >> 4) & 0xf) + '0');
    buffer[7] = @intCast((digits & 0xf) + '0');

    return buffer;
}

pub fn generic(num_in: u64) [6]u8 {
    var buffer: [6]u8 = undefined;
    @memset(&buffer, '\n');

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

    const digits = toBCD(num);
    buffer[5] = suffix;
    buffer[4] = @intCast((digits & 0xf) + '0');
    buffer[2] = @intCast(((digits >> 4) & 0xf) + '0');
    buffer[1] = @intCast(((digits >> 8) & 0xf) + '0');
    buffer[0] = @intCast(((digits >> 12) & 0xf) + '0');

    return buffer;
}

const NoneStruct = struct {
    buf: [21]u8,
    len: usize,
};

pub fn none(input: u64) NoneStruct {

    var result: NoneStruct = .{
        .buf = undefined,
        .len = undefined,
    };

    // Converts to standard decimal string then to u8 slice
    const str = std.fmt.bufPrint(&result.buf, "{d: >2}", .{input}) catch "--";
    result.len = str.len;

    return result;
}

test "BCD roundtrip and metric formatters" {
    try std.testing.expectEqual(@as(u64, 19072), fromBCD(toBCD(19072)));

    try std.testing.expectEqualStrings(" --", &cpuUsage(0));
    try std.testing.expectEqualStrings(" 13", &cpuUsage(13));
    try std.testing.expectEqualStrings("100", &cpuUsage(100));

    const mem_hi = memory(19072);
    try std.testing.expectEqualStrings("19\n072", mem_hi.slice());
    try std.testing.expectEqual(@as(usize, 6), try std.unicode.utf8CountCodepoints(mem_hi.slice()));

    const mem_lo = memory(512);
    try std.testing.expectEqualStrings("\u{e017}\u{e018}\n512", mem_lo.slice());
    try std.testing.expectEqual(@as(usize, 6), try std.unicode.utf8CountCodepoints(mem_lo.slice()));

    try std.testing.expectEqualStrings(" 1\n34", &systemLoad(134));
    try std.testing.expectEqualStrings("000\n0B", &generic(0));
}
