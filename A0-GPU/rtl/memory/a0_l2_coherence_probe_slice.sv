`timescale 1ns/1ps

/*
 * PROD-SEAM-P34 cache-backed coherence endpoint foundation.
 *
 * Additive successor to the frozen P17 dirty/writeback slice. The existing
 * one-miss, pulse-read-response, no-write-allocate store and immutable victim
 * behavior is retained. This primitive is not global coherence integration.
 *
 * A raw probe reserves its set against new local requests, but is accepted
 * only after older work on that set drains. One captured response is held
 * until accepted. A TAKE hit transfers responsibility only at that response
 * handshake: local validity/dirty state is then removed and the exact remote
 * ownership tuple protects the set until a matching full-line reclaim.
 *
 * Generations are allocated on TAKE-hit capture and never wrap. Reuse needs
 * a LOW certificate observed after exhaustion, followed by HIGH while idle.
 * That certificate resets only allocation state, never cache or read state.
 */
module a0_l2_coherence_probe_slice #(
    parameter integer STORE_LANES = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer SET_COUNT = 64,
    parameter integer GLOBAL_TAG_W = 8,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer SET_INDEX_W =
        (SET_COUNT <= 1) ? 1 : $clog2(SET_COUNT),
    parameter integer TAG_W =
        (SET_COUNT <= 1) ? LINE_ADDR_W : LINE_ADDR_W - $clog2(SET_COUNT),

    parameter integer COHERENCE_NODE_W = 4,
    parameter integer COHERENCE_TXN_W = 4,
    parameter integer COHERENCE_GEN_W = 2,
    parameter logic [COHERENCE_NODE_W-1:0] LOCAL_NODE_ID = '0
) (
    input  logic clk,
    input  logic rst_n,

    input  logic line_req_valid_i,
    output logic line_req_ready_o,
    input  logic [GLOBAL_TAG_W-1:0] line_req_global_tag_i,
    input  logic [LINE_ADDR_W-1:0] line_req_line_addr_i,

    output logic line_mem_req_valid_o,
    input  logic line_mem_req_ready_i,
    output logic [GLOBAL_TAG_W-1:0] line_mem_req_global_tag_o,
    output logic [LINE_ADDR_W-1:0] line_mem_req_line_addr_o,

    input  logic line_mem_resp_valid_i,
    input  logic [GLOBAL_TAG_W-1:0] line_mem_resp_global_tag_i,
    input  logic [LINE_ADDR_W-1:0] line_mem_resp_line_addr_i,
    input  logic line_mem_resp_fault_i,
    input  logic [31:0] line_mem_resp_data_i [0:LINE_WORDS-1],

    output logic line_resp_valid_o,
    output logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_o,
    output logic [LINE_ADDR_W-1:0] line_resp_line_addr_o,
    output logic line_resp_fault_o,
    output logic [31:0] line_resp_data_o [0:LINE_WORDS-1],

    input  logic store_valid_i,
    output logic store_ready_o,
    input  logic [STORE_LANES-1:0] store_lane_mask_i,
    input  logic [31:0] store_word_addr_i [0:STORE_LANES-1],
    input  logic [31:0] store_wdata_i [0:STORE_LANES-1],
    output logic [STORE_LANES-1:0] store_hit_mask_o,
    output logic [STORE_LANES-1:0] store_miss_mask_o,

    output logic wb_valid_o,
    input  logic wb_ready_i,
    output logic [LINE_ADDR_W-1:0] wb_line_addr_o,
    output logic [31:0] wb_data_o [0:LINE_WORDS-1],

    output logic dirty_present_o,
    output logic protocol_error_o,

    input  logic probe_req_valid_i,
    output logic probe_req_ready_o,
    input  logic probe_req_take_i,
    input  logic [COHERENCE_NODE_W-1:0] probe_req_node_i,
    input  logic [COHERENCE_TXN_W-1:0] probe_req_txn_i,
    input  logic [LINE_ADDR_W-1:0] probe_req_line_addr_i,

    output logic probe_resp_valid_o,
    input  logic probe_resp_ready_i,
    output logic probe_resp_take_o,
    output logic [COHERENCE_NODE_W-1:0] probe_resp_node_o,
    output logic [COHERENCE_TXN_W-1:0] probe_resp_txn_o,
    output logic [LINE_ADDR_W-1:0] probe_resp_line_addr_o,
    output logic [COHERENCE_GEN_W-1:0] probe_resp_generation_o,
    output logic probe_resp_hit_o,
    output logic probe_resp_dirty_o,
    output logic [31:0] probe_resp_data_o [0:LINE_WORDS-1],

    input  logic reclaim_valid_i,
    output logic reclaim_ready_o,
    input  logic [COHERENCE_NODE_W-1:0] reclaim_node_i,
    input  logic [COHERENCE_GEN_W-1:0] reclaim_generation_i,
    input  logic [LINE_ADDR_W-1:0] reclaim_line_addr_i,
    input  logic reclaim_dirty_i,
    input  logic [31:0] reclaim_data_i [0:LINE_WORDS-1],

    input  logic probe_reuse_safe_i,
    input  logic probe_block_i,
    output logic [SET_COUNT-1:0] coherence_block_set_o,
    output logic remote_owned_present_o,
    output logic probe_generation_exhausted_o,
    output logic coherence_protocol_error_o
);
    logic cache_valid_q [0:SET_COUNT-1];
    logic cache_dirty_q [0:SET_COUNT-1];
    logic [TAG_W-1:0] cache_tag_q [0:SET_COUNT-1];
    logic [31:0] cache_data_q [0:SET_COUNT-1][0:LINE_WORDS-1];

    logic miss_active_q;
    logic [GLOBAL_TAG_W-1:0] miss_global_tag_q;
    logic [LINE_ADDR_W-1:0] miss_line_q;

    logic evict_active_q;
    logic [GLOBAL_TAG_W-1:0] evict_req_global_tag_q;
    logic [LINE_ADDR_W-1:0] evict_req_line_q;
    logic [LINE_ADDR_W-1:0] evict_victim_line_q;
    logic [31:0] evict_victim_data_q [0:LINE_WORDS-1];

    logic hit_buf_valid_q;
    logic [GLOBAL_TAG_W-1:0] hit_buf_global_tag_q;
    logic [LINE_ADDR_W-1:0] hit_buf_line_q;
    logic [31:0] hit_buf_data_q [0:LINE_WORDS-1];

    logic probe_pending_q;
    logic probe_take_q;
    logic [COHERENCE_NODE_W-1:0] probe_node_q;
    logic [COHERENCE_TXN_W-1:0] probe_txn_q;
    logic [LINE_ADDR_W-1:0] probe_line_q;
    logic [COHERENCE_GEN_W-1:0] probe_generation_q;
    logic probe_hit_q;
    logic probe_dirty_q;
    logic [31:0] probe_data_q [0:LINE_WORDS-1];

    logic remote_owned_q [0:SET_COUNT-1];
    logic [LINE_ADDR_W-1:0] remote_line_q [0:SET_COUNT-1];
    logic [COHERENCE_NODE_W-1:0] remote_node_q [0:SET_COUNT-1];
    logic [COHERENCE_GEN_W-1:0] remote_generation_q [0:SET_COUNT-1];
    logic [COHERENCE_GEN_W-1:0] next_generation_q;
    logic generation_exhausted_q;
    logic reuse_low_seen_q;

    logic [SET_INDEX_W-1:0] req_set;
    logic [TAG_W-1:0] req_tag;
    logic req_hit;
    logic req_dirty_victim;
    logic req_store_conflict;
    logic req_coherence_block;
    logic line_accept;
    logic hit_accept;
    logic clean_miss_fire;
    logic evict_capture;
    logic evict_wb_fire;
    logic evict_read_fire;
    logic resp_match;
    logic refill_install;

    logic [SET_INDEX_W-1:0] probe_req_set;
    logic [SET_INDEX_W-1:0] probe_pending_set;
    logic probe_cache_hit;
    logic probe_older_busy;
    logic probe_self_take;
    logic probe_capture;
    logic probe_response_fire;
    logic probe_handoff;
    logic [SET_INDEX_W-1:0] reclaim_set;
    logic reclaim_match;
    logic reclaim_fire;
    logic generation_reuse;

    integer rs;
    integer rw;
    integer sw;
    integer lane;
    integer word;
    integer set_scan;

    initial begin
        if (STORE_LANES < 1) $fatal(1, "P34 STORE_LANES must be >=1");
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS-1)) != 0)
            $fatal(1, "P34 LINE_WORDS must be power of two");
        if (SET_COUNT < 1 || (SET_COUNT & (SET_COUNT-1)) != 0)
            $fatal(1, "P34 SET_COUNT must be power of two");
        if (GLOBAL_TAG_W < 1) $fatal(1, "P34 GLOBAL_TAG_W must be >=1");
        if (COHERENCE_NODE_W < 1) $fatal(1, "P34 COHERENCE_NODE_W must be >=1");
        if (COHERENCE_TXN_W < 1) $fatal(1, "P34 COHERENCE_TXN_W must be >=1");
        if (COHERENCE_GEN_W < 1) $fatal(1, "P34 COHERENCE_GEN_W must be >=1");
    end

    function automatic logic [SET_INDEX_W-1:0]
        line_set(input logic [LINE_ADDR_W-1:0] line_addr);
        begin
            line_set = SET_INDEX_W'(line_addr % SET_COUNT);
        end
    endfunction

    function automatic logic [TAG_W-1:0]
        line_tag(input logic [LINE_ADDR_W-1:0] line_addr);
        begin
            if (SET_COUNT <= 1) line_tag = TAG_W'(line_addr);
            else line_tag = TAG_W'(line_addr >> $clog2(SET_COUNT));
        end
    endfunction

    function automatic logic [LINE_ADDR_W-1:0]
        compose_line(
            input logic [TAG_W-1:0] tag,
            input logic [SET_INDEX_W-1:0] set_idx
        );
        begin
            if (SET_COUNT <= 1) compose_line = LINE_ADDR_W'(tag);
            else compose_line = (LINE_ADDR_W'(tag) << $clog2(SET_COUNT)) | LINE_ADDR_W'(set_idx);
        end
    endfunction

    function automatic logic [LINE_ADDR_W-1:0]
        word_to_line(input logic [31:0] word_addr);
        begin
            word_to_line = LINE_ADDR_W'(word_addr >> WORD_SELECT_W);
        end
    endfunction

    function automatic logic [WORD_SELECT_W:0]
        word_offset(input logic [31:0] word_addr);
        begin
            word_offset = (WORD_SELECT_W+1)'(word_addr % LINE_WORDS);
        end
    endfunction

    always_comb begin
        req_set = line_set(line_req_line_addr_i);
        req_tag = line_tag(line_req_line_addr_i);
        req_hit = cache_valid_q[integer'(req_set)] && cache_tag_q[integer'(req_set)] == req_tag;
        req_dirty_victim = cache_valid_q[integer'(req_set)] && !req_hit && cache_dirty_q[integer'(req_set)];
        probe_req_set = line_set(probe_req_line_addr_i);
        probe_pending_set = line_set(probe_line_q);
        reclaim_set = line_set(reclaim_line_addr_i);

        // Export registered reservations only. Raw valid is a local admission
        // interlock and must not feed an upstream combinational quarantine loop.
        coherence_block_set_o = '0;
        remote_owned_present_o = 1'b0;
        dirty_present_o = 1'b0;
        for (set_scan = 0; set_scan < SET_COUNT; set_scan = set_scan + 1) begin
            coherence_block_set_o[set_scan] = remote_owned_q[set_scan]
                || (probe_pending_q && integer'(probe_pending_set) == set_scan);
            if (remote_owned_q[set_scan]) remote_owned_present_o = 1'b1;
            if (cache_valid_q[set_scan] && cache_dirty_q[set_scan]) dirty_present_o = 1'b1;
        end
        req_coherence_block = coherence_block_set_o[integer'(req_set)]
            || (probe_req_valid_i && probe_req_set == req_set);

        // Use pre-edge busy state, including the refill/response retirement
        // edge. Both retained eviction addresses are checked explicitly.
        probe_older_busy = (miss_active_q && line_set(miss_line_q) == probe_req_set)
            || (evict_active_q && (line_set(evict_req_line_q) == probe_req_set
                || line_set(evict_victim_line_q) == probe_req_set))
            || (hit_buf_valid_q && line_set(hit_buf_line_q) == probe_req_set);
        probe_self_take = probe_req_take_i && probe_req_node_i == LOCAL_NODE_ID;
        probe_cache_hit = cache_valid_q[integer'(probe_req_set)]
            && cache_tag_q[integer'(probe_req_set)] == line_tag(probe_req_line_addr_i);
        probe_req_ready_o = rst_n && !probe_pending_q && !probe_block_i
            && !remote_owned_q[integer'(probe_req_set)] && !probe_older_busy
            && !probe_self_take && (!probe_req_take_i || !generation_exhausted_q);
        probe_capture = probe_req_valid_i && probe_req_ready_o;

        probe_resp_valid_o = rst_n && probe_pending_q;
        probe_resp_take_o = probe_take_q;
        probe_resp_node_o = probe_node_q;
        probe_resp_txn_o = probe_txn_q;
        probe_resp_line_addr_o = probe_line_q;
        probe_resp_generation_o = probe_generation_q;
        probe_resp_hit_o = probe_hit_q;
        probe_resp_dirty_o = probe_dirty_q;
        for (word = 0; word < LINE_WORDS; word = word + 1)
            probe_resp_data_o[word] = probe_data_q[word];
        probe_response_fire = probe_resp_valid_o && probe_resp_ready_i;
        probe_handoff = probe_response_fire && probe_take_q && probe_hit_q;

        reclaim_match = remote_owned_q[integer'(reclaim_set)]
            && remote_line_q[integer'(reclaim_set)] == reclaim_line_addr_i
            && remote_node_q[integer'(reclaim_set)] == reclaim_node_i
            && remote_generation_q[integer'(reclaim_set)] == reclaim_generation_i;
        reclaim_ready_o = rst_n && reclaim_match;
        reclaim_fire = reclaim_valid_i && reclaim_ready_o;
        probe_generation_exhausted_o = generation_exhausted_q;

        req_store_conflict = 1'b0;
        if (store_valid_i) begin
            for (lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                // STORE wins same-set admission so an alias READ cannot
                // invalidate or snapshot the resident line before this STORE.
                if (store_lane_mask_i[lane] && line_set(word_to_line(store_word_addr_i[lane])) == req_set)
                    req_store_conflict = 1'b1;
            end
        end

        line_req_ready_o = rst_n && !miss_active_q && !evict_active_q && !req_store_conflict
            && !req_coherence_block
            && (!req_hit || !hit_buf_valid_q || !line_mem_resp_valid_i)
            && (req_hit || req_dirty_victim || line_mem_req_ready_i);
        line_accept = line_req_valid_i && line_req_ready_o;
        hit_accept = line_accept && req_hit;
        clean_miss_fire = line_accept && !req_hit && !req_dirty_victim;
        evict_capture = line_accept && req_dirty_victim;

        wb_valid_o = evict_active_q && cache_valid_q[integer'(line_set(evict_victim_line_q))]
            && cache_dirty_q[integer'(line_set(evict_victim_line_q))];

        line_mem_req_valid_o = 1'b0;
        line_mem_req_global_tag_o = line_req_global_tag_i;
        line_mem_req_line_addr_o = line_req_line_addr_i;
        if (!miss_active_q && !evict_active_q && line_req_valid_i && !req_hit && !req_dirty_victim
            && !req_store_conflict && !req_coherence_block) begin
            line_mem_req_valid_o = 1'b1;
        end else if (evict_active_q && !wb_valid_o
            && !coherence_block_set_o[integer'(line_set(evict_req_line_q))]) begin
            // A raw waiting probe must let this older retained request drain.
            line_mem_req_valid_o = 1'b1;
            line_mem_req_global_tag_o = evict_req_global_tag_q;
            line_mem_req_line_addr_o = evict_req_line_q;
        end
        wb_line_addr_o = evict_victim_line_q;
        for (word = 0; word < LINE_WORDS; word = word + 1)
            wb_data_o[word] = evict_victim_data_q[word];
        evict_wb_fire = wb_valid_o && wb_ready_i;
        evict_read_fire = evict_active_q && !wb_valid_o && line_mem_req_valid_o && line_mem_req_ready_i;

        resp_match = miss_active_q && line_mem_resp_valid_i
            && line_mem_resp_global_tag_i == miss_global_tag_q
            && line_mem_resp_line_addr_i == miss_line_q;
        refill_install = resp_match && !line_mem_resp_fault_i;

        line_resp_valid_o = 1'b0;
        line_resp_global_tag_o = '0;
        line_resp_line_addr_o = '0;
        line_resp_fault_o = 1'b0;
        for (word = 0; word < LINE_WORDS; word = word + 1) line_resp_data_o[word] = '0;
        if (rst_n && resp_match) begin
            line_resp_valid_o = 1'b1;
            line_resp_global_tag_o = line_mem_resp_global_tag_i;
            line_resp_line_addr_o = line_mem_resp_line_addr_i;
            line_resp_fault_o = line_mem_resp_fault_i;
            for (word = 0; word < LINE_WORDS; word = word + 1)
                line_resp_data_o[word] = line_mem_resp_data_i[word];
        end else if (rst_n && hit_buf_valid_q) begin
            line_resp_valid_o = 1'b1;
            line_resp_global_tag_o = hit_buf_global_tag_q;
            line_resp_line_addr_o = hit_buf_line_q;
            for (word = 0; word < LINE_WORDS; word = word + 1)
                line_resp_data_o[word] = hit_buf_data_q[word];
        end

        store_ready_o = rst_n;
        if (store_valid_i) begin
            for (lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                if (store_lane_mask_i[lane]
                    && (coherence_block_set_o[integer'(line_set(word_to_line(store_word_addr_i[lane])))]
                        || (probe_req_valid_i
                            && line_set(word_to_line(store_word_addr_i[lane])) == probe_req_set)
                        || (evict_active_q
                            && word_to_line(store_word_addr_i[lane]) == evict_victim_line_q)))
                    store_ready_o = 1'b0;
            end
        end
        store_hit_mask_o = '0;
        store_miss_mask_o = '0;
        if (store_valid_i && store_ready_o) begin
            for (lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                if (store_lane_mask_i[lane]) begin
                    if (cache_valid_q[integer'(line_set(word_to_line(store_word_addr_i[lane])))]
                        && cache_tag_q[integer'(line_set(word_to_line(store_word_addr_i[lane])))]
                            == line_tag(word_to_line(store_word_addr_i[lane])))
                        store_hit_mask_o[lane] = 1'b1;
                    else store_miss_mask_o[lane] = 1'b1;
                end
            end
        end

        protocol_error_o = line_mem_resp_valid_i && !resp_match;
        generation_reuse = generation_exhausted_q && reuse_low_seen_q && probe_reuse_safe_i
            && !probe_pending_q && !remote_owned_present_o
            && !miss_active_q && !evict_active_q && !hit_buf_valid_q
            && !probe_capture && !line_accept;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            miss_active_q <= 1'b0;
            miss_global_tag_q <= '0;
            miss_line_q <= '0;
            evict_active_q <= 1'b0;
            evict_req_global_tag_q <= '0;
            evict_req_line_q <= '0;
            evict_victim_line_q <= '0;
            hit_buf_valid_q <= 1'b0;
            hit_buf_global_tag_q <= '0;
            hit_buf_line_q <= '0;
            probe_pending_q <= 1'b0;
            probe_take_q <= 1'b0;
            probe_node_q <= '0;
            probe_txn_q <= '0;
            probe_line_q <= '0;
            probe_generation_q <= '0;
            probe_hit_q <= 1'b0;
            probe_dirty_q <= 1'b0;
            next_generation_q <= '0;
            generation_exhausted_q <= 1'b0;
            reuse_low_seen_q <= 1'b0;
            coherence_protocol_error_o <= 1'b0;
            for (rs = 0; rs < SET_COUNT; rs = rs + 1) begin
                cache_valid_q[rs] <= 1'b0;
                cache_dirty_q[rs] <= 1'b0;
                cache_tag_q[rs] <= '0;
                remote_owned_q[rs] <= 1'b0;
                remote_line_q[rs] <= '0;
                remote_node_q[rs] <= '0;
                remote_generation_q[rs] <= '0;
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1) cache_data_q[rs][rw] <= '0;
            end
            for (rw = 0; rw < LINE_WORDS; rw = rw + 1) begin
                evict_victim_data_q[rw] <= '0;
                hit_buf_data_q[rw] <= '0;
                probe_data_q[rw] <= '0;
            end
        end else begin
            coherence_protocol_error_o <= (probe_req_valid_i && probe_self_take)
                || (reclaim_valid_i && !reclaim_match);

            if (hit_buf_valid_q && !line_mem_resp_valid_i) hit_buf_valid_q <= 1'b0;

            if (hit_accept) begin
                hit_buf_valid_q <= 1'b1;
                hit_buf_global_tag_q <= line_req_global_tag_i;
                hit_buf_line_q <= line_req_line_addr_i;
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                    hit_buf_data_q[rw] <= cache_data_q[integer'(req_set)][rw];
            end

            if (clean_miss_fire) begin
                miss_active_q <= 1'b1;
                miss_global_tag_q <= line_req_global_tag_i;
                miss_line_q <= line_req_line_addr_i;
                if (cache_valid_q[integer'(req_set)] && !cache_dirty_q[integer'(req_set)]) begin
                    cache_valid_q[integer'(req_set)] <= 1'b0;
                    cache_dirty_q[integer'(req_set)] <= 1'b0;
                end
            end

            if (evict_capture) begin
                evict_active_q <= 1'b1;
                evict_req_global_tag_q <= line_req_global_tag_i;
                evict_req_line_q <= line_req_line_addr_i;
                evict_victim_line_q <= compose_line(cache_tag_q[integer'(req_set)], req_set);
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                    evict_victim_data_q[rw] <= cache_data_q[integer'(req_set)][rw];
            end

            if (evict_wb_fire) begin
                cache_valid_q[integer'(line_set(evict_victim_line_q))] <= 1'b0;
                cache_dirty_q[integer'(line_set(evict_victim_line_q))] <= 1'b0;
            end

            if (evict_read_fire) begin
                miss_active_q <= 1'b1;
                miss_global_tag_q <= evict_req_global_tag_q;
                miss_line_q <= evict_req_line_q;
                evict_active_q <= 1'b0;
            end

            if (resp_match) begin
                miss_active_q <= 1'b0;
                if (refill_install) begin
                    cache_valid_q[integer'(line_set(line_mem_resp_line_addr_i))] <= 1'b1;
                    cache_dirty_q[integer'(line_set(line_mem_resp_line_addr_i))] <= 1'b0;
                    cache_tag_q[integer'(line_set(line_mem_resp_line_addr_i))] <= line_tag(line_mem_resp_line_addr_i);
                    for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                        cache_data_q[integer'(line_set(line_mem_resp_line_addr_i))][rw] <= line_mem_resp_data_i[rw];
                end
            end

            if (store_valid_i && store_ready_o) begin
                for (sw = 0; sw < STORE_LANES; sw = sw + 1) begin
                    if (store_hit_mask_o[sw]) begin
                        cache_data_q[integer'(line_set(word_to_line(store_word_addr_i[sw])))]
                            [integer'(word_offset(store_word_addr_i[sw]))] <= store_wdata_i[sw];
                        cache_dirty_q[integer'(line_set(word_to_line(store_word_addr_i[sw])))] <= 1'b1;
                    end
                end
            end

            // Capture and retirement are mutually exclusive: ready stays LOW
            // throughout the previous response's handshake edge.
            if (probe_capture) begin
                probe_pending_q <= 1'b1;
                probe_take_q <= probe_req_take_i;
                probe_node_q <= probe_req_node_i;
                probe_txn_q <= probe_req_txn_i;
                probe_line_q <= probe_req_line_addr_i;
                probe_hit_q <= probe_cache_hit;
                probe_dirty_q <= probe_cache_hit && cache_dirty_q[integer'(probe_req_set)];
                probe_generation_q <= '0;
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                    probe_data_q[rw] <= probe_cache_hit ? cache_data_q[integer'(probe_req_set)][rw] : 32'b0;
                if (probe_req_take_i && probe_cache_hit) begin
                    probe_generation_q <= next_generation_q;
                    if (&next_generation_q) begin
                        generation_exhausted_q <= 1'b1;
                        reuse_low_seen_q <= 1'b0;
                    end else begin
                        next_generation_q <= next_generation_q + COHERENCE_GEN_W'(1);
                    end
                end
            end else if (probe_response_fire) begin
                probe_pending_q <= 1'b0;
            end

            // These writes cannot collide with old read/refill/WB/store writes:
            // acceptance drained older same-set work and the registered probe
            // or remote hold blocks all newer same-set access through this edge.
            // Handoff and reclaim cannot target the same set on the same edge,
            // because reclaim requires a pre-edge remote ownership record.
            if (probe_handoff) begin
                cache_valid_q[integer'(probe_pending_set)] <= 1'b0;
                cache_dirty_q[integer'(probe_pending_set)] <= 1'b0;
                remote_owned_q[integer'(probe_pending_set)] <= 1'b1;
                remote_line_q[integer'(probe_pending_set)] <= probe_line_q;
                remote_node_q[integer'(probe_pending_set)] <= probe_node_q;
                remote_generation_q[integer'(probe_pending_set)] <= probe_generation_q;
            end
            if (reclaim_fire) begin
                cache_valid_q[integer'(reclaim_set)] <= 1'b1;
                cache_dirty_q[integer'(reclaim_set)] <= reclaim_dirty_i;
                cache_tag_q[integer'(reclaim_set)] <= line_tag(reclaim_line_addr_i);
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                    cache_data_q[integer'(reclaim_set)][rw] <= reclaim_data_i[rw];
                remote_owned_q[integer'(reclaim_set)] <= 1'b0;
            end

            // A LOW on the allocation/exhaustion edge does not count. The
            // predicate uses the previous registered exhausted state.
            if (generation_exhausted_q && !probe_reuse_safe_i)
                reuse_low_seen_q <= 1'b1;
            if (generation_reuse) begin
                next_generation_q <= '0;
                generation_exhausted_q <= 1'b0;
                reuse_low_seen_q <= 1'b0;
            end
        end
    end
endmodule
