`timescale 1ns/1ps
// Official encrypted SDRAM controller + embedded SDRAM model, three configurations:
//   official : App_ref_req tied low (official sdram.v)          -> counts refreshes
//   free     : ed_sdram ARBITRATE=0, refresh pulse at any time  -> data check
//   fixed    : ed_sdram ARBITRATE=1, refresh between bursts     -> data check
// Each data-checked instance gets 8192 known words written in 128-word bursts (the
// project writer's pattern), then 1600 back-to-back 128-word read bursts like the
// official frame_fifo_read (App_rd_en held for the whole burst, Sdr_busy not checked
// inside it). Every returned word is compared with the address that requested it.
module sdram_master #(parameter OBEY_HOLD=1)(input clk,input go,input init_done,busy,ref_vld,hold,
 output reg wr_en,output reg [20:0] wr_addr,output reg [31:0] wr_data,
 output reg rd_en,output reg [20:0] rd_addr,input rv,input [31:0] rd_data,
 output reg finished,output integer errors,output integer returned,output integer issued);
 function [31:0] pattern(input [20:0] a);begin pattern={a[15:0],~a[15:0]}^32'h5a3c0000;end endfunction
 reg [20:0] expected[0:4095];integer head=0,tail=0,b,i,gap;
 initial begin
  wr_en=0;rd_en=0;wr_addr=0;rd_addr=0;wr_data=0;finished=0;errors=0;returned=0;issued=0;
  wait(go);
  for(b=0;b<64;b=b+1) begin
   @(negedge clk);while(busy||ref_vld||(OBEY_HOLD&&hold)) @(negedge clk);
   for(i=0;i<128;i=i+1) begin wr_en=1;wr_addr=b*128+i;wr_data=pattern(b*128+i);@(negedge clk);end
   wr_en=0;repeat(12) @(negedge clk);
  end
  repeat(50) @(negedge clk);
  for(b=0;b<1600;b=b+1) begin
   while(OBEY_HOLD&&hold) @(negedge clk);
   for(i=0;i<128;i=i+1) begin
    rd_en=1;rd_addr=((b*128+i)%8192);expected[head%4096]=rd_addr;head=head+1;issued=issued+1;@(negedge clk);
   end
   rd_en=0;gap=40+((b*37)%160);repeat(gap) @(negedge clk);
  end
  repeat(200) @(negedge clk);finished=1;
 end
 always @(posedge clk) if(rv) begin
  if(rd_data!==pattern(expected[tail%4096])) begin errors=errors+1;if(errors<=6 && OBEY_HOLD) $display("DBG ret#%0d addr %h got %h want %h",tail,expected[tail%4096],rd_data,pattern(expected[tail%4096]));end
  tail=tail+1;returned=returned+1;
 end
endmodule

module tb_sdram_refresh;
 reg clk=0;always #4 clk=~clk;
 reg rst=1,go=0;
 // official: refresh count only
 wire done0,vld0,busy0,rv0;wire [31:0] rd0;
 wire c0_ras,c0_cas,c0_we,c0_clk;wire [1:0] c0_ba;wire [10:0] c0_addr;wire [31:0] c0_dq;wire [3:0] c0_dm;
 sdr_as_ram #(.self_refresh_open(1'b1)) official(.Sdr_clk(clk),.Sdr_clk_sft(~clk),.Rst(rst),
  .Sdr_init_done(done0),.Sdr_init_ref_vld(vld0),.Sdr_busy(busy0),.App_ref_req(1'b0),
  .App_wr_en(1'b0),.App_wr_addr(21'd0),.App_wr_dm(4'd0),.App_wr_din(32'd0),
  .App_rd_en(1'b0),.App_rd_addr(21'd0),.Sdr_rd_en(rv0),.Sdr_rd_dout(rd0),
  .SDRAM_CLK(c0_clk),.SDR_RAS(c0_ras),.SDR_CAS(c0_cas),.SDR_WE(c0_we),.SDR_BA(c0_ba),.SDR_ADDR(c0_addr),.SDR_DM(c0_dm),.SDR_DQ(c0_dq));
 // free-running refresh
 wire d1,v1,bz1,h1,rv1,we1,re1,f1;wire [20:0] wa1,ra1;wire [31:0] wd1,rd1;wire [15:0] n1;integer e1,r1,i1;
 ed_sdram #(.ARBITRATE(0)) free(.Clk(clk),.Clk_sft(~clk),.Rst(rst),.Sdr_init_done(d1),.Sdr_init_ref_vld(v1),.Sdr_busy(bz1),
  .ref_hold(h1),.ref_count(n1),.App_wr_en(we1),.App_wr_addr(wa1),.App_wr_dm(4'd0),.App_wr_din(wd1),
  .App_rd_en(re1),.App_rd_addr(ra1),.Sdr_rd_en(rv1),.Sdr_rd_dout(rd1));
 sdram_master #(.OBEY_HOLD(0)) m1(.clk(clk),.go(go),.init_done(d1),.busy(bz1),.ref_vld(v1),.hold(h1),
  .wr_en(we1),.wr_addr(wa1),.wr_data(wd1),.rd_en(re1),.rd_addr(ra1),.rv(rv1),.rd_data(rd1),
  .finished(f1),.errors(e1),.returned(r1),.issued(i1));
 // scheduled refresh
 wire d2,v2,bz2,h2,rv2,we2,re2,f2;wire [20:0] wa2,ra2;wire [31:0] wd2,rd2;wire [15:0] n2;integer e2,r2,i2;
 ed_sdram #(.ARBITRATE(1)) fixed(.Clk(clk),.Clk_sft(~clk),.Rst(rst),.Sdr_init_done(d2),.Sdr_init_ref_vld(v2),.Sdr_busy(bz2),
  .ref_hold(h2),.ref_count(n2),.App_wr_en(we2),.App_wr_addr(wa2),.App_wr_dm(4'd0),.App_wr_din(wd2),
  .App_rd_en(re2),.App_rd_addr(ra2),.Sdr_rd_en(rv2),.Sdr_rd_dout(rd2));
 sdram_master #(.OBEY_HOLD(1)) m2(.clk(clk),.go(go),.init_done(d2),.busy(bz2),.ref_vld(v2),.hold(h2),
  .wr_en(we2),.wr_addr(wa2),.wr_data(wd2),.rd_en(re2),.rd_addr(ra2),.rv(rv2),.rd_data(rd2),
  .finished(f2),.errors(e2),.returned(r2),.issued(i2));
 integer ref0=0,ref2=0;reg counting=0;
 always @(posedge clk) if(counting) begin
  if(!c0_ras && !c0_cas && c0_we) ref0=ref0+1;
  if(!fixed.SDR_RAS && !fixed.SDR_CAS && fixed.SDR_WE) ref2=ref2+1;
 end
 initial begin
  repeat(10) @(posedge clk);rst=0;
  wait(done0 && d1 && d2);repeat(100) @(posedge clk);counting=1;go=1;
  wait(f1 && f2);counting=0;
  $display("REFRESH official=%0d scheduled=%0d (requests %0d)",ref0,ref2,n2);
  $display("MODEL CL=%0d BL=%0d mrs=%0d | free: ref_open=%0d closed=%0d | fixed: ref_open=%0d closed=%0d refreshes=%0d",fixed.sdram.cl,fixed.sdram.bl,fixed.sdram.mrs_count,free.sdram.ref_open_errors,free.sdram.closed_access,fixed.sdram.ref_open_errors,fixed.sdram.closed_access,fixed.sdram.refreshes);
  $display("GAPS clocks (8 ns): free REF->cmd=%0d RCD=%0d RP=%0d | fixed REF->cmd=%0d RCD=%0d RP=%0d",free.sdram.min_ref_gap,free.sdram.min_rcd,free.sdram.min_rp,fixed.sdram.min_ref_gap,fixed.sdram.min_rcd,fixed.sdram.min_rp);
  $display("tRFC violations: free=%0d fixed=%0d",free.sdram.rfc_violations,fixed.sdram.rfc_violations);
  $display("FREE     refresh requests=%0d reads issued=%0d returned=%0d wrong=%0d",n1,i1,r1,e1);
  $display("SCHEDULE refresh requests=%0d reads issued=%0d returned=%0d wrong=%0d",n2,i2,r2,e2);
  if(ref0!=0) $fatal(1,"official wrapper unexpectedly refreshed");
  if(ref2<n2 || n2<100) $fatal(1,"scheduled refresh commands %0d / requests %0d",ref2,n2);
  if(free.sdram.rfc_violations==0 || e1==0) $fatal(1,"model did not reproduce the free-running refresh failure");
  if(fixed.sdram.rfc_violations!=0) $fatal(1,"scheduled refresh violates tRFC %0d times",fixed.sdram.rfc_violations);
  if(r2!=i2 || e2!=0) $fatal(1,"scheduled refresh corrupted reads: %0d wrong, %0d/%0d returned",e2,r2,i2);
  $display("PASS tb_sdram_refresh: official controller never refreshes; free-running refresh violates tRFC and corrupts %0d of %0d words; scheduled refresh %0d commands, tRFC met, 0 wrong",e1,i1,ref2);
  $finish;
 end
 initial begin #20000000;$fatal(1,"timeout");end
endmodule
