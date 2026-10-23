`timescale 1ns/1ps

/* PROD-SEAM-P33: scoped fault quarantine around the unchanged P24 cache.
 * Every raw pending commit reserves all of its enabled lanes' {home, set}
 * resources. The captured commit independently retains the same reservations
 * until the frontend releases ownership, including after aborted-source
 * withdrawal and through STORE-only rearm. This is admission ordering, not
 * cancellation or rollback of a previously issued physical write.
 * New conflicting READs wait outside P24. Previously admitted
 * READs, including their dirty-victim WB and replacement refill, keep draining
 * on their real interfaces before a conflicting commit reaches classification.
 *
 * A ledger entry retires only on an exact client/tag/line response. Commit
 * eligibility uses the registered ledger, never an optimistic same-cycle
 * response subtraction. A matching response may free its slot and tag for a
 * new request on that same edge. Already admitted requests are never cancelled.
 * Raw commit sources must hold valid and their payload until ready or abort.
 */
module a0_store_read_quarantine_order_guard #(
    parameter integer CLIENT_COUNT = 4,
    parameter integer LOCAL_TAG_W = 2,
    parameter integer CLIENT_MAX_OUTSTANDING = 4,
    parameter integer COMMIT_PORT_COUNT = 4,
    parameter integer STORE_LANES = 32,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT_PER_SLICE = 64,
    parameter integer SLICE_COUNT = 4,
    parameter integer WORD_SELECT_W = (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer SLICE_ID_W = (SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT),
    parameter integer SLICE_HASH_SHIFT = (SET_COUNT_PER_SLICE <= 1)
        ? 0 : $clog2(SET_COUNT_PER_SLICE),
    parameter integer SET_INDEX_W = (SET_COUNT_PER_SLICE <= 1)
        ? 1 : $clog2(SET_COUNT_PER_SLICE),
    parameter integer SLOT_ID_W = (CLIENT_MAX_OUTSTANDING <= 1)
        ? 1 : $clog2(CLIENT_MAX_OUTSTANDING)
) (
    input logic clk,
    input logic rst_n,

    input logic [CLIENT_COUNT-1:0] client_req_valid_i,
    input logic [LOCAL_TAG_W-1:0] client_req_local_tag_i [0:CLIENT_COUNT-1],
    input logic [LINE_ADDR_W-1:0] client_req_line_addr_i [0:CLIENT_COUNT-1],
    input logic [CLIENT_COUNT-1:0] core_client_req_ready_i,

    input logic [CLIENT_COUNT-1:0] client_resp_valid_i,
    input logic [LOCAL_TAG_W-1:0] client_resp_local_tag_i [0:CLIENT_COUNT-1],
    input logic [LINE_ADDR_W-1:0] client_resp_line_addr_i [0:CLIENT_COUNT-1],

    input logic [COMMIT_PORT_COUNT-1:0] commit_valid_i,
    input logic [STORE_LANES-1:0] commit_lane_mask_i [0:COMMIT_PORT_COUNT-1],
    input logic [31:0] commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],

    input logic captured_reservation_valid_i,
    input logic [STORE_LANES-1:0] captured_reservation_lane_mask_i,
    input logic [31:0] captured_reservation_word_addr_i [0:STORE_LANES-1],

    output logic [CLIENT_COUNT-1:0] core_client_req_valid_o,
    output logic [CLIENT_COUNT-1:0] client_req_ready_o,
    output logic [COMMIT_PORT_COUNT-1:0] core_commit_valid_o,
    output logic [CLIENT_COUNT-1:0] request_conflict_o,
    output logic [COMMIT_PORT_COUNT-1:0] commit_wait_o,
    output logic protocol_error_o
);
    logic live_q [0:CLIENT_COUNT-1][0:CLIENT_MAX_OUTSTANDING-1];
    logic [LOCAL_TAG_W-1:0] tag_q [0:CLIENT_COUNT-1][0:CLIENT_MAX_OUTSTANDING-1];
    logic [LINE_ADDR_W-1:0] line_q [0:CLIENT_COUNT-1][0:CLIENT_MAX_OUTSTANDING-1];
    logic protocol_error_q;

    logic [CLIENT_COUNT-1:0] retire_valid, response_error;
    logic [SLOT_ID_W-1:0] retire_slot [0:CLIENT_COUNT-1];
    logic [CLIENT_COUNT-1:0] free_slot_found, request_tag_busy, admission_allowed;
    logic [SLOT_ID_W-1:0] allocate_slot [0:CLIENT_COUNT-1];
    logic [CLIENT_COUNT-1:0] request_accept;

    initial begin
        if (CLIENT_COUNT < 1 || CLIENT_MAX_OUTSTANDING < 1
            || COMMIT_PORT_COUNT < 1 || STORE_LANES < 1 || LOCAL_TAG_W < 1)
            $fatal(1, "P33 ordering guard requires positive counts and tag width");
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
            $fatal(1, "P33 ordering guard LINE_WORDS must be a power of two");
        if (SET_COUNT_PER_SLICE < 1
            || (SET_COUNT_PER_SLICE & (SET_COUNT_PER_SLICE - 1)) != 0)
            $fatal(1, "P33 ordering guard set count must be a power of two");
        if (SLICE_COUNT < 1 || (SLICE_COUNT & (SLICE_COUNT - 1)) != 0)
            $fatal(1, "P33 ordering guard slice count must be a power of two");
        if (WORD_SELECT_W != ((LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS))
            || LINE_ADDR_W != 32 - WORD_SELECT_W || LINE_ADDR_W < 1)
            $fatal(1, "P33 ordering guard word/line address widths must match P24");
        if (SLICE_ID_W != ((SLICE_COUNT <= 1) ? 1 : $clog2(SLICE_COUNT))
            || SET_INDEX_W != ((SET_COUNT_PER_SLICE <= 1)
                ? 1 : $clog2(SET_COUNT_PER_SLICE))
            || SLOT_ID_W != ((CLIENT_MAX_OUTSTANDING <= 1)
                ? 1 : $clog2(CLIENT_MAX_OUTSTANDING))
            || SLICE_HASH_SHIFT < 0)
            $fatal(1, "P33 ordering guard resource/slot widths must match counts");
    end

    function automatic logic [LINE_ADDR_W-1:0] word_to_line(
        input logic [31:0] word_addr
    );
        word_to_line = LINE_ADDR_W'(word_addr >> WORD_SELECT_W);
    endfunction

    function automatic logic [SLICE_ID_W-1:0] line_to_slice(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        if (SLICE_COUNT <= 1) line_to_slice = '0;
        else line_to_slice = SLICE_ID_W'(line_addr)
            ^ SLICE_ID_W'(line_addr >> SLICE_HASH_SHIFT);
    endfunction

    function automatic logic [SET_INDEX_W-1:0] line_to_set(
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        line_to_set = SET_INDEX_W'(line_addr % SET_COUNT_PER_SLICE);
    endfunction

    function automatic logic same_resource(
        input logic [LINE_ADDR_W-1:0] line_a,
        input logic [LINE_ADDR_W-1:0] line_b
    );
        same_resource = line_to_slice(line_a) == line_to_slice(line_b)
            && line_to_set(line_a) == line_to_set(line_b);
    endfunction

    // This block has no request-ready or request-accept dependency.
    always_comb begin
        retire_valid = '0;
        response_error = '0;
        for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
            integer response_tag_matches;
            logic response_line_match;
            response_tag_matches = 0;
            response_line_match = 1'b0;
            retire_slot[c] = '0;
            for (integer s = 0; s < CLIENT_MAX_OUTSTANDING; s = s + 1) begin
                if (live_q[c][s] && tag_q[c][s] == client_resp_local_tag_i[c]) begin
                    response_tag_matches = response_tag_matches + 1;
                    if (line_q[c][s] == client_resp_line_addr_i[c]) begin
                        response_line_match = 1'b1;
                        retire_slot[c] = SLOT_ID_W'(s);
                    end
                end
            end
            if (client_resp_valid_i[c]) begin
                retire_valid[c] = response_tag_matches == 1 && response_line_match;
                response_error[c] = !retire_valid[c];
            end
        end
    end

    always_comb begin
        free_slot_found = '0;
        request_tag_busy = '0;
        for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
            allocate_slot[c] = '0;
            for (integer s = 0; s < CLIENT_MAX_OUTSTANDING; s = s + 1) begin
                if (!live_q[c][s]
                    || (retire_valid[c] && retire_slot[c] == SLOT_ID_W'(s))) begin
                    if (!free_slot_found[c]) begin
                        free_slot_found[c] = 1'b1;
                        allocate_slot[c] = SLOT_ID_W'(s);
                    end
                end else if (tag_q[c][s] == client_req_local_tag_i[c]) begin
                    request_tag_busy[c] = 1'b1;
                end
            end
        end
    end

    // Reserve raw pending sources, including ports not yet selected by the core.
    // Captured ownership survives source withdrawal independently of raw valid.
    always_comb begin
        request_conflict_o = '0;
        for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
            for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                if (client_req_valid_i[c] && captured_reservation_valid_i
                    && captured_reservation_lane_mask_i[lane]
                    && same_resource(client_req_line_addr_i[c],
                        word_to_line(captured_reservation_word_addr_i[lane])))
                    request_conflict_o[c] = 1'b1;
            end
            for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
                for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                    if (client_req_valid_i[c] && commit_valid_i[p]
                        && commit_lane_mask_i[p][lane]
                        && same_resource(client_req_line_addr_i[c],
                            word_to_line(commit_word_addr_i[p][lane])))
                        request_conflict_o[c] = 1'b1;
                end
            end
        end
    end

    // Deliberately inspect pre-edge entries, even when a response is present.
    // Old requests remain eligible for downstream service while their commit waits.
    always_comb begin
        commit_wait_o = '0;
        for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
            for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
                for (integer s = 0; s < CLIENT_MAX_OUTSTANDING; s = s + 1) begin
                    for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                        if (commit_valid_i[p] && commit_lane_mask_i[p][lane]
                            && live_q[c][s]
                            && same_resource(line_q[c][s],
                                word_to_line(commit_word_addr_i[p][lane])))
                            commit_wait_o[p] = 1'b1;
                    end
                end
            end
        end
    end

    assign admission_allowed = {CLIENT_COUNT{rst_n && !protocol_error_q}}
        & free_slot_found & ~request_tag_busy & ~request_conflict_o;
    assign core_client_req_valid_o = client_req_valid_i & admission_allowed;
    assign client_req_ready_o = core_client_req_ready_i & admission_allowed;
    assign request_accept = client_req_valid_i & client_req_ready_o;
    assign core_commit_valid_o = commit_valid_i & ~commit_wait_o
        & {COMMIT_PORT_COUNT{rst_n && !protocol_error_q}};
    // Only registered diagnostics may feed caller admission/fence controls.
    assign protocol_error_o = protocol_error_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            protocol_error_q <= 1'b0;
            for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
                for (integer s = 0; s < CLIENT_MAX_OUTSTANDING; s = s + 1) begin
                    live_q[c][s] <= 1'b0;
                    tag_q[c][s] <= '0;
                    line_q[c][s] <= '0;
                end
            end
        end else begin
            if (|response_error) protocol_error_q <= 1'b1;
            for (integer c = 0; c < CLIENT_COUNT; c = c + 1) begin
                if (retire_valid[c]) live_q[c][integer'(retire_slot[c])] <= 1'b0;
                // Allocation wins when retiring and reusing the same actual slot.
                if (request_accept[c]) begin
                    live_q[c][integer'(allocate_slot[c])] <= 1'b1;
                    tag_q[c][integer'(allocate_slot[c])] <= client_req_local_tag_i[c];
                    line_q[c][integer'(allocate_slot[c])] <= client_req_line_addr_i[c];
                end
            end
        end
    end
endmodule
