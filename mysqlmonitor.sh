#!/bin/bash
# MySQL Monitor Script
# ---------------------
# Author: Hayden James
# Website: https://consult.haydenjames.io
# Blog: https://linuxblog.io
# ---------------------

TITLE="MySQL Monitor v2026.10.24.02"

# Define minimum terminal width. The required height is measured from the frame itself.
MIN_COLS=50

# Check for required tools. MariaDB 11 prefers its own client names and warns on the
# old ones, so those are tried first.
for tool in awk stty; do
  if ! command -v "$tool" &> /dev/null; then
    echo "Error: $tool is not installed. Please install it and try again."
    exit 1
  fi
done
ADMIN_CLI=""
for c in mariadb-admin mysqladmin; do command -v "$c" &>/dev/null && { ADMIN_CLI=$c; break; }; done
if [[ -z $ADMIN_CLI ]]; then
  echo "Error: mysqladmin (or mariadb-admin) is not installed. Please install the MySQL/MariaDB client tools."
  exit 1
fi

# Default refresh interval in seconds
INTERVAL=5

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [interval]

Live MySQL/MariaDB dashboard for the terminal.

  interval              refresh every N seconds (default $INTERVAL)
  -i, --interval N      same as the positional interval
  -1, --once            print one snapshot and exit (for ssh one-liners, cron, logs)
      --no-color        plain text; also the default when output is not a terminal
      --color           colour even when output is not a terminal
      --ascii           no Unicode glyphs; the default outside a UTF-8 locale
  -h, --help            show this help and exit

Connecting (passed on to mysqladmin):
      --host H, --port P, --socket S, --user U, --defaults-file F, --login-path L
      -- ARGS...        any further mysqladmin options, verbatim

Keys while running:
  q     quit                      ?     help
  h     health checks and advice  r     raw counters (the classic table)
  p     processes (o sort, s sleepers, f filter, up/down select, k kill, c clear history)
  t     top queries from performance_schema (o sort, up/down select)
  d     details: every counter and description (when the dashboard had to leave some out)
  space pause/resume              + -   refresh faster or slower
  ↑ ↓ PgUp PgDn Home End          scroll a view that is taller than the window
  Esc   back to the dashboard

Credentials come from ~/.my.cnf ([client] user= / password=, chmod 600) or
from running as root; a password is never taken on the command line.
Set NO_COLOR=1 to disable colours.
EOF
}

ONCE=0
FORCE_COLOR=""
FORCE_ASCII=0
MYSQL_ARGS=()   # connection options handed to every mysqladmin call
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -i|--interval) shift; [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 )) || { echo "Invalid interval: ${1:-missing}" >&2; exit 1; }; INTERVAL=$(( 10#$1 )) ;;
    -1|--once) ONCE=1 ;;
    --no-color|--no-colour) FORCE_COLOR=0 ;;
    --color|--colour) FORCE_COLOR=1 ;;
    --ascii) FORCE_ASCII=1 ;;
    --host|--port|--socket|--user|--defaults-file|--defaults-extra-file|--login-path)
      [[ -n $2 ]] || { echo "$1 needs a value" >&2; exit 1; }; MYSQL_ARGS+=("$1=$2"); shift ;;
    --host=*|--port=*|--socket=*|--user=*|--defaults-file=*|--defaults-extra-file=*|--login-path=*) MYSQL_ARGS+=("$1") ;;
    --password|--password=*|-p*) echo "Put the password in ~/.my.cnf (chmod 600) instead of on the command line." >&2; exit 1 ;;
    --) shift; MYSQL_ARGS+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 )); then INTERVAL=$(( 10#$1 ))
      else echo "Invalid interval specified. Using default INTERVAL=$INTERVAL seconds."; fi ;;
  esac
  shift
done

# Use Unicode glyphs only in a UTF-8 locale, and honour NO_COLOR (https://no-color.org).
locale_name="${LC_ALL:-${LC_CTYPE:-$LANG}}"
if [[ $locale_name =~ [Uu][Tt][Ff]-?8 ]]; then UNICODE=1; else UNICODE=0; fi
(( FORCE_ASCII )) && UNICODE=0
if [[ -n $FORCE_COLOR ]]; then COLOR=$FORCE_COLOR
elif [[ -n $NO_COLOR ]] || [[ ! -t 1 ]]; then COLOR=0
else COLOR=1; fi

# mysqladmin with the connection options from the command line. --defaults-file must
# come first for mysqladmin to honour it, which the array order preserves. A connect
# timeout keeps a hung server from freezing the keys.
madmin() { command "$ADMIN_CLI" "${MYSQL_ARGS[@]}" --connect-timeout=5 "$@"; }

# Exact per-statement totals from performance_schema, read with the mysql client once per
# refresh and differenced against the previous sample for the top-queries view (t).
TOP_SQL="SELECT DIGEST, IFNULL(SCHEMA_NAME,''), COUNT_STAR, SUM_TIMER_WAIT, MAX_TIMER_WAIT, SUM_ROWS_EXAMINED, SUM_ROWS_SENT, \
SUM_CREATED_TMP_DISK_TABLES, SUM_SORT_MERGE_PASSES, SUM_NO_INDEX_USED, SUM_LOCK_TIME, DIGEST_TEXT \
FROM performance_schema.events_statements_summary_by_digest \
WHERE DIGEST_TEXT NOT LIKE 'SHOW %' AND DIGEST_TEXT NOT LIKE '%performance_schema%' \
ORDER BY SUM_TIMER_WAIT DESC LIMIT 250"
MYSQL_CLI=""
for c in mariadb mysql; do command -v "$c" &>/dev/null && { MYSQL_CLI=$c; break; }; done
mtop() { command "$MYSQL_CLI" "${MYSQL_ARGS[@]}" --connect-timeout=5 -B -N -e "${1:-$TOP_SQL}"; }
# The process list through the client: one tab-separated row per process with newlines
# and tabs inside queries escaped, so rows cannot be forged by query text, and the full
# statement instead of mysqladmin's 100-character cut. Header line included (-B without -N).
mplist() { command "$MYSQL_CLI" "${MYSQL_ARGS[@]}" --connect-timeout=5 -B -e "SHOW FULL PROCESSLIST"; }

# Test if MySQL command requiring credentials succeeds
if ! output=$(madmin status 2>&1); then
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
    if [[ $output == *"Can't connect"* || $output == *"Connection refused"* ]]; then
      echo "Cannot reach the MySQL server. Is it running? (systemctl status mysql / mariadb)"
    else
      echo "Credentials found in ~/.my.cnf, but the command still failed."
      echo "Please verify your credentials or server status."
    fi
    echo "MySQL admin output:"
    echo "$output"
    exit 1
  fi
fi

# Is the client usable with these credentials? Then it supplies the process list.
CLI_OK=0
[[ -n $MYSQL_CLI ]] && mtop "SELECT 1" >/dev/null 2>&1 && CLI_OK=1

# Can the top-queries view work here? Decided once; the view explains any failure.
TOPQ=0; TOP_ERR=""
if [[ -z $MYSQL_CLI ]]; then
  TOP_ERR="The mysql client is not installed; it is needed to read performance_schema."
elif top_out=$(mtop "${TOP_SQL/LIMIT 250/LIMIT 1}" 2>&1); then
  TOPQ=1
else
  TOP_ERR="performance_schema is not readable: ${top_out//$'\n'/ }"
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
  if (b >= 1048576)    return sprintf("%.0f MB", b / 1048576)
  return sprintf("%.0f KB", b / 1024)
}

function pct(x)  { return (x == "") ? "-" : sprintf("%.1f%%", x) }
function pct2(x) { return (x == "") ? "-" : sprintf("%.2f%%", x) }

# Per-second change of a counter since the previous frame ("" when unknown).
function rate(name,    d) {
  if (!have_prev || !(name in have) || !(name in prev)) return ""
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
# A column segment: like padR, but counts segments too wide for their column (OVER)
function colpad(s, w) { if (vw(s) > w) OVER++; return padR(s, w) }
function padL(s, w) { return rep(" ", w - vw(s)) s }
# Shortens plain (unstyled) text to w columns without splitting a UTF-8 character.
function clip(s, w,    i, n, c, out) {
  if (w < 1) return ""
  if (vw(s) <= w) return s
  n = 0; out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c !~ /[\200-\277]/ && ++n > w - 1) break
    out = out c
  }
  return out G_ELL
}

# Shortens styled text to w columns: colour codes are copied, not counted, and a
# reset is appended so a cut line can't leak its style onto the next one.
function clipStyled(s, w,    i, n, c, out, len) {
  if (vw(s) <= w) return s
  n = 0; out = ""; len = length(s)
  for (i = 1; i <= len; i++) {
    c = substr(s, i, 1)
    if (c == "\033") {
      while (i <= len && substr(s, i, 1) != "m") { out = out substr(s, i, 1); i++ }
      out = out "m"
      continue
    }
    if (c !~ /[\200-\277]/ && ++n > w - 1) break
    out = out c
  }
  return out G_ELL RST
}

# Text from the server (queries, users, hosts) can contain anything: drop control
# characters so it can't move the cursor or change colours, and collapse whitespace.
function clean(s) {
  gsub(/[\001-\037\177]/, " ", s)
  gsub(/\302[\200-\237]/, " ", s)      # UTF-8 encoded C1 controls (CSI and friends)
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

function ptitle(t, w) { return paint(BOLD CYN, G_H " " t " ") paint(DIM, rep(G_H, w - vw(t) - 3)) }

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
      if (!(name in have)) continue

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

    if ("Innodb_buffer_pool_pages_free" in have)
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
  right = paint(levelColor(up ? worse(status, 1) : 3), G_DOT " " st) "   " (paused ? paint(BOLD YEL, "PAUSED") : interval "s") "   " clock " "
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

# mode: "fit" (more = 1 when the fitted layout hides something), "details", "raw" or
# "view" (health/help). pos is the visible range while the content scrolls.
# Shortens itself to fit w columns: full labels, short labels, then keys only.
function keybar(mode, more, pos, w,    k, lvl, full) {
  if (mode == "fit") MORE = more
  for (lvl = 1; lvl <= 4; lvl++) {
    full = (lvl < 3)
    k = key("q", full ? "Quit" : "")
    if (view == "help") {
      k = k key("?", full ? "Back" : "")
    } else {
      # Keys-only level in the process view drops the other view switches to fit
      if (!(lvl == 4 && view == "procs")) {
        k = k key("?", full ? "Help" : "")
        k = k key("h", full ? ((view == "health") ? "Dashboard" : "Health") : "")
        k = k key("r", full ? ((view == "raw") ? "Dashboard" : (lvl == 1) ? "Raw counters" : "Raw") : "")
      }
      k = k key("p", full ? ((view == "procs") ? "Dashboard" : (lvl == 1) ? "Processes" : "Procs") : "")
      k = k key("t", full ? ((view == "top") ? "Dashboard" : (lvl == 1) ? "Top queries" : "Top") : "")
      if (view == "top") k = k key("o", full ? "Sort" : "") key(G_UP G_DOWN, full ? "Select" : "")
      if (mode == "fit" && more) k = k key("d", full ? "Details" : "")
      if (mode == "details") k = k key("d", full ? "Less" : "")
      if (view == "procs") {
        k = k key("s", full ? (psleep ? "Hide sleepers" : "Sleepers") : "") key("o", full ? "Sort" : "")
        k = k key("f", full ? "Filter" : "") key("k", full ? "Kill" : "") key("c", full ? "Clear" : "") key(G_UP G_DOWN, full ? "Select" : "")
      }
      if (lvl == 1 && (mode == "fit" || mode == "details")) k = k key("space", paused ? "Resume" : "Pause")
    }
    if (pos != "") k = k key(G_UP G_DOWN, (lvl == 1) ? "PgUp PgDn Scroll" : (lvl < 4) ? "Scroll" : "") ((lvl < 4) ? " " pos : "")
    if (vw(k) <= w) break
  }
  return k
}

# A full-screen text view: header pinned at the top, CONT lines scrolled below it,
# key bar on the last line. Returns the clamped scroll offset.
function pinnedView(off,    W, i) {
  W = cols - 3
  for (i = 1; i <= NC; i++) CONT[i] = clipStyled(CONT[i], W)
  NO = 0
  emit(header(W))
  off = viewport(off, rows - 2, W)
  emit(keybar("view", 0, (MAXOFF > 0) ? posText(off, rows - 2) : "", W))
  return off
}

# ---------- Health view ----------

# One health check: mark, name, now, since-boot, target; advice below it when flagged.
function hrow(lvl, name, now, boot, target, advice,    line, v) {
  v = (lvl >= 2) ? paint(BOLD levelColor(lvl), now) : now
  line = " " mark(lvl) " " padR(clip(name, HN), HN + 1) padL(v, 10)
  if (HB) line = line padL(boot, 12)
  line = line "   " target
  emit(line)
  # Advice wraps onto further lines rather than being cut off: it often ends in the command to run
  if (lvl >= 2 && advice != "") hadvice(advice)
}

function hadvice(text,    n, words, i, line, first, w) {
  n = split(text, words, " "); line = ""; first = 1; w = HW - 8
  for (i = 1; i <= n; i++) {
    if (line != "" && length(line) + 1 + length(words[i]) > w) {
      emit(paint(ITAL, (first ? "      " G_ARROW " " : "        ") line)); line = ""; first = 0
    }
    line = (line == "") ? words[i] : line " " words[i]
  }
  if (line != "") emit(paint(ITAL, (first ? "      " G_ARROW " " : "        ") line))
}

function bootRate(name) { return (cur["Uptime"] > 0) ? formatRate(cur[name] / cur["Uptime"]) : "-" }

function renderHealth(    W, lvl, x, n, eff) {
  HW = cols - 3; HB = (HW >= 72); HN = (HW >= 72) ? 30 : HW - 32
  if (HN < 14) HN = 14
  emit(ptitle("HEALTH CHECKS", HW))
  if (!up) { emit(" " mark(3) " MySQL is not responding: " clip(err, HW - 30)); return }
  emit(paint(BOLD, " " padR("", HN + 2) padL("now " interval "s", 10) (HB ? padL("since boot", 12) : "") "   target"))

  emit(paint(BOLD CYN, " InnoDB"))
  x = (hit_now != "") ? hit_now : hit_boot
  hrow(low(x, 99, 95), "Buffer pool hit ratio", pct2(hit_now), pct2(hit_boot), "> 99%",
       sprintf("innodb_buffer_pool_size = %s. %s RAM available; try %s.", formatBytes(bp_size), formatBytes(mem_avail), formatBytes(bp_size + mem_avail / 2)))
  hrow(high(r_wait, 0.001, 1), "Waits for free pool pages/s", formatRate(r_wait), bootRate("Innodb_buffer_pool_wait_free"), "0",
       sprintf("The pool is too small for the working set: raise innodb_buffer_pool_size (now %s).", formatBytes(bp_size)))
  hrow(!bp_known ? 0 : (cur["Innodb_buffer_pool_pages_free"] == 0) ? 2 : 1, "Buffer pool free", pct(bp_free_pct), "-", "> 0%",
       "The pool is fully used. Fine while the hit ratio stays high; otherwise raise innodb_buffer_pool_size.")
  hrow(high(r_logw, 0.001, 1), "InnoDB log waits/s", formatRate(r_logw), bootRate("Innodb_log_waits"), "0",
       sprintf("innodb_log_buffer_size = %s. Try %s.", formatBytes(vars["innodb_log_buffer_size"]), formatBytes(vars["innodb_log_buffer_size"] * 2)))
  x = (redo_h_now != "") ? redo_h_now : redo_h_boot
  hrow(low(x, 1, 0.25), "Redo log covers (hours)", (redo_h_now != "") ? sprintf("%.1fh", redo_h_now) : "-",
       (redo_h_boot != "") ? sprintf("%.1fh", redo_h_boot) : "-", "> 1h",
       sprintf("Redo log is %s in total; at this write rate it cycles in %.0f minutes, forcing constant checkpoints. Raise innodb_log_file_size%s.",
               formatBytes(redo_total), x * 60, (vars["innodb_redo_log_capacity"] > 0) ? " (innodb_redo_log_capacity)" : ""))
  hrow(high(r_rlw, 1, 10), "Row lock waits/s", formatRate(r_rlw), bootRate("Innodb_row_lock_waits"), "~0",
       sprintf("Transactions are contending (avg wait %.0f ms). Shorten transactions and index the columns in UPDATE/DELETE WHERE clauses.", rlw_ms))

  emit(paint(BOLD CYN, " Connections"))
  hrow(high(peak_pct, 85, 95), "Peak connection usage", pct(conn_pct), pct(peak_pct), "< 85%",
       sprintf("max_connections = %d, peak %d. Raise it, or pool connections in the application.", maxc, cur["Max_used_connections"]))
  x = (tc_now != "") ? tc_now : tc_boot
  n = vars["thread_cache_size"]
  hrow(low(x, 90, 50), "Thread cache hit ratio", pct(tc_now), pct(tc_boot), "> 90%",
       sprintf("thread_cache_size = %d (%s threads created). Try %d.", n, formatNumber(cur["Threads_created"]), (n * 2 > 16) ? n * 2 : 16))
  hrow((cur["Connection_errors_max_connections"] > 0 && r_refused == "") ? 2 : high(r_refused, 0.001, 0.001), "Refused (max_connections)/s",
       formatRate(r_refused), bootRate("Connection_errors_max_connections"), "0",
       sprintf("max_connections = %d was reached and clients were turned away (%s since boot). Raise it, or fix connection leaks and pooling.",
               maxc, formatNumber(cur["Connection_errors_max_connections"])))
  hrow((ncpu > 0) ? high(thr_running, 2 * ncpu, 4 * ncpu) : 0, "Running threads", thr_running "", "-",
       (ncpu > 0) ? "< " 2 * ncpu : "-", "More runnable threads than cores: queries are queuing for CPU. Look at the process list (p) and the slow log.")
  hrow(high(r_abort, 1, 10), "Aborted connections/s", formatRate(r_abort), bootRate("Aborted_connects"), "~0",
       "Failed logins, timeouts or dropped clients: check wait_timeout, max_allowed_packet and the network.")

  emit(paint(BOLD CYN, " Tables"))
  x = (tbl_now != "") ? tbl_now : tbl_boot
  hrow(low(x, 90, 50), "Table cache hit ratio", pct(tbl_now), pct(tbl_boot), "> 90%",
       sprintf("table_open_cache = %d, Open_tables = %d. Try %d.", toc, cur["Open_tables"], toc * 2))
  x = (vars["open_files_limit"] > 0) ? 100 * cur["Open_files"] / vars["open_files_limit"] : ""
  hrow(high(x, 85, 95), "Open files", pct(x), "-", "< 85%",
       sprintf("open_files_limit = %d. Raise it (and the OS limit for mysqld).", vars["open_files_limit"]))
  hrow(high(r_lockw, 0.001, 1), "Table lock waits/s", formatRate(r_lockw), bootRate("Table_locks_waited"), "0",
       "Table-level locks: MyISAM tables? Convert them to InnoDB.")
  hrow(high(rate("Key_reads"), 1, 100), "MyISAM key reads/s", formatRate(rate("Key_reads")), bootRate("Key_reads"), "0",
       sprintf("MyISAM is in use (key_buffer_size = %s). Migrate those tables to InnoDB.", formatBytes(vars["key_buffer_size"])))

  emit(paint(BOLD CYN, " Queries"))
  hrow(high(r_slow, 1, 10), "Slow queries", pct2(slow_now), pct2(slow_boot), "~0%",
       "Find the statements in the slow query log and fix their plans or indexes.")
  x = toupper(svars["slow_query_log"])
  hrow((x == "") ? 0 : (x == "ON" || x == "1") ? 1 : 2, "Slow query log", (x == "") ? "-" : x, "-", "ON",
       sprintf("SET GLOBAL slow_query_log = 1; long_query_time = %s%s", vars["long_query_time"] + 0,
               (vars["long_query_time"] >= 10) ? " is high: try 1-2s." : "."))
  x = toupper(svars["query_cache_type"])
  n = (x != "" && x != "OFF" && x != "0" && vars["query_cache_size"] > 0)
  hrow((x == "") ? 0 : (n ? 2 : 1), "Query cache", (x == "") ? "-" : (n ? "ON" : "OFF"), "-", "OFF",
       sprintf("The query cache serialises queries on multi-core servers (query_cache_size = %s). Set query_cache_type = 0 and query_cache_size = 0.",
               formatBytes(vars["query_cache_size"])))
  x = digestState()
  hrow((x == "ok") ? 1 : (x == "off" || x == "notcollecting") ? 2 : 0, "Statement digests (t view)",
       (x == "ok") ? "ON" : (x == "off") ? "OFF" : (x == "notcollecting") ? "empty" : "-", "-", "ON", digestFix(x))
  hrow(high(r_fj, 1, 10), "Joins without indexes/s", formatRate(r_fj), bootRate("Select_full_join"), "~0",
       "Add indexes on the joined columns (Select_full_join).")
  x = (tmp_now != "") ? tmp_now : tmp_boot
  # MySQL 8.0 builds internal temp tables with TempTable (limited by temptable_max_ram,
  # and per table by tmp_table_size); MySQL 5.7 and MariaDB use MEMORY, where the smaller
  # of tmp_table_size and max_heap_table_size applies and BLOB/TEXT always go to disk.
  if (svars["version"] !~ /MariaDB/ && svars["version"] + 0 >= 8)
    eff = sprintf("tmp_table_size = %s, temptable_max_ram = %s. Try raising both, and look for queries that build large temp tables.",
                  formatBytes(vars["tmp_table_size"]), formatBytes(vars["temptable_max_ram"]))
  else
    eff = sprintf("tmp_table_size / max_heap_table_size = %s / %s (the smaller applies). Try raising both; BLOB/TEXT columns always go to disk.",
                  formatBytes(vars["tmp_table_size"]), formatBytes(vars["max_heap_table_size"]))
  hrow(high(x, 25, 50), "Temp tables on disk", pct(tmp_now), pct(tmp_boot), "< 25%", eff)
  hrow(high(r_smp, 1, 10), "Sort merge passes/s", formatRate(r_smp), bootRate("Sort_merge_passes"), "~0",
       sprintf("sort_buffer_size = %s. Raise it cautiously: it is allocated per sort.", formatBytes(vars["sort_buffer_size"])))

  emit(paint(BOLD CYN, " System"))
  hrow(low(mem_avail_pct, 10, 5), "Memory available", pct(mem_avail_pct), "-", "> 10%",
       sprintf("Only %s free for the OS and page cache. Lower innodb_buffer_pool_size or add RAM.", formatBytes(mem_avail)))
  hrow(high(swap_pct, 20, 50), "Swap in use", pct(swap_pct), "-", "0%",
       sprintf("%s swapped. Lower vm.swappiness and keep memory headroom for mysqld.", formatBytes(swap_used)))
  hrow(high(cpu_pct, 80, 95), "CPU", pct(cpu_pct), "-", "< 80%", "Sustained high CPU: look at the active queries and their plans.")

  emit("")
  emit(paint(ITAL, " Server up " shortTime(cur["Uptime"]) ". Since-boot figures need a day of normal traffic to mean much;"))
  emit(paint(ITAL, " 'now' ratios appear once an interval holds enough events to judge."))
}

# ---------- Processlist view ----------

function procBefore(a, b) {
  if (psort == "id")   return pid[a] + 0 < pid[b] + 0
  if (psort == "user") return (puser[a] < puser[b]) || (puser[a] == puser[b] && ptime[a] > ptime[b])
  if (psort == "db")   return (pdb[a] < pdb[b]) || (pdb[a] == pdb[b] && ptime[a] > ptime[b])
  return ptime[a] > ptime[b]
}

# Builds PO: the processes to list, after the sleeper/filter options, in sort order.
function selectProcs(    i, j, t, c, f, hay) {
  NPO = 0; nrun = 0; nsys = 0; nself = 0
  f = tolower(pfilter)
  for (i = 1; i <= np; i++) {
    c = pcmd[i]
    if (c == "Daemon" || c ~ /^Binlog Dump/ || puser[i] == "system user" || puser[i] == "event_scheduler") { nsys++; continue }
    if (tolower(pinfo[i]) ~ /^show (full )?processlist/) { nself++; continue }
    if (c != "Sleep") nrun++
    if (c == "Sleep" && !psleep) continue
    if (f != "") {
      hay = tolower(pid[i] " " puser[i] " " phost[i] " " pdb[i] " " pstate[i] " " pinfo[i] " " c)
      if (index(hay, f) == 0) continue
    }
    PO[++NPO] = i
  }
  for (i = 2; i <= NPO; i++) {
    t = PO[i]
    for (j = i - 1; j >= 1 && procBefore(t, PO[j]); j--) PO[j + 1] = PO[j]
    PO[j + 1] = t
  }
}

# ---------- Query history: what has run in recent samples ----------

# Groups the same statement with different literals: strings and numbers become ?,
# IN-lists collapse, so repeats can be counted.
function fingerprint(q,    f) {
  f = tolower(q)
  gsub(/\\./, "", f)
  gsub(/'[^']*'/, "?", f); gsub(/"[^"]*"/, "?", f)
  gsub(/[0-9]+/, "?", f)
  gsub(/\?( *, *\?)+/, "?+", f)
  gsub(/  +/, " ", f)
  return substr(f, 1, 300)
}

function dropQ(i,    k) {
  delete qidx[qfp[i]]
  for (k = i; k < NQH; k++) {
    qfp[k] = qfp[k + 1]; qlast[k] = qlast[k + 1]; qcount[k] = qcount[k + 1]; qmax[k] = qmax[k + 1]
    quser[k] = quser[k + 1]; qdb[k] = qdb[k + 1]; qlastid[k] = qlastid[k + 1]; qlive[k] = qlive[k + 1]; qtext[k] = qtext[k + 1]
    qidx[qfp[k]] = k
  }
  NQH--
}

# Records every running client query in this sample. A query seen in consecutive
# samples on the same connection is one run; it counts again when it starts anew.
function noteQueries(    i, fp, k, nowS, oldest, oi) {
  nowS = int(now / 1000000)
  for (k = 1; k <= NQH; k++) qseen[k] = 0
  for (i = 1; i <= np; i++) {
    if (pcmd[i] == "Sleep" || pcmd[i] == "Daemon" || pcmd[i] ~ /^Binlog Dump/ || puser[i] == "system user" || puser[i] == "event_scheduler") continue
    if (pinfo[i] == "" || tolower(pinfo[i]) ~ /^show (full )?processlist/) continue
    fp = fingerprint(pinfo[i])
    k = (fp in qidx) ? qidx[fp] : 0
    if (k == 0) { k = ++NQH; qidx[fp] = k; qfp[k] = fp; qcount[k] = 0; qmax[k] = 0; qlive[k] = 0; qlastid[k] = "" }
    if (!(qlive[k] && qlastid[k] == pid[i])) qcount[k]++
    if (ptime[i] > qmax[k]) qmax[k] = ptime[i]
    qlast[k] = nowS; quser[k] = puser[i]; qdb[k] = pdb[i]; qtext[k] = substr(pinfo[i], 1, 300); qlastid[k] = pid[i]
    qseen[k] = 1
  }
  for (k = 1; k <= NQH; k++) qlive[k] = qseen[k]
  while (NQH > MAXQ) {
    oldest = qlast[1]; oi = 1
    for (k = 2; k <= NQH; k++) if (qlast[k] < oldest) { oldest = qlast[k]; oi = k }
    dropQ(oi)
  }
}

# Sort order for the history: newest first, then most often seen.
function sortHistory(    i, j, t) {
  for (i = 1; i <= NQH; i++) RO[i] = i
  for (i = 2; i <= NQH; i++) {
    t = RO[i]
    for (j = i - 1; j >= 1 && (qlast[RO[j]] < qlast[t] || (qlast[RO[j]] == qlast[t] && qcount[RO[j]] < qcount[t])); j--) RO[j + 1] = RO[j]
    RO[j + 1] = t
  }
}

function ago(sec) { return (sec < 5) ? "now" : fmtDur(sec) " ago" }

# The line shown instead of the key bar while a prompt is open.
function promptLine() {
  if (pedit) return " " paint(BOLD, "Filter: ") pfilter paint(INV, " ") "   Enter apply   Esc cancel"
  if (confirm != "") return " " paint(BOLD YEL, confirm) "   " key("y", "Yes") key("n", "No")
  return ""
}

# Full-screen process list with a selected row, then the recent-query history; the
# selection spans both lists and stays visible. Sets PSEL_OUT, SELID (live rows only)
# and SELDESC for the kill prompt, and NSEL for the key handler.
function renderProcs(sel, off,    W, wide, hwide, i, k, lvl, t, h, line, vh, hdr, last, nowS, base, q, detail) {
  W = cols - 3
  selectProcs(); sortHistory()
  nowS = int(now / 1000000)
  NSEL = NPO + NQH
  if (sel > NSEL) sel = NSEL
  if (sel < 1) sel = (NSEL > 0) ? 1 : 0
  wide = (W >= 100)
  NO = 0
  emit(header(W))
  emit(ptitle(clip(sprintf("PROCESSES  %d shown   %d running, %d sleeping%s   hidden: this monitor%s   sort: %s%s", NPO, nrun, nsleep,
                      psleep ? "" : " (hidden)", (nsys > 0) ? " + " nsys " system" : "", (psort == "") ? "time" : psort,
                      (pfilter != "" && !pedit) ? "   filter: " pfilter : ""), W - 4), W))
  hdr = "   " padR("ID", 9) padR("USER", 11) (wide ? padR("HOST", 16) : "") padR("DB", 13) (wide ? padR("CMD", 8) : "") \
        padL("TIME", 7) "  " (wide ? padR("STATE", 20) : "") "QUERY"
  emit(paint(BOLD, clip(hdr, W)))
  NC = 0
  for (k = 1; k <= NPO; k++) {
    i = PO[k]; t = ptime[i]
    lvl = (pcmd[i] == "Sleep") ? 0 : (t >= 60) ? 3 : (t >= 10) ? 2 : 0
    line = padR(clip(pid[i], 8), 9) padR(clip(puser[i], 10), 11)
    if (wide) { h = phost[i]; sub(/:[0-9]+$/, "", h); line = line padR(clip(h, 15), 16) }
    line = line padR(clip(pdb[i], 12), 13)
    if (wide) line = line padR(clip(pcmd[i], 7), 8)
    line = line padL(fmtDur(t), 7) "  "
    if (wide) line = line padR(clip(pstate[i], 19), 20)
    line = line clip((pinfo[i] != "") ? pinfo[i] : pcmd[i], W - 3 - vw(line))
    if (k == sel) CONT[++NC] = paint(INV, " " G_PTR " " padR(line, W - 3))
    else CONT[++NC] = " " mark(lvl) " " line
    ROWLINE[k] = NC
  }
  if (NPO == 0) CONT[++NC] = " " mark(1) " " paint(GRN, (pfilter != "") ? "No processes match the filter" : \
                               "No client processes right now" ((nself == 0 && np == 0) ? " (processlist empty: PROCESS privilege?)" : ""))
  # Recent queries: what was caught running in earlier samples, newest first
  CONT[++NC] = ""
  CONT[++NC] = ptitle(clip(sprintf("RECENT QUERIES  %d patterns remembered from %ds samples, newest first   repeats grouped by shape", NQH, interval), W - 4), W)
  hwide = (W >= 80)
  CONT[++NC] = paint(BOLD, clip("   " padR("LAST SEEN", 11) padL("SEEN", 5) padL("MAX", 8) "  " (hwide ? padR("USER", 11) padR("DB", 13) : "") "QUERY", W))
  base = NPO
  for (k = 1; k <= NQH; k++) {
    q = RO[k]
    lvl = (qmax[q] >= 60) ? 3 : (qmax[q] >= 10) ? 2 : 0
    line = padR(ago(nowS - qlast[q]), 11) padL("x" qcount[q], 5) padL(fmtDur(qmax[q]), 8) "  "
    if (hwide) line = line padR(clip(quser[q], 10), 11) padR(clip(qdb[q], 12), 13)
    line = line clip(qtext[q], W - 3 - vw(line))
    if (base + k == sel) CONT[++NC] = paint(INV, " " G_PTR " " padR(line, W - 3))
    else CONT[++NC] = " " mark(lvl) " " line
    ROWLINE[base + k] = NC
  }
  if (NQH == 0) CONT[++NC] = "   " paint(ITAL, "Nothing seen yet. Queries caught in a sample stay listed here; press c to clear.")
  # Full text of the selected query above the key bar (rows are clipped)
  detail = ""
  if (sel > 0) {
    detail = (sel <= NPO) ? ((pinfo[PO[sel]] != "") ? pinfo[PO[sel]] : pcmd[PO[sel]]) : qtext[RO[sel - NPO]]
    detail = " " G_PTR " " detail
  }
  vh = rows - 4 - ((detail != "") ? 2 : 0); if (vh < 1) vh = 1
  if (sel > 0) { k = ROWLINE[sel]; if (k - 1 < off) off = k - 1; if (k > off + vh) off = k - vh }
  off = viewport(off, vh, W)
  if (detail != "") {
    emit(clipStyled(paint(DIM, clip(detail, W)), W))
    emit(clipStyled("   " paint(DIM, clip(substr(detail, W + 1), W - 3)), W))
  }
  last = promptLine()
  if (last == "") {
    last = keybar("procs", 0, "", W)
    if (msg != "") last = clipStyled(" " paint(BOLD GRN, msg) " " last, W)
  }
  emit(clipStyled(last, W))
  PSEL_OUT = sel
  SELID = (sel > 0 && sel <= NPO) ? pid[PO[sel]] : "-"
  SELDESC = (sel > 0 && sel <= NPO) ? puser[PO[sel]] "@" phost[PO[sel]] ", " fmtDur(ptime[PO[sel]]) : "-"
  return off
}

# ---------- Top queries view (performance_schema digests) ----------

# Whether statement digests are actually being collected. An empty digest table must
# never read as "no slow queries": either performance_schema is off (MariaDB's default,
# needs my.cnf and a restart), or it is on but statement instrumentation or the
# statements_digest consumer is disabled (fixable at runtime). Sets DIGEST_STATE to
# "ok", "noclient", "off", "notcollecting" or "empty" (server just started).
function digestState(    ps) {
  ps = toupper(svars["performance_schema"])
  if (!topq) return "noclient"
  if (NT > 0) return "ok"
  if (ps == "OFF" || ps == "0") return "off"
  # The monitor's own statements are filtered out, so a running server with real
  # traffic and an empty table is not collecting
  if (cur["Questions"] > 1000) return "notcollecting"
  return "empty"
}

# Emits text word-wrapped to w columns, each line starting with indent.
function emitWrapped(text, w, indent,    n, words, i, line) {
  n = split(text, words, " "); line = ""
  for (i = 1; i <= n; i++) {
    if (line != "" && length(line) + 1 + length(words[i]) > w) { emit(indent line); line = "" }
    line = (line == "") ? words[i] : line " " words[i]
  }
  if (line != "") emit(indent line)
}

function digestFix(st) {
  if (st == "off") return "performance_schema is OFF (MariaDB's default) and can't be enabled at runtime: add performance_schema = ON under [mysqld] in my.cnf and restart."
  if (st == "notcollecting") return "performance_schema is ON but no statement digests are recorded. Enable them: UPDATE performance_schema.setup_consumers SET ENABLED = 'YES' WHERE NAME IN ('global_instrumentation', 'thread_instrumentation', 'statements_digest'); UPDATE performance_schema.setup_instruments SET ENABLED = 'YES' WHERE NAME LIKE 'statement/%';"
  return top_err
}

function fmtPs(ps,    sec) {
  sec = ps / 1e12
  if (sec >= 1)     return sprintf("%.2fs", sec)
  if (sec >= 0.001) return sprintf("%.1fms", sec * 1000)
  return sprintf("%.0f" G_MU "s", sec * 1e6)
}

function topBefore(a, b) {
  if (tsort == "calls") return TC[a] > TC[b]
  if (tsort == "avg")   return TS[a] / TC[a] > TS[b] / TC[b]
  if (tsort == "max")   return tmax[TA[a]] > tmax[TA[b]]
  return TS[a] > TS[b]
}

# Picks the statements with activity in this interval (or since boot on the first
# sample) and sorts them. Fills TA (digest index), TC/TS/TR/TRS/TT/TSO/TN (deltas).
function selectTop(    k, i, j, t, live, d) {
  NTA = 0; TTOTAL = 0
  live = (have_prev_top && have_prev)
  TOP_LIVE = live
  for (k = 1; k <= NT; k++) {
    d = td[k]
    if (live) {
      if (!(d in pdcount)) continue
      i = tcount[k] - pdcount[d]
      if (i <= 0) continue
      NTA++; TA[NTA] = k; TC[NTA] = i; TS[NTA] = tsum[k] - pdsum[d]
      TR[NTA] = trex[k] - pdrex[d]; TRS[NTA] = trsent[k] - pdrsent[d]
      TT[NTA] = ttmp[k] - pdtmp[d]; TSO[NTA] = tsortm[k] - pdsort[d]; TN[NTA] = tnoidx[k] - pdnoidx[d]
    } else {
      if (tcount[k] <= 0) continue
      NTA++; TA[NTA] = k; TC[NTA] = tcount[k]; TS[NTA] = tsum[k]
      TR[NTA] = trex[k]; TRS[NTA] = trsent[k]; TT[NTA] = ttmp[k]; TSO[NTA] = tsortm[k]; TN[NTA] = tnoidx[k]
    }
    if (TS[NTA] < 0) TS[NTA] = 0
    TTOTAL += TS[NTA]
  }
  for (i = 1; i <= NTA; i++) TO[i] = i
  for (i = 2; i <= NTA; i++) {
    t = TO[i]
    for (j = i - 1; j >= 1 && topBefore(t, TO[j]); j--) TO[j + 1] = TO[j]
    TO[j + 1] = t
  }
}

function renderTop(sel, off,    W, i, j, k, lvl, line, vh, detail, avg, ratio, flags, calls, sortname, wide, oneschema, cores, dst) {
  W = cols - 3
  NO = 0
  emit(header(W))
  dst = digestState()
  if (dst == "noclient" || dst == "off" || dst == "notcollecting") {
    emit(ptitle("TOP QUERIES", W))
    emit(" " mark(2) " " clip((dst == "noclient") ? "Not available: " top_err : \
                         (dst == "off") ? "Not available: performance_schema is OFF, so no statements are recorded." : \
                         "Statement digests are not being collected, so this list would be empty.", W - 3))
    emit("   " paint(ITAL, clip("An empty list here would not mean there are no slow queries.", W - 3)))
    emit("")
    emitWrapped(digestFix(dst), W - 6, "   ")
    emit("")
    emit("   This view reads performance_schema.events_statements_summary_by_digest with the mysql client,")
    emit("   and the MySQL user needs SELECT on performance_schema. MySQL has performance_schema on by")
    emit("   default since 5.6; MariaDB ships with it off.")
    emit(keybar("view", 0, "", W))
    NSEL = 0; PSEL_OUT = 0; SELID = "-"; SELDESC = "-"
    return 0
  }
  selectTop()
  NSEL = NTA
  if (sel > NSEL) sel = NSEL
  if (sel < 1) sel = (NSEL > 0) ? 1 : 0
  wide = (W >= 110)
  # When every statement is in the same schema, say so once instead of a column
  oneschema = (NTA > 0) ? tschema[TA[1]] : ""
  for (j = 2; j <= NTA; j++) if (tschema[TA[j]] != oneschema) { oneschema = ""; break }
  cores = (TOP_LIVE && elapsed > 0) ? sprintf(" = %.2f cores", TTOTAL / 1e12 / elapsed) : ""
  sortname = (tsort == "calls") ? "calls" : (tsort == "avg") ? "average latency" : (tsort == "max") ? "max latency" : "total time"
  emit(ptitle(clip(sprintf("TOP QUERIES  by %s   %s   %d statements, %s of query time%s%s%s", sortname,
                           TOP_LIVE ? "last " interval "s" : "since boot (first sample; live figures next refresh)",
                           NTA, fmtPs(TTOTAL), cores, (oneschema != "") ? "   schema: " oneschema : "",
                           (top_err != "") ? "   " top_err : ""), W - 4), W))
  emit(paint(BOLD, clip("   " padL(TOP_LIVE ? "CALLS/s" : "CALLS", 8) padL("AVG", 8) padL("MAX/boot", 9) padL("TIME%", 6) padL("EXAM/SENT", 10) \
                        "  " (wide ? padR("FLAGS", 11) ((oneschema == "") ? padR("SCHEMA", 11) : "") : "") "QUERY", W)))
  NC = 0
  for (j = 1; j <= NTA; j++) {
    i = TO[j]; k = TA[i]
    avg = TS[i] / TC[i] / 1e12
    ratio = (TRS[i] > 0) ? TR[i] / TRS[i] : ((TR[i] > 0) ? TR[i] : "")
    flags = ((TT[i] > 0) ? "tmp " : "") ((TSO[i] > 0) ? "sort " : "") ((TN[i] > 0) ? "noidx" : "")
    lvl = high(avg, 0.1, 1)
    if (ratio != "" && ratio >= 1000) lvl = worse(lvl, 2)
    # No index is only a concern when the statement actually reads a lot per call
    if (TT[i] > 0 || (TN[i] > 0 && TR[i] / TC[i] >= 1000)) lvl = worse(lvl, 2)
    if (lvl < 1) lvl = 1
    calls = TOP_LIVE ? formatRate(TC[i] / elapsed) : formatNumber(TC[i])
    line = padL(calls, 8) padL(fmtPs(TS[i] / TC[i]), 8) padL(fmtPs(tmax[k]), 9) \
           padL((TTOTAL > 0) ? sprintf("%.0f%%", 100 * TS[i] / TTOTAL) : "-", 6) \
           padL((ratio == "") ? "-" : (TRS[i] > 0) ? formatNumber(ratio) : formatNumber(ratio) "/0", 10) "  "
    if (wide) line = line padR(flags, 11) ((oneschema == "") ? padR(clip(tschema[k], 10), 11) : "")
    line = line clip(ttext[k], W - 3 - vw(line))
    if (j == sel) CONT[++NC] = paint(INV, " " G_PTR " " padR(line, W - 3))
    else CONT[++NC] = " " mark(lvl) " " line
  }
  if (NTA == 0) CONT[++NC] = (dst == "empty") ? "   No statements recorded yet (the server has only just started)." : \
                             " " mark(1) " " paint(GRN, TOP_LIVE ? "No statements ran in the last " interval "s" : "No statements recorded")
  detail = (sel > 0) ? " " G_PTR " " ttext[TA[TO[sel]]] : ""
  vh = rows - 4 - ((detail != "") ? 2 : 0); if (vh < 1) vh = 1
  if (sel > 0) { if (sel - 1 < off) off = sel - 1; if (sel > off + vh) off = sel - vh }
  off = viewport(off, vh, W)
  if (detail != "") {
    emit(clipStyled(paint(DIM, clip(detail, W)), W))
    emit(clipStyled("   " paint(DIM, clip(substr(detail, W + 1), W - 3)), W))
  }
  emit(clipStyled(keybar("top", 0, "", W), W))
  PSEL_OUT = sel; SELID = "-"; SELDESC = "-"
  return off
}

# ---------- Help view ----------

function helpKey(k, text) { emit("   " padR(paint(INV, " " k " "), 12) text) }

function renderHelp(    W) {
  W = cols - 3
  emit(ptitle("HELP", W))
  emit(paint(BOLD CYN, " Keys"))
  helpKey("q", "Quit")
  helpKey("?", "This help")
  helpKey("h", "Health checks with tuning advice")
  helpKey("r", "Raw counters: the classic table")
  helpKey("d", "Details: every counter and description (when the dashboard had to leave some out)")
  helpKey(G_UP G_DOWN, "Scroll a view that is taller than the window (also PgUp PgDn, Home End; j k outside the process view)")
  helpKey("p", "Processes: sort (o), show sleepers (s), filter (f), select (" G_UP G_DOWN ") and kill (k)")
  emit("                Below the live list, recent queries caught in earlier samples stay listed,")
  emit("                grouped by shape with how often and how long they ran (c clears them).")
  helpKey("t", "Top queries: exact per-statement totals from performance_schema, differenced every")
  emit("                refresh: calls/s, average and max latency, share of time, rows examined per row sent;")
  emit("                o sorts by time, calls, average or max. Needs the mysql client and performance_schema.")
  helpKey("space", "Pause and resume refreshing")
  helpKey("+ -", "Refresh faster or slower (1, 2, 3, 5, 10, 15, 30, 60 seconds)")
  helpKey("Esc", "Back to the dashboard")
  emit("")
  emit(paint(BOLD CYN, " Marks"))
  emit("   " mark(1) " healthy    " mark(2) " worth a look    " mark(3) " act on this")
  emit("   Values that need attention are shown in bold " paint(YEL, "yellow") " or " paint(RED, "red") ".")
  emit("")
  emit(paint(BOLD CYN, " Numbers"))
  emit("   Rates (/s) are measured between refreshes; 'avg' and 'total' count since the server started.")
  emit("   Hit ratios show the current interval, or 'since boot' until an interval holds enough events.")
  emit("   Sparklines show the last " HIST_MAX " refreshes. Bars show usage of a configured limit, such as")
  emit("   max_connections or table_open_cache. The layout adapts to the window: resize it to see more.")
  emit("")
  emit(paint(BOLD CYN, " Command line"))
  emit("   " padR("mysqlmonitor.sh [interval]", 32) "Refresh every N seconds (default 5)")
  emit("   " padR("--once", 32) "Print one snapshot and exit (ssh one-liners, cron)")
  emit("   " padR("--host H  --socket S  --user U", 32) "Connection options, passed on to mysqladmin")
  emit("   " padR("--help", 32) "All options and keys")
  emit("")
  emit("   Credentials: ~/.my.cnf with [client] user= and password= (chmod 600), or run as root.")
  emit("   Set NO_COLOR=1 to disable colours. Non-UTF-8 terminals get an ASCII version.")
}

function buildPanels(    p) {
  NP = 0
  if (!up) {
    ORDER[++NP] = "err"; panel("err", "MYSQL")
    pl(L(3, "Status", "DOWN", "", "retrying every refresh", ""))
    if (err != "") pl("   " paint(RED, clip(err, PW - 3)))
  } else {
    ORDER[++NP] = "thr"; panel("thr", "THROUGHPUT")
    pl(L(0, "Queries/s", formatRate(r_q), spark("qps", GW, 1), "avg " formatRate(avg_qps), "Client requests per second (not this monitor's)."))
    pl(L(high(r_slow, 1, 10), "Slow/s", formatRate(r_slow), spark("slow", GW, 1),
         (slow_pct != "") ? pct2(slow_pct) " slow" : "total " formatNumber(cur["Slow_queries"]),
         "Queries exceeding long_query_time."))
    pl(R(0, "Sel scan/s", "Select_scan", spark("scan", GW, 1), "Full table scans in SELECT queries."))
    pl(R(high(r_fj, 1, 10), "Full join/s", "Select_full_join", "", "Joins without usable indexes."))
    pd(L(0, "Questions", formatNumber(cur["Questions"]), "", "since boot", "Total number of client requests."))
    pd(L(0, "Uptime", "", "", prettyTime(cur["Uptime"]), "Wait 24h for accuracy."))

    ORDER[++NP] = "con"; panel("con", "CONNECTIONS")
    pl(L(high(conn_pct, 85, 95), "Connected", thr_conn ((maxc > 0) ? "/" maxc : ""),
         bar(conn_pct, GW, 85, 95), pct(conn_pct), "Open connections, excluding this monitor."))
    pl(L(0, "Running", thr_running, spark("running", GW, ncpu), (ncpu > 0) ? ncpu " cores" : "",
         "Threads running queries, excluding this monitor."))
    pl(L(high(peak_pct, 85, 95), "Peak", cur["Max_used_connections"] ((maxc > 0) ? "/" maxc : ""),
         bar(peak_pct, GW, 85, 95), pct(peak_pct), "Max concurrent connections so far."))
    pl(L(high(r_abort, 1, 10), "Aborted/s", formatRate(r_abort), "", "clients + connects", "Failed connections per second."))
    pl(L((r_conn >= 1) ? low(tc_now, 90, 50) : 0, "Thread cache", pct((tc_now != "") ? tc_now : tc_boot), "",
         (tc_now != "") ? "boot " pct(tc_boot) : "since boot", "Faster connection handling. > 90%."))
    pd(L(0, "Connections/s", formatRate(r_conn), "", "total " formatNumber(cur["Connections"]), "New connections per second (not this monitor's)."))
    pd(R(0, "Created/s", "Threads_created", "", "Threads created for connections."))
    pd(L(0, "Cached", cur["Threads_cached"], "", "", "Threads in the thread cache."))
    pd(L(0, "Aborted cli", formatNumber(cur["Aborted_clients"]), "", "since boot", "Failed client connections."))
    pd(L(0, "Aborted conn", formatNumber(cur["Aborted_connects"]), "", "since boot", "Failed MySQL server connections."))

    ORDER[++NP] = "bp"; panel("bp", "INNODB BUFFER POOL")
    pl(L(0, "Size", (bp_size > 0) ? formatBytes(bp_size) : "-", bar(bp_used_pct, GW, 101, 101), pct(bp_used_pct) " used",
         "Set by innodb_buffer_pool_size."))
    pl(L((bp_known && cur["Innodb_buffer_pool_pages_free"] == 0) ? 2 : 0, "Free", formatBytes(bp_free), "",
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
    pd(R(high(r_rlw, 1, 10), "Row lock wt/s", "Innodb_row_lock_waits", "", "InnoDB row lock waits (contention)."))
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
  OVER = 0
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
      if (vw(seg) > colw) OVER++
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
  OVER = 0
  emit(header(2 * colw + 3))
  if (up) {
    emit(colpad(L(0, "QPS", formatRate(r_q), spark("qps", GW, 1), ""), colw) sep \
         L(high(conn_pct, 85, 95), "Conn", thr_conn ((maxc > 0) ? "/" maxc : ""), bar(conn_pct, GW, 85, 95), (GW > 0) ? pct(conn_pct) : ""))
    emit(colpad(L(high(r_slow, 1, 10), "Slow/s", formatRate(r_slow), spark("slow", GW, 1), ""), colw) sep \
         L(0, "Running", thr_running, spark("running", GW, ncpu), ""))
    emit(colpad(L(low(hit_now, 99, 95), "BP hit", pct2((hit_now != "") ? hit_now : hit_boot), "", ""), colw) sep \
         L(high(mem_used_pct, 90, 95), "Memory", pct(mem_used_pct), bar(mem_used_pct, GW, 90, 95), ""))
    emit(colpad(L((r_tmp >= 1) ? high(tmp_now, 25, 50) : 0, "Tmp disk", pct((tmp_now != "") ? tmp_now : tmp_boot), "", ""), colw) sep \
         L(high(cpu_pct, 80, 95), "CPU", pct(cpu_pct), bar(cpu_pct, GW, 80, 95), ""))
    # Extra pairs when the terminal has spare rows (CX = 0..3, set by fit)
    if (CX >= 1)
      emit(colpad(L(0, "Scans/s", formatRate(r_scan), spark("scan", GW, 1), ""), colw) sep \
           L(high(peak_pct, 85, 95), "Peak", cur["Max_used_connections"] ((maxc > 0) ? "/" maxc : ""), bar(peak_pct, GW, 85, 95), ""))
    if (CX >= 2)
      emit(colpad(L(0, "Disk rd/s", formatRate(r_bpr), spark("bpr", GW, 1), ""), colw) sep \
           ((swap_total > 0) ? L(high(swap_pct, 20, 50), "Swap", pct(swap_pct), bar(swap_pct, GW, 20, 50), "") : L(0, "Swap", "none", "", "")))
    if (CX >= 3)
      emit(colpad(L((toc > 0 && cur["Open_tables"] >= toc && r_opened >= 1) ? 2 : 0, "Open tbl", pct(ot_pct), bar(ot_pct, GW, 95, 101), ""), colw) sep \
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
  MAXQ = 40        # remembered query patterns
  pfilter = clean(ENVIRON["MM_FILTER"]); confirm = clean(ENVIRON["MM_CONFIRM"]); msg = clean(ENVIRON["MM_MSG"]); top_err = clean(ENVIRON["MM_TOPERR"])
  if (marker == "") marker = "@@"  # section marker; the script passes a nonce so server text can't forge one
  ml = length(marker)
  DESC_MIN = 84    # narrowest column that fits descriptions (without the graphic)

  # Dim is kept for decoration only (bar tracks, separators, rules): many terminal themes
  # render it too dark to read. Bold is reserved for values that need attention.
  if (color) {
    RED = "\033[31m"; GRN = "\033[32m"; YEL = "\033[33m"; CYN = "\033[36m"
    DIM = "\033[2m"; BOLD = "\033[1m"; ITAL = "\033[3m"; INV = "\033[7m"; RST = "\033[0m"
  }
  if (unicode) {
    G_FULL = "█"; G_EMPTY = "░"; G_OK = "✓"; G_WARN = "⚠"; G_CRIT = "✗"
    G_DOT = "●"; G_SEP = "▸"; G_H = "─"; G_V = "│"; G_ELL = "…"; G_UP = "↑"; G_DOWN = "↓"; G_ARROW = "→"; G_PTR = "▶"; G_MU = "µ"
    split("_ ▁ ▂ ▃ ▄ ▅ ▆", SPK, " "); SPK[1] = " "
  } else {
    G_FULL = "#"; G_EMPTY = "."; G_OK = "+"; G_WARN = "!"; G_CRIT = "x"
    G_DOT = "*"; G_SEP = ">"; G_H = "-"; G_V = "|"; G_ELL = "~"; G_UP = "Up"; G_DOWN = "Dn"; G_ARROW = "->"; G_PTR = ">"; G_MU = "u"
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
             "Threads_cached Threads_connected Threads_created Threads_running Uptime " \
             "Connection_errors_max_connections Innodb_os_log_written Innodb_row_lock_time Innodb_row_lock_waits", metrics, " ")
  for (i = 1; i <= nm; i++) wanted[metrics[i]] = 1
  wanted["Innodb_buffer_pool_pages_total"] = 1

  split("Innodb_buffer_pool_pages_free Max_used_connections Open_files Open_tables " \
        "Threads_cached Threads_connected Threads_running Uptime", g, " ")
  for (i in g) gauge[g[i]] = 1

  split("innodb_buffer_pool_size innodb_page_size max_connections table_open_cache hostname version " \
        "thread_cache_size tmp_table_size max_heap_table_size slow_query_log long_query_time " \
        "innodb_log_buffer_size open_files_limit sort_buffer_size key_buffer_size " \
        "innodb_log_file_size innodb_log_files_in_group innodb_redo_log_capacity query_cache_type query_cache_size performance_schema temptable_max_ram", v, " ")
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
  desc["Connection_errors_max_connections"]= "Clients refused: max_connections hit."
  desc["Innodb_os_log_written"]            = "Bytes written to the redo log."
  desc["Innodb_row_lock_time"]             = "Time spent waiting for row locks (ms)."
  desc["Innodb_row_lock_waits"]            = "Row lock waits (contention)."

  section = ""; tables = 0; err = ""
}

substr($0, 1, ml) == marker { section = substr($1, ml + 1); if (section == "TIME") now = $2; next }

section == "PREV" {
  if ($1 == "D") {
    # Previous digest totals: D digest count sum rows_ex rows_sent tmp sort noidx
    n = split($0, f, "\t"); k = f[2]
    pdcount[k] = f[3] + 0; pdsum[k] = f[4] + 0; pdrex[k] = f[5] + 0; pdrsent[k] = f[6] + 0
    pdtmp[k] = f[7] + 0; pdsort[k] = f[8] + 0; pdnoidx[k] = f[9] + 0; have_prev_top = 1
    next
  }
  if ($1 == "Q") {
    # Remembered query: Q fp last count max user db lastid live text (tab-separated)
    n = split($0, f, "\t"); k = ++NQH
    qfp[k] = f[2]; qlast[k] = f[3] + 0; qcount[k] = f[4] + 0; qmax[k] = f[5] + 0
    quser[k] = f[6]; qdb[k] = f[7]; qlastid[k] = f[8]; qlive[k] = f[9] + 0; qtext[k] = f[10]
    qidx[qfp[k]] = k
  }
  else if ($1 ~ /^H_/) hist[substr($1, 3)] = $2
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
    if (tables == 1 && (name in wanted)) { cur[name] = val + 0; have[name] = 1 }
    else if (tables == 2 && (name in wanted_var)) { vars[name] = val + 0; svars[name] = clean(val) }
    else if (tables == 3 && name ~ /^[0-9]+$/ && n >= pcol["Info"] + 1 && trim(f[pcol["Time"] + 1]) ~ /^[0-9]*$/) addProcess(f, n)
    else if (tables == 3) contLine($0)
  } else if (tables == 3 && $0 !~ /^\+/) {
    contLine($0)
  } else if ($0 !~ /^\+/ && $0 != "") {
    err = (err == "") ? clean($0) : err " " clean($0)
  }
  next
}

# A later line of a multi-line query: keep its text, drop the table columns after Info
# (one "|" group per trailing column, plus the closing "|").
function contLine(l,    k, tail) {
  if (np == 0) return
  tail = pcols - pcol["Info"]
  for (k = 0; k <= tail; k++) sub(/ *\|[^|]*$/, "", l)
  pinfo[np] = pinfo[np] " " l
}

# Process list from the client (tab-separated, header first). Batch mode escapes
# newlines, tabs and backslashes inside values, so one line is always one process.
section == "PLIST" {
  n = split($0, f, "\t")
  if (f[1] == "Id") { for (i = 1; i <= n; i++) pcolt[f[i]] = i; plist = 1; next }
  if (!plist || n < pcolt["Info"]) { if (!plist && $0 != "") err = (err == "") ? clean($0) : err " " clean($0); next }
  np++
  pid[np] = clean(f[pcolt["Id"]]); puser[np] = clean(f[pcolt["User"]]); phost[np] = clean(f[pcolt["Host"]])
  pdb[np] = clean(f[pcolt["db"]]); pcmd[np] = clean(f[pcolt["Command"]]); ptime[np] = clean(f[pcolt["Time"]]) + 0
  pstate[np] = clean(f[pcolt["State"]]); pinfo[np] = f[pcolt["Info"]]
  if (pdb[np] == "NULL") pdb[np] = ""
  if (pstate[np] == "NULL") pstate[np] = ""
  if (pinfo[np] == "NULL") pinfo[np] = ""
  gsub(/\\n|\\t/, " ", pinfo[np]); gsub(/\\\\/, "\\", pinfo[np])
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

section == "TOP" {
  if (index($0, "\t") == 0) { if ($0 != "") top_err = (top_err == "") ? clean($0) : top_err " " clean($0); next }
  n = split($0, f, "\t"); if (n < 12) next
  k = ++NT
  td[k] = clean(f[1]); tschema[k] = clean(f[2]); tcount[k] = f[3] + 0; tsum[k] = f[4] + 0; tmax[k] = f[5] + 0
  trex[k] = f[6] + 0; trsent[k] = f[7] + 0; ttmp[k] = f[8] + 0; tsortm[k] = f[9] + 0; tnoidx[k] = f[10] + 0; tlock[k] = f[11] + 0
  ttext[k] = f[12]; for (i = 13; i <= n; i++) ttext[k] = ttext[k] " " f[i]
  ttext[k] = clean(ttext[k])
  next
}

END {
  up = ("Uptime" in have)
  bp_known = ("Innodb_buffer_pool_pages_free" in have)
  have_prev = ("T" in prev) && ("Uptime" in prev) && up && cur["Uptime"] >= prev["Uptime"]
  elapsed = have_prev ? (now - prev["T"]) / 1000000 : 0
  if (elapsed <= 0) have_prev = 0

  # ---------- Derived metrics ----------
  host = clean(svars["hostname"])
  server = clean(svars["version"])
  if (server != "") {
    sub(/-.*/, "", server)
    server = ((svars["version"] ~ /MariaDB/) ? "MariaDB " : "MySQL ") server
  }

  avg_qps = (cur["Uptime"] > 0) ? cur["Questions"] / cur["Uptime"] : ""
  r_q = rate("Questions"); r_slow = rate("Slow_queries"); r_scan = rate("Select_scan")
  # This monitor's own work is in the counters too: 3 statements and 1 connection per
  # sample (one more of each with the top-queries query), and its own thread in the
  # gauges. Take them out so an idle server reads as idle.
  own_q = 3 + (topq ? 1 : 0); own_c = 1 + (topq ? 1 : 0)
  if (r_q != "" && elapsed > 0) { r_q -= own_q / elapsed; if (r_q < 0) r_q = 0 }
  thr_running = cur["Threads_running"] - 1; if (thr_running < 0) thr_running = 0
  thr_conn = cur["Threads_connected"] - 1; if (thr_conn < 0) thr_conn = 0
  # Share of queries that were slow: a rate alone means little without the load behind it
  slow_boot = (cur["Questions"] > 0) ? 100 * cur["Slow_queries"] / cur["Questions"] : ""
  slow_now = (have_prev && delta("Questions") > 0) ? 100 * delta("Slow_queries") / delta("Questions") : ""
  slow_pct = (slow_now != "") ? slow_now : slow_boot
  r_refused = rate("Connection_errors_max_connections")
  r_rlw = rate("Innodb_row_lock_waits")
  rlw_ms = (have_prev && delta("Innodb_row_lock_waits") > 0) ? delta("Innodb_row_lock_time") / delta("Innodb_row_lock_waits") : \
           (cur["Innodb_row_lock_waits"] > 0) ? cur["Innodb_row_lock_time"] / cur["Innodb_row_lock_waits"] : ""
  # Redo log: hours of writes it holds at the current (and since-boot) write rate
  redo_total = (vars["innodb_redo_log_capacity"] > 0) ? vars["innodb_redo_log_capacity"] : \
               vars["innodb_log_file_size"] * ((vars["innodb_log_files_in_group"] > 0) ? vars["innodb_log_files_in_group"] : 1)
  r_redo = rate("Innodb_os_log_written")
  redo_h_now = (redo_total > 0 && r_redo > 0) ? redo_total / (r_redo * 3600) : ""
  redo_h_boot = (redo_total > 0 && cur["Uptime"] > 0 && cur["Innodb_os_log_written"] > 0) ? redo_total / (cur["Innodb_os_log_written"] / cur["Uptime"] * 3600) : ""
  r_fj = rate("Select_full_join"); r_conn = rate("Connections")
  if (r_conn != "" && elapsed > 0) { r_conn -= own_c / elapsed; if (r_conn < 0) r_conn = 0 }
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
  # A ratio over a handful of events is noise: "now" ratios need a minimum sample,
  # otherwise the since-boot value is shown and no alert is raised.
  if (have_prev && delta("Innodb_buffer_pool_read_requests") >= 1000) {
    hit_now = 100 * (1 - delta("Innodb_buffer_pool_reads") / delta("Innodb_buffer_pool_read_requests"))
    if (hit_now < 0) hit_now = 0
  }

  tc_boot = ""; tc_now = ""
  if (cur["Connections"] > 0) tc_boot = 100 * (1 - cur["Threads_created"] / cur["Connections"])
  if (have_prev && delta("Connections") >= 10) tc_now = 100 * (1 - delta("Threads_created") / delta("Connections"))

  tbl_boot = ""; tbl_now = ""
  total = cur["Table_open_cache_hits"] + cur["Table_open_cache_misses"]
  if (total > 0) tbl_boot = 100 * cur["Table_open_cache_hits"] / total
  if (have_prev) {
    total = delta("Table_open_cache_hits") + delta("Table_open_cache_misses")
    if (total >= 20) tbl_now = 100 * delta("Table_open_cache_hits") / total
  }

  tmp_boot = ""; tmp_now = ""
  if (cur["Created_tmp_tables"] > 0) tmp_boot = 100 * cur["Created_tmp_disk_tables"] / cur["Created_tmp_tables"]
  if (have_prev && delta("Created_tmp_tables") >= 20) tmp_now = 100 * delta("Created_tmp_disk_tables") / delta("Created_tmp_tables")

  maxc = vars["max_connections"]
  conn_pct = (maxc > 0) ? 100 * thr_conn / maxc : ""
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
    pushHist("running", thr_running)
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
    else if (bp_known && bp_free_pct != "" && cur["Innodb_buffer_pool_pages_free"] == 0)
      addAlert(2, "Buffer pool has no free pages. Consider raising innodb_buffer_pool_size.")
    if (r_logw > 0)
      addAlert(2, sprintf("InnoDB log waits %s/s. Consider raising innodb_log_buffer_size.", formatRate(r_logw)))
    if (conn_pct != "" && conn_pct >= 85)
      addAlert(high(conn_pct, 85, 95), sprintf("%d of %d connections in use (%.0f%%).", thr_conn, maxc, conn_pct))
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
      addAlert(high(r_slow, 1, 10), sprintf("%s slow queries/s (%s of all queries). Check the slow query log.", formatRate(r_slow), pct2(slow_pct)))
    if (r_fj >= 1)
      addAlert(2, sprintf("%s joins/s without usable indexes (Select_full_join).", formatRate(r_fj)))
    if (r_lockw > 0)
      addAlert(2, sprintf("Table lock waits %s/s. MyISAM tables? Consider converting them to InnoDB.", formatRate(r_lockw)))
    if (r_refused > 0)
      addAlert(3, sprintf("Clients are being refused: max_connections (%d) was reached.", maxc))
    if (r_rlw >= 1)
      addAlert(high(r_rlw, 1, 10), sprintf("InnoDB row lock waits %s/s (avg %.0f ms): transactions are contending.", formatRate(r_rlw), rlw_ms))
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
  if (up) noteQueries()

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
  else if (view == "procs") { SCROLL_OUT = renderProcs(psel, scroll); CHOSEN = "procs" }
  else if (view == "top") { SCROLL_OUT = renderTop(psel, scroll); CHOSEN = "top" }
  else if (view == "health" || view == "help") {
    if (view == "health") renderHealth(); else renderHelp()
    NC = NO; for (i = 1; i <= NO; i++) CONT[i] = OUT[i]
    SCROLL_OUT = pinnedView(scroll)
    CHOSEN = view
  }
  else if (details) SCROLL_OUT = layoutDetails(scroll)
  else layoutBest()
  for (i = 1; i <= NO; i++) print OUT[i]
  # Scroll position after clamping, the furthest it can scroll, and whether the
  # fitted dashboard hides anything (so 'd' is offered)
  print "@@SCROLL " SCROLL_OUT " " MAXOFF " " (MORE + 0)
  print "@@PROC " (NSEL + 0) " " (PSEL_OUT + 0) " " ((SELID == "") ? "-" : SELID) " " ((SELDESC == "") ? "-" : SELDESC)
  # Layout report for the size test harness (-v debug=1)
  if (debug) printf "LAYOUT %s|%d|%d|%d\n", CHOSEN, NO, QROWS, OVER > "/dev/stderr"

  print "@@STATE"
  printf "T %.0f\n", now
  if (cpu_total > 0) printf "cpu_total %.0f\ncpu_idle %.0f\n", cpu_total, cpu_idle
  for (name in have) printf "%s %.0f\n", name, cur[name]
  for (name in hist) printf "H_%s %s\n", name, hist[name]
  for (k = 1; k <= NT; k++)
    printf "D\t%s\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\n", td[k], tcount[k], tsum[k], trex[k], trsent[k], ttmp[k], tsortm[k], tnoidx[k]
  for (k = 1; k <= NQH; k++)
    printf "Q\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%d\t%s\n", qfp[k], qlast[k], qcount[k], qmax[k], quser[k], qdb[k], qlastid[k], qlive[k], qtext[k]
}
AWK

# Section marker for the awk input. A random one, so nothing a client can put in a
# query text can forge a section boundary.
MARK="@@$RANDOM$RANDOM$RANDOM@"

# Collects a new sample; the only external command is mysqladmin.
fetch() {
  local line
  now_us; sample_time=$REPLY
  printf -v clock '%(%H:%M:%S)T' -1
  sample=$(
    if (( CLI_OK )); then
      madmin extended-status variables 2>&1
      printf '%sPLIST\n' "$MARK"; mplist 2>&1
    else
      madmin extended-status variables processlist 2>&1
    fi
    printf '%sMEMINFO\n' "$MARK"
    [[ -r /proc/meminfo ]] && printf '%s\n' "$(</proc/meminfo)"
    printf '%sCPU\n' "$MARK"
    if [[ -r /proc/stat ]]; then
      while read -r line && [[ $line == cpu* ]]; do printf '%s\n' "$line"; done < /proc/stat
    fi
    printf '%sLOAD\n' "$MARK"
    [[ -r /proc/loadavg ]] && printf '%s\n' "$(</proc/loadavg)"
    if (( TOPQ )); then printf '%sTOP\n' "$MARK"; mtop 2>&1; fi
  )
}

# Lays out the current sample for the current terminal size and view.
render() {
  local out
  local filter=$PFILTER
  (( EDIT )) && filter=$EDITBUF
  out=$(LC_ALL=C MM_FILTER=$filter MM_CONFIRM=$CONFIRM MM_MSG=$MSG MM_TOPERR=$TOP_ERR \
        awk -v title="$TITLE" -v rows="$rows" -v cols="$cols" -v view="$VIEW" \
          -v interval="$INTERVAL" -v clock="$clock" -v unicode="$UNICODE" -v color="$COLOR" -v details="$DETAILS" -v scroll="$SCROLL" \
          -v paused="$PAUSED" -v psort="$PSORT" -v psleep="$PSLEEP" -v psel="$PSEL" -v pedit="$EDIT" \
          -v topq="$TOPQ" -v tsort="$TSORT" -v marker="$MARK" \
          "$RENDER_AWK" <<< "${MARK}TIME $sample_time"$'\n'"${MARK}PREV"$'\n'"$prev_state"$'\n'"${MARK}CUR"$'\n'"$sample" 2>&1)
  if [[ $out != *$'\n'@@STATE$'\n'* ]]; then
    # awk failed: show its error instead of a blank screen, and keep the previous state
    frame="Internal error while drawing the screen:"$'\n'"$out"
    next_state=$prev_state
    return
  fi
  frame=${out%%$'\n'@@SCROLL *}
  local meta=${out#*$'\n'@@SCROLL }
  read -r SCROLL MAXOFF MORE <<< "${meta%%$'\n'*}"
  if [[ $VIEW == procs || $VIEW == top ]]; then
    meta=${out#*$'\n'@@PROC }
    read -r NPROC PSEL SELID SELDESC <<< "${meta%%$'\n'*}"
  fi
  next_state=${out#*$'\n'@@STATE$'\n'}
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

read_size() {
  read -r rows cols < <(stty size 2>/dev/null < /dev/tty) || { rows=24; cols=80; }
  (( rows > 0 && cols > 0 )) || { rows=24; cols=80; }
}

# Reads one keypress into KEY, decoding arrow/page/home/end escape sequences into
# names (up, down, pgup, pgdn, home, end); a lone Esc becomes "esc".
read_key() {
  local k c seq=""
  IFS= read -t "$1" -n 1 -s -r k || return 1
  if [[ $k == "" ]]; then k=enter
  elif [[ $k == $'\x7f' || $k == $'\b' ]]; then k=bs
  elif [[ $k == $'\e' ]]; then
    # The rest of an arrow/page key follows the Esc; allow for SSH latency, and once a
    # sequence has clearly started, wait longer for its final byte
    local t=0.05
    while read -t "$t" -n 1 -s -r c; do
      seq+=$c
      [[ $c == [A-Za-z~] && ${#seq} -gt 1 ]] && break
      t=0.25
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

# Steps the refresh interval through fixed values and refreshes at once.
step_interval() {
  local steps=(1 2 3 5 10 15 30 60) i n idx=-1
  n=${#steps[@]}
  for (( i = 0; i < n; i++ )); do (( steps[i] >= INTERVAL )) && { idx=$i; break; }; done
  (( idx < 0 )) && idx=$(( n - 1 ))
  if (( $1 > 0 )); then (( steps[idx] == INTERVAL )) && (( idx++ )); else (( idx-- )); fi
  (( idx < 0 )) && idx=0
  (( idx >= n )) && idx=$(( n - 1 ))
  INTERVAL=${steps[idx]}
  deadline=$(( sample_time + INTERVAL * 1000000 ))
  refresh_soon
}

# Refreshes now, but never less than a second after the last sample, so rates are
# not computed over a sliver of time.
refresh_soon() {
  local t=$(( sample_time + 1000000 ))
  now_us
  (( deadline > REPLY )) && (( deadline > t )) && (( deadline <= sample_time + INTERVAL * 1000000 )) && return
  deadline=$(( t > REPLY ? t : REPLY ))
}

# Applies KEY to the view. Returns 1 when it changes nothing.
# 'd' toggles the details view (offered when the fitted dashboard hides something).
# Scroll keys move SCROLL within 0..MAXOFF, which awk reports for the current view;
# in the process view they move the selection instead.
apply_key() {
  local page=$(( rows > 12 ? rows - 8 : 4 )) out
  # A prompt takes every key while it is open
  if (( EDIT )); then
    case $KEY in
      enter) EDIT=0; PFILTER=$EDITBUF ;;
      esc) EDIT=0 ;;
      bs) [[ -n $EDITBUF ]] || return 1; EDITBUF=${EDITBUF%?} ;;
      ?) [[ $KEY == [[:print:]] ]] || return 1; EDITBUF+=$KEY ;;
      *) return 1 ;;
    esac
    PSEL=1; SCROLL=0
    return 0
  fi
  if [[ -n $CONFIRM ]]; then
    if [[ $KEY == y || $KEY == Y ]]; then
      if [[ ! $KILL_ID =~ ^[0-9]+$ ]]; then MSG="Not a valid connection id: $KILL_ID"
      elif out=$(madmin kill "$KILL_ID" 2>&1); then MSG="Killed $KILL_ID."
      else MSG="Kill $KILL_ID failed: ${out//$'\n'/ }"; fi
      refresh_soon
    fi
    CONFIRM=""
    return 0
  fi
  MSG=""
  case $KEY in
    q|Q) exit 0 ;;
    ' ') PAUSED=$(( ! PAUSED )); refresh_soon; return 0 ;;
    +|=) step_interval 1; return 0 ;;
    -|_) step_interval -1; return 0 ;;
    r|R) if [[ $VIEW == raw ]]; then VIEW=dashboard; else VIEW=raw; fi; SCROLL=0; return 0 ;;
    h|H) if [[ $VIEW == health ]]; then VIEW=dashboard; else VIEW=health; fi; SCROLL=0; return 0 ;;
    p|P) if [[ $VIEW == procs ]]; then VIEW=dashboard; else VIEW=procs; PSEL=1; fi; SCROLL=0; return 0 ;;
    t|T) if [[ $VIEW == top ]]; then VIEW=dashboard; else VIEW=top; PSEL=1; fi; SCROLL=0; return 0 ;;
    '?') if [[ $VIEW == help ]]; then VIEW=dashboard; else VIEW=help; fi; SCROLL=0; return 0 ;;
    esc) [[ $VIEW != dashboard ]] || (( DETAILS )) || return 1; VIEW=dashboard; DETAILS=0; SCROLL=0; return 0 ;;
  esac
  if [[ $VIEW == procs || $VIEW == top ]]; then
    # List views: a selection instead of a scroll offset; awk keeps it visible
    case $KEY in
      s|S) [[ $VIEW == procs ]] || return 1; PSLEEP=$(( ! PSLEEP )); PSEL=1; SCROLL=0 ;;
      o|O)
        if [[ $VIEW == procs ]]; then case $PSORT in time) PSORT=id ;; id) PSORT=user ;; user) PSORT=db ;; *) PSORT=time ;; esac
        else case $TSORT in time) TSORT=calls ;; calls) TSORT=avg ;; avg) TSORT=max ;; *) TSORT=time ;; esac; fi
        PSEL=1; SCROLL=0 ;;
      f|F) [[ $VIEW == procs ]] || return 1; EDIT=1; EDITBUF=$PFILTER ;;
      c|C) [[ $VIEW == procs ]] || return 1; state=$(grep -v $'^Q\t' <<< "$state"); prev_state=$(grep -v $'^Q\t' <<< "$prev_state"); PSEL=1; SCROLL=0 ;;
      k|K) [[ $VIEW == procs && $SELID =~ ^[0-9]+$ ]] || return 1; KILL_ID=$SELID; CONFIRM="Kill $SELID ($SELDESC)?" ;;
      down|j) (( PSEL < NPROC )) || return 1; (( PSEL += 1 )) ;;
      up)     (( PSEL > 1 )) || return 1; (( PSEL -= 1 )) ;;
      pgdn)   (( PSEL < NPROC )) || return 1; (( PSEL += page )) ;;
      pgup)   (( PSEL > 1 )) || return 1; (( PSEL = PSEL > page ? PSEL - page : 1 )) ;;
      home)   (( PSEL > 1 )) || return 1; PSEL=1 ;;
      end)    (( PSEL < NPROC )) || return 1; PSEL=$NPROC ;;
      *) return 1 ;;
    esac
    return 0
  fi
  case $KEY in
    d|D)
      [[ $VIEW == dashboard ]] || return 1
      if (( DETAILS )); then DETAILS=0; elif (( MORE )); then DETAILS=1; else return 1; fi
      SCROLL=0 ;;
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

trap 'exit 130' INT
trap 'exit 143' TERM

if (( ONCE )); then
  # One snapshot: two samples a second apart so the rates are real, printed in place.
  read_size
  [[ -t 1 ]] || { rows=${LINES:-50}; cols=${COLUMNS:-120}; }
  state=""; VIEW=dashboard; DETAILS=0; SCROLL=0; PAUSED=0
  PSORT=time PSLEEP=0 PFILTER="" PSEL=1 EDIT=0 EDITBUF="" CONFIRM="" MSG="" TSORT=time
  fetch; prev_state=$state; render; state=$next_state
  sleep 1
  fetch; prev_state=$state; render
  printf '%s\n' "$frame"
  exit 0
fi

if [[ ! -t 0 ]]; then
  echo "Standard input is not a terminal. Use --once for non-interactive output." >&2
  exit 1
fi

trap cleanup EXIT
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
PAUSED=0
PSORT=time PSLEEP=0 PFILTER="" PSEL=1 NPROC=0 SELID=- SELDESC=- TSORT=time
EDIT=0 EDITBUF="" CONFIRM="" KILL_ID="" MSG=""
read_size

# First refresh comes after 1 second so per-second rates appear quickly.
first_wait=1

while true; do
  if (( ! PAUSED )); then
    fetch
    prev_state=$state
    render
    state=$next_state
    draw
  fi

  # Wait for the next refresh in short slices so resizes redraw immediately.
  # Resizes and view changes re-render the same sample instead of querying the server again.
  now_us
  deadline=$(( REPLY + ${first_wait:-$INTERVAL} * 1000000 ))
  (( PAUSED )) && deadline=$(( REPLY + 3600 * 1000000 ))
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
