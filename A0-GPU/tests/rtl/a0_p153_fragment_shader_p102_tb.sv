`timescale 1ns/1ps
// P153 independent per-fragment shaded framebuffer oracle. Unchanged P102
// defines exact top-left coverage/depth. Independent scalar per-pixel
// shader math supplies expected RGB for covered pixels.
module a0_p153_fragment_shader_p102_tb #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4
);
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,clear_valid=0,tri_valid=0,host_read_valid=0;
  reg [23:0] clear_color=24'h102030,clear_depth=24'hffffff,tri_depth=24'h50;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  reg [1:0] depth_compare_op=0;
  reg depth_write=1,blend_enable=0;
  reg [7:0] source_alpha=0;
  reg shader_reg_write_valid=0,shader_insn_write_valid=0;
  reg [2:0] shader_reg_write_index=0,shader_debug_index=0;
  reg [31:0] shader_reg_write_data=0;
  reg [3:0] shader_insn_write_index=0;
  reg [23:0] shader_insn_write_data=0;
  reg [4:0] shader_program_length=1;
  reg [15:0] host_read_x=0,host_read_y=0,ref_read_x=0,ref_read_y=0;
  wire c_ready,c_done,t_ready,t_done,initialized,busy,fault;
  wire [1:0] pixel_writes;
  wire host_read_ready,host_rsp_valid,host_rsp_error;
  wire [23:0] host_rgb,host_depth;
  wire shader_config_ready,shader_done;
  wire [4:0] shader_retired_count;
  wire [31:0] shader_debug_data;
  wire [23:0] last_shaded_rgb;
  wire [15:0] shaded_pixels;
  wire rc_ready,rc_done,rt_ready,rt_done,ref_init,ref_busy,ref_wrote,ref_read_valid;
  wire [23:0] ref_rgb,ref_z;
  integer colors_checked=0,pixels_shaded=0,shader_done_count=0;
  integer draws=0,clears=0,read_errors=0,host_stalls=0;
  reg [23:0] marker=24'heeddcc;
  reg [31:0] secondary=32'h000a2010;
  reg [2:0] shader_opcode=2;
  reg [7:0] shader_alpha=0;
  reg [3:0] shader_mask=4'hf;

  a0_p153_fragment_shader_trial #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) dut(
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(c_ready),.clear_done(c_done),
    .clear_color(clear_color),.clear_depth(clear_depth),
    .tri_valid(tri_valid),.tri_ready(t_ready),.tri_done(t_done),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_depth(tri_depth),.depth_compare_op(depth_compare_op),
    .depth_write(depth_write),.blend_enable(blend_enable),
    .source_alpha(source_alpha),
    .shader_program_length(shader_program_length),
    .shader_reg_write_valid(shader_reg_write_valid),
    .shader_reg_write_index(shader_reg_write_index),
    .shader_reg_write_data(shader_reg_write_data),
    .shader_insn_write_valid(shader_insn_write_valid),
    .shader_insn_write_index(shader_insn_write_index),
    .shader_insn_write_data(shader_insn_write_data),
    .shader_debug_index(shader_debug_index),
    .shader_debug_data(shader_debug_data),
    .shader_config_ready(shader_config_ready),
    .shader_done(shader_done),
    .shader_retired_count(shader_retired_count),
    .last_shaded_rgb(last_shaded_rgb),
    .shaded_pixels(shaded_pixels),.initialized(initialized),
    .busy(busy),.fault(fault),.pixel_writes(pixel_writes),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_rgb),.host_rsp_depth(host_depth)
  );
  a0_triangle_scissor_depth_blend_p102 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) reference(
    .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),
    .clear_ready(rc_ready),.clear_done(rc_done),
    .clear_color(clear_color),.clear_depth(clear_depth),
    .tri_valid(tri_valid),.tri_ready(rt_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(marker),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(1'b0),.scissor_x(16'd0),.scissor_y(16'd0),
    .scissor_w(16'd0),.scissor_h(16'd0),
    .tri_done(rt_done),.initialized(ref_init),.busy(ref_busy),
    .read_x(ref_read_x),.read_y(ref_read_y),
    .read_valid(ref_read_valid),.read_color(ref_rgb),
    .read_depth(ref_z),.pixel_wrote(ref_wrote)
  );
  function automatic [31:0] independent_shader(
    input integer xx,yy
  );
    integer lane,a,b,z,n;
    reg [31:0] first,ret;
    begin
      first={8'hff,8'(yy),8'(xx),8'h40};ret=0;
      for(lane=0;lane<4;lane=lane+1)begin
        a=(first>>(8*lane))&255;
        b=(secondary>>(8*lane))&255;
        z=a;
        if(shader_mask[lane])begin
          case(shader_opcode)
            0:z=a;
            1:z=b;
            2:begin n=a+b;z=n>255?255:n;end
            3:z=a<b?0:a-b;
            4:z=(a*b+127)/255;
            5:z=a<b?a:b;
            6:z=a>b?a:b;
            7:z=(a*(255-int'(shader_alpha))+b*int'(shader_alpha)+127)/255;
          endcase
        end
        ret[8*lane+:8]=8'(z);
      end
      independent_shader=ret;
    end
  endfunction
  always @(posedge clk)begin
    if(rst_n && fault)$fatal(1,"P153 fail-closed fault during valid graphics scene");
    if(rst_n && shader_done)shader_done_count=shader_done_count+1;
    if(rst_n && host_read_valid && busy && !host_read_ready)
      host_stalls=host_stalls+1;
  end
  task automatic load_shader;
    begin
      @(negedge clk);
      if(!shader_config_ready)$fatal(1,"P153 shader config not ready");
      shader_reg_write_valid=1;shader_reg_write_index=1;
      shader_reg_write_data=secondary;
      @(negedge clk);shader_reg_write_valid=0;
      shader_insn_write_valid=1;shader_insn_write_index=0;
      shader_insn_write_data={shader_alpha,shader_mask,shader_opcode,
                              3'd2,3'd0,3'd1};
      @(negedge clk);shader_insn_write_valid=0;
    end
  endtask
  task automatic read_xy(input integer xx,yy,input reg had_draw);
    integer n;
    reg [23:0] expected_color;
    reg [31:0] expected_shader;
    begin
      @(negedge clk);
      host_read_x=16'(xx);host_read_y=16'(yy);
      ref_read_x=16'(xx);ref_read_y=16'(yy);
      host_read_valid=1;n=0;
      while(!host_read_ready)begin
        @(negedge clk);n=n+1;
        if(n>FRAME_WIDTH*FRAME_HEIGHT*20+60)
          $fatal(1,"P153 pixel debug read timeout");
      end
      @(posedge clk);@(negedge clk);host_read_valid=0;
      if(!host_rsp_valid)$fatal(1,"P153 missing host pixel response");
      if(xx<FRAME_WIDTH&&yy<FRAME_HEIGHT)begin
        expected_shader=independent_shader(xx,yy);
        expected_color=(had_draw && ref_rgb==marker)?
                         expected_shader[23:0]:clear_color;
        if(!ref_read_valid || host_rsp_error ||
           host_rgb!==expected_color || host_depth!==ref_z)
          $fatal(1,"P153 per-fragment shaded mismatch xy=%0d,%0d coverage=%h expected=%h/%h got=%h/%h",
            xx,yy,ref_rgb,expected_color,ref_z,host_rgb,host_depth);
        colors_checked=colors_checked+1;
        if(had_draw && ref_rgb==marker)pixels_shaded=pixels_shaded+1;
      end else begin
        if(ref_read_valid || !host_rsp_error || host_rgb!==0 || host_depth!==0)
          $fatal(1,"P153 invalid framebuffer debug XY not rejected");
        read_errors=read_errors+1;
      end
    end
  endtask
  task automatic frame_check(input reg had_draw);
    begin
      if(!initialized || !ref_init)
        $fatal(1,"P153 framebuffer not initialized");
      for(integer yy=0;yy<FRAME_HEIGHT;yy=yy+1)
        for(integer xx=0;xx<FRAME_WIDTH;xx=xx+1)
          read_xy(xx,yy,had_draw);
      read_xy(FRAME_WIDTH,0,had_draw);
      read_xy(0,FRAME_HEIGHT,had_draw);
    end
  endtask
  task automatic do_clear(input reg [23:0] rgb,z);
    reg done_a,done_b;
    begin
      @(negedge clk);
      if(!c_ready||!rc_ready)$fatal(1,"P153 clear readiness mismatch");
      clear_color=rgb;clear_depth=z;clear_valid=1;
      @(negedge clk);clear_valid=0;
      done_a=c_done;done_b=rc_done;
      for(integer n=0;n<FRAME_WIDTH*FRAME_HEIGHT*8+60 && !(done_a&&done_b);n=n+1)begin
        @(negedge clk);
        if(c_done)done_a=1;
        if(rc_done)done_b=1;
      end
      if(!(done_a&&done_b))$fatal(1,"P153 clear did not finish");
      clears=clears+1;
      frame_check(0);
    end
  endtask
  task automatic do_triangle(
    input reg signed [15:0] ax,ay,bx,by,cx,cy
  );
    reg done_a,done_b;
    integer before_shaded,before_done,covered;
    begin
      load_shader();
      @(negedge clk);
      if(!t_ready || !rt_ready)$fatal(1,"P153 triangle readiness mismatch");
      x0=ax;y0=ay;x1=bx;y1=by;x2=cx;y2=cy;
      before_shaded=pixels_shaded;before_done=shader_done_count;
      tri_valid=1;
      @(negedge clk);tri_valid=0;
      done_a=t_done;done_b=rt_done;
      for(integer n=0;n<FRAME_WIDTH*FRAME_HEIGHT*26+160 && !(done_a&&done_b);n=n+1)begin
        @(negedge clk);
        host_read_valid=(n<15);host_read_x=0;host_read_y=0;
        if(t_done)done_a=1;
        if(rt_done)done_b=1;
      end
      host_read_valid=0;
      if(!(done_a&&done_b))
        $fatal(1,"P153 real per-fragment raster or P102 did not finish");
      draws=draws+1;
      frame_check(1);
      covered=pixels_shaded-before_shaded;
      if(shaded_pixels!==16'(covered))
        $fatal(1,"P153 pixel shader invocation count %0d differs P102 covered pixels %0d",
          shaded_pixels,covered);
      if(shader_done_count-before_done != covered)
        $fatal(1,"P153 actual P151 shader completion count differs covered count");
    end
  endtask
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    do_clear(24'h102030,24'hffffff);
    shader_opcode=2;secondary=32'h000a2010;shader_alpha=0;
    tri_depth=24'h40;
    do_triangle(-16'sd257,-16'sd257,16'sd1024,-16'sd257,
                -16'sd257,16'sd1024);
    do_clear(24'h102030,24'hffffff);
    shader_opcode=7;secondary=32'h55a1c320;shader_alpha=8'd128;
    tri_depth=24'h20;
    do_triangle(-16'sd257,-16'sd257,-16'sd257,16'sd1024,
                16'sd1024,-16'sd257);
    // Abort an active per-fragment invocation, recover using reset.
    @(negedge clk);if(!t_ready||!rt_ready)$fatal(1,"P153 pre-reset readiness");
    x0=-257;y0=-257;x1=1024;y1=-257;x2=-257;y2=1024;tri_valid=1;
    @(negedge clk);tri_valid=0;
    repeat(7)@(negedge clk);
    rst_n=0;
    repeat(4)@(negedge clk);
    if(initialized || ref_init || t_done || c_done || shader_done)
      $fatal(1,"P153 reset left visible framebuffer/fragment state");
    rst_n=1;
    do_clear(24'h102030,24'hffffff);
    shader_opcode=4;secondary=32'hffffffff;shader_alpha=0;
    tri_depth=24'h08;
    do_triangle(-16'sd257,-16'sd257,16'sd1024,-16'sd257,
                -16'sd257,16'sd1024);
    if(clears!=3||draws!=3||colors_checked<6*FRAME_WIDTH*FRAME_HEIGHT||
       pixels_shaded<5 || shader_done_count<5 || read_errors<6 ||
       host_stalls<1)
      $fatal(1,"P153 vacuous coverage clears=%0d draws=%0d checks=%0d shaded=%0d done=%0d stalls=%0d",
        clears,draws,colors_checked,pixels_shaded,shader_done_count,host_stalls);
    $display("P153_REAL_PER_FRAGMENT_SHADER_P102_PASS size=%0dx%0d clears=%0d draws=%0d checked=%0d shader_invocations=%0d done=%0d host_stalls=%0d",
      FRAME_WIDTH,FRAME_HEIGHT,clears,draws,colors_checked,
      pixels_shaded,shader_done_count,host_stalls);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P153 per-fragment shader watchdog");end
endmodule
