#!/bin/bash
# MySQL Monitor Script
# ---------------------
# Author: Hayden James
# Website: https://consult.haydenjames.io
# Blog: https://linuxblog.io
# ---------------------

TITLE="MySQL Monitor v2026.10.23.01 (Press 'q' to exit)"

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
# Written for POSIX awk: works with gawk, mawk and busybox awk.
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

function pct(x) { return (x == "") ? "-" : sprintf("%.1f%%", x) }
function pct2(x) { return (x == "") ? "-" : sprintf("%.2f%%", x) }

# Per-second change of a counter since the previous frame ("" when unknown).
function rate(name,    d) {
  if (!have_prev || !(name in cur) || !(name in prev)) return ""
  d = cur[name] - prev[name]
  return (d < 0) ? "" : d / elapsed
}

function delta(name) { return cur[name] - prev[name] }

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

function rule(title, width,    left, right, s, i) {
  title = " " title " "
  left = int((width - length(title)) / 2)
  right = width - length(title) - left
  s = ""
  for (i = 0; i < left; i++) s = s "-"
  s = s title
  for (i = 0; i < right; i++) s = s "-"
  return s
}

BEGIN {
  RED = "\033[0;31m"; RESET = "\033[0m"

  # Display order, and which metrics are point-in-time gauges (no per-second rate)
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

  split("innodb_buffer_pool_size innodb_page_size max_connections table_open_cache", v, " ")
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

section == "PREV" { prev[$1] = $2 + 0; next }

section == "CUR" {
  if ($0 ~ /^\|/) {
    n = split($0, f, "|")
    name = trim(f[2]); val = trim(f[3])
    if (name == "Variable_name") { tables++; next }
    if (tables == 1 && (name in wanted)) cur[name] = val + 0
    else if (tables == 2 && (name in wanted_var)) vars[name] = val + 0
  } else if ($0 !~ /^\+/ && $0 != "") {
    err = (err == "") ? $0 : err " " $0
  }
  next
}

section == "MEMINFO" { sub(/:$/, "", $1); mem[$1] = $2 * 1024; next }

section == "CPU" {
  cpu_total = 0
  for (i = 2; i <= 9 && i <= NF; i++) cpu_total += $i
  cpu_idle = $5 + $6
  next
}

section == "LOAD" { load = $1 " " $2 " " $3; next }

END {
  have_prev = ("T" in prev) && ("Uptime" in prev) && ("Uptime" in cur) && cur["Uptime"] >= prev["Uptime"]
  elapsed = have_prev ? (now - prev["T"]) / 1000000 : 0
  if (elapsed <= 0) have_prev = 0

  w1 = 15; w2 = 10; w3 = 6; w4 = 25

  if (!("Uptime" in cur)) {
    addHeader("MySQL Runtime Metrics")
    addLine("Unable to read MySQL status. Retrying every refresh...", RED)
    if (err != "") addLine(err, RED)
  } else {
    addHeader("MySQL Runtime Metrics")
    addRow("Variable", "Total", "Now/s", "Description", "")

    for (i = 1; i <= nm; i++) {
      name = metrics[i]
      if (!(name in cur)) continue

      if (name == "Uptime") {
        addSpanRow("Uptime (Wait 24h for accuracy)", prettyTime(cur[name]))
        continue
      }

      label = name
      if (name == "Questions" && cur["Uptime"] > 0)
        label = sprintf("Questions (%.2f avg QPS)", cur["Questions"] / cur["Uptime"])

      extra = (name in gauge) ? "" : formatRate(rate(name))
      color = (name == "Innodb_buffer_pool_pages_free" && cur[name] == 0) ? RED : ""
      addRow(label, formatNumber(cur[name]), extra, desc[name], color)
    }

    addHeader("MySQL Health Metrics")
    addRow("Metric", "Boot avg", "Now", "", "")

    page_size = ("innodb_page_size" in vars && vars["innodb_page_size"] > 0) ? vars["innodb_page_size"] : 16384

    if ("innodb_buffer_pool_size" in vars)
      addRow("InnoDB Buffer Pool Size", formatBytes(vars["innodb_buffer_pool_size"]), "",
             "Set by innodb_buffer_pool_size.", "")

    if ("Innodb_buffer_pool_pages_free" in cur) {
      free_val = formatBytes(cur["Innodb_buffer_pool_pages_free"] * page_size)
      if (cur["Innodb_buffer_pool_pages_total"] > 0)
        free_val = free_val sprintf(" (%.0f%%)", 100 * cur["Innodb_buffer_pool_pages_free"] / cur["Innodb_buffer_pool_pages_total"])
      addRow("InnoDB Buffer Pool Free", free_val, "", "Zero/low? = innodb_buffer_pool_size.",
             (cur["Innodb_buffer_pool_pages_free"] == 0) ? RED : "")
    }

    boot = ""; now_r = ""
    if (cur["Innodb_buffer_pool_read_requests"] > 0) {
      boot = 100 * (1 - cur["Innodb_buffer_pool_reads"] / cur["Innodb_buffer_pool_read_requests"])
      if (boot < 0) boot = 0
    }
    if (have_prev && delta("Innodb_buffer_pool_read_requests") > 0) {
      now_r = 100 * (1 - delta("Innodb_buffer_pool_reads") / delta("Innodb_buffer_pool_read_requests"))
      if (now_r < 0) now_r = 0
    }
    if (boot != "")
      addRow("InnoDB Buffer Pool Hit Ratio", pct2(boot), pct2(now_r), "High QPS? Aim for high hit ratio.", "")

    boot = ""; now_r = ""
    if (cur["Connections"] > 0) boot = 100 * (1 - cur["Threads_created"] / cur["Connections"])
    if (have_prev && delta("Connections") > 0) now_r = 100 * (1 - delta("Threads_created") / delta("Connections"))
    if (boot != "")
      addRow("Thread Cache Hit Ratio", pct(boot), pct(now_r), "Faster connection handling. > 90%.", "")

    boot = ""; now_r = ""
    total = cur["Table_open_cache_hits"] + cur["Table_open_cache_misses"]
    if (total > 0) boot = 100 * cur["Table_open_cache_hits"] / total
    if (have_prev) {
      total = delta("Table_open_cache_hits") + delta("Table_open_cache_misses")
      if (total > 0) now_r = 100 * delta("Table_open_cache_hits") / total
    }
    if (boot != "")
      addRow("Table Cache Hit Ratio", pct(boot), pct(now_r), "Faster table access speeds. > 90%.", "")

    boot = ""; now_r = ""
    if (cur["Created_tmp_tables"] > 0) boot = 100 * cur["Created_tmp_disk_tables"] / cur["Created_tmp_tables"]
    if (have_prev && delta("Created_tmp_tables") > 0) now_r = 100 * delta("Created_tmp_disk_tables") / delta("Created_tmp_tables")
    if (boot != "")
      addRow("Temp tables created on disk", pct(boot), pct(now_r), "Keep this low! Disk I/O is slow.", "")

    if (vars["max_connections"] > 0)
      addRow("Connection Usage (peak / now)", pct(100 * cur["Max_used_connections"] / vars["max_connections"]),
             pct(100 * cur["Threads_connected"] / vars["max_connections"]),
             sprintf("Of max_connections (%d). < 85%%.", vars["max_connections"]), "")
  }

  addHeader("System")
  if (mem["MemTotal"] > 0) {
    gb = 1073741824
    avail = ("MemAvailable" in mem) ? mem["MemAvailable"] : mem["MemFree"]
    avail_pct = 100 * avail / mem["MemTotal"]
    mem_line = sprintf("Memory: Total %.2f GB, Used %.2f GB, Free %.2f GB, Available %.2f GB",
                       mem["MemTotal"] / gb, (mem["MemTotal"] - avail) / gb, mem["MemFree"] / gb, avail / gb)
    if (avail_pct < 10) addLine(mem_line sprintf(" (Warning!: %.1f%%)", avail_pct), RED)
    else addLine(mem_line, "")
  }
  cpu_line = "CPU: "
  if (("cpu_total" in prev) && cpu_total > prev["cpu_total"])
    cpu_line = cpu_line sprintf("%.1f%%", 100 * (1 - (cpu_idle - prev["cpu_idle"]) / (cpu_total - prev["cpu_total"])))
  else
    cpu_line = cpu_line "-"
  if (load != "") cpu_line = cpu_line "   Load: " load
  addLine(cpu_line, "")

  width = w1 + w2 + w3 + w4 + 9
  for (i = 1; i <= nrows; i++) {
    if (rkind[i] == "hdr") {
      print rule(rname[i], width)
    } else if (rkind[i] == "line") {
      print rcolor[i] rname[i] (rcolor[i] != "" ? RESET : "")
    } else if (rkind[i] == "span") {
      printf "%-" w1 "s | %s\n", rname[i], rval[i]
    } else {
      line = sprintf("%-" w1 "s | %-" w2 "s | %-" w3 "s | %s", rname[i], rval[i], rextra[i], rdesc[i])
      print rcolor[i] line (rcolor[i] != "" ? RESET : "")
    }
  }
  print rule(title, width)

  print "@@STATE"
  printf "T %.0f\n", now
  if (cpu_total > 0) printf "cpu_total %.0f\ncpu_idle %.0f\n", cpu_total, cpu_idle
  for (name in cur) printf "%s %.0f\n", name, cur[name]
}
AWK

# Collects every input the renderer needs in one stream; the only external command is mysqladmin.
render_frame() {
  local now line
  now_us; now=$REPLY
  local raw
  raw=$(
    printf '@@TIME %s\n@@PREV\n%s\n@@CUR\n' "$now" "$state"
    mysqladmin extended-status variables 2>&1
    printf '@@MEMINFO\n'
    [[ -r /proc/meminfo ]] && printf '%s\n' "$(</proc/meminfo)"
    printf '@@CPU\n'
    [[ -r /proc/stat ]] && { read -r line < /proc/stat; printf '%s\n' "$line"; }
    printf '@@LOAD\n'
    [[ -r /proc/loadavg ]] && printf '%s\n' "$(</proc/loadavg)"
  )
  local out
  out=$(awk -v title="$TITLE" "$RENDER_AWK" <<< "$raw")
  frame=${out%%$'\n'@@STATE*}
  state=${out#*@@STATE$'\n'}
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

# Restore the terminal exactly once, whatever the exit path (q, Ctrl+C, TERM or error).
cleanup() {
  printf '\033[?7h\033[?25h'
  tput rmcup 2>/dev/null || true
  echo "Exiting MySQL Monitor. Goodbye!"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'resized=1' WINCH

tput smcup 2>/dev/null || true
# Hide the cursor, disable line wrapping and clear the screen once.
printf '\033[?25l\033[?7l\033[H\033[J'

state=""
resized=0
read_size

# First refresh comes after 1 second so per-second rates appear quickly.
first_wait=1

while true; do
  render_frame
  draw

  # Wait for the next refresh in short slices so resizes redraw immediately.
  now_us
  deadline=$(( REPLY + ${first_wait:-$INTERVAL} * 1000000 ))
  first_wait=""
  while true; do
    if (( resized )); then
      resized=0
      read_size
      draw
    fi
    now_us
    remaining=$(( deadline - REPLY ))
    (( remaining <= 0 )) && break
    (( remaining > 200000 )) && remaining=200000
    printf -v timeout '0.%06d' "$remaining"
    if read -t "$timeout" -n 1 -s -r key; then
      [[ $key == "q" || $key == "Q" ]] && exit 0
    fi
  done
done
