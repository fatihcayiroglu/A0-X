`timescale 1ns/1ps

/*
 * A0 RTL9B-2 memory-service boundary.
 *
 * Legacy wave-memory traffic remains a bypass path. Physical legacy stores
 * are additionally observed by the L1 at launch so matching cached lines are
 * invalidated conservatively.
 *
 * The MSHR line channel is cacheable:
 *
 *     MSHR client -> L1 -> line backend
 *                    ^
 *                    |
 *                  refill
 *
 * Backend line responses always enter the L1 first. The L1 forwards every
 * backend response to the MSHR-facing response channel while selectively
 * installing successful, non-killed, non-store-conflicting refills.
 *
 * No write allocate, dirty state, writeback, coherence, translation, L2,
 * memory-controller, or ordering policy is introduced here.
 */
module a0_memory_service_boundary #(
    parameter integer WAVE_SIZE = 32,
    parameter integer WAVE_ID_W = 2,
    parameter integer LINE_WORDS = 8,
    parameter integer ENTRY_W = 1,
    parameter integer LINE_ADDR_W = 29,
    parameter integer MSHR_COUNT = 2,
    parameter integer L1_SET_COUNT = 64,
    parameter integer STORE_OBSERVER_COUNT = 1
) (
    input logic clk,
    input logic rst_n,

    input logic cluster_store_observe_enable_i,
    input logic [STORE_OBSERVER_COUNT-1:0] launch_observe_valid_i,
    input logic [WAVE_SIZE-1:0]
        launch_observe_lane_mask_i [0:STORE_OBSERVER_COUNT-1],
    input logic [31:0] launch_observe_word_addr_i
        [0:STORE_OBSERVER_COUNT-1][0:WAVE_SIZE-1],

    input  logic legacy_req_valid_i,
    input  logic legacy_req_write_i,
    input  logic [WAVE_ID_W-1:0] legacy_req_wave_i,
    input  logic [WAVE_ID_W-1:0] legacy_req_context_i,
    input  logic [WAVE_SIZE-1:0] legacy_req_lane_mask_i,
    input  logic [31:0] legacy_req_addr_i [0:WAVE_SIZE-1],
    input  logic [31:0] legacy_req_wdata_i [0:WAVE_SIZE-1],

    output logic legacy_req_valid_o,
    output logic legacy_req_write_o,
    output logic [WAVE_ID_W-1:0] legacy_req_wave_o,
    output logic [WAVE_ID_W-1:0] legacy_req_context_o,
    output logic [WAVE_SIZE-1:0] legacy_req_lane_mask_o,
    output logic [31:0] legacy_req_addr_o [0:WAVE_SIZE-1],
    output logic [31:0] legacy_req_wdata_o [0:WAVE_SIZE-1],

    input  logic legacy_resp_valid_i,
    input  logic [WAVE_ID_W-1:0] legacy_resp_wave_i,
    input  logic [WAVE_ID_W-1:0] legacy_resp_context_i,
    input  logic legacy_resp_fault_i,
    input  logic [31:0] legacy_resp_rdata_i [0:WAVE_SIZE-1],

    output logic legacy_resp_valid_o,
    output logic [WAVE_ID_W-1:0] legacy_resp_wave_o,
    output logic [WAVE_ID_W-1:0] legacy_resp_context_o,
    output logic legacy_resp_fault_o,
    output logic [31:0] legacy_resp_rdata_o [0:WAVE_SIZE-1],

    input  logic line_req_valid_i,
    output logic line_req_ready_o,
    input  logic [ENTRY_W-1:0] line_req_entry_i,
    input  logic [LINE_ADDR_W-1:0] line_req_line_addr_i,

    output logic line_req_valid_o,
    input  logic line_req_ready_i,
    output logic [ENTRY_W-1:0] line_req_entry_o,
    output logic [LINE_ADDR_W-1:0] line_req_line_addr_o,

    input  logic line_resp_valid_i,
    input  logic [ENTRY_W-1:0] line_resp_entry_i,
    input  logic [LINE_ADDR_W-1:0] line_resp_line_addr_i,
    input  logic line_resp_fault_i,
    input  logic [31:0] line_resp_data_i [0:LINE_WORDS-1],

    output logic line_resp_valid_o,
    output logic [ENTRY_W-1:0] line_resp_entry_o,
    output logic [LINE_ADDR_W-1:0] line_resp_line_addr_o,
    output logic line_resp_fault_o,
    output logic [31:0] line_resp_data_o [0:LINE_WORDS-1]
);

    localparam integer TOTAL_STORE_LANES =
        STORE_OBSERVER_COUNT * WAVE_SIZE;

    logic l1_store_valid;
    logic [TOTAL_STORE_LANES-1:0] l1_store_lane_mask;
    logic [31:0] l1_store_word_addr [0:TOTAL_STORE_LANES-1];

    integer lane;
    integer store_source;
    integer store_lane;

    /* Raw cluster launch only; pending state never enters private L1. */
    always_comb begin
        l1_store_valid = 1'b0;
        l1_store_lane_mask = '0;
        for (store_lane = 0; store_lane < TOTAL_STORE_LANES;
             store_lane = store_lane + 1) begin
            l1_store_word_addr[store_lane] = '0;
        end

        if (cluster_store_observe_enable_i) begin
            l1_store_valid = |launch_observe_valid_i;
            for (store_source = 0;
                 store_source < STORE_OBSERVER_COUNT;
                 store_source = store_source + 1) begin
                for (store_lane = 0; store_lane < WAVE_SIZE;
                     store_lane = store_lane + 1) begin
                    l1_store_lane_mask[
                        store_source * WAVE_SIZE + store_lane
                    ] = launch_observe_valid_i[store_source]
                        && launch_observe_lane_mask_i[
                            store_source
                        ][store_lane];
                    l1_store_word_addr[
                        store_source * WAVE_SIZE + store_lane
                    ] = launch_observe_word_addr_i[
                        store_source
                    ][store_lane];
                end
            end
        end else begin
            l1_store_valid = legacy_req_valid_i && legacy_req_write_i;
            for (store_lane = 0; store_lane < WAVE_SIZE;
                 store_lane = store_lane + 1) begin
                l1_store_lane_mask[store_lane] =
                    legacy_req_lane_mask_i[store_lane];
                l1_store_word_addr[store_lane] =
                    legacy_req_addr_i[store_lane];
            end
        end
    end

    /*
     * RTL7C/RTL8C legacy channel remains an exact bypass.
     * The L1 observes only physical store launch metadata.
     */
    always_comb begin
        legacy_req_valid_o = legacy_req_valid_i;
        legacy_req_write_o = legacy_req_write_i;
        legacy_req_wave_o = legacy_req_wave_i;
        legacy_req_context_o = legacy_req_context_i;
        legacy_req_lane_mask_o = legacy_req_lane_mask_i;

        legacy_resp_valid_o = legacy_resp_valid_i;
        legacy_resp_wave_o = legacy_resp_wave_i;
        legacy_resp_context_o = legacy_resp_context_i;
        legacy_resp_fault_o = legacy_resp_fault_i;

        for (lane = 0; lane < WAVE_SIZE; lane = lane + 1) begin
            legacy_req_addr_o[lane] = legacy_req_addr_i[lane];
            legacy_req_wdata_o[lane] = legacy_req_wdata_i[lane];
            legacy_resp_rdata_o[lane] = legacy_resp_rdata_i[lane];
        end
    end

    a0_l1_line_cache #(
        .WAVE_SIZE(TOTAL_STORE_LANES),
        .LINE_WORDS(LINE_WORDS),
        .SET_COUNT(L1_SET_COUNT),
        .MSHR_COUNT(MSHR_COUNT),
        .ENTRY_W(ENTRY_W),
        .LINE_ADDR_W(LINE_ADDR_W)
    ) l1_line_cache (
        .clk(clk),
        .rst_n(rst_n),

        .line_req_valid_i(line_req_valid_i),
        .line_req_ready_o(line_req_ready_o),
        .line_req_entry_i(line_req_entry_i),
        .line_req_line_addr_i(line_req_line_addr_i),

        .line_mem_req_valid_o(line_req_valid_o),
        .line_mem_req_ready_i(line_req_ready_i),
        .line_mem_req_entry_o(line_req_entry_o),
        .line_mem_req_line_addr_o(line_req_line_addr_o),

        .line_mem_resp_valid_i(line_resp_valid_i),
        .line_mem_resp_entry_i(line_resp_entry_i),
        .line_mem_resp_line_addr_i(line_resp_line_addr_i),
        .line_mem_resp_fault_i(line_resp_fault_i),
        .line_mem_resp_data_i(line_resp_data_i),

        .line_resp_valid_o(line_resp_valid_o),
        .line_resp_entry_o(line_resp_entry_o),
        .line_resp_line_addr_o(line_resp_line_addr_o),
        .line_resp_fault_o(line_resp_fault_o),
        .line_resp_data_o(line_resp_data_o),

        .store_valid_i(l1_store_valid),
        .store_lane_mask_i(l1_store_lane_mask),
        .store_word_addr_i(l1_store_word_addr)
    );

endmodule
