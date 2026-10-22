#!/usr/bin/env python3
"""External sampler. CPU = process CPU-time delta / monotonic wall time; 100%=one core.
Does not read input, inspect windows, or post keyboard events.
"""
import argparse
import json
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("--seconds", type=float, default=600)
parser.add_argument("--interval", type=float, default=5)
parser.add_argument("--scenario", required=True)
parser.add_argument("--output", required=True)
args = parser.parse_args()

def sample():
    result = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "cputime=,rss="], text=True).strip().split()
    cpu, rss = result
    fields = cpu.split(":")
    seconds = float(fields[-1]) + 60 * int(fields[-2])
    if len(fields) == 3:
        seconds += 3600 * int(fields[0])
    return {"elapsed": time.monotonic() - started, "cpu_seconds": seconds, "rss_mib": int(rss) / 1024}

started = time.monotonic()
samples = [sample()]
while time.monotonic() - started < args.seconds:
    time.sleep(min(args.interval, max(0, args.seconds - (time.monotonic() - started))))
    samples.append(sample())
elapsed = samples[-1]["elapsed"] - samples[0]["elapsed"]
output = {"scenario": args.scenario, "pid": args.pid, "duration_seconds": elapsed,
          "cpu_percent_one_core": 100 * (samples[-1]["cpu_seconds"] - samples[0]["cpu_seconds"]) / elapsed,
          "rss_mean_mib": sum(s["rss_mib"] for s in samples) / len(samples),
          "rss_max_mib": max(s["rss_mib"] for s in samples), "samples": samples,
          "method": "ps cputime delta / monotonic elapsed; RSS in KiB / 1024; external 5s sampler, no app helpers"}
Path(args.output).parent.mkdir(parents=True, exist_ok=True)
Path(args.output).write_text(json.dumps(output, indent=2) + "\n")
print(json.dumps({k: v for k, v in output.items() if k != "samples"}))
