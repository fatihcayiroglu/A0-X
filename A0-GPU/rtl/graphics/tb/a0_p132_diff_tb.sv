`timescale 1ns/1ps
// P132 differential: independent direct-P102 oracle, only start strobes shared.
module a0_p132_diff_tb;
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0,req_valid=0,req_write=0,rsp_ready=0;
  reg [7:0] req_addr=0;
  reg [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;
  wire ref_clear_ready,ref_tri_ready,ref_clear_done,ref_tri_done;
  wire ref_initialized,ref_busy,ref_read_valid,ref_pixel_wrote;
  wire [23:0] ref_read_color,ref_read_depth;
  reg [15:0] ref_read_x=0,ref_read_y=0;
  reg [23:0] ref_tri_color=24'h40a0e0,ref_tri_depth=24'h000040;
  reg [1:0] ref_depth_op=0;
  reg ref_depth_write=1,ref_blend=0,ref_scissor=0;
  reg [7:0] ref_alpha=0;
  reg [15:0] ref_sx=0,ref_sy=0,ref_sw=0,ref_sh=0;
  reg [31:0] response;
  integer x,y,i,filled;

  a0_p132_command_bus #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut(
    .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(req_ready),
    .req_write(req_write),.req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
    .rsp_rdata(rsp_rdata),.rsp_error(rsp_error)
  );
  a0_triangle_scissor_depth_blend_p102 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) oracle(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(dut.clear_start),.clear_ready(ref_clear_ready),
    .clear_color(24'h000011),.clear_depth(24'hffffff),.clear_done(ref_clear_done),
    .tri_valid(dut.tri_start),.tri_ready(ref_tri_ready),
    .x0(16'sd0),.y0(16'sd0),
    .x1(16'sd3),.y1(16'sd0),
    .x2(16'sd0),.y2(16'sd3),
    .tri_color(ref_tri_color),.tri_depth(ref_tri_depth),
    .depth_compare_op(ref_depth_op),.depth_write(ref_depth_write),
    .blend_enable(ref_blend),.source_alpha(ref_alpha),
    .scissor_enable(ref_scissor),
    .scissor_x(ref_sx),.scissor_y(ref_sy),
    .scissor_w(ref_sw),.scissor_h(ref_sh),
    .tri_done(ref_tri_done),.initialized(ref_initialized),.busy(ref_busy),
    .read_x(ref_read_x),.read_y(ref_read_y),
    .read_valid(ref_read_valid),.read_color(ref_read_color),
    .read_depth(ref_read_depth),.pixel_wrote(ref_pixel_wrote)
  );

  task automatic access(input reg write_en,input reg [7:0] addr,
                        input reg [31:0] value,output reg [31:0] result);
    integer cycles;
    begin
      @(negedge clk);
      req_valid=1;req_write=write_en;req_addr=addr;req_wdata=value;
      cycles=0;
      while (!req_ready) begin
        @(negedge clk);
        cycles=cycles+1;
        if (cycles>30) $fatal(1,"diff bus timeout");
      end
      @(posedge clk);
      @(negedge clk);
      req_valid=0;
      if (!rsp_valid || rsp_error) $fatal(1,"diff unexpected bus error at %h",addr);
      result=rsp_rdata;
      rsp_ready=1;
      @(posedge clk);
      @(negedge clk);
      rsp_ready=0;
    end
  endtask
  task automatic wr(input reg [7:0] addr,input reg [31:0] value);
    reg [31:0] result;
    begin access(1,addr,value,result); end
  endtask
  task automatic rd(input reg [7:0] addr,output reg [31:0] value);
    begin access(0,addr,0,value); end
  endtask
  task automatic wait_done(input integer flag);
    reg [31:0] stat;
    integer j;
    reg found;
    begin
      found=0;
      for(j=0;j<100 && !found;j=j+1) begin
        rd(8'h04,stat);
        if(stat[flag]) found=1;
      end
      if (!found) $fatal(1,"P132 differential completion timeout: %0d",flag);
    end
  endtask
  task automatic compare_frame;
    reg [31:0] got_c,got_d;
    begin
      filled=0;
      for(y=0;y<4;y=y+1) begin
        for(x=0;x<4;x=x+1) begin
          ref_read_x=x;
          ref_read_y=y;
          wr(8'h34,(y<<16)|x);
          rd(8'h38,got_c);
          rd(8'h3c,got_d);
          if (!ref_read_valid || got_c !== {8'h80,ref_read_color} ||
              got_d !== {8'h80,ref_read_depth})
            $fatal(1,"P132/P102 differential mismatch x=%0d y=%0d bus=%h/%h oracle=%h/%h",
                   x,y,got_c,got_d,ref_read_color,ref_read_depth);
          if (got_c[23:0] != 24'h000011) filled=filled+1;
        end
      end
    end
  endtask

  initial begin
    repeat(3) @(negedge clk);
    rst_n=1;
    wr(8'h0c,32'h00000011);
    wr(8'h10,32'h00ffffff);
    wr(8'h08,1);
    wait_done(2);
    compare_frame();
    if (filled != 0) $fatal(1,"initial clear not uniform");
    wr(8'h14,32'h00000000);
    wr(8'h18,32'h00000003);
    wr(8'h1c,32'h00030000);
    wr(8'h20,32'h0040a0e0);
    wr(8'h24,32'h00000040);
    wr(8'h28,32'h00000004);
    wr(8'h08,4);
    wr(8'h08,2);
    // Mutate staging registers after accepted launch; the in-flight triangle
    // must keep the original color/depth snapshot, matching direct P102.
    wr(8'h20,32'h00ff00ff);
    wr(8'h24,32'h00000001);
    wait_done(3);
    compare_frame();
    if (filled == 0) $fatal(1,"vacuous differential: no drawn pixels");
    ref_tri_color=24'h20ff40;
    ref_tri_depth=24'h000020;
    ref_depth_op=1;
    ref_blend=1;
    ref_alpha=128;
    ref_scissor=1;
    ref_sx=1;ref_sy=0;ref_sw=2;ref_sh=4;
    wr(8'h20,32'h0020ff40);
    wr(8'h24,32'h00000020);
    wr(8'h28,32'h0001800d); // LESS + write + blend + alpha128 + scissor
    wr(8'h2c,32'h00000001);
    wr(8'h30,32'h00040002);
    wr(8'h08,4);
    wr(8'h08,2);
    wait_done(3);
    compare_frame();
    $display("P132_DIFFERENTIAL_RTL_PASS direct P102 full-frame clear/draw/depth/blend/scissor");
    $finish;
  end
  initial begin
    #300000;
    $fatal(1,"P132 differential watchdog");
  end
endmodule
