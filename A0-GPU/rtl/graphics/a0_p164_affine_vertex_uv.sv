`timescale 1ns/1ps
// P164: signed affine interpolation of three Q8.8 UV vertex attributes at
// the center of an integer-space raster pixel, using P38-compatible edges.
// Exactly truncated-toward-zero rational arithmetic, no FP or heuristic.
// Two serialized 64-step unsigned restoring divides, with sign recovery.
// NOT perspective-correct: no reciprocal-W or depth-gradient division.
module a0_p164_affine_vertex_uv(
  input logic clk,rst_n,
  input logic req_valid,
  output logic req_ready,
  input logic signed [15:0] x0,y0,x1,y1,x2,y2,
  input logic signed [15:0] u0,v0,u1,v1,u2,v2,
  input logic signed [15:0] pixel_x,pixel_y,
  input logic [7:0] req_id,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [7:0] rsp_id,
  output logic signed [15:0] rsp_u,rsp_v,
  output logic rsp_error
);
  // Q8.8 source values are interpreted as signed raw sixteenth-bit words;
  // geometry uses full integer vertex/pixel locations, like P38.
  function automatic logic signed [35:0] edge_at(
    input logic signed [15:0] ax,ay,bx,by,
    input logic signed [16:0] px2,py2
  );
    logic signed [16:0] dx,dy;
    logic signed [17:0] rx,ry;
    logic signed [34:0] product_x,product_y;
    begin
      dx=$signed(bx)-$signed(ax);
      dy=$signed(by)-$signed(ay);
      rx=$signed(px2)-($signed(ax)*18'sd2);
      ry=$signed(py2)-($signed(ay)*18'sd2);
      product_x=dx*ry;product_y=dy*rx;
      edge_at=$signed(product_x)-$signed(product_y);
    end
  endfunction
  // Pixel center is (x+1/2,y+1/2). Winding is preserved, including
  // clockwise triangles, by retaining the signed denominator.
  wire signed [16:0] center_x=$signed(pixel_x)*17'sd2+17'sd1;
  wire signed [16:0] center_y=$signed(pixel_y)*17'sd2+17'sd1;
  wire signed [35:0] e0=edge_at(x1,y1,x2,y2,center_x,center_y);
  wire signed [35:0] e1=edge_at(x2,y2,x0,y0,center_x,center_y);
  wire signed [35:0] e2=edge_at(x0,y0,x1,y1,center_x,center_y);
  wire signed [35:0] area=e0+e1+e2;
  wire signed [51:0] u0_prod=$signed(u0)*$signed(e0);
  wire signed [51:0] u1_prod=$signed(u1)*$signed(e1);
  wire signed [51:0] u2_prod=$signed(u2)*$signed(e2);
  wire signed [51:0] v0_prod=$signed(v0)*$signed(e0);
  wire signed [51:0] v1_prod=$signed(v1)*$signed(e1);
  wire signed [51:0] v2_prod=$signed(v2)*$signed(e2);
  wire signed [63:0] u_numerator=
    $signed(u0_prod)+$signed(u1_prod)+$signed(u2_prod);
  wire signed [63:0] v_numerator=
    $signed(v0_prod)+$signed(v1_prod)+$signed(v2_prod);
  wire signed [63:0] divisor_signed=$signed(area);
  wire [63:0] divisor_abs=divisor_signed<0 ? -divisor_signed : divisor_signed;
  wire [63:0] u_abs=u_numerator<0 ? -u_numerator : u_numerator;
  wire [63:0] v_abs=v_numerator<0 ? -v_numerator : v_numerator;

  localparam logic [1:0] IDLE=0,DIV_U=1,DIV_V=2,OUTPUT=3;
  logic [1:0] state_q;
  logic [63:0] divisor_q,dividend_q,quotient_q,second_dividend_q;
  logic [64:0] remainder_q;
  logic [6:0] step_q;
  logic neg_u_q,neg_v_q;
  wire [64:0] trial_remainder={remainder_q[63:0],dividend_q[63]};
  wire subtract_valid=trial_remainder >= {1'b0,divisor_q};
  wire [64:0] next_remainder=subtract_valid ?
    (trial_remainder-{1'b0,divisor_q}) : trial_remainder;
  wire [63:0] next_quotient={quotient_q[62:0],subtract_valid};
  wire neg_current=(state_q==DIV_U)?neg_u_q:neg_v_q;
  // A negative signed 16-bit result can have magnitude 32768, while
  // nonnegative results must fit 0..32767. Do not silently wrap.
  wire magnitude_overflow=(next_quotient >
    (neg_current ? 64'd32768 : 64'd32767));
  wire signed [15:0] signed_result=neg_current ?
    -$signed(next_quotient[15:0]) : $signed(next_quotient[15:0]);

  assign req_ready=rst_n && state_q==IDLE;
  assign rsp_valid=rst_n && state_q==OUTPUT;
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;divisor_q<=0;dividend_q<=0;
      quotient_q<=0;second_dividend_q<=0;remainder_q<=0;
      step_q<=0;neg_u_q<=0;neg_v_q<=0;
      rsp_id<=0;rsp_u<=0;rsp_v<=0;rsp_error<=0;
    end else begin
      case(state_q)
        IDLE:if(req_valid && req_ready)begin
          rsp_id<=req_id;rsp_u<=0;rsp_v<=0;rsp_error<=0;
          if(area==0)begin
            rsp_error<=1;
            state_q<=OUTPUT;
          end else begin
            divisor_q<=divisor_abs;
            dividend_q<=u_abs;second_dividend_q<=v_abs;
            neg_u_q<=u_numerator[63] ^ area[35];
            neg_v_q<=v_numerator[63] ^ area[35];
            quotient_q<=0;remainder_q<=0;step_q<=0;
            state_q<=DIV_U;
          end
        end
        DIV_U,DIV_V:begin
          dividend_q<={dividend_q[62:0],1'b0};
          quotient_q<=next_quotient;
          remainder_q<=next_remainder;
          step_q<=step_q+7'd1;
          if(step_q==7'd63)begin
            if(magnitude_overflow)begin
              rsp_u<=0;rsp_v<=0;rsp_error<=1;
              state_q<=OUTPUT;
            end else if(state_q==DIV_U)begin
              rsp_u<=signed_result;
              dividend_q<=second_dividend_q;
              quotient_q<=0;remainder_q<=0;step_q<=0;
              state_q<=DIV_V;
            end else begin
              rsp_v<=signed_result;
              state_q<=OUTPUT;
            end
          end
        end
        OUTPUT:if(rsp_ready)state_q<=IDLE;
        default:state_q<=IDLE;
      endcase
    end
  end
endmodule
