`timescale 1ns/1ps
// P158: bounded 16x16 RGBA8 bilinear filtering over the real P156 BRAM.
// Coordinates are signed Q8.8 texel positions, NOT normalized UV values.
// Four ordered synchronous BRAM reads, then two rounded /256 lerps per axis.
// No mipmaps, shader ISA integration, cache, or physical board is implied.
module a0_p158_bilinear_texture(
  input logic clk,rst_n,
  input logic write_valid,
  output logic write_ready,
  input logic [3:0] write_x,write_y,
  input logic [31:0] write_rgba,
  input logic sample_valid,
  output logic sample_ready,
  input logic signed [15:0] sample_u,sample_v,
  input logic sample_repeat,
  input logic [7:0] sample_id,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [7:0] rsp_id,
  output logic [31:0] rsp_rgba,
  output logic rsp_present
);
  // P159 area optimization: time-share a single four-channel lerp between
  // two horizontal and one vertical calculations, instead of implementing
  // all three at once (24 independent multipliers in P158).
  localparam logic [2:0] IDLE=0,ISSUE=1,WAIT_TEX=2,
                         HORIZONTAL0=3,HORIZONTAL1=4,VERTICAL=5,OUTPUT=6;
  logic [2:0] state_q;
  logic signed [15:0] base_x_q,base_y_q;
  logic [7:0] fx_q,fy_q,tag_q;
  logic repeat_q;
  logic [1:0] tap_q;
  logic [31:0] texel_q[0:3];
  logic [31:0] top_row_q,bottom_row_q;
  logic [3:0] present_bits_q;
  wire tex_write_ready,tex_sample_ready,tex_rsp_valid,tex_rsp_present;
  wire [7:0] tex_rsp_id;
  wire [31:0] tex_rsp_rgba;
  wire signed [15:0] tap_x=base_x_q+$signed({15'd0,tap_q[0]});
  wire signed [15:0] tap_y=base_y_q+$signed({15'd0,tap_q[1]});
  wire sample_fire=sample_valid && sample_ready;

  // A new sample wins same-cycle write contention; writes never
  // interleave with four reads belonging to one bilinear response.
  assign sample_ready=rst_n && state_q==IDLE;
  assign write_ready=tex_write_ready && state_q==IDLE && !sample_valid;
  assign rsp_valid=rst_n && state_q==OUTPUT;

  a0_p156_nearest_texture texture(
    .clk(clk),.rst_n(rst_n),
    .write_valid(write_valid && state_q==IDLE && !sample_valid),
    .write_ready(tex_write_ready),
    .write_x(write_x),.write_y(write_y),.write_rgba(write_rgba),
    .sample_valid(state_q==ISSUE),.sample_ready(tex_sample_ready),
    .sample_x(tap_x),.sample_y(tap_y),.sample_repeat(repeat_q),
    .sample_id({6'd0,tap_q}),
    .rsp_valid(tex_rsp_valid),.rsp_ready(state_q==WAIT_TEX),
    .rsp_id(tex_rsp_id),.rsp_rgba(tex_rsp_rgba),
    .rsp_present(tex_rsp_present)
  );

  // Exact, documented two-pass Q0.8 interpolation with round-to-nearest.
  // Two 8-bit inputs of 255 return exactly 255 for every fraction.
  function automatic [7:0] lerp256(input logic [7:0] a,b,fraction);
    logic [17:0] sum;
    begin
      sum=18'(a)*(18'd256-18'(fraction))+
          18'(b)*18'(fraction)+18'd128;
      lerp256=sum[15:8];
    end
  endfunction
  logic [31:0] lerp_a,lerp_b,lerp_result;
  logic [7:0] lerp_factor;
  always_comb begin
    case(state_q)
      HORIZONTAL0:begin
        lerp_a=texel_q[0];lerp_b=texel_q[1];lerp_factor=fx_q;
      end
      HORIZONTAL1:begin
        lerp_a=texel_q[2];lerp_b=texel_q[3];lerp_factor=fx_q;
      end
      default:begin
        lerp_a=top_row_q;lerp_b=bottom_row_q;lerp_factor=fy_q;
      end
    endcase
    lerp_result=0;
    for(integer lane=0;lane<4;lane=lane+1)
      lerp_result[8*lane+:8]=lerp256(
        lerp_a[8*lane+:8],lerp_b[8*lane+:8],lerp_factor);
  end

  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;
      base_x_q<=0;base_y_q<=0;fx_q<=0;fy_q<=0;
      tag_q<=0;repeat_q<=0;tap_q<=0;present_bits_q<=0;
      top_row_q<=0;bottom_row_q<=0;
      rsp_id<=0;rsp_rgba<=0;rsp_present<=0;
      for(integer t=0;t<4;t=t+1)texel_q[t]<=0;
    end else begin
      case(state_q)
        IDLE:if(sample_fire)begin
          base_x_q<=sample_u>>>8;
          base_y_q<=sample_v>>>8;
          fx_q<=sample_u[7:0];fy_q<=sample_v[7:0];
          tag_q<=sample_id;repeat_q<=sample_repeat;
          tap_q<=0;present_bits_q<=0;
          state_q<=ISSUE;
        end
        ISSUE:if(tex_sample_ready)state_q<=WAIT_TEX;
        WAIT_TEX:if(tex_rsp_valid)begin
          if(tex_rsp_id!=={6'd0,tap_q})begin
            // An impossible internal tag mismatch must not expose old pixels.
            rsp_id<=tag_q;rsp_rgba<=0;rsp_present<=0;
            state_q<=OUTPUT;
          end else begin
            texel_q[tap_q]<=tex_rsp_rgba;
            present_bits_q[tap_q]<=tex_rsp_present;
            if(tap_q==2'd3)state_q<=HORIZONTAL0;
            else begin tap_q<=tap_q+2'd1;state_q<=ISSUE;end
          end
        end
        HORIZONTAL0:begin
          top_row_q<=lerp_result;
          state_q<=HORIZONTAL1;
        end
        HORIZONTAL1:begin
          bottom_row_q<=lerp_result;
          state_q<=VERTICAL;
        end
        VERTICAL:begin
          rsp_id<=tag_q;rsp_rgba<=lerp_result;
          // Zero-weight taps cannot make an otherwise valid sample missing.
          rsp_present<=present_bits_q[0] &&
            ((fx_q==0)||present_bits_q[1]) &&
            ((fy_q==0)||present_bits_q[2]) &&
            ((fx_q==0)||(fy_q==0)||present_bits_q[3]);
          state_q<=OUTPUT;
        end
        OUTPUT:if(rsp_ready)state_q<=IDLE;
        default:state_q<=IDLE;
      endcase
    end
  end
endmodule
