`timescale 1ns/1ps
// bmp24_decoder -> image_fit_scaler -> media_frame_loader on real BMP files: the six
// TF-card deliverables plus scaling cases (sim/scale, made by make_test_fixtures.py).
// Bytes are delivered like the SD path: 512-byte sectors at one byte per clock, and the
// next sector only when the scaler does not request hold. Every SDRAM word is checked
// against the bit-exact Python model (sum and position-weighted sum) and dumped to
// sim/scale/frame_<n>.hex for visual review.
module tb_assets;
 reg clk=0;always #4 clk=~clk;reg mclk=0;always #5 mclk=~mclk;   // loader SDRAM side, unrelated phase
 reg rst_n=0,start=0,fv=0,fe=0;reg [7:0] fb;reg [31:0] offset=0,size=0;
 wire hdr,sv,scommit,topdown,hold,ready,pv,commit,done;wire [11:0] sw,sh;wire [23:0] srgb,rgb;
 wire [7:0] err,serr,merr;wire [10:0] fw,fh;
 reg [2:0] bank=0;wire [5:0] complete;wire we;wire [20:0] addr;wire [31:0] data;
 reg [7:0] source[0:6300000];
 reg [31:0] sum=0,weighted=0,expected_sum[0:15],expected_weighted[0:15];
 reg [23:0] frame[0:307199];
 string files[0:15];integer asset_count;
 integer count=0,fd,n,i,j,k;
 bmp24_decoder #(.MIN_SRC(16),.MAX_SRC(2048)) decoder(.clk(clk),.rst_n(rst_n),.file_start(start),.file_size(size),
  .file_valid(fv),.file_byte(fb),.file_byte_offset(offset),.file_end(fe),.upstream_error(8'd0),.header_accepted(hdr),
  .src_w(sw),.src_h(sh),.pixel_valid(sv),.pixel_rgb(srgb),.frame_commit(scommit),.bmp_done(),.bmp_error(err),
  .top_down(topdown),.pixel_offset());
 image_fit_scaler scaler(.clk(clk),.rst_n(rst_n),.start(start),.header_valid(hdr),.src_w(sw),.src_h(sh),
  .in_valid(sv),.in_rgb(srgb),.in_commit(scommit),.hold(hold),.out_ready(ready),.out_valid(pv),.out_rgb(rgb),
  .out_commit(commit),.error(serr),.fit_w(fw),.fit_h(fh),.scaled());
 media_frame_loader writer(.clk(clk),.rst_n(rst_n),.load_start(start),.image_index(bank),.pixel_valid(pv),.pixel_rgb(rgb),
  .frame_commit(commit),.decode_error(err!=0?err:serr),.top_down(topdown),.load_busy(),.load_done(done),.image_complete(complete),
  .memory_error(merr),.load_ready(ready),
  .mem_clk(mclk),.mem_rst_n(rst_n),.controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(1'b0),.app_wr_en(we),.app_wr_addr(addr),.app_wr_mask(),.app_wr_data(data));
 always @(posedge mclk) if(we)begin
  if(addr<bank*307200 || addr>=(bank+1)*307200)$fatal(1,"bank boundary");
  sum=sum+data;weighted=weighted+data*(addr-bank*307200+1);count=count+1;frame[addr-bank*307200]=data[23:0];
 end
 initial begin
  `include "../sim/asset_checks.vh"
  repeat(4)@(negedge clk);rst_n=1;
  for(i=0;i<asset_count;i=i+1)begin
   fd=$fopen(files[i],"rb");if(fd==0)$fatal(1,"asset missing %0s",files[i]);
   n=$fread(source,fd);$fclose(fd);size=n;bank=i%6;count=0;sum=0;weighted=0;
   @(negedge clk);start=1;@(negedge clk);start=0;
   for(j=0;j<n;j=j+512)begin
    while(hold)@(negedge clk);
    repeat(20)@(negedge clk);                                  // command/token gap
    for(k=j;k<j+512&&k<n;k=k+1)begin fv=1;fb=source[k];offset=k;@(negedge clk);end
    fv=0;
   end
   repeat(4)@(negedge clk);fe=1;@(negedge clk);fe=0;
   wait(done);@(negedge clk);
   if(err!=0||serr!=0||merr!=0||count!=307200||sum!==expected_sum[i]||weighted!==expected_weighted[i])
    $fatal(1,"%0s err%h/%h/%h count%0d sum%h/%h weighted%h/%h",files[i],err,serr,merr,count,sum,expected_sum[i],weighted,expected_weighted[i]);
   $writememh($sformatf("../sim/scale/frame_%0d.hex",i),frame);
   $display("asset %0s: %0dx%0d -> %0dx%0d, 307200 words match the model",files[i],sw,sh,fw,fh);
  end
  $display("PASS tb_assets: %0d BMPs (16..2048 px, both row orders) decoded, fitted (area down / bilinear up, centred) and written bit-exact",asset_count);$finish;
 end
 // Bytes arrive ~100x faster than from the real card, so the serial scaler sets the pace
 // here (about 30-100 clocks per output pixel); on the board the card is the bottleneck.
 initial begin repeat(6) #1000000000;$fatal(1,"asset timeout");end
endmodule
