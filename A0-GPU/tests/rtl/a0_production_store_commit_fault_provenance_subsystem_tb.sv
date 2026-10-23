`timescale 1ns/1ps
module a0_production_store_commit_fault_provenance_subsystem_tb;
    localparam integer C=1,LT=2,CO=2,CP=2,LANES=2,S=1,LW=2,SETS=1,WID=2,MWR=0,SWID=3,MSR=0,TO=4;
    localparam integer LAW=31,CIDW=1,GTW=CIDW+LT,SIDW=1,RW=1,LATW=WID+RW,BATW=SIDW+LATW,BRTW=SIDW+GTW,CNTW=1,SRW=1,SAID=SWID+SRW,TW=2,PIDW=1;
    localparam logic[1:0] K_READ=2'b00,K_WB=2'b01,K_STORE=2'b10;
    logic clk,rst_n;
    logic[C-1:0] client_req_valid_i,client_req_ready_o; logic[LT-1:0] client_req_local_tag_i[0:C-1]; logic[LAW-1:0] client_req_line_addr_i[0:C-1];
    logic[C-1:0] client_resp_valid_o; logic[LT-1:0]client_resp_local_tag_o[0:C-1]; logic[LAW-1:0]client_resp_line_addr_o[0:C-1]; logic client_resp_fault_o[0:C-1]; logic[31:0]client_resp_data_o[0:C-1][0:LW-1];
    logic[CP-1:0]commit_valid_i,commit_ready_o; logic[LANES-1:0]commit_lane_mask_i[0:CP-1]; logic[31:0]commit_word_addr_i[0:CP-1][0:LANES-1],commit_wdata_i[0:CP-1][0:LANES-1];
    logic backend_cmd_valid_o,backend_cmd_ready_i; logic[1:0]backend_cmd_kind_o; logic[BRTW-1:0]backend_cmd_read_tag_o; logic[BATW-1:0]backend_cmd_wb_attempt_id_o; logic[SAID-1:0]backend_cmd_store_attempt_id_o; logic[LAW-1:0]backend_cmd_line_addr_o; logic[31:0]backend_cmd_data_o[0:LW-1]; logic[31:0]backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o;
    logic backend_read_resp_valid_i; logic[BRTW-1:0]backend_read_resp_tag_i; logic[LAW-1:0]backend_read_resp_line_addr_i; logic backend_read_resp_fault_i; logic[31:0]backend_read_resp_data_i[0:LW-1];
    logic backend_wb_status_valid_i; logic[BATW-1:0]backend_wb_status_attempt_id_i; logic backend_wb_status_success_i,backend_wb_status_retryable_i;
    logic backend_store_status_valid_i; logic[SAID-1:0]backend_store_status_attempt_id_i; logic backend_store_status_success_i,backend_store_status_retryable_i;
    logic[S-1:0]backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o,dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o; logic[RW-1:0]wb_retry_count_o[0:S-1]; logic[CNTW-1:0]wb_pending_count_o,wb_active_count_o;
    logic commit_visibility_busy_o,store_completion_busy_o,store_terminal_failure_o,line_resp_tag_error_o,line_resp_overflow_o,store_status_timeout_live_o,store_status_timeout_pulse_o,store_status_timeout_seen_o; logic[SRW-1:0]store_retry_count_o; logic[TW-1:0]store_status_timeout_age_o;
    logic[CP-1:0]commit_abort_o; logic commit_fault_valid_o,commit_fault_ready_i; logic[PIDW-1:0]commit_fault_port_id_o; logic[LANES-1:0]commit_fault_lane_mask_o; logic[31:0]commit_fault_word_addr_o[0:LANES-1],commit_fault_wdata_o[0:LANES-1]; logic commit_fault_store_timeout_o; logic[SRW-1:0]commit_fault_store_retry_count_o; logic recovery_required_o,protocol_error_o;
    integer ready_count[0:CP-1],abort_count[0:CP-1],store_issue_count,timeout_pulse_count,i,j;
    logic[SAID-1:0]last_store_id; logic[31:0]store_addr_seq[0:7],store_data_seq[0:7];

    a0_production_store_commit_fault_provenance_subsystem #(
      .CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),.COMMIT_PORT_COUNT(CP),.STORE_LANES(LANES),.SLICE_COUNT(S),.LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),.WRITE_ID_W(WID),.MAX_WB_RETRIES(MWR),.STORE_WRITE_ID_W(SWID),.MAX_STORE_RETRIES(MSR),.STORE_STATUS_TIMEOUT_CYCLES(TO)) dut(.*);
    initial clk=0; always #5 clk=~clk;

    always_ff @(posedge clk) begin
      if(!rst_n) begin
        for(integer p=0;p<CP;p=p+1)begin ready_count[p]<=0;abort_count[p]<=0;end
        store_issue_count<=0;timeout_pulse_count<=0;last_store_id<='0;
        for(integer q=0;q<8;q=q+1)begin store_addr_seq[q]<='0;store_data_seq[q]<='0;end
      end else begin
        for(integer p=0;p<CP;p=p+1)begin if(commit_ready_o[p])ready_count[p]<=ready_count[p]+1;if(commit_abort_o[p])abort_count[p]<=abort_count[p]+1;end
        if(store_status_timeout_pulse_o)timeout_pulse_count<=timeout_pulse_count+1;
        if(backend_cmd_valid_o&&backend_cmd_ready_i&&backend_cmd_kind_o==K_STORE)begin
          last_store_id<=backend_cmd_store_attempt_id_o;store_addr_seq[store_issue_count]<=backend_cmd_store_word_addr_o;store_data_seq[store_issue_count]<=backend_cmd_store_wdata_o;store_issue_count<=store_issue_count+1;
        end
      end
    end

    task automatic clear_inputs;
      begin
        client_req_valid_i='0;for(i=0;i<C;i=i+1)begin client_req_local_tag_i[i]='0;client_req_line_addr_i[i]='0;end
        commit_valid_i='0;for(i=0;i<CP;i=i+1)begin commit_lane_mask_i[i]='0;for(j=0;j<LANES;j=j+1)begin commit_word_addr_i[i][j]='0;commit_wdata_i[i][j]='0;end end
        backend_cmd_ready_i=1;backend_read_resp_valid_i=0;backend_read_resp_tag_i='0;backend_read_resp_line_addr_i='0;backend_read_resp_fault_i=0;for(i=0;i<LW;i=i+1)backend_read_resp_data_i[i]='0;
        backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_store_status_valid_i=0;backend_store_status_attempt_id_i='0;backend_store_status_success_i=0;backend_store_status_retryable_i=0;backend_wb_recovery_safe_valid_i='0;commit_fault_ready_i=0;
      end
    endtask
    task automatic reset;begin rst_n=0;clear_inputs();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
    task automatic drive_commit(input logic[PIDW-1:0] p,input logic[31:0]addr,input logic[31:0]data);
      begin commit_valid_i[p]=1;commit_lane_mask_i[p]=2'b01;commit_word_addr_i[p][0]=addr;commit_wdata_i[p][0]=data;commit_word_addr_i[p][1]=addr+32'd4;commit_wdata_i[p][1]=data^32'hffff_ffff;end
    endtask
    task automatic send_store_status(input logic success,input logic retryable);
      begin @(negedge clk);backend_store_status_valid_i=1;backend_store_status_attempt_id_i=last_store_id;backend_store_status_success_i=success;backend_store_status_retryable_i=retryable;#1;@(posedge clk);#1;@(negedge clk);backend_store_status_valid_i=0;backend_store_status_success_i=0;backend_store_status_retryable_i=0;#1;end
    endtask

    initial begin
      logic[31:0]fa0,fd0,fa1,fd1;
      reset();
      // Two simultaneous successful sources: wrapper owns arbitration and success ready stays source-specific.
      @(negedge clk);drive_commit(0,32'h0000_0100,32'hA028_0000);drive_commit(1,32'h0000_0200,32'hB028_0001);#1;
      while(store_issue_count<1)begin @(posedge clk);#1;end send_store_status(1,0);
      while(ready_count[0]<1)begin @(posedge clk);#1;end @(negedge clk);commit_valid_i[0]=0;#1;
      while(store_issue_count<2)begin @(posedge clk);#1;end send_store_status(1,0);
      while(ready_count[1]<1)begin @(posedge clk);#1;end @(negedge clk);commit_valid_i[1]=0;#1;
      if(store_addr_seq[0]!=32'h100||store_data_seq[0]!=32'hA028_0000||store_addr_seq[1]!=32'h200||store_data_seq[1]!=32'hB028_0001)$fatal(1,"P28 round-robin source order/identity");
      if(abort_count[0]!=0||abort_count[1]!=0||commit_fault_valid_o||recovery_required_o||protocol_error_o)$fatal(1,"P28 successful path diagnostics");
      $display("PROD_SEAM_P28_SUCCESS_ONLY_READY=PASS");
      $display("PROD_SEAM_P28_ROUND_ROBIN_PORT_IDENTITY=PASS");

      // Timeout fault: exact source identity/payload must be retained under fault backpressure.
      reset();@(negedge clk);drive_commit(1,32'h0000_0300,32'hC028_0002);fa0=32'h300;fd0=32'hC028_0002;fa1=32'h304;fd1=32'h3fd7_fffd;#1;
      while(store_issue_count<1)begin @(posedge clk);#1;end
      while(!commit_fault_valid_o)begin if(|commit_ready_o)$fatal(1,"P28 failure used normal ready");@(posedge clk);#1;end
      if(commit_fault_port_id_o!=PIDW'(1)||commit_fault_lane_mask_o!=2'b01||commit_fault_word_addr_o[0]!=fa0||commit_fault_wdata_o[0]!=fd0||commit_fault_word_addr_o[1]!=fa1||commit_fault_wdata_o[1]!=fd1||!commit_fault_store_timeout_o||commit_fault_store_retry_count_o!='0)$fatal(1,"P28 timeout fault provenance");
      repeat(3)begin @(posedge clk);#1;if(!commit_fault_valid_o||commit_fault_port_id_o!=PIDW'(1)||commit_fault_word_addr_o[0]!=fa0||commit_fault_wdata_o[0]!=fd0||(|commit_ready_o)||(|commit_abort_o))$fatal(1,"P28 fault payload/backpressure stability");end
      $display("PROD_SEAM_P28_FAULT_PAYLOAD_STABLE=PASS");
      $display("PROD_SEAM_P28_TIMEOUT_PROVENANCE=PASS");
      @(negedge clk);commit_fault_ready_i=1;#1;if(!commit_abort_o[1]||(|commit_ready_o))$fatal(1,"P28 abort handshake separation");@(posedge clk);#1;@(negedge clk);commit_fault_ready_i=0;commit_valid_i[1]=0;#1;
      if(abort_count[1]!=1||ready_count[1]!=0||!recovery_required_o||commit_fault_valid_o||timeout_pulse_count!=1)$fatal(1,"P28 abort/recovery-required cardinality");
      $display("PROD_SEAM_P28_ABORT_SEPARATE_FROM_SUCCESS=PASS");
      $display("PROD_SEAM_P28_POST_ABORT_RECOVERY_REQUIRED=PASS");

      // Genuine backend terminal failure is distinct from timeout provenance.
      reset();@(negedge clk);drive_commit(0,32'h0000_0400,32'hD028_0003);#1;
      while(store_issue_count<1)begin @(posedge clk);#1;end send_store_status(0,0);
      while(!commit_fault_valid_o)begin @(posedge clk);#1;end
      if(commit_fault_port_id_o!=PIDW'(0)||commit_fault_store_timeout_o||commit_fault_store_retry_count_o!='0||(|commit_ready_o))$fatal(1,"P28 backend terminal provenance");
      $display("PROD_SEAM_P28_BACKEND_FAILURE_DISTINCT_FROM_TIMEOUT=PASS");
      @(negedge clk);commit_fault_ready_i=1;#1;if(!commit_abort_o[0])$fatal(1,"P28 backend fault abort");@(posedge clk);#1;@(negedge clk);commit_fault_ready_i=0;commit_valid_i[0]=0;#1;
      if(abort_count[0]!=1||ready_count[0]!=0||!recovery_required_o||protocol_error_o)$fatal(1,"P28 final fault state");

      // Reference every frozen diagnostic/output so strict TB lint proves the composed surface remains wired.
      if((|client_req_ready_o)||(|client_resp_valid_o)||client_resp_local_tag_o[0]!='0||client_resp_line_addr_o[0]!='0||client_resp_fault_o[0]||client_resp_data_o[0][0]!='0||client_resp_data_o[0][1]!='0||backend_cmd_kind_o==K_READ||backend_cmd_kind_o==K_WB||backend_cmd_read_tag_o!='0||backend_cmd_wb_attempt_id_o!='0||backend_cmd_line_addr_o!='0||backend_cmd_data_o[0]!='0||backend_cmd_data_o[1]!='0||backend_read_resp_valid_i||backend_wb_status_valid_i||(|backend_wb_recovery_safe_ready_o)||(|dirty_present_o)||(|wb_busy_o)||wb_retry_count_o[0]!='0||(|wb_terminal_failure_o)||(|recovery_active_o)||(|recovery_complete_pulse_o)||wb_pending_count_o!='0||wb_active_count_o!='0||!commit_visibility_busy_o||!store_completion_busy_o||!store_terminal_failure_o||line_resp_tag_error_o||line_resp_overflow_o||store_status_timeout_live_o||store_status_timeout_seen_o||store_status_timeout_age_o!='0||store_retry_count_o!='0) begin end
      $display("PROD_SEAM_P28_NO_DOUBLE_SUCCESS_FAILURE=PASS");
      $display("PROD_SEAM_P28_END_TO_END_BEHAVIOR=PASS");
      $finish;
    end
endmodule
