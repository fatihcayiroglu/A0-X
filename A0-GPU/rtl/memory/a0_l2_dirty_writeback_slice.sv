`timescale 1ns/1ps

/*
 * PROD-SEAM-P17 bounded shared-L2 dirty/writeback foundation.
 *
 * This is a successor slice primitive; frozen P0-P16 RTL is not modified.
 * Scope is intentionally bounded to one outstanding read miss per slice.
 * Stores update resident words only (no-write-allocate) and mark the resident
 * line dirty. A miss that maps onto a dirty resident line is retained until the
 * full victim line is accepted by the writeback channel. The victim is never
 * invalidated or marked clean before that handshake.
 *
 * This is not ownership/snoop coherence and does not yet replace the P16
 * backing-store commit policy.
 */
module a0_l2_dirty_writeback_slice #(
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
        (SET_COUNT <= 1) ? LINE_ADDR_W : LINE_ADDR_W - $clog2(SET_COUNT)
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
    output logic protocol_error_o
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

    logic [SET_INDEX_W-1:0] req_set;
    logic [TAG_W-1:0] req_tag;
    logic req_hit;
    logic req_dirty_victim;
    logic req_store_conflict;
    logic line_accept;
    logic hit_accept;
    logic clean_miss_fire;
    logic evict_capture;
    logic evict_wb_fire;
    logic evict_read_fire;
    logic resp_match;
    logic refill_install;

    integer rs;
    integer rw;
    integer sw;
    integer lane;
    integer word;
    integer dirty_scan;

    initial begin
        if (STORE_LANES < 1) $fatal(1, "P17 STORE_LANES must be >=1");
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS-1)) != 0)
            $fatal(1, "P17 LINE_WORDS must be power of two");
        if (SET_COUNT < 1 || (SET_COUNT & (SET_COUNT-1)) != 0)
            $fatal(1, "P17 SET_COUNT must be power of two");
        if (GLOBAL_TAG_W < 1) $fatal(1, "P17 GLOBAL_TAG_W must be >=1");
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
            if (LINE_WORDS <= 1) word_to_line = word_addr[LINE_ADDR_W-1:0];
            else word_to_line = LINE_ADDR_W'(word_addr >> WORD_SELECT_W);
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
        req_hit = cache_valid_q[req_set] && cache_tag_q[req_set] == req_tag;
        req_dirty_victim = cache_valid_q[req_set] && !req_hit && cache_dirty_q[req_set];

        req_store_conflict = 1'b0;
        if (store_valid_i) begin
            for (lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                if (store_lane_mask_i[lane] && word_to_line(store_word_addr_i[lane]) == line_req_line_addr_i)
                    req_store_conflict = 1'b1;
            end
        end

        line_req_ready_o = rst_n && !miss_active_q && !evict_active_q && !req_store_conflict
            && (!req_hit || !hit_buf_valid_q || !line_mem_resp_valid_i)
            && (req_hit || req_dirty_victim || line_mem_req_ready_i);
        line_accept = line_req_valid_i && line_req_ready_o;
        hit_accept = line_accept && req_hit;
        clean_miss_fire = line_accept && !req_hit && !req_dirty_victim;
        evict_capture = line_accept && req_dirty_victim;

        wb_valid_o = evict_active_q && cache_valid_q[line_set(evict_victim_line_q)]
            && cache_dirty_q[line_set(evict_victim_line_q)];

        line_mem_req_valid_o = 1'b0;
        line_mem_req_global_tag_o = line_req_global_tag_i;
        line_mem_req_line_addr_o = line_req_line_addr_i;
        if (!miss_active_q && !evict_active_q && line_req_valid_i && !req_hit && !req_dirty_victim
            && !req_store_conflict) begin
            line_mem_req_valid_o = 1'b1;
        end else if (evict_active_q && !wb_valid_o) begin
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
        if (evict_active_q && store_valid_i) begin
            for (lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                if (store_lane_mask_i[lane] && word_to_line(store_word_addr_i[lane]) == evict_victim_line_q)
                    store_ready_o = 1'b0;
            end
        end
        store_hit_mask_o = '0;
        store_miss_mask_o = '0;
        if (store_valid_i && store_ready_o) begin
            for (lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                if (store_lane_mask_i[lane]) begin
                    if (cache_valid_q[line_set(word_to_line(store_word_addr_i[lane]))]
                        && cache_tag_q[line_set(word_to_line(store_word_addr_i[lane]))]
                            == line_tag(word_to_line(store_word_addr_i[lane])))
                        store_hit_mask_o[lane] = 1'b1;
                    else store_miss_mask_o[lane] = 1'b1;
                end
            end
        end

        dirty_present_o = 1'b0;
        for (dirty_scan = 0; dirty_scan < SET_COUNT; dirty_scan = dirty_scan + 1)
            if (cache_valid_q[dirty_scan] && cache_dirty_q[dirty_scan]) dirty_present_o = 1'b1;

        protocol_error_o = line_mem_resp_valid_i && !resp_match;
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
            for (rs = 0; rs < SET_COUNT; rs = rs + 1) begin
                cache_valid_q[rs] <= 1'b0;
                cache_dirty_q[rs] <= 1'b0;
                cache_tag_q[rs] <= '0;
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1) cache_data_q[rs][rw] <= '0;
            end
            for (rw = 0; rw < LINE_WORDS; rw = rw + 1) begin
                evict_victim_data_q[rw] <= '0;
                hit_buf_data_q[rw] <= '0;
            end
        end else begin
            if (hit_buf_valid_q && !line_mem_resp_valid_i) hit_buf_valid_q <= 1'b0;

            if (hit_accept) begin
                hit_buf_valid_q <= 1'b1;
                hit_buf_global_tag_q <= line_req_global_tag_i;
                hit_buf_line_q <= line_req_line_addr_i;
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                    hit_buf_data_q[rw] <= cache_data_q[req_set][rw];
            end

            if (clean_miss_fire) begin
                miss_active_q <= 1'b1;
                miss_global_tag_q <= line_req_global_tag_i;
                miss_line_q <= line_req_line_addr_i;
                if (cache_valid_q[req_set] && !cache_dirty_q[req_set]) begin
                    cache_valid_q[req_set] <= 1'b0;
                    cache_dirty_q[req_set] <= 1'b0;
                end
            end

            if (evict_capture) begin
                evict_active_q <= 1'b1;
                evict_req_global_tag_q <= line_req_global_tag_i;
                evict_req_line_q <= line_req_line_addr_i;
                evict_victim_line_q <= compose_line(cache_tag_q[req_set], req_set);
                for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                    evict_victim_data_q[rw] <= cache_data_q[req_set][rw];
            end

            if (evict_wb_fire) begin
                cache_valid_q[line_set(evict_victim_line_q)] <= 1'b0;
                cache_dirty_q[line_set(evict_victim_line_q)] <= 1'b0;
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
                    cache_valid_q[line_set(line_mem_resp_line_addr_i)] <= 1'b1;
                    cache_dirty_q[line_set(line_mem_resp_line_addr_i)] <= 1'b0;
                    cache_tag_q[line_set(line_mem_resp_line_addr_i)] <= line_tag(line_mem_resp_line_addr_i);
                    for (rw = 0; rw < LINE_WORDS; rw = rw + 1)
                        cache_data_q[line_set(line_mem_resp_line_addr_i)][rw] <= line_mem_resp_data_i[rw];
                end
            end

            if (store_valid_i && store_ready_o) begin
                for (sw = 0; sw < STORE_LANES; sw = sw + 1) begin
                    if (store_hit_mask_o[sw]) begin
                        cache_data_q[line_set(word_to_line(store_word_addr_i[sw]))]
                            [integer'(word_offset(store_word_addr_i[sw]))] <= store_wdata_i[sw];
                        cache_dirty_q[line_set(word_to_line(store_word_addr_i[sw]))] <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
