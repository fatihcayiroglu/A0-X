module a0_issue_queue #(
    parameter integer DEPTH = 8
) (
    input logic clk,
    input logic rst,

    /*
     * Dispatch payload.
     *
     * Dependency semantics are classified before insertion.  The queue stores
     * the enable-qualified contract instead of re-decoding opcode semantics.
     */
    input logic        dispatch_valid,
    input logic [31:0] dispatch_pc,

    input logic [7:0] dispatch_opcode,
    input logic [3:0] dispatch_flags,

    input logic [5:0] dispatch_dst,
    input logic [5:0] dispatch_src0,
    input logic [5:0] dispatch_src1,
    input logic [5:0] dispatch_src2,

    input logic [3:0] dispatch_pred,

    input logic dispatch_vector_src0_enable,
    input logic dispatch_vector_src1_enable,
    input logic dispatch_vector_src2_enable,
    input logic dispatch_vector_dst_enable,
    input logic dispatch_predicate_src_enable,
    input logic dispatch_predicate_dst_enable,

    output logic dispatch_ready,

    /*
     * Issue payload.
     */
    output logic        issue_valid,
    output logic [31:0] issue_pc,

    output logic [7:0] issue_opcode,
    output logic [3:0] issue_flags,

    output logic [5:0] issue_dst,
    output logic [5:0] issue_src0,
    output logic [5:0] issue_src1,
    output logic [5:0] issue_src2,

    output logic [3:0] issue_pred,

    output logic issue_vector_src0_enable,
    output logic issue_vector_src1_enable,
    output logic issue_vector_src2_enable,
    output logic issue_vector_dst_enable,
    output logic issue_predicate_src_enable,
    output logic issue_predicate_dst_enable,

    input logic issue_ready,

    /*
     * Busy-state snapshots from the owning scoreboard.
     *
     * The queue does not own dependency state.  It only applies the
     * enable-qualified dependency contract stored with each entry.
     */
    input logic [63:0] busy_vector_regs,
    input logic [15:0] busy_predicate_regs
);

    localparam integer INDEX_W =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    localparam integer AGE_W =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH);

    localparam integer COUNT_W =
        (DEPTH <= 1) ? 1 : $clog2(DEPTH + 1);

    /*
     * Queue storage.
     */
    logic [31:0] pc_q [0:DEPTH-1];

    logic [7:0] opcode_q [0:DEPTH-1];
    logic [3:0] flags_q [0:DEPTH-1];

    logic [5:0] dst_q [0:DEPTH-1];
    logic [5:0] src0_q [0:DEPTH-1];
    logic [5:0] src1_q [0:DEPTH-1];
    logic [5:0] src2_q [0:DEPTH-1];

    logic [3:0] pred_q [0:DEPTH-1];

    logic vector_src0_enable_q [0:DEPTH-1];
    logic vector_src1_enable_q [0:DEPTH-1];
    logic vector_src2_enable_q [0:DEPTH-1];
    logic vector_dst_enable_q [0:DEPTH-1];
    logic predicate_src_enable_q [0:DEPTH-1];
    logic predicate_dst_enable_q [0:DEPTH-1];

    logic valid_q [0:DEPTH-1];

    /*
     * Compact local age ranks.
     *
     * age_q == 0 is the oldest resident instruction.  When an entry issues,
     * younger ranks collapse by one.  This avoids wrap-around ambiguity while
     * bounding the ordering state and comparators to $clog2(DEPTH) bits.
     */
    logic [AGE_W-1:0] age_q [0:DEPTH-1];
    logic [COUNT_W-1:0] count_q;

    integer comb_i;
    integer seq_i;

    logic [INDEX_W-1:0] free_index;
    logic [INDEX_W-1:0] issue_index;
    logic [INDEX_W-1:0] dispatch_index;

    logic free_found;
    logic issue_found;

    logic [AGE_W-1:0] oldest_age;

    logic issue_fire;
    logic dispatch_fire;

    logic entry_ready;

    always_comb begin
        dispatch_ready = 1'b0;

        issue_valid = 1'b0;
        issue_pc = 32'b0;

        issue_opcode = 8'b0;
        issue_flags = 4'b0;

        issue_dst = 6'b0;
        issue_src0 = 6'b0;
        issue_src1 = 6'b0;
        issue_src2 = 6'b0;

        issue_pred = 4'b0;

        issue_vector_src0_enable = 1'b0;
        issue_vector_src1_enable = 1'b0;
        issue_vector_src2_enable = 1'b0;
        issue_vector_dst_enable = 1'b0;
        issue_predicate_src_enable = 1'b0;
        issue_predicate_dst_enable = 1'b0;

        free_found = 1'b0;
        issue_found = 1'b0;

        free_index = '0;
        issue_index = '0;
        dispatch_index = '0;

        oldest_age = {AGE_W{1'b1}};
        entry_ready = 1'b0;

        /* Find the first physically free slot. */
        for (comb_i = 0; comb_i < DEPTH; comb_i = comb_i + 1) begin
            if (!valid_q[comb_i] && !free_found) begin
                free_found = 1'b1;
                free_index = comb_i[INDEX_W-1:0];
            end
        end

        /*
         * Select the oldest dependency-ready resident instruction.
         *
         * The enable bits are the dependency classifier contract.  Unused
         * encoded fields therefore cannot create false dependencies, scalar
         * fields cannot alias vector registers, vector WAW is checked, and
         * vector-predicate RAW/WAW is checked.
         */
        for (comb_i = 0; comb_i < DEPTH; comb_i = comb_i + 1) begin
            entry_ready = (
                valid_q[comb_i]
                && (
                    !vector_src0_enable_q[comb_i]
                    || !busy_vector_regs[src0_q[comb_i]]
                )
                && (
                    !vector_src1_enable_q[comb_i]
                    || !busy_vector_regs[src1_q[comb_i]]
                )
                && (
                    !vector_src2_enable_q[comb_i]
                    || !busy_vector_regs[src2_q[comb_i]]
                )
                && (
                    !vector_dst_enable_q[comb_i]
                    || !busy_vector_regs[dst_q[comb_i]]
                )
                && (
                    !predicate_src_enable_q[comb_i]
                    || !busy_predicate_regs[pred_q[comb_i]]
                )
                && (
                    !predicate_dst_enable_q[comb_i]
                    || !busy_predicate_regs[pred_q[comb_i]]
                )
            );

            if (
                entry_ready
                && (
                    !issue_found
                    || age_q[comb_i] < oldest_age
                )
            ) begin
                issue_found = 1'b1;
                issue_index = comb_i[INDEX_W-1:0];
                oldest_age = age_q[comb_i];

                issue_valid = 1'b1;
                issue_pc = pc_q[comb_i];

                issue_opcode = opcode_q[comb_i];
                issue_flags = flags_q[comb_i];

                issue_dst = dst_q[comb_i];
                issue_src0 = src0_q[comb_i];
                issue_src1 = src1_q[comb_i];
                issue_src2 = src2_q[comb_i];

                issue_pred = pred_q[comb_i];

                issue_vector_src0_enable =
                    vector_src0_enable_q[comb_i];
                issue_vector_src1_enable =
                    vector_src1_enable_q[comb_i];
                issue_vector_src2_enable =
                    vector_src2_enable_q[comb_i];
                issue_vector_dst_enable =
                    vector_dst_enable_q[comb_i];
                issue_predicate_src_enable =
                    predicate_src_enable_q[comb_i];
                issue_predicate_dst_enable =
                    predicate_dst_enable_q[comb_i];
            end
        end

        issue_fire = issue_valid && issue_ready;

        /*
         * A full queue may accept one new instruction on the same cycle that
         * an existing instruction issues.  When no free slot exists, the
         * retiring issue slot is re-used atomically.
         */
        dispatch_ready = free_found || issue_fire;

        if (free_found) begin
            dispatch_index = free_index;
        end else begin
            dispatch_index = issue_index;
        end

        dispatch_fire = dispatch_valid && dispatch_ready;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            count_q <= '0;

            for (seq_i = 0; seq_i < DEPTH; seq_i = seq_i + 1) begin
                valid_q[seq_i] <= 1'b0;

                pc_q[seq_i] <= 32'b0;
                opcode_q[seq_i] <= 8'b0;
                flags_q[seq_i] <= 4'b0;

                dst_q[seq_i] <= 6'b0;
                src0_q[seq_i] <= 6'b0;
                src1_q[seq_i] <= 6'b0;
                src2_q[seq_i] <= 6'b0;
                pred_q[seq_i] <= 4'b0;

                vector_src0_enable_q[seq_i] <= 1'b0;
                vector_src1_enable_q[seq_i] <= 1'b0;
                vector_src2_enable_q[seq_i] <= 1'b0;
                vector_dst_enable_q[seq_i] <= 1'b0;
                predicate_src_enable_q[seq_i] <= 1'b0;
                predicate_dst_enable_q[seq_i] <= 1'b0;

                age_q[seq_i] <= '0;
            end
        end else begin
            /*
             * Collapse ranks after an issue so age is always local and
             * wrap-free: 0 .. resident_count-1.
             */
            if (issue_fire) begin
                for (seq_i = 0; seq_i < DEPTH; seq_i = seq_i + 1) begin
                    if (
                        valid_q[seq_i]
                        && seq_i[INDEX_W-1:0] != issue_index
                        && age_q[seq_i] > age_q[issue_index]
                    ) begin
                        age_q[seq_i] <= age_q[seq_i] - 1'b1;
                    end
                end

                valid_q[issue_index] <= 1'b0;
            end

            if (dispatch_fire) begin
                valid_q[dispatch_index] <= 1'b1;

                pc_q[dispatch_index] <= dispatch_pc;
                opcode_q[dispatch_index] <= dispatch_opcode;
                flags_q[dispatch_index] <= dispatch_flags;

                dst_q[dispatch_index] <= dispatch_dst;
                src0_q[dispatch_index] <= dispatch_src0;
                src1_q[dispatch_index] <= dispatch_src1;
                src2_q[dispatch_index] <= dispatch_src2;
                pred_q[dispatch_index] <= dispatch_pred;

                vector_src0_enable_q[dispatch_index] <=
                    dispatch_vector_src0_enable;
                vector_src1_enable_q[dispatch_index] <=
                    dispatch_vector_src1_enable;
                vector_src2_enable_q[dispatch_index] <=
                    dispatch_vector_src2_enable;
                vector_dst_enable_q[dispatch_index] <=
                    dispatch_vector_dst_enable;
                predicate_src_enable_q[dispatch_index] <=
                    dispatch_predicate_src_enable;
                predicate_dst_enable_q[dispatch_index] <=
                    dispatch_predicate_dst_enable;

                if (issue_fire) begin
                    age_q[dispatch_index] <=
                        AGE_W'(count_q - 1'b1);
                end else begin
                    age_q[dispatch_index] <= AGE_W'(count_q);
                end
            end

            case ({dispatch_fire, issue_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

endmodule
