`timescale 1ns/1ps
// Simulation-only W25Q64 behavioral model, SPI mode 0 (sample on SCLK rise, shift out on
// fall). Commands: AB wake, 9F JEDEC ID, 05/35/15 status 1/2/3, 06/04 WREN/WRDI,
// 20 sector erase (4 KB), 02 page program (bits only cleared), 03 read. Erase/program set
// WIP for ERASE_NS / PROG_NS and require WEL; WEL clears afterwards. Memory erased = FF.
// Counters for the testbench: erases, programs, writes_outside (any erase/program below
// GUARD_BASE, which must never happen).
module w25q64_model #(parameter [23:0] JEDEC=24'hef4017, parameter integer ERASE_NS=40000, PROG_NS=8000,
 parameter [23:0] GUARD_BASE=24'h7FE000)(input cs_n,sclk,mosi,output miso,input wp_n,hold_n);
 reg [7:0] mem[int];
 reg wel=0;time busy_until=0;
 integer erases=0,programs=0,writes_outside=0;
 reg [7:0] sh=0,cmd=0,out=8'hff;integer bitn=0,nbytes=0;reg [23:0] addr=0;reg outbit=1;
 assign miso=cs_n?1'bz:outbit;
 function [7:0] rd(input [23:0] a);begin rd=mem.exists(a)?mem[a]:8'hff;end endfunction
 // Evaluated on use: a continuous assign on $time would never re-evaluate.
 function busy;begin busy=$time<busy_until;end endfunction
 task load_out;begin
  case(cmd)
   8'h9f: out=(nbytes==1)?JEDEC[23:16]:(nbytes==2)?JEDEC[15:8]:JEDEC[7:0];
   8'h05: out={6'd0,wel,busy()};
   8'h35,8'h15: out=8'h00;
   8'h03: if(nbytes>=4) begin out=rd(addr);addr=addr+1;end else out=8'hff;
   default: out=8'hff;
  endcase
 end endtask
 task erase_sector(input [23:0] a);integer i;begin
  for(i=0;i<4096;i=i+1) if(mem.exists({a[23:12],12'd0}+i)) mem.delete({a[23:12],12'd0}+i);
 end endtask
 always @(negedge cs_n) begin bitn=0;nbytes=0;cmd=0;out=8'hff;outbit=1;end
 always @(posedge cs_n) begin
  if(nbytes>=4 && cmd==8'h20 && wel && !busy()) begin
   if(addr<GUARD_BASE) writes_outside=writes_outside+1;
   erase_sector(addr);erases=erases+1;busy_until=$time+ERASE_NS;wel=0;
  end
  if(cmd==8'h02 && nbytes>=5) begin programs=programs+1;busy_until=$time+PROG_NS;wel=0;end
 end
 always @(posedge sclk) if(!cs_n) begin
  sh={sh[6:0],mosi};bitn=bitn+1;
  if(bitn==8) begin
   bitn=0;
   if(nbytes==0) begin
    cmd=sh;
    if(cmd==8'h06 && !busy()) wel=1;
    if(cmd==8'h04) wel=0;
   end else if((cmd==8'h03||cmd==8'h20||cmd==8'h02) && nbytes<=3) addr={addr[15:0],sh};
   else if(cmd==8'h02 && nbytes>=4 && wel && !busy()) begin
    if(addr<GUARD_BASE) writes_outside=writes_outside+1;
    mem[addr]=rd(addr)&sh;addr={addr[23:8],addr[7:0]+8'd1};   // page wrap
   end
   nbytes=nbytes+1;
   load_out;
  end
 end
 always @(negedge sclk) if(!cs_n) begin
  outbit=out[7-bitn];
 end
endmodule
