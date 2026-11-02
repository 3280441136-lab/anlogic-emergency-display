// Menu settings persistence in the W25Q64 user flash, 25 MHz pixel domain, active-high
// async reset. Runs in the same clock domain as ed_controls, so no CDC.
//
// Record (8 bytes, written MSB first): {MAGIC 16, seq 16, value 16, crc 16}, crc =
// CRC-16/CCITT (poly 1021, init FFFF) over the first 6 bytes, computed bit-serially. Two journal slots in the
// last two 4 KB sectors (7FE000, 7FF000); writes alternate between them, so a power cut
// during an erase/program leaves the other slot intact. On boot the valid record with
// the newer sequence number (modulo-2^16 comparison) is applied once through cfg_load.
// value packing: [2:0] brightness [5:3] contrast [8:6] volume [10:9] effect [11] autoplay
// [12] eco [13] debug [15:14] OSD transparency.
//
// Write latency (2026-11-02, board: changes were lost when power was cut within ~2 s of
// closing the menu): the slot that receives the next record is erased ahead of time, in
// the background, right after boot and after every successful save. A save is then only
// a page program (about 1 ms). It starts SAVE_DELAY_CLOSED after the last change with the
// menu closed (closing the menu saves almost at once), or SAVE_DELAY_OPEN after the last
// change while the menu stays open. The slot being erased never holds the newest record,
// so a power cut during the erase or the program still leaves the newest valid record.
// A failed erase/program is not retried (status E) to avoid wearing the sector in a loop.
// Safety: nothing is written unless w25q64_preflight_reader reports the expected JEDEC ID
// (EF4017, W25Q64) and no write-protect bits; w25q64_record_store additionally rejects any
// address outside [ALLOWED_BASE, ALLOWED_LIMIT). The FPGA configuration flash (W25Q16 on
// the dedicated MSPI pins) is not connected to this logic.
// status: 0 no record (defaults), 1 record loaded / saved, 2 flash absent or protected,
//         3 write error, 4 busy (boot read or write in progress).
module ed_settings_store #(
 parameter [31:0] SAVE_DELAY_CLOSED=32'd250000,   // 10 ms at 25 MHz (key bounce margin)
 parameter [31:0] SAVE_DELAY_OPEN=32'd75000000,   // 3 s without changes while the menu is open
 parameter integer STARTUP_CYCLES=25000,        // 1 ms flash power-up wait
 parameter integer POLL_INTERVAL_CYCLES=2500,   // 100 us status polling while busy
 parameter [23:0] SLOT0=24'h7FE000, SLOT1=24'h7FF000
)(
 input clk,rst,
 input [15:0] settings,input menu_open,
 output reg cfg_load,output reg [15:0] cfg_value,
 output reg [2:0] status,
 output flash_cs_n,flash_sclk,flash_mosi,flash_wp_n,flash_hold_n,input flash_miso
);
 localparam [15:0] MAGIC=16'h4E4C;
 localparam [1:0] K_ERASE=2'd1, K_PROGRAM=2'd2;
 localparam S_PRE=0,S_PREW=1,S_R0=2,S_R0W=3,S_R1=4,S_R1W=5,S_PICK=6,S_IDLE=7,S_WRC=8,S_WRW=9,S_OFF=10,
            S_C0=11,S_C1=12,S_CRC=13,S_ERASE=14,S_ERW=15;
 localparam DMAX=(SAVE_DELAY_OPEN>SAVE_DELAY_CLOSED)?SAVE_DELAY_OPEN:SAVE_DELAY_CLOSED;
 localparam SW=$clog2(DMAX+1);
 // One bit-serial CRC-16/CCITT unit shared by both slot checks and the write record
 // (48 clocks per use) instead of three parallel 48-bit trees.
 reg [47:0] crc_sh;reg [15:0] crc;reg [5:0] crc_n;
 wire crc_fb=crc[15]^crc_sh[47]; wire rst_n=!rst;
 // ---------------- flash access ----------------
 reg pre_start,st_start,st_write;reg [1:0] st_kind;reg [23:0] st_addr;reg [63:0] st_wdata;
 wire pre_busy,pre_done,pre_ok,pre_err;wire [3:0] pre_code;
 wire st_busy,st_done,st_err,st_drop;wire [3:0] st_code;wire [63:0] st_rdata;
 wire p_cs,p_sclk,p_mosi,p_wp,p_hold,s_cs,s_sclk,s_mosi,s_wp,s_hold;
 w25q64_preflight_reader #(.SPI_CLK_DIV(4),.STARTUP_CYCLES(STARTUP_CYCLES),.WAKE_CYCLES(1000),.CS_HIGH_CYCLES(3),
  .EXPECTED_JEDEC_ID(24'hef4017)) u_preflight(.clk(clk),.rst_n(rst_n),.start(pre_start),.flash_miso(flash_miso),
  .flash_cs_n(p_cs),.flash_sclk(p_sclk),.flash_mosi(p_mosi),.flash_wp_n(p_wp),.flash_hold_n(p_hold),
  .busy(pre_busy),.done(pre_done),.accepted(pre_ok),.error(pre_err),.error_code(pre_code),
  .jedec_id(),.status1(),.status2(),.status3());
 w25q64_record_store #(.RECORD_BYTES(8),.CLK_DIV(4),.CS_HIGH_CYCLES(3),.POLL_INTERVAL_CYCLES(POLL_INTERVAL_CYCLES),
  .ERASE_TIMEOUT_CYCLES(32'd25000000),.PROGRAM_TIMEOUT_CYCLES(32'd2500000),   // 1 s / 100 ms
  .ALLOWED_BASE(SLOT0),.ALLOWED_LIMIT(SLOT1+24'h001000)) u_store(.clk(clk),.rst_n(rst_n),.start(st_start),
  .op_write(st_write),.write_kind(st_kind),.address(st_addr),.write_data(st_wdata),.busy(st_busy),.done(st_done),.error(st_err),
  .error_code(st_code),.read_data(st_rdata),.request_dropped(st_drop),
  .spi_cs_n(s_cs),.spi_sclk(s_sclk),.spi_mosi(s_mosi),.spi_miso(flash_miso),.spi_wp_n(s_wp),.spi_hold_n(s_hold));
 reg owner_store;   // 0: preflight drives the pins, 1: record store
 assign flash_cs_n  =owner_store ? s_cs   : p_cs;
 assign flash_sclk  =owner_store ? s_sclk : p_sclk;
 assign flash_mosi  =owner_store ? s_mosi : p_mosi;
 assign flash_wp_n  =owner_store ? s_wp   : p_wp;
 assign flash_hold_n=owner_store ? s_hold : p_hold;
 // ---------------- journal ----------------
 // slot: slot holding the newest record; the next record goes to the other one (target).
 reg [3:0] state,crc_ret;reg [63:0] r0,r1;reg [15:0] seq,saved,pending;reg slot;reg [SW-1:0] stable;reg failed;
 reg v0,v1,target_blank;
 wire newer1=$signed(r1[47:32]-r0[47:32])>0;
 wire [15:0] next_seq=seq+1'b1;
 wire [23:0] target=slot?SLOT0:SLOT1;
 wire [SW-1:0] delay=menu_open?SAVE_DELAY_OPEN[SW-1:0]:SAVE_DELAY_CLOSED[SW-1:0];
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   // Control only; data registers (r0/r1/seq/saved/pending/stable/st_addr/st_wdata/cfg_value)
   // are always written before use (boot reads both slots first), so they carry no reset.
   state<=S_PRE;pre_start<=0;st_start<=0;st_write<=0;st_kind<=0;owner_store<=0;slot<=1;failed<=0;
   target_blank<=0;cfg_load<=0;status<=3'd4;
  end else begin
   pre_start<=0;st_start<=0;cfg_load<=0;
   case(state)
    S_PRE: begin pre_start<=1;state<=S_PREW;end
    S_PREW: if(pre_done) begin
     if(pre_ok) begin owner_store<=1;state<=S_R0;end
     else begin status<=3'd2;saved<=settings;pending<=settings;state<=S_OFF;end
    end
    S_R0: begin st_start<=1;st_write<=0;st_addr<=SLOT0;state<=S_R0W;end
    S_R0W: if(st_done) begin r0<=st_err?64'd0:st_rdata;state<=S_R1;end
    S_R1: begin st_start<=1;st_write<=0;st_addr<=SLOT1;state<=S_R1W;end
    S_R1W: if(st_done) begin r1<=st_err?64'd0:st_rdata;crc_sh<=r0[63:16];crc<=16'hffff;crc_n<=0;crc_ret<=S_C0;state<=S_CRC;end
    S_C0: begin v0<=r0[63:48]==MAGIC && r0[15:0]==crc;crc_sh<=r1[63:16];crc<=16'hffff;crc_n<=0;crc_ret<=S_C1;state<=S_CRC;end
    S_C1: begin v1<=r1[63:48]==MAGIC && r1[15:0]==crc;state<=S_PICK;end
    S_CRC: begin   // shift one data bit per clock, MSB first
     crc<=crc_fb ? {crc[14:0],1'b0}^16'h1021 : {crc[14:0],1'b0};crc_sh<={crc_sh[46:0],1'b0};
     crc_n<=crc_n+1'b1;if(crc_n==6'd47) state<=crc_ret;
    end
    S_PICK: begin
     // Target blank: its 8 record bytes read back as FF (a page program only clears bits).
     if(v1 && (!v0 || newer1)) begin
      cfg_load<=1;cfg_value<=r1[31:16];saved<=r1[31:16];pending<=r1[31:16];seq<=r1[47:32];slot<=1;status<=3'd1;
      target_blank<=&r0;
     end else if(v0) begin
      cfg_load<=1;cfg_value<=r0[31:16];saved<=r0[31:16];pending<=r0[31:16];seq<=r0[47:32];slot<=0;status<=3'd1;
      target_blank<=&r1;
     end else begin
      saved<=settings;pending<=settings;seq<=0;slot<=1;status<=3'd0;   // first write goes to slot 0
      target_blank<=&r0;
     end
     stable<=0;state<=S_ERASE;
    end
    // Erase the target ahead of the next save unless it is already blank.
    S_ERASE: if(target_blank) state<=S_IDLE;
     else begin st_start<=1;st_write<=1;st_kind<=K_ERASE;st_addr<=target;state<=S_ERW;end
    S_ERW: if(st_done) begin
     if(st_err) begin failed<=1;status<=3'd3;end else target_blank<=1;
     stable<=0;state<=S_IDLE;
    end
    S_IDLE: begin
     // settings stay stable during the 48-clock CRC: S_CRC is entered only after the delay
     // with unchanged settings, and a change during CRC/write is picked up on return here.
     if(settings!=pending) begin pending<=settings;stable<=0;end
     else if(pending!=saved && !failed && target_blank) begin
      if(stable>=delay) begin
       st_wdata[63:16]<={MAGIC,next_seq,pending};crc_sh<={MAGIC,next_seq,pending};crc<=16'hffff;crc_n<=0;
       crc_ret<=S_WRC;status<=3'd4;state<=S_CRC;
      end else stable<=stable+1'b1;
     end else stable<=0;
    end
    S_WRC: begin st_wdata[15:0]<=crc;st_start<=1;st_write<=1;st_kind<=K_PROGRAM;st_addr<=target;state<=S_WRW;end
    S_WRW: if(st_done) begin
     if(st_err) begin failed<=1;status<=3'd3;stable<=0;state<=S_IDLE;end
     else begin   // the old slot becomes the next target: erase it now, in the background
      saved<=st_wdata[31:16];seq<=st_wdata[47:32];slot<=~slot;status<=3'd1;target_blank<=0;state<=S_ERASE;
     end
    end
    default: ;   // S_OFF: flash absent/protected, settings live only in RAM
   endcase
  end
 end
endmodule
