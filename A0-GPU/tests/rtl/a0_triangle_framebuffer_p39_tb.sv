`timescale 1ns/1ps
// Contract-level P39 RTL testbench. P38 RTL must be compiled in the same build.
module a0_triangle_framebuffer_p39_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic clear_valid = 1'b0, clear_ready, clear_done;
    logic [23:0] clear_color = '0;
    logic tri_valid = 1'b0, tri_ready, tri_done;
    logic signed [15:0] x0='0,y0='0,x1='0,y1='0,x2='0,y2='0;
    logic [23:0] tri_color='0;
    logic [15:0] read_x='0, read_y='0;
    logic [23:0] read_color;
    logic initialized, busy;
    localparam logic [63:0] TRI_A = 64'h0000_0000_0206_0E00;
    localparam logic [63:0] TRI_B = 64'h0040_6070_787C_0000;

    a0_triangle_framebuffer_p39 #(.FRAME_WIDTH(8),.FRAME_HEIGHT(8)) dut(
        .clk(clk),.rst_n(rst_n),.clear_valid(clear_valid),.clear_ready(clear_ready),
        .clear_color(clear_color),.clear_done(clear_done),
        .tri_valid(tri_valid),.tri_ready(tri_ready),
        .x0(x0),.y0(y0),.x1(x1),.y1(y1),.x2(x2),.y2(y2),
        .tri_color(tri_color),.tri_done(tri_done),.read_x(read_x),.read_y(read_y),
        .read_color(read_color),.initialized(initialized),.busy(busy));

    task automatic clear_frame(input logic [23:0] color);
        bit completed;
        begin
            @(negedge clk);
            if (!clear_ready) $fatal(1,"clear not ready");
            clear_color = color;
            clear_valid = 1'b1;
            @(negedge clk);
            clear_valid = 1'b0;
            if (!busy || tri_ready || initialized)
                $fatal(1,"clear not properly blocking commands/reads");
            completed = 0;
            for (int cycles=0;cycles<70;cycles++) begin
                @(posedge clk);
                #1;
                if (clear_done) begin
                    completed = 1;
                    break;
                end
            end
            if (!completed || !initialized || !clear_ready || busy)
                $fatal(1,"clear failed or did not finish");
            @(negedge clk);
        end
    endtask

    task automatic draw_triangle(
       input logic signed [15:0] ax,ay,bx,by,cx,cy,
       input logic [23:0] color
    );
        bit completed;
        begin
            @(negedge clk);
            if (!tri_ready) $fatal(1,"triangle command not ready");
            x0 = ax; y0 = ay;
            x1 = bx; y1 = by;
            x2 = cx; y2 = cy;
            tri_color = color;
            tri_valid = 1'b1;
            @(posedge clk);
            #1;
            completed = tri_done;
            @(negedge clk);
            tri_valid = 1'b0;
            for (int cycles=0;cycles<100 && !completed;cycles++) begin
                @(posedge clk);
                #1;
                if (tri_done) completed=1;
            end
            if (!completed || !tri_ready || busy)
                $fatal(1,"triangle did not finish");
            @(negedge clk);
        end
    endtask

    task automatic check_frame(
       input logic [63:0] first, second,
       input logic [23:0] background, color_a, color_b
    );
        logic [23:0] expected;
        int i;
        begin
            for (int y=0; y<8; y++) begin
                for (int x=0; x<8; x++) begin
                    i = y*8+x;
                    read_x = 16'(x);
                    read_y = 16'(y);
                    #1;
                    expected = second[i] ? color_b : first[i] ? color_a : background;
                    if (read_color !== expected)
                        $fatal(1,"pixel (%0d,%0d)=%h expected=%h",x,y,read_color,expected);
                end
            end
            read_x = 16'd8;
            read_y = 0;
            #1;
            if (read_color !== 24'h0) $fatal(1,"out-of-frame read was not zero");
        end
    endtask

    initial begin
        repeat (2) @(negedge clk);
        read_x=0;
        #1;
        if (initialized || tri_ready || read_color !== 24'h0)
            $fatal(1,"reset state incorrect");
        rst_n=1'b1;
        clear_frame(24'h123456);
        check_frame('0,'0,24'h123456,'0,'0);
        draw_triangle(1,1,5,1,1,5,24'hFF0000);
        check_frame(TRI_A,'0,24'h123456,24'hFF0000,'0);
        draw_triangle(2,2,7,2,7,7,24'h00FF00);
        check_frame(TRI_A,TRI_B,24'h123456,24'hFF0000,24'h00FF00);
        draw_triangle(1,1,2,2,3,3,24'hFFFFFF);
        check_frame(TRI_A,TRI_B,24'h123456,24'hFF0000,24'h00FF00);
        clear_frame(24'h010203);
        check_frame('0,'0,24'h010203,'0,'0);
        $display("P39_RTL_FRAMEBUFFER_PASS clear/draw/overlap/degenerate/read");
        $finish;
    end
    initial begin
        #50000;
        $fatal(1,"P39 simulation timeout");
    end
endmodule
