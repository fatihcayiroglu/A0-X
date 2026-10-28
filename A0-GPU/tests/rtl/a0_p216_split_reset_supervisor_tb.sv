`timescale 1ns/1ps
// Test assertion with sub-cycle pulses and deassert at *local* edges only.
module a0_p216_split_reset_supervisor_tb #(parameter integer REVERSE=0);
  logic host_clk=0,pixel_clk=0,raw_rst_n=0,pause_pixel=0;
  wire host_rst_n,pixel_rst_n,both_released;
  integer host_edges=0,pixel_edges=0;
  time last_host_edge=0,last_pixel_edge=0;
  always #(REVERSE ? 7 : 4)host_clk=~host_clk;
  always #(REVERSE ? 4 : 7)begin
    if(pause_pixel)pixel_clk=0;else pixel_clk=~pixel_clk;
  end
  a0_p216_split_reset_supervisor dut(
    .host_clk(host_clk),.pixel_clk(pixel_clk),.raw_rst_n(raw_rst_n),
    .host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n),
    .both_released(both_released)
  );
  always @(negedge raw_rst_n)begin host_edges=0;pixel_edges=0;end
  always @(posedge host_clk)begin last_host_edge=$time;if(raw_rst_n)host_edges=host_edges+1;end
  always @(posedge pixel_clk)begin last_pixel_edge=$time;if(raw_rst_n)pixel_edges=pixel_edges+1;end
  always @(posedge host_rst_n)begin
    if(!raw_rst_n || host_clk!==1'b1 || $time!=last_host_edge ||
       host_edges<2 || pixel_edges<2)
      $fatal(1,"P216 host reset deassert not on local clock/qualified host=%0d pixel=%0d",host_edges,pixel_edges);
  end
  always @(posedge pixel_rst_n)begin
    if(!raw_rst_n || pixel_clk!==1'b1 || $time!=last_pixel_edge ||
       host_edges<2 || pixel_edges<2)
      $fatal(1,"P216 pixel reset deassert not on local clock/qualified host=%0d pixel=%0d",host_edges,pixel_edges);
  end
  task automatic await_both;
    integer t;
    begin
      t=0;
      while(!both_released && t<200)begin #1;t=t+1;end
      if(!both_released || !host_rst_n || !pixel_rst_n)
        $fatal(1,"P216 two domains never independently released");
    end
  endtask
  task automatic short_pulse;
    begin
      @(negedge pixel_clk);
      #1 raw_rst_n=0;
      #1 if(host_rst_n!==0 || pixel_rst_n!==0 || both_released!==0)
        $fatal(1,"P216 asynchronous pulse did not assert both domains");
      #1 raw_rst_n=1;
      await_both();
    end
  endtask
  integer i;
  initial begin
    repeat(3)@(negedge host_clk);
    raw_rst_n=1;await_both();
    for(i=0;i<6;i=i+1)begin repeat(i%3)@(negedge host_clk);short_pulse();end
    @(negedge pixel_clk);pause_pixel=1;
    #1 raw_rst_n=0;
    #1 if(host_rst_n!==0 || pixel_rst_n!==0)
      $fatal(1,"P216 stopped-clock reset assertion failed");
    #1 raw_rst_n=1;
    repeat(10)@(posedge host_clk);
    #1 if(host_rst_n || pixel_rst_n || both_released)
      $fatal(1,"P216 host released without pixel qualified ready");
    pause_pixel=0;await_both();
    $display("P216_LOCAL_RELEASE_PASS reverse=%0d short_pulses=6 async_assert=1 two_domains=1 local_clock_edge_only=1 remote_ready_synchronized=1 stopped_pixel_fail_closed=1",REVERSE);
    $finish;
  end
  initial begin #100000;$fatal(1,"P216 split reset supervisor bounded timeout");end
endmodule