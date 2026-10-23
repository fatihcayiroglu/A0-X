`timescale 1ns/1ps

module a0_cluster_line_noc_endpoint_tb #(
    parameter integer CLUSTER_COUNT = 3,
    parameter integer CLUSTER_ID = 1,
    parameter integer CUS_PER_CLUSTER = 3,
    parameter integer MSHR_COUNT = 2,
    parameter integer LINE_WORDS = 8,
    parameter bit FULL_SCENARIOS = 1'b1,

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
);

    localparam integer ALT_CLUSTER_ID =
        (CLUSTER_COUNT <= 1)
            ? 0
            : ((CLUSTER_ID == 0) ? 1 : 0);
    localparam integer CLUSTER_ID_ENCODING_COUNT =
        integer'(64'd1 << CLUSTER_ID_W);
    localparam integer CU_ID_ENCODING_COUNT =
        integer'(64'd1 << CU_ID_W);
    localparam integer LOCAL_TAG_ENCODING_COUNT =
        integer'(64'd1 << LOCAL_TAG_W);
    localparam integer NETWORK_TAG_SPACE =
        integer'(64'd1 << NETWORK_TAG_W);

    localparam logic [CLUSTER_ID_W-1:0] THIS_CLUSTER_ID =
        CLUSTER_ID_W'(CLUSTER_ID);
    localparam logic [CLUSTER_ID_W-1:0] ALT_THIS_CLUSTER_ID =
        CLUSTER_ID_W'(ALT_CLUSTER_ID);

    logic clk;
    logic rst_n;

    logic local_req_valid_i;
    logic local_req_ready_o;
    logic [CLUSTER_LOCAL_TAG_W-1:0] local_req_tag_i;
    logic [LINE_ADDR_W-1:0] local_req_line_addr_i;
    logic local_req_tag_error_o;

    logic noc_req_valid_o;
    logic noc_req_ready_i;
    logic [NETWORK_TAG_W-1:0] noc_req_network_tag_o;
    logic [LINE_ADDR_W-1:0] noc_req_line_addr_o;

    logic noc_resp_valid_i;
    logic noc_resp_ready_o;
    logic [NETWORK_TAG_W-1:0] noc_resp_network_tag_i;
    logic [LINE_ADDR_W-1:0] noc_resp_line_addr_i;
    logic noc_resp_fault_i;
    logic [31:0] noc_resp_data_i [0:LINE_WORDS-1];
    logic noc_resp_tag_error_o;

    logic local_resp_valid_o;
    logic local_resp_ready_i;
    logic [CLUSTER_LOCAL_TAG_W-1:0] local_resp_tag_o;
    logic [LINE_ADDR_W-1:0] local_resp_line_addr_o;
    logic local_resp_fault_o;
    logic [31:0] local_resp_data_o [0:LINE_WORDS-1];

    logic alt_local_req_valid_i;
    logic alt_local_req_ready_o;
    logic [CLUSTER_LOCAL_TAG_W-1:0] alt_local_req_tag_i;
    logic [LINE_ADDR_W-1:0] alt_local_req_line_addr_i;
    logic alt_local_req_tag_error_o;

    logic alt_noc_req_valid_o;
    logic alt_noc_req_ready_i;
    logic [NETWORK_TAG_W-1:0] alt_noc_req_network_tag_o;
    logic [LINE_ADDR_W-1:0] alt_noc_req_line_addr_o;

    logic alt_noc_resp_valid_i;
    logic alt_noc_resp_ready_o;
    logic [NETWORK_TAG_W-1:0] alt_noc_resp_network_tag_i;
    logic [LINE_ADDR_W-1:0] alt_noc_resp_line_addr_i;
    logic alt_noc_resp_fault_i;
    logic [31:0] alt_noc_resp_data_i [0:LINE_WORDS-1];
    logic alt_noc_resp_tag_error_o;

    logic alt_local_resp_valid_o;
    logic alt_local_resp_ready_i;
    logic [CLUSTER_LOCAL_TAG_W-1:0] alt_local_resp_tag_o;
    logic [LINE_ADDR_W-1:0] alt_local_resp_line_addr_o;
    logic alt_local_resp_fault_o;
    logic [31:0] alt_local_resp_data_o [0:LINE_WORDS-1];

    integer unsigned request_accept_count;
    integer unsigned request_emit_count;
    integer unsigned response_accept_count;
    integer unsigned response_emit_count;

    logic request_model_valid;
    logic [NETWORK_TAG_W-1:0] request_model_tag;
    logic [LINE_ADDR_W-1:0] request_model_line;

    logic response_model_valid;
    logic [CLUSTER_LOCAL_TAG_W-1:0] response_model_tag;
    logic [LINE_ADDR_W-1:0] response_model_line;
    logic response_model_fault;
    logic [31:0] response_model_data [0:LINE_WORDS-1];

    logic request_accept;
    logic request_emit;
    logic response_accept;
    logic response_emit;

    assign request_accept = local_req_valid_i && local_req_ready_o;
    assign request_emit = noc_req_valid_o && noc_req_ready_i;
    assign response_accept = noc_resp_valid_i && noc_resp_ready_o;
    assign response_emit = local_resp_valid_o && local_resp_ready_i;


    a0_cluster_line_noc_endpoint #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CLUSTER_ID(CLUSTER_ID),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .CLUSTER_ID_W(CLUSTER_ID_W),
        .CU_ID_W(CU_ID_W),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLUSTER_LOCAL_TAG_W(CLUSTER_LOCAL_TAG_W),
        .NETWORK_TAG_W(NETWORK_TAG_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .local_req_valid_i(local_req_valid_i),
        .local_req_ready_o(local_req_ready_o),
        .local_req_tag_i(local_req_tag_i),
        .local_req_line_addr_i(local_req_line_addr_i),
        .local_req_tag_error_o(local_req_tag_error_o),
        .noc_req_valid_o(noc_req_valid_o),
        .noc_req_ready_i(noc_req_ready_i),
        .noc_req_network_tag_o(noc_req_network_tag_o),
        .noc_req_line_addr_o(noc_req_line_addr_o),
        .noc_resp_valid_i(noc_resp_valid_i),
        .noc_resp_ready_o(noc_resp_ready_o),
        .noc_resp_network_tag_i(noc_resp_network_tag_i),
        .noc_resp_line_addr_i(noc_resp_line_addr_i),
        .noc_resp_fault_i(noc_resp_fault_i),
        .noc_resp_data_i(noc_resp_data_i),
        .noc_resp_tag_error_o(noc_resp_tag_error_o),
        .local_resp_valid_o(local_resp_valid_o),
        .local_resp_ready_i(local_resp_ready_i),
        .local_resp_tag_o(local_resp_tag_o),
        .local_resp_line_addr_o(local_resp_line_addr_o),
        .local_resp_fault_o(local_resp_fault_o),
        .local_resp_data_o(local_resp_data_o)
    );


    a0_cluster_line_noc_endpoint #(
        .CLUSTER_COUNT(CLUSTER_COUNT),
        .CLUSTER_ID(ALT_CLUSTER_ID),
        .CUS_PER_CLUSTER(CUS_PER_CLUSTER),
        .MSHR_COUNT(MSHR_COUNT),
        .LINE_WORDS(LINE_WORDS),
        .WORD_SELECT_W(WORD_SELECT_W),
        .LINE_ADDR_W(LINE_ADDR_W),
        .CLUSTER_ID_W(CLUSTER_ID_W),
        .CU_ID_W(CU_ID_W),
        .LOCAL_TAG_W(LOCAL_TAG_W),
        .CLUSTER_LOCAL_TAG_W(CLUSTER_LOCAL_TAG_W),
        .NETWORK_TAG_W(NETWORK_TAG_W)
    ) alt_dut (
        .clk(clk),
        .rst_n(rst_n),
        .local_req_valid_i(alt_local_req_valid_i),
        .local_req_ready_o(alt_local_req_ready_o),
        .local_req_tag_i(alt_local_req_tag_i),
        .local_req_line_addr_i(alt_local_req_line_addr_i),
        .local_req_tag_error_o(alt_local_req_tag_error_o),
        .noc_req_valid_o(alt_noc_req_valid_o),
        .noc_req_ready_i(alt_noc_req_ready_i),
        .noc_req_network_tag_o(alt_noc_req_network_tag_o),
        .noc_req_line_addr_o(alt_noc_req_line_addr_o),
        .noc_resp_valid_i(alt_noc_resp_valid_i),
        .noc_resp_ready_o(alt_noc_resp_ready_o),
        .noc_resp_network_tag_i(alt_noc_resp_network_tag_i),
        .noc_resp_line_addr_i(alt_noc_resp_line_addr_i),
        .noc_resp_fault_i(alt_noc_resp_fault_i),
        .noc_resp_data_i(alt_noc_resp_data_i),
        .noc_resp_tag_error_o(alt_noc_resp_tag_error_o),
        .local_resp_valid_o(alt_local_resp_valid_o),
        .local_resp_ready_i(alt_local_resp_ready_i),
        .local_resp_tag_o(alt_local_resp_tag_o),
        .local_resp_line_addr_o(alt_local_resp_line_addr_o),
        .local_resp_fault_o(alt_local_resp_fault_o),
        .local_resp_data_o(alt_local_resp_data_o)
    );


    initial clk = 1'b0;
    always #5 clk = ~clk;


    function automatic logic [CLUSTER_LOCAL_TAG_W-1:0] make_local_tag(
        input integer cu_id,
        input integer local_tag
    );
        begin
            if (
                cu_id < 0
                || cu_id >= CU_ID_ENCODING_COUNT
                || local_tag < 0
                || local_tag >= LOCAL_TAG_ENCODING_COUNT
            ) begin
                $fatal(1, "MC-NOC-P0 TB local tag field is not representable");
            end
            make_local_tag = {
                CU_ID_W'(cu_id),
                LOCAL_TAG_W'(local_tag)
            };
        end
    endfunction


    function automatic logic [NETWORK_TAG_W-1:0] make_network_tag(
        input integer cluster_id,
        input integer cu_id,
        input integer local_tag
    );
        begin
            if (
                cluster_id < 0
                || cluster_id >= CLUSTER_ID_ENCODING_COUNT
                || cu_id < 0
                || cu_id >= CU_ID_ENCODING_COUNT
                || local_tag < 0
                || local_tag >= LOCAL_TAG_ENCODING_COUNT
            ) begin
                $fatal(1, "MC-NOC-P0 TB network tag field is not representable");
            end
            make_network_tag = {
                CLUSTER_ID_W'(cluster_id),
                CU_ID_W'(cu_id),
                LOCAL_TAG_W'(local_tag)
            };
        end
    endfunction


    task automatic clear_inputs;
        integer word_index;
        begin
            local_req_valid_i = 1'b0;
            local_req_tag_i = '0;
            local_req_line_addr_i = '0;
            noc_req_ready_i = 1'b0;

            noc_resp_valid_i = 1'b0;
            noc_resp_network_tag_i = '0;
            noc_resp_line_addr_i = '0;
            noc_resp_fault_i = 1'b0;
            local_resp_ready_i = 1'b0;

            alt_local_req_valid_i = 1'b0;
            alt_local_req_tag_i = '0;
            alt_local_req_line_addr_i = '0;
            alt_noc_req_ready_i = 1'b0;

            alt_noc_resp_valid_i = 1'b0;
            alt_noc_resp_network_tag_i = '0;
            alt_noc_resp_line_addr_i = '0;
            alt_noc_resp_fault_i = 1'b0;
            alt_local_resp_ready_i = 1'b0;

            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                noc_resp_data_i[word_index] = '0;
                alt_noc_resp_data_i[word_index] = '0;
            end
        end
    endtask


    task automatic reset_epoch;
        begin
            rst_n = 1'b0;
            clear_inputs();
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
        end
    endtask


    task automatic set_main_request(
        input integer cu_id,
        input integer local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            local_req_tag_i = make_local_tag(cu_id, local_tag);
            local_req_line_addr_i = line_addr;
            local_req_valid_i = 1'b1;
        end
    endtask


    task automatic set_alt_request(
        input integer cu_id,
        input integer local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr
    );
        begin
            alt_local_req_tag_i = make_local_tag(cu_id, local_tag);
            alt_local_req_line_addr_i = line_addr;
            alt_local_req_valid_i = 1'b1;
        end
    endtask


    task automatic set_main_response(
        input integer cluster_id,
        input integer cu_id,
        input integer local_tag,
        input logic [LINE_ADDR_W-1:0] line_addr,
        input logic fault,
        input logic [31:0] data_seed
    );
        integer word_index;
        begin
            noc_resp_network_tag_i =
                make_network_tag(cluster_id, cu_id, local_tag);
            noc_resp_line_addr_i = line_addr;
            noc_resp_fault_i = fault;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                noc_resp_data_i[word_index] =
                    data_seed + 32'(word_index);
            end
            noc_resp_valid_i = 1'b1;
        end
    endtask


    task automatic check_main_response_data(
        input logic [31:0] data_seed
    );
        integer word_index;
        begin
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                if (
                    local_resp_data_o[word_index]
                    !== data_seed + 32'(word_index)
                ) begin
                    $fatal(
                        1,
                        "MC-NOC-P0 local response data mismatch word=%0d",
                        word_index
                    );
                end
            end
        end
    endtask


    task automatic check_alt_idle;
        integer word_index;
        begin
            if (
                alt_noc_req_valid_o
                || alt_local_resp_valid_o
                || alt_local_req_tag_error_o
                || alt_noc_resp_tag_error_o
            ) begin
                $fatal(1, "MC-NOC-P0 alternate endpoint unexpectedly active");
            end
            if (
                (^alt_noc_resp_ready_o === 1'bx)
                || (^alt_local_req_ready_o === 1'bx)
                || (^alt_noc_req_network_tag_o === 1'bx)
                || (^alt_noc_req_line_addr_o === 1'bx)
                || (^alt_local_resp_tag_o === 1'bx)
                || (^alt_local_resp_line_addr_o === 1'bx)
                || (^alt_local_resp_fault_o === 1'bx)
            ) begin
                $fatal(1, "MC-NOC-P0 alternate endpoint exposed unknown output");
            end
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                if (^alt_local_resp_data_o[word_index] === 1'bx) begin
                    $fatal(1, "MC-NOC-P0 alternate endpoint data is unknown");
                end
            end
        end
    endtask


    always_ff @(posedge clk) begin : p_black_box_scoreboards
        integer word_index;

        if (!rst_n) begin
            request_accept_count <= 0;
            request_emit_count <= 0;
            response_accept_count <= 0;
            response_emit_count <= 0;

            request_model_valid <= 1'b0;
            request_model_tag <= '0;
            request_model_line <= '0;

            response_model_valid <= 1'b0;
            response_model_tag <= '0;
            response_model_line <= '0;
            response_model_fault <= 1'b0;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                response_model_data[word_index] <= '0;
            end
        end else begin
            if (request_emit) begin
                if (!request_model_valid) begin
                    $fatal(1, "MC-NOC-P0 phantom network request emission");
                end
                if (
                    noc_req_network_tag_o !== request_model_tag
                    || noc_req_line_addr_o !== request_model_line
                ) begin
                    $fatal(1, "MC-NOC-P0 network request differs from scoreboard");
                end
                request_emit_count <= request_emit_count + 1;
            end

            if (request_accept) begin
                if (request_model_valid && !request_emit) begin
                    $fatal(1, "MC-NOC-P0 request hold overflow");
                end
                if (
                    integer'(
                        local_req_tag_i[
                            CLUSTER_LOCAL_TAG_W-1
                            -: CU_ID_W
                        ]
                    ) >= CUS_PER_CLUSTER
                ) begin
                    $fatal(1, "MC-NOC-P0 malformed local request handshook");
                end
                request_accept_count <= request_accept_count + 1;
                request_model_valid <= 1'b1;
                request_model_tag <= {THIS_CLUSTER_ID, local_req_tag_i};
                request_model_line <= local_req_line_addr_i;
            end else if (request_emit) begin
                request_model_valid <= 1'b0;
            end

            if (response_emit) begin
                if (!response_model_valid) begin
                    $fatal(1, "MC-NOC-P0 phantom local response emission");
                end
                if (
                    local_resp_tag_o !== response_model_tag
                    || local_resp_line_addr_o !== response_model_line
                    || local_resp_fault_o !== response_model_fault
                ) begin
                    $fatal(1, "MC-NOC-P0 local response differs from scoreboard");
                end
                for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                    if (local_resp_data_o[word_index] !== response_model_data[word_index]) begin
                        $fatal(
                            1,
                            "MC-NOC-P0 local response scoreboard data mismatch word=%0d",
                            word_index
                        );
                    end
                end
                response_emit_count <= response_emit_count + 1;
            end

            if (response_accept) begin
                if (response_model_valid && !response_emit) begin
                    $fatal(1, "MC-NOC-P0 response hold overflow");
                end
                if (
                    noc_resp_network_tag_i[
                        NETWORK_TAG_W-1
                        -: CLUSTER_ID_W
                    ] !== THIS_CLUSTER_ID
                    || integer'(
                        noc_resp_network_tag_i[
                            CLUSTER_LOCAL_TAG_W-1
                            -: CU_ID_W
                        ]
                    ) >= CUS_PER_CLUSTER
                ) begin
                    $fatal(1, "MC-NOC-P0 malformed network response handshook");
                end
                response_accept_count <= response_accept_count + 1;
                response_model_valid <= 1'b1;
                response_model_tag <=
                    noc_resp_network_tag_i[CLUSTER_LOCAL_TAG_W-1:0];
                response_model_line <= noc_resp_line_addr_i;
                response_model_fault <= noc_resp_fault_i;
                for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                    response_model_data[word_index] <= noc_resp_data_i[word_index];
                end
            end else if (response_emit) begin
                response_model_valid <= 1'b0;
            end
        end
    end


    always @(posedge clk) begin : p_settled_black_box_invariants
        #1;
        if (rst_n) begin
            if (noc_req_valid_o !== request_model_valid) begin
                $fatal(1, "MC-NOC-P0 request valid/model occupancy mismatch");
            end
            if (local_resp_valid_o !== response_model_valid) begin
                $fatal(1, "MC-NOC-P0 response valid/model occupancy mismatch");
            end
            if (
                request_accept_count
                != request_emit_count + (request_model_valid ? 1 : 0)
            ) begin
                $fatal(1, "MC-NOC-P0 request conservation mismatch");
            end
            if (
                response_accept_count
                != response_emit_count + (response_model_valid ? 1 : 0)
            ) begin
                $fatal(1, "MC-NOC-P0 response conservation mismatch");
            end
            if (
                noc_req_valid_o
                && noc_req_network_tag_o[
                    NETWORK_TAG_W-1
                    -: CLUSTER_ID_W
                ] !== THIS_CLUSTER_ID
            ) begin
                $fatal(1, "MC-NOC-P0 emitted request has wrong cluster prefix");
            end
        end
    end


    task automatic run_parameter_smoke;
        integer word_index;
        integer smoke_local_tag;
        logic [LINE_ADDR_W-1:0] request_line;
        logic [LINE_ADDR_W-1:0] response_line;
        logic [31:0] response_seed;
        begin
            smoke_local_tag =
                (MSHR_COUNT == 1)
                    ? LOCAL_TAG_ENCODING_COUNT - 1
                    : MSHR_COUNT - 1;
            request_line = LINE_ADDR_W'(29'h0123_4567);
            response_line = LINE_ADDR_W'(29'h0234_5678);
            response_seed = 32'h5a00_1000;

            reset_epoch();
            check_alt_idle();

            noc_req_ready_i = 1'b0;
            @(negedge clk);
            set_main_request(
                CUS_PER_CLUSTER - 1,
                smoke_local_tag,
                request_line
            );
            #1;
            if (!local_req_ready_o || local_req_tag_error_o) begin
                $fatal(1, "MC-NOC-P0 parameter smoke request not ready");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            #1;
            if (
                !noc_req_valid_o
                || noc_req_network_tag_o
                    !== make_network_tag(
                        CLUSTER_ID,
                        CUS_PER_CLUSTER - 1,
                        smoke_local_tag
                    )
                || noc_req_line_addr_o !== request_line
            ) begin
                $fatal(1, "MC-NOC-P0 parameter smoke request mismatch");
            end
            noc_req_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (noc_req_valid_o) begin
                $fatal(1, "MC-NOC-P0 parameter smoke request did not drain");
            end

            local_resp_ready_i = 1'b0;
            @(negedge clk);
            set_main_response(
                CLUSTER_ID,
                CUS_PER_CLUSTER - 1,
                smoke_local_tag,
                response_line,
                1'b1,
                response_seed
            );
            #1;
            if (!noc_resp_ready_o || noc_resp_tag_error_o) begin
                $fatal(1, "MC-NOC-P0 parameter smoke response not ready");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            #1;
            if (
                !local_resp_valid_o
                || local_resp_tag_o
                    !== make_local_tag(
                        CUS_PER_CLUSTER - 1,
                        smoke_local_tag
                    )
                || local_resp_line_addr_o !== response_line
                || !local_resp_fault_o
            ) begin
                $fatal(1, "MC-NOC-P0 parameter smoke response mismatch");
            end
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                if (
                    local_resp_data_o[word_index]
                    !== response_seed + 32'(word_index)
                ) begin
                    $fatal(1, "MC-NOC-P0 parameter smoke data mismatch");
                end
            end
            local_resp_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                noc_req_valid_o
                || local_resp_valid_o
                || request_model_valid
                || response_model_valid
                || request_accept_count != request_emit_count
                || response_accept_count != response_emit_count
            ) begin
                $fatal(1, "MC-NOC-P0 parameter smoke did not drain");
            end

            $display("MC_NOC_P0_PARAMETER_SMOKE=PASS");
            $finish;
        end
    endtask


    task automatic run_full_scenarios;
        integer word_index;
        integer stall_cycle;
        integer cluster_index;
        integer cu_index;
        integer tag_index;
        integer tuple_count;
        logic [NETWORK_TAG_W-1:0] held_request_tag;
        logic [LINE_ADDR_W-1:0] held_request_line;
        logic [CLUSTER_LOCAL_TAG_W-1:0] held_response_tag;
        logic [LINE_ADDR_W-1:0] held_response_line;
        logic held_response_fault;
        logic [31:0] held_response_data [0:LINE_WORDS-1];
        logic [NETWORK_TAG_W-1:0] first_network_tag;
        logic [NETWORK_TAG_W-1:0] second_network_tag;
        logic [NETWORK_TAG_W-1:0] codec_tag;
        logic [NETWORK_TAG_SPACE-1:0] codec_seen;
        logic [LINE_ADDR_W-1:0] line_a;
        logic [LINE_ADDR_W-1:0] line_b;
        logic [LINE_ADDR_W-1:0] line_c;
        logic [LINE_ADDR_W-1:0] line_d;
        begin
            if (
                CLUSTER_COUNT != 3
                || CLUSTER_ID != 1
                || CUS_PER_CLUSTER != 3
                || MSHR_COUNT != 2
            ) begin
                $fatal(1, "MC-NOC-P0 full scenarios require K3 U3 M2 ID1");
            end

            line_a = LINE_ADDR_W'(29'h0012_3456);
            line_b = LINE_ADDR_W'(29'h0023_4567);
            line_c = LINE_ADDR_W'(29'h0034_5678);
            line_d = LINE_ADDR_W'(29'h0045_6789);

            reset_epoch();
            if (
                noc_req_valid_o
                || local_resp_valid_o
                || local_req_tag_error_o
                || noc_resp_tag_error_o
            ) begin
                $fatal(1, "MC-NOC-P0 reset/idle outputs not empty");
            end
            check_alt_idle();
            $display("MC_NOC_P0_01_RESET_IDLE=PASS");

            noc_req_ready_i = 1'b0;
            @(negedge clk);
            set_main_request(2, 1, line_a);
            #1;
            if (!local_req_ready_o || local_req_tag_error_o) begin
                $fatal(1, "MC-NOC-P0 legal local request was not ready");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            #1;
            if (request_accept_count != 1 || !request_model_valid) begin
                $fatal(1, "MC-NOC-P0 local request was not accepted");
            end
            $display("MC_NOC_P0_02_LOCAL_REQUEST_ACCEPTED=PASS");

            if (
                noc_req_network_tag_o[
                    NETWORK_TAG_W-1
                    -: CLUSTER_ID_W
                ] !== THIS_CLUSTER_ID
            ) begin
                $fatal(1, "MC-NOC-P0 request cluster ID was not added");
            end
            $display("MC_NOC_P0_03_REQUEST_CLUSTER_ID_ADDED=PASS");

            if (
                noc_req_network_tag_o[CLUSTER_LOCAL_TAG_W-1:0]
                !== make_local_tag(2, 1)
            ) begin
                $fatal(1, "MC-NOC-P0 request CU/local tag changed");
            end
            $display("MC_NOC_P0_04_REQUEST_CU_LOCAL_TAG_PRESERVED=PASS");

            if (noc_req_line_addr_o !== line_a) begin
                $fatal(1, "MC-NOC-P0 request line address changed");
            end
            $display("MC_NOC_P0_05_REQUEST_LINE_ADDR_PRESERVED=PASS");

            if (!noc_req_valid_o) begin
                $fatal(1, "MC-NOC-P0 request hold was not created");
            end
            held_request_tag = noc_req_network_tag_o;
            held_request_line = noc_req_line_addr_o;
            $display("MC_NOC_P0_06_REQUEST_HOLD_CREATED=PASS");

            if (
                !noc_req_valid_o
                || noc_req_ready_i
                || local_req_ready_o
            ) begin
                $fatal(1, "MC-NOC-P0 request stall visibility is wrong");
            end
            $display("MC_NOC_P0_07_REQUEST_STALL_VALID_HELD=PASS");

            set_main_request(0, 0, line_d);
            for (stall_cycle = 0; stall_cycle < 3; stall_cycle = stall_cycle + 1) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    !noc_req_valid_o
                    || local_req_ready_o
                    || noc_req_network_tag_o !== held_request_tag
                    || noc_req_line_addr_o !== held_request_line
                    || request_accept_count != 1
                ) begin
                    $fatal(1, "MC-NOC-P0 request payload changed while stalled");
                end
            end
            $display("MC_NOC_P0_08_REQUEST_STALL_PAYLOAD_STABLE=PASS");

            local_req_valid_i = 1'b0;
            noc_req_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                noc_req_valid_o
                || request_model_valid
                || request_accept_count != 1
                || request_emit_count != 1
            ) begin
                $fatal(1, "MC-NOC-P0 request did not drain exactly once");
            end
            $display("MC_NOC_P0_09_REQUEST_EXACTLY_ONCE_DRAIN=PASS");

            reset_epoch();
            noc_req_ready_i = 1'b1;
            @(negedge clk);
            set_main_request(0, 0, line_a);
            #1;
            if (!local_req_ready_o) begin
                $fatal(1, "MC-NOC-P0 first back-to-back request not ready");
            end
            @(posedge clk);
            @(negedge clk);
            set_main_request(1, 1, line_b);
            #1;
            if (
                !noc_req_valid_o
                || !noc_req_ready_i
                || !local_req_ready_o
                || noc_req_network_tag_o !== make_network_tag(CLUSTER_ID, 0, 0)
            ) begin
                $fatal(1, "MC-NOC-P0 request turnover precondition missing");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            #1;
            if (
                request_accept_count != 2
                || request_emit_count != 1
                || !noc_req_valid_o
            ) begin
                $fatal(1, "MC-NOC-P0 back-to-back requests were not accepted");
            end
            $display("MC_NOC_P0_10_REQUEST_BACK_TO_BACK=PASS");

            if (
                noc_req_network_tag_o !== make_network_tag(CLUSTER_ID, 1, 1)
                || noc_req_line_addr_o !== line_b
            ) begin
                $fatal(1, "MC-NOC-P0 request same-cycle replacement failed");
            end
            $display("MC_NOC_P0_11_REQUEST_SAME_CYCLE_TURNOVER=PASS");

            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                noc_req_valid_o
                || request_model_valid
                || request_accept_count != 2
                || request_emit_count != 2
            ) begin
                $fatal(1, "MC-NOC-P0 request conservation failed");
            end
            $display("MC_NOC_P0_12_REQUEST_CONSERVATION=PASS");

            reset_epoch();
            local_resp_ready_i = 1'b0;
            @(negedge clk);
            set_main_response(
                CLUSTER_ID,
                2,
                1,
                line_c,
                1'b1,
                32'h6100_0000
            );
            #1;
            if (!noc_resp_ready_o || noc_resp_tag_error_o) begin
                $fatal(1, "MC-NOC-P0 legal network response was not ready");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            #1;
            if (response_accept_count != 1 || !response_model_valid) begin
                $fatal(1, "MC-NOC-P0 addressed response was not accepted");
            end
            $display("MC_NOC_P0_13_ADDRESSED_RESPONSE_ACCEPTED=PASS");

            if (local_resp_tag_o !== make_local_tag(2, 1)) begin
                $fatal(1, "MC-NOC-P0 response CU/local tag was not restored");
            end
            $display("MC_NOC_P0_14_RESPONSE_CU_LOCAL_TAG_RESTORED=PASS");

            if (local_resp_line_addr_o !== line_c) begin
                $fatal(1, "MC-NOC-P0 response line address changed");
            end
            $display("MC_NOC_P0_15_RESPONSE_LINE_ADDR_PRESERVED=PASS");

            if (!local_resp_fault_o) begin
                $fatal(1, "MC-NOC-P0 response fault bit changed");
            end
            $display("MC_NOC_P0_16_RESPONSE_FAULT_PRESERVED=PASS");

            check_main_response_data(32'h6100_0000);
            $display("MC_NOC_P0_17_RESPONSE_LINE_DATA_PRESERVED=PASS");

            if (!local_resp_valid_o) begin
                $fatal(1, "MC-NOC-P0 response hold was not created");
            end
            held_response_tag = local_resp_tag_o;
            held_response_line = local_resp_line_addr_o;
            held_response_fault = local_resp_fault_o;
            for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                held_response_data[word_index] = local_resp_data_o[word_index];
            end
            $display("MC_NOC_P0_18_RESPONSE_HOLD_CREATED=PASS");

            if (
                !local_resp_valid_o
                || local_resp_ready_i
                || noc_resp_ready_o
            ) begin
                $fatal(1, "MC-NOC-P0 response stall visibility is wrong");
            end
            $display("MC_NOC_P0_19_RESPONSE_STALL_VALID_HELD=PASS");

            set_main_response(
                CLUSTER_ID,
                0,
                0,
                line_d,
                1'b0,
                32'hde00_0000
            );
            for (stall_cycle = 0; stall_cycle < 3; stall_cycle = stall_cycle + 1) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    !local_resp_valid_o
                    || noc_resp_ready_o
                    || local_resp_tag_o !== held_response_tag
                    || local_resp_line_addr_o !== held_response_line
                    || local_resp_fault_o !== held_response_fault
                    || response_accept_count != 1
                ) begin
                    $fatal(1, "MC-NOC-P0 response payload changed while stalled");
                end
                for (word_index = 0; word_index < LINE_WORDS; word_index = word_index + 1) begin
                    if (local_resp_data_o[word_index] !== held_response_data[word_index]) begin
                        $fatal(1, "MC-NOC-P0 stalled response data changed");
                    end
                end
            end
            $display("MC_NOC_P0_20_RESPONSE_STALL_PAYLOAD_STABLE=PASS");

            noc_resp_valid_i = 1'b0;
            local_resp_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                local_resp_valid_o
                || response_model_valid
                || response_accept_count != 1
                || response_emit_count != 1
            ) begin
                $fatal(1, "MC-NOC-P0 response did not drain exactly once");
            end
            $display("MC_NOC_P0_21_RESPONSE_EXACTLY_ONCE_DRAIN=PASS");

            reset_epoch();
            local_resp_ready_i = 1'b1;
            @(negedge clk);
            set_main_response(
                CLUSTER_ID,
                0,
                0,
                line_a,
                1'b0,
                32'h6200_0000
            );
            #1;
            if (!noc_resp_ready_o) begin
                $fatal(1, "MC-NOC-P0 first turnover response not ready");
            end
            @(posedge clk);
            @(negedge clk);
            set_main_response(
                CLUSTER_ID,
                1,
                1,
                line_b,
                1'b1,
                32'h6300_0000
            );
            #1;
            if (
                !local_resp_valid_o
                || !local_resp_ready_i
                || !noc_resp_ready_o
                || local_resp_tag_o !== make_local_tag(0, 0)
            ) begin
                $fatal(1, "MC-NOC-P0 response turnover precondition missing");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            #1;
            if (
                response_accept_count != 2
                || response_emit_count != 1
                || !local_resp_valid_o
                || local_resp_tag_o !== make_local_tag(1, 1)
                || local_resp_line_addr_o !== line_b
                || !local_resp_fault_o
            ) begin
                $fatal(1, "MC-NOC-P0 response same-cycle replacement failed");
            end
            check_main_response_data(32'h6300_0000);
            $display("MC_NOC_P0_22_RESPONSE_SAME_CYCLE_TURNOVER=PASS");
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            local_resp_ready_i = 1'b1;
            @(negedge clk);
            set_main_response(
                0,
                0,
                0,
                line_a,
                1'b0,
                32'h6400_0000
            );
            #1;
            if (
                noc_resp_ready_o
                || !noc_resp_tag_error_o
                || local_resp_valid_o
            ) begin
                $fatal(1, "MC-NOC-P0 wrong legal cluster was not rejected");
            end
            repeat (2) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    noc_resp_ready_o
                    || !noc_resp_tag_error_o
                    || local_resp_valid_o
                    || response_accept_count != 0
                ) begin
                    $fatal(1, "MC-NOC-P0 wrong-cluster response changed state");
                end
            end
            $display("MC_NOC_P0_23_WRONG_LEGAL_CLUSTER_NOT_ACCEPTED=PASS");

            noc_resp_valid_i = 1'b0;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                local_resp_valid_o
                || noc_resp_tag_error_o
                || response_accept_count != 0
                || response_emit_count != 0
            ) begin
                $fatal(1, "MC-NOC-P0 wrong-cluster response caused delivery");
            end
            $display("MC_NOC_P0_24_WRONG_LEGAL_CLUSTER_NO_LOCAL_DELIVERY=PASS");

            @(negedge clk);
            set_main_response(
                CLUSTER_COUNT,
                0,
                0,
                line_b,
                1'b0,
                32'h6500_0000
            );
            #1;
            if (
                noc_resp_ready_o
                || !noc_resp_tag_error_o
                || local_resp_valid_o
            ) begin
                $fatal(1, "MC-NOC-P0 unused cluster encoding was not rejected");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            #1;
            if (local_resp_valid_o || response_accept_count != 0) begin
                $fatal(1, "MC-NOC-P0 unused cluster encoding was captured");
            end
            $display("MC_NOC_P0_25_UNUSED_CLUSTER_ENCODING_NOT_ACCEPTED=PASS");

            @(negedge clk);
            set_main_response(
                CLUSTER_ID,
                CUS_PER_CLUSTER,
                0,
                line_c,
                1'b0,
                32'h6600_0000
            );
            #1;
            if (
                noc_resp_ready_o
                || !noc_resp_tag_error_o
                || local_resp_valid_o
            ) begin
                $fatal(1, "MC-NOC-P0 unused CU encoding was not rejected");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            #1;
            if (local_resp_valid_o || response_accept_count != 0) begin
                $fatal(1, "MC-NOC-P0 unused CU encoding was captured");
            end
            $display("MC_NOC_P0_26_UNUSED_CU_ENCODING_NOT_ACCEPTED=PASS");

            repeat (2) @(posedge clk);
            @(negedge clk);
            #1;
            if (
                local_resp_valid_o
                || response_model_valid
                || response_accept_count != 0
                || response_emit_count != 0
            ) begin
                $fatal(1, "MC-NOC-P0 malformed response caused phantom delivery");
            end
            $display("MC_NOC_P0_27_INVALID_IDS_NO_LOCAL_DELIVERY=PASS");

            noc_req_ready_i = 1'b1;
            @(negedge clk);
            set_main_request(CUS_PER_CLUSTER, 0, line_d);
            #1;
            if (
                local_req_ready_o
                || !local_req_tag_error_o
                || noc_req_valid_o
            ) begin
                $fatal(1, "MC-NOC-P0 invalid local CU was not rejected");
            end
            repeat (2) begin
                @(posedge clk);
                @(negedge clk);
                #1;
                if (
                    local_req_ready_o
                    || !local_req_tag_error_o
                    || noc_req_valid_o
                    || request_accept_count != 0
                ) begin
                    $fatal(1, "MC-NOC-P0 invalid local CU changed state");
                end
            end
            local_req_valid_i = 1'b0;
            @(posedge clk);
            @(negedge clk);
            #1;
            if (
                noc_req_valid_o
                || local_req_tag_error_o
                || request_model_valid
                || request_accept_count != 0
                || request_emit_count != 0
            ) begin
                $fatal(1, "MC-NOC-P0 invalid local CU caused phantom request");
            end
            $display("MC_NOC_P0_28_INVALID_LOCAL_REQUEST_CU_REJECTED=PASS");

            reset_epoch();
            local_resp_ready_i = 1'b0;
            @(negedge clk);
            set_main_response(
                CLUSTER_ID,
                2,
                1,
                line_c,
                1'b0,
                32'h6700_0000
            );
            #1;
            if (!noc_resp_ready_o) begin
                $fatal(1, "MC-NOC-P0 concurrency response preload not ready");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            noc_req_ready_i = 1'b0;
            local_resp_ready_i = 1'b1;
            set_main_request(1, 0, line_b);
            #1;
            if (
                !local_req_ready_o
                || !local_resp_valid_o
                || !local_resp_ready_i
            ) begin
                $fatal(1, "MC-NOC-P0 request/response independent progress missing");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            #1;
            if (
                !noc_req_valid_o
                || local_resp_valid_o
                || request_accept_count != 1
                || response_emit_count != 1
            ) begin
                $fatal(1, "MC-NOC-P0 directional independence failed");
            end
            $display("MC_NOC_P0_29_REQUEST_RESPONSE_INDEPENDENT_PROGRESS=PASS");
            noc_req_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            noc_req_ready_i = 1'b0;
            @(negedge clk);
            set_main_request(0, 0, line_a);
            #1;
            if (!local_req_ready_o) begin
                $fatal(1, "MC-NOC-P0 simultaneous test request preload failed");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            local_resp_ready_i = 1'b0;
            set_main_response(
                CLUSTER_ID,
                0,
                0,
                line_c,
                1'b0,
                32'h6800_0000
            );
            #1;
            if (!noc_resp_ready_o) begin
                $fatal(1, "MC-NOC-P0 simultaneous test response preload failed");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            noc_req_ready_i = 1'b1;
            local_resp_ready_i = 1'b1;
            set_main_request(1, 1, line_b);
            set_main_response(
                CLUSTER_ID,
                2,
                1,
                line_d,
                1'b1,
                32'h6900_0000
            );
            #1;
            if (
                !(noc_req_valid_o && noc_req_ready_i)
                || !(local_req_valid_i && local_req_ready_o)
                || !(local_resp_valid_o && local_resp_ready_i)
                || !(noc_resp_valid_i && noc_resp_ready_o)
            ) begin
                $fatal(1, "MC-NOC-P0 simultaneous handshakes not co-visible");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            noc_resp_valid_i = 1'b0;
            #1;
            if (
                request_accept_count != 2
                || request_emit_count != 1
                || response_accept_count != 2
                || response_emit_count != 1
                || noc_req_network_tag_o
                    !== make_network_tag(CLUSTER_ID, 1, 1)
                || local_resp_tag_o !== make_local_tag(2, 1)
                || local_resp_line_addr_o !== line_d
                || !local_resp_fault_o
            ) begin
                $fatal(1, "MC-NOC-P0 simultaneous handshake turnover failed");
            end
            check_main_response_data(32'h6900_0000);
            $display("MC_NOC_P0_30_SIMULTANEOUS_REQUEST_RESPONSE_HANDSHAKES=PASS");
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            noc_req_ready_i = 1'b0;
            @(negedge clk);
            set_main_request(2, 0, line_a);
            #1;
            if (!local_req_ready_o) begin
                $fatal(1, "MC-NOC-P0 reset-request preload not ready");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            #1;
            if (!noc_req_valid_o) begin
                $fatal(1, "MC-NOC-P0 reset-request hold missing");
            end
            @(negedge clk);
            rst_n = 1'b0;
            #1;
            if (noc_req_valid_o) begin
                $fatal(1, "MC-NOC-P0 request valid not gated during reset");
            end
            @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            if (
                noc_req_valid_o
                || request_model_valid
                || request_accept_count != 0
                || request_emit_count != 0
            ) begin
                $fatal(1, "MC-NOC-P0 reset did not flush held request");
            end
            $display("MC_NOC_P0_31_RESET_FLUSHES_HELD_REQUEST=PASS");

            reset_epoch();
            local_resp_ready_i = 1'b0;
            @(negedge clk);
            set_main_response(
                CLUSTER_ID,
                1,
                0,
                line_b,
                1'b0,
                32'h6a00_0000
            );
            #1;
            if (!noc_resp_ready_o) begin
                $fatal(1, "MC-NOC-P0 reset-response preload not ready");
            end
            @(posedge clk);
            @(negedge clk);
            noc_resp_valid_i = 1'b0;
            #1;
            if (!local_resp_valid_o) begin
                $fatal(1, "MC-NOC-P0 reset-response hold missing");
            end
            @(negedge clk);
            rst_n = 1'b0;
            #1;
            if (local_resp_valid_o) begin
                $fatal(1, "MC-NOC-P0 response valid not gated during reset");
            end
            @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            if (
                local_resp_valid_o
                || response_model_valid
                || response_accept_count != 0
                || response_emit_count != 0
            ) begin
                $fatal(1, "MC-NOC-P0 reset did not flush held response");
            end
            $display("MC_NOC_P0_32_RESET_FLUSHES_HELD_RESPONSE=PASS");

            reset_epoch();
            noc_req_ready_i = 1'b0;
            @(negedge clk);
            set_main_request(0, 1, line_a);
            #1;
            if (!local_req_ready_o) begin
                $fatal(1, "MC-NOC-P0 first codec request not ready");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            #1;
            first_network_tag = noc_req_network_tag_o;
            noc_req_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            noc_req_ready_i = 1'b0;
            set_main_request(2, 1, line_b);
            #1;
            if (!local_req_ready_o) begin
                $fatal(1, "MC-NOC-P0 second codec request not ready");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            #1;
            second_network_tag = noc_req_network_tag_o;
            if (
                first_network_tag === second_network_tag
                || first_network_tag[LOCAL_TAG_W-1:0]
                    !== second_network_tag[LOCAL_TAG_W-1:0]
            ) begin
                $fatal(1, "MC-NOC-P0 CU identity did not disambiguate equal local tags");
            end
            $display("MC_NOC_P0_33_SAME_LOCAL_TAG_DIFFERENT_CU_DISTINCT=PASS");
            noc_req_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;

            reset_epoch();
            noc_req_ready_i = 1'b0;
            alt_noc_req_ready_i = 1'b0;
            @(negedge clk);
            set_main_request(1, 1, line_c);
            set_alt_request(1, 1, line_c);
            #1;
            if (
                !local_req_ready_o
                || !alt_local_req_ready_o
                || local_req_tag_error_o
                || alt_local_req_tag_error_o
            ) begin
                $fatal(1, "MC-NOC-P0 two-endpoint codec requests not ready");
            end
            @(posedge clk);
            @(negedge clk);
            local_req_valid_i = 1'b0;
            alt_local_req_valid_i = 1'b0;
            #1;
            if (
                !noc_req_valid_o
                || !alt_noc_req_valid_o
                || noc_req_network_tag_o === alt_noc_req_network_tag_o
                || noc_req_network_tag_o[CLUSTER_LOCAL_TAG_W-1:0]
                    !== alt_noc_req_network_tag_o[CLUSTER_LOCAL_TAG_W-1:0]
                || noc_req_network_tag_o[
                    NETWORK_TAG_W-1
                    -: CLUSTER_ID_W
                ] !== THIS_CLUSTER_ID
                || alt_noc_req_network_tag_o[
                    NETWORK_TAG_W-1
                    -: CLUSTER_ID_W
                ] !== ALT_THIS_CLUSTER_ID
            ) begin
                $fatal(1, "MC-NOC-P0 cluster identity did not disambiguate equal local tags");
            end
            $display("MC_NOC_P0_34_SAME_CU_TAG_DIFFERENT_CLUSTER_DISTINCT=PASS");
            noc_req_ready_i = 1'b1;
            alt_noc_req_ready_i = 1'b1;
            @(posedge clk);
            @(negedge clk);
            #1;

            codec_seen = '0;
            tuple_count = 0;
            for (
                cluster_index = 0;
                cluster_index < CLUSTER_COUNT;
                cluster_index = cluster_index + 1
            ) begin
                for (
                    cu_index = 0;
                    cu_index < CUS_PER_CLUSTER;
                    cu_index = cu_index + 1
                ) begin
                    for (
                        tag_index = 0;
                        tag_index < MSHR_COUNT;
                        tag_index = tag_index + 1
                    ) begin
                        codec_tag = make_network_tag(
                            cluster_index,
                            cu_index,
                            tag_index
                        );
                        if (codec_seen[codec_tag]) begin
                            $fatal(1, "MC-NOC-P0 legal network-tag collision");
                        end
                        codec_seen[codec_tag] = 1'b1;
                        tuple_count = tuple_count + 1;
                        if (
                            codec_tag[
                                NETWORK_TAG_W-1
                                -: CLUSTER_ID_W
                            ] !== CLUSTER_ID_W'(cluster_index)
                            || codec_tag[
                                CLUSTER_LOCAL_TAG_W-1
                                -: CU_ID_W
                            ] !== CU_ID_W'(cu_index)
                            || codec_tag[LOCAL_TAG_W-1:0]
                                !== LOCAL_TAG_W'(tag_index)
                        ) begin
                            $fatal(1, "MC-NOC-P0 legal network-tag round trip failed");
                        end
                    end
                end
            end
            if (tuple_count != CLUSTER_COUNT * CUS_PER_CLUSTER * MSHR_COUNT) begin
                $fatal(1, "MC-NOC-P0 exhaustive codec tuple count mismatch");
            end
            codec_tag = make_network_tag(
                CLUSTER_COUNT - 1,
                CUS_PER_CLUSTER - 1,
                MSHR_COUNT - 1
            );
            if (
                codec_tag[
                    NETWORK_TAG_W-1
                    -: CLUSTER_ID_W
                ] !== CLUSTER_ID_W'(CLUSTER_COUNT - 1)
                || codec_tag[
                    CLUSTER_LOCAL_TAG_W-1
                    -: CU_ID_W
                ] !== CU_ID_W'(CUS_PER_CLUSTER - 1)
                || codec_tag[LOCAL_TAG_W-1:0]
                    !== LOCAL_TAG_W'(MSHR_COUNT - 1)
            ) begin
                $fatal(1, "MC-NOC-P0 maximum legal codec tuple failed");
            end
            $display("MC_NOC_P0_35_CODEC_ALL_LEGAL_AND_MAX_ROUND_TRIP=PASS");

            repeat (3) @(posedge clk);
            @(negedge clk);
            #1;
            if (
                noc_req_valid_o
                || local_resp_valid_o
                || request_model_valid
                || response_model_valid
                || request_accept_count != request_emit_count
                || response_accept_count != response_emit_count
                || local_req_tag_error_o
                || noc_resp_tag_error_o
                || alt_noc_req_valid_o
                || alt_local_resp_valid_o
            ) begin
                $fatal(1, "MC-NOC-P0 final conservation/drain failed");
            end
            check_alt_idle();
            $display("MC_NOC_P0_36_FINAL_CONSERVATION_AND_DRAIN=PASS");
            $finish;
        end
    endtask


    initial begin
        rst_n = 1'b0;
        clear_inputs();

        if (FULL_SCENARIOS) begin
            run_full_scenarios();
        end else begin
            run_parameter_smoke();
        end
    end

endmodule
