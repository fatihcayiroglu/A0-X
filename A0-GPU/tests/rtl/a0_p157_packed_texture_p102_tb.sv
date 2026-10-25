`timescale 1ns/1ps
// Real P153 76-bit packed host command + actual per-pixel P151 shader,
// P38 raster and P144 BRAM, independently checked vs P102 coverage and
// separate exact scalar per-pixel shading oracle on three shapes.
module a0_p157_packed_texture_p102_tb #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4
);
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req_valid=0,req_write=0;
  reg [4:0] req_addr=0;
  reg [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;
  wire ref_clear_ready,ref_clear_done,ref_tri_ready,ref_tri_done;
  wire ref_init,ref_busy,ref_pixel_wrote,ref_read_valid;
  wire [23:0] ref_color,ref_depth;
  reg [15:0] read_x=0,read_y=0;
  reg signed [15:0] x0=-16'sd257,y0=-16'sd257;
  reg signed [15:0] x1=16'sd1024,y1=-16'sd257;
  reg signed [15:0] x2=-16'sd257,y2=16'sd1024;
  reg [23:0] clear_color=24'h102030,depth_color=24'hffffff;
  reg [23:0] tri_depth=24'h40;
  reg [1:0] ref_depth_op=0;
  reg ref_scissor_enable=0;
  reg [23:0] marker=24'heeddcc;
  integer txns=0,rejected=0,pixels=0,covered=0;
  a0_p157_packed_textured_command_top #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_write(req_write),.req_ready(req_ready),
    .req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata)
  );
  wire clear_fire=req_valid&&req_ready&&req_write&&req_addr==5'd11&&req_wdata==32'd1;
  wire tri_fire=req_valid&&req_ready&&req_write&&req_addr==5'd11&&req_wdata==32'd2;
  a0_triangle_scissor_depth_blend_p102 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) reference(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(clear_fire),.clear_ready(ref_clear_ready),
    .clear_color(clear_color),.clear_depth(depth_color),
    .clear_done(ref_clear_done),
    .tri_valid(tri_fire),.tri_ready(ref_tri_ready),.tri_done(ref_tri_done),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(marker),.tri_depth(tri_depth),
    .depth_compare_op(ref_depth_op),.depth_write(1'b1),
    .blend_enable(1'b0),.source_alpha(8'd0),
    .scissor_enable(ref_scissor_enable),.scissor_x(16'd1),.scissor_y(16'd1),
    .scissor_w(16'd2),.scissor_h(16'd2),
    .initialized(ref_init),.busy(ref_busy),
    .read_x(read_x),.read_y(read_y),.read_valid(ref_read_valid),
    .read_color(ref_color),.read_depth(ref_depth),.pixel_wrote(ref_pixel_wrote)
  );
  task automatic txn(
    input reg wr,input reg [4:0] addr,input reg [31:0] data,
    output reg err,output reg [31:0] result
  );
    integer n;reg found;
    begin
      @(negedge clk);n=0;
      while(!req_ready)begin
        @(negedge clk);n=n+1;
        if(n>500)$fatal(1,"P153 packed bus request stalled");
      end
      req_write=wr;req_addr=addr;req_wdata=data;req_valid=1;
      @(posedge clk);#2;
      found=rsp_valid;
      if(found)begin err=rsp_error;result=rsp_rdata;end
      @(negedge clk);req_valid=0;
      n=0;
      while(!found)begin
        @(posedge clk);#2;
        if(rsp_valid)begin found=1;err=rsp_error;result=rsp_rdata;end
        n=n+1;
        if(n>200)$fatal(1,"P153 packed bus response timeout");
      end
      txns=txns+1;
      if(err)rejected=rejected+1;
    end
  endtask
  task automatic wr(input reg [4:0] addr,input reg [31:0] data);
    reg err;reg [31:0] result;
    begin
      txn(1,addr,data,err,result);
      if(err)$fatal(1,"P153 unexpected write rejection addr=%0d data=%h",addr,data);
    end
  endtask
  task automatic rd(input reg [4:0] addr,output reg [31:0] result);
    reg err;
    begin
      txn(0,addr,0,err,result);
      if(err)$fatal(1,"P153 unexpected read rejection addr=%0d",addr);
    end
  endtask
  task automatic expect_error(input reg write_v,input reg [4:0] addr,input reg [31:0] val);
    reg err;reg [31:0] result;
    begin
      txn(write_v,addr,val,err,result);
      if(!err)$fatal(1,"P153 accepted unsupported host command %0d",addr);
    end
  endtask
  task automatic poll_status(input integer done_bit);
    integer n;reg [31:0] status;
    begin
      n=0;status=0;
      while(!status[done_bit])begin
        rd(12,status);n=n+1;
        if(n>FRAME_WIDTH*FRAME_HEIGHT*40+90)
          $fatal(1,"P153 packed render/clear timeout status=%h",status);
        if(status[2])$fatal(1,"P153 packed raster fault status=%h",status);
      end
      n=0;
      while((done_bit==3 && !ref_clear_done && !ref_init) ||
            (done_bit==4 && ref_busy))begin
        @(negedge clk);n=n+1;
        if(n>FRAME_WIDTH*FRAME_HEIGHT*12+40)
          $fatal(1,"P153 P102 reference did not finish");
      end
    end
  endtask
  function automatic [31:0] texel_color(input integer xx,yy);
    // Deterministic, spatially varying RGBA8888, independently
    // computed by test and stored through actual packed bus RAM writes.
    texel_color=32'hff000000 |
      (32'((yy*13+7)&255)<<16) |
      (32'((xx*17+3)&255)<<8) |
      32'((xx^yy^8'h55)&255);
  endfunction
  task automatic check_pixel(input integer xx,yy);
    reg [31:0] col,z;
    reg [23:0] expected;
    begin
      read_x=16'(xx);read_y=16'(yy);
      wr(10,{16'(yy),16'(xx)});
      wr(11,32'd3);
      rd(13,col);rd(14,z);
      if(!ref_read_valid)$fatal(1,"P153 P102 missing valid pixel");
      expected=(ref_color==marker)?24'(texel_color(xx,yy)):clear_color;
      if(col[23:0]!==expected || z[23:0]!==ref_depth)
        $fatal(1,"P153 packed per-pixel shader RGB mismatch xy=%0d,%0d got=%h/%h expected=%h/%h",
           xx,yy,col[23:0],z[23:0],expected,ref_depth);
      pixels=pixels+1;
      if(ref_color==marker)covered=covered+1;
    end
  endtask
  reg [31:0] out;
  integer tex_writes=0,scene_reject=0;
  task automatic scene_readback;
    begin
      for(integer yy=0;yy<FRAME_HEIGHT;yy=yy+1)
        for(integer xx=0;xx<FRAME_WIDTH;xx=xx+1)
          check_pixel(xx,yy);
    end
  endtask
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    rd(15,out);
    if(out!==32'hA0157001)$fatal(1,"P157 wrong textured bus ID");
    expect_error(1,9,32'h10000); // high reserved MODE bits
    expect_error(1,25,32'h100); // invalid texture-coordinate reserved bits
    expect_error(1,18,32'hff000000);
    expect_error(1,19,0);
    wr(0,{8'd0,clear_color});
    wr(1,{8'd0,depth_color});
    wr(11,1);poll_status(3);
    // Real 16x16 texture uploaded through P157 76-I/O host bus.
    for(integer yy=0;yy<16;yy=yy+1)
      for(integer xx=0;xx<16;xx=xx+1)begin
        wr(25,{24'd0,4'(yy),4'(xx)});
        wr(26,texel_color(xx,yy));
        tex_writes=tex_writes+1;
      end
    // MOV_B from sampled texel R1 to shader output R2; no software
    // colour injected into the GPU pipeline for any pixel.
    wr(16,32'd0);
    wr(18,{8'd0,4'hf,3'd1,3'd2,3'd0,3'd1});
    wr(19,1);
    wr(4,{y0,x0});wr(5,{y1,x1});wr(6,{y2,x2});
    wr(3,{8'd0,tri_depth});
    wr(9,32'h44); // texture_enable bit6, depth_write bit2
    wr(11,2);poll_status(4);
    scene_readback();
    rd(27,out);
    if(out!==32'(FRAME_WIDTH*FRAME_HEIGHT))
      $fatal(1,"P157 visible triangle missed texture samples %0d",out);
    rd(23,out);
    if(out!==32'(FRAME_WIDTH*FRAME_HEIGHT))
      $fatal(1,"P157 shader count != texture covered pixels %0d",out);

    // A conservative Early-Z rejection must suppress BOTH texture
    // reads and shader programs when incoming depth is occluded.
    depth_color=24'h000010;
    wr(1,{8'd0,depth_color});wr(11,1);poll_status(3);
    ref_depth_op=1;tri_depth=24'h80;
    wr(3,{8'd0,tri_depth});
    wr(9,32'h65); // texture+early_depth+depth_write+LESS
    wr(11,2);poll_status(4);
    scene_readback();
    rd(24,out);
    if(out!==32'(FRAME_WIDTH*FRAME_HEIGHT))
      $fatal(1,"P157 Early-Z did not reject all fragments");
    scene_reject=int'(out);
    rd(27,out);if(out!==0)$fatal(1,"P157 sampled texture despite Early-Z occlusion");
    rd(23,out);if(out!==0)$fatal(1,"P157 invoked shader despite Early-Z occlusion");

    // Switch to repeat address mode + 2x2 scissor. Exactly four
    // distinct covered pixels should sample actual RAM texels.
    depth_color=24'hffffff;
    wr(1,{8'd0,depth_color});wr(11,1);poll_status(3);
    ref_depth_op=0;ref_scissor_enable=1;tri_depth=24'h40;
    wr(3,{8'd0,tri_depth});
    wr(7,{16'd1,16'd1});wr(8,{16'd2,16'd2});
    wr(9,32'hd4); // repeat bit7, texture bit6, scissor bit4, depthwrite bit2
    wr(11,2);poll_status(4);
    scene_readback();
    rd(27,out);if(out!==4)$fatal(1,"P157 scissor should fetch exactly 4 texels");
    rd(23,out);if(out!==4)$fatal(1,"P157 scissor should shade exactly 4 fragments");
    expect_error(0,26,0); // Texture RAM upload register is write-only.
    expect_error(1,2,32'hff102030);
    expect_error(0,31,0);
    if(pixels!=3*FRAME_WIDTH*FRAME_HEIGHT ||
       covered!=FRAME_WIDTH*FRAME_HEIGHT+4 || tex_writes!=256 ||
       scene_reject!=FRAME_WIDTH*FRAME_HEIGHT ||
       txns<512+8*FRAME_WIDTH*FRAME_HEIGHT || rejected<6)
      $fatal(1,"P157 vacuous texture/shader coverage reads=%0d covered=%0d texwrites=%0d rejected=%0d bus=%0d",
         pixels,covered,tex_writes,scene_reject,txns);
    $display("P157_TEXTURED_FRAGMENT_P102_PASS size=%0dx%0d pixel_readbacks=%0d textured_covered=%0d occluded_skips=%0d uploaded_texels=%0d host_packets=%0d invalid_packets=%0d",
       FRAME_WIDTH,FRAME_HEIGHT,pixels,covered,scene_reject,tex_writes,txns,rejected);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P153 packed shader bus watchdog");end
endmodule
