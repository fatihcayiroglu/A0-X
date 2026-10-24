`timescale 1ns/1ps
// Black-box FIFO stress. Checks 41-bit host->GPU and 33-bit GPU->host
// for ordering, duplication, loss, held-response stability and reset flushing.
// Simulator test only: not metastability/physical CDC qualification.
module a0_p133_fifo_stress_case #(
  parameter integer WIDTH=41,
  parameter integer COUNT=512,
  parameter integer SEED=0,
  parameter integer EXPECT_FULL=0
)(
  input wire wclk, rclk, rst_n,
  output reg done=0
);
  reg wvalid=0, rready=0;
  reg [WIDTH-1:0] wdata=0;
  wire wready, rvalid;
  wire [WIDTH-1:0] rdata;
  integer sent=0, received=0, wticks=0, rticks=0, full_hits=0;
  integer empty_hits=0, stalled_hits=0;
  reg held=0;
  reg [WIDTH-1:0] held_data=0;

  a0_p133_async_fifo #(.WIDTH(WIDTH),.ADDR_BITS(2)) fifo (
    .wclk(wclk),.wrst_n(rst_n),.wvalid(wvalid),.wready(wready),
    .wdata(wdata),.rclk(rclk),.rrst_n(rst_n),
    .rvalid(rvalid),.rready(rready),.rdata(rdata)
  );

  function automatic [WIDTH-1:0] pattern(input integer n);
    reg [63:0] mix;
    begin
      mix=64'h79b9c45de01267af ^ (n * 64'h9e3779b97f4a7c15);
      pattern=mix[WIDTH-1:0];
    end
  endfunction

  // Drive away from the sampling edges; all handshakes occur on posedges.
  always @(negedge wclk) begin
    if(!rst_n || done) begin wvalid=0; wdata=0; end
    else begin
      wvalid=(sent<COUNT) && ((wticks+SEED)%9!=0);
      wdata=pattern(sent);
    end
  end
  always @(negedge rclk) begin
    if(!rst_n || done) rready=0;
    else rready=((rticks+SEED)%11<7);
  end

  always @(posedge wclk or negedge rst_n) begin
    if(!rst_n) begin
      sent<=0; wticks<=0; full_hits<=0;
    end else if(!done) begin
      wticks<=wticks+1;
      if(wvalid && !wready) full_hits<=full_hits+1;
      if(wvalid && wready) begin
        if(sent>=COUNT || wdata !== pattern(sent))
          $fatal(1,"P133 FIFO WIDTH=%0d malformed producer",WIDTH);
        sent<=sent+1;
      end
      if(sent-received>4)
        $fatal(1,"P133 FIFO WIDTH=%0d capacity overflow",WIDTH);
    end
  end

  always @(posedge rclk or negedge rst_n) begin
    if(!rst_n) begin
      received<=0; rticks<=0; empty_hits<=0; stalled_hits<=0;
      held<=0; held_data<=0; done<=0;
    end else if(!done) begin
      rticks<=rticks+1;
      if(held && (!rvalid || rdata !== held_data))
        $fatal(1,"P133 FIFO WIDTH=%0d changed stalled response",WIDTH);
      held<=rvalid && !rready;
      if(rvalid && !rready) begin
        held_data<=rdata;
        stalled_hits<=stalled_hits+1;
      end
      if(rready && !rvalid) empty_hits<=empty_hits+1;
      if(rvalid && rready) begin
        if(received>=COUNT || rdata !== pattern(received))
          $fatal(1,"P133 FIFO WIDTH=%0d lost/reordered data index=%0d got=%h expected=%h",
                 WIDTH,received,rdata,pattern(received));
        received<=received+1;
        if(received==COUNT-1) begin
          if(sent!=COUNT) $fatal(1,"P133 FIFO finished before producer completed");
          if(empty_hits==0 || stalled_hits==0)
            $fatal(1,"P133 FIFO WIDTH=%0d missing empty/backpressure coverage",WIDTH);
          if(EXPECT_FULL && full_hits==0)
            $fatal(1,"P133 FIFO WIDTH=%0d missing full coverage",WIDTH);
          done<=1;
        end
      end
    end
  end
endmodule

module a0_p133_async_fifo_stress_tb #(
  parameter integer HOST_HALF_NS=3,
  parameter integer GPU_HALF_NS=11,
  parameter integer GPU_PHASE_NS=0
);
  reg host_clk=0, gpu_clk=0, rst_n=0;
  always #(HOST_HALF_NS) host_clk=~host_clk;
  initial begin
    #(GPU_PHASE_NS);
    forever #(GPU_HALF_NS) gpu_clk=~gpu_clk;
  end
  wire done_req, done_rsp;
  a0_p133_fifo_stress_case #(.WIDTH(41),.SEED(1),
    .EXPECT_FULL((HOST_HALF_NS*2)<=GPU_HALF_NS)) request(
    .wclk(host_clk),.rclk(gpu_clk),.rst_n(rst_n),.done(done_req));
  a0_p133_fifo_stress_case #(.WIDTH(33),.SEED(5),.EXPECT_FULL(0)) response(
    .wclk(gpu_clk),.rclk(host_clk),.rst_n(rst_n),.done(done_rsp));
  initial begin
    repeat(5) @(negedge gpu_clk);
    rst_n=1;
    // Interrupt live traffic, then verify both FIFOs restart from index zero.
    repeat(250) @(negedge host_clk);
    if(done_req || done_rsp) $fatal(1,"P133 reset exercise completed prematurely");
    rst_n=0;
    repeat(5) @(negedge gpu_clk);
    rst_n=1;
    wait(done_req && done_rsp);
    repeat(10) @(negedge gpu_clk);
    if(request.fifo.rvalid || response.fifo.rvalid)
      $fatal(1,"P133 FIFO repeated a response after drain");
    $display("P133_ASYNC_FIFO_STRESS_PASS widths=41,33 ordered=512x2 full/empty/stall/reset");
    $finish;
  end
  initial begin
    #200000;
    $fatal(1,"P133 FIFO stress watchdog");
  end
endmodule
