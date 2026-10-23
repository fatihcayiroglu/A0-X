#!/usr/bin/python3
"""P35 exact raw behavioral accounting, shared by gate and independent re-audit.

This module neither executes tests nor emits gate/CLOSED markers. The contract
rejects missing, duplicate, reordered, unknown or numerically changed evidence.
"""
import re

COMPONENT = (
    'RESET_AND_CERTIFICATE', 'PENDING_REPLAY_RETURN_AND_RESULT_BACKPRESSURE',
    'RESPONSE_LOSS_COMMITTED_REPLAY', 'CHANGED_FINGERPRINT_REJECTED',
    'SOURCE_CONTEXT_SEPARATION_CAS_WINNER', 'FULL_TABLE_REPLAY_PROGRESS',
    'ADDRESS_WIDTH_OPERATION_COMPARE_FINGERPRINT_REJECTED',
    'INVALID_OPCODE_AND_ODD_64_ADDRESS_REJECTED_WHILE_FULL', 'STALE_EPOCH_REJECTED',
    'ALL_32_64_OPERATIONS_OR_EXPLICIT_SINGLEWORD_REJECTION',
    'READ_FAULT_RETAINED_REPLAY_WITHOUT_OWNERSHIP',
    'TAKE_MISS_RETRIES_READ_WITH_ONE_FINAL_EFFECT',
    'CLEAN_FAILED_CAS_AND_REPLAY_PRESERVE_BYTES_AND_DIRTY',
)
RETIRE = (
    'UNISSUED_RESPONSE_REJECTED', 'ALL_KEY_AND_DESCRIPTOR_FIELDS_REQUIRED',
    'HELD_RETIREMENT_STABLE_WITH_OTHER_RESPONSE_AND_DUPLICATE',
    'POST_RETIRE_TRANSPORT_REPLAY_NO_DOUBLE_RETIRE',
    'FINITE_RETIRED_TOMBSTONES_AND_COLLISION',
    'GENERATION_REUSE_WRAP_AND_SAME_EDGE_STALE_RESPONSE',
)
INTEGRATED = (
    'RESET', 'COLD_FILL_ACTUAL_CACHE_RMW_BACKPRESSURE',
    'LOST_RESPONSE_REPLAY_REAL_CACHE', 'MUTATED_DESCRIPTOR_REJECTED',
    'TWO_SOURCE_CAS_SERIAL_ORDER', 'NORMAL_STORE_THEN_ATOMIC_ORDER',
    'ALL_OPERATIONS_OBSERVED_THROUGH_PUBLIC_READ',
    'STORE_RECOVERY_PRESERVES_HELD_ATOMIC_RESULT_AND_DIRTY_LINE',
    'STORE_RECOVERY_PRESERVES_COMMITTED_DEDUP', 'DIRTY_ATOMIC_WRITEBACK_AND_REFILL',
)
RETIRING = (*INTEGRATED[:5],
    'COMMITTED_CAS_WINNER_AND_LOSER_REPLAY_ORIGINAL_OUTCOME', *INTEGRATED[5:],
    'JOINT_NAMESPACE_ADVANCE_REUSE_AND_UNIQUE_RETIREMENT')
SCENARIOS = dict(component=COMPONENT, retire=RETIRE, integrated=INTEGRATED, retiring=RETIRING)


def expected_counts(phase, variant):
    if phase not in SCENARIOS or type(variant) is not int or variant not in range(3):
        raise ValueError('P35_PHASE_VARIANT')
    result = dict(variant=variant, scenarios=len(SCENARIOS[phase]))
    if phase == 'component':
        result.update(checks=(1101,1394,1542)[variant], accepts=41, responses=41,
            effects=(17,28,28)[variant], reads=(19,30,30)[variant],
            epochs=(4,7,7)[variant], probe_misses=1)
    elif phase == 'retire':
        result.update(checks=(227,311,479)[variant], allocations=4<<variant,
            retires=4<<variant, rejects=(15,19,27)[variant], duplicates=2)
    else:
        result.update(reads=3, read_returns=3, wb=1, wb_returns=1,
            stores=1, store_returns=1, aborts=1, rearms=1)
        if phase == 'integrated':
            result.update(checks=(6793,9001,11415)[variant], atomic_accepts=30,
                atomic_returns=30, clients=31, client_returns=31)
        else:
            result.update(checks=(8651,11131,13935)[variant], atomic_accepts=33,
                atomic_returns=28, clients=34, client_returns=34, allocations=28,
                duplicates=5, replay_packets=5)
    return result


def parse_behavior(text, phase, variant):
    expected = expected_counts(phase, variant)
    prefix = 'P35_' + phase.upper()
    evidence = [line for line in text.splitlines() if line.startswith('P35_')]
    names = SCENARIOS[phase]
    markers = [f'{prefix}_SCENARIO_PASS id={number} name={name}'
               for number, name in enumerate(names, 1)]
    if len(evidence) != len(markers)+1 or evidence[:-1] != markers:
        raise ValueError('P35_EXACT_ORDERED_SCENARIO_SET:' + repr(evidence))
    summary = evidence[-1]
    if not summary.startswith(prefix+'_PASS '):
        raise ValueError('P35_EXACT_ONE_SUMMARY')
    fields = summary.removeprefix(prefix+'_PASS ').split(' ')
    if any(re.fullmatch(r'[a-z_]+=[0-9]+', item) is None for item in fields):
        raise ValueError('P35_SUMMARY_FIELD_FORMAT')
    pairs = [item.split('=') for item in fields]
    if len({key for key, value in pairs}) != len(pairs):
        raise ValueError('P35_DUPLICATE_SUMMARY_FIELD')
    actual = {key:int(value) for key, value in pairs}
    if actual != expected:
        raise ValueError('P35_EXACT_COUNTS:expected='+repr(expected)+';actual='+repr(actual))
    if re.search(r'(?im)%Warning|%Error|\bwarning:|\berror:|CHECK_FAILED|watchdog', text):
        raise ValueError('P35_RAW_DIAGNOSTICS')
    if sum('Verilog $finish' in line for line in text.splitlines()) != 1:
        raise ValueError('P35_EXACT_NORMAL_FINISH')
    return actual
