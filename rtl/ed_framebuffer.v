// Read adapter, two channels, each the official memory request state machine
// (frame_fifo_read) with its own vendor async FIFO:
//   A: the displayed image (index), every frame;
//   B: the previous image (index_old), only in frames where blend is set (cross-fade).
// read_req is a held request; acks are synchronized to pix_clk. index/index_old/blend are
// stable across the held request (committed by the player at frame_start, in vertical
// blank). B is requested only when blend is set; the combined ack waits for both.
// SDRAM arbitration: the official reader only checks App_wr_busy before starting a burst
// (S_CHECK_FIFO) and reports O_rd_busy from that burst until 10 clocks after its last read
// command. A reader may start only while the other is not busy, no refresh is pending
// (mem_hold), and the grant register points at it; the grant alternates every clock while
// both are idle, so the two can never start in the same clock. Read returns are in order:
// a 64-entry tag FIFO (one bit per read command) sends each returned word to its channel.
// SDRAM refresh is issued by ed_sdram between bursts (mem_hold).
// refresh_rate: controller refresh pulses (rising edges of Sdr_init_ref_vld) per second,
// for diagnosis; crosses to pix_clk by toggle handshake on a value held for 1 s.
module ed_framebuffer #(
 parameter SECOND_CYCLES=125000000
)(
 input mem_clk,mem_rst,pix_clk,pix_rst,input enabled,
 input controller_init_done,controller_busy,refresh_active,
 // mem domain: refresh scheduled (ed_sdram ref_hold): blocks the start of new bursts.
 input mem_hold,
 // pix domain. index/index_old: banks 0..5. consume reads A, and B too in blend frames.
 input request,input [2:0] index,index_old,input blend,input consume,
 output request_ack,output [31:0] data,data_old,output reg underflow,
 output reg [15:0] refresh_rate,     // pix domain
 output app_rd_en,output [20:0] app_rd_addr,
 input return_valid,input [31:0] return_data
);
 wire ack_a,ack_b,clr_a,clr_b,empty_a,empty_b,full_a,full_b,busy_a,busy_b,en_a,en_b;
 wire [8:0] used_a,used_b;wire [20:0] addr_a,addr_b;
 reg [1:0] ack_sync_a,ack_sync_b,enable_sync;
 reg armed,request_d,request_d2,use_b;
 // ---------------- mem domain: refresh pulse rate ----------------
 // enabled (pix domain, boot done, monotonic until reset) -> two flip-flop synchronizer.
 reg [26:0] second;reg [15:0] ref_count,ref_hold;reg ref_d,ref_toggle;reg [1:0] enable_mem;
 always @(posedge mem_clk or posedge mem_rst) begin
  if(mem_rst) begin second<=0;ref_count<=0;ref_hold<=0;ref_d<=0;ref_toggle<=0;enable_mem<=0;end
  else begin
   ref_d<=refresh_active;enable_mem<={enable_mem[0],enabled};
   if(second==SECOND_CYCLES-1) begin
    second<=0;ref_hold<=ref_count;ref_toggle<=~ref_toggle;
    ref_count<=(refresh_active&&!ref_d) ? 16'd1 : 16'd0;
   end else begin
    second<=second+1'b1;
    if(refresh_active && !ref_d && ref_count!=16'hffff) ref_count<=ref_count+1'b1;
   end
  end
 end
 // ---------------- pix domain ----------------
 // use_b: blend of this frame, taken two clocks after the request rises (the player
 // updates blend on the frame_start edge, which coincides with the aligned request).
 reg [2:0] ref_toggle_sync;
 always @(posedge pix_clk or posedge pix_rst) begin
  if(pix_rst) begin
   ack_sync_a<=0;ack_sync_b<=0;enable_sync<=0;underflow<=0;armed<=0;request_d<=0;request_d2<=0;use_b<=0;
   ref_toggle_sync<=0;refresh_rate<=0;
  end else begin
   ack_sync_a<={ack_sync_a[0],ack_a};ack_sync_b<={ack_sync_b[0],ack_b};enable_sync<={enable_sync[0],enabled};
   request_d<=request;request_d2<=request_d;
   if(request_d&&!request_d2) use_b<=blend;
   if(request&&!request_d&&enable_sync[1]) armed<=1;
   if(consume&&armed&&(empty_a||(use_b&&empty_b))) underflow<=1;
   // ref_hold changed one mem cycle before the toggle and then holds for 1 s.
   ref_toggle_sync<={ref_toggle_sync[1:0],ref_toggle};
   if(ref_toggle_sync[2]!=ref_toggle_sync[1]) refresh_rate<=ref_hold;
  end
 end
 // B's request starts once use_b is valid (two clocks after A's) and ends with A's.
 wire request_b=request && request_d2 && use_b;
 assign request_ack=ack_sync_a[1] && (!use_b || ack_sync_b[1]);
 // Bank base addresses in the mem domain: indices (quasi-static, see above) through two
 // flip-flops, then a registered constant table. Settles 3 mem clocks after a change, well
 // before a reader's three-flop request synchronizer can see the delayed request.
 function [20:0] bank_base;input [2:0] i;begin case(i)
  0:bank_base=21'd0;1:bank_base=21'd307200;2:bank_base=21'd614400;3:bank_base=21'd921600;
  4:bank_base=21'd1228800;default:bank_base=21'd1536000;endcase end endfunction
 reg [2:0] index_m0,index_m1,old_m0,old_m1;reg [20:0] base_a,base_b;
 always @(posedge mem_clk) begin
  index_m0<=index;index_m1<=index_m0;base_a<=bank_base(index_m1);
  old_m0<=index_old;old_m1<=old_m0;base_b<=bank_base(old_m1);
 end
 // ---------------- arbitration and return routing (mem domain) ----------------
 reg grant_b;
 always @(posedge mem_clk or posedge mem_rst)
  if(mem_rst) grant_b<=0;else if(!busy_a && !busy_b) grant_b<=~grant_b;
 wire block_a=mem_hold || busy_b || grant_b;
 wire block_b=mem_hold || busy_a || !grant_b;
 assign app_rd_en=en_a||en_b;
 assign app_rd_addr=en_b ? addr_b : addr_a;
 reg tags[0:63];reg [5:0] tag_wp,tag_rp;
 always @(posedge mem_clk) if(app_rd_en) tags[tag_wp]<=en_b;
 always @(posedge mem_clk or posedge mem_rst)
  if(mem_rst) begin tag_wp<=0;tag_rp<=0;end
  else begin if(app_rd_en) tag_wp<=tag_wp+1'b1;if(return_valid) tag_rp<=tag_rp+1'b1;end
 wire ret_b=tags[tag_rp];
 // read_req goes straight to the official readers, which synchronize it (three flops).
 frame_fifo_read #(.BURST_SIZE(128)) u_read(
  .rst(mem_rst),.mem_clk(mem_clk),.Sdr_init_done(controller_init_done&&enable_mem[1]),
  .Sdr_init_ref_vld(refresh_active),.Sdr_busy(controller_busy),.Sdr_rd_en(return_valid&&!ret_b),
  .App_wr_busy(block_a),.O_rd_busy(busy_a),.App_rd_en(en_a),.App_rd_addr(addr_a),
  .read_req(request),.read_req_ack(ack_a),.read_finish(),
  .read_addr_0(base_a),.read_addr_1(21'd0),.read_addr_2(21'd0),.read_addr_3(21'd0),
  .read_addr_index(2'd0),.read_len(21'd307200),.fifo_aclr(clr_a),.wrusedw({1'b0,used_a})
 );
 rfifo_32_32_512 u_fifo(
  .rst(clr_a||mem_rst||pix_rst),.clkw(mem_clk),.clkr(pix_clk),
  .we(return_valid&&!ret_b&&!full_a),.di(return_data),.re(consume&&!empty_a),.dout(data),
  .full_flag(full_a),.empty_flag(empty_a),.wrusedw(used_a),.rdusedw(),.valid(),.afull(),.aempty()
 );
 frame_fifo_read #(.BURST_SIZE(128)) u_read_b(
  .rst(mem_rst),.mem_clk(mem_clk),.Sdr_init_done(controller_init_done&&enable_mem[1]),
  .Sdr_init_ref_vld(refresh_active),.Sdr_busy(controller_busy),.Sdr_rd_en(return_valid&&ret_b),
  .App_wr_busy(block_b),.O_rd_busy(busy_b),.App_rd_en(en_b),.App_rd_addr(addr_b),
  .read_req(request_b),.read_req_ack(ack_b),.read_finish(),
  .read_addr_0(base_b),.read_addr_1(21'd0),.read_addr_2(21'd0),.read_addr_3(21'd0),
  .read_addr_index(2'd0),.read_len(21'd307200),.fifo_aclr(clr_b),.wrusedw({1'b0,used_b})
 );
 rfifo_32_32_512 u_fifo_b(
  .rst(clr_b||mem_rst||pix_rst),.clkw(mem_clk),.clkr(pix_clk),
  .we(return_valid&&ret_b&&!full_b),.di(return_data),.re(consume&&use_b&&!empty_b),.dout(data_old),
  .full_flag(full_b),.empty_flag(empty_b),.wrusedw(used_b),.rdusedw(),.valid(),.afull(),.aempty()
 );
endmodule
// A frame boundary must not depend on the memory request being acknowledged.
// No card / stalled boot still has free-running HDMI timing and fault OSD.
// Delay held read request two pixel clocks so frame-committed index is stable
// before the official memory-domain request synchronizer captures it.
module ed_frame_boundary(input clk,rst,vs,read_req,output frame_start,read_req_aligned);
 reg vs_previous;reg [1:0] request_delay;
 always @(posedge clk or posedge rst)begin
  if(rst)begin vs_previous<=1;request_delay<=0;end
  else begin vs_previous<=vs;request_delay<={request_delay[0],read_req};end
 end
 assign frame_start=vs_previous&&!vs;
 assign read_req_aligned=request_delay[1];
endmodule

// Read-back integrity check, pixel domain, active-high async reset.
// Sums the raw SDRAM pixels (before OSD/adjustment) of every displayed frame. Once the
// bank index has been unchanged for two earlier full frames, each frame sum is compared
// with the previous frame (frame_changes: SDRAM read instability) and with the sum of
// the words written at boot (load_mismatches: write or read corruption). Equal sums
// with visible defects mean the data was already wrong when it left the TF card.
// load_sum* come from the storage domain and are quasi-static: they stop changing
// before boot_done, and are used only while ready (boot_done after a two-flop
// synchronizer). They are captured here once per pixel clock with no logic in between.
module ed_read_check #(parameter FRAME_WORDS=307200)(
 input clk,rst,frame_start,ready,de,input [23:0] pixel,input [2:0] index,
 input [31:0] load_sum0,load_sum1,load_sum2,load_sum3,load_sum4,load_sum5,
 output reg [7:0] frame_changes,load_mismatches
);
 reg [31:0] cap0,cap1,cap2,cap3,cap4,cap5;
 always @(posedge clk) begin cap0<=load_sum0;cap1<=load_sum1;cap2<=load_sum2;cap3<=load_sum3;cap4<=load_sum4;cap5<=load_sum5;end
 reg [31:0] sum,last_sum,expected;reg [18:0] count;reg [2:0] last_index;reg [1:0] stable;
 wire frame_ok=ready && index==last_index && count==FRAME_WORDS;
 always @* case(index) 0:expected=cap0;1:expected=cap1;2:expected=cap2;3:expected=cap3;4:expected=cap4;default:expected=cap5;endcase
 always @(posedge clk or posedge rst) begin
  if(rst) begin sum<=0;last_sum<=0;count<=0;last_index<=0;stable<=0;frame_changes<=0;load_mismatches<=0;end
  else if(frame_start) begin
   sum<=0;count<=0;last_index<=index;
   if(frame_ok) begin
    if(stable!=3) stable<=stable+1'b1;
    if(stable>=2) begin
     if(sum!=last_sum && frame_changes!=8'hff) frame_changes<=frame_changes+1'b1;
     if(sum!=expected && load_mismatches!=8'hff) load_mismatches<=load_mismatches+1'b1;
    end
    last_sum<=sum;
   end else stable<=0;
  end else if(de) begin sum<=sum+{8'd0,pixel};if(count!=FRAME_WORDS+1) count<=count+1'b1;end
 end
endmodule

// SDRAM wrapper, ext_mem_clk (125 MHz) domain, active-high Rst (synchronous use as in
// the official design). Same structure as the official user_source/.../SD/sdram.v:
// unmodified encrypted sdr_as_ram + embedded EG_PHY_SDRAM_2M_32. The only change is
// that App_ref_req is driven by a project refresh scheduler instead of 1'b0.
//
// Why: the controller's own periodic refresh is dead. global_def.v defines
//   SDR_CLK_PERIOD        1000000000/125000000          (no parentheses)
//   SELF_REFRESH_INTERVAL 64000000/`SDR_CLK_PERIOD/2**(`ROW_WIDTH)
// which expands to 64000000/1000000000/125000000/2048 = 0 in integer arithmetic, so
// sdr_init_ref's interval counter stays at 0 and its "== INTERVAL-10" request never
// fires. Board 2026-11-01: refresh pulses per second (RF) read 0000, and preloaded
// images not read for a while developed static, growing pixel errors.
//
// Scheduling: the official reader (frame_fifo_read) and the project writer issue
// App_*_en back to back for a whole 128-word burst and never look at Sdr_busy inside a
// burst, so a refresh must not start in the middle of one (board 2026-11-01: a free
// running refresh pulse gave moving white dashes). Every REFRESH_CYCLES the scheduler
// raises ref_hold, which both masters treat as "do not start a new burst"; once
// neither App_wr_en nor App_rd_en has been seen for IDLE_CYCLES (covers the read
// return latency) it pulses App_ref_req and keeps ref_hold until the controller's
// refresh window (Sdr_init_ref_vld) has ended. Hold lasts at most one burst plus
// about 40 cycles, far below the 20 us display FIFO reserve.
// 2048 rows x 4 banks (one REF covers all banks): 64 ms / 2048 = 31.25 us; the
// interval used is 15.6 us (1953 cycles). ARBITRATE=0 reproduces the unscheduled pulse
// (kept only for the regression that demonstrates the failure).
module ed_sdram #(parameter REFRESH_CYCLES=1953, IDLE_CYCLES=16, REF_TIMEOUT=127, ARBITRATE=1)(
 input         Clk,Clk_sft,Rst,
 output        Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,
 output reg    ref_hold,        // to masters: do not start a new burst
 output reg [15:0] ref_count,   // refresh requests issued (wraps), for diagnosis
 input         App_wr_en,input [20:0] App_wr_addr,input [3:0] App_wr_dm,input [31:0] App_wr_din,
 input         App_rd_en,input [20:0] App_rd_addr,
 output        Sdr_rd_en,output [31:0] Sdr_rd_dout
);
 localparam TW=$clog2(REFRESH_CYCLES);
 localparam S_IDLE=2'd0,S_DRAIN=2'd1,S_WAIT_ON=2'd2,S_WAIT_OFF=2'd3;
 reg [TW-1:0] ref_timer;reg app_ref_req;reg due;
 reg [1:0] state;reg [4:0] idle_count;reg [6:0] wait_count;
 always @(posedge Clk) begin
  if(Rst || !Sdr_init_done) begin
   ref_timer<=0;app_ref_req<=1'b0;due<=1'b0;state<=S_IDLE;idle_count<=0;wait_count<=0;ref_hold<=1'b0;ref_count<=0;
  end else begin
   app_ref_req<=1'b0;
   ref_timer<=(ref_timer==REFRESH_CYCLES-1) ? {TW{1'b0}} : ref_timer+1'b1;
   if(ref_timer==REFRESH_CYCLES-1) due<=1'b1;
   if(!ARBITRATE) begin
    if(ref_timer==REFRESH_CYCLES-1) begin app_ref_req<=1'b1;ref_count<=ref_count+1'b1;end
   end else case(state)
    S_IDLE: if(due) begin due<=1'b0;ref_hold<=1'b1;idle_count<=0;state<=S_DRAIN;end
    S_DRAIN: begin
     if(App_wr_en||App_rd_en) idle_count<=0;
     else if(idle_count==IDLE_CYCLES-1) begin app_ref_req<=1'b1;ref_count<=ref_count+1'b1;wait_count<=0;state<=S_WAIT_ON;end
     else idle_count<=idle_count+1'b1;
    end
    S_WAIT_ON: begin
     wait_count<=wait_count+1'b1;
     if(Sdr_init_ref_vld) state<=S_WAIT_OFF;
     else if(wait_count==REF_TIMEOUT) begin ref_hold<=1'b0;state<=S_IDLE;end
    end
    default: begin   // S_WAIT_OFF
     wait_count<=wait_count+1'b1;
     if(!Sdr_init_ref_vld || wait_count==REF_TIMEOUT) begin ref_hold<=1'b0;state<=S_IDLE;end
    end
   endcase
  end
 end
 wire SDRAM_CLK,SDR_RAS,SDR_CAS,SDR_WE;wire [1:0] SDR_BA;wire [10:0] SDR_ADDR;wire [31:0] SDR_DQ;wire [3:0] SDR_DM;
 sdr_as_ram #(.self_refresh_open(1'b1)) u2_ram(
  .Sdr_clk(Clk),.Sdr_clk_sft(Clk_sft),.Rst(Rst),
  .Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(Sdr_init_ref_vld),.Sdr_busy(Sdr_busy),
  .App_ref_req(app_ref_req),
  .App_wr_en(App_wr_en),.App_wr_addr(App_wr_addr),.App_wr_dm(App_wr_dm),.App_wr_din(App_wr_din),
  .App_rd_en(App_rd_en),.App_rd_addr(App_rd_addr),.Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout),
  .SDRAM_CLK(SDRAM_CLK),.SDR_RAS(SDR_RAS),.SDR_CAS(SDR_CAS),.SDR_WE(SDR_WE),
  .SDR_BA(SDR_BA),.SDR_ADDR(SDR_ADDR),.SDR_DM(SDR_DM),.SDR_DQ(SDR_DQ));
 EG_PHY_SDRAM_2M_32 sdram(
  .clk(SDRAM_CLK),.ras_n(SDR_RAS),.cas_n(SDR_CAS),.we_n(SDR_WE),.addr(SDR_ADDR[10:0]),.ba(SDR_BA),.dq(SDR_DQ),
  .cs_n(1'b0),.dm0(SDR_DM[0]),.dm1(SDR_DM[1]),.dm2(SDR_DM[2]),.dm3(SDR_DM[3]),.cke(1'b1));
endmodule
