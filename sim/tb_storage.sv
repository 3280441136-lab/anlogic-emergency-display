`timescale 1ns/1ps
module tb_storage;
 reg clk=0;always #4 clk=~clk;reg mclk=0;always #3 mclk=~mclk;   // loader SDRAM side
 reg rst_n=0,start=0;wire busy,done;wire [7:0] err,detail;wire [2:0] current;
 wire [5:0] valid,complete,scale;wire req;wire [31:0] lba;
 reg sector_busy=0,sv=0,sd=0;reg [7:0] sb=0,se=0;reg [8:0] si=0;
 wire we;wire [20:0] addr;wire [31:0] data;wire [3:0] mask;
 reg [7:0] disk[0:65535];reg [31:0] memory[0:23];reg [23:0] seen=0;
 integer phase=0,pos=0,base=0,writes=0;
 media_ingest_frontend #(.IMAGE_WIDTH(2),.IMAGE_HEIGHT(2),.FIFO_DEPTH(256),.MIN_SRC(1)) dut(
  .clk(clk),.rst_n(rst_n),.start(start),.busy(busy),.done(done),.ingest_error(err),.ingest_detail_error(detail),
  .current_image(current),.resource_valid(valid),.image_complete(complete),.image_scaled(scale),
  .reader_req(req),.reader_lba(lba),.reader_busy(sector_busy),.reader_valid(sv),.reader_byte(sb),.reader_byte_index(si),.reader_done(sd),.reader_error(se),
  .mem_clk(mclk),.mem_rst_n(rst_n),.controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(1'b0),
  .app_wr_en(we),.app_wr_addr(addr),.app_wr_mask(mask),.app_wr_data(data));
 always @(negedge clk) begin
  sv=0;sd=0;
  case(phase)
   0:if(req) begin base=lba*512;pos=0;sector_busy=1;phase=1;end
   1:begin sv=1;sb=disk[base+pos];si=pos;pos=pos+1;if(pos==512)phase=2;end
   2:begin sd=1;sector_busy=0;phase=0;end
  endcase
 end
 always @(posedge mclk) if(we) begin
  if(addr>=24) $fatal(1,"out of bank address %0d",addr);
  if(seen[addr]) $fatal(1,"duplicate address %0d",addr);
  seen[addr]<=1;memory[addr]<=data;writes=writes+1;
  if(mask!=0) $fatal(1,"write mask");
 end
 integer i,x,y,expected;
 initial begin
  $readmemh("../sim/fat_fixture.hex",disk);
  repeat(4) @(negedge clk);rst_n=1;@(negedge clk);start=1;@(negedge clk);start=0;
  wait(done);@(negedge clk);
  if(err!=0||complete!=63||scale!=6'b101010||writes!=24) $fatal(1,"ingest error %h/%h complete %h scale %h writes %0d",err,detail,complete,scale,writes);
  for(i=0;i<24;i=i+1) begin
   x=i%2;y=(i%4)/2;expected=((i/4)+1)*20+y*4+x;
   if(memory[i]!=={8'd0,8'd3,8'd2,expected[7:0]}) $fatal(1,"pixel bank/orientation/scale mismatch @%0d = %h",i,memory[i]);
  end
  // Second run: no named resources -> explicit error, never partial ready.
  rst_n=0;repeat(3) @(negedge clk);rst_n=1;disk[1536]=0;disk[1568]=0;disk[1600]=0;disk[1632]=0;disk[1664]=0;disk[1696]=0;
  @(negedge clk);start=1;@(negedge clk);start=0;wait(done);
  if(err==0) $fatal(1,"missing assets not rejected");
  $display("PASS tb_storage: FAT root chain, BMP decode, padding, orientation, 2x averaging, bank writes, missing assets");$finish;
 end
 initial begin #3000000;$fatal(1,"timeout state %0d current %0d error %h/%h",dut.u_ingest_pipeline.state,current,err,detail);end
endmodule
