`timescale 1ns/1ps
module a0_backend_recovery_dual_safe_join(
 input logic clk,input logic rst_n,input logic recovery_active_i,input logic recovery_complete_i,
 input logic write_safe_valid_i,output logic write_safe_ready_o,
 input logic read_safe_valid_i,output logic read_safe_ready_o,
 output logic joined_safe_valid_o,input logic joined_safe_ready_i,
 output logic write_safe_seen_o,output logic read_safe_seen_o
);
 logic write_seen_q, read_seen_q;
 logic write_fire, read_fire, joined_fire;
 always_comb begin
  write_safe_ready_o = recovery_active_i && !write_seen_q;
  read_safe_ready_o = recovery_active_i && !read_seen_q;
  write_fire = write_safe_valid_i && write_safe_ready_o;
  read_fire = read_safe_valid_i && read_safe_ready_o;
  joined_safe_valid_o = recovery_active_i && (write_seen_q || write_fire) && (read_seen_q || read_fire);
  joined_fire = joined_safe_valid_o && joined_safe_ready_i;
  write_safe_seen_o = write_seen_q || write_fire;
  read_safe_seen_o = read_seen_q || read_fire;
 end
 always_ff @(posedge clk) begin
  if(!rst_n) begin write_seen_q<=1'b0; read_seen_q<=1'b0; end
  else begin
   if(!recovery_active_i || recovery_complete_i) begin write_seen_q<=1'b0; read_seen_q<=1'b0; end
   else begin
    if(write_fire) write_seen_q<=1'b1;
    if(read_fire) read_seen_q<=1'b1;
    if(joined_fire) begin write_seen_q<=1'b1; read_seen_q<=1'b1; end
   end
  end
 end
endmodule
