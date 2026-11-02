// Adapted reference: 03第三方的课程资料/完赛篇/第五讲：系统稳定性/第4课_系统稳定性/bmp24_decoder.v
// Original remains read-only. Product changes and interface review: docs/设计与优化.md.
`timescale 1ns/1ps

// BMP header check and pixel extraction, ingest clock domain, active-low async reset.
// Accepts 24-bit uncompressed BMP of any width/height in [MIN_SRC, MAX_SRC] (top-down
// or bottom-up). Emits source pixels in FILE order (row padding removed), one per
// pixel_valid, at most one every three file bytes; scaling is done downstream by
// image_fit_scaler. src_w/src_h/top_down are valid while header_accepted is high.
// Header field select uses a local byte counter: the file streamer delivers bytes in
// order from offset 0, so the count equals file_byte_offset for bytes 0..63.
// Errors (bmp_error): 31 not BM; 32 size outside range or DIB < 40; 33 planes != 1;
// 34 not 24 bpp; 35 compressed; 36 bad pixel offset; 37 declared size above file size,
// or the file ended before all H rows were complete; 38 upstream read error.
// No multiplier: completeness is checked by counting finished rows, not W*H.
module bmp24_decoder #(
    parameter integer MIN_SRC = 16,
    parameter integer MAX_SRC = 2048
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    input  wire [31:0] file_size,
    input  wire        file_valid,
    input  wire [7:0]  file_byte,
    input  wire [31:0] file_byte_offset,
    input  wire        file_end,
    input  wire [7:0]  upstream_error,
    output reg         header_accepted,
    output reg  [11:0] src_w,
    output reg  [11:0] src_h,
    output reg         pixel_valid,
    output reg  [23:0] pixel_rgb,
    output reg         frame_commit,
    output reg         bmp_done,
    output reg  [7:0]  bmp_error,
    output reg         top_down,
    output reg  [31:0] pixel_offset
);
    reg [15:0] signature, planes, bpp;
    reg [31:0] dib_size, declared_size, width, compression;
    reg signed [31:0] height;
    reg [31:0] absolute_height;
    reg decode_enabled, data_valid, end_q; reg [7:0] data_byte;
    reg [12:0] byte_in_row, row_last, pixel_bytes, stride; reg [11:0] source_rows;
    reg [11:0] physical_row;
    reg [1:0] phase; reg [7:0] blue, green;
    reg rows_complete;
    reg width_ok, height_ok;
    reg [6:0] header_checks; reg [7:0] header_error;
    reg declared_in_file, offset_ok;
    reg [6:0] header_count;
    wire header_byte = file_valid && !header_count[6];
    wire active_byte = data_valid && physical_row < source_rows;
    // Header arithmetic is spread over bytes 26..34 (one registered step per byte).
    always @(posedge clk or negedge rst_n) begin
     if (!rst_n) begin
      signature<=0;planes<=0;bpp<=0;dib_size<=0;declared_size<=0;width<=0;height<=0;compression<=0;absolute_height<=0;
      decode_enabled<=0;data_valid<=0;end_q<=0;data_byte<=0;byte_in_row<=0;row_last<=0;pixel_bytes<=0;stride<=0;
      source_rows<=0;physical_row<=0;phase<=0;blue<=0;green<=0;rows_complete<=0;
      width_ok<=0;height_ok<=0;header_checks<=0;header_error<=0;
      declared_in_file<=0;offset_ok<=0;header_count<=0;
      header_accepted<=0;src_w<=0;src_h<=0;pixel_valid<=0;pixel_rgb<=0;frame_commit<=0;bmp_done<=0;bmp_error<=0;
      top_down<=0;pixel_offset<=0;
     end else begin
      pixel_valid<=0;frame_commit<=0;bmp_done<=0;
      rows_complete<=physical_row==source_rows;
      data_valid<=file_valid&&decode_enabled&&file_byte_offset>=pixel_offset;
      if(file_valid) data_byte<=file_byte;
      end_q<=file_end;
      if(file_start) begin
       header_count<=0;header_error<=0;header_checks<=0;decode_enabled<=0;header_accepted<=0;bmp_error<=0;
       byte_in_row<=0;physical_row<=0;phase<=0;top_down<=0;pixel_offset<=0;source_rows<=0;
       declared_in_file<=0;offset_ok<=0;width_ok<=0;height_ok<=0;
      end
      if(header_byte) header_count<=header_count+1'b1;
      if(header_byte) case(header_count[5:0])
       0:signature[7:0]<=file_byte;1:signature[15:8]<=file_byte;
       2:declared_size[7:0]<=file_byte;3:declared_size[15:8]<=file_byte;
       4:declared_size[23:16]<=file_byte;5:declared_size[31:24]<=file_byte;
       10:pixel_offset[7:0]<=file_byte;11:pixel_offset[15:8]<=file_byte;
       12:pixel_offset[23:16]<=file_byte;13:pixel_offset[31:24]<=file_byte;
       14:dib_size[7:0]<=file_byte;15:dib_size[15:8]<=file_byte;16:dib_size[23:16]<=file_byte;17:dib_size[31:24]<=file_byte;
       18:width[7:0]<=file_byte;19:width[15:8]<=file_byte;20:width[23:16]<=file_byte;21:width[31:24]<=file_byte;
       22:height[7:0]<=file_byte;23:height[15:8]<=file_byte;24:height[23:16]<=file_byte;25:height[31:24]<=file_byte;
       26:begin planes[7:0]<=file_byte;absolute_height<=height[31] ? -height : height;end
       27:begin planes[15:8]<=file_byte;
        width_ok<=width>=MIN_SRC&&width<=MAX_SRC;
        height_ok<=absolute_height>=MIN_SRC&&absolute_height<=MAX_SRC;
        // 3*width, rounded up to a multiple of 4 (BMP row stride); width <= 2048 here
        // only matters when width_ok, so the low 12 bits are sufficient.
        stride<=(({1'b0,width[11:0]}+{width[11:0],1'b0})+13'd3)&~13'd3;
        pixel_bytes<={1'b0,width[11:0]}+{width[11:0],1'b0};
       end
       28:bpp[7:0]<=file_byte;
       29:bpp[15:8]<=file_byte;
       30:compression[7:0]<=file_byte;
       31:compression[15:8]<=file_byte;
       32:begin compression[23:16]<=file_byte;declared_in_file<=declared_size<=file_size;end
       33:begin compression[31:24]<=file_byte;offset_ok<=pixel_offset>=54&&pixel_offset<file_size;end
       40:begin
        header_checks[0]<=signature==16'h4d42;
        header_checks[1]<=width_ok&&height_ok&&dib_size>=40;
        header_checks[2]<=planes==1;
        header_checks[3]<=bpp==24;
        header_checks[4]<=compression==0;
        header_checks[5]<=offset_ok;
        header_checks[6]<=declared_in_file;
       end
       41:begin
        if(!header_checks[0])header_error<=8'h31;
        else if(!header_checks[1])header_error<=8'h32;
        else if(!header_checks[2])header_error<=8'h33;
        else if(!header_checks[3])header_error<=8'h34;
        else if(!header_checks[4])header_error<=8'h35;
        else if(!header_checks[5])header_error<=8'h36;
        else if(!header_checks[6])header_error<=8'h37;
        else header_error<=0;
       end
       53:begin
        bmp_error<=header_error;
        if(header_error==0) begin
         header_accepted<=1;decode_enabled<=1;top_down<=height[31];
         src_w<=width[11:0];src_h<=absolute_height[11:0];
         row_last<=stride-1'b1;source_rows<=absolute_height[11:0];
        end
       end
       default:;
      endcase
      if(active_byte) begin
       if(byte_in_row<pixel_bytes) case(phase)
        0:begin blue<=data_byte;phase<=1;end
        1:begin green<=data_byte;phase<=2;end
        default:begin phase<=0;pixel_valid<=1;pixel_rgb<={data_byte,green,blue};end
       endcase
       if(byte_in_row==row_last) begin byte_in_row<=0;physical_row<=physical_row+1'b1;phase<=0;end
       else byte_in_row<=byte_in_row+1'b1;
      end
      if(end_q) begin
       bmp_done<=1;decode_enabled<=0;
       if(upstream_error!=0) bmp_error<=8'h38;
       else if(bmp_error==0) begin
        if(header_accepted&&rows_complete) frame_commit<=1;
        else bmp_error<=8'h37;
       end
      end
     end
    end
endmodule

// Aspect-preserving fit scaler, ingest clock domain, active-low async reset (control
// registers only; datapath registers are written before use and carry no reset).
// Consumes the decoder's source pixels (file order) and emits exactly OUT_W*OUT_H
// output pixels in the same row order, which media_frame_loader writes to SDRAM
// (bottom-up files are flipped there). Source W x H, 16..2048 each (decoder checks).
//   Fit: s = min(OUT_W/W, OUT_H/H); fit_w x fit_h = round(W*s) x round(H*s), centred,
//        borders black (pure 0). Source rows/columns map in file order.
//   Down (W >= OUT_W or H >= OUT_H): area average. Columns: a DDA adds fit_w per source
//        pixel and closes an output column when the sum reaches W; rows: the same with
//        fit_h and H. avg = (sum * R[n] + 2^15) >> 16, R[n] = round(2^16/n), n <= 8.
//        Horizontal averages accumulate per output column in acc RAM; the last source
//        row of a vertical span emits the output row while it is consumed.
//   Up (W < OUT_W and H < OUT_H): bilinear, align-corners sx = i*(W-1)/(fit_w-1),
//        sy = j*(H-1)/(fit_h-1), 16 fraction bits; weights use the top 8 bits:
//        v = a + (((b-a)*f + 128) >>> 8). Two source line buffers (rows y0, y1).
// Bit-exact reference: scripts/scaler_model.py.
//
// Low-resource arithmetic: no hardware multiplier. Every product (setup geometry,
// averaging, interpolation weights) goes through ONE shared shift-add unit (S_MUL):
// one adder, one conditional add per multiplier bit, early exit when the remaining
// multiplier bits are zero. Colour channels are processed one after another. The
// source arrives from the SD card at about 1 byte per 128 clocks (3 bytes per pixel),
// so a downscaled output pixel (at most ~70 clocks) and an upscaled one (~100 clocks)
// keep up with the card; datapath registers only toggle while a step is active.
// Rate decoupling: a source FIFO (FIFO_DEPTH pixels) absorbs one replayed sector at
// 1 byte/clock; hold asks the file streamer not to fetch another sector while fewer
// than HOLD_MARGIN entries are free (one 512-byte sector carries at most 171 pixels).
// Output is gated by out_ready (loader FIFO has room). error: 39 source FIFO overflow,
// 3a averaging count above 8.
module image_fit_scaler #(
    parameter integer OUT_W = 640,
    parameter integer OUT_H = 480,
    parameter integer FIFO_DEPTH = 512,
    parameter integer HOLD_MARGIN = 200
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    input  wire        header_valid,
    input  wire [11:0] src_w,
    input  wire [11:0] src_h,
    input  wire        in_valid,
    input  wire [23:0] in_rgb,
    input  wire        in_commit,
    output reg         hold,
    input  wire        out_ready,
    output reg         out_valid,
    output reg  [23:0] out_rgb,
    output reg         out_commit,
    output reg  [7:0]  error,
    output reg  [10:0] fit_w,
    output reg  [10:0] fit_h,
    output reg         scaled
);
    localparam AW = $clog2(FIFO_DEPTH);
    localparam LW = $clog2(OUT_W);
    localparam [5:0]
        S_IDLE=0, S_HDR=1, S_PA=2, S_PB=3, S_CMP=4, S_CMP2=5, S_DIV=6, S_FITQ=7, S_GEOM=8,
        S_TB=9, S_BB=10, S_SX=11, S_SXQ=12, S_SYQ=13, S_CLEAR=14, S_BLACK=15, S_MUL=16,
        D_ROW=17, D_POP=18, D_GOT=19, D_HMUL=20, D_HRES=21, D_ACC0=22, D_ACC=23, D_VMUL=24,
        D_VRES=25, D_OUT=26, D_NEXT=27, D_ROWEND=28,
        U_LOAD=29, U_LGOT=30, U_PREP=31, U_PREP2=32, U_PREP3=33, U_ROWS=34, U_P0=35, U_P1=36,
        U_P2=37, U_T=38, U_TB=39, U_BV=40, U_VD=41, U_OUT=42, U_ROWDONE=43,
        L_START=44, L_SGN=45, L_FIN=46, S_DONE=47;

    // ---------------- storage --------------------------------------------------------
    reg [23:0] fifo [0:FIFO_DEPTH-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [AW-1:0] wp, rp; reg [AW:0] used; reg [23:0] q;
    reg [23:0] lb0 [0:OUT_W-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [23:0] lb1 [0:OUT_W-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg [32:0] acc [0:OUT_W-1] /* fehdl force_ram=1, ram_style="bram" */;
    reg lb_we, acc_we, lb_wsel;
    reg [LW-1:0] lb_waddr, acc_waddr, col;
    reg [23:0] lb_wdata, lb0_q, lb1_q; reg [32:0] acc_wdata, acc_q;
    reg pop, lb_re, acc_re; reg [LW-1:0] lb_raddr;
    // Registered pop qualifiers (timing: no state decode / 10-bit compare on the FIFO read
    // enable). pop_d / pop_u rise one clock after entering D_POP / U_LOAD and fall on the
    // pop; nonempty_q may lag used by one clock, but used only decreases on a pop, and a pop
    // is never issued in the clock right after one (the flag is low then).
    reg pop_d, pop_u, nonempty_q;

    // ---------------- control registers (reset) ---------------------------------------
    reg [5:0] state, ret, div_ret, mul_ret, lret; reg [4:0] div_cnt; reg [19:0] black_left; reg row_end;
    reg [11:0] srcx, rows, r_row; reg [10:0] i_col, j_row; reg [1:0] ch; reg commit_seen;
    // ---------------- datapath registers (no reset) ----------------------------------
    reg [11:0] W, H, Wm1; reg upscale, wide;
    reg [21:0] prod_a, prod_b, numa, numb;
    reg [27:0] div_num; reg [11:0] div_den; reg [12:0] div_rem;
    reg [10:0] x0, y0, x_right, bot_rows, fit_w_m1; reg [18:0] top_black, bot_black;
    reg [27:0] step_x, step_y, sx, sy;
    reg [27:0] mul_x, mul_acc; reg [11:0] mul_y;           // shared shift-add multiplier
    reg [11:0] th, tv; reg emit_row, emit_next, close_next, rows_last, row_ready, rows_done;
    reg [3:0] hcnt, vcnt; reg [16:0] vrec, hrec;
    reg [10:0] hs_r, hs_g, hs_b, vs_r, vs_g, vs_b; reg [7:0] hv_r, hv_g, hv_b, o_r, o_g, o_b;
    reg [32:0] accq_r;
    reg [11:0] y0r, y1r; reg [7:0] fxr, fyr; reg selr;
    reg [7:0] ta_r, ta_g, ta_b, tb_r, tb_g, tb_b, ba_r, ba_g, ba_b, bb_r, bb_g, bb_b, ht;
    reg [7:0] la, lb, lf, lv; reg lneg; reg signed [17:0] lsp;  // lerp subroutine

    wire [12:0] div_shift = {div_rem[11:0], div_num[27]};
    wire [11:0] tn_h = th + fit_w, tn_v = tv + fit_h;
    // Registered (th + fit_w >= W): th changes only in D_ROW and D_GOT, and every D_GOT is
    // at least two cycles after either.
    wire close_col = close_next;
    wire [7:0] sat_avg = (mul_acc[27:24] != 0) ? 8'd255 : mul_acc[23:16];   // after +2^15 init

    function [16:0] recip; input [3:0] n; begin case (n)
        1: recip = 17'd65536; 2: recip = 17'd32768; 3: recip = 17'd21845; 4: recip = 17'd16384;
        5: recip = 17'd13107; 6: recip = 17'd10923; 7: recip = 17'd9362; default: recip = 17'd8192;
    endcase end endfunction
    function [7:0] pick; input [1:0] c; input [7:0] r, g, b; begin
        pick = (c == 0) ? r : (c == 1) ? g : b;
    end endfunction
    function [10:0] pick11; input [1:0] c; input [10:0] r, g, b; begin
        pick11 = (c == 0) ? r : (c == 1) ? g : b;
    end endfunction

    always @(posedge clk) begin
        if (in_valid) fifo[wp] <= in_rgb;
        if (pop) q <= fifo[rp];
        if (lb_we && !lb_wsel) lb0[lb_waddr] <= lb_wdata;
        if (lb_we &&  lb_wsel) lb1[lb_waddr] <= lb_wdata;
        if (lb_re) begin lb0_q <= lb0[lb_raddr]; lb1_q <= lb1[lb_raddr]; end
        if (acc_we) acc[acc_waddr] <= acc_wdata;
        if (acc_re) acc_q <= acc[col];
    end
    always @(*) begin
        pop = 1'b0; lb_re = 1'b0; acc_re = 1'b0; lb_raddr = sx[16+LW-1:16];
        case (state)
            D_POP:  pop = pop_d && nonempty_q && (out_ready || !emit_row);
            U_LOAD: pop = pop_u && nonempty_q;
            U_P0:   lb_re = out_ready;
            U_P1:   begin lb_re = 1'b1; lb_raddr = sx[16+LW-1:16] + 1'b1; end
            D_GOT:  acc_re = close_col;
            default: ;
        endcase
    end

    // black_left counts n-1 down to -1: the end test is the sign bit only (timing).
    task black; input [18:0] n; input [5:0] r; begin black_left <= {1'b0, n} - 1'b1; ret <= r; state <= S_BLACK; end endtask
    task mul; input [5:0] r; begin mul_ret <= r; state <= S_MUL; end endtask   // operands: datapath

    // ---------------- control ------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wp <= 0; rp <= 0; used <= 0; hold <= 1'b0; error <= 0; commit_seen <= 1'b0;
            state <= S_IDLE; ret <= S_IDLE; div_ret <= S_IDLE; mul_ret <= S_IDLE; lret <= S_IDLE;
            div_cnt <= 0; black_left <= 0; out_valid <= 1'b0; out_commit <= 1'b0; lb_we <= 1'b0; acc_we <= 1'b0;
            srcx <= 0; rows <= 0; r_row <= 0; i_col <= 0; j_row <= 0; col <= 0; ch <= 0; row_end <= 1'b0;
            pop_d <= 1'b0; pop_u <= 1'b0; nonempty_q <= 1'b0;
        end else begin
            out_valid <= 1'b0; out_commit <= 1'b0; lb_we <= 1'b0; acc_we <= 1'b0;
            pop_d <= state == D_POP && !pop; pop_u <= state == U_LOAD && !pop;
            nonempty_q <= used != 0 || in_valid;
            if (in_valid) wp <= wp + 1'b1;
            if (pop) rp <= rp + 1'b1;
            case ({in_valid, pop}) 2'b10: used <= used + 1'b1; 2'b01: used <= used - 1'b1; default: ; endcase
            if (in_valid && !pop && used == FIFO_DEPTH && error == 0) error <= 8'h39;
            hold <= used > FIFO_DEPTH - HOLD_MARGIN;
            if (in_commit) commit_seen <= 1'b1;
            if (start) begin
                wp <= 0; rp <= 0; used <= 0; error <= 0; commit_seen <= 1'b0; state <= S_HDR;
            end else case (state)
            S_IDLE:  ;
            S_HDR:   if (header_valid) mul(S_PA);              // W * OUT_H
            S_PA:    mul(S_PB);                                // H * OUT_W
            S_PB:    state <= S_CMP;
            S_CMP:   state <= S_CMP2;
            S_CMP2:  begin div_cnt <= 0; div_ret <= S_FITQ; state <= S_DIV; end
            S_DIV:   begin div_cnt <= div_cnt + 1'b1; if (div_cnt == 5'd27) state <= div_ret; end
            S_MUL:   if (mul_y == 0) state <= mul_ret;
            S_FITQ:  state <= S_GEOM;
            S_GEOM:  mul(S_TB);                                // y0 * OUT_W
            S_TB:    mul(S_BB);                                // bot_rows * OUT_W
            S_BB:    state <= S_SX;
            S_SX:    if (!upscale) begin col <= 0; state <= S_CLEAR; end
                     else begin div_cnt <= 0; div_ret <= S_SXQ; state <= S_DIV; end
            S_SXQ:   begin div_cnt <= 0; div_ret <= S_SYQ; state <= S_DIV; end
            S_SYQ:   begin r_row <= 0; j_row <= 0; srcx <= 0; black(top_black, U_LOAD); end
            S_CLEAR: begin   // zero the column accumulators; acc[col] is written next cycle
                acc_we <= 1'b1;
                if (col == OUT_W - 1) begin rows <= 0; black(top_black, D_ROW); end
                else col <= col + 1'b1;
            end
            S_BLACK: if (black_left[19]) state <= ret;
                     else if (out_ready) begin out_valid <= 1'b1; black_left <= black_left - 1'b1; end
            // ---------------- downscale ----------------
            D_ROW:   begin srcx <= 0; col <= 0; if (emit_next) black(x0, D_POP); else state <= D_POP; end
            D_POP:   if (pop) state <= D_GOT;
            D_GOT:   begin
                srcx <= srcx + 1'b1; ch <= 0; row_end <= srcx + 1'b1 == W;   // used by D_NEXT (timing)
                if (hcnt == 4'd8 && error == 0) error <= 8'h3a;
                state <= close_col ? D_HMUL : D_NEXT;
            end
            D_HMUL:  mul(D_HRES);
            D_HRES:  if (ch == 2) begin ch <= 0; state <= D_ACC0; end else begin ch <= ch + 1'b1; state <= D_HMUL; end
            D_ACC0:  state <= D_ACC;
            D_ACC:   begin
                acc_we <= 1'b1; col <= col + 1'b1; ch <= 0;
                if (vcnt == 4'd8 && error == 0) error <= 8'h3a;
                state <= emit_row ? D_VMUL : D_NEXT;
            end
            D_VMUL:  mul(D_VRES);
            D_VRES:  if (ch == 2) state <= D_OUT; else begin ch <= ch + 1'b1; state <= D_VMUL; end
            D_OUT:   begin out_valid <= 1'b1; state <= D_NEXT; end
            D_NEXT:  if (row_end) begin
                         rows <= rows + 1'b1;
                         if (emit_row) black(x_right, D_ROWEND); else state <= D_ROWEND;
                     end else state <= D_POP;
            D_ROWEND: if (rows_last) black(bot_black, S_DONE); else state <= D_ROW;
            // ---------------- upscale ----------------
            U_LOAD:  if (pop) state <= U_LGOT;
            U_LGOT:  begin
                lb_we <= 1'b1;
                if (srcx == Wm1) begin srcx <= 0; state <= U_PREP; end
                else begin srcx <= srcx + 1'b1; state <= U_LOAD; end
            end
            U_PREP:  state <= U_PREP2;
            U_PREP2: state <= U_PREP3;
            U_PREP3: state <= U_ROWS;
            U_ROWS:  if (rows_done) black(bot_black, S_DONE);
                     else if (row_ready) begin i_col <= 0; black(x0, U_P0); end
                     else begin r_row <= r_row + 1'b1; state <= U_LOAD; end
            U_P0:    if (out_ready) state <= U_P1;
            U_P1:    state <= U_P2;
            U_P2:    begin ch <= 0; state <= U_T; end
            U_T:     begin lret <= U_TB; state <= L_START; end   // top row, horizontal
            U_TB:    begin lret <= U_BV; state <= L_START; end   // bottom row, horizontal
            U_BV:    begin lret <= U_VD; state <= L_START; end   // vertical
            U_VD:    if (ch == 2) state <= U_OUT; else begin ch <= ch + 1'b1; state <= U_T; end
            U_OUT:   begin
                out_valid <= 1'b1; i_col <= i_col + 1'b1;
                if (i_col == fit_w_m1) black(x_right, U_ROWDONE); else state <= U_P0;
            end
            U_ROWDONE: begin j_row <= j_row + 1'b1; state <= U_PREP; end
            // lerp subroutine: lv = la + (((lb-la)*lf + 128) >>> 8)
            L_START: if (lf == 0) state <= lret; else mul(L_SGN);
            L_SGN:   state <= L_FIN;
            L_FIN:   state <= lret;
            S_DONE:  if (commit_seen) begin out_commit <= 1'b1; state <= S_IDLE; end
            default: state <= S_IDLE;
            endcase
        end
    end

    // ---------------- datapath ------------------------------------------------------
    always @(posedge clk) begin
        emit_next <= tn_v >= H;
        close_next <= tn_h >= W;
        case (state)
        S_HDR: if (header_valid) begin
            W <= src_w; H <= src_h; Wm1 <= src_w - 1'b1;
            upscale <= src_w < OUT_W && src_h < OUT_H;
            scaled <= src_w != OUT_W || src_h != OUT_H;
            mul_x <= src_w; mul_y <= OUT_H; mul_acc <= 0;
        end
        S_MUL: if (mul_y != 0) begin
            if (mul_y[0]) mul_acc <= mul_acc + mul_x;
            mul_x <= {mul_x[26:0], 1'b0}; mul_y <= {1'b0, mul_y[11:1]};
        end
        S_PA:   begin prod_a <= mul_acc[21:0]; mul_x <= H; mul_y <= OUT_W; mul_acc <= 0; end
        S_PB:   prod_b <= mul_acc[21:0];
        S_CMP:  begin wide <= prod_a >= prod_b; numa <= prod_b + (W >> 1); numb <= prod_a + (H >> 1); end
        S_CMP2: begin div_num <= wide ? numa : numb; div_den <= wide ? W : H; div_rem <= 0; end
        S_DIV:  if (div_shift >= {1'b0, div_den}) begin div_rem <= div_shift - div_den; div_num <= {div_num[26:0], 1'b1}; end
                else begin div_rem <= div_shift; div_num <= {div_num[26:0], 1'b0}; end
        S_FITQ: if (wide) begin fit_w <= OUT_W; fit_h <= (div_num == 0) ? 11'd1 : (div_num > OUT_H ? OUT_H : div_num[10:0]); end
                else begin fit_h <= OUT_H; fit_w <= (div_num == 0) ? 11'd1 : (div_num > OUT_W ? OUT_W : div_num[10:0]); end
        S_GEOM: begin
            x0 <= (OUT_W - fit_w) >> 1; y0 <= (OUT_H - fit_h) >> 1;
            x_right <= OUT_W - fit_w - ((OUT_W - fit_w) >> 1);
            bot_rows <= OUT_H - fit_h - ((OUT_H - fit_h) >> 1);
            fit_w_m1 <= fit_w - 1'b1;
            mul_x <= (OUT_H - fit_h) >> 1; mul_y <= OUT_W; mul_acc <= 0;
        end
        S_TB:   begin top_black <= mul_acc[18:0]; mul_x <= bot_rows; mul_y <= OUT_W; mul_acc <= 0; end
        S_BB:   bot_black <= mul_acc[18:0];
        S_SX:   begin
            tv <= 0; vcnt <= 0;
            if (upscale) begin div_num <= {W - 1'b1, 16'd0}; div_den <= fit_w - 1'b1; div_rem <= 0; end
        end
        S_SXQ:  begin step_x <= div_num; div_num <= {H - 1'b1, 16'd0}; div_den <= fit_h - 1'b1; div_rem <= 0; end
        S_SYQ:  begin step_y <= div_num; sy <= 0; end
        S_CLEAR: begin acc_waddr <= col; acc_wdata <= 33'd0; end
        S_BLACK: out_rgb <= 24'd0;
        // downscale
        D_ROW: begin
            th <= 0; hs_r <= 0; hs_g <= 0; hs_b <= 0; hcnt <= 0;
            emit_row <= emit_next; vrec <= recip(vcnt + 1'b1);
        end
        D_GOT: begin
            hs_r <= hs_r + q[23:16]; hs_g <= hs_g + q[15:8]; hs_b <= hs_b + q[7:0]; hcnt <= hcnt + 1'b1;
            hrec <= recip(hcnt + 1'b1);
            th <= close_col ? tn_h - W : tn_h;
        end
        D_HMUL: begin mul_x <= hrec; mul_y <= pick11(ch, hs_r, hs_g, hs_b); mul_acc <= 28'd32768; end
        D_HRES: case (ch) 0: hv_r <= sat_avg; 1: hv_g <= sat_avg; default: hv_b <= sat_avg; endcase
        D_ACC0: accq_r <= acc_q;
        D_ACC: begin
            vs_r <= accq_r[32:22] + hv_r; vs_g <= accq_r[21:11] + hv_g; vs_b <= accq_r[10:0] + hv_b;
            acc_waddr <= col;
            acc_wdata <= emit_row ? 33'd0 : {accq_r[32:22] + hv_r, accq_r[21:11] + hv_g, accq_r[10:0] + hv_b};
            hs_r <= 0; hs_g <= 0; hs_b <= 0; hcnt <= 0;
        end
        D_VMUL: begin mul_x <= vrec; mul_y <= pick11(ch, vs_r, vs_g, vs_b); mul_acc <= 28'd32768; end
        D_VRES: case (ch) 0: o_r <= sat_avg; 1: o_g <= sat_avg; default: o_b <= sat_avg; endcase
        D_OUT:  out_rgb <= {o_r, o_g, o_b};
        D_NEXT: if (row_end) begin
            rows_last <= rows + 1'b1 == H;
            if (emit_row) begin tv <= tn_v - H; vcnt <= 0; end else begin tv <= tn_v; vcnt <= vcnt + 1'b1; end
        end
        // upscale
        U_LGOT:  begin lb_wsel <= r_row[0]; lb_waddr <= srcx[LW-1:0]; lb_wdata <= q; end
        U_PREP:  begin y0r <= sy[27:16]; fyr <= sy[15:8]; end
        U_PREP2: begin
            selr <= y0r[0];
            if (y0r + 1'b1 < H) y1r <= y0r + 1'b1; else begin y1r <= y0r; fyr <= 8'd0; end
        end
        U_PREP3: begin row_ready <= y1r <= r_row; rows_done <= j_row == fit_h; end
        U_ROWS:  sx <= 0;
        U_P0:    fxr <= sx[15:8];
        U_P1:    begin {ta_r, ta_g, ta_b} <= selr ? lb1_q : lb0_q; {ba_r, ba_g, ba_b} <= selr ? lb0_q : lb1_q; end
        U_P2:    begin {tb_r, tb_g, tb_b} <= selr ? lb1_q : lb0_q; {bb_r, bb_g, bb_b} <= selr ? lb0_q : lb1_q; end
        U_T:     begin la <= pick(ch, ta_r, ta_g, ta_b); lb <= pick(ch, tb_r, tb_g, tb_b); lf <= fxr; end
        U_TB:    begin ht <= lv; la <= pick(ch, ba_r, ba_g, ba_b); lb <= pick(ch, bb_r, bb_g, bb_b); lf <= fxr; end
        U_BV:    begin la <= ht; lb <= lv; lf <= fyr; end
        U_VD:    case (ch) 0: o_r <= lv; 1: o_g <= lv; default: o_b <= lv; endcase
        U_OUT:   begin out_rgb <= {o_r, o_g, o_b}; sx <= sx + step_x; end
        U_ROWDONE: sy <= sy + step_y;
        L_START: begin   // |b - a| * f by the shared multiplier; sign applied afterwards
            lv <= la; lneg <= lb < la;
            mul_x <= (lb >= la) ? lb - la : la - lb; mul_y <= lf; mul_acc <= 0;
        end
        L_SGN:   lsp <= lneg ? 18'sd128 - $signed({2'b00, mul_acc[15:0]}) : $signed({2'b00, mul_acc[15:0]}) + 18'sd128;
        L_FIN:   lv <= la + lsp[15:8];   // arithmetic >>> 8, then modulo-256 add (result in range)
        default: ;
        endcase
    end
endmodule
