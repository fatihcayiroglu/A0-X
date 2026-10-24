`timescale 1ns/1ps
// P144 independent indexed RGB/depth golden model. No test stub storage.
// Each dual-lane RMW is checked on completion, including per-lane depth
// outcomes, full-frame host readback, packet atomic invalid/bank rejection,
// overwrite clears, alpha=0/127/255, unsupported depth op, and reset.
module a0_p144_dual_depth_blend_tb #(
  parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4,
  parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
);
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,op_valid=0,op_clear=0;
  reg lane0_valid=0,lane1_valid=0;
  reg [15:0] lane0_x=0,lane0_y=0,lane1_x=0,lane1_y=0;
  reg [23:0] source_rgb=0,source_depth=0;
  reg [1:0] depth_compare_op=0;
  reg depth_write=0,blend_enable=0;
  reg [7:0] source_alpha=0;
  wire op_ready,rsp_valid,rsp_error;
  wire [1:0] rsp_pixel_written;
  reg host_read_valid=0;
  reg [15:0] host_read_x=0,host_read_y=0;
  wire host_read_ready,host_rsp_valid,host_rsp_error;
  wire [23:0] host_rsp_color,host_rsp_depth;
  reg [47:0] golden [0:PIXELS-1];

  a0_p144_dual_depth_blend_rmw #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .op_valid(op_valid),.op_ready(op_ready),.op_clear(op_clear),
    .lane0_valid(lane0_valid),.lane1_valid(lane1_valid),
    .lane0_x(lane0_x),.lane0_y(lane0_y),
    .lane1_x(lane1_x),.lane1_y(lane1_y),
    .source_rgb(source_rgb),.source_depth(source_depth),
    .depth_compare_op(depth_compare_op),.depth_write(depth_write),
    .blend_enable(blend_enable),.source_alpha(source_alpha),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),
    .rsp_pixel_written(rsp_pixel_written),
    .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
    .host_read_x(host_read_x),.host_read_y(host_read_y),
    .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
    .host_rsp_color(host_rsp_color),.host_rsp_depth(host_rsp_depth)
  );

  integer ops=0,dual_ops=0,dual_commits=0,clears=0;
  integer collisions=0,invalids=0,depth_rejects=0,reads=0;
  integer blending=0,depth_kept=0,reset_aborts=0,nonclear=0;

  function automatic [7:0] blend_channel(
    input integer src,dst,alpha
  );
    integer numerator;
    begin
      numerator=src*alpha + dst*(255-alpha)+127;
      blend_channel=8'(numerator/255);
    end
  endfunction
  function automatic [23:0] blend_ref(
    input reg [23:0] src,dst,
    input reg [7:0] alpha,input reg enabled
  );
    begin
      if(!enabled) blend_ref=src;
      else blend_ref={
        blend_channel(src[23:16],dst[23:16],alpha),
        blend_channel(src[15:8],dst[15:8],alpha),
        blend_channel(src[7:0],dst[7:0],alpha)
      };
    end
  endfunction
  function automatic reg depth_pass(
    input reg [23:0] incoming,stored,input reg [1:0] mode
  );
    case(mode)
      2'd0:depth_pass=1;
      2'd1:depth_pass=incoming<stored;
      2'd2:depth_pass=incoming<=stored;
      default:depth_pass=0;
    endcase
  endfunction
  function automatic [23:0] rgb_for(input integer n);
    rgb_for=24'(32'h38e9a13f ^ (n*32'h001c942d));
  endfunction

  task automatic send(
    input reg is_clear,input reg v0,v1,
    input integer idx0,idx1,
    input reg [23:0] color,depth,
    input reg [1:0] mode,
    input reg dw,enable_blend,
    input reg [7:0] alpha
  );
    integer old0,old1;
    reg good,pass0,pass1,got_response;
    reg [1:0] expected_writes;
    reg [23:0] new_rgb;
    begin
      // idx outside range is represented by (x=FRAME_WIDTH,y=0).
      // The out-of-bounds Y case is tested separately by idx1=-1.
      @(negedge clk);
      if(!op_ready || !rst_n)
        $fatal(1,"P144 test offered packet while busy");
      op_clear=is_clear;op_valid=1;lane0_valid=v0;lane1_valid=v1;
      lane0_x=16'(idx0<0 ? 0 : idx0>=PIXELS ? FRAME_WIDTH : idx0%FRAME_WIDTH);
      lane0_y=16'(idx0<0 ? FRAME_HEIGHT : idx0>=PIXELS ? 0 : idx0/FRAME_WIDTH);
      lane1_x=16'(idx1<0 ? 0 : idx1>=PIXELS ? FRAME_WIDTH : idx1%FRAME_WIDTH);
      lane1_y=16'(idx1<0 ? FRAME_HEIGHT : idx1>=PIXELS ? 0 : idx1/FRAME_WIDTH);
      source_rgb=color;source_depth=depth;
      depth_compare_op=mode;depth_write=dw;
      blend_enable=enable_blend;source_alpha=alpha;
      good=(!v0 || (idx0>=0 && idx0<PIXELS)) &&
           (!v1 || (idx1>=0 && idx1<PIXELS)) &&
           !(v0 && v1 && ((idx0%2)==(idx1%2)));
      expected_writes=0;
      old0=idx0;old1=idx1;
      pass0=0;pass1=0;
      if(good && !is_clear) begin
        if(v0)pass0=depth_pass(depth,golden[old0][23:0],mode);
        if(v1)pass1=depth_pass(depth,golden[old1][23:0],mode);
      end
      if(good) begin
        if(is_clear) expected_writes={v1,v0};
        else expected_writes={v1&&pass1,v0&&pass0};
      end
      @(posedge clk);#2;
      got_response=rsp_valid;
      // Clear or invalid packet completes in one cycle; valid RMW in two.
      if(got_response !== (is_clear || !good))
        $fatal(1,"P144 wrong initial response beat clear=%b good=%b got=%b",
           is_clear,good,got_response);
      @(negedge clk);op_valid=0;
      if(!got_response) begin
        if(op_ready) $fatal(1,"P144 RMW must hold op_ready=0 until commit");
        @(posedge clk);#2;
        if(!rsp_valid)
          $fatal(1,"P144 RMW missing second beat completion");
      end
      if(!rsp_valid || rsp_error !== !good ||
         rsp_pixel_written !== expected_writes)
        $fatal(1,"P144 packet mismatch clear=%b good=%b expected=%b actual=%b error=%b",
          is_clear,good,expected_writes,rsp_pixel_written,rsp_error);

      if(good) begin
        if(is_clear) clears=clears+1;
        else nonclear=nonclear+1;
        if(!is_clear && enable_blend)blending=blending+1;
        if(!is_clear && !dw)depth_kept=depth_kept+1;
        if(expected_writes==2'b11)dual_commits=dual_commits+1;
        if(v0 && v1)dual_ops=dual_ops+1;
        if(v0 && expected_writes[0]) begin
          new_rgb=is_clear ? color :
                blend_ref(color,golden[old0][47:24],alpha,enable_blend);
          golden[old0]={new_rgb,(is_clear || dw) ? depth : golden[old0][23:0]};
        end else if(v0 && !is_clear) depth_rejects=depth_rejects+1;
        if(v1 && expected_writes[1]) begin
          new_rgb=is_clear ? color :
                blend_ref(color,golden[old1][47:24],alpha,enable_blend);
          golden[old1]={new_rgb,(is_clear || dw) ? depth : golden[old1][23:0]};
        end else if(v1 && !is_clear) depth_rejects=depth_rejects+1;
      end else if(v0 && v1 && idx0>=0 && idx0<PIXELS &&
                  idx1>=0 && idx1<PIXELS) collisions=collisions+1;
      else invalids=invalids+1;
      ops=ops+1;
      @(negedge clk);
      // rsp_valid is a legitimate full-cycle registered completion pulse
      // until the next rising edge; only require readiness here.
      if(!op_ready)
        $fatal(1,"P144 packet did not return to idle");
    end
  endtask

  task automatic scan_frame;
    begin
      for(integer idx=0;idx<PIXELS;idx=idx+1) begin
        @(negedge clk);
        if(!host_read_ready) $fatal(1,"P144 host read not ready at %0d",idx);
        host_read_valid=1;
        host_read_x=16'(idx%FRAME_WIDTH);
        host_read_y=16'(idx/FRAME_WIDTH);
        @(posedge clk);#2;
        if(!host_rsp_valid || host_rsp_error ||
           {host_rsp_color,host_rsp_depth} !== golden[idx])
          $fatal(1,"P144 framebuffer mismatch idx=%0d expected=%h actual=%h/%h",
            idx,golden[idx],host_rsp_color,host_rsp_depth);
        reads=reads+1;
        @(negedge clk);host_read_valid=0;
      end
      // Invalid coordinate must be error, no stale data or false success.
      @(negedge clk);
      host_read_valid=1;host_read_x=16'(FRAME_WIDTH);host_read_y=0;
      @(posedge clk);#2;
      if(!host_rsp_valid || !host_rsp_error ||
         host_rsp_color!==0 || host_rsp_depth!==0)
        $fatal(1,"P144 invalid host X was not rejected");
      @(negedge clk);host_read_valid=0;
    end
  endtask
  task automatic fill(input reg [23:0] rgb,z);
    begin
      for(integer idx=0;idx<PIXELS;idx=idx+2)
        send(1,1,(idx+1<PIXELS),idx,idx+1,rgb,z,0,1,0,8'd255);
    end
  endtask

  initial begin
    for(integer i=0;i<PIXELS;i=i+1)golden[i]=0;
    repeat(4)@(negedge clk);rst_n=1;
    scan_frame(); // uninitialized BRAM must return zero
    fill(24'h113355,24'hffffff);
    scan_frame();
    // Multiple dual-lane read-modify-write streams, exercising modes.
    for(integer k=0;k<360;k=k+1) begin
      send(0,1,1,2*(k%((PIXELS+1)/2)),
          2*(k%(PIXELS/2))+1,
          rgb_for(k),24'((k*127+3)&24'hffffff),
          2'(k%4),(k%3)!=0,(k%2)==0,
          (k%5==0)?8'd0:((k%5==1)?8'd127:
                 ((k%5==2)?8'd255:8'(k))));
      if(k%80==0)scan_frame();
    end
    // Rejected conflicts must have no partial write even for lane0.
    for(integer k=0;k<32;k=k+1)
      send(0,1,1,0,2,rgb_for(k+800),24'h11,0,1,1,8'd127);
    // Invalid X and Y, while other lane has a legal different bank.
    for(integer k=0;k<32;k=k+1) begin
      send(0,1,1,PIXELS,1,rgb_for(k),24'h0,0,1,0,8'd0);
      send(0,1,1,0,-1,rgb_for(k),24'h0,0,1,0,8'd0);
    end
    // One active lane and zero-lane packet, invalid depth mode fail closed.
    for(integer k=0;k<24;k=k+1) begin
      send(0,1,0,0,0,rgb_for(k+950),24'h33,2'd3,1,0,8'd20);
      send(0,0,1,0,1,rgb_for(k+960),24'h12,2'd0,0,1,8'd127);
      send(0,0,0,0,1,24'hffffff,24'hffff,2'd0,1,1,8'd255);
    end
    scan_frame();
    // Abort a read-in-flight with reset; response and state must flush.
    @(negedge clk);
    if(!op_ready) $fatal(1,"P144 not idle before reset injection");
    op_valid=1;op_clear=0;lane0_valid=1;lane1_valid=1;
    lane0_x=0;lane0_y=0;lane1_x=1;lane1_y=0;
    depth_compare_op=0;depth_write=1;blend_enable=1;
    source_rgb=24'hfeedba;source_depth=24'h000008;source_alpha=127;
    @(posedge clk);#2;
    if(rsp_valid || op_ready) $fatal(1,"P144 reset scenario not in-flight");
    @(negedge clk);
    rst_n=0;op_valid=0;
    repeat(3)@(negedge clk);
    if(rsp_valid || host_rsp_valid || op_ready)
      $fatal(1,"P144 reset leaked in-flight response");
    for(integer i=0;i<PIXELS;i=i+1)golden[i]=0;
    rst_n=1;
    reset_aborts=reset_aborts+1;
    scan_frame();
    fill(24'h345678,24'hffffff);
    scan_frame();
    if(ops<450 || dual_ops<300 || dual_commits<3 ||
       collisions<32 || invalids<64 || depth_rejects<10 ||
       blending<100 || depth_kept<100 || reads<PIXELS*4 ||
       reset_aborts!=1)
      $fatal(1,"P144 vacuous coverage ops=%0d dual=%0d writes=%0d collisions=%0d invalid=%0d rejects=%0d blend=%0d depth_keep=%0d reads=%0d",
        ops,dual_ops,dual_commits,collisions,invalids,depth_rejects,
        blending,depth_kept,reads);
    $display("P144_DUAL_DEPTH_BLEND_GOLDEN_PASS size=%0dx%0d ops=%0d dual_ops=%0d dual_commits=%0d collisions=%0d invalid=%0d rejects=%0d blend=%0d reads=%0d",
      FRAME_WIDTH,FRAME_HEIGHT,ops,dual_ops,dual_commits,collisions,
      invalids,depth_rejects,blending,reads);
    $finish;
  end
  initial begin #8000000; $fatal(1,"P144 test watchdog");end
endmodule
