`timescale 1ns/1ps
// Differential RTL test against the frozen original 64-bit P38 module.
// Compares actual emitted pixels/flow-control over many triangles, including
// extreme signed-16 vertices. Real iverilog+vvp are mandatory.
module a0_p130_p38_width_equivalence_tb;
  reg clk=0; always #5 clk=~clk;
  reg rst_n=0, tri_valid=0, pixel_ready=1;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  wire valid_a,ready_a,done_a,valid_b,ready_b,done_b;
  wire [15:0] px_a,py_a,px_b,py_b;
  integer checks=0,triangles=0,pixel_events=0,done_events=0;
  reg [31:0] rng=32'hc06e13a7;
  a0_triangle_coverage_p38 #(.FRAME_WIDTH(8),.FRAME_HEIGHT(8)) candidate(
    .clk(clk),.rst_n(rst_n),.tri_valid(tri_valid),.tri_ready(ready_a),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .pixel_valid(valid_a),.pixel_ready(pixel_ready),.pixel_x(px_a),
    .pixel_y(py_a),.done(done_a)
  );
  a0_triangle_coverage_p38_p130_reference #(.FRAME_WIDTH(8),.FRAME_HEIGHT(8)) reference_p38(
    .clk(clk),.rst_n(rst_n),.tri_valid(tri_valid),.tri_ready(ready_b),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .pixel_valid(valid_b),.pixel_ready(pixel_ready),.pixel_x(px_b),
    .pixel_y(py_b),.done(done_b)
  );
  function automatic signed [15:0] sample_vertex(input integer k);
    begin
      case (k % 14)
        0: sample_vertex=16'sh8000;
        1: sample_vertex=16'sh7fff;
        2: sample_vertex=-16'sd1;
        3: sample_vertex=16'sd0;
        4: sample_vertex=16'sd1;
        5: sample_vertex=16'sd7;
        6: sample_vertex=16'sd8;
        7: sample_vertex=-16'sd7;
        8: sample_vertex=16'sd32766;
        9: sample_vertex=-16'sd32767;
        10: sample_vertex=16'sd4;
        11: sample_vertex=16'sd6;
        12: sample_vertex=-16'sd128;
        default: sample_vertex=16'sd128;
      endcase
    end
  endfunction
  // Sampling after NBA settles and before the next negedge where stimulus changes.
  always @(posedge clk) begin
    #1;
    if ({ready_a,valid_a,px_a,py_a,done_a} !== {ready_b,valid_b,px_b,py_b,done_b})
      $fatal(1,"P130 output mismatch at cycle %0d A=%b %b %0d %0d %b B=%b %b %0d %0d %b",
        checks,ready_a,valid_a,px_a,py_a,done_a,
        ready_b,valid_b,px_b,py_b,done_b);
    checks=checks+1;
    if (rst_n && valid_a && pixel_ready) pixel_events=pixel_events+1;
    if (rst_n && done_a) done_events=done_events+1;
  end
  initial begin #3000000; $fatal(1,"P130 differential RTL timeout"); end
  initial begin
    repeat(4) @(negedge clk);
    rst_n=1;
    for(integer i=0;i<196;i=i+1) begin
      // Deterministic corner-directed 16-bit coordinates and winding flips.
      @(negedge clk);
      if (!ready_a || !ready_b) $fatal(1,"P130 triangle not ready");
      x0=sample_vertex(i);   y0=sample_vertex(i+3);
      x1=sample_vertex(i+4); y1=sample_vertex(i+6);
      x2=sample_vertex(i+8); y2=sample_vertex(i+10);
      tri_valid=1;
      @(negedge clk);
      tri_valid=0;
      triangles=triangles+1;
      // Retire 8x8 scan (one pixel position per cycle) plus idle margin.
      repeat(68) @(negedge clk);
      if (!ready_a || !ready_b) $fatal(1,"P130 triangle did not retire");
      // Perturb the source coordinates after tri_valid: in-flight snapshots
      // in each DUT must still match cycle-for-cycle.
      if ((i%7)==0) begin
        x0=16'sh7fff; y0=16'sh8000;
      end
    end
    if (triangles!==196 || checks<13000 || done_events<150)
      $fatal(1,"P130 coverage missing: triangles=%0d checks=%0d done=%0d",triangles,checks,done_events);
    $display("P130_P38_EQUIV_CYCLES=%0d", checks);
    $display("P130_P38_TRIANGLES=%0d", triangles);
    $display("P130_P38_PIXEL_EVENTS=%0d", pixel_events);
    $display("P130_P38_DONE_EVENTS=%0d", done_events);
    $display("P130_P38_EXACT_WIDTH_RTL_EQUIVALENCE_PASS");
    $finish;
  end
endmodule