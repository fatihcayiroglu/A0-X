`timescale 1ns/1ps

/*
 * PROD-SEAM-P10 bounded anti-ABA guard for backend reads.
 *
 * P9's base read tag is extended with a monotonically allocated generation.
 * When the finite generation space wraps, new reads are held until an explicit
 * backend reuse-safe acknowledgement is observed while no P10 read is live.
 * Writes are passed through and do not consume generation/track state.
 */
module a0_backend_read_epoch_guard #(
    parameter integer BASE_READ_TAG_W = 6,
    parameter integer READ_EPOCH_W = 16,
    parameter integer LINE_ADDR_W = 29,
    parameter integer LINE_WORDS = 8,
    parameter integer READ_TRACK_COUNT = 8,
    parameter integer TRACK_SLOT_W =
        (READ_TRACK_COUNT <= 1) ? 1 : $clog2(READ_TRACK_COUNT),
    parameter integer READ_OCCUPANCY_W =
        (READ_TRACK_COUNT <= 1) ? 1 : $clog2(READ_TRACK_COUNT + 1),
    parameter integer EXTERNAL_READ_ID_W = BASE_READ_TAG_W + READ_EPOCH_W
) (
    input logic clk,
    input logic rst_n,

    input logic upstream_cmd_valid_i,
    output logic upstream_cmd_ready_o,
    input logic upstream_cmd_write_i,
    input logic [BASE_READ_TAG_W-1:0] upstream_cmd_read_tag_i,
    input logic [31:0] upstream_cmd_word_addr_i,
    input logic [31:0] upstream_cmd_wdata_i,
    input logic [LINE_ADDR_W-1:0] upstream_cmd_line_addr_i,

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_write_o,
    output logic [EXTERNAL_READ_ID_W-1:0] backend_cmd_read_id_o,
    output logic [31:0] backend_cmd_word_addr_o,
    output logic [31:0] backend_cmd_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,

    input logic backend_resp_valid_i,
    input logic [EXTERNAL_READ_ID_W-1:0] backend_resp_read_id_i,
    input logic [LINE_ADDR_W-1:0] backend_resp_line_addr_i,
    input logic backend_resp_fault_i,
    input logic [31:0] backend_resp_data_i [0:LINE_WORDS-1],

    output logic upstream_resp_valid_o,
    output logic [BASE_READ_TAG_W-1:0] upstream_resp_read_tag_o,
    output logic [LINE_ADDR_W-1:0] upstream_resp_line_addr_o,
    output logic upstream_resp_fault_o,
    output logic [31:0] upstream_resp_data_o [0:LINE_WORDS-1],

    input logic backend_epoch_reuse_safe_i,
    output logic epoch_protocol_error_o,
    output logic epoch_wrap_block_o,
    output logic [READ_EPOCH_W-1:0] next_generation_o,
    output logic [READ_OCCUPANCY_W-1:0] epoch_outstanding_o
);
    logic probe_valid_q;
    logic probe_write_q;
    logic [BASE_READ_TAG_W-1:0] probe_read_tag_q;
    logic [31:0] probe_word_addr_q;
    logic [31:0] probe_wdata_q;
    logic [LINE_ADDR_W-1:0] probe_line_addr_q;

    logic [READ_EPOCH_W-1:0] next_generation_q;
    logic generation_wrap_block_q;

    logic [READ_TRACK_COUNT-1:0] track_valid_q;
    logic [BASE_READ_TAG_W-1:0]
        track_base_tag_q [0:READ_TRACK_COUNT-1];
    logic [READ_EPOCH_W-1:0]
        track_generation_q [0:READ_TRACK_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        track_addr_q [0:READ_TRACK_COUNT-1];

    logic free_found;
    logic [TRACK_SLOT_W-1:0] free_slot;
    logic response_live_found;
    logic [TRACK_SLOT_W-1:0] response_live_slot;
    logic response_live_addr_match;
    logic any_live;
    logic read_issue_allowed;
    logic command_fire;
    logic read_command_fire;
    logic [EXTERNAL_READ_ID_W-1:0] current_read_id;
    logic samecycle_id_match;
    logic samecycle_addr_match;
    logic forward_live_response;
    logic forward_samecycle_response;
    logic exact_live_completion;
    logic exact_samecycle_completion;
    logic probe_source_matches;

    initial begin
        if (BASE_READ_TAG_W < 1)
            $fatal(1, "PROD_SEAM_P10 BASE_READ_TAG_W must be >= 1");
        if (READ_EPOCH_W < 1)
            $fatal(1, "PROD_SEAM_P10 READ_EPOCH_W must be >= 1");
        if (LINE_ADDR_W < 1)
            $fatal(1, "PROD_SEAM_P10 LINE_ADDR_W must be >= 1");
        if (LINE_WORDS < 1)
            $fatal(1, "PROD_SEAM_P10 LINE_WORDS must be >= 1");
        if (READ_TRACK_COUNT < 1)
            $fatal(1, "PROD_SEAM_P10 READ_TRACK_COUNT must be >= 1");
    end

    always_comb begin
        free_found = 1'b0;
        free_slot = '0;
        response_live_found = 1'b0;
        response_live_slot = '0;
        any_live = 1'b0;

        for (integer slot = 0; slot < READ_TRACK_COUNT; slot = slot + 1) begin
            if (!free_found && !track_valid_q[slot]) begin
                free_found = 1'b1;
                free_slot = TRACK_SLOT_W'(slot);
            end
            if (track_valid_q[slot])
                any_live = 1'b1;
            if (!response_live_found && track_valid_q[slot]
                && track_base_tag_q[slot]
                    == backend_resp_read_id_i[BASE_READ_TAG_W-1:0]
                && track_generation_q[slot]
                    == backend_resp_read_id_i[EXTERNAL_READ_ID_W-1:BASE_READ_TAG_W]) begin
                response_live_found = 1'b1;
                response_live_slot = TRACK_SLOT_W'(slot);
            end
        end

        response_live_addr_match = response_live_found
            && track_addr_q[integer'(response_live_slot)] == backend_resp_line_addr_i;

        probe_source_matches = upstream_cmd_valid_i
            && upstream_cmd_write_i == probe_write_q
            && upstream_cmd_read_tag_i == probe_read_tag_q
            && upstream_cmd_word_addr_i == probe_word_addr_q
            && upstream_cmd_wdata_i == probe_wdata_q
            && upstream_cmd_line_addr_i == probe_line_addr_q;

        current_read_id = {next_generation_q, probe_read_tag_q};
        read_issue_allowed = free_found && !generation_wrap_block_q;

        backend_cmd_valid_o = probe_valid_q
            && (probe_write_q || read_issue_allowed);
        backend_cmd_write_o = probe_write_q;
        backend_cmd_read_id_o = probe_write_q
            ? {{READ_EPOCH_W{1'b0}}, probe_read_tag_q}
            : current_read_id;
        backend_cmd_word_addr_o = probe_word_addr_q;
        backend_cmd_wdata_o = probe_wdata_q;
        backend_cmd_line_addr_o = probe_line_addr_q;

        command_fire = backend_cmd_valid_o && backend_cmd_ready_i;
        upstream_cmd_ready_o = command_fire;
        read_command_fire = command_fire && !probe_write_q;

        samecycle_id_match = backend_resp_valid_i && read_command_fire
            && backend_resp_read_id_i == current_read_id;
        samecycle_addr_match = samecycle_id_match
            && backend_resp_line_addr_i == probe_line_addr_q;

        forward_live_response = backend_resp_valid_i && response_live_found;
        forward_samecycle_response = samecycle_id_match;
        exact_live_completion = forward_live_response && response_live_addr_match;
        exact_samecycle_completion = samecycle_addr_match;

        upstream_resp_valid_o = forward_live_response || forward_samecycle_response;
        upstream_resp_read_tag_o = backend_resp_read_id_i[BASE_READ_TAG_W-1:0];
        upstream_resp_line_addr_o = backend_resp_line_addr_i;
        upstream_resp_fault_o = backend_resp_fault_i;
        for (integer word = 0; word < LINE_WORDS; word = word + 1)
            upstream_resp_data_o[word] = backend_resp_data_i[word];

        epoch_protocol_error_o = backend_resp_valid_i
            && !forward_live_response && !forward_samecycle_response;

        epoch_wrap_block_o = generation_wrap_block_q;
        next_generation_o = next_generation_q;
        epoch_outstanding_o = '0;
        for (integer slot = 0; slot < READ_TRACK_COUNT; slot = slot + 1)
            if (track_valid_q[slot])
                epoch_outstanding_o = epoch_outstanding_o + READ_OCCUPANCY_W'(1);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            probe_valid_q <= 1'b0;
            probe_write_q <= 1'b0;
            probe_read_tag_q <= '0;
            probe_word_addr_q <= '0;
            probe_wdata_q <= '0;
            probe_line_addr_q <= '0;
            next_generation_q <= '0;
            generation_wrap_block_q <= 1'b0;
            track_valid_q <= '0;
            for (integer slot = 0; slot < READ_TRACK_COUNT; slot = slot + 1) begin
                track_base_tag_q[slot] <= '0;
                track_generation_q[slot] <= '0;
                track_addr_q[slot] <= '0;
            end
        end else begin
            if (!probe_valid_q && upstream_cmd_valid_i) begin
                probe_valid_q <= 1'b1;
                probe_write_q <= upstream_cmd_write_i;
                probe_read_tag_q <= upstream_cmd_read_tag_i;
                probe_word_addr_q <= upstream_cmd_word_addr_i;
                probe_wdata_q <= upstream_cmd_wdata_i;
                probe_line_addr_q <= upstream_cmd_line_addr_i;
            end

            if (probe_valid_q && !probe_source_matches)
                $fatal(1, "PROD_SEAM_P10_UPSTREAM_COMMAND_CHANGED_BEFORE_ACCEPT");

            if (command_fire)
                probe_valid_q <= 1'b0;

            if (backend_epoch_reuse_safe_i && (any_live || read_command_fire))
                $fatal(1, "PROD_SEAM_P10_REUSE_SAFE_WITH_LIVE_READS");

            if (backend_epoch_reuse_safe_i && !any_live && !read_command_fire)
                generation_wrap_block_q <= 1'b0;

            if (exact_live_completion)
                track_valid_q[integer'(response_live_slot)] <= 1'b0;

            if (read_command_fire) begin
                if (!exact_samecycle_completion) begin
                    track_valid_q[integer'(free_slot)] <= 1'b1;
                    track_base_tag_q[integer'(free_slot)] <= probe_read_tag_q;
                    track_generation_q[integer'(free_slot)] <= next_generation_q;
                    track_addr_q[integer'(free_slot)] <= probe_line_addr_q;
                end

                if (&next_generation_q) begin
                    next_generation_q <= '0;
                    generation_wrap_block_q <= 1'b1;
                end else begin
                    next_generation_q <= next_generation_q + READ_EPOCH_W'(1);
                end
            end
        end
    end
endmodule
