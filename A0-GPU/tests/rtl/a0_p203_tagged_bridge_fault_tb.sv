`timescale 1ns/1ps
// P203 standalone protocol fault injection; controller is explicitly a
// synthetic actor. Actual P175 integration uses P196 simulated RAM separately.
module a0_p203_tagged_bridge_fault_tb;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,bank_cmd_valid=0,bank_cmd_write=0;
  logic [31:0] bank_cmd_word_addr=32'h01000001;
  logic [47:0] bank_cmd_pixel=48'h112233445566;
  logic ctrl_flush_ack=0,ctrl_req_ready=1;
  logic ctrl_rsp_valid=0,ctrl_rsp_error=0;
  logic [47:0] ctrl_rsp_pixel=0;
  logic [3:0] ctrl_rsp_id=0;
  wire bank_cmd_ready,bank_rsp_valid,bank_rsp_error;
  wire [47:0] bank_rsp_pixel;
  wire fault,busy,ctrl_flush_req,ctrl_req_valid,ctrl_req_write;
  wire ctrl_rsp_ready;
  wire [31:0] ctrl_req_word_addr;
  wire [47:0] ctrl_req_pixel;
  wire [3:0] ctrl_req_id;
  integer timeout_error_pulses=0;
  a0_p203_tagged_controller_bridge #(
    .FRAME_WORDS(4),.BANK_INDEX(0),
    .TAG_BITS(4),.RESPONSE_TIMEOUT(8)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .bank_cmd_valid(bank_cmd_valid),.bank_cmd_write(bank_cmd_write),
    .bank_cmd_word_addr(bank_cmd_word_addr),
    .bank_cmd_pixel(bank_cmd_pixel),
    .bank_cmd_ready(bank_cmd_ready),
    .bank_rsp_valid(bank_rsp_valid),.bank_rsp_error(bank_rsp_error),
    .bank_rsp_pixel(bank_rsp_pixel),.fault(fault),.busy(busy),
    .ctrl_flush_req(ctrl_flush_req),.ctrl_flush_ack(ctrl_flush_ack),
    .ctrl_req_valid(ctrl_req_valid),.ctrl_req_write(ctrl_req_write),
    .ctrl_req_word_addr(ctrl_req_word_addr),
    .ctrl_req_pixel(ctrl_req_pixel),.ctrl_req_id(ctrl_req_id),
    .ctrl_req_ready(ctrl_req_ready),
    .ctrl_rsp_valid(ctrl_rsp_valid),.ctrl_rsp_error(ctrl_rsp_error),
    .ctrl_rsp_pixel(ctrl_rsp_pixel),.ctrl_rsp_id(ctrl_rsp_id),
    .ctrl_rsp_ready(ctrl_rsp_ready)
  );
  always @(posedge clk)if(rst_n && bank_rsp_valid && bank_rsp_error)
    timeout_error_pulses=timeout_error_pulses+1;

  task automatic reset_all;
    begin
      @(negedge clk);rst_n=0;bank_cmd_valid=0;
      bank_cmd_write=0;bank_cmd_word_addr=32'h01000001;
      bank_cmd_pixel=48'h112233445566;
      ctrl_flush_ack=0;ctrl_req_ready=1;
      ctrl_rsp_valid=0;ctrl_rsp_error=0;ctrl_rsp_pixel=0;
      ctrl_rsp_id=0;
      repeat(3)@(negedge clk);
      rst_n=1;#1;
      if(!ctrl_flush_req || ctrl_req_valid || bank_cmd_ready)
        $fatal(1,"P203 missing reset/flush barrier");
      @(negedge clk);ctrl_flush_ack=1;
      @(posedge clk);
      @(negedge clk);ctrl_flush_ack=0;
      #1;
      if(ctrl_flush_req || fault || busy)
        $fatal(1,"P203 flush acknowledgement not accepted");
    end
  endtask
  task automatic accept_read(output logic [3:0] tag);
    begin
      @(negedge clk);bank_cmd_valid=1;bank_cmd_write=0;
      bank_cmd_word_addr=32'h01000002;
      #1;
      if(!ctrl_req_valid || !bank_cmd_ready || ctrl_req_write)
        $fatal(1,"P203 read request acceptance incorrect");
      tag=ctrl_req_id;
      @(posedge clk);
      @(negedge clk);bank_cmd_valid=0;
      #1;
      if(!busy)$fatal(1,"P203 read not pending");
    end
  endtask
  task automatic accept_write(output logic [3:0] tag);
    begin
      @(negedge clk);bank_cmd_valid=1;bank_cmd_write=1;
      bank_cmd_word_addr=32'h01000003;
      bank_cmd_pixel=48'h112233445566;
      #1;
      if(!ctrl_req_valid || bank_cmd_ready || !ctrl_req_write ||
         ctrl_req_pixel!=48'h112233445566)
        $fatal(1,"P203 premature write acknowledgement");
      tag=ctrl_req_id;
      @(posedge clk);
      @(negedge clk);
      #1;
      if(bank_cmd_ready || !busy)
        $fatal(1,"P203 write acknowledged at controller request, not commit");
    end
  endtask
  logic [3:0] tag;
  initial begin
    reset_all();
    // Read is acknowledged on request acceptance; data arrives later.
    accept_read(tag);
    repeat(3)@(negedge clk);
    ctrl_rsp_valid=1;ctrl_rsp_id=tag;
    ctrl_rsp_pixel=48'habcdef012345;
    #1;
    if(!bank_rsp_valid || bank_rsp_error ||
       bank_rsp_pixel!==48'habcdef012345 || !ctrl_rsp_ready)
      $fatal(1,"P203 delayed tagged read mismatched");
    @(posedge clk);
    @(negedge clk);ctrl_rsp_valid=0;#1;
    if(fault || busy)$fatal(1,"P203 legal read did not retire");

    // Write MUST wait for matching COMMIT; request accepted is not enough.
    accept_write(tag);
    repeat(2)@(negedge clk);
    if(bank_cmd_ready || fault)
      $fatal(1,"P203 early write commit");
    ctrl_rsp_valid=1;ctrl_rsp_id=tag;
    #1;
    if(!bank_cmd_ready || bank_rsp_valid)
      $fatal(1,"P203 matching write commit not acknowledged");
    @(posedge clk);
    @(negedge clk);ctrl_rsp_valid=0;bank_cmd_valid=0;
    #1;
    if(fault || busy)$fatal(1,"P203 legal write did not retire");

    reset_all();
    accept_read(tag);
    @(negedge clk);ctrl_rsp_valid=1;ctrl_rsp_id=tag+4'd1;
    #1;
    if(bank_rsp_valid)$fatal(1,"P203 mismatched tag delivered data");
    @(negedge clk);ctrl_rsp_valid=0;
    if(!fault || ctrl_req_valid)
      $fatal(1,"P203 mismatched tag did not fail closed");

    reset_all();
    accept_read(tag);
    repeat(11)@(negedge clk);
    if(!fault || timeout_error_pulses!=1 || bank_rsp_valid)
      $fatal(1,"P203 missing/duplicate read-timeout error count=%0d",timeout_error_pulses);
    ctrl_rsp_valid=1;ctrl_rsp_id=tag;
    #1;
    if(bank_rsp_valid || bank_cmd_ready)
      $fatal(1,"P203 stale timeout response escaped quarantine");

    reset_all();
    accept_write(tag);
    repeat(11)@(negedge clk);
    if(!fault || bank_cmd_ready)
      $fatal(1,"P203 write with no commit ack did not fail closed");

    reset_all();
    accept_write(tag);
    @(negedge clk);bank_cmd_pixel=48'h000000000001;
    @(negedge clk);
    if(!fault || bank_cmd_ready)
      $fatal(1,"P203 mutated held write escaped");

    reset_all();
    @(negedge clk);ctrl_rsp_valid=1;ctrl_rsp_id=4'hf;
    #1;
    if(bank_rsp_valid || bank_cmd_ready)
      $fatal(1,"P203 unsolicited controller reply forwarded");
    @(negedge clk);
    if(!fault)$fatal(1,"P203 unsolicited controller reply not faulted");

    reset_all();
    @(negedge clk);bank_cmd_valid=1;bank_cmd_write=1;
    bank_cmd_word_addr=32'h01000004;
    #1;
    if(ctrl_req_valid || bank_cmd_ready)
      $fatal(1,"P203 wrong physical bank issued");
    @(negedge clk);
    if(!fault)$fatal(1,"P203 wrong bank did not fail closed");

    reset_all();
    accept_write(tag);
    @(negedge clk);ctrl_rsp_valid=1;ctrl_rsp_error=1;ctrl_rsp_id=tag;
    #1;
    if(bank_cmd_ready)$fatal(1,"P203 failed write published as commit");
    @(negedge clk);
    if(!fault)$fatal(1,"P203 controller write error not sticky");

    $display("P203_TAGGED_BRIDGE_FAULT_PASS flush_barrier=1 read_tag=1 write_commit_only=1 wrong_tag=1 read_timeout=1 one_error=1 late_quarantine=1 write_timeout=1 mutated_write=1 unsolicited=1 wrong_bank=1 failed_write=1");
    $finish;
  end
  initial begin #200000; $fatal(1,"P203 standalone probe global timeout"); end
endmodule
