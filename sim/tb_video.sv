`timescale 1ns/1ps
module tb_video;
 reg clk=0;always #20 clk=~clk;
 reg rst=1,fs=0,de=0,vs=1,ready=1;reg [9:0] x=0,y=100;
 reg [23:0] pixel=24'h102030;reg [2:0] brightness=2,contrast=2;reg [4:0] gain=16;
 reg [23:0] old_px=24'h000000;reg blend=0;reg [4:0] mix=16;
 wire od,ov;wire [23:0] rgb;
 ed_video dut(.clk(clk),.rst(rst),.frame_start(fs),.x(x),.y(y),.de(de),.vs(vs),.pixel(pixel),.pixel_old(old_px),.blend(blend),.mix(mix),
 .ready(ready),.fault(1'b0),.underflow(1'b0),.mode(2'd0),.index(3'd0),.effect(2'd0),.osd(2'd1),.brightness(brightness),.contrast(contrast),
 .volume(3'd2),.auto_en(1'b1),.eco(1'b0),.debug(1'b1),.menu_open(1'b0),.menu_sel(4'd0),.gain(gain),.wipe(1'b0),.reveal(6'd40),
 .wave(8'sd0),.peak(8'd0),.spec(6'd0),.spec_peak_bin(6'd22),.spec_peak_h(6'd63),.diag_rd(8'h3c),.diag_ld(8'h00),.diag_ref(16'h7d00),.diag_crc(8'h00),.diag_flash(3'd1),
 .wave_index(),.wave_rd(),.spec_index(),.spec_rd(),.out_de(od),.out_vs(ov),.rgb(rgb));
 task commit;begin fs=1;@(negedge clk);fs=0;repeat(5)@(negedge clk);end endtask
 initial begin
  repeat(4)@(negedge clk);rst=0;commit();de=1;repeat(5)@(negedge clk);
  if(rgb!==24'h102030 || !od) $fatal(1,"identity / DE mismatch %h",rgb);
  brightness=4;repeat(5)@(negedge clk);if(rgb!==24'h102030)$fatal(1,"midframe parameter change");
  commit();if(rgb!==24'h304050)$fatal(1,"brightness %h",rgb);
  contrast=4;pixel=24'hff0080;commit();if(rgb!==24'hff00a0)$fatal(1,"signed contrast clamp %h",rgb);
  // cross-fade: identity settings, (new*mix + old*(16-mix))/16 per channel
  brightness=2;contrast=2;commit();pixel=24'hf08020;old_px=24'h1060c0;blend=1;mix=4;repeat(5)@(negedge clk);
  if(rgb!==24'h486898)$fatal(1,"cross-fade mix 4/16 %h",rgb);
  mix=16;repeat(5)@(negedge clk);if(rgb!==24'hf08020)$fatal(1,"cross-fade end %h",rgb);
  blend=0;brightness=4;contrast=4;pixel=24'hff0080;commit();
  gain=0;repeat(5)@(negedge clk);if(rgb!==0)$fatal(1,"fade does not reach black %h",rgb);
  if(dut.glyphs[16]===16'hxxxx || dut.messages[0]===8'hxx) $fatal(1,"font ROM not initialized");
  // Status-line text: diagnostic hex digits and the menu cursor (combinational select).
  x=10'd44*8;#1 if(dut.character!=="3") $fatal(1,"RD high digit %s",dut.character);
  x=10'd45*8;#1 if(dut.character!=="C") $fatal(1,"RD low digit %s",dut.character);
  x=10'd56*8;#1 if(dut.character!=="7") $fatal(1,"RF digit %s",dut.character);
  x=10'd20*8;#1 if(dut.character!=="4") $fatal(1,"brightness field %s",dut.character);
  // audio panel readings: 22 x 46.875 = 1031 Hz, height 63 = 100 %
  x=10'd57*8;y=10'd330;#1 if(dut.text_char!=="1") $fatal(1,"Hz thousands %s",dut.text_char);
  x=10'd58*8;#1 if(dut.text_char!=="0") $fatal(1,"Hz digit %s",dut.text_char);
  x=10'd60*8;#1 if(dut.text_char!=="1") $fatal(1,"Hz last digit %s",dut.text_char);
  x=10'd64*8;#1 if(dut.text_char!=="1") $fatal(1,"percent %s",dut.text_char);
  x=10'd56*8;y=10'd418;#1 if(dut.text_char!=="1") $fatal(1,"1.5k tick %s",dut.text_char);
  y=10'd100;
  $display("PASS tb_video: frame-committed parameters, identity, saturation, true-black fade, cross-fade mix, ROM load, DE alignment");$finish;
 end
endmodule
