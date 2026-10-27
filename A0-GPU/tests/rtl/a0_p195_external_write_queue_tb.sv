`timescale 1ns/1ps
// Deterministic handshake scoreboard: never infer success from a marker alone.
module a0_p195_external_write_queue_tb;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0,in_valid=0,out_ready=0;
  logic [15:0] in_x=0,in_y=0;
  logic [47:0] in_pixel=0;
  wire in_ready,reject_valid,out_valid;
  wire [31:0] out_word_addr;
  wire [47:0] out_pixel;
  wire [1:0] queued_words;
  localparam logic [31:0] BASE=32'h01000000;
  a0_p195_external_pixel_write_queue #(
    .FRAME_WIDTH(256),.FRAME_HEIGHT(256),.BASE_WORD_ADDR(BASE)
  ) dut(
    .clk(clk),.rst_n(rst_n),.in_valid(in_valid),.in_ready(in_ready),
    .in_x(in_x),.in_y(in_y),.in_pixel(in_pixel),
    .reject_valid(reject_valid),
    .out_valid(out_valid),.out_ready(out_ready),
    .out_word_addr(out_word_addr),.out_pixel(out_pixel),
    .queued_words(queued_words)
  );

  logic [31:0] expected_addr [0:2047];
  logic [47:0] expected_pixel [0:2047];
  integer enqueued=0,drained=0,rejected=0,stalls=0;
  logic prior_reject=0;
  always @(posedge clk) begin
    if(!rst_n) begin
      enqueued=0;drained=0;rejected=0;stalls=0;prior_reject<=0;
    end else begin
      if(reject_valid!==prior_reject)
        $fatal(1,"P195 reject pulse differs from accepted bad coordinate");
      prior_reject<=in_valid && in_ready &&
         !(in_x<256 && in_y<256);
      if(out_valid && out_ready) begin
        if(drained>=enqueued)
          $fatal(1,"P195 output duplicated or appeared without input");
        if(out_word_addr!==expected_addr[drained] ||
           out_pixel!==expected_pixel[drained])
          $fatal(1,"P195 reordered/corrupted output #%0d addr=%h/%h pixel=%h/%h",
            drained,out_word_addr,expected_addr[drained],
            out_pixel,expected_pixel[drained]);
        drained=drained+1;
      end
      if(in_valid && !in_ready) stalls=stalls+1;
      if(in_valid && in_ready) begin
        if(in_x>=256 || in_y>=256) rejected=rejected+1;
        else begin
          if(enqueued>=2048)$fatal(1,"P195 test scoreboard exhausted");
          expected_addr[enqueued]=BASE+32'(in_y)*32'd256+32'(in_x);
          expected_pixel[enqueued]=in_pixel;
          enqueued=enqueued+1;
        end
      end
      if(queued_words>2)$fatal(1,"P195 occupancy overflow");
    end
  end

  integer pattern_step=0;
  bit pattern_enabled=0;
  always @(negedge clk) begin
    if(pattern_enabled && rst_n) begin
      pattern_step=pattern_step+1;
      out_ready=(pattern_step%7==0 || pattern_step%11==0);
    end
  end

  task automatic send(input logic [15:0] x,y,
                      input logic [47:0] data);
    bit accepted;
    begin
      accepted=0;
      @(negedge clk);
      in_valid=1;in_x=x;in_y=y;in_pixel=data;
      while(!accepted) begin
        @(posedge clk);accepted=in_ready;
        if(!accepted)@(negedge clk);
      end
      @(negedge clk);in_valid=0;
    end
  endtask
  task automatic flush_queue;
    integer waits;
    begin
      waits=0;
      @(negedge clk);out_ready=1;
      while(drained!=enqueued || queued_words!=0)begin
        @(negedge clk);waits=waits+1;
        if(waits>10000)$fatal(1,"P195 queue never drained");
      end
      if(out_valid)$fatal(1,"P195 phantom output after drain");
    end
  endtask

  integer i;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    // Fill both slots, hold downstream indefinitely.
    send(16'd0,16'd0,48'h010203040506);
    send(16'd255,16'd255,48'h0708090a0b0c);
    if(queued_words!==2 || !out_valid)
      $fatal(1,"P195 failed to fill two-slot FIFO");

    // Invalid host coordinates must be acknowledged as rejects even when full.
    send(16'd256,16'd0,48'hdeadbeef0000);
    send(16'd0,16'd256,48'hdeadcafe0000);
    if(queued_words!==2 || rejected!=2)
      $fatal(1,"P195 invalid coordinate corrupted full queue");

    // Keep third valid request stalled for five cycles, then accept it
    // on exactly the same beat as a full-queue downstream pop.
    @(negedge clk);in_valid=1;in_x=16'd128;in_y=16'd128;
    in_pixel=48'ha1a2a3a4a5a6;
    #1; // Settle combinational ready after invalid->valid XY change.
    repeat(5)begin
      if(in_ready!==0)$fatal(1,"P195 full queue did not backpressure");
      @(posedge clk);
      @(negedge clk);
    end
    out_ready=1;
    #1; // Settle combinational ready after downstream releases stall.
    if(!in_ready || !out_valid)
      $fatal(1,"P195 full pop+push did not expose capacity");
    @(posedge clk);
    @(negedge clk);in_valid=0;out_ready=0;
    if(queued_words!==2)
      $fatal(1,"P195 simultaneous pop and push lost occupancy");
    flush_queue();
    if(drained!=3 || enqueued!=3 || rejected!=2)
      $fatal(1,"P195 first-phase count mismatch");
    if(stalls<5)$fatal(1,"P195 never exercised backpressure");

    // 1,024 deterministic addresses and payloads across the entire frame.
    // Slow consumer produces sustained stalls; scoreboard requires FIFO order.
    @(posedge clk);pattern_enabled=1;
    for(i=0;i<1024;i=i+1)
      send(16'(i%256),16'((i*7)%256),
           {16'(i),16'(i ^ 16'h55aa),16'(16'hffff-i)});
    @(posedge clk);pattern_enabled=0;
    flush_queue();
    if(enqueued!=1027 || drained!=1027 || rejected!=2)
      $fatal(1,"P195 stress lost/duplicated output enq=%0d drn=%0d bad=%0d",
             enqueued,drained,rejected);

    // Reset must discard unaccepted/undrained payloads, not leak stale words.
    @(negedge clk);out_ready=0;
    send(16'd1,16'd1,48'h100000000001);
    send(16'd2,16'd2,48'h200000000002);
    if(queued_words!==2)$fatal(1,"P195 reset precondition failed");
    @(negedge clk);rst_n=0;
    repeat(3)@(negedge clk);
    if(out_valid || queued_words!==0 || reject_valid)
      $fatal(1,"P195 stale output survived reset");
    rst_n=1;
    send(16'd255,16'd0,48'habcdef112233);
    flush_queue();
    if(enqueued!=1 || drained!=1 || rejected!=0)
      $fatal(1,"P195 reset did not restart cleanly");
    $display("P195_EXTERNAL_WRITE_QUEUE_PASS frame=256x256 stress=1024 ordered=1027 rejected=2 depth=2 simultaneous_pop_push=1 reset_flush=1");
    $finish;
  end
  initial begin #3000000; $fatal(1,"P195 timeout"); end
endmodule
