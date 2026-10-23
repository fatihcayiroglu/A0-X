`timescale 1ns/1ps
module a0_production_store_commit_write_miss_visibility_subsystem_tb;
 localparam integer C=1,LT=2,CO=2,CP=2,LANES=2,S=2,LW=2,SETS=2,WID=2,MR=0;
 localparam integer LAW=31,RETRYW=1,LATW=3,BATW=4,BRTW=4,CNTW=2;
 localparam logic[1:0] K_READ=2'b00,K_WB=2'b01,K_STORE=2'b10;
 logic clk,rst_n;
 logic[C-1:0]client_req_valid_i,client_req_ready_o;logic[LT-1:0]client_req_local_tag_i[0:C-1];logic[LAW-1:0]client_req_line_addr_i[0:C-1];
 logic[C-1:0]client_resp_valid_o;logic[LT-1:0]client_resp_local_tag_o[0:C-1];logic[LAW-1:0]client_resp_line_addr_o[0:C-1];logic client_resp_fault_o[0:C-1];logic[31:0]client_resp_data_o[0:C-1][0:LW-1];
 logic[CP-1:0]commit_valid_i,commit_ready_o;logic[LANES-1:0]commit_lane_mask_i[0:CP-1];logic[31:0]commit_word_addr_i[0:CP-1][0:LANES-1],commit_wdata_i[0:CP-1][0:LANES-1];
 logic backend_cmd_valid_o,backend_cmd_ready_i;logic[1:0]backend_cmd_kind_o;logic[BRTW-1:0]backend_cmd_read_tag_o;logic[BATW-1:0]backend_cmd_wb_attempt_id_o;logic[LAW-1:0]backend_cmd_line_addr_o;logic[31:0]backend_cmd_data_o[0:LW-1];logic[31:0]backend_cmd_store_word_addr_o,backend_cmd_store_wdata_o;
 logic backend_read_resp_valid_i;logic[BRTW-1:0]backend_read_resp_tag_i;logic[LAW-1:0]backend_read_resp_line_addr_i;logic backend_read_resp_fault_i;logic[31:0]backend_read_resp_data_i[0:LW-1];
 logic backend_wb_status_valid_i;logic[BATW-1:0]backend_wb_status_attempt_id_i;logic backend_wb_status_success_i,backend_wb_status_retryable_i;logic[S-1:0]backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o;
 logic[S-1:0]dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o;logic[RETRYW-1:0]wb_retry_count_o[0:S-1];logic[CNTW-1:0]wb_pending_count_o,wb_active_count_o;logic commit_visibility_busy_o,line_resp_tag_error_o,line_resp_overflow_o,protocol_error_o;
 integer read_count,store_count,wb_count;logic[BRTW-1:0]last_read_tag;logic[LAW-1:0]last_read_line;logic[BATW-1:0]last_wb_id;logic[LAW-1:0]last_wb_line;logic[31:0]last_wb_data[0:LW-1];
 logic[31:0]mem[0:7][0:LW-1];integer i,j;
 localparam logic[LAW-1:0]A0=LAW'(0),A1=LAW'(1),A3=LAW'(3),B0=LAW'(4);
 a0_production_store_commit_write_miss_visibility_subsystem #(.CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),.COMMIT_PORT_COUNT(CP),.STORE_LANES(LANES),.SLICE_COUNT(S),.LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),.WRITE_ID_W(WID),.MAX_WB_RETRIES(MR)) dut(.*);
 initial clk=0;always #5 clk=~clk;
 function automatic logic[31:0] waddr(input logic[LAW-1:0]line,input integer off);waddr=(32'(line)<<1)+32'(off);endfunction
 function automatic integer wb_source(input logic[BATW-1:0]id);wb_source=integer'(id)>>LATW;endfunction
 always_ff @(posedge clk) begin integer line_idx; logic off_bit;
  if(!rst_n)begin read_count<=0;store_count<=0;wb_count<=0;last_read_tag<='0;last_read_line<='0;last_wb_id<='0;last_wb_line<='0;for(integer q=0;q<LW;q=q+1)last_wb_data[q]<='0;end
  else if(backend_cmd_valid_o&&backend_cmd_ready_i)begin
   case(backend_cmd_kind_o)
    K_READ:begin read_count<=read_count+1;last_read_tag<=backend_cmd_read_tag_o;last_read_line<=backend_cmd_line_addr_o;end
    K_STORE:begin
      store_count<=store_count+1;line_idx=integer'(backend_cmd_store_word_addr_o>>1);off_bit=backend_cmd_store_word_addr_o[0];
      if(line_idx<0||line_idx>7)$fatal(1,"P25 store line range");mem[line_idx][off_bit]<=backend_cmd_store_wdata_o;
    end
    K_WB:begin wb_count<=wb_count+1;last_wb_id<=backend_cmd_wb_attempt_id_o;last_wb_line<=backend_cmd_line_addr_o;for(integer q=0;q<LW;q=q+1)last_wb_data[q]<=backend_cmd_data_o[q];end
    default:$fatal(1,"P25 invalid backend kind");
   endcase
  end
 end
 task automatic clear;begin client_req_valid_i='0;commit_valid_i='0;backend_cmd_ready_i=1;backend_read_resp_valid_i=0;backend_read_resp_tag_i='0;backend_read_resp_line_addr_i='0;backend_read_resp_fault_i=0;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_wb_recovery_safe_valid_i='0;client_req_local_tag_i[0]='0;client_req_line_addr_i[0]='0;for(i=0;i<CP;i=i+1)begin commit_lane_mask_i[i]='0;for(j=0;j<LANES;j=j+1)begin commit_word_addr_i[i][j]='0;commit_wdata_i[i][j]='0;end end for(i=0;i<8;i=i+1)for(j=0;j<LW;j=j+1)mem[i][j]=32'h1000+32'(i*16+j);for(j=0;j<LW;j=j+1)backend_read_resp_data_i[j]='0;end endtask
 task automatic reset;begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
 task automatic req(input logic[LT-1:0]tag,input logic[LAW-1:0]line);begin @(negedge clk);client_req_valid_i[0]=1;client_req_local_tag_i[0]=tag;client_req_line_addr_i[0]=line;#1;while(!client_req_ready_o[0])begin @(posedge clk);@(negedge clk);#1;end @(posedge clk);@(negedge clk);client_req_valid_i[0]=0;#1;end endtask
 task automatic respond_last_read;begin @(negedge clk);backend_read_resp_valid_i=1;backend_read_resp_tag_i=last_read_tag;backend_read_resp_line_addr_i=last_read_line;for(j=0;j<LW;j=j+1)backend_read_resp_data_i[j]=mem[integer'(last_read_line)][j];#1;@(posedge clk);@(negedge clk);backend_read_resp_valid_i=0;#1;end endtask
 task automatic wait_resp(input logic[LT-1:0]tag,input logic[LAW-1:0]line,input logic[31:0]word1);begin while(!client_resp_valid_o[0])begin @(posedge clk);#1;end if(client_resp_local_tag_o[0]!=tag||client_resp_line_addr_o[0]!=line||client_resp_fault_o[0]||client_resp_data_o[0][1]!=word1)$fatal(1,"P25 client response mismatch");@(posedge clk);#1;end endtask
 task automatic wb_success(input logic[BATW-1:0]id);begin @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=id;backend_wb_status_success_i=1;#1;@(posedge clk);@(negedge clk);backend_wb_status_valid_i=0;backend_wb_status_success_i=0;#1;end endtask
 initial begin logic[31:0]held_addr,held_data;integer reads_before;
  reset();
  // Preload A0 only; A1 and A3 remain nonresident.
  req(2'd0,A0);while(read_count!=1)begin @(posedge clk);#1;end;if(backend_cmd_kind_o==K_STORE)$fatal(1,"P25 unexpected kind");respond_last_read();wait_resp(2'd0,A0,mem[0][1]);
  $display("PROD_SEAM_P25_PRELOAD_RESIDENT_HIT_LINE=PASS");

  // Port0: lane0 hits resident A0, lane1 misses nonresident A1. Port1 waits behind it.
  @(negedge clk);backend_cmd_ready_i=0;commit_valid_i=2'b11;
  commit_lane_mask_i[0]=2'b11;commit_word_addr_i[0][0]=waddr(A0,1);commit_wdata_i[0][0]=32'hA000_0025;commit_word_addr_i[0][1]=waddr(A1,1);commit_wdata_i[0][1]=32'hB000_0025;
  commit_lane_mask_i[1]=2'b01;commit_word_addr_i[1][0]=waddr(A3,0);commit_wdata_i[1][0]=32'hC000_0025;#1;
  while(!(backend_cmd_valid_o&&backend_cmd_kind_o==K_STORE))begin if(commit_ready_o!=0)$fatal(1,"P25 ack before miss visibility");@(posedge clk);#1;end
  if(commit_ready_o!=0||store_count!=0)$fatal(1,"P25 store miss escaped");held_addr=backend_cmd_store_word_addr_o;held_data=backend_cmd_store_wdata_o;
  if(held_addr!=waddr(A1,1)||held_data!=32'hB000_0025)$fatal(1,"P25 exact miss payload");
  repeat(2)begin @(posedge clk);#1;if(!backend_cmd_valid_o||backend_cmd_kind_o!=K_STORE||backend_cmd_store_word_addr_o!=held_addr||backend_cmd_store_wdata_o!=held_data||commit_ready_o!=0)$fatal(1,"P25 miss payload/backpressure stability");end
  $display("PROD_SEAM_P25_STORE_MISS_BACKPRESSURE_STABLE=PASS");
  $display("PROD_SEAM_P25_COMMIT_ACK_HELD_BEFORE_MISS_VISIBILITY=PASS");
  @(negedge clk);backend_cmd_ready_i=1;#1;@(posedge clk);#1;
  while(!commit_ready_o[0])begin @(posedge clk);#1;end
  if(store_count!=1||mem[1][1]!=32'hB000_0025||commit_ready_o[1])$fatal(1,"P25 first commit completion");
  $display("PROD_SEAM_P25_STORE_MISS_WORD_VISIBILITY=PASS");
  // Keep valid asserted through the ACK posedge; ready is not itself a handshake.
  @(posedge clk);#1;@(negedge clk);commit_valid_i[0]=0;#1;

  // Port1 must now progress and publish its miss word exactly once.
  while(store_count!=2)begin @(posedge clk);#1;end
  while(!commit_ready_o[1])begin @(posedge clk);#1;end
  if(mem[3][0]!=32'hC000_0025)$fatal(1,"P25 second port visibility");
  // Keep valid asserted through the ACK posedge before withdrawing it.
  @(posedge clk);#1;@(negedge clk);commit_valid_i[1]=0;#1;
  $display("PROD_SEAM_P25_ROUND_ROBIN_COMMIT_SOURCE_PROGRESS=PASS");
  $display("PROD_SEAM_P25_EXACTLY_ONCE_MISS_WRITE=PASS");

  // Hit lane stayed dirty in L2 and needed no write-through.
  reads_before=read_count;req(2'd1,A0);wait_resp(2'd1,A0,32'hA000_0025);if(read_count!=reads_before)$fatal(1,"P25 hit lane caused backend read");
  $display("PROD_SEAM_P25_RESIDENT_HIT_REMAINS_DIRTY_FASTPATH=PASS");

  // Miss lane later refills from the same visibility domain and must see new data.
  req(2'd2,A1);while(read_count!=reads_before+1)begin @(posedge clk);#1;end;if(last_read_line!=A1)$fatal(1,"P25 A1 read route");respond_last_read();wait_resp(2'd2,A1,32'hB000_0025);
  $display("PROD_SEAM_P25_POST_ACK_REFILL_OBSERVES_STORE_MISS=PASS");

  // Evict dirty A0; P23 writeback command must pass through typed boundary unchanged.
  req(2'd3,B0);while(wb_count!=1)begin @(posedge clk);#1;end
  if(last_wb_line!=A0||last_wb_data[1]!=32'hA000_0025||wb_source(last_wb_id)!=0)$fatal(1,"P25 wb passthrough payload");
  $display("PROD_SEAM_P25_P23_WRITEBACK_TYPED_PASSTHROUGH=PASS");
  wb_success(last_wb_id);while(read_count!=reads_before+2)begin @(posedge clk);#1;end;if(last_read_line!=B0)$fatal(1,"P25 replacement read");respond_last_read();wait_resp(2'd3,B0,mem[4][1]);
  repeat(2)@(posedge clk);#1;
  if(store_count!=2||wb_pending_count_o!=0||wb_active_count_o!=0||(|wb_busy_o)||(|dirty_present_o)||(|wb_terminal_failure_o)||(|recovery_active_o)||(|recovery_complete_pulse_o)||(|backend_wb_recovery_safe_ready_o)||commit_visibility_busy_o)$fatal(1,"P25 final state");
  for(i=0;i<S;i=i+1)if(wb_retry_count_o[i]!='0)$fatal(1,"P25 retry");if(line_resp_tag_error_o||line_resp_overflow_o||protocol_error_o)$fatal(1,"P25 diagnostics");
  $display("PROD_SEAM_P25_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS");$display("PROD_SEAM_P25_END_TO_END_BEHAVIOR=PASS");$finish;
 end
endmodule
