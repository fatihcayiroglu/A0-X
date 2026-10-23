`timescale 1ns/1ps
module a0_mc_noc_dirty_l2_unified_backend_subsystem_tb;
 localparam integer C=2,LT=2,CO=2,S=2,LANES=1,LW=2,SETS=2,WID=2,MR=0;
 localparam integer WSW=1,LAW=31,CIDW=1,GTW=3,RETRYW=1,LATW=3,BATW=4,BRTW=4,CNTW=2,HASH=1;
 logic clk,rst_n;
 logic[C-1:0]client_req_valid_i,client_req_ready_o;logic[LT-1:0]client_req_local_tag_i[0:C-1];logic[LAW-1:0]client_req_line_addr_i[0:C-1];
 logic[C-1:0]client_resp_valid_o;logic[LT-1:0]client_resp_local_tag_o[0:C-1];logic[LAW-1:0]client_resp_line_addr_o[0:C-1];logic client_resp_fault_o[0:C-1];logic[31:0]client_resp_data_o[0:C-1][0:LW-1];
 logic[S-1:0]slice_store_valid_i,slice_store_ready_o;logic[LANES-1:0]slice_store_lane_mask_i[0:S-1];logic[31:0]slice_store_word_addr_i[0:S-1][0:LANES-1],slice_store_wdata_i[0:S-1][0:LANES-1];logic[LANES-1:0]slice_store_hit_mask_o[0:S-1],slice_store_miss_mask_o[0:S-1];
 logic backend_cmd_valid_o,backend_cmd_ready_i,backend_cmd_write_o;logic[BRTW-1:0]backend_cmd_read_tag_o;logic[BATW-1:0]backend_cmd_wb_attempt_id_o;logic[LAW-1:0]backend_cmd_line_addr_o;logic[31:0]backend_cmd_data_o[0:LW-1];
 logic backend_read_resp_valid_i;logic[BRTW-1:0]backend_read_resp_tag_i;logic[LAW-1:0]backend_read_resp_line_addr_i;logic backend_read_resp_fault_i;logic[31:0]backend_read_resp_data_i[0:LW-1];
 logic backend_wb_status_valid_i;logic[BATW-1:0]backend_wb_status_attempt_id_i;logic backend_wb_status_success_i,backend_wb_status_retryable_i;logic[S-1:0]backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o;
 logic[S-1:0]dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o;logic[RETRYW-1:0]wb_retry_count_o[0:S-1];logic[CNTW-1:0]wb_pending_count_o,wb_active_count_o;logic line_resp_tag_error_o,line_resp_overflow_o,protocol_error_o;
 integer read_fire_count[0:S-1];logic[BRTW-1:0]last_read_tag[0:S-1];logic[LAW-1:0]last_read_line[0:S-1];integer wb_fire_count;logic[BATW-1:0]wb_id[0:S-1];integer i,w;
 localparam logic[LAW-1:0]A0=LAW'(0),A1=LAW'(1),B0=LAW'(4),B1=LAW'(5);
 a0_mc_noc_dirty_l2_unified_backend_subsystem #(.CLIENT_COUNT(C),.LOCAL_TAG_W(LT),.CLIENT_MAX_OUTSTANDING(CO),.SLICE_COUNT(S),.STORE_LANES_PER_SLICE(LANES),.LINE_WORDS(LW),.SET_COUNT_PER_SLICE(SETS),.WRITE_ID_W(WID),.MAX_WB_RETRIES(MR)) dut(.*);
 initial clk=0;always #5 clk=~clk;
 function automatic integer wb_source(input logic[BATW-1:0]id);wb_source=integer'(id)>>LATW;endfunction
 function automatic integer read_source(input logic[BRTW-1:0]id);read_source=integer'(id)>>GTW;endfunction
 function automatic logic[31:0]waddr(input logic[LAW-1:0]line,input integer off);waddr=(32'(line)<<WSW)+32'(off);endfunction
 always_ff @(posedge clk)begin integer src;
  if(!rst_n)begin wb_fire_count<=0;for(integer x=0;x<S;x=x+1)begin read_fire_count[x]<=0;last_read_tag[x]<='0;last_read_line[x]<='0;wb_id[x]<='0;end end
  else if(backend_cmd_valid_o&&backend_cmd_ready_i)begin
   if(backend_cmd_write_o)begin src=wb_source(backend_cmd_wb_attempt_id_o);if(src<0||src>=S)$fatal(1,"P23 wb source");wb_fire_count<=wb_fire_count+1;wb_id[src]<=backend_cmd_wb_attempt_id_o;
    if(src==0)begin if(backend_cmd_line_addr_o!=A0||backend_cmd_data_o[1]!=32'hA000_0000)$fatal(1,"P23 wb0 payload");end
    else begin if(backend_cmd_line_addr_o!=A1||backend_cmd_data_o[1]!=32'hB000_0001)$fatal(1,"P23 wb1 payload");end
   end else begin src=read_source(backend_cmd_read_tag_o);if(src<0||src>=S)$fatal(1,"P23 read source");read_fire_count[src]<=read_fire_count[src]+1;last_read_tag[src]<=backend_cmd_read_tag_o;last_read_line[src]<=backend_cmd_line_addr_o;if(backend_cmd_wb_attempt_id_o!='0||backend_cmd_data_o[0]!='0||backend_cmd_data_o[1]!='0)$fatal(1,"P23 typed read payload");end
  end
 end
 task automatic clear;begin client_req_valid_i='0;slice_store_valid_i='0;backend_cmd_ready_i=1;backend_read_resp_valid_i=0;backend_read_resp_tag_i='0;backend_read_resp_line_addr_i='0;backend_read_resp_fault_i=0;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_wb_recovery_safe_valid_i='0;for(i=0;i<C;i=i+1)begin client_req_local_tag_i[i]='0;client_req_line_addr_i[i]='0;end for(i=0;i<S;i=i+1)begin slice_store_lane_mask_i[i]='0;slice_store_word_addr_i[i][0]='0;slice_store_wdata_i[i][0]='0;end for(w=0;w<LW;w=w+1)backend_read_resp_data_i[w]='0;end endtask
 task automatic reset;begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
 task automatic request_one(input logic client,input logic[LT-1:0]tag,input logic[LAW-1:0]line);begin @(negedge clk);client_req_valid_i[client]=1;client_req_local_tag_i[client]=tag;client_req_line_addr_i[client]=line;#1;while(!client_req_ready_o[client])begin @(posedge clk);@(negedge clk);#1;end @(posedge clk);@(negedge clk);client_req_valid_i[client]=0;#1;end endtask
 task automatic respond_and_expect(input logic slice,input logic client,input logic[LT-1:0]tag,input logic[LAW-1:0]line,input logic[31:0]base);begin @(negedge clk);backend_read_resp_valid_i=1;backend_read_resp_tag_i=last_read_tag[slice];backend_read_resp_line_addr_i=last_read_line[slice];backend_read_resp_fault_i=0;for(w=0;w<LW;w=w+1)backend_read_resp_data_i[w]=base+32'(w);#1;@(posedge clk);@(negedge clk);backend_read_resp_valid_i=0;#1;while(!client_resp_valid_o[client])begin @(posedge clk);#1;end if(client_resp_local_tag_o[client]!=tag||client_resp_line_addr_o[client]!=line||client_resp_fault_o[client]||client_resp_data_o[client][0]!=base)$fatal(1,"P23 client restore");@(posedge clk);#1;end endtask
 task automatic store_hit(input logic slice,input logic[LAW-1:0]line,input logic[31:0]value);begin @(negedge clk);slice_store_valid_i[slice]=1;slice_store_lane_mask_i[slice][0]=1;slice_store_word_addr_i[slice][0]=waddr(line,1);slice_store_wdata_i[slice][0]=value;#1;if(!slice_store_ready_o[slice]||!slice_store_hit_mask_o[slice][0]||slice_store_miss_mask_o[slice][0])$fatal(1,"P23 store hit");@(posedge clk);@(negedge clk);slice_store_valid_i[slice]=0;slice_store_lane_mask_i[slice][0]=0;#1;end endtask
 task automatic wb_success(input logic[BATW-1:0]id);begin @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=id;backend_wb_status_success_i=1;backend_wb_status_retryable_i=0;#1;@(posedge clk);@(negedge clk);backend_wb_status_valid_i=0;backend_wb_status_success_i=0;#1;end endtask
 initial begin
  reset();if((A0[0]^A0[HASH])!=0||(A1[0]^A1[HASH])!=1||(B0[0]^B0[HASH])!=0||(B1[0]^B1[HASH])!=1)$fatal(1,"P23 hash assumptions");
  request_one(0,2'd1,A0);while(read_fire_count[0]!=1)begin @(posedge clk);#1;end;if(last_read_line[0]!=A0||last_read_tag[0][GTW-1 -: CIDW]!=0)$fatal(1,"P23 route0");respond_and_expect(0,0,2'd1,A0,32'h1000);
  request_one(1,2'd2,A1);while(read_fire_count[1]!=1)begin @(posedge clk);#1;end;if(last_read_line[1]!=A1||last_read_tag[1][GTW-1 -: CIDW]!=1)$fatal(1,"P23 route1");respond_and_expect(1,1,2'd2,A1,32'h1100);
  $display("PROD_SEAM_P23_UNIFIED_READ_HOME_SLICE_ROUTE=PASS");$display("PROD_SEAM_P23_END_TO_END_REQUESTER_RESTORE=PASS");
  store_hit(0,A0,32'hA000_0000);store_hit(1,A1,32'hB000_0001);if(dirty_present_o!='1)$fatal(1,"P23 dirty");
  @(negedge clk);client_req_valid_i='1;client_req_local_tag_i[0]=2'd3;client_req_line_addr_i[0]=B0;client_req_local_tag_i[1]=2'd0;client_req_line_addr_i[1]=B1;#1;if(client_req_ready_o!='1)$fatal(1,"P23 repl ready");@(posedge clk);@(negedge clk);client_req_valid_i='0;#1;
  while(wb_pending_count_o!=CNTW'(2))begin @(posedge clk);#1;end;if(read_fire_count[0]!=1||read_fire_count[1]!=1)$fatal(1,"P23 dirty read escaped");
  while(wb_fire_count<2)begin @(posedge clk);#1;end;if(wb_active_count_o!=CNTW'(2)||wb_source(wb_id[0])!=0||wb_source(wb_id[1])!=1)$fatal(1,"P23 wb identity");
  $display("PROD_SEAM_P23_UNIFIED_WRITEBACK_COMMANDS=PASS");$display("PROD_SEAM_P23_DIRTY_REPLACEMENT_HELD_UNTIL_DURABLE=PASS");
  wb_success(wb_id[1]);while(read_fire_count[1]!=2)begin @(posedge clk);#1;end;if(read_fire_count[0]!=1||dirty_present_o[0]!==1'b1||dirty_present_o[1]!==1'b0)$fatal(1,"P23 OOO1");respond_and_expect(1,1,2'd0,B1,32'h2100);
  wb_success(wb_id[0]);while(read_fire_count[0]!=2)begin @(posedge clk);#1;end;if(dirty_present_o[0])$fatal(1,"P23 OOO0");respond_and_expect(0,0,2'd3,B0,32'h2000);
  $display("PROD_SEAM_P23_OOO_WRITE_STATUS_RELEASE_ISOLATION=PASS");$display("PROD_SEAM_P23_POST_WRITEBACK_READ_RESPONSE_RESTORE=PASS");
  if(wb_pending_count_o!=0||wb_active_count_o!=0||(|wb_busy_o)||(|dirty_present_o)||(|wb_terminal_failure_o)||(|recovery_active_o)||(|recovery_complete_pulse_o)||(|backend_wb_recovery_safe_ready_o))$fatal(1,"P23 final state");for(i=0;i<S;i=i+1)if(wb_retry_count_o[i]!='0)$fatal(1,"P23 retry");if(line_resp_tag_error_o||line_resp_overflow_o||protocol_error_o)$fatal(1,"P23 diagnostics");
  $display("PROD_SEAM_P23_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS");$display("PROD_SEAM_P23_END_TO_END_BEHAVIOR=PASS");$finish;
 end
endmodule
