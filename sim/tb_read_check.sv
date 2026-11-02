`timescale 1ns/1ps
module tb_read_check;
 reg clk=0;always #2 clk=~clk;
 reg rst=1,fs=0,ready=0,de=0;reg [23:0] pixel=0;reg [2:0] index=0;
 reg [31:0] ls0=0,ls1=0,ls2=0,ls3=0,ls4=0,ls5=0;
 wire [7:0] changes,mismatches;
 // 4-word frames keep the bench short; the product uses 307200.
 ed_read_check #(.FRAME_WORDS(4)) dut(.clk(clk),.rst(rst),.frame_start(fs),.ready(ready),.de(de),.pixel(pixel),.index(index),
  .load_sum0(ls0),.load_sum1(ls1),.load_sum2(ls2),.load_sum3(ls3),.load_sum4(ls4),.load_sum5(ls5),.frame_changes(changes),.load_mismatches(mismatches));
 // One frame: four pixels base..base+3 (one optionally corrupted), then frame_start.
 task frame(input [23:0] base,input integer bad);
  integer i;
  begin
   for(i=0;i<4;i=i+1) begin @(negedge clk);de=1;pixel=base+i+((i==bad)?24'h000080:0);end
   @(negedge clk);de=0;repeat(3)@(negedge clk);fs=1;@(negedge clk);fs=0;
  end
 endtask
 initial begin
  ls0=4*100+6;ls5=4*200+6;   // sums of 100..103 (bank 0) and 200..203 (bank 5)
  repeat(3)@(negedge clk);rst=0;ready=1;
  fs=1;@(negedge clk);fs=0;
  repeat(6) frame(100,-1);
  if(changes!=0||mismatches!=0) $fatal(1,"clean frames counted %0d/%0d",changes,mismatches);
  frame(100,2);   // one corrupt read: differs from previous and from load
  frame(100,-1);  // back to good: differs from previous only
  if(changes!=2||mismatches!=1) $fatal(1,"read glitch %0d/%0d",changes,mismatches);
  // Bank switch: first frames after the switch are not compared.
  index=5;frame(100,-1);frame(200,-1);frame(200,-1);
  if(changes!=2||mismatches!=1) $fatal(1,"switch settling %0d/%0d",changes,mismatches);
  frame(200,-1);frame(200,-1);
  if(changes!=2||mismatches!=1) $fatal(1,"bank 5 clean %0d/%0d",changes,mismatches);
  // Stable but wrong data in SDRAM: every frame mismatches the load sum, never changes.
  ls5=ls5+1;frame(200,-1);frame(200,-1);
  if(changes!=2||mismatches!=3) $fatal(1,"stable wrong data %0d/%0d",changes,mismatches);
  $display("PASS tb_read_check: clean frames, read glitch, bank-switch settling, stable load mismatch");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
