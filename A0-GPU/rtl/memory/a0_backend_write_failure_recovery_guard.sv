`timescale 1ns/1ps
module a0_backend_write_failure_recovery_guard #(
    parameter integer WRITE_ID_W=8,
    parameter integer ATTEMPT_ID_W=10,
    parameter integer LINE_ADDR_W=29,
    parameter integer RETRY_COUNT_W=2,
    parameter integer READ_COUNT_W=4
)(
 input logic clk,input logic rst_n,
 input logic failure_i,
 input logic [ATTEMPT_ID_W-1:0] failed_attempt_id_i,
 input logic [31:0] failed_word_addr_i,input logic [31:0] failed_wdata_i,
 input logic [LINE_ADDR_W-1:0] failed_line_addr_i,
 input logic [RETRY_COUNT_W-1:0] failed_retry_count_i,
 input logic [READ_COUNT_W-1:0] read_outstanding_i,input logic [READ_COUNT_W-1:0] epoch_outstanding_i,
 input logic source_quiesced_i,
 input logic backend_recovery_safe_valid_i,output logic backend_recovery_safe_ready_o,
 input logic arch_abort_ack_valid_i,input logic [WRITE_ID_W-1:0] arch_abort_ack_write_id_i,output logic arch_abort_ack_ready_o,
 output logic abort_req_valid_o,output logic [ATTEMPT_ID_W-1:0] abort_req_attempt_id_o,output logic [WRITE_ID_W-1:0] abort_req_write_id_o,
 output logic [31:0] abort_req_word_addr_o,output logic [31:0] abort_req_wdata_o,
 output logic [LINE_ADDR_W-1:0] abort_req_line_addr_o,output logic [RETRY_COUNT_W-1:0] abort_req_retry_count_o,
 output logic recovery_active_o,output logic predecessor_reset_pulse_o,output logic recovery_complete_pulse_o,
 output logic recovery_protocol_error_o
);
 logic active_q, abort_done_q, safe_done_q, reset_q, complete_q, err_q;
 logic [ATTEMPT_ID_W-1:0] attempt_id_q; logic [WRITE_ID_W-1:0] write_id_q; logic [31:0] addr_q,data_q; logic [LINE_ADDR_W-1:0] line_q; logic [RETRY_COUNT_W-1:0] retry_q;
 logic exact_abort_ack, can_reset;
 always_comb begin
  abort_req_valid_o=active_q&&!abort_done_q; abort_req_attempt_id_o=attempt_id_q; abort_req_write_id_o=write_id_q; abort_req_word_addr_o=addr_q; abort_req_wdata_o=data_q; abort_req_line_addr_o=line_q; abort_req_retry_count_o=retry_q;
  arch_abort_ack_ready_o=abort_req_valid_o; exact_abort_ack=arch_abort_ack_valid_i&&arch_abort_ack_ready_o&&(arch_abort_ack_write_id_i==write_id_q);
  backend_recovery_safe_ready_o=active_q&&!safe_done_q;
  can_reset=active_q && (abort_done_q||exact_abort_ack) && (safe_done_q||(backend_recovery_safe_valid_i&&backend_recovery_safe_ready_o)) && source_quiesced_i && (read_outstanding_i=='0) && (epoch_outstanding_i=='0);
  recovery_active_o=active_q; predecessor_reset_pulse_o=reset_q; recovery_complete_pulse_o=complete_q; recovery_protocol_error_o=err_q;
 end
 always_ff @(posedge clk) begin
  if(!rst_n) begin active_q<=0;abort_done_q<=0;safe_done_q<=0;reset_q<=0;complete_q<=0;err_q<=0;attempt_id_q<='0;write_id_q<='0;addr_q<='0;data_q<='0;line_q<='0;retry_q<='0; end
  else begin
   reset_q<=0; complete_q<=0;
   if(!active_q && failure_i) begin active_q<=1; abort_done_q<=0; safe_done_q<=0; attempt_id_q<=failed_attempt_id_i; write_id_q<=failed_attempt_id_i[WRITE_ID_W-1:0]; addr_q<=failed_word_addr_i; data_q<=failed_wdata_i; line_q<=failed_line_addr_i; retry_q<=failed_retry_count_i; end
   if(active_q && arch_abort_ack_valid_i && arch_abort_ack_ready_o && arch_abort_ack_write_id_i!=write_id_q) err_q<=1;
   if(exact_abort_ack) abort_done_q<=1;
   if(backend_recovery_safe_valid_i&&backend_recovery_safe_ready_o) safe_done_q<=1;
   if(can_reset) begin reset_q<=1; complete_q<=1; active_q<=0; abort_done_q<=0; safe_done_q<=0; end
  end
 end
endmodule
