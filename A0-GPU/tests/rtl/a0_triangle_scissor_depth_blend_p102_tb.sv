`timescale 1ns/1ps
module a0_triangle_scissor_depth_blend_p102_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,clear_valid=0,clear_ready,clear_done,tri_valid=0,tri_ready,tri_done;
    logic [23:0] clear_color=0,clear_depth=24'hffffff,tri_color=0,tri_depth=0;
    logic signed [15:0] x0=0,y0=0,x1=4,y1=0,x2=0,y2=4;
    logic [1:0] depth_compare_op=1;
    logic depth_write=1,blend_enable=0,scissor_enable=0;
    logic [7:0] source_alpha=255;
    logic [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
    logic initialized,busy,pixel_wrote,read_valid;
    logic [15:0] read_x=0,read_y=0;
    logic [23:0] read_color,read_depth;
    a0_triangle_scissor_depth_blend_p102 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut(.*);
    task automatic clear_frame(input logic [23:0] rgb,dep);
        int n;
        @(negedge clk);
        for(n=0;!clear_ready && n<100;n++) @(negedge clk);
        if(!clear_ready) $fatal(1,"P102 clear_ready timeout");
        clear_color=rgb;clear_depth=dep;clear_valid=1;
        @(negedge clk);clear_valid=0;
        for(n=0;!clear_done && n<100;n++) @(negedge clk);
        if(!clear_done || !initialized) $fatal(1,"P102 clear failure");
    endtask
    task automatic draw;
        int n;
        @(negedge clk);
        for(n=0;!tri_ready && n<120;n++) @(negedge clk);
        if(!tri_ready) $fatal(1,"P102 triangle ready timeout");
        tri_valid=1;
        @(negedge clk);tri_valid=0;
        for(n=0;!tri_done && n<120;n++) @(negedge clk);
        if(!tri_done) $fatal(1,"P102 triangle completion timeout");
    endtask
    task automatic check(input logic [15:0] xx,yy, input logic [23:0] rgb,dep);
        @(negedge clk); read_x=xx; read_y=yy;
        #1;
        if(!read_valid || read_color !== rgb || read_depth !== dep)
            $fatal(1,"P102 pixel (%0d,%0d) color=%h depth=%h expected=%h/%h",
                xx,yy,read_color,read_depth,rgb,dep);
    endtask
    initial begin
        int cycles;
        repeat(3) @(negedge clk);rst_n=1;
        if(initialized || tri_ready || read_valid) $fatal(1,"P102 no read before clear");
        clear_frame(24'h000000,24'hffffff);
        tri_color=24'hff0000;tri_depth=24'h000400;
        scissor_enable=1;scissor_x=1;scissor_y=1;scissor_w=2;scissor_h=2;
        // Exercise register snapshot. Mutate source pins *after* acceptance;
        // in-flight pixels must retain accepted state and original scissor.
        @(negedge clk); if (!tri_ready) $fatal(1,"P102 expected ready");
        tri_valid=1;
        @(negedge clk); tri_valid=0;
        tri_color=24'h00ffff;scissor_enable=0;depth_compare_op=2'd3;
        depth_write=0;blend_enable=1;
        for(cycles=0;!tri_done && cycles<120;cycles++) @(negedge clk);
        if(!tri_done) $fatal(1,"P102 snapshotted triangle timeout");
        check(0,0,24'h000000,24'hffffff);
        check(1,1,24'hff0000,24'h000400);
        depth_compare_op=1;depth_write=1;blend_enable=0;
        check(3,3,24'h000000,24'hffffff);
        // Blend green with the closer red pixel while disabling scissor.
        scissor_enable=0; tri_color=24'h00ff00;tri_depth=24'h000200;
        blend_enable=1;source_alpha=8'd128;
        draw();check(1,1,24'h7f8000,24'h000200);
        // Farther blue is rejected by LESS depth test.
        blend_enable=0;tri_color=24'h0000ff;tri_depth=24'h000800;
        draw();check(1,1,24'h7f8000,24'h000200);
        // LESS_EQUAL at equal depth accepts blue.
        depth_compare_op=2;tri_depth=24'h000200;
        draw();check(1,1,24'h0000ff,24'h000200);
        // Disallow depth write, then check depth unchanged despite color write.
        depth_compare_op=0;depth_write=0;tri_color=24'habcdef;tri_depth=24'h000001;
        draw();check(1,1,24'habcdef,24'h000200);
        // An empty scissor accepts triangle but writes no pixels.
        scissor_enable=1;scissor_w=0;depth_write=1;tri_color=24'h123456;
        draw();check(1,1,24'habcdef,24'h000200);
        // New clear resets both color and depth, independently of scissor.
        clear_frame(24'h010203,24'habcdee);
        check(1,1,24'h010203,24'habcdee);
        // Reset aborts active operations and invalidates debug reads.
        tri_color=24'hffffff;tri_depth=24'h000001;scissor_enable=0;
        @(negedge clk);if(!tri_ready)$fatal(1,"P102 reset setup");
        tri_valid=1;
        @(negedge clk);tri_valid=0;
        repeat(2) @(negedge clk);
        rst_n=0;
        @(negedge clk);
        if(initialized || read_valid || tri_ready || tri_done || clear_done)
            $fatal(1,"P102 reset did not invalidate state");
        rst_n=1;
        clear_frame(24'h000000,24'hffffff);
        check(1,1,24'h000000,24'hffffff);
        $display("P102 RTL RESEARCH PIXEL PIPELINE PASS"); $finish;
    end
    initial begin #20000;$fatal(1,"P102 global timeout");end
endmodule
