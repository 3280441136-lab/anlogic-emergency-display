`timescale 1ns/1ps
// ed_settings_store with the adapted course flash modules and a W25Q64 model:
// blank flash, save, reload after "power cycle", alternate slots, save timing (menu closed:
// almost at once, program only; menu open: after the open delay), background pre-erase,
// power cut during a program falls back to the newest complete record, CRC rejection.
module tb_settings_store;
 reg clk=0;always #20 clk=~clk;           // 25 MHz pixel clock
 reg rst=1;reg menu=0;reg [15:0] live=16'h2892;   // controls model: defaults packed
 wire load;wire [15:0] value;wire [2:0] st;
 wire cs,sck,mosi,miso,wp,hold;
 ed_settings_store #(.SAVE_DELAY_CLOSED(100),.SAVE_DELAY_OPEN(3000),.STARTUP_CYCLES(50),.POLL_INTERVAL_CYCLES(40)) dut(
  .clk(clk),.rst(rst),.settings(live),.menu_open(menu),.cfg_load(load),.cfg_value(value),.status(st),
  .flash_cs_n(cs),.flash_sclk(sck),.flash_mosi(mosi),.flash_wp_n(wp),.flash_hold_n(hold),.flash_miso(miso));
 w25q64_model flash(.cs_n(cs),.sclk(sck),.mosi(mosi),.miso(miso),.wp_n(wp),.hold_n(hold));
 integer loads=0;reg [15:0] last_load;
 always @(posedge clk) if(load) begin loads=loads+1;last_load=value;live<=value;end
 task boot;begin rst=1;repeat(5)@(negedge clk);rst=0;wait(st!=4);repeat(5)@(negedge clk);end endtask
 task wait_saved;integer t;begin
  t=0;while(st!=4 && t<5000) begin @(negedge clk);t=t+1;end
  if(st!=4) $fatal(1,"no write started");
  wait(st!=4);@(negedge clk);
 end endtask
 function [15:0] rec(input [23:0] a,input integer k);begin
  rec={flash.rd(a+2*k),flash.rd(a+2*k+1)};
 end endfunction
 localparam [15:0] D=16'h2892,S1=16'h1d23,S2=16'h3a5c,S3=16'h0001,S4=16'h4123;
 integer e0,t0;
 initial begin
  // 1 blank flash: defaults, no load, nothing written
  live=D;boot;if(st!=0||loads!=0||flash.erases!=0) $fatal(1,"blank: st%0d loads%0d",st,loads);
  // 2 change -> after the stable delay one record in slot 0, seq 1
  live=S1;wait_saved;
  if(st!=1||rec(24'h7FE000,0)!==16'h4E4C||rec(24'h7FE000,1)!==16'd1||rec(24'h7FE000,2)!==S1) $fatal(1,"save1");
  // 3 power cycle: settings back to defaults, the stored value is loaded
  live=D;boot;if(loads!=1||last_load!==S1||st!=1) $fatal(1,"reload1 loads%0d %h",loads,last_load);
  // 4 next change goes to slot 1, seq 2; reboot loads it
  live=S2;wait_saved;if(rec(24'h7FF000,1)!==16'd2||rec(24'h7FF000,2)!==S2) $fatal(1,"save2 slot1");
  live=D;boot;if(last_load!==S2) $fatal(1,"reload2 %h",last_load);
  // 5a menu open: no write before the open delay; closing the menu saves within the short
  //    closed delay, as a page program only (slot 0 was erased in the background).
  repeat(6000)@(negedge clk);   // boot pre-erase of slot 0 (held S1) completes
  menu=1;live=S3;repeat(1500)@(negedge clk);if(st==4||rec(24'h7FE000,1)!==16'hffff) $fatal(1,"wrote early with menu open");
  e0=flash.erases;t0=$time;menu=0;wait_saved;
  if(rec(24'h7FE000,1)!==16'd3||rec(24'h7FE000,2)!==S3) $fatal(1,"save3");
  if(flash.erases!=e0) $fatal(1,"save needed an erase");
  if($time-t0>200000) $fatal(1,"save after menu close took %0t",$time-t0);
  // 5b menu left open: saved after the open delay (slot 1, seq 4), menu still open
  repeat(3000)@(negedge clk);menu=1;live=S4;wait_saved;menu=0;
  if(rec(24'h7FF000,1)!==16'd4||rec(24'h7FF000,2)!==S4) $fatal(1,"save4 with menu open");
  repeat(3000)@(negedge clk);if(rec(24'h7FE000,0)!==16'hffff) $fatal(1,"old slot not pre-erased");
  // 6 power cut while the next record was being programmed into slot 0 (half written):
  //   the newest complete record (S4) loads, and slot 0 is erased again at boot.
  flash.mem[24'h7FE000]=8'h4E;flash.mem[24'h7FE001]=8'h4C;flash.mem[24'h7FE003]=8'h05;
  live=D;boot;if(last_load!==S4||st!=1) $fatal(1,"fallback %h",last_load);
  repeat(3000)@(negedge clk);if(rec(24'h7FE000,0)!==16'hffff) $fatal(1,"half record not erased at boot");
  // 7 corrupted CRC in both slots: defaults, status 0
  flash.mem[24'h7FF006]=8'h00;loads=0;live=D;boot;
  if(loads!=0||st!=0) $fatal(1,"bad crc accepted");
  if(flash.writes_outside!=0) $fatal(1,"write outside the settings sectors");
  $display("PASS tb_settings_store: blank, save, reload, alternate slots, close-menu save without erase, open-menu delayed save, background pre-erase, half-programmed fallback, CRC rejection, %0d erases all inside 7FE000-7FFFFF",flash.erases);
  $finish;
 end
 initial begin #50000000;$fatal(1,"timeout st%0d state%0d",st,dut.state);end
endmodule

