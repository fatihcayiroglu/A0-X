`timescale 1ns/1ps
module a0_l2_multislice_recoverable_writeback_subsystem_tb;
 localparam integer SLICE_COUNT=3,STORE_LANES=1,LINE_WORDS=2,SET_COUNT=2,GLOBAL_TAG_W=4,WRITE_ID_W=2,MAX_WB_RETRIES=0;
 localparam integer WORD_SELECT_W=$clog2(LINE_WORDS),LINE_ADDR_W=32-WORD_SELECT_W,RETRY_W=1,LOCAL_ATTEMPT_ID_W=3,SLICE_ID_W=2,BACKEND_ATTEMPT_ID_W=5,COUNT_W=2;
 logic clk,rst_n;
 logic[SLICE_COUNT-1:0] line_req_valid_i,line_req_ready_o;logic[GLOBAL_TAG_W-1:0]line_req_global_tag_i[0:SLICE_COUNT-1];logic[LINE_ADDR_W-1:0]line_req_line_addr_i[0:SLICE_COUNT-1];
 logic[SLICE_COUNT-1:0]line_mem_req_valid_o,line_mem_req_ready_i;logic[GLOBAL_TAG_W-1:0]line_mem_req_global_tag_o[0:SLICE_COUNT-1];logic[LINE_ADDR_W-1:0]line_mem_req_line_addr_o[0:SLICE_COUNT-1];
 logic[SLICE_COUNT-1:0]line_mem_resp_valid_i;logic[GLOBAL_TAG_W-1:0]line_mem_resp_global_tag_i[0:SLICE_COUNT-1];logic[LINE_ADDR_W-1:0]line_mem_resp_line_addr_i[0:SLICE_COUNT-1];logic[SLICE_COUNT-1:0]line_mem_resp_fault_i;logic[31:0]line_mem_resp_data_i[0:SLICE_COUNT-1][0:LINE_WORDS-1];
 logic[SLICE_COUNT-1:0]line_resp_valid_o;logic[GLOBAL_TAG_W-1:0]line_resp_global_tag_o[0:SLICE_COUNT-1];logic[LINE_ADDR_W-1:0]line_resp_line_addr_o[0:SLICE_COUNT-1];logic[SLICE_COUNT-1:0]line_resp_fault_o;logic[31:0]line_resp_data_o[0:SLICE_COUNT-1][0:LINE_WORDS-1];
 logic[SLICE_COUNT-1:0]store_valid_i,store_ready_o;logic[STORE_LANES-1:0]store_lane_mask_i[0:SLICE_COUNT-1];logic[31:0]store_word_addr_i[0:SLICE_COUNT-1][0:STORE_LANES-1],store_wdata_i[0:SLICE_COUNT-1][0:STORE_LANES-1];logic[STORE_LANES-1:0]store_hit_mask_o[0:SLICE_COUNT-1],store_miss_mask_o[0:SLICE_COUNT-1];
 logic backend_wb_valid_o,backend_wb_ready_i;logic[BACKEND_ATTEMPT_ID_W-1:0]backend_wb_attempt_id_o;logic[LINE_ADDR_W-1:0]backend_wb_line_addr_o;logic[31:0]backend_wb_data_o[0:LINE_WORDS-1];
 logic backend_wb_status_valid_i;logic[BACKEND_ATTEMPT_ID_W-1:0]backend_wb_status_attempt_id_i;logic backend_wb_status_success_i,backend_wb_status_retryable_i;
 logic[SLICE_COUNT-1:0]backend_wb_recovery_safe_valid_i,backend_wb_recovery_safe_ready_o,dirty_present_o,wb_busy_o,wb_terminal_failure_o,recovery_active_o,recovery_complete_pulse_o;logic[RETRY_W-1:0]wb_retry_count_o[0:SLICE_COUNT-1];logic[COUNT_W-1:0]wb_pending_count_o,wb_active_count_o;logic protocol_error_o;
 integer s,w,fire_count;integer recovery_pulses[0:SLICE_COUNT-1];integer read_fire_count[0:SLICE_COUNT-1];
 logic[BACKEND_ATTEMPT_ID_W-1:0] issued_id[0:SLICE_COUNT-1];
 a0_l2_multislice_recoverable_writeback_subsystem #(.SLICE_COUNT(SLICE_COUNT),.STORE_LANES(STORE_LANES),.LINE_WORDS(LINE_WORDS),.SET_COUNT(SET_COUNT),.GLOBAL_TAG_W(GLOBAL_TAG_W),.WRITE_ID_W(WRITE_ID_W),.MAX_WB_RETRIES(MAX_WB_RETRIES)) dut(.*);
 initial clk=0;always #5 clk=~clk;
 always_ff @(posedge clk)begin
  if(!rst_n)begin fire_count<=0;for(integer x=0;x<SLICE_COUNT;x=x+1)begin recovery_pulses[x]<=0;read_fire_count[x]<=0;end end
  else begin
   if(backend_wb_valid_o&&backend_wb_ready_i)begin
    issued_id[integer'(backend_wb_attempt_id_o[BACKEND_ATTEMPT_ID_W-1 -: SLICE_ID_W])]<=backend_wb_attempt_id_o;fire_count<=fire_count+1;
   end
   for(integer x=0;x<SLICE_COUNT;x=x+1)begin if(recovery_complete_pulse_o[x])recovery_pulses[x]<=recovery_pulses[x]+1;if(line_mem_req_valid_o[x]&&line_mem_req_ready_i[x])read_fire_count[x]<=read_fire_count[x]+1;end
  end
 end
 function automatic logic[LINE_ADDR_W-1:0] aline(input integer slice);aline=LINE_ADDR_W'(slice*4);endfunction
 function automatic logic[LINE_ADDR_W-1:0] bline(input integer slice);bline=LINE_ADDR_W'(slice*4+2);endfunction
 function automatic logic[31:0] waddr(input logic[LINE_ADDR_W-1:0] line,input integer off);waddr=(32'(line)<<WORD_SELECT_W)+32'(off);endfunction
 function automatic integer source_of(input logic[BACKEND_ATTEMPT_ID_W-1:0] id);source_of=integer'(id)>>LOCAL_ATTEMPT_ID_W;endfunction
 task automatic clear;begin
  line_req_valid_i='0;line_mem_req_ready_i='1;line_mem_resp_valid_i='0;line_mem_resp_fault_i='0;store_valid_i='0;backend_wb_ready_i=0;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;backend_wb_recovery_safe_valid_i='0;
  for(s=0;s<SLICE_COUNT;s=s+1)begin line_req_global_tag_i[s]='0;line_req_line_addr_i[s]='0;line_mem_resp_global_tag_i[s]='0;line_mem_resp_line_addr_i[s]='0;store_lane_mask_i[s]='0;store_word_addr_i[s][0]='0;store_wdata_i[s][0]='0;issued_id[s]='0;for(w=0;w<LINE_WORDS;w=w+1)line_mem_resp_data_i[s][w]='0;end
 end endtask
 task automatic reset;begin rst_n=0;clear();repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
 task automatic miss(input integer slice,input logic[GLOBAL_TAG_W-1:0] tag,input logic[LINE_ADDR_W-1:0] line);begin
  @(negedge clk);line_req_valid_i[slice]=1;line_req_global_tag_i[slice]=tag;line_req_line_addr_i[slice]=line;#1;if(!line_req_ready_o[slice]||!line_mem_req_valid_o[slice]||line_mem_req_global_tag_o[slice]!=tag||line_mem_req_line_addr_o[slice]!=line)$fatal(1,"P21 miss slice %0d",slice);@(posedge clk);@(negedge clk);line_req_valid_i[slice]=0;#1;
 end endtask
 task automatic refill(input integer slice,input logic[GLOBAL_TAG_W-1:0] tag,input logic[LINE_ADDR_W-1:0] line,input logic[31:0] base);begin
  @(negedge clk);line_mem_resp_valid_i[slice]=1;line_mem_resp_global_tag_i[slice]=tag;line_mem_resp_line_addr_i[slice]=line;for(w=0;w<LINE_WORDS;w=w+1)line_mem_resp_data_i[slice][w]=base+32'(w);#1;if(!line_resp_valid_o[slice]||line_resp_fault_o[slice]||line_resp_global_tag_o[slice]!=tag||line_resp_line_addr_o[slice]!=line||line_resp_data_o[slice][0]!=base)$fatal(1,"P21 refill slice %0d",slice);@(posedge clk);@(negedge clk);line_mem_resp_valid_i[slice]=0;#1;
 end endtask
 task automatic dirty(input integer slice,input logic[31:0] value);begin
  @(negedge clk);store_valid_i[slice]=1;store_lane_mask_i[slice][0]=1;store_word_addr_i[slice][0]=waddr(aline(slice),1);store_wdata_i[slice][0]=value;#1;if(!store_ready_o[slice]||!store_hit_mask_o[slice][0]||store_miss_mask_o[slice][0])$fatal(1,"P21 dirty slice %0d",slice);@(posedge clk);@(negedge clk);store_valid_i[slice]=0;store_lane_mask_i[slice][0]=0;#1;
 end endtask
 task automatic start_evict(input integer slice,input logic[GLOBAL_TAG_W-1:0] tag);begin
  line_req_valid_i[slice]=1;line_req_global_tag_i[slice]=tag;line_req_line_addr_i[slice]=bline(slice);
 end endtask
 task automatic send_status(input logic[BACKEND_ATTEMPT_ID_W-1:0] id,input logic success,input logic retryable);begin
  @(negedge clk);backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=id;backend_wb_status_success_i=success;backend_wb_status_retryable_i=retryable;#1;@(posedge clk);@(negedge clk);backend_wb_status_valid_i=0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;#1;
 end endtask
 initial begin
  logic[BACKEND_ATTEMPT_ID_W-1:0] fail_id,reissue_id;integer src;
  reset();
  for(s=0;s<SLICE_COUNT;s=s+1)begin miss(s,GLOBAL_TAG_W'(s+1),aline(s));refill(s,GLOBAL_TAG_W'(s+1),aline(s),32'h1000+32'(s*16));dirty(s,32'hA000_0000+32'(s));end
  if(dirty_present_o!='1)$fatal(1,"P21 initial dirty vector %b",dirty_present_o);$display("PROD_SEAM_P21_MULTI_SLICE_DIRTY_VICTIMS=PASS");
  // Capture three conflicting replacements while unified backend is backpressured.
  @(negedge clk);for(s=0;s<SLICE_COUNT;s=s+1)start_evict(s,GLOBAL_TAG_W'(8+s));#1;if(line_req_ready_o!='1)$fatal(1,"P21 evict accepts %b",line_req_ready_o);@(posedge clk);@(negedge clk);line_req_valid_i='0;#1;
  while(wb_pending_count_o!=COUNT_W'(SLICE_COUNT))begin @(posedge clk);#1;end
  if(!backend_wb_valid_o||source_of(backend_wb_attempt_id_o)!=0)$fatal(1,"P21 initial fair source");$display("PROD_SEAM_P21_SHARED_QUEUE_CAPTURE=PASS");
  backend_wb_ready_i=1;
  // Observe fair 0,1,2 issue order; all become concurrently live.
  for(s=0;s<SLICE_COUNT;s=s+1)begin
   while(!(backend_wb_valid_o&&backend_wb_ready_i))begin @(posedge clk);#1;end
   src=source_of(backend_wb_attempt_id_o);if(src!=s)$fatal(1,"P21 RR order expected %0d got %0d",s,src);@(posedge clk);#1;
  end
  if(wb_active_count_o!=COUNT_W'(SLICE_COUNT)||fire_count!=SLICE_COUNT)$fatal(1,"P21 live attempts active=%0d fire=%0d pending=%0d",wb_active_count_o,fire_count,wb_pending_count_o);$display("PROD_SEAM_P21_FAIR_MULTI_SLICE_ISSUE=PASS");$display("PROD_SEAM_P21_MULTIPLE_LIVE_ATTEMPTS=PASS");
  // OOO: slice2 succeeds, slice1 terminal-fails, slice0 succeeds.
  send_status(issued_id[2],1,0);if(dirty_present_o[2])$fatal(1,"P21 slice2 not released");if(!dirty_present_o[0]||!dirty_present_o[1])$fatal(1,"P21 peer released early");
  fail_id=issued_id[1];send_status(fail_id,0,0);@(posedge clk);#1;if(!dirty_present_o[1]||!wb_terminal_failure_o[1]||!recovery_active_o[1])$fatal(1,"P21 failed slice did not retain");if(recovery_active_o[0]||recovery_active_o[2]||wb_terminal_failure_o[0]||wb_terminal_failure_o[2])$fatal(1,"P21 peer recovery contamination");
  send_status(issued_id[0],1,0);if(dirty_present_o[0]||!dirty_present_o[1])$fatal(1,"P21 per-slice success release");
  $display("PROD_SEAM_P21_OOO_STATUS_RESTORE=PASS");$display("PROD_SEAM_P21_SUCCESS_ONLY_PER_SLICE_RELEASE=PASS");$display("PROD_SEAM_P21_FAILURE_ISOLATION=PASS");
  // Allow successful slices' retained replacement reads to issue and refill.
  repeat(2)@(posedge clk);#1;
  if(read_fire_count[0]!=2||read_fire_count[2]!=2||read_fire_count[1]!=1)$fatal(1,"P21 replacement release counts %0d %0d %0d",read_fire_count[0],read_fire_count[1],read_fire_count[2]);
  refill(0,GLOBAL_TAG_W'(8),bline(0),32'h2000);refill(2,GLOBAL_TAG_W'(10),bline(2),32'h2200);
  // Only failed slice accepts recovery-safe; peers remain unaffected.
  if(!backend_wb_recovery_safe_ready_o[1]||backend_wb_recovery_safe_ready_o[0]||backend_wb_recovery_safe_ready_o[2])$fatal(1,"P21 safe-ready isolation");
  @(negedge clk);backend_wb_recovery_safe_valid_i[1]=1;#1;@(posedge clk);@(negedge clk);backend_wb_recovery_safe_valid_i[1]=0;#1;
  if(!dirty_present_o[1])$fatal(1,"P21 recovery synthetic clean");
  while(!(backend_wb_valid_o&&backend_wb_ready_i))begin @(posedge clk);#1;end
  if(source_of(backend_wb_attempt_id_o)!=1||backend_wb_line_addr_o!=aline(1)||backend_wb_data_o[1]!=(32'hA000_0001))$fatal(1,"P21 exact recovery reissue");reissue_id=backend_wb_attempt_id_o;
  @(posedge clk);#1;send_status(reissue_id,1,0);
  if(dirty_present_o[1]||wb_terminal_failure_o[1]||recovery_active_o[1])$fatal(1,"P21 recovery success did not release");
  repeat(2)@(posedge clk);#1;if(read_fire_count[1]!=2)$fatal(1,"P21 recovered replacement not released count=%0d",read_fire_count[1]);refill(1,GLOBAL_TAG_W'(9),bline(1),32'h2100);
  if(recovery_pulses[1]!=1||recovery_pulses[0]!=0||recovery_pulses[2]!=0)$fatal(1,"P21 recovery pulse isolation");
  if(protocol_error_o)$fatal(1,"P21 protocol error");
  if(wb_pending_count_o!=0||wb_active_count_o!=0||(|dirty_present_o)||(|wb_busy_o))$fatal(1,"P21 final drain");for(s=0;s<SLICE_COUNT;s=s+1)if(wb_retry_count_o[s]!='0)$fatal(1,"P21 retry count nonzero slice %0d",s);
  $display("PROD_SEAM_P21_RECOVERY_SAFE_PER_SLICE=PASS");$display("PROD_SEAM_P21_EXACT_VICTIM_RECOVERY_REISSUE=PASS");$display("PROD_SEAM_P21_PEER_PROGRESS_DURING_FAILURE=PASS");$display("PROD_SEAM_P21_FINAL_DRAIN=PASS");$display("PROD_SEAM_P21_BEHAVIOR=PASS");$finish;
 end
endmodule
