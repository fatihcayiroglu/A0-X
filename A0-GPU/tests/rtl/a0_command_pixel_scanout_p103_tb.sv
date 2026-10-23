`timescale 1ns/1ps
module a0_command_pixel_scanout_p103_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0;
    logic cmd_valid=0,cmd_ready;
    logic [1:0] cmd_opcode=0;
    logic [15:0] cmd_tag=0;
    logic [23:0] cmd_color=0,cmd_depth=24'hffffff;
    logic signed [15:0] cmd_x0=0,cmd_y0=0,cmd_x1=4,cmd_y1=0,cmd_x2=0,cmd_y2=4;
    logic [1:0] cmd_depth_op=1;
    logic cmd_depth_write=1,cmd_blend_enable=0;
    logic [7:0] cmd_alpha=255;
    logic cmd_scissor_enable=0;
    logic [15:0] cmd_scissor_x=0,cmd_scissor_y=0,cmd_scissor_w=0,cmd_scissor_h=0;
    logic completion_valid,completion_ready=0,completion_error,command_busy;
    logic [15:0] completion_tag;
    logic scan_enable=1,pixel_valid,pixel_ready=1;
    logic [15:0] pixel_x,pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame,end_of_line,end_of_frame,frame_done;
    logic render_initialized,render_busy,present_active;
    a0_command_pixel_scanout_p103 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut(.*);

    task automatic send(input logic [1:0] opcode,input logic [15:0] tag,
                        input logic [23:0] color,dep);
        int n;
        begin
            @(negedge clk);
            for(n=0; !cmd_ready && n<100; n++) @(negedge clk);
            if(!cmd_ready) $fatal(1,"P103 cmd_ready timeout");
            cmd_opcode=opcode;cmd_tag=tag;cmd_color=color;cmd_depth=dep;
            cmd_valid=1;
            @(negedge clk);cmd_valid=0;
        end
    endtask
    task automatic response(input logic [15:0] tag,input logic expected_error);
        int n;
        begin
            for(n=0;!completion_valid && n<200;n++) @(negedge clk);
            if(!completion_valid) $fatal(1,"P103 completion timeout tag=%0d",tag);
            if(completion_tag !== tag || completion_error !== expected_error)
                $fatal(1,"P103 response tag=%0d error=%b expected=%0d/%b",completion_tag,completion_error,tag,expected_error);
            completion_ready=1;
            @(negedge clk);completion_ready=0;
            if(completion_valid) $fatal(1,"P103 response must retire after acceptance");
        end
    endtask
    task automatic capture(input logic [23:0] clear_rgb,input logic combined);
        int n,guard;
        logic [23:0] expected;
        begin
            // An accepted PRESENT must emit exactly one complete frame even
            // after externally deasserting scan_enable, and must hold the first
            // pixel stable during downstream backpressure.
            pixel_ready=0;
            send(2,16'd20,0,0);
            for(guard=0;!present_active && guard<30;guard++) @(negedge clk);
            if(!present_active) $fatal(1,"P103 present was never accepted");
            scan_enable=0;  // dropping permission after acceptance cannot cancel frame
            for(guard=0;!pixel_valid && guard<100;guard++) @(negedge clk);
            if(!pixel_valid) $fatal(1,"P103 present did not begin");
            if(pixel_x !== 0 || pixel_y !== 0 || !start_of_frame)
                $fatal(1,"P103 incorrect first pixel");
            for(guard=0;guard<5;guard++) begin
                @(negedge clk);
                if(!pixel_valid || pixel_x !== 0 || pixel_y !== 0 || !start_of_frame)
                    $fatal(1,"P103 first beat changed while blocked");
            end
            pixel_ready=1;
            n=0;
            for(guard=0;guard<200 && n<16;guard++) begin
                if(pixel_valid) begin
                    if(pixel_x !== (n%4) || pixel_y !== (n/4))
                        $fatal(1,"P103 pixel order got %0d/%0d at index %0d",pixel_x,pixel_y,n);
                    expected=clear_rgb;
                    if(combined) begin
                        if((n%4)+(n/4)<=2) expected=24'hff0000;
                        if(n==5) expected=24'h7f8000;
                    end
                    if(pixel_color !== expected)
                        $fatal(1,"P103 pixel idx=%0d actual=%h expected=%h",n,pixel_color,expected);
                    if(start_of_frame !== (n==0) ||
                       end_of_line !== ((n%4)==3) || end_of_frame !== (n==15))
                        $fatal(1,"P103 scan flags idx=%0d",n);
                    n=n+1;
                end
                @(negedge clk);
            end
            if(n!=16 || !frame_done) $fatal(1,"P103 frame completion failed count=%0d",n);
            response(16'd20,0);
            for(guard=0;guard<12;guard++) begin
                @(negedge clk);
                if(pixel_valid) $fatal(1,"P103 emitted unrequested second frame");
            end
            scan_enable=1;
        end
    endtask
    initial begin
        #300000;
        $fatal(1,"P103 global watchdog");
    end
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        if(render_initialized || pixel_valid) $fatal(1,"P103 uninitialized state");
        send(2,16'd1,0,0);response(16'd1,1);
        send(3,16'd2,0,0);response(16'd2,1);
        send(0,16'd3,24'h000000,24'hffffff);response(16'd3,0);
        if(!render_initialized) $fatal(1,"P103 clear failed");
        cmd_depth_op=1;cmd_depth_write=1;
        send(1,16'd4,24'hff0000,24'h000400);
        // Deliberately mutate all exposed pins after acceptance. The backend
        // must render the accepted command, not the live host pins.
        cmd_depth=24'hfffffe;cmd_color=24'h0000ff;
        response(16'd4,0);
        cmd_blend_enable=1;cmd_alpha=128;cmd_scissor_enable=1;
        cmd_scissor_x=1;cmd_scissor_y=1;cmd_scissor_w=2;cmd_scissor_h=2;
        send(1,16'd5,24'h00ff00,24'h000200);
        cmd_depth_op=3;cmd_blend_enable=0;cmd_scissor_enable=0;
        response(16'd5,0);
        capture(24'h000000,1);
        send(0,16'd6,24'h123456,24'hffffff);response(16'd6,0);
        capture(24'h123456,0);
        @(negedge clk);rst_n=0;
        repeat(2) @(negedge clk);
        if(render_initialized || pixel_valid || completion_valid)
            $fatal(1,"P103 reset did not invalidate image");
        rst_n=1;
        send(1,16'd7,24'habcdef,24'h000100);response(16'd7,1);
        $display("P103_REAL_RTL_PASS");
        $finish;
    end
endmodule
