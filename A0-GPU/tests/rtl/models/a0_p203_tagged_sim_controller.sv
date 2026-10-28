`timescale 1ns/1ps
// P203 SIMULATION-ONLY tagged controller shim. It translates actual
// P196 one-cycle memory-model port acceptance into explicit tagged WRITE
// COMMIT acknowledgements and tagged READ results. No DDR PHY exists.
module a0_p203_tagged_sim_controller #(
  parameter integer WORDS=65536,
  parameter logic [31:0] BASE_WORD_ADDR=32'h01000000,
  parameter integer TAG_BITS=32
)(
  input logic clk,rst_n,allow_write,allow_read,
  input logic flush_req,
  output logic flush_ack,
  input logic req_valid,req_write,
  input logic [31:0] req_word_addr,
  input logic [47:0] req_pixel,
  input logic [TAG_BITS-1:0] req_id,
  output logic req_ready,
  output logic rsp_valid,rsp_error,
  output logic [47:0] rsp_pixel,
  output logic [TAG_BITS-1:0] rsp_id,
  input logic rsp_ready,
  output logic memory_write_fault
);
  localparam logic [2:0] IDLE=0,ISSUE=1,WRITE_WAIT=2,
    READ_WAIT=3,RESPONSE=4;
  logic [2:0] state_q;
  logic write_q;
  logic [31:0] addr_q;
  logic [47:0] data_q;
  logic [TAG_BITS-1:0] id_q;
  logic error_q;
  logic [47:0] result_q;
  wire mem_write_ready,mem_read_ready,mem_read_rsp_valid;
  wire mem_read_rsp_error;
  wire [47:0] mem_read_rsp_pixel;
  wire mem_write_valid=state_q==ISSUE && write_q && !flush_req;
  wire mem_read_valid=state_q==ISSUE && !write_q && !flush_req;
  a0_p196_external_word_memory_model #(
    .WORDS(WORDS),.BASE_WORD_ADDR(BASE_WORD_ADDR)
  ) memory(
    .clk(clk),.rst_n(rst_n),
    .allow_write(allow_write),.allow_read(allow_read),
    .write_valid(mem_write_valid),.write_ready(mem_write_ready),
    .write_word_addr(addr_q),.write_pixel(data_q),
    .write_fault(memory_write_fault),
    .read_valid(mem_read_valid),.read_ready(mem_read_ready),
    .read_word_addr(addr_q),
    .read_rsp_valid(mem_read_rsp_valid),
    .read_rsp_error(mem_read_rsp_error),
    .read_rsp_pixel(mem_read_rsp_pixel)
  );
  assign flush_ack=rst_n && flush_req && state_q==IDLE;
  assign req_ready=rst_n && state_q==IDLE && !flush_req;
  assign rsp_valid=rst_n && state_q==RESPONSE;
  assign rsp_error=error_q;
  assign rsp_pixel=result_q;
  assign rsp_id=id_q;
  always_ff @(posedge clk)begin
    if(!rst_n)begin
      state_q<=IDLE;write_q<=0;addr_q<=0;data_q<=0;
      id_q<=0;error_q<=0;result_q<=0;
    end else if(flush_req)begin
      // Only the initial quiescent flush may be acknowledged. A production
      // controller must additionally cancel all in-flight physical operations.
      if(state_q!=IDLE)state_q<=IDLE;
    end else case(state_q)
      IDLE:if(req_valid && req_ready)begin
        addr_q<=req_word_addr;data_q<=req_pixel;
        write_q<=req_write;id_q<=req_id;
        state_q<=ISSUE;
      end
      ISSUE:begin
        if(mem_write_valid && mem_write_ready)state_q<=WRITE_WAIT;
        else if(mem_read_valid && mem_read_ready)state_q<=READ_WAIT;
      end
      WRITE_WAIT:begin
        // P196 write_fault describes the preceding memory-accept edge.
        error_q<=memory_write_fault;result_q<=0;
        state_q<=RESPONSE;
      end
      READ_WAIT:if(mem_read_rsp_valid)begin
        error_q<=mem_read_rsp_error;
        result_q<=mem_read_rsp_pixel;
        state_q<=RESPONSE;
      end
      RESPONSE:if(rsp_ready)state_q<=IDLE;
      default:state_q<=IDLE;
    endcase
  end
endmodule
