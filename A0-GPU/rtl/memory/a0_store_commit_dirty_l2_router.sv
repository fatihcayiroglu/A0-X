`timescale 1ns/1ps

/*
 * PROD-SEAM-P24 bounded production-store commit to dirty-L2 router.
 *
 * One P7 visibility-commit source is selected fairly and locked until every
 * home slice touched by that commit has accepted its exact lane subset.  A
 * slice that has already accepted its subset is never presented the commit
 * again.  The upstream commit is acknowledged exactly once, only with the
 * final required slice acceptance.  This deliberately permits partial slice
 * update before the final upstream acknowledgement; the predecessor P7/P6
 * contract keeps the physical store globally pending, so conflicting
 * loads/replays remain blocked until this router raises commit_ready_o.
 *
 * This is not an atomic global-visibility point and not ownership/snoop
 * coherence.  Address/data identity is never reconstructed from cache state.
 */
module a0_store_commit_dirty_l2_router #(
    parameter integer COMMIT_PORT_COUNT = 4,
    parameter integer STORE_LANES = 32,
    parameter integer SLICE_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SLICE_HASH_SHIFT = 6,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer COMMIT_PORT_ID_W =
        (COMMIT_PORT_COUNT <= 1) ? 1 : $clog2(COMMIT_PORT_COUNT),
    parameter integer SLICE_ID_W =
        (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT)
) (
    input logic clk,
    input logic rst_n,

    input logic [COMMIT_PORT_COUNT-1:0] commit_valid_i,
    output logic [COMMIT_PORT_COUNT-1:0] commit_ready_o,
    input logic [STORE_LANES-1:0]
        commit_lane_mask_i [0:COMMIT_PORT_COUNT-1],
    input logic [31:0]
        commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],
    input logic [31:0]
        commit_wdata_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],

    output logic [SLICE_COUNT-1:0] slice_store_valid_o,
    input logic [SLICE_COUNT-1:0] slice_store_ready_i,
    output logic [STORE_LANES-1:0]
        slice_store_lane_mask_o [0:SLICE_COUNT-1],
    output logic [31:0]
        slice_store_word_addr_o [0:SLICE_COUNT-1][0:STORE_LANES-1],
    output logic [31:0]
        slice_store_wdata_o [0:SLICE_COUNT-1][0:STORE_LANES-1],

    output logic busy_o,
    output logic source_protocol_error_o
);
    logic active_q;
    logic [COMMIT_PORT_ID_W-1:0] active_port_q;
    logic [SLICE_COUNT-1:0] accepted_slice_q;
    logic [COMMIT_PORT_ID_W-1:0] rr_q;

    logic select_found;
    logic [COMMIT_PORT_ID_W-1:0] select_port;
    logic selected_valid;
    logic [SLICE_COUNT-1:0] needed_slice;
    logic [SLICE_COUNT-1:0] slice_accept;
    logic [SLICE_COUNT-1:0] accepted_before;
    logic [SLICE_COUNT-1:0] accepted_after;
    logic final_accept;

    integer scan_offset;
    logic [COMMIT_PORT_ID_W-1:0] scan_port;

    function automatic logic [LINE_ADDR_W-1:0]
        word_to_line(input logic [31:0] word_addr);
        begin
            if (LINE_WORDS <= 1) word_to_line = word_addr[LINE_ADDR_W-1:0];
            else word_to_line = LINE_ADDR_W'(word_addr >> WORD_SELECT_W);
        end
    endfunction

    function automatic logic [SLICE_ID_W-1:0]
        line_to_slice(input logic [LINE_ADDR_W-1:0] line_addr);
        logic [SLICE_ID_W-1:0] low_bits;
        logic [SLICE_ID_W-1:0] high_bits;
        begin
            if (SLICE_COUNT <= 1) begin
                line_to_slice = '0;
            end else begin
                low_bits = SLICE_ID_W'(line_addr);
                high_bits = SLICE_ID_W'(line_addr >> SLICE_HASH_SHIFT);
                line_to_slice = low_bits ^ high_bits;
            end
        end
    endfunction

    initial begin
        if (COMMIT_PORT_COUNT < 1) $fatal(1, "P24 COMMIT_PORT_COUNT must be >=1");
        if (STORE_LANES < 1) $fatal(1, "P24 STORE_LANES must be >=1");
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
            $fatal(1, "P24 LINE_WORDS must be power of two");
        if (SLICE_COUNT < 1 || (SLICE_COUNT & (SLICE_COUNT - 1)) != 0)
            $fatal(1, "P24 SLICE_COUNT must be power of two");
        if (SLICE_COUNT > 1 && SLICE_HASH_SHIFT >= LINE_ADDR_W)
            $fatal(1, "P24 SLICE_HASH_SHIFT must be below LINE_ADDR_W");
    end

    always_comb begin
        select_found = active_q;
        select_port = active_port_q;
        scan_port = '0;
        if (!active_q) begin
            select_found = 1'b0;
            select_port = '0;
            for (scan_offset = 0; scan_offset < COMMIT_PORT_COUNT; scan_offset = scan_offset + 1) begin
                scan_port = COMMIT_PORT_ID_W'(
                    (integer'(rr_q) + scan_offset) % COMMIT_PORT_COUNT
                );
                if (!select_found && commit_valid_i[integer'(scan_port)]) begin
                    select_found = 1'b1;
                    select_port = scan_port;
                end
            end
        end
        selected_valid = select_found && commit_valid_i[integer'(select_port)];
        accepted_before = active_q ? accepted_slice_q : '0;
    end

    /* Route construction intentionally does not read downstream ready.  This
     * keeps store_valid/payload independent from the dirty-slice ready path. */
    always_comb begin
        slice_store_valid_o = '0;
        needed_slice = '0;
        for (integer route_slice = 0; route_slice < SLICE_COUNT; route_slice = route_slice + 1) begin
            slice_store_lane_mask_o[route_slice] = '0;
            for (integer route_lane = 0; route_lane < STORE_LANES; route_lane = route_lane + 1) begin
                slice_store_word_addr_o[route_slice][route_lane] = '0;
                slice_store_wdata_o[route_slice][route_lane] = '0;
                if (selected_valid
                    && commit_lane_mask_i[integer'(select_port)][route_lane]
                    && line_to_slice(word_to_line(commit_word_addr_i[integer'(select_port)][route_lane]))
                        == SLICE_ID_W'(route_slice)) begin
                    needed_slice[route_slice] = 1'b1;
                    slice_store_lane_mask_o[route_slice][route_lane] = 1'b1;
                    slice_store_word_addr_o[route_slice][route_lane] =
                        commit_word_addr_i[integer'(select_port)][route_lane];
                    slice_store_wdata_o[route_slice][route_lane] =
                        commit_wdata_i[integer'(select_port)][route_lane];
                end
            end
            slice_store_valid_o[route_slice] = selected_valid
                && needed_slice[route_slice] && !accepted_before[route_slice];
        end
    end

    always_comb begin
        commit_ready_o = '0;
        slice_accept = '0;
        accepted_after = accepted_before;
        for (integer accept_slice = 0; accept_slice < SLICE_COUNT; accept_slice = accept_slice + 1) begin
            slice_accept[accept_slice] = slice_store_valid_o[accept_slice]
                && slice_store_ready_i[accept_slice];
            accepted_after[accept_slice] = accepted_before[accept_slice] || slice_accept[accept_slice];
        end
        final_accept = selected_valid
            && ((needed_slice & ~accepted_after) == '0);
        if (final_accept)
            commit_ready_o[integer'(select_port)] = 1'b1;

        busy_o = active_q;
        source_protocol_error_o = active_q
            && !commit_valid_i[integer'(active_port_q)];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            active_q <= 1'b0;
            active_port_q <= '0;
            accepted_slice_q <= '0;
            rr_q <= '0;
        end else begin
            if (source_protocol_error_o)
                $fatal(1, "PROD_SEAM_P24_COMMIT_SOURCE_DROPPED_VALID_BEFORE_READY");

            if (select_found && selected_valid) begin
                if (final_accept) begin
                    active_q <= 1'b0;
                    accepted_slice_q <= '0;
                    if (integer'(select_port) == COMMIT_PORT_COUNT - 1) rr_q <= '0;
                    else rr_q <= select_port + COMMIT_PORT_ID_W'(1);
                end else begin
                    active_q <= 1'b1;
                    active_port_q <= select_port;
                    accepted_slice_q <= accepted_after;
                end
            end else if (active_q) begin
                /* The fatal above terminates illegal source withdrawal. */
                active_q <= active_q;
            end
        end
    end
endmodule
