`timescale 1ns/1ps
// P206 end-to-end host-only acceptance: the data lives in RTL on-chip RAM.
// No P196 simulation model is connected. Reset must scrub *all* words.
module a0_p206_committed_bram_tb;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,host_valid=0,host_write=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  wire host_ready,fault,busy;
  wire [7:0] host_rdata;
  localparam logic [31:0] BASE=32'h01000000;
  localparam logic [47:0] PIX0=48'h112233445566,
    PIX7=48'hF0E1D2C3B4A5;
  a0_p206_committed_bram_top #(.WORDS(8),.RESPONSE_TIMEOUT(256)) dut(
    .clk(clk),.rst_n(rst_n),.host_valid(host_valid),
    .host_write(host_write),.host_addr(host_addr),
    .host_wdata(host_wdata),.host_ready(host_ready),
    .host_rdata(host_rdata),.fault(fault),.busy(busy)
  );
  task automatic host_wr(input logic [5:0] a,input logic [7:0] v);
    begin
      @(negedge clk);host_valid=1;host_write=1;
      host_addr=a;host_wdata=v;
      #1;if(!host_ready)$fatal(1,"P206 host interface not ready addr=%h",a);
      @(negedge clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic host_rd(input logic [5:0] a,output logic [7:0] v);
    begin
      @(negedge clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P206 host read not ready");
      v=host_rdata;
      @(negedge clk);host_valid=0;
    end
  endtask
  task automatic reset_and_wait;
    integer ticks;
    begin
      @(negedge clk);rst_n=0;host_valid=0;host_write=0;
      repeat(3)@(negedge clk);
      rst_n=1;
      ticks=0;
      while(busy && ticks<100)begin @(negedge clk);ticks=ticks+1;end
      if(fault || busy || ticks<8)
        $fatal(1,"P206 failed full-memory zeroization and controller flush ticks=%0d",ticks);
    end
  endtask
  task automatic prepare(input logic op_write,input logic [31:0] addr,
                         input logic [47:0] pixel,input logic full_data);
    integer i;
    begin
      host_wr(6'h02,{7'd0,op_write});
      for(i=0;i<4;i=i+1)host_wr(6'h04+6'(i),addr[i*8+:8]);
      if(op_write)
        for(i=0;i<(full_data?6:5);i=i+1)
          host_wr(6'h08+6'(i),pixel[i*8+:8]);
    end
  endtask
  task automatic wait_done(input logic expect_error);
    integer spins;
    logic [7:0] status,err;
    begin
      spins=0;status=0;
      while(!status[3] && spins<140)begin
        host_rd(6'h01,status);spins=spins+1;
        if(status[4])$fatal(1,"P206 unexpected sticky fault during legal command");
      end
      if(!status[3] || fault || spins<3)
        $fatal(1,"P206 prematurely accepted or never committed operation spins=%0d",spins);
      host_rd(6'h16,err);
      if(err[0]!==expect_error)
        $fatal(1,"P206 unexpected result err=%h",err);
    end
  endtask
  task automatic ack_result;
    begin host_wr(6'h00,8'h02);end
  endtask
  task automatic write_word(input logic [31:0] addr,input logic [47:0] pixel);
    begin
      prepare(1,addr,pixel,1);
      host_wr(6'h00,8'h01);
      wait_done(0);
      ack_result();
    end
  endtask
  task automatic read_word(input logic [31:0] addr,input logic [47:0] expected);
    integer i;
    logic [7:0] b;
    logic [47:0] got;
    begin
      prepare(0,addr,0,0);
      host_wr(6'h00,8'h01);
      wait_done(0);
      for(i=0;i<6;i=i+1)begin
        host_rd(6'h10+6'(i),b);got[i*8+:8]=b;
      end
      if(got!==expected)
        $fatal(1,"P206 BRAM readback addr=%h got=%h expected=%h",addr,got,expected);
      ack_result();
    end
  endtask
  initial begin
    reset_and_wait();
    read_word(BASE+0,48'd0);
    read_word(BASE+7,48'd0);
    write_word(BASE+0,PIX0);
    write_word(BASE+7,PIX7);
    if(dut.ram[0]!==PIX0 || dut.ram[7]!==PIX7)
      $fatal(1,"P206 host DONE occurred before physical RTL RAM commit");
    read_word(BASE+0,PIX0);
    read_word(BASE+7,PIX7);
    reset_and_wait();
    read_word(BASE+0,48'd0);
    read_word(BASE+7,48'd0);
    // Partial 48-bit write must fail closed and never commit.
    prepare(1,BASE+0,PIX0,0);
    host_wr(6'h00,8'h01);
    repeat(3)@(negedge clk);
    if(!fault || dut.ram[0]!==0)
      $fatal(1,"P206 partial command was accepted");
    reset_and_wait();
    // An out-of-bank physical word address must not alias EBR contents.
    prepare(0,BASE+8,0,0);
    host_wr(6'h00,8'h01);
    repeat(6)@(negedge clk);
    if(!fault)$fatal(1,"P206 wrong-bank request not quarantined");
    $display("P206_ONCHIP_BRAM_PASS pins=29 words=8 scrub=1 reset_zero=1 write_commit=1 byte_readback=1 two_addresses=1 partial_reject=1 wrong_bank=1");
    $finish;
  end
  initial begin #1000000;$fatal(1,"P206 bounded timeout");end
endmodule
