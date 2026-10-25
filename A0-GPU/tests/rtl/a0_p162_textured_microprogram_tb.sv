`timescale 1ns/1ps
// Independent scalar texture oracle: do not derive expected colors from DUT
// BRAM, its lerp function, its ALU output, or any internal controller state.
module a0_p162_textured_microprogram_tb;
  reg clk=0;always #5 clk=~clk;
  reg rst_n=0,reg_write_valid=0,insn_write_valid=0;
  reg texture_write_valid=0,start=0;
  reg [2:0] reg_write_index=0,reg_read_index=0;
  reg [31:0] reg_write_data=0,texture_write_rgba=0;
  reg [3:0] insn_write_index=0,texture_write_x=0,texture_write_y=0;
  reg [24:0] insn_write_data=0;
  reg [4:0] start_length=0;
  wire [31:0] reg_read_data;
  wire texture_write_ready,ready,busy,done,fault;
  wire [4:0] retired_count,texture_retired_count;
  reg [31:0] golden[0:7],texels[0:255];
  reg tex_written[0:255];
  reg [24:0] prog_mem[0:15];
  integer programs_run=0,retired_total=0,tex_total=0;
  integer register_checks=0,busy_write_attempts=0;
  integer rejected=0,single_tap=0,texture_updates=0;

  a0_p162_textured_microprogram dut(
    .clk(clk),.rst_n(rst_n),
    .reg_write_valid(reg_write_valid),.reg_write_index(reg_write_index),
    .reg_write_data(reg_write_data),.reg_read_index(reg_read_index),
    .reg_read_data(reg_read_data),
    .insn_write_valid(insn_write_valid),.insn_write_index(insn_write_index),
    .insn_write_data(insn_write_data),
    .texture_write_valid(texture_write_valid),
    .texture_write_ready(texture_write_ready),
    .texture_write_x(texture_write_x),.texture_write_y(texture_write_y),
    .texture_write_rgba(texture_write_rgba),
    .start(start),.start_length(start_length),
    .ready(ready),.busy(busy),.done(done),.fault(fault),
    .retired_count(retired_count),
    .texture_retired_count(texture_retired_count)
  );

  function automatic [31:0] pixel_formula(input integer x,y);
    reg [7:0] r,g,b,a;
    begin
      r=8'(x*17+y*3+19);g=8'(x*11+y*7+23);
      b=8'(x*5+y*13+61);a=8'(x*9+y*21+103);
      pixel_formula={a,b,g,r};
    end
  endfunction
  function automatic [31:0] pack_uv(input integer u,v);
    pack_uv={16'(v),16'(u)};
  endfunction
  function automatic [24:0] alu_insn(
    input integer opcode,dst,sa,sb,mask,alpha
  );
    alu_insn={1'b0,8'(alpha),4'(mask),3'(opcode),3'(dst),3'(sa),3'(sb)};
  endfunction
  function automatic [24:0] tex_insn(
    input integer dst,sa,mask,repeat_mode
  );
    tex_insn={1'b1,7'd0,1'(repeat_mode),4'(mask),3'd0,
              3'(dst),3'(sa),3'd0};
  endfunction
  function automatic [31:0] scalar_alu(
    input integer op,input reg [31:0] a,b,
    input integer alpha,mask
  );
    integer lane,u,v,t,w;
    reg [31:0] result;
    begin
      result=0;
      for(lane=0;lane<4;lane=lane+1)begin
        u=(a>>(8*lane))&255;v=(b>>(8*lane))&255;
        w=u;
        if((mask>>lane)&1)begin
          case(op)
            0:w=u;
            1:w=v;
            2:begin t=u+v;w=t>255?255:t;end
            3:w=u>=v?u-v:0;
            4:w=(u*v+127)/255;
            5:w=u<v?u:v;
            6:w=u>v?u:v;
            7:w=(u*(255-alpha)+v*alpha+127)/255;
          endcase
        end
        result[8*lane+:8]=8'(w);
      end
      scalar_alu=result;
    end
  endfunction

  function automatic integer map_coord(input integer p,input integer repeat_mode);
    if(repeat_mode!=0)map_coord=p&15;
    else if(p<0)map_coord=0;
    else if(p>15)map_coord=15;
    else map_coord=p;
  endfunction
  function automatic [31:0] fetch(input integer x,y,repeat_mode);
    integer tx,ty;
    begin
      tx=map_coord(x,repeat_mode);ty=map_coord(y,repeat_mode);
      fetch=tex_written[ty*16+tx]?texels[ty*16+tx]:32'd0;
    end
  endfunction
  function automatic integer present(input integer x,y,repeat_mode);
    integer tx,ty;
    begin
      tx=map_coord(x,repeat_mode);ty=map_coord(y,repeat_mode);
      present=tex_written[ty*16+tx];
    end
  endfunction
  function automatic [31:0] bilinear_oracle(
    input reg [31:0] uv,input integer repeat_mode
  );
    integer u,v,x,y,fx,fy,lane,a,b,c,d,h0,h1,z;
    reg [31:0] t0,t1,t2,t3,result;
    begin
      u=$signed(uv[15:0]);v=$signed(uv[31:16]);
      x=u>>>8;y=v>>>8;fx=u&255;fy=v&255;
      if(!present(x,y,repeat_mode) ||
         (fx!=0 && !present(x+1,y,repeat_mode)) ||
         (fy!=0 && !present(x,y+1,repeat_mode)) ||
         (fx!=0 && fy!=0 && !present(x+1,y+1,repeat_mode)))
        $fatal(1,"P162 invalid test fixture: expected a missing weighted texel");
      t0=fetch(x,y,repeat_mode);t1=fetch(x+1,y,repeat_mode);
      t2=fetch(x,y+1,repeat_mode);t3=fetch(x+1,y+1,repeat_mode);
      result=0;
      for(lane=0;lane<4;lane=lane+1)begin
        a=(t0>>(8*lane))&255;b=(t1>>(8*lane))&255;
        c=(t2>>(8*lane))&255;d=(t3>>(8*lane))&255;
        h0=(a*(256-fx)+b*fx+128)/256;
        h1=(c*(256-fx)+d*fx+128)/256;
        z=(h0*(256-fy)+h1*fy+128)/256;
        result[8*lane+:8]=8'(z);
      end
      bilinear_oracle=result;
    end
  endfunction
  task automatic reset_device;
    begin
      @(negedge clk);rst_n=0;
      reg_write_valid=0;insn_write_valid=0;
      texture_write_valid=0;start=0;
      repeat(4)@(negedge clk);
      if(ready || busy || done || fault || retired_count!=0 ||
         texture_retired_count!=0)
        $fatal(1,"P162 reset did not clear execution state");
      rst_n=1;
      for(integer i=0;i<8;i=i+1)golden[i]=0;
      for(integer i=0;i<256;i=i+1)begin
        tex_written[i]=0;texels[i]=0;
      end
    end
  endtask
  task automatic wr_reg(input integer idx,input reg [31:0] value);
    begin
      @(negedge clk);
      if(!ready)$fatal(1,"P162 register load while not idle");
      reg_write_index=3'(idx);reg_write_data=value;reg_write_valid=1;
      @(negedge clk);reg_write_valid=0;golden[idx]=value;
    end
  endtask
  task automatic wr_insn(input integer idx,input reg [24:0] word);
    begin
      @(negedge clk);
      if(!ready)$fatal(1,"P162 program load while not idle");
      insn_write_index=4'(idx);insn_write_data=word;insn_write_valid=1;
      @(negedge clk);insn_write_valid=0;prog_mem[idx]=word;
    end
  endtask
  task automatic wr_tex(input integer x,y,input reg [31:0] rgba);
    begin
      @(negedge clk);
      if(!ready || !texture_write_ready)
        $fatal(1,"P162 texture not writable when idle");
      texture_write_x=4'(x);texture_write_y=4'(y);
      texture_write_rgba=rgba;texture_write_valid=1;
      @(negedge clk);texture_write_valid=0;
      texels[y*16+x]=rgba;tex_written[y*16+x]=1;
      texture_updates=texture_updates+1;
    end
  endtask
  task automatic load_full_texture;
    begin
      for(integer y=0;y<16;y=y+1)
        for(integer x=0;x<16;x=x+1)
          wr_tex(x,y,pixel_formula(x,y));
    end
  endtask
  task automatic check_regs;
    begin
      for(integer i=0;i<8;i=i+1)begin
        @(negedge clk);reg_read_index=3'(i);#1;
        if(reg_read_data!==golden[i])
          $fatal(1,"P162 oracle mismatch reg=%0d expected=%h actual=%h program=%0d",
                 i,golden[i],reg_read_data,programs_run);
        register_checks=register_checks+1;
      end
    end
  endtask
  task automatic run_program(input integer length,input integer inject_writes);
    integer idx,dst,sa,sb,op,mask,alpha,tex_in_run,timeout_ticks;
    reg [24:0] insn;
    reg [31:0] sample_value,merged;
    begin
      if(!ready || busy || fault)$fatal(1,"P162 launch not idle");
      tex_in_run=0;
      for(idx=0;idx<length;idx=idx+1)begin
        insn=prog_mem[idx];dst=insn[8:6];sa=insn[5:3];
        sb=insn[2:0];op=insn[11:9];mask=insn[15:12];
        alpha=insn[23:16];
        if(insn[24])begin
          if(op!=0 || sb!=0 || (alpha&254)!=0)
            $fatal(1,"P162 expected program has invalid TEX encoding");
          sample_value=bilinear_oracle(golden[sa],alpha&1);
          merged=golden[dst];
          for(integer lane=0;lane<4;lane=lane+1)
            if((mask>>lane)&1)
              merged[8*lane+:8]=sample_value[8*lane+:8];
          golden[dst]=merged;
          tex_in_run=tex_in_run+1;
        end else
          golden[dst]=scalar_alu(op,golden[sa],golden[sb],alpha,mask);
      end
      @(negedge clk);start_length=5'(length);start=1;
      @(negedge clk);start=0;
      if(!busy || ready || fault)$fatal(1,"P162 failed to become busy");
      if(inject_writes!=0)begin
        reg_write_valid=1;reg_write_index=1;reg_write_data=32'hdeadbeef;
        insn_write_valid=1;insn_write_index=1;insn_write_data='1;
        texture_write_valid=1;texture_write_x=4;texture_write_y=7;
        texture_write_rgba=32'hbad00bad;
        if(texture_write_ready)$fatal(1,"P162 busy texture falsely ready");
        @(negedge clk);
        reg_write_valid=0;insn_write_valid=0;texture_write_valid=0;
        busy_write_attempts=busy_write_attempts+1;
      end
      timeout_ticks=0;
      while(!done && !fault)begin
        @(negedge clk);timeout_ticks=timeout_ticks+1;
        if(timeout_ticks>length*48+100)
          $fatal(1,"P162 shader deadlocked after %0d cycles",timeout_ticks);
      end
      if(fault || !ready || busy || retired_count!==5'(length) ||
         texture_retired_count!==5'(tex_in_run))
        $fatal(1,"P162 completion mismatch done=%b fault=%b retired=%0d tex=%0d expected_tex=%0d",
               done,fault,retired_count,texture_retired_count,tex_in_run);
      programs_run=programs_run+1;
      retired_total=retired_total+length;tex_total=tex_total+tex_in_run;
      check_regs();
    end
  endtask
  task automatic expect_sticky_fault;
    begin
      repeat(3)@(negedge clk);
      if(!fault || ready || busy || done)
        $fatal(1,"P162 fault did not remain latched");
      rejected=rejected+1;
    end
  endtask

  integer grp,dst,u,v;
  initial begin
    reset_device();
    load_full_texture();
    for(integer roundno=0;roundno<48;roundno=roundno+1)begin
      // Force subtexel, border, negative, repeat and interior footprints.
      u=((roundno*5)%23-3)*256+((roundno*37+59)%256);
      v=((roundno*7)%23-3)*256+((roundno*53+101)%256);
      if(roundno==24)begin
        // Explicit idle read-after-write texture mutation, independently
        // reflected in oracle. A subsequent TEX must consume the new BRAM.
        wr_tex(4,7,32'hd3a15be7);
        u=4*256+117;v=7*256+201;
      end
      for(integer r=0;r<8;r=r+1)
        wr_reg(r,32'h7f326011 ^ (32'(r)*32'h10240811) ^ (32'(roundno)*32'h2030405));
      wr_reg(1,pack_uv(u,v));
      for(integer p=0;p<16;p=p+1)begin
        grp=p/4;dst=grp+2;
        case(p%4)
          0:wr_insn(p,alu_insn(1,0,0,1,15,0));
          1:wr_insn(p,tex_insn(dst,0,(roundno+p)%16,(roundno+grp)%2));
          2:wr_insn(p,alu_insn((roundno+grp)%8,dst,dst,7,15,
                                (roundno*11+grp*29)%256));
          3:wr_insn(p,alu_insn(7,6,dst,3,(roundno*3+p)%16,
                                (roundno*17+p*7)%256));
        endcase
      end
      run_program(16,(roundno%4)==0);
    end
    if(programs_run!=48 || retired_total!=768 || tex_total!=192 ||
       busy_write_attempts!=12 || register_checks!=384 || texture_updates!=257)
      $fatal(1,"P162 vacuous coverage programs=%0d retired=%0d TEX=%0d busy=%0d reads=%0d writes=%0d",
             programs_run,retired_total,tex_total,busy_write_attempts,
             register_checks,texture_updates);

    // Zero-length start must latch fault; no program should retire.
    @(negedge clk);start=1;start_length=0;
    @(negedge clk);start=0;
    expect_sticky_fault();

    // Zero-weight neighboring unwritten texels are correctly irrelevant.
    reset_device();
    wr_tex(0,0,32'hdeadbeef);
    wr_reg(0,pack_uv(0,0));
    wr_reg(2,32'h0c0c0c0c);
    wr_insn(0,tex_insn(2,0,15,0));
    run_program(1,0);single_tap=single_tap+1;

    // With both fractions nonzero, missing neighboring taps fault closed.
    wr_reg(0,pack_uv(128,128));
    @(negedge clk);start=1;start_length=1;
    @(negedge clk);start=0;
    repeat(90)@(negedge clk);
    if(!fault || retired_count!=0 || texture_retired_count!=0)
      $fatal(1,"P162 unwritten weighted texel incorrectly retired");
    reg_read_index=2;#1;
    if(reg_read_data!==golden[2])
      $fatal(1,"P162 missing TEX mutated destination register");
    expect_sticky_fault();

    // Reserved TEX fields cannot silently reinterpret as arithmetic.
    reset_device();
    wr_insn(0,{1'b1,8'd0,4'hf,3'd1,3'd2,3'd0,3'd0});
    @(negedge clk);start=1;start_length=1;
    @(negedge clk);start=0;
    expect_sticky_fault();

    // Same-cycle start + texture upload rejects the whole transaction.
    reset_device();
    @(negedge clk);
    start=1;start_length=1;texture_write_valid=1;
    texture_write_x=0;texture_write_y=0;
    texture_write_rgba=32'h12345678;
    if(texture_write_ready)
      $fatal(1,"P162 accepted texture write during start collision");
    @(negedge clk);start=0;texture_write_valid=0;
    expect_sticky_fault();

    // Full reset recovery: previously latched misses/errors are erased.
    reset_device();
    load_full_texture();
    wr_reg(1,pack_uv(5*256+101,8*256+201));
    wr_reg(7,32'h593a0fc5);
    wr_insn(0,alu_insn(1,0,0,1,15,0));
    wr_insn(1,tex_insn(2,0,15,1));
    wr_insn(2,alu_insn(4,3,2,7,15,0));
    run_program(3,1);
    if(rejected!=4 || single_tap!=1 ||
       programs_run!=50 || retired_total!=772 || tex_total!=194)
      $fatal(1,"P162 missing adversarial coverage rejected=%0d single_tap=%0d runs=%0d retired=%0d TEX=%0d",
             rejected,single_tap,programs_run,retired_total,tex_total);
    $display("P162_TEXTURED_MICROPROGRAM_PASS programs=%0d retired=%0d TEX=%0d independent_register_checks=%0d blocked_busy_config=%0d fail_closed=%0d single_tap=%0d real_texture_writes=%0d",
             programs_run,retired_total,tex_total,register_checks,
             busy_write_attempts,rejected,single_tap,texture_updates);
    $finish;
  end
  initial begin #100000000;$fatal(1,"P162 watchdog");end
endmodule
