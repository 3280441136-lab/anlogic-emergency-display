`timescale 1ns/1ps
module tb_product;
 reg clk=0;always #20 clk=~clk;
 reg rst=1,fs=0,ready=0,next=0,auto_en=0;
 reg [1:0] mode=0,effect=2;wire [2:0] active,old;wire [1:0] cm;wire blend;wire [4:0] mix;wire [4:0] gain;wire wipe;wire [5:0] reveal;
 ed_player #(.DWELL_FRAMES(3)) player(.clk(clk),.rst(rst),.frame_start(fs),.ready(ready),
  .manual_next(next),.auto_en(auto_en),.mode(mode),.effect(effect),.menu(3'd0),
  .active_index(active),.gain(gain),.wipe(wipe),.reveal(reveal),.committed_mode(cm),
  .blend(blend),.mix(mix),.old_index(old));
 wire av;wire signed [23:0] pcm;wire signed [15:0] signal;reg [2:0] volume=2;
 ed_audio audio(.clk(clk),.rst(rst),.mode(mode),.ready(ready),.volume(volume),.valid(av),.pcm(pcm),.signal(signal));
 integer peak_pcm=0;always @(negedge clk) if(av && (pcm>peak_pcm)) peak_pcm=pcm;
 integer samples=0,cycles=0;reg [2:0] prev;reg old_fs;
 always @(posedge clk) old_fs<=fs;
 always @(negedge clk) if(!rst) begin
  if(av) samples=samples+1;
  if(active!=prev && !old_fs) $fatal(1,"index changed outside frame boundary");
  prev=active;
 end else prev=active;   // reset may change the index
 task frame;begin @(negedge clk);fs=1;@(negedge clk);fs=0;repeat(2) @(negedge clk);end endtask
 initial begin
  prev=0;old_fs=0;repeat(4) @(negedge clk);rst=0;ready=1;
  frame();if(active!=0) $fatal(1,"boot index");
  next=1;@(negedge clk);next=0;repeat(3) @(negedge clk);if(active!=0) $fatal(1,"mid frame");
  frame();frame();if(active!=1) $fatal(1,"manual next");
  // Notice: the notice image first, then the carousel continues with it between adverts.
  mode=1;frame();frame();if(active!=4) $fatal(1,"notice image (bank 4) first");
  next=1;@(negedge clk);next=0;frame();frame();if(active!=2) $fatal(1,"K2 in notice: next advert %0d",active);
  next=1;@(negedge clk);next=0;frame();frame();if(active!=4) $fatal(1,"notice again after the advert");
  mode=2;frame();if(active!=5 || cm!=2) $fatal(1,"emergency (bank 5) priority");
  repeat(9) frame();if(gain!=16) $fatal(1,"fade range");
  mode=1;frame();frame();if(active!=4) $fatal(1,"emergency -> notice shows the notice first");
  mode=0;repeat(12) frame();if(active!=2) $fatal(1,"resume carousel %0d",active);
  auto_en=1;repeat(5) frame();if(active!=3) $fatal(1,"auto playback");
  repeat(2) frame();if(active!=0) $fatal(1,"carousel wraps after four images");
  mode=1;frame();auto_en=1;repeat(3) frame();if(active!=4) $fatal(1,"auto notice first");
  repeat(3) frame();if(active!=1) $fatal(1,"auto: notice -> next advert %0d",active);
  repeat(3) frame();if(active!=4) $fatal(1,"auto: advert -> notice");
  mode=0;frame();frame();
  // Cross-fade (effect 3): blend from the old to the new image, mix 0..16 over 32 frames.
  auto_en=0;effect=3;frame();next=1;@(negedge clk);next=0;frame();frame();   // step, then start
  if(!blend||mix!=0||active==old) $fatal(1,"cross-fade start blend%0d mix%0d %0d/%0d",blend,mix,active,old);
  repeat(16) frame();if(!blend||mix!=8) $fatal(1,"cross-fade midway mix %0d",mix);
  repeat(17) frame();if(blend||mix!=16||gain!=16) $fatal(1,"cross-fade end blend%0d mix%0d",blend,mix);
  next=1;@(negedge clk);next=0;frame();repeat(4) frame();mode=2;frame();
  if(blend||active!=5) $fatal(1,"emergency cancels the cross-fade");
  mode=0;effect=2;repeat(12) frame();
  // Reset sample cadence; count exact rational 48kHz enable over 312500 clocks.
  rst=1;repeat(3) @(negedge clk);rst=0;samples=0;
  repeat(312500) @(negedge clk);
  if(samples!=600) $fatal(1,"48k rational cadence: %0d",samples);
  if(^pcm===1'bx) $fatal(1,"undefined PCM");
  if(peak_pcm<24'sd100000 || peak_pcm>24'sd262144) $fatal(1,"volume 2 chime peak %0d",peak_pcm);
  volume=0;repeat(2000) @(negedge clk);if(pcm!==24'sd0) $fatal(1,"volume 0 must mute");
  volume=4;mode=2;repeat(60000) @(negedge clk);if(pcm==0 || signal==0) $fatal(1,"alarm silent");
  $display("PASS tb_product: frame commit, notice interleaved carousel, cross-fade, emergency priority, resume, autoplay, exact PCM cadence, sine chime level, mute, alarm");$finish;
 end
 initial begin #20000000;$fatal(1,"timeout");end
endmodule
