`timescale 1ns/1ps
// Independent scalar bilinear/UNORM oracle + unchanged P102 RGB/depth
// frame oracle for real P38 -> P159 BRAM -> P150 -> P144 fragment writes.
module a0_p160_textured_fragment_p102_tb;
  localparam integer W=4,H=4;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,tex_write_valid=0,clear_valid=0,tri_valid=0;
  reg host_read_valid=0;
  reg [3:0] tex_write_x=0,tex_write_y=0;
  reg [31:0] tex_write_rgba=0,shader_operand_b=32'h10203040;
  reg [23:0] clear_color=24'h112233,clear_depth=24'hffffff;
  reg [23:0] tri_depth=24'h40;
  reg signed [15:0] x0=-257,y0=-257,x1=1024,y1=-257,x2=-257,y2=1024;
  reg [1:0] depth_compare_op=1;
  reg depth_write=1,blend_enable=0,sample_repeat=0;
  reg [7:0] source_alpha=255,shader_alpha=128;
  reg signed [15:0] uv_offset_u=128,uv_offset_v=64;
  reg [2:0] shader_opcode=2;
  reg [3:0] shader_lane_mask=4'hf;
  reg [15:0] host_read_x=0,host_read_y=0,ref_read_x=0,ref_read_y=0;
  wire tex_write_ready,clear_ready,clear_done,tri_ready,tri_done;
  wire initialized,busy,fault,host_read_ready,host_rsp_valid,host_rsp_error;
  wire [15:0] shaded_pixels;
  wire [23:0] last_shaded_rgb,host_rsp_color,host_rsp_depth;
  wire [1:0] pixel_writes;
  wire rc_ready,rc_done,rt_ready,rt_done,ref_init,ref_busy,ref_wrote;
  wire ref_read_valid;
  wire [23:0] ref_rgb,ref_depth;
  reg [31:0] texture_image[0:255];
  integer draws=0,clears=0,checked=0,shader_pixels=0,host_stalls=0;
  integer clamp_draws=0,repeat_draws=0,miss_faults=0;
  localparam [23:0] MARKER=24'heeadbc;

  a0_p160_textured_fragment_trial #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H)) dut(
    .clk(clk),.rst_n(rst_n),
    .tex_write_valid(tex_write_valid),.tex_write_ready(tex_write_ready),
    .tex_write_x(tex_write_x),.tex_write_y(tex_write_y),
    .tex_write_rgba(tex_write_rgba),
    .clear_valid(clear_valid),.clear_ready(clear_ready),
    .clear_done(clear_done),.clear_color(clear_color),
    .clear_depth(clear_depth),
    .tri_valid(tri_valid),.tri_ready(tri_ready),.tri_done(tri_done),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_depth(tri_depth),.depth_compare_op(depth_compare_op),
    .depth_write(depth_write),.blend_enable(blend_enable),
    .source_alpha(source_alpha),
    .uv_offset_u(uv_offset_u),.uv_offset_v(uv_offset_v),
    .sample_repeat(sample_repeat),
    .shader_opcode(shader_opcode),.shader_operand_b(shader_operand_b),
    .shader_alpha(shader_alpha),.shader_lane_mask(shader_lane_mask),
    .initialized(initialized),.busy(busy),.fault(fault),
    .shaded_pixels(shaded_pixels),.last_shaded_rgb(last_shaded_rgb),
    .pixel_writes(pixel_writes),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_rsp_color),.host_rsp_depth(host_rsp_depth)
  );
  a0_triangle_scissor_depth_blend_p102 #(.FRAME_WIDTH(W),.FRAME_HEIGHT(H)) reference(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_valid),.clear_ready(rc_ready),
    .clear_color(clear_color),.clear_depth(clear_depth),.clear_done(rc_done),
    .tri_valid(tri_valid),.tri_ready(rt_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(MARKER),.tri_depth(tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(1'b0),.scissor_x(16'd0),.scissor_y(16'd0),
    .scissor_w(16'd0),.scissor_h(16'd0),
    .tri_done(rt_done),.initialized(ref_init),.busy(ref_busy),
    .read_x(ref_read_x),.read_y(ref_read_y),
    .read_valid(ref_read_valid),.read_color(ref_rgb),
    .read_depth(ref_depth),.pixel_wrote(ref_wrote)
  );

  function automatic integer tex_idx(input integer x,y,repeat_mode);
    integer xx,yy;
    begin
      xx=repeat_mode?(x&15):(x<0?0:(x>15?15:x));
      yy=repeat_mode?(y&15):(y<0?0:(y>15?15:y));
      tex_idx=yy*16+xx;
    end
  endfunction
  function automatic [31:0] bilinear_oracle(input integer xx,yy);
    integer u,v,bx,by,fx,fy,i0,i1,i2,i3,lane,a,b,c,d,t0,t1;
    reg [31:0] result;
    begin
      u=xx*256+int'(uv_offset_u);
      v=yy*256+int'(uv_offset_v);
      bx=u>>>8;by=v>>>8;fx=u&255;fy=v&255;
      i0=tex_idx(bx,by,sample_repeat);
      i1=tex_idx(bx+1,by,sample_repeat);
      i2=tex_idx(bx,by+1,sample_repeat);
      i3=tex_idx(bx+1,by+1,sample_repeat);
      result=0;
      for(lane=0;lane<4;lane=lane+1)begin
        a=(texture_image[i0]>>(8*lane))&255;
        b=(texture_image[i1]>>(8*lane))&255;
        c=(texture_image[i2]>>(8*lane))&255;
        d=(texture_image[i3]>>(8*lane))&255;
        t0=(a*(256-fx)+b*fx+128)/256;
        t1=(c*(256-fx)+d*fx+128)/256;
        result[8*lane+:8]=8'((t0*(256-fy)+t1*fy+128)/256);
      end
      bilinear_oracle=result;
    end
  endfunction
  function automatic [31:0] shade_oracle(input integer xx,yy);
    integer a,b,k,lane,n,alpha;
    reg [31:0] tex,out;
    begin
      tex=bilinear_oracle(xx,yy);out=0;
      for(lane=0;lane<4;lane=lane+1)begin
        a=(tex>>(8*lane))&255;b=(shader_operand_b>>(8*lane))&255;
        alpha=int'(shader_alpha);k=a;
        if(shader_lane_mask[lane])case(shader_opcode)
          0:k=a;1:k=b;2:begin n=a+b;k=n>255?255:n;end
          3:k=a>=b?a-b:0;
          4:k=(a*b+127)/255;
          5:k=a<b?a:b;6:k=a>b?a:b;
          7:k=(a*(255-alpha)+b*alpha+127)/255;
        endcase
        out[8*lane+:8]=8'(k);
      end
      shade_oracle=out;
    end
  endfunction
  task automatic write_texel(input integer xx,yy,input [31:0] rgba);
    begin
      @(negedge clk);
      tex_write_x=4'(xx);tex_write_y=4'(yy);
      tex_write_rgba=rgba;tex_write_valid=1;
      #1;if(!tex_write_ready)$fatal(1,"P160 texture host write refused");
      @(negedge clk);tex_write_valid=0;
      texture_image[yy*16+xx]=rgba;
    end
  endtask
  task automatic load_texture;
    reg [31:0] value;
    begin
      for(integer y=0;y<16;y=y+1)
        for(integer x=0;x<16;x=x+1)begin
          value=32'h6e93c527 ^ (32'(x)*32'h13375111) ^
                (32'(y)*32'h37d52a07);
          write_texel(x,y,value);
        end
    end
  endtask
  task automatic read_pixel(input integer xx,yy,drawn);
    integer loops;
    reg [23:0] expected;
    reg [31:0] shaded;
    begin
      @(negedge clk);
      host_read_x=16'(xx);host_read_y=16'(yy);
      ref_read_x=16'(xx);ref_read_y=16'(yy);
      host_read_valid=1;loops=0;
      while(!host_read_ready)begin
        @(negedge clk);loops=loops+1;
        if(loops>100)$fatal(1,"P160 host read timeout");
      end
      @(posedge clk);@(negedge clk);host_read_valid=0;
      if(!host_rsp_valid || host_rsp_error || !ref_read_valid)
        $fatal(1,"P160 host/reference valid mismatch");
      shaded=shade_oracle(xx,yy);
      expected=(drawn && ref_rgb==MARKER)?shaded[23:0]:clear_color;
      if(host_rsp_color!==expected || host_rsp_depth!==ref_depth)
        $fatal(1,"P160 pixel oracle mismatch xy=%0d,%0d got=%h/%h expected=%h/%h reference=%h",
          xx,yy,host_rsp_color,host_rsp_depth,expected,ref_depth,ref_rgb);
      checked=checked+1;
      if(drawn && ref_rgb==MARKER)shader_pixels=shader_pixels+1;
    end
  endtask
  task automatic frame_check(input integer drawn);
    begin
      for(integer yy=0;yy<H;yy=yy+1)
        for(integer xx=0;xx<W;xx=xx+1)read_pixel(xx,yy,drawn);
    end
  endtask
  task automatic clear_frame;
    reg got_dut,got_ref;
    begin
      @(negedge clk);
      if(!clear_ready || !rc_ready)$fatal(1,"P160 clear not ready");
      clear_valid=1;
      @(negedge clk);clear_valid=0;
      got_dut=clear_done;got_ref=rc_done;
      for(integer n=0;n<350 && !(got_dut&&got_ref);n=n+1)begin
        @(negedge clk);if(clear_done)got_dut=1;if(rc_done)got_ref=1;
      end
      if(!(got_dut&&got_ref) || !initialized || !ref_init)
        $fatal(1,"P160 real framebuffer clear failed");
      clears=clears+1;frame_check(0);
    end
  endtask
  task automatic draw_triangle;
    reg got_dut,got_ref;
    integer prior;
    begin
      @(negedge clk);
      if(!tri_ready || !rt_ready)$fatal(1,"P160 triangle not ready");
      prior=shader_pixels;
      tri_valid=1;
      @(negedge clk);tri_valid=0;
      got_dut=tri_done;got_ref=rt_done;
      for(integer n=0;n<1800 && !(got_dut&&got_ref);n=n+1)begin
        @(negedge clk);
        host_read_valid=n<14;
        if(host_read_valid && busy && !host_read_ready)
          host_stalls=host_stalls+1;
        if(fault)$fatal(1,"P160 unexpected texture or BRAM failure");
        if(tri_done)got_dut=1;if(rt_done)got_ref=1;
      end
      host_read_valid=0;
      if(!(got_dut&&got_ref))$fatal(1,"P160 triangle did not finish");
      draws=draws+1;frame_check(1);
      if(shaded_pixels!==16'(shader_pixels-prior))
        $fatal(1,"P160 ALU/RMW invocation count did not equal P102 coverage");
      if(sample_repeat)repeat_draws=repeat_draws+1;
      else clamp_draws=clamp_draws+1;
    end
  endtask
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    load_texture();
    clear_frame();
    shader_opcode=2;shader_operand_b=32'h10203040;
    uv_offset_u=-16'sd384;uv_offset_v=16'sd3904;
    sample_repeat=0;
    draw_triangle();
    clear_frame();
    shader_opcode=4;shader_operand_b=32'hd0c08050;
    uv_offset_u=-16'sd384;uv_offset_v=16'sd3904;
    sample_repeat=1;
    draw_triangle();
    clear_frame();
    shader_opcode=7;shader_alpha=8'd173;
    shader_operand_b=32'hff91501a;
    uv_offset_u=16'sd95;uv_offset_v=-16'sd417;
    sample_repeat=1;
    draw_triangle();
    // A reset invalidates every P156 texture present bit. The next draw
    // must fail closed rather than write framebuffer pixels from stale RAM.
    @(negedge clk);rst_n=0;
    repeat(4)@(negedge clk);rst_n=1;
    clear_frame();
    write_texel(0,0,32'hffffffff);
    @(negedge clk);
    if(!tri_ready)$fatal(1,"P160 before missing-texture test not ready");
    tri_valid=1;
    @(negedge clk);tri_valid=0;
    for(integer n=0;n<220 && !fault;n=n+1)@(negedge clk);
    if(!fault || tri_done || tex_write_ready || host_read_ready)
      $fatal(1,"P160 uninitialized texel did not latch fail-closed fault");
    miss_faults=miss_faults+1;
    if(draws!=3 || clears!=4 || checked!=7*W*H ||
       shader_pixels<12 || host_stalls<3 ||
       clamp_draws!=1 || repeat_draws!=2 || miss_faults!=1)
      $fatal(1,"P160 insufficient real graphics coverage draws=%0d clears=%0d frames=%0d fragments=%0d stalls=%0d",
        draws,clears,checked,shader_pixels,host_stalls);
    $display("P160_TEXTURED_FRAGMENT_P102_PASS draws=%0d clears=%0d frame_pixels=%0d fragments=%0d clamp=%0d repeat=%0d host_stalls=%0d missing_fault=%0d",
      draws,clears,checked,shader_pixels,clamp_draws,repeat_draws,
      host_stalls,miss_faults);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P160 global watchdog");end
endmodule
