#!/bin/bash
# MySQL Monitor Script
# ---------------------
# Author: Hayden James
# Website: https://consult.haydenjames.io
# Blog: https://linuxblog.io
# ---------------------

TITLE="MySQL Monitor v2026.10.24.01"

# Define minimum terminal width. The required height is measured from the frame itself.
MIN_COLS=50

# Check for required tools
for tool in mysqladmin awk stty; do
  if ! command -v "$tool" &> /dev/null; then
    echo "Error: $tool is not installed. Please install it and try again."
    exit 1
  fi
done

# Default refresh interval in seconds
INTERVAL=5

# Check if the user provided an interval
if [[ $# -ge 1 ]]; then
  if [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 )); then
    INTERVAL=$1
  else
    echo "Invalid interval specified. Using default INTERVAL=$INTERVAL seconds."
  fi
fi

# Use Unicode glyphs only in a UTF-8 locale, and honour NO_COLOR (https://no-color.org).
locale_name="${LC_ALL:-${LC_CTYPE:-$LANG}}"
if [[ $locale_name =~ [Uu][Tt][Ff]-?8 ]]; then UNICODE=1; else UNICODE=0; fi
if [[ -n $NO_COLOR ]]; then COLOR=0; else COLOR=1; fi

# Test if MySQL command requiring credentials succeeds
if ! output=$(mysqladmin status 2>&1); then
  # Check for .my.cnf
  if [ ! -f ~/.my.cnf ]; then
    echo "It seems MySQL credentials are missing."
    echo "Please create a ~/.my.cnf file with the following structure:"
    echo ""
    echo "[client]"
    echo "user=your_username"
    echo "password=your_password"
    echo ""
    echo "Ensure the file permissions are secure: chmod 600 ~/.my.cnf"
    exit 1
  else
    # Check file permissions: group/other must have no access
    file_perm=$(stat -c "%a" ~/.my.cnf)
    if (( 8#$file_perm & 8#077 )); then
      echo "Error: ~/.my.cnf permissions are $file_perm. Please set them to 600 using 'chmod 600 ~/.my.cnf'."
      exit 1
    fi
    echo "Credentials found in ~/.my.cnf, but the command still failed."
    echo "MySQL admin output:"
    echo "$output"
    echo "Please verify your credentials or server status."
    exit 1
  fi
fi

# Current time in microseconds (EPOCHREALTIME needs bash 5; fall back to whole seconds).
now_us() {
  if [[ -n $EPOCHREALTIME ]]; then
    REPLY=${EPOCHREALTIME//[!0-9]/}
  else
    REPLY=$(( SECONDS * 1000000 ))
  fi
}

# Renders one frame from a single input stream made of marked sections:
#   @@TIME (now, µs)  @@PREV (state from the previous frame)  @@CUR (mysqladmin output)
#   @@MEMINFO (/proc/meminfo)  @@CPU (/proc/stat cpu line)  @@LOAD (/proc/loadavg)
# Prints the frame, then "@@STATE" followed by the state to feed back in next time.
# Written for POSIX awk (gawk, mawk, busybox awk) and run with LC_ALL=C, so strings are
# bytes everywhere; vw() measures on-screen width by skipping UTF-8 continuation bytes.
read -r -d '' RENDER_AWK <<'AWK'
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }

function prettyTime(sec,    years, months, days, hours, minutes, seconds, out) {
  years   = int(sec / 31536000); sec %= 31536000
  months  = int(sec / 2592000);  sec %= 2592000
  days    = int(sec / 86400);    sec %= 86400
  hours   = int(sec / 3600);     sec %= 3600
  minutes = int(sec / 60)
  seconds = sec % 60

  out = ""
  if (years   > 0) out = out years   "y "
  if (months  > 0) out = out months  "mo "
  if (days    > 0) out = out days    "d "
  if (hours   > 0) out = out hours   "h "
  if (minutes > 0) out = out minutes "m "
  if (seconds > 0) out = out seconds "s"
  return (out == "") ? "0s" : trim(out)
}

# The two largest units only, for the header ("12d 4h", "3h 20m", "5m 12s").
function shortTime(sec,    d, h, m) {
  d = int(sec / 86400); h = int((sec % 86400) / 3600); m = int((sec % 3600) / 60)
  if (d > 0) return d "d " h "h"
  if (h > 0) return h "h " m "m"
  return m "m " int(sec % 60) "s"
}

# Converts large numbers into user-friendly formats (K, M, B, T)
function formatNumber(num) {
  if (num >= 1e12) return sprintf("%.2fT", num / 1e12)
  if (num >= 1e9)  return sprintf("%.2fB", num / 1e9)
  if (num >= 1e6)  return sprintf("%.2fM", num / 1e6)
  if (num >= 1e3)  return sprintf("%.2fK", num / 1e3)
  return sprintf("%.0f", num)
}

function formatRate(r) {
  if (r == "") return "-"
  if (r >= 1000) return formatNumber(r)
  if (r >= 10)   return sprintf("%.1f", r)
  return sprintf("%.2f", r)
}

function formatBytes(b) {
  if (b >= 1073741824) return sprintf("%.1f GB", b / 1073741824)
  return sprintf("%.0f MB", b / 1048576)
}

function pct(x)  { return (x == "") ? "-" : sprintf("%.1f%%", x) }
function pct2(x) { return (x == "") ? "-" : sprintf("%.2f%%", x) }

# Per-second change of a counter since the previous frame ("" when unknown).
function rate(name,    d) {
  if (!have_prev || !(name in cur) || !(name in prev)) return ""
  d = cur[name] - prev[name]
  return (d < 0) ? "" : d / elapsed
}

function delta(name) { return cur[name] - prev[name] }

# ---------- Drawing helpers ----------

function vw(s,    t) {
  t = s
  gsub(/\033\[[0-9;]*m/, "", t)
  gsub(/[\200-\277]/, "", t)
  return length(t)
}

function rep(ch, n,    s) { s = ""; while (n-- > 0) s = s ch; return s }
function padR(s, w) { return s rep(" ", w - vw(s)) }
function padL(s, w) { return rep(" ", w - vw(s)) s }
# Shortens plain (unstyled) text to w columns without splitting a UTF-8 character.
function clip(s, w,    i, n, c, out) {
  if (vw(s) <= w) return s
  n = 0; out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c !~ /[\200-\277]/ && ++n > w - 1) break
    out = out c
  }
  return out G_ELL
}

# Text from the server (queries, users, hosts) can contain anything: drop control
# characters so it can't move the cursor or change colours, and collapse whitespace.
function clean(s) {
  gsub(/[\001-\037\177]/, " ", s)
  gsub(/  +/, " ", s)
  return trim(s)
}

# Stores one processlist row. A "|" inside the query splits Info into extra fields,
# so everything between Info and the columns after it is joined back together.
function addProcess(f, n,    extra, ii, k, info) {
  extra = n - (pcols + 2)
  ii = pcol["Info"] + 1
  info = f[ii]
  for (k = 1; k <= extra; k++) info = info "|" f[ii + k]
  np++
  pid[np] = clean(f[pcol["Id"] + 1]); puser[np] = clean(f[pcol["User"] + 1])
  phost[np] = clean(f[pcol["Host"] + 1]); pdb[np] = clean(f[pcol["db"] + 1])
  pcmd[np] = clean(f[pcol["Command"] + 1]); ptime[np] = clean(f[pcol["Time"] + 1]) + 0
  pstate[np] = clean(f[pcol["State"] + 1]); pinfo[np] = info
}

# Picks the queries worth showing, longest-running first: no idle connections,
# background threads, replication dumps, or this monitor's own processlist call.
function selectQueries(    i, j, t, c) {
  NQ = 0; nsleep = 0
  for (i = 1; i <= np; i++) {
    pinfo[i] = clean(pinfo[i])
    c = pcmd[i]
    if (c == "Sleep") { nsleep++; continue }
    if (c == "Daemon" || c ~ /^Binlog Dump/ || puser[i] == "system user" || puser[i] == "event_scheduler") continue
    if (tolower(pinfo[i]) ~ /^show (full )?processlist/) continue
    QO[++NQ] = i
  }
  for (i = 2; i <= NQ; i++) {
    t = QO[i]
    for (j = i - 1; j >= 1 && ptime[QO[j]] < ptime[t]; j--) QO[j + 1] = QO[j]
    QO[j + 1] = t
  }
}

function fmtDur(sec) { return (sec < 60) ? sec "s" : (sec < 3600) ? int(sec / 60) "m" sprintf("%02d", sec % 60) "s" : shortTime(sec) }

# Live queries below the panels, sized to the rows left over (qrows lines of queries).
function emitQueries(w, qrows,    wide, hdr, i, k, lvl, t, line, used) {
  # Idle: a single line says so instead of an empty table
  if (NQ == 0) { emit(ptitle(sprintf("ACTIVE QUERIES  none running, %d sleeping", nsleep), w)); return }
  emit(ptitle(sprintf("ACTIVE QUERIES  %d running, %d sleeping", NQ, nsleep), w))
  wide = (w >= 96)
  hdr = "   " padR("ID", 9) padR("USER", 11) (wide ? padR("HOST", 16) : "") padR("DB", 13) padL("TIME", 7) "  " \
        (wide ? padR("STATE", 18) : "") "QUERY"
  emit(paint(BOLD, clip(hdr, w)))
  for (k = 1; k <= NQ && k <= qrows; k++) {
    if (k == qrows && NQ > qrows) { emit("   +" (NQ - k + 1) " more"); return }
    i = QO[k]; t = ptime[i]
    lvl = (t >= 60) ? 3 : (t >= 10) ? 2 : 0
    line = " " mark(lvl) " " padR(clip(pid[i], 8), 9) padR(clip(puser[i], 10), 11)
    if (wide) { sub(/:[0-9]+$/, "", phost[i]); line = line padR(clip(phost[i], 15), 16) }
    line = line padR(clip(pdb[i], 12), 13) padL((lvl >= 2) ? paint(BOLD levelColor(lvl), fmtDur(t)) : fmtDur(t), 7) "  "
    if (wide) line = line padR(clip(pstate[i], 17), 18)
    used = vw(line)
    emit(line clip((pinfo[i] != "") ? pinfo[i] : pcmd[i], w - used))
  }
}
function paint(c, s) { return (c == "" || s == "") ? s : c s RST }

# Severity levels: 0 none, 1 ok, 2 warning, 3 critical
function levelColor(l) { return (l == 3) ? RED : (l == 2) ? YEL : GRN }
function mark(l) { return (l == 0) ? " " : paint(levelColor(l), (l == 3) ? G_CRIT : (l == 2) ? G_WARN : G_OK) }
function worse(a, b) { return (a > b) ? a : b }

# Level for a value where higher is worse / lower is worse ("" means unknown: no mark).
function high(x, warn, crit) { return (x == "") ? 0 : (x >= crit) ? 3 : (x >= warn) ? 2 : 1 }
function low(x, warn, crit)  { return (x == "") ? 0 : (x < crit) ? 3 : (x < warn) ? 2 : 1 }

function bar(p, w, warn, crit,    f, c) {
  if (w <= 0) return ""
  if (p == "") return rep(" ", w)
  f = int(p * w / 100 + 0.5)
  if (f > w) f = w
  if (f < 0) f = 0
  c = (p >= crit) ? RED : (p >= warn) ? YEL : GRN
  return paint(c, rep(G_FULL, f)) paint(DIM, rep(G_EMPTY, w - f))
}

# Sparkline of the last w samples, scaled from 0 to the window's peak but never below
# floor, so a steady low value doesn't fill the whole bar. Zero draws nothing and the
# top level is ▆, never █, so graphs on neighbouring lines don't touch each other.
function spark(key, w, floor,    n, a, i, start, mx, s, idx) {
  if (w <= 0) return ""
  n = (hist[key] == "") ? 0 : split(hist[key], a, ",")
  start = (n > w) ? n - w + 1 : 1
  mx = floor
  for (i = start; i <= n; i++) if (a[i] + 0 > mx) mx = a[i] + 0
  s = ""
  for (i = start; i <= n; i++) {
    idx = (a[i] + 0 <= 0 || mx <= 0) ? 1 : 2 + int(a[i] / mx * 5)
    if (idx > 7) idx = 7
    s = s SPK[idx]
  }
  return padR(paint(CYN, s), w)
}

function pushHist(key, val,    n, a, i, s) {
  if (val == "") return
  s = (hist[key] == "") ? sprintf("%.2f", val) : hist[key] "," sprintf("%.2f", val)
  n = split(s, a, ",")
  if (n > HIST_MAX) {
    s = a[n - HIST_MAX + 1]
    for (i = n - HIST_MAX + 2; i <= n; i++) s = s "," a[i]
  }
  hist[key] = s
}

# One metric line: status mark, label, value (bold in the warning/critical colour when it
# needs attention), optional graphic, suffix and, when the
# layout has room (SHOW_DESC), a description column.
function L(lvl, label, value, graphic, suffix, desc,    s) {
  s = " " mark(lvl) " " padR(label, LW) padL((lvl >= 2) ? paint(BOLD levelColor(lvl), value) : value, VWD)
  if (SHOW_DESC && desc != "")
    return s "  " padR(graphic, GW) "  " padR(suffix, SW) "  " paint(ITAL, clip(desc, DW))
  if (graphic != "") s = s "  " graphic
  if (suffix != "") s = s "  " suffix
  return s
}

# Rate line for a counter, with its total since boot as the suffix.
function R(lvl, label, name, graphic, desc) {
  return L(lvl, label, formatRate(rate(name)), graphic, "total " formatNumber(cur[name]), desc)
}

# Detail lines only appear when the layout has room for them (SHOW_DETAIL).
function pd(s) { if (SHOW_DETAIL) pl(s) }

function setWidths(colw, compact) {
  if (compact) {
    LW = 9; VWD = 8; GW = colw - 3 - LW - VWD - 2 - 2 - 6; if (GW > 12) GW = 12
  } else if (SHOW_DESC) {
    # Descriptions get at least 36 columns, else the graphic goes and they get the rest (>= 30)
    LW = 13; VWD = 10; SW = 22
    GW = colw - (3 + LW + VWD + 2 + 2 + SW + 2) - 36; if (GW > 24) GW = 24
    if (GW < 5) GW = 0
    DW = colw - (3 + LW + VWD + 2 + GW + 2 + SW + 2)
  } else {
    LW = 13; VWD = 10; GW = colw - 3 - LW - VWD - 2 - 2 - 13; if (GW > 30) GW = 30
  }
  if (GW < 5) GW = 0
}

function ptitle(t, w) { return paint(BOLD CYN, G_H " " t " ") paint(DIM, rep(G_H, w - length(t) - 3)) }

function panel(p, title) { cp = p; PN[p] = 1; P[p, 1] = ptitle(title, PW) }
function pl(s) { PN[cp]++; P[cp, PN[cp]] = s }

function emit(s) { NO++; OUT[NO] = s }

function addAlert(level, text) { NAL++; AL[NAL] = text; ALV[NAL] = level; if (level > status) status = level }

# ---------- Raw view (the classic table) ----------

function addRow(name, val, extra, expl, color) {
  nrows++
  rkind[nrows] = "row"; rname[nrows] = name; rval[nrows] = val
  rextra[nrows] = extra; rdesc[nrows] = expl; rcolor[nrows] = color
  if (length(name)  > w1) w1 = length(name)
  if (length(val)   > w2) w2 = length(val)
  if (length(extra) > w3) w3 = length(extra)
  if (length(expl)  > w4) w4 = length(expl)
}

# A row whose value runs to the end of the line instead of sitting in the value column.
function addSpanRow(name, val) {
  nrows++; rkind[nrows] = "span"; rname[nrows] = name; rval[nrows] = val
  if (length(name) > w1) w1 = length(name)
}

function addHeader(title) { nrows++; rkind[nrows] = "hdr"; rname[nrows] = title }

function addLine(text, color) { nrows++; rkind[nrows] = "line"; rname[nrows] = text; rcolor[nrows] = color }

function rule(title, width,    left, right) {
  title = " " title " "
  left = int((width - length(title)) / 2)
  right = width - length(title) - left
  return rep("-", left) title rep("-", right)
}

function renderRaw(    i, name, label, extra, color, width, line) {
  w1 = 15; w2 = 10; w3 = 6; w4 = 25

  addHeader("MySQL Runtime Metrics")
  if (!up) {
    addLine("Unable to read MySQL status. Retrying every refresh...", RED)
    if (err != "") addLine(err, RED)
  } else {
    addRow("Variable", "Total", "Now/s", "Description", "")

    for (i = 1; i <= nm; i++) {
      name = metrics[i]
      if (!(name in cur)) continue

      if (name == "Uptime") {
        addSpanRow("Uptime (Wait 24h for accuracy)", prettyTime(cur[name]))
        continue
      }

      label = name
      if (name == "Questions") label = sprintf("Questions (%.2f avg QPS)", avg_qps)

      extra = (name in gauge) ? "" : formatRate(rate(name))
      color = (name == "Innodb_buffer_pool_pages_free" && cur[name] == 0) ? RED : ""
      addRow(label, formatNumber(cur[name]), extra, desc[name], color)
    }

    addHeader("MySQL Health Metrics")
    addRow("Metric", "Boot avg", "Now", "", "")

    if (bp_size > 0)
      addRow("InnoDB Buffer Pool Size", formatBytes(bp_size), "", "Set by innodb_buffer_pool_size.", "")

    if ("Innodb_buffer_pool_pages_free" in cur)
      addRow("InnoDB Buffer Pool Free",
             formatBytes(bp_free) ((bp_free_pct != "") ? sprintf(" (%.0f%%)", bp_free_pct) : ""), "",
             "Zero/low? = innodb_buffer_pool_size.", (cur["Innodb_buffer_pool_pages_free"] == 0) ? RED : "")

    if (hit_boot != "")
      addRow("InnoDB Buffer Pool Hit Ratio", pct2(hit_boot), pct2(hit_now), "High QPS? Aim for high hit ratio.", "")
    if (tc_boot != "")
      addRow("Thread Cache Hit Ratio", pct(tc_boot), pct(tc_now), "Faster connection handling. > 90%.", "")
    if (tbl_boot != "")
      addRow("Table Cache Hit Ratio", pct(tbl_boot), pct(tbl_now), "Faster table access speeds. > 90%.", "")
    if (tmp_boot != "")
      addRow("Temp tables created on disk", pct(tmp_boot), pct(tmp_now), "Keep this low! Disk I/O is slow.", "")
    if (maxc > 0)
      addRow("Connection Usage (peak / now)", pct(peak_pct), pct(conn_pct),
             sprintf("Of max_connections (%d). < 85%%.", maxc), "")
  }

  addHeader("System")
  if (mem_total > 0) {
    line = sprintf("Memory: Total %.2f GB, Used %.2f GB, Free %.2f GB, Available %.2f GB",
                   mem_total / 1073741824, (mem_total - mem_avail) / 1073741824,
                   mem["MemFree"] / 1073741824, mem_avail / 1073741824)
    if (mem_avail_pct < 10) addLine(line sprintf(" (Warning!: %.1f%%)", mem_avail_pct), RED)
    else addLine(line, "")
  }
  addLine("CPU: " ((cpu_pct != "") ? pct(cpu_pct) : "-") ((load != "") ? "   Load: " load : ""), "")

  width = w1 + w2 + w3 + w4 + 9
  for (i = 1; i <= nrows; i++) {
    if (rkind[i] == "hdr") {
      emit(rule(rname[i], width))
    } else if (rkind[i] == "line") {
      emit(paint(rcolor[i], rname[i]))
    } else if (rkind[i] == "span") {
      emit(sprintf("%-" w1 "s | %s", rname[i], rval[i]))
    } else {
      emit(paint(rcolor[i], sprintf("%-" w1 "s | %-" w2 "s | %-" w3 "s | %s", rname[i], rval[i], rextra[i], rdesc[i])))
    }
  }
  emit(rule(title, width))
}

# ---------- Dashboard ----------

function header(w,    left, right, parts, n, i, st) {
  st = (!up) ? "DOWN" : (status == 3) ? "CRITICAL" : (status == 2) ? nwarn " WARN" : "OK"
  right = paint(levelColor(up ? worse(status, 1) : 3), G_DOT " " st) "   " interval "s   " clock " "
  n = 0
  parts[++n] = paint(BOLD, " MySQL Monitor")
  if (host != "")   parts[++n] = host
  if (server != "") parts[++n] = server
  if (up)           parts[++n] = "up " shortTime(cur["Uptime"])
  # Drop the least important parts until it fits
  while (n > 1) {
    left = parts[1]
    for (i = 2; i <= n; i++) left = left " " paint(DIM, G_SEP) " " parts[i]
    if (vw(left) + vw(right) + 3 <= w) break
    n--
  }
  if (n == 1) left = parts[1]
  return left rep(" ", w - vw(left) - vw(right)) right
}

function key(k, label) { return " " paint(INV, " " k " ") " " label " " }

# mode: "fit" (more = 1 when the fitted layout hides something), "details" or "raw".
# pos is the visible range while the content scrolls. Shortens itself to fit w columns.
function keybar(mode, more, pos, w,    k, lvl) {
  if (mode == "fit") MORE = more
  for (lvl = 1; lvl <= 3; lvl++) {
    k = key("q", (lvl < 3) ? "Quit" : "") key("r", (lvl < 3) ? ((view == "raw") ? "Dashboard" : "Raw counters") : "")
    if (mode == "fit" && more) k = k key("d", "Details")
    if (mode == "details") k = k key("d", (lvl < 3) ? "Less" : "")
    if (pos != "") k = k key(G_UP G_DOWN, (lvl == 1) ? "PgUp PgDn Scroll" : "Scroll") " " pos
    if (vw(k) <= w) break
  }
  return k
}

function buildPanels(    p) {
  NP = 0
  if (!up) {
    ORDER[++NP] = "err"; panel("err", "MYSQL")
    pl(L(3, "Status", "DOWN", "", "retrying every refresh", ""))
    if (err != "") pl("   " paint(RED, clip(err, PW - 3)))
  } else {
    ORDER[++NP] = "thr"; panel("thr", "THROUGHPUT")
    pl(L(0, "Queries/s", formatRate(r_q), spark("qps", GW, 1), "avg " formatRate(avg_qps), "Client requests per second."))
    pl(R(high(r_slow, 1, 10), "Slow/s", "Slow_queries", spark("slow", GW, 1), "Queries exceeding long_query_time."))
    pl(R(0, "Sel scan/s", "Select_scan", spark("scan", GW, 1), "Full table scans in SELECT queries."))
    pl(R(high(r_fj, 1, 10), "Full join/s", "Select_full_join", "", "Joins without usable indexes."))
    pd(L(0, "Questions", formatNumber(cur["Questions"]), "", "since boot", "Total number of client requests."))
    pd(L(0, "Uptime", "", "", prettyTime(cur["Uptime"]), "Wait 24h for accuracy."))

    ORDER[++NP] = "con"; panel("con", "CONNECTIONS")
    pl(L(high(conn_pct, 85, 95), "Connected", cur["Threads_connected"] ((maxc > 0) ? "/" maxc : ""),
         bar(conn_pct, GW, 85, 95), pct(conn_pct), "Currently open connections."))
    pl(L(0, "Running", cur["Threads_running"], spark("running", GW, ncpu), (ncpu > 0) ? ncpu " cores" : "",
         "Threads currently running queries."))
    pl(L(high(peak_pct, 85, 95), "Peak", cur["Max_used_connections"] ((maxc > 0) ? "/" maxc : ""),
         bar(peak_pct, GW, 85, 95), pct(peak_pct), "Max concurrent connections so far."))
    pl(L(high(r_abort, 1, 10), "Aborted/s", formatRate(r_abort), "", "clients + connects", "Failed connections per second."))
    pl(L((r_conn >= 1) ? low(tc_now, 90, 50) : 0, "Thread cache", pct((tc_now != "") ? tc_now : tc_boot), "",
         (tc_now != "") ? "boot " pct(tc_boot) : "since boot", "Faster connection handling. > 90%."))
    pd(R(0, "Connections/s", "Connections", "", "Total connection attempts."))
    pd(R(0, "Created/s", "Threads_created", "", "Threads created for connections."))
    pd(L(0, "Cached", cur["Threads_cached"], "", "", "Threads in the thread cache."))
    pd(L(0, "Aborted cli", formatNumber(cur["Aborted_clients"]), "", "since boot", "Failed client connections."))
    pd(L(0, "Aborted conn", formatNumber(cur["Aborted_connects"]), "", "since boot", "Failed MySQL server connections."))

    ORDER[++NP] = "bp"; panel("bp", "INNODB BUFFER POOL")
    pl(L(0, "Size", (bp_size > 0) ? formatBytes(bp_size) : "-", bar(bp_used_pct, GW, 101, 101), pct(bp_used_pct) " used",
         "Set by innodb_buffer_pool_size."))
    pl(L((cur["Innodb_buffer_pool_pages_free"] == 0) ? 2 : 0, "Free", formatBytes(bp_free), "",
         (bp_free_pct != "") ? pct(bp_free_pct) " of pool" : "", "Zero/low? = innodb_buffer_pool_size."))
    pl(L(low(hit_now, 99, 95), "Hit ratio", pct2((hit_now != "") ? hit_now : hit_boot), "",
         (hit_now != "") ? "boot " pct2(hit_boot) : "since boot", "High QPS? Aim for high hit ratio."))
    pl(R(0, "Disk reads/s", "Innodb_buffer_pool_reads", spark("bpr", GW, 1), "Reads that missed the pool (disk)."))
    pl(L(high(r_wait, 0.001, 1), "Wait free/s", formatRate(r_wait), "", "log waits/s " formatRate(r_logw),
         "Waits for free pages. Should be 0."))
    pd(R(0, "Read req/s", "Innodb_buffer_pool_read_requests", "", "Logical read requests to buffer."))
    pd(R(0, "Write req/s", "Innodb_buffer_pool_write_requests", "", "Writes requested to InnoDB buffer."))
    pd(R(0, "Data reads/s", "Innodb_data_reads", "", "Data pages read from disk."))
    pd(R(0, "Data writes/s", "Innodb_data_writes", "", "Data pages written to disk."))
    pd(R(0, "Log writes/s", "Innodb_log_writes", "", "Log writes to InnoDB log file."))

    ORDER[++NP] = "tmp"; panel("tmp", "TEMP TABLES & SORTS")
    pl(R(0, "Tmp tables/s", "Created_tmp_tables", spark("tmp", GW, 1), "Temp tables created in memory."))
    pl(L((r_tmp >= 1) ? high(tmp_now, 25, 50) : 0, "On disk", pct((tmp_now != "") ? tmp_now : tmp_boot), "",
         (tmp_now != "") ? "boot " pct(tmp_boot) : "since boot", "Keep this low! Disk I/O is slow."))
    pl(R(0, "Tmp files/s", "Created_tmp_files", "", "Temp files created by MySQL."))
    pl(R(high(r_smp, 1, 10), "Sort merge/s", "Sort_merge_passes", "", "Merge passes performed for sorting."))
    pl(R(0, "Sort rows/s", "Sort_rows", "", "Rows sorted by MySQL."))
    pd(R(0, "Disk tmp/s", "Created_tmp_disk_tables", "", "Temp tables created on disk."))
    pd(R(0, "Sort range/s", "Sort_range", "", "Range-based sort operations."))
    pd(R(0, "Sort scan/s", "Sort_scan", "", "Table-scan-based sort operations."))

    ORDER[++NP] = "tbl"; panel("tbl", "TABLES & LOCKS")
    pl(L((toc > 0 && cur["Open_tables"] >= toc && r_opened >= 1) ? 2 : 0, "Open tables",
         cur["Open_tables"] ((toc > 0) ? "/" toc : ""), bar(ot_pct, GW, 95, 101), pct(ot_pct), "Tables currently open."))
    pl(R(high(r_opened, 1, 10), "Opened/s", "Opened_tables", spark("opened", GW, 1), "Tables opened (table cache misses)."))
    pl(L(low(tbl_now, 90, 50), "Cache hit", pct((tbl_now != "") ? tbl_now : tbl_boot), "",
         (tbl_now != "") ? "boot " pct(tbl_boot) : "since boot", "Faster table access speeds. > 90%."))
    pl(R(high(r_lockw, 0.001, 1), "Lock waits/s", "Table_locks_waited", "", "Locks that had to wait. (bad)."))
    pl(L(0, "Open files", cur["Open_files"], "", "", "Files currently open by MySQL."))
    pd(R(0, "Cache hits/s", "Table_open_cache_hits", "", "Cache hits for table open."))
    pd(R(0, "Cache miss/s", "Table_open_cache_misses", "", "Cache misses for table open."))
    pd(R(0, "Locks imm/s", "Table_locks_immediate", "", "Locks acquired immediately."))
    pd(R(0, "Key reads/s", "Key_reads", "", "MyISAM disk reads (Use InnoDB)."))
    pd(R(0, "Key writes/s", "Key_writes", "", "MyISAM disk writes (Use InnoDB)."))
  }

  ORDER[++NP] = "sys"; panel("sys", "SYSTEM")
  pl(L(high(cpu_pct, 80, 95), "CPU", pct(cpu_pct), bar(cpu_pct, GW, 80, 95), (load != "") ? "load " load1 : "",
       "Whole-system CPU usage."))
  if (mem_total > 0)
    pl(L(high(mem_used_pct, 90, 95), "Memory", pct(mem_used_pct), bar(mem_used_pct, GW, 90, 95),
         formatBytes(mem_avail) " avail", "System RAM in use (" formatBytes(mem_total) " total)."))
  if (swap_total > 0)
    pl(L(high(swap_pct, 20, 50), "Swap", pct(swap_pct), bar(swap_pct, GW, 20, 50), formatBytes(swap_used) " used",
         "Keep near zero for MySQL."))
  else
    pl(L(0, "Swap", "none", "", "", ""))
  if (load != "") pl(L(0, "Load avg", "", "", load, "1, 5 and 15 minute averages."))
}

# Alerts, worst first, clipped to w columns. budget = lines available; an overflow line replaces the last one.
function emitAlerts(budget, w,    lvl, i, shown) {
  if (NAL == 0) { emit(" " mark(1) " " paint(GRN, "No issues detected")); return }
  shown = 0
  for (lvl = 3; lvl >= 2; lvl--)
    for (i = 1; i <= NAL; i++) {
      if (ALV[i] != lvl) continue
      if (shown == budget - 1 && NAL > budget) {
        emit("   +" (NAL - shown) " more")
        return
      }
      emit(" " mark(lvl) " " clip(AL[i], w - 3))
      shown++
    }
}

# Height of panels i..j stacked in one column (sep = blank line between panels).
function stackH(i, j, sep,    k, h) {
  h = 0
  for (k = i; k <= j; k++) h += PN[ORDER[k]] + ((k > i) ? sep : 0)
  return h
}

# Assigns panels to n columns in reading order (down one column, then the next),
# choosing the split points that keep the tallest column as short as possible.
function arrange(n, sep,    i, a, b, mx, best, ba, bb) {
  best = -1
  if (n == 1) { ba = NP; bb = NP }
  else if (n == 2) {
    for (a = 1; a < NP; a++) {
      mx = stackH(1, a, sep); if (stackH(a + 1, NP, sep) > mx) mx = stackH(a + 1, NP, sep)
      if (best < 0 || mx < best) { best = mx; ba = a; bb = NP }
    }
  } else {
    for (a = 1; a < NP - 1; a++)
      for (b = a + 1; b < NP; b++) {
        mx = stackH(1, a, sep)
        if (stackH(a + 1, b, sep) > mx) mx = stackH(a + 1, b, sep)
        if (stackH(b + 1, NP, sep) > mx) mx = stackH(b + 1, NP, sep)
        if (best < 0 || mx < best) { best = mx; ba = a; bb = b }
      }
  }
  for (i = 1; i <= NP; i++) COLOF[i] = (i <= ba) ? 1 : (i <= bb) ? 2 : 3
}

# Emits the panels packed into n columns of width colw.
function gridBody(n, colw,    sep, i, j, c, H, line, seg) {
  sep = (n > 1)
  arrange(n, sep)
  for (c = 1; c <= n; c++) CH[c] = 0
  for (i = 1; i <= NP; i++) {
    c = COLOF[i]
    if (CH[c] > 0 && sep) COL[c, ++CH[c]] = ""
    for (j = 1; j <= PN[ORDER[i]]; j++) COL[c, ++CH[c]] = P[ORDER[i], j]
  }
  H = 0; for (c = 1; c <= n; c++) if (CH[c] > H) H = CH[c]
  for (j = 1; j <= H; j++) {
    line = ""
    for (c = 1; c <= n; c++) {
      seg = (j <= CH[c]) ? COL[c, j] : ""
      line = (c == 1) ? seg : padR(line, (c - 1) * (colw + 2)) seg
    }
    emit(line)
  }
}

# Panels packed into n columns of width colw, then live queries if qrows > 0.
function layoutGrid(n, colw, budget, qrows,    w, sep) {
  NO = 0
  PW = colw; setWidths(colw, 0); buildPanels()
  w = n * colw + 2 * (n - 1)
  sep = (n > 1)
  emit(header(w))
  if (sep) emit("")
  gridBody(n, colw)
  if (sep) emit("")
  if (qrows > 0) { emitQueries(w, qrows); if (sep) emit("") }
  emit(ptitle("ALERTS", w)); emitAlerts(budget, w)
  if (sep) emit("")
  emit(keybar("fit", !SHOW_DETAIL || (!SHOW_DESC && cols - 3 >= DESC_MIN) || (up && NQ > qrows), "", w))
}

function layoutCompact(budget, qrows,    colw, sep) {
  NO = 0
  colw = int((cols - 4) / 2); if (colw > 44) colw = 44
  setWidths(colw, 1)
  sep = " " paint(DIM, G_V) " "
  emit(header(2 * colw + 3))
  if (up) {
    emit(padR(L(0, "QPS", formatRate(r_q), spark("qps", GW, 1), ""), colw) sep \
         L(high(conn_pct, 85, 95), "Conn", cur["Threads_connected"] ((maxc > 0) ? "/" maxc : ""), bar(conn_pct, GW, 85, 95), (GW > 0) ? pct(conn_pct) : ""))
    emit(padR(L(high(r_slow, 1, 10), "Slow/s", formatRate(r_slow), spark("slow", GW, 1), ""), colw) sep \
         L(0, "Running", cur["Threads_running"], spark("running", GW, ncpu), ""))
    emit(padR(L(low(hit_now, 99, 95), "BP hit", pct2((hit_now != "") ? hit_now : hit_boot), "", ""), colw) sep \
         L(high(mem_used_pct, 90, 95), "Memory", pct(mem_used_pct), bar(mem_used_pct, GW, 90, 95), ""))
    emit(padR(L((r_tmp >= 1) ? high(tmp_now, 25, 50) : 0, "Tmp disk", pct((tmp_now != "") ? tmp_now : tmp_boot), "", ""), colw) sep \
         L(high(cpu_pct, 80, 95), "CPU", pct(cpu_pct), bar(cpu_pct, GW, 80, 95), ""))
    # Extra pairs when the terminal has spare rows (CX = 0..3, set by fit)
    if (CX >= 1)
      emit(padR(L(0, "Scans/s", formatRate(r_scan), spark("scan", GW, 1), ""), colw) sep \
           L(high(peak_pct, 85, 95), "Peak", cur["Max_used_connections"] ((maxc > 0) ? "/" maxc : ""), bar(peak_pct, GW, 85, 95), ""))
    if (CX >= 2)
      emit(padR(L(0, "Disk rd/s", formatRate(r_bpr), spark("bpr", GW, 1), ""), colw) sep \
           ((swap_total > 0) ? L(high(swap_pct, 20, 50), "Swap", pct(swap_pct), bar(swap_pct, GW, 20, 50), "") : L(0, "Swap", "none", "", "")))
    if (CX >= 3)
      emit(padR(L((toc > 0 && cur["Open_tables"] >= toc && r_opened >= 1) ? 2 : 0, "Open tbl", pct(ot_pct), bar(ot_pct, GW, 95, 101), ""), colw) sep \
           L(0, "Load", "", "", load))
  } else {
    emit(L(3, "MySQL", "DOWN", "", clip(err, 2 * colw - 20)))
  }
  if (qrows > 0) emitQueries(2 * colw + 3, qrows)
  emitAlerts(budget, 2 * colw + 3)
  emit(keybar("fit", 1, "", 2 * colw + 3))
}

# Emits CONT[1..NC] when it fits in vh lines; otherwise the vh lines from off, each
# padded to w columns and followed by a scroll bar. Sets MAXOFF and returns the clamped off.
function viewport(off, vh, w,    thumb, tpos, k, ind) {
  MAXOFF = NC - vh; if (MAXOFF < 0) MAXOFF = 0
  if (MAXOFF == 0) { for (k = 1; k <= NC; k++) emit(CONT[k]); return 0 }
  if (off > MAXOFF) off = MAXOFF
  if (off < 0) off = 0
  thumb = int(vh * vh / NC); if (thumb < 1) thumb = 1
  tpos = int(off / MAXOFF * (vh - thumb) + 0.5)
  for (k = 1; k <= vh; k++) {
    ind = (k > tpos && k <= tpos + thumb) ? paint(CYN, G_FULL) : paint(DIM, G_V)
    emit(padR(CONT[off + k], w) " " ind)
  }
  return off
}

function posText(off, vh) { return (off + 1) "-" ((off + vh < NC) ? off + vh : NC) " of " NC }

# Details view: every detail line and (when wide enough) description, in as many
# columns as fit. Header, alerts and key bar stay in place; the panels scroll
# when they don't fit, with the scroll bar at the right edge of the terminal.
function layoutDetails(off,    W, n, colw, w, i, vh, fixed, budget, sep) {
  W = cols - 3
  SHOW_DETAIL = 1; SHOW_DESC = (W >= DESC_MIN)
  if (SHOW_DESC) {
    n = int((W + 2) / (DESC_MIN + 2)); if (n > 3) n = 3
    colw = int((W - 2 * (n - 1)) / n); if (colw > 120) colw = 120
  } else {
    n = 1; colw = (W > 80) ? 80 : W
  }
  sep = (n > 1)
  w = n * colw + 2 * (n - 1)
  PW = colw; setWidths(colw, 0); buildPanels()
  NO = 0
  gridBody(n, colw)
  if (up) { if (sep) emit(""); emitQueries(w, (NQ > 0) ? NQ : 1) }
  NC = NO; for (i = 1; i <= NO; i++) CONT[i] = OUT[i]

  budget = (NAL > 4) ? 4 : (NAL > 1) ? NAL : 1
  fixed = 1 + sep + sep + 1 + budget + sep + 1      # header, gaps, alerts title + lines, key bar
  vh = rows - fixed; if (vh < 1) vh = 1
  NO = 0
  emit(header(W))
  if (sep) emit("")
  off = viewport(off, vh, W)
  if (sep) emit("")
  emit(ptitle("ALERTS", W)); emitAlerts(budget, W)
  if (sep) emit("")
  emit(keybar("details", 0, (MAXOFF > 0) ? posText(off, vh) : "", W))
  CHOSEN = "details " n " col" ((SHOW_DESC) ? " +desc" : "")
  return off
}

# Layouts stay at least one column narrower than the terminal: with wrapping off, the
# erase-to-end-of-line after each line would wipe a character in the last column.

function build(layout, colw, budget, qrows) {
  if (layout) layoutGrid(layout, colw, budget, qrows); else layoutCompact(budget, qrows)
}

# Measures the layout with one alert line and no queries. If it fits, spare rows go
# first to extra alerts (up to 8 in all), then to the active queries panel.
# layout: 0 = compact, otherwise the number of columns.
function fit(layout, colw,    budget, spare, gap, qrows) {
  CX = 0
  build(layout, colw, 1, 0)
  if (NO > rows) return 0
  spare = rows - NO
  if (layout == 0 && up && cols >= 76) { CX = (spare > 3) ? 3 : spare; spare -= CX }
  budget = (NAL > 8) ? 8 : (NAL > 1) ? NAL : 1
  if (budget - 1 > spare) budget = spare + 1
  spare -= budget - 1
  gap = (layout > 1) ? 1 : 0
  qrows = 0
  if (up && spare >= 3 + gap) {
    qrows = spare - 2 - gap
    if (qrows > ((NQ > 0) ? NQ : 1)) qrows = (NQ > 0) ? NQ : 1
  }
  if (budget > 1 || qrows > 0 || CX > 0) build(layout, colw, budget, qrows)
  QROWS = qrows
  return 1
}

# Picks the layout that shows the most and still fits: descriptions and detail lines first,
# then detail only, descriptions only, the core lines, and finally the compact summary.
function layoutBest(    c, cand, cf, minw, maxw, n, colw) {
  split("1 1,0 1,1 0,0 0", cand, ",")
  for (c = 1; c <= 4; c++) {
    split(cand[c], cf, " "); SHOW_DESC = cf[1] + 0; SHOW_DETAIL = cf[2] + 0
    minw = SHOW_DESC ? 98 : 48
    n = int((cols + 1) / (minw + 2)); if (n > 3) n = 3
    if (n < 1) continue
    colw = int((cols - 1 - 2 * (n - 1)) / n)
    maxw = SHOW_DESC ? 120 : (n == 1) ? 80 : 64
    if (colw > maxw) colw = maxw
    if (fit(n, colw)) { CHOSEN = n " col" ((SHOW_DESC) ? " +desc" : "") ((SHOW_DETAIL) ? " +detail" : ""); return }
  }
  SHOW_DESC = 0; SHOW_DETAIL = 0
  fit(0, 0)
  CHOSEN = "compact"
}

BEGIN {
  HIST_MAX = 60
  DESC_MIN = 84    # narrowest column that fits descriptions (without the graphic)

  # Dim is kept for decoration only (bar tracks, separators, rules): many terminal themes
  # render it too dark to read. Bold is reserved for values that need attention.
  if (color) {
    RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; CYN = "\033[36m"
    DIM = "\033[2m"; BOLD = "\033[1m"; ITAL = "\033[3m"; INV = "\033[7m"; RST = "\033[0m"
  }
  if (unicode) {
    G_FULL = "█"; G_EMPTY = "░"; G_OK = "✓"; G_WARN = "⚠"; G_CRIT = "✗"
    G_DOT = "●"; G_SEP = "▸"; G_H = "─"; G_V = "│"; G_ELL = "…"; G_UP = "↑"; G_DOWN = "↓"
    split("_ ▁ ▂ ▃ ▄ ▅ ▆", SPK, " "); SPK[1] = " "
  } else {
    G_FULL = "#"; G_EMPTY = "."; G_OK = "+"; G_WARN = "!"; G_CRIT = "x"
    G_DOT = "*"; G_SEP = ">"; G_H = "-"; G_V = "|"; G_ELL = "~"; G_UP = "Up"; G_DOWN = "Dn"
    split("_ _ - = + * #", SPK, " "); SPK[1] = " "
  }

  # Display order of the raw view, and which metrics are point-in-time gauges (no rate)
  nm = split("Aborted_clients Aborted_connects Connections Created_tmp_disk_tables " \
             "Created_tmp_files Created_tmp_tables Innodb_buffer_pool_pages_free " \
             "Innodb_buffer_pool_read_requests Innodb_buffer_pool_reads " \
             "Innodb_buffer_pool_wait_free Innodb_buffer_pool_write_requests " \
             "Innodb_data_reads Innodb_data_writes Innodb_log_waits Innodb_log_writes " \
             "Key_reads Key_writes Max_used_connections Open_files Open_tables " \
             "Opened_tables Questions Select_full_join Select_scan Slow_queries " \
             "Sort_merge_passes Sort_range Sort_rows Sort_scan Table_locks_immediate " \
             "Table_locks_waited Table_open_cache_hits Table_open_cache_misses " \
             "Threads_cached Threads_connected Threads_created Threads_running Uptime", metrics, " ")
  for (i = 1; i <= nm; i++) wanted[metrics[i]] = 1
  wanted["Innodb_buffer_pool_pages_total"] = 1

  split("Innodb_buffer_pool_pages_free Max_used_connections Open_files Open_tables " \
        "Threads_cached Threads_connected Threads_running Uptime", g, " ")
  for (i in g) gauge[g[i]] = 1

  split("innodb_buffer_pool_size innodb_page_size max_connections table_open_cache hostname version", v, " ")
  for (i in v) wanted_var[v[i]] = 1

  desc["Aborted_clients"]                  = "Failed client connections."
  desc["Aborted_connects"]                 = "Failed MySQL server connections."
  desc["Connections"]                      = "Total connection attempts."
  desc["Created_tmp_disk_tables"]          = "Temp tables created on disk."
  desc["Created_tmp_files"]                = "Temp files created by MySQL."
  desc["Created_tmp_tables"]               = "Temp tables created in memory."
  desc["Innodb_buffer_pool_pages_free"]    = "Free pages in InnoDB buffer pool."
  desc["Innodb_buffer_pool_reads"]         = "Reads that missed the pool (disk)."
  desc["Innodb_buffer_pool_read_requests"] = "Logical read requests to buffer."
  desc["Innodb_buffer_pool_wait_free"]     = "Waits for free pages."
  desc["Innodb_buffer_pool_write_requests"]= "Writes requested to InnoDB buffer."
  desc["Innodb_data_reads"]                = "Data pages read from disk."
  desc["Innodb_data_writes"]               = "Data pages written to disk."
  desc["Innodb_log_waits"]                 = "Log waits for buffer flushes."
  desc["Innodb_log_writes"]                = "Log writes to InnoDB log file."
  desc["Key_reads"]                        = "MyISAM disk reads (Use InnoDB)."
  desc["Key_writes"]                       = "MyISAM disk writes (Use InnoDB)."
  desc["Max_used_connections"]             = "Max concurrent connections so far."
  desc["Open_files"]                       = "Files currently open by MySQL."
  desc["Open_tables"]                      = "Tables currently open."
  desc["Opened_tables"]                    = "Total tables opened since start."
  desc["Questions"]                        = "Total number of client requests."
  desc["Select_full_join"]                 = "Joins without usable indexes."
  desc["Select_scan"]                      = "Full table scans in SELECT queries."
  desc["Slow_queries"]                     = "Queries exceeding long_query_time."
  desc["Sort_merge_passes"]                = "Merge passes performed for sorting."
  desc["Sort_range"]                       = "Range-based sort operations."
  desc["Sort_rows"]                        = "Rows sorted by MySQL."
  desc["Sort_scan"]                        = "Table-scan-based sort operations."
  desc["Table_open_cache_hits"]            = "Cache hits for table open."
  desc["Table_open_cache_misses"]          = "Cache misses for table open."
  desc["Table_locks_immediate"]            = "Locks acquired immediately."
  desc["Table_locks_waited"]               = "Locks that had to wait. (bad)."
  desc["Threads_cached"]                   = "Threads in the thread cache."
  desc["Threads_connected"]                = "Currently open connections."
  desc["Threads_created"]                  = "Threads created for connections."
  desc["Threads_running"]                  = "Threads currently running queries."
  desc["Uptime"]                           = ""

  section = ""; tables = 0; err = ""
}

/^@@[A-Z]+/ { section = substr($1, 3); if (section == "TIME") now = $2; next }

section == "PREV" {
  if ($1 ~ /^H_/) hist[substr($1, 3)] = $2
  else if ($1 != "") prev[$1] = $2 + 0
  next
}

section == "CUR" {
  if ($0 ~ /^\|/) {
    n = split($0, f, "|")
    name = trim(f[2]); val = trim(f[3])
    if (name == "Variable_name") { tables++; next }
    if (name == "Id") {
      # Processlist header: map column names (MariaDB adds Progress after Info)
      tables = 3; pcols = n - 2
      for (i = 2; i < n; i++) pcol[trim(f[i])] = i - 1
      next
    }
    if (tables == 1 && (name in wanted)) cur[name] = val + 0
    else if (tables == 2 && (name in wanted_var)) { vars[name] = val + 0; svars[name] = val }
    else if (tables == 3) addProcess(f, n)
  } else if (tables == 3 && $0 !~ /^\+/) {
    # Continuation of a multi-line query: keep the text, drop the trailing columns
    line = $0; sub(/ *\|.*$/, "", line)
    if (np > 0) pinfo[np] = pinfo[np] " " line
  } else if ($0 !~ /^\+/ && $0 != "") {
    err = (err == "") ? $0 : err " " $0
  }
  next
}

section == "MEMINFO" { sub(/:$/, "", $1); mem[$1] = $2 * 1024; next }

section == "CPU" {
  if ($1 != "cpu") { if ($1 ~ /^cpu[0-9]/) ncpu++; next }
  cpu_total = 0
  for (i = 2; i <= 9 && i <= NF; i++) cpu_total += $i
  cpu_idle = $5 + $6
  next
}

section == "LOAD" { load = $1 " " $2 " " $3; load1 = $1; next }

END {
  up = ("Uptime" in cur)
  have_prev = ("T" in prev) && ("Uptime" in prev) && up && cur["Uptime"] >= prev["Uptime"]
  elapsed = have_prev ? (now - prev["T"]) / 1000000 : 0
  if (elapsed <= 0) have_prev = 0

  # ---------- Derived metrics ----------
  host = svars["hostname"]
  server = svars["version"]
  if (server != "") {
    sub(/-.*/, "", server)
    server = ((svars["version"] ~ /MariaDB/) ? "MariaDB " : "MySQL ") server
  }

  avg_qps = (cur["Uptime"] > 0) ? cur["Questions"] / cur["Uptime"] : ""
  r_q = rate("Questions"); r_slow = rate("Slow_queries"); r_scan = rate("Select_scan")
  r_fj = rate("Select_full_join"); r_conn = rate("Connections")
  r_abort = (rate("Aborted_clients") != "" && rate("Aborted_connects") != "") ? rate("Aborted_clients") + rate("Aborted_connects") : ""
  r_bpr = rate("Innodb_buffer_pool_reads"); r_wait = rate("Innodb_buffer_pool_wait_free")
  r_logw = rate("Innodb_log_waits"); r_tmp = rate("Created_tmp_tables"); r_tmpf = rate("Created_tmp_files")
  r_smp = rate("Sort_merge_passes"); r_sortrows = rate("Sort_rows")
  r_opened = rate("Opened_tables"); r_lockw = rate("Table_locks_waited")

  hit_boot = ""; hit_now = ""
  if (cur["Innodb_buffer_pool_read_requests"] > 0) {
    hit_boot = 100 * (1 - cur["Innodb_buffer_pool_reads"] / cur["Innodb_buffer_pool_read_requests"])
    if (hit_boot < 0) hit_boot = 0
  }
  if (have_prev && delta("Innodb_buffer_pool_read_requests") > 0) {
    hit_now = 100 * (1 - delta("Innodb_buffer_pool_reads") / delta("Innodb_buffer_pool_read_requests"))
    if (hit_now < 0) hit_now = 0
  }

  tc_boot = ""; tc_now = ""
  if (cur["Connections"] > 0) tc_boot = 100 * (1 - cur["Threads_created"] / cur["Connections"])
  if (have_prev && delta("Connections") > 0) tc_now = 100 * (1 - delta("Threads_created") / delta("Connections"))

  tbl_boot = ""; tbl_now = ""
  total = cur["Table_open_cache_hits"] + cur["Table_open_cache_misses"]
  if (total > 0) tbl_boot = 100 * cur["Table_open_cache_hits"] / total
  if (have_prev) {
    total = delta("Table_open_cache_hits") + delta("Table_open_cache_misses")
    if (total > 0) tbl_now = 100 * delta("Table_open_cache_hits") / total
  }

  tmp_boot = ""; tmp_now = ""
  if (cur["Created_tmp_tables"] > 0) tmp_boot = 100 * cur["Created_tmp_disk_tables"] / cur["Created_tmp_tables"]
  if (have_prev && delta("Created_tmp_tables") > 0) tmp_now = 100 * delta("Created_tmp_disk_tables") / delta("Created_tmp_tables")

  maxc = vars["max_connections"]
  conn_pct = (maxc > 0) ? 100 * cur["Threads_connected"] / maxc : ""
  peak_pct = (maxc > 0) ? 100 * cur["Max_used_connections"] / maxc : ""
  toc = vars["table_open_cache"]
  ot_pct = (toc > 0) ? 100 * cur["Open_tables"] / toc : ""

  page_size = (vars["innodb_page_size"] > 0) ? vars["innodb_page_size"] : 16384
  bp_size = vars["innodb_buffer_pool_size"]
  bp_free = cur["Innodb_buffer_pool_pages_free"] * page_size
  bp_free_pct = (cur["Innodb_buffer_pool_pages_total"] > 0) ? 100 * cur["Innodb_buffer_pool_pages_free"] / cur["Innodb_buffer_pool_pages_total"] : ""
  bp_used_pct = (bp_free_pct != "") ? 100 - bp_free_pct : ""

  mem_total = mem["MemTotal"]
  mem_avail = ("MemAvailable" in mem) ? mem["MemAvailable"] : mem["MemFree"]
  mem_avail_pct = (mem_total > 0) ? 100 * mem_avail / mem_total : ""
  mem_used_pct = (mem_total > 0) ? 100 - mem_avail_pct : ""
  swap_total = mem["SwapTotal"]; swap_used = swap_total - mem["SwapFree"]
  swap_pct = (swap_total > 0) ? 100 * swap_used / swap_total : ""
  cpu_pct = (("cpu_total" in prev) && cpu_total > prev["cpu_total"]) ? \
            100 * (1 - (cpu_idle - prev["cpu_idle"]) / (cpu_total - prev["cpu_total"])) : ""

  if (up) {
    pushHist("qps", r_q); pushHist("slow", r_slow); pushHist("scan", r_scan)
    pushHist("bpr", r_bpr); pushHist("tmp", r_tmp); pushHist("opened", r_opened)
    pushHist("running", cur["Threads_running"])
  }

  # ---------- Alerts ----------
  status = 1; NAL = 0
  if (!up) {
    addAlert(3, "Cannot read MySQL status. Retrying every refresh.")
  } else {
    if (hit_now != "" && hit_now < 99)
      addAlert(low(hit_now, 99, 95), sprintf("Buffer pool hit ratio %.2f%%: reads are going to disk. Consider a larger innodb_buffer_pool_size.", hit_now))
    if (r_wait > 0)
      addAlert(3, "Queries are waiting for free buffer pool pages. innodb_buffer_pool_size is too small.")
    else if (bp_free_pct != "" && cur["Innodb_buffer_pool_pages_free"] == 0)
      addAlert(2, "Buffer pool has no free pages. Consider raising innodb_buffer_pool_size.")
    if (r_logw > 0)
      addAlert(2, sprintf("InnoDB log waits %s/s. Consider raising innodb_log_buffer_size.", formatRate(r_logw)))
    if (conn_pct != "" && conn_pct >= 85)
      addAlert(high(conn_pct, 85, 95), sprintf("%d of %d connections in use (%.0f%%).", cur["Threads_connected"], maxc, conn_pct))
    else if (peak_pct != "" && peak_pct >= 85)
      addAlert(2, sprintf("Connections peaked at %.0f%% of max_connections (%d).", peak_pct, maxc))
    if (r_conn >= 1 && tc_now != "" && tc_now < 90)
      addAlert(2, sprintf("Thread cache hit ratio %.1f%%. Consider raising thread_cache_size.", tc_now))
    if (toc > 0 && cur["Open_tables"] >= toc && r_opened >= 1)
      addAlert(2, sprintf("table_open_cache (%d) is full and tables are reopened %s/s. Consider raising it.", toc, formatRate(r_opened)))
    else if (tbl_now != "" && tbl_now < 90)
      addAlert(2, sprintf("Table cache hit ratio %.1f%%. Consider raising table_open_cache.", tbl_now))
    if (r_tmp >= 1 && tmp_now != "" && tmp_now >= 25)
      addAlert(high(tmp_now, 25, 50), sprintf("%.0f%% of temp tables go to disk. Check tmp_table_size / max_heap_table_size and query plans.", tmp_now))
    if (r_slow >= 1)
      addAlert(high(r_slow, 1, 10), sprintf("%s slow queries/s. Check the slow query log.", formatRate(r_slow)))
    if (r_fj >= 1)
      addAlert(2, sprintf("%s joins/s without usable indexes (Select_full_join).", formatRate(r_fj)))
    if (r_lockw > 0)
      addAlert(2, sprintf("Table lock waits %s/s. MyISAM tables? Consider converting them to InnoDB.", formatRate(r_lockw)))
    if (r_smp >= 1)
      addAlert(2, sprintf("Sort merge passes %s/s. Large sorts are spilling to disk.", formatRate(r_smp)))
    if (r_abort >= 1)
      addAlert(2, sprintf("Aborted connections %s/s: failed logins, timeouts or network issues.", formatRate(r_abort)))
  }
  if (mem_avail_pct != "" && mem_avail_pct < 10)
    addAlert(low(mem_avail_pct, 10, 5), sprintf("Only %.1f%% of system memory available (%s).", mem_avail_pct, formatBytes(mem_avail)))
  if (swap_pct != "" && swap_pct >= 20)
    addAlert(high(swap_pct, 20, 50), sprintf("%.0f%% of swap in use (%s). MySQL performs badly when swapped out.", swap_pct, formatBytes(swap_used)))
  nwarn = 0
  for (i = 1; i <= NAL; i++) if (ALV[i] == 2) nwarn++

  selectQueries()

  # ---------- Output ----------
  NO = 0
  SCROLL_OUT = 0; MAXOFF = 0; MORE = 0
  if (view == "raw") {
    # The classic table scrolls when it is taller than the screen (key bar on the last line)
    renderRaw()
    NC = NO; for (i = 1; i <= NO; i++) CONT[i] = OUT[i]
    NO = 0
    SCROLL_OUT = viewport(scroll, rows - 1, cols - 3)
    emit(keybar("raw", 0, (MAXOFF > 0) ? posText(SCROLL_OUT, rows - 1) : "", cols - 1))
    CHOSEN = "raw"
  }
  else if (details) SCROLL_OUT = layoutDetails(scroll)
  else layoutBest()
  for (i = 1; i <= NO; i++) print OUT[i]
  # Scroll position after clamping, the furthest it can scroll, and whether the
  # fitted dashboard hides anything (so 'd' is offered)
  print "@@SCROLL " SCROLL_OUT " " MAXOFF " " (MORE + 0)
  # Layout report for the size test harness (-v debug=1)
  if (debug) printf "LAYOUT %s|%d|%d\n", CHOSEN, NO, QROWS > "/dev/stderr"

  print "@@STATE"
  printf "T %.0f\n", now
  if (cpu_total > 0) printf "cpu_total %.0f\ncpu_idle %.0f\n", cpu_total, cpu_idle
  for (name in cur) printf "%s %.0f\n", name, cur[name]
  for (name in hist) printf "H_%s %s\n", name, hist[name]
}
AWK

# Collects a new sample; the only external command is mysqladmin.
fetch() {
  local line
  now_us; sample_time=$REPLY
  printf -v clock '%(%H:%M:%S)T' -1
  sample=$(
    mysqladmin extended-status variables processlist 2>&1
    printf '@@MEMINFO\n'
    [[ -r /proc/meminfo ]] && printf '%s\n' "$(</proc/meminfo)"
    printf '@@CPU\n'
    if [[ -r /proc/stat ]]; then
      while read -r line && [[ $line == cpu* ]]; do printf '%s\n' "$line"; done < /proc/stat
    fi
    printf '@@LOAD\n'
    [[ -r /proc/loadavg ]] && printf '%s\n' "$(</proc/loadavg)"
  )
}

# Lays out the current sample for the current terminal size and view.
render() {
  local out
  out=$(LC_ALL=C awk -v title="$TITLE" -v rows="$rows" -v cols="$cols" -v view="$VIEW" \
          -v interval="$INTERVAL" -v clock="$clock" -v unicode="$UNICODE" -v color="$COLOR" -v details="$DETAILS" -v scroll="$SCROLL" \
          "$RENDER_AWK" <<< "@@TIME $sample_time"$'\n'"@@PREV"$'\n'"$prev_state"$'\n'"@@CUR"$'\n'"$sample" 2>&1)
  if [[ $out != *$'\n'@@STATE* ]]; then
    # awk failed: show its error instead of a blank screen, and keep the previous state
    frame="Internal error while drawing the screen:"$'\n'"$out"
    next_state=$prev_state
    return
  fi
  frame=${out%%$'\n'@@SCROLL *}
  local meta=${out#*$'\n'@@SCROLL }
  read -r SCROLL MAXOFF MORE <<< "${meta%%$'\n'*}"
  next_state=${out#*@@STATE$'\n'}
}

# Draws the cached frame in place: home the cursor, overwrite each line, clear what is left.
draw() {
  local -a lines
  mapfile -t lines <<< "$frame"

  if (( ${#lines[@]} > rows || cols < MIN_COLS )); then
    local need=$(( ${#lines[@]} > rows ? ${#lines[@]} : rows ))
    local msg="Terminal too small. Resize to at least ${MIN_COLS}x${need}. ('q' to exit)"
    local msg_col=$(( (cols - ${#msg}) / 2 + 1 ))
    (( msg_col < 1 )) && msg_col=1
    printf '\033[H\033[J\033[%d;%dH\033[1;31m%s\033[0m' $(( rows / 2 )) "$msg_col" "$msg"
    return
  fi

  local buf=$'\033[H' line
  for line in "${lines[@]}"; do
    buf+="${line}"$'\033[K\n'
  done
  printf '%s\033[J' "${buf%$'\n'}"
}

read_size() { read -r rows cols < <(stty size 2>/dev/null) || { rows=24; cols=80; }; }

# Reads one keypress into KEY, decoding arrow/page/home/end escape sequences into
# names (up, down, pgup, pgdn, home, end); a lone Esc becomes "esc".
read_key() {
  local k c seq=""
  read -t "$1" -n 1 -s -r k || return 1
  if [[ $k == $'\e' ]]; then
    # The rest of an arrow/page key follows the Esc; allow for SSH latency
    while read -t 0.05 -n 1 -s -r c; do
      seq+=$c
      [[ $c == [A-Za-z~] && ${#seq} -gt 1 ]] && break
    done
    case $seq in
      "[A"|"OA") k=up ;;      "[B"|"OB") k=down ;;
      "[5~") k=pgup ;;        "[6~") k=pgdn ;;
      "[H"|"OH"|"[1~"|"[7~") k=home ;;
      "[F"|"OF"|"[4~"|"[8~") k=end ;;
      "") k=esc ;;
      *) k="" ;;
    esac
  fi
  KEY=$k
}

# Applies KEY to the view. Returns 1 when it changes nothing.
# 'd' toggles the details view (offered when the fitted dashboard hides something).
# Scroll keys move SCROLL within 0..MAXOFF, which awk reports for the current view.
apply_key() {
  local page=$(( rows > 12 ? rows - 8 : 4 ))
  case $KEY in
    q|Q) exit 0 ;;
    r|R) if [[ $VIEW == raw ]]; then VIEW=dashboard; else VIEW=raw; fi; SCROLL=0 ;;
    d|D)
      [[ $VIEW == dashboard ]] || return 1
      if (( DETAILS )); then DETAILS=0; elif (( MORE )); then DETAILS=1; else return 1; fi
      SCROLL=0 ;;
    esc) [[ $VIEW == dashboard ]] && (( DETAILS )) || return 1; DETAILS=0; SCROLL=0 ;;
    down|j) (( SCROLL < MAXOFF )) || return 1; (( SCROLL += 1 )) ;;
    pgdn)   (( SCROLL < MAXOFF )) || return 1; (( SCROLL += page )) ;;
    end)    (( SCROLL < MAXOFF )) || return 1; SCROLL=$MAXOFF ;;
    up|k)   (( SCROLL > 0 )) || return 1; (( SCROLL -= 1 )) ;;
    pgup)   (( SCROLL > 0 )) || return 1; (( SCROLL = SCROLL > page ? SCROLL - page : 0 )) ;;
    home)   (( SCROLL > 0 )) || return 1; SCROLL=0 ;;
    *) return 1 ;;
  esac
  return 0
}

# Restore the terminal exactly once, whatever the exit path (q, Ctrl+C, TERM or error).
cleanup() {
  [[ -n $saved_stty ]] && stty "$saved_stty" 2>/dev/null
  printf '\033[?7h\033[?25h'
  tput rmcup 2>/dev/null || true
  echo "Exiting MySQL Monitor. Goodbye!"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'resized=1' WINCH

# Keys pressed while a refresh is running must not be echoed onto the screen
saved_stty=$(stty -g 2>/dev/null)
stty -echo -icanon 2>/dev/null
tput smcup 2>/dev/null || true
# Hide the cursor, disable line wrapping and clear the screen once.
printf '\033[?25l\033[?7l\033[H\033[J'

state=""
resized=0
VIEW=dashboard
DETAILS=0
SCROLL=0
MAXOFF=0
MORE=0
read_size

# First refresh comes after 1 second so per-second rates appear quickly.
first_wait=1

while true; do
  fetch
  prev_state=$state
  render
  state=$next_state
  draw

  # Wait for the next refresh in short slices so resizes redraw immediately.
  # Resizes and view changes re-render the same sample instead of querying the server again.
  now_us
  deadline=$(( REPLY + ${first_wait:-$INTERVAL} * 1000000 ))
  first_wait=""
  while true; do
    if (( resized )); then
      resized=0
      read_size
      render
      draw
    fi
    now_us
    remaining=$(( deadline - REPLY ))
    (( remaining <= 0 )) && break
    (( remaining > 200000 )) && remaining=200000
    printf -v timeout '0.%06d' "$remaining"
    if read_key "$timeout"; then
      # Apply every key already waiting (e.g. a held arrow key), then redraw once
      changed=0
      apply_key && changed=1
      while read_key 0.005; do apply_key && changed=1; done
      if (( changed )); then
        render
        draw
      fi
    fi
  done
done
