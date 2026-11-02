`timescale 1ns/1ps
// Renders complete 640x480 frames through ed_video (with the real ed_audio/ed_audio_scope
// feeding the waveform) and writes every output pixel as hex, one frame per file.
// scripts/run_sim.py prepares sim/osd/pic*.hex and converts frame_*.hex to PNG for review. Also checks that
// out_de carries exactly 307200 pixels per frame and that each frame's parameters only
// change at frame_start.
module tb_osd_frame;
 reg clk=0;always #20 clk=~clk;
 reg rst=1,fs=0,de=0,vs=1;reg [9:0] x=0,y=0;
 reg [23:0] image[0:307199];reg [23:0] pixel=0;
 reg ready=1,fault=0;reg [1:0] mode=0,effect=0,osd=1;reg [2:0] index=0,b=2,c=2,v=2;reg [3:0] sel=0;
 reg auto_en=1,eco=0,debug=1,menu_open=0;
 wire od,ov;wire [23:0] rgb;wire [6:0] wave_index;wire wave_rd;
 wire valid;wire signed [23:0] pcm;wire signed [15:0] signal;wire signed [7:0] wave;wire [7:0] peak;
 ed_audio audio(.clk(clk),.rst(rst),.mode(mode),.ready(ready),.volume(v),.valid(valid),.pcm(pcm),.signal(signal));
 ed_audio_scope scope(.clk(clk),.rst(rst),.frame_start(fs),.valid(valid),.eco(eco),.signal(signal),
  .read_index(wave_index),.read_enable(wave_rd),.wave(wave),.peak(peak));
 wire [5:0] spec_index,spec,spec_pb,spec_ph;wire spec_rd;
 ed_audio_spectrum spectrum(.clk(clk),.rst(rst),.frame_start(fs),.valid(valid),.eco(eco),.signal(signal),
  .read_index(spec_index),.read_enable(spec_rd),.bar(spec),.peak_bin(spec_pb),.peak_h(spec_ph));
 ed_video dut(.clk(clk),.rst(rst),.frame_start(fs),.x(x),.y(y),.de(de),.vs(vs),.pixel(pixel),.pixel_old(24'h000000),.blend(1'b0),.mix(5'd16),
  .ready(ready),.fault(fault),.underflow(1'b0),.mode(mode),.index(index),.effect(effect),
  .brightness(b),.contrast(c),.volume(v),.osd(osd),.auto_en(auto_en),.eco(eco),.debug(debug),.menu_open(menu_open),.menu_sel(sel),
  .gain(5'd16),.wipe(1'b0),.reveal(6'd40),.wave(wave),.peak(peak),.spec(spec),.spec_peak_bin(spec_pb),.spec_peak_h(spec_ph),
  .diag_rd(8'h00),.diag_ld(8'h00),.diag_ref(16'h7d00),.diag_crc(8'h00),.diag_flash(3'd1),
  .wave_index(wave_index),.wave_rd(wave_rd),.spec_index(spec_index),.spec_rd(spec_rd),.out_de(od),.out_vs(ov),.rgb(rgb));
 integer fd,count,i,f;
 always @(posedge clk) if(od) begin $fwrite(fd,"%06h\n",rgb);count=count+1;end
 task frame(input [8*40-1:0] image_file,input [8*40-1:0] out_file);
  integer row,col;
  begin
   $readmemh(image_file,image);
   fd=$fopen(out_file,"w");count=0;
   // Let the audio scope capture and publish a triggered bank before this frame.
   vs=1;repeat(300000) @(negedge clk);
   vs=0;fs=1;@(negedge clk);fs=0;repeat(20) @(negedge clk);
   for(row=0;row<480;row=row+1) begin
    for(col=0;col<640;col=col+1) begin x=col;y=row;de=1;pixel=image[row*640+col];@(negedge clk);end
    de=0;repeat(16) @(negedge clk);
   end
   repeat(10) @(negedge clk);$fclose(fd);
   if(count!=307200) $fatal(1,"%0s: %0d output pixels",out_file,count);
  end
 endtask
 initial begin
  repeat(4) @(negedge clk);rst=0;
  // 1: normal poster, debug overlay on, settings menu open on "volume".
  mode=0;index=0;debug=1;menu_open=1;sel=2;v=3;
  // Let the spectrum publish two captures: the first one contains the tone's undefined
  // (simulation X) first sample, since ed_audio's datapath has no reset.
  repeat(2) begin repeat(600000) @(negedge clk);fs=1;@(negedge clk);fs=0;end
  frame("../sim/osd/pic1.hex","../sim/osd/frame_menu.hex");
  f=0;for(i=0;i<64;i=i+1) if(spectrum.res[{spectrum.rbank,i[5:0]}]>f) f=spectrum.res[{spectrum.rbank,i[5:0]}];
  $display("spectrum published %0d, tallest bar %0d, state %0d",spectrum.ready_bank,f,spectrum.state);
  if(!spectrum.ready_bank || f==0) $fatal(1,"no spectrum shown in the debug frame");
  // 2: product mode (debug off), notice image and caption, translucent band (osd 1).
  mode=1;index=4;debug=0;menu_open=0;v=2;
  frame("../sim/osd/pic5.hex","../sim/osd/frame_notice.hex");
  // 3: product mode, emergency, evacuation map (border flash phase depends on frame count).
  mode=2;index=5;
  for(i=0;i<30;i=i+1) begin fs=1;@(negedge clk);fs=0;@(negedge clk);end   // flash phase on
  frame("../sim/osd/pic6.hex","../sim/osd/frame_alarm.hex");
  // 3b: carousel, upscaled advert (PIC4 480x360), clear overlay (osd 2), menu on OSD item.
  mode=0;index=3;osd=2;menu_open=1;sel=4;
  frame("../sim/osd/pic4.hex","../sim/osd/frame_clear.hex");
  osd=1;menu_open=0;
  // 3c: debug overlay without the menu during the siren: waveform, spectrum, readings.
  mode=2;index=5;debug=1;
  frame("../sim/osd/pic6.hex","../sim/osd/frame_debug.hex");
  debug=0;
  // 4: boot screen (not ready), debug on.
  ready=0;debug=1;mode=0;
  frame("../sim/osd/pic1.hex","../sim/osd/frame_boot.hex");
  $display("PASS tb_osd_frame: six full frames rendered, 307200 output pixels each");$finish;
 end
endmodule
