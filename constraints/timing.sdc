# Board clock and existing system/video PLLs retain the baseline parameters.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {ext_mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {video_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
# Concurrent pixel and serializer clocks remain related (never exclusive).
# No blanket storage/video cuts. FIFO Gray-pointer exceptions are vendor scoped.
# External I/O timing and hard-SDRAM model paths remain visible for review.
# Startup reset request paths remain visible in STA. Each ed_reset implements
# asynchronous assertion and three-stage local release. A future exception must
# target verified post-synthesis objects and preserve release recovery/removal.
# Exception (2026-11-02): the board-clock power-up hold drives only the asynchronous
# set of the ed_reset synchronizer flops (u_*_reset/release_ff, which TD replicates for
# fanout). That input is asynchronous by design: only stage 0 samples a 0, stages 1-2
# hold 1 on the first released edge, so its recovery check against 125 MHz is not a real
# constraint. The release from release_ff to every domain register stays analysed.
# power_count reaches other clocks only through async_reset (ed_reset set inputs). Clock-based
# target because TD adds release_ff replicas during placement, after the SDC is bound.
set_false_path -from [get_regs {power_count[*]}] -to [get_clocks {ext_mem_clk video_clk}]
