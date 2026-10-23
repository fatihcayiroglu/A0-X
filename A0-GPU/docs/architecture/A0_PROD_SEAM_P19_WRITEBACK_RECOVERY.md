# PROD-SEAM-P19 — dirty writeback terminal-failure recovery

P19 adds bounded recovery around the frozen P17 dirty slice and frozen P18 writeback completion guard. A terminal writeback failure never resets the cache and never acknowledges P17. The dirty victim and retained refill remain intact.

Recovery is armed only after a terminal failure. An early backend recovery-safe signal is not captured. While recovery is active, an explicit `backend_wb_recovery_safe` handshake certifies that pre-recovery writeback statuses can no longer arrive. P19 then locally resets only the P18 completion guard for one cycle; the P17 cache remains live and dirty. The still-valid P17 writeback source is recaptured and the identical victim is reissued. Recovery itself never synthesizes `wb_ready` or a clean transition. A new real matching SUCCESS is still required to release the victim and blocked refill.

P19 remains bounded: it has one dirty victim in flight and no multi-victim queue, global writeback arbitration, ownership/snoop coherence, or VRAM durability protocol.
