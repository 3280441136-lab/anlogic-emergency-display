`timescale 1ns/1ps
// media_frame_loader across the board clocks: producer at 25 MHz pushing one pixel per
// clock whenever load_ready (worst case), SDRAM side at 125 MHz with random controller_busy
// and a periodic refresh hold. Checks every word's address and data for both row orders,
// 128-word contiguous bursts with >= 12 idle cycles between them, no burst start in a
// refresh hold or busy period, and the memory stall watchdog (46) followed by a clean image.
module tb_loader_cdc;
 reg pix=0,mem=0;always #20 pix=~pix;initial begin #1.3;forever #4 mem=~mem;end
 reg rst_n=0,start=0,pv=0,commit=0,topdown=1;reg [2:0] bank=0;reg [23:0] rgb=0;
 reg busy=0,hold=0,force_busy=0;
 wire ready,done,we;wire [5:0] complete;wire [7:0] error;wire [20:0] addr;wire [31:0] data;
 media_frame_loader #(.STALL_TIMEOUT(4095)) dut(.clk(pix),.rst_n(rst_n),.load_start(start),.image_index(bank),
  .pixel_valid(pv),.pixel_rgb(rgb),.frame_commit(commit),.decode_error(8'd0),.top_down(topdown),
  .load_busy(),.load_done(done),.image_complete(complete),.load_ready(ready),.memory_error(error),
  .mem_clk(mem),.mem_rst_n(rst_n),.controller_init_done(1'b1),.controller_busy(busy||force_busy),.refresh_active(hold),
  .app_wr_en(we),.app_wr_addr(addr),.app_wr_mask(),.app_wr_data(data));
 function [23:0] pixel(input [2:0] b,input integer i);pixel=i^({b,21'd0});endfunction
 // ---------------- SDRAM-side monitor ----------------
 reg seen[0:1843199];integer writes=0,run=0,gap=99,rc=0,busy_age=0,hold_age=0,check_data=1;reg we_d=0;
 integer off,row,col,idx;
 always @(posedge mem) begin
  rc=(rc==249)?0:rc+1;hold<=(rc>=200&&rc<230);busy<=($urandom%64)==0 ? ~busy : busy;
  hold_age=hold?hold_age+1:0;busy_age=(busy||force_busy)?busy_age+1:0;
  if(we&&!we_d) begin
   if(gap<12)$fatal(1,"burst gap %0d",gap);
   // A start decided just before the hold is seen reaches app_wr_en 5 monitor cycles later.
   if(hold_age>5||busy_age>5)$fatal(1,"burst started in hold (%0d) / busy (%0d)",hold_age,busy_age);
  end
  if(!we&&we_d&&run!=128)$fatal(1,"burst length %0d",run);
  if(we) begin
   run=we_d?run+1:1;gap=0;
   if(addr<bank*307200||addr>=(bank+1)*307200)$fatal(1,"bank boundary %0d",addr);
   if(seen[addr])$fatal(1,"duplicate address %0d",addr);seen[addr]=1;
   off=addr-bank*307200;row=off/640;col=off%640;idx=(topdown?row:479-row)*640+col;
   if(check_data&&data!=={8'd0,pixel(bank,idx)})$fatal(1,"addr %0d data %h expected %h",addr,data,pixel(bank,idx));
   writes=writes+1;
  end else gap=gap+1;
  we_d=we;
 end
 // ---------------- producer ----------------
 integer i,k;
 task load(input [2:0] b,input td);
  begin
   @(negedge pix);bank=b;topdown=td;writes=0;start=1;@(negedge pix);start=0;
   i=0;
   while(i<307200) begin
    pv=ready;if(ready) begin rgb=pixel(b,i);i=i+1;end
    @(negedge pix);
   end
   pv=0;commit=1;@(negedge pix);commit=0;
   wait(done);@(negedge pix);
  end
 endtask
 initial begin
  for(k=0;k<1843200;k=k+1)seen[k]=0;
  repeat(5)@(negedge pix);rst_n=1;repeat(5)@(negedge pix);
  load(0,1);if(error!=0||complete!=6'b000001||writes!=307200)$fatal(1,"top-down: err %h complete %b writes %0d",error,complete,writes);
  load(5,0);if(error!=0||complete!=6'b100001||writes!=307200)$fatal(1,"bottom-up: err %h complete %b writes %0d",error,complete,writes);
  // Stall: controller busy for 20000 SDRAM cycles in the middle of the image.
  fork
   load(1,1);
   begin repeat(20000)@(negedge pix);force_busy=1;check_data=0;repeat(20000)@(posedge mem);force_busy=0;end
  join
  if(error!=8'h46||complete[1])$fatal(1,"stall: err %h complete %b",error,complete);
  check_data=1;
  load(4,0);if(error!=0||complete!=6'b110001||writes!=307200)$fatal(1,"after stall: err %h complete %b writes %0d",error,complete,writes);
  $display("PASS tb_loader_cdc: 25->125 MHz async FIFO and req/ack, both row orders bit-exact, 128-word bursts, refresh/busy respected, stall 46 then clean image");
  $finish;
 end
 initial begin #200000000;$fatal(1,"timeout");end
endmodule
