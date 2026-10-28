#!/usr/bin/env python3
"""P218 scoped CDC crossing inventory and fail-closed regression gate.

This is a source-level audit of the versioned P216 two-clock island, not an
exhaustive formal CDC proof or a board timing-closure certification.
"""
import argparse
import collections
import json
import pathlib
import re

RTL = pathlib.Path("A0-GPU/rtl/display/a0_p216_domain_local_reset_raster.sv")
CONTRACT = pathlib.Path("A0-GPU/constraints/p218_experimental_clock_contract.json")
MODULE_RE = re.compile(r"\bmodule\s+([A-Za-z_]\w*)[\s\S]*?\bendmodule\b")
ALWAYS_RE = re.compile(r"always_ff\s*@\(\s*posedge\s+(\w+)(?:\s+or[^)]*)?\)")
ASSIGN_RE = re.compile(r"\b([A-Za-z_]\w*)\s*(?:\[[^]]+\])?\s*<=\s*([^;]+);")
NAME_RE = re.compile(r"[A-Za-z_]\w*")
EXPECTED_MODULE_CLOCKS = {
    "a0_p216_split_reset_supervisor": ["host_clk", "pixel_clk"],
    "a0_p216_domain_local_reset_raster": [],
    "a0_p216_split_reset_fifo": ["wr_clk", "wr_clk", "rd_clk", "rd_clk"],
    "a0_p216_split_reset_queue": ["pixel_clk"],
    "a0_p216_split_domain_raster": ["pixel_clk", "pixel_clk"],
}
EXPECTED_REGISTER_CROSSINGS = {
    ("a0_p216_split_reset_supervisor", "pixel_ready_q", "pixel_clk", "pixel_ready_meta_h_q", "host_clk"),
    ("a0_p216_split_reset_supervisor", "host_ready_q", "host_clk", "host_ready_meta_p_q", "pixel_clk"),
    ("a0_p216_split_reset_fifo", "rgray_q", "rd_clk", "w_rgray_meta_q", "wr_clk"),
    ("a0_p216_split_reset_fifo", "wgray_q", "wr_clk", "r_wgray_meta_q", "rd_clk"),
}
REQUIRED_PROTOCOL_TOKENS = {
    "host fault synchronizer first stage": "pix_fault_meta_q<=source_fault;",
    "host fault synchronizer second stage": "pix_fault_q<=pix_fault_meta_q;",
    "host P210 producer reset": ".clk(host_clk),.rst_n(host_rst_n)",
    "dual clock FIFO instance": ".wr_clk(host_clk),.rd_clk(pixel_clk)",
    "split FIFO reset instance": ".wr_rst_n(host_rst_n),.rd_rst_n(pixel_rst_n)",
    "FIFO payload read guarded by Gray pointer": "wire prefetch=r_release_q && !rd_valid_q && !empty;",
    "FIFO Gray full check": "wire full=(wgray_q==",
    "FIFO read sync first stage": "r_wgray_meta_q<=wgray_q;",
    "FIFO read sync second stage": "r_wgray_sync_q<=r_wgray_meta_q;",
    "FIFO write sync first stage": "w_rgray_meta_q<=rgray_q;",
    "FIFO write sync second stage": "w_rgray_sync_q<=w_rgray_meta_q;",
    "FIFO host reset": "assign wr_ready=wr_rst_n && w_release_q && !full;",
    "FIFO pixel reset": "assign rd_valid=rd_rst_n && r_release_q && rd_valid_q;",
    "reset releases are local": "assign both_released=host_rst_n && pixel_rst_n;",
}
MUTATIONS = [
    ("bypass_ready_host_sync", "pixel_ready_sync_h_q<=pixel_ready_meta_h_q;", "pixel_ready_sync_h_q<=pixel_ready_q[1];"),
    ("bypass_ready_pixel_sync", "host_ready_sync_p_q<=host_ready_meta_p_q;", "host_ready_sync_p_q<=host_ready_q[1];"),
    ("bypass_gray_host_sync", "w_rgray_sync_q<=w_rgray_meta_q;", "w_rgray_sync_q<=rgray_q;"),
    ("bypass_gray_pixel_sync", "r_wgray_sync_q<=r_wgray_meta_q;", "r_wgray_sync_q<=wgray_q;"),
    ("bypass_host_fault_sync", "pix_fault_q<=pix_fault_meta_q;", "pix_fault_q<=source_fault;"),
    ("remove_fifo_empty_guard", "wire prefetch=r_release_q && !rd_valid_q && !empty;", "wire prefetch=r_release_q && !rd_valid_q;"),
    ("swap_fifo_reset_domains", ".wr_rst_n(host_rst_n),.rd_rst_n(pixel_rst_n)", ".wr_rst_n(pixel_rst_n),.rd_rst_n(host_rst_n)"),
    ("remove_ready_crossing", "pixel_ready_meta_h_q<=pixel_ready_q[1];", "pixel_ready_meta_h_q<=host_ready_q[1];"),
    ("swap_reset_raster_ports", ".host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n)", ".host_rst_n(pixel_rst_n),.pixel_rst_n(host_rst_n)"),
]


def inspect_rtl(source: str) -> list[tuple[str, str, str, str, str]]:
    modules = {match.group(1): match.group(0) for match in MODULE_RE.finditer(source)}
    if set(modules) != set(EXPECTED_MODULE_CLOCKS):
        raise AssertionError(f"P218 new/missing clock island modules: {sorted(set(modules)^set(EXPECTED_MODULE_CLOCKS))}")
    for label, token in REQUIRED_PROTOCOL_TOKENS.items():
        if token not in source:
            raise AssertionError(f"P218 missing guarded protocol: {label}")
    if source.count(".host_rst_n(host_rst_n),.pixel_rst_n(pixel_rst_n)") != 3:
        raise AssertionError("P218 split resets not wired to both boundaries")
    if ".rst_n(fabric_rst_n)" in source:
        raise AssertionError("P218 combined status reset reached sequential datapath")
    crosses = set()
    for module, text in modules.items():
        clocks = list(ALWAYS_RE.finditer(text))
        actual = [c.group(1) for c in clocks]
        if sorted(actual) != sorted(EXPECTED_MODULE_CLOCKS[module]):
            raise AssertionError(f"P218 unexpected clocks in {module}: {actual}")
        blocks = []
        for i, event in enumerate(clocks):
            end = clocks[i+1].start() if i+1 < len(clocks) else len(text)
            assignments = [(m.group(1), m.group(2)) for m in ASSIGN_RE.finditer(text[event.end():end])]
            blocks.append((event.group(1), assignments))
        owner = collections.defaultdict(set)
        for clock, assignments in blocks:
            for left, _ in assignments:
                owner[left].add(clock)
        for clock, assignments in blocks:
            for left, right in assignments:
                for identifier in set(NAME_RE.findall(right)):
                    domains = owner.get(identifier, set())
                    if domains and clock not in domains:
                        if len(domains) != 1:
                            raise AssertionError(f"P218 multi-clock drive of {identifier}: {domains}")
                        crosses.add((module, identifier, next(iter(domains)), left, clock))
    if crosses != EXPECTED_REGISTER_CROSSINGS:
        missing = sorted(EXPECTED_REGISTER_CROSSINGS-crosses)
        unexpected = sorted(crosses-EXPECTED_REGISTER_CROSSINGS)
        raise AssertionError(f"P218 unknown/removed direct register crossings missing={missing} extra={unexpected}")
    return sorted(crosses)


def contract() -> dict:
    data = json.loads(CONTRACT.read_text(encoding="utf-8"))
    if (data.get("schema") != "a0-x-ecp5-experimental-clock-contract-v1"
        or data.get("top_module") != "a0_p216_domain_local_reset_raster"
        or data.get("package") != "CABGA381"
        or data.get("device") != "ECP5-85K"
        or data.get("clock_ports") != ["host_clk", "pixel_clk"]
        or data.get("clock_relation") != "asynchronous-independent"
        or data.get("board_pin_map") is not None
        or data.get("board_timing_signoff") is not False
        or data.get("formal_cdc_signoff") is not False
        or data.get("minimum_each_routed_mhz") != 10.0):
        raise AssertionError("P218 cannot invent board pinouts or weaken clock contract")
    return data


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--route", type=pathlib.Path)
    args = parser.parse_args()
    source = RTL.read_text(encoding="utf-8")
    found = inspect_rtl(source)
    spec = contract()
    cases = [
        {
            "module": module,
            "signal": source_sig,
            "source_clock": source_clock,
            "synchronized_into": sink,
            "destination_clock": target_clock,
            "classification": "first-stage-two-flop-synchronizer",
        }
        for module, source_sig, source_clock, sink, target_clock in found
    ]
    cases.extend([
        {"module": "a0_p216_split_reset_queue", "signal": "source_fault",
         "source_clock": "host_clk", "synchronized_into": "pix_fault_meta_q",
         "destination_clock": "pixel_clk", "classification": "two-stage-fault-level"},
        {"module": "a0_p216_split_reset_fifo", "signal": "mem[read/write-pointer]",
         "source_clock": "wr_clk", "synchronized_into": "rd_data_q",
         "destination_clock": "rd_clk", "classification": "dual-port-memory-gray-pointer-handshake"},
    ])
    for name, old, new in MUTATIONS:
        if source.count(old) < 1:
            raise AssertionError(f"P218 missing mutation target {name}")
        broken = source.replace(old, new, 1)
        try:
            inspect_rtl(broken)
        except AssertionError:
            print(f"P218_CDC_MUTATION_REJECT name={name}")
        else:
            raise AssertionError(f"P218 unsafe mutation escaped: {name}")
    report = {
        "scope": "P216 versioned two-clock island, excludes internal P203-P210 source clocks",
        "assurance": "scoped RTL ownership graph plus explicit protocol contract; not formal CDC or board signoff",
        "clock_contract": spec,
        "crossings": cases,
        "mutation_rejections": len(MUTATIONS),
    }
    print("P218_CDC_INVENTORY_PASS direct_register_crossings=4 declared_protocol_crossings=2 total=6")
    print("P218_CDC_NEGATIVE_PASS mutations=9 fail_closed=1")
    if args.route:
        route = json.loads(args.route.read_text(encoding="utf-8"))
        fmax = route.get("fmax", {})
        actual = {}
        for name in spec["clock_ports"]:
            matching = [value["achieved"] for key, value in fmax.items() if name in key]
            if len(matching) != 1 or matching[0] < spec["minimum_each_routed_mhz"]:
                raise AssertionError(f"P218 missing/underfloor routed clock {name}: {fmax}")
            actual[name] = matching[0]
        report["routed_mhz"] = actual
        print("P218_DUAL_CLOCK_ROUTE_CONTRACT_PASS host_mhz=%.2f pixel_mhz=%.2f floor_mhz=%.2f board_signoff=0" %
              (actual["host_clk"], actual["pixel_clk"], spec["minimum_each_routed_mhz"]))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True)+"\n", encoding="utf-8")


if __name__ == "__main__":
    main()
