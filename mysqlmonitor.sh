#!/bin/bash
# MySQL Monitor Script v2025.01.21

INTERVAL=10

TITLE="MySQL Monitor (q = exit)"

# The extended-status variables
MYSQL_CMD='mysqladmin extended-status 2>/dev/null \
  | grep -E "Aborted_clients|Aborted_connects|Connections|Created_tmp_disk_tables|Created_tmp_files|Created_tmp_tables|Innodb_buffer_pool_pages_free|Innodb_buffer_pool_reads|Innodb_buffer_pool_read_requests|Innodb_buffer_pool_size|Innodb_buffer_pool_wait_free|Innodb_buffer_pool_write_requests|Innodb_data_reads|Innodb_data_writes|Innodb_log_waits|Innodb_log_writes|Key_reads|Key_read_requests|Key_writes|Key_write_requests|Max_used_connections|Open_files|Open_tables|Opened_tables|Questions|Select_full_join|Select_scan|Slow_queries|Sort_merge_passes|Sort_range|Sort_rows|Sort_scan|Table_locks_immediate|Table_locks_waited|Threads_cached|Threads_connected|Threads_created|Threads_running|Uptime" \
  | grep -v "Aborted_connects_preauth" \
  | grep -v "Max_used_connections_time" \
  | grep -v "Uptime_since_flush_status"'

# Handle CTRL+C
trap "echo -e '\nExiting MySQL Monitor. Goodbye!'; exit" SIGINT

while true; do
  clear
  echo "MySQL Metrics"
  printf "%-40s | %-20s | %s\n" \
    "----------------------------------------" "--------------------" "-------------------------------"

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
      desc["Aborted_clients"]                  = "Client connections ended unexpectedly"
      desc["Aborted_connects"]                 = "Failed MySQL server connections"
      desc["Connections"]                      = "Total connection attempts"
      desc["Created_tmp_disk_tables"]          = "Temp tables created on disk"
      desc["Created_tmp_files"]                = "Temp files created by MySQL"
      desc["Created_tmp_tables"]               = "Temp tables created in memory"
      desc["Innodb_buffer_pool_pages_free"]    = "Free pages in InnoDB buffer pool"
      desc["Innodb_buffer_pool_reads"]         = "Logical reads from disk into buffer"
      desc["Innodb_buffer_pool_read_requests"] = "Total logical read requests to buffer"
      desc["Innodb_buffer_pool_size"]          = "InnoDB buffer pool size (bytes)"
      desc["Innodb_buffer_pool_wait_free"]     = "Waits for free pages in buffer pool"
      desc["Innodb_buffer_pool_write_requests"]= "Writes requested to InnoDB buffer"
      desc["Innodb_data_reads"]                = "Data pages read from disk"
      desc["Innodb_data_writes"]               = "Data pages written to disk"
      desc["Innodb_log_waits"]                 = "Log waits for buffer flushes"
      desc["Innodb_log_writes"]                = "Log writes to InnoDB log file"
      desc["Key_reads"]                        = "Key blocks physically read from disk"
      desc["Key_read_requests"]                = "Requests to read key blocks"
      desc["Key_writes"]                       = "Key blocks physically written to disk"
      desc["Key_write_requests"]               = "Requests to write key blocks"
      desc["Max_used_connections"]             = "Highest concurrent connections so far"
      desc["Open_files"]                       = "Files currently open by MySQL"
      desc["Open_tables"]                      = "Tables currently open"
      desc["Opened_tables"]                    = "Total tables opened since start"
      desc["Questions"]                        = "Statements sent to server"
      desc["Select_full_join"]                 = "Joins without usable indexes"
      desc["Select_scan"]                      = "Full table scans in SELECT queries"
      desc["Slow_queries"]                     = "Queries exceeding long_query_time"
      desc["Sort_merge_passes"]                = "Merge passes performed for sorting"
      desc["Sort_range"]                       = "Range-based sort operations"
      desc["Sort_rows"]                        = "Rows sorted by MySQL"
      desc["Sort_scan"]                        = "Table-scan-based sort operations"
      desc["Table_locks_immediate"]            = "Locks acquired immediately"
      desc["Table_locks_waited"]               = "Locks that had to wait (contention)"
      desc["Threads_cached"]                   = "Threads in the thread cache"
      desc["Threads_connected"]                = "Currently open connections"
      desc["Threads_created"]                  = "Threads created for connections"
      desc["Threads_running"]                  = "Threads currently running queries"
      desc["Uptime"]                           = "Ensure 24h+ uptime for accurate data!!"
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

      # Print the alphabetical list of raw stats
      for (i=1; i<=count; i++) {
        varName = keys[i]
        explanation = (varName in desc) ? desc[varName] : "No description available"
        val = data[varName]

        # Pretty-print Uptime
        if (varName == "Uptime") {
          val = prettyTime(val)
        }

        # Highlight zero free pages if needed
        if (varName == "Innodb_buffer_pool_pages_free" && data[varName] == 0) {
          printf "\033[0;31m%-40s | %-20s | %s\033[0m\n", varName, val, explanation
        } else {
          printf "%-40s | %-20s | %s\n", varName, val, explanation
        }
      }

      print ""
      print "Additional Metrics"
      print "----------------------------------------"
      if (ibp_size_mb != "") {
        printf "%-40s : %s\n", \
          "InnoDB Buffer Pool Size", shortSizeMB(ibp_size_mb)
      }
      if (ibp_free_mb != "") {
        printf "%-40s : %s\n", \
          "InnoDB Buffer Pool Free", shortSizeMB(ibp_free_mb)
      }
      if (qps != "") {
        # Keep a small decimal for QPS
        printf "%-40s : %.2f QPS\n", "Queries per Second", qps
      }
      if (tmp_disk_ratio != "") {
        printf "%-40s : %.1f%%\n", "Temp Tables on Disk", tmp_disk_ratio
      }
      if (thread_cache_ratio != "") {
        printf "%-40s : %.1f%%\n", "Thread Cache Hit Ratio", thread_cache_ratio
      }
      if (table_cache_ratio != "") {
        printf "%-40s : %.1f%%\n", "Table Cache Hit Ratio", table_cache_ratio
      }
      if (ibp_efficiency != "") {
        printf "%-40s : %.1f%%\n", "InnoDB Buffer Pool Hit Ratio", ibp_efficiency
      }
    }
  '

  # System Memory Section
  echo
  echo "System Memory (GB)"
  printf "%-40s | %-20s\n" "----------------------------------------" "--------------------"

  mem_raw=$(free -b | awk '/Mem:/ {print $2, $3, $4, $7}')
  mem_array=($mem_raw)

  mem_total_bytes=${mem_array[0]}
  mem_used_bytes=${mem_array[1]}
  mem_free_bytes=${mem_array[2]}
  mem_avail_bytes=${mem_array[3]}

  mem_total_gb=$(bc -l <<< "scale=2; $mem_total_bytes/1024/1024/1024")
  mem_used_gb=$(bc -l <<< "scale=2; $mem_used_bytes/1024/1024/1024")
  mem_free_gb=$(bc -l <<< "scale=2; $mem_free_bytes/1024/1024/1024")
  mem_avail_gb=$(bc -l <<< "scale=2; $mem_avail_bytes/1024/1024/1024")

  avail_mem_percentage=$(( (100 * mem_avail_bytes) / mem_total_bytes ))

  printf "%-40s | %s\n" "Total Memory"  "$mem_total_gb"
  printf "%-40s | %s\n" "Used Memory"   "$mem_used_gb"
  printf "%-40s | %s\n" "Free Memory"   "$mem_free_gb"

  if [ "$avail_mem_percentage" -lt 10 ]; then
    printf "\033[0;31m%-40s | %s (Critical: ${avail_mem_percentage}%%)\033[0m\n" \
      "Available Memory" "$mem_avail_gb"
  else
    printf "%-40s | %s\n" "Available Memory" "$mem_avail_gb"
  fi

  echo
  echo "$TITLE"

  read -t "$INTERVAL" -n 1 -r key
  if [[ $key == "q" || $key == "Q" ]]; then
    echo -e "\nQuitting MySQL Monitor. Goodbye!"
    break
  fi
done
