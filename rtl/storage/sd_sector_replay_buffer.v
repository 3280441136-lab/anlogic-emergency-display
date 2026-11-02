// Adapted reference: 03第三方的课程资料/完赛篇/第七讲：FAT32文件系统升级/第6课_FAT32文件系统/sd_sector_replay_buffer.v
// Original remains read-only. Product changes and interface review: docs/设计与优化.md.
`timescale 1ns/1ps

// Product change: a failed sector read (reader error or out-of-order capture) is
// reissued up to RETRY_LIMIT more times before the error is reported upstream.
// Bytes are only replayed after one complete, CRC-clean capture.
module sd_sector_replay_buffer #(
    parameter integer RETRY_LIMIT = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        sector_req,
    input  wire [31:0] sector_lba,
    output wire        sector_busy,
    output reg         sector_valid,
    output reg  [7:0]  sector_byte,
    output reg  [8:0]  sector_byte_index,
    output reg         sector_done,
    output reg  [7:0]  sector_error,

    output reg         reader_req,
    output reg  [31:0] reader_lba,
    input  wire        reader_busy,
    input  wire        reader_valid,
    input  wire [7:0]  reader_byte,
    input  wire [8:0]  reader_byte_index,
    input  wire        reader_done,
    input  wire [7:0]  reader_error
);
    reg [7:0] replay_data;
    reg [8:0] replay_index_out;
    reg replay_valid,replay_done;
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n)begin sector_byte<=0;sector_byte_index<=0;sector_valid<=0;sector_done<=0;end
      else begin sector_byte<=replay_data;sector_byte_index<=replay_index_out;sector_valid<=replay_valid;sector_done<=replay_done;end
    end
    localparam ERR_CAPTURE_ORDER = 8'he1;
    localparam ST_IDLE    = 3'd0;
    localparam ST_ISSUE   = 3'd1;
    localparam ST_CAPTURE = 3'd2;
    localparam ST_REPLAY  = 3'd3;
    localparam ST_DONE    = 3'd4;

    reg [2:0] state;
    reg [7:0] sector_mem [0:511] /* fehdl force_ram=1 */;
    reg [9:0] captured_count;
    reg [8:0] replay_index;
    reg capture_fault;
    reg [3:0] retries_left;
    wire attempt_failed;
    wire current_byte_in_order;
    wire [10:0] captured_count_after;

    assign sector_busy = state != ST_IDLE;
    assign current_byte_in_order = reader_byte_index == captured_count[8:0] &&
                                   captured_count < 10'd512;
    assign captured_count_after = captured_count + (reader_valid ? 1'b1 : 1'b0);
    assign attempt_failed = reader_error != 0 || capture_fault ||
                            (reader_valid && !current_byte_in_order) ||
                            captured_count_after != 11'd512;

    always @(posedge clk) begin
        if(reader_valid && state==ST_CAPTURE && current_byte_in_order)
            sector_mem[reader_byte_index]<=reader_byte;
        if(state==ST_REPLAY) replay_data<=sector_mem[replay_index];
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            replay_valid <= 1'b0;

            replay_index_out <= 9'd0;
            replay_done <= 1'b0;
            sector_error <= 8'd0;
            reader_req <= 1'b0;
            reader_lba <= 32'd0;
            captured_count <= 10'd0;
            replay_index <= 9'd0;
            capture_fault <= 1'b0;
            retries_left <= 4'd0;
        end else begin
            replay_valid <= 1'b0;
            replay_done <= 1'b0;
            reader_req <= 1'b0;

            case (state)
                // reader_lba follows sector_lba every idle cycle (timing: no request-gated
                // enable on 32 bits); the value captured with the request is held after.
                ST_IDLE: begin reader_lba <= sector_lba; if (sector_req) begin
                    sector_error <= 8'd0;
                    captured_count <= 10'd0;
                    replay_index <= 9'd0;
                    capture_fault <= 1'b0;
                    retries_left <= RETRY_LIMIT;
                    state <= ST_ISSUE;
                end end
                ST_ISSUE: if (!reader_busy) begin
                    reader_req <= 1'b1;
                    state <= ST_CAPTURE;
                end
                ST_CAPTURE: begin
                    if (reader_valid) begin
                        if (!current_byte_in_order)
                            capture_fault <= 1'b1;
                        captured_count <= captured_count + 1'b1;   // 10 bits; checked ==512 at done
                    end

                    // replay_index is unused while capturing; clearing it on every
                    // reader_done keeps the outcome decode off its enable (timing).
                    if (reader_done) replay_index <= 9'd0;
                    if (reader_done) begin
                        if (attempt_failed && retries_left != 0) begin
                            retries_left <= retries_left - 1'b1;
                            captured_count <= 10'd0;
                            capture_fault <= 1'b0;
                            state <= ST_ISSUE;
                        end else if (reader_error != 0) begin
                            sector_error <= reader_error;
                            state <= ST_DONE;
                        end else if (capture_fault ||
                                     (reader_valid && !current_byte_in_order) ||
                                     captured_count_after != 11'd512) begin
                            sector_error <= ERR_CAPTURE_ORDER;
                            state <= ST_DONE;
                        end else begin
                            state <= ST_REPLAY;
                        end
                    end
                end
                ST_REPLAY: begin
                    replay_valid <= 1'b1;

                    replay_index_out <= replay_index;
                    if (replay_index == 9'd511)
                        state <= ST_DONE;
                    else
                        replay_index <= replay_index + 1'b1;
                end
                ST_DONE: begin
                    replay_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
