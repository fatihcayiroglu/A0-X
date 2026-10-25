`timescale 1ns/1ps
// P157: ordered single-in-flight sampler -> RGBA UNORM ALU pipeline.
// Real P156 single-port DP16KD texture and P150 exact vector arithmetic.
// Missing texture texels are zero (no stale memory leakage), and all
// output tags, data and presence flags are held during host backpressure.
// NOT a GPU fragment shader, normalized UV, mipmap or PCIe system.
module a0_p157_texture_alu_link(
  input logic clk,rst_n,
  input logic write_valid,
  output logic write_ready,
  input logic [3:0] write_x,write_y,
  input logic [31:0] write_rgba,
  input logic req_valid,
  output logic req_ready,
  input logic signed [15:0] sample_x,sample_y,
  input logic sample_repeat,
  input logic [7:0] req_id,
  input logic [2:0] opcode,
  input logic [31:0] operand_b,
  input logic [7:0] alpha,
  input logic [3:0] lane_mask,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [7:0] rsp_id,
  output logic [31:0] rsp_rgba,
  output logic rsp_present
);
  localparam logic [1:0] IDLE=0,TEX_WAIT=1,ALU_WAIT=2,OUTPUT=3;
  logic [1:0] state_q;
  logic [7:0] id_q,alpha_q;
  logic [2:0] op_q;
  logic [3:0] mask_q;
  logic [31:0] other_q,result_q;
  logic present_q;
  wire texture_ready,texture_valid,texture_present,texture_write_ready;
  wire [7:0] texture_id;
  wire [31:0] texture_rgba;
  wire alu_ready,alu_valid;
  wire [7:0] alu_id;
  wire [31:0] alu_rgba;
  wire fire=req_valid && req_ready;
  assign req_ready=rst_n && state_q==IDLE && texture_ready;
  assign write_ready=texture_write_ready && state_q==IDLE && !req_valid;
  assign rsp_valid=rst_n && state_q==OUTPUT;
  assign rsp_id=id_q;
  assign rsp_rgba=result_q;
  assign rsp_present=present_q;
  a0_p156_nearest_texture texture(
    .clk(clk),.rst_n(rst_n),
    .write_valid(write_valid && state_q==IDLE && !req_valid),
    .write_ready(texture_write_ready),
    .write_x(write_x),.write_y(write_y),.write_rgba(write_rgba),
    .sample_valid(fire),.sample_ready(texture_ready),
    .sample_x(sample_x),.sample_y(sample_y),
    .sample_repeat(sample_repeat),.sample_id(req_id),
    .rsp_valid(texture_valid),.rsp_ready(state_q==TEX_WAIT),
    .rsp_id(texture_id),.rsp_rgba(texture_rgba),
    .rsp_present(texture_present)
  );
  a0_p150_unorm_simd4_alu alu(
    .clk(clk),.rst_n(rst_n),
    .req_valid(state_q==TEX_WAIT && texture_valid),
    .req_ready(alu_ready),.req_id(texture_id),
    .opcode(op_q),.operand_a(texture_rgba),.operand_b(other_q),
    .uniform_alpha(alpha_q),.lane_mask(mask_q),
    .rsp_valid(alu_valid),.rsp_ready(state_q==ALU_WAIT),
    .rsp_id(alu_id),.rsp_data(alu_rgba)
  );
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;id_q<=0;op_q<=0;alpha_q<=0;mask_q<=0;
      other_q<=0;result_q<=0;present_q<=0;
    end else begin
      case(state_q)
        IDLE:if(fire)begin
          id_q<=req_id;op_q<=opcode;alpha_q<=alpha;
          mask_q<=lane_mask;other_q<=operand_b;
          state_q<=TEX_WAIT;
        end
        TEX_WAIT:if(texture_valid && alu_ready)begin
          // Missing texels have zero value; presence remains observable.
          if(texture_id!=id_q)state_q<=OUTPUT;
          else begin present_q<=texture_present;state_q<=ALU_WAIT;end
        end
        ALU_WAIT:if(alu_valid)begin
          result_q<=alu_rgba;
          state_q<=OUTPUT;
        end
        OUTPUT:if(rsp_ready)state_q<=IDLE;
        default:state_q<=IDLE;
      endcase
    end
  end
endmodule
