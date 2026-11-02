`timescale 1ns/1ps
module tb_sd_delay;
 reg clk=0;always #20 clk=~clk;   // product loading clock 25 MHz
 reg rst_n=0,start=0;wire sclk;
 sd_spi_init #(.SPI_CLK_DIV(2),.STARTUP_DELAY_CYCLES(2500000)) dut(
 .clk(clk),.rst_n(rst_n),.init_start(start),.init_busy(),.init_done(),.init_ready(),.error_code(),
 .card_high_capacity(),.ocr(),.last_cmd(),.last_r1(),.acmd41_attempts(),.sd_cs_n(),.sd_sclk(sclk),.sd_mosi(),.sd_miso(1'b1));
 initial begin
  repeat(3)@(negedge clk);rst_n=1;start=1;@(negedge clk);start=0;
  if($bits(dut.startup_delay_cnt)<22)$fatal(1,"100ms/25MHz counter cannot reach threshold");
  wait(dut.state==15);@(negedge clk);
  dut.startup_delay_cnt=2499998;
  repeat(8)@(negedge clk);
  if(dut.state==15)$fatal(1,"startup delay never completes");
  wait(sclk);$display("PASS tb_sd_delay: 25MHz 100ms threshold is reachable, initialization proceeds");$finish;
 end
 initial begin #50000;$fatal(1,"timeout");end
endmodule
