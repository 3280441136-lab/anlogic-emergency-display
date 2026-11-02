`timescale 1ns/1ps
module tb_scope;
 reg clk=0;always #20 clk=~clk;
 reg rst=1,frame_start=0;reg signed [15:0] signal=16'sd8192;reg [6:0] index=0;
 wire signed [7:0] a,b;wire [7:0] pa,pb;
 ed_audio_scope normal(.clk(clk),.rst(rst),.frame_start(frame_start),.valid(1'b1),.eco(1'b0),.signal(signal),.read_index(index),.read_enable(1'b1),.wave(a),.peak(pa));
 ed_audio_scope eco(.clk(clk),.rst(rst),.frame_start(frame_start),.valid(1'b1),.eco(1'b1),.signal(signal),.read_index(index),.read_enable(1'b1),.wave(b),.peak(pb));
 integer frame,c,nwrites=0,ewrites=0,phase=0;
 always @(posedge clk)if(!rst)begin
  if(normal.store||normal.trigger) nwrites=nwrites+1;
  if(eco.store||eco.trigger) ewrites=ewrites+1;
 end
 initial begin
  repeat(3)@(negedge clk);rst=0;
  for(frame=0;frame<20;frame=frame+1)begin
   frame_start=1;@(negedge clk);frame_start=0;
   // 16-sample-period square wave: rising zero crossings for the trigger.
   for(c=0;c<2047;c=c+1)begin @(negedge clk);phase=phase+1;signal=(phase%16<8)?16'sd8192:-16'sd8192;index=index+1'b1;end
  end
  if(^a===1'bx||^b===1'bx)$fatal(1,"uninitialized waveform published");
  if(!normal.scope_valid||!eco.scope_valid)$fatal(1,"no bank published");
  if(normal.banks[0]<0||normal.banks[128]<0)$fatal(1,"capture not aligned to rising zero crossing");
  if(nwrites<ewrites*2)$fatal(1,"ECO did not lower write activity %0d/%0d",nwrites,ewrites);
  if(pa==0||pb==0)$fatal(1,"peak does not use the signal");
  $display("PASS tb_scope: triggered capture at rising zero crossing, banks published, normal writes=%0d ECO writes=%0d",nwrites,ewrites);$finish;
 end
endmodule