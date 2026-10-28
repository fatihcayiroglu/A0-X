`timescale 1ns/1ps
// P207 hardware-to-hardware isolation acceptance: NO memory model.
// Run with WORDS=8 and again with default WORDS=1024.
module a0_p207_two_bram_banks_tb #(
  parameter integer WORDS=8
);
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,host_valid=0,host_write=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  wire host_ready,fault,busy;
  wire [7:0] host_rdata;
  localparam logic [31:0] BASE=32'h01000000;
  localparam logic [47:0] A=48'h0123456789AB,
    B=48'hAABBCCDDEEFF,C=48'h1234F0E1D2C3,D=48'hEFE0D0C0B0A0;
  a0_p207_two_bram_banks #(
    .WORDS(WORDS),.RESPONSE_TIMEOUT(256)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .fault(fault),.busy(busy)
  );
  task automatic hw(input logic [5:0] a,input logic [7:0] v);
    begin
      @(negedge clk);host_valid=1;host_write=1;host_addr=a;host_wdata=v;
      #1;if(!host_ready)$fatal(1,"P207 host write blocked unexpectedly addr=%h",a);
      @(negedge clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] v);
    begin
      @(negedge clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P207 read not ready addr=%h",a);
      v=host_rdata;
      @(negedge clk);host_valid=0;
    end
  endtask
  task automatic reset_both;
    integer n;
    begin
      @(negedge clk);rst_n=0;host_valid=0;host_write=0;
      repeat(3)@(negedge clk);rst_n=1;
      n=0;
      while(busy && n<WORDS+120)begin @(negedge clk);n=n+1;end
      if(busy || fault || n<WORDS || dut.bank_sel_q!==0)
        $fatal(1,"P207 both banks not scrubbed before host readiness n=%0d",n);
    end
  endtask
  task automatic select_bank(input logic bank);
    logic [7:0] v;
    begin
      hw(6'h30,{7'd0,bank});
      hr(6'h30,v);
      if(v[0]!==bank || fault || v[1])
        $fatal(1,"P207 bank selection failed requested=%b status=%h",bank,v);
    end
  endtask
  task automatic prepare(input logic wr,input logic [31:0] addr,
                         input logic [47:0] pixel);
    integer i;
    begin
      hw(6'h02,{7'd0,wr});
      for(i=0;i<4;i=i+1)hw(6'h04+6'(i),addr[i*8+:8]);
      if(wr)
        for(i=0;i<6;i=i+1)hw(6'h08+6'(i),pixel[i*8+:8]);
    end
  endtask
  task automatic done_ack;
    logic [7:0] v;
    integer spins;
    begin
      spins=0;v=0;
      while(!v[3] && spins<160)begin
        hr(6'h01,v);spins=spins+1;
        if(v[4] || fault)$fatal(1,"P207 bank fault under legal operation");
      end
      if(!v[3] || spins<3)
        $fatal(1,"P207 early/missing commit DONE spins=%0d",spins);
      hr(6'h16,v);
      if(v[0])$fatal(1,"P207 bank reported error");
      hw(6'h00,8'h02);
    end
  endtask
  task automatic write_word(input logic [31:0] addr,input logic [47:0] pixel);
    begin prepare(1,addr,pixel);hw(6'h00,8'h01);done_ack();end
  endtask
  task automatic read_word(input logic [31:0] addr,input logic [47:0] expected);
    logic [7:0] b;
    logic [47:0] got;
    integer i;
    begin
      prepare(0,addr,0);
      hw(6'h00,8'h01);
      // Read result first, then clear the host DONE flag.
      b=0;
      begin : wait_read
        integer spins;spins=0;
        while(!b[3] && spins<160)begin
          hr(6'h01,b);spins=spins+1;
          if(fault)$fatal(1,"P207 read fault");
        end
        if(!b[3])$fatal(1,"P207 read timeout");
      end
      for(i=0;i<6;i=i+1)begin
        hr(6'h10+6'(i),b);got[i*8+:8]=b;
      end
      if(got!==expected)$fatal(1,"P207 readback %h expected %h addr %h",got,expected,addr);
      hw(6'h00,8'h02);
    end
  endtask
  initial begin
    reset_both();
    // The banks have disjoint physical address windows and independent EBR.
    write_word(BASE,A);
    write_word(BASE+WORDS-1,B);
    select_bank(1);
    write_word(BASE+WORDS,C);
    write_word(BASE+(2*WORDS)-1,D);
    if(dut.bank0.ram[0]!==A || dut.bank0.ram[WORDS-1]!==B ||
       dut.bank1.ram[0]!==C || dut.bank1.ram[WORDS-1]!==D)
      $fatal(1,"P207 not actually committed to two different EBR arrays");
    select_bank(0);
    read_word(BASE,A);
    read_word(BASE+WORDS-1,B);
    select_bank(1);
    read_word(BASE+WORDS,C);
    read_word(BASE+(2*WORDS)-1,D);
    reset_both();
    read_word(BASE,0);
    read_word(BASE+WORDS-1,0);
    select_bank(1);
    read_word(BASE+WORDS,0);
    read_word(BASE+(2*WORDS)-1,0);
    reset_both();
    // Incomplete/staged transaction may not migrate to the other bank.
    hw(6'h02,8'h01);
    hw(6'h30,8'h01);
    repeat(2)@(negedge clk);
    if(!fault || dut.bank_sel_q!==0)$fatal(1,"P207 staged command switched bank");
    reset_both();
    hw(6'h30,8'h02);
    repeat(2)@(negedge clk);
    if(!fault || dut.bank_sel_q!==0)$fatal(1,"P207 invalid selector accepted");
    reset_both();
    prepare(1,BASE,A);
    hw(6'h00,8'h01);
    hw(6'h30,8'h01);
    repeat(2)@(negedge clk);
    if(!fault || dut.bank_sel_q!==0)$fatal(1,"P207 active write switched bank");
    $display("P207_DUAL_BRAM_PASS words=%0d pins=29 banks=2 scrub=1 isolated=1 edge=1 switch_stage_reject=1 invalid_selector=1 active_switch_reject=1",WORDS);
    $finish;
  end
  initial begin #5000000;$fatal(1,"P207 test bounded timeout");end
endmodule
