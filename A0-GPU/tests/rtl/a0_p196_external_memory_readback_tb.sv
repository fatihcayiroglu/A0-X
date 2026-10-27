`timescale 1ns/1ps
// P196: actual P195 producer FIFO connected to a stateful, arbitration-
// constrained memory model. Every accepted write is checked in order.
module a0_p196_external_memory_readback_tb;
  logic clk=0;always #5 clk=~clk;
  logic rst_n=0,in_valid=0,allow_write=1,allow_read=1;
  logic [15:0] in_x=0,in_y=0;
  logic [47:0] in_pixel=0;
  wire in_ready,reject_valid,out_valid,mem_wr_ready,wr_fault;
  wire [31:0] out_word_addr;
  wire [47:0] out_pixel;
  wire [1:0] queued;
  logic read_valid=0;
  logic [31:0] read_addr=0;
  wire read_ready,read_rsp_valid,read_rsp_error;
  wire [47:0] read_rsp_pixel;
  localparam logic [31:0] BASE=32'h01000000;
  a0_p195_external_pixel_write_queue #(
    .FRAME_WIDTH(256),.FRAME_HEIGHT(256),.BASE_WORD_ADDR(BASE)
  ) fifo(
    .clk(clk),.rst_n(rst_n),
    .in_valid(in_valid),.in_ready(in_ready),
    .in_x(in_x),.in_y(in_y),.in_pixel(in_pixel),
    .reject_valid(reject_valid),.out_valid(out_valid),
    .out_ready(mem_wr_ready),.out_word_addr(out_word_addr),
    .out_pixel(out_pixel),.queued_words(queued)
  );
  a0_p196_external_word_memory_model #(
    .WORDS(65536),.BASE_WORD_ADDR(BASE)
  ) mem(
    .clk(clk),.rst_n(rst_n),
    .allow_write(allow_write),.allow_read(allow_read),
    .write_valid(out_valid),.write_ready(mem_wr_ready),
    .write_word_addr(out_word_addr),.write_pixel(out_pixel),
    .write_fault(wr_fault),
    .read_valid(read_valid),.read_ready(read_ready),
    .read_word_addr(read_addr),.read_rsp_valid(read_rsp_valid),
    .read_rsp_error(read_rsp_error),.read_rsp_pixel(read_rsp_pixel)
  );

  logic [31:0] expected_addr [0:2047];
  logic [47:0] expected_data [0:2047];
  integer accepted=0,committed=0,rejected=0,stalled=0;
  integer contention=0,granted_reads=0,granted_writes=0;
  always @(posedge clk)begin
    if(!rst_n)begin
      accepted=0;committed=0;rejected=0;stalled=0;
      contention=0;granted_reads=0;granted_writes=0;
    end else begin
      if(wr_fault)$fatal(1,"P196 external port reported invalid write");
      if(out_valid && mem_wr_ready)begin
        if(committed>=accepted)
          $fatal(1,"P196 duplicated/unexpected external write");
        if(out_word_addr!==expected_addr[committed] ||
           out_pixel!==expected_data[committed])
          $fatal(1,"P196 external commit order or payload mismatch #%0d",
                 committed);
        committed=committed+1;
      end
      if(in_valid && !in_ready)stalled=stalled+1;
      if(in_valid && in_ready)begin
        if(in_x>=256 || in_y>=256)rejected=rejected+1;
        else begin
          if(accepted>=2048)$fatal(1,"P196 scoreboard too small");
          expected_addr[accepted]=BASE+32'(in_y)*32'd256+32'(in_x);
          expected_data[accepted]=in_pixel;
          accepted=accepted+1;
        end
      end
      if(read_valid && out_valid && allow_write && allow_read)begin
        contention=contention+1;
        if(read_ready)granted_reads=granted_reads+1;
        if(mem_wr_ready)granted_writes=granted_writes+1;
        if(read_ready == mem_wr_ready)
          $fatal(1,"P196 single-port arbitration accepted both/neither");
      end
      if(queued>2)$fatal(1,"P196 upstream queue overflow");
    end
  end

  bit stress=0;
  integer tick=0;
  always @(negedge clk)begin
    if(stress && rst_n)begin
      tick=tick+1;
      allow_write=(tick%5!=0 && tick%5!=1);
      allow_read=(tick%7!=0);
    end
  end

  task automatic send(input logic [15:0] x,y,
                      input logic [47:0] data);
    bit got;
    begin
      got=0;
      @(negedge clk);
      in_valid=1;in_x=x;in_y=y;in_pixel=data;
      while(!got)begin
        @(posedge clk);got=in_ready;
        if(!got)@(negedge clk);
      end
      @(negedge clk);in_valid=0;
    end
  endtask

  task automatic read_check(input logic [31:0] addr,
      input logic [47:0] want,input bit want_error);
    bit got;
    integer waits;
    begin
      got=0;waits=0;
      @(negedge clk);read_valid=1;read_addr=addr;
      while(!got)begin
        @(posedge clk);got=read_ready;
        if(!got)begin
          @(negedge clk);waits=waits+1;
          if(waits>4000)$fatal(1,"P196 read request starved");
        end
      end
      @(negedge clk);read_valid=0;
      if(!read_rsp_valid)
        $fatal(1,"P196 accepted read did not return registered response");
      if(read_rsp_error!==want_error ||
         read_rsp_pixel!==(want_error ? 48'd0 : want))
        $fatal(1,"P196 wrong read response addr=%h got=%h/%b want=%h/%b",
               addr,read_rsp_pixel,read_rsp_error,want,want_error);
    end
  endtask

  task automatic flush;
    integer waits;
    begin
      waits=0;
      @(negedge clk);allow_write=1;allow_read=1;
      while(committed!=accepted || queued!=0)begin
        @(negedge clk);waits=waits+1;
        if(waits>12000)$fatal(1,"P196 undrained accepted write");
      end
      if(out_valid)$fatal(1,"P196 write phantom after drain");
    end
  endtask

  integer k,j;
  initial begin
    repeat(4)@(negedge clk);rst_n=1;
    send(0,0,48'h112233445566);
    send(255,255,48'h778899aabbcc);
    send(127,128,48'h010203040506);
    send(128,127,48'hd0d1d2d3d4d5);
    flush();
    if(committed!=4)$fatal(1,"P196 initial writes not committed");
    read_check(BASE,48'h112233445566,0);
    read_check(BASE+32'd65535,48'h778899aabbcc,0);
    read_check(BASE+32'd32895,48'h010203040506,0);
    read_check(BASE+32'd32640,48'hd0d1d2d3d4d5,0);
    read_check(BASE+32'd50000,48'd0,1);
    read_check(BASE+32'd65536,48'd0,1);
    read_check(BASE-32'd1,48'd0,1);
    send(256,0,48'hdeadbeef0000);
    send(0,256,48'hbadcafe00000);
    if(rejected!=2)$fatal(1,"P196 out-of-bounds admission mismatch");

    // Real overlapping host reads and 1,024 producer writes. The single
    // modeled port must grant both request classes without losing order.
    @(posedge clk);stress=1;
    fork
      begin
        for(k=0;k<1024;k=k+1)
          send(16'(k%256),16'(4+(k/256)),
               {16'(k),16'(k ^ 16'h55aa),16'(16'hffff-k)});
      end
      begin
        for(j=0;j<200;j=j+1)begin
          case(j%4)
            0:read_check(BASE,48'h112233445566,0);
            1:read_check(BASE+32'd65535,48'h778899aabbcc,0);
            2:read_check(BASE+32'd32895,48'h010203040506,0);
            3:read_check(BASE+32'd32640,48'hd0d1d2d3d4d5,0);
          endcase
        end
      end
    join
    @(posedge clk);stress=0;
    flush();
    if(accepted!=1028 || committed!=1028 || rejected!=2 ||
       contention<10 || granted_reads<1 || granted_writes<1 || stalled<1)
      $fatal(1,"P196 integrity/fairness missing: accepted=%0d committed=%0d rejects=%0d overlap=%0d r=%0d w=%0d stalls=%0d",
         accepted,committed,rejected,contention,granted_reads,
         granted_writes,stalled);
    for(k=0;k<1024;k=k+127)
      read_check(BASE+32'((4+(k/256))*256+(k%256)),
          {16'(k),16'(k ^ 16'h55aa),16'(16'hffff-k)},0);

    // A reset discards only FIFO words that memory has not accepted.
    // Already-accepted memory writes MUST remain readable afterwards.
    @(negedge clk);allow_write=0;
    send(8,40,48'h100000000001);
    send(9,40,48'h200000000002);
    if(queued!==2)$fatal(1,"P196 pending-reset setup lost writes");
    @(negedge clk);rst_n=0;
    repeat(3)@(negedge clk);
    if(out_valid || queued!=0 || read_rsp_valid || wr_fault)
      $fatal(1,"P196 protocol reset leaked stale response or queued word");
    rst_n=1;allow_write=1;allow_read=1;
    read_check(BASE,48'h112233445566,0);
    read_check(BASE+32'd65535,48'h778899aabbcc,0);
    read_check(BASE+32'd10248,48'd0,1);
    read_check(BASE+32'd10249,48'd0,1);
    send(7,40,48'habcdabcd1234);
    flush();
    read_check(BASE+32'd10247,48'habcdabcd1234,0);
    if(accepted!=1 || committed!=1)
      $fatal(1,"P196 reset epoch commit mismatch");
    $display("P196_EXTERNAL_MEMORY_MODEL_PASS frame=256x256 committed=1028 concurrent_reads=200 invalid_writes=2 reset_retention=1 pending_discard=1 arbitration=1");
    $finish;
  end
  initial begin #10000000; $fatal(1,"P196 memory simulation timeout"); end
endmodule
