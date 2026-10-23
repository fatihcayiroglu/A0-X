# P109 OFFLINE SYNTHETIC fixtures

These capture bytes were generated from software encoders; they are NOT actual FPGA/ASIC captures or authenticated evidence. The P109 checker only tests consistency.

Run from A0-GPU:

```bash
python tools/a0_p109_verify.py batch --manifest examples/p109/batch.json
python tools/a0_p109_verify.py verify --plan examples/p109/session_1.plan.json --receipt examples/p109/session_1.receipt.json --capture examples/p109/session_1.capture.bin --sent-wire examples/p109/session_1.wire.bin
```
