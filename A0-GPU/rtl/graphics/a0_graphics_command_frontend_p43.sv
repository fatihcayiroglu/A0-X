`timescale 1ns/1ps
// P43 EXPERIMENTAL serialized graphics command frontend.
// No PCIe/host DMA/shader ISA or queue; one command may be in flight.
// Opcode 00 CLEAR back bank; 01 TRIANGLE; 10 PRESENT; 11 INVALID.
// Every accepted command yields exactly one tagged completion unless reset.
module a0_graphics_command_frontend_p43 #(
    parameter int TAG_BITS = 16
) (
    input  logic clk, rst_n,
    input  logic render_initialized,
    input  logic cmd_valid,
    output logic cmd_ready,
    input  logic [1:0] cmd_opcode,
    input  logic [TAG_BITS-1:0] cmd_tag,
    input  logic [23:0] cmd_color,
    input  logic signed [15:0] cmd_x0, cmd_y0, cmd_x1, cmd_y1, cmd_x2, cmd_y2,
    output logic completion_valid,
    input  logic completion_ready,
    output logic [TAG_BITS-1:0] completion_tag,
    output logic completion_error,
    output logic busy,
    output logic clear_valid,
    input  logic clear_ready, clear_done,
    output logic [23:0] clear_color,
    output logic tri_valid,
    input  logic tri_ready, tri_done,
    output logic signed [15:0] x0, y0, x1, y1, x2, y2,
    output logic [23:0] tri_color,
    output logic swap_valid,
    input  logic swap_ready, swap_done
);
    localparam logic [1:0] CMD_CLEAR=2'd0, CMD_TRI=2'd1, CMD_PRESENT=2'd2;
    typedef enum logic [1:0] {IDLE, OFFER, WAIT_DONE, RESPONSE} state_t;
    state_t state;
    logic [1:0] opcode_q;
    logic [TAG_BITS-1:0] tag_q;
    logic [23:0] color_q;
    logic signed [15:0] x0_q, y0_q, x1_q, y1_q, x2_q, y2_q;
    logic error_q, operation_accepted, operation_done;

    assign cmd_ready = rst_n && (state == IDLE);
    assign busy = rst_n && (state != IDLE);
    assign completion_valid = rst_n && (state == RESPONSE);
    assign completion_tag = tag_q;
    assign completion_error = error_q;
    assign clear_valid = rst_n && (state == OFFER) && (opcode_q == CMD_CLEAR);
    assign tri_valid = rst_n && (state == OFFER) && (opcode_q == CMD_TRI);
    assign swap_valid = rst_n && (state == OFFER) && (opcode_q == CMD_PRESENT);
    assign operation_accepted = (clear_valid && clear_ready) ||
                                (tri_valid && tri_ready) ||
                                (swap_valid && swap_ready);
    assign operation_done = ((opcode_q == CMD_CLEAR) && clear_done) ||
                            ((opcode_q == CMD_TRI) && tri_done) ||
                            ((opcode_q == CMD_PRESENT) && swap_done);
    assign clear_color = color_q;
    assign tri_color = color_q;
    assign x0=x0_q; assign y0=y0_q; assign x1=x1_q;
    assign y1=y1_q; assign x2=x2_q; assign y2=y2_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= IDLE;
            opcode_q <= '0;
            tag_q <= '0;
            color_q <= '0;
            x0_q <= '0; y0_q <= '0;
            x1_q <= '0; y1_q <= '0;
            x2_q <= '0; y2_q <= '0;
            error_q <= 1'b0;
        end else begin
            case (state)
                IDLE: if (cmd_valid && cmd_ready) begin
                    opcode_q <= cmd_opcode;
                    tag_q <= cmd_tag;
                    color_q <= cmd_color;
                    x0_q <= cmd_x0; y0_q <= cmd_y0;
                    x1_q <= cmd_x1; y1_q <= cmd_y1;
                    x2_q <= cmd_x2; y2_q <= cmd_y2;
                    // Reject commands which would otherwise wait forever for
                    // an uninitialized render bank. CLEAR is the bootstrap.
                    error_q <= (cmd_opcode == 2'b11) ||
                               ((cmd_opcode != CMD_CLEAR) && !render_initialized);
                    state <= ((cmd_opcode == 2'b11) ||
                              ((cmd_opcode != CMD_CLEAR) && !render_initialized))
                             ? RESPONSE : OFFER;
                end
                OFFER: if (operation_accepted) state <= WAIT_DONE;
                WAIT_DONE: if (operation_done) begin
                    error_q <= 1'b0;
                    state <= RESPONSE;
                end
                RESPONSE: if (completion_valid && completion_ready)
                    state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
    initial begin
        if (TAG_BITS < 1) $fatal(1,"P43 TAG_BITS must be positive");
    end
endmodule
