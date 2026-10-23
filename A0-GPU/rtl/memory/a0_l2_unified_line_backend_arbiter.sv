`timescale 1ns/1ps

/*
 * PROD-SEAM-P23 unified line-backend arbiter.
 *
 * Multiple home-slice refill reads and one durable writeback stream share one
 * command channel. Commands are first captured into a one-entry hold so the
 * selected identity/payload is stable across backend backpressure. Arbitration
 * is round-robin across {read ports..., writeback}. Responses remain typed:
 * reads return by {home_slice, global_requester_tag}; write statuses retain the
 * opaque durable writeback attempt id and are passed to the P21 owner.
 */
module a0_l2_unified_line_backend_arbiter #(
    parameter integer READ_PORT_COUNT = 4,
    parameter integer LINE_WORDS = 8,
    parameter integer GLOBAL_TAG_W = 4,
    parameter integer LINE_ADDR_W = 29,
    parameter integer WB_ATTEMPT_ID_W = 10,
    parameter integer READ_PORT_ID_W = (READ_PORT_COUNT <= 1) ? 1 : $clog2(READ_PORT_COUNT),
    parameter integer BACKEND_READ_TAG_W = READ_PORT_ID_W + GLOBAL_TAG_W,
    parameter integer SOURCE_COUNT = READ_PORT_COUNT + 1,
    parameter integer SOURCE_ID_W = (SOURCE_COUNT <= 1) ? 1 : $clog2(SOURCE_COUNT)
) (
    input logic clk,
    input logic rst_n,

    input logic [READ_PORT_COUNT-1:0] read_valid_i,
    output logic [READ_PORT_COUNT-1:0] read_ready_o,
    input logic [GLOBAL_TAG_W-1:0] read_global_tag_i [0:READ_PORT_COUNT-1],
    input logic [LINE_ADDR_W-1:0] read_line_addr_i [0:READ_PORT_COUNT-1],

    input logic wb_valid_i,
    output logic wb_ready_o,
    input logic [WB_ATTEMPT_ID_W-1:0] wb_attempt_id_i,
    input logic [LINE_ADDR_W-1:0] wb_line_addr_i,
    input logic [31:0] wb_data_i [0:LINE_WORDS-1],

    output logic backend_cmd_valid_o,
    input logic backend_cmd_ready_i,
    output logic backend_cmd_write_o,
    output logic [BACKEND_READ_TAG_W-1:0] backend_cmd_read_tag_o,
    output logic [WB_ATTEMPT_ID_W-1:0] backend_cmd_wb_attempt_id_o,
    output logic [LINE_ADDR_W-1:0] backend_cmd_line_addr_o,
    output logic [31:0] backend_cmd_data_o [0:LINE_WORDS-1],

    input logic backend_read_resp_valid_i,
    input logic [BACKEND_READ_TAG_W-1:0] backend_read_resp_tag_i,
    input logic [LINE_ADDR_W-1:0] backend_read_resp_line_addr_i,
    input logic backend_read_resp_fault_i,
    input logic [31:0] backend_read_resp_data_i [0:LINE_WORDS-1],

    output logic [READ_PORT_COUNT-1:0] read_resp_valid_o,
    output logic [GLOBAL_TAG_W-1:0] read_resp_global_tag_o [0:READ_PORT_COUNT-1],
    output logic [LINE_ADDR_W-1:0] read_resp_line_addr_o [0:READ_PORT_COUNT-1],
    output logic [READ_PORT_COUNT-1:0] read_resp_fault_o,
    output logic [31:0] read_resp_data_o [0:READ_PORT_COUNT-1][0:LINE_WORDS-1],

    input logic backend_wb_status_valid_i,
    input logic [WB_ATTEMPT_ID_W-1:0] backend_wb_status_attempt_id_i,
    input logic backend_wb_status_success_i,
    input logic backend_wb_status_retryable_i,
    output logic wb_status_valid_o,
    output logic [WB_ATTEMPT_ID_W-1:0] wb_status_attempt_id_o,
    output logic wb_status_success_o,
    output logic wb_status_retryable_o,

    output logic read_resp_protocol_error_o
);
    logic hold_valid_q;
    logic hold_write_q;
    logic [BACKEND_READ_TAG_W-1:0] hold_read_tag_q;
    logic [WB_ATTEMPT_ID_W-1:0] hold_wb_attempt_q;
    logic [LINE_ADDR_W-1:0] hold_line_q;
    logic [31:0] hold_data_q [0:LINE_WORDS-1];
    logic [SOURCE_ID_W-1:0] rr_q;

    logic select_found;
    logic [SOURCE_ID_W-1:0] select_source;
    logic select_write;
    logic [READ_PORT_ID_W-1:0] response_port;
    logic response_port_valid;
    integer off;
    integer scan;
    integer source;
    integer word;
    integer reset_word;

    initial begin
        if (READ_PORT_COUNT < 1) $fatal(1, "P23 READ_PORT_COUNT must be >=1");
        if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
            $fatal(1, "P23 LINE_WORDS must be power of two");
        if (GLOBAL_TAG_W < 1 || LINE_ADDR_W < 1 || WB_ATTEMPT_ID_W < 1)
            $fatal(1, "P23 widths must be >=1");
    end

    always_comb begin
        select_found = 1'b0;
        select_source = '0;
        for (off = 0; off < SOURCE_COUNT; off = off + 1) begin
            scan = integer'(rr_q) + off;
            if (scan >= SOURCE_COUNT) scan = scan - SOURCE_COUNT;
            if (!select_found) begin
                if (scan < READ_PORT_COUNT && read_valid_i[scan]) begin
                    select_found = 1'b1;
                    select_source = SOURCE_ID_W'(scan);
                end else if (scan == READ_PORT_COUNT && wb_valid_i) begin
                    select_found = 1'b1;
                    select_source = SOURCE_ID_W'(scan);
                end
            end
        end
        select_write = select_found && integer'(select_source) == READ_PORT_COUNT;

        read_ready_o = '0;
        wb_ready_o = 1'b0;
        if (!hold_valid_q && select_found) begin
            if (select_write) wb_ready_o = 1'b1;
            else read_ready_o[integer'(select_source)] = 1'b1;
        end

        backend_cmd_valid_o = hold_valid_q;
        backend_cmd_write_o = hold_write_q;
        backend_cmd_read_tag_o = hold_read_tag_q;
        backend_cmd_wb_attempt_id_o = hold_wb_attempt_q;
        backend_cmd_line_addr_o = hold_line_q;
        for (word = 0; word < LINE_WORDS; word = word + 1)
            backend_cmd_data_o[word] = hold_data_q[word];

        response_port = backend_read_resp_tag_i[BACKEND_READ_TAG_W-1 -: READ_PORT_ID_W];
        response_port_valid = integer'(response_port) < READ_PORT_COUNT;
        read_resp_protocol_error_o = backend_read_resp_valid_i && !response_port_valid;
        read_resp_valid_o = '0;
        read_resp_fault_o = '0;
        for (source = 0; source < READ_PORT_COUNT; source = source + 1) begin
            read_resp_global_tag_o[source] = '0;
            read_resp_line_addr_o[source] = '0;
            for (word = 0; word < LINE_WORDS; word = word + 1)
                read_resp_data_o[source][word] = '0;
        end
        if (backend_read_resp_valid_i && response_port_valid) begin
            read_resp_valid_o[integer'(response_port)] = 1'b1;
            read_resp_global_tag_o[integer'(response_port)] = backend_read_resp_tag_i[GLOBAL_TAG_W-1:0];
            read_resp_line_addr_o[integer'(response_port)] = backend_read_resp_line_addr_i;
            read_resp_fault_o[integer'(response_port)] = backend_read_resp_fault_i;
            for (word = 0; word < LINE_WORDS; word = word + 1)
                read_resp_data_o[integer'(response_port)][word] = backend_read_resp_data_i[word];
        end

        wb_status_valid_o = backend_wb_status_valid_i;
        wb_status_attempt_id_o = backend_wb_status_attempt_id_i;
        wb_status_success_o = backend_wb_status_success_i;
        wb_status_retryable_o = backend_wb_status_retryable_i;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hold_valid_q <= 1'b0;
            hold_write_q <= 1'b0;
            hold_read_tag_q <= '0;
            hold_wb_attempt_q <= '0;
            hold_line_q <= '0;
            rr_q <= '0;
            for (reset_word = 0; reset_word < LINE_WORDS; reset_word = reset_word + 1)
                hold_data_q[reset_word] <= '0;
        end else begin
            if (hold_valid_q && backend_cmd_ready_i)
                hold_valid_q <= 1'b0;

            if (!hold_valid_q && select_found) begin
                hold_valid_q <= 1'b1;
                hold_write_q <= select_write;
                hold_read_tag_q <= '0;
                hold_wb_attempt_q <= '0;
                hold_line_q <= '0;
                for (reset_word = 0; reset_word < LINE_WORDS; reset_word = reset_word + 1)
                    hold_data_q[reset_word] <= '0;
                if (select_write) begin
                    hold_wb_attempt_q <= wb_attempt_id_i;
                    hold_line_q <= wb_line_addr_i;
                    for (reset_word = 0; reset_word < LINE_WORDS; reset_word = reset_word + 1)
                        hold_data_q[reset_word] <= wb_data_i[reset_word];
                end else begin
                    hold_read_tag_q <= {READ_PORT_ID_W'(select_source), read_global_tag_i[integer'(select_source)]};
                    hold_line_q <= read_line_addr_i[integer'(select_source)];
                end
                if (integer'(select_source) == SOURCE_COUNT - 1) rr_q <= '0;
                else rr_q <= select_source + SOURCE_ID_W'(1);
            end
        end
    end
endmodule
