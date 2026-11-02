`timescale 1ns/1ps
module tb_boot_status;
 reg clk=0;always #4 clk=~clk;
 reg rst=1,done=0,fault=0,timeout=0,ready=0;reg [2:0] stage=0;reg [7:0] code=0,detail=0,serr=0,crc=0;
 reg [5:0] complete=0,valid=0;reg [1:0] state=0;reg [2:0] image=0;
 wire [7:0] s0,s1,s2,s3,s4,s5;
 ed_boot_status dut(.clk(clk),.rst(rst),.boot_done(done),.boot_fault(fault),.boot_timeout(timeout),
  .error_stage(stage),.error_code(code),.error_detail(detail),.complete(complete),.resource_valid(valid),
  .state(state),.image(image),.sector_error(serr),.crc_mismatches(crc),.card_ready(ready),
  .seg0(s0),.seg1(s1),.seg2(s2),.seg3(s3),.seg4(s4),.seg5(s5));
 // Official seg_decoder patterns with DP off; X = blank.
 function [7:0] h(input [3:0] v);
  case(v)0:h=8'hc0;1:h=8'hf9;2:h=8'ha4;3:h=8'hb0;4:h=8'h99;5:h=8'h92;6:h=8'h82;7:h=8'hf8;
   8:h=8'h80;9:h=8'h90;10:h=8'h88;11:h=8'h83;12:h=8'hc6;13:h=8'ha1;14:h=8'h86;default:h=8'h8e;endcase
 endfunction
 localparam [7:0] X=8'hff;
 task expect6(input [7:0] e0,e1,e2,e3,e4,e5,input [8*24-1:0] what);
  begin repeat(4) @(negedge clk);
   if({s0,s1,s2,s3,s4,s5}!=={e0,e1,e2,e3,e4,e5}) $fatal(1,"%0s: got %h %h %h %h %h %h",what,s0,s1,s2,s3,s4,s5);
  end
 endtask
 initial begin
  expect6(X,X,X,X,X,X,"reset");
  rst=0;state=1;expect6(h(11),h(1),X,h(0),h(0),h(0),"loading init");
  state=2;valid=6'h1f;image=0;crc=8'h3c;expect6(h(11),h(2),X,h(0),h(3),h(12),"loading scan");
  valid=6'h3f;image=5;crc=0;expect6(h(11),h(2),h(6),h(0),h(0),h(0),"loading image 6");
  fault=1;state=0;stage=1;code=8'h08;detail=8'h08;expect6(h(14),h(1),X,h(0),h(0),h(8),"init ACMD41");
  stage=2;code=8'h80;detail=8'h10;serr=8'h03;image=0;valid=0;expect6(h(14),h(2),X,h(3),h(1),h(0),"scan sector token");
  code=8'h82;detail=8'h10;serr=8'he1;image=1;expect6(h(14),h(3),h(2),h(14),h(1),h(0),"file capture order");
  code=8'h83;detail=8'h32;serr=0;image=1;expect6(h(14),h(4),h(2),h(0),h(3),h(2),"BMP size");
  code=8'h84;detail=8'h46;image=3;expect6(h(14),h(5),h(4),h(0),h(4),h(6),"SDRAM stall");
  stage=0;code=0;detail=0;complete=6'h1f;expect6(h(14),h(6),X,h(0),h(1),h(15),"incomplete");
  timeout=1;state=2;valid=6'h3f;image=3;ready=1;serr=8'h05;expect6(h(14),h(15),h(4),h(5),h(2),h(1),"watchdog");
  serr=8'h44;expect6(h(14),h(15),h(4),h(15),h(2),h(1),"unknown reader code");
  rst=1;@(negedge clk);rst=0;fault=0;timeout=0;done=1;serr=0;expect6(h(0),X,X,X,X,X,"ready");
  serr=8'h05;expect6(h(0),X,X,h(5),X,X,"ready after retry");
  serr=0;crc=8'hff;expect6(h(0),X,X,X,h(15),h(15),"ready CRC mismatches");
  $display("PASS tb_boot_status: loading, ready, init/scan/file/BMP/SDRAM/incomplete/watchdog codes");$finish;
 end
endmodule
