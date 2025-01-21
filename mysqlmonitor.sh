#!/bin/bash
# MySQL Monitor Script v2025.01.21

# Set the refresh interval
INTERVAL=5

TITLE="MySQL Monitor (q = exit)"

# MySQL extended-status command
MYSQL_CMD='mysqladmin extended-status 2>/dev/null \
  | grep -E "Innodb_buffer_pool_size|Aborted_clients|Aborted_connects|Created_tmp_disk_tables|Created_tmp_files|Created_tmp_tables|Innodb_buffer_pool_reads|Innodb_buffer_pool_wait_free|Innodb_buffer_pool_write_requests|Innodb_buffer_pool_pages_free|Innodb_data_fsyncs|Innodb_data_reads|Innodb_data_writes|Innodb_log_waits|Innodb_log_writes|Innodb_os_log_fsyncs|Key_reads|Key_read_requests|Key_writes|Key_write_requests|Max_used_connections|Open_files|Open_tables|Opened_tables|Questions|Select_full_join|Select_scan|Slow_queries|Sort_merge_passes|Sort_range|Sort_rows|Sort_scan|Table_locks_immediate|Table_locks_waited|Threads_cached|Threads_connected|Threads_created|Threads_running|Uptime" \
  | grep -v "Aborted_connects_preauth" \
  | grep -v "Max_used_connections_time" \
  | grep -v "Uptime_since_flush_status"'

# Trap CTRL+C to gracefully exit
trap "echo -e '\nExiting MySQL Monitor. Goodbye!'; exit" SIGINT

while true; do
  clear

  echo "MySQL Metrics"
  printf "%-40s | %-20s | %s\n" \
    "----------------------------------------" "--------------------" "-------------------------------"

  # Execute the MySQL command and format the output, including short explanations
  eval "$MYSQL_CMD" | awk '
    function prettyTime(u) {
      # Convert total seconds into years, months, days, hours, minutes, seconds
      years   = int(u/31536000);  u = u % 31536000
      months  = int(u/2592000);   u = u % 2592000
      days    = int(u/86400);     u = u % 86400
      hours   = int(u/3600);      u = u % 3600
      minutes = int(u/60)
      seconds = u % 60

      # Build a string showing only non-zero parts
      result = ""
      if (years   > 0) result = result years   "y "
      if (months  > 0) result = result months  "m "
      if (days    > 0) result = result days    "d "
      if (hours   > 0) result = result hours   "h "
      if (minutes > 0) result = result minutes "m "
      if (seconds > 0) result = result seconds "s"
      if (result == "") result = "0s"
      return result
    }

    BEGIN {
      # Short descriptions for each status variable
      desc["Innodb_buffer_pool_size"]          = "Size of InnoDB buffer pool"
      desc["Aborted_clients"]                  = "Clients ended unexpectedly (timeouts, etc.)"
      desc["Aborted_connects"]                 = "Failed connections (bad creds, etc.)"
      desc["Created_tmp_disk_tables"]          = "Temporary tables created on disk"
      desc["Created_tmp_files"]                = "Temporary files created by MySQL"
      desc["Created_tmp_tables"]               = "Temporary tables created in memory"
      desc["Innodb_buffer_pool_reads"]         = "Logical reads from disk into buffer"
      desc["Innodb_buffer_pool_wait_free"]     = "Waits for free pages in buffer pool"
      desc["Innodb_buffer_pool_write_requests"] = "Writes requested to InnoDB buffer"
      desc["Innodb_buffer_pool_pages_free"]    = "Free pages in InnoDB buffer pool"
      desc["Innodb_data_fsyncs"]               = "fsync() calls (disk) for InnoDB data files"
      desc["Innodb_data_reads"]                = "Data pages read from disk"
      desc["Innodb_data_writes"]               = "Data pages written to disk"
      desc["Innodb_log_waits"]                 = "Log waits for buffer flushes"
      desc["Innodb_log_writes"]                = "Log writes to InnoDB log file"
      desc["Innodb_os_log_fsyncs"]             = "fsync() calls (disk) for InnoDB log file"
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
      desc["Uptime"]                           = "MySQL server uptime (seconds)"
    }

    {
      varName=$2
      varValue=$4

      if (varName == "Uptime") {
        # Convert seconds to more readable format
        pretty = prettyTime(varValue)
        varValueFormatted = pretty
      } else {
        varValueFormatted = varValue
      }

      # If this variable has a description in our array, use it
      if (varName in desc) {
        explanation = desc[varName]
      } else {
        explanation = "No description available"
      }

      # Highlight Innodb_buffer_pool_pages_free if it hits zero
      if (varName == "Innodb_buffer_pool_pages_free" && varValue == 0) {
        printf "\033[0;31m%-40s | %-20s | %s\033[0m\n", varName, varValueFormatted, explanation
      } else {
        printf "%-40s | %-20s | %s\n", varName, varValueFormatted, explanation
      }
    }
  '

  echo
  echo "System Memory (GB)"
  printf "%-40s | %-20s\n" "----------------------------------------" "--------------------"

  # Fetch system memory info in bytes (total, used, free, available)
  mem_raw=$(free -b | awk '/Mem:/ {print $2, $3, $4, $7}')
  mem_array=($mem_raw)

  mem_total_bytes=${mem_array[0]}
  mem_used_bytes=${mem_array[1]}
  mem_free_bytes=${mem_array[2]}
  mem_avail_bytes=${mem_array[3]}

  # Convert bytes to GB
  mem_total_gb=$(bc -l <<< "scale=2; $mem_total_bytes/1024/1024/1024")
  mem_used_gb=$(bc -l <<< "scale=2; $mem_used_bytes/1024/1024/1024")
  mem_free_gb=$(bc -l <<< "scale=2; $mem_free_bytes/1024/1024/1024")
  mem_avail_gb=$(bc -l <<< "scale=2; $mem_avail_bytes/1024/1024/1024")

  # Determine percent of total memory that is available
  avail_mem_percentage=$(( (100 * mem_avail_bytes) / mem_total_bytes ))

  printf "%-40s | %s\n" "Total Memory"  "$mem_total_gb"
  printf "%-40s | %s\n" "Used Memory"   "$mem_used_gb"
  printf "%-40s | %s\n" "Free Memory"   "$mem_free_gb"

  # Highlight Available Memory in red if below 10%
  if [ "$avail_mem_percentage" -lt 10 ]; then
    printf "\033[0;31m%-40s | %s (Critical: ${avail_mem_percentage}%%)\033[0m\n" "Available Memory" "$mem_avail_gb"
  else
    printf "%-40s | %s\n" "Available Memory" "$mem_avail_gb"
  fi

  echo
  echo "$TITLE"

  # Wait for keypress or interval. "q" = exit.
  read -t "$INTERVAL" -n 1 -r key
  if [[ $key == "q" || $key == "Q" ]]; then
    echo -e "\nQuitting MySQL Monitor. Goodbye!"
    break
  fi
done
