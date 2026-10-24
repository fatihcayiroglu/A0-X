`timescale 1ns/1ps
// Independent integer oracle for the *real RTL* four-lane UNORM shader ALU.
// Checks all 8 opcodes, all lane masks, exact /255 with boundary and
// deterministic pseudo-random inputs, sustained 1 packet/clock, stall
// stability, tagged ordering and response flush on reset.
module a0_p150_unorm_simd4_alu_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,req_valid=0,rsp_ready=1;
  reg [7:0] req_id=0,uniform_alpha=0;
  reg [2:0] opcode=0;
  reg [3:0] lane_mask=0;
  reg [31:0] operand_a=0,operand_b=0;
  wire req_ready,rsp_valid;
  wire [7:0] rsp_id;
  wire [31:0] rsp_data;
  a0_p150_unorm_simd4_alu dut(
    .clk(clk),.rst_n(rst_n),
    .req_valid(req_valid),.req_ready(req_ready),.req_id(req_id),
    .opcode(opcode),.operand_a(operand_a),.operand_b(operand_b),
    .uniform_alpha(uniform_alpha),.lane_mask(lane_mask),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),
    .rsp_id(rsp_id),.rsp_data(rsp_data)
  );

  reg [39:0] expected[0:16000];
  integer sent=0,received=0,clock_count=0,stall_cycles=0;
  integer boundary_checks=0,random_checks=0,continuous_cycles=0;
  integer reset_flushes=0;
  reg stall_mode=0;
  integer t;
  reg [31:0] held_data;
  reg [7:0] held_id;
  reg [7:0] extremes[0:5];

  function automatic [31:0] model(
    input reg [2:0] op,
    input reg [31:0] a,b,
    input reg [7:0] alpha,
    input reg [3:0] mask
  );
    integer u,v,n,out_lane,lane;
    reg [31:0] result;
    begin
      result=0;
      for(lane=0;lane<4;lane=lane+1)begin
        u=int'((a>>(8*lane))&32'hff);
        v=int'((b>>(8*lane))&32'hff);
        out_lane=u;
        if(mask[lane])begin
          case(op)
            0:out_lane=u;
            1:out_lane=v;
            2:begin n=u+v;out_lane=(n>255)?255:n;end
            3:out_lane=(u<v)?0:(u-v);
            4:out_lane=(u*v+127)/255;
            5:out_lane=(u<v)?u:v;
            6:out_lane=(u>v)?u:v;
            7:out_lane=(u*(255-int'(alpha))+v*int'(alpha)+127)/255;
          endcase
        end
        result[8*lane+:8]=8'(out_lane);
      end
      model=result;
    end
  endfunction

  // Compare accepted outputs to a FIFO of independent mathematical
  // results. Full registered response hold is checked separately.
  always @(posedge clk)begin
    clock_count=clock_count+1;
    if(!rst_n)begin
      sent=0;received=0;
    end else begin
      if(rsp_valid && !rsp_ready)stall_cycles=stall_cycles+1;
      if(rsp_valid && rsp_ready)begin
        if(received>=sent)
          $fatal(1,"P150 extra shader reply without issued command");
        if({rsp_id,rsp_data}!==expected[received])
          $fatal(1,"P150 SIMD mismatch response %0d expected=%h got=%h",
            received,expected[received],{rsp_id,rsp_data});
        received=received+1;
      end
      if(req_valid && req_ready)begin
        if(sent>=16000)$fatal(1,"P150 scoreboard overflow");
        expected[sent]={req_id,model(opcode,operand_a,operand_b,
                                     uniform_alpha,lane_mask)};
        sent=sent+1;
      end
    end
  end
  always @(negedge clk)
    if(stall_mode)rsp_ready=(clock_count%13>=5);

  task automatic drive(input integer k);
    reg [31:0] pa,pb;
    begin
      pa=32'(32'h7395b1d3 ^ (k*32'h43a6f003) ^ (k>>3));
      pb=32'(32'hce21f70b ^ (k*32'h9e3779b9) ^ (k<<5));
      req_id=8'(k);
      opcode=3'(k%8);
      lane_mask=4'((k/8)%16);
      uniform_alpha=8'((k*13)^((k/15)*71));
      operand_a=pa;operand_b=pb;
    end
  endtask
  task automatic send(input integer k);
    integer n;
    begin
      @(negedge clk);
      drive(k);req_valid=1;
      #1;
      n=0;
      while(!req_ready)begin
        @(negedge clk);#1;
        n=n+1;
        if(n>300)$fatal(1,"P150 ALU backpressure did not clear");
      end
      @(posedge clk);#1;
      @(negedge clk);req_valid=0;
    end
  endtask
  task automatic drain;
    integer n;
    begin
      n=0;
      while(received<sent)begin
        @(negedge clk);
        n=n+1;
        if(n>300)$fatal(1,"P150 outstanding ALU response timeout");
      end
    end
  endtask

  initial begin
    extremes[0]=0;extremes[1]=1;extremes[2]=127;
    extremes[3]=128;extremes[4]=254;extremes[5]=255;
    repeat(4)@(negedge clk);rst_n=1;

    // Real continuous throughput at one accepted 4-lane instruction
    // each clock, with 128 consecutive valid beats and rsp_ready high.
    req_valid=1;stall_mode=0;rsp_ready=1;
    for(integer k=0;k<128;k=k+1)begin
      @(negedge clk);drive(k);
      #1;if(!req_ready)$fatal(1,"P150 missing full-rate packet acceptance");
      @(posedge clk);#1;
      continuous_cycles=continuous_cycles+1;
    end
    @(negedge clk);req_valid=0;
    drain();

    // Boundary matrix: each of 8 modes and all 6x6 endpoint operand
    // combinations, 6 alpha settings and four lane-mask patterns.
    for(integer op=0;op<8;op=op+1)
      for(integer a=0;a<6;a=a+1)
        for(integer b=0;b<6;b=b+1)
          for(integer z=0;z<6;z=z+1)
            for(integer mask=0;mask<4;mask=mask+1)begin
              @(negedge clk);
              req_valid=0;
              while(!req_ready)@(negedge clk);
              req_id=8'(boundary_checks);
              opcode=3'(op);
              operand_a={4{extremes[a]}};
              operand_b={4{extremes[b]}};
              uniform_alpha=extremes[z];
              case(mask)
                0:lane_mask=4'h0;
                1:lane_mask=4'h5;
                2:lane_mask=4'ha;
                default:lane_mask=4'hf;
              endcase
              req_valid=1;
              @(posedge clk);#1;
              @(negedge clk);req_valid=0;
              boundary_checks=boundary_checks+1;
            end
    drain();

    stall_mode=1;
    for(integer k=0;k<2048;k=k+1)begin
      send(k+3000);
      random_checks=random_checks+1;
    end
    drain();
    stall_mode=0;
    @(negedge clk);rsp_ready=1;

    // Deliberate held response, incoming valid packet cannot overwrite.
    send(7777);
    @(negedge clk);
    rsp_ready=0;
    req_valid=1;drive(7778);
    #1;
    if(!rsp_valid || req_ready)$fatal(1,"P150 held reply did not backpressure");
    held_data=rsp_data;held_id=rsp_id;
    for(integer j=0;j<18;j=j+1)begin
      @(negedge clk);#1;
      if(!rsp_valid || req_ready ||
         rsp_data!==held_data || rsp_id!==held_id)
        $fatal(1,"P150 response data/ID changed during host stall");
    end
    req_valid=0;rsp_ready=1;
    drain();

    // In-flight response must be flushed by reset. Do not replay.
    send(8888);
    @(negedge clk);rsp_ready=0;
    if(!rsp_valid)$fatal(1,"P150 missing response before reset");
    rst_n=0;
    repeat(3)@(negedge clk);
    if(rsp_valid || req_ready)$fatal(1,"P150 response leaked across reset");
    reset_flushes=reset_flushes+1;
    rst_n=1;rsp_ready=1;
    for(integer j=0;j<16;j=j+1)send(9000+j);
    drain();
    if(sent!=16 || received!=16 || boundary_checks!=6912 ||
       random_checks!=2048 || continuous_cycles!=128 ||
       stall_cycles<18 || reset_flushes!=1)
      $fatal(1,"P150 insufficient coverage b=%0d random=%0d streaming=%0d stalls=%0d sent=%0d received=%0d",
        boundary_checks,random_checks,continuous_cycles,stall_cycles,sent,received);
    $display("P150_UNORM_SIMD4_REAL_RTL_PASS boundary=%0d randomized=%0d consecutive_cycle_inputs=%0d stalled_response_cycles=%0d after_reset_replies=%0d modes=8 lane_masks=4",
      boundary_checks,random_checks,continuous_cycles,stall_cycles,received);
    $finish;
  end
  initial begin #50000000;$fatal(1,"P150 shader RTL watchdog");end
endmodule
