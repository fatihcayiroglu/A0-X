# A0 RTL9D-1 — L2-ready requester-tagged line fabric foundation

## Status

RTL9D-1 introduces an isolated multi-client line-request fabric foundation.

It does not rewire the live core and does not introduce L2 storage.

The purpose of this milestone is to make the line-memory transaction identity
safe for future sharing across multiple compute units.

## Why this milestone exists

The current live core exposes one MSHR-backed line-fill interface.

Its response identity is local to one core:

    {local MSHR entry, line address}

That contract is sufficient while one requester owns the backend interface.

It is not sufficient for a future shared L2 when two independent compute units
may use the same local MSHR entry number concurrently.

RTL9D-1 therefore introduces a requester identity before shared L2 hardware is
added.

## Identity contract

Client-side transaction identity:

    {client_id, local_tag, line_addr}

Downstream transaction identity:

    global_tag = {client_id, local_tag}
    line_addr

`global_tag` is intentionally opaque to later shared-cache logic.

The fabric restores the original `local_tag` when a response returns to the
selected client.

## Request path

The fabric has a parameterized number of clients and one downstream request
port.

Requests are selected using round-robin arbitration.

A selected request is copied into a one-entry output holding register.

Once captured, the downstream request payload is independent of further
changes on the originating client's input.

The output therefore remains stable for the complete duration of downstream
backpressure.

The holding slot can be replaced on the same clock edge that its previous
request is accepted downstream, allowing consecutive requests without an
unnecessary empty cycle.

## Response path

Responses are routed using the requester field embedded in `global_tag`.

A valid response:

- asserts exactly one client response-valid bit;
- restores the client's original local tag;
- preserves line address;
- preserves fault;
- preserves every response-data word.

Responses may arrive in any order.

The fabric does not require response order to match request order.

For non-power-of-two client counts, unused encoded requester IDs are invalid.

A response carrying an invalid requester ID:

- raises `line_resp_tag_error_o`;
- is delivered to no client;
- cannot fan out to multiple clients.

## Parameterization

RTL9D-1 supports:

- `CLIENT_COUNT >= 1`;
- `LOCAL_TAG_W >= 1`;
- parameterized line address width;
- parameterized line word count.

`CLIENT_ID_W` is derived as:

    max(1, ceil(log2(CLIENT_COUNT)))

`GLOBAL_TAG_W` is:

    CLIENT_ID_W + LOCAL_TAG_W

`CLIENT_COUNT=1` remains legal.

Non-power-of-two client counts remain legal.

## Verification contract

The behavioral test proves:

1. reset/idle behavior;
2. global requester-tag encoding;
3. line-address preservation;
4. request stability under downstream backpressure;
5. no acceptance of another requester while a held request is stalled;
6. deterministic round-robin service;
7. no request loss or duplication in the arbitration sequence;
8. out-of-order response routing;
9. original local-tag restoration;
10. line/fault/data response preservation;
11. malformed requester-tag rejection;
12. no malformed-response fanout.

The runner additionally lints `CLIENT_COUNT` variants:

- 1;
- 3;
- 4;
- 5.

## Non-goals

RTL9D-1 does not add:

- L2 cache arrays;
- cache hit/miss policy;
- refill installation;
- L2 MSHRs;
- write allocate;
- dirty state;
- writeback;
- coherence;
- TLB/MMU;
- NoC;
- DRAM scheduling;
- DRAM controller behavior;
- production core rewiring.

## Scope

RTL9D-1 adds exactly five files:

1. `docs/architecture/A0_RTL9D1_LINE_FABRIC_FOUNDATION.md`
2. `rtl/memory/a0_line_request_fabric.sv`
3. `tests/rtl/a0_line_request_fabric_tb.sv`
4. `tests/run_rtl9d1_line_fabric.py`
5. `tests/run_rtl9d1_gate.py`

No existing tracked file changes in this milestone.

`RTL9D1_LINE_FABRIC_FOUNDATION=DEFINED`
