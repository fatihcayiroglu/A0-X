`timescale 1ns/1ps

/*
 * PROD-SEAM-P9 bounded backend-read transaction guard.
 *
 * The upstream P8 command is first snapshotted without handshaking it. P8 is
 * acknowledged only on the cycle that the exact snapshot is accepted by the
 * external backend. This preserves P8's store visibility point while breaking
 * command/ready combinational loops. Read commands additionally consume one
 * scoreboard entry holding exact backend tag and line address.
 */
module a0_backend_read_transaction_guard #(
    parameter integer READ_TRACK_COUNT = 8,
    parameter integer BACKEND_READ_TAG_W = 6,
    parameter integer LINE_ADDR_W = 29,
    parameter integer LINE_WORDS = 8,
    parameter integer TRACK_SLOT_W =
        (READ_TRACK_COUNT <= 1) ? 1 : $clog2(READ_TRACK_COUNT),
    parameter integer READ_OCCUPANCY_W =
        (READ_TRACK_COUNT <= 1) ? 1 : $clog2(READ_TRACK_COUNT + 1)
) (
    input logic clk,
    input logic rst_n,

    input logic upstream_cmd_valid_i,
    output logic upstream_cmd_ready_o,
    input logic upstream_cmd_write_i,
    input logic [BACKEND_READ_TAG_W-1:0] upstream_cmd_read_tag_i,
    input logic [31:0] upstream_cmd_word_addr_i,
    input logic [31:0] upstream_cmd_wdata_i,
    input logic [LINE_ADDR_W-1:0] upstream_cmd_line_addr_i,

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_write_o,
    output logic [BACKEND_READ_TAG_W-1:0] backend_cmd_read_tag_o,
    output logic [31:0] backend_cmd_word_addr_o,
    output logic [31:0] backend_cmd_wdata_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,

    input logic backend_resp_valid_i,
    input logic [BACKEND_READ_TAG_W-1:0] backend_resp_read_tag_i,
    input logic [LINE_ADDR_W-1:0] backend_resp_line_addr_i,
    input logic backend_resp_fault_i,
    input logic [31:0] backend_resp_data_i [0:LINE_WORDS-1],

    output logic upstream_resp_valid_o,
    output logic [BACKEND_READ_TAG_W-1:0] upstream_resp_read_tag_o,
    output logic [LINE_ADDR_W-1:0] upstream_resp_line_addr_o,
    output logic upstream_resp_fault_o,
    output logic [31:0] upstream_resp_data_o [0:LINE_WORDS-1],

    output logic read_resp_protocol_error_o,
    output logic read_duplicate_block_o,
    output logic [READ_OCCUPANCY_W-1:0] read_outstanding_o,
    output logic read_capacity_full_o
);
    logic probe_valid_q;
    logic probe_write_q;
    logic [BACKEND_READ_TAG_W-1:0] probe_read_tag_q;
    logic [31:0] probe_word_addr_q;
    logic [31:0] probe_wdata_q;
    logic [LINE_ADDR_W-1:0] probe_line_addr_q;

    logic [READ_TRACK_COUNT-1:0] track_valid_q;
    logic [BACKEND_READ_TAG_W-1:0]
        track_tag_q [0:READ_TRACK_COUNT-1];
    logic [LINE_ADDR_W-1:0]
        track_addr_q [0:READ_TRACK_COUNT-1];

    logic free_found;
    logic [TRACK_SLOT_W-1:0] free_slot;
    logic duplicate_live;
    logic live_resp_found;
    logic [TRACK_SLOT_W-1:0] live_resp_slot;
    logic live_resp_addr_match;
    logic probe_read_allowed;
    logic command_fire;
    logic read_command_fire;
    logic samecycle_new_response;
    logic exact_live_response;
    logic exact_response;
    logic probe_source_matches;

    initial begin
        if (READ_TRACK_COUNT < 1)
            $fatal(1, "PROD_SEAM_P9 READ_TRACK_COUNT must be >= 1");
        if (BACKEND_READ_TAG_W < 1)
            $fatal(1, "PROD_SEAM_P9 BACKEND_READ_TAG_W must be >= 1");
        if (LINE_ADDR_W < 1)
            $fatal(1, "PROD_SEAM_P9 LINE_ADDR_W must be >= 1");
        if (LINE_WORDS < 1)
            $fatal(1, "PROD_SEAM_P9 LINE_WORDS must be >= 1");
    end

    always_comb begin
        free_found = 1'b0;
        free_slot = '0;
        duplicate_live = 1'b0;
        live_resp_found = 1'b0;
        live_resp_slot = '0;
        for (integer slot = 0; slot < READ_TRACK_COUNT; slot = slot + 1) begin
            if (!free_found && !track_valid_q[slot]) begin
                free_found = 1'b1;
                free_slot = TRACK_SLOT_W'(slot);
            end
            if (track_valid_q[slot]
                && track_tag_q[slot] == probe_read_tag_q)
                duplicate_live = 1'b1;
            if (!live_resp_found && track_valid_q[slot]
                && track_tag_q[slot] == backend_resp_read_tag_i) begin
                live_resp_found = 1'b1;
                live_resp_slot = TRACK_SLOT_W'(slot);
            end
        end

        live_resp_addr_match = live_resp_found
            && track_addr_q[integer'(live_resp_slot)] == backend_resp_line_addr_i;

        probe_source_matches = upstream_cmd_valid_i
            && upstream_cmd_write_i == probe_write_q
            && upstream_cmd_read_tag_i == probe_read_tag_q
            && upstream_cmd_word_addr_i == probe_word_addr_q
            && upstream_cmd_wdata_i == probe_wdata_q
            && upstream_cmd_line_addr_i == probe_line_addr_q;

        read_capacity_full_o = !free_found;
        read_duplicate_block_o = probe_valid_q && !probe_write_q && duplicate_live;
        probe_read_allowed = free_found && !duplicate_live;

        backend_cmd_valid_o = probe_valid_q
            && (probe_write_q || probe_read_allowed);
        backend_cmd_write_o = probe_write_q;
        backend_cmd_read_tag_o = probe_read_tag_q;
        backend_cmd_word_addr_o = probe_word_addr_q;
        backend_cmd_wdata_o = probe_wdata_q;
        backend_cmd_line_addr_o = probe_line_addr_q;

        command_fire = backend_cmd_valid_o && backend_cmd_ready_i;
        upstream_cmd_ready_o = command_fire;
        read_command_fire = command_fire && !probe_write_q;

        samecycle_new_response = backend_resp_valid_i
            && read_command_fire
            && backend_resp_read_tag_i == probe_read_tag_q
            && backend_resp_line_addr_i == probe_line_addr_q;
        exact_live_response = backend_resp_valid_i && live_resp_addr_match;
        exact_response = exact_live_response || samecycle_new_response;

        read_resp_protocol_error_o = backend_resp_valid_i && !exact_response;

        upstream_resp_valid_o = exact_response;
        upstream_resp_read_tag_o = '0;
        upstream_resp_line_addr_o = '0;
        upstream_resp_fault_o = 1'b0;
        for (integer word = 0; word < LINE_WORDS; word = word + 1)
            upstream_resp_data_o[word] = '0;

        if (exact_live_response) begin
            upstream_resp_read_tag_o =
                track_tag_q[integer'(live_resp_slot)];
            upstream_resp_line_addr_o =
                track_addr_q[integer'(live_resp_slot)];
            upstream_resp_fault_o = backend_resp_fault_i;
            for (integer word = 0; word < LINE_WORDS; word = word + 1)
                upstream_resp_data_o[word] = backend_resp_data_i[word];
        end else if (samecycle_new_response) begin
            upstream_resp_read_tag_o = probe_read_tag_q;
            upstream_resp_line_addr_o = probe_line_addr_q;
            upstream_resp_fault_o = backend_resp_fault_i;
            for (integer word = 0; word < LINE_WORDS; word = word + 1)
                upstream_resp_data_o[word] = backend_resp_data_i[word];
        end

        read_outstanding_o = '0;
        for (integer slot = 0; slot < READ_TRACK_COUNT; slot = slot + 1)
            if (track_valid_q[slot])
                read_outstanding_o = read_outstanding_o + READ_OCCUPANCY_W'(1);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            probe_valid_q <= 1'b0;
            probe_write_q <= 1'b0;
            probe_read_tag_q <= '0;
            probe_word_addr_q <= '0;
            probe_wdata_q <= '0;
            probe_line_addr_q <= '0;
            track_valid_q <= '0;
            for (integer slot = 0; slot < READ_TRACK_COUNT; slot = slot + 1) begin
                track_tag_q[slot] <= '0;
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
                $fatal(1, "PROD_SEAM_P9_UPSTREAM_COMMAND_CHANGED_BEFORE_ACCEPT");

            if (command_fire)
                probe_valid_q <= 1'b0;

            if (exact_live_response)
                track_valid_q[integer'(live_resp_slot)] <= 1'b0;

            if (read_command_fire && !samecycle_new_response) begin
                track_valid_q[integer'(free_slot)] <= 1'b1;
                track_tag_q[integer'(free_slot)] <= probe_read_tag_q;
                track_addr_q[integer'(free_slot)] <= probe_line_addr_q;
            end
        end
    end
endmodule
