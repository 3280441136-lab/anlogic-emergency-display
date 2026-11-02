`timescale 1ns/1ps
module tb_frame_boundary;
 reg clk=0;always #20 clk=~clk;
 reg rst=1,vs=1,request=0;wire frame_start,aligned;
 ed_frame_boundary dut(.clk(clk),.rst(rst),.vs(vs),.read_req(request),.frame_start(frame_start),.read_req_aligned(aligned));
 integer frames=0,i;
 always @(posedge clk)if(!rst&&frame_start)frames=frames+1;
 initial begin
  repeat(3)@(negedge clk);rst=0;request=1;
  // Model no card: the held read request never gets an acknowledgment.
  for(i=0;i<10;i=i+1)begin
   vs=0;@(negedge clk);vs=1;repeat(5)@(negedge clk);
  end
  if(frames!=10||!aligned)$fatal(1,"frame commits stopped while request held %0d",frames);
  request=0;repeat(3)@(negedge clk);if(aligned)$fatal(1,"request did not release");
  $display("PASS tb_frame_boundary: no-card/stalled-memory held request cannot stop frame commits");$finish;
 end
endmodule
