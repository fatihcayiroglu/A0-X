`timescale 1ns/1ps
// P202 fault-injection proof. The backend is an explicit stub: it stores
// nothing, so these tests prove the protocol guard, not real VRAM.
module a0_p202_bank_guard_fault_tb;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0,cmd_valid=0,cmd_write=0;
  logic [31:0] cmd_word_addr=32'h01000000;
  logic [47:0] cmd_pixel=48'h123456789abc;
  logic backend_cmd_ready=0,backend_rsp_valid=0,backend_rsp_error=0;
  logic [47:0] backend_rsp_pixel=0;
  wire cmd_ready,rsp_valid,rsp_error,fault,read_pending;
  wire [47:0] rsp_pixel,backend_cmd_pixel;
  wire backend_cmd_valid,backend_cmd_write;
  wire [31:0] backend_cmd_word_addr;
  integer error_pulses=0,valid_pulses=0;
  a0_p202_bounded_bank_port_guard #(
    .FRAME_WORDS(4),.BANK_INDEX(0),
    .CMD_STALL_LIMIT(5),.READ_TIMEOUT(6)
  ) dut(
    .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),
    .cmd_write(cmd_write),.cmd_word_addr(cmd_word_addr),
    .cmd_pixel(cmd_pixel),.cmd_ready(cmd_ready),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_pixel(rsp_pixel),
    .fault(fault),.read_pending(read_pending),
    .backend_cmd_valid(backend_cmd_valid),
    .backend_cmd_write(backend_cmd_write),
    .backend_cmd_word_addr(backend_cmd_word_addr),
    .backend_cmd_pixel(backend_cmd_pixel),
    .backend_cmd_ready(backend_cmd_ready),
    .backend_rsp_valid(backend_rsp_valid),
    .backend_rsp_error(backend_rsp_error),
    .backend_rsp_pixel(backend_rsp_pixel)
  );
  always @(posedge clk)if(rst_n && rsp_valid)begin
    valid_pulses=valid_pulses+1;
    if(rsp_error)error_pulses=error_pulses+1;
  end
  task automatic reset_all;
    begin
      @(negedge clk);rst_n=0;cmd_valid=0;cmd_write=0;
      cmd_word_addr=32'h01000000;cmd_pixel=48'h123456789abc;
      backend_cmd_ready=0;backend_rsp_valid=0;
      backend_rsp_error=0;backend_rsp_pixel=0;
      repeat(3)@(negedge clk);
      rst_n=1;
      @(negedge clk);
      if(fault || read_pending || rsp_valid)
        $fatal(1,"P202 reset failed");
    end
  endtask
  task automatic accept_read;
    begin
      @(negedge clk);cmd_valid=1;cmd_write=0;
      cmd_word_addr=32'h01000002;backend_cmd_ready=1;
      @(posedge clk);
      if(!cmd_ready || !backend_cmd_valid || backend_cmd_write)
        $fatal(1,"P202 legal read not accepted");
      @(negedge clk);cmd_valid=0;
      if(!read_pending)$fatal(1,"P202 read lease missing");
    end
  endtask
  initial begin
    reset_all();
    // Bounded legal write stall; still no phantom acceptance.
    @(negedge clk);cmd_valid=1;cmd_write=1;
    cmd_word_addr=32'h01000003;backend_cmd_ready=0;
    repeat(2)@(negedge clk);
    if(cmd_ready || !backend_cmd_valid || fault)
      $fatal(1,"P202 valid bounded backpressure rejected");
    backend_cmd_ready=1;
    @(posedge clk);
    if(!cmd_ready || !backend_cmd_valid ||
       !backend_cmd_write || backend_cmd_word_addr!=32'h01000003 ||
       backend_cmd_pixel!=48'h123456789abc)
      $fatal(1,"P202 write command corrupted");
    @(negedge clk);cmd_valid=0;
    repeat(2)@(negedge clk);
    if(fault || read_pending)$fatal(1,"P202 legal write caused fault");
    accept_read();
    repeat(2)@(negedge clk);
    backend_rsp_valid=1;backend_rsp_pixel=48'h112233445566;
    if(!rsp_valid || rsp_error || rsp_pixel!=48'h112233445566)
      $fatal(1,"P202 delayed legal response lost");
    @(posedge clk);
    @(negedge clk);backend_rsp_valid=0;
    if(fault || read_pending)$fatal(1,"P202 legal read caused fault");

    // A stalled read must fault and synthesize exactly ONE error reply.
    reset_all();
    accept_read();
    repeat(9)@(negedge clk);
    if(!fault || read_pending || error_pulses!=1)
      $fatal(1,"P202 missing/duplicate read timeout reply count=%0d",error_pulses);
    backend_rsp_valid=1;backend_rsp_pixel=48'hbad00bad0000;
    if(rsp_valid || rsp_pixel!=0 || backend_cmd_valid)
      $fatal(1,"P202 late response escaped quarantine");
    @(negedge clk);backend_rsp_valid=0;
    if(!fault)$fatal(1,"P202 read timeout fault not sticky");

    // A reply with no accepted read is never forwarded.
    reset_all();
    @(negedge clk);backend_rsp_valid=1;
    if(rsp_valid)$fatal(1,"P202 unsolicited response forwarded");
    @(negedge clk);
    if(!fault)$fatal(1,"P202 unsolicited response not latched");

    // Address from physical bank 1 must not reach bank 0.
    reset_all();
    @(negedge clk);cmd_valid=1;cmd_write=1;
    cmd_word_addr=32'h01000004;backend_cmd_ready=1;
    if(backend_cmd_valid || cmd_ready)
      $fatal(1,"P202 wrong-bank address accepted");
    @(negedge clk);
    if(!fault)$fatal(1,"P202 wrong-bank address did not fault");

    // An indefinitely blocked WRITE command must fault (no fake commit).
    reset_all();
    @(negedge clk);cmd_valid=1;cmd_write=1;
    backend_cmd_ready=0;
    repeat(8)@(negedge clk);
    if(!fault || cmd_ready || read_pending || backend_cmd_valid)
      $fatal(1,"P202 missing write-backpressure timeout");

    // A backend read error is propagated and quarantines the bank.
    reset_all();
    accept_read();
    @(negedge clk);backend_rsp_valid=1;backend_rsp_error=1;
    if(!rsp_valid || !rsp_error)
      $fatal(1,"P202 backend error not surfaced");
    @(negedge clk);backend_rsp_valid=0;backend_rsp_error=0;
    if(!fault || read_pending)
      $fatal(1,"P202 backend error not latched");

    // No second command while a read is outstanding.
    reset_all();
    accept_read();
    @(negedge clk);cmd_valid=1;cmd_write=1;
    if(backend_cmd_valid || cmd_ready)
      $fatal(1,"P202 overlapping command escaped");
    @(negedge clk);cmd_valid=0;
    if(!fault)$fatal(1,"P202 overlapping command did not fault");
    $display("P202_BANK_GUARD_FAULT_PASS delayed_read=1 bounded_write_stall=1 read_timeout=1 single_error_reply=1 late_quarantine=1 unsolicited=1 wrong_bank=1 stalled_write=1 backend_error=1 overlap=1");
    $finish;
  end
  initial begin #100000; $fatal(1,"P202 fault-test global timeout"); end
endmodule
