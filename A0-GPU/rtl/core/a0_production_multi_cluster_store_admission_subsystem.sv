`timescale 1ns/1ps

/*
 * PROD-SEAM-P6 production pending-store admission-ordering composition.
 *
 * This successor preserves the closed P2 multi-cluster load/refill path and
 * aggregates every P1 cluster's conservative physical-store observation into
 * one cache-domain vector broadcast to all sliced-L2 banks.  The existing L2
 * primitive invalidates resident matching lines and kills matching in-flight
 * refill installation.  Store write data still uses the legacy memory path;
 * dirty state, writeback, atomics and full coherence remain later milestones.
 */
module a0_production_multi_cluster_store_admission_subsystem #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer RESIDENT_WAVES = 4,
    parameter integer WAVE_SIZE = 32,
    parameter integer PHYSICAL_LANES = 8,
    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer SCALAR_REG_COUNT = 32,
    parameter integer PREDICATE_REG_COUNT = 16,
    parameter integer SCALAR_PREDICATE_REG_COUNT = 16,
    parameter integer RECONV_STACK_DEPTH = 16,
    parameter integer GLOBAL_MEMORY_WORDS = 1024,
    parameter integer PROGRAM_WORDS = 256,
    parameter bit ENABLE_LOAD_MSHR = 1'b1,
    parameter integer MSHR_COUNT = 2,
    parameter integer MSHR_LINE_WORDS = 8,
    parameter integer STORE_QUEUE_DEPTH = 4,
    parameter integer STORE_SEQ_W = 64,
    parameter integer L1_SET_COUNT = 64,
    parameter integer L2_SLICE_COUNT = 4,
    parameter integer L2_SET_COUNT_PER_SLICE = 256,
    parameter integer L2_MISS_COUNT_PER_SLICE = 16,

    parameter integer WAVE_ID_W =
        (RESIDENT_WAVES <= 1) ? 1 : $clog2(RESIDENT_WAVES),
    parameter integer PC_W =
        (PROGRAM_WORDS <= 1) ? 1 : $clog2(PROGRAM_WORDS),
    parameter integer VECTOR_REG_INDEX_W =
        (VECTOR_REG_COUNT <= 1) ? 1 : $clog2(VECTOR_REG_COUNT),
    parameter integer SCALAR_REG_INDEX_W =
        (SCALAR_REG_COUNT <= 1) ? 1 : $clog2(SCALAR_REG_COUNT),
    parameter integer PREDICATE_INDEX_W =
        (PREDICATE_REG_COUNT <= 1) ? 1 : $clog2(PREDICATE_REG_COUNT),
    parameter integer MSHR_ENTRY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT),
    parameter integer MSHR_LINE_ADDR_W =
        32 - ((MSHR_LINE_WORDS <= 1) ? 1 : $clog2(MSHR_LINE_WORDS)),
    parameter integer MSHR_OCCUPANCY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT + 1),
    parameter integer CU_ID_W =
        (CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER),
    parameter integer CLUSTER_LOCAL_TAG_W = CU_ID_W + MSHR_ENTRY_W,
    parameter integer CLUSTER_ID_W =
        (CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT),
    parameter integer NETWORK_TAG_W = CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
) (
    input logic clk,
    input logic rst_n,

    input logic [CUS_PER_CLUSTER-1:0]
        run_enable_i [0:CLUSTER_COUNT-1],
    input logic [CUS_PER_CLUSTER-1:0]
        program_we_i [0:CLUSTER_COUNT-1],
    input logic [PC_W-1:0]
        program_waddr_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [63:0]
        program_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    input logic [CUS_PER_CLUSTER-1:0]
        alloc_valid_i [0:CLUSTER_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        alloc_wave_id_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [CUS_PER_CLUSTER-1:0]
        alloc_ready_o [0:CLUSTER_COUNT-1],
    input logic [PC_W-1:0]
        alloc_pc_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [WAVE_SIZE-1:0]
        alloc_exec_mask_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [WAVE_ID_W-1:0]
        alloc_vrf_context_id_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    input logic [CUS_PER_CLUSTER-1:0]
        release_valid_i [0:CLUSTER_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        release_wave_id_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    input logic [CUS_PER_CLUSTER-1:0]
        scalar_we_i [0:CLUSTER_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        scalar_wwave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [SCALAR_REG_INDEX_W-1:0]
        scalar_wreg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [31:0]
        scalar_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    input logic [CUS_PER_CLUSTER-1:0]
        predicate_we_i [0:CLUSTER_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        predicate_wwave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [PREDICATE_INDEX_W-1:0]
        predicate_wreg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [WAVE_SIZE-1:0]
        predicate_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    input logic [CUS_PER_CLUSTER-1:0]
        vector_we_i [0:CLUSTER_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        vector_wcontext_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [VECTOR_REG_INDEX_W-1:0]
        vector_wreg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [$clog2(WAVE_SIZE)-1:0]
        vector_wlane_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [31:0]
        vector_wdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    output logic [CUS_PER_CLUSTER-1:0]
        mem_req_valid_o [0:CLUSTER_COUNT-1],
    output logic [CUS_PER_CLUSTER-1:0]
        mem_req_write_o [0:CLUSTER_COUNT-1],
    output logic [WAVE_ID_W-1:0]
        mem_req_wave_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [WAVE_ID_W-1:0]
        mem_req_context_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [WAVE_SIZE-1:0]
        mem_req_lane_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [31:0]
        mem_req_addr_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:WAVE_SIZE-1],
    output logic [31:0]
        mem_req_wdata_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:WAVE_SIZE-1],

    input logic [CUS_PER_CLUSTER-1:0]
        mem_resp_valid_i [0:CLUSTER_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        mem_resp_wave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [WAVE_ID_W-1:0]
        mem_resp_context_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [CUS_PER_CLUSTER-1:0]
        mem_resp_fault_i [0:CLUSTER_COUNT-1],
    input logic [31:0]
        mem_resp_rdata_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:WAVE_SIZE-1],

    output logic [MSHR_OCCUPANCY_W-1:0]
        mshr_occupancy_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [CUS_PER_CLUSTER-1:0]
        mshr_full_o [0:CLUSTER_COUNT-1],
    output logic [CUS_PER_CLUSTER-1:0]
        mshr_merge_event_o [0:CLUSTER_COUNT-1],
    output logic [RESIDENT_WAVES-1:0]
        mshr_active_wave_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [CUS_PER_CLUSTER-1:0]
        mshr_tag_error_o [0:CLUSTER_COUNT-1],
    output logic [CUS_PER_CLUSTER-1:0]
        memory_outstanding_o [0:CLUSTER_COUNT-1],
    output logic [CUS_PER_CLUSTER-1:0]
        memory_tag_error_o [0:CLUSTER_COUNT-1],

    input logic [CUS_PER_CLUSTER-1:0]
        policy_override_valid_i [0:CLUSTER_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        policy_override_wave_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    input logic [WAVE_ID_W-1:0]
        debug_vector_context_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [VECTOR_REG_INDEX_W-1:0]
        debug_vector_reg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [$clog2(WAVE_SIZE)-1:0]
        debug_vector_lane_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [31:0]
        debug_vector_data_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    input logic [WAVE_ID_W-1:0]
        debug_context_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [SCALAR_REG_INDEX_W-1:0]
        debug_scalar_reg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [PREDICATE_INDEX_W-1:0]
        debug_predicate_reg_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [CUS_PER_CLUSTER-1:0]
        debug_context_valid_o [0:CLUSTER_COUNT-1],
    output logic [PC_W-1:0]
        debug_pc_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [WAVE_SIZE-1:0]
        debug_exec_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [CUS_PER_CLUSTER-1:0]
        debug_halted_o [0:CLUSTER_COUNT-1],
    output logic [31:0]
        debug_scalar_data_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [WAVE_SIZE-1:0]
        debug_predicate_data_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],

    output logic [CUS_PER_CLUSTER-1:0]
        retire_valid_o [0:CLUSTER_COUNT-1],
    output logic [WAVE_ID_W-1:0]
        retire_wave_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [PC_W-1:0]
        retire_pc_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [CUS_PER_CLUSTER-1:0]
        engine_busy_o [0:CLUSTER_COUNT-1],
    output logic [CUS_PER_CLUSTER-1:0]
        faulted_o [0:CLUSTER_COUNT-1],
    output logic [RESIDENT_WAVES-1:0]
        valid_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [RESIDENT_WAVES-1:0]
        ready_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [RESIDENT_WAVES-1:0]
        halted_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [WAVE_ID_W-1:0]
        rr_cursor_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [CUS_PER_CLUSTER-1:0]
        all_halted_o [0:CLUSTER_COUNT-1],

    output logic [CLUSTER_COUNT-1:0] line_resp_tag_error_o,
    output logic [CLUSTER_COUNT-1:0] store_observe_valid_o,
    output logic [(CUS_PER_CLUSTER * WAVE_SIZE)-1:0]
        store_observe_lane_mask_o [0:CLUSTER_COUNT-1],
    output logic [31:0]
        store_observe_word_addr_o
            [0:CLUSTER_COUNT-1]
            [0:(CUS_PER_CLUSTER * WAVE_SIZE)-1],

    output logic [CLUSTER_COUNT-1:0] cluster_local_req_tag_error_o,
    output logic [CLUSTER_COUNT-1:0] noc_req_tag_error_o,
    output logic [L2_SLICE_COUNT-1:0] slice_resp_protocol_error_o,
    output logic [CLUSTER_COUNT-1:0] noc_resp_tag_error_o,

    output logic [L2_SLICE_COUNT-1:0] line_mem_req_valid_o,
    input logic [L2_SLICE_COUNT-1:0] line_mem_req_ready_i,
    output logic [NETWORK_TAG_W-1:0]
        line_mem_req_network_tag_o [0:L2_SLICE_COUNT-1],
    output logic [MSHR_LINE_ADDR_W-1:0]
        line_mem_req_line_addr_o [0:L2_SLICE_COUNT-1],
    input logic [L2_SLICE_COUNT-1:0] line_mem_resp_valid_i,
    input logic [NETWORK_TAG_W-1:0]
        line_mem_resp_network_tag_i [0:L2_SLICE_COUNT-1],
    input logic [MSHR_LINE_ADDR_W-1:0]
        line_mem_resp_line_addr_i [0:L2_SLICE_COUNT-1],
    input logic line_mem_resp_fault_i [0:L2_SLICE_COUNT-1],
    input logic [31:0]
        line_mem_resp_data_i [0:L2_SLICE_COUNT-1][0:MSHR_LINE_WORDS-1]
);

    localparam integer CLUSTER_STORE_LANES =
        CUS_PER_CLUSTER * WAVE_SIZE;
    localparam integer GLOBAL_STORE_LANES =
        CLUSTER_COUNT * CLUSTER_STORE_LANES;

    logic global_store_valid;
    logic [GLOBAL_STORE_LANES-1:0] global_store_lane_mask;
    logic [31:0] global_store_word_addr [0:GLOBAL_STORE_LANES-1];

    logic [CLUSTER_COUNT-1:0] cluster_line_req_valid;
    logic [CLUSTER_COUNT-1:0] cluster_line_req_ready;
    logic [CLUSTER_LOCAL_TAG_W-1:0]
        cluster_line_req_tag [0:CLUSTER_COUNT-1];
    logic [MSHR_LINE_ADDR_W-1:0]
        cluster_line_req_addr [0:CLUSTER_COUNT-1];

    logic [CLUSTER_COUNT-1:0] cluster_line_resp_valid;
    logic [CLUSTER_LOCAL_TAG_W-1:0]
        cluster_line_resp_tag [0:CLUSTER_COUNT-1];
    logic [MSHR_LINE_ADDR_W-1:0]
        cluster_line_resp_addr [0:CLUSTER_COUNT-1];
    logic cluster_line_resp_fault [0:CLUSTER_COUNT-1];
    logic [31:0]
        cluster_line_resp_data [0:CLUSTER_COUNT-1][0:MSHR_LINE_WORDS-1];

    logic [CLUSTER_COUNT-1:0] cluster_local_resp_ready;
    integer store_cluster;
    integer store_lane;

    assign cluster_local_resp_ready = '1;

    always_comb begin
        global_store_valid = 1'b0;
        global_store_lane_mask = '0;
        for (store_cluster = 0; store_cluster < CLUSTER_COUNT;
             store_cluster = store_cluster + 1) begin
            if (store_observe_valid_o[store_cluster])
                global_store_valid = 1'b1;
            for (store_lane = 0; store_lane < CLUSTER_STORE_LANES;
                 store_lane = store_lane + 1) begin
                global_store_lane_mask[
                    (store_cluster * CLUSTER_STORE_LANES) + store_lane
                ] = store_observe_valid_o[store_cluster]
                    && store_observe_lane_mask_o[store_cluster][store_lane];
                global_store_word_addr[
                    (store_cluster * CLUSTER_STORE_LANES) + store_lane
                ] = store_observe_word_addr_o[store_cluster][store_lane];
            end
        end
    end

    initial begin
        if (CLUSTER_COUNT < 1)
            $fatal(1, "CLUSTER_COUNT must be >= 1");
        if (CUS_PER_CLUSTER < 1)
            $fatal(1, "CUS_PER_CLUSTER must be >= 1");
        if (MSHR_COUNT < 1)
            $fatal(1, "MSHR_COUNT must be >= 1");
        if (MSHR_LINE_WORDS < 2 || (MSHR_LINE_WORDS & (MSHR_LINE_WORDS - 1)) != 0)
            $fatal(1, "MSHR_LINE_WORDS must be a power of two >= 2");
    end

    genvar cluster;
    generate
        for (cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin : g_cluster
            a0_production_cu_cluster_frontend #(
                .CU_COUNT(CUS_PER_CLUSTER),
                .RESIDENT_WAVES(RESIDENT_WAVES),
                .WAVE_SIZE(WAVE_SIZE),
                .PHYSICAL_LANES(PHYSICAL_LANES),
                .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
                .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
                .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
                .SCALAR_PREDICATE_REG_COUNT(SCALAR_PREDICATE_REG_COUNT),
                .RECONV_STACK_DEPTH(RECONV_STACK_DEPTH),
                .GLOBAL_MEMORY_WORDS(GLOBAL_MEMORY_WORDS),
                .PROGRAM_WORDS(PROGRAM_WORDS),
                .ENABLE_LOAD_MSHR(ENABLE_LOAD_MSHR),
                .MSHR_COUNT(MSHR_COUNT),
                .MSHR_LINE_WORDS(MSHR_LINE_WORDS),
                .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
                .STORE_SEQ_W(STORE_SEQ_W),
                .L1_SET_COUNT(L1_SET_COUNT)
            ) frontend (
                .clk(clk),
                .rst_n(rst_n),
                .run_enable_i(run_enable_i[cluster]),
                .program_we_i(program_we_i[cluster]),
                .program_waddr_i(program_waddr_i[cluster]),
                .program_wdata_i(program_wdata_i[cluster]),
                .alloc_valid_i(alloc_valid_i[cluster]),
                .alloc_wave_id_i(alloc_wave_id_i[cluster]),
                .alloc_ready_o(alloc_ready_o[cluster]),
                .alloc_pc_i(alloc_pc_i[cluster]),
                .alloc_exec_mask_i(alloc_exec_mask_i[cluster]),
                .alloc_vrf_context_id_i(alloc_vrf_context_id_i[cluster]),
                .release_valid_i(release_valid_i[cluster]),
                .release_wave_id_i(release_wave_id_i[cluster]),
                .scalar_we_i(scalar_we_i[cluster]),
                .scalar_wwave_i(scalar_wwave_i[cluster]),
                .scalar_wreg_i(scalar_wreg_i[cluster]),
                .scalar_wdata_i(scalar_wdata_i[cluster]),
                .predicate_we_i(predicate_we_i[cluster]),
                .predicate_wwave_i(predicate_wwave_i[cluster]),
                .predicate_wreg_i(predicate_wreg_i[cluster]),
                .predicate_wdata_i(predicate_wdata_i[cluster]),
                .vector_we_i(vector_we_i[cluster]),
                .vector_wcontext_i(vector_wcontext_i[cluster]),
                .vector_wreg_i(vector_wreg_i[cluster]),
                .vector_wlane_i(vector_wlane_i[cluster]),
                .vector_wdata_i(vector_wdata_i[cluster]),
                .mem_req_valid_o(mem_req_valid_o[cluster]),
                .mem_req_write_o(mem_req_write_o[cluster]),
                .mem_req_wave_o(mem_req_wave_o[cluster]),
                .mem_req_context_o(mem_req_context_o[cluster]),
                .mem_req_lane_mask_o(mem_req_lane_mask_o[cluster]),
                .mem_req_addr_o(mem_req_addr_o[cluster]),
                .mem_req_wdata_o(mem_req_wdata_o[cluster]),
                .mem_resp_valid_i(mem_resp_valid_i[cluster]),
                .mem_resp_wave_i(mem_resp_wave_i[cluster]),
                .mem_resp_context_i(mem_resp_context_i[cluster]),
                .mem_resp_fault_i(mem_resp_fault_i[cluster]),
                .mem_resp_rdata_i(mem_resp_rdata_i[cluster]),
                .mshr_occupancy_o(mshr_occupancy_o[cluster]),
                .mshr_full_o(mshr_full_o[cluster]),
                .mshr_merge_event_o(mshr_merge_event_o[cluster]),
                .mshr_active_wave_mask_o(mshr_active_wave_mask_o[cluster]),
                .mshr_tag_error_o(mshr_tag_error_o[cluster]),
                .memory_outstanding_o(memory_outstanding_o[cluster]),
                .memory_tag_error_o(memory_tag_error_o[cluster]),
                .policy_override_valid_i(policy_override_valid_i[cluster]),
                .policy_override_wave_i(policy_override_wave_i[cluster]),
                .debug_vector_context_i(debug_vector_context_i[cluster]),
                .debug_vector_reg_i(debug_vector_reg_i[cluster]),
                .debug_vector_lane_i(debug_vector_lane_i[cluster]),
                .debug_vector_data_o(debug_vector_data_o[cluster]),
                .debug_context_i(debug_context_i[cluster]),
                .debug_scalar_reg_i(debug_scalar_reg_i[cluster]),
                .debug_predicate_reg_i(debug_predicate_reg_i[cluster]),
                .debug_context_valid_o(debug_context_valid_o[cluster]),
                .debug_pc_o(debug_pc_o[cluster]),
                .debug_exec_mask_o(debug_exec_mask_o[cluster]),
                .debug_halted_o(debug_halted_o[cluster]),
                .debug_scalar_data_o(debug_scalar_data_o[cluster]),
                .debug_predicate_data_o(debug_predicate_data_o[cluster]),
                .retire_valid_o(retire_valid_o[cluster]),
                .retire_wave_o(retire_wave_o[cluster]),
                .retire_pc_o(retire_pc_o[cluster]),
                .engine_busy_o(engine_busy_o[cluster]),
                .faulted_o(faulted_o[cluster]),
                .valid_mask_o(valid_mask_o[cluster]),
                .ready_mask_o(ready_mask_o[cluster]),
                .halted_mask_o(halted_mask_o[cluster]),
                .rr_cursor_o(rr_cursor_o[cluster]),
                .all_halted_o(all_halted_o[cluster]),
                .line_req_valid_o(cluster_line_req_valid[cluster]),
                .line_req_ready_i(cluster_line_req_ready[cluster]),
                .line_req_global_tag_o(cluster_line_req_tag[cluster]),
                .line_req_line_addr_o(cluster_line_req_addr[cluster]),
                .line_resp_valid_i(cluster_line_resp_valid[cluster]),
                .line_resp_global_tag_i(cluster_line_resp_tag[cluster]),
                .line_resp_line_addr_i(cluster_line_resp_addr[cluster]),
                .line_resp_fault_i(cluster_line_resp_fault[cluster]),
                .line_resp_data_i(cluster_line_resp_data[cluster]),
                .line_resp_tag_error_o(line_resp_tag_error_o[cluster]),
                .store_observe_valid_o(store_observe_valid_o[cluster]),
                .store_observe_lane_mask_o(store_observe_lane_mask_o[cluster]),
                .store_observe_word_addr_o(store_observe_word_addr_o[cluster])
            );
        end
    endgenerate

    a0_mc_noc_sliced_l2_store_admission_subsystem #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT),
        .LINE_WORDS(MSHR_LINE_WORDS),
        .L2_SLICE_COUNT(L2_SLICE_COUNT),
        .L2_SET_COUNT_PER_SLICE(L2_SET_COUNT_PER_SLICE),
        .L2_MISS_COUNT_PER_SLICE(L2_MISS_COUNT_PER_SLICE),
        .STORE_LANES(GLOBAL_STORE_LANES)
    ) store_admission_noc_l2 (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_local_req_valid_i(cluster_line_req_valid),
        .cluster_local_req_ready_o(cluster_line_req_ready),
        .cluster_local_req_tag_i(cluster_line_req_tag),
        .cluster_local_req_line_addr_i(cluster_line_req_addr),
        .cluster_local_req_tag_error_o(cluster_local_req_tag_error_o),
        .cluster_local_resp_valid_o(cluster_line_resp_valid),
        .cluster_local_resp_ready_i(cluster_local_resp_ready),
        .cluster_local_resp_tag_o(cluster_line_resp_tag),
        .cluster_local_resp_line_addr_o(cluster_line_resp_addr),
        .cluster_local_resp_fault_o(cluster_line_resp_fault),
        .cluster_local_resp_data_o(cluster_line_resp_data),
        .global_store_valid_i(global_store_valid),
        .global_store_lane_mask_i(global_store_lane_mask),
        .global_store_word_addr_i(global_store_word_addr),
        .noc_req_tag_error_o(noc_req_tag_error_o),
        .slice_resp_protocol_error_o(slice_resp_protocol_error_o),
        .noc_resp_tag_error_o(noc_resp_tag_error_o),
        .line_mem_req_valid_o(line_mem_req_valid_o),
        .line_mem_req_ready_i(line_mem_req_ready_i),
        .line_mem_req_network_tag_o(line_mem_req_network_tag_o),
        .line_mem_req_line_addr_o(line_mem_req_line_addr_o),
        .line_mem_resp_valid_i(line_mem_resp_valid_i),
        .line_mem_resp_network_tag_i(line_mem_resp_network_tag_i),
        .line_mem_resp_line_addr_i(line_mem_resp_line_addr_i),
        .line_mem_resp_fault_i(line_mem_resp_fault_i),
        .line_mem_resp_data_i(line_mem_resp_data_i)
    );

endmodule
