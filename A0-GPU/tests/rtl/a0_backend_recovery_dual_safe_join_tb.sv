`timescale 1ns/1ps
module a0_backend_recovery_dual_safe_join_tb;
 logic clk,rst_n,active,complete,wv,wr,rv,rr,jv,jr,ws,rs;
 a0_backend_recovery_dual_safe_join dut(.clk(clk),.rst_n(rst_n),.recovery_active_i(active),.recovery_complete_i(complete),.write_safe_valid_i(wv),.write_safe_ready_o(wr),.read_safe_valid_i(rv),.read_safe_ready_o(rr),.joined_safe_valid_o(jv),.joined_safe_ready_i(jr),.write_safe_seen_o(ws),.read_safe_seen_o(rs));
 initial clk=0; always #5 clk=~clk; task tick; begin @(posedge clk); #1; end endtask
 initial begin rst_n=0;active=0;complete=0;wv=0;rv=0;jr=1;tick;rst_n=1;tick;
 wv=1;rv=1;tick;wv=0;rv=0;if(ws||rs||jv)$fatal; $display("PROD_SEAM_P16_EARLY_SAFE_NOT_CAPTURED=PASS");
 active=1;wv=1;#1;if(!wr||!rr)$fatal;tick;wv=0;if(!ws||rs||jv)$fatal; $display("PROD_SEAM_P16_WRITE_ONLY_NOT_JOINED=PASS");
 rv=1;#1;if(!rr)$fatal;tick;rv=0;if(!ws||!rs||!jv)$fatal; $display("PROD_SEAM_P16_WRITE_THEN_READ_JOIN=PASS");
 jr=0;tick;if(!jv)$fatal; jr=1;tick; $display("PROD_SEAM_P16_JOIN_HELD_UNTIL_READY=PASS");
 complete=1;tick;complete=0;active=0;tick;if(ws||rs||jv)$fatal; $display("PROD_SEAM_P16_REARM_AFTER_RECOVERY=PASS");
 active=1;rv=1;tick;rv=0;if(!rs||ws||jv)$fatal;wv=1;tick;wv=0;if(!jv)$fatal;$display("PROD_SEAM_P16_READ_THEN_WRITE_JOIN=PASS");
 $display("PROD_SEAM_P16_BOTH_SAFE_REQUIRED=PASS"); $display("PROD_SEAM_P16_BEHAVIOR=PASS"); $finish; end
endmodule
