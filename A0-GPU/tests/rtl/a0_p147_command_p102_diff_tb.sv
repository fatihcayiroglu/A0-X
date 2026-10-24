`timescale 1ns/1ps
// P147 genuine bus-driven golden frame differential. External DUT has only
// narrow 32-bit register transactions; P102 receives the SAME launch edge.
// No direct raster inputs are driven into DUT. Full signed 16-bit vertices
// including <-128/>127 are retained, never sign-extended from 8 bits.
module a0_p147_command_p102_diff_tb #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
);
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req_valid=0,req_write=0;
  reg [4:0] req_addr=0;
  reg [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;
  a0_p147_packed_command_top #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_write(req_write),
    .req_ready(req_ready),.req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata)
  );
  reg [23:0] ref_clear_color=0,ref_clear_depth=0;
  reg [23:0] ref_tri_color=0,ref_tri_depth=0;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  reg [1:0] depth_compare_op=0;
  reg depth_write=1,blend_enable=0,scissor_enable=0;
  reg [7:0] source_alpha=0;
  reg [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
  reg [15:0] ref_read_x=0,ref_read_y=0;
  wire ref_clear_ready,ref_clear_done,ref_tri_ready,ref_tri_done;
  wire ref_initialized,ref_busy,ref_read_valid,ref_pixel_wrote;
  wire [23:0] ref_color,ref_depth;
  wire launch_clear=req_valid&&req_ready&&req_write&&req_addr==5'd11&&req_wdata==1;
  wire launch_tri=req_valid&&req_ready&&req_write&&req_addr==5'd11&&req_wdata==2;
  integer ref_writes=0,dut_writes=0,dual_commits=0;
  integer clears=0,draws=0,checked=0,large_vertices=0;
  integer bus_txns=0,rejections=0,host_reads=0;
  reg ref_clear_seen=0,ref_tri_seen=0;
  a0_triangle_scissor_depth_blend_p102 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) reference(
    .clk(clk),.rst_n(rst_n),
    .clear_valid(launch_clear),.clear_ready(ref_clear_ready),
    .clear_color(ref_clear_color),.clear_depth(ref_clear_depth),
    .clear_done(ref_clear_done),
    .tri_valid(launch_tri),.tri_ready(ref_tri_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .tri_color(ref_tri_color),.tri_depth(ref_tri_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .scissor_enable(scissor_enable),.scissor_x(scissor_x),
    .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
    .tri_done(ref_tri_done),.initialized(ref_initialized),.busy(ref_busy),
    .read_x(ref_read_x),.read_y(ref_read_y),
    .read_valid(ref_read_valid),.read_color(ref_color),
    .read_depth(ref_depth),.pixel_wrote(ref_pixel_wrote)
  );
  always @(posedge clk) begin
    if(!rst_n)begin
      ref_clear_seen<=0;ref_tri_seen<=0;
    end else begin
      if(ref_clear_done)ref_clear_seen<=1;
      if(ref_tri_done)ref_tri_seen<=1;
      if(launch_clear)ref_clear_seen<=0;
      if(launch_tri)ref_tri_seen<=0;
    end
    #1;
    if(rst_n)begin
      if(ref_pixel_wrote)ref_writes=ref_writes+1;
      dut_writes=dut_writes+int'(dut.core_pixel_writes[0])
                            +int'(dut.core_pixel_writes[1]);
      if(dut.core_pixel_writes==2'b11)dual_commits=dual_commits+1;
      if(dut.core_fault)$fatal(1,"P147 raster fault latched");
    end
  end

  task automatic transaction(
    input reg wr,input reg [4:0] adr,input reg [31:0] data_in,
    output reg error_out,output reg [31:0] data_out
  );
    integer tries;
    reg got;
    begin
      @(negedge clk);
      req_valid=0;
      tries=0;
      while(!req_ready)begin
        @(negedge clk);
        tries=tries+1;
        if(tries>50)$fatal(1,"P147 request channel stuck");
      end
      req_write=wr;req_addr=adr;req_wdata=data_in;req_valid=1;
      @(posedge clk);#2;
      got=rsp_valid;
      if(got)begin error_out=rsp_error;data_out=rsp_rdata;end
      @(negedge clk);
      req_valid=0;
      tries=0;
      while(!got)begin
        @(posedge clk);#2;
        if(rsp_valid)begin
          got=1;error_out=rsp_error;data_out=rsp_rdata;
        end
        tries=tries+1;
        if(tries>50)$fatal(1,"P147 bus response timeout adr=%0d wr=%b",adr,wr);
      end
      bus_txns=bus_txns+1;
      if(error_out)rejections=rejections+1;
    end
  endtask
  task automatic wr(input reg [4:0] adr,input reg [31:0] value);
    reg err;reg [31:0] out;
    begin
      transaction(1,adr,value,err,out);
      if(err)$fatal(1,"P147 write rejected addr=%0d data=%h",adr,value);
    end
  endtask
  task automatic rd(input reg [4:0] adr,output reg [31:0] result);
    reg err;
    begin
      transaction(0,adr,0,err,result);
      if(err)$fatal(1,"P147 read rejected addr=%0d",adr);
    end
  endtask
  task automatic expect_err(input reg wrv,input reg [4:0] adr,input reg [31:0] v);
    reg err;reg [31:0] out;
    begin
      transaction(wrv,adr,v,err,out);
      if(!err)$fatal(1,"P147 unsupported command/address was accepted %0d",adr);
    end
  endtask
  task automatic poll_done(input integer bit_index);
    integer count;reg [31:0] status;
    begin
      count=0;status=0;
      while(!status[bit_index])begin
        rd(12,status);
        count=count+1;
        if(count>12*PIXELS+70)
          $fatal(1,"P147 command did not finish status=%h bit=%0d",status,bit_index);
        if(status[2])$fatal(1,"P147 error/fault during draw");
      end
      // P102 and dual-BRAM P146 have DIFFERENT operation latencies.
      // Wait for each engine's own completion; never require same edge.
      count=0;
      while(!ref_initialized ||
            (bit_index==3 && !ref_clear_seen) ||
            (bit_index==4 && !ref_tri_seen)) begin
        @(negedge clk);
        count=count+1;
        if(count>12*PIXELS+70)
          $fatal(1,"P147 P102 original reference did not complete independently");
      end
    end
  endtask
  task automatic configure_triangle(
    input reg signed [15:0] xa,ya,xb,yb,xc,yc
  );
    reg [31:0] v;
    begin
      x0=xa;y0=ya;x1=xb;y1=yb;x2=xc;y2=yc;
      if(xa< -128||xa>127||ya< -128||ya>127||
         xb< -128||xb>127||yb< -128||yb>127||
         xc< -128||xc>127||yc< -128||yc>127)
         large_vertices=large_vertices+1;
      wr(4,{ya,xa});wr(5,{yb,xb});wr(6,{yc,xc});
      rd(4,v);if(v!=={ya,xa})$fatal(1,"P147 lost signed16 vertex 0");
      rd(5,v);if(v!=={yb,xb})$fatal(1,"P147 lost signed16 vertex 1");
      rd(6,v);if(v!=={yc,xc})$fatal(1,"P147 lost signed16 vertex 2");
    end
  endtask
  task automatic configure_mode;
    reg [31:0] val,readback;
    begin
      val={16'd0,source_alpha,3'd0,scissor_enable,
           blend_enable,depth_write,depth_compare_op};
      wr(9,val);
      rd(9,readback);
      if(readback!==val)$fatal(1,"P147 mode bits corrupted");
      wr(7,{scissor_y,scissor_x});
      wr(8,{scissor_h,scissor_w});
      wr(2,{8'd0,ref_tri_color});
      wr(3,{8'd0,ref_tri_depth});
    end
  endtask
  task automatic one_pixel(input integer xx,yy);
    reg err;reg [31:0] reply,col,dep;
    begin
      ref_read_x=16'(xx);ref_read_y=16'(yy);
      wr(10,{16'(yy),16'(xx)});
      transaction(1,11,32'd3,err,reply);
      if(xx<FRAME_WIDTH&&yy<FRAME_HEIGHT)begin
        if(err||!ref_read_valid)$fatal(1,"P147 valid pixel read rejected");
        rd(13,col);rd(14,dep);
        if(col[23:0]!==ref_color || dep[23:0]!==ref_depth ||
           col[31:24]!==0||dep[31:24]!==0)
          $fatal(1,"P147 P102 RGB/depth mismatch xy=%0d,%0d reference=%h/%h bus=%h/%h",
            xx,yy,ref_color,ref_depth,col,dep);
        checked=checked+1;host_reads=host_reads+1;
      end else begin
        if(!err || ref_read_valid)
          $fatal(1,"P147 invalid coordinates accepted (%0d,%0d)",xx,yy);
        expect_err(0,13,0);
        expect_err(0,14,0);
      end
    end
  endtask
  task automatic compare_frame;
    reg [31:0] status;
    begin
      rd(12,status);
      if(status[0]!==1 || status[1]!==0 || status[2]!==0)
        $fatal(1,"P147 not idle and initialized status=%h",status);
      for(integer yy=0;yy<FRAME_HEIGHT;yy=yy+1)
        for(integer xx=0;xx<FRAME_WIDTH;xx=xx+1)
          one_pixel(xx,yy);
      one_pixel(FRAME_WIDTH,0);
      one_pixel(0,FRAME_HEIGHT);
    end
  endtask
  task automatic clear_frame(input reg [23:0] rgb,z);
    reg [31:0] status;
    begin
      if(!ref_clear_ready)$fatal(1,"P147 P102 not ready for clear");
      ref_clear_color=rgb;ref_clear_depth=z;
      wr(0,{8'd0,rgb});wr(1,{8'd0,z});
      wr(11,32'd1);
      // A second command while raster is running must fail closed.
      rd(12,status);
      if(status[1]) expect_err(1,11,32'd2);
      poll_done(3);
      clears=clears+1;
      compare_frame();
    end
  endtask
  task automatic draw_triangle(
    input reg signed [15:0] xa,ya,xb,yb,xc,yc
  );
    integer start_ref,start_dut;
    reg [31:0] status;
    begin
      configure_triangle(xa,ya,xb,yb,xc,yc);
      configure_mode();
      if(!ref_tri_ready)$fatal(1,"P147 P102 tri not ready");
      start_ref=ref_writes;start_dut=dut_writes;
      wr(11,32'd2);
      rd(12,status);
      if(status[1])expect_err(1,11,32'd3);
      poll_done(4);
      compare_frame();
      if(ref_writes-start_ref!==dut_writes-start_dut)
        $fatal(1,"P147 committed writes disagree ref=%0d real BRAM=%0d",
          ref_writes-start_ref,dut_writes-start_dut);
      draws=draws+1;
    end
  endtask

  reg [31:0] test_reg;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    rd(15,test_reg);
    if(test_reg!==32'hA0147001)$fatal(1,"P147 wrong device ID");
    expect_err(1,31,32'hdeadbeef);
    expect_err(0,31,0);
    expect_err(1,12,0);
    expect_err(1,11,99);
    expect_err(0,13,0);
    // Reserved bits on MODE are rejected without modifying prior config.
    rd(9,test_reg);
    expect_err(1,9,32'hffff0000);
    if(test_reg!==0)$fatal(1,"P147 default MODE invalid");
    clear_frame(24'h112233,24'hffffff);
    ref_tri_color=24'h3090e0;ref_tri_depth=24'h000040;
    depth_compare_op=0;depth_write=1;blend_enable=0;scissor_enable=0;
    // These vertex magnitudes CANNOT be represented by P145 8-bit pins.
    draw_triangle(-16'sd257,-16'sd257,16'sd1024,-16'sd257,
                  -16'sd257,16'sd1024);
    ref_tri_color=24'h00ff18;ref_tri_depth=24'h000020;
    depth_compare_op=1;depth_write=1;blend_enable=1;source_alpha=8'd128;
    scissor_enable=1;scissor_x=1;scissor_y=0;
    scissor_w=16'(FRAME_WIDTH);scissor_h=16'(FRAME_HEIGHT);
    draw_triangle(-16'sd257,-16'sd257,16'sd1024,-16'sd257,
                  -16'sd257,16'sd1024);
    ref_tri_color=24'hff1020;ref_tri_depth=24'h000010;
    depth_compare_op=2;depth_write=0;blend_enable=1;source_alpha=8'd191;
    scissor_enable=0;
    draw_triangle(-16'sd257,-16'sd257,-16'sd257,16'sd1024,
                  16'sd1024,-16'sd257);
    ref_tri_color=24'h784411;ref_tri_depth=24'h000080;
    depth_compare_op=0;depth_write=1;blend_enable=0;
    draw_triangle(0,0,0,0,0,0);
    // Aborted in-flight draw: reset flushes cached pixel and command state.
    configure_triangle(-16'sd257,-16'sd257,16'sd1024,-16'sd257,
                       -16'sd257,16'sd1024);
    wr(11,32'd2);
    repeat(3)@(negedge clk);
    rst_n=0;req_valid=0;
    repeat(4)@(negedge clk);
    if(rsp_valid || req_ready || dut.core_initialized)
      $fatal(1,"P147 reset leaked pending state");
    rst_n=1;
    expect_err(0,13,0);
    clear_frame(24'h010203,24'hffffff);
    ref_tri_color=24'h847362;ref_tri_depth=24'h000008;
    depth_compare_op=0;depth_write=1;blend_enable=0;scissor_enable=0;
    draw_triangle(-16'sd257,-16'sd257,16'sd1024,-16'sd257,
                  -16'sd257,16'sd1024);
    if(clears!=2||draws!=5||large_vertices<4||checked<7*PIXELS||
       host_reads<7*PIXELS||dual_commits<1||bus_txns<7*PIXELS*4 ||
       rejections<15)
      $fatal(1,"P147 vacuous cover clears=%0d draws=%0d large=%0d checked=%0d host=%0d dual=%0d bus=%0d errors=%0d",
        clears,draws,large_vertices,checked,host_reads,dual_commits,
        bus_txns,rejections);
    $display("P147_FULL16_PACKED_BUS_P102_PASS size=%0dx%0d clears=%0d draws=%0d large_vertices=%0d frame_pixels_checked=%0d bus_txns=%0d rejected=%0d dual_commits=%0d",
       FRAME_WIDTH,FRAME_HEIGHT,clears,draws,large_vertices,checked,
       bus_txns,rejections,dual_commits);
    $finish;
  end
  initial begin #20000000;$fatal(1,"P147 bus/fullframe watchdog");end
endmodule
