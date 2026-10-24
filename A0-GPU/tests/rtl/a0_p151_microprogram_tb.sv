`timescale 1ns/1ps
// P151 genuine 16-instruction shader research golden_insns execution vs
// independent scalar /255 and saturation oracle. Check RAW dependencies,
// all 8 opcodes, 8 registers, partial masks, busy-write isolation,
// exact retirement counts, invalid commands and reset-recovery.
module a0_p151_microprogram_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,reg_write_valid=0,insn_write_valid=0,start=0;
  reg [2:0] reg_write_index=0,reg_read_index=0;
  reg [31:0] reg_write_data=0;
  reg [3:0] insn_write_index=0;
  reg [23:0] insn_write_data=0;
  reg [4:0] start_length=0;
  wire [31:0] reg_read_data;
  wire ready,busy,done,fault;
  wire [4:0] retired_count;
  reg [31:0] golden[0:7];
  reg [23:0] golden_insns[0:15];
  integer programs_run=0,instructions_run=0,raw_hazards=0;
  integer ignored_busy_writes=0,bad_launches=0,read_checks=0;
  integer tick=0;
  always @(posedge clk)tick=tick+1;

  a0_p151_unorm_microprogram dut(
    .clk(clk),.rst_n(rst_n),
    .reg_write_valid(reg_write_valid),
    .reg_write_index(reg_write_index),.reg_write_data(reg_write_data),
    .reg_read_index(reg_read_index),.reg_read_data(reg_read_data),
    .insn_write_valid(insn_write_valid),
    .insn_write_index(insn_write_index),.insn_write_data(insn_write_data),
    .start(start),.start_length(start_length),
    .ready(ready),.busy(busy),.done(done),.fault(fault),
    .retired_count(retired_count)
  );
  function automatic [31:0] scalar_model(
    input reg [2:0] op,input reg [31:0] a,b,
    input reg [7:0] alpha,input reg [3:0] mask
  );
    integer lane,u,v,result,t;
    reg [31:0] out;
    begin
      out=0;
      for(lane=0;lane<4;lane=lane+1)begin
        u=(a>>(8*lane))&255;v=(b>>(8*lane))&255;
        result=u;
        if(mask[lane])begin
          case(op)
            0:result=u;
            1:result=v;
            2:begin t=u+v;result=(t>255)?255:t;end
            3:result=(u<v)?0:u-v;
            4:result=(u*v+127)/255;
            5:result=(u<v)?u:v;
            6:result=(u>v)?u:v;
            7:result=(u*(255-int'(alpha))+v*int'(alpha)+127)/255;
          endcase
        end
        out[8*lane+:8]=8'(result);
      end
      scalar_model=out;
    end
  endfunction
  function automatic [23:0] mk_instruction(
    input integer idx,roundno
  );
    reg [2:0] op,dst,sa,sb;
    reg [3:0] mask;
    reg [7:0] a;
    begin
      op=3'((idx+roundno)%8);
      dst=3'((idx+3*roundno)%8);
      // Source A depends on the PREVIOUS instruction's destination
      // whenever idx>0 (true read-after-write scoreboard hazard).
      sa=3'((idx==0)?(roundno%8):((idx-1+3*roundno)%8));
      sb=3'((idx+roundno+3)%8);
      mask=4'((idx*7+roundno)%16);
      a=8'((idx*17+roundno*13)^8'h91);
      mk_instruction={a,mask,op,dst,sa,sb};
    end
  endfunction
  task automatic wr_reg(input integer idx,input reg [31:0] value);
    begin
      @(negedge clk);
      if(!ready)$fatal(1,"P151 register write when not ready");
      reg_write_index=3'(idx);reg_write_data=value;reg_write_valid=1;
      @(posedge clk);
      @(negedge clk);reg_write_valid=0;
      golden[idx]=value;
    end
  endtask
  task automatic wr_insn(input integer idx,input reg [23:0] value);
    begin
      @(negedge clk);
      if(!ready)$fatal(1,"P151 instruction load while running");
      insn_write_index=4'(idx);insn_write_data=value;
      insn_write_valid=1;
      @(posedge clk);
      @(negedge clk);insn_write_valid=0;
      golden_insns[idx]=value;
    end
  endtask
  task automatic check_regs;
    begin
      for(integer r=0;r<8;r=r+1)begin
        @(negedge clk);
        reg_read_index=3'(r);#1;
        if(reg_read_data !== golden[r])
          $fatal(1,"P151 register %0d mismatch expected=%h actual=%h after programs=%0d",
                 r,golden[r],reg_read_data,programs_run);
        read_checks=read_checks+1;
      end
    end
  endtask
  task automatic run(input integer len,input reg inject_busy_write);
    integer k,limit,cycles_before;
    reg [23:0] instruction;
    reg [2:0] dst,sa,sb,op;
    reg [3:0] mask;
    reg [7:0] alpha;
    begin
      if(!ready || busy || fault)$fatal(1,"P151 engine not idle at launch");
      for(k=0;k<len;k=k+1)begin
        instruction=golden_insns[k];
        sb=instruction[2:0];sa=instruction[5:3];
        dst=instruction[8:6];op=instruction[11:9];
        mask=instruction[15:12];alpha=instruction[23:16];
        golden[dst]=scalar_model(op,golden[sa],golden[sb],alpha,mask);
        if(k>0)raw_hazards=raw_hazards+1;
      end
      @(negedge clk);
      start_length=5'(len);start=1;cycles_before=tick;
      @(posedge clk);
      @(negedge clk);start=0;
      if(!busy || ready || fault)$fatal(1,"P151 failed to enter running state");
      if(inject_busy_write)begin
        reg_write_valid=1;reg_write_index=0;reg_write_data=32'hdeadbeef;
        insn_write_valid=1;insn_write_index=0;insn_write_data=24'hffffff;
        @(posedge clk);
        @(negedge clk);reg_write_valid=0;insn_write_valid=0;
        ignored_busy_writes=ignored_busy_writes+1;
      end
      limit=0;
      while(!done)begin
        @(negedge clk);
        limit=limit+1;
        if(limit>len*8+20)
          $fatal(1,"P151 instruction retirement timeout len=%0d",len);
      end
      if(!ready || busy || fault || retired_count!==5'(len))
        $fatal(1,"P151 wrong completion ready=%b busy=%b fault=%b retired=%0d len=%0d",
               ready,busy,fault,retired_count,len);
      programs_run=programs_run+1;
      instructions_run=instructions_run+len;
      check_regs();
    end
  endtask

  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    for(integer r=0;r<8;r=r+1)
      wr_reg(r,32'(32'h3246dc80 ^ (r*32'h10101011)));
    for(integer p=0;p<16;p=p+1)wr_insn(p,mk_instruction(p,0));
    run(16,1);

    // Many independent programs, each with explicit RAW dependencies,
    // multi-operand instructions and different masks/alphas/opcodes.
    for(integer roundno=1;roundno<=48;roundno=roundno+1)begin
      for(integer p=0;p<16;p=p+1)
        wr_insn(p,mk_instruction(p,roundno));
      run(16,(roundno%5)==0);
    end
    for(integer p=0;p<16;p=p+1)wr_insn(p,mk_instruction(p,97));
    run(1,0);
    run(7,0);
    if(programs_run!=51 || instructions_run!=792 ||
       raw_hazards<700 || ignored_busy_writes<9 || read_checks<400)
      $fatal(1,"P151 vacuous dependency coverage runs=%0d retired=%0d hazards=%0d busy_wr=%0d read=%0d",
        programs_run,instructions_run,raw_hazards,ignored_busy_writes,read_checks);

    // An empty golden_insns is a *latched* error, not silent success.
    @(negedge clk);start_length=0;start=1;
    @(posedge clk);@(negedge clk);start=0;
    if(!fault || ready || busy || done)
      $fatal(1,"P151 invalid zero-length golden_insns was accepted");
    bad_launches=bad_launches+1;
    repeat(4)@(negedge clk);
    if(!fault)$fatal(1,"P151 invalid golden_insns fault self-cleared");

    // Physical reset clears instruction memory, registers and errors.
    rst_n=0;
    repeat(3)@(negedge clk);
    if(fault || busy || done || ready || retired_count!=0)
      $fatal(1,"P151 failed power-on reset behavior");
    rst_n=1;
    for(integer r=0;r<8;r=r+1)golden[r]=0;
    check_regs();
    wr_reg(0,32'h10203040);wr_reg(1,32'h55667788);
    wr_insn(0,{8'd255,4'hf,3'd7,3'd2,3'd0,3'd1});
    run(1,0);

    // Concurrent launch and golden_insns update must fail closed.
    @(negedge clk);
    start=1;start_length=1;insn_write_valid=1;
    @(posedge clk);
    @(negedge clk);start=0;insn_write_valid=0;
    if(!fault || ready || done || busy)
      $fatal(1,"P151 simultaneous load/run accepted unsafely");
    bad_launches=bad_launches+1;
    if(bad_launches!=2)
      $fatal(1,"P151 insufficient rejected launch coverage");
    $display("P151_UNORM_SHADER_MICROPROGRAM_PASS programs=%0d retired=%0d RAW_checks=%0d ignored_busy_writes=%0d readback_checks=%0d fail_closed_launches=%0d register_count=8 instruction_slots=16",
      programs_run,instructions_run,raw_hazards,ignored_busy_writes,read_checks,bad_launches);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P151 golden_insns test watchdog");end
endmodule
