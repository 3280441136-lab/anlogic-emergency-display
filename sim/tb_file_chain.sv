`timescale 1ns/1ps
module tb_file_chain;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,start=0,sector_busy=0,sv=0,sd=0,bad=0;
 wire busy,done,fv,req;wire [7:0] stream_byte,err;wire [31:0] offset,lba;
 reg [7:0] sb=0;reg [8:0] si=0;integer phase=0,pos=0,sector=0,received=0;
 fat32_file_streamer dut(.clk(clk),.rst_n(rst_n),.file_start(start),.hold(1'b0),.first_cluster(32'd4),.file_size(32'd1025),
 .sectors_per_cluster(8'd1),.fat_start_lba(32'd1),.data_start_lba(32'd100),.max_cluster(32'd50),
 .file_busy(busy),.file_done(done),.file_valid(fv),.file_byte(stream_byte),.file_byte_offset(offset),.fs_error(err),
 .sector_req(req),.sector_lba(lba),.sector_busy(sector_busy),.sector_valid(sv),.sector_byte(sb),.sector_byte_index(si),.sector_done(sd),.sector_error(8'd0));
 always @(negedge clk)begin
  sv=0;sd=0;
  case(phase)
   0:if(req)begin
    sector=lba;if(sector!=1&&sector!=102&&sector!=106&&sector!=104)$fatal(1,"bad cluster LBA %0d",sector);
    sector_busy=1;pos=0;phase=1;
   end
   1:begin
    sv=1;si=pos;sb=pos;
    if(sector==1)begin
     sb=0;
     if(pos==16)sb=bad?4:8;
     if(pos==32)sb=6;
     if(pos>=24&&pos<=27)sb=pos==27?8'h0f:8'hff;
    end
    pos=pos+1;if(pos==512)phase=2;
   end
   2:begin sd=1;sector_busy=0;phase=0;end
  endcase
 end
 always @(posedge clk)if(fv)begin
  if(offset!=received||stream_byte!==offset[7:0])$fatal(1,"file stream order at %0d",received);
  received=received+1;
 end
 initial begin
  repeat(4)@(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
  if(err!=0||received!=1025)$fatal(1,"fragmented file fails %h %0d",err,received);
  rst_n=0;repeat(3)@(negedge clk);rst_n=1;bad=1;received=0;
  start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
  if(err!=8'h23)$fatal(1,"self-loop not rejected %h",err);
  $display("PASS tb_file_chain: fragmented FAT32 clusters, exact final stream_byte, EOC validation and self-loop rejection");$finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule

