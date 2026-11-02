`timescale 1ns/1ps
// Shared SPI card bench. CHECK=1: data-CRC mismatch is a sector error (retried, then
// rejected). CHECK=0: product non-protected mode, mismatches are only counted.
module spi_card_bench #(parameter CHECK=1);
 // Product clocks: loading chain 25 MHz, SPI_CLK_DIV 1 (SCLK 12.5 MHz); SDRAM side 125 MHz.
 reg clk=0;always #20 clk=~clk;reg mclk=0;always #4 mclk=~mclk;
 reg rst_n=0,start=0;wire busy,done,ready;wire [2:0] stage;wire [7:0] error,detail;
 wire [5:0] complete;wire we;wire [20:0] addr;wire [31:0] data;
 wire cs,sclk,mosi;reg miso=1;
 reg [7:0] disk[0:65535];reg [7:0] queue[0:8191];
 reg corrupt_crc=0;
 // Per-run card behaviour: CMD17 number (1-based) answered late / with one bad CRC.
 integer slow_read=-1,slow_bytes=5000,bad_crc_read=-1;
 wire [7:0] sector_error,crc_mismatches;reg [31:0] golden[0:23];integer i;
 integer qp=0,qn=0,bitn=0,cmdn=0;reg [7:0] tx=255,rx=0,cmd[0:5];
 reg [31:0] mem[0:23];integer writes=0,sectors=0;
 media_storage_ingest_top #(.SPI_CLK_DIV(1),.INIT_SPI_CLK_DIV(32),.IMAGE_WIDTH(2),.IMAGE_HEIGHT(2),
  .FIFO_DEPTH(256),.MIN_SRC(1),.INIT_STARTUP_DELAY_CYCLES(256),
  .TOKEN_TIMEOUT_BYTES(8192),.SECTOR_RETRIES(3),.CHECK_DATA_CRC(CHECK)) dut(
  .clk(clk),.rst_n(rst_n),.start(start),.busy(busy),.done(done),.error_stage(stage),.error_code(error),.error_detail(detail),
  .card_ready(ready),.card_high_capacity(),.resource_valid(),.image_complete(complete),.image_scaled(),
  .status_state(),.status_image(),.status_sector_error(sector_error),.status_crc_mismatches(crc_mismatches),
  .mem_clk(mclk),.mem_rst_n(rst_n),.controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(1'b0),
  .app_wr_en(we),.app_wr_addr(addr),.app_wr_mask(),.app_wr_data(data),
  .sd_cs_n(cs),.sd_sclk(sclk),.sd_mosi(mosi),.sd_miso(miso));
 function [15:0] crcbyte(input [15:0] crc,input [7:0] val);
  reg [15:0] c;integer j;
  begin c=crc;for(j=7;j>=0;j=j-1) c=(c[15]^val[j])?((c<<1)^16'h1021):(c<<1);crcbyte=c;end
 endfunction
 task respond;
  reg [31:0] lba;reg [15:0] crc;integer j,d;
  begin
   qp=0;qn=0;
   case(cmd[0]&8'h3f)
    0:begin queue[0]=1;qn=1;end
    8:begin queue[0]=1;queue[1]=0;queue[2]=0;queue[3]=1;queue[4]=8'haa;qn=5;end
    55:begin queue[0]=1;qn=1;end
    41:begin queue[0]=0;qn=1;end
    58:begin queue[0]=0;queue[1]=8'hc0;queue[2]=8'hff;queue[3]=8'h80;queue[4]=0;qn=5;end
    17:begin
     lba={cmd[1],cmd[2],cmd[3],cmd[4]};if(lba>=128)$fatal(1,"LBA out of fixture");
     sectors=sectors+1;d=(sectors==slow_read)?slow_bytes:0;
     queue[0]=0;for(j=0;j<d;j=j+1) queue[j+1]=8'hff;queue[d+1]=8'hfe;crc=0;
     for(j=0;j<512;j=j+1) begin queue[d+j+2]=disk[lba*512+j];crc=crcbyte(crc,disk[lba*512+j]);end
     queue[d+514]=crc[15:8];queue[d+515]=crc[7:0]^((corrupt_crc||sectors==bad_crc_read)?8'h01:8'h00);qn=d+516;
    end
    default:begin queue[0]=4;qn=1;end
   endcase
  end
 endtask
 always @(posedge cs) begin bitn=0;cmdn=0;qp=0;qn=0;rx=0;tx=255;miso=1;end
 always @(posedge sclk) if(!cs) begin
  rx={rx[6:0],mosi};bitn=bitn+1;
  if(bitn==8) begin
   bitn=0;
   if(cmdn!=0 || rx[7:6]==2'b01) begin
    cmd[cmdn]=rx;cmdn=cmdn+1;
    if(cmdn==6) begin cmdn=0;respond();end
   end
   rx=0;
   if(qp<qn) begin tx=queue[qp];qp=qp+1;end else tx=255;
  end else tx={tx[6:0],1'b1};
 end
 // Card timing: MISO valid T_OUT after the SCLK fall (14 ns card output delay plus pads and
 // board); MOSI must be stable T_SU before and T_H after each SCLK rise.
 localparam realtime T_OUT=22,T_SU=10,T_H=5;realtime mosi_t=0,rise_t=-100;
 always @(mosi) begin if(!cs && $realtime-rise_t<T_H) $fatal(1,"MOSI hold");mosi_t=$realtime;end
 always @(posedge sclk) if(!cs) begin if($realtime-mosi_t<T_SU) $fatal(1,"MOSI setup");rise_t=$realtime;end
 always @(negedge sclk) if(!cs) begin miso<=1'bx;miso<=#T_OUT tx[7];end
 always @(posedge mclk) if(we) begin
  if(addr>=24)$fatal(1,"address");mem[addr]<=data;writes=writes+1;
 end
 initial begin
  $readmemh("../sim/fat_fixture.hex",disk);
  repeat(5) @(negedge clk);rst_n=1;@(negedge clk);start=1;@(negedge clk);start=0;
  wait(done);@(negedge clk);
  if(error!=0 || complete!=63 || writes!=24 || sector_error!=0 || crc_mismatches!=0) $fatal(1,"SPI ingest %h/%h stage%0d images%h writes%0d sector%h crc%0d",error,detail,stage,complete,writes,sector_error,crc_mismatches);
  for(i=0;i<24;i=i+1) golden[i]=mem[i];
  repeat(1000) @(negedge clk);if(!cs||sclk)$fatal(1,"idle card bus toggles");
  // Slow first read (token after 5000 polls, beyond the old 4096 limit) and one bad
  // CRC on read 2: checked mode retries and reports R=5; unchecked mode only counts it.
  rst_n=0;repeat(5)@(negedge clk);rst_n=1;sectors=0;writes=0;slow_read=1;bad_crc_read=2;
  @(negedge clk);start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
  if(error!=0 || complete!=63 || writes!=24 || sector_error!=(CHECK ? 8'h05 : 8'h00) || crc_mismatches!=1) $fatal(1,"slow/retry ingest %h/%h images%h writes%0d sector%h crc%0d",error,detail,complete,writes,sector_error,crc_mismatches);
  // Card whose data CRC is never valid ("don't care" in SPI non-protected mode).
  rst_n=0;repeat(5)@(negedge clk);rst_n=1;sectors=0;writes=0;slow_read=-1;bad_crc_read=-1;corrupt_crc=1;
  @(negedge clk);start=1;@(negedge clk);start=0;wait(done);@(negedge clk);
  if(CHECK) begin
   if(error==0 || stage!=2 || sector_error!=8'h05 || crc_mismatches!=4) $fatal(1,"bad sector CRC accepted %h stage%0d sector%h crc%0d",error,stage,sector_error,crc_mismatches);
   $display("PASS tb_spi: CMD0/8/55/41/58/17, SDHC addressing, slow token, CRC16 retry and rejection, full FAT32-to-SDRAM writes, idle SPI");
  end else begin
   if(error!=0 || complete!=63 || writes!=24 || sector_error!=0 || crc_mismatches!=sectors) $fatal(1,"don't-care CRC card %h/%h images%h writes%0d sector%h crc%0d/%0d",error,detail,complete,writes,sector_error,crc_mismatches,sectors);
   for(i=0;i<24;i=i+1) if(mem[i]!==golden[i]) $fatal(1,"pixel %0d differs with don't-care CRC",i);
   $display("PASS tb_spi_nocrc: non-protected SPI mode, slow token, every-sector CRC mismatch counted (%0d), identical SDRAM image",crc_mismatches);
  end
  $finish;
 end
 initial begin #60000000;$fatal(1,"SPI timeout state%0d err%h/%h sectors%0d",dut.u_sd_service.u_init.state,error,detail,sectors);end
endmodule

module tb_spi;
 spi_card_bench #(.CHECK(1)) bench();
endmodule
