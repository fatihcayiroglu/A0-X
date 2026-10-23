#!/usr/bin/python3
"""Exact P36 raw simulation evidence parser; does not execute DUTs or gates.

The counts below come from the six preserved development simulation logs.
The enclosing canonical audit must independently bind source identity, argv,
exit status, tool identity, diagnostics and containment. This parser alone
cannot qualify a gate, prove hardware behavior or declare a milestone closed.
"""

import argparse
import json
from pathlib import Path
import re


COMPONENT = (
    "EMPTY_ACQUIRE_EXACT_IDENTITY",
    "RELEASE_ENROLLS_ALL_RAW_PORTS_AND_DRAINS_REAL_TERMINALS",
    "SAME_EDGE_STORE_SUCCESS_AND_ABORT_ACCOUNTED_ONCE",
    "BACKPRESSURED_RESPONSE_STABLE_WITH_YOUNGER_REQUESTS_AND_EVENTS",
    "STORE_FAULT_HELD_BEFORE_CUT_REQUIRES_REAL_ABORT_AND_RECOVERY",
    "CUT_AND_DRAIN_FAULTS_STICK_UNTIL_REAL_QUIET",
    "INVALID_MODE_HAS_SEPARATE_ERROR_RESPONSE",
    "HISTORICAL_OUTSIDE_EVENTS_DO_NOT_TAINT_NEXT_FENCE",
    "LANE_MASK_CHANGE_FAILS_CLOSED",
    "INACTIVE_LANE_ADDRESS_CHANGE_FAILS_CLOSED",
    "INACTIVE_LANE_DATA_CHANGE_FAILS_CLOSED",
    "SOURCE_WITHDRAWAL_CANNOT_COMPLETE_ENROLLED_STORE",
    "SIMULTANEOUS_READY_ABORT_IS_PROTOCOL_FAILURE",
    "INHERITED_PROTOCOL_FAILURE_PREVENTS_SUCCESS_RESPONSE",
)

INTEGRATED = (
    "EMPTY_FENCE_EXACT_RESPONSE",
    "DIRTY_RESIDENT_DRAIN_NOT_FLUSH_AND_LATER_EXACT_WB",
    "OUTSTANDING_READ_DELIVERY_DRAINS_FENCE",
    "SAME_EDGE_READ_DELIVERY_AND_FENCE_CUT",
    "SAME_EDGE_ALL_STORE_PORTS_CAPTURE_AND_NEW_ADMISSION_BLOCK",
    "CAPTURED_FULL_STORE_PAYLOAD_AND_BACKEND_PROMISE_BACKPRESSURE",
    "LIVE_WB_EXACT_PAYLOAD_AND_SAME_EDGE_STATUS_CUT",
    "HELD_ARCHITECTURAL_RETIRE_AND_SAME_EDGE_RETIRE_CUT",
    "MIXED_PUBLIC_READ_WB_STORE_AND_HELD_ATOMIC_RETIRE",
    "MULTIPLE_STORE_PORTS_INDEPENDENT_TERMINAL_ACCOUNTING",
    "STORE_ABORT_FAULT_BACKPRESSURE_SELECTIVE_REARM",
    "READ_FAULT_AND_ATOMIC_FAULT_REQUIRE_REAL_DELIVERY_RETIRE",
    "WB_TERMINAL_FAILURE_RETAINED_PAYLOAD_AND_RECOVERY_DRAIN",
    "HELD_FENCE_RESPONSE_IDENTITY_AND_ALL_YOUNGER_DOMAINS_BLOCKED",
    "P30_GENERATION_STALE_STORE_STATUS_CANNOT_RELEASE_FENCE",
    "INVALID_MODE_EXACT_ERROR_AND_FRESH_FENCE_IGNORES_HISTORY",
    "FULL_RETIRED_TABLE_NOT_LIVE_WORK_AND_POST_FENCE_NAMESPACE_PROGRESS",
)

SCENARIOS = {"component": COMPONENT, "integrated": INTEGRATED}
STATUS_REJECTS_SEMANTICS = (
    "status_rejects counts clock-edge observations of the sticky "
    "store_status_rejected_o signal; it is not a rejected-packet count. "
    "stale_packets=1 is the independently injected stale STORE status count."
)
SUITES = {
    "component": {
        "scenario_prefix": "P36_FENCE_SCENARIO_PASS",
        "summary_prefix": "P36_FENCE_CONTROLLER_PASS",
        "testbench": "a0_memory_drain_fence_controller_tb.sv",
        "finish_line": 300,
    },
    "integrated": {
        "scenario_prefix": "P36_INTEGRATED_SCENARIO_PASS",
        "summary_prefix": "P36_INTEGRATED_PASS",
        "testbench": "a0_production_atomic_fenced_subsystem_tb.sv",
        "finish_line": 758,
    },
}


class P36BehaviorError(ValueError):
    """The supplied raw text fails the frozen P36 behavioral contract."""


def _variant(variant):
    if type(variant) is not int or variant not in (0, 1, 2):
        raise P36BehaviorError("P36_EXPECTED_INTEGER_VARIANT_0_1_2")


def expected_component(variant):
    _variant(variant)
    return {
        "variant": variant, "ports": variant + 2, "lanes": variant + 1,
        "scenarios": 14, "checks": (172, 174, 176)[variant],
        "fences": 14, "responses": 8, "completions": 8 + 2 * variant,
        "aborts": 3, "faulted": 4, "protocol_cases": 6,
    }


def expected_integrated(variant):
    _variant(variant)
    return {
        "variant": variant, "scenarios": 17,
        "checks": (9490, 10531, 12613)[variant],
        "fence_accepts": 19, "fence_returns": 19, "fence_errors": 4,
        "atomic_accepts": 16, "atomic_retires": 16, "allocations": 16,
        "duplicates": 0, "replay_packets": 0,
        "reads": 13, "read_returns": 13, "wb": 5, "wb_returns": 5,
        "wb_successes": 4, "clients": 9, "client_returns": 9,
        "stores": 11, "store_returns": 11, "store_successes": 10,
        "port0_retires": 5, "port1_retires": 3, "aborts": 1,
        "store_rearms": 1, "wb_recoveries": 1, "wb_certificates": 1,
        "stale_packets": 1, "status_rejects": 162,
    }


def _audit(text, suite, variant):
    _variant(variant)
    if type(text) is not str or "\x00" in text:
        raise P36BehaviorError("P36_EXPECTED_RAW_TEXT_WITHOUT_NUL")
    contract = SUITES[suite]
    expected = (expected_component if suite == "component" else expected_integrated)(variant)
    names = SCENARIOS[suite]
    lines = text.splitlines()
    # Every line is accounted for: scenarios, summary, normal finish, 3 reports.
    if len(lines) != len(names) + 5:
        raise P36BehaviorError("P36_EXACT_RAW_LINE_COUNT")
    markers = [
        f"{contract['scenario_prefix']} id={number} name={name}"
        for number, name in enumerate(names, 1)
    ]
    if lines[:len(names)] != markers:
        raise P36BehaviorError("P36_EXACT_ORDERED_SCENARIO_ID_NAME_SET")
    # Ordered, unique known fields; canonical decimal syntax; no extra suffix.
    fields = " ".join(f"{key}=(?P<{key}>0|[1-9][0-9]*)" for key in expected)
    summary = re.fullmatch(re.escape(contract["summary_prefix"]) + " " + fields, lines[len(names)])
    if summary is None:
        raise P36BehaviorError("P36_EXACT_ONE_SUMMARY_FIELD_SCHEMA")
    actual = {key: int(value) for key, value in summary.groupdict().items()}
    if actual != expected:
        raise P36BehaviorError(f"P36_EXACT_COUNTS expected={expected!r} observed={actual!r}")
    footer = lines[len(names) + 1:]
    finish_pattern = (
        r"- [^\r\n]+/" + re.escape(contract["testbench"])
        + ":" + str(contract["finish_line"]) + r": Verilog \$finish"
    )
    if re.fullmatch(finish_pattern, footer[0]) is None:
        raise P36BehaviorError("P36_EXACT_TESTBENCH_NORMAL_FINISH")
    if footer[1] != "- S i m u l a t i o n   R e p o r t: Verilator 5.050 2026-07-01":
        raise P36BehaviorError("P36_EXACT_SIMULATION_REPORT_VERSION")
    if re.fullmatch(
        r"- Verilator: \$finish at [1-9][0-9]*(?:fs|ps|ns|us|ms|s); "
        r"walltime [0-9]+\.[0-9]+ s; speed [0-9]+\.[0-9]+ [a-z]+/s", footer[2]
    ) is None:
        raise P36BehaviorError("P36_NORMAL_FINISH_TIMING_REPORT")
    if re.fullmatch(
        r"- Verilator: cpu [0-9]+\.[0-9]+ s on 1 threads; allocated [0-9]+ MB", footer[3]
    ) is None:
        raise P36BehaviorError("P36_NORMAL_FINISH_RESOURCE_REPORT")
    # Strict full-line grammar above also rejects all warning/error chatter.
    return actual


def audit_component(text, variant):
    """Return exact component counters or raise; no qualification markers."""
    return _audit(text, "component", variant)


def audit_integrated(text, variant):
    """Return exact integrated counters; status_rejects is sticky observations."""
    return _audit(text, "integrated", variant)


def _negative_texts(text, suite, variant):
    """In-memory evidence corruption cases; never mutates an existing log."""
    lines = text.splitlines()
    names = SCENARIOS[suite]
    summary_index = len(names)
    contract = SUITES[suite]
    expected = (expected_component if suite == "component" else expected_integrated)(variant)
    yield "empty", "", variant
    yield "diagnostic", "%Warning-UNUSEDSIGNAL: invalid\n" + text, variant
    yield "unknown_evidence", text + "P36_UNPROVEN_PASS\n", variant
    yield "duplicate_summary", text + lines[summary_index] + "\n", variant
    yield "missing_summary", "\n".join(lines[:summary_index] + lines[summary_index + 1:]), variant
    yield "missing_finish", "\n".join(lines[:summary_index + 1] + lines[summary_index + 2:]), variant
    yield "duplicate_finish", text + lines[summary_index + 1] + "\n", variant
    yield "blank_line", "\n" + text, variant
    yield "nul", text + "\x00", variant
    yield "wrong_variant_argument", text, (variant + 1) % 3
    yield "boolean_variant", text, True
    yield "tool_version", text.replace("Verilator 5.050", "Verilator 5.032"), variant
    yield "source_basename", text.replace(contract["testbench"], "wrong_tb.sv"), variant
    yield "finish_source_line", text.replace(
        f":{contract['finish_line']}: Verilog $finish",
        f":{contract['finish_line'] + 1}: Verilog $finish"
    ), variant
    yield "no_finish", text.replace("Verilog $finish", "Verilog $stop"), variant
    yield "summary_unknown_field", text.replace(lines[summary_index], lines[summary_index] + " unproven=1"), variant
    yield "summary_duplicate_field", text.replace(lines[summary_index], lines[summary_index] + f" variant={variant}"), variant
    yield "summary_noncanonical_decimal", text.replace(" scenarios=", " scenarios=0", 1), variant
    for number in range(len(names)):
        yield f"scenario_{number + 1}_missing", "\n".join(lines[:number] + lines[number + 1:]), variant
        yield f"scenario_{number + 1}_duplicate", "\n".join(lines[:number] + [lines[number]] + lines[number:]), variant
        altered = lines.copy()
        altered[number] += "_UNPROVEN"
        yield f"scenario_{number + 1}_unknown", "\n".join(altered), variant
    reordered = lines.copy()
    reordered[0], reordered[1] = reordered[1], reordered[0]
    yield "scenario_reorder", "\n".join(reordered), variant
    for key, value in expected.items():
        changed = re.sub(rf"(?<= ){key}=[0-9]+(?= |$)", f"{key}={value + 1}", lines[summary_index])
        altered = lines.copy()
        altered[summary_index] = changed
        yield f"counter_{key}_changed", "\n".join(altered), variant
    fields = lines[summary_index].split(" ")
    fields[1], fields[2] = fields[2], fields[1]
    altered = lines.copy()
    altered[summary_index] = " ".join(fields)
    yield "summary_fields_reordered", "\n".join(altered), variant


def selftest_from_logs(component_logs, integrated_logs):
    """Validate six raw logs and corruption rejection using only text parsing."""
    if len(component_logs) != 3 or len(integrated_logs) != 3:
        raise P36BehaviorError("P36_SELFTEST_REQUIRES_THREE_LOGS_PER_SUITE")
    accepted = 0
    rejected = 0
    per_log = []
    for suite, logs, parser in (
        ("component", component_logs, audit_component),
        ("integrated", integrated_logs, audit_integrated),
    ):
        for variant, text in enumerate(logs):
            counts = parser(text, variant)
            accepted += 1
            local_rejected = 0
            for label, corrupt, supplied_variant in _negative_texts(text, suite, variant):
                try:
                    parser(corrupt, supplied_variant)
                except P36BehaviorError:
                    rejected += 1
                    local_rejected += 1
                else:
                    raise P36BehaviorError(f"P36_PARSER_ACCEPTED_CORRUPTION suite={suite} variant={variant} mutation={label}")
            per_log.append({"suite": suite, "variant": variant, "counts": counts, "corruptions_rejected": local_rejected})
    return {
        "classification": "PARSER_SELF_TEST_ONLY",
        "parser_selftest": "PASS", "existing_raw_logs_accepted": accepted,
        "in_memory_corruptions_rejected": rejected, "per_log": per_log,
        "status_rejects_semantics": STATUS_REJECTS_SEMANTICS,
        "dut_executions": 0, "canonical_qualification": "NOT_PERFORMED",
        "existing_log_mutation": "NONE",
    }


def _main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--selftest", action="store_true", required=True)
    cli.add_argument("--component-dir", type=Path, required=True)
    cli.add_argument("--integrated-dir", type=Path, required=True)
    options = cli.parse_args()
    component_logs = [
        (options.component_dir / f"{4 + 3 * variant:03d}_component_{variant}_sim.log").read_text(encoding="utf-8")
        for variant in range(3)
    ]
    integrated_logs = [
        (options.integrated_dir / f"{4 + 3 * variant:03d}_integrated_{variant}_sim.log").read_text(encoding="utf-8")
        for variant in range(3)
    ]
    print(json.dumps(selftest_from_logs(component_logs, integrated_logs), sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    _main()
