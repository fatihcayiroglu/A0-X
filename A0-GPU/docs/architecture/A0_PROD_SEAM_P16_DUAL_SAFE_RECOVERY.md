# PROD-SEAM-P16 — dual-domain recovery-safe join

P16 freezes P15 and closes a reset-driven read-ID ABA gap. Drained live-read counters alone do not prove that a very late or duplicate pre-recovery backend read response can no longer arrive after P15 resets the predecessor read-generation state.

P16 therefore accepts **two independent recovery-safe acknowledgements** during an active P15 recovery epoch: write-status reuse-safe and read-response/epoch reuse-safe. Neither acknowledgement alone can reach P15. Only their joined handshake is forwarded to P15's existing recovery-safe input. Early acknowledgements outside an active recovery are not retained, the two acknowledgements may arrive in either order, and the join rearms after recovery completion.

This remains bounded recovery plumbing, not full coherence or a VRAM controller.
