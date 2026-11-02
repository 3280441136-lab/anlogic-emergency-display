`timescale 1ns/1ps
// Behavioral LUT primitive used only by the unmodified vendor FIFO simulation.
module AL_MAP_LUT1 #(parameter [1:0] INIT=0)(input a,output o);assign o=INIT[a];endmodule
// ed_framebuffer with both read channels: frame 0 bank 0 alone, frame 1 bank 5 with a
// cross-fade from bank 2 (both FIFOs consumed together), frame 2 bank 3 alone again.
// Memory model: data = address, returned 11 clocks after the read command. Checks every
// word of every stream, the read count per frame, that the two channels never issue in
// the same clock or start a burst while the other is busy, no burst starts in mem_hold,
// no underflow (both streams at 25 MHz), and the refresh rate counter.
module tb_framebuffer;
 reg mem=0,pix=0;always #4 mem=~mem;always #20 pix=~pix;
 reg mr=1,pr=1,enabled=0,request=0,consume=0,blend=0;reg [2:0] bank=0,old_bank=0;
 reg refresh=0,hold=0;integer rc=0;
 wire ack,underflow,ren;wire [31:0] data,data_old;wire [20:0] addr;wire [15:0] rate;
 reg [10:0] valpipe=0;reg [31:0] pipe[0:10];
 // Refresh pulse every 250 mem cycles; "second" shortened to 25000 cycles -> rate 100.
 // mem_hold is raised for 30 of every 250 cycles, like ed_sdram's refresh window.
 ed_framebuffer #(.SECOND_CYCLES(25000)) dut(.mem_clk(mem),.mem_rst(mr),.pix_clk(pix),.pix_rst(pr),.enabled(enabled),
 .controller_init_done(1'b1),.controller_busy(1'b0),.refresh_active(refresh),.mem_hold(hold),
 .request(request),.index(bank),.index_old(old_bank),.blend(blend),.consume(consume),.request_ack(ack),
 .data(data),.data_old(data_old),.underflow(underflow),
 .refresh_rate(rate),.app_rd_en(ren),.app_rd_addr(addr),.return_valid(valpipe[10]),.return_data(pipe[10]));
 integer j,word,frame,issued=0,started_in_hold=0,overlap=0;reg ren_d=0,ea_d=0,eb_d=0;
 always @(posedge mem)begin
  valpipe<={valpipe[9:0],ren};pipe[0]<={11'd0,addr};for(j=1;j<11;j=j+1)pipe[j]<=pipe[j-1];
  rc=(rc==249)?0:rc+1;refresh<=(rc<4);hold<=(rc>=200&&rc<230);
  ren_d<=ren;if(ren&&!ren_d&&hold&&rc>=204) started_in_hold=started_in_hold+1;   // allow the decision lag
  if(dut.en_a&&dut.en_b) overlap=overlap+1;
  if((dut.en_a&&!ea_d&&dut.busy_b)||(dut.en_b&&!eb_d&&dut.busy_a)) overlap=overlap+1;
  ea_d<=dut.en_a;eb_d<=dut.en_b;
  if(ren)issued=issued+1;
 end
 initial begin
  repeat(5)@(negedge pix);mr=0;pr=0;enabled=1;
  for(frame=0;frame<3;frame=frame+1)begin
   bank=(frame==0)?0:(frame==1)?5:3;old_bank=2;issued=0;
   // the player changes index/blend at frame_start, the edge where the aligned request rises
   @(negedge pix);request=1;blend=(frame==1);wait(ack);@(negedge pix);request=0;
   repeat(2000)@(negedge pix);
   consume=1;
   for(word=0;word<307200;word=word+1)begin
    @(negedge pix);
    if(data!==(bank*307200+word))$fatal(1,"frame%0d word%0d actual %h",frame,word,data);
    if(blend && data_old!==(old_bank*307200+word))$fatal(1,"old stream frame%0d word%0d actual %h",frame,word,data_old);
   end
   consume=0;repeat(100)@(negedge pix);
   if(issued!=(blend?614400:307200))$fatal(1,"frame%0d request count %0d",frame,issued);
   if(underflow)$fatal(1,"FIFO underflow in frame %0d",frame);
  end
  if(rate!=100)$fatal(1,"refresh rate %0d",rate);
  if(started_in_hold!=0)$fatal(1,"%0d bursts started while mem_hold was high",started_in_hold);
  if(overlap!=0)$fatal(1,"%0d channel overlaps",overlap);
  $display("PASS tb_framebuffer: unmodified vendor readers/FIFOs, bank 0, cross-fade 5 over 2 (both streams exact, 614400 reads), bank 3, arbitration without overlap, no burst starts in mem_hold, no underflow, refresh rate");$finish;
 end
 initial begin #120000000;$fatal(1,"timeout");end
endmodule
