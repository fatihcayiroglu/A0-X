`timescale 1ns/1ps
// P115 EXPERIMENTAL passive, single-clock P42/P47/P114 consistency checker.
// P42 frame_done and P47 CRC event register on the same accepted EOF edge.
// P114 liveness completed counter increments when it observes frame_done on
// the subsequent edge. Only count matched frames AFTER confirmation.
// Good here means internally paired, NOT independently verified image content
// and NOT delivered host telemetry, physical scanout or FPGA qualification.
module a0_frame_event_audit_p115 (
    input logic clk,rst_n,
    input logic scan_active,
    input logic frame_done,frame_crc_valid,frame_crc_error,
    input logic [31:0] frame_crc32,
    input logic frame_liveness_pending,frame_liveness_fault,
    input logic [31:0] frame_liveness_completed,
    input logic [31:0] telemetry_dropped_frames,
    output logic fault_sticky,confirmation_pending,
    output logic [31:0] matched_good_frames,untrusted_frames,
    output logic [31:0] event_fault_count,crc_error_frame_count,
    output logic [31:0] liveness_fault_event_count,telemetry_lost_event_count,
    output logic [31:0] last_crc32
);
    logic awaiting_q,crc_clean_q,liveness_fault_seen_q;
    logic [31:0] expected_completed_q,dropped_q;
    assign confirmation_pending=awaiting_q;

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            fault_sticky<=1'b0;
            awaiting_q<=1'b0;
            crc_clean_q<=1'b0;
            liveness_fault_seen_q<=1'b0;
            expected_completed_q<='0;
            dropped_q<='0;
            matched_good_frames<='0;
            untrusted_frames<='0;
            event_fault_count<='0;
            crc_error_frame_count<='0;
            liveness_fault_event_count<='0;
            telemetry_lost_event_count<='0;
            last_crc32<='0;
        end else begin
            // P114 sticky fault is counted ONCE, not once per clock.
            if(frame_liveness_fault && !liveness_fault_seen_q) begin
                fault_sticky<=1'b1;
                if(liveness_fault_event_count!=32'hffffffff)
                    liveness_fault_event_count<=liveness_fault_event_count+1'b1;
            end
            liveness_fault_seen_q<=frame_liveness_fault;

            // P48 drop counter must be monotone within a reset epoch.
            if(telemetry_dropped_frames!=dropped_q) begin
                if(telemetry_dropped_frames>dropped_q) begin
                    fault_sticky<=1'b1;
                    if(telemetry_lost_event_count >
                       32'hffffffff-(telemetry_dropped_frames-dropped_q))
                        telemetry_lost_event_count<=32'hffffffff;
                    else telemetry_lost_event_count<=telemetry_lost_event_count+
                                       (telemetry_dropped_frames-dropped_q);
                end else begin
                    fault_sticky<=1'b1;
                    if(event_fault_count!=32'hffffffff)
                        event_fault_count<=event_fault_count+1'b1;
                end
                dropped_q<=telemetry_dropped_frames;
            end

            // One cycle AFTER event, P114 completed counter must advance.
            if(awaiting_q) begin
                awaiting_q<=1'b0;
                if(frame_liveness_completed!=expected_completed_q ||
                   frame_liveness_fault) begin
                    fault_sticky<=1'b1;
                    if(untrusted_frames!=32'hffffffff)
                        untrusted_frames<=untrusted_frames+1'b1;
                    if(event_fault_count!=32'hffffffff)
                        event_fault_count<=event_fault_count+1'b1;
                end else if(crc_clean_q) begin
                    if(matched_good_frames!=32'hffffffff)
                        matched_good_frames<=matched_good_frames+1'b1;
                end else if(untrusted_frames!=32'hffffffff)
                    untrusted_frames<=untrusted_frames+1'b1;
            end

            // Registered P42 and P47 frame events MUST be simultaneous.
            if(frame_done || frame_crc_valid) begin
                if(!frame_done || !frame_crc_valid || !scan_active ||
                   !frame_liveness_pending || frame_liveness_fault || awaiting_q) begin
                    fault_sticky<=1'b1;
                    if(event_fault_count!=32'hffffffff)
                        event_fault_count<=event_fault_count+1'b1;
                    if(untrusted_frames!=32'hffffffff)
                        untrusted_frames<=untrusted_frames+1'b1;
                end else begin
                    awaiting_q<=1'b1;
                    expected_completed_q<=frame_liveness_completed==32'hffffffff ?
                        32'hffffffff : frame_liveness_completed+1'b1;
                    crc_clean_q<=!frame_crc_error;
                    if(frame_crc_error) fault_sticky<=1'b1;
                    last_crc32<=frame_crc32;
                    if(frame_crc_error && crc_error_frame_count!=32'hffffffff)
                        crc_error_frame_count<=crc_error_frame_count+1'b1;
                end
            end
        end
    end
endmodule
