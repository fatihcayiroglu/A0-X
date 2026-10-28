`timescale 1ns/1ps
module a0_p212_gray_async_fifo_tb #(
  parameter integer REVERSE=0
);
  localparam integer AB=6,DEPTH=64;
  logic wr_clk=0,rd_clk=0,rst_n=0;
  always #(REVERSE?7:4) wr_clk=~wr_clk;
  always #(REVERSE?4:7) rd_clk=~rd_clk;
  logic wr_valid=0,rd_ready=0;
  wire wr_ready,rd_valid;
  logic [91:0] wr_data=0;
  wire [91:0] rd_data;
  a0_p212_gray_async_fifo #(.WIDTH(92),.ADDR_BITS(AB)) dut(
    .wr_clk(wr_clk),.rd_clk(rd_clk),.rst_n(rst_n),
    .wr_valid(wr_valid),.wr_ready(wr_ready),.wr_data(wr_data),
    .rd_valid(rd_valid),.rd_ready(rd_ready),.rd_data(rd_data)
  );
  function automatic [91:0] payload(input integer i);
    payload={32'hbacd0000^32'(i),32'h01230000+32'(i),28'(i)};
  endfunction
  task automatic reset_all;
    begin
      @(negedge wr_clk);rst_n=0;wr_valid=0;rd_ready=0;
      repeat(6)@(negedge rd_clk);rst_n=1;
      repeat(6)@(negedge wr_clk);
      repeat(6)@(negedge rd_clk);
      if(rd_valid || rd_data!==92'd0)
        $fatal(1,"P212 reset exposed stale FIFO payload");
    end
  endtask
  task automatic send(input integer i);
    integer t;
    begin
      @(negedge wr_clk);wr_valid=1;wr_data=payload(i);t=0;
      while(!wr_ready && t<3000)begin @(negedge wr_clk);t=t+1;end
      if(!wr_ready)$fatal(1,"P212 stuck FIFO writer index=%0d",i);
      @(negedge wr_clk);wr_valid=0;
    end
  endtask
  task automatic recv(input integer i);
    integer t;
    begin
      @(negedge rd_clk);rd_ready=0;t=0;
      while(!rd_valid && t<3000)begin @(negedge rd_clk);t=t+1;end
      if(!rd_valid || rd_data!==payload(i))
        $fatal(1,"P212 FIFO reorder/corruption index=%0d data=%h expected=%h",i,rd_data,payload(i));
      rd_ready=1;
      @(negedge rd_clk);rd_ready=0;
    end
  endtask
  integer i;
  logic [91:0] hold_data;
  initial begin
    reset_all();
    // With output prefetch, capacity is DEPTH in RAM plus one prefetched word.
    for(i=0;i<=DEPTH;i=i+1)send(i);
    repeat(6)@(negedge wr_clk);
    if(wr_ready || !rd_valid)$fatal(1,"P212 FIFO did not become physically full");
    hold_data=rd_data;
    repeat(8)begin
      @(negedge rd_clk);
      if(!rd_valid || rd_data!==hold_data)
        $fatal(1,"P212 output not stable under read backpressure");
    end
    // A denied extra write cannot enter or change stream sequence.
    @(negedge wr_clk);wr_valid=1;wr_data=payload(9999);
    repeat(6)begin
      @(negedge wr_clk);
      if(wr_ready)$fatal(1,"P212 overflow accepted");
    end
    wr_valid=0;
    for(i=0;i<=DEPTH;i=i+1)recv(i);
    // Wrap binary and Gray pointers repeatedly under concurrent clock rates.
    fork
      begin : writer
        integer k;
        for(k=DEPTH+1;k<DEPTH+301;k=k+1)begin
          repeat(k%3)@(negedge wr_clk);
          send(k);
        end
      end
      begin : reader
        integer k;
        for(k=DEPTH+1;k<DEPTH+301;k=k+1)begin
          repeat(k%4)@(negedge rd_clk);
          recv(k);
        end
      end
    join
    // Reset while valid output remains held: no stale valid or exposed data.
    send(7000);send(7001);
    repeat(8)@(negedge rd_clk);
    if(!rd_valid)$fatal(1,"P212 reset challenge never prefetched a word");
    reset_all();
    send(8000);recv(8000);
    repeat(8)@(negedge rd_clk);
    if(rd_valid || rd_data!==92'd0)
      $fatal(1,"P212 empty FIFO leaked payload after drain");
    $display("P212_ASYNC_FIFO_PASS reverse=%0d depth=%0d width=92 full=1 overflow_reject=1 stable=1 wrap=1 concurrent=1 reset_isolation=1",REVERSE,DEPTH);
    $finish;
  end
  initial begin #50000000;$fatal(1,"P212 async FIFO bounded timeout");end
endmodule
