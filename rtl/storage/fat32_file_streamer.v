// Adapted reference: 03第三方的课程资料/完赛篇/第七讲：FAT32文件系统升级/第6课_FAT32文件系统/fat32_file_streamer.v
// Original remains read-only. Product changes and interface review: docs/设计与优化.md.
`timescale 1ns/1ps

module fat32_file_streamer #(
    parameter integer MAX_VISITED_CLUSTERS = 8192
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        file_start,
    // Downstream back-pressure: no new DATA sector is requested while hold is high
    // (bytes of the sector in flight are always delivered).
    input  wire        hold,
    input  wire [31:0] first_cluster,
    input  wire [31:0] file_size,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] fat_start_lba,
    input  wire [31:0] data_start_lba,
    input  wire [31:0] max_cluster,
    output wire        file_busy,
    output reg         file_done,
    output reg         file_valid,
    output reg  [7:0]  file_byte,
    output reg  [31:0] file_byte_offset,
    output reg  [7:0]  fs_error,
    output reg         sector_req,
    output reg  [31:0] sector_lba,
    input  wire        sector_busy,
    input  wire        sector_valid,
    input  wire [7:0]  sector_byte,
    input  wire [8:0]  sector_byte_index,
    input  wire        sector_done,
    input  wire [7:0]  sector_error
);
    localparam ERR_NONE              = 8'h00;
    localparam ERR_SECTOR            = 8'h10;
    localparam ERR_FAT_LOOP          = 8'h23;
    localparam ERR_CLUSTER_RANGE     = 8'h24;
    localparam ERR_EARLY_EOF         = 8'h25;
    localparam ERR_VISITED_EXHAUSTED = 8'h26;

    localparam ST_IDLE       = 4'd0;
    localparam ST_DATA_REQ   = 4'd1;
    localparam ST_DATA_WAIT  = 4'd2;
    localparam ST_FAT_REQ    = 4'd3;
    localparam ST_FAT_WAIT   = 4'd4;
    localparam ST_FAT_PARSE  = 4'd5;
    localparam ST_FINISH     = 4'd7;

    localparam integer CHAIN_COUNT_WIDTH = $clog2(MAX_VISITED_CLUSTERS + 1);

    reg [2:0] cluster_shift;
    function [2:0] spc_shift;
      input [7:0] value;
      begin case(value)
       2:spc_shift=1;4:spc_shift=2;8:spc_shift=3;16:spc_shift=4;
       32:spc_shift=5;64:spc_shift=6;128:spc_shift=7;default:spc_shift=0;
      endcase end
    endfunction
    reg candidate_eoc,candidate_range,candidate_self,chain_full;
    localparam ST_FAT_CHECK=10,ST_VALIDATE=11,ST_ADDR_SUB=12;
    localparam ST_ADDR_SHIFT=8, ST_ADDR_ADD=9;
    reg [31:0] cluster_minus, cluster_scaled;
    reg [3:0] state;
    reg [31:0] current_cluster;
    reg [31:0] next_cluster;
    reg [31:0] remaining_bytes;
    // Registered remaining_bytes==0 / ==1, updated with every remaining_bytes write,
    // so the end-of-file decision does not chain a 32-bit compare into the LBA mux.
    reg remaining_zero, remaining_one;
    reg [7:0] sector_in_cluster;
    reg [8:0] fat_entry_offset;
    reg [7:0] fat_byte0, fat_byte1, fat_byte2, fat_byte3;
    reg fat_hit; reg [1:0] fat_lane; reg [7:0] fat_data; reg first_bad;
    reg [CHAIN_COUNT_WIDTH-1:0] chain_count;
    reg final_chain_check;

    assign file_busy = (state != ST_IDLE);

    task finish_with_error;
        input [7:0] code;
        begin
            fs_error <= code;
            state <= ST_FINISH;
        end
    endtask

    task advance_to_next_cluster;
        input [31:0] cluster_value;
        begin
            chain_count <= chain_count + 1'b1;
            current_cluster <= cluster_value;
            state <= ST_ADDR_SUB;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; cluster_minus<=0;cluster_scaled<=0;cluster_shift<=0;candidate_eoc<=0;candidate_range<=0;candidate_self<=0;chain_full<=0;
            file_done <= 1'b0;
            file_valid <= 1'b0;
            file_byte <= 8'd0;
            file_byte_offset <= 32'd0;
            fs_error <= ERR_NONE;
            sector_req <= 1'b0;
            sector_lba <= 32'd0;
            current_cluster <= 32'd0;
            next_cluster <= 32'd0;
            remaining_bytes <= 32'd0;
            remaining_zero <= 1'b1;
            remaining_one <= 1'b0;
            sector_in_cluster <= 8'd0;
            fat_entry_offset <= 9'd0;
            fat_byte0 <= 8'd0;
            fat_byte1 <= 8'd0;
            fat_byte2 <= 8'd0;
            fat_byte3 <= 8'd0;
            fat_hit <= 1'b0;
            fat_lane <= 2'd0;
            fat_data <= 8'd0;
            chain_count <= 0;
            final_chain_check <= 1'b0;
        end else begin
            file_done <= 1'b0;
            file_valid <= 1'b0;
            sector_req <= 1'b0;

            if (state == ST_DATA_WAIT && sector_valid && !remaining_zero) begin
                file_valid <= 1'b1;
                file_byte <= sector_byte;
                file_byte_offset <= file_size - remaining_bytes;
                remaining_bytes <= remaining_bytes - 1'b1;
                remaining_zero <= remaining_one;
                remaining_one <= remaining_bytes == 32'd2;
            end

            // FAT entry capture, one cycle after the byte (timing). The last data byte
            // precedes sector_done by at least one cycle, so the delayed write lands no
            // later than the FAT_WAIT -> FAT_CHECK edge and is visible in FAT_CHECK.
            fat_hit <= state == ST_FAT_WAIT && sector_valid &&
                       sector_byte_index[8:2] == fat_entry_offset[8:2];
            fat_lane <= sector_byte_index[1:0];
            fat_data <= sector_byte;
            if (fat_hit) begin
                case(fat_lane)
                 0:fat_byte0<=fat_data;1:fat_byte1<=fat_data;
                 2:fat_byte2<=fat_data;3:fat_byte3<=fat_data;
                endcase
            end

            case (state)
                ST_IDLE: if (file_start) begin
                    cluster_shift<=spc_shift(sectors_per_cluster);
                    fs_error <= ERR_NONE;
                    file_byte_offset <= 32'd0;
                    remaining_bytes <= file_size;
                    remaining_zero <= file_size == 32'd0;
                    remaining_one <= file_size == 32'd1;
                    sector_in_cluster <= 8'd0;
                    chain_count <= 1;
                    final_chain_check <= 1'b0;
                    current_cluster<=first_cluster;
                    // range check registered here, used in ST_VALIDATE (timing)
                    first_bad<=first_cluster<2||first_cluster>max_cluster||sectors_per_cluster==0;
                    state<=ST_VALIDATE;
                end
                ST_VALIDATE:begin
                    if(remaining_zero)state<=ST_FINISH;
                    else if(first_bad)
                        finish_with_error(ERR_CLUSTER_RANGE);
                    else state<=ST_ADDR_SUB;
                end
                ST_ADDR_SUB:begin cluster_minus<=current_cluster-2;state<=ST_ADDR_SHIFT;end
                ST_ADDR_SHIFT: begin cluster_scaled<=cluster_minus<<cluster_shift; state<=ST_ADDR_ADD;end
                ST_ADDR_ADD: begin sector_lba<=data_start_lba+cluster_scaled;state<=ST_DATA_REQ;end
                ST_DATA_REQ: if (!sector_busy && !hold) begin
                    sector_req <= 1'b1;
                    state <= ST_DATA_WAIT;
                end
                ST_DATA_WAIT: if (sector_done) begin
                    if (sector_error != 0) begin
                        finish_with_error(ERR_SECTOR);
                    end else if (remaining_zero ||
                                 (remaining_one && sector_valid)) begin
                        final_chain_check <= 1'b1;
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end else if (sector_in_cluster + 1'b1 < sectors_per_cluster) begin
                        sector_in_cluster <= sector_in_cluster + 1'b1;
                        sector_lba <= sector_lba + 1'b1;
                        state <= ST_DATA_REQ;
                    end else begin
                        sector_in_cluster <= 8'd0;
                        fat_entry_offset <= {current_cluster[6:0], 2'b00};
                        sector_lba <= fat_start_lba + (current_cluster >> 7);
                        state <= ST_FAT_REQ;
                    end
                end
                ST_FAT_REQ: if (!sector_busy) begin
                    sector_req <= 1'b1;
                    state <= ST_FAT_WAIT;
                end
                ST_FAT_WAIT: if (sector_done) begin
                    if (sector_error != 0)
                        finish_with_error(ERR_SECTOR);
                    else
                        state <= ST_FAT_CHECK;
                end
                ST_FAT_CHECK: begin
                    next_cluster <= {4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0};
                    candidate_eoc <= {fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}>=28'hffffff8;
                    candidate_range <= ({4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}<2)||
                        ({4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}>max_cluster);
                    candidate_self <= {4'd0,fat_byte3[3:0],fat_byte2,fat_byte1,fat_byte0}==current_cluster;
                    chain_full <= chain_count>=MAX_VISITED_CLUSTERS;
                    state<=ST_FAT_PARSE;
                end
                ST_FAT_PARSE: begin
                    if(final_chain_check)begin
                        final_chain_check<=0;
                        if(candidate_eoc)state<=ST_FINISH;
                        else if(candidate_range)finish_with_error(ERR_CLUSTER_RANGE);
                        else finish_with_error(ERR_FAT_LOOP);
                    end else if(candidate_eoc)finish_with_error(ERR_EARLY_EOF);
                    else if(candidate_range)finish_with_error(ERR_CLUSTER_RANGE);
                    else if(chain_full)finish_with_error(ERR_VISITED_EXHAUSTED);
                    else if(candidate_self)finish_with_error(ERR_FAT_LOOP);
                    else advance_to_next_cluster(next_cluster);
                end
                ST_FINISH: begin
                    file_done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
