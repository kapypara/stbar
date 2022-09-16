#include <iostream>
#include <string>
#include "segments.h"

#include <iostream>

void segment::output::draw() {

    using std::cout;

    const std::string htop = "konsole -e htop &";
    const std::string unix_time = "cclip -i $(date +%s)";
    const std::string get_name_by_shell = "xdotool getwindowname `xdotool getactivewindow`";

    //cout << "%{l}%{A:cclip -i \"" + safe_string(window) + "\":} " + window + " %{A}";
    cout << "%{l}%{A:" + get_name_by_shell + " | cclip -i:} " + window_title + " %{A}";

    if (sound_button.test(std::memory_order_relaxed)) {
        cout << "%{r} %{B#CC71b8b3}%{A:line_out -s 0 & echo >/tmp/status_bar/sound:}  %{A}";
    } else {
        cout << "%{r} %{B#CC71b8b3}%{A:line_out -s 1 & echo >/tmp/status_bar/sound:}  %{A}";
    }

    cout << "%{B#CC54A64B}%{A:usb-restart &:} " + net_rx + " " + net_tx + " %{A}";

    cout << "%{B#CC944BA6}%{A:dolphin &:} " + io_read + " " + io_write + " " + mem_dirty + " " + space_free + "G %{A}";

    cout << "%{B#CCA6974C}%{A:screenfix &:} " + load + " " + temp + " %{A}";

    cout << "%{B#CCA65353}%{A:" + htop + ":} " + cpu_usage + " " + mem_free + " %{A}";

    cout << "%{B#CC707070}%{A:" + unix_time + ":} " + time + " %{A}";

    cout << "%{B#77000000}" << std::endl;
}

void segment::state::new_tick(u16 tick_index, u64 value){

    ticks[tick_index] = value;

    u64 target = ticks_sum(); 

    if (state_type == type::avreage) [[likely]]
        target /= ticks.size();

    setTransition(target);
}

void segment::state::setTransition(u64 goal){

    i64 step = goal - last;

    if (step == 0){
        std::fill(transition_values.begin(), transition_values.end(), goal);
        return;
    }

#ifdef __this
    for(u8 i=0; i<step_limit; i++){
        step = (step/2)?: step;
        // step = (step&0x8000000000000000) | (((step&0x7fffffffffffffff)>>1)?: step);
    }
#endif

    // step = DivIfPossible(step, transition_values.size()/4);

    i64 increment = last;

    if (step > 0)
        for (u8 i=0; i<transition_values.size(); i++) {
            increment = increment+step;
            
            if (increment<goal) {
                transition_values[i] = increment;

            } else {

                std::fill(transition_values.begin()+i, transition_values.end(), goal);
                break;
            }

        }
    else 
        for (u8 i=0; i<transition_values.size(); i++) {
            increment = increment+step;

            if (increment>goal && increment > -1) {
                transition_values[i] = increment;

            } else {

                std::fill(transition_values.begin()+i, transition_values.end(), goal);
                break;
            }
        }

}
