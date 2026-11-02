// Product integration: official PLL/SDRAM/HDMI interfaces, product-owned application.
// See docs/设计与优化.md for sources, clock crossings, resources and limitations.
module emergency_display_top(
 // Board keys: rst_n = KEY1 (A2), key1 = K2 (B2), key3 = K3 (B1), key2 = K4 (C1).
 // alarm_sw: toggle switch SW1 (C8, up = 1), simulated fire-alarm input -> emergency mode.
 input clk,rst_n,key1,key2,key3,alarm_sw,
 output [5:0] seg_sel,output [7:0] seg_data,
 // W25Q64 user flash (board manual p.17), settings only; not the configuration flash.
 output flash_cs_n,flash_sclk,flash_mosi,flash_wp_n,flash_hold_n,input flash_miso,
 output HDMI_CLK_P,HDMI_D2_P,HDMI_D1_P,HDMI_D0_P,
 output HDMI_DDC_SCL,inout HDMI_DDC_SDA,
 output sd_ncs,sd_dclk,sd_mosi,input sd_miso
);
 wire sd_card_clk,ext_mem_clk,ext_mem_clk_sft,video_clk,hdmi_5x_clk;
 sys_pll sys_pll_m0(.refclk(clk),.clk0_out(sd_card_clk),.clk1_out(ext_mem_clk),.clk2_out(ext_mem_clk_sft),.reset(1'b0));
 video_pll video_pll_m0(.refclk(clk),.clk0_out(video_clk),.clk1_out(hdmi_5x_clk),.reset(1'b0));
 // 10.49ms reference-domain power-up hold; existing PLL parameters remain unchanged.
 reg [19:0] power_count=0;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) power_count<=0;else if(!power_count[19]) power_count<=power_count+1'b1;
 end
 wire async_reset=!rst_n||!power_count[19];
 wire rst_mem,rst_all;
 ed_reset u_mem_reset(.clk(ext_mem_clk),.async_rst(async_reset),.rst(rst_mem));
 ed_reset u_pix_reset(.clk(video_clk),.async_rst(async_reset),.rst(rst_all));
 // Separate release tree for the settings flash logic (same clock and release behaviour),
 // so its registers do not load the pixel-domain reset net (route/hold-fix capacity).
 wire rst_flash;
 ed_reset u_flash_reset(.clk(video_clk),.async_rst(async_reset),.rst(rst_flash));
 // Loading chain (SD, FAT32, BMP, scaler, boot control, digit display) also runs on the
 // 25 MHz pixel clock, with its own release tree. Only the SDRAM write port is at 125 MHz;
 // media_frame_loader crosses with the vendor async FIFO and a req/ack toggle pair.
 wire rst_load;
 ed_reset u_load_reset(.clk(video_clk),.async_rst(async_reset),.rst(rst_load));
 wire Sdr_init_done,Sdr_init_ref_vld,Sdr_busy,Sdr_rd_en;
 // ref_hold: refresh scheduled; both masters finish the current burst and start no new one.
 wire ref_hold;wire [15:0] ref_requests;
 wire App_rd_en,App_wr_en;
 wire [20:0] App_rd_addr,App_wr_addr;
 wire [31:0] App_wr_din,Sdr_rd_dout;
 wire [3:0] App_wr_dm;
 // Official controller with the project refresh timer (ed_sdram in rtl/ed_framebuffer.v).
 ed_sdram U3(.Clk(ext_mem_clk),.Clk_sft(ext_mem_clk_sft),.Rst(rst_mem),
  .Sdr_init_done(Sdr_init_done),.Sdr_init_ref_vld(Sdr_init_ref_vld),.Sdr_busy(Sdr_busy),
  .ref_hold(ref_hold),.ref_count(ref_requests),
  .App_wr_en(App_wr_en),.App_wr_addr(App_wr_addr),.App_wr_dm(App_wr_dm),.App_wr_din(App_wr_din),
  .App_rd_en(App_rd_en),.App_rd_addr(App_rd_addr),.Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout));
 wire ingest_busy,ingest_done,card_ready;
 wire [2:0] error_stage;wire [7:0] error_code,error_detail;
 // Six images PIC1..PIC6 -> banks 0..5 (0-3 carousel, 4 notice, 5 emergency).
 wire [5:0] complete,resource_valid,scale_2x;
 wire [1:0] ingest_state;wire [2:0] ingest_image;wire [7:0] sector_error,crc_mismatches;
 // Boot watchdog only catches a hung loader: every SD/FAT/BMP/SDRAM step has its own
 // timeout. 90 s at 25 MHz; the six card images are about 11000 single-sector CMD17 reads.
 localparam [33:0] BOOT_TIMEOUT_CYCLES=34'd2249999999;
 // Automatic boot retry: a load that ends with an error (card not ready at power-up,
 // transient read error) is restarted from card initialization after RETRY_WAIT (1 s),
 // up to BOOT_RETRIES times; only then is the fault latched. The ingest chain returns to
 // idle after done, and every image bank is rewritten, so no reset is needed. A watchdog
 // timeout (hung loader) faults immediately. The watchdog spans all attempts.
 wire start,boot_done,boot_fault,boot_timeout;wire [1:0] boot_retries;
 // SDRAM init done is monotonic until reset: two flip-flop level synchronizer.
 reg [1:0] mem_ready_sync;
 always @(posedge video_clk or posedge rst_load)
  if(rst_load) mem_ready_sync<=0;else mem_ready_sync<={mem_ready_sync[0],Sdr_init_done};
 ed_boot_control #(.TIMEOUT_CYCLES(BOOT_TIMEOUT_CYCLES),.RETRIES(3),.RETRY_WAIT(27'd24999999)) u_boot(
  .clk(video_clk),.rst(rst_load),.mem_ready(mem_ready_sync[1]),.ingest_done(ingest_done),
  .ingest_ok(error_code==0 && complete==6'h3f),.start(start),.boot_done(boot_done),.boot_fault(boot_fault),
  .boot_timeout(boot_timeout),.retries(boot_retries));
 // Data-token wait: 400000 polls x about 68 cycles = 218 ms, above the 100 ms SDHC
 // read-access limit (old 4096 polls were only 2.2 ms). Three extra tries per sector.
 // SPI runs in non-protected mode (no CMD59), where the card's data CRC is "don't care"
 // (SD Physical Layer 7.2.2); like the official reader it is not an error, only counted.
 // Board 2026-10-28: with checking on, this card failed MBR read 4/4 (E2_510).
 // SPI_CLK_DIV 1 at 25 MHz: SCLK 12.5 MHz (SD default speed allows 25 MHz). MISO is
 // sampled 40 ns after the SCLK fall that launches it (card output delay <= 14 ns plus pads;
 // tb_spi checks with 22 ns). Board history: 64 ns (7.8 MHz) and 80 ns (6.25 MHz) builds
 // read correctly; the sparse pixel errors once blamed on 32 ns sampling were the SDRAM
 // refresh fault found 2026-11-01. Fallback: SPI_CLK_DIV 2 (6.25 MHz).
 // Identification 390 kHz (DIV 32), power-up wait 100 ms.
 media_storage_ingest_top #(.SPI_CLK_DIV(1),.INIT_SPI_CLK_DIV(32),.FIFO_DEPTH(512),.MIN_SRC(16),
  .INIT_STARTUP_DELAY_CYCLES(2500000),.TOKEN_TIMEOUT_BYTES(400000),.SECTOR_RETRIES(3),
  .CHECK_DATA_CRC(1'b0)) u_ingest(
  .clk(video_clk),.rst_n(!rst_load),.mem_clk(ext_mem_clk),.mem_rst_n(!rst_mem),
  .start(start),.busy(ingest_busy),.done(ingest_done),
  .error_stage(error_stage),.error_code(error_code),.error_detail(error_detail),
  .card_ready(card_ready),.card_high_capacity(),.resource_valid(resource_valid),.image_complete(complete),.image_scaled(scale_2x),
  .status_state(ingest_state),.status_image(ingest_image),.status_sector_error(sector_error),
  .status_crc_mismatches(crc_mismatches),.controller_init_done(Sdr_init_done),.controller_busy(Sdr_busy),.refresh_active(Sdr_init_ref_vld||ref_hold),
  .app_wr_en(App_wr_en),.app_wr_addr(App_wr_addr),.app_wr_mask(App_wr_dm),.app_wr_data(App_wr_din),
  .sd_cs_n(sd_ncs),.sd_sclk(sd_dclk),.sd_mosi(sd_mosi),.sd_miso(sd_miso));
 // Diagnostics, SDRAM domain: modular sum of the 24-bit pixels written to each bank.
 // Writes of image i happen only while the loader's current image is i: ingest_image
 // advances only after the loader's end handshake (all writes done), so it is quasi-static
 // here and a two flip-flop synchronizer suffices. Boot start (pixel-domain pulse) clears
 // the sums through a toggle synchronizer. Frozen at boot end; read in the pixel domain.
 reg [31:0] load_sum0,load_sum1,load_sum2,load_sum3,load_sum4,load_sum5;reg load_we;reg [23:0] load_px;reg [2:0] load_bank;
 reg start_t;reg [2:0] start_sync;reg [2:0] bank_sync0,bank_sync1;
 always @(posedge video_clk or posedge rst_load) if(rst_load) start_t<=0;else if(start) start_t<=~start_t;
 // Only the synchronizer and the write strobe are reset (rst_mem fanout: route hold-fix
 // capacity, PHY-8023). The sums are cleared by every boot start, which always precedes
 // the first write and ready; the data copies follow their sources one cycle later.
 always @(posedge ext_mem_clk or posedge rst_mem) begin
  if(rst_mem) begin start_sync<=0;load_we<=0;end
  else begin start_sync<={start_sync[1:0],start_t};load_we<=App_wr_en;end
 end
 always @(posedge ext_mem_clk) begin
  begin
   bank_sync0<=ingest_image;bank_sync1<=bank_sync0;
   load_px<=App_wr_din[23:0];load_bank<=bank_sync1;
   if(start_sync[2]!=start_sync[1]) begin load_sum0<=0;load_sum1<=0;load_sum2<=0;load_sum3<=0;load_sum4<=0;load_sum5<=0;end
   else if(load_we) case(load_bank)
    0:load_sum0<=load_sum0+{8'd0,load_px};1:load_sum1<=load_sum1+{8'd0,load_px};
    2:load_sum2<=load_sum2+{8'd0,load_px};3:load_sum3<=load_sum3+{8'd0,load_px};
    4:load_sum4<=load_sum4+{8'd0,load_px};default:load_sum5<=load_sum5+{8'd0,load_px};
   endcase
  end
 end
 // Boot done/fault come from the same (pixel) clock; committed at a frame boundary.
 reg ready,fault;
 wire video_read_req,video_read_req_ack,video_read_en;wire [31:0] video_read_data,video_read_old;
 wire hs_0,vs_0,de_0,hs,vs,de;wire [23:0] vout_data_raw;
 wire frame_start,read_req_aligned;
 ed_frame_boundary u_boundary(.clk(video_clk),.rst(rst_all),.vs(vs_0),.read_req(video_read_req),
  .frame_start(frame_start),.read_req_aligned(read_req_aligned));
 always @(posedge video_clk or posedge rst_all) begin
  if(rst_all) begin ready<=0;fault<=0;end
  else if(frame_start) begin ready<=boot_done;fault<=boot_fault;end
 end
 wire [1:0] mode,effect,osd,committed_mode;wire [2:0] active_index,brightness,contrast,volume;wire [3:0] menu_sel;
 wire manual_next,auto_en,eco,debug,menu_open,wipe,blend;wire [4:0] gain,mix;wire [5:0] reveal;wire [2:0] old_index;
 // Debug overlay on by default (DEBUG_DEFAULT).
 wire cfg_load;wire [15:0] cfg_value;wire [2:0] settings_status;
 ed_controls #(.DEBUG_DEFAULT(1)) u_controls(.clk(video_clk),.rst(rst_all),.key1(key1),.key2(key2),.key3(key3),.alarm_sw(alarm_sw),
  .cfg_load(cfg_load),.cfg_value(cfg_value),
  .mode(mode),.manual_next(manual_next),.auto_en(auto_en),.brightness(brightness),.contrast(contrast),.volume(volume),
  .effect(effect),.osd(osd),.eco(eco),.debug(debug),.menu_open(menu_open),.menu_sel(menu_sel));
 // Settings persistence (pixel domain, same as ed_controls: no CDC).
 ed_settings_store u_settings(.clk(video_clk),.rst(rst_flash),
  .settings({osd,debug,eco,auto_en,effect,volume,contrast,brightness}),.menu_open(menu_open),
  .cfg_load(cfg_load),.cfg_value(cfg_value),.status(settings_status),
  .flash_cs_n(flash_cs_n),.flash_sclk(flash_sclk),.flash_mosi(flash_mosi),.flash_wp_n(flash_wp_n),
  .flash_hold_n(flash_hold_n),.flash_miso(flash_miso));
 ed_player u_player(.clk(video_clk),.rst(rst_all),.frame_start(frame_start),.ready(ready),
  .manual_next(manual_next),.auto_en(auto_en),.mode(mode),.effect(effect),.menu({2'b00,menu_open}),
  .active_index(active_index),.gain(gain),.wipe(wipe),.reveal(reveal),.committed_mode(committed_mode),
  .blend(blend),.mix(mix),.old_index(old_index));
 
 
 wire underflow;
 video_timing_data video_timing_data_m0(.video_clk(video_clk),.rst(rst_all),
  .read_req(video_read_req),.read_req_ack(video_read_req_ack),.hs(hs_0),.vs(vs_0),.de(de_0));
 video_delay video_delay_m0(.video_clk(video_clk),.rst(rst_all),.read_en(video_read_en),.read_data(video_read_data[23:0]),
  .hs(hs_0),.vs(vs_0),.de(de_0),.hs_r(hs),.vs_r(vs),.de_r(de),.vout_data(vout_data_raw));
 wire [15:0] refresh_rate;
 ed_framebuffer u_reader(.mem_clk(ext_mem_clk),.mem_rst(rst_mem),.pix_clk(video_clk),.pix_rst(rst_all),.enabled(boot_done),
  .refresh_rate(refresh_rate),
  .controller_init_done(Sdr_init_done),.controller_busy(Sdr_busy),.refresh_active(Sdr_init_ref_vld),.mem_hold(ref_hold),
  .request(read_req_aligned),.index(active_index),.index_old(old_index),.blend(blend),.consume(video_read_en),
  .request_ack(video_read_req_ack),.data(video_read_data),.data_old(video_read_old),
  .underflow(underflow),.app_rd_en(App_rd_en),.app_rd_addr(App_rd_addr),.return_valid(Sdr_rd_en),.return_data(Sdr_rd_dout));
 // Previous image for the cross-fade, aligned like video_delay's vout_data: the FIFO word
 // appears one clock after read_en and is registered on the following clock.
 reg read_en_d;reg [23:0] vout_old;
 always @(posedge video_clk or posedge rst_all) begin
  if(rst_all) begin read_en_d<=0;vout_old<=0;end
  else begin read_en_d<=video_read_en;vout_old<=read_en_d?video_read_old[23:0]:24'd0;end
 end
 // Coordinates aligned with official delayed DE and RGB.
 reg [9:0] pixel_x,pixel_y;reg de_d,vs_d;
 always @(posedge video_clk or posedge rst_all) begin
  if(rst_all) begin pixel_x<=0;pixel_y<=0;de_d<=0;vs_d<=1;end
  else begin
   de_d<=de;vs_d<=vs;
   if(!vs&&vs_d) begin pixel_x<=0;pixel_y<=0;end
   else if(de) begin
    if(pixel_x==639) begin pixel_x<=0;pixel_y<=pixel_y+1'b1;end else pixel_x<=pixel_x+1'b1;
   end
  end
 end
 wire audio_valid;wire signed [23:0] audio_left_data;wire [23:0] audio_right_data=audio_left_data;wire signed [15:0] audio_signal;
 ed_audio u_audio(.clk(video_clk),.rst(rst_all),.mode(committed_mode),.ready(ready),.volume(volume),
  .valid(audio_valid),.pcm(audio_left_data),.signal(audio_signal));
 wire [6:0] scope_index;wire scope_read;wire signed [7:0] wave;wire [7:0] peak;
 ed_audio_scope u_scope(.clk(video_clk),.rst(rst_all),.frame_start(frame_start),.valid(audio_valid),.eco(eco),.signal(audio_signal),
  .read_index(scope_index),.read_enable(scope_read),.wave(wave),.peak(peak));
 // 128-point FFT of the same tone for the debug panel (one shared multiplier).
 wire [5:0] spec_index,spec_bar,spec_peak_bin,spec_peak_h;wire spec_read;
 ed_audio_spectrum u_spectrum(.clk(video_clk),.rst(rst_all),.frame_start(frame_start),.valid(audio_valid),.eco(eco),
  .signal(audio_signal),.read_index(spec_index),.read_enable(spec_read),.bar(spec_bar),.peak_bin(spec_peak_bin),.peak_h(spec_peak_h));
 wire [7:0] read_changes,read_mismatches;
 ed_read_check u_read_check(.clk(video_clk),.rst(rst_all),.frame_start(frame_start),.ready(ready),
  .de(de),.pixel(vout_data_raw),.index(active_index),
  .load_sum0(load_sum0),.load_sum1(load_sum1),.load_sum2(load_sum2),.load_sum3(load_sum3),.load_sum4(load_sum4),.load_sum5(load_sum5),
  .frame_changes(read_changes),.load_mismatches(read_mismatches));
 wire processed_de,processed_vs;wire [23:0] processed_rgb;
 ed_video u_video(.clk(video_clk),.rst(rst_all),.frame_start(frame_start),.x(pixel_x),.y(pixel_y),.de(de),.vs(vs),.pixel(vout_data_raw),.pixel_old(vout_old),.blend(blend),.mix(mix),
  .ready(ready),.fault(fault),.underflow(underflow),.mode(committed_mode),.index(active_index),.effect(effect),
  .brightness(brightness),.contrast(contrast),.volume(volume),.osd(osd),.auto_en(auto_en),.eco(eco),.debug(debug),
  .menu_open(menu_open),.menu_sel(menu_sel),.gain(gain),.wipe(wipe),.reveal(reveal),.wave(wave),.peak(peak),.spec(spec_bar),.spec_peak_bin(spec_peak_bin),.spec_peak_h(spec_peak_h),
  .diag_rd(read_changes),.diag_ld(read_mismatches),.diag_ref(refresh_rate),.diag_crc(crc_mismatches),.diag_flash(settings_status),
  .wave_index(scope_index),.wave_rd(scope_read),.spec_index(spec_index),.spec_rd(spec_read),.out_de(processed_de),.out_vs(processed_vs),.rgb(processed_rgb));
 wire acr_valid;wire [19:0] acr_cts,acr_n;
 audio_arc_calculate #(.ACR_N(6144)) u_audio_arc_calculate(.I_clk(video_clk),.I_rst(rst_all),.I_audio_valid(audio_valid),
  .O_acr_valid(acr_valid),.O_acr_cts(acr_cts),.O_acr_n(acr_n));
 // Six-digit boot diagnostics run in the loading domain beside their sources (no CDC).
 // Code table: docs/上板与素材验收.md. Official scan module, rescaled for 25 MHz.
 wire [7:0] seg_status0,seg_status1,seg_status2,seg_status3,seg_status4,seg_status5;
 ed_boot_status u_boot_status(.clk(video_clk),.rst(rst_load),
  .boot_done(boot_done),.boot_fault(boot_fault),.boot_timeout(boot_timeout),
  .error_stage(error_stage),.error_code(error_code),.error_detail(error_detail),
  .complete(complete),.resource_valid(resource_valid),.state(ingest_state),.image(ingest_image),
  .sector_error(sector_error),.crc_mismatches(crc_mismatches),.card_ready(card_ready),
  .seg0(seg_status0),.seg1(seg_status1),.seg2(seg_status2),.seg3(seg_status3),.seg4(seg_status4),.seg5(seg_status5));
 seg_scan #(.CLK_FREQ(25000000)) u_seg(.clk(video_clk),.rst_n(!rst_load),.seg_sel(seg_sel),.seg_data(seg_data),
  .seg_data_0(seg_status0),.seg_data_1(seg_status1),.seg_data_2(seg_status2),
  .seg_data_3(seg_status3),.seg_data_4(seg_status4),.seg_data_5(seg_status5));
 wire axis_s_user,axis_s_valid,axis_s_last,axis_s_ready;wire [23:0] axis_s_data;
 wire edid_trig,edid_valid;wire [7:0] edid_data;
 wire [9:0] tmds_ch0_data,tmds_ch1_data,tmds_ch2_data,tmds_clk_data;
// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (processed_vs),
    .I_de          (processed_de),
    .I_rgb         (processed_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
