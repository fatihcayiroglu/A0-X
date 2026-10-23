`timescale 1ns/1ps
// P42 EXPERIMENTAL on-chip dual-port RGB888 framebuffer.
// One synchronous read port (one clock latency) and one write/clear port.
// Contents are UNDEFINED until a complete clear. Never reset the RAM array.
// The display top selects a DIFFERENT bank for scanout and for rendering.
module a0_sync_frame_ram_p42 #(
    parameter int PIXELS = 64,
    parameter int ADDR_BITS = (PIXELS <= 1 ? 1 : $clog2(PIXELS))
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear_valid,
    output logic clear_ready,
    input  logic [23:0] clear_color,
    output logic clear_done,
    output logic busy,
    output logic initialized,
    input  logic write_valid,
    output logic write_ready,
    input  logic [ADDR_BITS-1:0] write_addr,
    input  logic [23:0] write_color,
    input  logic read_en,
    input  logic [ADDR_BITS-1:0] read_addr,
    output logic read_valid,
    output logic [23:0] read_data
);
    logic [23:0] mem [0:PIXELS-1];
    logic clearing;
    logic [ADDR_BITS-1:0] clear_addr;
    logic [23:0] clear_color_q;

    assign clear_ready = rst_n && !clearing;
    assign write_ready = rst_n && initialized && !clearing && !clear_valid;
    assign busy = clearing;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            clearing <= 1'b0;
            clear_addr <= '0;
            clear_color_q <= '0;
            clear_done <= 1'b0;
            initialized <= 1'b0;
            read_data <= '0;
            read_valid <= 1'b0;
        end else begin
            clear_done <= 1'b0;
            // Registered BRAM read, one request per cycle when enabled.
            read_valid <= read_en && initialized && (int'(read_addr) < PIXELS);
            if (read_en && initialized && (int'(read_addr) < PIXELS))
                read_data <= mem[read_addr];

            if (clearing) begin
                mem[clear_addr] <= clear_color_q;
                if (int'(clear_addr) == PIXELS - 1) begin
                    clearing <= 1'b0;
                    clear_addr <= '0;
                    initialized <= 1'b1;
                    clear_done <= 1'b1;
                end else begin
                    clear_addr <= clear_addr + 1'b1;
                end
            end else if (clear_valid && clear_ready) begin
                clearing <= 1'b1;
                clear_addr <= '0;
                clear_color_q <= clear_color;
                initialized <= 1'b0;
            end else if (write_valid && write_ready && (int'(write_addr) < PIXELS)) begin
                mem[write_addr] <= write_color;
            end
        end
    end

    initial begin
        if (PIXELS < 1 || PIXELS > 65536 || ADDR_BITS < 1 ||
            ((64'd1 << ADDR_BITS) < 64'(PIXELS)))
            $fatal(1, "P42 unsupported RAM geometry");
    end
endmodule
