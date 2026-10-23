`timescale 1ns/1ps

/*
 * PROD-SEAM-P1 successor production CU cluster frontend: private L1/MSHRs,
 * cluster-local physical store ordering, peer-conflict gating, and the P0
 * L2-free requester seam.  No L2 or NoC is embedded here. Requester identity
 * remains cluster-owned and never enters a core.
 */
module a0_production_cu_cluster_frontend #(
    parameter integer CU_COUNT = 4,
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
    parameter integer CLIENT_ID_W =
        (CU_COUNT <= 1) ? 1 : $clog2(CU_COUNT),
    parameter integer GLOBAL_TAG_W = CLIENT_ID_W + MSHR_ENTRY_W
) (
    input logic clk,
    input logic rst_n,

    input logic [CU_COUNT-1:0] run_enable_i,
    input logic [CU_COUNT-1:0] program_we_i,
    input logic [PC_W-1:0] program_waddr_i [0:CU_COUNT-1],
    input logic [63:0] program_wdata_i [0:CU_COUNT-1],

    input logic [CU_COUNT-1:0] alloc_valid_i,
    input logic [WAVE_ID_W-1:0] alloc_wave_id_i [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] alloc_ready_o,
    input logic [PC_W-1:0] alloc_pc_i [0:CU_COUNT-1],
    input logic [WAVE_SIZE-1:0] alloc_exec_mask_i [0:CU_COUNT-1],
    input logic [WAVE_ID_W-1:0]
        alloc_vrf_context_id_i [0:CU_COUNT-1],

    input logic [CU_COUNT-1:0] release_valid_i,
    input logic [WAVE_ID_W-1:0] release_wave_id_i [0:CU_COUNT-1],

    input logic [CU_COUNT-1:0] scalar_we_i,
    input logic [WAVE_ID_W-1:0] scalar_wwave_i [0:CU_COUNT-1],
    input logic [SCALAR_REG_INDEX_W-1:0]
        scalar_wreg_i [0:CU_COUNT-1],
    input logic [31:0] scalar_wdata_i [0:CU_COUNT-1],

    input logic [CU_COUNT-1:0] predicate_we_i,
    input logic [WAVE_ID_W-1:0] predicate_wwave_i [0:CU_COUNT-1],
    input logic [PREDICATE_INDEX_W-1:0]
        predicate_wreg_i [0:CU_COUNT-1],
    input logic [WAVE_SIZE-1:0] predicate_wdata_i [0:CU_COUNT-1],

    input logic [CU_COUNT-1:0] vector_we_i,
    input logic [WAVE_ID_W-1:0] vector_wcontext_i [0:CU_COUNT-1],
    input logic [VECTOR_REG_INDEX_W-1:0]
        vector_wreg_i [0:CU_COUNT-1],
    input logic [$clog2(WAVE_SIZE)-1:0]
        vector_wlane_i [0:CU_COUNT-1],
    input logic [31:0] vector_wdata_i [0:CU_COUNT-1],

    /* Per-CU legacy wave-memory interfaces remain independent. */
    output logic [CU_COUNT-1:0] mem_req_valid_o,
    output logic [CU_COUNT-1:0] mem_req_write_o,
    output logic [WAVE_ID_W-1:0] mem_req_wave_o [0:CU_COUNT-1],
    output logic [WAVE_ID_W-1:0] mem_req_context_o [0:CU_COUNT-1],
    output logic [WAVE_SIZE-1:0] mem_req_lane_mask_o [0:CU_COUNT-1],
    output logic [31:0]
        mem_req_addr_o [0:CU_COUNT-1][0:WAVE_SIZE-1],
    output logic [31:0]
        mem_req_wdata_o [0:CU_COUNT-1][0:WAVE_SIZE-1],

    input logic [CU_COUNT-1:0] mem_resp_valid_i,
    input logic [WAVE_ID_W-1:0] mem_resp_wave_i [0:CU_COUNT-1],
    input logic [WAVE_ID_W-1:0] mem_resp_context_i [0:CU_COUNT-1],
    input logic [CU_COUNT-1:0] mem_resp_fault_i,
    input logic [31:0]
        mem_resp_rdata_i [0:CU_COUNT-1][0:WAVE_SIZE-1],

    output logic [MSHR_OCCUPANCY_W-1:0]
        mshr_occupancy_o [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] mshr_full_o,
    output logic [CU_COUNT-1:0] mshr_merge_event_o,
    output logic [RESIDENT_WAVES-1:0]
        mshr_active_wave_mask_o [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] mshr_tag_error_o,
    output logic [CU_COUNT-1:0] memory_outstanding_o,
    output logic [CU_COUNT-1:0] memory_tag_error_o,

    input logic [CU_COUNT-1:0] policy_override_valid_i,
    input logic [WAVE_ID_W-1:0]
        policy_override_wave_i [0:CU_COUNT-1],

    input logic [WAVE_ID_W-1:0]
        debug_vector_context_i [0:CU_COUNT-1],
    input logic [VECTOR_REG_INDEX_W-1:0]
        debug_vector_reg_i [0:CU_COUNT-1],
    input logic [$clog2(WAVE_SIZE)-1:0]
        debug_vector_lane_i [0:CU_COUNT-1],
    output logic [31:0] debug_vector_data_o [0:CU_COUNT-1],

    input logic [WAVE_ID_W-1:0] debug_context_i [0:CU_COUNT-1],
    input logic [SCALAR_REG_INDEX_W-1:0]
        debug_scalar_reg_i [0:CU_COUNT-1],
    input logic [PREDICATE_INDEX_W-1:0]
        debug_predicate_reg_i [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] debug_context_valid_o,
    output logic [PC_W-1:0] debug_pc_o [0:CU_COUNT-1],
    output logic [WAVE_SIZE-1:0] debug_exec_mask_o [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] debug_halted_o,
    output logic [31:0] debug_scalar_data_o [0:CU_COUNT-1],
    output logic [WAVE_SIZE-1:0]
        debug_predicate_data_o [0:CU_COUNT-1],

    output logic [CU_COUNT-1:0] retire_valid_o,
    output logic [WAVE_ID_W-1:0] retire_wave_o [0:CU_COUNT-1],
    output logic [PC_W-1:0] retire_pc_o [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] engine_busy_o,
    output logic [CU_COUNT-1:0] faulted_o,
    output logic [RESIDENT_WAVES-1:0] valid_mask_o [0:CU_COUNT-1],
    output logic [RESIDENT_WAVES-1:0] ready_mask_o [0:CU_COUNT-1],
    output logic [RESIDENT_WAVES-1:0] halted_mask_o [0:CU_COUNT-1],
    output logic [WAVE_ID_W-1:0] rr_cursor_o [0:CU_COUNT-1],
    output logic [CU_COUNT-1:0] all_halted_o,

    /* P0 L2-free post-local-fabric request/response seam. */
    output logic line_req_valid_o,
    input logic line_req_ready_i,
    output logic [GLOBAL_TAG_W-1:0] line_req_global_tag_o,
    output logic [MSHR_LINE_ADDR_W-1:0] line_req_line_addr_o,
    input logic line_resp_valid_i,
    input logic [GLOBAL_TAG_W-1:0] line_resp_global_tag_i,
    input logic [MSHR_LINE_ADDR_W-1:0] line_resp_line_addr_i,
    input logic line_resp_fault_i,
    input logic [31:0]
        line_resp_data_i [0:MSHR_LINE_WORDS-1],
    output logic line_resp_tag_error_o,

    /* Flattened physical-store visibility for the downstream cache domain. */
    output logic store_observe_valid_o,
    output logic [(CU_COUNT * WAVE_SIZE)-1:0] store_observe_lane_mask_o,
    output logic [31:0]
        store_observe_word_addr_o [0:(CU_COUNT * WAVE_SIZE)-1]
);

    logic [CU_COUNT-1:0] core_line_req_valid;
    logic [CU_COUNT-1:0] core_line_req_ready;
    logic [MSHR_ENTRY_W-1:0]
        core_line_req_entry [0:CU_COUNT-1];
    logic [MSHR_LINE_ADDR_W-1:0]
        core_line_req_line_addr [0:CU_COUNT-1];

    logic [CU_COUNT-1:0] shared_client_req_valid;
    logic [CU_COUNT-1:0] shared_client_req_ready;
    logic [MSHR_ENTRY_W-1:0]
        shared_client_req_local_tag [0:CU_COUNT-1];
    logic [MSHR_LINE_ADDR_W-1:0]
        shared_client_req_line_addr [0:CU_COUNT-1];

    /*
     * One request holding slot per CU decouples the private L1/MSHR ready
     * path from the shared round-robin fabric.  Some legacy L1 request
     * sources compute valid as part of a ready/valid chain; feeding the
     * fabric's arbitration-ready combinationally back into that chain would
     * create a cross-CU combinational loop.  The slot therefore makes the
     * fabric-facing valid/payload registered while still allowing a consumed
     * request to be replaced in the same cycle.
     */
    logic [CU_COUNT-1:0] line_req_hold_valid_q;
    logic [MSHR_ENTRY_W-1:0]
        line_req_hold_entry_q [0:CU_COUNT-1];
    logic [MSHR_LINE_ADDR_W-1:0]
        line_req_hold_addr_q [0:CU_COUNT-1];
    logic [CU_COUNT-1:0] shared_client_resp_valid;
    logic [MSHR_ENTRY_W-1:0]
        shared_client_resp_local_tag [0:CU_COUNT-1];
    logic [MSHR_LINE_ADDR_W-1:0]
        shared_client_resp_line_addr [0:CU_COUNT-1];
    logic shared_client_resp_fault [0:CU_COUNT-1];
    logic [31:0] shared_client_resp_data
        [0:CU_COUNT-1][0:MSHR_LINE_WORDS-1];

    logic [CU_COUNT-1:0] store_launch_valid;
    logic [CU_COUNT-1:0] core_store_terminal_valid;
    logic [CU_COUNT-1:0] core_store_terminal_fault;
    logic [CU_COUNT-1:0] controller_pending_valid;

    logic [CU_COUNT-1:0] launch_observe_valid;
    logic [WAVE_SIZE-1:0]
        launch_observe_lane_mask [0:CU_COUNT-1];
    logic [31:0]
        launch_observe_word_addr [0:CU_COUNT-1][0:WAVE_SIZE-1];

    logic [CU_COUNT-1:0] ordering_store_valid;
    logic [WAVE_SIZE-1:0]
        ordering_store_lane_mask [0:CU_COUNT-1];
    logic [31:0]
        ordering_store_word_addr [0:CU_COUNT-1][0:WAVE_SIZE-1];

    logic [CU_COUNT-1:0] terminal_store_valid;
    logic [CU_COUNT-1:0] terminal_store_fault;
    logic [WAVE_SIZE-1:0]
        terminal_store_lane_mask [0:CU_COUNT-1];
    logic [31:0]
        terminal_store_word_addr [0:CU_COUNT-1][0:WAVE_SIZE-1];

    logic [CU_COUNT-1:0] fabric_peer_conflict;
    logic [CU_COUNT-1:0]
        peer_ordering_valid [0:CU_COUNT-1];
    logic [WAVE_SIZE-1:0]
        peer_ordering_lane_mask [0:CU_COUNT-1][0:CU_COUNT-1];
    logic [31:0] peer_ordering_word_addr
        [0:CU_COUNT-1][0:CU_COUNT-1][0:WAVE_SIZE-1];

    genvar cu;
    genvar source;
    genvar store_lane;

    initial begin
        if (CU_COUNT < 1 || CU_COUNT > 4)
            $fatal(1, "production cluster supports CU_COUNT 1..4");
        if (WAVE_SIZE != 32)
            $fatal(1, "production cluster requires WAVE_SIZE=32");
        if (MSHR_LINE_WORDS != 8)
            $fatal(1, "production cluster requires LINE_WORDS=8");
        if (MSHR_COUNT < 2)
            $fatal(1, "production cluster requires MSHR_COUNT>=2");
        if (L1_SET_COUNT != 64)
            $fatal(1, "production cluster requires L1_SET_COUNT=64");
        if (!ENABLE_LOAD_MSHR)
            $fatal(1, "production cluster requires ENABLE_LOAD_MSHR=1");
    end

    generate
        for (cu = 0; cu < CU_COUNT; cu = cu + 1) begin : g_cu
            assign store_launch_valid[cu] =
                mem_req_valid_o[cu] && mem_req_write_o[cu];

            assign shared_client_req_valid[cu] =
                line_req_hold_valid_q[cu] && !fabric_peer_conflict[cu];
            assign shared_client_req_local_tag[cu] =
                line_req_hold_entry_q[cu];
            assign shared_client_req_line_addr[cu] =
                line_req_hold_addr_q[cu];

            /*
             * Empty slots accept independently of fabric arbitration.  A full
             * slot may be refilled only when the held request is accepted.
             * Peer-store conflict preserves the predecessor behavior by
             * blocking both acceptance and forwarding while the conflict is
             * live.
             */
            assign core_line_req_ready[cu] =
                !line_req_hold_valid_q[cu]
                || (
                    !fabric_peer_conflict[cu]
                    && shared_client_req_ready[cu]
                );

            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    line_req_hold_valid_q[cu] <= 1'b0;
                    line_req_hold_entry_q[cu] <= '0;
                    line_req_hold_addr_q[cu] <= '0;
                end else begin
                    case ({
                        core_line_req_valid[cu]
                            && core_line_req_ready[cu],
                        shared_client_req_valid[cu]
                            && shared_client_req_ready[cu]
                    })
                        2'b10: begin
                            line_req_hold_valid_q[cu] <= 1'b1;
                            line_req_hold_entry_q[cu] <=
                                core_line_req_entry[cu];
                            line_req_hold_addr_q[cu] <=
                                core_line_req_line_addr[cu];
                        end
                        2'b01: begin
                            line_req_hold_valid_q[cu] <= 1'b0;
                        end
                        2'b11: begin
                            line_req_hold_valid_q[cu] <= 1'b1;
                            line_req_hold_entry_q[cu] <=
                                core_line_req_entry[cu];
                            line_req_hold_addr_q[cu] <=
                                core_line_req_line_addr[cu];
                        end
                        default: begin
                        end
                    endcase
                end
            end

            for (source = 0; source < CU_COUNT;
                 source = source + 1) begin : g_peer_source
                assign peer_ordering_valid[cu][source] =
                    (source == cu) ? 1'b0 : ordering_store_valid[source];
                assign peer_ordering_lane_mask[cu][source] =
                    (source == cu) ? '0 : ordering_store_lane_mask[source];
                for (store_lane = 0; store_lane < WAVE_SIZE;
                     store_lane = store_lane + 1) begin : g_peer_lane
                    assign peer_ordering_word_addr[cu][source][store_lane] =
                        ordering_store_word_addr[source][store_lane];
                end
            end

            /*
             * Warning-clean terminal metadata contract.  The store-order
             * controller may only emit a terminal event while the matching
             * physical-store owner is still pending, and its terminal fault
             * bit must preserve the originating core response fault.
             * This is an assertion-only contract; it does not alter traffic.
             */
            always_ff @(posedge clk) begin
                if (rst_n && terminal_store_valid[cu]) begin
                    if (!controller_pending_valid[cu])
                        $fatal(1, "PROD_DEPS_WARN_TERMINAL_PENDING_OWNER");
                    if (terminal_store_fault[cu] !== core_store_terminal_fault[cu])
                        $fatal(1, "PROD_DEPS_WARN_TERMINAL_FAULT_PROVENANCE");
                end
            end

            a0_multi_wave_core #(
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
                .STORE_OBSERVER_COUNT(CU_COUNT)
            ) core (
                .clk(clk),
                .rst_n(rst_n),
                .run_enable(run_enable_i[cu]),
                .program_we(program_we_i[cu]),
                .program_waddr(program_waddr_i[cu]),
                .program_wdata(program_wdata_i[cu]),
                .alloc_valid(alloc_valid_i[cu]),
                .alloc_wave_id(alloc_wave_id_i[cu]),
                .alloc_ready(alloc_ready_o[cu]),
                .alloc_pc(alloc_pc_i[cu]),
                .alloc_exec_mask(alloc_exec_mask_i[cu]),
                .alloc_vrf_context_id(alloc_vrf_context_id_i[cu]),
                .release_valid(release_valid_i[cu]),
                .release_wave_id(release_wave_id_i[cu]),
                .scalar_we(scalar_we_i[cu]),
                .scalar_wwave(scalar_wwave_i[cu]),
                .scalar_wreg(scalar_wreg_i[cu]),
                .scalar_wdata(scalar_wdata_i[cu]),
                .predicate_we(predicate_we_i[cu]),
                .predicate_wwave(predicate_wwave_i[cu]),
                .predicate_wreg(predicate_wreg_i[cu]),
                .predicate_wdata(predicate_wdata_i[cu]),
                .vector_we(vector_we_i[cu]),
                .vector_wcontext(vector_wcontext_i[cu]),
                .vector_wreg(vector_wreg_i[cu]),
                .vector_wlane(vector_wlane_i[cu]),
                .vector_wdata(vector_wdata_i[cu]),
                .mem_req_valid_o(mem_req_valid_o[cu]),
                .mem_req_write_o(mem_req_write_o[cu]),
                .mem_req_wave_o(mem_req_wave_o[cu]),
                .mem_req_context_o(mem_req_context_o[cu]),
                .mem_req_lane_mask_o(mem_req_lane_mask_o[cu]),
                .mem_req_addr_o(mem_req_addr_o[cu]),
                .mem_req_wdata_o(mem_req_wdata_o[cu]),
                .mem_resp_valid_i(mem_resp_valid_i[cu]),
                .mem_resp_wave_i(mem_resp_wave_i[cu]),
                .mem_resp_context_i(mem_resp_context_i[cu]),
                .mem_resp_fault_i(mem_resp_fault_i[cu]),
                .mem_resp_rdata_i(mem_resp_rdata_i[cu]),
                .cluster_store_observe_enable_i(1'b1),
                .launch_observe_valid_i(launch_observe_valid),
                .launch_observe_lane_mask_i(launch_observe_lane_mask),
                .launch_observe_word_addr_i(launch_observe_word_addr),
                .ordering_store_valid_i(peer_ordering_valid[cu]),
                .ordering_store_lane_mask_i(peer_ordering_lane_mask[cu]),
                .ordering_store_word_addr_i(peer_ordering_word_addr[cu]),
                .terminal_store_valid_i(terminal_store_valid),
                .terminal_store_lane_mask_i(terminal_store_lane_mask),
                .terminal_store_word_addr_i(terminal_store_word_addr),
                .store_terminal_valid_o(core_store_terminal_valid[cu]),
                .store_terminal_fault_o(core_store_terminal_fault[cu]),
                .mshr_mem_req_valid_o(core_line_req_valid[cu]),
                .mshr_mem_req_ready_i(core_line_req_ready[cu]),
                .mshr_mem_req_entry_o(core_line_req_entry[cu]),
                .mshr_mem_req_line_addr_o(core_line_req_line_addr[cu]),
                .mshr_mem_resp_valid_i(shared_client_resp_valid[cu]),
                .mshr_mem_resp_entry_i(shared_client_resp_local_tag[cu]),
                .mshr_mem_resp_line_addr_i(shared_client_resp_line_addr[cu]),
                .mshr_mem_resp_fault_i(shared_client_resp_fault[cu]),
                .mshr_mem_resp_line_data_i(shared_client_resp_data[cu]),
                .mshr_occupancy_o(mshr_occupancy_o[cu]),
                .mshr_full_o(mshr_full_o[cu]),
                .mshr_merge_event_o(mshr_merge_event_o[cu]),
                .mshr_active_wave_mask_o(mshr_active_wave_mask_o[cu]),
                .mshr_tag_error_o(mshr_tag_error_o[cu]),
                .memory_outstanding_o(memory_outstanding_o[cu]),
                .memory_tag_error_o(memory_tag_error_o[cu]),
                .policy_override_valid_i(policy_override_valid_i[cu]),
                .policy_override_wave_i(policy_override_wave_i[cu]),
                .debug_vector_context_i(debug_vector_context_i[cu]),
                .debug_vector_reg_i(debug_vector_reg_i[cu]),
                .debug_vector_lane_i(debug_vector_lane_i[cu]),
                .debug_vector_data_o(debug_vector_data_o[cu]),
                .debug_context_i(debug_context_i[cu]),
                .debug_scalar_reg_i(debug_scalar_reg_i[cu]),
                .debug_predicate_reg_i(debug_predicate_reg_i[cu]),
                .debug_context_valid_o(debug_context_valid_o[cu]),
                .debug_pc_o(debug_pc_o[cu]),
                .debug_exec_mask_o(debug_exec_mask_o[cu]),
                .debug_halted_o(debug_halted_o[cu]),
                .debug_scalar_data_o(debug_scalar_data_o[cu]),
                .debug_predicate_data_o(debug_predicate_data_o[cu]),
                .retire_valid_o(retire_valid_o[cu]),
                .retire_wave_o(retire_wave_o[cu]),
                .retire_pc_o(retire_pc_o[cu]),
                .engine_busy_o(engine_busy_o[cu]),
                .faulted_o(faulted_o[cu]),
                .valid_mask_o(valid_mask_o[cu]),
                .ready_mask_o(ready_mask_o[cu]),
                .halted_mask_o(halted_mask_o[cu]),
                .rr_cursor_o(rr_cursor_o[cu]),
                .all_halted_o(all_halted_o[cu])
            );
        end
    endgenerate

    a0_cluster_store_order_controller #(
        .CU_COUNT(CU_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(MSHR_LINE_WORDS),
        .WAVE_ID_W(WAVE_ID_W),
        .CONTEXT_ID_W(WAVE_ID_W),
        .LINE_ADDR_W(MSHR_LINE_ADDR_W)
    ) store_order_controller (
        .clk(clk),
        .rst_n(rst_n),
        .store_launch_valid_i(store_launch_valid),
        .store_launch_wave_i(mem_req_wave_o),
        .store_launch_context_i(mem_req_context_o),
        .store_launch_lane_mask_i(mem_req_lane_mask_o),
        .store_launch_word_addr_i(mem_req_addr_o),
        .store_terminal_valid_i(core_store_terminal_valid),
        .store_terminal_wave_i(mem_resp_wave_i),
        .store_terminal_context_i(mem_resp_context_i),
        .store_terminal_fault_i(core_store_terminal_fault),
        .fabric_candidate_valid_i(line_req_hold_valid_q),
        .fabric_candidate_line_addr_i(line_req_hold_addr_q),
        .fabric_peer_conflict_o(fabric_peer_conflict),
        .pending_store_valid_o(controller_pending_valid),
        .launch_observe_valid_o(launch_observe_valid),
        .launch_observe_lane_mask_o(launch_observe_lane_mask),
        .launch_observe_word_addr_o(launch_observe_word_addr),
        .ordering_store_valid_o(ordering_store_valid),
        .ordering_store_lane_mask_o(ordering_store_lane_mask),
        .ordering_store_word_addr_o(ordering_store_word_addr),
        .terminal_store_valid_o(terminal_store_valid),
        .terminal_store_fault_o(terminal_store_fault),
        .terminal_store_lane_mask_o(terminal_store_lane_mask),
        .terminal_store_word_addr_o(terminal_store_word_addr)
    );

    a0_production_cluster_line_seam #(
        .CLIENT_COUNT(CU_COUNT),
        .LOCAL_TAG_W(MSHR_ENTRY_W),
        .STORE_LANES_PER_CLIENT(WAVE_SIZE),
        .LINE_WORDS(MSHR_LINE_WORDS)
    ) production_line_seam (
        .clk(clk),
        .rst_n(rst_n),
        .client_req_valid_i(shared_client_req_valid),
        .client_req_ready_o(shared_client_req_ready),
        .client_req_local_tag_i(shared_client_req_local_tag),
        .client_req_line_addr_i(shared_client_req_line_addr),
        .client_resp_valid_o(shared_client_resp_valid),
        .client_resp_local_tag_o(shared_client_resp_local_tag),
        .client_resp_line_addr_o(shared_client_resp_line_addr),
        .client_resp_fault_o(shared_client_resp_fault),
        .client_resp_data_o(shared_client_resp_data),
        .client_store_valid_i(ordering_store_valid),
        .client_store_lane_mask_i(ordering_store_lane_mask),
        .client_store_word_addr_i(ordering_store_word_addr),
        .line_req_valid_o(line_req_valid_o),
        .line_req_ready_i(line_req_ready_i),
        .line_req_global_tag_o(line_req_global_tag_o),
        .line_req_line_addr_o(line_req_line_addr_o),
        .line_resp_valid_i(line_resp_valid_i),
        .line_resp_global_tag_i(line_resp_global_tag_i),
        .line_resp_line_addr_i(line_resp_line_addr_i),
        .line_resp_fault_i(line_resp_fault_i),
        .line_resp_data_i(line_resp_data_i),
        .line_resp_tag_error_o(line_resp_tag_error_o),
        .store_observe_valid_o(store_observe_valid_o),
        .store_observe_lane_mask_o(store_observe_lane_mask_o),
        .store_observe_word_addr_o(store_observe_word_addr_o)
    );

endmodule
