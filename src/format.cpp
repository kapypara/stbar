#include "format.h"

// #define bitTest(cond, ifTrue, ifFalse) (((ifTrue) * (cond)) | ((ifFalse) * !(cond)))
template <typename C, typename T>
inline constexpr T bitSelect(C condition, T ifTrue, T ifFalse){

    return (ifTrue & -condition) | (ifFalse & ~(-condition));
}

inline u64 format::toBCD(u64 binary_num){

    u64 bcd = 0;

#if 1

    u8 bcd_arr[10];
    double a = binary_num;

    asm("fbstp %0" : "=m" (bcd_arr[0]) : "t" (a) : "st");

    bcd = * reinterpret_cast<u64*>(bcd_arr);

#else

    for (u8 digit_bits=0; binary_num != 0; digit_bits+=4){

        auto const digit = std::ldiv(binary_num, 10);

        bcd |= digit.rem << digit_bits;

        binary_num = digit.quot;
    }
#endif

    return bcd;
}

inline constexpr u64 format::fromBCD(u64 bcd_num){

    u64 binary = 0;

    for (u64 digit_place=1; bcd_num != 0; digit_place*=10){

        binary += (bcd_num & 0xf) * digit_place;

        bcd_num >>= 4;
    }

    return binary;
}

std::u16string format::cpu_useage(u64 input) {

    std::u16string buffer(3, '\n');

    u64 digits = toBCD(input);
    
    buffer[2]  = digits & 0xf;
    buffer[2] += bitSelect(digits > 0, u'0', u'-');

    buffer[1]  = (digits>>4) & 0xf;
    buffer[1] += bitSelect(digits > 0, u'0', u'-');

    buffer[0]  = bitSelect(digits > 0xff, u'1', u' ');

    return buffer;
}

std::u16string format::memory(u64 input) {

    std::u16string buffer(6, '\n');

    u64 digits = toBCD(input);

    buffer[5] = (digits & 0xf) + u'0';
    buffer[4] = ((digits>>4) & 0xf) + u'0';
    buffer[3] = ((digits>>8) & 0xf) + u'0';
    // [2] comma digit , skipping

    if ((digits>>12) & 0xff) { [[likely]]
        buffer[1] = ((digits>>12) & 0xf) + u'0';
        buffer[0] = ((digits>>16) & 0xf) + u'0';
    } else {
        // special characters used as a warning
        buffer[1] = 0xe018;
        buffer[0] = 0xe017;
    }

    return buffer;
}

std::u16string format::system_load(u64 input) {

    std::u16string buffer(5, '\n');

    u64 digits = toBCD(input);

    buffer[4] = (digits & 0xf) + u'0';
    buffer[3] = ((digits>>4) & 0xf) + u'0';
    // [2] dot digit . skipping
    buffer[1] = ((digits>>8) & 0xf) + u'0';

    buffer[0] = ((digits>>12) & 0xf);
    buffer[0] += buffer[0] ? u'0' : u' ';

    return buffer;
}

std::u16string format::free_space(u64 input) {

    std::u16string buffer(8, '\n');

    input = ((input>>20)*1000)>>10;

    u64 const digits = toBCD(input);

    // digit set to 0x2 if digit is zero and previous digit is also zero
    // if previous digit is zero it would have 0x2 value
    // 0x2 is uesd in the font as a special characters
    buffer[0] = ((digits>>24) & 0xf);
    buffer[0] += bitSelect(buffer[0] == 0, u'\2', u'0');

    buffer[1] = ((digits>>20) & 0xf);
    buffer[1] += bitSelect(buffer[1] == 0 && buffer[0] == u'\2', u'\2', u'0');

    buffer[2] = ((digits>>16) & 0xf);
    buffer[2] += bitSelect(buffer[2] == 0 && buffer[1] == u'\2', u'\2', u'0');

    buffer[3] = ((digits>>12) & 0xf);
    buffer[3] += bitSelect(buffer[3] == 0 && buffer[2] == u'\2', u'\2', u'0');

    // [4] dot digit . skipping
    buffer[5] = ((digits>>8) & 0xf) + u'0';
    buffer[6] = ((digits>>4) & 0xf) + u'0';
    buffer[7] = (digits & 0xf) + u'0';


    return buffer;
}

/*
std::string format::generic(u64 num){
    char buffer[7];  // the output will look like "015.6M" so six characters and a null byte.

    if( num < 1e3 )
        std::snprintf(buffer, sizeof buffer, "%05.1fB", (float)num);
    else if( num < 1e6 )
        std::snprintf(buffer, sizeof buffer, "%05.1fK", (float)num/1024.f);
    else if( num < 1e9 )
        std::snprintf(buffer, sizeof buffer, "%05.1fM", (float)(num>>10)/1024.f);
    else if( num < 1e12 )
        std::snprintf(buffer, sizeof buffer, "%05.1fG", (float)(num>>20)/1024.f);
    else if( num < 1e15 )
        std::snprintf(buffer, sizeof buffer, "%05.1fT", (float)(num>>30)/1024.f);
    else if( num < 1e18 )
        std::snprintf(buffer, sizeof buffer, "%05.1fP", (float)(num>>40)/1024.f);
    else
        std::snprintf(buffer, sizeof buffer, "%05.1fE", (float)(num>>50)/1024.f);

    return buffer;
}
/**/

    #include <iostream>
std::u16string format::generic(u64 num){

    // the output will look like "015.6M"
    // buffer[3] will not be touch since dot(.) don't need to change.
    std::u16string buffer(6, '\n');

    // buffer[3]= '.';
    // std::cout << num << " -> ";

    switch(num){
        case 0 ... 999:
            num = num*10;
            buffer[5] = 'B';
            break;

        case 1000 ... 999999:
            num = num*10>>10;
            buffer[5] = 'K';
            break;

        case 1000000 ... 999999999:
            num = (num>>10)*10>>10;
            buffer[5] = 'M';
            break;

        case 1000000000 ... 999999999999:
            num = (num>>20)*10>>10;
            buffer[5] = 'G';
            break;

        case 1000000000000 ... 999999999999999:
            num = (num>>30)*10>>10;
            buffer[5] = 'T';
            break;

        case 1000000000000000 ... 999999999999999999:
            num = (num>>40)*10>>10;
            buffer[5] = 'P';
            break;

        default:
            num = (num>>50)*10>>10;
            buffer[5] = 'E';
    }

    u64 digits = toBCD(num);

    buffer[4] = (digits & 0xf) + u'0';
    // [3] skipping dot
    buffer[2] = ((digits>>4) & 0xf) + u'0';
    buffer[1] = ((digits>>8) & 0xf) + u'0';
    buffer[0] = ((digits>>12) & 0xf) + u'0';

    // std::cout << std::string{buffer.begin(), buffer.end()} << '\n';

    return buffer;
}
/**/

std::u16string format::none(u64 input) {

    const auto temp = std::to_string(input);
    return {temp.begin(), temp.end()};
}
