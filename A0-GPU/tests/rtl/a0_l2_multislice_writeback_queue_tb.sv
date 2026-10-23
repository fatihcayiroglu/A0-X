`timescale 1ns/1ps
module a0_l2_multislice_writeback_queue_tb;
 localparam integer SOURCE_COUNT=3,LINE_WORDS=2,LINE_ADDR_W=12,LOCAL_ATTEMPT_ID_W=3,SOURCE_ID_W=2,BACKEND_ATTEMPT_ID_W=5,COUNT_W=2;
 logic clk,rst_n;
 logic[SOURCE_COUNT-1:0] src_valid_i,src_ready_o;
 logic[LOCAL_ATTEMPT_ID_W-1:0] src_attempt_id_i[0:SOURCE_COUNT-1];
 logic[LINE_ADDR_W-1:0] src_line_addr_i[0:SOURCE_COUNT-1];
 logic[31:0] src_data_i[0:SOURCE_COUNT-1][0:LINE_WORDS-1];
 logic[SOURCE_COUNT-1:0] src_status_valid_o;
 logic[LOCAL_ATTEMPT_ID_W-1:0] src_status_attempt_id_o[0:SOURCE_COUNT-1];
 logic src_status_success_o[0:SOURCE_COUNT-1],src_status_retryable_o[0:SOURCE_COUNT-1];
 logic backend_valid_o,backend_ready_i;logic[BACKEND_ATTEMPT_ID_W-1:0]backend_attempt_id_o;logic[LINE_ADDR_W-1:0]backend_line_addr_o;logic[31:0]backend_data_o[0:LINE_WORDS-1];
 logic backend_status_valid_i;logic[BACKEND_ATTEMPT_ID_W-1:0]backend_status_attempt_id_i;logic backend_status_success_i,backend_status_retryable_i;
 logic[COUNT_W-1:0]pending_count_o,active_count_o;logic protocol_error_o;
 integer s,w,backend_fire_count;
 a0_l2_multislice_writeback_queue #(.SOURCE_COUNT(SOURCE_COUNT),.LINE_WORDS(LINE_WORDS),.LINE_ADDR_W(LINE_ADDR_W),.LOCAL_ATTEMPT_ID_W(LOCAL_ATTEMPT_ID_W)) dut(.*);
 initial clk=0;always #5 clk=~clk;
 always_ff @(posedge clk)begin if(!rst_n)backend_fire_count<=0;else if(backend_valid_o&&backend_ready_i)backend_fire_count<=backend_fire_count+1;end
 function automatic logic[BACKEND_ATTEMPT_ID_W-1:0] bid(input integer source,input logic[LOCAL_ATTEMPT_ID_W-1:0] local_attempt);bid={SOURCE_ID_W'(source % SOURCE_COUNT),local_attempt};endfunction
 task automatic clear;begin
  src_valid_i='0;backend_ready_i=0;backend_status_valid_i=0;backend_status_attempt_id_i='0;backend_status_success_i=0;backend_status_retryable_i=0;
  for(s=0;s<SOURCE_COUNT;s=s+1)begin src_attempt_id_i[s]='0;src_line_addr_i[s]='0;for(w=0;w<LINE_WORDS;w=w+1)src_data_i[s][w]='0;end
 end endtask
 task automatic reset;begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
 task automatic queue_source(input integer source,input logic[LOCAL_ATTEMPT_ID_W-1:0] attempt,input logic[LINE_ADDR_W-1:0] line,input logic[31:0] base);begin
  if(!src_ready_o[source])$fatal(1,"P20 source not ready %0d",source);src_valid_i[source]=1;src_attempt_id_i[source]=attempt;src_line_addr_i[source]=line;for(w=0;w<LINE_WORDS;w=w+1)src_data_i[source][w]=base+32'(w);
 end endtask
 task automatic send_status(input integer source,input logic[LOCAL_ATTEMPT_ID_W-1:0] attempt,input logic success,input logic retryable);begin
  @(negedge clk);backend_status_valid_i=1;backend_status_attempt_id_i=bid(source,attempt);backend_status_success_i=success;backend_status_retryable_i=retryable;#1;
  if(!src_status_valid_o[source]||src_status_attempt_id_o[source]!=attempt||src_status_success_o[source]!=success||src_status_retryable_o[source]!=retryable)$fatal(1,"P20 status route source %0d",source);
  @(posedge clk);@(negedge clk);backend_status_valid_i=0;backend_status_success_i=0;backend_status_retryable_i=0;#1;
 end endtask
 initial begin
  logic[BACKEND_ATTEMPT_ID_W-1:0] held_id;logic[LINE_ADDR_W-1:0]held_line;logic[31:0]held_data;
  reset();if(pending_count_o!=0||active_count_o!=0||protocol_error_o)$fatal(1,"P20 reset");$display("PROD_SEAM_P20_RESET_EMPTY=PASS");
  // Three slices enqueue simultaneously while backend is blocked.
  @(negedge clk);queue_source(0,3'd1,12'h101,32'hA000);queue_source(1,3'd2,12'h202,32'hB000);queue_source(2,3'd3,12'h303,32'hC000);#1;@(posedge clk);@(negedge clk);src_valid_i='0;#1;
  if(pending_count_o!=3||!backend_valid_o||backend_attempt_id_o!=bid(0,3'd1))$fatal(1,"P20 initial queue/arbitration");held_id=backend_attempt_id_o;held_line=backend_line_addr_o;held_data=backend_data_o[1];
  repeat(2)begin @(posedge clk);#1;if(backend_attempt_id_o!=held_id||backend_line_addr_o!=held_line||backend_data_o[1]!=held_data)$fatal(1,"P20 payload unstable");end
  $display("PROD_SEAM_P20_MULTI_SOURCE_CAPTURE=PASS");$display("PROD_SEAM_P20_BACKPRESSURE_PAYLOAD_STABLE=PASS");
  // Issue 0,1,2 in RR order without waiting for statuses.
  backend_ready_i=1;
  @(posedge clk);#1;if(backend_attempt_id_o!=bid(1,3'd2))$fatal(1,"P20 expected source1 second");
  @(posedge clk);#1;if(backend_attempt_id_o!=bid(2,3'd3))$fatal(1,"P20 expected source2 third");
  @(posedge clk);#1;if(backend_valid_o||pending_count_o!=0||active_count_o!=3||backend_fire_count!=3)$fatal(1,"P20 issue counts");
  $display("PROD_SEAM_P20_ROUND_ROBIN_FAIR_ISSUE=PASS");$display("PROD_SEAM_P20_MULTIPLE_LIVE_ATTEMPTS=PASS");
  if(src_ready_o[0]||src_ready_o[1]||src_ready_o[2])$fatal(1,"P20 active source accepted duplicate");$display("PROD_SEAM_P20_PER_SOURCE_LIVE_BACKPRESSURE=PASS");
  // OOO completions route exactly.
  send_status(2,3'd3,1,0);if(active_count_o!=2)$fatal(1,"P20 active after source2");
  send_status(0,3'd1,1,0);if(active_count_o!=1)$fatal(1,"P20 active after source0");
  send_status(1,3'd2,0,0);if(active_count_o!=0)$fatal(1,"P20 active after source1 fail");
  $display("PROD_SEAM_P20_OOO_STATUS_IDENTITY_RESTORE=PASS");$display("PROD_SEAM_P20_FAILURE_STATUS_ISOLATED=PASS");
  // RR pointer ended at 0 after source2, so source0 beats source2 when both queued.
  @(negedge clk);backend_ready_i=0;queue_source(0,3'd4,12'h111,32'hD000);queue_source(2,3'd5,12'h333,32'hE000);#1;@(posedge clk);@(negedge clk);src_valid_i='0;#1;if(backend_attempt_id_o!=bid(0,3'd4))$fatal(1,"P20 rr wrap source0");backend_ready_i=1;@(posedge clk);#1;if(backend_attempt_id_o!=bid(2,3'd5))$fatal(1,"P20 rr source2");$display("PROD_SEAM_P20_RR_WRAP_FAIRNESS=PASS");
  // Complete those two to free sources.
  @(posedge clk);#1;send_status(0,3'd4,1,0);send_status(2,3'd5,1,0);
  // Same-cycle backend issue + matching status is legal and leaves no active ghost.
  @(negedge clk);backend_ready_i=0;queue_source(1,3'd6,12'h222,32'hF000);#1;@(posedge clk);@(negedge clk);src_valid_i='0;backend_ready_i=1;backend_status_valid_i=1;backend_status_attempt_id_i=bid(1,3'd6);backend_status_success_i=1;backend_status_retryable_i=0;#1;
  if(!src_status_valid_o[1]||!src_status_success_o[1])$fatal(1,"P20 same cycle status route");@(posedge clk);#1;if(active_count_o!=0||pending_count_o!=0)$fatal(1,"P20 same cycle ghost");@(negedge clk);backend_status_valid_i=0;#1;$display("PROD_SEAM_P20_SAME_CYCLE_ISSUE_STATUS=PASS");
  // Attempt-id zero must remain active while status_valid is low.
  @(negedge clk);backend_ready_i=0;queue_source(0,3'd0,12'h444,32'hAB00);#1;@(posedge clk);@(negedge clk);src_valid_i='0;backend_ready_i=1;#1;@(posedge clk);#1;
  if(active_count_o!=1||src_ready_o[0])$fatal(1,"P20 zero-attempt active lost on issue");
  repeat(2)begin @(posedge clk);#1;if(active_count_o!=1||src_ready_o[0])$fatal(1,"P20 zero-attempt cleared without valid status");end
  send_status(0,3'd0,1,0);if(active_count_o!=0)$fatal(1,"P20 zero-attempt valid status did not clear");
  $display("PROD_SEAM_P20_ZERO_ATTEMPT_STATUS_VALID_GUARD=PASS");
  // Unknown/stale status cannot alias a source.
  backend_status_valid_i=1;backend_status_attempt_id_i=bid(0,3'd7);backend_status_success_i=1;#1;if(!protocol_error_o||(|src_status_valid_o))$fatal(1,"P20 stale status");backend_status_valid_i=0;#1;$display("PROD_SEAM_P20_STALE_STATUS_CONTAINED=PASS");
  $display("PROD_SEAM_P20_BEHAVIOR=PASS");$finish;
 end
endmodule
