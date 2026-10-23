`timescale 1ns/1ps
module a0_mc_noc_multislice_recoverable_writeback_subsystem_tb;
 localparam integer CLIENT_COUNT=2,LOCAL_TAG_W=2,CLIENT_MAX_OUTSTANDING=2,SLICE_COUNT=2,STORE_LANES_PER_SLICE=1,LINE_WORDS=2,SET_COUNT_PER_SLICE=2,WRITE_ID_W=2,MAX_WB_RETRIES=0;
 localparam integer WORD_SELECT_W=1,LINE_ADDR_W=31,CLIENT_ID_W=1,GLOBAL_TAG_W=3,SLICE_HASH_SHIFT=1,RETRY_W=1,LOCAL_ATTEMPT_ID_W=3,BACKEND_ATTEMPT_ID_W=4,COUNT_W=2;
 logic clk,rst_n;
 logic[CLIENT_COUNT-1:0]client_req_valid_i,client_req_ready_o;logic[LOCAL_TAG_W-1:0]client_req_local_tag_i[0:CLIENT_COUNT-1];logic[LINE_ADDR_W-1:0]client_req_line_addr_i[0:CLIENT_COUNT-1];
 logic[CLIENT_COUNT-1:0]client_resp_valid_o;logic[LOCAL_TAG_W-1:0]client_resp_local_tag_o[0:CLIENT_COUNT-1];logic[LINE_ADDR_W-1:0]client_resp_line_addr_o[0:CLIENT_COUNT-1];logic client_resp_fault_o[0:CLIENT_COUNT-1];logic[31:0]client_resp_data_o[0:CLIENT_COUNT-1][0:LINE_WORDS-1];
 logic[SLICE_COUNT-1:0]slice_store_valid_i,slice_store_ready_o;logic[STORE_LANES_PER_SLICE-1:0]slice_store_lane_mask_i[0:SLICE_COUNT-1];logic[31:0]slice_store_word_addr_i[0:SLICE_COUNT-1][0:STORE_LANES_PER_SLICE-1],slice_store_wdata_i[0:SLICE_COUNT-1][0:STORE_LANES_PER_SLICE-1];logic[STORE_LANES_PER_SLICE-1:0]slice_store_hit_mask_o[0:SLICE_COUNT-1],slice_store_miss_mask_o[0:SLICE_COUNT-1];
 logic[SLICE_COUNT-1:0]line_mem_req_valid_o,line_mem_req_ready_i;logic[GLOBAL_TAG_W-1:0]line_mem_req_global_tag_o[0:SLICE_COUNT-1];logic[LINE_ADDR_W-1:0]line_mem_req_line_addr_o[0:SLICE_COUNT-1];logic[SLICE_COUNT-1:0]line_mem_resp_valid_i;logic[GLOBAL_TAG_W-1:0]line_mem_resp_global_tag_i[0:SLICE_COUNT-1];logic[LINE_ADDR_W-1:0]line_mem_resp_line_addr_i[0:SLICE_COUNT-1];logic[SLICE_COUNT-1:0]line_mem_resp_fault_i;logic[31:0]line_mem_resp_data_i[0:SLICE_COUNT-1][0:LINE_WORDS-1];
 logic backend_wb_valid_o,backend_wb_ready_i;logic[BACKEND_ATTEMPT_ID_W-1:0]backend_wb_attempt_id_o;logic[LINE_ADDR_W-1:0]backend_wb_line_addr_o;logic[31:0]backend_wb_data_o[0:LINE_WORDS-1];logic backend_wb_status_valid_i;logic[BACKEND_ATTEMPT_ID_W-1:0]backend_wb_status_attempt_id_i;logic backend_wb_status_success_i,backend_wb_status_retryable_i;logic[SLICE_COUNT-1:0]backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o;
 logic[SLICE_COUNT-1:0]dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o;logic[RETRY_W-1:0]wb_retry_count_o[0:SLICE_COUNT-1];logic[COUNT_W-1:0]wb_pending_count_o,wb_active_count_o;logic line_resp_tag_error_o,line_resp_overflow_o,protocol_error_o;
 integer s,w;integer read_fire_count[0:SLICE_COUNT-1];logic[GLOBAL_TAG_W-1:0]last_read_tag[0:SLICE_COUNT-1];logic[LINE_ADDR_W-1:0]last_read_line[0:SLICE_COUNT-1];integer wb_fire_count;logic[BACKEND_ATTEMPT_ID_W-1:0]wb_id[0:SLICE_COUNT-1];
 localparam logic[LINE_ADDR_W-1:0]A0=LINE_ADDR_W'(0),A1=LINE_ADDR_W'(1),B0=LINE_ADDR_W'(4),B1=LINE_ADDR_W'(5);
 a0_mc_noc_multislice_recoverable_writeback_subsystem #(.CLIENT_COUNT(CLIENT_COUNT),.LOCAL_TAG_W(LOCAL_TAG_W),.CLIENT_MAX_OUTSTANDING(CLIENT_MAX_OUTSTANDING),.SLICE_COUNT(SLICE_COUNT),.STORE_LANES_PER_SLICE(STORE_LANES_PER_SLICE),.LINE_WORDS(LINE_WORDS),.SET_COUNT_PER_SLICE(SET_COUNT_PER_SLICE),.WRITE_ID_W(WRITE_ID_W),.MAX_WB_RETRIES(MAX_WB_RETRIES)) dut(.*);
 initial clk=0;always #5 clk=~clk;
 function automatic integer source_of(input logic[BACKEND_ATTEMPT_ID_W-1:0] id);source_of=integer'(id)>>LOCAL_ATTEMPT_ID_W;endfunction
 function automatic logic[31:0]waddr(input logic[LINE_ADDR_W-1:0]line,input integer off);waddr=(32'(line)<<WORD_SELECT_W)+32'(off);endfunction
 always_ff @(posedge clk)begin
  if(!rst_n)begin wb_fire_count<=0;for(integer x=0;x<SLICE_COUNT;x=x+1)begin read_fire_count[x]<=0;last_read_tag[x]<='0;last_read_line[x]<='0;wb_id[x]<='0;end end
  else begin
   for(integer x=0;x<SLICE_COUNT;x=x+1)if(line_mem_req_valid_o[x]&&line_mem_req_ready_i[x])begin read_fire_count[x]<=read_fire_count[x]+1;last_read_tag[x]<=line_mem_req_global_tag_o[x];last_read_line[x]<=line_mem_req_line_addr_o[x];end
   if(backend_wb_valid_o&&backend_wb_ready_i)begin wb_fire_count<=wb_fire_count+1;wb_id[source_of(backend_wb_attempt_id_o)]<=backend_wb_attempt_id_o;
    if(source_of(backend_wb_attempt_id_o)==0)begin if(backend_wb_line_addr_o!=A0||backend_wb_data_o[1]!=32'hA000_0000)$fatal(1,"P22 slice0 victim payload");end
    else begin if(backend_wb_line_addr_o!=A1||backend_wb_data_o[1]!=32'hB000_0001)$fatal(1,"P22 slice1 victim payload");end
   end
  end
 end
 task automatic clear;begin
  client_req_valid_i='0;slice_store_valid_i='0;line_mem_req_ready_i='1;line_mem_resp_valid_i='0;line_mem_resp_fault_i='0;backend_wb_ready_i=0;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_wb_recovery_safe_valid_i='0;
  for(s=0;s<CLIENT_COUNT;s=s+1)begin client_req_local_tag_i[s]='0;client_req_line_addr_i[s]='0;end
  for(s=0;s<SLICE_COUNT;s=s+1)begin slice_store_lane_mask_i[s]='0;slice_store_word_addr_i[s][0]='0;slice_store_wdata_i[s][0]='0;line_mem_resp_global_tag_i[s]='0;line_mem_resp_line_addr_i[s]='0;for(w=0;w<LINE_WORDS;w=w+1)line_mem_resp_data_i[s][w]='0;end
 end endtask
 task automatic reset;begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
 task automatic request_one(input logic client,input logic[LOCAL_TAG_W-1:0]tag,input logic[LINE_ADDR_W-1:0]line);begin
  @(negedge clk);client_req_valid_i[client]=1;client_req_local_tag_i[client]=tag;client_req_line_addr_i[client]=line;#1;
  while(!client_req_ready_o[client])begin @(posedge clk);@(negedge clk);#1;end
  @(posedge clk);@(negedge clk);client_req_valid_i[client]=0;#1;
 end endtask
 task automatic refill_and_expect(input logic slice,input logic client,input logic[LOCAL_TAG_W-1:0]tag,input logic[LINE_ADDR_W-1:0]line,input logic[31:0]base);begin
  @(negedge clk);line_mem_resp_valid_i[slice]=1;line_mem_resp_global_tag_i[slice]=last_read_tag[slice];line_mem_resp_line_addr_i[slice]=last_read_line[slice];for(w=0;w<LINE_WORDS;w=w+1)line_mem_resp_data_i[slice][w]=base+32'(w);#1;
  @(posedge clk);@(negedge clk);line_mem_resp_valid_i[slice]=0;#1;
  while(!client_resp_valid_o[client])begin @(posedge clk);#1;end
  if(client_resp_local_tag_o[client]!=tag||client_resp_line_addr_o[client]!=line||client_resp_fault_o[client]||client_resp_data_o[client][0]!=base)$fatal(1,"P22 client response restore c%0d",client);
  @(posedge clk);#1;
 end endtask
 task automatic store_hit(input logic slice,input logic[LINE_ADDR_W-1:0]line,input logic[31:0]value);begin
  @(negedge clk);slice_store_valid_i[slice]=1;slice_store_lane_mask_i[slice][0]=1;slice_store_word_addr_i[slice][0]=waddr(line,1);slice_store_wdata_i[slice][0]=value;#1;
  if(!slice_store_ready_o[slice]||!slice_store_hit_mask_o[slice][0]||slice_store_miss_mask_o[slice][0])$fatal(1,"P22 store hit slice %0d",slice);
  @(posedge clk);@(negedge clk);slice_store_valid_i[slice]=0;slice_store_lane_mask_i[slice][0]=0;#1;
 end endtask
 task automatic send_wb_success(input logic[BACKEND_ATTEMPT_ID_W-1:0]id);begin
  @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=id;backend_wb_status_success_i=1;backend_wb_status_retryable_i=0;#1;@(posedge clk);@(negedge clk);backend_wb_status_valid_i=0;backend_wb_status_success_i=0;#1;
 end endtask
 initial begin
  reset();
  if((A0[0]^A0[SLICE_HASH_SHIFT])!=0||(A1[0]^A1[SLICE_HASH_SHIFT])!=1||(B0[0]^B0[SLICE_HASH_SHIFT])!=0||(B1[0]^B1[SLICE_HASH_SHIFT])!=1)$fatal(1,"P22 address hash assumptions");
  request_one(0,2'd1,A0);while(read_fire_count[0]!=1)begin @(posedge clk);#1;end;if(last_read_line[0]!=A0||last_read_tag[0][GLOBAL_TAG_W-1 -: CLIENT_ID_W]!=0)$fatal(1,"P22 first route0");refill_and_expect(0,0,2'd1,A0,32'h1000);
  request_one(1,2'd2,A1);while(read_fire_count[1]!=1)begin @(posedge clk);#1;end;if(last_read_line[1]!=A1||last_read_tag[1][GLOBAL_TAG_W-1 -: CLIENT_ID_W]!=1)$fatal(1,"P22 first route1");refill_and_expect(1,1,2'd2,A1,32'h1100);
  $display("PROD_SEAM_P22_CLIENT_HOME_SLICE_ROUTING=PASS");$display("PROD_SEAM_P22_INITIAL_RESPONSE_IDENTITY_RESTORE=PASS");
  store_hit(0,A0,32'hA000_0000);store_hit(1,A1,32'hB000_0001);if(dirty_present_o!='1)$fatal(1,"P22 dirty vector");$display("PROD_SEAM_P22_SLICE_LOCAL_DIRTY_UPDATE=PASS");
  // Concurrent clients target dirty same-set replacements on different home slices.
  @(negedge clk);client_req_valid_i='1;client_req_local_tag_i[0]=2'd3;client_req_line_addr_i[0]=B0;client_req_local_tag_i[1]=2'd0;client_req_line_addr_i[1]=B1;#1;
  if(client_req_ready_o!='1)$fatal(1,"P22 concurrent replacement ready %b",client_req_ready_o);@(posedge clk);@(negedge clk);client_req_valid_i='0;#1;
  while(wb_pending_count_o!=COUNT_W'(2))begin @(posedge clk);#1;end
  if(read_fire_count[0]!=1||read_fire_count[1]!=1)$fatal(1,"P22 dirty replacement read escaped before durable success");$display("PROD_SEAM_P22_DIRTY_REPLACEMENT_HELD=PASS");
  backend_wb_ready_i=1;while(wb_fire_count<2)begin @(posedge clk);#1;end
  if(wb_active_count_o!=COUNT_W'(2)||source_of(wb_id[0])!=0||source_of(wb_id[1])!=1)$fatal(1,"P22 wb identity/live");$display("PROD_SEAM_P22_UNIFIED_WRITEBACK_IDENTITY=PASS");
  // Out-of-order durable completion: slice1 first. Only client1 replacement may proceed.
  send_wb_success(wb_id[1]);while(read_fire_count[1]!=2)begin @(posedge clk);#1;end;if(read_fire_count[0]!=1||dirty_present_o[0]!==1'b1||dirty_present_o[1]!==1'b0)$fatal(1,"P22 OOO release isolation");refill_and_expect(1,1,2'd0,B1,32'h2100);
  $display("PROD_SEAM_P22_OOO_SUCCESS_RELEASE_ISOLATION=PASS");
  send_wb_success(wb_id[0]);while(read_fire_count[0]!=2)begin @(posedge clk);#1;end;if(dirty_present_o[0])$fatal(1,"P22 slice0 dirty not released");refill_and_expect(0,0,2'd3,B0,32'h2000);
  $display("PROD_SEAM_P22_REPLACEMENT_REQUESTER_IDENTITY_PRESERVED=PASS");$display("PROD_SEAM_P22_POST_WRITEBACK_RESPONSE_RESTORE=PASS");
  if(wb_pending_count_o!=0||wb_active_count_o!=0||(|wb_busy_o)||(|dirty_present_o)||(|wb_terminal_failure_o)||(|recovery_active_o)||(|recovery_complete_pulse_o)||(|backend_wb_recovery_safe_ready_o))$fatal(1,"P22 final state");
  for(s=0;s<SLICE_COUNT;s=s+1)if(wb_retry_count_o[s]!='0)$fatal(1,"P22 retry count");
  if(line_resp_tag_error_o||line_resp_overflow_o||protocol_error_o)$fatal(1,"P22 diagnostics");
  $display("PROD_SEAM_P22_FINAL_DRAIN_DIAGNOSTIC_CLEAN=PASS");$display("PROD_SEAM_P22_BEHAVIOR=PASS");$finish;
 end
endmodule
