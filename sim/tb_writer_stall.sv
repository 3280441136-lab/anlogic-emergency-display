`timescale 1ns/1ps
module tb_writer_stall;
 reg clk=0;always #4 clk=~clk;reg mclk=0;always #3 mclk=~mclk;   // loader SDRAM side
 reg rst_n=0,start=0,pv=0,commit=0;reg [23:0] rgb=0;
 wire done,we;wire [5:0] complete;wire [7:0] error;wire [20:0] addr;wire [31:0] data;
 integer writes=0,i;
 media_frame_loader #(.IMAGE_WORDS(4),.FRAME_WIDTH(2),.FRAME_HEIGHT(2),.STALL_TIMEOUT(31)) dut(
 .clk(clk),.rst_n(rst_n),.load_start(start),.image_index(3'd0),.pixel_valid(pv),.pixel_rgb(rgb),.frame_commit(commit),
 .decode_error(8'd0),.top_down(1'b1),.load_busy(),.load_done(done),.image_complete(complete),.memory_error(error),
 .mem_clk(mclk),.mem_rst_n(rst_n),.controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(1'b0),.app_wr_en(we),.app_wr_addr(addr),.app_wr_mask(),.app_wr_data(data));
 always @(posedge mclk)if(we)begin if(data!==addr+1)$fatal(1,"write data/addr mismatch: addr %0d data %0d",addr,data);writes=writes+1;end
 initial begin
  repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);start=1;   // vendor FIFO releases its reset 2 clocks later
  @(negedge clk);start=0;
  pv=1;rgb=1;@(negedge clk);pv=0;
  repeat(100)@(negedge clk);if(error!=0)$fatal(1,"normal SD wait treated as memory stall");
  for(i=2;i<=4;i=i+1)begin pv=1;rgb=i;@(negedge clk);pv=0;repeat(100)@(negedge clk);end
  commit=1;@(negedge clk);commit=0;wait(done);@(negedge clk);
  if(error!=0||complete!=1||writes!=4)$fatal(1,"partial final burst fails");
  $display("PASS tb_writer_stall: slow card gaps do not trip memory watchdog; final partial burst drains");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule
