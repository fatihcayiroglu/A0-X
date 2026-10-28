`timescale 1ns/1ps
module a0_p215_dual_clock_reset_supervisor_tb #(
  parameter integer REVERSE=0
);
  logic host_clk=0,pixel_clk=0,raw_rst_n=0;
  logic pause_pixel=0;
  wire fabric_rst_n;
  always #(REVERSE?7:4)host_clk=~host_clk;
  always #(REVERSE?4:7)begin
    if(pause_pixel)pixel_clk=0;
    else pixel_clk=~pixel_clk;
  end
  integer host_edges=0,pixel_edges=0;
  a0_p215_dual_clock_reset_supervisor dut(
    .host_clk(host_clk),.pixel_clk(pixel_clk),
    .raw_rst_n(raw_rst_n),.fabric_rst_n(fabric_rst_n)
  );
  always @(negedge raw_rst_n)begin host_edges=0;pixel_edges=0;end
  always @(posedge host_clk)if(raw_rst_n && !fabric_rst_n)host_edges=host_edges+1;
  always @(posedge pixel_clk)if(raw_rst_n && !fabric_rst_n)pixel_edges=pixel_edges+1;
  task automatic await_release;
    integer t;
    begin
      t=0;
      while(!fabric_rst_n && t<200)begin #1;t=t+1;end
      if(!fabric_rst_n || host_edges<2 || pixel_edges<2)
        $fatal(1,"P215 released without 2 edges in both clock domains host=%0d pixel=%0d",
               host_edges,pixel_edges);
    end
  endtask
  task automatic short_pulse;
    begin
      @(negedge pixel_clk);
      #1 raw_rst_n=0;
      #1 if(fabric_rst_n!==0)$fatal(1,"P215 raw async reset did not assert immediately");
      #1 raw_rst_n=1; // 2ns pulse, shorter than either clock period
      await_release();
    end
  endtask
  integer i;
  initial begin
    repeat(3)@(negedge host_clk);
    raw_rst_n=1;await_release();
    for(i=0;i<6;i=i+1)begin
      repeat(i%3)@(negedge host_clk);
      short_pulse();
    end
    // Stop pixel clock: no number of host edges alone may release fabric.
    @(negedge pixel_clk);pause_pixel=1;
    #1 raw_rst_n=0;
    #1 if(fabric_rst_n!==0)$fatal(1,"P215 stopped-pixel reset assertion");
    #1 raw_rst_n=1;
    repeat(7)@(posedge host_clk);
    #1 if(fabric_rst_n!==0)$fatal(1,"P215 released with pixel clock stopped");
    pause_pixel=0;
    await_release();
    $display("P215_SUPERVISOR_PASS reverse=%0d short_pulses=6 async_assert=1 two_host_edges=1 two_pixel_edges=1 stopped_pixel_fail_closed=1",REVERSE);
    $finish;
  end
  initial begin #100000;$fatal(1,"P215 bounded reset supervisor timeout");end
endmodule
