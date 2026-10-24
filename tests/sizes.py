# Renders the dashboard at many terminal sizes, with gawk, mawk and busybox awk, and
# checks that every view fits the terminal and that the three awks agree.
# Usage: python3 tests/sizes.py mysqlmonitor.sh tests
import re, subprocess, sys, os
M, S = sys.argv[1], sys.argv[2]
src = open(M).read()
awk_prog = src.split("read -r -d '' RENDER_AWK <<'AWK'\n", 1)[1].split("\nAWK\n", 1)[0]
env = dict(os.environ, PATH=f"{S}/bin:" + os.environ["PATH"])
def sample():
    out = subprocess.run(["mysqladmin", "extended-status", "variables", "processlist"], capture_output=True, text=True, env=env).stdout
    mem = open("/proc/meminfo").read()
    cpu = "".join(l for l in open("/proc/stat") if l.startswith("cpu"))
    top = subprocess.run(["mysql", "-B", "-N", "-e", "x"], capture_output=True, text=True, env=env).stdout
    return out + "@@MEMINFO\n" + mem + "@@CPU\n" + cpu + "@@LOAD\n" + open("/proc/loadavg").read() + "@@TOP\n" + top
def render(awk, rows, cols, prev, t, smp, color="1", view="dashboard", scroll=0, details=0):
    inp = f"@@TIME {t}\n@@PREV\n{prev}\n@@CUR\n{smp}"
    p = subprocess.run(awk + ["-v", f"rows={rows}", "-v", f"cols={cols}", "-v", f"view={view}", "-v", f"scroll={scroll}", "-v", f"details={details}", "-v", "topq=1", "-v", "interval=5",
                       "-v", "clock=09:00:00", "-v", "unicode=1", "-v", f"color={color}", "-v", "debug=1", awk_prog],
                       input=inp, capture_output=True, text=True, env=dict(env, LC_ALL="C"))
    body, state = p.stdout.split("\n@@STATE\n", 1); body = body.split("\n@@PROC ", 1)[0]
    frame, sc = body.split("\n@@SCROLL ", 1)
    return frame, state, p.stderr + f"SCROLLOUT {sc}\n"
ANSI = re.compile(r"\x1b\[[0-9;]*m")
smp1 = sample(); import time; time.sleep(1.1); smp2 = sample()
sizes = [(50,12),(56,16),(80,24),(80,30),(95,45),(100,30),(100,45),(200,45),(120,40),(120,55),(132,43),(138,52),(155,55),(160,50),(190,45),(190,52),(210,55),(240,60),(270,70),(380,100)]
labels = {(100,45):"your half", (200,45):"your full", (80,24):"classic", (132,43):"", (270,70):"1440p", (380,100):"4K"}
awks = {"gawk":["gawk"], "mawk":["mawk"], "busybox":["busybox","awk"]}
bad = 0
print(f"{'size':>9} {'':11} {'layout':<22} {'used':>9} {'spare':>5} {'queries':>7}  check")
for cols, rows in sizes:
    results = {}
    for name, awk in awks.items():
        _, st, _ = render(awk, rows, cols, "", 1_000_000_000, smp1)
        frame, _, err = render(awk, rows, cols, st, 1_001_100_000, smp2)
        results[name] = (frame, err)
    frame, err = results["gawk"]
    m = re.search(r"LAYOUT (.*)\|(\d+)\|(\d+)\|(\d+)", err)
    layout, used, qrows, over = m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4))
    lines = frame.split("\n")
    widest = max(len(ANSI.sub("", l)) for l in lines)
    problems = []
    if len(lines) > rows: problems.append(f"{len(lines)} lines > {rows} rows")
    if widest > cols - 1: problems.append(f"width {widest} > {cols-1}")
    if over: problems.append(f"{over} segments wider than their column")
    if len(set(f for f, _ in results.values())) != 1: problems.append("awks differ")
    errs = [e for _, e in results.values() if re.sub(r"(LAYOUT|SCROLLOUT) .*\n", "", e).strip()]
    if errs: problems.append("stderr: " + errs[0][:60])
    bad += bool(problems)
    print(f"{cols:>4}x{rows:<4} {labels.get((cols,rows),''):11} {layout:<22} {len(lines):>3}/{rows:<4} {rows-len(lines):>5} {qrows:>7}  {'OK' if not problems else '; '.join(problems)}")

# Scroll view (top, middle, end) and raw view at every size
print()
print(f"{'size':>9} {'view':<16} {'used':>9} {'pos/max':>7} {'layout':<20} check")
for cols, rows in sizes:
    for view, details, scroll in (("dashboard", 1, 0), ("dashboard", 1, 15), ("dashboard", 1, 999999), ("raw", 0, 0), ("raw", 0, 999999), ("health", 0, 0), ("health", 0, 999999), ("help", 0, 0), ("procs", 0, 0), ("top", 0, 0)):
        outs = {}
        for name, awk in awks.items():
            _, st, _ = render(awk, rows, cols, "", 1_000_000_000, smp1, view=view, scroll=scroll, details=details)
            outs[name] = render(awk, rows, cols, st, 1_001_100_000, smp2, view=view, scroll=scroll, details=details)
        frame, _, err = outs["gawk"]
        lines = frame.split("\n")
        widest = max(len(ANSI.sub("", l)) for l in lines)
        sc, maxoff = re.search(r"SCROLLOUT (-?\d+) (\d+)", err).groups()
        layout, over = re.search(r"LAYOUT (.*?)\|\d+\|\d+\|(\d+)", err).groups()
        problems = []
        if len(lines) > rows: problems.append(f"{len(lines)} lines > {rows} rows")
        # The raw table is fixed-width by design; only the dashboard must fit the width
        if view != "raw" and widest > cols - 1: problems.append(f"width {widest} > {cols-1}")
        if int(over): problems.append(f"{over} segments wider than their column")
        if len(set(f for f, _, _ in outs.values())) != 1: problems.append("awks differ")
        bad += bool(problems)
        if problems or (cols, rows) in labels:
            print(f"{cols:>4}x{rows:<4} {(('details' if details else view) + ' @' + str(scroll)):<16} {len(lines):>3}/{rows:<4} {sc:>3}/{maxoff:<3} {layout:<20} {'OK' if not problems else '; '.join(problems)}")
print("all checks OK" if not bad else f"{bad} checks with problems")
