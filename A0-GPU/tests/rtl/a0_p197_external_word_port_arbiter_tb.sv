\`timescale 1ns/1ps
module a0_p197_external_word_port_arbiter_tb;
  localparam logic [31:0] BASE=32'h01000000;
  localparam logic [47:0] P0=48'h001122334455;
  localparam logic [47:0] P1=48'h112233445566;
  localparam logic [47:0] P2=48'h223344556677;
  localparam logic [47:0] P3=48'h334455667788;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0;
  logic in_valid=0;
  logic [15:0] in_x=0,in_y=0;
  logic [47:0] in_pixel=0;
  wire in_ready,producer_reject;
  wire fifo_valid,fifo_ready;
  wire [31:0] fifo_addr;
  wire [47:0] fifo_pixel;
  wire [1:0] fifo_words;

  logic direct_mode=0,direct_valid=0;
  logic [31:0] direct_addr=0;
  logic [47:0] direct_pixel=0;
  wire port_write_valid=direct_mode ? direct_valid : fifo_valid;
  wire [31:0] port_write_addr=direct_mode ? direct_addr : fifo_addr;
  wire [47:0] port_write_pixel=direct_mode ? direct_pixel : fifo_pixel;
  wire port_write_ready,port_write_fault;
  assign fifo_ready=!direct_mode && port_write_ready;

  logic read_valid=0;
  logic [31:0] read_addr=0;
  wire read_ready,read_rsp_valid,read_rsp_error,read_pending,protocol_fault;
  wire [47:0] read_rsp_pixel;
  wire mem_cmd_valid,mem_cmd_ready,mem_cmd_write;
  wire [31:0] mem_cmd_addr;
  wire [47:0] mem_cmd_pixel;
  wire mem_rsp_valid,mem_rsp_error;
  wire [47:0] mem_rsp_pixel;
  wire model_write_ready,model_read_ready,model_write_fault;
  wire model_rsp_valid,model_rsp_error;
  wire [47:0] model_rsp_pixel;
  logic spurious_rsp=0;
  logic hold_writes=0;
  integer cycles=0;
  wire allow_write=!hold_writes && ((cycles%7)!=0);
  wire allow_read=((cycles%5)!=0);
  always @(posedge clk)begin
    if(!rst_n) cycles<=0;
    else cycles<=cycles+1;
  end

  a0_p195_external_pixel_write_queue #(
    .FRAME_WIDTH(256),.FRAME_HEIGHT(256),.BASE_WORD_ADDR(BASE)
  ) fifo (
    .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),
    .in_x(in_x),.in_y(in_y),.in_pixel(in_pixel),.reject_valid(producer_reject),
    .out_valid(fifo_valid),.out_ready(fifo_ready),
    .out_word_addr(fifo_addr),.out_pixel(fifo_pixel),.queued_words(fifo_words)
  );

  a0_p197_external_word_port_arbiter #(
    .FRAME_WORDS(65536),.BASE_WORD_ADDR(BASE)
  ) dut (
    .clk(clk),.rst_n(rst_n),
    .write_valid(port_write_valid),.write_ready(port_write_ready),
    .write_word_addr(port_write_addr),.write_pixel(port_write_pixel),
    .write_fault(port_write_fault),
    .read_valid(read_valid),.read_ready(read_ready),.read_word_addr(read_addr),
    .read_rsp_valid(read_rsp_valid),.read_rsp_error(read_rsp_error),
    .read_rsp_pixel(read_rsp_pixel),
    .mem_cmd_valid(mem_cmd_valid),.mem_cmd_ready(mem_cmd_ready),
    .mem_cmd_write(mem_cmd_write),.mem_cmd_word_addr(mem_cmd_addr),
    .mem_cmd_pixel(mem_cmd_pixel),
    .mem_rsp_valid(mem_rsp_valid),.mem_rsp_error(mem_rsp_error),
    .mem_rsp_pixel(mem_rsp_pixel),
    .read_pending(read_pending),.protocol_fault(protocol_fault)
  );

  a0_p196_external_word_memory_model #(
    .WORDS(65536),.BASE_WORD_ADDR(BASE)
  ) backing (
    .clk(clk),.rst_n(rst_n),.allow_write(allow_write),
    .allow_read(allow_read),
    .write_valid(mem_cmd_valid && mem_cmd_write),
    .write_ready(model_write_ready),.write_word_addr(mem_cmd_addr),
    .write_pixel(mem_cmd_pixel),.write_fault(model_write_fault),
    .read_valid(mem_cmd_valid && !mem_cmd_write),
    .read_ready(model_read_ready),.read_word_addr(mem_cmd_addr),
    .read_rsp_valid(model_rsp_valid),.read_rsp_error(model_rsp_error),
    .read_rsp_pixel(model_rsp_pixel)
  );
  assign mem_cmd_ready=mem_cmd_write ? model_write_ready : model_read_ready;
  assign mem_rsp_valid=model_rsp_valid || spurious_rsp;
  assign mem_rsp_error=model_rsp_error || spurious_rsp;
  assign mem_rsp_pixel=model_rsp_pixel;

  logic [31:0] expected_addr [0:2047];
  logic [47:0] expected_pixel [0:2047];
  integer produced=0,committed=0,bus_reads=0;
  integer contended_writes=0,contended_reads=0;
  integer write_stalls=0,read_stalls=0,held_stalls=0,bad_writes=0;
  logic was_stalled=0,was_write=0;
  logic [31:0] was_addr=0;
  logic [47:0] was_pixel=0;
  always @(posedge clk) begin
    if(!rst_n) begin
      // The uncommitted producer FIFO tail is canceled by protocol reset.
      produced=committed;
      was_stalled=0;
    end else begin
      if(producer_reject || model_write_fault)
        $fatal(1,"P197 unexpected upstream/model fault");
      if(fifo_valid && !fifo_ready)write_stalls=write_stalls+1;
      if(read_valid && !read_ready)read_stalls=read_stalls+1;
      if(port_write_fault)bad_writes=bad_writes+1;
      if(was_stalled)begin
        if(!mem_cmd_valid || mem_cmd_write!==was_write ||
           mem_cmd_addr!==was_addr || mem_cmd_pixel!==was_pixel)
          $fatal(1,"P197 external command changed while backpressured");
      end
      was_stalled=mem_cmd_valid && !mem_cmd_ready;
      if(was_stalled)begin
        held_stalls=held_stalls+1;
        was_write=mem_cmd_write;
        was_addr=mem_cmd_addr;
        was_pixel=mem_cmd_pixel;
      end
      if(in_valid && in_ready &&
         in_x<256 && in_y<256)begin
        if(produced>=2048)$fatal(1,"P197 scoreboard capacity exceeded");
        expected_addr[produced]=BASE+32'(in_y)*32'd256+32'(in_x);
        expected_pixel[produced]=in_pixel;
        produced=produced+1;
      end
      if(mem_cmd_valid && mem_cmd_ready)begin
        if(mem_cmd_write)begin
          if(committed>=produced ||
             mem_cmd_addr!==expected_addr[committed] ||
             mem_cmd_pixel!==expected_pixel[committed])
            $fatal(1,"P197 reordered/duplicated write at %0d got=%h",committed,mem_cmd_addr);
          committed=committed+1;
        end else bus_reads=bus_reads+1;
        if(port_write_valid && read_valid)begin
          if(mem_cmd_write)contended_writes=contended_writes+1;
          else contended_reads=contended_reads+1;
        end
      end
      if(mem_cmd_valid && mem_cmd_write && read_pending)
        $fatal(1,"P197 issued a command with outstanding read");
      if(mem_cmd_valid && !mem_cmd_write && read_pending)
        $fatal(1,"P197 issued overlapping read");
    end
  end

  task automatic push_pixel(
    input logic [15:0] x,y,input logic [47:0] pixel
  );
    integer t;
    logic accepted;
    begin
      @(negedge clk);
      in_valid=1;in_x=x;in_y=y;in_pixel=pixel;
      accepted=0;t=0;
      while(!accepted && t<30000)begin
        @(posedge clk);
        if(in_ready)accepted=1;
        t=t+1;
      end
      if(!accepted)$fatal(1,"P197 producer acceptance timed out");
      @(negedge clk);in_valid=0;
    end
  endtask

  task automatic read_check(
    input logic [31:0] address,
    input logic [47:0] pixel,
    input logic error_expected
  );
    integer t;
    logic accepted,responded;
    begin
      @(negedge clk);
      read_addr=address;read_valid=1;
      accepted=0;t=0;
      while(!accepted && t<30000)begin
        @(posedge clk);
        if(read_ready)accepted=1;
        t=t+1;
      end
      if(!accepted)$fatal(1,"P197 host read handshake timed out: %h",address);
      @(negedge clk);read_valid=0;
      responded=0;t=0;
      while(!responded && t<30000)begin
        @(posedge clk);
        if(read_rsp_valid)begin
          responded=1;
          if(read_rsp_error!==error_expected ||
             read_rsp_pixel!==(error_expected ? 48'd0 : pixel))
            $fatal(1,"P197 bad read response %h err=%b data=%h",address,read_rsp_error,read_rsp_pixel);
        end
        t=t+1;
      end
      if(!responded)$fatal(1,"P197 host read response timed out: %h",address);
    end
  endtask

  task automatic wait_committed(input integer target);
    integer t;
    begin
      t=0;
      while(committed<target && t<30000)begin
        @(negedge clk);t=t+1;
      end
      if(committed!=target)
        $fatal(1,"P197 write count timeout: committed=%0d expected=%0d",committed,target);
    end
  endtask

  initial begin : test
    integer i;
    $display("P197 start synthesis-compatible arbiter with actual P195 FIFO and P196 backing memory");
    repeat(4)@(negedge clk);
    rst_n=1;
    push_pixel(0,0,P0);
    push_pixel(255,0,P1);
    push_pixel(0,255,P2);
    push_pixel(255,255,P3);
    wait_committed(4);
    read_check(BASE,P0,0);
    read_check(BASE+255,P1,0);
    read_check(BASE+65280,P2,0);
    read_check(BASE+65535,P3,0);
    read_check(BASE+500,48'd0,1); // unwritten valid bus address
    read_check(BASE+65536,48'd0,1); // invalid local address; zero bus traffic
    fork
      begin : feed
        integer k;
        for(k=0;k<1024;k=k+1)
          push_pixel(16'(k%128),16'(5+(k/128)),
                     48'h000102030405+48'(k));
      end
      begin : read_during_write
        integer k;
        for(k=0;k<200;k=k+1)begin
          case(k%4)
            0:read_check(BASE,P0,0);
            1:read_check(BASE+255,P1,0);
            2:read_check(BASE+65280,P2,0);
            3:read_check(BASE+65535,P3,0);
          endcase
        end
      end
    join
    wait_committed(1028);
    if(produced!=1028 || committed!=1028 || fifo_words!=0 ||
       contended_writes<1 || contended_reads<1 ||
       write_stalls<1 || read_stalls<1 || held_stalls<1 ||
       bus_reads<205)
      $fatal(1,"P197 missing genuine pressure/order/fairness: p=%0d c=%0d cw=%0d cr=%0d ws=%0d rs=%0d hs=%0d rd=%0d",
        produced,committed,contended_writes,contended_reads,
        write_stalls,read_stalls,held_stalls,bus_reads);

    // An invalid *direct port* write is consumed with a fault pulse and
    // must never become a command to the backing memory.
    @(negedge clk);direct_mode=1;direct_valid=1;
    direct_addr=BASE+65536;direct_pixel=48'hbadbadbadbad;
    @(posedge clk);
    if(!port_write_ready)$fatal(1,"P197 invalid write should be consumed");
    @(negedge clk);direct_valid=0;direct_mode=0;
    repeat(2)@(negedge clk);
    if(bad_writes!=1)$fatal(1,"P197 missed invalid write fault: %0d",bad_writes);

    // Two accepted producer words are held behind a completely stalled
    // external write port, then discarded by a common protocol reset.
    hold_writes=1;
    push_pixel(200,20,48'h111111111111);
    push_pixel(201,20,48'h222222222222);
    repeat(3)@(negedge clk);
    if(fifo_words!=2 || committed!=1028)
      $fatal(1,"P197 unable to hold exactly two uncommitted words");
    rst_n=0;
    repeat(3)@(negedge clk);
    hold_writes=0;rst_n=1;
    repeat(2)@(negedge clk);
    if(fifo_words!=0 || protocol_fault || read_pending || committed!=1028)
      $fatal(1,"P197 reset failed to discard queued writes");
    read_check(BASE+20*256+200,48'd0,1);
    read_check(BASE,P0,0); // accepted backing memory retained across reset

    // An unsolicited response is a sticky fail-closed protocol error.
    repeat(3)@(negedge clk);
    spurious_rsp=1;
    @(negedge clk);spurious_rsp=0;
    if(!protocol_fault)$fatal(1,"P197 accepted unsolicited memory response");
    read_valid=1;read_addr=BASE;
    #1;
    if(read_ready || mem_cmd_valid || port_write_ready)
      $fatal(1,"P197 fault state failed to close memory requests");
    read_valid=0;
    rst_n=0;repeat(3)@(negedge clk);rst_n=1;
    repeat(2)@(negedge clk);
    if(protocol_fault)$fatal(1,"P197 fault not cleared on common reset");
    read_check(BASE+65535,P3,0);
    if(committed!=1028 || bad_writes!=1 || contended_writes<1 ||
       contended_reads<1)
      $fatal(1,"P197 final invariant failed");
    $display("P197_SYNTH_WORD_ARBITER_PASS frame=256x256 committed=1028 concurrent_reads=200 fairness=1 stalled_hold=1 local_write_fault=1 read_fault=1 reset_retention=1 pending_discard=1 protocol_fail_closed=1");
    $finish;
  end
  initial begin
    #5000000;
    $fatal(1,"P197 global timeout");
  end
endmodule
