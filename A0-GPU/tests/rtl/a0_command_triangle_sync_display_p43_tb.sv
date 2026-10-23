`timescale 1ns/1ps
// P43 HDL execution testbench. Parsing does NOT constitute a behavioral PASS.
module a0_command_triangle_sync_display_p43_tb;
    logic clk;
    initial clk=0;
    always #5 clk=~clk;
    logic rst_n=0;
    logic cmd_valid=0,cmd_ready;
    logic [1:0] cmd_opcode=0;
    logic [15:0] cmd_tag=0;
    logic [23:0] cmd_color=0;
    logic signed [15:0] cmd_x0=0,cmd_y0=0,cmd_x1=3,cmd_y1=0,cmd_x2=0,cmd_y2=3;
    logic completion_valid, completion_ready=0;
    logic [15:0] completion_tag;
    logic completion_error,command_busy;
    logic scan_enable=0,pixel_valid,pixel_ready=0;
    logic [15:0] pixel_x,pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame,end_of_line,end_of_frame,frame_done;
    logic display_bank,render_bank,display_initialized,render_initialized,render_busy,swap_pending;

    a0_command_triangle_sync_display_p43 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut (
        .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
        .cmd_opcode(cmd_opcode),.cmd_tag(cmd_tag),.cmd_color(cmd_color),
        .cmd_x0(cmd_x0),.cmd_y0(cmd_y0),.cmd_x1(cmd_x1),.cmd_y1(cmd_y1),
        .cmd_x2(cmd_x2),.cmd_y2(cmd_y2),
        .completion_valid(completion_valid),.completion_ready(completion_ready),
        .completion_tag(completion_tag),.completion_error(completion_error),
        .command_busy(command_busy),.scan_enable(scan_enable),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_x(pixel_x),.pixel_y(pixel_y),.pixel_color(pixel_color),
        .start_of_frame(start_of_frame),.end_of_line(end_of_line),
        .end_of_frame(end_of_frame),.frame_done(frame_done),
        .display_bank(display_bank),.render_bank(render_bank),
        .display_initialized(display_initialized),.render_initialized(render_initialized),
        .render_busy(render_busy),.swap_pending(swap_pending)
    );

    task automatic send(input logic [1:0] opcode, input logic [15:0] tag,
                         input logic [23:0] rgb, input logic expect_error);
        int cycles;
        begin
            @(negedge clk);
            cycles=0;
            while (!cmd_ready && cycles < 400) begin
                @(negedge clk); cycles++;
            end
            if (!cmd_ready) $fatal(1,"P43 host ready timeout");
            cmd_opcode=opcode; cmd_tag=tag; cmd_color=rgb; cmd_valid=1;
            @(negedge clk);
            cmd_valid=0;
            if (cmd_ready || !command_busy) $fatal(1,"P43 did not own accepted command");
            cycles=0;
            while (!completion_valid && cycles < 400) begin
                @(negedge clk); cycles++;
            end
            if (!completion_valid) $fatal(1,"P43 completion timeout opcode=%d",opcode);
            if (completion_tag !== tag || completion_error !== expect_error)
                $fatal(1,"P43 result mismatch opcode=%d tag=%d",opcode,tag);
            // Completion must be stable under five cycles of host backpressure.
            repeat(5) begin
                @(negedge clk);
                if (!completion_valid || completion_tag !== tag ||
                    completion_error !== expect_error || cmd_ready)
                    $fatal(1,"P43 completion changed while stalled");
            end
            completion_ready=1;
            @(negedge clk); completion_ready=0;
            if (!cmd_ready || completion_valid) $fatal(1,"P43 response did not retire");
        end
    endtask

    initial begin : test
        int pixels;
        logic [23:0] expect_color;
        rst_n=0;
        repeat(4) @(negedge clk);
        rst_n=1;
        send(2'd3,16'd90,24'hFFFFFF,1'b1);
        send(2'd2,16'd91,24'h000000,1'b1);
        send(2'd1,16'd92,24'hFF5500,1'b1);
        send(2'd0,16'd1,24'h112233,1'b0);
        send(2'd2,16'd2,24'h000000,1'b0);
        if (display_bank !== 1'b1 || render_bank !== 1'b0 || swap_pending || render_busy)
            $fatal(1,"P43 initial presentation bank ownership broken");
        if (!display_initialized) $fatal(1,"P43 front bank not initialized");
        send(2'd0,16'd3,24'h000000,1'b0);
        if (!render_initialized) $fatal(1,"P43 new back bank uninitialized");
        send(2'd1,16'd4,24'hFF5500,1'b0);
        send(2'd2,16'd5,24'h000000,1'b0);
        scan_enable=1; pixel_ready=1;
        pixels=0;
        for (int t=0; t<180 && pixels<16; t++) begin
            @(negedge clk);
            if (pixel_valid && pixel_ready) begin
                expect_color= ((pixel_x == 0 && pixel_y == 0) ||
                               (pixel_x == 1 && pixel_y == 0) ||
                               (pixel_x == 0 && pixel_y == 1)) ? 24'hFF5500 : 24'h000000;
                if (pixel_color !== expect_color) $fatal(1,"P43 pixel color mismatch at %d,%d",pixel_x,pixel_y);
                if (pixel_x !== 16'(pixels%4) || pixel_y !== 16'(pixels/4))
                    $fatal(1,"P43 pixel order mismatch %d",pixels);
                if (start_of_frame !== (pixels == 0) ||
                    end_of_line !== ((pixels%4)==3) ||
                    end_of_frame !== (pixels==15))
                    $fatal(1,"P43 frame markers wrong at %d",pixels);
                pixels++;
            end
        end
        if (pixels!=16) $fatal(1,"P43 scanout incomplete");
        @(negedge clk);
        if (!frame_done) $fatal(1,"P43 scanout did not signal frame completion");
        $display("P43 HDL COMMAND+TRIANGLE+SCANOUT PASS");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"P43 global timeout");
    end
endmodule
