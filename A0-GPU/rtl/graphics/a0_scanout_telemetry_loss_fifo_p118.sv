`timescale 1ns/1ps
// P118 DEVELOPMENT: loss-transparent extension of P117 telemetry FIFO.
// A0GF is unchanged. New A0GL is a 32-byte cumulative LOSS NOTICE, NOT
// a synthetic good/bad frame. Legacy decoders intentionally fail closed.
// When a frame event is dropped, a notice is owed even when no later frames
// are produced. First free slot prioritizes that notice over fresh events.
// No physical bus or qualified RTL; requires a real HDL simulator.
module a0_scanout_telemetry_loss_fifo_p118 #(
    parameter int FIFO_DEPTH=4,
    parameter int PTR_BITS=(FIFO_DEPTH<=2?1:$clog2(FIFO_DEPTH)),
    parameter int COUNT_BITS=$clog2(FIFO_DEPTH+1)
)(
    input logic clk,rst_n,
    input logic frame_valid,frame_error,
    input logic [31:0] frame_crc32,good_frame_count,bad_frame_count,aborted_frame_count,
    output logic tx_valid,
    input logic tx_ready,
    output logic [7:0] tx_byte,
    output logic [31:0] dropped_frame_events,
    output logic [COUNT_BITS-1:0] queued_frame_events,
    output logic loss_notice_pending
);
    logic [255:0] packets[0:FIFO_DEPTH-1];
    logic [PTR_BITS-1:0] rd_q,wr_q;
    logic [4:0] byte_index_q;
    logic [COUNT_BITS-1:0] count_q;
    logic [15:0] event_sequence_q;
    logic [223:0] frame_payload,notice_payload;
    logic finish_packet,free_slot,push_frame,push_notice,push_any,overflow_event;
    logic notice_owed_q;
    function automatic logic [PTR_BITS-1:0] step_ptr(input logic [PTR_BITS-1:0] p);
        return p==PTR_BITS'(FIFO_DEPTH-1) ? '0 : p+PTR_BITS'(1);
    endfunction
    function automatic logic [31:0] crc32_28(input logic [223:0] data);
        logic [31:0] crc;
        crc=32'hffffffff;
        for(int i=0;i<28;i++) begin
            crc=crc^{24'd0,data[i*8+:8]};
            for(int j=0;j<8;j++)
                crc=crc[0] ? ((crc>>1)^32'hedb88320) : (crc>>1);
        end
        return ~crc;
    endfunction
    // P117 A0GF wire unchanged: A0GF, version, error, seq, crc, counters.
    assign frame_payload={dropped_frame_events,aborted_frame_count,
        bad_frame_count,good_frame_count,frame_crc32,
        event_sequence_q,{7'd0,frame_error},8'd1,32'h46473041};
    // A0GL wire: magic, version=1, notice_type=1, attempted_seq (next),
    // cumulative dropped, good, bad, aborted, reserved=0, IEEE CRC32.
    assign notice_payload={32'd0,aborted_frame_count,bad_frame_count,
        good_frame_count,dropped_frame_events,event_sequence_q,
        8'd1,8'd1,32'h4c473041};
    assign queued_frame_events=count_q;
    assign loss_notice_pending=notice_owed_q;
    assign tx_valid=rst_n && count_q!='0;
    assign tx_byte=count_q!='0 ? packets[rd_q][{byte_index_q,3'b000}+:8] : 8'd0;
    assign finish_packet=tx_valid && tx_ready && byte_index_q==5'd31;
    assign free_slot=(count_q<COUNT_BITS'(FIFO_DEPTH)) || finish_packet;
    // The owed notice has first claim on a free slot; current frame can drop.
    assign push_notice=rst_n && notice_owed_q && free_slot;
    assign push_frame=rst_n && frame_valid && free_slot && !notice_owed_q;
    assign push_any=push_notice || push_frame;
    assign overflow_event=rst_n && frame_valid && !push_frame;
    initial begin
        if(FIFO_DEPTH<2) $fatal(1,"P118 FIFO_DEPTH must be >= 2");
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            rd_q<='0;wr_q<='0;count_q<='0;byte_index_q<='0;
            event_sequence_q<='0;dropped_frame_events<='0;notice_owed_q<=1'b0;
        end else begin
            if(frame_valid) event_sequence_q<=event_sequence_q+16'd1;
            if(overflow_event && dropped_frame_events!=32'hffffffff)
                dropped_frame_events<=dropped_frame_events+32'd1;
            // If overflow coincides with emitting the previous summary,
            // preserve a NEW owed summary for the newly lost frame.
            if(overflow_event) notice_owed_q<=1'b1;
            else if(push_notice) notice_owed_q<=1'b0;
            if(push_any) begin
                packets[wr_q]<=push_notice ?
                    {crc32_28(notice_payload),notice_payload} :
                    {crc32_28(frame_payload),frame_payload};
                wr_q<=step_ptr(wr_q);
            end
            if(tx_valid && tx_ready) begin
                if(finish_packet) begin
                    rd_q<=step_ptr(rd_q);byte_index_q<='0;
                end else byte_index_q<=byte_index_q+5'd1;
            end
            case ({push_any,finish_packet})
                2'b10:count_q<=count_q+COUNT_BITS'(1);
                2'b01:count_q<=count_q-COUNT_BITS'(1);
                default:count_q<=count_q;
            endcase
        end
    end
endmodule
