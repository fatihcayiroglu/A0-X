`timescale 1ns/1ps
// P138: experimental TWO-BANK 48-bit framebuffer scratchpad.
// Two independent request lanes, one selected access per bank per clock.
// Different physical banks can service two reads, writes, or a mixture
// in one clock. Same-bank conflict: lane 0 wins and lane 1 must retry.
// Registered bank read ports are designed for FPGA RAM inference.
// A fixed one-cycle response pulse has NO response backpressure.
// Does not connect to P102, external VRAM, PCIe, scanout or board clocks.
module a0_p138_dual_bank_framebuffer #(
    parameter integer FRAME_WIDTH=4,
    parameter integer FRAME_HEIGHT=4,
    parameter integer PIXELS=FRAME_WIDTH*FRAME_HEIGHT,
    parameter integer ADDR_BITS=PIXELS<=1 ? 1 : $clog2(PIXELS),
    parameter integer BANK_DEPTH=(PIXELS+1)/2,
    // Only integrated clients with an enforced complete-clear protocol may opt in.
    parameter bit FULL_CLEAR_GUARD=1'b0
)(
    input  logic clk,
    input  logic rst_n,
    // True only after every pixel has been overwritten since the last reset/clear.
    input  logic frame_initialized,

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
    // Interleaved 48-bit packed {RGB888,depth24}, 2 banks.
    // Data arrays deliberately have NO hardware reset. Legacy clients keep
    // per-pixel resettable validity, so unwritten locations read as zero.
    // The opt-in full-clear client uses one registered frame guard instead;
    // it must never assert frame_initialized until all pixels are overwritten.
    (* ram_style = "block" *) logic [47:0] bank0 [0:BANK_DEPTH-1];
    (* ram_style = "block" *) logic [47:0] bank1 [0:BANK_DEPTH-1];
    logic [BANK_DEPTH-1:0] valid0,valid1;
    logic [47:0] bank0_read_q,bank1_read_q;

    wire index0_ok = (32'(req0_index) < PIXELS);
    wire index1_ok = (32'(req1_index) < PIXELS);
    wire collision = req0_valid && req1_valid && index0_ok && index1_ok &&
                     (req0_index[0] == req1_index[0]);
    assign req0_ready = rst_n;
    assign req1_ready = rst_n && !collision;
    wire fire0 = req0_valid && req0_ready;
    wire fire1 = req1_valid && req1_ready;
    wire [ADDR_BITS-1:0] offset0 = req0_index >> 1;
    wire [ADDR_BITS-1:0] offset1 = req1_index >> 1;

    // Select exactly one physical operation for each bank. This explicit
    // mux keeps bank0 and bank1 independent for ECP5 block RAM inference.
    wire req0_bank0 = fire0 && index0_ok && !req0_index[0];
    wire req0_bank1 = fire0 && index0_ok &&  req0_index[0];
    wire req1_bank0 = fire1 && index1_ok && !req1_index[0];
    wire req1_bank1 = fire1 && index1_ok &&  req1_index[0];

    wire bank0_we = (req0_bank0 && req0_write) ||
                    (req1_bank0 && req1_write);
    wire bank1_we = (req0_bank1 && req0_write) ||
                    (req1_bank1 && req1_write);
    wire bank0_re = (req0_bank0 && !req0_write) ||
                    (req1_bank0 && !req1_write);
    wire bank1_re = (req0_bank1 && !req0_write) ||
                    (req1_bank1 && !req1_write);

    wire [ADDR_BITS-1:0] bank0_write_addr =
        (req0_bank0 && req0_write) ? offset0 : offset1;
    wire [ADDR_BITS-1:0] bank1_write_addr =
        (req0_bank1 && req0_write) ? offset0 : offset1;
    wire [47:0] bank0_write_data =
        (req0_bank0 && req0_write) ? req0_wdata : req1_wdata;
    wire [47:0] bank1_write_data =
        (req0_bank1 && req0_write) ? req0_wdata : req1_wdata;
    wire [ADDR_BITS-1:0] bank0_read_addr =
        (req0_bank0 && !req0_write) ? offset0 : offset1;
    wire [ADDR_BITS-1:0] bank1_read_addr =
        (req0_bank1 && !req0_write) ? offset0 : offset1;

    // Separate synchronous bank read data registers. No combinational
    // read port and no memory content reset. Any read/write same bank
    // in one clock is prevented by the ready arbitration.
    always_ff @(posedge clk) begin
        if (bank0_we) bank0[bank0_write_addr] <= bank0_write_data;
        if (bank1_we) bank1[bank1_write_addr] <= bank1_write_data;
        if (bank0_re) bank0_read_q <= bank0[bank0_read_addr];
        if (bank1_re) bank1_read_q <= bank1[bank1_read_addr];
    end

    // Constant-index enables may shorten the small-bank critical path.
    // Elaborate this topology only for <=512 bank entries: a wider array of
    // per-bit always_ff processes is prohibitively slow in real RTL simulation
    // (first P182 128x64 oracle exceeded 240s). Large banks retain the
    // original proven dynamic-index sequential assignment. The same branch
    // is used by synthesis AND simulation for each parameterized geometry.
    generate if (!FULL_CLEAR_GUARD && BANK_DEPTH <= 512) begin : GEN_SMALL_VALID_BITS
        for (genvar valid_idx = 0; valid_idx < BANK_DEPTH; valid_idx = valid_idx + 1) begin : GEN_VALID_BITS
            wire valid0_set = bank0_we && (bank0_write_addr == ADDR_BITS'(valid_idx));
            wire valid1_set = bank1_we && (bank1_write_addr == ADDR_BITS'(valid_idx));
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    valid0[valid_idx] <= 1'b0;
                    valid1[valid_idx] <= 1'b0;
                end else begin
                    if (valid0_set) valid0[valid_idx] <= 1'b1;
                    if (valid1_set) valid1[valid_idx] <= 1'b1;
                end
            end
        end
    end else if (!FULL_CLEAR_GUARD) begin : GEN_LARGE_VALID_BITS
        always_ff @(posedge clk) begin
            if (!rst_n) begin
                valid0 <= '0;
                valid1 <= '0;
            end else begin
                if (bank0_we) valid0[bank0_write_addr] <= 1'b1;
                if (bank1_we) valid1[bank1_write_addr] <= 1'b1;
            end
        end
    end endgenerate

    // Response lane metadata is captured on the same edge as each bank
    // read. The bank-read registers feed only matching accepted lane(s).
    logic read0_q,read1_q,read0_bank_q,read1_bank_q;
    logic read0_initialized_q,read1_initialized_q;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rsp0_valid <= 1'b0;
            rsp0_error <= 1'b0;
            rsp1_valid <= 1'b0;
            rsp1_error <= 1'b0;
            read0_q <= 1'b0; read1_q <= 1'b0;
            read0_bank_q <= 1'b0;read1_bank_q <= 1'b0;
            read0_initialized_q <= 1'b0;
            read1_initialized_q <= 1'b0;
        end else begin
            rsp0_valid <= fire0;
            rsp0_error <= fire0 && !index0_ok;
            rsp1_valid <= fire1;
            rsp1_error <= fire1 && !index1_ok;
            read0_q <= fire0 && index0_ok && !req0_write;
            read1_q <= fire1 && index1_ok && !req1_write;
            read0_bank_q <= req0_index[0];
            read1_bank_q <= req1_index[0];
            read0_initialized_q <= index0_ok &&
                (FULL_CLEAR_GUARD ? frame_initialized :
                    (req0_index[0] ? valid1[offset0] : valid0[offset0]));
            read1_initialized_q <= index1_ok &&
                (FULL_CLEAR_GUARD ? frame_initialized :
                    (req1_index[0] ? valid1[offset1] : valid0[offset1]));
        end
    end

    assign rsp0_rdata = (rsp0_valid && read0_q && read0_initialized_q) ?
        (read0_bank_q ? bank1_read_q : bank0_read_q) : 48'd0;
    assign rsp1_rdata = (rsp1_valid && read1_q && read1_initialized_q) ?
        (read1_bank_q ? bank1_read_q : bank0_read_q) : 48'd0;

    initial begin
        if (FRAME_WIDTH < 1 || FRAME_HEIGHT < 1 ||
            PIXELS != FRAME_WIDTH*FRAME_HEIGHT ||
            PIXELS < 2 || PIXELS > 65536 ||
            ADDR_BITS < $clog2(PIXELS) || BANK_DEPTH < (PIXELS+1)/2 ||
            (FULL_CLEAR_GUARD && PIXELS < 2048))
            $fatal(1,"P138 unsupported scratchpad geometry");
    end
endmodule
