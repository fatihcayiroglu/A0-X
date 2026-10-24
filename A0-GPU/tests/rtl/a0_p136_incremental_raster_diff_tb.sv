`timescale 1ns/1ps
// P136: independent differential oracle uses frozen P130 64-bit P38.
// Strict cycle-by-cycle output comparison under stalls, windings, arbitrary
// vertices, dimensions, in-flight source mutation and reset.
module a0_p136_incremental_raster_diff_tb #(
    parameter integer FRAME_WIDTH=8,
    parameter integer FRAME_HEIGHT=8
);
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0, tri_valid=0, pixel_ready=1;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  wire val_new, ready_new, done_new, val_ref, ready_ref, done_ref;
  wire [15:0] px_new, py_new, px_ref, py_ref;
  integer cycles=0, triangles=0, valid_pixels=0, backpressure=0, done_count=0;
  integer tick=0;
  reg [31:0] state=32'h629a187d;

  a0_triangle_coverage_p38 #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) candidate(
    .clk(clk),.rst_n(rst_n),.tri_valid(tri_valid),.tri_ready(ready_new),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .pixel_valid(val_new),.pixel_ready(pixel_ready),
    .pixel_x(px_new),.pixel_y(py_new),.done(done_new)
  );
  a0_triangle_coverage_p38_p130_reference #(
    .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
  ) original(
    .clk(clk),.rst_n(rst_n),.tri_valid(tri_valid),.tri_ready(ready_ref),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .pixel_valid(val_ref),.pixel_ready(pixel_ready),
    .pixel_x(px_ref),.pixel_y(py_ref),.done(done_ref)
  );

  always @(negedge clk) begin
    tick=tick+1;
    if(!rst_n) pixel_ready=1;
    else pixel_ready=((tick%13)!=0 && (tick%17)!=0 && (tick%19)!=0);
  end
  always @(posedge clk) begin
    #1;
    if({ready_new,val_new,px_new,py_new,done_new} !==
       {ready_ref,val_ref,px_ref,py_ref,done_ref})
      $fatal(1,"P136 mismatch dimensions=%0dx%0d cycle=%0d new ready/valid/xy/done=%b%b/%d,%d/%b reference=%b%b/%d,%d/%b",
        FRAME_WIDTH,FRAME_HEIGHT,cycles,ready_new,val_new,px_new,py_new,done_new,
        ready_ref,val_ref,px_ref,py_ref,done_ref);
    cycles=cycles+1;
    if(rst_n && val_new) valid_pixels=valid_pixels+1;
    if(rst_n && val_new && !pixel_ready) backpressure=backpressure+1;
    if(rst_n && done_new) done_count=done_count+1;
  end

  task automatic start_tri(
    input reg signed [15:0] xa,ya,xb,yb,xc,yc
  );
    begin
      @(negedge clk);
      if(!ready_new || !ready_ref) $fatal(1,"P136 not idle before launch");
      x0=xa; y0=ya; x1=xb; y1=yb; x2=xc; y2=yc;
      tri_valid=1;
      @(negedge clk);
      tri_valid=0;
      triangles=triangles+1;
      // Deliberately change port vertices after hardware snaps the command.
      x0=16'sh7fff; y0=16'sh8000;
      x1=-16'sd7; y1=16'sd12;
      x2=16'sd5; y2=-16'sd3;
    end
  endtask

  task automatic retire;
    integer j;
    reg observed;
    begin
      observed=done_new;
      for(j=0;j<FRAME_WIDTH*FRAME_HEIGHT*5+50 && !observed;j=j+1) begin
        @(negedge clk);
        if(done_new) observed=1;
      end
      if(!observed) $fatal(1,"P136 triangle completion timed out %0dx%0d",FRAME_WIDTH,FRAME_HEIGHT);
      @(negedge clk);
      if(!ready_new || !ready_ref) $fatal(1,"P136 triangle did not retire");
    end
  endtask

  task automatic drive_tri(
    input reg signed [15:0] xa,ya,xb,yb,xc,yc
  );
    begin
      start_tri(xa,ya,xb,yb,xc,yc);
      retire();
    end
  endtask

  function automatic signed [15:0] vertex(input integer i);
    begin
      case(i%16)
        0:vertex=16'sh8000;
        1:vertex=16'sh7fff;
        2:vertex=16'sd0;
        3:vertex=16'sd1;
        4:vertex=16'sd7;
        5:vertex=16'sd8;
        6:vertex=-16'sd1;
        7:vertex=-16'sd3;
        8:vertex=16'sd10;
        9:vertex=16'sd32766;
        10:vertex=-16'sd32767;
        11:vertex=-16'sd7;
        12:vertex=16'sd5;
        13:vertex=16'sd128;
        14:vertex=-16'sd128;
        default:vertex=16'sd3;
      endcase
    end
  endfunction

  initial begin
    repeat(4) @(negedge clk);
    rst_n=1;
    // Dense triangles cover several scanlines; also test winding reversal.
    drive_tri(-16'sd12,-16'sd12,16'sd32,-16'sd12,-16'sd12,16'sd32);
    drive_tri(-16'sd12,-16'sd12,-16'sd12,16'sd32,16'sd32,-16'sd12);
    drive_tri(16'sd0,16'sd0,16'sd7,16'sd0,16'sd0,16'sd7);
    drive_tri(16'sd0,16'sd0,16'sd0,16'sd7,16'sd7,16'sd0);
    drive_tri(16'sd0,16'sd0,16'sd0,16'sd0,16'sd0,16'sd0); // degenerate
    drive_tri(16'sh8000,16'sh7fff,16'sh7fff,16'sh8000,16'sh7fff,16'sh7fff);
    for(integer i=0;i<144;i=i+1) begin
      drive_tri(vertex(i),vertex(i+3),
                vertex(i+5),vertex(i+7),
                vertex(i+10),vertex(i+13));
    end
    // Abort one active triangle with shared reset; neither RTL should leak
    // stale edge registers or completion signals into the next launch.
    start_tri(-16'sd12,-16'sd12,16'sd32,-16'sd12,-16'sd12,16'sd32);
    repeat(5) @(negedge clk);
    rst_n=0;
    repeat(4) @(negedge clk);
    if(done_new || done_ref || val_new || val_ref)
      $fatal(1,"P136 stale raster events during reset");
    rst_n=1;
    drive_tri(-16'sd12,-16'sd12,16'sd32,-16'sd12,-16'sd12,16'sd32);
    if(cycles<500 || triangles<150 || valid_pixels<20 || backpressure<2 || done_count<130)
      $fatal(1,"P136 insufficient coverage: cycles=%0d tris=%0d pixels=%0d stalled=%0d done=%0d",
             cycles,triangles,valid_pixels,backpressure,done_count);
    $display("P136_INCREMENTAL_EDGE_DIFFERENTIAL_PASS cycles=%0d triangles=%0d pixels=%0d stalled=%0d dimensions=%0dx%0d",
             cycles,triangles,valid_pixels,backpressure,FRAME_WIDTH,FRAME_HEIGHT);
    $finish;
  end
  initial begin
    #8000000;
    $fatal(1,"P136 differential test watchdog");
  end
endmodule
