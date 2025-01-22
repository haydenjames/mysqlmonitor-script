#!/bin/bash
# MySQL Monitor Script

INTERVAL=10

TITLE="MySQL Monitor v2025.01.22 (Press 'q' to exit)"

# The extended-status variables
MYSQL_CMD='mysqladmin extended-status 2>/dev/null \
  | grep -E "Aborted_clients|Aborted_connects|Connections|Created_tmp_disk_tables|Created_tmp_files|Created_tmp_tables|Innodb_buffer_pool_pages_free|Innodb_buffer_pool_reads|Innodb_buffer_pool_read_requests|Innodb_buffer_pool_size|Innodb_buffer_pool_wait_free|Innodb_buffer_pool_write_requests|Innodb_data_reads|Innodb_data_writes|Innodb_log_waits|Innodb_log_writes|Key_reads|Key_read_requests|Key_writes|Key_write_requests|Max_used_connections|Open_files|Open_tables|Opened_tables|Questions|Select_full_join|Select_scan|Slow_queries|Sort_merge_passes|Sort_range|Sort_rows|Sort_scan|Table_locks_immediate|Table_locks_waited|Threads_cached|Threads_connected|Threads_created|Threads_running|Uptime" \
  | grep -v "Aborted_connects_preauth" \
  | grep -v "Max_used_connections_time" \
  | grep -v "Uptime_since_flush_status"'

# Test if MySQL command requiring credentials succeeds
if ! eval "$MYSQL_CMD" > /dev/null 2>&1; then
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
    echo "Credentials found in ~/.my.cnf, but the command still failed."
    echo "Please verify your credentials or server status."
    exit 1
  fi
fi

# Handle CTRL+C
trap "echo -e '\nExiting MySQL Monitor. Goodbye!'; exit" SIGINT

while true; do
  clear
  echo "MySQL Metrics"
  printf "%s\n" "--------------------"

  # Run the command and pipe into AWK
  eval "$MYSQL_CMD" | awk '
    # Converts seconds to a human-readable "x d y h z m" etc.
    function prettyTime(sec) {
      years   = int(sec / 31536000); sec %= 31536000
      months  = int(sec / 2592000);  sec %= 2592000
      days    = int(sec / 86400);    sec %= 86400
      hours   = int(sec / 3600);     sec %= 3600
      minutes = int(sec / 60);
      seconds = sec % 60;

      out=""
      if (years   > 0) out = out years   "y "
      if (months  > 0) out = out months  "m "
      if (days    > 0) out = out days    "d "
      if (hours   > 0) out = out hours   "h "
      if (minutes > 0) out = out minutes "m "
      if (seconds > 0) out = out seconds "s"
      return (out == "") ? "0s" : out
    }

    # Convert values in MB to either XX MB or XX GB.
    function shortSizeMB(mb) {
      if (mb >= 1024) {
        gb = mb / 1024
        return sprintf("%.0f GB", gb)
      } else {
        return sprintf("%.0f MB", mb)
      }
    }

    BEGIN {
      # Short descriptions for variables
      desc["Aborted_clients"]                  = "Failed client connections."
      desc["Aborted_connects"]                 = "Failed MySQL server connections."
      desc["Connections"]                      = "Total connection attempts."
      desc["Created_tmp_disk_tables"]          = "Temp tables created on disk."
      desc["Created_tmp_files"]                = "Temp files created by MySQL."
      desc["Created_tmp_tables"]               = "Temp tables created in memory."
      desc["Innodb_buffer_pool_pages_free"]    = "Free pages in InnoDB buffer pool."
      desc["Innodb_buffer_pool_reads"]         = "Logical reads from disk into buffer."
      desc["Innodb_buffer_pool_read_requests"] = "Logical read requests to buffer."
      desc["Innodb_buffer_pool_size"]          = "InnoDB buffer pool size (bytes)."
      desc["Innodb_buffer_pool_wait_free"]     = "Waits for free pages in buffer pool."
      desc["Innodb_buffer_pool_write_requests"]= "Writes requested to InnoDB buffer."
      desc["Innodb_data_reads"]                = "Data pages read from disk."
      desc["Innodb_data_writes"]               = "Data pages written to disk."
      desc["Innodb_log_waits"]                 = "Log waits for buffer flushes."
      desc["Innodb_log_writes"]                = "Log writes to InnoDB log file."
      desc["Key_reads"]                        = "Key blocks read from disk."
      desc["Key_read_requests"]                = "Requests to read key blocks."
      desc["Key_writes"]                       = "Key blocks written to disk."
      desc["Key_write_requests"]               = "Requests to write key blocks."
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
      desc["Table_locks_immediate"]            = "Locks acquired immediately."
      desc["Table_locks_waited"]               = "Locks that had to wait (contention)."
      desc["Threads_cached"]                   = "Threads in the thread cache."
      desc["Threads_connected"]                = "Currently open connections."
      desc["Threads_created"]                  = "Threads created for connections."
      desc["Threads_running"]                  = "Threads currently running queries."
      desc["Uptime"]                           = ""
    }

    {
      varName  = $2
      varValue = $4
      data[varName] = varValue
    }

    END {
      # Build a list of keys
      count = 0
      for (v in data) {
        count++
        keys[count] = v
      }
      asort(keys)  # Sort the array of keys

      # Prepare the values
      # InnoDB Buffer Pool
      ibp_size_mb = ""
      if ("Innodb_buffer_pool_size" in data) {
        ibp_size_mb = data["Innodb_buffer_pool_size"] / (1024 * 1024)
      }
      # Estimate free pages in MB, then we’ll do shortSizeMB on it
      ibp_free_mb = ""
      if ("Innodb_buffer_pool_pages_free" in data) {
        ibp_free_mb = data["Innodb_buffer_pool_pages_free"] * 16 / 1024
      }

      # Queries per second (QPS)
      qps = ""
      if (("Questions" in data) && ("Uptime" in data) && (data["Uptime"] > 0)) {
        qps = data["Questions"] / data["Uptime"]
      }

      # Temp table disk ratio
      tmp_disk_ratio = ""
      if (("Created_tmp_disk_tables" in data) && ("Created_tmp_tables" in data) && (data["Created_tmp_tables"] > 0)) {
        tmp_disk_ratio = 100 * data["Created_tmp_disk_tables"] / data["Created_tmp_tables"]
      }

      # Thread Cache Hit Ratio
      thread_cache_ratio = ""
      if (("Threads_created" in data) && ("Connections" in data) && (data["Connections"] > 0)) {
        thread_cache_ratio = 100 * (1 - (data["Threads_created"] / data["Connections"]))
      }

      # Table Cache Hit Ratio
      table_cache_ratio = ""
      if (("Opened_tables" in data) && ("Connections" in data) && (data["Connections"] > 0)) {
        table_cache_ratio = 100 * (1 - (data["Opened_tables"] / data["Connections"]))
      }

      # InnoDB Buffer Pool Hit Ratio, clamped to 0% if negative
      ibp_efficiency = ""
      if (("Innodb_buffer_pool_read_requests" in data) && ("Innodb_buffer_pool_reads" in data) && (data["Innodb_buffer_pool_read_requests"] > 0)) {
        temp_ratio = 100 * (1 - (data["Innodb_buffer_pool_reads"] / data["Innodb_buffer_pool_read_requests"]))
        if (temp_ratio < 0) {
          temp_ratio = 0
        }
        ibp_efficiency = temp_ratio
      }
      
# Calculate column widths dynamically based on content
col1_width = 0
col2_width = 0
col3_width = 0

for (v in data) {
  if (length(v) > col1_width) col1_width = length(v)  # Longest Metric (varName)
  if (length(data[v]) > col2_width) col2_width = length(data[v])  # Longest Value (val)
  if (length(desc[v]) > col3_width) col3_width = length(desc[v])  # Longest Description (explanation)
}

# Ensure minimum widths for readability
col1_width = (col1_width > 15 ? col1_width : 15)
col2_width = (col2_width > 10 ? col2_width : 10)
col3_width = (col3_width > 25 ? col3_width : 25)

# Print the data with adjusted widths
for (i=1; i<=count; i++) {
  varName = keys[i]
  explanation = (varName in desc) ? desc[varName] : "No description available"

if (varName == "Uptime") {
  val = prettyTime(data[varName])  # Format Uptime
  # Append the note "(Wait 24h for accuracy)" to the varName
  printf "%-" col1_width "s | %s %s\n", varName " (Wait 24h for accuracy)", val, explanation
  # Skip further processing for Uptime
  continue
}

  val = data[varName]

  # Highlight specific values if needed
  if (varName == "Innodb_buffer_pool_pages_free" && data[varName] == 0) {
    printf "\033[0;31m%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\033[0m\n", varName, val, explanation
  } else {
    printf "%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", varName, val, explanation
  }
}

# Additional Metrics section
print ""
print "Additional Metrics"
printf "%-20s\n", "--------------------"

if (ibp_free_mb != "") {
  printf "%-" col1_width "s | %-" col2_width "s\n", \
    "InnoDB Buffer Pool Free", shortSizeMB(ibp_free_mb)
}
if (qps != "") {
  printf "%-" col1_width "s | %.2f QPS\n", "Queries per Second", qps
}
if (tmp_disk_ratio != "") {
  printf "%-" col1_width "s | %.1f%%\n", "Temp Tables on Disk", tmp_disk_ratio
}
if (thread_cache_ratio != "") {
  printf "%-" col1_width "s | %.1f%%\n", "Thread Cache Hit Ratio", thread_cache_ratio
}
if (table_cache_ratio != "") {
  printf "%-" col1_width "s | %.1f%%\n", "Table Cache Hit Ratio", table_cache_ratio
}
if (ibp_efficiency != "") {
  printf "%-" col1_width "s | %.1f%%\n", "InnoDB Buffer Pool Hit Ratio", ibp_efficiency
            }
          }
        '
        
  # System Memory Section
  echo
  echo "System Memory (GB)"
  printf "%s\n" \
    "--------------------"

  mem_raw=$(free -b | awk '/Mem:/ {print $2, $3, $4, $7}')
  mem_array=($mem_raw)

  mem_total_bytes=${mem_array[0]}
  mem_used_bytes=${mem_array[1]}
  mem_free_bytes=${mem_array[2]}
  mem_avail_bytes=${mem_array[3]}

  mem_total_gb=$(echo "scale=2; $mem_total_bytes/1024/1024/1024" | bc -l)
  mem_used_gb=$(echo "scale=2; $mem_used_bytes/1024/1024/1024" | bc -l)
  mem_free_gb=$(echo "scale=2; $mem_free_bytes/1024/1024/1024" | bc -l)
  mem_avail_gb=$(echo "scale=2; $mem_avail_bytes/1024/1024/1024" | bc -l)

  avail_mem_percentage=$(( (100 * mem_avail_bytes) / mem_total_bytes ))

if [ "$avail_mem_percentage" -lt 10 ]; then
  printf "Total: %s, Used: %s, Free: %s, Available: %s \033[0;31m(Warning!: ${avail_mem_percentage}%%)\033[0m\n" \
    "$mem_total_gb" "$mem_used_gb" "$mem_free_gb" "$mem_avail_gb"
else
  printf "Total: %s, Used: %s, Free: %s, Available: %s\n" \
    "$mem_total_gb" "$mem_used_gb" "$mem_free_gb" "$mem_avail_gb"
fi

  echo
  echo "$TITLE"

  read -t "$INTERVAL" -n 1 -r key
  if [[ $key == "q" || $key == "Q" ]]; then
    echo -e "\nQuitting MySQL Monitor. Goodbye!"
    break
  fi
done
