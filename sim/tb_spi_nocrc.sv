`timescale 1ns/1ps
// Product configuration: CHECK_DATA_CRC=0 (bench defined in tb_spi.sv).
module tb_spi_nocrc;
 spi_card_bench #(.CHECK(0)) bench();
endmodule
