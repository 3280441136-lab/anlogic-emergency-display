// Product writer, two clock domains, active-low async resets (rst_n: clk, mem_rst_n: mem_clk).
//   clk     (ingest, 25 MHz on the board): accepts decoded pixels, counts, reports status.
//   mem_clk (SDRAM, 125 MHz): address generation, 128-word bursts, 12-cycle drain guard.
// Only crossings: the vendor async FIFO rfifo_32_32_512 (Gray pointers, IP SDC) carrying
// {top_down, rgb}, and one req/ack toggle pair (two flip-flops each way). Values read across
// (bank, received, mem_ok, mem_stalled) are registers that are stable while the toggle that
// qualifies them is in flight.
// Handshake per image: req toggle #1 = begin (mem side clears its counters for `bank`,
// acks); pixels stream; req toggle #2 = end with the final count `received`; mem side acks
// once it has popped `received` words and the last write burst has drained. The FIFO
// pointer sync is not used to decide completion, so its latency cannot end an image early.
// load_start must come at least 3 clk cycles after both resets release (the vendor FIFO
// releases its internal reset two clocks late); the product starts after SDRAM init.
// Rows: the first word's top_down bit sets the start row (bottom-up BMP: last row first).
module media_frame_loader #(
 parameter ADDR_WIDTH=21, IMAGE_WORDS=307200, FIFO_DEPTH=512,
 parameter BURST_SIZE=128, STALL_TIMEOUT=65535, READY_MARGIN=16,
 parameter FRAME_WIDTH=640, FRAME_HEIGHT=480,
 // clk cycles to wait for a mem-side acknowledgement (begin, or drain of at most
 // FIFO_DEPTH words) before reporting 46; far above the normal few microseconds.
 parameter ACK_TIMEOUT=1048575
)(
 input clk,rst_n,load_start,input [2:0] image_index,   // bank 0..5
 input pixel_valid,input [23:0] pixel_rgb,input frame_commit,
 input [7:0] decode_error,input top_down,
 output load_busy,output reg load_done,output reg [5:0] image_complete,
 // Upstream may present one pixel per cycle while load_ready (FIFO has at least
 // READY_MARGIN free entries; covers the producer's pipeline latency).
 output load_ready,
 output reg [7:0] memory_error,
 input mem_clk,mem_rst_n,
 input controller_init_done,controller_busy,refresh_active,   // mem_clk domain
 output reg app_wr_en,output reg [ADDR_WIDTH-1:0] app_wr_addr,
 output [3:0] app_wr_mask,output [31:0] app_wr_data
);
 localparam AW=$clog2(FIFO_DEPTH), CW=$clog2(IMAGE_WORDS+1);
 localparam P_IDLE=2'd0,P_BEGIN=2'd1,P_STREAM=2'd2,P_END=2'd3;
 wire [AW-1:0] wrusedw,rdusedw;wire full,empty;wire [24:0] fifo_q;
 wire re;reg mem_ack;   // mem_clk domain, declared here for the FIFO and the ack synchronizer
 // ---------------- clk domain ----------------
 reg [1:0] pstate,ack_s;reg req,commit_seen;reg [2:0] bank;reg [CW-1:0] received;reg [7:0] err;
 reg [$clog2(ACK_TIMEOUT+1)-1:0] wait_cnt;
 wire mem_ok,mem_stalled;   // mem_clk registers, stable when ack_s[1]==req
 // Pixels are accepted from load_start on; the FIFO is empty between images and the mem
 // side pops only after it has taken the begin request, so words never mix images. The
 // end request waits for the begin acknowledgement (toggles must not merge).
 wire accepting=pstate==P_BEGIN || pstate==P_STREAM;
 wire push=accepting && pixel_valid && !full && received!=IMAGE_WORDS && err==0;
 assign load_busy=pstate!=P_IDLE;
 assign load_ready=accepting && wrusedw<FIFO_DEPTH-READY_MARGIN;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   pstate<=P_IDLE;ack_s<=0;req<=0;commit_seen<=0;bank<=0;received<=0;err<=0;wait_cnt<=0;
   load_done<=0;image_complete<=0;memory_error<=0;
  end else begin
   ack_s<={ack_s[0],mem_ack};load_done<=0;
   if(pstate==P_BEGIN || pstate==P_END) wait_cnt<=wait_cnt+1'b1;else wait_cnt<=0;
   if(push) received<=received+1'b1;
   if(accepting && frame_commit) commit_seen<=1;
   // Errors are latched in any active state and end the image once streaming.
   if(pstate!=P_IDLE && err==0) begin
    if(decode_error!=0) err<=8'h44;
    else if(accepting && pixel_valid && !push) err<=8'h42;   // overflow / extra pixel
   end
   case(pstate)
    P_IDLE: if(load_start) begin
     bank<=image_index;received<=0;err<=0;commit_seen<=0;memory_error<=0;image_complete[image_index]<=0;
     req<=~req;pstate<=P_BEGIN;
    end
    P_BEGIN: if(ack_s[1]==req) pstate<=P_STREAM;
     else if(wait_cnt==ACK_TIMEOUT) begin memory_error<=8'h46;load_done<=1;pstate<=P_IDLE;end
    P_STREAM:
     if(commit_seen || frame_commit || err!=0 || decode_error!=0 || (pixel_valid && !push)) begin
      req<=~req;pstate<=P_END;
     end
    default: if(ack_s[1]==req) begin   // P_END: all received words written (or discarded)
     load_done<=1;pstate<=P_IDLE;
     if(err!=0) memory_error<=err;
     else if(mem_stalled) memory_error<=8'h46;
     else if(received!=IMAGE_WORDS || !mem_ok) memory_error<=8'h45;
     else image_complete[bank]<=1;
    end else if(wait_cnt==ACK_TIMEOUT) begin memory_error<=8'h46;load_done<=1;pstate<=P_IDLE;end
   endcase
  end
 end
 // Unmodified vendor async FIFO (also used by the read path); NOREG: data one cycle after re.
 // Capacity FIFO_DEPTH-1 words. wrusedw over-estimates and rdusedw under-estimates the
 // fill level while pointers are in flight, so both uses below are conservative.
 rfifo_32_32_512 #(.DATA_WIDTH_W(25),.DATA_WIDTH_R(25),.ADDR_WIDTH_W(AW),.ADDR_WIDTH_R(AW),
  .AL_FULL_NUM(FIFO_DEPTH-3),.AL_EMPTY_NUM(2),.SHOW_AHEAD_EN(1'b0),.OUTREG_EN("NOREG")) u_fifo(
  .rst(!rst_n||!mem_rst_n),.clkw(clk),.clkr(mem_clk),.we(push),.di({top_down,pixel_rgb}),
  .re(re),.dout(fifo_q),.valid(),.full_flag(full),.empty_flag(empty),.afull(),.aempty(),
  .wrusedw(wrusedw),.rdusedw(rdusedw));
 // ---------------- mem_clk domain ----------------
 reg [1:0] req_s;reg run,end_seen,discard,failed,ok_r,fifo_top_down;
 reg [2:0] bank_m;reg [CW-1:0] total,popped,written;
 reg [ADDR_WIDTH-1:0] row_base;reg [9:0] column;reg orient;
 reg [7:0] burst_left;reg [4:0] guard;reg [$clog2(STALL_TIMEOUT+1)-1:0] stall;
 reg v1,v2,refresh_q;reg [23:0] d_rgb;
 reg [31:0] wr_data;
 assign mem_ok=ok_r;assign mem_stalled=failed;
 assign app_wr_data=wr_data;assign app_wr_mask=0;
 assign re=discard ? !empty : burst_left!=0;
 wire pop=re && !empty;
 wire want=rdusedw>=BURST_SIZE || (end_seen && popped!=total);
 // refresh_q: registered refresh/hold. Write enables start 3 cycles after the decision;
 // ed_sdram needs 16 consecutive idle cycles after raising hold, so a burst decided on
 // the old value only delays the refresh.
 wire start_burst=run && !discard && controller_init_done && burst_left==0 && guard==0 &&
                  !controller_busy && !refresh_q && rdusedw!=0 && want;
 function [ADDR_WIDTH-1:0] first_row;
 input [2:0] b;input td; reg [ADDR_WIDTH-1:0] base; begin
  case(b) 0:base=0;1:base=IMAGE_WORDS;2:base=IMAGE_WORDS*2;3:base=IMAGE_WORDS*3;4:base=IMAGE_WORDS*4;default:base=IMAGE_WORDS*5;endcase
  first_row=base+(td ? 0 : IMAGE_WORDS-FRAME_WIDTH);
 end endfunction
 always @(posedge mem_clk or negedge mem_rst_n) begin
  if(!mem_rst_n) begin
   // Control only. bank_m/total/popped/written/column/orient/stall are set by every begin
   // request before use (run is 0 until then): no reset, smaller rst_mem fanout.
   req_s<=0;mem_ack<=0;run<=0;end_seen<=0;discard<=0;failed<=0;ok_r<=0;
   burst_left<=0;guard<=0;v1<=0;v2<=0;app_wr_en<=0;refresh_q<=1'b1;
  end else begin
   req_s<={req_s[0],req};refresh_q<=refresh_active;app_wr_en<=0;
   if(guard!=0) guard<=guard-1'b1;
   // begin: req changed while idle. bank is stable since it changed with the toggle.
   if(!run && req_s[1]!=mem_ack) begin
    run<=1;mem_ack<=req_s[1];bank_m<=bank;popped<=0;written<=0;column<=0;orient<=0;
    end_seen<=0;discard<=0;failed<=0;ok_r<=0;stall<=0;
   end
   if(run && !end_seen && req_s[1]!=mem_ack) begin end_seen<=1;total<=received;end
   if(start_burst) burst_left<=rdusedw>=BURST_SIZE ? BURST_SIZE : rdusedw;
   if(pop) begin
    popped<=popped+1'b1;
    if(!discard) begin burst_left<=burst_left-1'b1;if(burst_left==1) guard<=12;end
   end
   // stage 1: FIFO data valid one cycle after the pop
   v1<=pop && !discard;
   if(v1) begin
    d_rgb<=fifo_q[23:0];
    if(!orient) begin orient<=1;fifo_top_down<=fifo_q[24];row_base<=first_row(bank_m,fifo_q[24]);end
   end
   // stage 2: address and write
   v2<=v1;
   if(v2) begin
    app_wr_en<=1;app_wr_addr<=row_base+column;wr_data<={8'd0,d_rgb};written<=written+1'b1;
    if(column==FRAME_WIDTH-1) begin
     column<=0;row_base<=fifo_top_down ? row_base+FRAME_WIDTH : row_base-FRAME_WIDTH;
    end else column<=column+1'b1;
   end
   // Memory stall watchdog: words waiting but no burst for STALL_TIMEOUT cycles. The
   // rest of the image is then popped and dropped so the FIFO is empty for the next one.
   if(run && !discard && burst_left==0 && want && !start_burst) begin
    if(stall==STALL_TIMEOUT) begin discard<=1;failed<=1;end else stall<=stall+1'b1;
   end else stall<=0;
   if(run && end_seen && popped==total && burst_left==0 && !v1 && !v2 && !app_wr_en &&
      guard==0 && !controller_busy) begin
    run<=0;mem_ack<=req_s[1];ok_r<=!failed && written==total;
   end
  end
 end
endmodule

// Asynchronous assertion, three clock synchronous release, active-high output.
module ed_reset(input clk,input async_rst,output rst);
 reg [2:0] release_ff;
 always @(posedge clk or posedge async_rst)
  if(async_rst) release_ff<=3'b111;else release_ff<={release_ff[1:0],1'b0};
 assign rst=release_ff[2];
endmodule
