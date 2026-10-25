`timescale 1ns/1ps
// P161 real 76-bit host transfers vs independent P102 coverage/depth and
// scalar bilinear+P150 per-channel arithmetic. All texels host-programmed.
module a0_p161_packed_textured_p102_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req_valid=0,req_write=0;
  reg [4:0] req_addr=0;
  reg [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;
  reg [15:0] ref_x=0,ref_y=0;
  reg signed [15:0] x0=-257,y0=-257,x1=1024,y1=-257,x2=-257,y2=1024;
  reg signed [15:0] uv_u=-384,uv_v=3904;
  reg [31:0] shader_b=32'h10203040;
  reg [2:0] opcode=2;
  reg [7:0] shader_alpha=128;
  reg [3:0] lane_mask=4'hf;
  reg sample_repeat=0;
  reg [23:0] clear_rgb=24'h112233,clear_depth=24'hffffff;
  reg [23:0] tri_depth=24'h000040;
  wire ref_clear_ready,ref_clear_done,ref_tri_ready,ref_tri_done;
  wire ref_init,ref_busy,ref_wrote,ref_read_valid;
  wire [23:0] ref_color,ref_depth;
  localparam [23:0] MARKER=24'hdeadbc;
  integer transactions=0,errors=0,texwrites=0;
  integer clears=0,draws=0,checked=0,covered=0,missing_faults=0;
  wire fire=req_valid&&req_ready&&req_write;
  wire clear_fire=fire&&req_addr==5'd13&&req_wdata==1;
  wire tri_fire=fire&&req_addr==5'd13&&req_wdata==2;
  a0_p161_packed_textured_command_top dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_write(req_write),.req_ready(req_ready),
    .req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata)
  );
  a0_triangle_scissor_depth_blend_p102 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) reference(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_fire),.clear_ready(ref_clear_ready),
    .clear_color(clear_rgb),.clear_depth(clear_depth),.clear_done(ref_clear_done),
    .tri_valid(tri_fire),.tri_ready(ref_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(MARKER),.tri_depth(tri_depth),
    .depth_compare_op(2'd1),.depth_write(1'b1),
    .blend_enable(1'b0),.source_alpha(8'hff),
    .scissor_enable(1'b0),.scissor_x(16'd0),.scissor_y(16'd0),
    .scissor_w(16'd0),.scissor_h(16'd0),
    .tri_done(ref_tri_done),.initialized(ref_init),.busy(ref_busy),
    .read_x(ref_x),.read_y(ref_y),
    .read_valid(ref_read_valid),.read_color(ref_color),
    .read_depth(ref_depth),.pixel_wrote(ref_wrote)
  );

  function automatic [31:0] texel(input integer xx,yy);
    begin
      texel=32'h6e93c527 ^ (32'(xx)*32'h13375111) ^
            (32'(yy)*32'h37d52a07);
    end
  endfunction
  function automatic integer addr(input integer xx,yy,repeat_mode);
    integer x,y;
    begin
      x=repeat_mode?(xx&15):(xx<0?0:(xx>15?15:xx));
      y=repeat_mode?(yy&15):(yy<0?0:(yy>15?15:yy));
      addr=y*16+x;
    end
  endfunction
  function automatic [31:0] oracle_color(input integer xx,yy);
    integer u,v,bx,by,fx,fy,i0,i1,i2,i3,lane,a,b,c,d,h0,h1,k,n,al;
    reg [31:0] mixed,out;
    begin
      u=xx*256+int'(uv_u);v=yy*256+int'(uv_v);
      bx=u>>>8;by=v>>>8;fx=u&255;fy=v&255;
      i0=addr(bx,by,sample_repeat);i1=addr(bx+1,by,sample_repeat);
      i2=addr(bx,by+1,sample_repeat);i3=addr(bx+1,by+1,sample_repeat);
      mixed=0;out=0;al=int'(shader_alpha);
      for(lane=0;lane<4;lane=lane+1)begin
        a=(texel(i0&15,i0>>4)>>(lane*8))&255;
        b=(texel(i1&15,i1>>4)>>(lane*8))&255;
        c=(texel(i2&15,i2>>4)>>(lane*8))&255;
        d=(texel(i3&15,i3>>4)>>(lane*8))&255;
        h0=(a*(256-fx)+b*fx+128)/256;
        h1=(c*(256-fx)+d*fx+128)/256;
        mixed[8*lane+:8]=8'((h0*(256-fy)+h1*fy+128)/256);
      end
      for(lane=0;lane<4;lane=lane+1)begin
        a=(mixed>>(8*lane))&255;b=(shader_b>>(8*lane))&255;k=a;
        if(lane_mask[lane])case(opcode)
          0:k=a;1:k=b;2:begin n=a+b;k=n>255?255:n;end
          3:k=a>=b?a-b:0;4:k=(a*b+127)/255;
          5:k=a<b?a:b;6:k=a>b?a:b;
          7:k=(a*(255-al)+b*al+127)/255;
        endcase
        out[8*lane+:8]=8'(k);
      end
      oracle_color=out;
    end
  endfunction
  task automatic txn(input reg wr,input reg [4:0] address,
    input reg [31:0] data,output reg err,output reg [31:0] value);
    integer cycles;reg found;
    begin
      @(negedge clk);cycles=0;
      while(!req_ready)begin
        @(negedge clk);cycles=cycles+1;
        if(cycles>500)$fatal(1,"P161 bus request starved");
      end
      req_valid=1;req_write=wr;req_addr=address;req_wdata=data;
      @(posedge clk);#2;found=rsp_valid;
      if(found)begin err=rsp_error;value=rsp_rdata;end
      @(negedge clk);req_valid=0;
      cycles=0;
      while(!found)begin
        @(posedge clk);#2;
        if(rsp_valid)begin found=1;err=rsp_error;value=rsp_rdata;end
        cycles=cycles+1;
        if(cycles>600)$fatal(1,"P161 deferred framebuffer response timeout");
      end
      transactions=transactions+1;if(err)errors=errors+1;
    end
  endtask
  task automatic wr(input reg [4:0] address,input reg [31:0] data);
    reg err;reg [31:0] out;
    begin
      txn(1,address,data,err,out);
      if(err)$fatal(1,"P161 write denied addr=%0d data=%h",address,data);
    end
  endtask
  task automatic rd(input reg [4:0] address,output reg [31:0] out);
    reg err;
    begin
      txn(0,address,0,err,out);
      if(err)$fatal(1,"P161 read denied addr=%0d",address);
    end
  endtask
  task automatic reject(input reg wr_mode,input reg [4:0] address,
    input reg [31:0] data);
    reg err;reg [31:0] out;
    begin
      txn(wr_mode,address,data,err,out);
      if(!err)$fatal(1,"P161 invalid host transaction accepted addr=%0d",address);
    end
  endtask
  task automatic poll_done(input integer bit_index);
    integer n;reg [31:0] status;
    begin
      status=0;n=0;
      while(!status[bit_index])begin
        rd(14,status);n=n+1;
        if(status[2])$fatal(1,"P161 unexpected core fault %h",status);
        if(n>1200)$fatal(1,"P161 command completion timeout %h",status);
      end
    end
  endtask
  task automatic load_texture;
    reg [31:0] out;
    begin
      for(integer y=0;y<16;y=y+1)
        for(integer x=0;x<16;x=x+1)begin
          wr(11,32'((y<<4)|x));
          wr(12,texel(x,y));texwrites=texwrites+1;
        end
      rd(20,out);
      if(out!==32'd256)$fatal(1,"P161 texture write count lost");
    end
  endtask
  task automatic pixel_check(input integer xx,yy,drawn);
    reg [31:0] color,z;
    reg [23:0] expected;
    reg [31:0] shaded;
    begin
      ref_x=16'(xx);ref_y=16'(yy);
      wr(10,{16'(yy),16'(xx)});
      wr(13,3);
      rd(15,color);rd(16,z);
      shaded=oracle_color(xx,yy);
      expected=(drawn && ref_color==MARKER)?shaded[23:0]:clear_rgb;
      if(!ref_read_valid || color[23:0]!==expected || z[23:0]!==ref_depth)
        $fatal(1,"P161 packed texture P102 mismatch xy=%0d,%0d expected=%h/%h got=%h/%h",
          xx,yy,expected,ref_depth,color[23:0],z[23:0]);
      checked=checked+1;
      if(drawn && ref_color==MARKER)covered=covered+1;
    end
  endtask
  task automatic frame_check(input integer drawn);
    begin
      for(integer yy=0;yy<4;yy=yy+1)
        for(integer xx=0;xx<4;xx=xx+1)pixel_check(xx,yy,drawn);
    end
  endtask
  task automatic do_clear;
    begin
      wr(13,1);poll_done(3);clears=clears+1;
      if(!ref_init)$fatal(1,"P161 P102 framebuffer clear not complete");
      frame_check(0);
    end
  endtask
  task automatic do_draw;
    reg [31:0] out;
    integer before_covered;
    begin
      before_covered=covered;
      wr(13,2);poll_done(4);draws=draws+1;
      frame_check(1);
      rd(18,out);
      if(out!==32'(covered-before_covered))
        $fatal(1,"P161 real texture shader count differs P102 coverage");
    end
  endtask
  function automatic [31:0] mode_value(
    input reg rep,input [2:0] op,input [7:0] alpha);
    begin
      mode_value={1'b0,alpha,4'hf,op,8'hff,3'd0,rep,1'b0,1'b1,2'd1};
    end
  endfunction
  reg [31:0] out;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    rd(17,out);if(out!==32'hA0161001)$fatal(1,"P161 device ID mismatch");
    reject(1,8,32'h80000000);
    reject(1,11,32'h00000100);
    reject(1,13,32'd99);
    reject(0,15,0);
    load_texture();
    wr(0,{8'd0,clear_rgb});wr(1,{8'd0,clear_depth});
    wr(2,{8'd0,tri_depth});
    wr(3,{y0,x0});wr(4,{y1,x1});wr(5,{y2,x2});
    wr(7,shader_b);
    wr(6,{uv_v,uv_u});
    wr(8,mode_value(0,2,shader_alpha));
    rd(8,out);if(out!==mode_value(0,2,shader_alpha))
      $fatal(1,"P161 shader mode readback corrupt");
    do_clear();do_draw();
    shader_b=32'hff91501a;opcode=7;shader_alpha=173;
    sample_repeat=1;uv_u=95;uv_v=-417;
    wr(7,shader_b);wr(6,{uv_v,uv_u});
    wr(8,mode_value(sample_repeat,opcode,shader_alpha));
    do_clear();do_draw();
    if(texwrites!=256 || draws!=2 || clears!=2 || checked!=64 ||
       covered<12 || errors<4 || transactions<600)
      $fatal(1,"P161 vacuous packed bus proof tx=%0d errors=%0d checks=%0d cover=%0d",
        transactions,errors,checked,covered);
    $display("P161_PACKED_TEXTURED_P102_PASS txns=%0d texture_writes=%0d clears=%0d draws=%0d pixels=%0d covered=%0d rejected=%0d",
      transactions,texwrites,clears,draws,checked,covered,errors);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P161 global watchdog");end
endmodule
