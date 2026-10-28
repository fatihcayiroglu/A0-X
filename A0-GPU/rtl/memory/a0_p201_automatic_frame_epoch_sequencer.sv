`timescale 1ns/1ps
// P201: synthesizable fail-closed coordinator for consecutive post-render
// framebuffer snapshot epochs. Generates P199 begin/seal and P198 start;
// observes actual committed words, not merely P198 queued pixels.
// No data storage, real VRAM, live raster coherence, or memory PHY.
module a0_p201_automatic_frame_epoch_sequencer #(
  parameter integer FRAME_WORDS=65536
)(
  input logic clk,rst_n,
  input logic capture_request,
  input logic exporter_busy,exporter_done,exporter_fault,
  input logic [31:0] exporter_queued_pixels,
  input logic [1:0] fifo_queued_words,
  input logic stage_active,seal_pending,active_valid,
  input logic epoch_fault,router_fault,
  input logic [31:0] committed_words,published_epochs,
  output logic stage_begin,export_start,stage_seal,
  output logic busy,complete_pulse,fault,
  output logic [31:0] completed_epochs
);
  localparam logic [2:0]
    IDLE=3'd0,ARM_EXPORT=3'd1,WAIT_BUSY=3'd2,
    DRAIN=3'd3,WAIT_PUBLISH=3'd4,FAILED=3'd5;
  logic [2:0] state_q;
  logic fault_q,stage_begin_q,export_start_q,stage_seal_q;
  logic complete_q;
  logic [31:0] target_epoch_q,completed_q;

  assign stage_begin=stage_begin_q;
  assign export_start=export_start_q;
  assign stage_seal=stage_seal_q;
  assign complete_pulse=complete_q;
  assign completed_epochs=completed_q;
  assign fault=fault_q;
  assign busy=(state_q!=IDLE && state_q!=FAILED);
  wire upstream_bad=exporter_fault || epoch_fault || router_fault;
  wire counters_bad=exporter_queued_pixels>FRAME_WORDS ||
    committed_words>FRAME_WORDS;
  wire epoch_unexpected=published_epochs>target_epoch_q;

  always_ff @(posedge clk)begin
    if(!rst_n)begin
      state_q<=IDLE;fault_q<=0;
      stage_begin_q<=0;export_start_q<=0;stage_seal_q<=0;
      complete_q<=0;target_epoch_q<=0;completed_q<=0;
    end else begin
      stage_begin_q<=0;export_start_q<=0;stage_seal_q<=0;
      complete_q<=0;
      if(upstream_bad || (state_q!=IDLE && capture_request) ||
         (state_q!=IDLE && counters_bad))begin
        fault_q<=1;state_q<=FAILED;
      end else case(state_q)
        IDLE:if(capture_request)begin
          if(stage_active || seal_pending || fault_q ||
             published_epochs==32'hffff_ffff || exporter_busy)begin
            fault_q<=1;state_q<=FAILED;
          end else begin
            target_epoch_q<=published_epochs+32'd1;
            stage_begin_q<=1;state_q<=ARM_EXPORT;
          end
        end
        ARM_EXPORT:begin
          // The registered begin pulse is accepted by P199 at this edge.
          export_start_q<=1;
          state_q<=WAIT_BUSY;
        end
        WAIT_BUSY:begin
          if(!stage_active || seal_pending || epoch_unexpected)begin
            fault_q<=1;state_q<=FAILED;
          end else if(exporter_busy)state_q<=DRAIN;
        end
        DRAIN:begin
          if(!stage_active || seal_pending || epoch_unexpected)begin
            fault_q<=1;state_q<=FAILED;
          end else if(exporter_done)begin
            if(exporter_queued_pixels!=FRAME_WORDS)begin
              fault_q<=1;state_q<=FAILED;
            end else if(fifo_queued_words==0 &&
               committed_words==FRAME_WORDS)begin
              stage_seal_q<=1;state_q<=WAIT_PUBLISH;
            end
          end
        end
        WAIT_PUBLISH:begin
          if(published_epochs==target_epoch_q)begin
            if(!active_valid || stage_active || seal_pending)begin
              fault_q<=1;state_q<=FAILED;
            end else begin
              completed_q<=completed_q+32'd1;
              complete_q<=1;state_q<=IDLE;
            end
          end else if(epoch_unexpected || !stage_active ||
                      (!seal_pending && !stage_seal_q))begin
            // Seal must already be queued or observed before waiting for a flip.
            fault_q<=1;state_q<=FAILED;
          end
        end
        FAILED:begin end
        default:begin fault_q<=1;state_q<=FAILED;end
      endcase
    end
  end
  initial if(FRAME_WORDS<2 || FRAME_WORDS>65536)
    $fatal(1,"P201 unsupported frame size");
endmodule
