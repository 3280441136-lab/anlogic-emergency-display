// Adapted reference: 03第三方的课程资料/完赛篇/第七讲：FAT32文件系统升级/第6课_FAT32文件系统/media_storage_ingest_top.v
// Original remains read-only. Product changes and interface review: docs/设计与优化.md.
`timescale 1ns/1ps

module media_storage_ingest_top #(
    parameter integer SPI_CLK_DIV = 4,
    // Card identification clock divider (SCLK = clk / (2*INIT_SPI_CLK_DIV), <= 400 kHz).
    parameter integer INIT_SPI_CLK_DIV = 160,
    parameter integer IMAGE_WIDTH = 640,
    parameter integer IMAGE_HEIGHT = 480,
    parameter integer ADDR_WIDTH = 21,
    parameter integer FIFO_DEPTH = 512,
    parameter integer STALL_TIMEOUT = 65535,
    parameter integer MIN_SRC = 16,
    parameter integer INIT_STARTUP_DELAY_CYCLES = 4000000,
    // CMD17 data-token polls (0xFF bytes) before ERR_TOKEN_TIMEOUT.
    parameter integer TOKEN_TIMEOUT_BYTES = 4096,
    // Extra attempts for one failed sector read before reporting the error.
    parameter integer SECTOR_RETRIES = 0,
    // 1: data-CRC mismatch is a sector error. 0: SPI non-protected mode, the card's
    // CRC is "don't care" (SD Physical Layer 7.2.2); mismatches are only counted.
    parameter CHECK_DATA_CRC = 1'b1
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output wire                  busy,
    output reg                   done,
    output reg  [2:0]            error_stage,
    output reg  [7:0]            error_code,
    output reg  [7:0]            error_detail,
    output wire                  card_ready,
    output wire                  card_high_capacity,
    output wire [5:0]            resource_valid,
    output wire [5:0]            image_complete,
    output wire [5:0]            image_scaled,
    // Diagnostics, clk domain: 0 idle, 1 card init, 2 file ingest; image being
    // loaded; first non-zero SPI sector-reader error since start (sticky).
    output wire [1:0]            status_state,
    output wire [2:0]            status_image,
    output reg  [7:0]            status_sector_error,
    // Completed sector reads whose data CRC differed, saturating at 255.
    output reg  [7:0]            status_crc_mismatches,
    // SDRAM write port, mem_clk domain; everything else runs on clk. The only crossing is
    // inside media_frame_loader (vendor async FIFO + req/ack toggle).
    input  wire                  mem_clk,
    input  wire                  mem_rst_n,
    input  wire                  controller_init_done,
    input  wire                  controller_busy,
    input  wire                  refresh_active,
    output wire                  app_wr_en,
    output wire [ADDR_WIDTH-1:0] app_wr_addr,
    output wire [3:0]            app_wr_mask,
    output wire [31:0]           app_wr_data,
    output wire                  sd_cs_n,
    output wire                  sd_sclk,
    output wire                  sd_mosi,
    input  wire                  sd_miso
);
    localparam ST_IDLE = 2'd0;
    localparam ST_INIT = 2'd1;
    localparam ST_INGEST = 2'd2;
    localparam ERR_STAGE_NONE = 3'd0;
    localparam ERR_STAGE_INIT = 3'd1;
    localparam ERR_STAGE_INGEST = 3'd2;

    reg [1:0] state;
    reg init_start;
    reg ingest_start;
    wire init_done;
    wire [7:0] init_error;
    wire service_sector_req;
    wire [31:0] service_sector_lba;
    wire service_sector_busy;
    wire service_sector_done;
    wire service_sector_valid;
    wire [7:0] service_sector_byte;
    wire [8:0] service_sector_byte_index;
    wire [7:0] service_sector_error;
    wire service_sector_crc_mismatch;
    wire ingest_done;
    wire [7:0] ingest_error;
    wire [7:0] ingest_detail_error;

    assign busy = state != ST_IDLE;
    assign status_state = state;

    sd_media_service #(.SPI_CLK_DIV(SPI_CLK_DIV), .INIT_SPI_CLK_DIV(INIT_SPI_CLK_DIV),
                       .INIT_STARTUP_DELAY_CYCLES(INIT_STARTUP_DELAY_CYCLES),
                       .MAX_TOKEN_BYTES(TOKEN_TIMEOUT_BYTES),
                       .CHECK_DATA_CRC(CHECK_DATA_CRC))
        u_sd_service (
        .clk(clk), .rst_n(rst_n), .init_start(init_start), .init_busy(),
        .init_done(init_done), .init_ready(card_ready), .init_error(init_error),
        .card_high_capacity(card_high_capacity), .card_ocr(), .owner_reader(),
        .sector_req(service_sector_req), .sector_lba(service_sector_lba),
        .sector_busy(service_sector_busy), .sector_done(service_sector_done),
        .sector_valid(service_sector_valid), .sector_byte(service_sector_byte),
        .sector_byte_index(service_sector_byte_index),
        .sector_error(service_sector_error),
        .sector_crc_mismatch(service_sector_crc_mismatch), .sd_cs_n(sd_cs_n),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso)
    );

    media_ingest_frontend #(
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .ADDR_WIDTH(ADDR_WIDTH), .FIFO_DEPTH(FIFO_DEPTH),
        .STALL_TIMEOUT(STALL_TIMEOUT), .MIN_SRC(MIN_SRC),
        .SECTOR_RETRIES(SECTOR_RETRIES)
    ) u_ingest_frontend (
        .clk(clk), .rst_n(rst_n), .start(ingest_start), .busy(),
        .done(ingest_done), .ingest_error(ingest_error),
        .ingest_detail_error(ingest_detail_error), .current_image(status_image),
        .resource_valid(resource_valid), .image_complete(image_complete),
        .image_scaled(image_scaled),
        .reader_req(service_sector_req), .reader_lba(service_sector_lba),
        .reader_busy(service_sector_busy), .reader_valid(service_sector_valid),
        .reader_byte(service_sector_byte),
        .reader_byte_index(service_sector_byte_index),
        .reader_done(service_sector_done), .reader_error(service_sector_error),
        .mem_clk(mem_clk), .mem_rst_n(mem_rst_n),
        .controller_init_done(controller_init_done),
        .controller_busy(controller_busy), .refresh_active(refresh_active),
        .app_wr_en(app_wr_en), .app_wr_addr(app_wr_addr),
        .app_wr_mask(app_wr_mask), .app_wr_data(app_wr_data)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            init_start <= 1'b0;
            ingest_start <= 1'b0;
            done <= 1'b0;
            error_stage <= ERR_STAGE_NONE;
            error_code <= 8'd0;
            error_detail <= 8'd0;
            status_sector_error <= 8'd0;
            status_crc_mismatches <= 8'd0;
        end else begin
            init_start <= 1'b0;
            ingest_start <= 1'b0;
            done <= 1'b0;
            if (service_sector_done && service_sector_error != 0 &&
                status_sector_error == 0)
                status_sector_error <= service_sector_error;
            if (service_sector_done && service_sector_crc_mismatch &&
                status_crc_mismatches != 8'hff)
                status_crc_mismatches <= status_crc_mismatches + 1'b1;
            case (state)
                ST_IDLE: if (start) begin
                    error_stage <= ERR_STAGE_NONE;
                    error_code <= 8'd0;
                    error_detail <= 8'd0;
                    status_sector_error <= 8'd0;
                    status_crc_mismatches <= 8'd0;
                    init_start <= 1'b1;
                    state <= ST_INIT;
                end
                ST_INIT: if (init_done) begin
                    if (!card_ready || init_error != 0) begin
                        error_stage <= ERR_STAGE_INIT;
                        error_code <= init_error;
                        error_detail <= init_error;
                        done <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        ingest_start <= 1'b1;
                        state <= ST_INGEST;
                    end
                end
                ST_INGEST: if (ingest_done) begin
                    if (ingest_error != 0) begin
                        error_stage <= ERR_STAGE_INGEST;
                        error_code <= ingest_error;
                        error_detail <= ingest_detail_error;
                    end
                    done <= 1'b1;
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
