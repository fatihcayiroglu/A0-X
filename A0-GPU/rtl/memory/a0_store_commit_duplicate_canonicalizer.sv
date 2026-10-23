`timescale 1ns/1ps

/*
 * PROD-SEAM-P11 bounded same-commit duplicate-word canonicalizer.
 *
 * Non-atomic stores from multiple lanes of one visibility commit may target the
 * same word.  P8 intentionally failed stop while this case was unfrozen.  P11
 * gives the implementation a deterministic local rule without claiming atomic
 * semantics: among active lanes targeting one word, the highest lane index is
 * retained.  This is exactly the final writer that P8's existing ascending-lane
 * serialization would produce if all duplicate beats were emitted.
 */
module a0_store_commit_duplicate_canonicalizer #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer STORE_LANES = 32
) (
    input logic [CUS_PER_CLUSTER-1:0]
        commit_valid_i [0:CLUSTER_COUNT-1],
    input logic [STORE_LANES-1:0]
        commit_lane_mask_i [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    input logic [31:0]
        commit_word_addr_i
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1],
    input logic [31:0]
        commit_wdata_i
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1],

    output logic [STORE_LANES-1:0]
        canonical_lane_mask_o [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1],
    output logic [31:0]
        canonical_word_addr_o
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1],
    output logic [31:0]
        canonical_wdata_o
            [0:CLUSTER_COUNT-1][0:CUS_PER_CLUSTER-1][0:STORE_LANES-1],
    output logic [CUS_PER_CLUSTER-1:0]
        duplicate_collapse_o [0:CLUSTER_COUNT-1]
);
    initial begin
        if (CLUSTER_COUNT < 1)
            $fatal(1, "PROD_SEAM_P11 CLUSTER_COUNT must be >= 1");
        if (CUS_PER_CLUSTER < 1)
            $fatal(1, "PROD_SEAM_P11 CUS_PER_CLUSTER must be >= 1");
        if (STORE_LANES < 1)
            $fatal(1, "PROD_SEAM_P11 STORE_LANES must be >= 1");
    end

    always_comb begin
        for (integer cluster = 0; cluster < CLUSTER_COUNT; cluster = cluster + 1) begin
            duplicate_collapse_o[cluster] = '0;
            for (integer cu = 0; cu < CUS_PER_CLUSTER; cu = cu + 1) begin
                canonical_lane_mask_o[cluster][cu] = commit_lane_mask_i[cluster][cu];
                for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                    canonical_word_addr_o[cluster][cu][lane] =
                        commit_word_addr_i[cluster][cu][lane];
                    canonical_wdata_o[cluster][cu][lane] =
                        commit_wdata_i[cluster][cu][lane];
                end

                if (commit_valid_i[cluster][cu]) begin
                    for (integer lane = 0; lane < STORE_LANES; lane = lane + 1) begin
                        if (commit_lane_mask_i[cluster][cu][lane]) begin
                            for (integer higher = lane + 1;
                                 higher < STORE_LANES; higher = higher + 1) begin
                                if (commit_lane_mask_i[cluster][cu][higher]
                                    && commit_word_addr_i[cluster][cu][lane]
                                        == commit_word_addr_i[cluster][cu][higher]) begin
                                    canonical_lane_mask_o[cluster][cu][lane] = 1'b0;
                                    duplicate_collapse_o[cluster][cu] = 1'b1;
                                end
                            end
                        end
                    end
                end
            end
        end
    end
endmodule
