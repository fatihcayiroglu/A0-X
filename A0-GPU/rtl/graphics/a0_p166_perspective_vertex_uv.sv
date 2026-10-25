`timescale 1ns/1ps
// P166: signed perspective-correct interpolation of Q8.8 UV attributes at
// the center of a P38 pixel. Each vertex carries positive unsigned inverse-W
// in a common fixed-point scale (e.g. Q4.12); scaling cancels in the ratio.
// U = sum(edge_i * inverseW_i * U_i) / sum(edge_i * inverseW_i).
// V = sum(edge_i * inverseW_i * V_i) / sum(edge_i * inverseW_i).
// There is NO intermediate rounding of U/W or 1/W. Two serialized
// 80-cycle restoring divisions implement exact truncation toward zero.
// P168: reciprocal weights (1,1,1) use exactly 64 quotient bits.
// P169: registered edge/weight, multiply, sum and sign stages break the
// long geometry -> DSP -> 80-bit sum -> sign path. All request inputs
// become immutable as soon as req_valid/req_ready handshake.
// Loading the 64-bit affine numerator into the upper 64 of the 80-bit
// shift register preserves the original P164 result and halves no accuracy.
module a0_p166_perspective_vertex_uv(
  input logic clk,rst_n,
  input logic req_valid,
  output logic req_ready,
  input logic signed [15:0] x0,y0,x1,y1,x2,y2,
  input logic signed [15:0] u0,v0,u1,v1,u2,v2,
  input logic [15:0] inv_w0,inv_w1,inv_w2,
  input logic signed [15:0] pixel_x,pixel_y,
  input logic [7:0] req_id,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [7:0] rsp_id,
  output logic signed [15:0] rsp_u,rsp_v,
  output logic rsp_error
);
  // Inputs are raw signed Q8.8 UV and nonzero unsigned reciprocal-W. The
  // reciprocal scale is shared by all three vertices and cancels out.
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
  // Stage 0: geometry edges and weighted attributes captured atomically
  // with the request, so caller mutations cannot change a busy sample.
  wire signed [32:0] uw0=$signed(u0)*$signed({1'b0,inv_w0});
  wire signed [32:0] uw1=$signed(u1)*$signed({1'b0,inv_w1});
  wire signed [32:0] uw2=$signed(u2)*$signed({1'b0,inv_w2});
  wire signed [32:0] vw0=$signed(v0)*$signed({1'b0,inv_w0});
  wire signed [32:0] vw1=$signed(v1)*$signed({1'b0,inv_w1});
  wire signed [32:0] vw2=$signed(v2)*$signed({1'b0,inv_w2});
  logic signed [35:0] e0_q,e1_q,e2_q;
  logic signed [32:0] uw0_q,uw1_q,uw2_q,vw0_q,vw1_q,vw2_q;
  logic [15:0] iw0_q,iw1_q,iw2_q;

  // Stage 1: the six weighted vertex products and denominator terms
  // are registered before the 80-bit carry chains of stage 2.
  logic signed [78:0] u0_prod_q,u1_prod_q,u2_prod_q;
  logic signed [78:0] v0_prod_q,v1_prod_q,v2_prod_q;
  logic signed [53:0] d0_q,d1_q,d2_q;
  logic signed [35:0] area_sum_q;

  // Stage 2: exact, full-precision signed arithmetic (no rounding).
  logic signed [79:0] u_sum_q,v_sum_q,denom_sum_q;
  wire [79:0] divisor_abs=denom_sum_q<0 ? -denom_sum_q : denom_sum_q;
  wire [79:0] u_abs=u_sum_q<0 ? -u_sum_q : u_sum_q;
  wire [79:0] v_abs=v_sum_q<0 ? -v_sum_q : v_sum_q;

  localparam logic [2:0] IDLE=0,PREMULT=1,PRESUM=2,PREABS=3,
                         DIV_U=4,DIV_V=5,OUTPUT=6;
  logic [2:0] state_q;
  logic [79:0] divisor_q,dividend_q,quotient_q,second_dividend_q;
  logic [80:0] remainder_q;
  logic [6:0] step_q;
  logic affine_short_q,neg_u_q,neg_v_q;
  wire affine_short=(inv_w0==16'd1 && inv_w1==16'd1 &&
                     inv_w2==16'd1);
  wire [80:0] trial_remainder={remainder_q[79:0],dividend_q[79]};
  wire subtract_valid=trial_remainder >= {1'b0,divisor_q};
  wire [80:0] next_remainder=subtract_valid ?
    (trial_remainder-{1'b0,divisor_q}) : trial_remainder;
  wire [79:0] next_quotient={quotient_q[78:0],subtract_valid};
  wire neg_current=(state_q==DIV_U)?neg_u_q:neg_v_q;
  // A negative signed 16-bit result can have magnitude 32768, while
  // nonnegative results must fit 0..32767. Do not silently wrap.
  wire magnitude_overflow=(next_quotient >
    (neg_current ? 80'd32768 : 80'd32767));
  wire signed [15:0] signed_result=neg_current ?
    -$signed(next_quotient[15:0]) : $signed(next_quotient[15:0]);

  assign req_ready=rst_n && state_q==IDLE;
  assign rsp_valid=rst_n && state_q==OUTPUT;
  always_ff @(posedge clk) begin
    if(!rst_n)begin
      state_q<=IDLE;divisor_q<=0;dividend_q<=0;
      quotient_q<=0;second_dividend_q<=0;remainder_q<=0;
      step_q<=0;affine_short_q<=0;neg_u_q<=0;neg_v_q<=0;
      e0_q<=0;e1_q<=0;e2_q<=0;
      uw0_q<=0;uw1_q<=0;uw2_q<=0;
      vw0_q<=0;vw1_q<=0;vw2_q<=0;
      iw0_q<=0;iw1_q<=0;iw2_q<=0;
      u0_prod_q<=0;u1_prod_q<=0;u2_prod_q<=0;
      v0_prod_q<=0;v1_prod_q<=0;v2_prod_q<=0;
      d0_q<=0;d1_q<=0;d2_q<=0;
      area_sum_q<=0;u_sum_q<=0;v_sum_q<=0;denom_sum_q<=0;
      rsp_id<=0;rsp_u<=0;rsp_v<=0;rsp_error<=0;
    end else begin
      case(state_q)
        IDLE:if(req_valid && req_ready)begin
          rsp_id<=req_id;rsp_u<=0;rsp_v<=0;rsp_error<=0;
          if(inv_w0==0 || inv_w1==0 || inv_w2==0)begin
            rsp_error<=1;
            state_q<=OUTPUT;
          end else begin
            e0_q<=e0;e1_q<=e1;e2_q<=e2;
            uw0_q<=uw0;uw1_q<=uw1;uw2_q<=uw2;
            vw0_q<=vw0;vw1_q<=vw1;vw2_q<=vw2;
            iw0_q<=inv_w0;iw1_q<=inv_w1;iw2_q<=inv_w2;
            affine_short_q<=affine_short;
            state_q<=PREMULT;
          end
        end
        PREMULT:begin
          u0_prod_q<=$signed(uw0_q)*$signed(e0_q);
          u1_prod_q<=$signed(uw1_q)*$signed(e1_q);
          u2_prod_q<=$signed(uw2_q)*$signed(e2_q);
          v0_prod_q<=$signed(vw0_q)*$signed(e0_q);
          v1_prod_q<=$signed(vw1_q)*$signed(e1_q);
          v2_prod_q<=$signed(vw2_q)*$signed(e2_q);
          d0_q<=$signed(e0_q)*$signed({1'b0,iw0_q});
          d1_q<=$signed(e1_q)*$signed({1'b0,iw1_q});
          d2_q<=$signed(e2_q)*$signed({1'b0,iw2_q});
          state_q<=PRESUM;
        end
        PRESUM:begin
          area_sum_q<=e0_q+e1_q+e2_q;
          u_sum_q<=$signed(u0_prod_q)+$signed(u1_prod_q)+
                   $signed(u2_prod_q);
          v_sum_q<=$signed(v0_prod_q)+$signed(v1_prod_q)+
                   $signed(v2_prod_q);
          denom_sum_q<=$signed(d0_q)+$signed(d1_q)+$signed(d2_q);
          state_q<=PREABS;
        end
        PREABS:begin
          if(area_sum_q==0 || denom_sum_q==0)begin
            rsp_error<=1;
            state_q<=OUTPUT;
          end else begin
            divisor_q<=divisor_abs;
            dividend_q<=affine_short_q ? {u_abs[63:0],16'd0} : u_abs;
            second_dividend_q<=affine_short_q ?
              {v_abs[63:0],16'd0} : v_abs;
            neg_u_q<=u_sum_q[79] ^ denom_sum_q[79];
            neg_v_q<=v_sum_q[79] ^ denom_sum_q[79];
            quotient_q<=0;remainder_q<=0;step_q<=0;
            state_q<=DIV_U;
          end
        end
        DIV_U,DIV_V:begin
          dividend_q<={dividend_q[78:0],1'b0};
          quotient_q<=next_quotient;
          remainder_q<=next_remainder;
          step_q<=step_q+7'd1;
          if(step_q==(affine_short_q ? 7'd63 : 7'd79))begin
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
