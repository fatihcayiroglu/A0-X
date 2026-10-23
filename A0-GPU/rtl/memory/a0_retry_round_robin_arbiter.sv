`timescale 1ns/1ps

/* Bounded round-robin selector for PROD-SEAM-P5 replay state. */
module a0_retry_round_robin_arbiter #(
    parameter integer TAG_W = 1,
    parameter integer SLOT_COUNT = (1 << TAG_W)
) (
    input logic [SLOT_COUNT-1:0] pending_i,
    input logic [TAG_W-1:0] cursor_i,
    output logic found_o,
    output logic [TAG_W-1:0] tag_o
);
    initial begin
        if (TAG_W < 1)
            $fatal(1, "PROD_SEAM_P5 TAG_W must be >= 1");
        if (SLOT_COUNT != (1 << TAG_W))
            $fatal(1, "PROD_SEAM_P5 retry slot encoding mismatch");
    end

    always_comb begin
        found_o = 1'b0;
        tag_o = '0;
        for (integer off = 0; off < SLOT_COUNT; off = off + 1) begin
            logic [TAG_W-1:0] scan_tag;
            scan_tag = cursor_i + TAG_W'(off);
            if (!found_o && pending_i[integer'(scan_tag)]) begin
                found_o = 1'b1;
                tag_o = scan_tag;
            end
        end
    end
endmodule
