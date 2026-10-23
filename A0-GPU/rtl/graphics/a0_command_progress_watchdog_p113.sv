`timescale 1ns/1ps
// P113 research monitor. Only PRESENT (opcode 2'b10) uses progress-aware timing.
// An accepted display pixel is real forward progress; stalled valid pixel with
// !pixel_ready represents external backpressure and does not age the watchdog.
// CLEAR/TRIANGLE/invalid opcodes retain P111's response wait semantics.
// Nonintrusive: this block must never influence the GPU's valid/ready paths.
module a0_command_progress_watchdog_p113 #(
    parameter int MAX_WAIT_CYCLES=4096
)(
    input logic clk,rst_n,
    input logic cmd_valid,cmd_ready,
    input logic [1:0] cmd_opcode,
    input logic [15:0] cmd_tag,
    input logic completion_valid,completion_ready,
    input logic [15:0] completion_tag,
    input logic completion_error,
    input logic pixel_valid,pixel_ready,
    output logic fault_sticky,pending,
    output logic [15:0] active_tag,last_fault_tag,
    output logic [31:0] timeout_count,tag_mismatch_count,
    output logic [31:0] protocol_fault_count,completed_count,
    output logic [31:0] present_pixel_count
);
    typedef enum logic [1:0] {IDLE, WAIT_RESPONSE, HOLD_RESPONSE, FAULT} state_t;
    state_t state_q;
    logic [31:0] wait_cycles_q;
    logic active_present_q,held_error_q;
    wire accepting=cmd_valid && cmd_ready;
    wire responding=completion_valid;
    assign pending=(state_q==WAIT_RESPONSE || state_q==HOLD_RESPONSE);
    assign fault_sticky=(state_q==FAULT);

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state_q<=IDLE;
            wait_cycles_q<='0;
            active_present_q<=1'b0;
            held_error_q<=1'b0;
            active_tag<='0;last_fault_tag<='0;
            timeout_count<='0;tag_mismatch_count<='0;
            protocol_fault_count<='0;completed_count<='0;
            present_pixel_count<='0;
        end else begin
            case(state_q)
                IDLE: begin
                    if(responding) begin
                        state_q<=FAULT;
                        last_fault_tag<=completion_tag;
                        if(protocol_fault_count!=32'hffffffff)
                            protocol_fault_count<=protocol_fault_count+1'b1;
                    end else if(accepting) begin
                        active_tag<=cmd_tag;
                        active_present_q<=(cmd_opcode==2'b10);
                        present_pixel_count<='0;
                        wait_cycles_q<='0;
                        state_q<=WAIT_RESPONSE;
                    end
                end
                WAIT_RESPONSE: begin
                    if(accepting) begin
                        state_q<=FAULT;
                        last_fault_tag<=cmd_tag;
                        if(protocol_fault_count!=32'hffffffff)
                            protocol_fault_count<=protocol_fault_count+1'b1;
                    end else if(responding) begin
                        if(completion_tag!=active_tag) begin
                            state_q<=FAULT;
                            last_fault_tag<=completion_tag;
                            if(tag_mismatch_count!=32'hffffffff)
                                tag_mismatch_count<=tag_mismatch_count+1'b1;
                        end else if(completion_ready) begin
                            state_q<=IDLE;
                            if(completed_count!=32'hffffffff)
                                completed_count<=completed_count+1'b1;
                        end else begin
                            held_error_q<=completion_error;
                            state_q<=HOLD_RESPONSE;
                        end
                    end else if(active_present_q && pixel_valid && pixel_ready) begin
                        wait_cycles_q<='0;
                        if(present_pixel_count!=32'hffffffff)
                            present_pixel_count<=present_pixel_count+1'b1;
                    end else if(active_present_q && pixel_valid && !pixel_ready) begin
                        // The sink owns this stall; indefinite backpressure is
                        // not by itself evidence that the GPU is hung.
                    end else if(wait_cycles_q >= MAX_WAIT_CYCLES-1) begin
                        state_q<=FAULT;
                        last_fault_tag<=active_tag;
                        if(timeout_count!=32'hffffffff)
                            timeout_count<=timeout_count+1'b1;
                    end else begin
                        wait_cycles_q<=wait_cycles_q+1'b1;
                    end
                end
                HOLD_RESPONSE: begin
                    if(accepting || !responding || completion_tag!=active_tag ||
                       completion_error!=held_error_q) begin
                        state_q<=FAULT;
                        last_fault_tag<=active_tag;
                        if(protocol_fault_count!=32'hffffffff)
                            protocol_fault_count<=protocol_fault_count+1'b1;
                    end else if(completion_ready) begin
                        state_q<=IDLE;
                        if(completed_count!=32'hffffffff)
                            completed_count<=completed_count+1'b1;
                    end
                end
                FAULT: begin end // Sticky fault, explicit reset only.
                default: state_q<=FAULT;
            endcase
        end
    end
    initial begin
        if(MAX_WAIT_CYCLES<1 || MAX_WAIT_CYCLES>32'h7fffffff)
            $fatal(1,"P113 MAX_WAIT_CYCLES out of 1..2^31-1");
    end
endmodule
