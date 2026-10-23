`timescale 1ns/1ps
module a0_l2_unified_line_backend_arbiter_tb;
 localparam integer N=3,LW=2,TW=3,AW=8,WW=5,PIDW=2,RTW=PIDW+TW;
 logic clk,rst_n;
 logic[N-1:0] read_valid_i,read_ready_o; logic[TW-1:0] read_global_tag_i[0:N-1]; logic[AW-1:0] read_line_addr_i[0:N-1];
 logic wb_valid_i,wb_ready_o; logic[WW-1:0]wb_attempt_id_i;logic[AW-1:0]wb_line_addr_i;logic[31:0]wb_data_i[0:LW-1];
 logic backend_cmd_valid_o,backend_cmd_ready_i,backend_cmd_write_o;logic[RTW-1:0]backend_cmd_read_tag_o;logic[WW-1:0]backend_cmd_wb_attempt_id_o;logic[AW-1:0]backend_cmd_line_addr_o;logic[31:0]backend_cmd_data_o[0:LW-1];
 logic backend_read_resp_valid_i;logic[RTW-1:0]backend_read_resp_tag_i;logic[AW-1:0]backend_read_resp_line_addr_i;logic backend_read_resp_fault_i;logic[31:0]backend_read_resp_data_i[0:LW-1];
 logic[N-1:0]read_resp_valid_o;logic[TW-1:0]read_resp_global_tag_o[0:N-1];logic[AW-1:0]read_resp_line_addr_o[0:N-1];logic[N-1:0]read_resp_fault_o;logic[31:0]read_resp_data_o[0:N-1][0:LW-1];
 logic backend_wb_status_valid_i;logic[WW-1:0]backend_wb_status_attempt_id_i;logic backend_wb_status_success_i,backend_wb_status_retryable_i;logic wb_status_valid_o;logic[WW-1:0]wb_status_attempt_id_o;logic wb_status_success_o,wb_status_retryable_o,read_resp_protocol_error_o;
 integer fire_count; logic fire_write[0:3];logic[1:0]fire_port[0:3];logic[AW-1:0]fire_line[0:3];
 a0_l2_unified_line_backend_arbiter #(.READ_PORT_COUNT(N),.LINE_WORDS(LW),.GLOBAL_TAG_W(TW),.LINE_ADDR_W(AW),.WB_ATTEMPT_ID_W(WW)) dut(.*);
 initial clk=0;always #5 clk=~clk;
 always_ff @(posedge clk) if(!rst_n) fire_count<=0; else if(backend_cmd_valid_o&&backend_cmd_ready_i)begin
   fire_write[fire_count]<=backend_cmd_write_o; fire_port[fire_count]<=backend_cmd_read_tag_o[RTW-1 -: PIDW];fire_line[fire_count]<=backend_cmd_line_addr_o;if(backend_cmd_write_o && (backend_cmd_wb_attempt_id_o!=5'h15||backend_cmd_data_o[0]!=32'hDEAD0000||backend_cmd_data_o[1]!=32'hBEEF0001))$fatal(1,"P23 wb payload identity");fire_count<=fire_count+1;
 end
 task automatic reset;integer i;begin rst_n=0;read_valid_i='0;wb_valid_i=0;backend_cmd_ready_i=0;backend_read_resp_valid_i=0;backend_read_resp_tag_i='0;backend_read_resp_line_addr_i='0;backend_read_resp_fault_i=0;backend_wb_status_valid_i=0;backend_wb_status_attempt_id_i='0;backend_wb_status_success_i=0;backend_wb_status_retryable_i=0;wb_attempt_id_i=5'h15;wb_line_addr_i=8'hE0;wb_data_i[0]=32'hDEAD0000;wb_data_i[1]=32'hBEEF0001;for(i=0;i<N;i=i+1)begin read_global_tag_i[i]=TW'(i+1);read_line_addr_i[i]=8'h10+8'(i);end for(i=0;i<LW;i=i+1)backend_read_resp_data_i[i]='0;repeat(3)@(posedge clk);@(negedge clk);rst_n=1;#1;end endtask
 initial begin logic hold_w;logic[RTW-1:0]hold_t;logic[AW-1:0]hold_a;
   reset();
   // Four simultaneous contenders prove round-robin order: R0,R1,R2,WB.
   read_valid_i='1;wb_valid_i=1;#1;if(read_ready_o!=3'b001)$fatal(1,"P23 initial grant");
   @(posedge clk);@(negedge clk);if(!backend_cmd_valid_o||backend_cmd_write_o||backend_cmd_line_addr_o!=8'h10)$fatal(1,"P23 first capture");
   read_valid_i[0]=0;hold_w=backend_cmd_write_o;hold_t=backend_cmd_read_tag_o;hold_a=backend_cmd_line_addr_o;
   repeat(3)begin @(posedge clk);@(negedge clk);if(!backend_cmd_valid_o||backend_cmd_write_o!=hold_w||backend_cmd_read_tag_o!=hold_t||backend_cmd_line_addr_o!=hold_a)$fatal(1,"P23 backpressure stability");end
   $display("PROD_SEAM_P23_BACKPRESSURE_PAYLOAD_STABLE=PASS");
   backend_cmd_ready_i=1;
   // Deassert each source after arbiter accepts it into its hold register.
   while(!read_ready_o[1])begin @(posedge clk);@(negedge clk);#1;end @(posedge clk);@(negedge clk);read_valid_i[1]=0;#1;
   while(!read_ready_o[2])begin @(posedge clk);@(negedge clk);#1;end @(posedge clk);@(negedge clk);read_valid_i[2]=0;#1;
   while(!wb_ready_o)begin @(posedge clk);@(negedge clk);#1;end @(posedge clk);@(negedge clk);wb_valid_i=0;#1;
   while(fire_count<4)begin @(posedge clk);#1;end
   if(fire_write[0]||fire_port[0]!=0||fire_line[0]!=8'h10)$fatal(1,"P23 order0");
   if(fire_write[1]||fire_port[1]!=1||fire_line[1]!=8'h11)$fatal(1,"P23 order1");
   if(fire_write[2]||fire_port[2]!=2||fire_line[2]!=8'h12)$fatal(1,"P23 order2");
   if(!fire_write[3]||fire_line[3]!=8'hE0)$fatal(1,"P23 order wb");
   $display("PROD_SEAM_P23_ROUND_ROBIN_READ_WRITE_FAIRNESS=PASS");
   $display("PROD_SEAM_P23_TYPED_COMMAND_IDENTITY=PASS");
   // Exact read response route to port2; no other port may pulse.
   @(negedge clk);backend_read_resp_valid_i=1;backend_read_resp_tag_i={2'd2,3'd5};backend_read_resp_line_addr_i=8'h52;backend_read_resp_fault_i=1;backend_read_resp_data_i[0]=32'h1234;backend_read_resp_data_i[1]=32'h5678;#1;
   if(read_resp_valid_o!=3'b100||read_resp_global_tag_o[2]!=3'd5||read_resp_line_addr_o[2]!=8'h52||read_resp_fault_o!=3'b100||read_resp_data_o[2][1]!=32'h5678||read_resp_protocol_error_o)$fatal(1,"P23 response route");
   $display("PROD_SEAM_P23_READ_RESPONSE_IDENTITY_ROUTE=PASS");
   backend_read_resp_tag_i={2'd3,3'd1};#1;if(!read_resp_protocol_error_o||read_resp_valid_o!='0)$fatal(1,"P23 invalid port containment");
   $display("PROD_SEAM_P23_INVALID_READ_PORT_CONTAINED=PASS");backend_read_resp_valid_i=0;
   // Write status remains a distinct typed path and retains opaque attempt id.
   backend_wb_status_valid_i=1;backend_wb_status_attempt_id_i=5'h1B;backend_wb_status_success_i=0;backend_wb_status_retryable_i=1;#1;
   if(!wb_status_valid_o||wb_status_attempt_id_o!=5'h1B||wb_status_success_o||!wb_status_retryable_o)$fatal(1,"P23 wb status path");
   $display("PROD_SEAM_P23_WRITE_STATUS_IDENTITY_ROUTE=PASS");backend_wb_status_valid_i=0;
   $display("PROD_SEAM_P23_ARBITER_BEHAVIOR=PASS");$finish;
 end
endmodule
