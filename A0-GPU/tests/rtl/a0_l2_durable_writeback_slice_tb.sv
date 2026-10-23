`timescale 1ns/1ps
module a0_l2_durable_writeback_slice_tb;
 localparam integer STORE_LANES=1, LINE_WORDS=4, SET_COUNT=4, GLOBAL_TAG_W=4, WRITE_ID_W=3, MAX_WB_RETRIES=1;
 localparam integer WORD_SELECT_W=$clog2(LINE_WORDS), LINE_ADDR_W=32-WORD_SELECT_W, RETRY_W=1, ATTEMPT_ID_W=WRITE_ID_W+RETRY_W;
 logic clk,rst_n;
 logic line_req_valid_i,line_req_ready_o; logic [GLOBAL_TAG_W-1:0] line_req_global_tag_i; logic [LINE_ADDR_W-1:0] line_req_line_addr_i;
 logic line_mem_req_valid_o,line_mem_req_ready_i; logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o; logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o;
 logic line_mem_resp_valid_i; logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i; logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i; logic line_mem_resp_fault_i; logic [31:0] line_mem_resp_data_i[0:LINE_WORDS-1];
 logic line_resp_valid_o; logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_o; logic [LINE_ADDR_W-1:0] line_resp_line_addr_o; logic line_resp_fault_o; logic [31:0] line_resp_data_o[0:LINE_WORDS-1];
 logic store_valid_i,store_ready_o; logic [STORE_LANES-1:0] store_lane_mask_i; logic [31:0] store_word_addr_i[0:STORE_LANES-1],store_wdata_i[0:STORE_LANES-1]; logic [STORE_LANES-1:0] store_hit_mask_o,store_miss_mask_o;
 logic backend_wb_valid_o,backend_wb_ready_i; logic [ATTEMPT_ID_W-1:0] backend_wb_attempt_id_o; logic [LINE_ADDR_W-1:0] backend_wb_line_addr_o; logic [31:0] backend_wb_data_o[0:LINE_WORDS-1];
 logic backend_wb_status_valid_i; logic [ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i; logic backend_wb_status_success_i,backend_wb_status_retryable_i;
 logic dirty_present_o,wb_busy_o; logic [RETRY_W-1:0] wb_retry_count_o; logic wb_terminal_failure_o,protocol_error_o;
 integer i,read_fire_count,wb_fire_count;
 localparam logic [LINE_ADDR_W-1:0] A=LINE_ADDR_W'(1), B=LINE_ADDR_W'(5), C=LINE_ADDR_W'(9);

 a0_l2_durable_writeback_slice #(.STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),.SET_COUNT(SET_COUNT),.GLOBAL_TAG_W(GLOBAL_TAG_W),.WRITE_ID_W(WRITE_ID_W),.MAX_WB_RETRIES(MAX_WB_RETRIES)) dut(.*);
 initial clk=0; always #5 clk=~clk;
 always_ff @(posedge clk) begin
  if(!rst_n) begin read_fire_count<=0; wb_fire_count<=0; end
  else begin if(line_mem_req_valid_o&&line_mem_req_ready_i) read_fire_count<=read_fire_count+1; if(backend_wb_valid_o&&backend_wb_ready_i) wb_fire_count<=wb_fire_count+1; end
 end
 function automatic logic [31:0] waddr(input logic[LINE_ADDR_W-1:0] line,input integer off); waddr=(32'(line)<<WORD_SELECT_W)+32'(off); endfunction
 task automatic clear; begin
  line_req_valid_i=0;line_req_global_tag_i='0;line_req_line_addr_i='0;line_mem_req_ready_i=1;line_mem_resp_valid_i=0;line_mem_resp_global_tag_i='0;line_mem_resp_line_addr_i='0;line_mem_resp_fault_i=0;
  store_valid_i=0;store_lane_mask_i='0;store_word_addr_i[0]='0;store_wdata_i[0]='0; backend_wb_ready_i=1;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;
  for(i=0;i<LINE_WORDS;i=i+1) line_mem_resp_data_i[i]='0;
 end endtask
 task automatic reset; begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1; end endtask
 task automatic miss(input logic[GLOBAL_TAG_W-1:0] tag,input logic[LINE_ADDR_W-1:0] line); begin
  @(negedge clk);line_req_valid_i=1;line_req_global_tag_i=tag;line_req_line_addr_i=line;#1;if(!line_req_ready_o||!line_mem_req_valid_o)$fatal(1,"P18 miss not accepted");@(posedge clk);@(negedge clk);line_req_valid_i=0;#1;
 end endtask
 task automatic refill(input logic[GLOBAL_TAG_W-1:0] tag,input logic[LINE_ADDR_W-1:0] line,input logic[31:0] base); begin
  @(negedge clk);line_mem_resp_valid_i=1;line_mem_resp_global_tag_i=tag;line_mem_resp_line_addr_i=line;line_mem_resp_fault_i=0;for(i=0;i<LINE_WORDS;i=i+1)line_mem_resp_data_i[i]=base+32'(i);#1;if(!line_resp_valid_o||line_resp_global_tag_o!=tag||line_resp_line_addr_o!=line||line_resp_fault_o||line_resp_data_o[0]!=base)$fatal(1,"P18 refill not forwarded");@(posedge clk);@(negedge clk);line_mem_resp_valid_i=0;#1;
 end endtask
 task automatic dirty_word(input logic[LINE_ADDR_W-1:0] line,input integer off,input logic[31:0] data); begin
  @(negedge clk);store_valid_i=1;store_lane_mask_i=1;store_word_addr_i[0]=waddr(line,off);store_wdata_i[0]=data;#1;if(!store_ready_o||!store_hit_mask_o[0]||store_miss_mask_o[0])$fatal(1,"P18 dirty store miss");@(posedge clk);@(negedge clk);store_valid_i=0;store_lane_mask_i=0;#1;if(!dirty_present_o)$fatal(1,"P18 dirty absent");
 end endtask
 task automatic begin_dirty_evict(input logic[GLOBAL_TAG_W-1:0] tag,input logic[LINE_ADDR_W-1:0] line); begin
  @(negedge clk);line_req_valid_i=1;line_req_global_tag_i=tag;line_req_line_addr_i=line;#1;if(!line_req_ready_o||line_mem_req_valid_o)$fatal(1,"P18 dirty eviction acceptance");@(posedge clk);@(negedge clk);line_req_valid_i=0;#1;
  // P17 presents victim; guard captures it on next edge.
  @(posedge clk);#1;if(!wb_busy_o)$fatal(1,"P18 guard did not capture victim");
 end endtask
 task automatic wait_issue(output logic[ATTEMPT_ID_W-1:0] id); begin
  while(!backend_wb_valid_o) @(posedge clk); #1; id=backend_wb_attempt_id_o;
 end endtask
 task automatic status(input logic[ATTEMPT_ID_W-1:0] id,input logic success,input logic retryable); begin
  @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=id;backend_wb_status_success_i=success;backend_wb_status_retryable_i=retryable;#1;@(posedge clk);@(negedge clk);backend_wb_status_valid_i=0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;#1;
 end endtask
 initial begin
  logic[ATTEMPT_ID_W-1:0] id0,id1,id2; integer before_reads;
  reset(); miss(4'h1,A); refill(4'h1,A,32'h1000); dirty_word(A,2,32'hDEAD_BEEF);
  $display("PROD_SEAM_P18_DIRTY_SOURCE_READY=PASS");
  before_reads=read_fire_count; begin_dirty_evict(4'h2,B); wait_issue(id0);
  if(backend_wb_line_addr_o!=A||backend_wb_data_o[2]!=32'hDEAD_BEEF)$fatal(1,"P18 wb payload");
  @(posedge clk);#1; // command accepted, now waiting for status
  if(!dirty_present_o||read_fire_count!=before_reads||wb_terminal_failure_o)$fatal(1,"P18 command acceptance released dirty victim");
  $display("PROD_SEAM_P18_COMMAND_ACCEPTANCE_NOT_CLEAN=PASS");
  $display("PROD_SEAM_P18_RETAINED_REFILL_BLOCKED_PENDING_STATUS=PASS");

  status(id0,0,1); if(wb_retry_count_o!=1||!dirty_present_o)$fatal(1,"P18 retryable status semantics");
  wait_issue(id1); if(id1==id0)$fatal(1,"P18 retry attempt id not advanced");
  if(backend_wb_line_addr_o!=A||backend_wb_data_o[2]!=32'hDEAD_BEEF)$fatal(1,"P18 retry payload changed");
  $display("PROD_SEAM_P18_RETRY_EXACT_PAYLOAD=PASS");
  @(posedge clk);#1; status(id1,1,0);
  if(dirty_present_o)$fatal(1,"P18 success did not release victim");
  if(!line_mem_req_valid_o||line_mem_req_global_tag_o!=4'h2||line_mem_req_line_addr_o!=B)$fatal(1,"P18 retained refill not released after success");
  $display("PROD_SEAM_P18_SUCCESS_RELEASES_P17_WRITEBACK=PASS");
  @(posedge clk);#1; refill(4'h2,B,32'h2000);
  $display("PROD_SEAM_P18_POST_SUCCESS_REFILL=PASS");

  // Second dirty victim: non-retryable failure must fail closed and retain dirty line.
  dirty_word(B,1,32'hBEEF_1234); before_reads=read_fire_count; begin_dirty_evict(4'h3,C); wait_issue(id2); @(posedge clk);#1; status(id2,0,0);
  if(!wb_terminal_failure_o||!dirty_present_o||read_fire_count!=before_reads)$fatal(1,"P18 terminal failure did not fail closed");
  if(line_mem_req_valid_o)$fatal(1,"P18 refill escaped terminal failure");
  $display("PROD_SEAM_P18_TERMINAL_FAILURE_FAIL_CLOSED=PASS");
  $display("PROD_SEAM_P18_NO_SYNTHETIC_CLEAN_ON_FAILURE=PASS");

  // Late/wrong status cannot release failed victim and is diagnosed.
  @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=id0;backend_wb_status_success_i=1;#1;
  if(!protocol_error_o||!dirty_present_o)$fatal(1,"P18 stale status containment");
  @(negedge clk);backend_wb_status_valid_i=0;#1;
  $display("PROD_SEAM_P18_STALE_STATUS_CONTAINED=PASS");
  if(wb_fire_count<3)$fatal(1,"P18 expected backend attempts");
  $display("PROD_SEAM_P18_ATTEMPT_ID_PROVENANCE=PASS");
  $display("PROD_SEAM_P18_BEHAVIOR=PASS");
  $finish;
 end
endmodule
