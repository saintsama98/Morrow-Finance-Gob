"""Mutation testing for the Morrow contracts.

Each mutant in mutants.json replaces one exact snippet in one source file. The runner copies the
repository into a disposable workspace, applies one mutant at a time, builds, runs the local suite at
reduced depth and records whether any test failed (killed), every test passed (survived), or the
mutant did not compile (stillborn). Fork suites are skipped by unsetting BASE_RPC_URL.

Run from the repository root:

    python3 sim/mutation/run.py                 # every mutant, plus an unmutated baseline
    python3 sim/mutation/run.py M03 P09         # selected mutants
    python3 sim/mutation/run.py --pause 60      # wait 60 seconds between mutants
    python3 sim/mutation/run.py --max-temp 80   # on Linux, wait for the CPU to cool below 80 C first

Results are appended to cache/mutation/results.jsonl, logs go to cache/mutation/logs/.
"""

import argparse
import json
import os
import shutil
import subprocess
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "cache", "mutation")
WS = os.path.join(OUT, "ws")
LOGS = os.path.join(OUT, "logs")

ENV = dict(os.environ)
ENV.pop("BASE_RPC_URL", None)
ENV.update(FOUNDRY_FUZZ_RUNS="256", FOUNDRY_INVARIANT_RUNS="24", FOUNDRY_INVARIANT_DEPTH="64")


def run(cmd, log, timeout):
    with open(log, "w") as f:
        try:
            return subprocess.run(cmd, cwd=WS, stdout=f, stderr=subprocess.STDOUT, env=ENV, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            return "timeout"


def wait_cool(limit_c):
    """Linux only: block while the first thermal zone is at or above limit_c."""
    zone = "/sys/class/thermal/thermal_zone0/temp"
    while limit_c and os.path.exists(zone) and int(open(zone).read()) >= limit_c * 1000:
        time.sleep(15)


def workspace():
    """A copy of the tracked files and submodules, so the real tree is never edited."""
    if os.path.isdir(WS):
        return
    files = subprocess.check_output(["git", "ls-files", "--recurse-submodules"], cwd=ROOT).decode().split("\n")
    for f in filter(None, files):
        dst = os.path.join(WS, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(ROOT, f), dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ids", nargs="*")
    ap.add_argument("--pause", type=int, default=0)
    ap.add_argument("--max-temp", type=int, default=0)
    args = ap.parse_args()

    mutants = json.load(open(os.path.join(ROOT, "sim", "mutation", "mutants.json")))
    todo = [{"id": "BASE", "file": None}] + [m for m in mutants if not args.ids or m["id"] in args.ids]
    os.makedirs(LOGS, exist_ok=True)
    workspace()

    for m in todo:
        pristine = None
        if m["file"]:
            path = os.path.join(WS, m["file"])
            pristine = open(os.path.join(ROOT, m["file"])).read()
            assert pristine.count(m["old"]) == 1, m["id"] + ": snippet not found exactly once"
            open(path, "w").write(pristine.replace(m["old"], m["new"], 1))
        wait_cool(args.max_temp)
        t0 = time.time()
        built = run(["forge", "build"], os.path.join(LOGS, m["id"] + ".build.log"), 3600)
        if built != 0:
            res = {"id": m["id"], "result": "stillborn", "build": built}
        else:
            tested = run(["forge", "test", "-j", "1"], os.path.join(LOGS, m["id"] + ".test.log"), 5400)
            log = open(os.path.join(LOGS, m["id"] + ".test.log")).read()
            fails = sorted({line.strip()[:160] for line in log.splitlines() if line.startswith("[FAIL")})
            summary = [line for line in log.splitlines() if "tests passed" in line][-1:]
            result = "killed" if fails else ("survived" if tested == 0 else "error-%s" % tested)
            res = {"id": m["id"], "result": result, "nfail": len(fails), "fails": fails[:12], "summary": summary}
        res["secs"] = round(time.time() - t0)
        if pristine is not None:
            open(os.path.join(WS, m["file"]), "w").write(pristine)
        with open(os.path.join(OUT, "results.jsonl"), "a") as f:
            f.write(json.dumps(res) + "\n")
        print(json.dumps(res)[:240], flush=True)
        if args.pause:
            time.sleep(args.pause)


if __name__ == "__main__":
    main()
