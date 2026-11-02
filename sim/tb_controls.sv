`timescale 1ns/1ps
// Monitor-style three-key UI. Board labels: K2 = key1, K4 = key2, K3 = key3.
// K4 opens/closes the menu; in the menu K3 selects the next item and K2 the next value;
// outside it K2 changes image (short) / mode (long) and K3 toggles the debug overlay. Time scaled: 1 ms = 2 clocks.
module tb_controls;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,k2=1,k4=1,k3=1,sw=0,cfg_load=0;reg [15:0] cfg_value=0;
 wire [1:0] mode,fx,osd;wire [2:0] b,c,v;wire [3:0] sel;wire next,auto_en,eco,debug,menu;
 ed_controls #(.CLK_HZ(2000),.HOLD_MS(60),.MENU_IDLE_MS(300),.CHORD_MS(100),.DEBUG_DEFAULT(1)) dut(.clk(clk),.rst(rst),
  .key1(k2),.key2(k4),.key3(k3),.alarm_sw(sw),.cfg_load(cfg_load),.cfg_value(cfg_value),
  .mode(mode),.manual_next(next),.auto_en(auto_en),.brightness(b),.contrast(c),.volume(v),.effect(fx),.osd(osd),.eco(eco),.debug(debug),
  .menu_open(menu),.menu_sel(sel));
 integer nexts=0;always @(posedge clk) if(next) nexts=nexts+1;
 task wait_ms(input integer n);begin repeat(n*2) @(negedge clk);end endtask
 task press(input integer key,input integer duration);begin
  case(key) 2:k2=0;3:k3=0;default:k4=0; endcase
  wait_ms(duration);k2=1;k3=1;k4=1;wait_ms(35);
 end endtask
 initial begin
  wait_ms(3);rst=0;wait_ms(35);
  if(b!=2||c!=2||v!=2||osd!=1||!debug||menu||!auto_en) $fatal(1,"defaults");
  // Menu closed
  press(2,35);if(nexts!=1||menu)$fatal(1,"K2 short = next image");
  press(2,100);if(mode!=1||nexts!=1)$fatal(1,"K2 long = next mode, no short leak");
  press(2,100);if(mode!=0)$fatal(1,"K2 long: notice -> normal (emergency only from SW1)");
  // SW1 alarm switch: up = emergency regardless of the key mode, debounced
  sw=1;wait_ms(5);sw=0;wait_ms(5);sw=1;wait_ms(5);if(mode!=0)$fatal(1,"switch bounce must not trigger");
  wait_ms(30);if(mode!=2)$fatal(1,"SW1 up = emergency");
  press(2,100);if(mode!=2)$fatal(1,"K2 long cannot leave the emergency while SW1 is up");
  sw=0;wait_ms(30);if(mode!=1)$fatal(1,"SW1 down returns to the key mode (notice) %0d",mode);
  press(2,100);if(mode!=0)$fatal(1,"back to normal");
  press(3,35);if(debug!=0||menu)$fatal(1,"K3 (menu closed) = debug toggle");
  press(3,100);if(debug!=1)$fatal(1,"K3 long also toggles debug when closed");
  // Menu open/close with K4, any press length
  press(4,35);if(!menu||sel!=0)$fatal(1,"K4 opens menu at brightness");
  press(4,100);if(menu)$fatal(1,"K4 (long) closes menu");
  press(4,35);
  press(2,35);if(b!=3||nexts!=1)$fatal(1,"K2 in menu = next value, no image change");
  press(2,35);press(2,35);if(b!=0)$fatal(1,"brightness wraps 4 -> 0");
  press(2,100);if(b!=1||mode!=0||!menu)$fatal(1,"K2 long in menu = next value too, no mode change");
  press(3,35);if(sel!=1||debug!=1)$fatal(1,"K3 in menu = next item, debug untouched");
  press(3,35);press(2,35);if(v!=3)$fatal(1,"volume +1");
  press(3,35);press(2,35);press(2,35);press(2,35);if(fx!=3)$fatal(1,"fourth transition (cross-fade)");
  press(2,35);if(fx!=0)$fatal(1,"transition wraps");
  press(3,35);press(2,35);if(osd!=2)$fatal(1,"OSD transparency +1");
  press(2,35);if(osd!=0)$fatal(1,"OSD transparency wraps");
  press(3,35);press(2,35);if(auto_en)$fatal(1,"autoplay toggle");
  press(3,35);press(2,35);if(!eco)$fatal(1,"eco toggle");
  press(3,35);press(2,35);if(debug)$fatal(1,"debug item toggle");
  press(3,35);if(sel!=0)$fatal(1,"item wraps 7 -> 0");
  press(4,35);if(menu||debug)$fatal(1,"K4 closes menu, debug kept");
  press(4,35);wait_ms(320);if(menu)$fatal(1,"idle timeout closes menu");
  k2=0;k4=0;wait_ms(130);k2=1;k4=1;wait_ms(40);
  if(mode!=0||b!=2||c!=2||v!=2||fx!=0||osd!=1||!auto_en||eco||!debug||menu||nexts!=1)$fatal(1,"chord restores defaults without side effects (menu %0d)",menu);
  // flash restore: valid fields applied, out-of-range fields fall back to defaults
  @(negedge clk);cfg_value=16'h1d23;cfg_load=1;@(negedge clk);cfg_load=0;@(negedge clk);
  if(b!=3||c!=4||v!=4||fx!=2||osd!=0||!auto_en||!eco||debug) $fatal(1,"cfg_load apply");
  @(negedge clk);cfg_value=16'hc1ff;cfg_load=1;@(negedge clk);cfg_load=0;@(negedge clk);
  if(b!=2||c!=2||v!=2||fx!=0||osd!=1) $fatal(1,"cfg_load range fallback b%0d c%0d v%0d fx%0d",b,c,v,fx);
  $display("PASS tb_controls: K4 menu open/close, K3 item / debug, K2 value / image / normal-notice, SW1 emergency with debounce, wraps, idle close, chord defaults, flash restore with range check");$finish;
 end
endmodule
