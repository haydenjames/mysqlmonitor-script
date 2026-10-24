# Drives the monitor through a pty with SSH-like key timing (split escape sequences,
# held keys) and prints the key bar after each step.
# Usage: python3 tests/keys.py mysqlmonitor.sh tests
import os, pty, sys, time, select, fcntl, termios, struct, re, threading
script, S = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(PATH=f"{S}/bin:" + os.environ["PATH"], LANG="en_US.UTF-8", TERM="xterm-256color")
    os.execvp("bash", ["bash", script, "1"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 45, 100, 0, 0))
out = bytearray(); lock = threading.Lock(); done = False
def reader():
    while not done:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try: data = os.read(fd, 65536)
            except OSError: break
            with lock: out.extend(data)
threading.Thread(target=reader, daemon=True).start()
def mark():
    with lock: return len(out)
def keybar_since(m):
    time.sleep(0.6)
    with lock: tail = out[m:].decode("utf-8", "replace")
    bars = re.findall(r"Quit .*?(?=\x1b\[K|\x1b\[J|$)", re.sub(r"\x1b\[[0-9;]*m", "", tail))
    return bars[-1].strip() if bars else "(no redraw)"
time.sleep(2.5)
print("start        :", keybar_since(mark()))
m = mark(); os.write(fd, b"\x1b[B")                                          # Down in fitted view: nothing
print("Down (fitted):", keybar_since(m))
m = mark(); os.write(fd, b"d")
print("d            :", keybar_since(m))
m = mark(); os.write(fd, b"\x1b"); time.sleep(0.03); os.write(fd, b"[B")      # arrow split by latency
print("split Down   :", keybar_since(m))
m = mark()
for _ in range(40): os.write(fd, b"\x1b[B"); time.sleep(0.01)                 # held Down key
print("40x Down     :", keybar_since(m))
m = mark(); os.write(fd, b"\x1b[H")
print("Home         :", keybar_since(m))
m = mark(); os.write(fd, b"\x1b")                                             # lone Esc
print("Esc          :", keybar_since(m))
m = mark(); os.write(fd, b"d"); time.sleep(0.3); os.write(fd, b"d")
print("d, d         :", keybar_since(m))
os.write(fd, b"q"); time.sleep(0.5); done = True
with lock: text = bytes(out)
print("echoed ^[ sequences:", text.count(b"^["))
