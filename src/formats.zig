const std = @import("std");

/// Bitwise selection: (ifTrue & -condition) | (ifFalse & ~(-condition))
/// In Zig, we cast the bool to a integer to create the mask.
fn bitSelect(condition: bool, ifTrue: u16, ifFalse: u16) u16 {
    const mask = if (@intFromBool(condition) == 1) @as(u16, 0xFFFF) else @as(u16, 0);
    return (ifTrue & mask) | (ifFalse & ~mask);
}

pub fn toBCD(binary_num: u64) u64 {
    var bcd: [10]u8 align(16) = [_]u8{0} ** 10;
    
    // Using x86 inline assembly for the FBSTP (FPU BCD Store and Pop)
    // This matches the logic of the original fildq/fbstp block.
    asm volatile (
        \\ fildq %[num]
        \\ fbstp %[bcd]
        :
        : [bcd] "*m" (&bcd),
          [num] "*m" (&binary_num),
    );

    // Return the first 8 bytes as a u64
    return @as(*align(1) const u64, @ptrCast(&bcd)).*;
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

pub fn cpuUsage(allocator: std.mem.Allocator, input: u64) ![]u16 {
    var buffer = try allocator.alloc(u16, 3);
    const digits = toBCD(input);

    buffer[2] = @intCast(digits & 0xf);
    buffer[2] += bitSelect(digits > 0, '0', '-');

    buffer[1] = @intCast((digits >> 4) & 0xf);
    buffer[1] += bitSelect(digits > 0, '0', '-');

    buffer[0] = bitSelect(digits > 0xff, '1', ' ');
    return buffer;
}

pub fn memory(allocator: std.mem.Allocator, input: u64) ![]u16 {
    var buffer = try allocator.alloc(u16, 6);
    @memset(buffer, '\n'); // Keep original behavior of '\n' padding
    
    const digits = toBCD(input);

    buffer[5] = @intCast((digits & 0xf) + '0');
    buffer[4] = @intCast(((digits >> 4) & 0xf) + '0');
    buffer[3] = @intCast(((digits >> 8) & 0xf) + '0');

    if (((digits >> 12) & 0xff) != 0) {
        buffer[1] = @intCast(((digits >> 12) & 0xf) + '0');
        buffer[0] = @intCast(((digits >> 16) & 0xf) + '0');
    } else {
        // Warning characters
        buffer[1] = 0xe018;
        buffer[0] = 0xe017;
    }
    return buffer;
}

pub fn systemLoad(allocator: std.mem.Allocator, input: u64) ![]u16 {
    var buffer = try allocator.alloc(u16, 5);
    @memset(buffer, '\n');

    const digits = toBCD(input);

    buffer[4] = @intCast((digits & 0xf) + '0');
    buffer[3] = @intCast(((digits >> 4) & 0xf) + '0');
    buffer[1] = @intCast(((digits >> 8) & 0xf) + '0');

    const first_digit: u16 = @intCast((digits >> 12) & 0xf);
    buffer[0] = first_digit + (if (first_digit != 0) @as(u16, '0') else @as(u16, ' '));

    return buffer;
}

pub fn freeSpace(allocator: std.mem.Allocator, input_raw: u64) ![]u16 {
    var buffer = try allocator.alloc(u16, 8);
    @memset(buffer, '\n');

    const input = ((input_raw >> 20) * 1000) >> 10;
    const digits = toBCD(input);

    // Logic for leading zero suppression using '\2' special char
    const d0: u16 = @intCast((digits >> 24) & 0xf);
    buffer[0] = d0 + bitSelect(d0 == 0, '\x02', '0');

    const d1: u16 = @intCast((digits >> 20) & 0xf);
    buffer[1] = d1 + bitSelect(d1 == 0 and buffer[0] == '\x02', '\x02', '0');

    const d2: u16 = @intCast((digits >> 16) & 0xf);
    buffer[2] = d2 + bitSelect(d2 == 0 and buffer[1] == '\x02', '\x02', '0');

    const d3: u16 = @intCast((digits >> 12) & 0xf);
    buffer[3] = d3 + bitSelect(d3 == 0 and buffer[2] == '\x02', '\x02', '0');

    buffer[5] = @intCast(((digits >> 8) & 0xf) + '0');
    buffer[6] = @intCast(((digits >> 4) & 0xf) + '0');
    buffer[7] = @intCast((digits & 0xf) + '0');

    return buffer;
}

pub fn generic(allocator: std.mem.Allocator, num_in: u64) ![]u16 {
    var buffer = try allocator.alloc(u16, 6);
    @memset(buffer, '\n');

    var num = num_in;
    var suffix: u16 = ' ';

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

pub fn none(allocator: std.mem.Allocator, input: u64) ![]u16 {
    // Converts to standard decimal string then to u16 slice
    var buf: [21]u8 = undefined;
    const str = try std.fmt.bufPrint(&buf, "{}", .{input});
    
    var result = try allocator.alloc(u16, str.len);
    for (str, 0..) |char, i| {
        result[i] = char;
    }
    return result;
}
