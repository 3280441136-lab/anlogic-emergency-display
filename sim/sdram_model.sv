`timescale 1ns/1ps
// Simulation-only behavioral SDR SDRAM with the port list of the EG4 embedded
// EG_PHY_SDRAM_2M_32 (the vendor sim_release file is an empty shell: dq stays Z).
// 4 banks x 2048 rows x 256 columns x 32 bits; commands sampled on the rising clk edge.
// Mode register: CAS latency addr[6:4], burst length 2^addr[2:0] (sequential).
// Protocol checks (counters, readable by the testbench):
//   ref_open_errors   AUTO REFRESH issued while a bank is active
//   closed_access     READ/WRITE to a bank with no active row (data then undefined: the
//                     model returns 32'hffffffff, like an undriven pulled-up bus)
// Read data appears T_AC after the edge before the one where it is due (CL3 tAC 5.4 ns,
// typical 125/133 MHz SDR SDRAM), so it is valid from 5.4 ns after edge n+CL-1 to 5.4 ns
// after edge n+CL. Calibration: with no refresh, the controller must read back every word.
module EG_PHY_SDRAM_2M_32(input clk,ras_n,cas_n,we_n,input [10:0] addr,input [1:0] ba,inout [31:0] dq,
 input cs_n,dm0,dm1,dm2,dm3,cke);
 parameter real T_AC=5.4;
 // tRFC in clocks (8 ns): ~66 ns for 64 Mbit SDR parts. An ACTIVE issued sooner after an
 // AUTO REFRESH is ignored by a real device; the model counts it and leaves the bank closed,
 // so the following reads return the undriven (all ones) bus.
 parameter integer T_RFC=9;
 integer rfc_violations=0;
 reg [31:0] mem[int];
 reg [3:0] open;reg [10:0] row[0:3];
 reg [2:0] cl=3'd2;reg [3:0] bl=4'd1;
 integer ref_open_errors=0,closed_access=0,refreshes=0,mrs_count=0;
 // Minimum observed command spacings in clocks: REF->any command (tRFC), ACT->READ/WRITE
 // (tRCD), PRE->ACT (tRP), ACT->ACT same bank (tRC). 0x7fffffff = never seen.
 integer cyc=0,last_ref=-1000,last_pre=-1000,min_ref_gap=32'h7fffffff,min_rcd=32'h7fffffff,min_rp=32'h7fffffff;
 integer last_act[0:3];integer after_ref_cmds=0;
 initial begin last_act[0]=-1000;last_act[1]=-1000;last_act[2]=-1000;last_act[3]=-1000;end
 // read pipeline: up to 16 pending words, each with remaining edges until due
 reg [31:0] pdata[0:15];integer pdue[0:15];reg pvalid[0:15];
 reg drive=0;reg [31:0] dout=0;
 assign dq=drive?dout:32'bz;
 // write burst state
 integer wleft=0;reg [1:0] wba;reg [7:0] wcol;
 integer rq_left=0;reg [1:0] rba;reg [7:0] rcol;reg rbad;
 integer i,slot;
 function [31:0] key(input [1:0] b,input [10:0] r,input [7:0] c);begin key={11'd0,b,r,c};end endfunction
 task push_read(input [31:0] d);begin
  slot=-1;for(i=0;i<16;i=i+1) if(!pvalid[i]&&slot<0) slot=i;
  pvalid[slot]=1;pdata[slot]=d;pdue[slot]=cl;
 end endtask
 initial begin open=0;for(i=0;i<16;i=i+1) pvalid[i]=0;end
 always @(posedge clk) begin
  // advance pending reads; a word whose due count reaches 1 is presented after this edge
  drive<=#(T_AC) 1'b0;
  for(i=0;i<16;i=i+1) if(pvalid[i]) begin
   pdue[i]=pdue[i]-1;
   if(pdue[i]==1) begin dout<=#(T_AC) pdata[i];drive<=#(T_AC) 1'b1;end
   if(pdue[i]<=0) pvalid[i]=0;
  end
  // continue bursts started earlier; any READ/WRITE/PRECHARGE/BURST STOP interrupts them
  if(!cs_n && cke && ({ras_n,cas_n,we_n}==3'b101 || {ras_n,cas_n,we_n}==3'b100 ||
                     {ras_n,cas_n,we_n}==3'b010 || {ras_n,cas_n,we_n}==3'b110)) begin wleft=0;rq_left=0;end
  if(wleft>0) begin
   mem[key(wba,row[wba],wcol)]=dq;wcol=wcol+1;wleft=wleft-1;
  end
  if(rq_left>0) begin
   push_read(rbad?32'hffffffff:(mem.exists(key(rba,row[rba],rcol))?mem[key(rba,row[rba],rcol)]:32'h0));
   rcol=rcol+1;rq_left=rq_left-1;
  end
  cyc=cyc+1;
  if(!cs_n && cke && {ras_n,cas_n,we_n}!=3'b111 && {ras_n,cas_n,we_n}!=3'b001 && cyc-last_ref<min_ref_gap) min_ref_gap=cyc-last_ref;
  if(!cs_n && cke && {ras_n,cas_n,we_n}==3'b011 && cyc-last_pre<min_rp) min_rp=cyc-last_pre;
  if(!cs_n && cke && ({ras_n,cas_n,we_n}==3'b101||{ras_n,cas_n,we_n}==3'b100) && cyc-last_act[ba]<min_rcd) min_rcd=cyc-last_act[ba];
  if(!cs_n && cke) case({ras_n,cas_n,we_n})
   3'b011: if(cyc-last_ref<T_RFC) rfc_violations=rfc_violations+1;else begin open[ba]=1;row[ba]=addr;last_act[ba]=cyc; end                         // ACTIVE
   3'b010: begin if(addr[10]) open=0;else open[ba]=0;last_pre=cyc;end                      // PRECHARGE
   3'b001: begin refreshes=refreshes+1;last_ref=cyc;if(open!=0) ref_open_errors=ref_open_errors+1;end // AUTO REFRESH
   3'b000: begin cl=addr[6:4];bl=4'd1<<addr[2:0];mrs_count=mrs_count+1;end // MODE REGISTER
   3'b101: begin                                                       // READ
    rba=ba;rcol=addr[7:0];rbad=!open[ba];if(rbad) closed_access=closed_access+1;
    push_read(rbad?32'hffffffff:(mem.exists(key(ba,row[ba],addr[7:0]))?mem[key(ba,row[ba],addr[7:0])]:32'h0));
    rcol=rcol+1;rq_left=bl-1;
    if(addr[10]) open[ba]=0;  // auto precharge (burst continues on the captured row)
   end
   3'b100: begin                                                       // WRITE
    if(!open[ba]) closed_access=closed_access+1;
    else mem[key(ba,row[ba],addr[7:0])]=dq;
    wba=ba;wcol=addr[7:0]+1;wleft=bl-1;if(addr[10]) open[ba]=0;
   end
   default:;
  endcase
 end
endmodule
