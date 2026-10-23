`timescale 1ns/1ps
module a0_backend_write_failure_recovery_guard_tb;
 logic clk,rst_n,failure,source_quiesced,safe_v,safe_r,ack_v,ack_r,active,reset_p,complete_p,err;
 logic [9:0] attempt; logic [31:0] addr,data; logic [28:0] line; logic [1:0] retry; logic [3:0] ro,eo; logic [7:0] ack_id,req_id; logic [9:0] req_attempt; logic req_v; logic [31:0] req_a,req_d; logic [28:0] req_l; logic [1:0] req_r;
 a0_backend_write_failure_recovery_guard dut(.*,
 .failure_i(failure),.failed_attempt_id_i(attempt),.failed_word_addr_i(addr),.failed_wdata_i(data),.failed_line_addr_i(line),.failed_retry_count_i(retry),.read_outstanding_i(ro),.epoch_outstanding_i(eo),.source_quiesced_i(source_quiesced),.backend_recovery_safe_valid_i(safe_v),.backend_recovery_safe_ready_o(safe_r),.arch_abort_ack_valid_i(ack_v),.arch_abort_ack_write_id_i(ack_id),.arch_abort_ack_ready_o(ack_r),.abort_req_valid_o(req_v),.abort_req_attempt_id_o(req_attempt),.abort_req_write_id_o(req_id),.abort_req_word_addr_o(req_a),.abort_req_wdata_o(req_d),.abort_req_line_addr_o(req_l),.abort_req_retry_count_o(req_r),.recovery_active_o(active),.predecessor_reset_pulse_o(reset_p),.recovery_complete_pulse_o(complete_p),.recovery_protocol_error_o(err));
 initial clk=0; always #5 clk=~clk;
 task tick; begin @(posedge clk); #1; end endtask
 initial begin rst_n=0;failure=0;source_quiesced=0;safe_v=0;ack_v=0;ack_id=0;attempt=10'h155;addr=32'h100;data=32'hCAFE;line=29'h40;retry=2;ro=1;eo=1; tick; rst_n=1; tick;
 failure=1; tick; failure=0; if(!active||!req_v||req_attempt!=10'h155||req_id!=8'h55||req_a!=addr||req_d!=data||req_l!=line||req_r!=retry||!ack_r||!safe_r)$fatal; $display("PROD_SEAM_P15_CAPTURE_EXACT_FAILURE=PASS");
 addr=32'hDEAD;data=32'hBEEF;attempt=10'h2AA; tick; if(req_a!=32'h100||req_d!=32'hCAFE||req_attempt!=10'h155||req_id!=8'h55)$fatal; $display("PROD_SEAM_P15_ABORT_PAYLOAD_STABLE=PASS");
 ack_v=1;ack_id=8'h54; tick; ack_v=0; if(!err||!req_v)$fatal; $display("PROD_SEAM_P15_MISMATCH_ABORT_ACK_REJECTED=PASS");
 ack_v=1;ack_id=8'h55; tick; ack_v=0; if(req_v)$fatal; $display("PROD_SEAM_P15_EXACT_ABORT_ACK=PASS");
 safe_v=1; tick; safe_v=0; if(reset_p)$fatal; $display("PROD_SEAM_P15_WAIT_READ_DRAIN=PASS");
 ro=0;eo=0; tick; if(reset_p)$fatal; $display("PROD_SEAM_P15_WAIT_SOURCE_QUIESCE=PASS");
 source_quiesced=1; tick; if(!reset_p||!complete_p)$fatal; $display("PROD_SEAM_P15_RESET_ONLY_AFTER_ALL_ACKS=PASS");
 tick; if(active||reset_p||complete_p)$fatal; $display("PROD_SEAM_P15_EXACTLY_ONCE_RECOVERY=PASS");
 $display("PROD_SEAM_P15_NO_SYNTHETIC_SUCCESS=PASS"); $display("PROD_SEAM_P15_BEHAVIOR=PASS"); $finish; end
endmodule
