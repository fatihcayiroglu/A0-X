`timescale 1ns/1ps
module tb_a0_p100_primitive_candidates;
  logic [15:0] px,py,rx,ry,rw,rh;
  logic gate_enable,gate_out;
  logic [23:0] dz,oz;
  logic [1:0] dop;
  logic zvalid,zpass;
  logic [23:0] src_rgb,dst_rgb,blend_rgb;
  logic [7:0] alpha;
  logic blend_enable;
  logic [15:0] u,v,tw,th;
  logic texvalid;
  logic [31:0] texoff;
  logic [3:0] em,pm,wm;
  logic we;
  a0_p59_scissor_coverage sc(px,py,rx,ry,rw,rh,gate_enable,gate_out);
  a0_p68_depth_compare dp(dz,oz,dop,zvalid,zpass);
  a0_p70_rgb_blend bl(src_rgb,dst_rgb,alpha,blend_enable,blend_rgb);
  a0_p74_nearest_texel_address ta(u,v,tw,th,texvalid,texoff);
  a0_p83_lane_mask_filter #(.LANES(4)) lm(em,pm,we,wm);
  initial begin
    px=16'd3;py=16'd4;rx=16'd2;ry=16'd3;rw=16'd2;rh=16'd2;gate_enable=1;
    dz=24'd4;oz=24'd5;dop=2'd1;zvalid=1;
    src_rgb=24'hff0000;dst_rgb=24'h0000ff;alpha=8'd255;blend_enable=1;
    u=16'h8000;v=16'h8000;tw=16'd4;th=16'd2;
    em=4'b1011;pm=4'b0110;we=1;
    #1;
    if (!gate_out || !zpass || blend_rgb!==24'hff0000 || !texvalid || texoff!==32'd24 || wm!==4'b0010) $fatal(1,"primitive candidate checks failed");
    px=16'd4;dz=24'd6;dop=2'd1;we=0;alpha=0;
    #1;
    if (gate_out || zpass || blend_rgb!==dst_rgb || wm!==0) $fatal(1,"negative candidate checks failed");
    $display("P100 CANDIDATE RTL TESTBENCH PASS");
    $finish;
  end
endmodule
