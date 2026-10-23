`timescale 1ns/1ps

module a0_memory_drain_fence_controller_tb #(parameter integer VARIANT = 0);
    localparam integer SOURCE_W = 4, CONTEXT_W = 4, REQUEST_ID_W = 8, GENERATION_W = 2;
    localparam integer COMMIT_PORT_COUNT = VARIANT + 2, STORE_LANES = VARIANT + 1;
    logic clk, rst_n;
    logic fence_req_valid_i, fence_req_ready_o;
    logic [SOURCE_W-1:0] fence_req_source_i, fence_resp_source_o;
    logic [CONTEXT_W-1:0] fence_req_context_i, fence_resp_context_o;
    logic [REQUEST_ID_W-1:0] fence_req_request_id_i, fence_resp_request_id_o;
    logic [GENERATION_W-1:0] fence_req_generation_i, fence_resp_generation_o;
    logic fence_req_acquire_i, fence_req_release_i;
    logic fence_resp_valid_o, fence_resp_ready_i, fence_resp_acquire_o, fence_resp_release_o;
    logic [4:0] fence_resp_fault_bits_o;
    logic [COMMIT_PORT_COUNT-1:0] commit_valid_i, store_complete_i, store_abort_i;
    logic [STORE_LANES-1:0] commit_lane_mask_i [0:COMMIT_PORT_COUNT-1];
    logic [31:0] commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic [31:0] commit_wdata_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic drain_quiet_i, inherited_protocol_error_i;
    logic read_fault_event_i, atomic_fault_event_i, store_fault_event_i, wb_terminal_failure_event_i;
    logic allow_new_o, fence_busy_o, fence_protocol_error_o;
    logic [COMMIT_PORT_COUNT-1:0] store_allow_o, fence_pending_store_o;
    logic expect_protocol_error;
    integer cycles, checks, scenarios, fences, responses, store_completions, store_aborts;
    integer faulted_responses, protocol_cases;

    a0_memory_drain_fence_controller #(
        .SOURCE_W(SOURCE_W), .CONTEXT_W(CONTEXT_W), .REQUEST_ID_W(REQUEST_ID_W),
        .GENERATION_W(GENERATION_W), .COMMIT_PORT_COUNT(COMMIT_PORT_COUNT), .STORE_LANES(STORE_LANES)
    ) dut (.*);

    initial begin clk = 0; forever #5 clk = ~clk; end
    task automatic check(input bit ok, input string detail);
        if (!ok) $fatal(1, "P36_FENCE_CHECK_FAILED cycle=%0d %s", cycles, detail);
        checks = checks + 1;
    endtask
    task automatic tick; @(negedge clk); #1; endtask
    task automatic mark(input string name);
        scenarios = scenarios + 1;
        $display("P36_FENCE_SCENARIO_PASS id=%0d name=%s", scenarios, name);
    endtask
    initial begin
        forever begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 3000) $fatal(1, "P36 fence component watchdog");
            if (rst_n) begin
                if (!expect_protocol_error) check(!fence_protocol_error_o, "unexpected protocol error");
                if (fence_req_valid_i && fence_req_ready_o) fences = fences + 1;
                if (fence_resp_valid_o && fence_resp_ready_i) begin
                    responses = responses + 1;
                    if (fence_resp_fault_bits_o != '0) faulted_responses = faulted_responses + 1;
                end
                for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
                    if (store_allow_o[p] && commit_valid_i[p] && store_complete_i[p])
                        store_completions = store_completions + 1;
                    if (store_allow_o[p] && commit_valid_i[p] && store_abort_i[p])
                        store_aborts = store_aborts + 1;
                end
                if (fence_resp_valid_o)
                    check(!allow_new_o && store_allow_o == '0 && fence_busy_o, "response holds admission boundary");
            end
        end
    end

    task automatic prepare_stores;
        begin
            commit_valid_i = '1;
            for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
                commit_lane_mask_i[p] = '1;
                // The final lane is deliberately inactive, including the
                // singleton variant, to prove full source-payload checking.
                commit_lane_mask_i[p][STORE_LANES-1] = 1'b0;
                for (integer l = 0; l < STORE_LANES; l = l + 1) begin
                    commit_word_addr_i[p][l] = 32'h1000 + 32'(p * 64 + l * 4);
                    commit_wdata_i[p][l] = 32'ha5000000 + 32'(p * 256 + l);
                end
            end
        end
    endtask
    task automatic prepare_fence(input logic [REQUEST_ID_W-1:0] id, input bit acquire, input bit release_order);
        begin
            fence_req_source_i = SOURCE_W'(id);
            fence_req_context_i = CONTEXT_W'(9);
            fence_req_request_id_i = id;
            fence_req_generation_i = GENERATION_W'(id);
            fence_req_acquire_i = acquire;
            fence_req_release_i = release_order;
        end
    endtask
    task automatic cut(input logic [REQUEST_ID_W-1:0] id, input bit acquire, input bit release_order);
        begin
            prepare_fence(id, acquire, release_order);
            fence_req_valid_i = 1;
            #1;
            check(fence_req_ready_o && !allow_new_o && store_allow_o == '1,
                "fence priority blocks new READ/atomic/epoch but forwards raw STORE at cut");
            tick();
            fence_req_valid_i = 0;
            check(fence_busy_o && !allow_new_o && !fence_resp_valid_o, "accepted boundary enters drain");
        end
    endtask
    task automatic check_response(input logic [REQUEST_ID_W-1:0] id, input bit acquire,
        input bit release_order, input logic [4:0] faults);
        begin
            check(fence_resp_valid_o && fence_resp_source_o == SOURCE_W'(id)
                && fence_resp_context_o == CONTEXT_W'(9) && fence_resp_request_id_o == id
                && fence_resp_generation_o == GENERATION_W'(id)
                && fence_resp_acquire_o == acquire && fence_resp_release_o == release_order
                && fence_resp_fault_bits_o == faults, "exact fence response identity/mode/fault");
        end
    endtask
    task automatic complete_response(input logic [REQUEST_ID_W-1:0] id, input bit acquire,
        input bit release_order, input logic [4:0] faults);
        integer bound;
        begin
            bound = 0;
            while (!fence_resp_valid_o) begin
                tick(); bound = bound + 1; check(bound < 12, "response after real drain");
            end
            check_response(id, acquire, release_order, faults);
            fence_resp_ready_i = 1;
            tick(); fence_resp_ready_i = 0;
            check(!fence_busy_o && !fence_resp_valid_o && allow_new_o && store_allow_o == '1,
                "response handshake releases admission on following cycle");
            tick();
        end
    endtask
    task automatic finish_pending_success;
        begin
            store_complete_i = fence_pending_store_o;
            tick();
            commit_valid_i = '0;
            store_complete_i = '0;
            check(fence_pending_store_o == '0 && !fence_resp_valid_o,
                "only terminal edge clears all enrolled stores; no same-edge response");
        end
    endtask
    task automatic reset_component;
        begin
            rst_n = 0;
            fence_req_valid_i = 0; fence_resp_ready_i = 0;
            commit_valid_i = '0; store_complete_i = '0; store_abort_i = '0;
            drain_quiet_i = 1; inherited_protocol_error_i = 0;
            read_fault_event_i = 0; atomic_fault_event_i = 0;
            store_fault_event_i = 0; wb_terminal_failure_event_i = 0;
            repeat (2) tick();
            rst_n = 1; expect_protocol_error = 0; tick();
            check(allow_new_o && !fence_busy_o && fence_req_ready_o && !fence_protocol_error_o,
                "global component reset only");
        end
    endtask
    task automatic check_fail_closed;
        begin
            tick();
            check(fence_protocol_error_o && fence_busy_o && !allow_new_o && !fence_resp_valid_o,
                "source/terminal protocol violation fails closed");
            commit_valid_i = '1; store_complete_i = fence_pending_store_o;
            tick(); store_complete_i = '0; commit_valid_i = '0;
            repeat (3) tick();
            check(fence_protocol_error_o && !fence_resp_valid_o && !fence_req_ready_o
                && fence_pending_store_o == '0, "terminal drain cannot repair sticky protocol failure");
            protocol_cases = protocol_cases + 1;
        end
    endtask

    initial begin
        cycles = 0; checks = 0; scenarios = 0; fences = 0; responses = 0;
        store_completions = 0; store_aborts = 0; faulted_responses = 0; protocol_cases = 0;
        expect_protocol_error = 0;
        fence_req_source_i = '0; fence_req_context_i = '0; fence_req_request_id_i = '0;
        fence_req_generation_i = '0; fence_req_acquire_i = 0; fence_req_release_i = 0;
        for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
            commit_lane_mask_i[p] = '0;
            for (integer l = 0; l < STORE_LANES; l = l + 1) begin
                commit_word_addr_i[p][l] = '0; commit_wdata_i[p][l] = '0;
            end
        end
        reset_component();

        cut(8'd1, 1, 0);
        check(fence_pending_store_o == '0, "empty acquire snapshot");
        complete_response(8'd1, 1, 0, 5'b00000);
        mark("EMPTY_ACQUIRE_EXACT_IDENTITY");

        prepare_stores(); drain_quiet_i = 0;
        cut(8'd2, 0, 1);
        check(fence_pending_store_o == '1 && store_allow_o == '1, "all raw ports enrolled");
        repeat (3) begin tick(); check(!fence_resp_valid_o && fence_pending_store_o == '1, "live drain waits"); end
        for (integer p = 0; p < COMMIT_PORT_COUNT; p = p + 1) begin
            store_complete_i = COMMIT_PORT_COUNT'(1) << p;
            tick(); store_complete_i = '0; commit_valid_i[p] = 0;
            check(!fence_pending_store_o[p] && !store_allow_o[p], "completed port cannot admit younger store");
        end
        check(fence_pending_store_o == '0 && !fence_resp_valid_o, "quiet remains independently required");
        repeat (2) tick(); drain_quiet_i = 1;
        complete_response(8'd2, 0, 1, 5'b00000);
        mark("RELEASE_ENROLLS_ALL_RAW_PORTS_AND_DRAINS_REAL_TERMINALS");

        prepare_stores(); drain_quiet_i = 0;
        store_complete_i = COMMIT_PORT_COUNT'(1);
        store_abort_i = COMMIT_PORT_COUNT'(2);
        cut(8'd3, 1, 1);
        check(fence_pending_store_o == (COMMIT_PORT_COUNT'('1) & ~COMMIT_PORT_COUNT'(3)),
            "same-edge success and separate abort excluded from pending");
        store_complete_i = '0; store_abort_i = '0; commit_valid_i[0] = 0; commit_valid_i[1] = 0;
        finish_pending_success(); drain_quiet_i = 1;
        complete_response(8'd3, 1, 1, 5'b00100);
        mark("SAME_EDGE_STORE_SUCCESS_AND_ABORT_ACCOUNTED_ONCE");

        cut(8'd4, 1, 0); tick();
        check_response(8'd4, 1, 0, 5'b00000);
        prepare_stores(); prepare_fence(8'd99, 0, 1); fence_req_valid_i = 1;
        read_fault_event_i = 1; atomic_fault_event_i = 1; store_fault_event_i = 1;
        wb_terminal_failure_event_i = 1;
        repeat (4) begin
            tick(); check_response(8'd4, 1, 0, 5'b00000);
            check(!fence_req_ready_o && store_allow_o == '0 && !allow_new_o, "younger offers held behind response");
        end
        fence_req_valid_i = 0; commit_valid_i = '0;
        read_fault_event_i = 0; atomic_fault_event_i = 0; store_fault_event_i = 0;
        wb_terminal_failure_event_i = 0;
        complete_response(8'd4, 1, 0, 5'b00000);
        mark("BACKPRESSURED_RESPONSE_STABLE_WITH_YOUNGER_REQUESTS_AND_EVENTS");

        prepare_stores(); commit_valid_i = COMMIT_PORT_COUNT'(1); drain_quiet_i = 0;
        store_fault_event_i = 1;
        cut(8'd5, 0, 1);
        repeat (3) begin
            tick(); check(fence_pending_store_o == COMMIT_PORT_COUNT'(1)
                && !fence_resp_valid_o, "held STORE fault is not fabricated abort");
        end
        store_abort_i = COMMIT_PORT_COUNT'(1); tick();
        store_abort_i = '0; commit_valid_i = '0; store_fault_event_i = 0;
        check(fence_pending_store_o == '0 && !fence_resp_valid_o, "actual abort cleared owner, recovery still live");
        repeat (2) tick(); drain_quiet_i = 1;
        complete_response(8'd5, 0, 1, 5'b00100);
        mark("STORE_FAULT_HELD_BEFORE_CUT_REQUIRES_REAL_ABORT_AND_RECOVERY");

        drain_quiet_i = 0;
        read_fault_event_i = 1; atomic_fault_event_i = 1;
        cut(8'd6, 1, 1);
        read_fault_event_i = 0; atomic_fault_event_i = 0;
        wb_terminal_failure_event_i = 1; store_fault_event_i = 1; tick();
        wb_terminal_failure_event_i = 0; store_fault_event_i = 0;
        repeat (2) tick(); drain_quiet_i = 1;
        complete_response(8'd6, 1, 1, 5'b01111);
        mark("CUT_AND_DRAIN_FAULTS_STICK_UNTIL_REAL_QUIET");

        cut(8'd7, 0, 0);
        complete_response(8'd7, 0, 0, 5'b10000);
        mark("INVALID_MODE_HAS_SEPARATE_ERROR_RESPONSE");

        read_fault_event_i = 1; atomic_fault_event_i = 1;
        store_fault_event_i = 1; wb_terminal_failure_event_i = 1; tick();
        read_fault_event_i = 0; atomic_fault_event_i = 0;
        store_fault_event_i = 0; wb_terminal_failure_event_i = 0;
        cut(8'd8, 0, 1);
        complete_response(8'd8, 0, 1, 5'b00000);
        check(fences == 8 && responses == 8 && faulted_responses == 4,
            "one response per accepted valid/invalid fence; faults do not taint next boundary");
        mark("HISTORICAL_OUTSIDE_EVENTS_DO_NOT_TAINT_NEXT_FENCE");

        prepare_stores(); commit_valid_i = COMMIT_PORT_COUNT'(1);
        cut(8'd9, 1, 0); expect_protocol_error = 1;
        commit_lane_mask_i[0][STORE_LANES-1] = ~commit_lane_mask_i[0][STORE_LANES-1];
        check_fail_closed(); mark("LANE_MASK_CHANGE_FAILS_CLOSED"); reset_component();

        prepare_stores(); commit_valid_i = COMMIT_PORT_COUNT'(1);
        cut(8'd10, 1, 0); expect_protocol_error = 1;
        commit_word_addr_i[0][STORE_LANES-1] = commit_word_addr_i[0][STORE_LANES-1] ^ 32'd4;
        check_fail_closed(); mark("INACTIVE_LANE_ADDRESS_CHANGE_FAILS_CLOSED"); reset_component();

        prepare_stores(); commit_valid_i = COMMIT_PORT_COUNT'(1);
        cut(8'd11, 1, 0); expect_protocol_error = 1;
        commit_wdata_i[0][STORE_LANES-1] = commit_wdata_i[0][STORE_LANES-1] ^ 32'd1;
        check_fail_closed(); mark("INACTIVE_LANE_DATA_CHANGE_FAILS_CLOSED"); reset_component();

        prepare_stores(); commit_valid_i = COMMIT_PORT_COUNT'(1);
        cut(8'd12, 1, 0); expect_protocol_error = 1; commit_valid_i = '0;
        check_fail_closed(); mark("SOURCE_WITHDRAWAL_CANNOT_COMPLETE_ENROLLED_STORE"); reset_component();

        prepare_stores(); commit_valid_i = COMMIT_PORT_COUNT'(1);
        cut(8'd13, 1, 0); expect_protocol_error = 1;
        store_complete_i = COMMIT_PORT_COUNT'(1); store_abort_i = COMMIT_PORT_COUNT'(1);
        check_fail_closed(); store_abort_i = '0;
        mark("SIMULTANEOUS_READY_ABORT_IS_PROTOCOL_FAILURE"); reset_component();

        cut(8'd14, 1, 0); expect_protocol_error = 1; inherited_protocol_error_i = 1;
        check_fail_closed(); inherited_protocol_error_i = 0;
        mark("INHERITED_PROTOCOL_FAILURE_PREVENTS_SUCCESS_RESPONSE");

        check(scenarios == 14 && fences == 14 && responses == 8 && protocol_cases == 6
            && faulted_responses == 4 && store_aborts == 3
            && store_completions == 2 * COMMIT_PORT_COUNT + 4,
            "exact accepted/response/terminal/error accounting");
        $display("P36_FENCE_CONTROLLER_PASS variant=%0d ports=%0d lanes=%0d scenarios=%0d checks=%0d fences=%0d responses=%0d completions=%0d aborts=%0d faulted=%0d protocol_cases=%0d",
            VARIANT, COMMIT_PORT_COUNT, STORE_LANES, scenarios, checks, fences, responses,
            store_completions, store_aborts, faulted_responses, protocol_cases);
        $finish;
    end
endmodule
