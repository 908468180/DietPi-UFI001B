#!/usr/bin/env python3
"""Patch the MSM8916 device tree for UFI001B.

Wraps dtc to decompile/recompile and performs two well-defined text edits
on the generated DTS (structure mirrors the stock 6.6 DTB of
msm8916-thwc-ufi001c.dtb as shipped by postmarketOS):

  1. --opp-mhz N   : replace the CPU OPP table children with a set of
                     frequencies stepping by 100 MHz up to N MHz
                     (default build uses 1200 => 400/800/1000/1100/1200,
                     the same OPPs proven by the community overclock).
                     N<=0 leaves the stock table untouched (<=998.4 MHz).
                     OPPs carry only opp-hz (no opp-microvolt), exactly
                     like the community recipe.
2. --release-memory : delete /reserved-memory/mpss, venus and mba
                       (the ~97 MiB modem carve-out plus dead venus/mba
                       reservations) while KEEPING wcnss, because the
                       WCNSS-pronto remote processor still needs its
                       memory-region and phandle to bring up Wi-Fi.
 3. --aggressive     : additionally delete /reserved-memory/gps, rmtfs,
                       rfsa and reserved@86680000 (~3.5 MiB of unused
                       modem/GPS-era reservations). tz-apps / tz / smem /
                       hypervisor are always kept as firmware territory.

Run once:  python3 patch_dtb.py --input stock.dtb --output patched.dtb \
              --opp-mhz 1200 --release-memory --aggressive

dtc (device-tree-compiler) must be installed. Use --self-test to verify
the pure-text transforms without dtc.
"""

import argparse
import os
import re
import subprocess
import sys

OPP_START_INDENT = "\t" * 2          # children of /soc/opp-table-cpu

# Stock msm8916 6.6 DTS excerpt mirroring the real structure (self-test only).
FIXTURE_DTS = """/dts-v1/;

/ {
	#address-cells = <0x2>;
	#size-cells = <0x2>;

	memshare {
		memory-region = <&mpss_mem>;
		mpss@0 {
			qcom,smem-state-names = "fatal";
			gps@0 {
				memory-region = <&gps>;
			};
		};
	};

	reserved-memory {
		#address-cells = <0x2>;
		#size-cells = <0x2>;
		ranges;

		mpss_mem: mpss@86800000 {
			reg = <0x0 0x86800000 0x0 0x5500000>;
			no-map;
		};

		wcnss {
			size = <0x0 0x600000>;
			no-map;
		};

		venus {
			size = <0x0 0x500000>;
			no-map;
		};

		mba {
			size = <0x0 0x100000>;
			no-map;
		};

		tz-apps@86000000 {
			reg = <0x0 0x86000000 0x0 0x300000>;
			no-map;
		};

		gps {
			size = <0x0 0x200000>;
			alignment = <0x0 0x100000>;
			alloc-ranges = <0x0 0x86800000 0x0 0x8000000>;
			no-map;
			status = "disabled";
			phandle = <0x16>;
		};

		rmtfs@86700000 {
			compatible = "qcom,rmtfs-mem";
			reg = <0x0 0x86700000 0x0 0xe0000>;
			no-map;
		};

		rfsa@867e0000 {
			reg = <0x0 0x867e0000 0x0 0x20000>;
			no-map;
		};

		reserved@86680000 {
			reg = <0x0 0x86680000 0x0 0x80000>;
			no-map;
		};

		wcnss_mem: wcnss {
			size = <0x0 0x600000>;
			no-map;
		};
	};

	soc {
		#address-cells = <0x2>;
		#size-cells = <0x1>;
		ranges;

		remoteproc@4080000 {
			mpss {
				memory-region = <&mpss_mem>;
			};
		};

		pronto: remoteproc@a204000 {
			memory-region = <&wcnss_mem>;
		};

		cpu0_opp_table: opp-table-cpu {
			compatible = "operating-points-v2";
			opp-shared;

			opp-200000000 {
				opp-hz = /bits/ 64 <200000000>;
			};
			opp-400000000 {
				opp-hz = /bits/ 64 <400000000>;
			};
			opp-800000000 {
				opp-hz = /bits/ 64 <800000000>;
			};
			opp-998400000 {
				opp-hz = /bits/ 64 <998400000>;
			};
		};
	};
};
"""


def read_lines(text):
    return text.splitlines()


def find_node_blocks(lines, header_re, start=0):
    """Return (start_line, end_line) 0-based inclusive for every node whose
    header line matches header_re. Uses brace counting ('{' - '}')."""
    blocks = []
    depth = 0
    i = 0
    while i < len(lines):
        line = lines[i]
        d0 = depth
        opens = line.count("{") - line.count("}")
        if header_re.search(line) and opens > 0 and d0 >= 0:
            # Walk to the closing brace that brings us back to d0.
            j = i
            d = d0
            while j < len(lines):
                d += lines[j].count("{") - lines[j].count("}")
                if d <= d0 and j > i:
                    blocks.append((i, j))
                    i = j
                    depth = d
                    break
                j += 1
            i += 1
            depth = d
            continue
        depth = d0 + opens
        i += 1
    return blocks


def remove_blocks(lines, header_res):
    """Remove all nodes whose header matches any regex in header_res."""
    combined = re.compile("|".join(r.pattern for r in header_res))
    out = []
    i = 0
    removed = []
    while i < len(lines):
        line = lines[i]
        opens = line.count("{") - line.count("}")
        if opens > 0 and combined.search(line):
            blocks = find_node_blocks(lines, combined)
            blk = next((b for b in blocks if b[0] == i), None)
            if blk:
                removed.append(line.strip())
                i = blk[1] + 1
                continue
        out.append(lines[i])
        i += 1
    return out, removed


def opp_names(current_text):
    return sorted(set(int(m.group(1)) for m in
                      re.finditer(r"opp-(\d+)000000", current_text)))


def build_opp_children(freqs_mhz, indent=OPP_START_INDENT):
    lines = []
    for mhz in sorted(freqs_mhz):
        hz = mhz * 1000000
        lines.append("%sopp-%d {" % (indent, hz))
        lines.append("%s\t opp-hz = /bits/ 64 <%d>;" % (indent, hz))
        lines.append("%s};" % indent)
    return lines


def target_freqs(mhz):
    """Community recipe: 400/800 plus 1000..mhz step 100."""
    if mhz is None or mhz <= 0:
        return None
    if mhz < 1000:
        return None          # stock table already covers <= 998.4
    freqs = [400, 800]
    f = 1000
    while f <= mhz:
        freqs.append(f)
        f += 100
    return sorted(set(freqs))


def transform(dts, opts):
    lines = read_lines(dts)

    if opts.get("release_memory"):
        lines, removed = remove_blocks(lines, [
            re.compile(r"^\s*([\w.-]+:\s*)?mpss@86800000\s*\{"),
            re.compile(r"^\s*([\w.-]+:\s*)?venus(@[0-9a-fA-Fx,.-]+)?\s*\{"),
            re.compile(r"^\s*([\w.-]+:\s*)?mba(@[0-9a-fA-Fx,.-]+)?\s*\{"),
            re.compile(r"^\s*([\w.-]+:\s*)?mpss@0\s*\{"),
        ])
        opts["_removed"] = removed

    if opts.get("aggressive"):
        lines, removed = remove_blocks(lines, [
            re.compile(r"^\s*([\w.-]+:\s*)?gps(@[0-9a-fA-Fx,.-]+)?\s*\{"),
            re.compile(r"^\s*([\w.-]+:\s*)?rmtfs@86700000\s*\{"),
            re.compile(r"^\s*([\w.-]+:\s*)?rfsa@867e0000\s*\{"),
            re.compile(r"^\s*([\w.-]+:\s*)?reserved@86680000\s*\{"),
        ])
        opts["_removed"] = opts.get("_removed", []) + removed

    if opts.get("release_memory") or opts.get("aggressive"):
        # Drop dangling phandle references to the removed nodes, but never
        # touch wcnss (its memory-region keeps Wi-Fi alive).
        dead = re.compile(
            r"memory-region\s*=\s*<&(mpss|venus|mba|modem|gps)"
            r"(_mem)?([,\>])")
        lines = [l for l in lines if not dead.search(l)]

    opp_mhz = opts.get("opp_mhz")
    freqs = target_freqs(opp_mhz)
    if freqs is not None:
        table_re = re.compile(r"\bopp-table-cpu\s*\{")
        blocks = find_node_blocks(lines, table_re)
        if not blocks:
            raise RuntimeError("could not locate opp-table-cpu node")
        s, e = blocks[0]
        # Keep the node's own indentation for the regenerated children.
        table_indent = re.match(r"^\s*", lines[s]).group(0)
        child_indent = table_indent + "\t"
        inner = lines[s + 1:e]
        kept = []
        i = 0
        while i < len(inner):
            line = inner[i]
            if re.match(r"^\s*opp-\d+\s*\{", line):
                blocks2 = find_node_blocks(inner, re.compile(r"^\s*opp-\d+\s*\{"))
                blk = next((b for b in blocks2 if b[0] == i), None)
                if blk:
                    i = blk[1] + 1
                    continue
            kept.append(line)
            i += 1

        if not any(re.match(r"^\s*opp-shared\s*;", l) for l in kept):
            kept.append(child_indent + "opp-shared;")

        new_inner = kept + [""] + build_opp_children(freqs, child_indent)
        lines = lines[:s + 1] + new_inner + lines[e:]

    return "\n".join(lines) + "\n"


def run_dtc(args, dts_path, out_path):
    subprocess.run(["dtc", "-I", "dts", "-O", "dtb", dts_path, "-o", out_path],
                   check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="stock .dtb")
    ap.add_argument("--output", help="patched .dtb")
    ap.add_argument("--opp-mhz", type=int, default=0, help="target CPU MHz (0=stock)")
    ap.add_argument("--release-memory", action="store_true", dest="release_memory")
    ap.add_argument("--aggressive", action="store_true", dest="aggressive",
                    help="also drop gps/rmtfs/rfsa/reserved@86680000 "
                         "(keep tz-apps and firmware regions)")
    ap.add_argument("--keep-dts", help="also save intermediate .dts here")
    ap.add_argument("--self-test", action="store_true", help="run transform unit checks only")
    args = ap.parse_args()

    if args.self_test:
        ok = True
        o = transform(FIXTURE_DTS, {"opp_mhz": 1200, "release_memory": True})
        for pat in [re.compile(r"^\s*([\w.-]+:\s*)?mpss@"),
                    re.compile(r"^\s*(venus|mba)(@[0-9a-fA-Fx,.-]+)?\s*\{"),
                    re.compile(r"\bopp-998400000\b"),
                    re.compile(r"mpss_mem")]:
            if pat.search(o):
                print("FAIL: %s still present" % pat.pattern)
                ok = False
        # wcnss must survive the release so Wi-Fi/pronto keeps working.
        if "wcnss_mem: wcnss {" not in o:
            print("FAIL: wcnss accidentally removed")
            ok = False
        if "memory-region = <&wcnss_mem>;" not in o:
            print("FAIL: pronto wcnss memory-region lost")
            ok = False
        for f in (400, 800, 1000, 1100, 1200):
            if "opp-%d {" % (f * 1000000) not in o:
                print("FAIL: missing opp-%d" % (f * 1000000))
                ok = False
        for f in (200, 998400000):
            if "opp-%d {" % f in o:
                print("FAIL: stock opp-%d should be gone" % f)
                ok = False
        if "opp-shared;" not in o:
            print("FAIL: missing opp-shared")
            ok = False
        # Memory release must not catch the stock table or unrelated nodes.
        o2 = transform(FIXTURE_DTS, {"opp_mhz": 800, "release_memory": False})
        if "opp-998400000" not in o2:
            print("FAIL: transformed despite opp-mhz<=stock")
            ok = False
        if "mpss_mem: mpss@86800000" not in o2:
            print("FAIL: reserved-memory accidentally removed")
            ok = False
        if "wcnss {" not in o2 or "venus {" not in o2 or "mba {" not in o2:
            print("FAIL: wcnss/venus/mba accidentally removed")
            ok = False
        # --aggressive removes the leftover modem/GPS-era reservations
        # but must keep tz-apps and every firmware-critical region.
        o3 = transform(FIXTURE_DTS, {"opp_mhz": 0, "aggressive": True})
        for pat in [re.compile(r"^\s*([\w.-]+:\s*)?gps(@[0-9a-fA-Fx,.-]+)?\s*\{"),
                    re.compile(r"rmtfs@86700000"),
                    re.compile(r"rfsa@867e0000"),
                    re.compile(r"reserved@86680000")]:
            if pat.search(o3):
                print("FAIL: aggressive still present: %s" % pat.pattern)
                ok = False
        for keep in ["tz-apps@86000000", "wcnss_mem: wcnss {",
                     "memory-region = <&wcnss_mem>;"]:
            if keep not in o3:
                print("FAIL: aggressive removed %s" % keep)
                ok = False
        if "memory-region = <&gps>;" in o3:
            print("FAIL: dangling gps ref kept")
            ok = False
        print("self-test: %s" % ("OK" if ok else "FAILED"))
        sys.exit(0 if ok else 1)

    if not (args.input and args.output):
        ap.error("--input and --output are required (or use --self-test)")
    if not os.path.exists(args.input):
        raise SystemExit("input not found: %s" % args.input)

    import tempfile
    tmp = tempfile.mkdtemp(prefix="patch_dtb_")
    dts_path = os.path.join(tmp, "input.dts")
    with open(dts_path, "w", encoding="utf-8") as f:
        subprocess.run(["dtc", "-I", "dtb", "-O", "dts", args.input],
                       check=True, stdout=f)

    with open(dts_path, encoding="utf-8") as f:
        dts = f.read()
    opts = {"opp_mhz": args.opp_mhz, "release_memory": args.release_memory,
            "aggressive": args.aggressive}
    dts = transform(dts, opts)
    with open(dts_path, "w", encoding="utf-8") as f:
        f.write(dts)

    if opts.get("_removed"):
        print("removed nodes: %s" % ", ".join(opts["_removed"]))
    run_dtc(args, dts_path, args.output)
    if args.keep_dts:
        import shutil
        shutil.copy(dts_path, args.keep_dts)
    print("wrote %s" % args.output)


if __name__ == "__main__":
    main()