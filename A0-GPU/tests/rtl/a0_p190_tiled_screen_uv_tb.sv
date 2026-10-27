`timescale 1ns/1ps
module a0_p190_tiled_screen_uv_tb;
  logic [15:0] pixel_x=0,pixel_y=0;
  logic signed [15:0] offset_u=0,offset_v=0;
  logic tile_enable=0;
  wire signed [15:0] tex_u,tex_v;
  wire invalid;
  integer checked=0;
  a0_p190_tiled_screen_uv dut(
    .pixel_x(pixel_x),.pixel_y(pixel_y),.offset_u(offset_u),
    .offset_v(offset_v),.tile_enable(tile_enable),
    .tex_u(tex_u),.tex_v(tex_v),.invalid(invalid)
  );
  task automatic check(input integer x,y,
                       input logic signed [15:0] ou,ov,
                       input bit tile);
    integer signed ix,iy,iu,iv;
    bit expected_invalid;
    reg signed [15:0] expected_u,expected_v;
    begin
      pixel_x=16'(x);pixel_y=16'(y);
      offset_u=ou;offset_v=ov;tile_enable=tile;
      ix=tile ? (x & 127) : x;
      iy=tile ? (y & 127) : y;
      iu=ix+($signed(ou)>>>8);
      iv=iy+($signed(ov)>>>8);
      expected_invalid=(!tile && (x>=128 || y>=128)) ||
        (iu < -128 || iu > 127) || (iv < -128 || iv > 127);
      expected_u=expected_invalid ? 16'sd0 : {8'(iu),ou[7:0]};
      expected_v=expected_invalid ? 16'sd0 : {8'(iv),ov[7:0]};
      #1;
      if(invalid!==expected_invalid ||
         tex_u!==expected_u || tex_v!==expected_v)
        $fatal(1,"P190 bad x=%0d y=%0d tile=%0d offs=%h/%h got=%h/%h invalid=%b want=%h/%h invalid=%b",
          x,y,tile,ou,ov,tex_u,tex_v,invalid,
          expected_u,expected_v,expected_invalid);
      checked=checked+1;
    end
  endtask
  initial begin
    for(integer x=0;x<256;x=x+1)begin
      check(x,255-x,16'h0000,16'h0000,0);
      check(x,x,16'h0000,16'h0000,1);
      check(x,255-x,16'hff80,16'h007f,1);
      check(x,x,16'h8000,16'h7fff,1);
      check(x,255-x,16'h0100,16'hff00,1);
      check(x,255-x,16'h7fff,16'h8000,0);
    end
    check(0,0,16'h0000,16'h0000,0);
    check(127,127,16'h0000,16'h0000,0);
    check(128,0,16'h0000,16'h0000,0);
    check(0,128,16'h0000,16'h0000,0);
    check(128,0,16'h0000,16'h0000,1);
    check(255,255,16'h0000,16'h0000,1);
    check(65535,65535,16'h0000,16'h0000,1);
    check(65535,0,16'h0100,16'h0000,1);
    check(0,65535,16'h0000,16'h0100,1);
    $display("P190_TILED_SCREEN_UV_PASS cases=%0d integer and fractional exact, bad widths fail closed",checked);
    $finish;
  end
  initial begin #1000000; $fatal(1,"P190 tiled UV timeout"); end
endmodule
