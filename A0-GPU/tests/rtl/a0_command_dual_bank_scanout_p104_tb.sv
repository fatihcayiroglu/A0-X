`timescale 1ns/1ps
module a0_command_dual_bank_scanout_p104_tb;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,cmd_valid=0,cmd_ready;
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
    logic scan_enable=1,pixel_valid,pixel_ready=0;
    logic [15:0] pixel_x,pixel_y;
    logic [23:0] pixel_color;
    logic start_of_frame,end_of_line,end_of_frame,frame_done;
    logic render_initialized,render_busy,display_initialized,display_bank,render_bank;
    logic swap_pending,scan_active;
    a0_command_dual_bank_scanout_p104 #(.FRAME_WIDTH(4),.FRAME_HEIGHT(4)) dut(.*);

    task automatic send(input logic [1:0] opcode,input logic [15:0] tag,
                        input logic [23:0] color,depth);
        int i;
        begin
            @(negedge clk);
            for(i=0;!cmd_ready && i<300;i++) @(negedge clk);
            if(!cmd_ready) $fatal(1,"P104 cmd_ready timeout %0d",tag);
            cmd_opcode=opcode;cmd_tag=tag;cmd_color=color;cmd_depth=depth;
            cmd_valid=1;
            @(negedge clk);cmd_valid=0;
        end
    endtask
    task automatic retire(input logic [15:0] tag,input logic err);
        int i;
        begin
            for(i=0;!completion_valid && i<500;i++) @(negedge clk);
            if(!completion_valid) $fatal(1,"P104 completion timeout %0d",tag);
            if(completion_tag!==tag || completion_error!==err)
                $fatal(1,"P104 tag/error wrong: got %0d/%b want %0d/%b",
                       completion_tag,completion_error,tag,err);
            completion_ready=1;
            @(negedge clk);completion_ready=0;
        end
    endtask
    task automatic capture(input logic [23:0] expected_color);
        int i,cycles;
        begin
            pixel_ready=1;
            i=0;
            for(cycles=0;cycles<400 && i<16;cycles++) begin
                if(pixel_valid) begin
                    if(pixel_x!==(i%4) || pixel_y!==(i/4) || pixel_color!==expected_color)
                        $fatal(1,"P104 frame idx=%0d got x%0d y%0d c%h expected %h",
                               i,pixel_x,pixel_y,pixel_color,expected_color);
                    if(start_of_frame !== (i==0) ||
                       end_of_line !== ((i%4)==3) || end_of_frame !== (i==15))
                        $fatal(1,"P104 flags wrong pixel=%0d",i);
                    i=i+1;
                end
                @(negedge clk);
            end
            if(i!=16 || !frame_done) $fatal(1,"P104 incomplete frame count=%0d",i);
            pixel_ready=0;
        end
    endtask
    initial begin #300000; $fatal(1,"P104 global watchdog"); end
    initial begin
        int i;
        repeat(3) @(negedge clk);rst_n=1;
        if(display_initialized || render_initialized || pixel_valid)
            $fatal(1,"P104 reset initialization failed");
        send(2,1,0,0);retire(1,1); // no clear before first present
        send(0,2,24'h112233,24'hffffff);retire(2,0);
        if(!render_initialized || display_initialized || render_bank!==1'b1)
            $fatal(1,"P104 initial back bank invalid");
        send(2,3,0,0);retire(3,0); // PRESENT retires at swap, NOT scan end
        if(!scan_active || display_bank!==1'b1 || render_bank!==1'b0)
            $fatal(1,"P104 first swap did not activate front scan");
        // Ready stays low; front bank must be held stable while back clears.
        for(i=0;!pixel_valid && i<30;i++) @(negedge clk);
        if(!pixel_valid || pixel_color!==24'h112233) $fatal(1,"P104 front pixel not offered");
        send(0,4,24'h445566,24'hffffff);retire(4,0);
        for(i=0;i<8;i++) begin
            @(negedge clk);
            if(!pixel_valid || pixel_x!==0 || pixel_y!==0 ||
               pixel_color!==24'h112233 || !start_of_frame)
                $fatal(1,"P104 torn front during blocked scan");
        end
        // Pending PRESENT may be accepted but cannot flip banks until
        // the previous frame's last pixel has been accepted.
        send(2,5,0,0);
        for(i=0;!swap_pending && i<30;i++) @(negedge clk);
        if(!swap_pending) $fatal(1,"P104 second PRESENT not pending");
        scan_enable=0; // Permission withdrawn AFTER acceptance must not abort the queued frame.
        for(i=0;i<8;i++) begin
            @(negedge clk);
            if(display_bank!==1'b1 || completion_valid)
                $fatal(1,"P104 early bank flip/completion under backpressure");
        end
        capture(24'h112233);
        retire(5,0);
        if(display_bank!==1'b0) $fatal(1,"P104 second flip did not commit");
        capture(24'h445566);
        repeat(5) @(negedge clk);
        if(pixel_valid || scan_active) $fatal(1,"P104 emitted extra unsolicited frame");
        // A reset invalidates both buffer ownership and any outstanding frame.
        rst_n=0;repeat(2) @(negedge clk);
        if(display_initialized || render_initialized || scan_active || pixel_valid)
            $fatal(1,"P104 reset leaves stale image");
        rst_n=1;
        send(1,6,24'habcdef,24'h100);retire(6,1);
        $display("P104_REAL_RTL_PASS");
        $finish;
    end
endmodule
