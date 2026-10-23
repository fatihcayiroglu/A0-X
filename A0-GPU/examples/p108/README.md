P108 examples are simulated writer callback return sequences, not live device logs.
Use `tools/a0_p108_transfer.py simulate` with `../p107/session.json` as the plan.
`success_simulated.json`: complete logical host acceptance.
`partial_timeout_simulated.json`: first five bytes accepted then progress stops -> uncertain.
`--timeout 5` makes the third event cross the timeout threshold.
Neither scenario proves any physical device reset, receipt or execution.
