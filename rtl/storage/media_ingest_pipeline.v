// Adapted reference: 03第三方的课程资料/完赛篇/第七讲：FAT32文件系统升级/第6课_FAT32文件系统/media_ingest_pipeline.v
// Original remains read-only. Product changes and interface review: docs/设计与优化.md.
`timescale 1ns/1ps

module media_ingest_pipeline #(
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480,
    parameter integer ADDR_WIDTH = 21,
    parameter integer FIFO_DEPTH = 512,
    parameter integer STALL_TIMEOUT = 65535,
    // Smallest accepted source width/height (largest is 2048); tests with a tiny output
    // frame lower it.
    parameter integer MIN_SRC = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output wire                  busy,
    output reg                   done,
    output reg  [7:0]            ingest_error,
    output reg  [7:0]            ingest_detail_error,
    // Six images PIC1..PIC6 (banks 0..5).
    output reg  [2:0]            current_image,
    output wire [5:0]            resource_valid,
    output wire [5:0]            image_complete,
    output reg  [5:0]            image_scaled,

    output wire                  sector_req,
    output wire [31:0]           sector_lba,
    input  wire                  sector_busy,
    input  wire                  sector_valid,
    input  wire [7:0]            sector_byte,
    input  wire [8:0]            sector_byte_index,
    input  wire                  sector_done,
    input  wire [7:0]            sector_error,

    // SDRAM write port, mem_clk domain (crossing inside media_frame_loader).
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data
);
    localparam integer IMAGE_WORDS = IMAGE_WIDTH * IMAGE_HEIGHT;
    localparam ERR_NONE   = 8'h00;
    localparam ERR_SCAN   = 8'h80;
    localparam ERR_FILE   = 8'h82;
    localparam ERR_BMP    = 8'h83;
    localparam ERR_MEMORY = 8'h84;

    localparam ST_IDLE      = 3'd0;
    localparam ST_SCAN      = 3'd1;
    localparam ST_FILE_PREP=3'd5;
    localparam ST_FILE_START= 3'd2;
    localparam ST_FILE      = 3'd3;
    localparam ST_FAIL_WAIT = 3'd4;

    reg [2:0] state;
    reg scan_start;
    reg file_start;
    reg load_start;

    wire scan_busy;
    wire scan_done;
    wire [7:0] scan_error;
    wire [7:0] sectors_per_cluster;
    wire [31:0] fat_start_lba;
    wire [31:0] data_start_lba;
    wire [31:0] max_cluster;
    wire [31:0] resource0_cluster, resource1_cluster;
    wire [31:0] resource2_cluster, resource3_cluster, resource4_cluster, resource5_cluster;
    wire [31:0] resource0_size, resource1_size;
    wire [31:0] resource2_size, resource3_size, resource4_size, resource5_size;
    wire scan_sector_req;
    wire [31:0] scan_sector_lba;

    wire file_busy;
    wire file_done;
    wire file_valid;
    wire [7:0] file_byte;
    wire [31:0] file_byte_offset;
    wire [7:0] file_error;
    wire file_sector_req;
    wire [31:0] file_sector_lba;
    reg [31:0] selected_cluster;
    wire [31:0] selected_cluster_mux;
    reg [31:0] selected_size;
    wire [31:0] selected_size_mux;

    wire src_valid;
    wire [23:0] src_rgb;
    wire src_commit, header_ok;
    wire [11:0] src_w, src_h;
    wire pixel_valid;
    wire [23:0] pixel_rgb;
    wire frame_commit;
    wire scaler_hold, load_ready;
    wire [7:0] scaler_error;
    wire [10:0] fit_w, fit_h;
    wire image_is_scaled;
    wire bmp_done;
    wire [7:0] bmp_error;
    wire source_top_down;
    wire load_busy;
    wire load_done;
    wire [7:0] memory_error;

    // Timing: each consumer gets its own registered copy of the replayed sector bus.
    // valid/byte/index/done/error are all delayed by the same one cycle, so their
    // relative order is unchanged; busy is not delayed (it only gates new requests,
    // which consumers issue after seeing done, when the replay buffer is idle).
    // Only the strobes are reset; byte/index/error are qualified by them (their content
    // is ignored until a strobe, which follows one cycle after the source registers).
    reg scan_sv, scan_sd, file_sv, file_sd;
    reg [7:0] scan_sb, file_sb, scan_se, file_se;
    reg [8:0] scan_si, file_si;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scan_sv <= 0; scan_sd <= 0; file_sv <= 0; file_sd <= 0;
        end else begin
            scan_sv <= sector_valid; scan_sd <= sector_done;
            file_sv <= sector_valid; file_sd <= sector_done;
        end
    end
    always @(posedge clk) begin
        // Both consumers only test sector_error != 0: pass the reduced bit (timing).
        scan_sb <= sector_byte; scan_se <= {7'd0, |sector_error}; scan_si <= sector_byte_index;
        file_sb <= sector_byte; file_se <= {7'd0, |sector_error}; file_si <= sector_byte_index;
    end

    assign busy = state != ST_IDLE;
    assign sector_req = scan_sector_req | file_sector_req;
    assign sector_lba = scan_sector_req ? scan_sector_lba : file_sector_lba;

    assign selected_cluster_mux = current_image == 3'd0 ? resource0_cluster :
                              current_image == 3'd1 ? resource1_cluster :
                              current_image == 3'd2 ? resource2_cluster :
                              current_image == 3'd3 ? resource3_cluster :
                              current_image == 3'd4 ? resource4_cluster : resource5_cluster;
    assign selected_size_mux = current_image == 3'd0 ? resource0_size :
                           current_image == 3'd1 ? resource1_size :
                           current_image == 3'd2 ? resource2_size :
                           current_image == 3'd3 ? resource3_size :
                           current_image == 3'd4 ? resource4_size : resource5_size;

    fat32_volume_scanner u_volume_scanner (
        .clk(clk), .rst_n(rst_n), .scan_start(scan_start), .scan_busy(scan_busy),
        .scan_done(scan_done), .fs_error(scan_error), .partition_lba(),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .resource_valid(resource_valid),
        .resource0_cluster(resource0_cluster), .resource1_cluster(resource1_cluster),
        .resource2_cluster(resource2_cluster), .resource3_cluster(resource3_cluster),
        .resource4_cluster(resource4_cluster), .resource5_cluster(resource5_cluster),
        .resource0_size(resource0_size), .resource1_size(resource1_size),
        .resource2_size(resource2_size), .resource3_size(resource3_size),
        .resource4_size(resource4_size), .resource5_size(resource5_size),
        .sector_req(scan_sector_req), .sector_lba(scan_sector_lba),
        .sector_busy(sector_busy), .sector_valid(scan_sv), .sector_byte(scan_sb),
        .sector_byte_index(scan_si), .sector_done(scan_sd),
        .sector_error(scan_se)
    );

    fat32_file_streamer u_file_streamer (
        .clk(clk), .rst_n(rst_n), .file_start(file_start), .hold(scaler_hold),
        .first_cluster(selected_cluster), .file_size(selected_size),
        .sectors_per_cluster(sectors_per_cluster), .fat_start_lba(fat_start_lba),
        .data_start_lba(data_start_lba), .max_cluster(max_cluster),
        .file_busy(file_busy), .file_done(file_done), .file_valid(file_valid),
        .file_byte(file_byte), .file_byte_offset(file_byte_offset), .fs_error(file_error),
        .sector_req(file_sector_req), .sector_lba(file_sector_lba),
        .sector_busy(sector_busy), .sector_valid(file_sv), .sector_byte(file_sb),
        .sector_byte_index(file_si), .sector_done(file_sd),
        .sector_error(file_se)
    );

    bmp24_decoder #(.MIN_SRC(MIN_SRC), .MAX_SRC(2048)) u_bmp_decoder (
        .clk(clk), .rst_n(rst_n), .file_start(file_start), .file_size(selected_size),
        .file_valid(file_valid), .file_byte(file_byte), .file_byte_offset(file_byte_offset),
        .file_end(file_done), .upstream_error(file_error), .header_accepted(header_ok),
        .src_w(src_w), .src_h(src_h), .pixel_valid(src_valid), .pixel_rgb(src_rgb),
        .frame_commit(src_commit), .bmp_done(bmp_done), .bmp_error(bmp_error),
        .top_down(source_top_down), .pixel_offset()
    );

    // Any-size source -> centred IMAGE_WIDTH x IMAGE_HEIGHT frame (see image_fit_scaler).
    image_fit_scaler #(.OUT_W(IMAGE_WIDTH), .OUT_H(IMAGE_HEIGHT)) u_scaler (
        .clk(clk), .rst_n(rst_n), .start(file_start), .header_valid(header_ok),
        .src_w(src_w), .src_h(src_h), .in_valid(src_valid), .in_rgb(src_rgb), .in_commit(src_commit),
        .hold(scaler_hold), .out_ready(load_ready), .out_valid(pixel_valid), .out_rgb(pixel_rgb),
        .out_commit(frame_commit), .error(scaler_error), .fit_w(fit_w), .fit_h(fit_h), .scaled(image_is_scaled)
    );
    media_frame_loader #(
        .ADDR_WIDTH(ADDR_WIDTH), .IMAGE_WORDS(IMAGE_WORDS),
        .FRAME_WIDTH(IMAGE_WIDTH), .FRAME_HEIGHT(IMAGE_HEIGHT),
        .FIFO_DEPTH(FIFO_DEPTH), .STALL_TIMEOUT(STALL_TIMEOUT)
    ) u_frame_loader (
        .clk(clk), .rst_n(rst_n), .load_start(load_start), .image_index(current_image),
        .pixel_valid(pixel_valid), .pixel_rgb(pixel_rgb), .frame_commit(frame_commit),
        .decode_error(bmp_error != 0 ? bmp_error : scaler_error), .top_down(source_top_down),
        .load_busy(load_busy), .load_done(load_done), .load_ready(load_ready),
        .image_complete(image_complete), .memory_error(memory_error),
        .mem_clk(mem_clk), .mem_rst_n(mem_rst_n),
        .controller_init_done(controller_init_done), .controller_busy(controller_busy),
        .refresh_active(refresh_active), .app_wr_en(app_wr_en),
        .app_wr_addr(app_wr_addr), .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;selected_cluster<=0;selected_size<=0;
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;
            ingest_error <= ERR_NONE;
            ingest_detail_error <= ERR_NONE;
            current_image <= 3'd0;
            image_scaled <= 6'd0;
        end else begin
            scan_start <= 1'b0;
            file_start <= 1'b0;
            load_start <= 1'b0;
            done <= 1'b0;

            case (state)
                ST_IDLE: if (start) begin
                    ingest_error <= ERR_NONE;
                    ingest_detail_error <= ERR_NONE;
                    current_image <= 3'd0;
                    image_scaled <= 6'd0;
                    scan_start <= 1'b1;
                    state <= ST_SCAN;
                end
                ST_SCAN: if (scan_done) begin
                    if (scan_error != 0) begin
                        ingest_error <= ERR_SCAN;
                        ingest_detail_error <= scan_error;
                        state <= ST_FAIL_WAIT;
                    end else begin
                        current_image <= 3'd0;
                        state <= ST_FILE_PREP;
                    end
                end
                ST_FILE_PREP: begin
                    selected_cluster<=selected_cluster_mux;selected_size<=selected_size_mux;
                    state<=ST_FILE_START;
                end
                ST_FILE_START: begin
                    file_start <= 1'b1;
                    load_start <= 1'b1;
                    state <= ST_FILE;
                end
                ST_FILE: if (load_done) begin
                    if (file_error != 0) begin
                        ingest_error <= ERR_FILE;
                        ingest_detail_error <= file_error;
                        state <= ST_FAIL_WAIT;
                    end else if (bmp_error != 0 || scaler_error != 0) begin
                        ingest_error <= ERR_BMP;
                        ingest_detail_error <= bmp_error != 0 ? bmp_error : scaler_error;
                        state <= ST_FAIL_WAIT;
                    end else if (memory_error != 0) begin
                        ingest_error <= ERR_MEMORY;
                        ingest_detail_error <= memory_error;
                        state <= ST_FAIL_WAIT;
                    end else if (current_image == 3'd5) begin
                        image_scaled[current_image] <= image_is_scaled;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        image_scaled[current_image] <= image_is_scaled;
                        current_image <= current_image + 1'b1;
                        state <= ST_FILE_PREP;
                    end
                end
                ST_FAIL_WAIT: if (!scan_busy && !file_busy && !load_busy) begin
                    done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
