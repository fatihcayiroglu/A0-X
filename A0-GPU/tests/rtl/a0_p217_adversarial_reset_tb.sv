`timescale 1ns/1ps
// P217: deliberately race short raw reset pulses against two unrelated clock
// ratios, assert local-edge release and enforce two-flop remote-ready latency.
// This is dynamic evidence, NOT formal CDC/MTBF or board-timing signoff.
module a0_p217_adversarial_reset_tb #(parameter integer REVERSE=0);
  logic host_clk=0,pixel_clk=0,raw_rst_n=0,pause_host=0,pause_pixel=0;
  wire host_rst_n,pixel_rst_n,both_released;
  integer host_edges=0,pixel_edges=0,host_after_pixel_ready=0,pixel_after_host_ready=0;
  time host_edge_time=0,pixel_edge_time=0;
  always #(REVERSE ? 7 : 4)begin
    if(pause_host)host_clk=0;else host_clk=~host_clk;
  end
  always #(REVERSE ? 4 : 7)begin
    if(pause_pixel)pixel_clk=0;else pixel_clk=~pixel_clk;
  end
  a0_p216_split_reset_supervisor dut(
    .host_clk(host_clk),.pixel_clk(pixel_clk),.raw_rst_n(raw_rst_n),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .both_released(both_released)
  );
  always @(negedge raw_rst_n)begin
    host_edges=0;pixel_edges=0;
    host_after_pixel_ready=0;pixel_after_host_ready=0;
  end
  always @(posedge dut.pixel_ready_q[1])host_after_pixel_ready=0;
  always @(posedge dut.host_ready_q[1])pixel_after_host_ready=0;
  always @(posedge host_clk)begin
    host_edge_time=$time;
    if(raw_rst_n)host_edges=host_edges+1;
    if(raw_rst_n && dut.pixel_ready_q[1])
      host_after_pixel_ready=host_after_pixel_ready+1;
  end
  always @(posedge pixel_clk)begin
    pixel_edge_time=$time;
    if(raw_rst_n)pixel_edges=pixel_edges+1;
    if(raw_rst_n && dut.host_ready_q[1])
      pixel_after_host_ready=pixel_after_host_ready+1;
  end
  always @(posedge host_rst_n)begin
    if(!raw_rst_n || host_clk!==1'b1 || host_edge_time!=$time ||
       host_edges<2 || pixel_edges<2 || host_after_pixel_ready<3)
      $fatal(1,"P217 host release bypasses local edge or two remote sync stages h=%0d p=%0d remote=%0d",host_edges,pixel_edges,host_after_pixel_ready);
  end
  always @(posedge pixel_rst_n)begin
    if(!raw_rst_n || pixel_clk!==1'b1 || pixel_edge_time!=$time ||
       host_edges<2 || pixel_edges<2 || pixel_after_host_ready<3)
      $fatal(1,"P217 pixel release bypasses local edge or two remote sync stages h=%0d p=%0d remote=%0d",host_edges,pixel_edges,pixel_after_host_ready);
  end
  task automatic wait_both;
    integer n;
    begin
      n=0;
      while(!both_released && n<200)begin #1;n=n+1;end
      if(!both_released || !host_rst_n || !pixel_rst_n)
        $fatal(1,"P217 missing qualified two-domain release");
    end
  endtask
  task automatic pulse;
    begin
      @(negedge pixel_clk);
      #1 raw_rst_n=0;
      #1 if(host_rst_n!==0 || pixel_rst_n!==0 || both_released!==0)
        $fatal(1,"P217 raw 2ns reset failed to clear both domains");
      #1 raw_rst_n=1;
      wait_both();
    end
  endtask
  integer i;
  initial begin
    repeat(3)@(negedge host_clk);
    raw_rst_n=1;wait_both();
    for(i=0;i<12;i=i+1)begin
      repeat(i%4)@(negedge host_clk);
      pulse();
    end
    // If pixel oscillator stops during reset, host must not leave reset.
    @(negedge pixel_clk);pause_pixel=1;
    #1 raw_rst_n=0;
    #1 if(host_rst_n!==0 || pixel_rst_n!==0)
      $fatal(1,"P217 stopped pixel failed async reset");
    #1 raw_rst_n=1;
    repeat(12)@(posedge host_clk);
    #1 if(host_rst_n!==0 || pixel_rst_n!==0 || both_released!==0)
      $fatal(1,"P217 host released with pixel stopped");
    pause_pixel=0;wait_both();
    // Symmetric check: pixel cannot leave reset while host oscillator stops.
    @(negedge host_clk);pause_host=1;
    #1 raw_rst_n=0;
    #1 if(host_rst_n!==0 || pixel_rst_n!==0)
      $fatal(1,"P217 stopped host failed async reset");
    #1 raw_rst_n=1;
    repeat(12)@(posedge pixel_clk);
    #1 if(host_rst_n!==0 || pixel_rst_n!==0 || both_released!==0)
      $fatal(1,"P217 pixel released with host stopped");
    pause_host=0;wait_both();
    $display("P217_ADVERSARIAL_RESET_PASS reverse=%0d short_pulses=12 local_edge=1 two_remote_sync_stages=1 stopped_host=1 stopped_pixel=1 async_assert=1",REVERSE);
    $finish;
  end
  initial begin #100000;$fatal(1,"P217 adversarial reset bounded timeout");end
endmodule