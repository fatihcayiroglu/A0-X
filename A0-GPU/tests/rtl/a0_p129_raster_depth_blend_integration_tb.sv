`timescale 1ns/1ps
// P129: real-simulator witness for the existing P102 graphics chain.
// It is an 4x4 research framebuffer, not a real GPU/display/PCIe path.
module a0_p129_raster_depth_blend_integration_tb;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0, clear_valid=0, clear_ready, clear_done;
    logic [23:0] clear_color=0, clear_depth=0;
    logic tri_valid=0, tri_ready, tri_done, initialized, busy;
    logic signed [15:0] x0=0,y0=0,x1=4,y1=0,x2=0,y2=4;
    logic [23:0] tri_color=0,tri_depth=0;
    logic [1:0] depth_compare_op=1;
    logic depth_write=1,blend_enable=0;
    logic [7:0] source_alpha=255;
    logic scissor_enable=0;
    logic [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
    logic [15:0] read_x=0,read_y=0;
    logic read_valid,pixel_wrote;
    logic [23:0] read_color,read_depth;
    integer writes=0;
    integer triangles=0;

    a0_triangle_scissor_depth_blend_p102 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut(.*);
    always @(negedge clk) if (rst_n && pixel_wrote) writes=writes+1;
    initial begin #25000; $fatal(1,"P129 simulation watchdog"); end

    task automatic reset_device;
        begin
            @(negedge clk); rst_n=0;tri_valid=0;clear_valid=0;
            repeat(3) @(negedge clk);
            #1;
            if(initialized!==0 || read_valid!==0) $fatal(1,"P129 reset did not gate stale framebuffer");
            rst_n=1;
        end
    endtask

    task automatic clear_fb(input logic [23:0] color, input logic [23:0] depth);
        integer k;
        begin
            @(negedge clk);
            if(clear_ready!==1) $fatal(1,"P129 clear not ready");
            clear_color=color;clear_depth=depth;clear_valid=1;
            @(negedge clk);clear_valid=0;
            for(k=0;k<50 && clear_done!==1;k=k+1) @(negedge clk);
            if(clear_done!==1 || initialized!==1 || busy!==0)
                $fatal(1,"P129 clear completion failed");
        end
    endtask

    task automatic triangle(input logic [23:0] color, input logic [23:0] depth,
                            input logic [1:0] mode, input logic dwrite,
                            input logic do_blend, input logic [7:0] alpha,
                            input logic scissor_on);
        integer k;
        begin
            @(negedge clk);
            if(tri_ready!==1) $fatal(1,"P129 triangle not ready");
            tri_color=color;tri_depth=depth;depth_compare_op=mode;
            depth_write=dwrite;blend_enable=do_blend;source_alpha=alpha;
            scissor_enable=scissor_on;
            scissor_x=1;scissor_y=0;scissor_w=2;scissor_h=2;
            x0=0;y0=0;x1=4;y1=0;x2=0;y2=4;
            tri_valid=1;
            @(negedge clk);
            tri_valid=0;
            // The in-flight transaction must use the snapshotted inputs.
            tri_color=24'h55aa12;tri_depth=24'hfefefe;
            depth_compare_op=0;depth_write=0;blend_enable=0;
            scissor_enable=0;source_alpha=0;
            x0=3;y0=3;x1=3;y1=3;x2=3;y2=3;
            for(k=0;k<70 && tri_done!==1;k=k+1) @(negedge clk);
            if(tri_done!==1) $fatal(1,"P129 raster completion timeout");
            @(negedge clk);#1;
            triangles=triangles+1;
        end
    endtask

    task automatic expect_pixel(input integer px,input integer py,
                               input logic [23:0] want_color,input logic [23:0] want_depth);
        begin
            read_x=16'(px);read_y=16'(py);#1;
            if(read_valid!==1 || read_color!==want_color || read_depth!==want_depth)
                $fatal(1,"P129 pixel (%0d,%0d) got C=%06x D=%06x expected C=%06x D=%06x",
                        px,py,read_color,read_depth,want_color,want_depth);
        end
    endtask

    task automatic expect_frame(input integer phase);
        logic covered,scissored;
        logic [23:0] c,d;
        begin
            for(integer yy=0;yy<4;yy=yy+1)
                for(integer xx=0;xx<4;xx=xx+1) begin
                    covered=((xx+yy)<3);
                    scissored=(xx>=1 && xx<3 && yy<2);
                    c=24'h000000;d=24'hffffff;
                    if(covered) begin
                        c=24'hff0000;d=24'd100;
                        if(phase==3 && scissored) c=24'h7f0080;
                    end
                    expect_pixel(xx,yy,c,d);
                end
        end
    endtask

    initial begin
        repeat(3) @(negedge clk);
        rst_n=1;
        clear_fb(24'h000000,24'hffffff);
        if(writes!==0) $fatal(1,"P129 unexpected writes during clear");
        triangle(24'hff0000,24'd100,2'd1,1,0,8'd255,0);
        if(writes!==6) $fatal(1,"P129 first raster writes=%0d expected=6",writes);
        expect_frame(1);
        // More distant fragments must not modify the depth/color framebuffer.
        triangle(24'h00ff00,24'd200,2'd1,1,0,8'd255,0);
        if(writes!==6) $fatal(1,"P129 failed depth rejection");
        expect_frame(2);
        // Scissor should constrain a nearer, alpha-blended triangle to 3 pixels.
        triangle(24'h0000ff,24'd50,2'd1,0,1,8'd128,1);
        if(writes!==9) $fatal(1,"P129 scissored blend writes=%0d expected=9",writes);
        expect_frame(3);
        read_x=16'd4;read_y=0;#1;
        if(read_valid!==0 || read_color!==0 || read_depth!==0)
            $fatal(1,"P129 out-of-range read not gated");
        // Reset during a new clear must invalidate reads until fully re-cleared.
        @(negedge clk);
        clear_valid=1;clear_color=24'habcdef;clear_depth=24'd0;
        @(negedge clk);clear_valid=0;
        repeat(3) @(negedge clk);
        reset_device();
        clear_fb(24'h123456,24'd7);
        expect_pixel(0,0,24'h123456,24'd7);
        expect_pixel(3,3,24'h123456,24'd7);
        if(triangles!==3) $fatal(1,"P129 missing triangle coverage");
        $display("P129_GRAPHICS_INTEGRATION_WITNESS triangles=%0d committed_pixels=%0d framebuffer=4x4",triangles,writes);
        $display("P129_REAL_RTL_GRAPHICS_INTEGRATION_PASS");
        $finish;
    end
endmodule