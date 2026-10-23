`timescale 1ns/1ps
// P37 candidate logical channels. This block does not model a DRAM PHY or timing.
// State reset is synchronous and active-low, matching the P36 controllers.
// Handshake outputs are gated while rst_n is low; state clears on a clock edge.
module a0_memory_channel_scheduler #(
    parameter integer CHANNEL_COUNT = 4,
    parameter integer DEPTH_PER_CHANNEL = 2,
    parameter integer LINE_WORDS = 8,
    parameter integer READ_TAG_W = 8,
    parameter integer WB_ATTEMPT_ID_W = 8,
    parameter integer STORE_ATTEMPT_ID_W = 16,
    parameter integer TOKEN_GENERATION_W = 8,
    parameter integer WORD_SELECT_W = (LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS),
    parameter integer LINE_ADDR_W = 32 - WORD_SELECT_W,
    parameter integer SLOT_W = (DEPTH_PER_CHANNEL <= 1) ? 1 : $clog2(DEPTH_PER_CHANNEL),
    parameter integer TOKEN_W = SLOT_W + TOKEN_GENERATION_W
) (
    input logic clk,
    input logic rst_n,
    input logic cmd_valid_i,
    output logic cmd_ready_o,
    input logic [1:0] cmd_kind_i,
    input logic [READ_TAG_W-1:0] cmd_read_tag_i,
    input logic [WB_ATTEMPT_ID_W-1:0] cmd_wb_attempt_id_i,
    input logic [STORE_ATTEMPT_ID_W-1:0] cmd_store_attempt_id_i,
    input logic [LINE_ADDR_W-1:0] cmd_line_addr_i,
    input logic [31:0] cmd_data_i [0:LINE_WORDS-1],
    input logic [31:0] cmd_store_word_addr_i,
    input logic [31:0] cmd_store_wdata_i,

    output logic [CHANNEL_COUNT-1:0] channel_cmd_valid_o,
    input logic [CHANNEL_COUNT-1:0] channel_cmd_ready_i,
    output logic [TOKEN_W-1:0] channel_cmd_token_o [0:CHANNEL_COUNT-1],
    output logic [1:0] channel_cmd_kind_o [0:CHANNEL_COUNT-1],
    output logic [READ_TAG_W-1:0] channel_cmd_read_tag_o [0:CHANNEL_COUNT-1],
    output logic [WB_ATTEMPT_ID_W-1:0] channel_cmd_wb_attempt_id_o [0:CHANNEL_COUNT-1],
    output logic [STORE_ATTEMPT_ID_W-1:0] channel_cmd_store_attempt_id_o [0:CHANNEL_COUNT-1],
    output logic [LINE_ADDR_W-1:0] channel_cmd_line_addr_o [0:CHANNEL_COUNT-1],
    output logic [31:0] channel_cmd_data_o [0:CHANNEL_COUNT-1][0:LINE_WORDS-1],
    output logic [31:0] channel_cmd_store_word_addr_o [0:CHANNEL_COUNT-1],
    output logic [31:0] channel_cmd_store_wdata_o [0:CHANNEL_COUNT-1],

    input logic [CHANNEL_COUNT-1:0] channel_resp_valid_i,
    output logic [CHANNEL_COUNT-1:0] channel_resp_ready_o,
    input logic [TOKEN_W-1:0] channel_resp_token_i [0:CHANNEL_COUNT-1],
    input logic [1:0] channel_resp_kind_i [0:CHANNEL_COUNT-1],
    input logic [READ_TAG_W-1:0] channel_resp_read_tag_i [0:CHANNEL_COUNT-1],
    input logic [WB_ATTEMPT_ID_W-1:0] channel_resp_wb_attempt_id_i [0:CHANNEL_COUNT-1],
    input logic [STORE_ATTEMPT_ID_W-1:0] channel_resp_store_attempt_id_i [0:CHANNEL_COUNT-1],
    input logic [LINE_ADDR_W-1:0] channel_resp_line_addr_i [0:CHANNEL_COUNT-1],
    input logic [31:0] channel_resp_store_word_addr_i [0:CHANNEL_COUNT-1],
    input logic [31:0] channel_resp_data_i [0:CHANNEL_COUNT-1][0:LINE_WORDS-1],
    input logic [CHANNEL_COUNT-1:0] channel_resp_success_i,
    input logic [CHANNEL_COUNT-1:0] channel_resp_retryable_i,

    output logic read_resp_valid_o,
    output logic [READ_TAG_W-1:0] read_resp_tag_o,
    output logic [LINE_ADDR_W-1:0] read_resp_line_addr_o,
    output logic read_resp_fault_o,
    output logic [31:0] read_resp_data_o [0:LINE_WORDS-1],
    output logic wb_status_valid_o,
    output logic [WB_ATTEMPT_ID_W-1:0] wb_status_attempt_id_o,
    output logic wb_status_success_o,
    output logic wb_status_retryable_o,
    output logic store_status_valid_o,
    output logic [STORE_ATTEMPT_ID_W-1:0] store_status_attempt_id_o,
    output logic store_status_success_o,
    output logic store_status_retryable_o,

    output logic busy_o,
    output logic quiescent_o,
    output logic read_busy_o,
    output logic wb_busy_o,
    output logic store_busy_o,
    output logic [CHANNEL_COUNT-1:0] channel_busy_o,
    output logic [CHANNEL_COUNT-1:0] response_rejected_o,
    output logic protocol_error_o,
    input logic all_generations_quiescent_i,
    output logic [CHANNEL_COUNT-1:0] generation_rearm_pulse_o,
    output logic [CHANNEL_COUNT-1:0] generation_exhausted_o
);
    localparam logic [1:0] KIND_READ = 2'b00;
    localparam logic [1:0] KIND_WB = 2'b01;
    localparam logic [1:0] KIND_STORE = 2'b10;
    localparam logic [1:0] FREE = 2'b00;
    localparam logic [1:0] QUEUED = 2'b01;
    localparam logic [1:0] ISSUED = 2'b10;
    localparam logic [1:0] RETURNED = 2'b11;
    localparam integer QUEUE_COUNT_W = $clog2(DEPTH_PER_CHANNEL + 1);
    localparam integer CHANNEL_INDEX_W = (CHANNEL_COUNT <= 1) ? 1 : $clog2(CHANNEL_COUNT);
    localparam integer TOTAL_SLOTS = CHANNEL_COUNT * DEPTH_PER_CHANNEL;
    localparam integer RR_W = (TOTAL_SLOTS <= 1) ? 1 : $clog2(TOTAL_SLOTS);

    initial begin
        if ((CHANNEL_COUNT < 1) || (DEPTH_PER_CHANNEL < 1))
            $fatal(1, "P37 scheduler requires positive channel and slot counts");
        if ((LINE_WORDS < 1) || ((LINE_WORDS & (LINE_WORDS - 1)) != 0))
            $fatal(1, "P37 scheduler requires a positive power-of-two line size");
        if ((READ_TAG_W < 1) || (WB_ATTEMPT_ID_W < 1)
            || (STORE_ATTEMPT_ID_W < 1) || (TOKEN_GENERATION_W < 1))
            $fatal(1, "P37 scheduler requires positive identity widths");
        if ((WORD_SELECT_W != ((LINE_WORDS <= 1) ? 0 : $clog2(LINE_WORDS)))
            || (LINE_ADDR_W != (32 - WORD_SELECT_W)) || (LINE_ADDR_W < 1))
            $fatal(1, "P37 scheduler line geometry is inconsistent");
        if ((SLOT_W != ((DEPTH_PER_CHANNEL <= 1) ? 1 : $clog2(DEPTH_PER_CHANNEL)))
            || (TOKEN_W != (SLOT_W + TOKEN_GENERATION_W)))
            $fatal(1, "P37 scheduler token geometry is inconsistent");
    end

    logic [1:0] state_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [1:0] kind_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [READ_TAG_W-1:0] read_tag_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [WB_ATTEMPT_ID_W-1:0] wb_id_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [STORE_ATTEMPT_ID_W-1:0] store_id_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [LINE_ADDR_W-1:0] line_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [31:0] data_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1][0:LINE_WORDS-1];
    logic [31:0] store_word_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [31:0] store_data_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic success_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic retryable_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [TOKEN_GENERATION_W-1:0] active_generation_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [TOKEN_GENERATION_W-1:0] next_generation_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic generation_used_up_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];

    // The FIFO stores slot indices. Slots retain transport ownership until the
    // typed, non-backpressured upstream completion is actually delivered.
    logic [SLOT_W-1:0] dispatch_queue_q [0:CHANNEL_COUNT-1][0:DEPTH_PER_CHANNEL-1];
    logic [SLOT_W-1:0] queue_head_q [0:CHANNEL_COUNT-1];
    logic [SLOT_W-1:0] queue_tail_q [0:CHANNEL_COUNT-1];
    logic [QUEUE_COUNT_W-1:0] queue_count_q [0:CHANNEL_COUNT-1];
    logic [RR_W-1:0] return_rr_q;

    logic [LINE_ADDR_W-1:0] cmd_canonical_line;
    integer cmd_channel;
    integer free_slot;
    integer selected_return;
    logic [CHANNEL_INDEX_W-1:0] return_channel;
    logic [SLOT_W-1:0] return_slot;
    integer scan_flat;
    logic [CHANNEL_INDEX_W-1:0] scan_channel;
    logic [SLOT_W-1:0] scan_slot;
    integer dispatch_slot [0:CHANNEL_COUNT-1];
    integer response_slot [0:CHANNEL_COUNT-1];
    logic [CHANNEL_COUNT-1:0] dispatch_fire;
    logic [CHANNEL_COUNT-1:0] response_matches;
    logic enqueue_fire;
    logic owned_slots_empty;
    logic rearm_eligible;

    always_comb begin
        cmd_canonical_line = cmd_line_addr_i;
        if (cmd_kind_i == KIND_STORE)
            cmd_canonical_line = cmd_line_addr_i;
        cmd_channel = int'($unsigned(32'(cmd_canonical_line)) % $unsigned(CHANNEL_COUNT));
        free_slot = -1;
        for (integer s = 0; s < DEPTH_PER_CHANNEL; s = s + 1) begin
            if ((free_slot < 0) && (state_q[cmd_channel][s] == FREE)
                && !generation_used_up_q[cmd_channel][s])
                free_slot = s;
        end
        cmd_ready_o = rst_n && (cmd_kind_i != 2'b11) && (free_slot >= 0);

        busy_o = cmd_valid_i || (|channel_resp_valid_i);
        owned_slots_empty = 1'b1;
        read_busy_o = cmd_valid_i && (cmd_kind_i == KIND_READ);
        wb_busy_o = cmd_valid_i && (cmd_kind_i == KIND_WB);
        store_busy_o = cmd_valid_i && (cmd_kind_i == KIND_STORE);
        channel_busy_o = channel_resp_valid_i;
        if (cmd_valid_i) channel_busy_o[cmd_channel] = 1'b1;
        generation_exhausted_o = '0;
        channel_cmd_valid_o = '0;
        channel_resp_ready_o = {CHANNEL_COUNT{rst_n}};
        dispatch_fire = '0;
        response_matches = '0;

        for (integer c = 0; c < CHANNEL_COUNT; c = c + 1) begin
            dispatch_slot[c] = int'(dispatch_queue_q[c][queue_head_q[c]]);
            response_slot[c] = int'(channel_resp_token_i[c][SLOT_W-1:0]);
            channel_cmd_token_o[c] = '0;
            channel_cmd_kind_o[c] = KIND_READ;
            channel_cmd_read_tag_o[c] = '0;
            channel_cmd_wb_attempt_id_o[c] = '0;
            channel_cmd_store_attempt_id_o[c] = '0;
            channel_cmd_line_addr_o[c] = '0;
            channel_cmd_store_word_addr_o[c] = '0;
            channel_cmd_store_wdata_o[c] = '0;
            for (integer w = 0; w < LINE_WORDS; w = w + 1)
                channel_cmd_data_o[c][w] = '0;
            if (queue_count_q[c] != 0) begin
                channel_cmd_valid_o[c] = rst_n;
                channel_cmd_token_o[c] = {active_generation_q[c][dispatch_slot[c]], SLOT_W'(dispatch_slot[c])};
                channel_cmd_kind_o[c] = kind_q[c][dispatch_slot[c]];
                channel_cmd_read_tag_o[c] = read_tag_q[c][dispatch_slot[c]];
                channel_cmd_wb_attempt_id_o[c] = wb_id_q[c][dispatch_slot[c]];
                channel_cmd_store_attempt_id_o[c] = store_id_q[c][dispatch_slot[c]];
                channel_cmd_line_addr_o[c] = line_q[c][dispatch_slot[c]];
                channel_cmd_store_word_addr_o[c] = store_word_q[c][dispatch_slot[c]];
                channel_cmd_store_wdata_o[c] = store_data_q[c][dispatch_slot[c]];
                for (integer w = 0; w < LINE_WORDS; w = w + 1)
                    channel_cmd_data_o[c][w] = data_q[c][dispatch_slot[c]][w];
            end
            dispatch_fire[c] = channel_cmd_valid_o[c] && channel_cmd_ready_i[c];

            // A zero-latency channel may respond on its command handshake.
            // Recognize that exact QUEUED head as issued for this cycle only.
            if (response_slot[c] < DEPTH_PER_CHANNEL) begin
                response_matches[c] =
                    ((state_q[c][response_slot[c]] == ISSUED)
                     || ((state_q[c][response_slot[c]] == QUEUED)
                         && dispatch_fire[c] && (response_slot[c] == dispatch_slot[c])))
                    && (channel_resp_token_i[c][TOKEN_W-1:SLOT_W] == active_generation_q[c][response_slot[c]])
                    && (channel_resp_kind_i[c] == kind_q[c][response_slot[c]])
                    && (channel_resp_read_tag_i[c] == read_tag_q[c][response_slot[c]])
                    && (channel_resp_wb_attempt_id_i[c] == wb_id_q[c][response_slot[c]])
                    && (channel_resp_store_attempt_id_i[c] == store_id_q[c][response_slot[c]])
                    && (channel_resp_line_addr_i[c] == line_q[c][response_slot[c]])
                    && (channel_resp_store_word_addr_i[c] == store_word_q[c][response_slot[c]]);
            end
            for (integer s = 0; s < DEPTH_PER_CHANNEL; s = s + 1) begin
                generation_exhausted_o[c] = generation_exhausted_o[c] || generation_used_up_q[c][s];
                if (state_q[c][s] != FREE) begin
                    owned_slots_empty = 1'b0;
                    busy_o = 1'b1;
                    channel_busy_o[c] = 1'b1;
                    read_busy_o = read_busy_o || (kind_q[c][s] == KIND_READ);
                    wb_busy_o = wb_busy_o || (kind_q[c][s] == KIND_WB);
                    store_busy_o = store_busy_o || (kind_q[c][s] == KIND_STORE);
                end
            end
            if (channel_resp_valid_i[c]) begin
                read_busy_o = read_busy_o || (channel_resp_kind_i[c] == KIND_READ);
                wb_busy_o = wb_busy_o || (channel_resp_kind_i[c] == KIND_WB);
                store_busy_o = store_busy_o || (channel_resp_kind_i[c] == KIND_STORE);
            end
        end
        quiescent_o = !busy_o;
        // An unaccepted, held ingress offer is not an old transport copy.
        // Allow certification with that offer present, but insert an acceptance
        // bubble so no new owner can collide with a generation reset.
        rearm_eligible = all_generations_quiescent_i && owned_slots_empty
            && !(|channel_resp_valid_i) && (|generation_exhausted_o);
        if (rearm_eligible) cmd_ready_o = 1'b0;
        enqueue_fire = cmd_valid_i && cmd_ready_o;

        // Round robin across every buffered slot, including within a channel.
        selected_return = -1;
        scan_flat = 0;
        scan_channel = 0;
        scan_slot = 0;
        for (integer offset = 0; offset < TOTAL_SLOTS; offset = offset + 1) begin
            scan_flat = (int'(return_rr_q) + offset) % TOTAL_SLOTS;
            scan_channel = CHANNEL_INDEX_W'(scan_flat / DEPTH_PER_CHANNEL);
            scan_slot = SLOT_W'(scan_flat % DEPTH_PER_CHANNEL);
            if ((selected_return < 0) && (state_q[scan_channel][scan_slot] == RETURNED))
                selected_return = scan_flat;
        end
        return_channel = 0;
        return_slot = 0;
        read_resp_valid_o = 1'b0;
        read_resp_tag_o = '0;
        read_resp_line_addr_o = '0;
        read_resp_fault_o = 1'b0;
        for (integer w = 0; w < LINE_WORDS; w = w + 1) read_resp_data_o[w] = '0;
        wb_status_valid_o = 1'b0;
        wb_status_attempt_id_o = '0;
        wb_status_success_o = 1'b0;
        wb_status_retryable_o = 1'b0;
        store_status_valid_o = 1'b0;
        store_status_attempt_id_o = '0;
        store_status_success_o = 1'b0;
        store_status_retryable_o = 1'b0;
        if (selected_return >= 0) begin
            return_channel = CHANNEL_INDEX_W'(selected_return / DEPTH_PER_CHANNEL);
            return_slot = SLOT_W'(selected_return % DEPTH_PER_CHANNEL);
            case (kind_q[return_channel][return_slot])
                KIND_READ: begin
                    read_resp_valid_o = rst_n;
                    read_resp_tag_o = read_tag_q[return_channel][return_slot];
                    read_resp_line_addr_o = line_q[return_channel][return_slot];
                    read_resp_fault_o = !success_q[return_channel][return_slot];
                    for (integer w = 0; w < LINE_WORDS; w = w + 1)
                        read_resp_data_o[w] = data_q[return_channel][return_slot][w];
                end
                KIND_WB: begin
                    wb_status_valid_o = rst_n;
                    wb_status_attempt_id_o = wb_id_q[return_channel][return_slot];
                    wb_status_success_o = success_q[return_channel][return_slot];
                    wb_status_retryable_o = retryable_q[return_channel][return_slot];
                end
                KIND_STORE: begin
                    store_status_valid_o = rst_n;
                    store_status_attempt_id_o = store_id_q[return_channel][return_slot];
                    store_status_success_o = success_q[return_channel][return_slot];
                    store_status_retryable_o = retryable_q[return_channel][return_slot];
                end
                default: begin end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            return_rr_q <= '0;
            response_rejected_o <= '0;
            protocol_error_o <= 1'b0;
            generation_rearm_pulse_o <= '0;
            for (integer c = 0; c < CHANNEL_COUNT; c = c + 1) begin
                queue_head_q[c] <= '0;
                queue_tail_q[c] <= '0;
                queue_count_q[c] <= '0;
                for (integer s = 0; s < DEPTH_PER_CHANNEL; s = s + 1) begin
                    state_q[c][s] <= FREE;
                    kind_q[c][s] <= KIND_READ;
                    read_tag_q[c][s] <= '0;
                    wb_id_q[c][s] <= '0;
                    store_id_q[c][s] <= '0;
                    line_q[c][s] <= '0;
                    store_word_q[c][s] <= '0;
                    store_data_q[c][s] <= '0;
                    success_q[c][s] <= 1'b0;
                    retryable_q[c][s] <= 1'b0;
                    active_generation_q[c][s] <= '0;
                    next_generation_q[c][s] <= '0;
                    generation_used_up_q[c][s] <= 1'b0;
                    dispatch_queue_q[c][s] <= '0;
                    for (integer w = 0; w < LINE_WORDS; w = w + 1) data_q[c][s][w] <= '0;
                end
            end
        end else begin
            response_rejected_o <= '0;
            generation_rearm_pulse_o <= '0;
            if (cmd_valid_i && (cmd_kind_i == 2'b11)) protocol_error_o <= 1'b1;

            if (selected_return >= 0) begin
                state_q[return_channel][return_slot] <= FREE;
                if (selected_return == (TOTAL_SLOTS - 1)) return_rr_q <= '0;
                else return_rr_q <= RR_W'(selected_return + 1);
            end

            for (integer c = 0; c < CHANNEL_COUNT; c = c + 1) begin
                case ({(enqueue_fire && (cmd_channel == c)), dispatch_fire[c]})
                    2'b10: queue_count_q[c] <= queue_count_q[c] + QUEUE_COUNT_W'(1);
                    2'b01: queue_count_q[c] <= queue_count_q[c] - QUEUE_COUNT_W'(1);
                    default: begin end
                endcase
                if (dispatch_fire[c]) begin
                    state_q[c][dispatch_slot[c]] <= ISSUED;
                    if (int'(queue_head_q[c]) == (DEPTH_PER_CHANNEL - 1)) queue_head_q[c] <= '0;
                    else queue_head_q[c] <= queue_head_q[c] + SLOT_W'(1);
                end
                if (channel_resp_valid_i[c] && channel_resp_ready_o[c]) begin
                    if (response_matches[c]) begin
                        state_q[c][response_slot[c]] <= RETURNED;
                        success_q[c][response_slot[c]] <= channel_resp_success_i[c];
                        retryable_q[c][response_slot[c]] <= channel_resp_retryable_i[c];
                        for (integer w = 0; w < LINE_WORDS; w = w + 1)
                            data_q[c][response_slot[c]][w] <= channel_resp_data_i[c][w];
                    end else begin
                        response_rejected_o[c] <= 1'b1;
                        protocol_error_o <= 1'b1;
                    end
                end
            end

            if (enqueue_fire) begin
                state_q[cmd_channel][free_slot] <= QUEUED;
                kind_q[cmd_channel][free_slot] <= cmd_kind_i;
                read_tag_q[cmd_channel][free_slot] <= cmd_read_tag_i;
                wb_id_q[cmd_channel][free_slot] <= cmd_wb_attempt_id_i;
                store_id_q[cmd_channel][free_slot] <= cmd_store_attempt_id_i;
                line_q[cmd_channel][free_slot] <= cmd_canonical_line;
                store_word_q[cmd_channel][free_slot] <= cmd_store_word_addr_i;
                store_data_q[cmd_channel][free_slot] <= cmd_store_wdata_i;
                success_q[cmd_channel][free_slot] <= 1'b0;
                retryable_q[cmd_channel][free_slot] <= 1'b0;
                for (integer w = 0; w < LINE_WORDS; w = w + 1)
                    data_q[cmd_channel][free_slot][w] <= cmd_data_i[w];
                active_generation_q[cmd_channel][free_slot] <= next_generation_q[cmd_channel][free_slot];
                if (&next_generation_q[cmd_channel][free_slot])
                    generation_used_up_q[cmd_channel][free_slot] <= 1'b1;
                else next_generation_q[cmd_channel][free_slot] <= next_generation_q[cmd_channel][free_slot] + TOKEN_GENERATION_W'(1);
                dispatch_queue_q[cmd_channel][queue_tail_q[cmd_channel]] <= SLOT_W'(free_slot);
                if (int'(queue_tail_q[cmd_channel]) == (DEPTH_PER_CHANNEL - 1)) queue_tail_q[cmd_channel] <= '0;
                else queue_tail_q[cmd_channel] <= queue_tail_q[cmd_channel] + SLOT_W'(1);
            end

            // This is an explicit external certificate covering every old token
            // copy, including the external channel transport. Local idleness
            // alone never authorizes token reuse after generation exhaustion.
            if (rearm_eligible) begin
                generation_rearm_pulse_o <= generation_exhausted_o;
                for (integer c = 0; c < CHANNEL_COUNT; c = c + 1) begin
                    for (integer s = 0; s < DEPTH_PER_CHANNEL; s = s + 1) begin
                        active_generation_q[c][s] <= '0;
                        next_generation_q[c][s] <= '0;
                        generation_used_up_q[c][s] <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
