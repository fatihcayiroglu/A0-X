`timescale 1ns/1ps
// P223: compare exact same EBR FIFO transactions, old vs zero-bubble.
// Read throughput is a *clock-edge functional measurement*, not hardware
// throughput or board signoff. All payloads must agree exactly.
module a0_p223_zero_bubble_fifo_tb #(
  parameter integer REVERSE=0
);
  localparam integer WIDTH=92, AB=6, COUNT=32;
  localparam integer WH=(REVERSE==0)?4:7;
  localparam integer RH=(REVERSE==0)?7:4;
  logic wr_clk=0,rd_clk=0,rst_n=0;
  always #(WH) wr_clk=~wr_clk;
  initial begin
    #(REVERSE+1);
    forever #(RH) rd_clk=~rd_clk;
  end
  logic wr_valid=0,rd_ready=0;
  logic [WIDTH-1:0] wr_data=0;
  wire old_wr_ready,new_wr_ready,old_rd_valid,new_rd_valid;
  wire [WIDTH-1:0] old_rd_data,new_rd_data;
  a0_p216_split_reset_fifo #(.WIDTH(WIDTH),.ADDR_BITS(AB)) baseline(
    .wr_clk(wr_clk),.rd_clk(rd_clk),.wr_rst_n(rst_n),.rd_rst_n(rst_n),
    .wr_valid(wr_valid),.wr_ready(old_wr_ready),.wr_data(wr_data),
    .rd_valid(old_rd_valid),.rd_ready(rd_ready),.rd_data(old_rd_data)
  );
  a0_p223_split_reset_fifo #(.WIDTH(WIDTH),.ADDR_BITS(AB)) optimized(
    .wr_clk(wr_clk),.rd_clk(rd_clk),.wr_rst_n(rst_n),.rd_rst_n(rst_n),
    .wr_valid(wr_valid),.wr_ready(new_wr_ready),.wr_data(wr_data),
    .rd_valid(new_rd_valid),.rd_ready(rd_ready),.rd_data(new_rd_data)
  );
  function automatic [WIDTH-1:0] payload(input integer k);
    payload={32'hace00000 ^ 32'(k),32'h0a110000 + 32'(k),28'(k*17+3)};
  endfunction
  task automatic send(input integer k);
    integer guard;
    begin
      @(negedge wr_clk);
      wr_valid=1;wr_data=payload(k);guard=0;
      while(!(old_wr_ready && new_wr_ready) && guard<1000)begin
        @(negedge wr_clk);guard=guard+1;
      end
      if(!(old_wr_ready && new_wr_ready))
        $fatal(1,"P223 write handshake timeout index=%0d",k);
      @(negedge wr_clk);
      wr_valid=0;
    end
  endtask
  integer i,cycle,old_count,new_count,old_last,new_last;
  logic [WIDTH-1:0] held_old,held_new;
  initial begin
    if(REVERSE<0 || REVERSE>1)$fatal(1,"P223 unsupported clock ratio");
    repeat(7)@(negedge wr_clk);
    rst_n=1;
    repeat(12)@(negedge rd_clk);
    if(old_rd_valid || new_rd_valid || old_rd_data!==0 || new_rd_data!==0)
      $fatal(1,"P223 cold reset leaked prior FIFO payload");
    // Queue 32 words into 64 physical slots. Both FIFO outputs are held.
    for(i=0;i<COUNT;i=i+1)send(i);
    repeat(12)@(negedge rd_clk);
    if(!old_rd_valid || !new_rd_valid || old_rd_data!==payload(0) ||
       new_rd_data!==payload(0))
      $fatal(1,"P223 failed to prefetch the first real EBR word");
    held_old=old_rd_data;held_new=new_rd_data;
    repeat(12)begin
      @(negedge rd_clk);
      if(!old_rd_valid || !new_rd_valid ||
         old_rd_data!==held_old || new_rd_data!==held_new)
        $fatal(1,"P223 registered FIFO head changed under backpressure");
    end
    // Both sinks are permanently ready. A full queue must permit one
    // P223 pop at every consecutive pixel rising edge (zero bubbles).
    @(negedge rd_clk);rd_ready=1;
    old_count=0;new_count=0;old_last=-1;new_last=-1;
    for(cycle=0;cycle<96;cycle=cycle+1)begin
      @(posedge rd_clk);
      if(new_rd_valid)begin
        if(new_count>=COUNT || new_rd_data!==payload(new_count))
          $fatal(1,"P223 optimized FIFO reorder/duplication index=%0d",new_count);
        if(new_count<16 && cycle!=new_count)
          $fatal(1,"P223 optimized FIFO introduced a bubble at index=%0d cycle=%0d",new_count,cycle);
        new_last=cycle;new_count=new_count+1;
      end
      if(old_rd_valid)begin
        if(old_count>=COUNT || old_rd_data!==payload(old_count))
          $fatal(1,"P223 baseline FIFO reorder/duplication index=%0d",old_count);
        old_last=cycle;old_count=old_count+1;
      end
    end
    @(negedge rd_clk);rd_ready=0;
    if(new_count!=COUNT || old_count!=COUNT || new_last!=COUNT-1 ||
       old_last<2*(COUNT-1))
      $fatal(1,"P223 throughput assertion failed old=%0d/%0d new=%0d/%0d",
        old_count,old_last,new_count,new_last);
    repeat(8)@(negedge rd_clk);
    if(old_rd_valid || new_rd_valid || old_rd_data!==0 || new_rd_data!==0)
      $fatal(1,"P223 empty FIFO exposed phantom payload");
    // Put both outputs under backpressure, then assert a 2ns raw reset
    // entirely between pixel-clock edges. Stale prefetch must be revoked.
    send(100);send(101);
    repeat(14)@(negedge rd_clk);
    if(!old_rd_valid || !new_rd_valid ||
       old_rd_data!==payload(100) || new_rd_data!==payload(100))
      $fatal(1,"P223 live-reset challenge lacks valid prefetched data");
    #1 rst_n=0;
    #1;
    if(old_rd_valid || new_rd_valid || old_rd_data!==0 || new_rd_data!==0)
      $fatal(1,"P223 short asynchronous reset failed to revoke output");
    #1 rst_n=1;
    repeat(16)begin
      @(negedge rd_clk);
      if(old_rd_valid || new_rd_valid || old_rd_data!==0 || new_rd_data!==0)
        $fatal(1,"P223 stale pre-reset packet replayed");
    end
    send(200);
    repeat(12)@(negedge rd_clk);
    if(!old_rd_valid || !new_rd_valid ||
       old_rd_data!==payload(200) || new_rd_data!==payload(200))
      $fatal(1,"P223 post-reset epoch failed to start clean");
    @(negedge rd_clk);rd_ready=1;
    @(negedge rd_clk);rd_ready=0;
    repeat(8)@(negedge rd_clk);
    if(old_rd_valid || new_rd_valid || old_rd_data!==0 || new_rd_data!==0)
      $fatal(1,"P223 post-reset drain left stale output");
    $display("P223_ZERO_BUBBLE_FIFO_PASS reverse=%0d words=%0d old_last_edge=%0d new_last_edge=%0d consecutive=16 stable_stall=1 async_reset_ns=2 stale_replay=0",
      REVERSE,COUNT,old_last,new_last);
    $finish;
  end
  initial begin #50000000;$fatal(1,"P223 zero-bubble comparison bounded timeout");end
endmodule
