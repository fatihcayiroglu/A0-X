`timescale 1ns/1ps
// P205 mailbox acceptance using the real P203 inside DUT and actual P196
// SIMULATION-ONLY memory commits. No physical board or DDR is emulated.
module a0_p205_narrow_mailbox_tb;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,host_valid=0,host_write=0;
  logic [5:0] host_addr=0;
  logic [7:0] host_wdata=0;
  wire host_ready;
  wire [7:0] host_rdata;
  logic ctrl_valid=0,ctrl_write=0;
  logic [5:0] ctrl_addr=0;
  logic [7:0] ctrl_wdata=0;
  wire ctrl_ready;
  wire [7:0] ctrl_rdata;
  wire fault,busy;
  a0_p205_narrow_p203_mailbox #(
    .FRAME_WORDS(4),.BANK_INDEX(0),.RESPONSE_TIMEOUT(256)
  ) dut(
    .clk(clk),.rst_n(rst_n),
    .host_valid(host_valid),.host_write(host_write),
    .host_addr(host_addr),.host_wdata(host_wdata),
    .host_ready(host_ready),.host_rdata(host_rdata),
    .ctrl_valid(ctrl_valid),.ctrl_write(ctrl_write),
    .ctrl_addr(ctrl_addr),.ctrl_wdata(ctrl_wdata),
    .ctrl_ready(ctrl_ready),.ctrl_rdata(ctrl_rdata),
    .fault(fault),.busy(busy)
  );
  logic mem_write_valid=0,mem_read_valid=0;
  logic [31:0] mem_addr=0;
  logic [47:0] mem_data=0;
  wire mem_write_ready,mem_read_ready,mem_write_fault;
  wire mem_rsp_valid,mem_rsp_error;
  wire [47:0] mem_rsp_pixel;
  a0_p196_external_word_memory_model #(
    .WORDS(4),.BASE_WORD_ADDR(32'h01000000)
  ) memory(
    .clk(clk),.rst_n(rst_n),.allow_write(1'b1),.allow_read(1'b1),
    .write_valid(mem_write_valid),.write_ready(mem_write_ready),
    .write_word_addr(mem_addr),.write_pixel(mem_data),
    .write_fault(mem_write_fault),
    .read_valid(mem_read_valid),.read_ready(mem_read_ready),
    .read_word_addr(mem_addr),
    .read_rsp_valid(mem_rsp_valid),.read_rsp_error(mem_rsp_error),
    .read_rsp_pixel(mem_rsp_pixel)
  );
  task automatic reset_all;
    begin
      @(negedge clk);rst_n=0;
      host_valid=0;host_write=0;ctrl_valid=0;ctrl_write=0;
      mem_write_valid=0;mem_read_valid=0;
      repeat(3)@(negedge clk);rst_n=1;
      @(negedge clk);
      if(fault || !busy)
        $fatal(1,"P205 reset did not require controller flush");
    end
  endtask
  task automatic hw(input logic [5:0] a,input logic [7:0] d);
    begin
      @(negedge clk);host_valid=1;host_write=1;host_addr=a;host_wdata=d;
      #1;if(!host_ready)$fatal(1,"P205 host write not ready addr=%h",a);
      @(negedge clk);host_valid=0;host_write=0;
    end
  endtask
  task automatic hr(input logic [5:0] a,output logic [7:0] d);
    begin
      @(negedge clk);host_valid=1;host_write=0;host_addr=a;
      #1;if(!host_ready)$fatal(1,"P205 host read not ready addr=%h",a);
      d=host_rdata;
      @(negedge clk);host_valid=0;
    end
  endtask
  task automatic cw(input logic [5:0] a,input logic [7:0] d);
    begin
      @(negedge clk);ctrl_valid=1;ctrl_write=1;ctrl_addr=a;ctrl_wdata=d;
      #1;if(!ctrl_ready)$fatal(1,"P205 ctrl write not ready addr=%h",a);
      @(negedge clk);ctrl_valid=0;ctrl_write=0;
    end
  endtask
  task automatic cr(input logic [5:0] a,output logic [7:0] d);
    begin
      @(negedge clk);ctrl_valid=1;ctrl_write=0;ctrl_addr=a;
      #1;if(!ctrl_ready)$fatal(1,"P205 ctrl read not ready addr=%h",a);
      d=ctrl_rdata;
      @(negedge clk);ctrl_valid=0;
    end
  endtask
  task automatic flush_controller;
    logic [7:0] st;
    begin
      cr(6'h01,st);
      if(!st[0] || fault)$fatal(1,"P205 reset flush request not exposed");
      cw(6'h00,8'h01);
      repeat(3)@(negedge clk);
      cr(6'h01,st);
      if(st[0] || fault)$fatal(1,"P205 flush ack not consumed");
    end
  endtask
  task automatic host_prepare(input logic op_write,
      input logic [31:0] addr,input logic [47:0] pixel);
    integer i;
    begin
      hw(6'h02,{7'd0,op_write});
      for(i=0;i<4;i=i+1)hw(6'h04+6'(i),addr[i*8+:8]);
      if(op_write)
        for(i=0;i<6;i=i+1)hw(6'h08+6'(i),pixel[i*8+:8]);
    end
  endtask
  task automatic get_controller_request(
    output logic op_write,output logic [31:0] addr,
    output logic [47:0] pixel,output logic [31:0] id
  );
    integer spins,i;
    logic [7:0] st,b;
    begin
      spins=0;st=0;
      while(!st[1] && spins<50)begin
        cr(6'h01,st);spins=spins+1;
      end
      if(!st[1] || st[3] || fault)
        $fatal(1,"P205 no controller request / fault");
      cr(6'h02,b);op_write=b[0];
      addr=0;pixel=0;id=0;
      for(i=0;i<4;i=i+1)begin
        cr(6'h04+6'(i),b);addr[i*8+:8]=b;
      end
      for(i=0;i<6;i=i+1)begin
        cr(6'h08+6'(i),b);pixel[i*8+:8]=b;
      end
      for(i=0;i<4;i=i+1)begin
        cr(6'h10+6'(i),b);id[i*8+:8]=b;
      end
    end
  endtask
  task automatic controller_reply(input logic [31:0] id,
      input logic error,input logic [47:0] pixel,input bit is_read);
    integer i;
    begin
      cw(6'h14,{7'd0,error});
      for(i=0;i<4;i=i+1)
        cw(6'h18+6'(i),id[i*8+:8]);
      if(is_read)for(i=0;i<6;i=i+1)
        cw(6'h20+6'(i),pixel[i*8+:8]);
      cw(6'h00,8'h02);
    end
  endtask
  task automatic memory_commit(input logic [31:0] addr,
      input logic [47:0] data);
    begin
      @(negedge clk);mem_addr=addr;mem_data=data;mem_write_valid=1;
      @(posedge clk);
      if(!mem_write_ready)$fatal(1,"P205 simulated memory refused write");
      @(negedge clk);mem_write_valid=0;
      if(mem_write_fault)$fatal(1,"P205 physical model write fault");
    end
  endtask
  task automatic memory_read(input logic [31:0] addr,
      output logic [47:0] data);
    begin
      @(negedge clk);mem_addr=addr;mem_read_valid=1;
      @(posedge clk);
      if(!mem_read_ready)$fatal(1,"P205 simulated memory refused read");
      @(negedge clk);mem_read_valid=0;
      if(!mem_rsp_valid || mem_rsp_error)
        $fatal(1,"P205 simulated memory read error");
      data=mem_rsp_pixel;
    end
  endtask
  task automatic await_host_done(input logic expected_error);
    integer spins;
    logic [7:0] st,b;
    begin
      spins=0;st=0;
      while(!st[3] && spins<80)begin hr(6'h01,st);spins=spins+1;end
      if(!st[3] || st[4] || fault)
        $fatal(1,"P205 host did not retire committed operation status=%h",st);
      hr(6'h16,b);
      if(b[0]!==expected_error)
        $fatal(1,"P205 host result error mismatch got=%h",b);
    end
  endtask

  logic op;
  logic [31:0] addr,id;
  logic [47:0] pixel,readback,expected;
  logic [7:0] st,b;
  integer i;
  initial begin
    reset_all();
    flush_controller();
    // WRITE: controller request acceptance cannot make host DONE.
    host_prepare(1,32'h01000002,48'h112233445566);
    hw(6'h00,8'h01);
    get_controller_request(op,addr,pixel,id);
    if(!op || addr!==32'h01000002 || pixel!==48'h112233445566)
      $fatal(1,"P205 byte-assembled controller write mismatch");
    hr(6'h01,st);
    if(st[3] || fault)$fatal(1,"P205 phantom write commit before memory");
    memory_commit(addr,pixel);
    controller_reply(id,0,48'd0,0);
    await_host_done(0);
    hw(6'h00,8'h02);

    // READ after actual simulation-bank write, 48-bit result via 8-bit bus.
    host_prepare(0,32'h01000002,48'd0);
    hw(6'h00,8'h01);
    get_controller_request(op,addr,pixel,id);
    if(op || addr!==32'h01000002)
      $fatal(1,"P205 byte-assembled controller read mismatch");
    memory_read(addr,readback);
    controller_reply(id,0,readback,1);
    await_host_done(0);
    expected=0;
    for(i=0;i<6;i=i+1)begin
      hr(6'h10+6'(i),b);expected[i*8+:8]=b;
    end
    if(expected!==48'h112233445566)
      $fatal(1,"P205 narrow host readback corrupted %h",expected);
    hw(6'h00,8'h02);

    // Partial commands are rejected without touching the controller.
    reset_all();flush_controller();
    hw(6'h00,8'h01);
    hr(6'h01,st);
    if(!st[4] || dut.ctrl_req_pending_q)
      $fatal(1,"P205 partial host command accepted");

    // Mismatched controller tag must never yield a successful result.
    reset_all();flush_controller();
    host_prepare(0,32'h01000002,0);
    hw(6'h00,8'h01);
    get_controller_request(op,addr,pixel,id);
    controller_reply(id+32'd1,0,48'h111111111111,1);
    repeat(4)@(negedge clk);
    hr(6'h01,st);
    if(!st[4] || !fault)
      $fatal(1,"P205 wrong controller tag not quarantined");

    // Physical bank 1 address must never be accepted by bank 0.
    reset_all();flush_controller();
    host_prepare(0,32'h01000004,0);
    hw(6'h00,8'h01);
    repeat(4)@(negedge clk);
    hr(6'h01,st);
    if(!st[4] || !fault || dut.ctrl_req_pending_q)
      $fatal(1,"P205 wrong physical bank accepted");

    // Duplicate command while an earlier request is pending => sticky fault.
    reset_all();flush_controller();
    host_prepare(1,32'h01000002,48'h123456789abc);
    hw(6'h00,8'h01);
    get_controller_request(op,addr,pixel,id);
    hw(6'h00,8'h01);
    hr(6'h01,st);
    if(!st[4] || !fault)$fatal(1,"P205 duplicate kick accepted");

    // Controller response cannot be posted without all tag/error bytes.
    reset_all();flush_controller();
    host_prepare(0,32'h01000002,0);
    hw(6'h00,8'h01);
    get_controller_request(op,addr,pixel,id);
    cw(6'h00,8'h02);
    hr(6'h01,st);
    if(!st[4] || !fault)$fatal(1,"P205 incomplete reply accepted");

    $display("P205_NARROW_MAILBOX_PASS io_bits=54 flush=1 byte_write=1 commit_ack=1 byte_read=1 readback=1 partial_reject=1 wrong_tag=1 wrong_bank=1 duplicate_kick=1 incomplete_reply=1");
    $finish;
  end
  initial begin #2500000; $fatal(1,"P205 mailbox test timed out");end
endmodule
