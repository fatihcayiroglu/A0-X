`timescale 1ns/1ps

module a0_dependency_classifier (
    input logic instruction_valid,

    input logic [7:0] opcode,
    input logic [3:0] flags /* verilator public_flat */,

    input logic [5:0] dst_index,
    input logic [5:0] src0_index,
    input logic [5:0] src1_index,
    input logic [5:0] src2_index,

    input logic [3:0] pred_index,

    output logic tracked_instruction,

    output logic vector_src0_enable,
    output logic [5:0] vector_src0,

    output logic vector_src1_enable,
    output logic [5:0] vector_src1,

    output logic vector_src2_enable,
    output logic [5:0] vector_src2,

    output logic vector_dst_enable,
    output logic [5:0] vector_dst,

    output logic predicate_src_enable,
    output logic [3:0] predicate_src,

    output logic predicate_dst_enable,
    output logic [3:0] predicate_dst
);

    localparam logic [7:0] OP_VADD     = 8'h01;
    localparam logic [7:0] OP_VSUB     = 8'h02;
    localparam logic [7:0] OP_VMUL     = 8'h03;
    localparam logic [7:0] OP_VAND     = 8'h04;
    localparam logic [7:0] OP_VOR      = 8'h05;
    localparam logic [7:0] OP_VXOR     = 8'h06;

    localparam logic [7:0] OP_VLOADX   = 8'h54;
    localparam logic [7:0] OP_VSTOREX  = 8'h55;

    localparam logic [7:0] OP_VCMP_EQ  = 8'h60;
    localparam logic [7:0] OP_VCMP_LT  = 8'h61;
    localparam logic [7:0] OP_VCMP_LE  = 8'h62;

    localparam logic [7:0] OP_SPLIT    = 8'h72;


    always_comb begin

        tracked_instruction = 1'b0;

        vector_src0_enable = 1'b0;
        vector_src1_enable = 1'b0;
        vector_src2_enable = 1'b0;

        vector_dst_enable = 1'b0;

        predicate_src_enable = 1'b0;
        predicate_dst_enable = 1'b0;


        /*
         * Indices always reflect the decoded instruction.
         * Enable signals determine whether they participate
         * in dependency checking.
         */
        vector_src0 = src0_index;
        vector_src1 = src1_index;
        vector_src2 = src2_index;

        vector_dst = dst_index;

        predicate_src = pred_index;
        predicate_dst = pred_index;


        if (instruction_valid) begin

            case (opcode)

                OP_VADD,
                OP_VSUB,
                OP_VMUL,
                OP_VAND,
                OP_VOR,
                OP_VXOR: begin

                    tracked_instruction = 1'b1;

                    vector_src0_enable = 1'b1;
                    vector_src1_enable = 1'b1;

                    vector_dst_enable = 1'b1;

                    /*
                     * Current vector ALU predication
                     * contract uses flags[0].
                     */
                    predicate_src_enable =
                        flags[0];
                end


                OP_VCMP_EQ,
                OP_VCMP_LT,
                OP_VCMP_LE: begin

                    tracked_instruction = 1'b1;

                    vector_src0_enable = 1'b1;
                    vector_src1_enable = 1'b1;

                    /*
                     * Compare writes the vector-predicate
                     * register selected by pred_index.
                     *
                     * Current VCMP execution uses EXEC only,
                     * so flags[0] does not create a
                     * predicate source dependency.
                     */
                    predicate_dst_enable = 1'b1;
                end


                OP_VLOADX: begin

                    tracked_instruction = 1'b1;

                    /*
                     * src0 is the scalar base and is outside
                     * the RTL5B Phase 2 vector scoreboard.
                     *
                     * src1 is the per-lane vector offset.
                     */
                    vector_src1_enable = 1'b1;
                    vector_dst_enable = 1'b1;

                    predicate_src_enable =
                        flags[0];
                end


                OP_VSTOREX: begin

                    tracked_instruction = 1'b1;

                    /*
                     * src0 is the scalar base.
                     * src1 is vector offset.
                     * src2 is vector store data.
                     */
                    vector_src1_enable = 1'b1;
                    vector_src2_enable = 1'b1;

                    predicate_src_enable =
                        flags[0];
                end


                OP_SPLIT: begin

                    tracked_instruction = 1'b1;

                    /*
                     * SPLIT consumes the vector predicate
                     * selected by pred_index.
                     */
                    predicate_src_enable = 1'b1;
                end


                default: begin
                    /*
                     * Scalar-only/control instructions that
                     * do not consume vector/predicate state,
                     * and unsupported opcodes, do not enter
                     * this Phase 2 scoreboard query.
                     */
                end

            endcase
        end
    end

endmodule
