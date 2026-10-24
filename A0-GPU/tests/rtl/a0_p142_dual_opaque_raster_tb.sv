`timescale 1ns/1ps
// P142 true 2-position/cycle opaque raster reference: original unchanged
// P102 compared against actual P142/P139/P138 BRAM. FULL 48-bit pixels are
// read back after each operation and write counts are independently checked.
module a0_p142_dual_opaque_raster_tb #(
    parameter integer FRAME_WIDTH=4,FRAME_HEIGHT=4,
    parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT
);
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,clear_valid=0,tri_valid=0;
    reg [23:0] clear_color=24'h112233,clear_depth=24'hffffff;
    reg [23:0] tri_color=24'h274eb8,tri_depth=24'h000090;
    reg signed [15:0] x0=-16'sd16,y0=-16'sd16;
    reg signed [15:0] x1=16'sd256,y1=-16'sd16;
    reg signed [15:0] x2=-16'sd16,y2=16'sd256;
    reg scissor_enable=0;
    reg [15:0] scissor_x=0,scissor_y=0,scissor_w=0,scissor_h=0;
    reg [15:0] ref_read_x=0,ref_read_y=0;
    reg host_read_valid=0;
    reg [15:0] host_read_x=0,host_read_y=0;
    wire ref_clear_ready,ref_clear_done,ref_tri_ready,ref_tri_done;
    wire ref_initialized,ref_busy,ref_read_valid,ref_pixel_wrote;
    wire [23:0] ref_color,ref_depth;
    wire dut_clear_ready,dut_clear_done,dut_tri_ready,dut_tri_done;
    wire dut_initialized,dut_busy,host_read_ready,host_rsp_valid,host_rsp_error;
    wire [23:0] host_color,host_depth;
    wire [1:0] dut_pixel_writes;

    integer clock_count=0,ref_writes=0,dut_writes=0;
    integer clears=0,draws=0,full_pairs=0,all_pixel_reads=0;
    integer total_full_ref_cycles=0,total_full_dut_cycles=0;
    always @(posedge clk) begin
        clock_count=clock_count+1;
        #1;
        if(rst_n && ref_pixel_wrote) ref_writes=ref_writes+1;
        if(rst_n && dut_pixel_writes[0])dut_writes=dut_writes+1;
        if(rst_n && dut_pixel_writes[1])dut_writes=dut_writes+1;
        if(rst_n && dut_pixel_writes==2'b11)full_pairs=full_pairs+1;
    end

    a0_triangle_scissor_depth_blend_p102 #(
        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
    ) reference (
        .clk(clk),.rst_n(rst_n),
        .clear_valid(clear_valid),.clear_ready(ref_clear_ready),
        .clear_color(clear_color),.clear_depth(clear_depth),
        .clear_done(ref_clear_done),
        .tri_valid(tri_valid),.tri_ready(ref_tri_ready),
        .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
        .tri_color(tri_color),.tri_depth(tri_depth),
        .depth_compare_op(2'd0),.depth_write(1'b1),
        .blend_enable(1'b0),.source_alpha(8'd255),
        .scissor_enable(scissor_enable),.scissor_x(scissor_x),
        .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
        .tri_done(ref_tri_done),.initialized(ref_initialized),
        .busy(ref_busy),.pixel_wrote(ref_pixel_wrote),
        .read_x(ref_read_x),.read_y(ref_read_y),
        .read_valid(ref_read_valid),.read_color(ref_color),
        .read_depth(ref_depth)
    );
    a0_p142_dual_opaque_raster_bram #(
        .FRAME_WIDTH(FRAME_WIDTH),.FRAME_HEIGHT(FRAME_HEIGHT)
    ) candidate (
        .clk(clk),.rst_n(rst_n),
        .clear_valid(clear_valid),.clear_ready(dut_clear_ready),
        .clear_color(clear_color),.clear_depth(clear_depth),
        .clear_done(dut_clear_done),
        .tri_valid(tri_valid),.tri_ready(dut_tri_ready),
        .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
        .tri_color(tri_color),.tri_depth(tri_depth),
        .scissor_enable(scissor_enable),.scissor_x(scissor_x),
        .scissor_y(scissor_y),.scissor_w(scissor_w),.scissor_h(scissor_h),
        .tri_done(dut_tri_done),.initialized(dut_initialized),
        .busy(dut_busy),.pixel_writes(dut_pixel_writes),
        .host_read_valid(host_read_valid),.host_read_ready(host_read_ready),
        .host_read_x(host_read_x),.host_read_y(host_read_y),
        .host_rsp_valid(host_rsp_valid),.host_rsp_error(host_rsp_error),
        .host_rsp_color(host_color),.host_rsp_depth(host_depth)
    );

    task automatic read_one(input integer x,y);
        begin
            @(negedge clk);
            if(!host_read_ready) $fatal(1,"P142 debug host not ready");
            host_read_valid=1;
            host_read_x=16'(x);host_read_y=16'(y);
            ref_read_x=16'(x);ref_read_y=16'(y);
            @(posedge clk);
            #2;
            if(!host_rsp_valid)
                $fatal(1,"P142 missing registered host response (%0d,%0d)",x,y);
            if(x<FRAME_WIDTH && y<FRAME_HEIGHT) begin
                if(!ref_read_valid || host_rsp_error ||
                   ref_color !== host_color || ref_depth !== host_depth)
                    $fatal(1,"P142 framebuffer mismatch (%0d,%0d) ref=%h/%h BRAM=%h/%h err=%b",
                      x,y,ref_color,ref_depth,host_color,host_depth,host_rsp_error);
                all_pixel_reads=all_pixel_reads+1;
            end else if(ref_read_valid || !host_rsp_error ||
                        host_color!==24'd0 || host_depth!==24'd0)
                $fatal(1,"P142 out of bounds response failed (%0d,%0d)",x,y);
            @(negedge clk);
            host_read_valid=0;
        end
    endtask

    task automatic compare_frame;
        begin
            if(!dut_initialized || !ref_initialized)
                $fatal(1,"P142 attempted read before clear");
            for(integer y=0;y<FRAME_HEIGHT;y=y+1)
                for(integer x=0;x<FRAME_WIDTH;x=x+1)
                    read_one(x,y);
            read_one(FRAME_WIDTH,0);
            read_one(0,FRAME_HEIGHT);
        end
    endtask

    task automatic clear_both(input reg [23:0] rgb,z);
        reg [1:0] done_seen;
        begin
            @(negedge clk);
            if(!dut_clear_ready || !ref_clear_ready)
                $fatal(1,"P142 clear launch not ready");
            clear_color=rgb;clear_depth=z;clear_valid=1;
            @(negedge clk);clear_valid=0;
            done_seen={ref_clear_done,dut_clear_done};
            for(integer t=0;t<PIXELS*5+32 && done_seen!==2'b11;t=t+1)begin
                @(negedge clk);
                if(ref_clear_done)done_seen[1]=1;
                if(dut_clear_done)done_seen[0]=1;
            end
            if(done_seen!==2'b11) $fatal(1,"P142 clear completion timeout");
            clears=clears+1;
            compare_frame();
        end
    endtask

    task automatic draw_both(input integer expected_full);
        reg [1:0] seen;
        integer start_clock,ref_cycles,dut_cycles;
        integer writes_r0,writes_d0;
        begin
            @(negedge clk);
            if(!ref_tri_ready || !dut_tri_ready)
                $fatal(1,"P142 draw launch not ready");
            writes_r0=ref_writes;
            writes_d0=dut_writes;
            tri_valid=1;
            @(negedge clk);tri_valid=0;
            // Mutating external vertices and color after accepted command
            // must not affect either of the two independent raster engines.
            x0=16'sh7fff;y0=16'sh8000;
            x1=-16'sd3;y1=16'sd8;x2=16'sd15;y2=-16'sd5;
            tri_color=24'hfedcba;tri_depth=24'h000001;
            start_clock=clock_count;
            ref_cycles=-1;dut_cycles=-1;
            seen={ref_tri_done,dut_tri_done};
            if(seen[0])dut_cycles=0;
            if(seen[1])ref_cycles=0;
            for(integer t=0;t<PIXELS*5+32 && seen!==2'b11;t=t+1)begin
                @(negedge clk);
                if(dut_tri_done && !seen[0]) begin
                    seen[0]=1;dut_cycles=clock_count-start_clock;
                end
                if(ref_tri_done && !seen[1]) begin
                    seen[1]=1;ref_cycles=clock_count-start_clock;
                end
            end
            if(seen!==2'b11)
                $fatal(1,"P142 triangle completion timeout");
            compare_frame();
            if(ref_writes-writes_r0 !== dut_writes-writes_d0)
                $fatal(1,"P142 write count ref=%0d candidate=%0d",
                    ref_writes-writes_r0,dut_writes-writes_d0);
            if(expected_full)begin
                if(ref_writes-writes_r0!==PIXELS ||
                   ref_cycles!==PIXELS || dut_cycles!==(PIXELS+1)/2)
                    $fatal(1,"P142 failed non-vacuous 2-pixel throughput ref_cycles=%0d dut_cycles=%0d writes=%0d pixels=%0d",
                        ref_cycles,dut_cycles,dut_writes-writes_d0,PIXELS);
                total_full_ref_cycles=total_full_ref_cycles+ref_cycles;
                total_full_dut_cycles=total_full_dut_cycles+dut_cycles;
            end
            draws=draws+1;
            $display("P142_DRAW_METRIC_PASS shape=%0dx%0d ref_cycles=%0d dual_cycles=%0d writes=%0d full=%0d",
                FRAME_WIDTH,FRAME_HEIGHT,ref_cycles,dut_cycles,dut_writes-writes_d0,expected_full);
        end
    endtask

    initial begin
        repeat(4)@(negedge clk);
        rst_n=1;
        clear_both(24'h102030,24'hffffff);

        // Fully covered opaque triangle and reversed winding.
        x0=-16'sd16;y0=-16'sd16;
        x1=16'sd256;y1=-16'sd16;
        x2=-16'sd16;y2=16'sd256;
        tri_color=24'h1949a7;tri_depth=24'h000080;
        draw_both(1);
        x0=-16'sd16;y0=-16'sd16;
        x1=-16'sd16;y1=16'sd256;
        x2=16'sd256;y2=-16'sd16;
        tri_color=24'hd1430f;tri_depth=24'h000060;
        draw_both(1);

        // An actual partial triangle must not spill pixels into other banks.
        x0=16'sd0;y0=16'sd0;
        x1=16'(FRAME_WIDTH-1);y1=16'sd0;
        x2=16'sd0;y2=16'(FRAME_HEIGHT-1);
        tri_color=24'h70a010;tri_depth=24'h000040;
        draw_both(0);

        // Scissor reduces active pixels; both lanes can independently skip.
        x0=-16'sd16;y0=-16'sd16;
        x1=16'sd256;y1=-16'sd16;
        x2=-16'sd16;y2=16'sd256;
        scissor_enable=1;scissor_x=1;scissor_y=1;
        scissor_w=16'(FRAME_WIDTH-1);scissor_h=16'(FRAME_HEIGHT-1);
        tri_color=24'h21aa77;tri_depth=24'h000030;
        draw_both(0);

        // Degenerate triangle must signal completion without writes.
        scissor_enable=0;
        x0=0;y0=0;x1=0;y1=0;x2=0;y2=0;
        draw_both(0);

        // Reset while running; next clear must restore exact reference.
        @(negedge clk);
        if(!dut_tri_ready || !ref_tri_ready)
            $fatal(1,"P142 pre-reset launch not ready");
        x0=-16'sd16;y0=-16'sd16;
        x1=16'sd256;y1=-16'sd16;
        x2=-16'sd16;y2=16'sd256;tri_valid=1;
        @(negedge clk);tri_valid=0;
        repeat(3)@(negedge clk);
        rst_n=0;
        repeat(4)@(negedge clk);
        if(dut_initialized || ref_initialized || dut_busy || ref_busy)
            $fatal(1,"P142 reset left renderer initialized or busy");
        rst_n=1;
        clear_both(24'h010203,24'hffffff);
        x0=-16'sd16;y0=-16'sd16;
        x1=16'sd256;y1=-16'sd16;
        x2=-16'sd16;y2=16'sd256;
        tri_color=24'h89abce;tri_depth=24'h000018;
        draw_both(1);
        if(clears!=2 || draws!=6 ||
           all_pixel_reads<8*PIXELS || full_pairs<3 ||
           total_full_ref_cycles!=3*PIXELS ||
           total_full_dut_cycles!=3*((PIXELS+1)/2))
            $fatal(1,"P142 insufficient real dual-pixel coverage");
        $display("P142_DUAL_OPAQUE_FRAME_PASS shape=%0dx%0d drawn=%0d dual_write_cycles=%0d full_original_cycles=%0d full_dual_cycles=%0d comparisons=%0d",
            FRAME_WIDTH,FRAME_HEIGHT,draws,full_pairs,
            total_full_ref_cycles,total_full_dut_cycles,all_pixel_reads);
        $finish;
    end
    initial begin #8000000;$fatal(1,"P142 RTL watchdog");end
endmodule
