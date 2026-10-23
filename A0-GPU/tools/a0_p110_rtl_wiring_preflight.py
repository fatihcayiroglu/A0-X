#!/usr/bin/env python3
"""P110 structural preflight for the P106 host-to-graphics RTL integration.

Pure source-level checks; this is NOT elaboration, simulation, synthesis, or
proof of correct widths, timing, handshakes, performance, or physical behavior.
Rejects missing source files, missing/duplicate/unknown named ports, missing
expected instances, and unexpected references to known sibling modules in the audited hierarchy.
"""
from __future__ import annotations

import argparse
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path
import re

SOURCES = (
    'a0_graphics_command_frontend_p43.sv',
    'a0_triangle_coverage_p38.sv',
    'a0_p59_scissor_coverage.sv',
    'a0_p68_depth_compare.sv',
    'a0_p70_rgb_blend.sv',
    'a0_triangle_scissor_depth_blend_p102.sv',
    'a0_sync_frame_scanout_p42.sv',
    'a0_command_dual_bank_scanout_p104.sv',
    'a0_host_command_rx_p106.sv',
    'a0_host_result_tx_p46.sv',
    'a0_scanout_frame_guard_p47.sv',
    'a0_scanout_telemetry_tx_p48.sv',
    'a0_host_tx_fair_arbiter_p49.sv',
    'a0_host_fragment_dual_bank_bridge_p106.sv',
)
# Deliberately explicit topology; if RTL topology changes, this contract must
# be reviewed and updated rather than silently accepting new/removed edges.
EDGES = {
    'a0_triangle_scissor_depth_blend_p102': {
        'a0_triangle_coverage_p38': 1,
        'a0_p59_scissor_coverage': 1,
        'a0_p68_depth_compare': 1,
        'a0_p70_rgb_blend': 1,
    },
    'a0_command_dual_bank_scanout_p104': {
        'a0_graphics_command_frontend_p43': 1,
        'a0_triangle_scissor_depth_blend_p102': 1,  # generate loop creates 2 banks
        'a0_sync_frame_scanout_p42': 1,
    },
    'a0_host_fragment_dual_bank_bridge_p106': {
        'a0_host_command_rx_p106': 1,
        'a0_command_dual_bank_scanout_p104': 1,
        'a0_host_result_tx_p46': 1,
        'a0_scanout_frame_guard_p47': 1,
        'a0_scanout_telemetry_tx_p48': 1,
        'a0_host_tx_fair_arbiter_p49': 1,
    },
}

class WiringError(ValueError):
    pass


def strip_comments(text: str) -> str:
    # Keep strings so they cannot be mistaken for comments by this lexer.
    return re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)


def skip_space(s: str, i: int) -> int:
    while i < len(s) and s[i].isspace():
        i += 1
    return i


def bracket(s: str, i: int, start: str = '(', end: str = ')') -> int:
    if i >= len(s) or s[i] != start:
        raise WiringError(f'expected {start} at byte {i}')
    depth = 1
    i += 1
    while i < len(s):
        if s[i] == start:
            depth += 1
        elif s[i] == end:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise WiringError(f'unterminated {start} grouping')


def split_top(s: str) -> list[str]:
    tokens = []
    start = 0
    depths = {'(':0, '[':0, '{':0}
    partners = {')':'(', ']':'[', '}':'{'}
    for i, ch in enumerate(s):
        if ch in depths:
            depths[ch] += 1
        elif ch in partners:
            depths[partners[ch]] -= 1
            if depths[partners[ch]] < 0:
                raise WiringError('unbalanced port expression')
        elif ch == ',' and all(v == 0 for v in depths.values()):
            tokens.append(s[start:i].strip())
            start = i+1
    if any(depths.values()):
        raise WiringError('unbalanced port expressions')
    tokens.append(s[start:].strip())
    return tokens


def module_ports(text: str, expected_name: str) -> set[str]:
    m = re.search(r'\bmodule\s+([A-Za-z_]\w*)', text)
    if not m or m.group(1) != expected_name:
        raise WiringError(f'expected module definition {expected_name}')
    i = skip_space(text, m.end())
    if i < len(text) and text[i] == '#':
        i = skip_space(text, i+1)
        i = skip_space(text, bracket(text, i))
    if i >= len(text) or text[i] != '(':
        raise WiringError(f'{expected_name}: missing ANSI port list')
    end = bracket(text, i)
    if text[skip_space(text, end)] != ';':
        raise WiringError(f'{expected_name}: unterminated declaration')
    entries = split_top(text[i+1:end-1])
    names = []
    for entry in entries:
        if not entry:
            raise WiringError(f'{expected_name}: empty port declaration')
        mport = re.search(r'([A-Za-z_]\w*)\s*$', entry)
        if not mport:
            raise WiringError(f'{expected_name}: unrecognized port declaration: {entry}')
        names.append(mport.group(1))
    if len(names) != len(set(names)):
        raise WiringError(f'{expected_name}: duplicate port declaration')
    return set(names)


def named_connections(block: str, parent: str, child: str) -> list[str]:
    names = []
    for entry in split_top(block):
        m = re.fullmatch(r'\.([A-Za-z_]\w*)\s*\((.*)\)', entry, re.S)
        if not m or not m.group(2).strip():
            raise WiringError(f'{parent}->{child}: positional, wildcard or empty port: {entry!r}')
        names.append(m.group(1))
    return names


def find_instances(text: str, child: str, parent: str) -> list[tuple[str, list[str]]]:
    results = []
    for m in re.finditer(r'\b' + re.escape(child) + r'\b', text):
        # Skip module declarations, but not valid instantiations.
        prefix = text[:m.start()].rstrip()
        if re.search(r'\bmodule\s*$', prefix):
            continue
        i = skip_space(text, m.end())
        if i < len(text) and text[i] == '#':
            i = skip_space(text, i+1)
            i = skip_space(text, bracket(text, i))
        identifier = re.match(r'[A-Za-z_]\w*', text[i:])
        if not identifier:
            continue
        inst = identifier.group()
        i = skip_space(text, i+len(inst))
        if i >= len(text) or text[i] != '(':
            continue
        end = bracket(text, i)
        if text[skip_space(text, end)] != ';':
            continue
        names = named_connections(text[i+1:end-1], parent, child)
        results.append((inst, names))
    return results


def audit(root: Path) -> dict:
    source_dir = root/'rtl'/'graphics'
    texts, ports, hashes = {}, {}, {}
    for filename in SOURCES:
        path = source_dir/filename
        if not path.is_file():
            raise WiringError(f'missing source file: {filename}')
        payload = path.read_bytes()
        name = path.stem
        content = strip_comments(payload.decode('utf-8'))
        ports[name] = module_ports(content, name)
        texts[name] = content
        hashes[filename] = sha256(payload).hexdigest()
    checked_instances = 0
    checked_connections = 0
    counts = {}
    for parent, children in EDGES.items():
        source = texts[parent]
        counts[parent] = {}
        for child, needed in children.items():
            found = find_instances(source, child, parent)
            counts[parent][child] = len(found)
            if len(found) != needed:
                raise WiringError(f'{parent}->{child}: expected {needed} instances, found {len(found)}')
            for inst, names in found:
                duplicates = [p for p, n in Counter(names).items() if n > 1]
                unknown = sorted(set(names) - ports[child])
                missing = sorted(ports[child] - set(names))
                if duplicates or unknown or missing:
                    raise WiringError(f'{parent}->{child} {inst}: duplicate={duplicates} '
                                      f'unknown={unknown} missing={missing}')
                checked_instances += 1
                checked_connections += len(names)
    # Check for additional references to other modules in the bounded graph.
    # This is deliberately NOT a complete SystemVerilog elaborator.
    all_names = set(texts)
    for parent in EDGES:
        allowed = set(EDGES[parent])
        for other in sorted(all_names - allowed - {parent}):
            found = find_instances(texts[parent], other, parent)
            if found:
                raise WiringError(f'{parent}: unreviewed dependency {other}')
    return {
        'schema': 'A0-P110-STATIC-WIRING-v1', 'status': 'PASS',
        'qualification': 'SOURCE_STRUCTURE_ONLY_NOT_ELABORATED',
        'source_files': len(SOURCES), 'instances_checked': checked_instances,
        'named_connections_checked': checked_connections,
        'design_edges': counts, 'source_sha256': hashes,
        'rtl_compiled': False, 'rtl_simulated': False,
        'physical_gpu_proven': False,
    }


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument('--json', type=Path, help='write result JSON')
    args = p.parse_args()
    try:
        result = audit(args.root)
    except (WiringError, OSError, UnicodeDecodeError) as exc:
        print('P110_STATIC_PREFLIGHT_FAIL:', str(exc))
        return 1
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2, sort_keys=True)+'\n')
    print('P110_STATIC_PREFLIGHT_PASS:', result['source_files'], 'sources,',
          result['instances_checked'], 'instances,',
          result['named_connections_checked'], 'named ports; NOT RTL simulation')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
