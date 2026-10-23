`timescale 1ns/1ps

module a0_wave_core #(
    parameter integer WAVE_SIZE = 32,

    parameter integer PHYSICAL_LANES =
        WAVE_SIZE,

    parameter integer VECTOR_REG_COUNT = 64,
    parameter integer SCALAR_REG_COUNT = 32,
    parameter integer PREDICATE_REG_COUNT = 16,
    parameter integer SCALAR_PREDICATE_REG_COUNT = 16,
    parameter integer RECONV_STACK_DEPTH = 16,
    parameter integer GLOBAL_MEMORY_WORDS = 1024,
    parameter integer PROGRAM_WORDS = 256
) (
    input  logic clk,
    input  logic rst_n,
    input  logic run_enable,

    input  logic program_we,
    input  logic [$clog2(PROGRAM_WORDS)-1:0]
        program_waddr,
    input  logic [63:0] program_wdata,

    input  logic vector_we,
    input  logic [$clog2(VECTOR_REG_COUNT)-1:0]
        vector_wreg,
    input  logic [$clog2(WAVE_SIZE)-1:0]
        vector_wlane,
    input  logic [31:0] vector_wdata,

    input  logic scalar_we,
    input  logic [$clog2(SCALAR_REG_COUNT)-1:0]
        scalar_wreg,
    input  logic [31:0] scalar_wdata,

    /*
     * RTL2 architectural global-memory interface.
     *
     * Addresses are word addresses, not byte addresses.
     */
    output logic mem_req_valid,
    output logic mem_req_write,

    output logic [WAVE_SIZE-1:0]
        mem_req_lane_mask,

    output logic [31:0]
        mem_req_addr [0:WAVE_SIZE-1],

    output logic [31:0]
        mem_req_wdata [0:WAVE_SIZE-1],

    input  logic mem_resp_valid,
    input  logic mem_resp_fault,

    input  logic [31:0]
        mem_resp_rdata [0:WAVE_SIZE-1],

    output logic halted,
    output logic faulted,
    output logic [$clog2(PROGRAM_WORDS)-1:0] pc
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

    localparam logic [7:0] OP_SCMP_LT = 8'h63;

    localparam logic [7:0] OP_JMP     = 8'h70;
    localparam logic [7:0] OP_BRA     = 8'h71;
    localparam logic [7:0] OP_SPLIT   = 8'h72;
    localparam logic [7:0] OP_ELSE    = 8'h73;
    localparam logic [7:0] OP_JOIN    = 8'h74;

    localparam logic [7:0] OP_HALT    = 8'hFF;

    logic [63:0] program_mem
        [0:PROGRAM_WORDS-1];

    logic [31:0] vector_regs
        [0:VECTOR_REG_COUNT-1]
        [0:WAVE_SIZE-1];

    logic [31:0] scalar_regs
        [0:SCALAR_REG_COUNT-1];

    logic [WAVE_SIZE-1:0] predicate_regs
        [0:PREDICATE_REG_COUNT-1];

    logic scalar_predicate_regs
        [0:SCALAR_PREDICATE_REG_COUNT-1];

    logic [WAVE_SIZE-1:0] exec_mask;


    /*
     * A0-RTL4B physical vector execution state.
     *
     * vector_waiting means the architectural instruction
     * at the current PC has been launched but has not yet
     * completed all of its physical SIMD beats.
     */
    logic vector_waiting;

    /*
     * A0-RTL5A vector execution instruction latch.
     *
     * Once issued, physical beats consume these fields
     * instead of live program_mem[pc] decode.
     */
    logic [7:0] vector_issue_opcode;
    logic [3:0] vector_issue_flags /* verilator public_flat */;

    logic [5:0] vector_issue_dst_index;
    logic [5:0] vector_issue_src0_index;
    logic [5:0] vector_issue_src1_index;
    logic [5:0] vector_issue_src2_index;

    logic [3:0] vector_issue_pred_index;

    /*
     * Dependency semantics are latched with the issued instruction.
     * RTL6B uses these bits both for operand collection and release,
     * removing duplicated opcode lists from the execution path.
     */
    logic vector_issue_src0_enable;
    logic vector_issue_src1_enable;
    logic vector_issue_src2_enable;
    logic vector_issue_vector_dst_enable;
    logic vector_issue_predicate_dst_enable;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        vector_issue_pc;


    /*
     * A0-RTL5C one-entry pending vector instruction.
     *
     * The pending entry owns the immediate sequential
     * vector instruction following an issued vector op.
     */
    logic vector_pending_valid;

    logic [7:0] vector_pending_opcode;
    logic [3:0] vector_pending_flags;

    logic [5:0] vector_pending_dst_index;
    logic [5:0] vector_pending_src0_index;
    logic [5:0] vector_pending_src1_index;
    logic [5:0] vector_pending_src2_index;

    logic [3:0] vector_pending_pred_index;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        vector_pending_pc;


    /*
     * Dependency-query source.
     *
     * A pending instruction has priority over live decode
     * because it already owns that architectural slot.
     */
    logic [7:0] dependency_opcode;
    logic [3:0] dependency_flags;

    logic [5:0] dependency_dst_index;
    logic [5:0] dependency_src0_index;
    logic [5:0] dependency_src1_index;
    logic [5:0] dependency_src2_index;

    logic [3:0] dependency_pred_index;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        dependency_pc;


    logic direct_vector_issue_fire;
    logic pending_vector_issue_fire;
    logic pending_handoff_fire;


    /*
     * Sequential prefetch generated by the instruction
     * that is actually issuing.
     */
    localparam logic [31:0] PROGRAM_WORDS_LIMIT =
        32'(PROGRAM_WORDS);

    logic [31:0] vector_prefetch_pc_extended;

    logic vector_prefetch_valid;

    logic [$clog2(PROGRAM_WORDS)-1:0]
        vector_prefetch_pc;

    logic [63:0] vector_prefetch_instruction_with_unused_imm;

    logic [7:0] vector_prefetch_opcode;
    logic [3:0] vector_prefetch_flags;

    logic [5:0] vector_prefetch_dst_index;
    logic [5:0] vector_prefetch_src0_index;
    logic [5:0] vector_prefetch_src1_index;
    logic [5:0] vector_prefetch_src2_index;

    logic [3:0] vector_prefetch_pred_index;


    /*
     * A0-RTL5B live dependency / scoreboard state.
     */
    logic scoreboard_query_valid;
    logic scoreboard_issue_allowed;
    logic scoreboard_any_hazard_unused;

    logic scoreboard_vector_raw_hazard /* verilator public_flat */;
    logic scoreboard_vector_waw_hazard /* verilator public_flat */;

    logic scoreboard_predicate_raw_hazard /* verilator public_flat */;
    logic scoreboard_predicate_waw_hazard /* verilator public_flat */;

    logic scoreboard_reserve_valid;
    logic scoreboard_release_valid;

    logic scoreboard_release_vector_dst_enable;
    logic scoreboard_release_predicate_dst_enable;

    logic vector_issue_fire;


    logic classifier_tracked_instruction;

    logic classifier_vector_src0_enable;
    logic [5:0] classifier_vector_src0;

    logic classifier_vector_src1_enable;
    logic [5:0] classifier_vector_src1;

    logic classifier_vector_src2_enable;
    logic [5:0] classifier_vector_src2;

    logic classifier_vector_dst_enable;
    logic [5:0] classifier_vector_dst;

    logic classifier_predicate_src_enable;
    logic [3:0] classifier_predicate_src;

    logic classifier_predicate_dst_enable;
    logic [3:0] classifier_predicate_dst;


    logic [VECTOR_REG_COUNT-1:0]
        vector_scoreboard_busy /* verilator public_flat */;

    logic [PREDICATE_REG_COUNT-1:0]
        predicate_scoreboard_busy /* verilator public_flat */;


    logic vector_sequence_opcode;
    logic vector_sequence_pred_enable;
    logic vector_sequence_start;

    logic vector_seq_busy;
    logic vector_seq_done;
    logic vector_seq_beat_valid;

    logic [$clog2(WAVE_SIZE)-1:0]
        vector_seq_beat_index /* verilator public_flat */;

    logic [PHYSICAL_LANES-1:0]
        vector_seq_valid_mask_unused;

    logic [PHYSICAL_LANES-1:0]
        vector_seq_active_mask;

    logic [$clog2(WAVE_SIZE)-1:0]
        vector_seq_logical_lane
        [0:PHYSICAL_LANES-1];


    /*
     * A0-RTL6B live banked-vector operand path.
     *
     * The architectural vector_regs array remains as a verification and
     * legacy-memory shadow during this transition milestone. Sequenced
     * vector ALU/compare source operands come only from the banked VRF.
     */
    localparam integer VECTOR_BEAT_COUNT =
        (WAVE_SIZE + PHYSICAL_LANES - 1) / PHYSICAL_LANES;

    localparam integer VECTOR_BEAT_INDEX_W =
        (VECTOR_BEAT_COUNT <= 1)
        ? 1
        : $clog2(VECTOR_BEAT_COUNT);

    localparam integer VECTOR_BEAT_DATA_W =
        PHYSICAL_LANES * 32;

    logic vector_operand_req_valid;
    logic vector_operand_req_ready;

    logic vector_operand_result_valid;
    logic vector_operand_result_ready;

    logic [VECTOR_BEAT_DATA_W-1:0]
        vector_operand_src0_data;
    logic [VECTOR_BEAT_DATA_W-1:0]
        vector_operand_src1_data;
    logic [VECTOR_BEAT_DATA_W-1:0]
        vector_operand_src2_data_unused;

    logic vector_operand_busy_unused;
    logic vector_operand_bank_conflict_cycle /* verilator public_flat */;

    logic vector_beat_request_sent;
    logic vector_execute_beat_fire;
    logic vector_sequence_advance_enable;

    logic [VECTOR_BEAT_DATA_W-1:0]
        vector_execute_result_data;

    logic vrf_write_valid;
    logic [5:0] vrf_write_reg;
    logic [VECTOR_BEAT_INDEX_W-1:0]
        vrf_write_beat;
    logic [PHYSICAL_LANES-1:0]
        vrf_write_lane_mask;
    logic [VECTOR_BEAT_DATA_W-1:0]
        vrf_write_data;
    logic vrf_write_ready;

    logic vrf_refill_pending;
    logic [5:0] vrf_refill_dst;
    logic [WAVE_SIZE-1:0] vrf_refill_lane_mask;
    logic [VECTOR_BEAT_INDEX_W-1:0]
        vrf_refill_beat;


    localparam integer RECONV_SP_WIDTH =
        $clog2(RECONV_STACK_DEPTH + 1);

    localparam integer RECONV_INDEX_WIDTH =
        $clog2(RECONV_STACK_DEPTH);

    localparam logic [RECONV_SP_WIDTH-1:0]
        RECONV_STACK_DEPTH_COUNT =
            RECONV_SP_WIDTH'(RECONV_STACK_DEPTH);

    logic [RECONV_INDEX_WIDTH-1:0]
        reconv_push_index;

    logic [RECONV_INDEX_WIDTH-1:0]
        reconv_top_index;

    logic [WAVE_SIZE-1:0] reconv_parent_mask
        [0:RECONV_STACK_DEPTH-1];

    logic [WAVE_SIZE-1:0] reconv_else_mask
        [0:RECONV_STACK_DEPTH-1];

    logic reconv_else_entered
        [0:RECONV_STACK_DEPTH-1];

    logic [RECONV_SP_WIDTH-1:0] reconv_sp;

    logic mem_waiting;
    logic mem_pending_load;

    logic [5:0] mem_pending_dst;

    logic [WAVE_SIZE-1:0]
        mem_pending_lane_mask;

    localparam logic signed [63:0]
        GLOBAL_MEMORY_WORDS_LIMIT =
            64'(GLOBAL_MEMORY_WORDS);

    logic [63:0] instruction;

    logic [7:0] opcode;
    logic [3:0] flags;

    logic [5:0] dst_index;
    logic [5:0] src0_index;
    logic [5:0] src1_index;
    logic [5:0] src2_index;

    logic [3:0] pred_index;

    logic signed [31:0] signed_imm24;
    logic signed [31:0] pc_extended;
    logic signed [31:0] branch_target;

    integer lane;
    integer physical_lane;
    integer vector_result_lane;
    integer vrf_write_pack_lane;
    integer vrf_write_logical_index;
    integer reg_index;
    integer predicate_index;
    integer scalar_predicate_index;
    integer reconv_index;

    assign vector_sequence_opcode = (
        opcode == OP_VADD
        || opcode == OP_VSUB
        || opcode == OP_VMUL
        || opcode == OP_VAND
        || opcode == OP_VOR
        || opcode == OP_VXOR
        || opcode == OP_VCMP_EQ
        || opcode == OP_VCMP_LT
        || opcode == OP_VCMP_LE
    );


    /*
     * Current vector ALU instructions use flags[0]
     * for optional vector-predicate masking.
     *
     * Current VCMP semantics use EXEC only.
     */
    /*
     * A0-RTL5C dependency candidate selection.
     */
    assign dependency_opcode = (
        vector_pending_valid
        ? vector_pending_opcode
        : opcode
    );

    assign dependency_flags = (
        vector_pending_valid
        ? vector_pending_flags
        : flags
    );

    assign dependency_dst_index = (
        vector_pending_valid
        ? vector_pending_dst_index
        : dst_index
    );

    assign dependency_src0_index = (
        vector_pending_valid
        ? vector_pending_src0_index
        : src0_index
    );

    assign dependency_src1_index = (
        vector_pending_valid
        ? vector_pending_src1_index
        : src1_index
    );

    assign dependency_src2_index = (
        vector_pending_valid
        ? vector_pending_src2_index
        : src2_index
    );

    assign dependency_pred_index = (
        vector_pending_valid
        ? vector_pending_pred_index
        : pred_index
    );

    assign dependency_pc = (
        vector_pending_valid
        ? vector_pending_pc
        : pc
    );


    assign vector_sequence_pred_enable = (
        vector_waiting
        ? (
            vector_issue_flags[0]
            && (
                vector_issue_opcode == OP_VADD
                || vector_issue_opcode == OP_VSUB
                || vector_issue_opcode == OP_VMUL
                || vector_issue_opcode == OP_VAND
                || vector_issue_opcode == OP_VOR
                || vector_issue_opcode == OP_VXOR
            )
        )
        : (
            flags[0]
            && (
                opcode == OP_VADD
                || opcode == OP_VSUB
                || opcode == OP_VMUL
                || opcode == OP_VAND
                || opcode == OP_VOR
                || opcode == OP_VXOR
            )
        )
    );


    /*
     * Launch only on the first architectural issue
     * cycle of a sequenced vector instruction.
     */
    /*
     * A0-RTL5B Phase 3:
     *
     * A sequenced vector instruction enters dependency
     * classification only when the architectural front end
     * is actually eligible to issue it.
     */
    /*
     * RTL6B refill is an architectural front-end stall, not merely a
     * writeback detail. While a VLOADX destination is being mirrored
     * into the banked VRF, no dependency query or vector issue event may
     * escape. Otherwise the lane sequencer/pending buffer can observe an
     * issue fire that the main core state machine cannot latch because it
     * still owns the refill branch.
     */
    assign scoreboard_query_valid = (
        run_enable
        && !halted
        && !mem_waiting
        && !vrf_refill_pending
        && (
            vector_pending_valid
            || (
                !vector_waiting
                && vector_sequence_opcode
            )
        )
    );


    /*
     * Direct issue is the RTL5B-compatible path.
     */
    assign direct_vector_issue_fire = (
        run_enable
        && !halted
        && !mem_waiting
        && !vrf_refill_pending
        && !vector_waiting
        && !vector_pending_valid
        && vector_sequence_opcode
        && scoreboard_issue_allowed
    );


    /*
     * A hazard-blocked pending instruction issues after
     * the older producer has retired and released its
     * scoreboard ownership.
     */
    assign pending_vector_issue_fire = (
        run_enable
        && !halted
        && !mem_waiting
        && !vrf_refill_pending
        && !vector_waiting
        && vector_pending_valid
        && scoreboard_issue_allowed
    );


    /*
     * Independent pending instructions may hand directly
     * from retirement into the now-idle lane sequencer.
     *
     * RAW/WAW dependencies remain blocked because the
     * producer destination is still busy until this edge.
     */
    assign pending_handoff_fire = (
        run_enable
        && !halted
        && !mem_waiting
        && !vrf_refill_pending
        && vector_waiting
        && vector_seq_done
        && vector_pending_valid
        && scoreboard_issue_allowed
    );


    assign vector_issue_fire = (
        direct_vector_issue_fire
        || pending_vector_issue_fire
        || pending_handoff_fire
    );


    /*
     * Physical sequencing and architectural issue use
     * exactly the same fire event.
     */
    assign vector_sequence_start =
        vector_issue_fire;


    assign scoreboard_reserve_valid =
        vector_issue_fire;


    /*
     * Reservation ownership is released at the same
     * architectural completion point used by RTL5A.
     */
    assign scoreboard_release_valid = (
        run_enable
        && vector_waiting
        && vector_seq_done
    );


    assign scoreboard_release_vector_dst_enable =
        vector_issue_vector_dst_enable;


    assign scoreboard_release_predicate_dst_enable =
        vector_issue_predicate_dst_enable;


    /*
     * One operand-collector request is emitted for each visible physical
     * beat. vector_beat_request_sent prevents the zero-bubble collector
     * handoff contract from accidentally re-accepting the old beat on
     * the same edge that its result is consumed.
     */
    assign vector_operand_req_valid = (
        run_enable
        && vector_waiting
        && vector_seq_beat_valid
        && !vector_beat_request_sent
    );


    assign vector_execute_beat_fire = (
        run_enable
        && vector_waiting
        && vector_seq_beat_valid
        && vector_operand_result_valid
    );


    assign vector_operand_result_ready =
        vector_execute_beat_fire;


    /*
     * Idle cycles remain enabled so a new start may be accepted. While
     * busy, the lane sequencer advances only after the current beat has
     * a complete operand set and is architecturally executed.
     */
    assign vector_sequence_advance_enable = (
        run_enable
        && (
            !vector_seq_busy
            || vector_execute_beat_fire
        )
    );


    /*
     * ALU beat result generated exclusively from the banked VRF operand
     * payload. Inactive physical lanes are harmless because writeback is
     * masked by vector_seq_active_mask.
     */
    always_comb begin
        vector_execute_result_data = '0;

        for (
            vector_result_lane = 0;
            vector_result_lane < PHYSICAL_LANES;
            vector_result_lane = vector_result_lane + 1
        ) begin
            case (vector_issue_opcode)
                OP_VADD: begin
                    vector_execute_result_data[
                        vector_result_lane*32 +: 32
                    ] =
                        vector_operand_src0_data[
                            vector_result_lane*32 +: 32
                        ]
                        +
                        vector_operand_src1_data[
                            vector_result_lane*32 +: 32
                        ];
                end

                OP_VSUB: begin
                    vector_execute_result_data[
                        vector_result_lane*32 +: 32
                    ] =
                        vector_operand_src0_data[
                            vector_result_lane*32 +: 32
                        ]
                        -
                        vector_operand_src1_data[
                            vector_result_lane*32 +: 32
                        ];
                end

                OP_VMUL: begin
                    vector_execute_result_data[
                        vector_result_lane*32 +: 32
                    ] =
                        vector_operand_src0_data[
                            vector_result_lane*32 +: 32
                        ]
                        *
                        vector_operand_src1_data[
                            vector_result_lane*32 +: 32
                        ];
                end

                OP_VAND: begin
                    vector_execute_result_data[
                        vector_result_lane*32 +: 32
                    ] =
                        vector_operand_src0_data[
                            vector_result_lane*32 +: 32
                        ]
                        &
                        vector_operand_src1_data[
                            vector_result_lane*32 +: 32
                        ];
                end

                OP_VOR: begin
                    vector_execute_result_data[
                        vector_result_lane*32 +: 32
                    ] =
                        vector_operand_src0_data[
                            vector_result_lane*32 +: 32
                        ]
                        |
                        vector_operand_src1_data[
                            vector_result_lane*32 +: 32
                        ];
                end

                OP_VXOR: begin
                    vector_execute_result_data[
                        vector_result_lane*32 +: 32
                    ] =
                        vector_operand_src0_data[
                            vector_result_lane*32 +: 32
                        ]
                        ^
                        vector_operand_src1_data[
                            vector_result_lane*32 +: 32
                        ];
                end

                default: begin
                    vector_execute_result_data[
                        vector_result_lane*32 +: 32
                    ] = 32'b0;
                end
            endcase
        end
    end


    /*
     * Single banked-VRF write port arbitration.
     *
     * 1. debug/initialization lane writes while the core is stopped,
     * 2. serialized refill after a VLOADX response,
     * 3. live vector-ALU beat writeback.
     */
    always_comb begin
        vrf_write_valid = 1'b0;
        vrf_write_reg = '0;
        vrf_write_beat = '0;
        vrf_write_lane_mask = '0;
        vrf_write_data = '0;
        vrf_write_logical_index = 0;

        if (!run_enable && vector_we) begin
            vrf_write_valid = 1'b1;
            vrf_write_reg = vector_wreg;
            vrf_write_beat = VECTOR_BEAT_INDEX_W'(
                integer'(vector_wlane) / PHYSICAL_LANES
            );

            vrf_write_lane_mask[
                integer'(vector_wlane) % PHYSICAL_LANES
            ] = 1'b1;

            vrf_write_data[
                (integer'(vector_wlane) % PHYSICAL_LANES)*32
                +: 32
            ] = vector_wdata;

        end else if (vrf_refill_pending) begin
            vrf_write_valid = 1'b1;
            vrf_write_reg = vrf_refill_dst;
            vrf_write_beat = vrf_refill_beat;

            for (
                vrf_write_pack_lane = 0;
                vrf_write_pack_lane < PHYSICAL_LANES;
                vrf_write_pack_lane = vrf_write_pack_lane + 1
            ) begin
                vrf_write_logical_index = (
                    integer'(vrf_refill_beat)
                    * PHYSICAL_LANES
                    + vrf_write_pack_lane
                );

                if (vrf_write_logical_index < WAVE_SIZE) begin
                    vrf_write_lane_mask[vrf_write_pack_lane] =
                        vrf_refill_lane_mask[
                            vrf_write_logical_index
                        ];

                    vrf_write_data[
                        vrf_write_pack_lane*32 +: 32
                    ] = vector_regs[
                        vrf_refill_dst
                    ][
                        vrf_write_logical_index
                    ];
                end
            end

        end else if (
            vector_execute_beat_fire
            && vector_issue_vector_dst_enable
        ) begin
            vrf_write_valid = 1'b1;
            vrf_write_reg = vector_issue_dst_index;
            vrf_write_beat = VECTOR_BEAT_INDEX_W'(
                vector_seq_beat_index
            );
            vrf_write_lane_mask =
                vector_seq_active_mask;
            vrf_write_data =
                vector_execute_result_data;
        end
    end


    function automatic logic signed [63:0]
        indexed_word_address(
            input logic [31:0] scalar_base,
            input logic [31:0] vector_offset,
            input logic signed [31:0] immediate
        );

        logic signed [63:0] base64;
        logic signed [63:0] offset64;
        logic signed [63:0] immediate64;

        begin
            /*
             * Scalar/vector architectural values are
             * unsigned 32-bit quantities.
             *
             * The IMM24 contribution is signed.
             */
            base64 = $signed({
                32'b0,
                scalar_base
            });

            offset64 = $signed({
                32'b0,
                vector_offset
            });

            immediate64 = {
                {32{immediate[31]}},
                immediate
            };

            indexed_word_address =
                base64
                + offset64
                + immediate64;
        end
    endfunction

    always_comb begin
        instruction = program_mem[pc];

        opcode = instruction[63:56];
        flags = instruction[55:52];

        dst_index = instruction[51:46];
        src0_index = instruction[45:40];
        src1_index = instruction[39:34];
        src2_index = instruction[33:28];

        pred_index = instruction[27:24];

        signed_imm24 = {
            {8{instruction[23]}},
            instruction[23:0]
        };

        /*
         * Python golden semantics increment PC
         * before executing JMP/BRA.
         *
         * Therefore:
         *
         * target = current_pc + 1 + signed_imm24
         */
        /*
         * Keep PC arithmetic explicitly 32-bit.
         */
        pc_extended = $signed({
            {(32 - $bits(pc)){1'b0}},
            pc
        });

        branch_target =
            pc_extended
            + 32'sd1
            + signed_imm24;

        /*
         * reconv_sp is a depth/count and can
         * represent RECONV_STACK_DEPTH itself.
         *
         * Array indices need only the actual
         * stack-index width.
         */
        reconv_push_index =
            reconv_sp[
                RECONV_INDEX_WIDTH-1:0
            ];

        reconv_top_index =
            reconv_sp[
                RECONV_INDEX_WIDTH-1:0
            ] - 1'b1;
    end

    /*
     * A0-RTL5B instruction dependency classifier.
     *
     * Phase 3 connects the classifier to the live
     * sequenced-vector issue path.
     *
     * VLOADX/VSTOREX/SPLIT classification exists in the
     * standalone classifier but their live core reservation
     * paths remain outside this phase.
     */
    a0_dependency_classifier
        vector_dependency_classifier (
            .instruction_valid(
                scoreboard_query_valid
            ),

            .opcode(dependency_opcode),
            .flags(dependency_flags),

            .dst_index(dependency_dst_index),
            .src0_index(dependency_src0_index),
            .src1_index(dependency_src1_index),
            .src2_index(dependency_src2_index),

            .pred_index(dependency_pred_index),

            .tracked_instruction(
                classifier_tracked_instruction
            ),

            .vector_src0_enable(
                classifier_vector_src0_enable
            ),
            .vector_src0(
                classifier_vector_src0
            ),

            .vector_src1_enable(
                classifier_vector_src1_enable
            ),
            .vector_src1(
                classifier_vector_src1
            ),

            .vector_src2_enable(
                classifier_vector_src2_enable
            ),
            .vector_src2(
                classifier_vector_src2
            ),

            .vector_dst_enable(
                classifier_vector_dst_enable
            ),
            .vector_dst(
                classifier_vector_dst
            ),

            .predicate_src_enable(
                classifier_predicate_src_enable
            ),
            .predicate_src(
                classifier_predicate_src
            ),

            .predicate_dst_enable(
                classifier_predicate_dst_enable
            ),
            .predicate_dst(
                classifier_predicate_dst
            )
        );


    /*
     * A0-RTL5B live vector/predicate scoreboard.
     */
    a0_scoreboard #(
        .VECTOR_REG_COUNT(
            VECTOR_REG_COUNT
        ),
        .PREDICATE_REG_COUNT(
            PREDICATE_REG_COUNT
        )
    ) vector_scoreboard (
        .clk(clk),
        .rst_n(rst_n),

        .query_valid(
            classifier_tracked_instruction
        ),

        .query_vector_src0_enable(
            classifier_vector_src0_enable
        ),
        .query_vector_src0(
            classifier_vector_src0
        ),

        .query_vector_src1_enable(
            classifier_vector_src1_enable
        ),
        .query_vector_src1(
            classifier_vector_src1
        ),

        .query_vector_src2_enable(
            classifier_vector_src2_enable
        ),
        .query_vector_src2(
            classifier_vector_src2
        ),

        .query_vector_dst_enable(
            classifier_vector_dst_enable
        ),
        .query_vector_dst(
            classifier_vector_dst
        ),

        .query_predicate_src_enable(
            classifier_predicate_src_enable
        ),
        .query_predicate_src(
            classifier_predicate_src
        ),

        .query_predicate_dst_enable(
            classifier_predicate_dst_enable
        ),
        .query_predicate_dst(
            classifier_predicate_dst
        ),

        .reserve_valid(
            scoreboard_reserve_valid
        ),

        .reserve_vector_dst_enable(
            classifier_vector_dst_enable
        ),
        .reserve_vector_dst(
            classifier_vector_dst
        ),

        .reserve_predicate_dst_enable(
            classifier_predicate_dst_enable
        ),
        .reserve_predicate_dst(
            classifier_predicate_dst
        ),

        .release_valid(
            scoreboard_release_valid
        ),

        .release_vector_dst_enable(
            scoreboard_release_vector_dst_enable
        ),
        .release_vector_dst(
            vector_issue_dst_index
        ),

        .release_predicate_dst_enable(
            scoreboard_release_predicate_dst_enable
        ),
        .release_predicate_dst(
            vector_issue_pred_index
        ),

        .vector_raw_hazard(
            scoreboard_vector_raw_hazard
        ),

        .vector_waw_hazard(
            scoreboard_vector_waw_hazard
        ),

        .predicate_raw_hazard(
            scoreboard_predicate_raw_hazard
        ),

        .predicate_waw_hazard(
            scoreboard_predicate_waw_hazard
        ),

        .any_hazard(
            scoreboard_any_hazard_unused
        ),

        .issue_allowed(
            scoreboard_issue_allowed
        ),

        .vector_busy(
            vector_scoreboard_busy
        ),

        .predicate_busy(
            predicate_scoreboard_busy
        )
    );


    /*
     * A0-RTL5C bounded sequential vector prefetch.
     *
     * Prefetch never reads beyond PROGRAM_WORDS and does
     * not define a new PC wrap policy.
     */
    always_comb begin

        vector_prefetch_valid = 1'b0;

        vector_prefetch_pc = '0;
        vector_prefetch_pc_extended = (
            32'(dependency_pc)
            + 32'd1
        );

        vector_prefetch_instruction_with_unused_imm = '0;

        vector_prefetch_opcode = '0;
        vector_prefetch_flags = '0;

        vector_prefetch_dst_index = '0;
        vector_prefetch_src0_index = '0;
        vector_prefetch_src1_index = '0;
        vector_prefetch_src2_index = '0;

        vector_prefetch_pred_index = '0;


        if (
            vector_issue_fire
            && vector_prefetch_pc_extended
                < PROGRAM_WORDS_LIMIT
        ) begin

            vector_prefetch_pc =
                vector_prefetch_pc_extended[
                    $clog2(PROGRAM_WORDS)-1:0
                ];

            vector_prefetch_instruction_with_unused_imm =
                program_mem[
                    vector_prefetch_pc_extended[
                        $clog2(PROGRAM_WORDS)-1:0
                    ]
                ];


            vector_prefetch_opcode =
                vector_prefetch_instruction_with_unused_imm[63:56];

            vector_prefetch_flags =
                vector_prefetch_instruction_with_unused_imm[55:52];

            vector_prefetch_dst_index =
                vector_prefetch_instruction_with_unused_imm[51:46];

            vector_prefetch_src0_index =
                vector_prefetch_instruction_with_unused_imm[45:40];

            vector_prefetch_src1_index =
                vector_prefetch_instruction_with_unused_imm[39:34];

            vector_prefetch_src2_index =
                vector_prefetch_instruction_with_unused_imm[33:28];

            vector_prefetch_pred_index =
                vector_prefetch_instruction_with_unused_imm[27:24];


            vector_prefetch_valid = (
                vector_prefetch_opcode == OP_VADD
                || vector_prefetch_opcode == OP_VSUB
                || vector_prefetch_opcode == OP_VMUL
                || vector_prefetch_opcode == OP_VAND
                || vector_prefetch_opcode == OP_VOR
                || vector_prefetch_opcode == OP_VXOR
                || vector_prefetch_opcode == OP_VCMP_EQ
                || vector_prefetch_opcode == OP_VCMP_LT
                || vector_prefetch_opcode == OP_VCMP_LE
            );
        end
    end


    /*
     * Pending instruction ownership is independent of
     * live program-memory decode.
     *
     * Every successful vector issue consumes the current
     * candidate and replaces the one-entry queue with its
     * immediate sequential vector successor, if present.
     */
    always_ff @(posedge clk) begin

        if (!rst_n) begin

            vector_pending_valid <= 1'b0;

            vector_pending_opcode <= '0;
            vector_pending_flags <= '0;

            vector_pending_dst_index <= '0;
            vector_pending_src0_index <= '0;
            vector_pending_src1_index <= '0;
            vector_pending_src2_index <= '0;

            vector_pending_pred_index <= '0;
            vector_pending_pc <= '0;

        end else if (run_enable) begin

            if (vector_issue_fire) begin

                vector_pending_valid <=
                    vector_prefetch_valid;

                if (vector_prefetch_valid) begin

                    vector_pending_opcode <=
                        vector_prefetch_opcode;

                    vector_pending_flags <=
                        vector_prefetch_flags;

                    vector_pending_dst_index <=
                        vector_prefetch_dst_index;

                    vector_pending_src0_index <=
                        vector_prefetch_src0_index;

                    vector_pending_src1_index <=
                        vector_prefetch_src1_index;

                    vector_pending_src2_index <=
                        vector_prefetch_src2_index;

                    vector_pending_pred_index <=
                        vector_prefetch_pred_index;

                    vector_pending_pc <=
                        vector_prefetch_pc;
                end
            end
        end
    end


    /*
     * A0-RTL6B banked VRF + operand collector.
     *
     * Sequenced vector execution consumes this path live. The shadow
     * vector_regs array is no longer a source for ALU/VCMP operations.
     */
    a0_vector_operand_path #(
        .VECTOR_REG_COUNT(VECTOR_REG_COUNT),
        .WAVE_SIZE(WAVE_SIZE),
        .PHYSICAL_LANES(PHYSICAL_LANES),
        .BANK_COUNT(4),
        .REG_INDEX_W($clog2(VECTOR_REG_COUNT)),
        .BEAT_COUNT(VECTOR_BEAT_COUNT),
        .BEAT_INDEX_W(VECTOR_BEAT_INDEX_W)
    ) vector_operand_path (
        .clk(clk),
        .rst_n(rst_n),

        .req_valid(vector_operand_req_valid),
        .req_ready(vector_operand_req_ready),

        .req_src0_enable(vector_issue_src0_enable),
        .req_src1_enable(vector_issue_src1_enable),
        .req_src2_enable(vector_issue_src2_enable),

        .req_src0(vector_issue_src0_index),
        .req_src1(vector_issue_src1_index),
        .req_src2(vector_issue_src2_index),
        .req_beat(VECTOR_BEAT_INDEX_W'(vector_seq_beat_index)),

        .result_valid(vector_operand_result_valid),
        .result_ready(vector_operand_result_ready),

        .result_src0_data(vector_operand_src0_data),
        .result_src1_data(vector_operand_src1_data),
        .result_src2_data(vector_operand_src2_data_unused),

        .busy(vector_operand_busy_unused),
        .bank_conflict_cycle(vector_operand_bank_conflict_cycle),

        .write_valid(vrf_write_valid),
        .write_reg(vrf_write_reg),
        .write_beat(vrf_write_beat),
        .write_lane_mask(vrf_write_lane_mask),
        .write_data(vrf_write_data),
        .write_ready(vrf_write_ready)
    );


    a0_lane_sequencer #(
        .WAVE_SIZE(
            WAVE_SIZE
        ),
        .PHYSICAL_LANES(
            PHYSICAL_LANES
        )
    ) vector_lane_sequencer (
        .clk(clk),
        .rst_n(rst_n),

        .advance_enable(
            vector_sequence_advance_enable
        ),

        .start(
            vector_sequence_start
        ),

        .exec_mask(
            exec_mask
        ),

        .pred_enable(
            vector_sequence_pred_enable
        ),

        .pred_mask(
            predicate_regs[
                vector_waiting
                ? vector_issue_pred_index
                : pred_index
            ]
        ),

        .busy(
            vector_seq_busy
        ),

        .done(
            vector_seq_done
        ),

        .beat_valid(
            vector_seq_beat_valid
        ),

        .beat_index(
            vector_seq_beat_index
        ),

        .physical_valid_mask(
            vector_seq_valid_mask_unused
        ),

        .physical_active_mask(
            vector_seq_active_mask
        ),

        .logical_lane(
            vector_seq_logical_lane
        )
    );


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc <= '0;

            halted <= 1'b0;
            faulted <= 1'b0;

            mem_req_valid <= 1'b0;
            mem_req_write <= 1'b0;
            mem_req_lane_mask <= '0;

            mem_waiting <= 1'b0;
            mem_pending_load <= 1'b0;
            mem_pending_dst <= '0;
            mem_pending_lane_mask <= '0;


            vector_waiting <= 1'b0;

            vector_issue_opcode <= '0;
            vector_issue_flags <= '0;

            vector_issue_dst_index <= '0;
            vector_issue_src0_index <= '0;
            vector_issue_src1_index <= '0;
            vector_issue_src2_index <= '0;

            vector_issue_pred_index <= '0;

            vector_issue_src0_enable <= 1'b0;
            vector_issue_src1_enable <= 1'b0;
            vector_issue_src2_enable <= 1'b0;
            vector_issue_vector_dst_enable <= 1'b0;
            vector_issue_predicate_dst_enable <= 1'b0;

            vector_issue_pc <= '0;

            vector_beat_request_sent <= 1'b0;

            vrf_refill_pending <= 1'b0;
            vrf_refill_dst <= '0;
            vrf_refill_lane_mask <= '0;
            vrf_refill_beat <= '0;

            exec_mask <= {WAVE_SIZE{1'b1}};
            reconv_sp <= '0;

            for (
                lane = 0;
                lane < WAVE_SIZE;
                lane = lane + 1
            ) begin
                mem_req_addr[lane] <= 32'b0;
                mem_req_wdata[lane] <= 32'b0;
            end

            for (
                reg_index = 0;
                reg_index < VECTOR_REG_COUNT;
                reg_index = reg_index + 1
            ) begin
                for (
                    lane = 0;
                    lane < WAVE_SIZE;
                    lane = lane + 1
                ) begin
                    vector_regs[
                        reg_index
                    ][lane] <= 32'b0;
                end
            end

            for (
                reg_index = 0;
                reg_index < SCALAR_REG_COUNT;
                reg_index = reg_index + 1
            ) begin
                scalar_regs[
                    reg_index
                ] <= 32'b0;
            end

            for (
                predicate_index = 0;
                predicate_index
                    < PREDICATE_REG_COUNT;
                predicate_index =
                    predicate_index + 1
            ) begin
                predicate_regs[
                    predicate_index
                ] <= '0;
            end

            for (
                scalar_predicate_index = 0;
                scalar_predicate_index
                    < SCALAR_PREDICATE_REG_COUNT;
                scalar_predicate_index =
                    scalar_predicate_index + 1
            ) begin
                scalar_predicate_regs[
                    scalar_predicate_index
                ] <= 1'b0;
            end

            for (
                reconv_index = 0;
                reconv_index < RECONV_STACK_DEPTH;
                reconv_index = reconv_index + 1
            ) begin
                reconv_parent_mask[
                    reconv_index
                ] <= '0;

                reconv_else_mask[
                    reconv_index
                ] <= '0;

                reconv_else_entered[
                    reconv_index
                ] <= 1'b0;
            end

        end else if (!run_enable) begin

            mem_req_valid <= 1'b0;

            if (program_we) begin
                program_mem[
                    program_waddr
                ] <= program_wdata;
            end

            if (vector_we) begin
                vector_regs[
                    vector_wreg
                ][vector_wlane] <= vector_wdata;
            end

            if (scalar_we) begin
                scalar_regs[
                    scalar_wreg
                ] <= scalar_wdata;
            end

        end else if (mem_waiting) begin

            /*
             * Request-valid is a one-cycle launch pulse.
             * Architectural execution remains stalled
             * until the response arrives.
             */
            mem_req_valid <= 1'b0;

            if (mem_resp_valid) begin
                if (mem_resp_fault) begin
                    faulted <= 1'b1;
                    halted <= 1'b1;

                end else if (mem_pending_load) begin
                    for (
                        lane = 0;
                        lane < WAVE_SIZE;
                        lane = lane + 1
                    ) begin
                        if (
                            mem_pending_lane_mask[lane]
                        ) begin
                            vector_regs[
                                mem_pending_dst
                            ][lane] <=
                                mem_resp_rdata[lane];
                        end
                    end

                    /*
                     * The architectural shadow receives the response on
                     * this edge. RTL6B then serializes the same vector into
                     * the 1-write-port banked VRF before allowing the next
                     * instruction to issue.
                     */
                    vrf_refill_pending <= 1'b1;
                    vrf_refill_dst <= mem_pending_dst;
                    vrf_refill_lane_mask <=
                        mem_pending_lane_mask;
                    vrf_refill_beat <= '0;
                end

                mem_waiting <= 1'b0;
                mem_pending_load <= 1'b0;
                mem_pending_lane_mask <= '0;
            end

        end else if (vrf_refill_pending) begin

            /*
             * VLOADX -> banked-VRF coherence bridge. One physical beat is
             * written per cycle; architectural issue remains stalled until
             * every beat of the loaded destination has been mirrored.
             */
            mem_req_valid <= 1'b0;

            if (vrf_write_ready) begin
                if (
                    integer'(vrf_refill_beat)
                    == VECTOR_BEAT_COUNT - 1
                ) begin
                    vrf_refill_pending <= 1'b0;
                    vrf_refill_beat <= '0;
                end else begin
                    vrf_refill_beat <=
                        vrf_refill_beat + 1'b1;
                end
            end

        end else if (vector_waiting) begin

            /*
             * A0-RTL5A vector execution stage.
             *
             * Instruction identity is owned by the issue
             * latch, not the live program-memory decode.
             */
            mem_req_valid <= 1'b0;

            pc <= vector_issue_pc;

            if (
                vector_operand_req_valid
                && vector_operand_req_ready
            ) begin
                vector_beat_request_sent <= 1'b1;
            end

            if (vector_seq_beat_valid) begin

                if (vector_execute_beat_fire) begin

                    /*
                     * The collector result consumed on this edge belongs
                     * to the current lane-sequencer beat. Clear the sent
                     * flag so the next visible beat may request operands.
                     */
                    vector_beat_request_sent <= 1'b0;

                    for (
                        physical_lane = 0;
                        physical_lane < PHYSICAL_LANES;
                        physical_lane = physical_lane + 1
                    ) begin

                        if (
                            vector_seq_active_mask[
                                physical_lane
                            ]
                        ) begin

                            if (
                                vector_issue_vector_dst_enable
                            ) begin
                                vector_regs[
                                    vector_issue_dst_index
                                ][
                                    vector_seq_logical_lane[
                                        physical_lane
                                    ]
                                ] <=
                                    vector_execute_result_data[
                                        physical_lane*32 +: 32
                                    ];
                            end

                            if (
                                vector_issue_predicate_dst_enable
                            ) begin
                                case (vector_issue_opcode)
                                    OP_VCMP_EQ: begin
                                        predicate_regs[
                                            vector_issue_pred_index
                                        ][
                                            vector_seq_logical_lane[
                                                physical_lane
                                            ]
                                        ] <= (
                                            vector_operand_src0_data[
                                                physical_lane*32 +: 32
                                            ]
                                            ==
                                            vector_operand_src1_data[
                                                physical_lane*32 +: 32
                                            ]
                                        );
                                    end

                                    OP_VCMP_LT: begin
                                        predicate_regs[
                                            vector_issue_pred_index
                                        ][
                                            vector_seq_logical_lane[
                                                physical_lane
                                            ]
                                        ] <= (
                                            vector_operand_src0_data[
                                                physical_lane*32 +: 32
                                            ]
                                            <
                                            vector_operand_src1_data[
                                                physical_lane*32 +: 32
                                            ]
                                        );
                                    end

                                    OP_VCMP_LE: begin
                                        predicate_regs[
                                            vector_issue_pred_index
                                        ][
                                            vector_seq_logical_lane[
                                                physical_lane
                                            ]
                                        ] <= (
                                            vector_operand_src0_data[
                                                physical_lane*32 +: 32
                                            ]
                                            <=
                                            vector_operand_src1_data[
                                                physical_lane*32 +: 32
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

            end else if (vector_seq_done) begin

                vector_beat_request_sent <= 1'b0;

                /*
                 * A0-RTL5C retirement-time handoff.
                 *
                 * Independent pending instructions may
                 * immediately take execution ownership.
                 *
                 * A dependency hazard blocks this path;
                 * the producer retires normally and its
                 * reservation is released on this edge.
                 */
                if (pending_handoff_fire) begin

                    vector_waiting <= 1'b1;

                    vector_issue_opcode <=
                        vector_pending_opcode;

                    vector_issue_flags <=
                        vector_pending_flags;

                    vector_issue_dst_index <=
                        vector_pending_dst_index;

                    vector_issue_src0_index <=
                        vector_pending_src0_index;

                    vector_issue_src1_index <=
                        vector_pending_src1_index;

                    vector_issue_src2_index <=
                        vector_pending_src2_index;

                    vector_issue_pred_index <=
                        vector_pending_pred_index;

                    vector_issue_src0_enable <=
                        classifier_vector_src0_enable;
                    vector_issue_src1_enable <=
                        classifier_vector_src1_enable;
                    vector_issue_src2_enable <=
                        classifier_vector_src2_enable;
                    vector_issue_vector_dst_enable <=
                        classifier_vector_dst_enable;
                    vector_issue_predicate_dst_enable <=
                        classifier_predicate_dst_enable;

                    vector_issue_pc <=
                        vector_pending_pc;

                    vector_beat_request_sent <= 1'b0;

                    pc <= vector_pending_pc;

                end else begin

                    vector_waiting <= 1'b0;

                    pc <=
                        vector_issue_pc
                        + 1'b1;
                end
            end


        /*
         * A hazard-blocked pending instruction remains
         * architectural owner of the current PC after
         * the older vector instruction retires.
         */
        end else if (vector_pending_valid) begin

            mem_req_valid <= 1'b0;

            pc <= vector_pending_pc;


            if (pending_vector_issue_fire) begin

                vector_waiting <= 1'b1;

                vector_issue_opcode <=
                    vector_pending_opcode;

                vector_issue_flags <=
                    vector_pending_flags;

                vector_issue_dst_index <=
                    vector_pending_dst_index;

                vector_issue_src0_index <=
                    vector_pending_src0_index;

                vector_issue_src1_index <=
                    vector_pending_src1_index;

                vector_issue_src2_index <=
                    vector_pending_src2_index;

                vector_issue_pred_index <=
                    vector_pending_pred_index;

                vector_issue_src0_enable <=
                    classifier_vector_src0_enable;
                vector_issue_src1_enable <=
                    classifier_vector_src1_enable;
                vector_issue_src2_enable <=
                    classifier_vector_src2_enable;
                vector_issue_vector_dst_enable <=
                    classifier_vector_dst_enable;
                vector_issue_predicate_dst_enable <=
                    classifier_predicate_dst_enable;

                vector_issue_pc <=
                    vector_pending_pc;

                vector_beat_request_sent <= 1'b0;

                pc <= vector_pending_pc;
            end

        end else if (!halted) begin

            mem_req_valid <= 1'b0;

            /*
             * A0 architectural execution currently
             * advances PC before instruction effects.
             *
             * Branching is intentionally outside RTL0.
             */
            pc <= pc + 1'b1;

            case (opcode)

                OP_VADD,
                OP_VSUB,
                OP_VMUL,
                OP_VAND,
                OP_VOR,
                OP_VXOR: begin

                    /*
                     * A0-RTL5B scoreboard-qualified
                     * vector ALU issue.
                     */
                    if (vector_issue_fire) begin

                        vector_waiting <= 1'b1;

                        vector_issue_opcode <= opcode;
                        vector_issue_flags <= flags;

                        vector_issue_dst_index <= dst_index;
                        vector_issue_src0_index <= src0_index;
                        vector_issue_src1_index <= src1_index;
                        vector_issue_src2_index <= src2_index;

                        vector_issue_pred_index <= pred_index;

                        vector_issue_src0_enable <=
                            classifier_vector_src0_enable;
                        vector_issue_src1_enable <=
                            classifier_vector_src1_enable;
                        vector_issue_src2_enable <=
                            classifier_vector_src2_enable;
                        vector_issue_vector_dst_enable <=
                            classifier_vector_dst_enable;
                        vector_issue_predicate_dst_enable <=
                            classifier_predicate_dst_enable;

                        vector_issue_pc <= pc;
                        vector_beat_request_sent <= 1'b0;

                        /*
                         * Issue does not retire the
                         * instruction.
                         */
                        pc <= pc;

                    end else begin

                        /*
                         * Dependency hazard or failed
                         * classification stalls the
                         * architectural front end.
                         */
                        pc <= pc;
                    end
                end


                OP_SADD: begin
                    scalar_regs[
                        dst_index[4:0]
                    ] <=
                        scalar_regs[
                            src0_index[4:0]
                        ]
                        +
                        scalar_regs[
                            src1_index[4:0]
                        ];
                end

                OP_SSUB: begin
                    scalar_regs[
                        dst_index[4:0]
                    ] <=
                        scalar_regs[
                            src0_index[4:0]
                        ]
                        -
                        scalar_regs[
                            src1_index[4:0]
                        ];
                end

                OP_VCMP_EQ,
                OP_VCMP_LT,
                OP_VCMP_LE: begin

                    /*
                     * A0-RTL5B scoreboard-qualified
                     * vector compare issue.
                     */
                    if (vector_issue_fire) begin

                        vector_waiting <= 1'b1;

                        vector_issue_opcode <= opcode;
                        vector_issue_flags <= flags;

                        vector_issue_dst_index <= dst_index;
                        vector_issue_src0_index <= src0_index;
                        vector_issue_src1_index <= src1_index;
                        vector_issue_src2_index <= src2_index;

                        vector_issue_pred_index <= pred_index;

                        vector_issue_src0_enable <=
                            classifier_vector_src0_enable;
                        vector_issue_src1_enable <=
                            classifier_vector_src1_enable;
                        vector_issue_src2_enable <=
                            classifier_vector_src2_enable;
                        vector_issue_vector_dst_enable <=
                            classifier_vector_dst_enable;
                        vector_issue_predicate_dst_enable <=
                            classifier_predicate_dst_enable;

                        vector_issue_pc <= pc;
                        vector_beat_request_sent <= 1'b0;

                        /*
                         * Issue does not retire the
                         * instruction.
                         */
                        pc <= pc;

                    end else begin

                        /*
                         * Dependency hazard or failed
                         * classification stalls the
                         * architectural front end.
                         */
                        pc <= pc;
                    end
                end


                OP_VLOADX: begin : rtl2_vloadx

                    logic [WAVE_SIZE-1:0]
                        active_mask;

                    logic address_fault;

                    logic signed [63:0]
                        lane_address;

                    active_mask = '0;
                    address_fault = 1'b0;

                    /*
                     * Validate every active lane before
                     * launching any request.
                     *
                     * This preserves fail-before-access
                     * behavior of the golden model.
                     */
                    for (
                        lane = 0;
                        lane < WAVE_SIZE;
                        lane = lane + 1
                    ) begin
                        if (
                            exec_mask[lane]
                            && (
                                !flags[0]
                                || predicate_regs[
                                    pred_index
                                ][lane]
                            )
                        ) begin
                            active_mask[lane] = 1'b1;

                            lane_address =
                                indexed_word_address(
                                    scalar_regs[
                                        src0_index[4:0]
                                    ],
                                    vector_regs[
                                        src1_index
                                    ][lane],
                                    signed_imm24
                                );

                            if (
                                lane_address < 0
                                || lane_address
                                    >=
                                    GLOBAL_MEMORY_WORDS_LIMIT
                            ) begin
                                address_fault = 1'b1;
                            end
                        end
                    end

                    if (address_fault) begin
                        faulted <= 1'b1;
                        halted <= 1'b1;

                    end else if (active_mask != '0) begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b0;

                        mem_req_lane_mask <=
                            active_mask;

                        mem_pending_lane_mask <=
                            active_mask;

                        mem_pending_load <= 1'b1;
                        mem_pending_dst <= dst_index;

                        for (
                            lane = 0;
                            lane < WAVE_SIZE;
                            lane = lane + 1
                        ) begin
                            if (active_mask[lane]) begin
                                lane_address =
                                    indexed_word_address(
                                        scalar_regs[
                                            src0_index[4:0]
                                        ],
                                        vector_regs[
                                            src1_index
                                        ][lane],
                                        signed_imm24
                                    );

                                mem_req_addr[lane] <=
                                    lane_address[31:0];
                            end else begin
                                mem_req_addr[lane] <= 0;
                            end

                            mem_req_wdata[lane] <= 0;
                        end

                        mem_waiting <= 1'b1;
                    end
                end

                OP_VSTOREX: begin : rtl2_vstorex

                    logic [WAVE_SIZE-1:0]
                        active_mask;

                    logic address_fault;

                    logic signed [63:0]
                        lane_address;

                    active_mask = '0;
                    address_fault = 1'b0;

                    for (
                        lane = 0;
                        lane < WAVE_SIZE;
                        lane = lane + 1
                    ) begin
                        if (
                            exec_mask[lane]
                            && (
                                !flags[0]
                                || predicate_regs[
                                    pred_index
                                ][lane]
                            )
                        ) begin
                            active_mask[lane] = 1'b1;

                            lane_address =
                                indexed_word_address(
                                    scalar_regs[
                                        src0_index[4:0]
                                    ],
                                    vector_regs[
                                        src1_index
                                    ][lane],
                                    signed_imm24
                                );

                            if (
                                lane_address < 0
                                || lane_address
                                    >=
                                    GLOBAL_MEMORY_WORDS_LIMIT
                            ) begin
                                address_fault = 1'b1;
                            end
                        end
                    end

                    if (address_fault) begin
                        faulted <= 1'b1;
                        halted <= 1'b1;

                    end else if (active_mask != '0) begin
                        mem_req_valid <= 1'b1;
                        mem_req_write <= 1'b1;

                        mem_req_lane_mask <=
                            active_mask;

                        mem_pending_lane_mask <=
                            active_mask;

                        mem_pending_load <= 1'b0;
                        mem_pending_dst <= '0;

                        for (
                            lane = 0;
                            lane < WAVE_SIZE;
                            lane = lane + 1
                        ) begin
                            if (active_mask[lane]) begin
                                lane_address =
                                    indexed_word_address(
                                        scalar_regs[
                                            src0_index[4:0]
                                        ],
                                        vector_regs[
                                            src1_index
                                        ][lane],
                                        signed_imm24
                                    );

                                mem_req_addr[lane] <=
                                    lane_address[31:0];

                                mem_req_wdata[lane] <=
                                    vector_regs[
                                        src2_index
                                    ][lane];

                            end else begin
                                mem_req_addr[lane] <= 0;
                                mem_req_wdata[lane] <= 0;
                            end
                        end

                        mem_waiting <= 1'b1;
                    end
                end

                OP_SCMP_LT: begin
                    scalar_predicate_regs[
                        pred_index
                    ] <= (
                        scalar_regs[
                            src0_index[4:0]
                        ]
                        <
                        scalar_regs[
                            src1_index[4:0]
                        ]
                    );
                end

                OP_JMP: begin
                    if (
                        branch_target < 0
                        || branch_target >= PROGRAM_WORDS
                    ) begin
                        faulted <= 1'b1;
                        halted <= 1'b1;
                    end else begin
                        pc <= branch_target[
                            $clog2(PROGRAM_WORDS)-1:0
                        ];
                    end
                end

                OP_BRA: begin
                    if (
                        scalar_predicate_regs[
                            pred_index
                        ]
                    ) begin
                        if (
                            branch_target < 0
                            || branch_target >= PROGRAM_WORDS
                        ) begin
                            faulted <= 1'b1;
                            halted <= 1'b1;
                        end else begin
                            pc <= branch_target[
                                $clog2(PROGRAM_WORDS)-1:0
                            ];
                        end
                    end
                end

                OP_SPLIT: begin
                    if (
                        reconv_sp
                        >= RECONV_STACK_DEPTH_COUNT
                    ) begin
                        faulted <= 1'b1;
                        halted <= 1'b1;
                    end else begin
                        reconv_parent_mask[
                            reconv_push_index
                        ] <= exec_mask;

                        reconv_else_mask[
                            reconv_push_index
                        ] <= (
                            exec_mask
                            & ~predicate_regs[
                                pred_index
                            ]
                        );

                        reconv_else_entered[
                            reconv_push_index
                        ] <= 1'b0;

                        exec_mask <= (
                            exec_mask
                            & predicate_regs[
                                pred_index
                            ]
                        );

                        reconv_sp <= (
                            reconv_sp + 1'b1
                        );
                    end
                end

                OP_ELSE: begin
                    if (reconv_sp == 0) begin
                        faulted <= 1'b1;
                        halted <= 1'b1;
                    end else if (
                        reconv_else_entered[
                            reconv_top_index
                        ]
                    ) begin
                        faulted <= 1'b1;
                        halted <= 1'b1;
                    end else begin
                        exec_mask <=
                            reconv_else_mask[
                                reconv_top_index
                            ];

                        reconv_else_entered[
                            reconv_top_index
                        ] <= 1'b1;
                    end
                end

                OP_JOIN: begin
                    if (reconv_sp == 0) begin
                        faulted <= 1'b1;
                        halted <= 1'b1;
                    end else begin
                        exec_mask <=
                            reconv_parent_mask[
                                reconv_top_index
                            ];

                        reconv_sp <= (
                            reconv_sp - 1'b1
                        );
                    end
                end

                OP_HALT: begin
                    halted <= 1'b1;
                end

                default: begin
                    /*
                     * RTL0 fails closed on instructions
                     * outside its supported subset.
                     */
                    faulted <= 1'b1;
                    halted <= 1'b1;
                end

            endcase
        end
    end

endmodule
