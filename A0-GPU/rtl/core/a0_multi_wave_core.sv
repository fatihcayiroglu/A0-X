`timescale 1ns/1ps

/*
 * A0-RTL8C live multi-wave execution core with buffered stores.
 *
 * This is the first A0 RTL block in which multiple resident architectural
 * wave contexts are selected by the RTL7A scheduler and execute through one
 * shared scalar/vector execution path.
 *
 * RTL8B extends the RTL7C shared-engine subset with live MSHR-backed
 * indexed loads while preserving the proven wave-tagged store path:
 *   SADD, SSUB
 *   VADD, VSUB, VMUL, VAND, VOR, VXOR
 *   VCMP_EQ, VCMP_LT, VCMP_LE
 *   VLOADX, VSTOREX
 *   HALT
 *
 * VLOADX is decomposed into 32B/8-word line requests and routed through the
 * RTL8A MSHR table. Multiple resident waves may therefore own outstanding
 * loads concurrently, same-line loads may merge, and backend line responses
 * may return out of order. The one-port architectural VRF refill path remains
 * serialized after a whole wave load completes. VSTOREX remains on the
 * RTL7C single-outstanding backend path; RTL8C-5B2 forwards the youngest older
 * exact store source while suppressing response-cycle physical-source capture.
 *
 * Structured divergence remains on the proven legacy a0_wave_core path until
 * later integration phases. The old core remains the historical regression
 * oracle while this top grows toward full feature parity.
 */
module a0_multi_wave_core #(
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

    /* RTL8B: VLOADX uses the live MSHR path by default. */
    parameter bit ENABLE_LOAD_MSHR = 1'b1,
    parameter integer MSHR_COUNT = 2,
    parameter integer MSHR_LINE_WORDS = 8,

    /* RTL8C: whole-wave stores buffer before the legacy backend. */
    parameter integer STORE_QUEUE_DEPTH = 4,

    /* RTL8C-5A: reset-domain monotonic store ordering identity. */
    parameter integer STORE_SEQ_W = 64,

    /* Bounded-cluster store observation source count. */
    parameter integer STORE_OBSERVER_COUNT = 1,

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
    parameter integer RECONV_SP_W =
        (RECONV_STACK_DEPTH <= 1)
            ? 1
            : $clog2(RECONV_STACK_DEPTH + 1),
    parameter integer RECONV_INDEX_W =
        (RECONV_STACK_DEPTH <= 1)
            ? 1
            : $clog2(RECONV_STACK_DEPTH),
    parameter integer VECTOR_BEAT_COUNT =
        (WAVE_SIZE + PHYSICAL_LANES - 1) / PHYSICAL_LANES,
    parameter integer VECTOR_BEAT_INDEX_W =
        (VECTOR_BEAT_COUNT <= 1) ? 1 : $clog2(VECTOR_BEAT_COUNT),
    parameter integer VECTOR_BEAT_DATA_W = PHYSICAL_LANES * 32,
    parameter integer PHYSICAL_SLOT_W =
        (PHYSICAL_LANES <= 1) ? 1 : $clog2(PHYSICAL_LANES),
    parameter integer MSHR_ENTRY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT),
    parameter integer MSHR_WORD_SELECT_W =
        (MSHR_LINE_WORDS <= 1) ? 1 : $clog2(MSHR_LINE_WORDS),
    parameter integer MSHR_LINE_ADDR_W = 32 - MSHR_WORD_SELECT_W,
    parameter integer MSHR_OCCUPANCY_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT + 1),
    parameter integer STORE_QUEUE_OCCUPANCY_W =
        (STORE_QUEUE_DEPTH <= 1)
            ? 1
            : $clog2(STORE_QUEUE_DEPTH + 1)
) (
    input logic clk,
    input logic rst_n,
    input logic run_enable,

    input logic program_we,
    input logic [PC_W-1:0] program_waddr,
    input logic [63:0] program_wdata,

    input logic alloc_valid,
    input logic [WAVE_ID_W-1:0] alloc_wave_id,
    output logic alloc_ready,
    input logic [PC_W-1:0] alloc_pc,
    input logic [WAVE_SIZE-1:0] alloc_exec_mask,
    input logic [WAVE_ID_W-1:0] alloc_vrf_context_id,

    input logic release_valid,
    input logic [WAVE_ID_W-1:0] release_wave_id,

    /* Debug/loader architectural initialization while run_enable=0. */
    input logic scalar_we,
    input logic [WAVE_ID_W-1:0] scalar_wwave,
    input logic [SCALAR_REG_INDEX_W-1:0] scalar_wreg,
    input logic [31:0] scalar_wdata,

    input logic predicate_we,
    input logic [WAVE_ID_W-1:0] predicate_wwave,
    input logic [PREDICATE_INDEX_W-1:0] predicate_wreg,
    input logic [WAVE_SIZE-1:0] predicate_wdata,

    input logic vector_we,
    input logic [WAVE_ID_W-1:0] vector_wcontext,
    input logic [VECTOR_REG_INDEX_W-1:0] vector_wreg,
    input logic [$clog2(WAVE_SIZE)-1:0] vector_wlane,
    input logic [31:0] vector_wdata,

    /*
     * RTL7C single-outstanding, wave-tagged global-memory interface.
     *
     * Request valid is a one-cycle launch pulse. The backend response must
     * echo the request wave/context tag; a mismatched response is rejected
     * and raises faulted_o without consuming the outstanding request.
     */
    output logic mem_req_valid_o,
    output logic mem_req_write_o,
    output logic [WAVE_ID_W-1:0] mem_req_wave_o,
    output logic [WAVE_ID_W-1:0] mem_req_context_o,
    output logic [WAVE_SIZE-1:0] mem_req_lane_mask_o,
    output logic [31:0] mem_req_addr_o [0:WAVE_SIZE-1],
    output logic [31:0] mem_req_wdata_o [0:WAVE_SIZE-1],

    input logic mem_resp_valid_i,
    input logic [WAVE_ID_W-1:0] mem_resp_wave_i,
    input logic [WAVE_ID_W-1:0] mem_resp_context_i,
    input logic mem_resp_fault_i,
    input logic [31:0] mem_resp_rdata_i [0:WAVE_SIZE-1],

    /* Cluster ordering is observational; requester identity stays outside. */
    input logic cluster_store_observe_enable_i,
    input logic [STORE_OBSERVER_COUNT-1:0] launch_observe_valid_i,
    input logic [WAVE_SIZE-1:0]
        launch_observe_lane_mask_i [0:STORE_OBSERVER_COUNT-1],
    input logic [31:0] launch_observe_word_addr_i
        [0:STORE_OBSERVER_COUNT-1][0:WAVE_SIZE-1],
    input logic [STORE_OBSERVER_COUNT-1:0] ordering_store_valid_i,
    input logic [WAVE_SIZE-1:0]
        ordering_store_lane_mask_i [0:STORE_OBSERVER_COUNT-1],
    input logic [31:0] ordering_store_word_addr_i
        [0:STORE_OBSERVER_COUNT-1][0:WAVE_SIZE-1],
    input logic [STORE_OBSERVER_COUNT-1:0] terminal_store_valid_i,
    input logic [WAVE_SIZE-1:0]
        terminal_store_lane_mask_i [0:STORE_OBSERVER_COUNT-1],
    input logic [31:0] terminal_store_word_addr_i
        [0:STORE_OBSERVER_COUNT-1][0:WAVE_SIZE-1],
    output logic store_terminal_valid_o,
    output logic store_terminal_fault_o,

    /*
     * RTL8B line-fill backend for MSHR-backed VLOADX misses. The backend may
     * return accepted line requests out of order by {entry,line} tag.
     */
    output logic mshr_mem_req_valid_o,
    input logic mshr_mem_req_ready_i,
    output logic [MSHR_ENTRY_W-1:0] mshr_mem_req_entry_o,
    output logic [MSHR_LINE_ADDR_W-1:0] mshr_mem_req_line_addr_o,

    input logic mshr_mem_resp_valid_i,
    input logic [MSHR_ENTRY_W-1:0] mshr_mem_resp_entry_i,
    input logic [MSHR_LINE_ADDR_W-1:0] mshr_mem_resp_line_addr_i,
    input logic mshr_mem_resp_fault_i,
    input logic [31:0]
        mshr_mem_resp_line_data_i [0:MSHR_LINE_WORDS-1],

    output logic [MSHR_OCCUPANCY_W-1:0] mshr_occupancy_o,
    output logic mshr_full_o,
    output logic mshr_merge_event_o,
    output logic [RESIDENT_WAVES-1:0] mshr_active_wave_mask_o,
    output logic mshr_tag_error_o,

    output logic memory_outstanding_o,
    output logic memory_tag_error_o,

    /* Optional future policy override; LRR remains the reference policy. */
    input logic policy_override_valid_i,
    input logic [WAVE_ID_W-1:0] policy_override_wave_i,

    /* Verification/debug readback from the architectural vector shadow. */
    input logic [WAVE_ID_W-1:0] debug_vector_context_i,
    input logic [VECTOR_REG_INDEX_W-1:0] debug_vector_reg_i,
    input logic [$clog2(WAVE_SIZE)-1:0] debug_vector_lane_i,
    output logic [31:0] debug_vector_data_o,

    input logic [WAVE_ID_W-1:0] debug_context_i,
    input logic [SCALAR_REG_INDEX_W-1:0] debug_scalar_reg_i,
    input logic [PREDICATE_INDEX_W-1:0] debug_predicate_reg_i,
    output logic debug_context_valid_o,
    output logic [PC_W-1:0] debug_pc_o,
    output logic [WAVE_SIZE-1:0] debug_exec_mask_o,
    output logic debug_halted_o,
    output logic [31:0] debug_scalar_data_o,
    output logic [WAVE_SIZE-1:0] debug_predicate_data_o,

    output logic retire_valid_o,
    output logic [WAVE_ID_W-1:0] retire_wave_o,
    output logic [PC_W-1:0] retire_pc_o,

    output logic engine_busy_o,
    output logic faulted_o,

    output logic [RESIDENT_WAVES-1:0] valid_mask_o,
    output logic [RESIDENT_WAVES-1:0] ready_mask_o,
    output logic [RESIDENT_WAVES-1:0] halted_mask_o,
    output logic [WAVE_ID_W-1:0] rr_cursor_o,
    output logic all_halted_o
);

    localparam logic [7:0] OP_VADD    = 8'h01;
    localparam logic [7:0] OP_VSUB    = 8'h02;
    localparam logic [7:0] OP_VMUL    = 8'h03;
    localparam logic [7:0] OP_VAND    = 8'h04;
    localparam logic [7:0] OP_VOR     = 8'h05;
    localparam logic [7:0] OP_VXOR    = 8'h06;
    localparam logic [7:0] OP_SADD    = 8'h40;
    localparam logic [7:0] OP_SSUB    = 8'h41;
    localparam logic [7:0] OP_VLOADX  = 8'h54;
    localparam logic [7:0] OP_VSTOREX = 8'h55;
    localparam logic [7:0] OP_VCMP_EQ = 8'h60;
    localparam logic [7:0] OP_VCMP_LT = 8'h61;
    localparam logic [7:0] OP_VCMP_LE = 8'h62;
    localparam logic [7:0] OP_HALT    = 8'hFF;

    logic [63:0] program_mem [0:PROGRAM_WORDS-1];

    localparam logic signed [63:0] GLOBAL_MEMORY_WORDS_LIMIT =
        64'(GLOBAL_MEMORY_WORDS);

    /*
     * RECONV_INDEX_W is part of the external parameter contract even though
     * this bounded multi-wave core delegates reconvergence storage to the
     * frontend.  Keep the override legal only when it can represent every
     * configured stack entry; wider encodings remain permitted.
     */
    initial begin : reconv_index_width_contract
        if (
            RECONV_INDEX_W
            < ((RECONV_STACK_DEPTH <= 1)
                ? 1
                : $clog2(RECONV_STACK_DEPTH))
        ) begin
            $fatal(
                1,
                "RECONV_INDEX_W cannot represent RECONV_STACK_DEPTH"
            );
        end
    end

    /* Transitional architectural/debug vector shadow, now wave-qualified. */
    logic [31:0] vector_shadow
        [0:RESIDENT_WAVES-1]
        [0:VECTOR_REG_COUNT-1]
        [0:WAVE_SIZE-1];

    logic frontend_alloc_ready;
    logic alloc_mapping_valid;

    logic frontend_grant_valid;
    logic [WAVE_ID_W-1:0] frontend_grant_wave;
    logic frontend_policy_override_accepted_unused;
    logic frontend_selected_valid;
    logic [PC_W-1:0] frontend_selected_pc;
    logic [WAVE_SIZE-1:0] frontend_selected_exec_mask;
    logic [RECONV_SP_W-1:0] frontend_selected_reconv_sp;
    logic frontend_selected_halted_unused;
    logic frontend_selected_blocked_unused;
    logic frontend_selected_memory_waiting_unused;
    logic frontend_selected_barrier_waiting_unused;
    logic [WAVE_ID_W-1:0] frontend_selected_vrf_context;
    logic [31:0] frontend_scalar_src0;
    logic [31:0] frontend_scalar_src1;
    logic [WAVE_SIZE-1:0] frontend_predicate_data;

    localparam integer FRONTEND_WAVE_COUNT_W =
        (RESIDENT_WAVES <= 1)
            ? 1
            : $clog2(RESIDENT_WAVES + 1);

    /*
     * RTL7B does not consume divergence/policy telemetry yet. Connect every
     * frontend output explicitly so production lint can remain warning-fatal.
     */
    logic frontend_scalar_predicate_unused;
    logic [WAVE_SIZE-1:0] frontend_reconv_parent_unused;
    logic [WAVE_SIZE-1:0] frontend_reconv_else_unused;
    logic frontend_reconv_else_entered_unused;
    logic frontend_pressure_high_unused;
    logic [RESIDENT_WAVES-1:0] frontend_merge_ready_unused;
    logic [FRONTEND_WAVE_COUNT_W-1:0] frontend_ready_count_unused;
    logic [FRONTEND_WAVE_COUNT_W-1:0]
        frontend_memory_ready_count_unused;
    logic [FRONTEND_WAVE_COUNT_W-1:0]
        frontend_non_memory_ready_count_unused;
    logic [FRONTEND_WAVE_COUNT_W-1:0]
        frontend_memory_stalled_count_unused;
    logic [FRONTEND_WAVE_COUNT_W-1:0]
        frontend_merge_ready_count_unused;

    logic [RESIDENT_WAVES-1:0] architectural_ready_mask;
    logic [RESIDENT_WAVES-1:0] scheduler_ready_mask;
    logic [PC_W-1:0] context_pc_by_wave [0:RESIDENT_WAVES-1];
    logic [RESIDENT_WAVES-1:0] execution_block_mask;
    logic [RESIDENT_WAVES-1:0] current_memory_mask;
    logic [RESIDENT_WAVES-1:0] current_load_mask;
    logic [RESIDENT_WAVES-1:0] current_store_mask;
    logic [RESIDENT_WAVES-1:0] memory_ready_mask;
    logic [RESIDENT_WAVES-1:0] non_memory_ready_mask;
    logic [RESIDENT_WAVES-1:0] memory_stalled_mask;
    logic [RESIDENT_WAVES-1:0] blocked_mask_unused;
    logic [RESIDENT_WAVES-1:0] memory_waiting_mask;
    logic [RESIDENT_WAVES-1:0] barrier_waiting_mask_unused;

    logic [63:0] selected_instruction;
    logic [7:0] selected_opcode;
    logic [3:0] selected_flags;
    logic [5:0] selected_dst;
    logic [5:0] selected_src0;
    logic [5:0] selected_src1;
    logic [5:0] selected_src2;
    logic [3:0] selected_pred;

    logic selected_vector_instruction;
    logic selected_memory_instruction;
    logic selected_scalar_instruction;
    logic selected_halt_instruction;
    logic selected_supported_instruction;
    logic classifier_contract_fault;

    logic classifier_tracked;
    logic classifier_src0_enable;
    logic [5:0] classifier_src0;
    logic classifier_src1_enable;
    logic [5:0] classifier_src1;
    logic classifier_src2_enable;
    logic [5:0] classifier_src2;
    logic classifier_vector_dst_enable;
    logic [5:0] classifier_vector_dst;
    logic classifier_predicate_src_enable;
    logic [3:0] classifier_predicate_src;
    logic classifier_predicate_dst_enable;
    logic [3:0] classifier_predicate_dst;

    logic scoreboard_vector_raw_hazard_unused;
    logic scoreboard_vector_waw_hazard_unused;
    logic scoreboard_predicate_raw_hazard_unused;
    logic scoreboard_predicate_waw_hazard_unused;
    logic scoreboard_any_hazard_unused;
    logic scoreboard_issue_allowed;
    logic [VECTOR_REG_COUNT-1:0]
        scoreboard_vector_busy [0:RESIDENT_WAVES-1] /* verilator public_flat */;
    logic [PREDICATE_REG_COUNT-1:0]
        scoreboard_predicate_busy [0:RESIDENT_WAVES-1] /* verilator public_flat */;

    logic direct_retire_fire;
    logic vector_issue_fire;
    logic vector_release_fire;
    logic vector_arch_release_fire;
    logic memory_launch_fire;
    logic legacy_memory_launch_fire;
    logic mshr_load_launch_fire;
    logic mshr_load_internal_fault_fire;
    logic memory_noop_release_fire;
    logic memory_fault_release_fire;
    logic memory_complete_fire;
    logic scoreboard_release_fire;
    logic scheduler_grant_fire;

    logic state_write_valid;
    logic [WAVE_ID_W-1:0] state_write_wave;
    logic [PC_W-1:0] state_write_pc;
    logic [WAVE_SIZE-1:0] state_write_exec_mask;
    logic [RECONV_SP_W-1:0] state_write_reconv_sp;
    logic state_write_halted;
    logic state_write_memory_waiting;

    logic scalar_write_valid;
    logic [WAVE_ID_W-1:0] scalar_write_wave;
    logic [SCALAR_REG_INDEX_W-1:0] scalar_write_reg;
    logic [31:0] scalar_write_data;

    logic predicate_write_valid;
    logic [WAVE_ID_W-1:0] predicate_write_wave;
    logic [PREDICATE_INDEX_W-1:0] predicate_write_reg;
    logic [WAVE_SIZE-1:0] predicate_write_data;

    logic exec_active_q;
    logic [WAVE_ID_W-1:0] exec_wave_q;
    logic [WAVE_ID_W-1:0] exec_vrf_context_q;
    logic [PC_W-1:0] exec_pc_q;
    logic [WAVE_SIZE-1:0] exec_mask_q;
    logic [RECONV_SP_W-1:0] exec_reconv_sp_q;
    logic [WAVE_SIZE-1:0] exec_predicate_mask_q;
    logic [7:0] exec_opcode_q;
    logic exec_predicate_enable_q;
    logic [5:0] exec_dst_q;
    logic [5:0] exec_src0_q;
    logic [5:0] exec_src1_q;
    logic [5:0] exec_src2_q;
    logic [3:0] exec_pred_q;
    logic exec_src0_enable_q;
    logic exec_src1_enable_q;
    logic exec_src2_enable_q;
    logic exec_vector_dst_enable_q;
    logic exec_predicate_dst_enable_q;
    logic [31:0] exec_scalar_base_q;
    logic signed [31:0] exec_imm_q;

    logic [WAVE_SIZE-1:0] compare_accum_q;

    /* RTL9A transparent memory-service boundary client signals. */
    logic service_legacy_req_valid;
    logic service_legacy_req_write;
    logic [WAVE_ID_W-1:0] service_legacy_req_wave;
    logic [WAVE_ID_W-1:0] service_legacy_req_context;
    logic [WAVE_SIZE-1:0] service_legacy_req_lane_mask;
    logic [31:0] service_legacy_req_addr [0:WAVE_SIZE-1];
    logic [31:0] service_legacy_req_wdata [0:WAVE_SIZE-1];
    logic service_legacy_resp_valid;
    logic [WAVE_ID_W-1:0] service_legacy_resp_wave;
    logic [WAVE_ID_W-1:0] service_legacy_resp_context;
    logic service_legacy_resp_fault;
    logic [31:0] service_legacy_resp_rdata [0:WAVE_SIZE-1];
    logic service_mshr_req_valid;
    logic service_mshr_req_ready;
    logic [MSHR_ENTRY_W-1:0] service_mshr_req_entry;
    logic [MSHR_LINE_ADDR_W-1:0] service_mshr_req_line_addr;
    logic service_mshr_resp_valid;
    logic [MSHR_ENTRY_W-1:0] service_mshr_resp_entry;
    logic [MSHR_LINE_ADDR_W-1:0] service_mshr_resp_line_addr;
    logic service_mshr_resp_fault;
    logic [31:0] service_mshr_resp_line_data [0:MSHR_LINE_WORDS-1];

    /*
     * RTL7C single-outstanding global-memory lifecycle.
     *
     * mem_pending_valid_q represents the backend transaction. A completed
     * load remains architecturally blocked through mem_refill_pending_q until
     * every physical VRF beat has been restored. mem_complete_pending_q then
     * serializes the final architectural completion/context update.
     */
    logic mem_pending_valid_q;
    logic mem_pending_load_q;
    logic [WAVE_ID_W-1:0] mem_owner_wave_q;
    logic [WAVE_ID_W-1:0] mem_owner_context_q;
    logic [PC_W-1:0] mem_owner_pc_q;
    logic [PC_W-1:0] mem_owner_resume_pc_q;
    logic [WAVE_SIZE-1:0] mem_owner_exec_mask_q;
    logic [RECONV_SP_W-1:0] mem_owner_reconv_sp_q;
    logic [VECTOR_REG_INDEX_W-1:0] mem_owner_dst_q;
    logic [WAVE_SIZE-1:0] mem_owner_lane_mask_q;

    /* Explicit physical-store ownership for ordering and forwarding. */
    logic [STORE_SEQ_W-1:0] mem_owner_store_seq_q;
    logic [31:0] mem_owner_store_addr_q [0:WAVE_SIZE-1];
    logic [31:0] mem_owner_store_wdata_q [0:WAVE_SIZE-1];

    logic mem_refill_pending_q;
    logic [VECTOR_BEAT_INDEX_W-1:0] mem_refill_beat_q;
    logic [31:0] mem_response_buffer_q [0:WAVE_SIZE-1];

    logic mem_complete_pending_q;
    logic mem_complete_fault_q;

    logic [WAVE_SIZE-1:0] mem_build_lane_mask_q;
    logic [31:0] mem_build_addr_q [0:WAVE_SIZE-1];
    logic [31:0] mem_build_wdata_q [0:WAVE_SIZE-1];
    logic mem_build_fault_q;

    /* RTL8C whole-wave store queue. */
    logic store_queue_enqueue_valid;
    logic store_queue_enqueue_ready;
    logic store_queue_enqueue_fire;
    logic selected_store_queue_issue_ready;
    logic store_queue_internal_fault_fire;
    logic store_queue_drain_valid;
    logic store_queue_drain_ready;
    logic store_queue_drain_fire;
    logic [WAVE_ID_W-1:0] store_queue_drain_wave;
    logic [WAVE_ID_W-1:0] store_queue_drain_context;
    logic [STORE_SEQ_W-1:0] store_queue_drain_seq;
    logic [WAVE_SIZE-1:0] store_queue_drain_lane_mask;
    logic [31:0] store_queue_drain_word_addr [0:WAVE_SIZE-1];
    logic [31:0] store_queue_drain_wdata [0:WAVE_SIZE-1];
    logic [STORE_QUEUE_OCCUPANCY_W-1:0] store_queue_occupancy /* verilator public_flat */;
    logic store_queue_full;
    logic store_queue_empty;
    logic [RESIDENT_WAVES-1:0] store_queue_active_wave_mask_unused;
    logic store_queue_enqueue_stall_unused;

    logic store_queue_probe_valid;
    logic [WAVE_SIZE-1:0] store_queue_probe_lane_mask;
    logic [31:0] store_queue_probe_word_addr [0:WAVE_SIZE-1];
    logic [STORE_SEQ_W-1:0] store_queue_probe_seq_boundary;
    logic store_queue_probe_exact_conflict /* verilator public_flat */;
    logic [WAVE_SIZE-1:0] store_queue_probe_exact_conflict_lane_mask_unused;
    logic store_queue_probe_line_conflict;
    logic [WAVE_SIZE-1:0] store_queue_probe_line_conflict_lane_mask;
    logic [WAVE_SIZE-1:0] store_queue_probe_source_valid_lane_mask;
    logic [WAVE_SIZE-1:0] store_queue_probe_source_ambiguous_lane_mask;
    logic [STORE_SEQ_W-1:0]
        store_queue_probe_source_seq [0:WAVE_SIZE-1];
    logic [31:0] store_queue_probe_source_wdata [0:WAVE_SIZE-1];

    /* One post-address load-order wait slot. */
    logic load_order_wait_valid_q;
    logic [WAVE_ID_W-1:0] load_order_wait_wave_q;
    logic [WAVE_ID_W-1:0] load_order_wait_context_q;
    logic [VECTOR_REG_INDEX_W-1:0] load_order_wait_dst_q;
    logic [PC_W-1:0] load_order_wait_pc_q;
    logic [PC_W-1:0] load_order_wait_resume_pc_q;
    logic [WAVE_SIZE-1:0] load_order_wait_exec_mask_q;
    logic [RECONV_SP_W-1:0] load_order_wait_reconv_sp_q;
    logic [WAVE_SIZE-1:0] load_order_wait_lane_mask_q;
    logic [STORE_SEQ_W-1:0] load_order_wait_store_seq_boundary_q;
    logic [31:0] load_order_wait_addr_q [0:WAVE_SIZE-1];

    logic [STORE_SEQ_W-1:0] store_seq_next_q;
    logic current_load_order_candidate;
    logic physical_store_exact_conflict /* verilator public_flat */;
    logic [WAVE_SIZE-1:0] physical_store_exact_conflict_lane_mask_unused;
    logic physical_store_line_conflict;
    logic [WAVE_SIZE-1:0] physical_store_line_conflict_lane_mask;
    logic [WAVE_SIZE-1:0] physical_store_source_valid_lane_mask;
    logic [WAVE_SIZE-1:0] physical_store_source_ambiguous_lane_mask;
    logic [STORE_SEQ_W-1:0]
        physical_store_source_seq [0:WAVE_SIZE-1];
    logic [31:0] physical_store_source_wdata [0:WAVE_SIZE-1];
    logic [WAVE_SIZE-1:0] load_store_source_valid_lane_mask;
    logic [WAVE_SIZE-1:0] load_store_source_ambiguous_lane_mask;
    logic [STORE_SEQ_W-1:0]
        load_store_source_seq [0:WAVE_SIZE-1];
    logic [31:0] load_store_source_wdata [0:WAVE_SIZE-1];
    logic load_store_line_conflict /* verilator public_flat */;
    logic load_store_unresolved_line_conflict;
    logic [WAVE_SIZE-1:0] load_store_source_physical_lane_mask;
    logic [WAVE_SIZE-1:0] load_store_forward_safe_lane_mask;
    logic [WAVE_SIZE-1:0] load_store_unresolved_line_conflict_lane_mask;
    logic load_order_hold_fire;
    logic load_order_replay_valid;
    logic load_order_replay_fire;
    logic [31:0] load_mshr_req_word_addr [0:WAVE_SIZE-1];

    logic [PC_W-1:0] store_owner_pc_by_wave_q [0:RESIDENT_WAVES-1];
    logic [PC_W-1:0]
        store_owner_resume_pc_by_wave_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0]
        store_owner_exec_mask_by_wave_q [0:RESIDENT_WAVES-1];
    logic [RECONV_SP_W-1:0]
        store_owner_reconv_sp_by_wave_q [0:RESIDENT_WAVES-1];

    logic memory_backend_available;
    logic selected_memory_issue_ready;
    logic maintenance_idle;
    logic exec_memory_instruction;

    /* RTL8B live VLOADX MSHR bridge. */
    logic load_mshr_req_valid;
    logic load_mshr_req_ready;
    logic load_mshr_req_fire;
    logic [WAVE_ID_W-1:0] load_mshr_req_wave;
    logic [WAVE_ID_W-1:0] load_mshr_req_context;
    logic [VECTOR_REG_INDEX_W-1:0] load_mshr_req_dst;
    logic [WAVE_SIZE-1:0] load_mshr_req_lane_mask;

    logic load_mshr_complete_valid;
    logic load_mshr_complete_ready;
    logic [WAVE_ID_W-1:0] load_mshr_complete_wave;
    logic [WAVE_ID_W-1:0] load_mshr_complete_context;
    logic [VECTOR_REG_INDEX_W-1:0] load_mshr_complete_dst;
    logic [WAVE_SIZE-1:0] load_mshr_complete_lane_mask;
    logic load_mshr_complete_fault;
    logic [31:0] load_mshr_complete_data [0:WAVE_SIZE-1];

    logic load_mshr_empty;
    logic legacy_memory_tag_error_q;
    logic load_mshr_allocator_stall_unused;
    logic load_mshr_allocation_event_unused;
    logic load_mshr_bridge_busy;
    logic load_mshr_forward_dependency_active;
    logic store_queue_drain_age_safe;
    logic store_response_resolve_fire;
    logic [STORE_SEQ_W-1:0]
        mshr_owner_store_seq_boundary_by_wave_q [0:RESIDENT_WAVES-1];

    logic [PC_W-1:0] mshr_owner_pc_by_wave_q [0:RESIDENT_WAVES-1];
    logic [PC_W-1:0] mshr_owner_resume_pc_by_wave_q [0:RESIDENT_WAVES-1];
    logic [WAVE_SIZE-1:0]
        mshr_owner_exec_mask_by_wave_q [0:RESIDENT_WAVES-1];
    logic [RECONV_SP_W-1:0]
        mshr_owner_reconv_sp_by_wave_q [0:RESIDENT_WAVES-1];

    logic vector_seq_busy;
    logic vector_seq_done;
    logic vector_seq_beat_valid;
    logic [$clog2(WAVE_SIZE)-1:0] vector_seq_beat_index_with_unused_high;
    logic [PHYSICAL_LANES-1:0] vector_seq_valid_mask_unused;
    logic [PHYSICAL_LANES-1:0] vector_seq_active_mask;
    logic [$clog2(WAVE_SIZE)-1:0]
        vector_seq_logical_lane [0:PHYSICAL_LANES-1];

    logic operand_req_valid;
    logic operand_req_ready;
    logic operand_result_valid;
    logic operand_result_ready;
    logic [VECTOR_BEAT_DATA_W-1:0] operand_src0_data;
    logic [VECTOR_BEAT_DATA_W-1:0] operand_src1_data;
    logic [VECTOR_BEAT_DATA_W-1:0] operand_src2_data;
    logic operand_busy_unused;
    logic operand_bank_conflict_cycle /* verilator public_flat */;
    logic beat_request_sent_q;
    logic execute_beat_fire;
    logic sequence_advance_enable;
    logic [VECTOR_BEAT_DATA_W-1:0] execute_result_data;

    logic vrf_write_valid;
    logic [WAVE_ID_W-1:0] vrf_write_context;
    logic [VECTOR_REG_INDEX_W-1:0] vrf_write_reg;
    logic [VECTOR_BEAT_INDEX_W-1:0] vrf_write_beat;
    logic [PHYSICAL_LANES-1:0] vrf_write_lane_mask;
    logic [VECTOR_BEAT_DATA_W-1:0] vrf_write_data;
    logic vrf_write_ready;

    logic [PHYSICAL_LANES-1:0] refill_write_lane_mask;
    logic [VECTOR_BEAT_DATA_W-1:0] refill_write_data;

    logic [VECTOR_BEAT_INDEX_W-1:0] debug_write_beat;
    logic [PHYSICAL_SLOT_W-1:0] debug_write_slot;
    logic [PHYSICAL_LANES-1:0] debug_write_lane_mask;
    logic [VECTOR_BEAT_DATA_W-1:0] debug_write_data;




    function automatic logic signed [63:0] indexed_word_address(
        input logic [31:0] scalar_base,
        input logic [31:0] vector_offset,
        input logic signed [31:0] immediate
    );
        logic signed [63:0] base64;
        logic signed [63:0] offset64;
        logic signed [63:0] immediate64;
        begin
            base64 = $signed({32'b0, scalar_base});
            offset64 = $signed({32'b0, vector_offset});
            immediate64 = {
                {32{immediate[31]}},
                immediate
            };
            indexed_word_address =
                base64 + offset64 + immediate64;
        end
    endfunction


    /*
     * RTL7B freezes a one-to-one resident-wave -> physical VRF-context
     * mapping. A later allocator may relax this, but duplicate ownership
     * must never silently alias two live architectural waves.
     */
    assign alloc_mapping_valid =
        alloc_vrf_context_id == alloc_wave_id;

    /*
     * RTL8C retains one physical legacy backend transaction at a time.
     * Stores may queue while older loads finish. Physical store drain remains
     * behind live MSHRs, while MSHR-backed younger loads use post-address
     * cache-line conflict checks instead of a global store barrier.
     */
    function automatic logic [31:0] rtl8c_line_tag(
        input logic [31:0] word_addr
    );
        begin
            if (MSHR_LINE_WORDS <= 1) begin
                rtl8c_line_tag = word_addr;
            end else begin
                rtl8c_line_tag =
                    word_addr >> $clog2(MSHR_LINE_WORDS);
            end
        end
    endfunction


    assign memory_backend_available = (
        !mem_pending_valid_q
        && !mem_refill_pending_q
        && !mem_complete_pending_q
    );

    assign load_mshr_bridge_busy = (
        !load_mshr_empty
        || mshr_active_wave_mask_o != '0
    );

    /*
     * RTL8C-5B1 breaks only a real forwarding dependency cycle. Queue drain
     * may overlap active MSHR loads when a provisional queued-store source is
     * outstanding and the FIFO head is older than every MSHR-active load
     * boundary. Held order-wait loads retain RTL8C-4 conservative conflict
     * drain/replay behavior.
     */
    always_comb begin
        store_queue_drain_age_safe = store_queue_drain_valid;

        if (store_queue_drain_valid) begin
            for (
                int drain_age_wave = 0;
                drain_age_wave < RESIDENT_WAVES;
                drain_age_wave = drain_age_wave + 1
            ) begin
                if (
                    mshr_active_wave_mask_o[drain_age_wave]
                    && !(
                        store_queue_drain_seq
                        < mshr_owner_store_seq_boundary_by_wave_q[drain_age_wave]
                    )
                ) begin
                    store_queue_drain_age_safe = 1'b0;
                end
            end
        end
    end

    assign store_queue_drain_ready = (
        run_enable
        && memory_backend_available
        && (
            !ENABLE_LOAD_MSHR
            || !load_mshr_bridge_busy
            || (
                load_mshr_forward_dependency_active
                && store_queue_drain_age_safe
            )
        )
    );

    /*
     * Pre-issue store readiness must be qualified against the wave currently
     * selected by the frontend, not the previous execution owner in
     * exec_wave_q. Actual queue enqueue payload remains exec_wave_q at release.
     */
    always_comb begin
        selected_store_queue_issue_ready = 1'b0;

        if (
            frontend_grant_valid
            && integer'(frontend_grant_wave) < RESIDENT_WAVES
        ) begin
            selected_store_queue_issue_ready = (
                !store_queue_full
                && !store_queue_active_wave_mask_unused[
                    integer'(frontend_grant_wave)
                ]
            );
        end
    end

    assign selected_memory_issue_ready = (
        selected_opcode == OP_VSTOREX
    )
        ? selected_store_queue_issue_ready
        : (
            (
                selected_opcode == OP_VLOADX
                && ENABLE_LOAD_MSHR
            )
                ? !load_order_wait_valid_q
                : (
                    memory_backend_available
                    && store_queue_empty
                )
        );

    assign maintenance_idle = (
        !exec_active_q
        && memory_backend_available
        && store_queue_empty
        && !load_order_wait_valid_q
        && (
            !ENABLE_LOAD_MSHR
            || !load_mshr_bridge_busy
        )
    );

    assign alloc_ready =
        !run_enable
        && maintenance_idle
        && alloc_mapping_valid
        && frontend_alloc_ready;

    assign exec_memory_instruction = (
        exec_opcode_q == OP_VLOADX
        || exec_opcode_q == OP_VSTOREX
    );

    assign memory_outstanding_o = (
        mem_pending_valid_q
        || mem_refill_pending_q
        || mem_complete_pending_q
        || !store_queue_empty
        || load_order_wait_valid_q
        || (ENABLE_LOAD_MSHR && load_mshr_bridge_busy)
    );

    assign memory_tag_error_o = (
        legacy_memory_tag_error_q
        || (ENABLE_LOAD_MSHR && mshr_tag_error_o)
    );

    /* Correctly tagged physical-store response -> forwarding resolve. */
    assign store_response_resolve_fire = (
        service_legacy_resp_valid
        && mem_pending_valid_q
        && !mem_pending_load_q
        && service_legacy_resp_wave == mem_owner_wave_q
        && service_legacy_resp_context == mem_owner_context_q
    );

    assign store_terminal_valid_o = store_response_resolve_fire;
    assign store_terminal_fault_o =
        store_response_resolve_fire && service_legacy_resp_fault;

    assign load_mshr_complete_ready = (
        ENABLE_LOAD_MSHR
        && run_enable
        && load_mshr_complete_valid
        && !exec_active_q
        && !mem_pending_valid_q
        && !mem_refill_pending_q
        && !mem_complete_pending_q
    );


    /*
     * While one vector instruction owns the shared engine, keep the RTL7A
     * scheduler selection pinned to that architectural wave. The cursor is
     * still advanced only on retirement, but this makes retirement ownership
     * explicit instead of relying on an unchanged ready set.
     */
    always_comb begin
        execution_block_mask = '0;
        current_memory_mask = '0;
        current_load_mask = '0;
        current_store_mask = '0;
        memory_ready_mask = '0;
        non_memory_ready_mask = '0;
        memory_stalled_mask = memory_waiting_mask;

        for (
            integer blocker_wave = 0;
            blocker_wave < RESIDENT_WAVES;
            blocker_wave = blocker_wave + 1
        ) begin
            if (valid_mask_o[blocker_wave]) begin
                current_load_mask[blocker_wave] = (
                    program_mem[
                        context_pc_by_wave[blocker_wave]
                    ][63:56] == OP_VLOADX
                );
                current_store_mask[blocker_wave] = (
                    program_mem[
                        context_pc_by_wave[blocker_wave]
                    ][63:56] == OP_VSTOREX
                );
                current_memory_mask[blocker_wave] = (
                    current_load_mask[blocker_wave]
                    || current_store_mask[blocker_wave]
                );
            end else begin
                current_load_mask[blocker_wave] = 1'b0;
                current_store_mask[blocker_wave] = 1'b0;
                current_memory_mask[blocker_wave] = 1'b0;
            end

            memory_ready_mask[blocker_wave] = (
                architectural_ready_mask[blocker_wave]
                && current_memory_mask[blocker_wave]
            );

            non_memory_ready_mask[blocker_wave] = (
                architectural_ready_mask[blocker_wave]
                && !current_memory_mask[blocker_wave]
            );
        end

        if (exec_active_q) begin
            /*
             * The shared beat engine is single-owner. Keep every other wave
             * off the scheduler until this physical sequence yields.
             */
            for (
                integer blocker_wave = 0;
                blocker_wave < RESIDENT_WAVES;
                blocker_wave = blocker_wave + 1
            ) begin
                if (blocker_wave != integer'(exec_wave_q)) begin
                    execution_block_mask[blocker_wave] = 1'b1;
                end
            end

        end else if (
            load_mshr_complete_valid
            || mem_refill_pending_q
            || mem_complete_pending_q
        ) begin
            /*
             * One shared VRF write/context-completion path drains a completed
             * load atomically. Backend responses may continue accumulating in
             * the MSHR table while this short architectural refill is active.
             */
            execution_block_mask = '1;

        end else if (mem_pending_valid_q) begin
            /*
             * Compatibility-mode loads retain the old barrier. With live
             * MSHRs enabled, a physical store no longer blocks a younger load
             * before address generation; RTL8C-4 resolves the dependency
             * after the complete load address set exists.
             */
            if (mem_pending_load_q) begin
                execution_block_mask = current_memory_mask;
            end else begin
                execution_block_mask = '0;

                if (!ENABLE_LOAD_MSHR) begin
                    execution_block_mask = current_load_mask;
                end

                if (store_queue_full) begin
                    execution_block_mask =
                        execution_block_mask | current_store_mask;
                end
            end

            memory_stalled_mask =
                memory_stalled_mask
                | (
                    architectural_ready_mask
                    & execution_block_mask
                );

        end else if (!store_queue_empty) begin
            /*
             * With live MSHRs, queued stores are resolved after VLOADX address
             * generation. Compatibility mode remains conservative.
             */
            execution_block_mask = '0;

            if (!ENABLE_LOAD_MSHR) begin
                execution_block_mask = current_load_mask;
            end

            if (store_queue_full) begin
                execution_block_mask =
                    execution_block_mask | current_store_mask;
            end

            memory_stalled_mask =
                memory_stalled_mask
                | (
                    architectural_ready_mask
                    & execution_block_mask
                );
        end

        /* One wait slot: do not issue a second address-unknown VLOADX. */
        if (ENABLE_LOAD_MSHR && load_order_wait_valid_q) begin
            execution_block_mask =
                execution_block_mask | current_load_mask;

            memory_stalled_mask =
                memory_stalled_mask
                | (
                    architectural_ready_mask
                    & current_load_mask
                );
        end
    end


    assign selected_instruction =
        frontend_selected_valid
        ? program_mem[frontend_selected_pc]
        : 64'b0;

    assign selected_opcode = selected_instruction[63:56];
    assign selected_flags = selected_instruction[55:52];
    assign selected_dst = selected_instruction[51:46];
    assign selected_src0 = selected_instruction[45:40];
    assign selected_src1 = selected_instruction[39:34];
    assign selected_src2 = selected_instruction[33:28];
    assign selected_pred = selected_instruction[27:24];

    assign selected_vector_instruction = (
        selected_opcode == OP_VADD
        || selected_opcode == OP_VSUB
        || selected_opcode == OP_VMUL
        || selected_opcode == OP_VAND
        || selected_opcode == OP_VOR
        || selected_opcode == OP_VXOR
        || selected_opcode == OP_VCMP_EQ
        || selected_opcode == OP_VCMP_LT
        || selected_opcode == OP_VCMP_LE
        || selected_opcode == OP_VLOADX
        || selected_opcode == OP_VSTOREX
    );

    assign selected_memory_instruction = (
        selected_opcode == OP_VLOADX
        || selected_opcode == OP_VSTOREX
    );

    assign selected_scalar_instruction = (
        selected_opcode == OP_SADD
        || selected_opcode == OP_SSUB
    );

    assign selected_halt_instruction =
        selected_opcode == OP_HALT;

    assign selected_supported_instruction = (
        selected_vector_instruction
        || selected_scalar_instruction
        || selected_halt_instruction
    );

    assign classifier_contract_fault = (
        selected_vector_instruction
        && !classifier_tracked
    );

    /*
     * The ISA carries fixed-width vector/predicate register identifiers even
     * when a bounded verification configuration instantiates fewer registers.
     * The datapath intentionally narrows those identifiers only after decode.
     * Make the existing valid-program contract explicit so high identifier bits
     * are checked rather than silently treated as dead lint-only metadata.
     * These assertions do not alter request, scheduling, scoreboard, or retire
     * behavior for architecturally valid instructions.
     */
    always_ff @(posedge clk) begin : configured_register_index_contract
        if (rst_n) begin
            if (classifier_tracked) begin
                if (
                    classifier_src0_enable
                    && integer'(classifier_src0) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "vector src0 index exceeds configured register count");
                end
                if (
                    classifier_src1_enable
                    && integer'(classifier_src1) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "vector src1 index exceeds configured register count");
                end
                if (
                    classifier_src2_enable
                    && integer'(classifier_src2) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "vector src2 index exceeds configured register count");
                end
                if (
                    classifier_vector_dst_enable
                    && integer'(classifier_vector_dst) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "vector dst index exceeds configured register count");
                end
                if (
                    classifier_predicate_src_enable
                    && integer'(classifier_predicate_src) >= PREDICATE_REG_COUNT
                ) begin
                    $fatal(1, "predicate src index exceeds configured register count");
                end
                if (
                    classifier_predicate_dst_enable
                    && integer'(classifier_predicate_dst) >= PREDICATE_REG_COUNT
                ) begin
                    $fatal(1, "predicate dst index exceeds configured register count");
                end
            end

            if (exec_active_q) begin
                if (
                    exec_src0_enable_q
                    && integer'(exec_src0_q) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "active vector src0 index exceeds configured register count");
                end
                if (
                    exec_src1_enable_q
                    && integer'(exec_src1_q) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "active vector src1 index exceeds configured register count");
                end
                if (
                    exec_src2_enable_q
                    && integer'(exec_src2_q) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "active vector src2 index exceeds configured register count");
                end
                if (
                    exec_vector_dst_enable_q
                    && integer'(exec_dst_q) >= VECTOR_REG_COUNT
                ) begin
                    $fatal(1, "active vector dst index exceeds configured register count");
                end
                if (
                    (exec_predicate_enable_q || exec_predicate_dst_enable_q)
                    && integer'(exec_pred_q) >= PREDICATE_REG_COUNT
                ) begin
                    $fatal(1, "active predicate index exceeds configured register count");
                end
            end
        end
    end


    assign vector_issue_fire = (
        run_enable
        && !exec_active_q
        && frontend_grant_valid
        && frontend_selected_valid
        && selected_vector_instruction
        && classifier_tracked
        && scoreboard_issue_allowed
        && (
            !selected_memory_instruction
            || selected_memory_issue_ready
        )
    );

    assign direct_retire_fire = (
        run_enable
        && !exec_active_q
        && frontend_grant_valid
        && frontend_selected_valid
        && (
            !selected_vector_instruction
            || classifier_contract_fault
        )
    );

    assign vector_release_fire = (
        run_enable
        && exec_active_q
        && vector_seq_done
    );

    assign current_load_order_candidate = (
        ENABLE_LOAD_MSHR
        && vector_release_fire
        && exec_opcode_q == OP_VLOADX
        && mem_build_lane_mask_q != '0
        && !mem_build_fault_q
    );

    always_comb begin
        store_queue_probe_valid = 1'b0;
        store_queue_probe_lane_mask = '0;
        store_queue_probe_seq_boundary = '0;

        for (
            int probe_mux_lane = 0;
            probe_mux_lane < WAVE_SIZE;
            probe_mux_lane = probe_mux_lane + 1
        ) begin
            store_queue_probe_word_addr[probe_mux_lane] = '0;
        end

        if (load_order_wait_valid_q) begin
            store_queue_probe_valid = 1'b1;
            store_queue_probe_lane_mask = load_order_wait_lane_mask_q;
            store_queue_probe_seq_boundary =
                load_order_wait_store_seq_boundary_q;

            for (
                int wait_probe_lane = 0;
                wait_probe_lane < WAVE_SIZE;
                wait_probe_lane = wait_probe_lane + 1
            ) begin
                store_queue_probe_word_addr[wait_probe_lane] =
                    load_order_wait_addr_q[wait_probe_lane];
            end

        end else if (current_load_order_candidate) begin
            store_queue_probe_valid = 1'b1;
            store_queue_probe_lane_mask = mem_build_lane_mask_q;
            store_queue_probe_seq_boundary = store_seq_next_q;

            for (
                int current_probe_lane = 0;
                current_probe_lane < WAVE_SIZE;
                current_probe_lane = current_probe_lane + 1
            ) begin
                store_queue_probe_word_addr[current_probe_lane] =
                    mem_build_addr_q[current_probe_lane];
            end
        end
    end

    always_comb begin
        physical_store_exact_conflict = 1'b0;
        physical_store_exact_conflict_lane_mask_unused = '0;
        physical_store_line_conflict = 1'b0;
        physical_store_line_conflict_lane_mask = '0;
        physical_store_source_valid_lane_mask = '0;
        physical_store_source_ambiguous_lane_mask = '0;

        for (
            int physical_source_clear_lane = 0;
            physical_source_clear_lane < WAVE_SIZE;
            physical_source_clear_lane = physical_source_clear_lane + 1
        ) begin
            physical_store_source_seq[physical_source_clear_lane] = '0;
            physical_store_source_wdata[physical_source_clear_lane] = '0;
        end

        if (
            store_queue_probe_valid
            && mem_pending_valid_q
            && !mem_pending_load_q
        ) begin
            for (
                int load_probe_lane = 0;
                load_probe_lane < WAVE_SIZE;
                load_probe_lane = load_probe_lane + 1
            ) begin
                if (store_queue_probe_lane_mask[load_probe_lane]) begin
                    for (
                        int physical_store_lane = 0;
                        physical_store_lane < WAVE_SIZE;
                        physical_store_lane = physical_store_lane + 1
                    ) begin
                        if (mem_owner_lane_mask_q[physical_store_lane]) begin
                            if (
                                store_queue_probe_word_addr[load_probe_lane]
                                == mem_owner_store_addr_q[
                                    physical_store_lane
                                ]
                            ) begin
                                physical_store_exact_conflict = 1'b1;
                                physical_store_exact_conflict_lane_mask_unused[
                                    load_probe_lane
                                ] = 1'b1;

                                if (
                                    mem_owner_store_seq_q
                                        < store_queue_probe_seq_boundary
                                ) begin
                                    if (
                                        !physical_store_source_valid_lane_mask[
                                            load_probe_lane
                                        ]
                                    ) begin
                                        physical_store_source_valid_lane_mask[
                                            load_probe_lane
                                        ] = 1'b1;
                                        physical_store_source_seq[
                                            load_probe_lane
                                        ] = mem_owner_store_seq_q;
                                        physical_store_source_wdata[
                                            load_probe_lane
                                        ] = mem_owner_store_wdata_q[
                                            physical_store_lane
                                        ];

                                    end else begin
                                        /*
                                         * A second active lane in the same
                                         * physical store targets this word.
                                         * Keep the source identity but mark
                                         * the data choice architecturally
                                         * ambiguous until lane ordering is
                                         * defined.
                                         */
                                        physical_store_source_ambiguous_lane_mask[
                                            load_probe_lane
                                        ] = 1'b1;
                                    end
                                end
                            end

                            if (
                                rtl8c_line_tag(
                                    store_queue_probe_word_addr[
                                        load_probe_lane
                                    ]
                                )
                                == rtl8c_line_tag(
                                    mem_owner_store_addr_q[
                                        physical_store_lane
                                    ]
                                )
                            ) begin
                                physical_store_line_conflict = 1'b1;
                                physical_store_line_conflict_lane_mask[
                                    load_probe_lane
                                ] = 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

    assign load_store_line_conflict = (
        store_queue_probe_line_conflict
        || physical_store_line_conflict
    );

    /*
     * RTL8C-5B2 resolves ordering only after the combined 5A youngest-source
     * selector below has identified the exact source and its origin.
     */

    /*
     * RTL8C-5A resolves the youngest older exact-word source across the
     * physical store and every queued store. RTL8C-5B2 consumes that combined
     * source and records whether the winning source is the physical owner.
     */
    always_comb begin
        load_store_source_valid_lane_mask = '0;
        load_store_source_ambiguous_lane_mask = '0;
        load_store_source_physical_lane_mask = '0;

        for (
            int combined_source_lane = 0;
            combined_source_lane < WAVE_SIZE;
            combined_source_lane = combined_source_lane + 1
        ) begin
            load_store_source_seq[combined_source_lane] = '0;
            load_store_source_wdata[combined_source_lane] = '0;

            if (
                store_queue_probe_source_valid_lane_mask[combined_source_lane]
            ) begin
                load_store_source_valid_lane_mask[combined_source_lane] = 1'b1;
                load_store_source_ambiguous_lane_mask[combined_source_lane] =
                    store_queue_probe_source_ambiguous_lane_mask[
                        combined_source_lane
                    ];
                load_store_source_seq[combined_source_lane] =
                    store_queue_probe_source_seq[combined_source_lane];
                load_store_source_wdata[combined_source_lane] =
                    store_queue_probe_source_wdata[combined_source_lane];
            end

            if (physical_store_source_valid_lane_mask[combined_source_lane]) begin
                if (
                    !load_store_source_valid_lane_mask[combined_source_lane]
                    || physical_store_source_seq[combined_source_lane]
                        > load_store_source_seq[combined_source_lane]
                ) begin
                    load_store_source_valid_lane_mask[combined_source_lane] =
                        1'b1;
                    load_store_source_ambiguous_lane_mask[combined_source_lane] =
                        physical_store_source_ambiguous_lane_mask[
                            combined_source_lane
                        ];
                    load_store_source_seq[combined_source_lane] =
                        physical_store_source_seq[combined_source_lane];
                    load_store_source_wdata[combined_source_lane] =
                        physical_store_source_wdata[combined_source_lane];
                    load_store_source_physical_lane_mask[
                        combined_source_lane
                    ] = 1'b1;

                end else if (
                    physical_store_source_seq[combined_source_lane]
                        == load_store_source_seq[combined_source_lane]
                ) begin
                    /* A duplicated sequence identity is itself ambiguous. */
                    load_store_source_ambiguous_lane_mask[combined_source_lane] =
                        1'b1;
                end
            end
        end
    end

    /*
     * A selected source is forwarding-safe only when its exact-word identity is
     * unambiguous. If the winning source is the physical store whose correctly
     * tagged response is resolving in this cycle, suppress new forwarding so
     * the load takes the conservative hold/replay path instead of losing the
     * one-cycle resolve event during dependency capture.
     */
    assign load_store_forward_safe_lane_mask = (
        load_store_source_valid_lane_mask
        & ~load_store_source_ambiguous_lane_mask
        & ~(
            load_store_source_physical_lane_mask
            & {WAVE_SIZE{store_response_resolve_fire}}
        )
    );

    assign load_store_unresolved_line_conflict_lane_mask = (
        store_queue_probe_line_conflict_lane_mask
        | physical_store_line_conflict_lane_mask
    ) & ~load_store_forward_safe_lane_mask;

    assign load_store_unresolved_line_conflict =
        |load_store_unresolved_line_conflict_lane_mask;

    assign load_order_hold_fire = (
        current_load_order_candidate
        && load_store_unresolved_line_conflict
    );

    assign load_order_replay_valid = (
        ENABLE_LOAD_MSHR
        && run_enable
        && load_order_wait_valid_q
        && !load_store_unresolved_line_conflict
    );

    assign load_mshr_req_valid = (
        load_order_replay_valid
        || (
            current_load_order_candidate
            && !load_store_unresolved_line_conflict
        )
    );

    assign load_mshr_req_wave =
        load_order_replay_valid
            ? load_order_wait_wave_q
            : exec_wave_q;

    assign load_mshr_req_context =
        load_order_replay_valid
            ? load_order_wait_context_q
            : exec_vrf_context_q;

    assign load_mshr_req_dst =
        load_order_replay_valid
            ? load_order_wait_dst_q
            : VECTOR_REG_INDEX_W'(exec_dst_q);

    assign load_mshr_req_lane_mask =
        load_order_replay_valid
            ? load_order_wait_lane_mask_q
            : mem_build_lane_mask_q;

    always_comb begin
        for (
            int load_req_lane = 0;
            load_req_lane < WAVE_SIZE;
            load_req_lane = load_req_lane + 1
        ) begin
            load_mshr_req_word_addr[load_req_lane] =
                load_order_replay_valid
                    ? load_order_wait_addr_q[load_req_lane]
                    : mem_build_addr_q[load_req_lane];
        end
    end

    assign mshr_load_launch_fire = (
        load_mshr_req_fire
        && !load_order_replay_valid
    );

    assign load_order_replay_fire = (
        load_mshr_req_fire
        && load_order_replay_valid
    );

    assign mshr_load_internal_fault_fire = (
        current_load_order_candidate
        && !load_store_unresolved_line_conflict
        && !load_mshr_req_ready
    );

    assign store_queue_enqueue_valid = (
        vector_release_fire
        && exec_opcode_q == OP_VSTOREX
        && mem_build_lane_mask_q != '0
        && !mem_build_fault_q
    );

    assign store_queue_internal_fault_fire = (
        store_queue_enqueue_valid
        && !store_queue_enqueue_ready
    );

    /* Compatibility VLOADX path when live MSHRs are disabled. */
    assign legacy_memory_launch_fire = (
        vector_release_fire
        && exec_opcode_q == OP_VLOADX
        && !ENABLE_LOAD_MSHR
        && mem_build_lane_mask_q != '0
        && !mem_build_fault_q
    );

    assign memory_launch_fire = (
        legacy_memory_launch_fire
        || mshr_load_launch_fire
        || store_queue_enqueue_fire
        || load_order_hold_fire
    );

    assign memory_noop_release_fire = (
        vector_release_fire
        && exec_memory_instruction
        && mem_build_lane_mask_q == '0
        && !mem_build_fault_q
    );

    assign memory_fault_release_fire = (
        (
            vector_release_fire
            && exec_memory_instruction
            && mem_build_fault_q
        )
        || mshr_load_internal_fault_fire
        || store_queue_internal_fault_fire
    );

    assign vector_arch_release_fire = (
        vector_release_fire
        && (
            !exec_memory_instruction
            || memory_noop_release_fire
            || memory_fault_release_fire
        )
    );

    assign memory_complete_fire = (
        run_enable
        && mem_complete_pending_q
        && !exec_active_q
    );

    assign scoreboard_release_fire = (
        vector_arch_release_fire
        || memory_complete_fire
    );

    /*
     * Memory launch advances LRR to another wave but is not exposed as an
     * architectural retire event until response/refill completion.
     */
    assign scheduler_grant_fire =
        direct_retire_fire || vector_release_fire;


    /*
     * One collector request for every visible physical beat.
     */
    assign operand_req_valid = (
        run_enable
        && exec_active_q
        && vector_seq_beat_valid
        && !beat_request_sent_q
    );

    assign execute_beat_fire = (
        run_enable
        && exec_active_q
        && vector_seq_beat_valid
        && operand_result_valid
    );

    assign operand_result_ready = execute_beat_fire;

    assign sequence_advance_enable = (
        run_enable
        && (
            !vector_seq_busy
            || execute_beat_fire
        )
    );


    always_comb begin
        execute_result_data = '0;

        for (
            integer execute_lane = 0;
            execute_lane < PHYSICAL_LANES;
            execute_lane = execute_lane + 1
        ) begin
            case (exec_opcode_q)
                OP_VADD: begin
                    execute_result_data[execute_lane*32 +: 32] =
                        operand_src0_data[execute_lane*32 +: 32]
                        + operand_src1_data[execute_lane*32 +: 32];
                end
                OP_VSUB: begin
                    execute_result_data[execute_lane*32 +: 32] =
                        operand_src0_data[execute_lane*32 +: 32]
                        - operand_src1_data[execute_lane*32 +: 32];
                end
                OP_VMUL: begin
                    execute_result_data[execute_lane*32 +: 32] =
                        operand_src0_data[execute_lane*32 +: 32]
                        * operand_src1_data[execute_lane*32 +: 32];
                end
                OP_VAND: begin
                    execute_result_data[execute_lane*32 +: 32] =
                        operand_src0_data[execute_lane*32 +: 32]
                        & operand_src1_data[execute_lane*32 +: 32];
                end
                OP_VOR: begin
                    execute_result_data[execute_lane*32 +: 32] =
                        operand_src0_data[execute_lane*32 +: 32]
                        | operand_src1_data[execute_lane*32 +: 32];
                end
                OP_VXOR: begin
                    execute_result_data[execute_lane*32 +: 32] =
                        operand_src0_data[execute_lane*32 +: 32]
                        ^ operand_src1_data[execute_lane*32 +: 32];
                end
                default: begin
                    execute_result_data[execute_lane*32 +: 32] = '0;
                end
            endcase
        end
    end


    /* Debug single-lane write packing into the context-qualified VRF. */
    always_comb begin
        debug_write_beat = VECTOR_BEAT_INDEX_W'(
            integer'(vector_wlane) / PHYSICAL_LANES
        );
        debug_write_slot = PHYSICAL_SLOT_W'(
            integer'(vector_wlane) % PHYSICAL_LANES
        );
        debug_write_lane_mask = '0;
        debug_write_data = '0;

        if (
            integer'(vector_wlane) < WAVE_SIZE
            && integer'(debug_write_slot) < PHYSICAL_LANES
        ) begin
            debug_write_lane_mask[debug_write_slot] = 1'b1;
            debug_write_data[debug_write_slot*32 +: 32] = vector_wdata;
        end
    end


    always_comb begin
        refill_write_lane_mask = '0;
        refill_write_data = '0;

        for (
            integer refill_lane = 0;
            refill_lane < PHYSICAL_LANES;
            refill_lane = refill_lane + 1
        ) begin : refill_lane_pack
            integer refill_logical_index;

            refill_logical_index = (
                integer'(mem_refill_beat_q)
                * PHYSICAL_LANES
                + refill_lane
            );

            if (refill_logical_index < WAVE_SIZE) begin
                refill_write_lane_mask[refill_lane] =
                    mem_owner_lane_mask_q[refill_logical_index];

                refill_write_data[refill_lane*32 +: 32] =
                    mem_response_buffer_q[refill_logical_index];
            end
        end
    end


    always_comb begin
        vrf_write_valid = 1'b0;
        vrf_write_context = '0;
        vrf_write_reg = '0;
        vrf_write_beat = '0;
        vrf_write_lane_mask = '0;
        vrf_write_data = '0;

        if (!run_enable && maintenance_idle && vector_we) begin
            vrf_write_valid = 1'b1;
            vrf_write_context = vector_wcontext;
            vrf_write_reg = vector_wreg;
            vrf_write_beat = debug_write_beat;
            vrf_write_lane_mask = debug_write_lane_mask;
            vrf_write_data = debug_write_data;

        end else if (
            run_enable
            && mem_refill_pending_q
            && !exec_active_q
        ) begin
            vrf_write_valid = 1'b1;
            vrf_write_context = mem_owner_context_q;
            vrf_write_reg = mem_owner_dst_q;
            vrf_write_beat = mem_refill_beat_q;
            vrf_write_lane_mask = refill_write_lane_mask;
            vrf_write_data = refill_write_data;

        end else if (
            execute_beat_fire
            && exec_vector_dst_enable_q
            && !exec_memory_instruction
        ) begin
            vrf_write_valid = 1'b1;
            vrf_write_context = exec_vrf_context_q;
            vrf_write_reg = VECTOR_REG_INDEX_W'(exec_dst_q);
            vrf_write_beat = VECTOR_BEAT_INDEX_W'(vector_seq_beat_index_with_unused_high);
            vrf_write_lane_mask = vector_seq_active_mask;
            vrf_write_data = execute_result_data;
        end
    end


    /*
     * Context update mux. Debug writes own scalar/predicate ports only while
     * execution is paused. Retirement owns them while run_enable is high.
     */
    always_comb begin
        state_write_valid = 1'b0;
        state_write_wave = '0;
        state_write_pc = '0;
        state_write_exec_mask = '0;
        state_write_reconv_sp = '0;
        state_write_halted = 1'b0;
        state_write_memory_waiting = 1'b0;

        scalar_write_valid = 1'b0;
        scalar_write_wave = '0;
        scalar_write_reg = '0;
        scalar_write_data = '0;

        predicate_write_valid = 1'b0;
        predicate_write_wave = '0;
        predicate_write_reg = '0;
        predicate_write_data = '0;

        if (!run_enable && maintenance_idle) begin
            scalar_write_valid = scalar_we;
            scalar_write_wave = scalar_wwave;
            scalar_write_reg = scalar_wreg;
            scalar_write_data = scalar_wdata;

            predicate_write_valid = predicate_we;
            predicate_write_wave = predicate_wwave;
            predicate_write_reg = predicate_wreg;
            predicate_write_data = predicate_wdata;

        end else if (memory_complete_fire) begin
            state_write_valid = 1'b1;
            state_write_wave = mem_owner_wave_q;
            state_write_pc = mem_owner_resume_pc_q;
            state_write_exec_mask = mem_owner_exec_mask_q;
            state_write_reconv_sp = mem_owner_reconv_sp_q;
            state_write_halted = mem_complete_fault_q;
            state_write_memory_waiting = 1'b0;

        end else if (direct_retire_fire) begin
            state_write_valid = 1'b1;
            state_write_wave = frontend_grant_wave;
            state_write_pc = frontend_selected_pc + PC_W'(1);
            state_write_exec_mask = frontend_selected_exec_mask;
            state_write_reconv_sp = frontend_selected_reconv_sp;
            state_write_halted = selected_halt_instruction
                || !selected_supported_instruction
                || classifier_contract_fault;
            state_write_memory_waiting = 1'b0;

            if (selected_scalar_instruction) begin
                scalar_write_valid = 1'b1;
                scalar_write_wave = frontend_grant_wave;
                scalar_write_reg = SCALAR_REG_INDEX_W'(selected_dst);

                if (selected_opcode == OP_SADD) begin
                    scalar_write_data =
                        frontend_scalar_src0 + frontend_scalar_src1;
                end else begin
                    scalar_write_data =
                        frontend_scalar_src0 - frontend_scalar_src1;
                end
            end

        end else if (vector_release_fire) begin
            state_write_valid = 1'b1;
            state_write_wave = exec_wave_q;
            state_write_pc = exec_pc_q + PC_W'(1);
            state_write_exec_mask = exec_mask_q;
            state_write_reconv_sp = exec_reconv_sp_q;
            state_write_halted = memory_fault_release_fire;
            state_write_memory_waiting = memory_launch_fire;

            if (
                exec_predicate_dst_enable_q
                && !exec_memory_instruction
            ) begin
                predicate_write_valid = 1'b1;
                predicate_write_wave = exec_wave_q;
                predicate_write_reg = PREDICATE_INDEX_W'(exec_pred_q);
                predicate_write_data = compare_accum_q;
            end
        end
    end


    assign engine_busy_o = exec_active_q;
    assign all_halted_o = (
        valid_mask_o != '0
        && (halted_mask_o & valid_mask_o) == valid_mask_o
    );


    always_comb begin
        if (
            integer'(debug_vector_context_i) < RESIDENT_WAVES
            && integer'(debug_vector_reg_i) < VECTOR_REG_COUNT
            && integer'(debug_vector_lane_i) < WAVE_SIZE
        ) begin
            debug_vector_data_o = vector_shadow[
                debug_vector_context_i
            ][debug_vector_reg_i][debug_vector_lane_i];
        end else begin
            debug_vector_data_o = '0;
        end
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            exec_active_q <= 1'b0;
            exec_wave_q <= '0;
            exec_vrf_context_q <= '0;
            exec_pc_q <= '0;
            exec_mask_q <= '0;
            exec_reconv_sp_q <= '0;
            exec_predicate_mask_q <= '0;
            exec_opcode_q <= '0;
            exec_predicate_enable_q <= 1'b0;
            exec_dst_q <= '0;
            exec_src0_q <= '0;
            exec_src1_q <= '0;
            exec_src2_q <= '0;
            exec_pred_q <= '0;
            exec_src0_enable_q <= 1'b0;
            exec_src1_enable_q <= 1'b0;
            exec_src2_enable_q <= 1'b0;
            exec_vector_dst_enable_q <= 1'b0;
            exec_predicate_dst_enable_q <= 1'b0;
            exec_scalar_base_q <= '0;
            exec_imm_q <= '0;
            compare_accum_q <= '0;
            beat_request_sent_q <= 1'b0;

            mem_pending_valid_q <= 1'b0;
            mem_pending_load_q <= 1'b0;
            mem_owner_wave_q <= '0;
            mem_owner_context_q <= '0;
            mem_owner_pc_q <= '0;
            mem_owner_resume_pc_q <= '0;
            mem_owner_exec_mask_q <= '0;
            mem_owner_reconv_sp_q <= '0;
            mem_owner_dst_q <= '0;
            mem_owner_lane_mask_q <= '0;
            mem_owner_store_seq_q <= '0;

            store_seq_next_q <= '0;

            for (
                int boundary_reset_wave = 0;
                boundary_reset_wave < RESIDENT_WAVES;
                boundary_reset_wave = boundary_reset_wave + 1
            ) begin
                mshr_owner_store_seq_boundary_by_wave_q[
                    boundary_reset_wave
                ] <= '0;
            end
            load_order_wait_valid_q <= 1'b0;
            load_order_wait_wave_q <= '0;
            load_order_wait_context_q <= '0;
            load_order_wait_dst_q <= '0;
            load_order_wait_pc_q <= '0;
            load_order_wait_resume_pc_q <= '0;
            load_order_wait_exec_mask_q <= '0;
            load_order_wait_reconv_sp_q <= '0;
            load_order_wait_lane_mask_q <= '0;
            load_order_wait_store_seq_boundary_q <= '0;

            for (
                integer mshr_owner_reset_wave = 0;
                mshr_owner_reset_wave < RESIDENT_WAVES;
                mshr_owner_reset_wave = mshr_owner_reset_wave + 1
            ) begin
                mshr_owner_pc_by_wave_q[mshr_owner_reset_wave] <= '0;
                mshr_owner_resume_pc_by_wave_q[mshr_owner_reset_wave] <= '0;
                mshr_owner_exec_mask_by_wave_q[mshr_owner_reset_wave] <= '0;
                mshr_owner_reconv_sp_by_wave_q[mshr_owner_reset_wave] <= '0;

                store_owner_pc_by_wave_q[mshr_owner_reset_wave] <= '0;
                store_owner_resume_pc_by_wave_q[mshr_owner_reset_wave] <= '0;
                store_owner_exec_mask_by_wave_q[mshr_owner_reset_wave] <= '0;
                store_owner_reconv_sp_by_wave_q[mshr_owner_reset_wave] <= '0;
            end

            mem_refill_pending_q <= 1'b0;
            mem_refill_beat_q <= '0;
            mem_complete_pending_q <= 1'b0;
            mem_complete_fault_q <= 1'b0;

            mem_build_lane_mask_q <= '0;
            mem_build_fault_q <= 1'b0;

            service_legacy_req_valid <= 1'b0;
            service_legacy_req_write <= 1'b0;
            service_legacy_req_wave <= '0;
            service_legacy_req_context <= '0;
            service_legacy_req_lane_mask <= '0;
            legacy_memory_tag_error_q <= 1'b0;

            retire_valid_o <= 1'b0;
            retire_wave_o <= '0;
            retire_pc_o <= '0;
            faulted_o <= 1'b0;

            for (
                integer memory_lane = 0;
                memory_lane < WAVE_SIZE;
                memory_lane = memory_lane + 1
            ) begin
                mem_build_addr_q[memory_lane] <= '0;
                mem_build_wdata_q[memory_lane] <= '0;
                mem_response_buffer_q[memory_lane] <= '0;
                service_legacy_req_addr[memory_lane] <= '0;
                service_legacy_req_wdata[memory_lane] <= '0;
                mem_owner_store_addr_q[memory_lane] <= '0;
                mem_owner_store_wdata_q[memory_lane] <= '0;
                load_order_wait_addr_q[memory_lane] <= '0;
            end

        end else begin
            retire_valid_o <= 1'b0;
            service_legacy_req_valid <= 1'b0;

            if (ENABLE_LOAD_MSHR && mshr_tag_error_o) begin
                faulted_o <= 1'b1;
            end

            if (store_queue_enqueue_fire) begin
                store_seq_next_q <=
                    store_seq_next_q + STORE_SEQ_W'(1);
            end

            if (load_order_replay_fire) begin
                load_order_wait_valid_q <= 1'b0;
                mshr_owner_store_seq_boundary_by_wave_q[
                    integer'(load_order_wait_wave_q)
                ] <= load_order_wait_store_seq_boundary_q;

                mshr_owner_pc_by_wave_q[
                    integer'(load_order_wait_wave_q)
                ] <= load_order_wait_pc_q;
                mshr_owner_resume_pc_by_wave_q[
                    integer'(load_order_wait_wave_q)
                ] <= load_order_wait_resume_pc_q;
                mshr_owner_exec_mask_by_wave_q[
                    integer'(load_order_wait_wave_q)
                ] <= load_order_wait_exec_mask_q;
                mshr_owner_reconv_sp_by_wave_q[
                    integer'(load_order_wait_wave_q)
                ] <= load_order_wait_reconv_sp_q;
            end

            /*
             * A whole-wave MSHR load completion is accepted only while the
             * shared architectural refill path is idle. Backend line responses
             * themselves are buffered independently inside the MSHR bridge.
             */
            if (load_mshr_complete_valid && load_mshr_complete_ready) begin
                mem_pending_load_q <= 1'b1;
                mem_owner_wave_q <= load_mshr_complete_wave;
                mem_owner_context_q <= load_mshr_complete_context;
                mem_owner_pc_q <=
                    mshr_owner_pc_by_wave_q[
                        integer'(load_mshr_complete_wave)
                    ];
                mem_owner_resume_pc_q <=
                    mshr_owner_resume_pc_by_wave_q[
                        integer'(load_mshr_complete_wave)
                    ];
                mem_owner_exec_mask_q <=
                    mshr_owner_exec_mask_by_wave_q[
                        integer'(load_mshr_complete_wave)
                    ];
                mem_owner_reconv_sp_q <=
                    mshr_owner_reconv_sp_by_wave_q[
                        integer'(load_mshr_complete_wave)
                    ];
                mem_owner_dst_q <= load_mshr_complete_dst;
                mem_owner_lane_mask_q <= load_mshr_complete_lane_mask;

                if (load_mshr_complete_fault) begin
                    mem_complete_pending_q <= 1'b1;
                    mem_complete_fault_q <= 1'b1;
                end else begin
                    mem_refill_pending_q <= 1'b1;
                    mem_refill_beat_q <= '0;
                    mem_complete_fault_q <= 1'b0;

                    for (
                        integer memory_lane = 0;
                        memory_lane < WAVE_SIZE;
                        memory_lane = memory_lane + 1
                    ) begin
                        mem_response_buffer_q[memory_lane] <=
                            load_mshr_complete_data[memory_lane];
                    end
                end
            end

            /*
             * Legacy response capture is independent of run_enable. Pausing the
             * execution engine therefore cannot lose a backend response.
             *
             * Same-cycle request/response is intentionally not part of the
             * RTL7C contract; the backend responds no earlier than the cycle
             * after the one-cycle request pulse.
             */
            if (service_legacy_resp_valid) begin
                if (!mem_pending_valid_q) begin
                    legacy_memory_tag_error_q <= 1'b1;

                end else if (
                    service_legacy_resp_wave != mem_owner_wave_q
                    || service_legacy_resp_context != mem_owner_context_q
                ) begin
                    /*
                     * Reject stale/misrouted responses without consuming the
                     * outstanding transaction. A correctly tagged response
                     * may still arrive later.
                     */
                    legacy_memory_tag_error_q <= 1'b1;

                end else begin
                    mem_pending_valid_q <= 1'b0;

                    if (service_legacy_resp_fault) begin
                        mem_complete_pending_q <= 1'b1;
                        mem_complete_fault_q <= 1'b1;

                    end else if (mem_pending_load_q) begin
                        mem_refill_pending_q <= 1'b1;
                        mem_refill_beat_q <= '0;

                        for (
                            integer memory_lane = 0;
                            memory_lane < WAVE_SIZE;
                            memory_lane = memory_lane + 1
                        ) begin
                            mem_response_buffer_q[memory_lane] <=
                                service_legacy_resp_rdata[memory_lane];

                        end

                    end else begin
                        mem_complete_pending_q <= 1'b1;
                        mem_complete_fault_q <= 1'b0;
                    end
                end
            end

            /*
             * VLOADX response -> context-qualified VRF refill. The memory
             * owner remains architecturally memory_waiting until the final
             * beat has been written through the shared 1-write-port VRF.
             */
            if (
                run_enable
                && mem_refill_pending_q
                && !exec_active_q
                && vrf_write_ready
            ) begin
                for (
                    integer shadow_refill_lane = 0;
                    shadow_refill_lane < PHYSICAL_LANES;
                    shadow_refill_lane = shadow_refill_lane + 1
                ) begin : shadow_refill_lane_pack
                    integer shadow_refill_index;

                    shadow_refill_index = (
                        integer'(mem_refill_beat_q)
                        * PHYSICAL_LANES
                        + shadow_refill_lane
                    );

                    if (
                        shadow_refill_index < WAVE_SIZE
                        && mem_owner_lane_mask_q[shadow_refill_index]
                    ) begin
                        vector_shadow[
                            mem_owner_context_q
                        ][
                            mem_owner_dst_q
                        ][shadow_refill_index] <=
                            mem_response_buffer_q[shadow_refill_index];
                    end
                end

                if (
                    integer'(mem_refill_beat_q)
                    == VECTOR_BEAT_COUNT - 1
                ) begin
                    mem_refill_pending_q <= 1'b0;
                    mem_refill_beat_q <= '0;
                    mem_complete_pending_q <= 1'b1;
                    mem_complete_fault_q <= 1'b0;
                end else begin
                    mem_refill_beat_q <=
                        mem_refill_beat_q + 1'b1;
                end
            end

            /*
             * Architectural memory completion is serialized after refill and
             * after any already-running shared vector instruction. The
             * context mux clears memory_waiting and the scoreboard release
             * occurs on this same edge.
             */
            if (memory_complete_fire) begin
                mem_complete_pending_q <= 1'b0;

                retire_valid_o <= 1'b1;
                retire_wave_o <= mem_owner_wave_q;
                retire_pc_o <= mem_owner_pc_q;

                if (mem_complete_fault_q) begin
                    faulted_o <= 1'b1;
                end

                mem_owner_lane_mask_q <= '0;
            end

            if (!run_enable) begin
                /*
                 * Pause preserves vector execution and every stage of the
                 * memory lifecycle. Maintenance writes are accepted only
                 * when no execution or memory ownership remains.
                 */
                if (
                    maintenance_idle
                    && vector_we
                    && integer'(vector_wcontext) < RESIDENT_WAVES
                    && integer'(vector_wreg) < VECTOR_REG_COUNT
                    && integer'(vector_wlane) < WAVE_SIZE
                    && vrf_write_ready
                ) begin
                    vector_shadow[
                        vector_wcontext
                    ][vector_wreg][vector_wlane] <= vector_wdata;
                end

                if (maintenance_idle && program_we) begin
                    program_mem[program_waddr] <= program_wdata;
                end

            end else begin
                if (vector_issue_fire) begin
                    exec_active_q <= 1'b1;
                    exec_wave_q <= frontend_grant_wave;
                    exec_vrf_context_q <= frontend_selected_vrf_context;
                    exec_pc_q <= frontend_selected_pc;
                    exec_mask_q <= frontend_selected_exec_mask;
                    exec_reconv_sp_q <= frontend_selected_reconv_sp;
                    exec_predicate_mask_q <= frontend_predicate_data;
                    exec_opcode_q <= selected_opcode;
                    exec_predicate_enable_q <= selected_flags[0];
                    exec_dst_q <= selected_dst;
                    exec_src0_q <= selected_src0;
                    exec_src1_q <= selected_src1;
                    exec_src2_q <= selected_src2;
                    exec_pred_q <= selected_pred;
                    exec_src0_enable_q <= classifier_src0_enable;
                    exec_src1_enable_q <= classifier_src1_enable;
                    exec_src2_enable_q <= classifier_src2_enable;
                    exec_vector_dst_enable_q <= classifier_vector_dst_enable;
                    exec_predicate_dst_enable_q <= classifier_predicate_dst_enable;
                    exec_scalar_base_q <= frontend_scalar_src0;
                    exec_imm_q <= {
                        {8{selected_instruction[23]}},
                        selected_instruction[23:0]
                    };
                    compare_accum_q <= frontend_predicate_data;
                    beat_request_sent_q <= 1'b0;

                    if (selected_memory_instruction) begin
                        mem_build_lane_mask_q <= '0;
                        mem_build_fault_q <= 1'b0;

                        for (
                            integer memory_lane = 0;
                            memory_lane < WAVE_SIZE;
                            memory_lane = memory_lane + 1
                        ) begin
                            mem_build_addr_q[memory_lane] <= '0;
                            mem_build_wdata_q[memory_lane] <= '0;
                        end
                    end
                end

                if (operand_req_valid && operand_req_ready) begin
                    beat_request_sent_q <= 1'b1;
                end

                if (execute_beat_fire) begin
                    beat_request_sent_q <= 1'b0;

                    for (
                        integer retire_lane = 0;
                        retire_lane < PHYSICAL_LANES;
                        retire_lane = retire_lane + 1
                    ) begin
                        if (vector_seq_active_mask[retire_lane]) begin
                            if (exec_memory_instruction) begin : rtl7c_memory_lane
                                logic signed [63:0] lane_address;

                                lane_address = indexed_word_address(
                                    exec_scalar_base_q,
                                    operand_src1_data[
                                        retire_lane*32 +: 32
                                    ],
                                    exec_imm_q
                                );

                                mem_build_lane_mask_q[
                                    vector_seq_logical_lane[retire_lane]
                                ] <= 1'b1;

                                if (
                                    lane_address < 0
                                    || lane_address
                                        >= GLOBAL_MEMORY_WORDS_LIMIT
                                ) begin
                                    mem_build_fault_q <= 1'b1;
                                    mem_build_addr_q[
                                        vector_seq_logical_lane[retire_lane]
                                    ] <= '0;
                                end else begin
                                    mem_build_addr_q[
                                        vector_seq_logical_lane[retire_lane]
                                    ] <= lane_address[31:0];
                                end

                                if (exec_opcode_q == OP_VSTOREX) begin
                                    mem_build_wdata_q[
                                        vector_seq_logical_lane[retire_lane]
                                    ] <= operand_src2_data[
                                        retire_lane*32 +: 32
                                    ];
                                end else begin
                                    mem_build_wdata_q[
                                        vector_seq_logical_lane[retire_lane]
                                    ] <= '0;
                                end

                            end else begin
                                if (exec_vector_dst_enable_q) begin
                                    vector_shadow[
                                        exec_vrf_context_q
                                    ][
                                        VECTOR_REG_INDEX_W'(exec_dst_q)
                                    ][
                                        vector_seq_logical_lane[retire_lane]
                                    ] <= execute_result_data[
                                        retire_lane*32 +: 32
                                    ];
                                end

                                if (exec_predicate_dst_enable_q) begin
                                    case (exec_opcode_q)
                                        OP_VCMP_EQ: begin
                                            compare_accum_q[
                                                vector_seq_logical_lane[
                                                    retire_lane
                                                ]
                                            ] <= (
                                                operand_src0_data[
                                                    retire_lane*32 +: 32
                                                ]
                                                == operand_src1_data[
                                                    retire_lane*32 +: 32
                                                ]
                                            );
                                        end
                                        OP_VCMP_LT: begin
                                            compare_accum_q[
                                                vector_seq_logical_lane[
                                                    retire_lane
                                                ]
                                            ] <= (
                                                operand_src0_data[
                                                    retire_lane*32 +: 32
                                                ]
                                                < operand_src1_data[
                                                    retire_lane*32 +: 32
                                                ]
                                            );
                                        end
                                        OP_VCMP_LE: begin
                                            compare_accum_q[
                                                vector_seq_logical_lane[
                                                    retire_lane
                                                ]
                                            ] <= (
                                                operand_src0_data[
                                                    retire_lane*32 +: 32
                                                ]
                                                <= operand_src1_data[
                                                    retire_lane*32 +: 32
                                                ]
                                            );
                                        end
                                        default: begin
                                        end
                                    endcase
                                end
                            end
                        end
                    end
                end

                /*
                 * RTL8C queue head -> one physical legacy store transaction.
                 * The queue pops on this launch edge; architectural ownership
                 * remains in mem_owner_* until the tagged backend response.
                 */
                if (store_queue_drain_fire) begin
                    mem_pending_valid_q <= 1'b1;
                    mem_pending_load_q <= 1'b0;

                    mem_owner_wave_q <= store_queue_drain_wave;
                    mem_owner_context_q <= store_queue_drain_context;
                    mem_owner_pc_q <=
                        store_owner_pc_by_wave_q[
                            integer'(store_queue_drain_wave)
                        ];
                    mem_owner_resume_pc_q <=
                        store_owner_resume_pc_by_wave_q[
                            integer'(store_queue_drain_wave)
                        ];
                    mem_owner_exec_mask_q <=
                        store_owner_exec_mask_by_wave_q[
                            integer'(store_queue_drain_wave)
                        ];
                    mem_owner_reconv_sp_q <=
                        store_owner_reconv_sp_by_wave_q[
                            integer'(store_queue_drain_wave)
                        ];
                    mem_owner_dst_q <= '0;
                    mem_owner_lane_mask_q <= store_queue_drain_lane_mask;
                    mem_owner_store_seq_q <= store_queue_drain_seq;

                    service_legacy_req_valid <= 1'b1;
                    service_legacy_req_write <= 1'b1;
                    service_legacy_req_wave <= store_queue_drain_wave;
                    service_legacy_req_context <= store_queue_drain_context;
                    service_legacy_req_lane_mask <= store_queue_drain_lane_mask;

                    for (
                        integer memory_lane = 0;
                        memory_lane < WAVE_SIZE;
                        memory_lane = memory_lane + 1
                    ) begin
                        service_legacy_req_addr[memory_lane] <=
                            store_queue_drain_word_addr[memory_lane];
                        service_legacy_req_wdata[memory_lane] <=
                            store_queue_drain_wdata[memory_lane];
                        mem_owner_store_addr_q[memory_lane] <=
                            store_queue_drain_word_addr[memory_lane];
                        mem_owner_store_wdata_q[memory_lane] <=
                            store_queue_drain_wdata[memory_lane];
                    end
                end

                if (direct_retire_fire) begin
                    retire_valid_o <= 1'b1;
                    retire_wave_o <= frontend_grant_wave;
                    retire_pc_o <= frontend_selected_pc;

                    if (
                        !selected_supported_instruction
                        || classifier_contract_fault
                    ) begin
                        faulted_o <= 1'b1;
                    end
                end

                if (vector_release_fire) begin
                    exec_active_q <= 1'b0;
                    beat_request_sent_q <= 1'b0;

                    if (legacy_memory_launch_fire) begin
                        mem_pending_valid_q <= 1'b1;
                        mem_pending_load_q <=
                            exec_opcode_q == OP_VLOADX;

                        mem_owner_wave_q <= exec_wave_q;
                        mem_owner_context_q <= exec_vrf_context_q;
                        mem_owner_pc_q <= exec_pc_q;
                        mem_owner_resume_pc_q <= exec_pc_q + PC_W'(1);
                        mem_owner_exec_mask_q <= exec_mask_q;
                        mem_owner_reconv_sp_q <= exec_reconv_sp_q;
                        mem_owner_dst_q <=
                            VECTOR_REG_INDEX_W'(exec_dst_q);
                        mem_owner_lane_mask_q <= mem_build_lane_mask_q;

                        service_legacy_req_valid <= 1'b1;
                        service_legacy_req_write <=
                            exec_opcode_q == OP_VSTOREX;
                        service_legacy_req_wave <= exec_wave_q;
                        service_legacy_req_context <= exec_vrf_context_q;
                        service_legacy_req_lane_mask <= mem_build_lane_mask_q;

                        for (
                            integer memory_lane = 0;
                            memory_lane < WAVE_SIZE;
                            memory_lane = memory_lane + 1
                        ) begin
                            service_legacy_req_addr[memory_lane] <=
                                mem_build_addr_q[memory_lane];
                            service_legacy_req_wdata[memory_lane] <=
                                mem_build_wdata_q[memory_lane];
                        end

                    end else if (store_queue_enqueue_fire) begin
                        /*
                         * Queueing is not architectural retirement. Preserve
                         * the original store instruction state by wave until
                         * the FIFO head is launched to the physical backend.
                         */
                        store_owner_pc_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= exec_pc_q;
                        store_owner_resume_pc_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= exec_pc_q + PC_W'(1);
                        store_owner_exec_mask_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= exec_mask_q;
                        store_owner_reconv_sp_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= exec_reconv_sp_q;

                    end else if (load_order_hold_fire) begin
                        load_order_wait_valid_q <= 1'b1;
                        load_order_wait_wave_q <= exec_wave_q;
                        load_order_wait_context_q <= exec_vrf_context_q;
                        load_order_wait_dst_q <=
                            VECTOR_REG_INDEX_W'(exec_dst_q);
                        load_order_wait_pc_q <= exec_pc_q;
                        load_order_wait_resume_pc_q <=
                            exec_pc_q + PC_W'(1);
                        load_order_wait_exec_mask_q <= exec_mask_q;
                        load_order_wait_reconv_sp_q <= exec_reconv_sp_q;
                        load_order_wait_lane_mask_q <= mem_build_lane_mask_q;
                        load_order_wait_store_seq_boundary_q <= store_seq_next_q;

                        for (
                            integer memory_lane = 0;
                            memory_lane < WAVE_SIZE;
                            memory_lane = memory_lane + 1
                        ) begin
                            load_order_wait_addr_q[memory_lane] <=
                                mem_build_addr_q[memory_lane];
                        end

                    end else if (mshr_load_launch_fire) begin
                        mshr_owner_store_seq_boundary_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= store_seq_next_q;
                        /*
                         * The bridge owns line allocation/merge/response state.
                         * Keep only architectural retirement metadata per wave
                         * until the whole VLOADX completes.
                         */
                        mshr_owner_pc_by_wave_q[integer'(exec_wave_q)] <=
                            exec_pc_q;
                        mshr_owner_resume_pc_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= exec_pc_q + PC_W'(1);
                        mshr_owner_exec_mask_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= exec_mask_q;
                        mshr_owner_reconv_sp_by_wave_q[
                            integer'(exec_wave_q)
                        ] <= exec_reconv_sp_q;

                    end else begin
                        /*
                         * Normal vector/compare retirement, an all-masked
                         * memory no-op, or fail-before-access address fault.
                         */
                        retire_valid_o <= 1'b1;
                        retire_wave_o <= exec_wave_q;
                        retire_pc_o <= exec_pc_q;

                        if (memory_fault_release_fire) begin
                            faulted_o <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    /*
     * RTL8C buffered store path. The queue keeps backend order/data while
     * per-wave architectural metadata stays in the core until physical launch.
     */
    a0_store_queue #(
        .STORE_QUEUE_DEPTH(STORE_QUEUE_DEPTH),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(MSHR_LINE_WORDS),
        .STORE_SEQ_W(STORE_SEQ_W)
    ) store_queue (
        .clk(clk),
        .rst_n(rst_n),

        .enqueue_valid_i(store_queue_enqueue_valid),
        .enqueue_ready_o(store_queue_enqueue_ready),
        .enqueue_fire_o(store_queue_enqueue_fire),
        .enqueue_wave_i(exec_wave_q),
        .enqueue_context_i(exec_vrf_context_q),
        .enqueue_seq_i(store_seq_next_q),
        .enqueue_lane_mask_i(mem_build_lane_mask_q),
        .enqueue_word_addr_i(mem_build_addr_q),
        .enqueue_wdata_i(mem_build_wdata_q),

        .drain_valid_o(store_queue_drain_valid),
        .drain_ready_i(store_queue_drain_ready),
        .drain_fire_o(store_queue_drain_fire),
        .drain_wave_o(store_queue_drain_wave),
        .drain_context_o(store_queue_drain_context),
        .drain_seq_o(store_queue_drain_seq),
        .drain_lane_mask_o(store_queue_drain_lane_mask),
        .drain_word_addr_o(store_queue_drain_word_addr),
        .drain_wdata_o(store_queue_drain_wdata),

        .probe_valid_i(store_queue_probe_valid),
        .probe_lane_mask_i(store_queue_probe_lane_mask),
        .probe_word_addr_i(store_queue_probe_word_addr),
        .probe_seq_boundary_i(store_queue_probe_seq_boundary),
        .probe_conflict_o(store_queue_probe_exact_conflict),
        .probe_conflict_lane_mask_o(
            store_queue_probe_exact_conflict_lane_mask_unused
        ),
        .probe_line_conflict_o(store_queue_probe_line_conflict),
        .probe_line_conflict_lane_mask_o(
            store_queue_probe_line_conflict_lane_mask
        ),
        .probe_source_valid_lane_mask_o(
            store_queue_probe_source_valid_lane_mask
        ),
        .probe_source_ambiguous_lane_mask_o(
            store_queue_probe_source_ambiguous_lane_mask
        ),
        .probe_source_seq_o(store_queue_probe_source_seq),
        .probe_source_wdata_o(store_queue_probe_source_wdata),

        .occupancy_o(store_queue_occupancy),
        .full_o(store_queue_full),
        .empty_o(store_queue_empty),
        .active_wave_mask_o(store_queue_active_wave_mask_unused),
        .enqueue_stall_o(store_queue_enqueue_stall_unused)
    );


    /*
     * RTL8B live load path. Whole-wave VLOADX transactions are decomposed
     * into cache lines and merged/routed through the proven RTL8A table.
     */
    a0_memory_service_boundary #(
        .WAVE_SIZE(WAVE_SIZE), .WAVE_ID_W(WAVE_ID_W),
        .LINE_WORDS(MSHR_LINE_WORDS), .ENTRY_W(MSHR_ENTRY_W),
        .LINE_ADDR_W(MSHR_LINE_ADDR_W), .MSHR_COUNT(MSHR_COUNT),
        .L1_SET_COUNT(64),
        .STORE_OBSERVER_COUNT(STORE_OBSERVER_COUNT)
    ) memory_service_boundary (
        .clk(clk),
        .rst_n(rst_n),
        .cluster_store_observe_enable_i(
            cluster_store_observe_enable_i
        ),
        .launch_observe_valid_i(launch_observe_valid_i),
        .launch_observe_lane_mask_i(launch_observe_lane_mask_i),
        .launch_observe_word_addr_i(launch_observe_word_addr_i),
        .legacy_req_valid_i(service_legacy_req_valid),
        .legacy_req_write_i(service_legacy_req_write),
        .legacy_req_wave_i(service_legacy_req_wave),
        .legacy_req_context_i(service_legacy_req_context),
        .legacy_req_lane_mask_i(service_legacy_req_lane_mask),
        .legacy_req_addr_i(service_legacy_req_addr),
        .legacy_req_wdata_i(service_legacy_req_wdata),
        .legacy_req_valid_o(mem_req_valid_o),
        .legacy_req_write_o(mem_req_write_o),
        .legacy_req_wave_o(mem_req_wave_o),
        .legacy_req_context_o(mem_req_context_o),
        .legacy_req_lane_mask_o(mem_req_lane_mask_o),
        .legacy_req_addr_o(mem_req_addr_o),
        .legacy_req_wdata_o(mem_req_wdata_o),
        .legacy_resp_valid_i(mem_resp_valid_i),
        .legacy_resp_wave_i(mem_resp_wave_i),
        .legacy_resp_context_i(mem_resp_context_i),
        .legacy_resp_fault_i(mem_resp_fault_i),
        .legacy_resp_rdata_i(mem_resp_rdata_i),
        .legacy_resp_valid_o(service_legacy_resp_valid),
        .legacy_resp_wave_o(service_legacy_resp_wave),
        .legacy_resp_context_o(service_legacy_resp_context),
        .legacy_resp_fault_o(service_legacy_resp_fault),
        .legacy_resp_rdata_o(service_legacy_resp_rdata),
        .line_req_valid_i(service_mshr_req_valid),
        .line_req_ready_o(service_mshr_req_ready),
        .line_req_entry_i(service_mshr_req_entry),
        .line_req_line_addr_i(service_mshr_req_line_addr),
        .line_req_valid_o(mshr_mem_req_valid_o),
        .line_req_ready_i(mshr_mem_req_ready_i),
        .line_req_entry_o(mshr_mem_req_entry_o),
        .line_req_line_addr_o(mshr_mem_req_line_addr_o),
        .line_resp_valid_i(mshr_mem_resp_valid_i),
        .line_resp_entry_i(mshr_mem_resp_entry_i),
        .line_resp_line_addr_i(mshr_mem_resp_line_addr_i),
        .line_resp_fault_i(mshr_mem_resp_fault_i),
        .line_resp_data_i(mshr_mem_resp_line_data_i),
        .line_resp_valid_o(service_mshr_resp_valid),
        .line_resp_entry_o(service_mshr_resp_entry),
        .line_resp_line_addr_o(service_mshr_resp_line_addr),
        .line_resp_fault_o(service_mshr_resp_fault),
        .line_resp_data_o(service_mshr_resp_line_data)
    );

    a0_wave_load_mshr_bridge #(
        .MSHR_COUNT(MSHR_COUNT),
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .WAVE_SIZE(WAVE_SIZE),
        .LINE_WORDS(MSHR_LINE_WORDS),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .STORE_SEQ_W(STORE_SEQ_W),
        .PEER_STORE_SOURCE_COUNT(STORE_OBSERVER_COUNT)
    ) load_mshr_bridge (
        .clk(clk),
        .rst_n(rst_n),

        .load_valid_i(load_mshr_req_valid),
        .load_ready_o(load_mshr_req_ready),
        .load_fire_o(load_mshr_req_fire),
        .load_wave_i(load_mshr_req_wave),
        .load_context_i(load_mshr_req_context),
        .load_dst_i(load_mshr_req_dst),
        .load_lane_mask_i(load_mshr_req_lane_mask),
        .load_word_addr_i(load_mshr_req_word_addr),
        .load_forward_valid_lane_mask_i(
            load_store_forward_safe_lane_mask
        ),
        .load_forward_seq_i(load_store_source_seq),
        .load_forward_data_i(load_store_source_wdata),

        .store_resolve_valid_i(store_response_resolve_fire),
        .store_resolve_seq_i(mem_owner_store_seq_q),
        .store_resolve_fault_i(service_legacy_resp_fault),
        .ordering_store_valid_i(ordering_store_valid_i),
        .ordering_store_lane_mask_i(ordering_store_lane_mask_i),
        .ordering_store_word_addr_i(ordering_store_word_addr_i),
        .terminal_store_valid_i(terminal_store_valid_i),
        .terminal_store_lane_mask_i(terminal_store_lane_mask_i),
        .terminal_store_word_addr_i(terminal_store_word_addr_i),

        .miss_req_valid_o(service_mshr_req_valid),
        .miss_req_ready_i(service_mshr_req_ready),
        .miss_req_entry_o(service_mshr_req_entry),
        .miss_req_line_addr_o(service_mshr_req_line_addr),

        .miss_resp_valid_i(service_mshr_resp_valid),
        .miss_resp_entry_i(service_mshr_resp_entry),
        .miss_resp_line_addr_i(service_mshr_resp_line_addr),
        .miss_resp_fault_i(service_mshr_resp_fault),
        .miss_resp_line_data_i(service_mshr_resp_line_data),
        .response_tag_error_o(mshr_tag_error_o),

        .complete_valid_o(load_mshr_complete_valid),
        .complete_ready_i(load_mshr_complete_ready),
        .complete_wave_o(load_mshr_complete_wave),
        .complete_context_o(load_mshr_complete_context),
        .complete_dst_o(load_mshr_complete_dst),
        .complete_lane_mask_o(load_mshr_complete_lane_mask),
        .complete_fault_o(load_mshr_complete_fault),
        .complete_data_o(load_mshr_complete_data),

        .occupancy_o(mshr_occupancy_o),
        .full_o(mshr_full_o),
        .empty_o(load_mshr_empty),
        .active_wave_mask_o(mshr_active_wave_mask_o),
        .allocation_event_o(load_mshr_allocation_event_unused),
        .merge_event_o(mshr_merge_event_o),
        .allocator_stall_o(load_mshr_allocator_stall_unused),
        .forward_dependency_active_o(load_mshr_forward_dependency_active)
    );


    a0_dependency_classifier dependency_classifier (
        .instruction_valid(
            run_enable
            && !exec_active_q
            && frontend_grant_valid
            && frontend_selected_valid
            && selected_vector_instruction
        ),
        .opcode(selected_opcode),
        .flags(selected_flags),
        .dst_index(selected_dst),
        .src0_index(selected_src0),
        .src1_index(selected_src1),
        .src2_index(selected_src2),
        .pred_index(selected_pred),
        .tracked_instruction(classifier_tracked),
        .vector_src0_enable(classifier_src0_enable),
        .vector_src0(classifier_src0),
        .vector_src1_enable(classifier_src1_enable),
        .vector_src1(classifier_src1),
        .vector_src2_enable(classifier_src2_enable),
        .vector_src2(classifier_src2),
        .vector_dst_enable(classifier_vector_dst_enable),
        .vector_dst(classifier_vector_dst),
        .predicate_src_enable(classifier_predicate_src_enable),
        .predicate_src(classifier_predicate_src),
        .predicate_dst_enable(classifier_predicate_dst_enable),
        .predicate_dst(classifier_predicate_dst)
    );


    a0_wave_scoreboard_bank #(
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT)
    ) scoreboard_bank (
        .clk(clk),
        .rst_n(rst_n),
        .query_valid(classifier_tracked),
        .query_wave(frontend_grant_wave),
        .query_vector_src0_enable(classifier_src0_enable),
        .query_vector_src0(VECTOR_REG_INDEX_W'(classifier_src0)),
        .query_vector_src1_enable(classifier_src1_enable),
        .query_vector_src1(VECTOR_REG_INDEX_W'(classifier_src1)),
        .query_vector_src2_enable(classifier_src2_enable),
        .query_vector_src2(VECTOR_REG_INDEX_W'(classifier_src2)),
        .query_vector_dst_enable(classifier_vector_dst_enable),
        .query_vector_dst(VECTOR_REG_INDEX_W'(classifier_vector_dst)),
        .query_predicate_src_enable(classifier_predicate_src_enable),
        .query_predicate_src(PREDICATE_INDEX_W'(classifier_predicate_src)),
        .query_predicate_dst_enable(classifier_predicate_dst_enable),
        .query_predicate_dst(PREDICATE_INDEX_W'(classifier_predicate_dst)),

        .reserve_valid(vector_issue_fire),
        .reserve_wave(frontend_grant_wave),
        .reserve_vector_dst_enable(classifier_vector_dst_enable),
        .reserve_vector_dst(VECTOR_REG_INDEX_W'(classifier_vector_dst)),
        .reserve_predicate_dst_enable(classifier_predicate_dst_enable),
        .reserve_predicate_dst(PREDICATE_INDEX_W'(classifier_predicate_dst)),

        .release_valid(scoreboard_release_fire),
        .release_wave(
            memory_complete_fire
                ? mem_owner_wave_q
                : exec_wave_q
        ),
        .release_vector_dst_enable(
            memory_complete_fire
                ? mem_pending_load_q
                : (
                    exec_vector_dst_enable_q
                    && !memory_launch_fire
                )
        ),
        .release_vector_dst(
            memory_complete_fire
                ? mem_owner_dst_q
                : VECTOR_REG_INDEX_W'(exec_dst_q)
        ),
        .release_predicate_dst_enable(
            memory_complete_fire
                ? 1'b0
                : exec_predicate_dst_enable_q
        ),
        .release_predicate_dst(PREDICATE_INDEX_W'(exec_pred_q)),

        .clear_valid(
            release_valid
            && !run_enable
            && maintenance_idle
        ),
        .clear_wave(release_wave_id),

        .vector_raw_hazard(scoreboard_vector_raw_hazard_unused),
        .vector_waw_hazard(scoreboard_vector_waw_hazard_unused),
        .predicate_raw_hazard(scoreboard_predicate_raw_hazard_unused),
        .predicate_waw_hazard(scoreboard_predicate_waw_hazard_unused),
        .any_hazard(scoreboard_any_hazard_unused),
        .issue_allowed(scoreboard_issue_allowed),
        .vector_busy_by_wave(scoreboard_vector_busy),
        .predicate_busy_by_wave(scoreboard_predicate_busy)
    );


    a0_vector_operand_path_contexted #(
        .CONTEXT_COUNT(RESIDENT_WAVES),
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(4)
    ) vector_operand_path (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(operand_req_valid),
        .req_ready(operand_req_ready),
        .req_context(exec_vrf_context_q),
        .req_src0_enable(exec_src0_enable_q),
        .req_src1_enable(exec_src1_enable_q),
        .req_src2_enable(exec_src2_enable_q),
        .req_src0(VECTOR_REG_INDEX_W'(exec_src0_q)),
        .req_src1(VECTOR_REG_INDEX_W'(exec_src1_q)),
        .req_src2(VECTOR_REG_INDEX_W'(exec_src2_q)),
        .req_beat(VECTOR_BEAT_INDEX_W'(vector_seq_beat_index_with_unused_high)),
        .result_valid(operand_result_valid),
        .result_ready(operand_result_ready),
        .result_src0_data(operand_src0_data),
        .result_src1_data(operand_src1_data),
        .result_src2_data(operand_src2_data),
        .busy(operand_busy_unused),
        .bank_conflict_cycle(operand_bank_conflict_cycle),
        .write_valid(vrf_write_valid),
        .write_context(vrf_write_context),
        .write_reg(vrf_write_reg),
        .write_beat(vrf_write_beat),
        .write_lane_mask(vrf_write_lane_mask),
        .write_data(vrf_write_data),
        .write_ready(vrf_write_ready)
    );


    a0_lane_sequencer #(
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES)
    ) lane_sequencer (
        .clk(clk),
        .rst_n(rst_n),
        .advance_enable(sequence_advance_enable),
        .start(vector_issue_fire),
        .exec_mask(
            vector_issue_fire
                ? frontend_selected_exec_mask
                : exec_mask_q
        ),
        .pred_enable(
            vector_issue_fire
                ? (
                    selected_flags[0]
                    && (
                        selected_opcode == OP_VADD
                        || selected_opcode == OP_VSUB
                        || selected_opcode == OP_VMUL
                        || selected_opcode == OP_VAND
                        || selected_opcode == OP_VOR
                        || selected_opcode == OP_VXOR
                        || selected_opcode == OP_VLOADX
                        || selected_opcode == OP_VSTOREX
                    )
                )
                : (
                    exec_predicate_enable_q
                    && (
                        exec_opcode_q == OP_VADD
                        || exec_opcode_q == OP_VSUB
                        || exec_opcode_q == OP_VMUL
                        || exec_opcode_q == OP_VAND
                        || exec_opcode_q == OP_VOR
                        || exec_opcode_q == OP_VXOR
                        || exec_opcode_q == OP_VLOADX
                        || exec_opcode_q == OP_VSTOREX
                    )
                )
        ),
        .pred_mask(
            vector_issue_fire
                ? frontend_predicate_data
                : exec_predicate_mask_q
        ),
        .busy(vector_seq_busy),
        .done(vector_seq_done),
        .beat_valid(vector_seq_beat_valid),
        .beat_index(vector_seq_beat_index_with_unused_high),
        .physical_valid_mask(vector_seq_valid_mask_unused),
        .physical_active_mask(vector_seq_active_mask),
        .logical_lane(vector_seq_logical_lane)
    );


    a0_multi_wave_frontend #(
        .RESIDENT_WAVES(RESIDENT_WAVES),
        .PROGRAM_WORDS(PROGRAM_WORDS),
        .WAVE_SIZE(WAVE_SIZE),
        .SCALAR_REG_COUNT(SCALAR_REG_COUNT),
        .PREDICATE_REG_COUNT(PREDICATE_REG_COUNT),
        .SCALAR_PREDICATE_REG_COUNT(SCALAR_PREDICATE_REG_COUNT),
        .RECONV_STACK_DEPTH(RECONV_STACK_DEPTH)
    ) frontend (
        .clk(clk),
        .rst_n(rst_n),
        .alloc_valid(
            alloc_valid
            && !run_enable
            && maintenance_idle
            && alloc_mapping_valid
        ),
        .alloc_wave_id(alloc_wave_id),
        .alloc_ready(frontend_alloc_ready),
        .alloc_pc(alloc_pc),
        .alloc_exec_mask(alloc_exec_mask),
        .alloc_vrf_context_id(alloc_vrf_context_id),
        .release_valid(
            release_valid
            && !run_enable
            && maintenance_idle
        ),
        .release_wave_id(release_wave_id),

        .state_write_valid(state_write_valid),
        .state_write_wave_id(state_write_wave),
        .state_write_pc(state_write_pc),
        .state_write_exec_mask(state_write_exec_mask),
        .state_write_reconv_sp(state_write_reconv_sp),
        .state_write_halted(state_write_halted),
        .state_write_blocked(1'b0),
        .state_write_memory_waiting(state_write_memory_waiting),
        .state_write_barrier_waiting(1'b0),

        .scalar_write_valid(scalar_write_valid),
        .scalar_write_wave_id(scalar_write_wave),
        .scalar_write_reg(scalar_write_reg),
        .scalar_write_data(scalar_write_data),

        .predicate_write_valid(predicate_write_valid),
        .predicate_write_wave_id(predicate_write_wave),
        .predicate_write_reg(predicate_write_reg),
        .predicate_write_data(predicate_write_data),

        .scalar_predicate_write_valid(1'b0),
        .scalar_predicate_write_wave_id('0),
        .scalar_predicate_write_reg('0),
        .scalar_predicate_write_data(1'b0),

        .reconv_write_valid(1'b0),
        .reconv_write_wave_id('0),
        .reconv_write_index('0),
        .reconv_write_parent_mask('0),
        .reconv_write_else_mask('0),
        .reconv_write_else_entered(1'b0),

        .external_block_mask_i(execution_block_mask),
        .memory_ready_mask_i(memory_ready_mask),
        .non_memory_ready_mask_i(non_memory_ready_mask),
        .memory_stalled_mask_i(memory_stalled_mask),
        .merge_ready_mask_i('0),
        .mshr_occupancy_i(
            ENABLE_LOAD_MSHR
                ? 8'(mshr_occupancy_o)
                : (memory_outstanding_o ? 8'd1 : 8'd0)
        ),
        .mshr_capacity_i(
            ENABLE_LOAD_MSHR
                ? 8'(MSHR_COUNT)
                : 8'd1
        ),
        .policy_override_valid_i(
            policy_override_valid_i && !exec_active_q
        ),
        .policy_override_wave_i(policy_override_wave_i),
        .grant_fire_i(scheduler_grant_fire),

        .selected_scalar_read_reg(
            SCALAR_REG_INDEX_W'(selected_src0)
        ),
        .selected_scalar_read_reg1(
            SCALAR_REG_INDEX_W'(selected_src1)
        ),
        .selected_predicate_read_reg(
            PREDICATE_INDEX_W'(selected_pred)
        ),
        .selected_scalar_predicate_read_reg('0),
        .selected_reconv_read_index('0),

        .debug_read_wave_id_i(debug_context_i),
        .debug_scalar_read_reg_i(debug_scalar_reg_i),
        .debug_predicate_read_reg_i(debug_predicate_reg_i),
        .debug_read_valid_o(debug_context_valid_o),
        .debug_read_pc_o(debug_pc_o),
        .debug_read_exec_mask_o(debug_exec_mask_o),
        .debug_read_halted_o(debug_halted_o),
        .debug_scalar_read_data_o(debug_scalar_data_o),
        .debug_predicate_read_data_o(debug_predicate_data_o),

        .grant_valid_o(frontend_grant_valid),
        .grant_wave_o(frontend_grant_wave),
        .policy_override_accepted_o(
            frontend_policy_override_accepted_unused
        ),
        .selected_context_valid_o(frontend_selected_valid),
        .selected_pc_o(frontend_selected_pc),
        .selected_exec_mask_o(frontend_selected_exec_mask),
        .selected_reconv_sp_o(frontend_selected_reconv_sp),
        .selected_halted_o(frontend_selected_halted_unused),
        .selected_blocked_o(frontend_selected_blocked_unused),
        .selected_memory_waiting_o(
            frontend_selected_memory_waiting_unused
        ),
        .selected_barrier_waiting_o(
            frontend_selected_barrier_waiting_unused
        ),
        .selected_vrf_context_id_o(
            frontend_selected_vrf_context
        ),
        .selected_scalar_read_data_o(frontend_scalar_src0),
        .selected_scalar_read_data1_o(frontend_scalar_src1),
        .selected_predicate_read_data_o(frontend_predicate_data),
        .selected_scalar_predicate_read_data_o(
            frontend_scalar_predicate_unused
        ),
        .selected_reconv_parent_mask_o(
            frontend_reconv_parent_unused
        ),
        .selected_reconv_else_mask_o(
            frontend_reconv_else_unused
        ),
        .selected_reconv_else_entered_o(
            frontend_reconv_else_entered_unused
        ),
        .valid_mask_o(valid_mask_o),
        .pc_by_wave_o(context_pc_by_wave),
        .architectural_ready_mask_o(architectural_ready_mask),
        .scheduler_ready_mask_o(scheduler_ready_mask),
        .halted_mask_o(halted_mask_o),
        .blocked_mask_o(blocked_mask_unused),
        .memory_waiting_mask_o(memory_waiting_mask),
        .barrier_waiting_mask_o(barrier_waiting_mask_unused),
        .pressure_high_o(frontend_pressure_high_unused),
        .merge_ready_visible_o(frontend_merge_ready_unused),
        .ready_count_o(frontend_ready_count_unused),
        .memory_ready_count_o(
            frontend_memory_ready_count_unused
        ),
        .non_memory_ready_count_o(
            frontend_non_memory_ready_count_unused
        ),
        .memory_stalled_count_o(
            frontend_memory_stalled_count_unused
        ),
        .merge_ready_count_o(
            frontend_merge_ready_count_unused
        ),
        .rr_cursor_o(rr_cursor_o)
    );

    assign ready_mask_o = scheduler_ready_mask;


endmodule
