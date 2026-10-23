`timescale 1ns/1ps

/*
 * A0 MC-NOC-P0 isolated cluster line-NoC endpoint.
 *
 * The endpoint sits after one cluster-local requester fabric. It adds a
 * constant cluster identity to line-read requests and removes that identity
 * from responses addressed to this cluster. Request and response transport
 * are independent one-entry registered elastic holds with no combinational
 * payload bypass.
 *
 * P0 deliberately contains no L2, home-slice routing, NoC arbitration,
 * stores, coherence, credits, outstanding table, or production adapter.
 */
module a0_cluster_line_noc_endpoint #(
    parameter integer CLUSTER_COUNT = 2,
    parameter integer CLUSTER_ID = 0,
    parameter integer CUS_PER_CLUSTER = 2,
    parameter integer MSHR_COUNT = 2,
    parameter integer LINE_WORDS = 8,

    parameter integer WORD_SELECT_W =
        (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),

    parameter integer LINE_ADDR_W =
        32 - WORD_SELECT_W,

    parameter integer CLUSTER_ID_W =
        (CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT),

    parameter integer CU_ID_W =
        (CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER),

    parameter integer LOCAL_TAG_W =
        (MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT),

    parameter integer CLUSTER_LOCAL_TAG_W =
        CU_ID_W + LOCAL_TAG_W,

    parameter integer NETWORK_TAG_W =
        CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
) (
    input logic clk,
    input logic rst_n,

    /* Cluster-local request: tag layout is {cu_id, local_tag}. */
    input logic local_req_valid_i,
    output logic local_req_ready_o,

    input logic [CLUSTER_LOCAL_TAG_W-1:0]
        local_req_tag_i,

    input logic [LINE_ADDR_W-1:0]
        local_req_line_addr_i,

    output logic local_req_tag_error_o,

    /* Logical-NoC request: network tag is {cluster_id, cu_id, local_tag}. */
    output logic noc_req_valid_o,
    input logic noc_req_ready_i,

    output logic [NETWORK_TAG_W-1:0]
        noc_req_network_tag_o,

    output logic [LINE_ADDR_W-1:0]
        noc_req_line_addr_o,

    /* Logical-NoC response with proper ready/valid backpressure. */
    input logic noc_resp_valid_i,
    output logic noc_resp_ready_o,

    input logic [NETWORK_TAG_W-1:0]
        noc_resp_network_tag_i,

    input logic [LINE_ADDR_W-1:0]
        noc_resp_line_addr_i,

    input logic noc_resp_fault_i,

    input logic [31:0]
        noc_resp_data_i [0:LINE_WORDS-1],

    output logic noc_resp_tag_error_o,

    /* Restored cluster-local response. */
    output logic local_resp_valid_o,
    input logic local_resp_ready_i,

    output logic [CLUSTER_LOCAL_TAG_W-1:0]
        local_resp_tag_o,

    output logic [LINE_ADDR_W-1:0]
        local_resp_line_addr_o,

    output logic local_resp_fault_o,

    output logic [31:0]
        local_resp_data_o [0:LINE_WORDS-1]
);

    localparam logic [CLUSTER_ID_W-1:0] THIS_CLUSTER_ID =
        CLUSTER_ID_W'(CLUSTER_ID);

    logic req_hold_valid_q;
    logic [NETWORK_TAG_W-1:0] req_hold_network_tag_q;
    logic [LINE_ADDR_W-1:0] req_hold_line_addr_q;

    logic resp_hold_valid_q;
    logic [CLUSTER_LOCAL_TAG_W-1:0] resp_hold_local_tag_q;
    logic [LINE_ADDR_W-1:0] resp_hold_line_addr_q;
    logic resp_hold_fault_q;
    logic [31:0] resp_hold_data_q [0:LINE_WORDS-1];

    logic [CU_ID_W-1:0] local_req_cu_id;
    logic local_req_cu_valid;

    logic [CLUSTER_ID_W-1:0] noc_resp_cluster_id;
    logic [CU_ID_W-1:0] noc_resp_cu_id;
    logic noc_resp_cluster_valid;
    logic noc_resp_cu_valid;
    logic noc_resp_identity_valid;

    logic req_slot_available;
    logic resp_slot_available;
    logic req_enqueue;
    logic req_dequeue;
    logic resp_enqueue;
    logic resp_dequeue;

    integer output_word;
    integer sequential_word;

    genvar assertion_word;


    function automatic logic cluster_id_valid(
        input logic [CLUSTER_ID_W-1:0] cluster_id
    );
        cluster_id_valid =
            integer'(cluster_id) < CLUSTER_COUNT;
    endfunction


    function automatic logic cu_id_valid(
        input logic [CU_ID_W-1:0] cu_id
    );
        cu_id_valid =
            integer'(cu_id) < CUS_PER_CLUSTER;
    endfunction


    initial begin
        if (CLUSTER_COUNT < 1) begin
            $fatal(1, "MC_NOC_P0 CLUSTER_COUNT must be >= 1");
        end
        if (CLUSTER_ID < 0 || CLUSTER_ID >= CLUSTER_COUNT) begin
            $fatal(1, "MC_NOC_P0 CLUSTER_ID out of range");
        end
        if (CUS_PER_CLUSTER < 1 || CUS_PER_CLUSTER > 4) begin
            $fatal(1, "MC_NOC_P0 CUS_PER_CLUSTER must be 1..4");
        end
        if (MSHR_COUNT < 1) begin
            $fatal(1, "MC_NOC_P0 MSHR_COUNT must be >= 1");
        end
        if (LINE_WORDS < 1) begin
            $fatal(1, "MC_NOC_P0 LINE_WORDS must be >= 1");
        end
        if (
            LINE_WORDS >= 1
            && (LINE_WORDS & (LINE_WORDS - 1)) != 0
        ) begin
            $fatal(1, "MC_NOC_P0 LINE_WORDS must be a power of two");
        end
        if (WORD_SELECT_W != ((LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS))) begin
            $fatal(1, "MC_NOC_P0 WORD_SELECT_W inconsistent");
        end
        if (LINE_ADDR_W != 32 - WORD_SELECT_W || LINE_ADDR_W < 1) begin
            $fatal(1, "MC_NOC_P0 LINE_ADDR_W inconsistent");
        end
        if (
            CLUSTER_ID_W
            != ((CLUSTER_COUNT <= 1) ? 1 : $clog2(CLUSTER_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P0 CLUSTER_ID_W inconsistent");
        end
        if (
            CU_ID_W
            != ((CUS_PER_CLUSTER <= 1) ? 1 : $clog2(CUS_PER_CLUSTER))
        ) begin
            $fatal(1, "MC_NOC_P0 CU_ID_W inconsistent");
        end
        if (
            LOCAL_TAG_W
            != ((MSHR_COUNT <= 1) ? 1 : $clog2(MSHR_COUNT))
        ) begin
            $fatal(1, "MC_NOC_P0 LOCAL_TAG_W inconsistent");
        end
        if (CLUSTER_LOCAL_TAG_W != CU_ID_W + LOCAL_TAG_W) begin
            $fatal(1, "MC_NOC_P0 CLUSTER_LOCAL_TAG_W inconsistent");
        end
        if (
            NETWORK_TAG_W
            != CLUSTER_ID_W + CLUSTER_LOCAL_TAG_W
        ) begin
            $fatal(1, "MC_NOC_P0 NETWORK_TAG_W inconsistent");
        end
    end


    always_comb begin
        local_req_cu_id =
            local_req_tag_i[
                CLUSTER_LOCAL_TAG_W-1
                -:
                CU_ID_W
            ];

        local_req_cu_valid =
            cu_id_valid(local_req_cu_id);

        noc_resp_cluster_id =
            noc_resp_network_tag_i[
                NETWORK_TAG_W-1
                -:
                CLUSTER_ID_W
            ];

        noc_resp_cu_id =
            noc_resp_network_tag_i[
                CLUSTER_LOCAL_TAG_W-1
                -:
                CU_ID_W
            ];

        noc_resp_cluster_valid =
            cluster_id_valid(noc_resp_cluster_id);

        noc_resp_cu_valid =
            cu_id_valid(noc_resp_cu_id);

        noc_resp_identity_valid =
            noc_resp_cluster_valid
            && noc_resp_cluster_id == THIS_CLUSTER_ID
            && noc_resp_cu_valid;

        req_slot_available =
            !req_hold_valid_q
            || noc_req_ready_i;

        resp_slot_available =
            !resp_hold_valid_q
            || local_resp_ready_i;

        local_req_ready_o =
            rst_n
            && req_slot_available
            && (
                !local_req_valid_i
                || local_req_cu_valid
            );

        noc_resp_ready_o =
            rst_n
            && resp_slot_available
            && (
                !noc_resp_valid_i
                || noc_resp_identity_valid
            );

        local_req_tag_error_o =
            rst_n
            && local_req_valid_i
            && !local_req_cu_valid;

        noc_resp_tag_error_o =
            rst_n
            && noc_resp_valid_i
            && !noc_resp_identity_valid;

        noc_req_valid_o =
            rst_n
            && req_hold_valid_q;

        noc_req_network_tag_o =
            req_hold_network_tag_q;

        noc_req_line_addr_o =
            req_hold_line_addr_q;

        local_resp_valid_o =
            rst_n
            && resp_hold_valid_q;

        local_resp_tag_o =
            resp_hold_local_tag_q;

        local_resp_line_addr_o =
            resp_hold_line_addr_q;

        local_resp_fault_o =
            resp_hold_fault_q;

        for (
            output_word = 0;
            output_word < LINE_WORDS;
            output_word = output_word + 1
        ) begin
            local_resp_data_o[output_word] =
                resp_hold_data_q[output_word];
        end

        req_enqueue =
            local_req_valid_i
            && local_req_ready_o;

        req_dequeue =
            noc_req_valid_o
            && noc_req_ready_i;

        resp_enqueue =
            noc_resp_valid_i
            && noc_resp_ready_o;

        resp_dequeue =
            local_resp_valid_o
            && local_resp_ready_i;
    end


    always_ff @(posedge clk) begin
        if (!rst_n) begin
            req_hold_valid_q <= 1'b0;
            req_hold_network_tag_q <= '0;
            req_hold_line_addr_q <= '0;

            resp_hold_valid_q <= 1'b0;
            resp_hold_local_tag_q <= '0;
            resp_hold_line_addr_q <= '0;
            resp_hold_fault_q <= 1'b0;

            for (
                sequential_word = 0;
                sequential_word < LINE_WORDS;
                sequential_word = sequential_word + 1
            ) begin
                resp_hold_data_q[sequential_word] <= '0;
            end
        end else begin
            /* Enqueue wins so dequeue plus replacement has no bubble. */
            if (req_enqueue) begin
                req_hold_valid_q <= 1'b1;
                req_hold_network_tag_q <= {
                    THIS_CLUSTER_ID,
                    local_req_tag_i
                };
                req_hold_line_addr_q <=
                    local_req_line_addr_i;
            end else if (req_dequeue) begin
                req_hold_valid_q <= 1'b0;
            end

            /* Response direction is independent and has identical turnover. */
            if (resp_enqueue) begin
                resp_hold_valid_q <= 1'b1;
                resp_hold_local_tag_q <=
                    noc_resp_network_tag_i[
                        CLUSTER_LOCAL_TAG_W-1:0
                    ];
                resp_hold_line_addr_q <=
                    noc_resp_line_addr_i;
                resp_hold_fault_q <=
                    noc_resp_fault_i;

                for (
                    sequential_word = 0;
                    sequential_word < LINE_WORDS;
                    sequential_word = sequential_word + 1
                ) begin
                    resp_hold_data_q[sequential_word] <=
                        noc_resp_data_i[sequential_word];
                end
            end else if (resp_dequeue) begin
                resp_hold_valid_q <= 1'b0;
            end
        end
    end


    property request_output_stable_under_stall;
        @(posedge clk)
        disable iff (!rst_n)
        noc_req_valid_o
        && !noc_req_ready_i
        |=> noc_req_valid_o
            && $stable(noc_req_network_tag_o)
            && $stable(noc_req_line_addr_o);
    endproperty

    assert property (request_output_stable_under_stall)
        else $fatal(1, "MC_NOC_P0 request payload changed under stall");


    property response_output_stable_under_stall;
        @(posedge clk)
        disable iff (!rst_n)
        local_resp_valid_o
        && !local_resp_ready_i
        |=> local_resp_valid_o
            && $stable(local_resp_tag_o)
            && $stable(local_resp_line_addr_o)
            && $stable(local_resp_fault_o);
    endproperty

    assert property (response_output_stable_under_stall)
        else $fatal(1, "MC_NOC_P0 response payload changed under stall");

    generate
        for (
            assertion_word = 0;
            assertion_word < LINE_WORDS;
            assertion_word = assertion_word + 1
        ) begin : gen_response_data_stability_assertion
            property response_data_word_stable_under_stall;
                @(posedge clk)
                disable iff (!rst_n)
                local_resp_valid_o
                && !local_resp_ready_i
                |=> $stable(local_resp_data_o[assertion_word]);
            endproperty

            assert property (response_data_word_stable_under_stall)
                else $fatal(
                    1,
                    "MC_NOC_P0 response data changed under stall"
                );
        end
    endgenerate


    property invalid_local_cu_cannot_handshake;
        @(posedge clk)
        disable iff (!rst_n)
        local_req_valid_i
        && !local_req_cu_valid
        |-> !local_req_ready_o;
    endproperty

    assert property (invalid_local_cu_cannot_handshake)
        else $fatal(1, "MC_NOC_P0 invalid local CU handshook");


    property wrong_cluster_cannot_handshake;
        @(posedge clk)
        disable iff (!rst_n)
        noc_resp_valid_i
        && (
            !noc_resp_cluster_valid
            || noc_resp_cluster_id != THIS_CLUSTER_ID
        )
        |-> !noc_resp_ready_o;
    endproperty

    assert property (wrong_cluster_cannot_handshake)
        else $fatal(1, "MC_NOC_P0 wrong cluster response handshook");


    property invalid_response_cu_cannot_handshake;
        @(posedge clk)
        disable iff (!rst_n)
        noc_resp_valid_i
        && !noc_resp_cu_valid
        |-> !noc_resp_ready_o;
    endproperty

    assert property (invalid_response_cu_cannot_handshake)
        else $fatal(1, "MC_NOC_P0 invalid response CU handshook");


    property request_cluster_prefix_is_constant;
        @(posedge clk)
        disable iff (!rst_n)
        noc_req_valid_o
        |-> noc_req_network_tag_o[
                NETWORK_TAG_W-1
                -:
                CLUSTER_ID_W
            ] == THIS_CLUSTER_ID;
    endproperty

    assert property (request_cluster_prefix_is_constant)
        else $fatal(1, "MC_NOC_P0 request cluster prefix mismatch");


    property reset_clears_holds;
        @(posedge clk)
        !rst_n
        |=> !req_hold_valid_q
            && !resp_hold_valid_q;
    endproperty

    assert property (reset_clears_holds)
        else $fatal(1, "MC_NOC_P0 reset did not clear holds");

endmodule
