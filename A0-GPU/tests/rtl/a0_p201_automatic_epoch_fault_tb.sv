`timescale 1ns/1ps
// P201 negative protocol coverage with an intentionally tiny fake producer.
// Real P175 and P196 integration is verified separately, not substituted here.
module a0_p201_automatic_epoch_fault_tb;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0,capture_request=0,exporter_busy=0,exporter_done=0;
  logic exporter_fault=0;
  logic [31:0] exporter_queued_pixels=0,committed_words=0,published_epochs=0;
  logic [1:0] fifo_queued_words=0;
  logic stage_active=0,seal_pending=0,active_valid=0;
  logic epoch_fault=0,router_fault=0;
  wire stage_begin,export_start,stage_seal,busy,complete_pulse,fault;
  wire [31:0] completed_epochs;
  a0_p201_automatic_frame_epoch_sequencer #(.FRAME_WORDS(2)) dut(
    .clk(clk),.rst_n(rst_n),.capture_request(capture_request),
    .exporter_busy(exporter_busy),.exporter_done(exporter_done),
    .exporter_fault(exporter_fault),
    .exporter_queued_pixels(exporter_queued_pixels),
    .fifo_queued_words(fifo_queued_words),
    .stage_active(stage_active),.seal_pending(seal_pending),
    .active_valid(active_valid),.epoch_fault(epoch_fault),
    .router_fault(router_fault),.committed_words(committed_words),
    .published_epochs(published_epochs),
    .stage_begin(stage_begin),.export_start(export_start),
    .stage_seal(stage_seal),.busy(busy),
    .complete_pulse(complete_pulse),.fault(fault),
    .completed_epochs(completed_epochs)
  );
  task automatic reset_all;
    begin
      @(negedge clk);rst_n=0;capture_request=0;
      exporter_busy=0;exporter_done=0;exporter_fault=0;
      exporter_queued_pixels=0;fifo_queued_words=0;
      stage_active=0;seal_pending=0;active_valid=0;
      epoch_fault=0;router_fault=0;committed_words=0;published_epochs=0;
      repeat(3)@(negedge clk);
      rst_n=1;
      @(negedge clk);
      if(fault || busy || completed_epochs)
        $fatal(1,"P201 fake probe reset failed");
    end
  endtask
  task automatic launch_and_observe_busy;
    begin
      @(negedge clk);capture_request=1;
      @(negedge clk);capture_request=0;stage_active=1;
      wait(export_start);
      @(negedge clk);exporter_busy=1;
      @(negedge clk);exporter_busy=0;
    end
  endtask
  initial begin
    reset_all();
    launch_and_observe_busy();
    @(negedge clk);exporter_done=1;
    exporter_queued_pixels=1;committed_words=1;
    repeat(3)@(negedge clk);
    if(!fault || stage_seal || completed_epochs!=0)
      $fatal(1,"P201 early complete did not fail closed");
    exporter_queued_pixels=2;committed_words=2;
    repeat(3)@(negedge clk);
    if(!fault || stage_seal || complete_pulse)
      $fatal(1,"P201 early complete fault was not sticky");

    reset_all();
    @(negedge clk);capture_request=1;
    @(negedge clk);capture_request=0;stage_active=1;
    @(negedge clk);capture_request=1;
    @(negedge clk);capture_request=0;
    repeat(3)@(negedge clk);
    if(!fault || stage_seal || completed_epochs!=0)
      $fatal(1,"P201 overlapping capture request was accepted");

    reset_all();
    launch_and_observe_busy();
    @(negedge clk);exporter_done=1;exporter_queued_pixels=2;
    committed_words=1;fifo_queued_words=1;
    repeat(4)@(negedge clk);
    if(stage_seal || complete_pulse || fault)
      $fatal(1,"P201 sealed before the physical port drained");
    @(negedge clk);committed_words=2;fifo_queued_words=0;
    wait(stage_seal);
    @(negedge clk);seal_pending=1;
    repeat(3)@(negedge clk);
    if(fault || complete_pulse)
      $fatal(1,"P201 completed before atomic publication");
    @(negedge clk);seal_pending=0;stage_active=0;
    active_valid=1;published_epochs=1;
    wait(complete_pulse);
    @(negedge clk);
    if(fault || busy || completed_epochs!=1)
      $fatal(1,"P201 legal publication lost");
    $display("P201_COORDINATOR_FAULT_GUARDS_PASS early_done_fault=1 duplicate_request_fault=1 sticky_fault=1 drain_guard=1 legal_publish=1");
    $finish;
  end
  initial begin #150000; $fatal(1,"P201 negative probe timeout");end
endmodule
