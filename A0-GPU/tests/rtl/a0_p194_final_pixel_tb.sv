`timescale 1ns/1ps
// P194: actual full-frame drawing into both upper-right framebuffer corner bytes.
// Demonstrate x=254/255 tile-local Q8.8 values while global color/depth remain unaliased.
module a0_p194_final_pixel_tb #(
  parameter integer W=256,H=256
);
  localparam integer BASE_X=W>128 ? 128 : 0;
  localparam integer BASE_Y=H>128 ? 128 : 0;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0,req_valid=0,req_write=0;
  logic [5:0] req_addr=0;
  logic [31:0] req_wdata=0;
  wire req_ready,rsp_valid,rsp_error;
  wire [31:0] rsp_rdata;
  a0_p175_scaled_programmed_command_top #(
    .FRAME_WIDTH(W),.FRAME_HEIGHT(H),.TILED_SCREEN_UV(1'b1)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_write(req_write),.req_ready(req_ready),
    .req_addr(req_addr),.req_wdata(req_wdata),
    .rsp_valid(rsp_valid),.rsp_error(rsp_error),.rsp_rdata(rsp_rdata)
  );
  function automatic [24:0] alu_copy_r1;
    alu_copy_r1={1'b0,8'd0,4'hf,3'd0,3'd1,3'd1,3'd1};
  endfunction
  task automatic txn(input bit write_en,input logic [5:0] addr,
       input logic [31:0] data,output bit error,
       output logic [31:0] value);
    integer loops;
    bit seen;
    begin
      @(negedge clk);loops=0;
      while(!req_ready)begin
        @(negedge clk);loops=loops+1;
        if(loops>300)$fatal(1,"P194 bus not ready");
      end
      req_valid=1;req_write=write_en;req_addr=addr;req_wdata=data;
      @(posedge clk);#2;
      seen=rsp_valid;
      if(seen)begin error=rsp_error;value=rsp_rdata;end
      @(negedge clk);req_valid=0;
      loops=0;
      while(!seen)begin
        @(posedge clk);#2;
        if(rsp_valid)begin seen=1;error=rsp_error;value=rsp_rdata;end
        loops=loops+1;
        if(loops>500)$fatal(1,"P194 deferred response missing");
      end
    end
  endtask
  task automatic wr(input logic [5:0] addr,input logic [31:0] data);
    bit err;logic [31:0] val;
    begin
      txn(1,addr,data,err,val);
      if(err)$fatal(1,"P194 unexpected write rejection reg=%0d data=%h",addr,data);
    end
  endtask
  task automatic rd(input logic [5:0] addr,output logic [31:0] data);
    bit err;
    begin
      txn(0,addr,0,err,data);
      if(err)$fatal(1,"P194 unexpected read rejection reg=%0d",addr);
    end
  endtask
  task automatic poll(input integer bit_index);
    integer loops;
    logic [31:0] status;
    begin
      status=0;loops=0;
      while(!status[bit_index])begin
        rd(17,status);
        if(status[2])$fatal(1,"P194 core fault status=%h",status);
        loops=loops+1;
        if(loops>W*H*20+500)$fatal(1,"P194 draw/clear timeout bit=%0d",bit_index);
      end
    end
  endtask
  task automatic check_pixel(input integer x,y,
      input logic [23:0] expected_rgb,expected_z);
    logic [31:0] rgb,z;
    begin
      wr(15,{16'(y),16'(x)});
      wr(16,32'd3);
      rd(18,rgb);rd(19,z);
      if(rgb[23:0]!==expected_rgb || z[23:0]!==expected_z)
        $fatal(1,"P194 wrong global pixel %0d,%0d got %h/%h expected %h/%h",
          x,y,rgb[23:0],z[23:0],expected_rgb,expected_z);
    end
  endtask
  // Every clear transaction must write its unique global linear address.
  // This also checks the second full clear after reset, with no bypass.
  integer accepted_clear_writes=0;
  always @(posedge clk) begin
    if(!rst_n) accepted_clear_writes<=0;
    else if(dut.core.framebuffer.good_fire && dut.core.framebuffer.op_clear) begin
      if(accepted_clear_writes >= W*H ||
         (int'(dut.core.fb_y_q)*W+int'(dut.core.fb_x_q)) != accepted_clear_writes)
        $fatal(1,"P194 missing/reordered clear write: count=%0d xy=%0d,%0d",
          accepted_clear_writes,dut.core.fb_x_q,dut.core.fb_y_q);
      accepted_clear_writes<=accepted_clear_writes+1;
    end
  end
  bit err;
  logic [31:0] answer,insns,texops;
  initial begin
    if(W!=256 || H!=256)
      $fatal(1,"P194 test shape unsupported");
    repeat(4)@(negedge clk);rst_n=1;
    wr(0,32'h00112233);wr(1,32'h00ffffff);wr(2,32'h00000040);
    wr(3,{16'(BASE_Y),16'(BASE_X)});
    wr(4,{16'(BASE_Y),16'(BASE_X+4)});
    wr(5,{16'(BASE_Y+4),16'(BASE_X)});
    wr(6,32'd0);
    wr(7,{16'd0,8'd255,4'd0,1'b0,1'b1,2'd1});
    wr(11,32'd0);wr(12,{7'd0,alu_copy_r1()});
    wr(8,{24'd0,3'd0,5'd1}); // shader output R0, one unrelated ALU op
    wr(16,32'd1);poll(3);
    if(accepted_clear_writes!=W*H)
      $fatal(1,"P194 did not write all %0d global pixels: %0d",W*H,accepted_clear_writes);
    check_pixel(BASE_X+1,BASE_Y+1,24'h112233,24'hffffff);
    check_pixel(255,255,24'h112233,24'hffffff);
    check_pixel(0,0,24'h112233,24'hffffff);
    check_pixel(1,1,24'h112233,24'hffffff);
    // Illegal out-of-range host coordinate is rejected without corrupting the frame.
    wr(15,{16'd0,16'd256});
    txn(1,6'd16,32'd3,err,answer);
    if(!err)$fatal(1,"P194 out-of-bounds host read accepted");
    wr(16,32'd2);poll(4);
    check_pixel(BASE_X+1,BASE_Y+1,24'h000100,24'h000040);
    check_pixel(BASE_X+2,BASE_Y,24'h000200,24'h000040);
    check_pixel(1,1,24'h112233,24'hffffff);
    check_pixel(255,255,24'h112233,24'hffffff);
    rd(20,answer);rd(21,insns);rd(22,texops);
    if(answer==0 || insns!==answer || texops!==0)
      $fatal(1,"P194 first shader retirement mismatch shaded=%0d insns=%0d tex=%0d",
        answer,insns,texops);

    // Draw a second real high-corner triangle. Vertices deliberately cross
    // x/y=255; clipping must retain the 254/255 framebuffer pixels.
    // Tile-local shader R0 must distinguish 126 and 127 without wrapping.
    wr(3,{16'd252,16'd252});
    wr(4,{16'd252,16'd262});
    wr(5,{16'd262,16'd252});
    wr(16,32'd2);poll(4);
    check_pixel(254,255,24'h007e00,24'h000040);
    check_pixel(255,255,24'h007f00,24'h000040);
    check_pixel(129,129,24'h000100,24'h000040);
    check_pixel(1,1,24'h112233,24'hffffff);
    rd(20,answer);rd(21,insns);rd(22,texops);
    if(answer==0 || insns!==answer || texops!==0)
      $fatal(1,"P194 final pixel retirement mismatch shaded=%0d insns=%0d tex=%0d",
        answer,insns,texops);
    @(negedge clk);rst_n=0;
    repeat(3)@(negedge clk);rst_n=1;
    wr(15,{16'(BASE_Y+1),16'(BASE_X+1)});
    txn(1,6'd16,32'd3,err,answer);
    if(!err)$fatal(1,"P194 uninitialized frame host read incorrectly accepted");
    // The host configuration registers are reset, not retained across reset.
    // Reprogram the required clear values before proving reinitialization.
    wr(0,32'h00112233);wr(1,32'h00ffffff);
    wr(16,32'd1);poll(3);
    if(accepted_clear_writes!=W*H)
      $fatal(1,"P194 post-reset clear incomplete: %0d",accepted_clear_writes);
    check_pixel(BASE_X+1,BASE_Y+1,24'h112233,24'hffffff);
    check_pixel(255,255,24'h112233,24'hffffff);
    $display("P194_TILED_PROGRAMMED_FRAME_PASS shape=%0dx%0d high_xy=%0d,%0d shader_retired=%0d final_pixel_rgb=007f00 ordered_clear_writes=65536 masked_reset=1",
      W,H,BASE_X+1,BASE_Y+1,insns);
    $finish;
  end
  initial begin #(W*H*100+100000); $fatal(1,"P194 simulation timeout"); end
endmodule
