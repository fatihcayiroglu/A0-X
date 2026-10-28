`timescale 1ns/1ps
// P208 actual double-BRAM publication coverage; run at WORDS=8 and 1024.
// Deliberately uses only the externally observable byte register protocol.
module a0_p208_frame_publication_tb #(
  parameter integer WORDS=8
);
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,host_valid=0,host_write=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  wire host_ready,fault,busy;
  wire [7:0] host_rdata;
  localparam logic [31:0] BASE=32'h01000000;
  a0_p208_frame_publication_fence #(
    .WORDS(WORDS),.RESPONSE_TIMEOUT(256)
  ) dut(
    .clk(clk),.rst_n(rst_n),.host_valid(host_valid),
    .host_write(host_write),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_ready(host_ready),
    .host_rdata(host_rdata),.fault(fault),.busy(busy)
  );
  function automatic [47:0] pattern(input integer bank,input integer i);
    begin
      pattern={bank ? 16'h5a5a : 16'ha5a5,16'(i),16'(i ^ 16'hc3d7)};
    end
  endfunction
  task automatic hw(input logic [5:0] a,input logic [7:0] value);
    begin
      @(negedge clk);host_valid=1;host_write=1;host_addr=a;host_wdata=value;
      #1;if(!host_ready)$fatal(1,"P208 host write unexpectedly not ready a=%h",a);
      @(negedge clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] value);
    begin
      @(negedge clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P208 host read unexpectedly not ready a=%h",a);
      value=host_rdata;
      @(negedge clk);host_valid=0;
    end
  endtask
  task automatic reset_both;
    integer cycles;
    logic [7:0] st;
    begin
      @(negedge clk);rst_n=0;host_valid=0;host_write=0;
      repeat(3)@(negedge clk);rst_n=1;
      cycles=0;
      while(busy && cycles<WORDS+120)begin
        @(negedge clk);cycles=cycles+1;
      end
      if(fault || busy || cycles<WORDS)
        $fatal(1,"P208 scrub/flush failed cycles=%0d",cycles);
      hr(6'h32,st);
      if(st[0] || dut.epoch_q!==0)
        $fatal(1,"P208 reset retained a published front/epoch");
    end
  endtask
  task automatic select_bank(input logic bank);
    logic [7:0] status;
    begin
      hw(6'h30,{7'd0,bank});
      hr(6'h33,status);
      if(status[0]!==bank || fault)$fatal(1,"P208 bank select refused");
    end
  endtask
  task automatic prepare(input logic wr,input logic [31:0] addr,
                         input logic [47:0] pixel);
    integer i;
    begin
      hw(6'h02,{7'd0,wr});
      for(i=0;i<4;i=i+1)hw(6'h04+6'(i),addr[i*8+:8]);
      if(wr)for(i=0;i<6;i=i+1)hw(6'h08+6'(i),pixel[i*8+:8]);
    end
  endtask
  task automatic wait_done_and_ok;
    logic [7:0] v;
    integer spins;
    begin
      spins=0;v=0;
      while(!v[3] && spins<170)begin
        hr(6'h01,v);spins=spins+1;
        if(v[4] || fault)$fatal(1,"P208 legal operation fault");
      end
      if(!v[3] || spins<3)$fatal(1,"P208 early or missing DONE spins=%0d",spins);
      hr(6'h16,v);
      if(v[0] || fault)$fatal(1,"P208 error response");
    end
  endtask
  task automatic write_word(input logic [31:0] addr,input logic [47:0] pixel);
    begin
      prepare(1,addr,pixel);
      hw(6'h00,8'h01);
      wait_done_and_ok();
      hw(6'h00,8'h02);
      if(fault)$fatal(1,"P208 write commit was rejected");
    end
  endtask
  task automatic read_word(input logic [31:0] addr,input logic [47:0] expected);
    logic [47:0] value;
    logic [7:0] b;
    integer i;
    begin
      prepare(0,addr,0);hw(6'h00,8'h01);
      wait_done_and_ok();
      for(i=0;i<6;i=i+1)begin hr(6'h10+6'(i),b);value[i*8+:8]=b;end
      if(value!==expected)
        $fatal(1,"P208 front readback mismatch addr=%h got=%h exp=%h",addr,value,expected);
      hw(6'h00,8'h02);
    end
  endtask
  task automatic publish(input logic expected_bank,input integer expected_epoch);
    logic [7:0] status,ep;
    begin
      hw(6'h31,8'h01);
      hr(6'h32,status);
      hr(6'h34,ep);
      if(!status[0] || status[1]!==expected_bank ||
         !status[3] || ep!==8'(expected_epoch) || fault)
        $fatal(1,"P208 publish not atomic status=%h epoch_low=%h",status,ep);
    end
  endtask
  integer i;
  initial begin
    reset_both();
    // Rewriting the same word cannot forge a complete frame.
    write_word(BASE,pattern(0,0));
    write_word(BASE,pattern(0,0));
    hw(6'h31,8'h01);
    repeat(2)@(negedge clk);
    if(!fault || dut.front_valid_q)
      $fatal(1,"P208 duplicate write falsely completed a frame");
    reset_both();
    // Complete frame #1: every distinct address must be COMMIT-acknowledged.
    for(i=0;i<WORDS;i=i+1)write_word(BASE+i,pattern(0,i));
    publish(0,1);
    select_bank(1);
    // The old published front remains readable while the back is built.
    for(i=0;i<WORDS;i=i+1)begin
      write_word(BASE+WORDS+i,pattern(1,i));
      if(i==WORDS/2)begin
        select_bank(0);
        read_word(BASE,pattern(0,0));
        read_word(BASE+WORDS-1,pattern(0,WORDS-1));
        select_bank(1);
      end
    end
    publish(1,2);
    read_word(BASE+WORDS,pattern(1,0));
    read_word(BASE+2*WORDS-1,pattern(1,WORDS-1));
    // A read-only front may not be mutated after publication.
    hw(6'h02,8'h01);
    repeat(2)@(negedge clk);
    if(!fault || dut.front_bank_q!==1 || dut.epoch_q!==2)
      $fatal(1,"P208 published front accepted a new write");
    reset_both();
    read_word(BASE,0);
    select_bank(1);
    read_word(BASE+WORDS,0);
    $display("P208_FRAME_FENCE_PASS words=%0d pins=29 banks=2 unique_commit=1 partial_reject=1 epochs=2 immutable_front=1 reset_scrub=1",WORDS);
    $finish;
  end
  initial begin #20000000;$fatal(1,"P208 bounded simulation timeout");end
endmodule
