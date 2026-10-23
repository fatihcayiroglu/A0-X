`timescale 1ns/1ps
module a0_l2_recoverable_writeback_slice_tb;
 localparam integer STORE_LANES=1,LINE_WORDS=4,SET_COUNT=4,GLOBAL_TAG_W=4,WRITE_ID_W=3,MAX_WB_RETRIES=0;
 localparam integer WORD_SELECT_W=$clog2(LINE_WORDS),LINE_ADDR_W=32-WORD_SELECT_W,RETRY_W=1,ATTEMPT_ID_W=WRITE_ID_W+RETRY_W;
 logic clk,rst_n;
 logic line_req_valid_i,line_req_ready_o; logic[GLOBAL_TAG_W-1:0] line_req_global_tag_i; logic[LINE_ADDR_W-1:0] line_req_line_addr_i;
 logic line_mem_req_valid_o,line_mem_req_ready_i; logic[GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o; logic[LINE_ADDR_W-1:0] line_mem_req_line_addr_o;
 logic line_mem_resp_valid_i; logic[GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i; logic[LINE_ADDR_W-1:0] line_mem_resp_line_addr_i; logic line_mem_resp_fault_i; logic[31:0] line_mem_resp_data_i[0:LINE_WORDS-1];
 logic line_resp_valid_o; logic[GLOBAL_TAG_W-1:0] line_resp_global_tag_o; logic[LINE_ADDR_W-1:0] line_resp_line_addr_o; logic line_resp_fault_o; logic[31:0] line_resp_data_o[0:LINE_WORDS-1];
 logic store_valid_i,store_ready_o; logic[STORE_LANES-1:0] store_lane_mask_i; logic[31:0] store_word_addr_i[0:STORE_LANES-1],store_wdata_i[0:STORE_LANES-1]; logic[STORE_LANES-1:0] store_hit_mask_o,store_miss_mask_o;
 logic backend_wb_valid_o,backend_wb_ready_i; logic[ATTEMPT_ID_W-1:0] backend_wb_attempt_id_o; logic[LINE_ADDR_W-1:0] backend_wb_line_addr_o; logic[31:0] backend_wb_data_o[0:LINE_WORDS-1];
 logic backend_wb_status_valid_i; logic[ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i; logic backend_wb_status_success_i,backend_wb_status_retryable_i;
 logic backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o;
 logic dirty_present_o,wb_busy_o; logic[RETRY_W-1:0] wb_retry_count_o; logic wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o,protocol_error_o;
 integer i,read_fire_count,recovery_pulse_count;
 localparam logic[LINE_ADDR_W-1:0] A=LINE_ADDR_W'(1),B=LINE_ADDR_W'(5);
 a0_l2_recoverable_writeback_slice #(.STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),.SET_COUNT(SET_COUNT),.GLOBAL_TAG_W(GLOBAL_TAG_W),.WRITE_ID_W(WRITE_ID_W),.MAX_WB_RETRIES(MAX_WB_RETRIES)) dut(.*);
 initial clk=0; always #5 clk=~clk;
 always_ff @(posedge clk) begin
  if(!rst_n) begin read_fire_count<=0; recovery_pulse_count<=0; end
  else begin if(line_mem_req_valid_o&&line_mem_req_ready_i)read_fire_count<=read_fire_count+1; if(recovery_complete_pulse_o)recovery_pulse_count<=recovery_pulse_count+1; end
 end
 function automatic logic[31:0] waddr(input logic[LINE_ADDR_W-1:0] l,input integer o);waddr=(32'(l)<<WORD_SELECT_W)+32'(o);endfunction
 task automatic clear;begin
  line_req_valid_i=0;line_req_global_tag_i='0;line_req_line_addr_i='0;line_mem_req_ready_i=1;line_mem_resp_valid_i=0;line_mem_resp_global_tag_i='0;line_mem_resp_line_addr_i='0;line_mem_resp_fault_i=0;
  store_valid_i=0;store_lane_mask_i=0;store_word_addr_i[0]=0;store_wdata_i[0]=0;backend_wb_ready_i=1;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i=0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_wb_recovery_safe_valid_i=0;
  for(i=0;i<LINE_WORDS;i=i+1)line_mem_resp_data_i[i]=0;
 end endtask
 task automatic reset;begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
 task automatic miss(input logic[GLOBAL_TAG_W-1:0] t,input logic[LINE_ADDR_W-1:0] l);begin @(negedge clk);line_req_valid_i=1;line_req_global_tag_i=t;line_req_line_addr_i=l;#1;if(!line_req_ready_o||!line_mem_req_valid_o)$fatal(1,"P19 miss");@(posedge clk);@(negedge clk);line_req_valid_i=0;#1;end endtask
 task automatic refill(input logic[GLOBAL_TAG_W-1:0] t,input logic[LINE_ADDR_W-1:0] l,input logic[31:0] base);begin @(negedge clk);line_mem_resp_valid_i=1;line_mem_resp_global_tag_i=t;line_mem_resp_line_addr_i=l;for(i=0;i<LINE_WORDS;i=i+1)line_mem_resp_data_i[i]=base+32'(i);#1;if(!line_resp_valid_o||line_resp_global_tag_o!=t||line_resp_line_addr_o!=l||line_resp_fault_o||line_resp_data_o[0]!=base)$fatal(1,"P19 refill");@(posedge clk);@(negedge clk);line_mem_resp_valid_i=0;#1;end endtask
 task automatic dirty;begin @(negedge clk);store_valid_i=1;store_lane_mask_i=1;store_word_addr_i[0]=waddr(A,1);store_wdata_i[0]=32'hFACE_CAFE;#1;if(!store_ready_o||!store_hit_mask_o[0]||store_miss_mask_o[0])$fatal(1,"P19 store");@(posedge clk);@(negedge clk);store_valid_i=0;store_lane_mask_i=0;#1;end endtask
 task automatic evict;begin @(negedge clk);line_req_valid_i=1;line_req_global_tag_i=4'h2;line_req_line_addr_i=B;#1;if(!line_req_ready_o||line_mem_req_valid_o)$fatal(1,"P19 evict");@(posedge clk);@(negedge clk);line_req_valid_i=0;#1;while(!backend_wb_valid_o)@(posedge clk);#1;end endtask
 initial begin
  logic[ATTEMPT_ID_W-1:0] failed_id,reissued_id;integer before_reads;
  reset();
  // Early safe must not be consumed/remembered.
  backend_wb_recovery_safe_valid_i=1;#1;if(backend_wb_recovery_safe_ready_o)$fatal(1,"P19 early safe ready");@(posedge clk);@(negedge clk);backend_wb_recovery_safe_valid_i=0;#1;
  $display("PROD_SEAM_P19_EARLY_SAFE_NOT_CAPTURED=PASS");
  miss(4'h1,A);refill(4'h1,A,32'h1000);dirty();if(!dirty_present_o)$fatal(1,"P19 dirty absent");before_reads=read_fire_count;evict();
  failed_id=backend_wb_attempt_id_o;if(backend_wb_line_addr_o!=A||backend_wb_data_o[1]!=32'hFACE_CAFE)$fatal(1,"P19 initial wb payload");
  @(posedge clk);#1; // backend command accepted
  @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=failed_id;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;#1;@(posedge clk);@(negedge clk);backend_wb_status_valid_i=0;#1;
  if(!wb_terminal_failure_o||!dirty_present_o||read_fire_count!=before_reads)$fatal(1,"P19 failure hold");
  $display("PROD_SEAM_P19_TERMINAL_FAILURE_RETAINS_DIRTY=PASS");
  // Recovery cannot begin without explicit safe ack.
  repeat(2)begin @(posedge clk);#1;if(backend_wb_valid_o||!recovery_active_o||backend_wb_recovery_safe_ready_o!==1'b1)$fatal(1,"P19 wait safe");end
  $display("PROD_SEAM_P19_RECOVERY_WAITS_FOR_BACKEND_SAFE=PASS");
  @(negedge clk);backend_wb_recovery_safe_valid_i=1;#1;if(!backend_wb_recovery_safe_ready_o)$fatal(1,"P19 safe not accepted");@(posedge clk);@(negedge clk);backend_wb_recovery_safe_valid_i=0;#1;
  if(!dirty_present_o||read_fire_count!=before_reads)$fatal(1,"P19 safe synthesized clean");
  $display("PROD_SEAM_P19_SAFE_ACK_DOES_NOT_CLEAN=PASS");
  // Local guard reset/rearm; P17 stays dirty and re-presents exact victim.
  while(!backend_wb_valid_o)begin @(posedge clk);#1;end
  reissued_id=backend_wb_attempt_id_o;
  if(backend_wb_line_addr_o!=A||backend_wb_data_o[1]!=32'hFACE_CAFE)$fatal(1,"P19 reissue payload changed");
  if(!dirty_present_o||line_mem_req_valid_o)$fatal(1,"P19 reissue released victim");
  $display("PROD_SEAM_P19_EXACT_VICTIM_REISSUED=PASS");
  $display("PROD_SEAM_P19_NO_SYNTHETIC_READY_ON_RECOVERY=PASS");
  @(posedge clk);#1;
  @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=reissued_id;backend_wb_status_success_i=1;backend_wb_status_retryable_i=0;#1;@(posedge clk);@(negedge clk);backend_wb_status_valid_i=0;#1;
  if(dirty_present_o)$fatal(1,"P19 post recovery success did not clean");
  if(!line_mem_req_valid_o||line_mem_req_global_tag_o!=4'h2||line_mem_req_line_addr_o!=B)$fatal(1,"P19 retained refill not released");
  $display("PROD_SEAM_P19_POST_RECOVERY_SUCCESS_RELEASES=PASS");
  @(posedge clk);#1;refill(4'h2,B,32'h2000);
  if(recovery_pulse_count!=1)$fatal(1,"P19 recovery pulse count %0d",recovery_pulse_count);
  if(protocol_error_o)$fatal(1,"P19 protocol error");
  if(wb_retry_count_o!='0||wb_busy_o)$fatal(1,"P19 guard not idle after success");
  $display("PROD_SEAM_P19_RECOVERY_EPOCH_COMPLETES_ONCE=PASS");
  $display("PROD_SEAM_P19_POST_RECOVERY_REFILL=PASS");
  $display("PROD_SEAM_P19_BEHAVIOR=PASS");$finish;
 end
endmodule
