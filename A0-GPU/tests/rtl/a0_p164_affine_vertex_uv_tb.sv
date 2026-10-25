`timescale 1ns/1ps
// Independent signed 64-bit barycentric scalar geometry oracle for the
// sequential P164 RTL. Includes both windings, subtexel signs, zero area,
// narrow area, unrepresentable extrapolations and output backpressure.
module a0_p164_affine_vertex_uv_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req_valid=0,rsp_ready=0;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  reg signed [15:0] u0=0,v0=0,u1=0,v1=0,u2=0,v2=0;
  reg signed [15:0] pixel_x=0,pixel_y=0;
  reg [7:0] req_id=0;
  wire req_ready,rsp_valid,rsp_error;
  wire signed [15:0] rsp_u,rsp_v;
  wire [7:0] rsp_id;
  integer checked=0,matched=0,errors=0,negatives=0;
  integer held_outputs=0,winding_cases=0,reset_aborts=0;

  a0_p164_affine_vertex_uv dut(
    .clk(clk),.rst_n(rst_n),.req_valid(req_valid),
    .req_ready(req_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .u0(u0),.v0(v0),.u1(u1),.v1(v1),.u2(u2),.v2(v2),
    .pixel_x(pixel_x),.pixel_y(pixel_y),.req_id(req_id),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
    .rsp_id(rsp_id),.rsp_u(rsp_u),.rsp_v(rsp_v),
    .rsp_error(rsp_error)
  );

  // A deliberately different reference implementation from the RTL:
  // signed longint scalar cross products and native mathematical division.
  function automatic longint signed scalar_cross_product(input longint signed ax,ay,bx,by,cx,cy);
    scalar_cross_product=(bx-ax)*(cy-ay)-(by-ay)*(cx-ax);
  endfunction
  task automatic oracle(
    output integer expected_error,
    output integer expected_u,expected_v
  );
    longint signed a0,a1,a2,area,nu,nv,ux,vy;
    longint signed px2,py2;
    begin
      px2=2*longint'(pixel_x)+1;
      py2=2*longint'(pixel_y)+1;
      // Twice all coordinates so raster sample means actual pixel center.
      a0=scalar_cross_product(longint'(x1)*2,longint'(y1)*2,
               longint'(x2)*2,longint'(y2)*2,px2,py2);
      a1=scalar_cross_product(longint'(x2)*2,longint'(y2)*2,
               longint'(x0)*2,longint'(y0)*2,px2,py2);
      a2=scalar_cross_product(longint'(x0)*2,longint'(y0)*2,
               longint'(x1)*2,longint'(y1)*2,px2,py2);
      // Doubling all geometric coordinates scales numerator and area
      // equally, so this oracle stays independent of P164 edge widths.
      area=a0+a1+a2;
      nu=a0*longint'(u0)+a1*longint'(u1)+a2*longint'(u2);
      nv=a0*longint'(v0)+a1*longint'(v1)+a2*longint'(v2);
      expected_error=0;expected_u=0;expected_v=0;
      if(area==0)expected_error=1;
      else begin
        ux=nu/area;vy=nv/area;
        if(ux < -32768 || ux>32767 || vy < -32768 || vy>32767)
          expected_error=1;
        else begin expected_u=integer'(ux);expected_v=integer'(vy);end
      end
    end
  endtask
  task automatic check_one(input integer token);
    integer eu,ev,expect_error,loops;
    reg signed [15:0] held_u,held_v;
    reg held_error;
    begin
      oracle(expect_error,eu,ev);
      @(negedge clk);req_id=8'(token);req_valid=1;
      if(!req_ready)$fatal(1,"P164 interpolation request refused while idle");
      @(negedge clk);req_valid=0;
      if(req_ready)$fatal(1,"P164 accepted overlap during signed divider");
      loops=0;
      while(!rsp_valid)begin
        @(negedge clk);loops=loops+1;
        if(loops>150)$fatal(1,"P164 2x64 restoring division stalled");
      end
      if(rsp_id!==8'(token) || rsp_error!==1'(expect_error) ||
         (!expect_error &&
          (rsp_u!==16'(eu) || rsp_v!==16'(ev))) ||
         (expect_error && (rsp_u!==0 || rsp_v!==0)))
        $fatal(1,"P164 oracle mismatch id=%0d expected err/u/v=%0d/%0d/%0d got=%b/%0d/%0d",
          token,expect_error,eu,ev,rsp_error,$signed(rsp_u),$signed(rsp_v));
      held_u=rsp_u;held_v=rsp_v;held_error=rsp_error;
      // A backpressured response must remain stable for arbitrary cycles.
      repeat(3)begin
        @(negedge clk);
        if(!rsp_valid || req_ready || rsp_id!==8'(token) ||
           rsp_u!==held_u || rsp_v!==held_v || rsp_error!==held_error)
          $fatal(1,"P164 output mutated under host backpressure");
        held_outputs=held_outputs+1;
      end
      rsp_ready=1;
      @(negedge clk);rsp_ready=0;
      if(rsp_valid || !req_ready)$fatal(1,"P164 response not retired");
      checked=checked+1;
      if(expect_error)errors=errors+1;
      else begin
        matched=matched+1;
        if(eu<0 || ev<0)negatives=negatives+1;
      end
    end
  endtask
  task automatic set_triangle(input integer kind);
    begin
      case(kind)
        0:begin x0=-2;y0=-2;x1=9;y1=-2;x2=-2;y2=9;end
        1:begin x0=-2;y0=-2;x1=-2;y1=9;x2=9;y2=-2;end
        2:begin x0=0;y0=0;x1=5;y1=0;x2=0;y2=5;end
        3:begin x0=0;y0=0;x1=0;y1=5;x2=5;y2=0;end
        4:begin x0=0;y0=0;x1=1;y1=0;x2=0;y2=1;end
        5:begin x0=0;y0=0;x1=1;y1=1;x2=2;y2=2;end
        default:begin x0=-3;y0=7;x1=8;y1=-1;x2=4;y2=9;end
      endcase
    end
  endtask
  task automatic set_uv(input integer kind,reverse_winding);
    reg signed [15:0] tu,tv;
    begin
      case(kind)
        0:begin
          u0=16'sd0;v0=16'sd0;
          u1=16'sd512;v1=-16'sd256;
          u2=-16'sd768;v2=16'sd1024;
        end
        1:begin
          u0=-16'sd1024;v0=16'sd2200;
          u1=16'sd32767;v1=-16'sd32768;
          u2=-16'sd23000;v2=16'sd31000;
        end
        2:begin
          u0=16'sd1234;v0=-16'sd4567;
          u1=16'sd1234;v1=-16'sd4567;
          u2=16'sd1234;v2=-16'sd4567;
        end
        default:begin
          u0=16'sd11;v0=16'sd257;
          u1=-16'sd31;v1=16'sd513;
          u2=16'sd3999;v2=-16'sd1;
        end
      endcase
      if(reverse_winding!=0)begin
        tu=u1;tv=v1;u1=u2;v1=v2;u2=tu;v2=tv;
      end
    end
  endtask

  integer id=0;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    for(integer triangle=0;triangle<7;triangle=triangle+1)
      for(integer uvset=0;uvset<4;uvset=uvset+1)begin
        set_triangle(triangle);
        set_uv(uvset,triangle==1 || triangle==3);
        for(integer py=-1;py<5;py=py+1)
          for(integer px=-1;px<5;px=px+1)begin
            pixel_x=16'(px);pixel_y=16'(py);
            check_one(id);id=id+1;
          end
        winding_cases=winding_cases+1;
      end

    // Out-of-range extrapolation must fail instead of wrapping signed UV.
    set_triangle(4);set_uv(1,0);
    pixel_x=16'sd30000;pixel_y=16'sd30000;
    check_one(id);id=id+1;

    // Reset in the middle of a divide clears in-flight response and state.
    set_triangle(2);set_uv(0,0);
    pixel_x=1;pixel_y=2;
    @(negedge clk);req_id=8'hab;req_valid=1;
    @(negedge clk);req_valid=0;
    repeat(11)@(negedge clk);
    if(req_ready || rsp_valid)$fatal(1,"P164 div unexpectedly finished before reset");
    rst_n=0;
    repeat(3)@(negedge clk);
    if(req_ready || rsp_valid || rsp_error || rsp_u!==0 || rsp_v!==0)
      $fatal(1,"P164 reset failed to discard active response");
    rst_n=1;reset_aborts=reset_aborts+1;
    check_one(id);

    if(checked!=1010 || matched<120 || errors<1 || negatives<80 ||
       held_outputs!=3*checked || winding_cases!=28 || reset_aborts!=1)
      $fatal(1,"P164 insufficient signed oracle coverage checks=%0d matched=%0d errors=%0d negative=%0d holds=%0d windings=%0d resets=%0d",
        checked,matched,errors,negatives,held_outputs,winding_cases,reset_aborts);
    $display("P164_AFFINE_VERTEX_UV_PASS checks=%0d exact=%0d fail_closed=%0d signed_negative=%0d backpressure_checks=%0d winding_cases=%0d reset_abort=%0d serial_divisions_per_sample=2",
      checked,matched,errors,negatives,held_outputs,winding_cases,reset_aborts);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P164 UV test watchdog");end
endmodule
