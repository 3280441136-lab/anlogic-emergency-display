`timescale 1ns/1ps
// ed_audio_spectrum with synthetic sines. Time is compressed 10x (a sample every 52 clocks,
// a frame every 41667) so capture/frame ratios match the product; bins are f / 46.875 Hz:
// the tallest bar must sit in the tone's bin (f / 46.875 Hz), its height must match the
// Hann/FFT scaling (amplitude A -> about A/4/128 pixels), far bins must stay low, silence
// gives no bars, nothing is shown before the first publish, and ECO halves the updates.
module tb_spectrum;
 reg clk=0;always #20 clk=~clk;
 reg rst=1,fs=0,valid=0,eco=0;reg signed [15:0] signal=0;
 reg [5:0] idx=0;reg rd=0;wire [5:0] bar,pk_bin,pk_h;
 ed_audio_spectrum dut(.clk(clk),.rst(rst),.frame_start(fs),.valid(valid),.eco(eco),.signal(signal),
  .read_index(idx),.read_enable(rd),.bar(bar),.peak_bin(pk_bin),.peak_h(pk_h));
 real freq=0,amp=0,phase=0;integer sample_div=0,frame_div=0,publishes=0;
 // 48 kHz sample stream and a 60 Hz frame_start
 always @(posedge clk) begin
  valid<=0;fs<=0;
  if(sample_div==51) begin
   sample_div<=0;valid<=1;phase=phase+2.0*3.14159265358979*freq/48000.0;
   signal<=$rtoi(amp*$sin(phase));
  end else sample_div<=sample_div+1;
  if(frame_div==41666) begin frame_div<=0;fs<=1;end else frame_div<=frame_div+1;
 end
 always @(posedge clk) if(fs && dut.state==4'd15 && (!eco || dut.eco_phase==0)) publishes=publishes+1;
 reg [5:0] bars[0:63];integer i,best,best_h,far;
 task read_bars;begin
  for(i=0;i<64;i=i+1) begin @(negedge clk);idx=i;rd=1;@(negedge clk);rd=0;@(negedge clk);bars[i]=bar;end
  best=0;best_h=0;for(i=0;i<64;i=i+1) if(bars[i]>best_h) begin best_h=bars[i];best=i;end
 end endtask
 task tone(input real f,input real a,input integer want_bin,input integer h_lo,input integer h_hi);begin
  freq=f;amp=a;repeat(6) @(posedge fs);   // a complete capture of this tone, published
  read_bars;
  far=0;for(i=0;i<64;i=i+1) if((i<want_bin-3 || i>want_bin+3) && bars[i]>far) far=bars[i];
  if(pk_bin!=best || pk_h!=best_h) $fatal(1,"peak outputs %0d/%0d vs bars %0d/%0d",pk_bin,pk_h,best,best_h);
  if(best!=want_bin || best_h<h_lo || best_h>h_hi || far>2)
   $fatal(1,"tone %0f Hz amp %0f: peak bin %0d (want %0d) height %0d (want %0d..%0d), far bins max %0d",f,a,best,want_bin,best_h,h_lo,h_hi,far);
  $display("  %0.1f Hz amp %0.0f -> bin %0d height %0d",f,a,best,best_h);
 end endtask
 initial begin
  repeat(5) @(negedge clk);rst=0;
  read_bars;if(best_h!=0) $fatal(1,"bars before the first publish");
  tone(750.0,30000.0,16,52,63);       // bin-centred, A/4/128 = 58.6
  tone(1031.25,16000.0,22,26,33);      // bin-centred, half amplitude: 31
  tone(523.25,30000.0,11,48,63);       // C5 chime pitch, between bins 11 and 12
  tone(1200.0,26600.0,26,42,56);       // siren top
  freq=0;amp=0;repeat(6) @(posedge fs);read_bars;if(best_h>1) $fatal(1,"silence shows %0d",best_h);
  // ECO: a new transform only on every fourth frame (normally every second frame)
  publishes=0;repeat(16) @(posedge fs);i=publishes;eco=1;publishes=0;repeat(16) @(posedge fs);
  if(publishes*2>i+1) $fatal(1,"ECO publishes %0d vs normal %0d",publishes,i);
  $display("PASS tb_spectrum: 128-point Hann FFT bins and heights for 4 tones, low leakage, silence, no early bars, ECO %0d/%0d publishes",publishes,i);
  $finish;
 end
 initial begin #3000000000;$fatal(1,"timeout state %0d",dut.state);end
endmodule
