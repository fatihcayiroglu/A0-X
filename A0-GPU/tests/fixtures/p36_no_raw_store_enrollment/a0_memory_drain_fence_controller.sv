`timescale 1ns/1ps

// P36 instance-wide ordering boundary. A raw STORE offer has no admission
// handshake: every offer on the accepting fence edge belongs to its drain.
// READ/atomic/epoch acceptance is blocked on that edge. No domain is reset,
// no completion is synthesized, and dirty residency is not a flush request.
module a0_memory_drain_fence_controller #(
    parameter integer SOURCE_W = 4,
    parameter integer CONTEXT_W = 4,
    parameter integer REQUEST_ID_W = 8,
    parameter integer GENERATION_W = 2,
    parameter integer COMMIT_PORT_COUNT = 4,
    parameter integer STORE_LANES = 32
) (
    input logic clk,
    input logic rst_n,
    input logic fence_req_valid_i,
    output logic fence_req_ready_o,
    input logic [SOURCE_W-1:0] fence_req_source_i,
    input logic [CONTEXT_W-1:0] fence_req_context_i,
    input logic [REQUEST_ID_W-1:0] fence_req_request_id_i,
    input logic [GENERATION_W-1:0] fence_req_generation_i,
    input logic fence_req_acquire_i,
    input logic fence_req_release_i,
    output logic fence_resp_valid_o,
    input logic fence_resp_ready_i,
    output logic [SOURCE_W-1:0] fence_resp_source_o,
    output logic [CONTEXT_W-1:0] fence_resp_context_o,
    output logic [REQUEST_ID_W-1:0] fence_resp_request_id_o,
    output logic [GENERATION_W-1:0] fence_resp_generation_o,
    output logic fence_resp_acquire_o,
    output logic fence_resp_release_o,
    // bit0 READ, bit1 atomic, bit2 STORE, bit3 WB, bit4 invalid mode.
    output logic [4:0] fence_resp_fault_bits_o,
    input logic [COMMIT_PORT_COUNT-1:0] commit_valid_i,
    input logic [STORE_LANES-1:0] commit_lane_mask_i [0:COMMIT_PORT_COUNT-1],
    input logic [31:0] commit_word_addr_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],
    input logic [31:0] commit_wdata_i [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1],
    input logic [COMMIT_PORT_COUNT-1:0] store_complete_i,
    input logic [COMMIT_PORT_COUNT-1:0] store_abort_i,
    input logic drain_quiet_i,
    input logic inherited_protocol_error_i,
    input logic read_fault_event_i,
    input logic atomic_fault_event_i,
    input logic store_fault_event_i,
    input logic wb_terminal_failure_event_i,
    output logic allow_new_o,
    output logic [COMMIT_PORT_COUNT-1:0] store_allow_o,
    output logic fence_busy_o,
    output logic fence_protocol_error_o,
    output logic [COMMIT_PORT_COUNT-1:0] fence_pending_store_o
);
    typedef enum logic [1:0] {IDLE, DRAIN, RESPONSE} state_t;
    state_t state_q;
    logic [COMMIT_PORT_COUNT-1:0] pending_q;
    logic [STORE_LANES-1:0] lane_mask_q [0:COMMIT_PORT_COUNT-1];
    logic [31:0] word_addr_q [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic [31:0] wdata_q [0:COMMIT_PORT_COUNT-1][0:STORE_LANES-1];
    logic fence_fire, current_protocol_error;
    logic [4:0] fault_events;

    initial begin
        if (SOURCE_W < 1 || CONTEXT_W < 1 || REQUEST_ID_W < 1
            || GENERATION_W < 1 || COMMIT_PORT_COUNT < 1 || STORE_LANES < 1)
            $fatal(1, "P36 fence geometry must be positive");
    end

    assign fence_req_ready_o = rst_n && state_q == IDLE && !fence_protocol_error_o;
    assign fence_fire = fence_req_valid_i && fence_req_ready_o;
    // This predicate is independent of child ready. Raw STOREs still pass
    // on the cut edge so every offered port can join the predecessor set.
    assign allow_new_o = rst_n && state_q == IDLE
        && !fence_req_valid_i && !fence_protocol_error_o;
    assign fence_busy_o = state_q != IDLE;
    assign fence_pending_store_o = pending_q;
    assign fence_resp_valid_o = rst_n && state_q == RESPONSE;

    always_comb begin
        store_allow_o = '0;
        if (rst_n) begin
            if (state_q == IDLE && !fence_protocol_error_o) store_allow_o = '1;
            else if (state_q == DRAIN) store_allow_o = pending_q;
        end
        current_protocol_error = 1'b0;
        if (fence_fire && |(commit_valid_i & store_complete_i & store_abort_i))
            current_protocol_error = 1'b1;
        if (state_q == DRAIN) begin
            for (integer port_c = 0; port_c < COMMIT_PORT_COUNT; port_c = port_c + 1) begin
                if (pending_q[port_c]) begin
                    if (!commit_valid_i[port_c]
                        || commit_lane_mask_i[port_c] != lane_mask_q[port_c]
                        || (store_complete_i[port_c] && store_abort_i[port_c]))
                        current_protocol_error = 1'b1;
                    // Inactive lane bytes are part of the inherited source
                    // hold contract too. Snapshotting must not hide changes.
                    for (integer lane_c = 0; lane_c < STORE_LANES; lane_c = lane_c + 1) begin
                        if (commit_word_addr_i[port_c][lane_c] != word_addr_q[port_c][lane_c]
                            || commit_wdata_i[port_c][lane_c] != wdata_q[port_c][lane_c])
                            current_protocol_error = 1'b1;
                    end
                end
            end
        end
        fault_events = '0;
        fault_events[0] = read_fault_event_i;
        fault_events[1] = atomic_fault_event_i;
        fault_events[2] = store_fault_event_i
            || |(store_abort_i & ((state_q == DRAIN) ? pending_q : commit_valid_i));
        fault_events[3] = wb_terminal_failure_event_i;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q <= IDLE;
            pending_q <= '0;
            fence_protocol_error_o <= 1'b0;
            fence_resp_source_o <= '0;
            fence_resp_context_o <= '0;
            fence_resp_request_id_o <= '0;
            fence_resp_generation_o <= '0;
            fence_resp_acquire_o <= 1'b0;
            fence_resp_release_o <= 1'b0;
            fence_resp_fault_bits_o <= '0;
            for (integer port_s = 0; port_s < COMMIT_PORT_COUNT; port_s = port_s + 1) begin
                lane_mask_q[port_s] <= '0;
                for (integer lane_s = 0; lane_s < STORE_LANES; lane_s = lane_s + 1) begin
                    word_addr_q[port_s][lane_s] <= '0;
                    wdata_q[port_s][lane_s] <= '0;
                end
            end
        end else begin
            if (inherited_protocol_error_i || current_protocol_error)
                fence_protocol_error_o <= 1'b1;
            case (state_q)
                IDLE: if (fence_fire) begin
                    state_q <= DRAIN;
                    pending_q <= '0; // NEGATIVE FIXTURE ONLY: omit accepting-edge STORE enrollment.
                    fence_resp_source_o <= fence_req_source_i;
                    fence_resp_context_o <= fence_req_context_i;
                    fence_resp_request_id_o <= fence_req_request_id_i;
                    fence_resp_generation_o <= fence_req_generation_i;
                    fence_resp_acquire_o <= fence_req_acquire_i;
                    fence_resp_release_o <= fence_req_release_i;
                    fence_resp_fault_bits_o <= fault_events
                        | ((!fence_req_acquire_i && !fence_req_release_i) ? 5'b10000 : 5'b00000);
                    for (integer port_s = 0; port_s < COMMIT_PORT_COUNT; port_s = port_s + 1) begin
                        lane_mask_q[port_s] <= commit_lane_mask_i[port_s];
                        for (integer lane_s = 0; lane_s < STORE_LANES; lane_s = lane_s + 1) begin
                            word_addr_q[port_s][lane_s] <= commit_word_addr_i[port_s][lane_s];
                            wdata_q[port_s][lane_s] <= commit_wdata_i[port_s][lane_s];
                        end
                    end
                end
                DRAIN: begin
                    // Real child terminals are the only way to clear a port.
                    // Even a detected source violation cannot invent a terminal.
                    pending_q <= pending_q & ~(store_complete_i | store_abort_i);
                    fence_resp_fault_bits_o <= fence_resp_fault_bits_o | fault_events;
                    if (drain_quiet_i && pending_q == '0 && !fence_protocol_error_o
                        && !inherited_protocol_error_i && !current_protocol_error)
                        state_q <= RESPONSE;
                end
                RESPONSE: if (fence_resp_valid_o && fence_resp_ready_i) begin
                    state_q <= IDLE;
                    pending_q <= '0;
                end
                default: begin
                    fence_protocol_error_o <= 1'b1;
                    state_q <= DRAIN;
                end
            endcase
        end
    end
endmodule
