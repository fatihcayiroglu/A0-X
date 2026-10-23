#!/usr/bin/env python3

import argparse
import io
import json
import math
import sys
from contextlib import redirect_stdout
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SIM_DIR = ROOT / "sim"

sys.path.insert(0, str(SIM_DIR))


from a0_asm import assemble_source
from a0_sim import (
    A0GPU,
    TimingConfig,
    TimingWorkgroupScheduler,
    WAVE_SIZE,
    WorkgroupState,
    f32_to_bits,
)


POLICIES = (
    "lrr",
    "gto",
    "oldest_ready",
    "a0_adaptive_v0",
)

WAVE_COUNTS = (2, 4, 8)

WORKLOADS = (
    "latency_hiding",
    "cache_fits_l2",
    "cache_thrashes_l2",
    "vrf_clean",
    "vrf_conflict",
)


def build_waves(workload, wave_count):
    workgroup = WorkgroupState()
    waves = []

    for wave_id in range(wave_count):
        gpu = A0GPU(
            workgroup=workgroup,
            wave_id=wave_id,
        )

        if workload == "latency_hiding":
            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = (
                    f32_to_bits(1.0)
                )
                gpu.vector_regs[2][thread] = (
                    f32_to_bits(2.0)
                )

            source = """
                VFADD V3, V1, V2
                VFADD V4, V3, V2
                VFADD V5, V4, V2
                VFADD V6, V5, V2
                VFADD V7, V6, V2
                HALT
            """

        elif workload in {
            "cache_fits_l2",
            "cache_thrashes_l2",
        }:
            base = wave_id * 128
            gpu.scalar_regs[0] = base

            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = thread
                gpu.memory[base + thread] = (
                    1000 + wave_id * 100 + thread
                )

            source = """
                VLOADX V8,  S0, V1, 0
                VLOADX V9,  S0, V1, 0
                VLOADX V10, S0, V1, 0
                VLOADX V11, S0, V1, 0
                HALT
            """

        elif workload == "vrf_clean":
            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = (
                    thread + wave_id
                )
                gpu.vector_regs[2][thread] = 3
                gpu.vector_regs[3][thread] = 7

            source = """
                VADD V8,  V1, V2
                VADD V9,  V2, V3
                VADD V10, V1, V2
                VADD V11, V2, V3
                HALT
            """

        elif workload == "vrf_conflict":
            for thread in range(WAVE_SIZE):
                gpu.vector_regs[1][thread] = (
                    thread + wave_id
                )
                gpu.vector_regs[2][thread] = 3
                gpu.vector_regs[5][thread] = 5
                gpu.vector_regs[6][thread] = 6

            source = """
                VADD V8,  V1, V5
                VADD V9,  V2, V6
                VADD V10, V1, V5
                VADD V11, V2, V6
                HALT
            """

        else:
            raise ValueError(
                f"Unknown SIM15 workload: {workload}"
            )

        gpu.load_program(
            assemble_source(source)
        )

        waves.append(gpu)

    return waves


def workload_config(workload, policy):
    common = {
        "scheduler_policy": policy,
        "issue_width": 1,
    }

    if workload == "latency_hiding":
        return TimingConfig(
            **common,
            fp_add_latency=4,
            vector_frontend_model="ideal",
        )

    if workload == "cache_fits_l2":
        return TimingConfig(
            **common,
            vector_frontend_model="ideal",
            cache_line_words=16,
            l1_capacity_lines=2,
            l2_capacity_lines=16,
            l1_hit_latency=2,
            l2_hit_latency=10,
            global_memory_latency=30,
            global_memory_transaction_penalty=0,
        )

    if workload == "cache_thrashes_l2":
        return TimingConfig(
            **common,
            vector_frontend_model="ideal",
            cache_line_words=16,
            l1_capacity_lines=2,
            l2_capacity_lines=4,
            l1_hit_latency=2,
            l2_hit_latency=10,
            global_memory_latency=30,
            global_memory_transaction_penalty=0,
        )

    return TimingConfig(
        **common,
        vector_frontend_model="rtl6b_coarse",
        physical_lanes=8,
        vrf_bank_count=4,
        vrf_read_ports_per_bank=1,
        vrf_read_latency=1,
        vrf_request_cycles=1,
        vector_retire_cycles=1,
    )


def architectural_fingerprint(waves):
    return tuple(
        (
            wave.pc,
            wave.halted,
            tuple(
                tuple(register)
                for register in wave.vector_regs
            ),
            tuple(wave.scalar_regs),
        )
        for wave in waves
    )


def run_case(workload, wave_count, policy):
    waves = build_waves(
        workload,
        wave_count,
    )

    scheduler = TimingWorkgroupScheduler(
        waves,
        workload_config(
            workload,
            policy,
        ),
    )

    with redirect_stdout(io.StringIO()):
        result = scheduler.run()

    result = dict(result)
    result.update(
        {
            "workload": workload,
            "wave_count": wave_count,
            "policy": policy,
        }
    )

    return (
        result,
        architectural_fingerprint(waves),
    )


def geometric_mean(values):
    if not values:
        return 0.0

    return math.exp(
        sum(math.log(value) for value in values)
        / len(values)
    )


def run_study():
    results = []
    fingerprints = {}

    for workload in WORKLOADS:
        for wave_count in WAVE_COUNTS:
            reference = None

            for policy in POLICIES:
                result, fingerprint = run_case(
                    workload,
                    wave_count,
                    policy,
                )

                results.append(result)

                key = (workload, wave_count)

                if reference is None:
                    reference = fingerprint
                    fingerprints[key] = fingerprint

                elif fingerprint != reference:
                    raise RuntimeError(
                        "SIM15 architectural mismatch: "
                        f"workload={workload} "
                        f"waves={wave_count} "
                        f"policy={policy}"
                    )

    lrr_cycles = {
        (
            result["workload"],
            result["wave_count"],
        ): result["cycles"]
        for result in results
        if result["policy"] == "lrr"
    }

    policy_summary = {}

    for policy in POLICIES:
        policy_results = [
            result
            for result in results
            if result["policy"] == policy
        ]

        speedups = []
        worst_regression = 0.0

        for result in policy_results:
            key = (
                result["workload"],
                result["wave_count"],
            )

            baseline = lrr_cycles[key]
            speedup = baseline / result["cycles"]
            speedups.append(speedup)

            regression = (
                result["cycles"] / baseline
            ) - 1.0

            worst_regression = max(
                worst_regression,
                regression,
            )

        policy_summary[policy] = {
            "geomean_speedup_vs_lrr": (
                geometric_mean(speedups)
            ),
            "worst_cycle_regression_vs_lrr": (
                worst_regression
            ),
            "total_cycles": sum(
                result["cycles"]
                for result in policy_results
            ),
            "total_dram_accesses": sum(
                result["dram_accesses"]
                for result in policy_results
            ),
            "total_frontend_stall_events": sum(
                result["frontend_stall_events"]
                for result in policy_results
            ),
            "total_scheduler_switches": sum(
                result["scheduler_switches"]
                for result in policy_results
            ),
        }

    return {
        "schema": "a0.sim15.scheduler-study.v1",
        "policies": list(POLICIES),
        "workloads": list(WORKLOADS),
        "wave_counts": list(WAVE_COUNTS),
        "results": results,
        "policy_summary": policy_summary,
        "architectural_equivalence": True,
    }


def print_report(report):
    print(
        "workload,waves,policy,cycles,ipc,dram,"
        "l1_hits,frontend_stalls,vrf_penalty,switches"
    )

    for result in report["results"]:
        print(
            f"{result['workload']},"
            f"{result['wave_count']},"
            f"{result['policy']},"
            f"{result['cycles']},"
            f"{result['ipc']:.6f},"
            f"{result['dram_accesses']},"
            f"{result['l1_hits']},"
            f"{result['frontend_stall_events']},"
            f"{result['vrf_conflict_penalty_cycles']},"
            f"{result['scheduler_switches']}"
        )

    print()

    for policy in POLICIES:
        summary = report["policy_summary"][policy]

        print(
            "SIM15_POLICY_SCORE "
            f"policy={policy} "
            "geomean_speedup_vs_lrr="
            f"{summary['geomean_speedup_vs_lrr']:.6f} "
            "worst_cycle_regression_vs_lrr="
            f"{summary['worst_cycle_regression_vs_lrr']:.6f} "
            f"total_cycles={summary['total_cycles']} "
            "total_frontend_stalls="
            f"{summary['total_frontend_stall_events']} "
            f"total_dram={summary['total_dram_accesses']}"
        )

    print("SIM15_ARCHITECTURAL_EQUIVALENCE=PASS")
    print("SIM15_SCHEDULER_STUDY=PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--json-out",
        type=Path,
    )

    args = parser.parse_args()

    report = run_study()
    print_report(report)

    if args.json_out is not None:
        args.json_out.parent.mkdir(
            parents=True,
            exist_ok=True,
        )

        args.json_out.write_text(
            json.dumps(
                report,
                indent=2,
                sort_keys=True,
            )
            + "\n"
        )


if __name__ == "__main__":
    main()
