`timescale 1ns/1ps
// P168: independent, previously validated P164 affine engine is the golden
// hardware reference for the P166 shared-engine all-one inverse-W fast path.
// Covers signed UV, reverse winding, degeneration, extrapolation and reset.
module a0_p168_shared_affine_uv_tb;
  reg clk=0;
  always #5 clk=~clk;
  reg rst_n=0,req_valid=0,rsp_ready=0;
  reg signed [15:0] x0=0,y0=0,x1=0,y1=0,x2=0,y2=0;
  reg signed [15:0] u0=0,v0=0,u1=0,v1=0,u2=0,v2=0;
  reg signed [15:0] pixel_x=0,pixel_y=0;
  reg [7:0] req_id=0;
  wire aready,bready,avalid,bvalid,aerror,berror;
  wire [7:0] aid,bid;
  wire signed [15:0] au,av,bu,bv;
  integer checked=0,passed=0,failed_closed=0,fast_cycles=0;
  integer negative=0,backpressure_checks=0,reset_abort=0;

  a0_p164_affine_vertex_uv reference_affine(
    .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(aready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .u0(u0),.v0(v0),.u1(u1),.v1(v1),.u2(u2),.v2(v2),
    .pixel_x(pixel_x),.pixel_y(pixel_y),.req_id(req_id),
    .rsp_valid(avalid),.rsp_ready(rsp_ready),
    .rsp_id(aid),.rsp_u(au),.rsp_v(av),.rsp_error(aerror)
  );
  a0_p166_perspective_vertex_uv shared_fast_affine(
    .clk(clk),.rst_n(rst_n),.req_valid(req_valid),.req_ready(bready),
    .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
    .u0(u0),.v0(v0),.u1(u1),.v1(v1),.u2(u2),.v2(v2),
    .inv_w0(16'd1),.inv_w1(16'd1),.inv_w2(16'd1),
    .pixel_x(pixel_x),.pixel_y(pixel_y),.req_id(req_id),
    .rsp_valid(bvalid),.rsp_ready(rsp_ready),
    .rsp_id(bid),.rsp_u(bu),.rsp_v(bv),.rsp_error(berror)
  );
  task automatic setup_triangle(input integer kind);
    begin
      case(kind)
        0:begin x0=-2;y0=-2;x1=9;y1=-2;x2=-2;y2=9;end
        1:begin x0=-2;y0=-2;x1=-2;y1=9;x2=9;y2=-2;end
        2:begin x0=0;y0=0;x1=1;y1=1;x2=2;y2=2;end
        default:begin
          x0=-32768;y0=-32768;x1=32767;y1=-32768;
          x2=-32768;y2=32767;
        end
      endcase
    end
  endtask
  task automatic setup_attributes(input integer kind);
    begin
      case(kind)
        0:begin
          u0=-512;v0=0;u1=3584;v1=256;u2=320;v2=4096;
        end
        1:begin
          u0=127;v0=-999;u1=-32768;v1=32767;u2=32767;v2=-32768;
        end
        2:begin
          u0=-32768;v0=32767;u1=-32768;v1=32767;
          u2=-32768;v2=32767;
        end
        default:begin
          u0=11;v0=257;u1=-31;v1=513;u2=3999;v2=-1;
        end
      endcase
    end
  endtask
  task automatic check_one(input integer token);
    integer cycles;
    reg signed [15:0] held_u,held_v;
    reg held_error;
    begin
      @(negedge clk);req_id=8'(token);req_valid=1;
      if(!aready || !bready)
        $fatal(1,"P168 shared UV request unexpectedly refused");
      @(negedge clk);req_valid=0;
      cycles=0;
      while(!avalid || !bvalid)begin
        @(negedge clk);cycles=cycles+1;
        if(cycles>140)
          $fatal(1,"P168 fast affine did not complete in 128 divider cycles");
      end
      if(aid!==8'(token) || bid!==8'(token) || aerror!==berror ||
         au!==bu || av!==bv)
        $fatal(1,"P168 shared/reference mismatch token=%0d err=%b/%b uv=%0d,%0d/%0d,%0d",
          token,aerror,berror,$signed(au),$signed(av),$signed(bu),$signed(bv));
      if(!aerror)begin
        if(cycles!=128)
          $fatal(1,"P168 affine result latency drifted cycles=%0d expected=128",cycles);
        fast_cycles=fast_cycles+cycles;
        passed=passed+1;
        if(au<0 || av<0)negative=negative+1;
      end else begin
        if(cycles>128) $fatal(1,"P168 fail-closed latency drift");
        failed_closed=failed_closed+1;
      end
      held_u=bu;held_v=bv;held_error=berror;
      repeat(2)begin
        @(negedge clk);
        if(!avalid || !bvalid || aready || bready ||
           bu!==held_u || bv!==held_v || berror!==held_error)
          $fatal(1,"P168 in-flight result mutated under backpressure");
        backpressure_checks=backpressure_checks+1;
      end
      rsp_ready=1;
      @(negedge clk);rsp_ready=0;
      if(avalid || bvalid || !aready || !bready)
        $fatal(1,"P168 handshake failed to retire both results");
      checked=checked+1;
    end
  endtask
  integer id=0;
  initial begin
    repeat(4) @(negedge clk);rst_n=1;
    for(integer t=0;t<4;t=t+1)
      for(integer a=0;a<4;a=a+1)begin
        setup_triangle(t);setup_attributes(a);
        for(integer py=-1;py<7;py=py+1)
          for(integer px=-1;px<7;px=px+1)begin
            pixel_x=16'(px);pixel_y=16'(py);
            check_one(id);id=id+1;
          end
      end
    // An aborted divider cannot leak a result after reset.
    setup_triangle(0);setup_attributes(0);pixel_x=1;pixel_y=2;
    @(negedge clk);req_valid=1;
    @(negedge clk);req_valid=0;
    repeat(12) @(negedge clk);
    if(avalid || bvalid || aready || bready)
      $fatal(1,"P168 reset fixture unexpectedly completed");
    rst_n=0;
    repeat(3) @(negedge clk);
    if(avalid || bvalid || aready || bready || au!==0 || av!==0 ||
       bu!==0 || bv!==0)
      $fatal(1,"P168 reset failed to discard a pending request");
    rst_n=1;reset_abort=reset_abort+1;
    check_one(id);id=id+1;
    if(checked!=1025 || passed<200 || failed_closed<100 ||
       negative<100 || backpressure_checks!=2*checked ||
       reset_abort!=1)
      $fatal(1,"P168 coverage too small cases=%0d pass=%0d closed=%0d negative=%0d",
        checked,passed,failed_closed,negative);
    $display("P168_SHARED_AFFINE_UV_PASS cases=%0d success=%0d fail_closed=%0d negative=%0d fast_cycles=%0d backpressure=%0d reset_abort=%0d",
      checked,passed,failed_closed,negative,fast_cycles,
      backpressure_checks,reset_abort);
    $finish;
  end
  initial begin #30000000;$fatal(1,"P168 shared UV RTL watchdog");end
endmodule
