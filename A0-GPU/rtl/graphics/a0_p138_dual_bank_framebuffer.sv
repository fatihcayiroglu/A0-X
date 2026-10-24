`timescale 1ns/1ps
// P138: experimental TWO-BANK 48-bit framebuffer scratchpad.
// Two independent request lanes, exactly one access per bank per clock.
// Address parity chooses bank; conflicts arbitrate lane 0 first, lane 1
// must hold its request until ready. Responses are ONE-cycle registered
// pulses, not backpressured; consumers must capture the pulse.
// 48-bit data is packed {RGB888, DEPTH24}; this is NOT VRAM, not PCIe,
// not integrated in P102, and not a qualified physical dual-port RAM.
module a0_p138_dual_bank_framebuffer #(
    parameter integer FRAME_WIDTH=4,
    parameter integer FRAME_HEIGHT=4,
    parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
    parameter integer ADDR_BITS=PIXELS<=1 ? 1 : $clog2(PIXELS),
    parameter integer BANK_DEPTH=(PIXELS+1)/2
)(
    input  logic clk,
    input  logic rst_n,

    input  logic req0_valid,
    output logic req0_ready,
    input  logic req0_write,
    input  logic [ADDR_BITS-1:0] req0_index,
    input  logic [47:0] req0_wdata,
    output logic rsp0_valid,
    output logic rsp0_error,
    output logic [47:0] rsp0_rdata,

    input  logic req1_valid,
    output logic req1_ready,
    input  logic req1_write,
    input  logic [ADDR_BITS-1:0] req1_index,
    input  logic [47:0] req1_wdata,
    output logic rsp1_valid,
    output logic rsp1_error,
    output logic [47:0] rsp1_rdata
);
    // Valid metadata is reset; data arrays intentionally are not cleared.
    // First read after reset of an unwritten word is deterministic ZERO.
    logic [47:0] bank0 [0:BANK_DEPTH-1];
    logic [47:0] bank1 [0:BANK_DEPTH-1];
    logic [BANK_DEPTH-1:0] valid0,valid1;

    wire index0_ok = (32'(req0_index) < PIXELS);
    wire index1_ok = (32'(req1_index) < PIXELS);
    wire bank0sel = req0_index[0];
    wire bank1sel = req1_index[0];
    wire collision = req0_valid && req1_valid &&
                     index0_ok && index1_ok && (bank0sel == bank1sel);
    assign req0_ready = rst_n;
    assign req1_ready = rst_n && !collision;

    wire fire0 = req0_valid && req0_ready;
    wire fire1 = req1_valid && req1_ready;
    wire [ADDR_BITS-1:0] offset0 = req0_index >> 1;
    wire [ADDR_BITS-1:0] offset1 = req1_index >> 1;

    // One physical write choice per bank. A concurrent access to the other
    // bank is independent. No same-bank simultaneous read/write is accepted.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid0 <= '0;
            valid1 <= '0;
        end else begin
            if (fire0 && index0_ok && req0_write) begin
                if (!bank0sel) begin
                    bank0[offset0] <= req0_wdata;
                    valid0[offset0] <= 1'b1;
                end else begin
                    bank1[offset0] <= req0_wdata;
                    valid1[offset0] <= 1'b1;
                end
            end
            if (fire1 && index1_ok && req1_write) begin
                if (!bank1sel) begin
                    bank0[offset1] <= req1_wdata;
                    valid0[offset1] <= 1'b1;
                end else begin
                    bank1[offset1] <= req1_wdata;
                    valid1[offset1] <= 1'b1;
                end
            end
        end
    end

    // Fixed one-cycle response contract: data and error become valid
    // immediately after the accepting rising edge and are observed in that
    // cycle; the next edge can emit another response without an extra bubble.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rsp0_valid <= 1'b0; rsp0_error <= 1'b0; rsp0_rdata <= '0;
            rsp1_valid <= 1'b0; rsp1_error <= 1'b0; rsp1_rdata <= '0;
        end else begin
            rsp0_valid <= fire0;
            rsp0_error <= fire0 && !index0_ok;
            rsp0_rdata <= '0;
            if (fire0 && index0_ok && !req0_write) begin
                if (!bank0sel)
                    rsp0_rdata <= valid0[offset0] ? bank0[offset0] : '0;
                else
                    rsp0_rdata <= valid1[offset0] ? bank1[offset0] : '0;
            end
            rsp1_valid <= fire1;
            rsp1_error <= fire1 && !index1_ok;
            rsp1_rdata <= '0;
            if (fire1 && index1_ok && !req1_write) begin
                if (!bank1sel)
                    rsp1_rdata <= valid0[offset1] ? bank0[offset1] : '0;
                else
                    rsp1_rdata <= valid1[offset1] ? bank1[offset1] : '0;
            end
        end
    end

    initial begin
        if (FRAME_WIDTH < 1 || FRAME_HEIGHT < 1 ||
            PIXELS != FRAME_WIDTH*FRAME_HEIGHT ||
            PIXELS < 2 || PIXELS > 65536 ||
            ADDR_BITS < $clog2(PIXELS) || BANK_DEPTH < (PIXELS+1)/2)
            $fatal(1,"P138 unsupported scratchpad geometry");
    end
endmodule
