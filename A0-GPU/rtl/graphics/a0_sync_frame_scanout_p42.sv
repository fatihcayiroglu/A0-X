`timescale 1ns/1ps
// P42 EXPERIMENTAL synchronous-memory scanout. No physical display timing.
// A request launches, a registered RAM response arrives after an edge, and
// the output beat then holds until ready. At most one outstanding read.
module a0_sync_frame_scanout_p42 #(
    parameter int FRAME_WIDTH = 8,
    parameter int FRAME_HEIGHT = 8,
    parameter int PIXELS = FRAME_WIDTH * FRAME_HEIGHT,
    parameter int ADDR_BITS = (PIXELS <= 1 ? 1 : $clog2(PIXELS))
) (
    input logic clk,
    input logic rst_n,
    input logic enable,
    input logic framebuffer_initialized,
    output logic read_en,
    output logic [ADDR_BITS-1:0] read_addr,
    input logic read_valid,
    input logic [23:0] read_data,
    output logic pixel_valid,
    input logic pixel_ready,
    output logic [15:0] pixel_x,
    output logic [15:0] pixel_y,
    output logic [23:0] pixel_color,
    output logic start_of_frame,
    output logic end_of_line,
    output logic end_of_frame,
    output logic frame_done
);
    typedef enum logic [1:0] { ISSUE, WAIT_READ, HOLD } state_t;
    state_t state;
    logic [ADDR_BITS-1:0] cursor;
    logic [15:0] cx, cy;
    logic [15:0] beat_x, beat_y;
    logic [23:0] beat_color;
    logic running;
    logic accepted;

    assign running = rst_n && enable && framebuffer_initialized;
    assign read_en = running && state == ISSUE;
    assign read_addr = cursor;
    assign pixel_valid = running && state == HOLD;
    assign pixel_x = beat_x;
    assign pixel_y = beat_y;
    assign pixel_color = beat_color;
    assign start_of_frame = pixel_valid && (beat_x == 0 && beat_y == 0);
    assign end_of_line = pixel_valid && (int'(beat_x) == FRAME_WIDTH - 1);
    assign end_of_frame = end_of_line && (int'(beat_y) == FRAME_HEIGHT - 1);
    assign accepted = pixel_valid && pixel_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= ISSUE;
            cursor <= '0;
            cx <= '0;
            cy <= '0;
            beat_x <= '0;
            beat_y <= '0;
            beat_color <= '0;
            frame_done <= 1'b0;
        end else begin
            frame_done <= accepted && end_of_frame;
            if (!running) begin
                state <= ISSUE;
                cursor <= '0;
                cx <= '0;
                cy <= '0;
            end else begin
                case (state)
                    ISSUE: state <= WAIT_READ;
                    WAIT_READ: if (read_valid) begin
                        beat_x <= cx;
                        beat_y <= cy;
                        beat_color <= read_data;
                        state <= HOLD;
                    end
                    HOLD: if (accepted) begin
                        state <= ISSUE;
                        if (int'(cx) == FRAME_WIDTH - 1) begin
                            cx <= '0;
                            if (int'(cy) == FRAME_HEIGHT - 1) begin
                                cy <= '0;
                                cursor <= '0;
                            end else begin
                                cy <= cy + 16'd1;
                                cursor <= cursor + 1'b1;
                            end
                        end else begin
                            cx <= cx + 16'd1;
                            cursor <= cursor + 1'b1;
                        end
                    end
                    default: state <= ISSUE;
                endcase
            end
        end
    end

    initial begin
        if (FRAME_WIDTH < 1 || FRAME_HEIGHT < 1 || FRAME_WIDTH > 32767 ||
            FRAME_HEIGHT > 32767 || PIXELS > 65536)
            $fatal(1, "P42 unsupported scanout geometry");
    end
endmodule
