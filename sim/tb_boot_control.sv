`timescale 1ns/1ps
// ed_boot_control: success, retry after transient errors, fault after all retries,
// watchdog timeout without retry.
module tb_boot_control;
 reg clk=0;always #4 clk=~clk;
 reg rst=1,ready=0,done=0,ok=0;wire start,bdone,bfault,btimeout;wire [1:0] retries;
 ed_boot_control #(.TIMEOUT_CYCLES(34'd5000),.RETRIES(3),.RETRY_WAIT(27'd50)) dut(.clk(clk),.rst(rst),.mem_ready(ready),
  .ingest_done(done),.ingest_ok(ok),.start(start),.boot_done(bdone),.boot_fault(bfault),.boot_timeout(btimeout),.retries(retries));
 integer starts=0;always @(posedge clk) if(start) starts=starts+1;
 task finish_load(input good);begin wait(start);repeat(20)@(negedge clk);ok=good;done=1;@(negedge clk);done=0;end endtask
 task reboot;begin rst=1;starts=0;repeat(3)@(negedge clk);rst=0;ready=1;end endtask
 initial begin
  // 1 first load succeeds
  reboot;finish_load(1);repeat(5)@(negedge clk);
  if(!bdone||bfault||starts!=1||retries!=0) $fatal(1,"success path");
  // 2 two transient failures, then success: three starts, done
  reboot;finish_load(0);finish_load(0);finish_load(1);repeat(5)@(negedge clk);
  if(!bdone||bfault||starts!=3||retries!=2) $fatal(1,"retry path starts%0d",starts);
  // 3 every attempt fails: 1 + 3 retries, then fault
  reboot;finish_load(0);finish_load(0);finish_load(0);finish_load(0);repeat(80)@(negedge clk);
  if(bdone||!bfault||btimeout||starts!=4||retries!=3) $fatal(1,"fault path starts%0d",starts);
  // 4 loader hangs: watchdog fault, no further start
  reboot;wait(start);repeat(6000)@(negedge clk);
  if(!bfault||!btimeout||starts!=1) $fatal(1,"watchdog path");
  $display("PASS tb_boot_control: first-try boot, retries after transient errors, fault after 3 retries, watchdog without retry");$finish;
 end
endmodule