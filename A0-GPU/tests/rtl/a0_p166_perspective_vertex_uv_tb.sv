`timescale 1ns/1ps
// P166 independent signed 64-bit rational perspective oracle, plus a wide
// constant-attribute invariant that exceeds signed-64 intermediate range.
// Tests both windings, unequal positive reciprocal-W, rejected zero-W,
// signed subtexels, output backpressure and reset abort.
module a0_p166_perspective_vertex_uv_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req_valid=0,rsp_ready=0;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  reg signed [15:0] u0=0,v0=0,u1=0,v1=0,u2=0,v2=0;
  reg [15:0] inv_w0=4096,inv_w1=4096,inv_w2=4096;
  reg wide_constant_case=0;
  reg signed [15:0] pixel_x=0,pixel_y=0;
  reg [7:0] req_id=0;
  wire req_ready,rsp_valid,rsp_error;
  wire signed [15:0] rsp_u,rsp_v;
  wire [7:0] rsp_id;
  integer checked=0,matched=0,errors=0,negatives=0;
  integer held_outputs=0,winding_cases=0,reset_aborts=0;
  integer zero_w_cases=0,wide_cases=0,equal_w_cases=0;

  a0_p166_perspective_vertex_uv dut(
    .clk(clk),.rst_n(rst_n),.req_valid(req_valid),
    .req_ready(req_ready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .u0(u0),.v0(v0),.u1(u1),.v1(v1),.u2(u2),.v2(v2),
    .inv_w0(inv_w0),.inv_w1(inv_w1),.inv_w2(inv_w2),
    .pixel_x(pixel_x),.pixel_y(pixel_y),.req_id(req_id),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
    .rsp_id(rsp_id),.rsp_u(rsp_u),.rsp_v(rsp_v),
    .rsp_error(rsp_error)
  );

  // Independent rational arithmetic; every ordinary fixture is chosen
  // small enough that its complete weighted numerator fits signed 64 bits.
  // The extreme fixture below instead uses an exact constant-UV invariant.
  function automatic longint signed scalar_cross(
    input longint signed ax,ay,bx,by,cx,cy
  );
    scalar_cross=(bx-ax)*(cy-ay)-(by-ay)*(cx-ax);
  endfunction
  task automatic oracle(
    output integer expected_error,
    output integer expected_u,expected_v
  );
    longint signed a0,a1,a2,den,nu,nv,ux,vy,px2,py2;
    begin
      expected_error=0;expected_u=0;expected_v=0;
      if(wide_constant_case)begin
        expected_u=-32768;expected_v=32767;
      end else begin
        px2=2*longint'(pixel_x)+1;
        py2=2*longint'(pixel_y)+1;
        a0=scalar_cross(longint'(x1)*2,longint'(y1)*2,
                 longint'(x2)*2,longint'(y2)*2,px2,py2);
        a1=scalar_cross(longint'(x2)*2,longint'(y2)*2,
                 longint'(x0)*2,longint'(y0)*2,px2,py2);
        a2=scalar_cross(longint'(x0)*2,longint'(y0)*2,
                 longint'(x1)*2,longint'(y1)*2,px2,py2);
        den=a0*longint'(inv_w0)+a1*longint'(inv_w1)+
            a2*longint'(inv_w2);
        nu=a0*longint'(u0)*longint'(inv_w0)+
           a1*longint'(u1)*longint'(inv_w1)+
           a2*longint'(u2)*longint'(inv_w2);
        nv=a0*longint'(v0)*longint'(inv_w0)+
           a1*longint'(v1)*longint'(inv_w1)+
           a2*longint'(v2)*longint'(inv_w2);
        if(a0+a1+a2==0 || den==0 ||
           inv_w0==0 || inv_w1==0 || inv_w2==0)
          expected_error=1;
        else begin
          ux=nu/den;vy=nv/den;
          if(ux < -32768 || ux>32767 || vy < -32768 || vy>32767)
            expected_error=1;
          else begin
            expected_u=integer'(ux);expected_v=integer'(vy);
          end
        end
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
      if(!req_ready)$fatal(1,"P166 interpolation request refused while idle");
      @(negedge clk);req_valid=0;
      if(req_ready)$fatal(1,"P166 accepted overlap during signed divider");
      loops=0;
      while(!rsp_valid)begin
        @(negedge clk);loops=loops+1;
        if(loops>195)$fatal(1,"P166 2x80 restoring division stalled");
      end
      if(rsp_id!==8'(token) || rsp_error!==1'(expect_error) ||
         (!expect_error &&
          (rsp_u!==16'(eu) || rsp_v!==16'(ev))) ||
         (expect_error && (rsp_u!==0 || rsp_v!==0)))
        $fatal(1,"P166 oracle mismatch id=%0d expected err/u/v=%0d/%0d/%0d got=%b/%0d/%0d",
          token,expect_error,eu,ev,rsp_error,$signed(rsp_u),$signed(rsp_v));
      held_u=rsp_u;held_v=rsp_v;held_error=rsp_error;
      // A backpressured response must remain stable for arbitrary cycles.
      repeat(3)begin
        @(negedge clk);
        if(!rsp_valid || req_ready || rsp_id!==8'(token) ||
           rsp_u!==held_u || rsp_v!==held_v || rsp_error!==held_error)
          $fatal(1,"P166 output mutated under host backpressure");
        held_outputs=held_outputs+1;
      end
      rsp_ready=1;
      @(negedge clk);rsp_ready=0;
      if(rsp_valid || !req_ready)$fatal(1,"P166 response not retired");
      checked=checked+1;
      if(inv_w0==0 || inv_w1==0 || inv_w2==0)zero_w_cases=zero_w_cases+1;
      if(wide_constant_case)wide_cases=wide_cases+1;
      if(inv_w0==inv_w1 && inv_w1==inv_w2)equal_w_cases=equal_w_cases+1;
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

  task automatic set_weights(input integer kind,reverse_winding);
    reg [15:0] tmp;
    begin
      case(kind)
        0:begin inv_w0=4096;inv_w1=4096;inv_w2=4096;end
        1:begin inv_w0=2048;inv_w1=4096;inv_w2=8192;end
        2:begin inv_w0=1;inv_w1=65535;inv_w2=256;end
        default:begin inv_w0=0;inv_w1=4096;inv_w2=8192;end
      endcase
      if(reverse_winding!=0)begin
        tmp=inv_w1;inv_w1=inv_w2;inv_w2=tmp;
      end
    end
  endtask

  integer id=0;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    for(integer triangle=0;triangle<7;triangle=triangle+1)
      for(integer uvset=0;uvset<4;uvset=uvset+1)
        for(integer weightset=0;weightset<4;weightset=weightset+1)begin
          set_triangle(triangle);
          set_uv(uvset,triangle==1 || triangle==3);
          set_weights(weightset,triangle==1 || triangle==3);
          for(integer py=-1;py<5;py=py+1)
            for(integer px=-1;px<5;px=px+1)begin
              pixel_x=16'(px);pixel_y=16'(py);
              check_one(id);id=id+1;
            end
          winding_cases=winding_cases+1;
        end

    // Out-of-range extrapolation must fail instead of wrapping signed UV.
    set_triangle(4);set_uv(1,0);set_weights(2,0);
    pixel_x=16'sd30000;pixel_y=16'sd30000;
    check_one(id);id=id+1;

    // Reset in the middle of a divide clears in-flight response and state.
    set_triangle(2);set_uv(0,0);set_weights(1,0);
    pixel_x=1;pixel_y=2;
    @(negedge clk);req_id=8'hab;req_valid=1;
    @(negedge clk);req_valid=0;
    repeat(11)@(negedge clk);
    if(req_ready || rsp_valid)$fatal(1,"P166 div unexpectedly finished before reset");
    rst_n=0;
    repeat(3)@(negedge clk);
    if(req_ready || rsp_valid || rsp_error || rsp_u!==0 || rsp_v!==0)
      $fatal(1,"P166 reset failed to discard active response");
    rst_n=1;reset_aborts=reset_aborts+1;
    check_one(id);id=id+1;

    // Extreme e*U*inverseW products exceed signed 64-bit. Because all
    // attributes are constant and inverseW is positive, the quotient MUST
    // equal those constants regardless of triangle dimensions or winding.
    wide_constant_case=1;
    x0=-32768;y0=-32768;x1=32767;y1=-32768;x2=-32768;y2=32767;
    u0=-32768;u1=-32768;u2=-32768;
    v0=32767;v1=32767;v2=32767;
    inv_w0=65535;inv_w1=65535;inv_w2=65535;
    pixel_x=0;pixel_y=0;check_one(id);id=id+1;
    wide_constant_case=0;

    if(checked!=4035 || matched<500 || errors<100 || negatives<150 ||
       held_outputs!=3*checked || winding_cases!=112 || reset_aborts!=1 ||
       zero_w_cases<100 || wide_cases!=1 || equal_w_cases<100)
      $fatal(1,"P166 insufficient signed oracle coverage checks=%0d matched=%0d errors=%0d negative=%0d holds=%0d windings=%0d resets=%0d",
        checked,matched,errors,negatives,held_outputs,winding_cases,reset_aborts,
      zero_w_cases,wide_cases,equal_w_cases);
    $display("P166_PERSPECTIVE_VERTEX_UV_PASS checks=%0d exact=%0d fail_closed=%0d signed_negative=%0d backpressure_checks=%0d winding_cases=%0d reset_abort=%0d zero_w=%0d wide=%0d equal_w=%0d serial_divisions_per_sample=2",
      checked,matched,errors,negatives,held_outputs,winding_cases,reset_aborts);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P166 UV test watchdog");end
endmodule
