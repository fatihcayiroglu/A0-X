#!/usr/bin/env python3
"""P217 fail-closed CDC topology guard with deliberately broken RTL variants.

This is source-layout + dynamic mutation evidence, NOT a formal CDC/MTBF or
silicon reset recovery/removal timing proof.
"""
import pathlib
import subprocess
import tempfile

RTL = pathlib.Path("A0-GPU/rtl/display/a0_p216_domain_local_reset_raster.sv")
TB = pathlib.Path("A0-GPU/tests/rtl/a0_p217_adversarial_reset_tb.sv")

REQUIRED = {
    "two host ready edges": "host_ready_q<={host_ready_q[0],1'b1};",
    "two pixel ready edges": "pixel_ready_q<={pixel_ready_q[0],1'b1};",
    "pixel-to-host first stage": "pixel_ready_meta_h_q<=pixel_ready_q[1];",
    "pixel-to-host second stage": "pixel_ready_sync_h_q<=pixel_ready_meta_h_q;",
    "host-to-pixel first stage": "host_ready_meta_p_q<=host_ready_q[1];",
    "host-to-pixel second stage": "host_ready_sync_p_q<=host_ready_meta_p_q;",
    "host release local edge": "always_ff @(posedge host_clk or negedge raw_rst_n)",
    "pixel release local edge": "always_ff @(posedge pixel_clk or negedge raw_rst_n)",
    "host async assert": "assign host_rst_n=raw_rst_n && host_up_q;",
    "pixel async assert": "assign pixel_rst_n=raw_rst_n && pixel_up_q;",
    "source uses host reset": ".clk(host_clk),.rst_n(host_rst_n)",
    "FIFO uses two resets": ".wr_rst_n(host_rst_n),.rd_rst_n(pixel_rst_n)",
    "pixel storage uses pixel reset": "always_ff @(posedge pixel_clk or negedge pixel_rst_n)",
    "two synchronizer directions marked": '(* async_reg="true" *) logic pixel_ready_meta_h_q,pixel_ready_sync_h_q;',
}
MUTANTS = [
    ("bypass_host_second_sync", "pixel_ready_sync_h_q<=pixel_ready_meta_h_q;", "pixel_ready_sync_h_q<=pixel_ready_q[1];"),
    ("bypass_pixel_second_sync", "host_ready_sync_p_q<=host_ready_meta_p_q;", "host_ready_sync_p_q<=host_ready_q[1];"),
    ("bypass_host_up_sync", "if(host_ready_q[1] && pixel_ready_sync_h_q)host_up_q<=1;", "if(host_ready_q[1] && pixel_ready_meta_h_q)host_up_q<=1;"),
    ("bypass_pixel_up_sync", "if(pixel_ready_q[1] && host_ready_sync_p_q)pixel_up_q<=1;", "if(pixel_ready_q[1] && host_ready_meta_p_q)pixel_up_q<=1;"),
    ("ignore_pixel_ready", "if(host_ready_q[1] && pixel_ready_sync_h_q)host_up_q<=1;", "if(host_ready_q[1])host_up_q<=1;"),
    ("ignore_host_ready", "if(pixel_ready_q[1] && host_ready_sync_p_q)pixel_up_q<=1;", "if(pixel_ready_q[1])pixel_up_q<=1;"),
]


def audit(source: str) -> None:
    for label, token in REQUIRED.items():
        if token not in source:
            raise AssertionError(f"P217 topology missing {label}")
    if ".rst_n(fabric_rst_n)" in source or ".host_rst_n(pixel_rst_n)" in source:
        raise AssertionError("P217 combined or swapped host reset reached datapath")
    if source.count("assign both_released=host_rst_n && pixel_rst_n;") != 1:
        raise AssertionError("P217 diagnostic reset status modified")
    if source.count("module a0_p216_split_reset_supervisor") != 1:
        raise AssertionError("P217 expected exactly one supervisor")


def reject_mutant(name: str, broken: str, temp: pathlib.Path) -> None:
    rtl_path = temp / f"{name}.sv"
    exe = temp / f"{name}.vvp"
    rtl_path.write_text(broken, encoding="utf-8")
    result = subprocess.run(
        ["iverilog", "-g2012", "-s", "a0_p217_adversarial_reset_tb",
         "-Pa0_p217_adversarial_reset_tb.REVERSE=0",
         "-o", str(exe), str(rtl_path), str(TB)],
        capture_output=True, text=True, timeout=120, check=False
    )
    if result.returncode != 0:
        raise AssertionError(f"P217 {name} did not compile; invalid mutation: {result.stderr[-1000:]}")
    result = subprocess.run(["vvp", str(exe)], capture_output=True, text=True, timeout=120, check=False)
    if result.returncode == 0 or "FATAL:" not in (result.stdout + result.stderr):
        raise AssertionError(f"P217 mutation escaped detection: {name}: {result.stdout[-500:]}")
    print(f"P217_MUTATION_REJECT name={name}")


def main() -> None:
    original = RTL.read_text(encoding="utf-8")
    audit(original)
    swapped = original.replace(".wr_rst_n(host_rst_n),.rd_rst_n(pixel_rst_n)",
                               ".wr_rst_n(pixel_rst_n),.rd_rst_n(host_rst_n)")
    if swapped == original:
        raise AssertionError("P217 missing FIFO swap mutation target")
    try:
        audit(swapped)
    except AssertionError:
        print("P217_MUTATION_REJECT name=swapped_fifo_reset_domains")
    else:
        raise AssertionError("P217 topology guard accepted swapped FIFO reset")
    with tempfile.TemporaryDirectory(prefix="p217-cdc-mutant-") as dirname:
        temp = pathlib.Path(dirname)
        for name, old, new in MUTANTS:
            if original.count(old) != 1:
                raise AssertionError(f"P217 unexpected mutation target count: {name}")
            reject_mutant(name, original.replace(old, new), temp)
    print("P217_CDC_MUTATION_GUARD_PASS dynamic_mutants=6 topology_mutants=1 baseline_rtl=1")


if __name__ == "__main__":
    main()
