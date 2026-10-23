`timescale 1ns/1ps
module a0_production_store_commit_completed_miss_visibility_subsystem_tb;
    localparam integer C=1,LT=2,CO=2,CP=1,LANES=1,S=1,LW=2,SETS=1,WID=2,MWR=0,SWID=3,MSR=1;
    localparam integer LAW=31,CIDW=1,GTW=CIDW+LT,SIDW=1,RW=1,LATW=WID+RW,BATW=SIDW+LATW,BRTW=SIDW+GTW,CNTW=1,SRW=1,SAID=SWID+SRW;
    localparam logic[1:0] K_READ=2'b00,K_WB=2'b01,K_STORE=2'b10;
    logic clk,rst_n;
    logic[C-1:0] client_req_valid_i,client_req_ready_o;
    logic[LT-1:0] client_req_local_tag_i[0:C-1]; logic[LAW-1:0] client_req_line_addr_i[0:C-1];
    logic[C-1:0] client_resp_valid_o; logic[LT-1:0]client_resp_local_tag_o[0:C-1];
    logic[LAW-1:0]client_resp_line_addr_o[0:C-1]; logic client_resp_fault_o[0:C-1]; logic[31:0]client_resp_data_o[0:C-1][0:LW-1];
    logic[CP-1:0]commit_valid_i,commit_ready_o; logic[LANES-1:0]commit_lane_mask_i[0:CP-1];
    logic[31:0]commit_word_addr_i[0:CP-1][0:LANES-1],commit_wdata_i[0:CP-1][0:LANES-1];
    logic backend_cmd_valid_o,backend_cmd_ready_i; logic[1:0]backend_cmd_kind_o;
    logic[BRTW-1:0]backend_cmd_read_tag_o; logic[BATW-1:0]backend_cmd_wb_attempt_id_o; logic[SAID-1:0]backend_cmd_store_attempt_id_o;
    logic[LAW-1:0]backend_cmd_line_addr_o; logic[31:0]backend_cmd_data_o[0:LW-1]; logic[31:0]backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o;
    logic backend_read_resp_valid_i; logic[BRTW-1:0]backend_read_resp_tag_i; logic[LAW-1:0]backend_read_resp_line_addr_i; logic backend_read_resp_fault_i; logic[31:0]backend_read_resp_data_i[0:LW-1];
    logic backend_wb_status_valid_i; logic[BATW-1:0]backend_wb_status_attempt_id_i; logic backend_wb_status_success_i,backend_wb_status_retryable_i;
    logic backend_store_status_valid_i; logic[SAID-1:0]backend_store_status_attempt_id_i; logic backend_store_status_success_i,backend_store_status_retryable_i;
    logic[S-1:0]backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o,dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o;
    logic[RW-1:0]wb_retry_count_o[0:S-1]; logic[CNTW-1:0]wb_pending_count_o,wb_active_count_o;
    logic commit_visibility_busy_o,store_completion_busy_o,store_terminal_failure_o,line_resp_tag_error_o,line_resp_overflow_o,protocol_error_o; logic[SRW-1:0]store_retry_count_o;
    logic[31:0]mem[0:7][0:LW-1]; integer i,j,read_count,store_issue_count,wb_count;
    logic[BRTW-1:0]last_read_tag; logic[LAW-1:0]last_read_line; logic[SAID-1:0]last_store_id; logic[31:0]last_store_addr,last_store_data;
    logic[BATW-1:0]last_wb_id; logic[LAW-1:0]last_wb_line; logic[31:0]last_wb_data[0:LW-1];
    localparam logic[LAW-1:0]A1=LAW'(1),B1=LAW'(2);

    a0_production_store_commit_completed_miss_visibility_subsystem #(
      .CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),.COMMIT_PORT_COUNT(CP),.STORE_LANES(LANES),
      .SLICE_COUNT(S),.LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),.WRITE_ID_W(WID),.MAX_WB_RETRIES(MWR),
      .STORE_WRITE_ID_W(SWID),.MAX_STORE_RETRIES(MSR)) dut(.*);
    initial clk=0; always #5 clk=~clk;
    function automatic logic[31:0] waddr(input logic[LAW-1:0] line,input logic off); waddr=(32'(line)<<1)+32'(off); endfunction

    always_ff @(posedge clk) begin
      if(!rst_n) begin
        read_count<=0; store_issue_count<=0; wb_count<=0; last_read_tag<='0; last_read_line<='0;
        last_store_id<='0;last_store_addr<='0;last_store_data<='0;last_wb_id<='0;last_wb_line<='0;
        for(integer q=0;q<LW;q=q+1)last_wb_data[q]<='0;
      end else if(backend_cmd_valid_o&&backend_cmd_ready_i) begin
        case(backend_cmd_kind_o)
          K_READ: begin read_count<=read_count+1;last_read_tag<=backend_cmd_read_tag_o;last_read_line<=backend_cmd_line_addr_o; end
          K_STORE: begin store_issue_count<=store_issue_count+1;last_store_id<=backend_cmd_store_attempt_id_o;last_store_addr<=backend_cmd_store_word_addr_o;last_store_data<=backend_cmd_store_wdata_o; end
          K_WB: begin wb_count<=wb_count+1;last_wb_id<=backend_cmd_wb_attempt_id_o;last_wb_line<=backend_cmd_line_addr_o;for(integer q=0;q<LW;q=q+1)last_wb_data[q]<=backend_cmd_data_o[q]; end
          default:$fatal(1,"P26 invalid backend kind");
        endcase
      end
    end
    task automatic clear;
      begin
        client_req_valid_i='0;commit_valid_i='0;backend_cmd_ready_i=1;backend_read_resp_valid_i=0;backend_read_resp_tag_i='0;
        backend_read_resp_line_addr_i='0;backend_read_resp_fault_i=0;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;
        backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_store_status_valid_i=0;backend_store_status_attempt_id_i='0;
        backend_store_status_success_i=0;backend_store_status_retryable_i=0;backend_wb_recovery_safe_valid_i='0;
        client_req_local_tag_i[0]='0;client_req_line_addr_i[0]='0;commit_lane_mask_i[0]='0;commit_word_addr_i[0][0]='0;commit_wdata_i[0][0]='0;
        for(i=0;i<8;i=i+1)for(j=0;j<LW;j=j+1)mem[i][j]=32'h2600_0000+32'(i*16+j);
        for(j=0;j<LW;j=j+1)backend_read_resp_data_i[j]='0;
      end
    endtask
    task automatic reset; begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
    task automatic req(input logic[LT-1:0]tag,input logic[LAW-1:0]line);
      begin @(negedge clk);client_req_valid_i[0]=1;client_req_local_tag_i[0]=tag;client_req_line_addr_i[0]=line;#1;
        while(!client_req_ready_o[0])begin @(posedge clk);@(negedge clk);#1;end @(posedge clk);@(negedge clk);client_req_valid_i[0]=0;#1;end
    endtask
    task automatic respond_read;
      begin @(negedge clk);backend_read_resp_valid_i=1;backend_read_resp_tag_i=last_read_tag;backend_read_resp_line_addr_i=last_read_line;
        for(j=0;j<LW;j=j+1)backend_read_resp_data_i[j]=mem[integer'(last_read_line)][j];#1;@(posedge clk);@(negedge clk);backend_read_resp_valid_i=0;#1;end
    endtask
    task automatic wait_resp(input logic[LT-1:0]tag,input logic[LAW-1:0]line,input logic[31:0]w0,input logic[31:0]w1);
      begin while(!client_resp_valid_o[0])begin @(posedge clk);#1;end
        if(client_resp_local_tag_o[0]!=tag||client_resp_line_addr_o[0]!=line||client_resp_fault_o[0]
           ||client_resp_data_o[0][0]!=w0||client_resp_data_o[0][1]!=w1)$fatal(1,"P26 client response mismatch");@(posedge clk);#1;end
    endtask

    initial begin
      integer reads_before;
      reset();
      // A1 is not resident: command acceptance alone must not acknowledge this visibility commit.
      @(negedge clk);commit_valid_i[0]=1;commit_lane_mask_i[0]=1;commit_word_addr_i[0][0]=waddr(A1,1'b1);commit_wdata_i[0][0]=32'hD026_0001;#1;
      while(store_issue_count!=1)begin if(commit_ready_o[0])$fatal(1,"P26 commit ack before store issue");@(posedge clk);#1;end
      repeat(2)begin @(posedge clk);#1;if(commit_ready_o[0])$fatal(1,"P26 commit ack on command acceptance alone");end
      if(last_store_addr!=waddr(A1,1'b1)||last_store_data!=32'hD026_0001||!store_completion_busy_o)$fatal(1,"P26 captured store identity");
      $display("PROD_SEAM_P26_E2E_ACCEPT_ALONE_COMMIT_BLOCKED=PASS");

      // Backend makes the word visible only when it returns matching SUCCESS.
      @(negedge clk);mem[1][1]=32'hD026_0001;backend_store_status_valid_i=1;backend_store_status_attempt_id_i=last_store_id;
      backend_store_status_success_i=1;#1;@(posedge clk);#1;@(negedge clk);backend_store_status_valid_i=0;backend_store_status_success_i=0;#1;
      while(!commit_ready_o[0])begin @(posedge clk);#1;end
      if(store_terminal_failure_o||store_retry_count_o!='0)$fatal(1,"P26 unexpected store completion state");
      $display("PROD_SEAM_P26_E2E_MATCHING_SUCCESS_RELEASES_COMMIT=PASS");
      @(posedge clk);#1;@(negedge clk);commit_valid_i[0]=0;#1;

      // Post-ack refill must now see the completed store value.
      req(2'd1,A1);while(read_count!=1)begin @(posedge clk);#1;end
      if(last_read_line!=A1)$fatal(1,"P26 refill line");respond_read();wait_resp(2'd1,A1,mem[1][0],32'hD026_0001);
      $display("PROD_SEAM_P26_POST_SUCCESS_REFILL_FRESH=PASS");
      $display("PROD_SEAM_P26_READ_TYPED_PASSTHROUGH=PASS");

      // Resident hit stays on dirty fast path and therefore needs no STORE_WORD completion.
      @(negedge clk);commit_valid_i[0]=1;commit_lane_mask_i[0]=1;commit_word_addr_i[0][0]=waddr(A1,1'b0);commit_wdata_i[0][0]=32'hE026_0002;#1;
      while(!commit_ready_o[0])begin @(posedge clk);#1;end
      if(store_issue_count!=1||store_completion_busy_o)$fatal(1,"P26 resident hit incorrectly used store guard");
      @(posedge clk);#1;@(negedge clk);commit_valid_i[0]=0;#1;
      $display("PROD_SEAM_P26_RESIDENT_DIRTY_FASTPATH_UNCHANGED=PASS");

      // Replacement proves P23 writeback passthrough survives the P26 interception layer.
      reads_before=read_count; req(2'd2,B1); while(wb_count!=1)begin @(posedge clk);#1;end
      if(last_wb_line!=A1||last_wb_data[0]!=32'hE026_0002||last_wb_data[1]!=32'hD026_0001)$fatal(1,"P26 writeback payload");
      $display("PROD_SEAM_P26_WRITEBACK_TYPED_PASSTHROUGH=PASS");
      @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=last_wb_id;backend_wb_status_success_i=1;#1;
      @(posedge clk);#1;@(negedge clk);backend_wb_status_valid_i=0;backend_wb_status_success_i=0;#1;
      while(read_count!=reads_before+1)begin @(posedge clk);#1;end
      if(last_read_line!=B1)$fatal(1,"P26 replacement refill");respond_read();wait_resp(2'd2,B1,mem[2][0],mem[2][1]);
      repeat(2)@(posedge clk);#1;
      if(commit_visibility_busy_o||store_completion_busy_o||store_terminal_failure_o||protocol_error_o||line_resp_tag_error_o||line_resp_overflow_o
         ||wb_pending_count_o!='0||wb_active_count_o!='0||(|wb_busy_o)||(|dirty_present_o)||(|wb_terminal_failure_o)||(|recovery_active_o)||(|recovery_complete_pulse_o)||(|backend_wb_recovery_safe_ready_o))
        $fatal(1,"P26 final diagnostics");
      if(store_retry_count_o!='0||wb_retry_count_o[0]!='0)$fatal(1,"P26 final retry state");
      $display("PROD_SEAM_P26_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS");
      $display("PROD_SEAM_P26_END_TO_END_BEHAVIOR=PASS");
      $finish;
    end
endmodule
