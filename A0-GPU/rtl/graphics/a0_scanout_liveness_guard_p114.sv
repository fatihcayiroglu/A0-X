`timescale 1ns/1ps
// P114 EXPERIMENTAL, passive scanout-liveness guard.
// P104 PRESENT completion acknowledges bank swap, NOT the final pixel.
// Therefore observe scan_active independently of the command-completion monitor.
// No effect on pixel valid/ready, command completion or frame buffer contents.
module a0_scanout_liveness_guard_p114 #(
    parameter int FRAME_WIDTH=8,
    parameter int FRAME_HEIGHT=8,
    parameter int MAX_NO_PROGRESS_CYCLES=4096,
    parameter int MAX_FRAME_DONE_DELAY=4
)(
    input logic clk,rst_n,
    input logic scan_active,
    input logic pixel_valid,pixel_ready,
    input logic [15:0] pixel_x,pixel_y,
    input logic [23:0] pixel_color,
    input logic start_of_frame,end_of_line,end_of_frame,
    input logic frame_done,
    output logic fault_sticky,pending,
    output logic [31:0] timeout_count,protocol_fault_count,
    output logic [31:0] completed_frames,accepted_pixels,stalled_cycles,
    output logic [15:0] last_fault_x,last_fault_y
);
    localparam int PIXELS=FRAME_WIDTH*FRAME_HEIGHT;
    typedef enum logic [1:0] {IDLE,STREAM,WAIT_FRAME_DONE,FAULT} state_t;
    state_t state_q;
    logic [31:0] index_q,no_progress_q,done_delay_q;
    logic stalled_q;
    logic [15:0] held_x_q,held_y_q;
    logic [23:0] held_color_q;
    logic held_sof_q,held_eol_q,held_eof_q;
    wire beat_accepted=pixel_valid && pixel_ready;
    wire beat_stalled=pixel_valid && !pixel_ready;
    wire held_changed=(pixel_x!=held_x_q || pixel_y!=held_y_q ||
                       pixel_color!=held_color_q ||
                       start_of_frame!=held_sof_q ||
                       end_of_line!=held_eol_q ||
                       end_of_frame!=held_eof_q);
    wire coordinate_error=(pixel_x!=16'(index_q%FRAME_WIDTH) ||
                           pixel_y!=16'(index_q/FRAME_WIDTH) ||
                           start_of_frame!=(index_q==0) ||
                           end_of_line!=((index_q%FRAME_WIDTH)==FRAME_WIDTH-1) ||
                           end_of_frame!=(index_q==PIXELS-1));
    assign fault_sticky=(state_q==FAULT);
    assign pending=(state_q==STREAM || state_q==WAIT_FRAME_DONE);
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state_q<=IDLE;
            index_q<='0;no_progress_q<='0;done_delay_q<='0;
            stalled_q<=1'b0;
            held_x_q<='0;held_y_q<='0;held_color_q<='0;
            held_sof_q<=1'b0;held_eol_q<=1'b0;held_eof_q<=1'b0;
            timeout_count<='0;protocol_fault_count<='0;
            completed_frames<='0;accepted_pixels<='0;stalled_cycles<='0;
            last_fault_x<='0;last_fault_y<='0;
        end else begin
            case(state_q)
                IDLE: begin
                    // A spurious EOF or accepted pixel outside the frame is
                    // a protocol fault. A valid but stalled pixel is also
                    // impossible outside a permitted scanout.
                    if(frame_done || pixel_valid) begin
                        state_q<=FAULT;
                        last_fault_x<=pixel_x;last_fault_y<=pixel_y;
                        if(protocol_fault_count!=32'hffffffff)
                            protocol_fault_count<=protocol_fault_count+1'b1;
                    end else if(scan_active) begin
                        state_q<=STREAM;
                        index_q<='0;no_progress_q<='0;done_delay_q<='0;
                        stalled_q<=1'b0;
                    end
                end
                STREAM: begin
                    if(!scan_active || frame_done ||
                       (stalled_q && (!pixel_valid || held_changed))) begin
                        state_q<=FAULT;
                        last_fault_x<=pixel_x;last_fault_y<=pixel_y;
                        if(protocol_fault_count!=32'hffffffff)
                            protocol_fault_count<=protocol_fault_count+1'b1;
                    end else if(beat_accepted) begin
                        if(coordinate_error) begin
                            state_q<=FAULT;
                            last_fault_x<=pixel_x;last_fault_y<=pixel_y;
                            if(protocol_fault_count!=32'hffffffff)
                                protocol_fault_count<=protocol_fault_count+1'b1;
                        end else begin
                            if(accepted_pixels!=32'hffffffff)
                                accepted_pixels<=accepted_pixels+1'b1;
                            stalled_q<=1'b0;
                            no_progress_q<='0;
                            if(index_q==PIXELS-1) begin
                                state_q<=WAIT_FRAME_DONE;
                                done_delay_q<='0;
                            end else index_q<=index_q+1'b1;
                        end
                    end else if(beat_stalled) begin
                        // This is external sink backpressure. Track stability
                        // and freeze the no-progress watchdog, even for long
                        // stalls. A changed payload or dropped valid faults.
                        if(!stalled_q) begin
                            held_x_q<=pixel_x;held_y_q<=pixel_y;
                            held_color_q<=pixel_color;
                            held_sof_q<=start_of_frame;
                            held_eol_q<=end_of_line;
                            held_eof_q<=end_of_frame;
                        end
                        stalled_q<=1'b1;
                        if(stalled_cycles!=32'hffffffff)
                            stalled_cycles<=stalled_cycles+1'b1;
                    end else if(no_progress_q>=MAX_NO_PROGRESS_CYCLES-1) begin
                        state_q<=FAULT;
                        last_fault_x<=16'(index_q%FRAME_WIDTH);
                        last_fault_y<=16'(index_q/FRAME_WIDTH);
                        if(timeout_count!=32'hffffffff)
                            timeout_count<=timeout_count+1'b1;
                    end else no_progress_q<=no_progress_q+1'b1;
                end
                WAIT_FRAME_DONE: begin
                    // P42 frame_done is a registered pulse AFTER the final
                    // accepted beat. Do not require it in the pixel cycle.
                    if(!scan_active || pixel_valid) begin
                        state_q<=FAULT;
                        last_fault_x<=pixel_x;last_fault_y<=pixel_y;
                        if(protocol_fault_count!=32'hffffffff)
                            protocol_fault_count<=protocol_fault_count+1'b1;
                    end else if(frame_done) begin
                        state_q<=IDLE;
                        if(completed_frames!=32'hffffffff)
                            completed_frames<=completed_frames+1'b1;
                    end else if(done_delay_q>=MAX_FRAME_DONE_DELAY-1) begin
                        state_q<=FAULT;
                        last_fault_x<=16'(FRAME_WIDTH-1);
                        last_fault_y<=16'(FRAME_HEIGHT-1);
                        if(timeout_count!=32'hffffffff)
                            timeout_count<=timeout_count+1'b1;
                    end else done_delay_q<=done_delay_q+1'b1;
                end
                FAULT: begin end // Sticky until reset. Never replay a frame.
                default: state_q<=FAULT;
            endcase
        end
    end
    initial begin
        if(FRAME_WIDTH<1 || FRAME_HEIGHT<1 || FRAME_WIDTH>32767 ||
           FRAME_HEIGHT>32767 || PIXELS>65536 ||
           MAX_NO_PROGRESS_CYCLES<1 || MAX_NO_PROGRESS_CYCLES>32'h7fffffff ||
           MAX_FRAME_DONE_DELAY<1 || MAX_FRAME_DONE_DELAY>32'h7fffffff)
            $fatal(1,"P114 invalid frame geometry or watchdog threshold");
    end
endmodule
