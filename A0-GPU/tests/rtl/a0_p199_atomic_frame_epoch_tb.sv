`timescale 1ns/1ps
module a0_p199_atomic_frame_epoch_tb;
  localparam logic [31:0] BASE=32'h01000000;
  localparam integer N=65536;
  logic clk=0;
  always #5 clk=~clk;
  logic rst_n=0,stage_begin=0,stage_seal=0;
  logic in_valid=0;
  logic [15:0] in_x=0,in_y=0;
  logic [47:0] in_pixel=0;
  wire in_ready,reject_valid;
  wire fifo_valid,fifo_ready;
  wire [31:0] fifo_addr;
  wire [47:0] fifo_pixel;
  wire [1:0] fifo_words;
  logic read_valid=0;
  logic [31:0] read_addr=0;
  wire read_ready,read_rsp_valid,read_rsp_error,read_pending,protocol_fault;
  wire [47:0] read_rsp_pixel;
  wire mem_cmd_valid,mem_cmd_ready,mem_cmd_write;
  wire [31:0] mem_cmd_addr;
  wire [47:0] mem_cmd_pixel;
  wire mem_rsp_valid,mem_rsp_error;
  wire [47:0] mem_rsp_pixel;
  wire write_fault,stage_bank,active_bank,active_valid,stage_active;
  wire write_permitted,read_permitted,read_leased,seal_pending,publish_pulse,epoch_fault;
  wire [31:0] committed_words,published_epochs;
  logic inject_bad_commit=0;
  logic tiny_rst_n=0,tiny_begin=0,tiny_seal=0,tiny_write=0;
  logic [31:0] tiny_write_addr=BASE;
  wire tiny_valid,tiny_fault,tiny_pending;
  wire [31:0] tiny_count,tiny_epochs;
  wire write_commit=mem_cmd_valid && mem_cmd_ready && mem_cmd_write;
  wire read_accept=mem_cmd_valid && mem_cmd_ready && !mem_cmd_write;

  a0_p195_external_pixel_write_queue #(
    .FRAME_WIDTH(256),.FRAME_HEIGHT(256),.BASE_WORD_ADDR(BASE)
  ) fifo(
    .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),
    .in_x(in_x),.in_y(in_y),.in_pixel(in_pixel),.reject_valid(reject_valid),
    .out_valid(fifo_valid),.out_ready(fifo_ready),
    .out_word_addr(fifo_addr),.out_pixel(fifo_pixel),.queued_words(fifo_words)
  );
  a0_p197_external_word_port_arbiter #(
    .FRAME_WORDS(N),.BASE_WORD_ADDR(BASE)
  ) port(
    .clk(clk),.rst_n(rst_n),
    .write_valid(fifo_valid),.write_ready(fifo_ready),
    .write_word_addr(fifo_addr),.write_pixel(fifo_pixel),
    .write_fault(write_fault),
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
  a0_p199_atomic_frame_bank_epoch #(
    .FRAME_WORDS(N),.BASE_WORD_ADDR(BASE)
  ) epoch(
    .clk(clk),.rst_n(rst_n),.stage_begin(stage_begin),.stage_seal(stage_seal),
    .write_commit(write_commit || inject_bad_commit),
    .write_word_addr(inject_bad_commit ? BASE+32'd5 : mem_cmd_addr),
    .read_accept(read_accept),.read_complete(mem_rsp_valid),
    .stage_bank(stage_bank),.active_bank(active_bank),
    .active_valid(active_valid),.stage_active(stage_active),
    .write_permitted(write_permitted),.read_permitted(read_permitted),
    .read_leased(read_leased),.seal_pending(seal_pending),
    .publish_pulse(publish_pulse),.fault(epoch_fault),
    .committed_words(committed_words),.published_epochs(published_epochs)
  );

  // Adversarial two-word publication test: an illegal stage_begin arriving
  // in the same cycle as a pending publication must fail closed, not flip.
  a0_p199_atomic_frame_bank_epoch #(
    .FRAME_WORDS(2),.BASE_WORD_ADDR(BASE)
  ) adversarial(
    .clk(clk),.rst_n(tiny_rst_n),.stage_begin(tiny_begin),
    .stage_seal(tiny_seal),.write_commit(tiny_write),
    .write_word_addr(tiny_write_addr),
    .read_accept(1'b0),.read_complete(1'b0),
    .stage_bank(),.active_bank(),.active_valid(tiny_valid),
    .stage_active(),.write_permitted(),.read_permitted(),
    .read_leased(),.seal_pending(tiny_pending),.publish_pulse(),
    .fault(tiny_fault),.committed_words(tiny_count),
    .published_epochs(tiny_epochs)
  );

  // P196 models remain two independent SIMULATION-ONLY physical banks.
  // P199 itself synthesizes *only* the publication/epoch state machine.
  integer cycles=0;
  wire allow_write=(cycles%127)>=48;
  wire allow_read=(cycles%7)!=0;
  always @(posedge clk)begin
    if(!rst_n)cycles<=0;else cycles<=cycles+1;
  end
  wire command_bank=mem_cmd_write ? stage_bank : active_bank;
  wire [31:0] bank_addr=mem_cmd_addr+
    (command_bank ? 32'd65536 : 32'd0);
  wire w0r,w1r,r0r,r1r,fault0,fault1,rsp0,rsp1,err0,err1;
  wire [47:0] data0,data1;
  wire b0_wr=mem_cmd_valid && mem_cmd_write && write_permitted && !command_bank;
  wire b1_wr=mem_cmd_valid && mem_cmd_write && write_permitted && command_bank;
  wire b0_rd=mem_cmd_valid && !mem_cmd_write && read_permitted && !command_bank;
  wire b1_rd=mem_cmd_valid && !mem_cmd_write && read_permitted && command_bank;
  a0_p196_external_word_memory_model #(
    .WORDS(N),.BASE_WORD_ADDR(BASE)
  ) bank0(
    .clk(clk),.rst_n(rst_n),
    .allow_write(allow_write),.allow_read(allow_read),
    .write_valid(b0_wr),.write_ready(w0r),.write_word_addr(bank_addr),
    .write_pixel(mem_cmd_pixel),.write_fault(fault0),
    .read_valid(b0_rd),.read_ready(r0r),.read_word_addr(bank_addr),
    .read_rsp_valid(rsp0),.read_rsp_error(err0),.read_rsp_pixel(data0)
  );
  a0_p196_external_word_memory_model #(
    .WORDS(N),.BASE_WORD_ADDR(BASE+32'd65536)
  ) bank1(
    .clk(clk),.rst_n(rst_n),
    .allow_write(allow_write),.allow_read(allow_read),
    .write_valid(b1_wr),.write_ready(w1r),.write_word_addr(bank_addr),
    .write_pixel(mem_cmd_pixel),.write_fault(fault1),
    .read_valid(b1_rd),.read_ready(r1r),.read_word_addr(bank_addr),
    .read_rsp_valid(rsp1),.read_rsp_error(err1),.read_rsp_pixel(data1)
  );
  assign mem_cmd_ready=mem_cmd_write ?
    (write_permitted && (command_bank ? w1r : w0r)) :
    (read_permitted && (command_bank ? r1r : r0r));
  assign mem_rsp_valid=rsp0 || rsp1;
  assign mem_rsp_error=err0 || err1;
  assign mem_rsp_pixel=data0 | data1;

  function automatic [47:0] pattern(input integer gen,input integer idx);
    begin
      pattern=(gen==0 ? 48'h110000000000 : 48'h220000000000) ^
        (48'(idx)*48'h000000010101);
    end
  endfunction

  integer total_writes=0,read_commands=0;
  integer busy_reads=0,backpressure=0,seal_with_lease=0,publications=0;
  always @(posedge clk)begin
    if(rst_n)begin
      if(reject_valid || write_fault || fault0 || fault1 || protocol_fault)
        $fatal(1,"P199 upstream or backing bank fault");
      if(epoch_fault && !inject_bad_commit && published_epochs<2)
        $fatal(1,"P199 premature epoch fault");
      if(fifo_valid && !fifo_ready)backpressure=backpressure+1;
      if(read_valid && !read_ready)busy_reads=busy_reads+1;
      if(stage_seal && read_leased)seal_with_lease=seal_with_lease+1;
      if(publish_pulse)publications=publications+1;
      if(write_commit)begin
        if(total_writes>=2*N ||
           mem_cmd_addr!==BASE+32'(total_writes%N) ||
           mem_cmd_pixel!==pattern(total_writes/N,total_writes%N) ||
           command_bank!==(total_writes<N))
          $fatal(1,"P199 wrong write data/address/bank index=%0d bank=%b addr=%h data=%h",
            total_writes,command_bank,mem_cmd_addr,mem_cmd_pixel);
        total_writes=total_writes+1;
      end
      if(read_accept)read_commands=read_commands+1;
      if(write_commit && read_accept)
        $fatal(1,"P199 simultaneous single-port commands");
    end
  end

  task automatic start_stage;
    begin
      @(negedge clk);stage_begin=1;
      @(negedge clk);stage_begin=0;
      if(!stage_active || committed_words!=0)
        $fatal(1,"P199 stage begin failed");
    end
  endtask
  task automatic send(input integer gen,input integer idx);
    integer tries;
    logic accepted;
    begin
      @(negedge clk);
      in_valid=1;in_x=16'(idx%256);in_y=16'(idx/256);
      in_pixel=pattern(gen,idx);
      tries=0;accepted=0;
      while(!accepted && tries<10000)begin
        @(posedge clk);
        if(in_ready)accepted=1;
        tries=tries+1;
      end
      if(!accepted)$fatal(1,"P199 producer stalled forever idx=%0d",idx);
      @(negedge clk);in_valid=0;
    end
  endtask
  task automatic await_commits(input integer count);
    integer tries;
    begin
      tries=0;
      while(total_writes<count && tries<2000000)begin
        @(negedge clk);
        tries=tries+1;
      end
      if(total_writes!=count || fifo_words!=0)
        $fatal(1,"P199 incomplete staged frame writes=%0d target=%0d",total_writes,count);
    end
  endtask
  task automatic read_check(input integer idx,input integer gen);
    integer tries;
    logic accepted,responded;
    begin
      @(negedge clk);
      read_valid=1;read_addr=BASE+32'(idx);
      tries=0;accepted=0;
      while(!accepted && tries<30000)begin
        @(posedge clk);
        if(read_ready)accepted=1;
        tries=tries+1;
      end
      if(!accepted)$fatal(1,"P199 read handshake timed out");
      @(negedge clk);read_valid=0;
      tries=0;responded=0;
      while(!responded && tries<30000)begin
        @(posedge clk);
        if(read_rsp_valid)begin
          responded=1;
          if(read_rsp_error || read_rsp_pixel!==pattern(gen,idx))
            $fatal(1,"P199 torn read idx=%0d gen=%0d got=%h expected=%h",
              idx,gen,read_rsp_pixel,pattern(gen,idx));
        end
        tries=tries+1;
      end
      if(!responded)$fatal(1,"P199 read response timed out");
    end
  endtask
  task automatic wait_published(input integer count);
    integer tries;
    begin
      tries=0;
      while(published_epochs<count && tries<10000)begin
        @(negedge clk);tries=tries+1;
      end
      if(published_epochs!=count || !active_valid || stage_active)
        $fatal(1,"P199 failed publication epoch=%0d",published_epochs);
    end
  endtask

  initial begin : stimulus
    integer k;
    logic last_read_accepted,last_read_answered;
    repeat(4)@(negedge clk);rst_n=1;
    if(active_valid || read_permitted)
      $fatal(1,"P199 uninitialized frame visible");
    start_stage();
    for(k=0;k<N;k=k+1)send(0,k);
    await_commits(N);
    if(committed_words!=N || active_valid)
      $fatal(1,"P199 old bank visible before first seal");
    @(negedge clk);stage_seal=1;
    @(negedge clk);stage_seal=0;
    wait_published(1);
    if(active_bank!==1 || published_epochs!=1)
      $fatal(1,"P199 first bank selected incorrectly");
    read_check(0,0);read_check(257,0);read_check(65535,0);

    start_stage();
    fork
      begin : writer
        integer i;
        for(i=0;i<N;i=i+1)send(1,i);
      end
      begin : old_bank_reader
        integer i;
        for(i=0;i<200;i=i+1)
          read_check((i%2)==0 ? 0 : 65535,0);
      end
    join
    await_commits(2*N);
    if(active_bank!==1 || published_epochs!=1 || !active_valid ||
       committed_words!=N)
      $fatal(1,"P199 published partial second frame");

    // Seal while the old bank still owns one in-flight read. The bank
    // must not change until the old response has been returned.
    @(negedge clk);read_addr=BASE+32'd257;read_valid=1;
    last_read_accepted=0;
    while(!last_read_accepted)begin
      @(posedge clk);
      if(read_ready)last_read_accepted=1;
    end
    @(negedge clk);read_valid=0;stage_seal=1;
    @(posedge clk);
    if(!read_leased || published_epochs!=1)
      $fatal(1,"P199 lost active reader during seal");
    @(negedge clk);stage_seal=0;
    last_read_answered=0;
    while(!last_read_answered)begin
      @(posedge clk);
      if(read_rsp_valid)begin
        if(read_rsp_error || read_rsp_pixel!==pattern(0,257))
          $fatal(1,"P199 old-bank in-flight read torn by publication");
        last_read_answered=1;
      end
    end
    wait_published(2);
    if(active_bank!==0 || stage_active || fifo_words!=0 ||
       committed_words!=N || publications<1 || seal_with_lease<1 ||
       backpressure<1 || busy_reads<1 || read_commands<204)
      $fatal(1,"P199 missing real concurrency/publication stress pub=%0d lease=%0d stalls=%0d rd=%0d",
        publications,seal_with_lease,backpressure,read_commands);
    read_check(0,1);read_check(257,1);read_check(65535,1);

    // An incorrect staged address is a genuine sticky fail-closed state.
    start_stage();
    @(negedge clk);inject_bad_commit=1;
    @(negedge clk);inject_bad_commit=0;
    if(!epoch_fault || write_permitted || read_permitted)
      $fatal(1,"P199 accepted out-of-order stage write");
    rst_n=0;repeat(3)@(negedge clk);rst_n=1;
    repeat(2)@(negedge clk);
    if(epoch_fault || active_valid || published_epochs!=0 ||
       read_permitted)
      $fatal(1,"P199 reset left stale published epoch visible");

    tiny_rst_n=1;
    @(negedge clk);tiny_begin=1;
    @(negedge clk);tiny_begin=0;
    @(negedge clk);tiny_write=1;tiny_write_addr=BASE;
    @(negedge clk);tiny_write_addr=BASE+32'd1;
    @(negedge clk);tiny_write=0;
    if(tiny_count!=2)$fatal(1,"P199 adversarial stage incomplete");
    @(negedge clk);tiny_seal=1;
    @(negedge clk);tiny_seal=0;tiny_begin=1;
    @(negedge clk);tiny_begin=0;
    if(!tiny_fault || tiny_epochs!=0 || tiny_valid)
      $fatal(1,"P199 illegally published a sealed epoch during conflicting input");
    $display("P199_DOUBLE_BANK_PUBLICATION_PASS frame=256x256 epochs=2 committed=131072 old_reads=200 no_torn_reads=1 reader_seal_guard=1 backpressure=1 invalid_commit_fault=1 reset_fail_closed=1 seal_conflict_fault=1");
    $finish;
  end
  initial begin #30000000; $fatal(1,"P199 global simulation timeout"); end
endmodule
