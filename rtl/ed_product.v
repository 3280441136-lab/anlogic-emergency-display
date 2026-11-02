// Three-key monitor-style UI, 25 MHz pixel domain. Keys are asynchronous active-low
// board keys (KEY1/A2 is the board reset): key1 = K2 (B2), key2 = K4 (C1), key3 = K3 (B1).
// Two-flop synchronizer, 20 ms integrator, shared 1 ms enable. Short events act on
// release; a long event fires once at HOLD_MS while held and suppresses that press's
// short event.
//   K4 (any press, on release): open / close the settings menu.
//   Menu closed: K2 short = next image, K2 long = normal <-> notice,
//                K3 = toggle the debug overlay (product <-> debug picture).
//   Menu open:   K3 = next item, K2 = next value of that item (both wrap; no long presses).
//   No key for MENU_IDLE_MS closes the menu. K2+K4 held CHORD_MS restores defaults.
// alarm_sw: board switch SW1 (up = 1) as the fire-alarm input. While it is up, mode is 2
// (emergency) whatever the keys did; down returns to the key-selected normal/notice mode.
// Same two-flop synchronizer and 20 ms integrator as the keys.
// Items (menu_sel 0..7): 0 brightness 1 contrast 2 volume (0..4, default 2), 3 transition
// (0 fade, 1 wipe, 2 cut, 3 cross-fade), 4 OSD transparency (0 opaque, 1 translucent (default), 2 clear), 5 autoplay,
// 6 eco, 7 debug overlay.
// cfg_load (one clock): apply settings restored from flash (ed_settings_store packing);
// out-of-range fields fall back to their defaults.
module ed_controls #(parameter CLK_HZ=25000000, HOLD_MS=800, MENU_IDLE_MS=10000, CHORD_MS=2000, DEBUG_DEFAULT=1)(
 input clk,rst,input key1,key2,key3,alarm_sw,
 input cfg_load,input [15:0] cfg_value,
 output [1:0] mode,output reg manual_next,output reg auto_en,
 output reg [2:0] brightness,contrast,volume,output reg [1:0] effect,osd,output reg eco,debug,
 output reg menu_open,output reg [3:0] menu_sel
);
 localparam MW=$clog2(CLK_HZ/1000), LAST_ITEM=7;
 reg [MW-1:0] ms_div;wire ms_tick=ms_div==CLK_HZ/1000-1;
 reg [1:0] k1,k2,k3;reg [4:0] db1,db2,db3;reg pressed1,pressed2,pressed3;
 reg [10:0] held1;reg held2,held3,long1,long2;reg [13:0] menu_idle;
 reg chord;reg [11:0] chord_ms;
 reg [1:0] ksel;reg [1:0] sw_s;reg [4:0] db_sw;reg alarm;   // ksel: key mode 0 normal, 1 notice
 assign mode=alarm?2'd2:ksel;
 function [2:0] up5;input [2:0] v;begin up5=(v>=4)?3'd0:v+1'b1;end endfunction
 function [1:0] up3;input [1:0] v;begin up3=(v>=2)?2'd0:v+1'b1;end endfunction
 task defaults;begin
  ksel<=0;auto_en<=1;brightness<=2;contrast<=2;volume<=2;effect<=0;osd<=1;eco<=0;debug<=DEBUG_DEFAULT;menu_open<=0;menu_sel<=0;
 end endtask
 task adjust;begin   // next value, wrapping
  case(menu_sel)
   0:brightness<=up5(brightness);
   1:contrast<=up5(contrast);
   2:volume<=up5(volume);
   3:effect<=effect+1'b1;   // 4 transitions, wraps
   4:osd<=up3(osd);
   5:auto_en<=~auto_en;6:eco<=~eco;default:debug<=~debug;
  endcase
 end endtask
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   ms_div<=0;k1<=3;k2<=3;k3<=3;sw_s<=0;db_sw<=0;alarm<=0;db1<=0;db2<=0;db3<=0;pressed1<=0;pressed2<=0;pressed3<=0;
   held1<=0;held2<=0;held3<=0;long1<=0;long2<=0;chord<=0;chord_ms<=0;menu_idle<=0;manual_next<=0;
   defaults;
  end else begin
   k1<={k1[0],key1};k2<={k2[0],key2};k3<={k3[0],key3};sw_s<={sw_s[0],alarm_sw};manual_next<=0;
   if(cfg_load) begin
    brightness<=(cfg_value[2:0]<=4)?cfg_value[2:0]:3'd2;contrast<=(cfg_value[5:3]<=4)?cfg_value[5:3]:3'd2;
    volume<=(cfg_value[8:6]<=4)?cfg_value[8:6]:3'd2;effect<=cfg_value[10:9];
    auto_en<=cfg_value[11];eco<=cfg_value[12];debug<=cfg_value[13];osd<=(cfg_value[15:14]<=2)?cfg_value[15:14]:2'd1;
   end
   if(ms_tick) ms_div<=0;else ms_div<=ms_div+1'b1;
   if(ms_tick) begin
    if(!k1[1]) begin if(db1!=20) db1<=db1+1'b1;else pressed1<=1;end
    else begin if(db1!=0) db1<=db1-1'b1;else pressed1<=0;end
    if(!k2[1]) begin if(db2!=20) db2<=db2+1'b1;else pressed2<=1;end
    else begin if(db2!=0) db2<=db2-1'b1;else pressed2<=0;end
    if(!k3[1]) begin if(db3!=20) db3<=db3+1'b1;else pressed3<=1;end
    else begin if(db3!=0) db3<=db3-1'b1;else pressed3<=0;end
    if(sw_s[1]) begin if(db_sw!=20) db_sw<=db_sw+1'b1;else alarm<=1;end
    else begin if(db_sw!=0) db_sw<=db_sw-1'b1;else alarm<=0;end
    if(menu_open) begin
     if(pressed1||pressed2||pressed3) menu_idle<=0;
     else if(menu_idle==MENU_IDLE_MS-1) begin menu_open<=0;menu_idle<=0;end
     else menu_idle<=menu_idle+1'b1;
    end else menu_idle<=0;
    if(pressed1&&pressed2) begin
     chord<=1;long1<=1;long2<=1;
     if(chord_ms==CHORD_MS-1) defaults;
     if(chord_ms!=CHORD_MS) chord_ms<=chord_ms+1'b1;
    end else if(!pressed1&&!pressed2) begin chord<=0;chord_ms<=0;end
    // K2 (key1): menu closed: short = next image, long = next mode; menu open: next value
    // of the selected item on release, whatever the press length.
    if(pressed1&&!pressed2&&!chord) begin
     if(held1<HOLD_MS) held1<=held1+1'b1;
     else if(!long1 && !menu_open) begin long1<=1;ksel<={1'b0,~ksel[0]};end
    end
    if(!pressed1 && held1!=0) begin
     if(!long1&&!chord) begin if(menu_open) adjust;else manual_next<=1;end
     held1<=0;long1<=0;
    end
    // K4 (key2): menu open/close on release, whatever the press length (not after a chord).
    if(pressed2) held2<=1;
    else if(held2) begin
     if(!long2) begin menu_open<=~menu_open;menu_sel<=0;end
     held2<=0;long2<=0;
    end
    // K3 (key3): next menu item while the menu is open, debug overlay toggle otherwise;
    // acts on release.
    if(pressed3) held3<=1;
    else if(held3) begin
     if(menu_open) menu_sel<=(menu_sel==LAST_ITEM)?4'd0:menu_sel+1'b1;
     else debug<=~debug;
     held3<=0;
    end
   end
  end
 end
endmodule

// Frame-domain scheduler, pixel domain. Banks: 0..3 normal carousel, 4 notice, 5 emergency
// evacuation (both exits). Normal: carousel 0..3 with the chosen transition. Notice (crowd
// warning, shops still open): the carousel keeps running with the notice image inserted
// after every advert (notice, ad, notice, next ad, ...), starting with the notice image.
// Emergency: cut in immediately (highest priority); leaving it returns to the carousel.
// No asynchronous control inputs. Auto timer holds during menu and transition.
module ed_player #(parameter DWELL_FRAMES=300)(
 input clk,rst,frame_start,ready,manual_next,auto_en,
 input [1:0] mode,effect,input [2:0] menu,
 output reg [2:0] active_index,output reg [4:0] gain,
 output reg wipe,output reg [5:0] reveal,output reg [1:0] committed_mode,
 // Cross-fade (effect 3): while blend, the frame shows old_index * (16-mix)/16 + active_index
 // * mix/16; mix rises 0..16 by one every second frame (about 0.55 s).
 output reg blend,output reg [4:0] mix,output reg [2:0] old_index
);
 localparam NORMAL_IMAGES=4;
 reg [1:0] normal_index;reg pending_next,notice_slot;reg [8:0] dwell;reg [1:0] state;
 reg [1:0] current_effect;reg mix_phase;
 wire [1:0] next_normal=(normal_index==NORMAL_IMAGES-1)?2'd0:normal_index+1'b1;
 wire [2:0] target=(mode==2)?3'd5:(mode==1&&notice_slot)?3'd4:{1'b0,normal_index};
 // One carousel step: in notice mode alternate notice / next advert.
 task advance;begin
  if(mode==1 && !notice_slot) notice_slot<=1;
  else begin notice_slot<=0;normal_index<=next_normal;end
 end endtask
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   normal_index<=0;pending_next<=0;notice_slot<=0;dwell<=0;state<=0;active_index<=0;
   gain<=16;wipe<=0;reveal<=40;committed_mode<=0;current_effect<=0;blend<=0;mix<=16;old_index<=0;mix_phase<=0;
  end else begin
   if(manual_next && mode!=2 && menu==0) pending_next<=1;
   if(frame_start) begin
    committed_mode<=mode;
    if(mode==2) pending_next<=0;   // no carousel step during an emergency
    // Entering notice mode shows the notice image first; other modes never show it.
    if(!ready) begin dwell<=0;gain<=16;state<=0;wipe<=0;blend<=0;end
    else begin
     if(mode==1 && committed_mode!=1) begin notice_slot<=1;dwell<=0;end
     else if(mode!=1) notice_slot<=0;
     if(mode!=2 && committed_mode==mode && menu==0 && state==0) begin
      if(pending_next) begin advance;pending_next<=0;dwell<=0;end
      else if(auto_en) begin
       if(dwell==DWELL_FRAMES-1) begin advance;dwell<=0;end
       else dwell<=dwell+1'b1;
      end else dwell<=0;
     end else dwell<=0;
     if(mode==2 && active_index!=target) begin
      active_index<=target;gain<=0;wipe<=0;blend<=0;state<=2;current_effect<=0;
     end else case(state)
      0: if(active_index!=target) begin
       current_effect<=effect;
       if(effect==3) begin old_index<=active_index;active_index<=target;gain<=16;blend<=1;mix<=0;mix_phase<=0;state<=3;end
       else if(effect==2) begin active_index<=target;gain<=16;end
       else if(effect==1) begin active_index<=target;reveal<=0;wipe<=1;gain<=16;state<=2;end
       else state<=1;
      end
      1: if(gain==0) begin active_index<=target;state<=2;end else gain<=gain-2;
      2: if(current_effect==1) begin
       if(reveal>=40) begin wipe<=0;state<=0;end else reveal<=reveal+2;
      end else if(gain==16) state<=0;else gain<=gain+2;
      default: begin   // 3: cross-fade
       mix_phase<=~mix_phase;
       if(mix==16) begin blend<=0;state<=0;end else if(mix_phase) mix<=mix+1'b1;
      end
     endcase
    end
   end
  end
 end
endmodule

// PCM synthesis, 25 MHz pixel domain, active-high async reset. Exactly 48 kHz: sample
// periods 520,521,521,521,521,521 clocks (48000 per 25e6); valid is a one-clock pulse.
// Output signed 24-bit, the same sample on left and right (mono).
// Tone = sine(phase) * envelope / 65536, sine from a 64-entry quarter-wave table. The
// product uses a 16-step shift-add multiplier started at each sample tick (520 clocks
// per sample available), so no DSP block; the tone is output one sample later.
//   normal: chime arpeggio, a note every 250 ms (12000 samples), envelope decays by
//           1/8192 per sample (time constant ~170 ms);
//   notice: "ding-dong", E5 then C5 600 ms later, every 10 s, decay 1/16384 (~340 ms)
//           (shops stay open in notice mode, so the cue is sparse);
//   alarm:  continuous siren, 600 -> 1200 -> 600 Hz triangle sweep each second.
// signal: tone before volume (waveform tap). pcm = tone << (volume+1); volume 0 mutes,
// volume 2 equals the previous +-2^18 peak level. Silent until ready; a mode change
// restarts the pattern.
module ed_audio(input clk,rst,input [1:0] mode,input ready,input [2:0] volume,
 output reg valid,output reg signed [23:0] pcm,output reg signed [15:0] signal);
 localparam NOTE_SAMPLES=12000, NOTICE_PERIOD=480000, DONG_AT=28800;
 localparam [23:0] INC_600=24'd209715, INC_1200=24'd419430, SWEEP_STEP=24'd140;
 reg [9:0] divider;reg [2:0] sixth;
 wire tick=divider==((sixth==0)?519:520);
 reg [23:0] phase,increment,env;reg [18:0] timer;reg [3:0] note;reg [3:0] sweep_div;reg sweep_up;
 reg [1:0] mode_d;reg ready_d;
 function [14:0] quarter_sine;input [5:0] i;begin case(i)
  0:quarter_sine=402;1:quarter_sine=1206;2:quarter_sine=2009;3:quarter_sine=2811;4:quarter_sine=3612;5:quarter_sine=4410;
  6:quarter_sine=5205;7:quarter_sine=5998;8:quarter_sine=6786;9:quarter_sine=7571;10:quarter_sine=8351;11:quarter_sine=9126;
  12:quarter_sine=9896;13:quarter_sine=10659;14:quarter_sine=11417;15:quarter_sine=12167;16:quarter_sine=12910;17:quarter_sine=13645;
  18:quarter_sine=14372;19:quarter_sine=15090;20:quarter_sine=15800;21:quarter_sine=16499;22:quarter_sine=17189;23:quarter_sine=17869;
  24:quarter_sine=18537;25:quarter_sine=19195;26:quarter_sine=19841;27:quarter_sine=20475;28:quarter_sine=21096;29:quarter_sine=21705;
  30:quarter_sine=22301;31:quarter_sine=22884;32:quarter_sine=23452;33:quarter_sine=24007;34:quarter_sine=24547;35:quarter_sine=25072;
  36:quarter_sine=25582;37:quarter_sine=26077;38:quarter_sine=26556;39:quarter_sine=27019;40:quarter_sine=27466;41:quarter_sine=27896;
  42:quarter_sine=28310;43:quarter_sine=28706;44:quarter_sine=29085;45:quarter_sine=29447;46:quarter_sine=29791;47:quarter_sine=30117;
  48:quarter_sine=30424;49:quarter_sine=30714;50:quarter_sine=30985;51:quarter_sine=31237;52:quarter_sine=31470;53:quarter_sine=31685;
  54:quarter_sine=31880;55:quarter_sine=32057;56:quarter_sine=32213;57:quarter_sine=32351;58:quarter_sine=32469;59:quarter_sine=32567;
  60:quarter_sine=32646;61:quarter_sine=32705;62:quarter_sine=32745;default:quarter_sine=32765;
 endcase end endfunction
 function [23:0] chime;input [3:0] n;begin case(n)   // C5 E5 G5 C6 A5 G5 E5 G5 F5 A5 C6 A5 G5 E5 D5 C5
  0:chime=182889;1:chime=230428;2:chime=274024;3:chime=365778;4:chime=307582;5:chime=274024;6:chime=230428;7:chime=274024;
  8:chime=244129;9:chime=307582;10:chime=365778;11:chime=307582;12:chime=274024;13:chime=230428;14:chime=205287;default:chime=182889;
 endcase end endfunction
 wire [14:0] magnitude=quarter_sine(phase[22] ? ~phase[21:16] : phase[21:16]);
 // Serial |sine| * env16: am_y holds the remaining multiplier bits, done when zero.
 reg [30:0] am_x,am_acc;reg [15:0] am_y;reg am_neg;reg signed [15:0] tone;
 wire signed [23:0] tone24={{8{tone[15]}},tone};
 // Datapath only (no reset; keeps the pixel-domain reset fanout small). tone is undefined
 // until the first sample tick, and pcm/signal are forced to 0 while !ready meanwhile.
 always @(posedge clk) begin
  if(tick) begin am_x<={16'd0,magnitude};am_y<=env[23:8];am_acc<=0;am_neg<=phase[23];end
  else if(am_y!=0) begin
   if(am_y[0]) am_acc<=am_acc+am_x;
   am_x<={am_x[29:0],1'b0};am_y<={1'b0,am_y[15:1]};
  end else tone<=am_neg ? -$signed({1'b0,am_acc[30:16]}) : $signed({1'b0,am_acc[30:16]});
 end
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   divider<=0;sixth<=0;phase<=0;increment<=0;env<=0;timer<=0;note<=0;sweep_div<=0;sweep_up<=1;
   mode_d<=0;ready_d<=0;valid<=0;pcm<=0;signal<=0;
  end else begin
   valid<=tick;
   if(tick) begin
    divider<=0;sixth<=(sixth==5)?0:sixth+1'b1;
    mode_d<=mode;ready_d<=ready;
    phase<=phase+increment;
    if(!ready || mode!=mode_d || !ready_d) begin
     timer<=0;note<=0;env<=0;increment<=(mode>=2)?INC_600:24'd0;sweep_up<=1;sweep_div<=0;
    end else if(mode>=2) begin
     env<=24'hd00000;
     sweep_div<=sweep_div+1'b1;
     if(sweep_div==0) begin
      if(sweep_up) begin if(increment>=INC_1200) sweep_up<=0;else increment<=increment+SWEEP_STEP;end
      else begin if(increment<=INC_600) sweep_up<=1;else increment<=increment-SWEEP_STEP;end
     end
    end else if(mode==1) begin
     timer<=(timer==NOTICE_PERIOD-1)?19'd0:timer+1'b1;
     if(timer==0) begin increment<=chime(4'd1);env<=24'hffffff;end
     else if(timer==DONG_AT) begin increment<=chime(4'd0);env<=24'hffffff;end
     else env<=env-(env>>14);
    end else begin
     if(timer==NOTE_SAMPLES-1) timer<=0;else timer<=timer+1'b1;
     if(timer==0) begin increment<=chime(note);note<=note+1'b1;env<=24'hffffff;end
     else env<=env-(env>>13);
    end
    signal<=ready?tone:16'sd0;
    pcm<=(!ready||volume==0) ? 24'sd0 : (tone24<<<(volume+1'b1));
   end else divider<=divider+1'b1;
  end
 end
endmodule

// Waveform tap of the generated signal, pixel domain. Ping-pong 128-point banks with a
// rising zero-crossing trigger (or after 4096 samples without one) so periodic tones
// stand still; decimation 2 (ECO 4). A captured bank is published at a frame boundary
// (ECO: every fourth frame). Peak: maximum |signal| over 1024-sample windows.
module ed_audio_scope(input clk,rst,frame_start,valid,eco,input signed [15:0] signal,
 input [6:0] read_index,input read_enable,output reg signed [7:0] wave,output reg [7:0] peak);
 // Both banks in one 256 x 8 block RAM, bank select as the address MSB (one write port,
 // one registered read port) instead of two LUT-mapped arrays and an output mux.
 reg signed [7:0] banks[0:255] /* fehdl force_ram=1, ram_style="bram" */;
 reg wr_bank,rd_bank,pending,armed,scope_valid;reg [6:0] ptr;reg [11:0] wait_count;
 reg [1:0] decim;reg [9:0] window_count;reg [7:0] max_abs,pending_peak;reg [1:0] eco_phase;
 reg signed [15:0] last;
 wire [15:0] mag=signal[15] ? -signal : signal;
 wire [7:0] amplitude=mag[14:7];
 wire trigger=armed && valid && ((last<0 && signal>=0) || wait_count==12'hfff);
 reg signed [7:0] wave_q;reg wave_ok;
 always @* wave=wave_ok ? wave_q : 8'sd0;   // same one-clock read latency as before
 wire store=valid && !armed && !pending && decim==0;
 always @(posedge clk) begin
  if(store||trigger) banks[{wr_bank,trigger?7'd0:ptr}]<=signal[15:8];
  if(read_enable) wave_q<=banks[{rd_bank,read_index}];
  if(read_enable) wave_ok<=scope_valid;
 end
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   pending_peak<=0;eco_phase<=0;scope_valid<=0;wr_bank<=0;rd_bank<=1;pending<=0;armed<=1;ptr<=0;wait_count<=0;
   decim<=0;peak<=0;window_count<=0;max_abs<=0;last<=0;
  end else begin
   if(valid) begin
    last<=signal;
    if(armed) begin
     wait_count<=wait_count+1'b1;
     if(trigger) begin armed<=0;ptr<=1;decim<=eco?2'd3:2'd1;wait_count<=0;end
    end else if(!pending) begin
     if(decim==0) begin
      decim<=eco?2'd3:2'd1;
      if(ptr==127) pending<=1;else ptr<=ptr+1'b1;
     end else decim<=decim-1'b1;
    end
    if(amplitude>max_abs) max_abs<=amplitude;
    if(window_count==1023) begin window_count<=0;pending_peak<=max_abs;max_abs<=0;end
    else window_count<=window_count+1'b1;
   end
   if(frame_start) begin eco_phase<=eco_phase+1'b1;peak<=pending_peak;end
   if(frame_start && pending && (!eco || eco_phase==0)) begin
    scope_valid<=1;rd_bank<=wr_bank;wr_bank<=~wr_bank;pending<=0;armed<=1;ptr<=0;
   end
  end
 end
endmodule
// Audio spectrum for the debug panel, 25 MHz pixel domain, active-high async reset.
// Input: the generated 48 kHz tone (ed_audio signal, before volume, signed 16-bit, valid
// one clock per sample), decimated by 8 (mean of 8 samples: 6 kHz).
// 128-point radix-2 decimation-in-time FFT with a Hann window, computed in place in one
// 128 x 36-bit RAM ({re, im}, signed 18 bits each). Samples are written in bit-reversed
// order, so the result comes out in natural order. Every butterfly halves its outputs
// (total 1/128); the 2 bits of headroom over the 16-bit input cover the worst-case growth
// of 1.21 per stage (1.21^7 = 3.7 < 4), so the 18-bit words never overflow.
// One 18 x 17 signed multiplier is shared by the window (one product per sample, while
// capturing) and the butterflies (4 products each, 11 clocks per butterfly, 448
// butterflies: about 5000 clocks per transform; capturing 128 samples takes 21 ms).
// Output: 64 bins of 6000/128 = 46.875 Hz (0 to 2953 Hz). Magnitude max(|re|,|im|) +
// 3/8 min (error <= 7 %), shown as 0..63 pixels (mag/128, saturating). A sine of
// amplitude A gives about A/4 in its bin (Hann coherent gain 1/2, N/2, scaling 1/N):
// full scale 32767 -> 63 pixels.
// Results go to one of two 64-entry banks; a finished bank is published at a frame
// boundary, then the next capture starts. A capture spans more than one frame, so normally
// one transform every second frame; ECO waits for every fourth frame (half the activity).
module ed_audio_spectrum(input clk,rst,frame_start,valid,eco,input signed [15:0] signal,
 input [5:0] read_index,input read_enable,output [5:0] bar,
 // Tallest bin of the published spectrum and its height (0 until the first publish).
 output reg [5:0] peak_bin,peak_h);
 localparam S_CAP=4'd0,S_WIN=4'd1,S_WWR=4'd2,S_RB=4'd3,S_RA=4'd4,S_LB=4'd5,S_LA=4'd6,
            S_M0=4'd7,S_M1=4'd8,S_M2=4'd9,S_M3=4'd10,S_M4=4'd11,S_W0=4'd12,S_W1=4'd13,
            S_MAG=4'd14,S_DONE=4'd15;
 // cos(2*pi*k/128) * 32767, k = 0..32 (Q15)
 function [15:0] cos_tab;input [5:0] k;begin case(k)
  0:cos_tab=32767;1:cos_tab=32728;2:cos_tab=32609;3:cos_tab=32412;4:cos_tab=32137;5:cos_tab=31785;
  6:cos_tab=31356;7:cos_tab=30852;8:cos_tab=30273;9:cos_tab=29621;10:cos_tab=28898;11:cos_tab=28105;
  12:cos_tab=27245;13:cos_tab=26319;14:cos_tab=25329;15:cos_tab=24279;16:cos_tab=23170;17:cos_tab=22005;
  18:cos_tab=20787;19:cos_tab=19519;20:cos_tab=18204;21:cos_tab=16846;22:cos_tab=15446;23:cos_tab=14010;
  24:cos_tab=12539;25:cos_tab=11039;26:cos_tab=9512;27:cos_tab=7962;28:cos_tab=6393;29:cos_tab=4808;
  30:cos_tab=3212;31:cos_tab=1608;default:cos_tab=0;
 endcase end endfunction
 // cos(2*pi*i/128) for i = 0..64, signed Q15
 function signed [16:0] cos64;input [6:0] i;begin
  cos64=(i<=32)?$signed({1'b0,cos_tab(i[5:0])}):-$signed({1'b0,cos_tab(7'd64-i)});
 end endfunction
 function [6:0] bitrev;input [6:0] v;begin bitrev={v[0],v[1],v[2],v[3],v[4],v[5],v[6]};end endfunction
 // ---------------- RAMs ----------------
 reg [35:0] mem[0:127] /* fehdl force_ram=1, ram_style="bram" */;
 reg [5:0] res[0:127] /* fehdl force_ram=1, ram_style="bram" */;
 reg we,res_we;reg [6:0] wa,ra,res_wa;reg [35:0] wd,q;reg [5:0] res_wd,bar_q;
 reg wbank,rbank,ready_bank,bar_ok;
 always @(posedge clk) begin
  if(we) mem[wa]<=wd;
  q<=mem[ra];
  if(res_we) res[res_wa]<=res_wd;
  if(read_enable) begin bar_q<=res[{rbank,read_index}];bar_ok<=ready_bank;end
 end
 assign bar=bar_ok?bar_q:6'd0;
 // ---------------- shared multiplier ----------------
 reg signed [17:0] ma;reg signed [16:0] mb;reg signed [34:0] p;
 always @(posedge clk) p<=ma*mb;
 // ---------------- control (reset) and datapath (no reset) ----------------
 // Only the state, counters, write strobes and bank flags are reset (pixel-domain reset
 // fanout); every datapath register is written before it is used in a transform.
 reg [3:0] state;reg [2:0] dcount;reg [6:0] n;reg [2:0] s;reg [5:0] bf;reg [1:0] mag_step,eco_phase;
 reg [5:0] best_bin,best_h;
 reg signed [18:0] dacc;reg [6:0] a,b,k;reg signed [16:0] tc,ts;
 reg signed [17:0] ar,ai,br,bi;reg signed [35:0] acc,tre,tim;
 wire signed [15:0] dec=(dacc+signal)>>>3;              // mean of 8 samples
 wire dec_valid=valid && dcount==3'd7;
 wire [6:0] ci=(n<=64)?n:7'd128-n;
 wire signed [16:0] hann=17'sd16384-(cos64(ci)>>>1);    // (1 - cos)/2, Q15
 // butterfly addressing for stage s (half size m = 2^s): j = bf mod m, a = group*2m + j,
 // b = a + m, twiddle W^(j*64/m)
 wire [6:0] m=7'd1<<s;
 wire [6:0] j={1'b0,bf}&(m-1'b1);
 wire [6:0] a_n=(({1'b0,bf}>>s)<<(s+1'b1))|j;
 wire [5:0] k_n=j[5:0]<<(3'd6-s);
 wire signed [36:0] ar_s={{4{ar[17]}},ar,15'd0}, ai_s={{4{ai[17]}},ai,15'd0};
 wire signed [36:0] tre_s={tre[35],tre}, tim_s={tim[35],tim};
 wire signed [36:0] sa_re=ar_s+tre_s, sa_im=ai_s+tim_s, sb_re=ar_s-tre_s, sb_im=ai_s-tim_s;
 // magnitude of the word read back (q)
 wire signed [17:0] qre=q[35:18], qim=q[17:0];
 wire [17:0] are=qre[17]?-qre:qre, aim=qim[17]?-qim:qim;
 wire [17:0] mx=(are>aim)?are:aim, mn=(are>aim)?aim:are;
 wire [18:0] mag={1'b0,mx}+(mn>>2)+(mn>>3);
 wire [5:0] height=(mag[18:7]>63)?6'd63:mag[12:7];
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   state<=S_CAP;dcount<=0;n<=0;s<=0;bf<=0;mag_step<=0;eco_phase<=0;
   we<=0;res_we<=0;wbank<=0;rbank<=1;ready_bank<=0;peak_bin<=0;peak_h<=0;best_bin<=0;best_h<=0;
  end else begin
   we<=0;res_we<=0;
   if(valid) dcount<=dcount+1'b1;
   if(frame_start) eco_phase<=eco_phase+1'b1;
   case(state)
    S_CAP: if(dec_valid) state<=S_WIN;
    S_WIN: state<=S_WWR;                                   // p = sample * window
    S_WWR: begin
     we<=1;
     if(n==127) begin n<=0;s<=0;bf<=0;state<=S_RB;end else begin n<=n+1'b1;state<=S_CAP;end
    end
    S_RB: state<=S_RA;   // one butterfly: read b, read a, 4 products, write a, write b
    S_RA: state<=S_LB;
    S_LB: state<=S_LA;
    S_LA: state<=S_M0;
    S_M0: state<=S_M1;
    S_M1: state<=S_M2;
    S_M2: state<=S_M3;
    S_M3: state<=S_M4;
    S_M4: state<=S_W0;
    S_W0: begin we<=1;state<=S_W1;end
    S_W1: begin
     we<=1;
     if(bf==63) begin
      bf<=0;
      if(s==6) begin n<=0;mag_step<=0;best_h<=0;best_bin<=0;state<=S_MAG;end else begin s<=s+1'b1;state<=S_RB;end
     end else begin bf<=bf+1'b1;state<=S_RB;end
    end
    S_MAG: begin   // magnitudes of bins 0..63 into the write bank: read, wait, write
     if(mag_step==2'd2) begin
      res_we<=1;mag_step<=2'd0;
      if(height>best_h) begin best_h<=height;best_bin<=n[5:0];end
      if(n==63) begin n<=0;state<=S_DONE;end else n<=n+1'b1;
     end else mag_step<=mag_step+1'b1;
    end
    default: if(frame_start && (!eco || eco_phase==0)) begin   // S_DONE: publish, capture again
     rbank<=wbank;wbank<=~wbank;ready_bank<=1;n<=0;peak_bin<=best_bin;peak_h<=best_h;state<=S_CAP;
    end
   endcase
  end
 end
 always @(posedge clk) begin
  if(valid) dacc<=(dcount==3'd7)?19'sd0:dacc+signal;
  case(state)
   S_CAP: begin ma<={{2{dec[15]}},dec};mb<=hann;end
   S_WWR: begin wa<=bitrev(n);wd<={p[32:15],18'd0};end    // Q15 product back to sample units
   S_RB: begin a<=a_n;b<=a_n|m;k<=k_n;ra<=a_n|m;end
   S_RA: begin
    ra<=a;
    tc<=(k<=32)?$signed({1'b0,cos_tab(k[5:0])}):-$signed({1'b0,cos_tab(7'd64-k)});   // cos(k)
    ts<=$signed({1'b0,cos_tab((k<=32)?6'd32-k[5:0]:k[5:0]-6'd32)});              // sin(k) = cos(|32-k|)
   end
   S_LB: begin br<=q[35:18];bi<=q[17:0];end
   S_LA: begin ar<=q[35:18];ai<=q[17:0];ma<=br;mb<=tc;end   // issue br*c
   S_M0: begin ma<=bi;mb<=ts;end                            // issue bi*s
   S_M1: begin acc<=p;ma<=bi;mb<=tc;end                     // br*c ready; issue bi*c
   S_M2: begin tre<=acc+p;ma<=br;mb<=ts;end                 // t_re = br*c + bi*s; issue br*s
   S_M3: acc<=p;                                            // bi*c ready
   S_M4: tim<=acc-p;                                        // t_im = bi*c - br*s
   S_W0: begin wa<=a;wd<={sa_re[33:16],sa_im[33:16]};end    // (a + t) / 2
   S_W1: begin wa<=b;wd<={sb_re[33:16],sb_im[33:16]};end    // (a - t) / 2
   S_MAG: begin
    if(mag_step==2'd0) ra<=n;
    if(mag_step==2'd2) begin res_wa<={wbank,n[5:0]};res_wd<=height;end
   end
   default:;
  endcase
 end
endmodule
// Boot status for the six-digit panel; storage clock domain, active-high async reset.
// All inputs are registers of the same domain, so no CDC. seg0 is the leftmost digit.
// Fault:   E K I R DD  K=1 SD init,2 FAT32 scan,3 cluster chain,4 BMP header/size,
//          5 SDRAM write,6 incomplete,F boot watchdog; I=image 1..6; R=first SPI
//          sector error (0 none, 1..6 reader code, E capture order); DD=detail hex.
// Loading: b S I R C C S=1 card init, 2 file ingest; CC=sectors with data-CRC mismatch
//          (saturates at FF). Ready: 0, plus R if a retry occurred and CC if non-zero.
module ed_boot_status(
 input clk,rst,input boot_done,boot_fault,boot_timeout,
 input [2:0] error_stage,input [7:0] error_code,error_detail,
 input [5:0] complete,resource_valid,input [1:0] state,input [2:0] image,
 input [7:0] sector_error,crc_mismatches,input card_ready,
 output reg [7:0] seg0,seg1,seg2,seg3,seg4,seg5
);
 localparam [7:0] BLANK=8'hff;
 function [7:0] hex7;  // Same active-low pattern as the official seg_decoder; DP off.
  input [3:0] v; begin case(v)
  0:hex7=8'hc0;1:hex7=8'hf9;2:hex7=8'ha4;3:hex7=8'hb0;4:hex7=8'h99;5:hex7=8'h92;
  6:hex7=8'h82;7:hex7=8'hf8;8:hex7=8'h80;9:hex7=8'h90;10:hex7=8'h88;11:hex7=8'h83;
  12:hex7=8'hc6;13:hex7=8'ha1;14:hex7=8'h86;default:hex7=8'h8e;endcase end
 endfunction
 reg [3:0] kind,reader;reg [7:0] detail;
 reg [3:0] kind_q,reader_q;reg [7:0] detail_q;   // registered decode (timing, display only)
 // Timing: decode from a registered copy of the inputs (display only, one cycle late).
 // State flags are reset; the data copies are not (they follow their reset sources one
 // cycle later, and the outputs below are reset), which keeps the reset fanout small.
 reg boot_done_q,boot_fault_q,boot_timeout_q,card_ready_q;reg [2:0] error_stage_q;
 reg [7:0] error_code_q,error_detail_q,sector_error_q,crc_q;reg [5:0] complete_q,resource_valid_q;reg [1:0] state_q;reg [2:0] image_q;
 always @(posedge clk or posedge rst) begin
  if(rst) begin boot_done_q<=0;boot_fault_q<=0;boot_timeout_q<=0;end
  else begin boot_done_q<=boot_done;boot_fault_q<=boot_fault;boot_timeout_q<=boot_timeout;end
 end
 always @(posedge clk) begin
  card_ready_q<=card_ready;error_stage_q<=error_stage;error_code_q<=error_code;error_detail_q<=error_detail;
  sector_error_q<=sector_error;crc_q<=crc_mismatches;complete_q<=complete;resource_valid_q<=resource_valid;state_q<=state;image_q<=image;
 end
 wire images_known=state_q==2'd2&&resource_valid_q==6'h3f;
 always @* begin
  if(boot_timeout_q) kind=4'hf;
  else if(error_stage_q==3'd1) kind=4'h1;
  else if(error_stage_q==3'd2) case(error_code_q)
   8'h80:kind=4'h2;8'h82:kind=4'h3;8'h83:kind=4'h4;8'h84:kind=4'h5;default:kind=4'h6;endcase
  else kind=4'h6;
  case(kind)
   4'h1:detail=error_code_q;
   4'hf:detail={2'b00,state_q,3'b000,card_ready_q};
   4'h6:detail=error_stage_q==3'd0 ? {2'b00,complete_q} : error_code_q;
   default:detail=error_detail_q;
  endcase
  if(sector_error_q==8'h00) reader=4'h0;
  else if(sector_error_q<=8'h06) reader=sector_error_q[3:0];
  else if(sector_error_q==8'he1) reader=4'he;
  else reader=4'hf;
 end
 always @(posedge clk) begin kind_q<=kind;reader_q<=reader;detail_q<=detail;end
 always @(posedge clk or posedge rst) begin
  if(rst) begin seg0<=BLANK;seg1<=BLANK;seg2<=BLANK;seg3<=BLANK;seg4<=BLANK;seg5<=BLANK;end
  else if(boot_fault_q) begin
   seg0<=hex7(4'he);seg1<=hex7(kind_q);
   seg2<=(kind_q>=4'h3&&kind_q<=4'h5)||(kind_q==4'hf&&images_known) ? hex7({1'b0,image_q}+1'b1) : BLANK;
   seg3<=hex7(reader_q);seg4<=hex7(detail_q[7:4]);seg5<=hex7(detail_q[3:0]);
  end else if(boot_done_q) begin
   seg0<=hex7(4'h0);seg1<=BLANK;seg2<=BLANK;seg3<=reader_q!=0 ? hex7(reader_q) : BLANK;
   seg4<=crc_q!=0 ? hex7(crc_q[7:4]) : BLANK;
   seg5<=crc_q!=0 ? hex7(crc_q[3:0]) : BLANK;
  end else begin
   seg0<=hex7(4'hb);seg1<=hex7({2'b00,state_q});seg2<=images_known ? hex7({1'b0,image_q}+1'b1) : BLANK;
   seg3<=hex7(reader_q);seg4<=hex7(crc_q[7:4]);seg5<=hex7(crc_q[3:0]);
  end
 end
endmodule

// Boot sequencing, storage clock domain, active-high async reset.
// Starts the TF ingest once the SDRAM controller is initialized. A load that ends with
// an error (card not ready at power-up, transient read error) is restarted from card
// initialization after RETRY_WAIT cycles, up to RETRIES times; only then is boot_fault
// latched. The ingest chain returns to idle after done and every image bank is rewritten,
// so no reset is needed. The watchdog spans all attempts; a timeout (hung loader) faults
// immediately. boot_done/boot_fault are monotonic until reset.
module ed_boot_control #(parameter [33:0] TIMEOUT_CYCLES=34'd11249999999, parameter integer RETRIES=3,
 parameter [26:0] RETRY_WAIT=27'd124999999)(
 input clk,rst,mem_ready,ingest_done,ingest_ok,
 output reg start,boot_done,boot_fault,boot_timeout,output reg [1:0] retries
);
 reg kicked,retry_pending;reg [33:0] watchdog;reg [26:0] retry_count;
 always @(posedge clk or posedge rst) begin
  if(rst) begin start<=0;kicked<=0;boot_done<=0;boot_fault<=0;boot_timeout<=0;watchdog<=0;
   retries<=0;retry_pending<=0;retry_count<=0;end
  else begin
   start<=0;
   if(mem_ready&&!kicked) begin start<=1;kicked<=1;end
   if(kicked&&!boot_done&&!boot_fault) begin
    if(watchdog==TIMEOUT_CYCLES) begin boot_fault<=1;boot_timeout<=1;end
    else watchdog<=watchdog+1'b1;
    if(retry_pending) begin
     if(retry_count==RETRY_WAIT) begin retry_pending<=0;start<=1;end
     else retry_count<=retry_count+1'b1;
    end else if(ingest_done) begin
     if(ingest_ok) boot_done<=1;
     else if(retries!=RETRIES) begin retries<=retries+1'b1;retry_pending<=1;retry_count<=0;end
     else boot_fault<=1;
    end
   end
  end
 end
endmodule