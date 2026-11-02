`timescale 1ns/1ps
// Wrong chip (JEDEC mismatch): status 2 and never any erase/program.
module tb_settings_wrongchip;
 reg clk=0;always #20 clk=~clk;
 reg rst=1;wire load;wire [15:0] value;wire [2:0] st;wire cs,sck,mosi,miso,wp,hold;
 reg [15:0] live=16'h2892;
 ed_settings_store #(.SAVE_DELAY_CLOSED(100),.SAVE_DELAY_OPEN(300),.STARTUP_CYCLES(50),.POLL_INTERVAL_CYCLES(40)) dut(
  .clk(clk),.rst(rst),.settings(live),.menu_open(1'b0),.cfg_load(load),.cfg_value(value),.status(st),
  .flash_cs_n(cs),.flash_sclk(sck),.flash_mosi(mosi),.flash_wp_n(wp),.flash_hold_n(hold),.flash_miso(miso));
 w25q64_model #(.JEDEC(24'hef4015)) flash(.cs_n(cs),.sclk(sck),.mosi(mosi),.miso(miso),.wp_n(wp),.hold_n(hold));
 initial begin
  repeat(5)@(negedge clk);rst=0;wait(st!=4);live=16'h1111;repeat(3000)@(negedge clk);
  if(st!=2||load||flash.erases!=0||flash.programs!=0) $fatal(1,"wrong chip st%0d erases%0d",st,flash.erases);
  $display("PASS tb_settings_wrongchip: W25Q16-class ID rejected, flash never erased or programmed");$finish;
 end
 initial begin #20000000;$fatal(1,"timeout");end
endmodule
