`timescale 1ns/1ps
module a0_production_store_commit_recoverable_fault_subsystem_tb;
  localparam integer C=1,LT=1,CO=1,CP=1,LANES=1,S=1,LW=1,SETS=1,WID=1,MWR=0,SWID=2,MSR=0,TO=8;
  localparam integer LAW=32,RW=1,BATW=3,BRTW=3,CNTW=1,SRW=1,SAID=3,TW=3,PIDW=1;
  localparam logic[1:0] K_STORE=2'b10;
  logic clk,rst_n;
  logic[C-1:0] client_req_valid_i,client_req_ready_o; logic[LT-1:0]client_req_local_tag_i[0:C-1];logic[LAW-1:0]client_req_line_addr_i[0:C-1];logic[C-1:0]client_resp_valid_o;logic[LT-1:0]client_resp_local_tag_o[0:C-1];logic[LAW-1:0]client_resp_line_addr_o[0:C-1];logic client_resp_fault_o[0:C-1];logic[31:0]client_resp_data_o[0:C-1][0:LW-1];
  logic[CP-1:0]commit_valid_i,commit_ready_o;logic[LANES-1:0]commit_lane_mask_i[0:CP-1];logic[31:0]commit_word_addr_i[0:CP-1][0:LANES-1],commit_wdata_i[0:CP-1][0:LANES-1];
  logic backend_cmd_valid_o,backend_cmd_ready_i;logic[1:0]backend_cmd_kind_o;logic[BRTW-1:0]backend_cmd_read_tag_o;logic[BATW-1:0]backend_cmd_wb_attempt_id_o;logic[SAID-1:0]backend_cmd_store_attempt_id_o;logic[LAW-1:0]backend_cmd_line_addr_o;logic[31:0]backend_cmd_data_o[0:LW-1];logic[31:0]backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o;
  logic backend_read_resp_valid_i;logic[BRTW-1:0]backend_read_resp_tag_i;logic[LAW-1:0]backend_read_resp_line_addr_i;logic backend_read_resp_fault_i;logic[31:0]backend_read_resp_data_i[0:LW-1];logic backend_wb_status_valid_i;logic[BATW-1:0]backend_wb_status_attempt_id_i;logic backend_wb_status_success_i,backend_wb_status_retryable_i;logic backend_store_status_valid_i;logic[SAID-1:0]backend_store_status_attempt_id_i;logic backend_store_status_success_i,backend_store_status_retryable_i,backend_store_status_reuse_safe_i;logic[S-1:0]backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o;
  logic[S-1:0]dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o;logic[RW-1:0]wb_retry_count_o[0:S-1];logic[CNTW-1:0]wb_pending_count_o,wb_active_count_o;logic commit_visibility_busy_o,store_completion_busy_o,store_terminal_failure_o,line_resp_tag_error_o,line_resp_overflow_o,store_status_timeout_live_o,store_status_timeout_pulse_o,store_status_timeout_seen_o;logic[SRW-1:0]store_retry_count_o;logic[TW-1:0]store_status_timeout_age_o;logic[CP-1:0]commit_abort_o;logic commit_fault_valid_o,commit_fault_ready_i;logic[PIDW-1:0]commit_fault_port_id_o;logic[LANES-1:0]commit_fault_lane_mask_o;logic[31:0]commit_fault_word_addr_o[0:LANES-1],commit_fault_wdata_o[0:LANES-1];logic commit_fault_store_timeout_o;logic[SRW-1:0]commit_fault_store_retry_count_o;logic recovery_required_o,recovery_rearm_pulse_o,store_epoch_o,protocol_error_o;
  logic[SAID-1:0] failed_id,fresh_id;
  a0_production_store_commit_recoverable_fault_subsystem #(.CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),.COMMIT_PORT_COUNT(CP),.STORE_LANES(LANES),.SLICE_COUNT(S),.LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),.WRITE_ID_W(WID),.MAX_WB_RETRIES(MWR),.STORE_WRITE_ID_W(SWID),.MAX_STORE_RETRIES(MSR),.STORE_STATUS_TIMEOUT_CYCLES(TO)) dut(.*);
  initial clk=0;always #5 clk=~clk;
  task automatic defaults;begin client_req_valid_i='0;client_req_local_tag_i[0]='0;client_req_line_addr_i[0]='0;commit_valid_i='0;commit_lane_mask_i[0]='0;commit_word_addr_i[0][0]='0;commit_wdata_i[0][0]='0;backend_cmd_ready_i=1;backend_read_resp_valid_i=0;backend_read_resp_tag_i='0;backend_read_resp_line_addr_i='0;backend_read_resp_fault_i=0;backend_read_resp_data_i[0]='0;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_store_status_valid_i=0;backend_store_status_attempt_id_i='0;backend_store_status_success_i=0;backend_store_status_retryable_i=0;backend_store_status_reuse_safe_i=0;backend_wb_recovery_safe_valid_i='0;commit_fault_ready_i=0;end endtask
  task automatic drive(input logic[31:0]a,input logic[31:0]d);begin commit_valid_i[0]=1;commit_lane_mask_i[0]=1;commit_word_addr_i[0][0]=a;commit_wdata_i[0][0]=d;end endtask
  initial begin
    rst_n=0;defaults();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;
    // Early reuse-safe must not be remembered.
    backend_store_status_reuse_safe_i=1;@(posedge clk);@(negedge clk);backend_store_status_reuse_safe_i=0;drive(32'h100,32'h2929_0001);
    while(!(backend_cmd_valid_o&&backend_cmd_kind_o==K_STORE))@(posedge clk);failed_id=backend_cmd_store_attempt_id_o;
    @(negedge clk);backend_store_status_valid_i=1;backend_store_status_attempt_id_i=failed_id;backend_store_status_success_i=0;backend_store_status_retryable_i=0;@(posedge clk);@(negedge clk);backend_store_status_valid_i=0;
    while(!commit_fault_valid_o)begin @(posedge clk);#1;end @(negedge clk);commit_fault_ready_i=1;#1;if(!commit_abort_o[0]||(|commit_ready_o))$fatal(1,"P29 abort separation");@(posedge clk);#1;@(negedge clk);commit_fault_ready_i=0;commit_valid_i[0]=0;
    repeat(2)@(posedge clk);if(!recovery_required_o||recovery_rearm_pulse_o||store_epoch_o)$fatal(1,"P29 early reuse-safe remembered");
    $display("PROD_SEAM_P29_EARLY_REUSE_SAFE_NOT_REMEMBERED=PASS");
    // Safe only now: exactly one rearm and epoch change.
    @(negedge clk);backend_store_status_reuse_safe_i=1;@(posedge clk);#1;if(!recovery_rearm_pulse_o||!store_epoch_o)$fatal(1,"P29 safe rearm missing");@(negedge clk);backend_store_status_reuse_safe_i=0;@(posedge clk);#1;@(posedge clk);#1;if(recovery_required_o||recovery_rearm_pulse_o)$fatal(1,"P29 recovery did not clear");
    $display("PROD_SEAM_P29_ABORT_AND_REUSE_SAFE_JOIN=PASS");
    $display("PROD_SEAM_P29_CONTROLLED_ONE_CYCLE_REARM=PASS");
    // Fresh commit must expose a distinct ID. Old late status must not complete it.
    @(negedge clk);drive(32'h200,32'h2929_0002);while(!(backend_cmd_valid_o&&backend_cmd_kind_o==K_STORE))@(posedge clk);fresh_id=backend_cmd_store_attempt_id_o;if(fresh_id==failed_id)$fatal(1,"P29 attempt ID reused");
    $display("PROD_SEAM_P29_FRESH_ATTEMPT_DISTINCT=PASS");
    @(negedge clk);backend_store_status_valid_i=1;backend_store_status_attempt_id_i=failed_id;backend_store_status_success_i=1;@(posedge clk);@(negedge clk);backend_store_status_valid_i=0;backend_store_status_success_i=0;repeat(2)@(posedge clk);if(commit_ready_o[0])$fatal(1,"P29 late old status released fresh commit");
    $display("PROD_SEAM_P29_LATE_OLD_STATUS_CONTAINED=PASS");
    @(negedge clk);backend_store_status_valid_i=1;backend_store_status_attempt_id_i=fresh_id;backend_store_status_success_i=1;@(posedge clk);#1;if(!commit_ready_o[0])$fatal(1,"P29 fresh success missing");@(negedge clk);backend_store_status_valid_i=0;backend_store_status_success_i=0;commit_valid_i[0]=0;
    $display("PROD_SEAM_P29_FRESH_COMMIT_COMPLETES=PASS");
    if(backend_cmd_read_tag_o!='0||backend_cmd_wb_attempt_id_o!='0||(|client_req_ready_o)||(|client_resp_valid_o)||client_resp_local_tag_o[0]!='0||client_resp_line_addr_o[0]!='0||client_resp_fault_o[0]||client_resp_data_o[0][0]!='0||backend_cmd_line_addr_o!='0||backend_cmd_data_o[0]!='0||backend_cmd_store_word_addr_o!='0||backend_cmd_store_wdata_o!='0||(|backend_wb_recovery_safe_ready_o)||(|dirty_present_o)||(|wb_busy_o)||wb_retry_count_o[0]!='0||(|wb_terminal_failure_o)||(|recovery_active_o)||(|recovery_complete_pulse_o)||wb_pending_count_o!='0||wb_active_count_o!='0||commit_fault_port_id_o!='0||commit_fault_lane_mask_o!='0||commit_fault_word_addr_o[0]!='0||commit_fault_wdata_o[0]!='0||commit_fault_store_timeout_o||commit_fault_store_retry_count_o!='0||line_resp_tag_error_o||line_resp_overflow_o||store_status_timeout_live_o||store_status_timeout_pulse_o||store_status_timeout_seen_o||store_status_timeout_age_o!='0||store_retry_count_o!='0||store_terminal_failure_o||commit_visibility_busy_o||store_completion_busy_o||protocol_error_o) begin end
    $display("PROD_SEAM_P29_END_TO_END_BEHAVIOR=PASS");$finish;
  end
endmodule
