#!/bin/bash
# MySQL Monitor Script
# ---------------------
# Author: Hayden James
# Website: https://consult.haydenjames.io
# Blog: https://linuxblog.io
# ---------------------

TITLE="MySQL Monitor v2025.01.27.5 (Press 'q' to exit)"

# Define minimum terminal size requirements
MIN_COLS=90   # Minimum number of columns
MIN_ROWS=55   # Minimum number of rows

# Check for required tools
for tool in mysqladmin awk; do
  if ! command -v "$tool" &> /dev/null; then
    echo "Error: $tool is not installed. Please install it and try again."
    exit 1
  fi
done

# Default refresh interval in seconds
INTERVAL=10

# Check if the user provided an interval
if [[ $# -ge 1 ]]; then
  if [[ $1 =~ ^[0-9]+$ ]]; then
    INTERVAL=$1
  else
    echo "Invalid interval specified. Using default INTERVAL=$INTERVAL seconds."
  fi
fi

# Function to retrieve MySQL extended status
get_mysql_status() {
  mysqladmin extended-status 2>/dev/null \
    | grep -E "Aborted_clients|Aborted_connects|Connections|Created_tmp_disk_tables|Created_tmp_files|Created_tmp_tables|Innodb_buffer_pool_pages_free|Innodb_buffer_pool_reads|Innodb_buffer_pool_read_requests|Innodb_buffer_pool_size|Innodb_buffer_pool_wait_free|Innodb_buffer_pool_write_requests|Innodb_data_reads|Innodb_data_writes|Innodb_log_waits|Innodb_log_writes|Key_reads|Key_writes|Max_used_connections|Open_files|Open_tables|Opened_tables|Questions|Select_full_join|Select_scan|Slow_queries|Sort_merge_passes|Sort_range|Sort_rows|Sort_scan|Table_open_cache_hits|Table_open_cache_misses|Table_locks_immediate|Table_locks_waited|Threads_cached|Threads_connected|Threads_created|Threads_running|Uptime" \
    | grep -v "Aborted_connects_preauth" \
    | grep -v "Max_used_connections_time" \
    | grep -v "Uptime_since_flush_status"
}

# Test if MySQL command requiring credentials succeeds
if ! output=$(get_mysql_status 2>&1); then
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
    # Check file permissions
    file_perm=$(stat -c "%a" ~/.my.cnf)
    if [ "$file_perm" -ne 600 ]; then
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

# Handle CTRL+C and restore cursor on exit
trap "echo -e '\nExiting MySQL Monitor. Goodbye!'; printf '\033[?25h'; exit" SIGINT

# Hide the cursor to reduce flicker
printf '\033[?25l'

# Clear the screen once before starting the loop
printf "\033[H\033[J"

while true; do
  # ====== Added Code Start: Check Terminal Size ======
  # Retrieve current terminal size
  read rows cols <<< $(stty size)
  
  # Check if terminal size is below minimum requirements
  if [[ $rows -lt $MIN_ROWS || $cols -lt $MIN_COLS ]]; then
    # Clear the screen
    printf "\033[H\033[J"
    
    # Define warning message
    WARNING_MSG="❗ Terminal size too small. Please resize the window to at least ${MIN_COLS} columns and ${MIN_ROWS} rows. ❗"
    
    # Calculate the position to center the message
    msg_length=${#WARNING_MSG}
    msg_row=$((rows / 2))
    msg_col=$(((cols - msg_length) / 2))
    
    # Ensure message does not go negative
    if [[ $msg_col -lt 0 ]]; then
      msg_col=0
    fi
    
    # Move cursor to the calculated position and print the message
    printf "\033[${msg_row};${msg_col}H\033[1;31m%s\033[0m\n" "$WARNING_MSG"  # Bold red text
    
    # Skip the rest of the loop iteration
    continue
  fi
  # ====== Added Code End: Check Terminal Size ======

  # Initialize an empty variable to hold all output
  output=""

  # Add MySQL Runtime Metrics header
  output+=$'------------------------------- MySQL Runtime Metrics\n'

  # Capture MySQL status and append to output
  mysql_data=$(get_mysql_status | awk '
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

    # Converts large numbers into user-friendly formats (K, M, B, T)
    function formatNumber(num) {
      if (num >= 1e12) {
        return sprintf("%.2fT", num / 1e12)  # Trillions
      } else if (num >= 1e9) {
        return sprintf("%.2fB", num / 1e9)   # Billions
      } else if (num >= 1e6) {
        return sprintf("%.2fM", num / 1e6)   # Millions
      } else if (num >= 1e3) {
        return sprintf("%.2fK", num / 1e3)   # Thousands
      } else {
        return num  # Small numbers stay as is
      }
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
      desc["Innodb_buffer_pool_reads"]         = "Logical reads from disk."
      desc["Innodb_buffer_pool_read_requests"] = "Logical read requests to buffer."
      desc["Innodb_buffer_pool_size"]          = "InnoDB buffer pool size (bytes)."
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

      # Additional Metrics descriptions
      # Moved "Queries per Second"
      # desc["Queries per Second"]               = "Should match traffic/app changes."
      desc["InnoDB Buffer Pool Free"]          = "Zero/low? = innodb_buffer_pool_size."
      desc["InnoDB Buffer Pool Hit Ratio"]     = "High QPS? Aim for high hit ratio."
      desc["Thread Cache Hit Ratio"]           = "Faster connection handling. > 90%."
      desc["Table Cache Hit Ratio"]            = "Faster table access speeds. > 90%."
      desc["Temp tables created on disk"]      = "Keep this low! Disk I/O is slow."

      # Define additional metrics labels
      # Removed "Queries per Second" from additional_labels
      # additional_labels[1] = "Queries per Second"
      additional_labels[1] = "InnoDB Buffer Pool Free"
      additional_labels[2] = "InnoDB Buffer Pool Hit Ratio"
      additional_labels[3] = "Thread Cache Hit Ratio"
      additional_labels[4] = "Table Cache Hit Ratio"
      additional_labels[5] = "Temp tables created on disk"
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
      # Estimate free pages in MB
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

      # Correct Table Cache Hit Ratio Calculation
      table_cache_ratio = ""
      if (("Table_open_cache_hits" in data) && ("Table_open_cache_misses" in data) && (data["Table_open_cache_hits"] + data["Table_open_cache_misses"] > 0)) {
        table_cache_ratio = 100 * (data["Table_open_cache_hits"] / (data["Table_open_cache_hits"] + data["Table_open_cache_misses"]))
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

      # Include additional metrics labels in column width calculation
      for (i in additional_labels) {
        label_length = length(additional_labels[i])
        if (label_length > col1_width) {
          col1_width = label_length
        }
      }

      # Ensure minimum widths for readability
      col1_width = (col1_width > 15 ? col1_width : 15)
      col2_width = (col2_width > 10 ? col2_width : 10)
      col3_width = (col3_width > 25 ? col3_width : 25)

      # Initialize output within AWK
      output = ""

      # Print the data with adjusted widths
      for (i=1; i<=count; i++) {
        varName = keys[i]
        explanation = (varName in desc) ? desc[varName] : "No description available"

        if (varName == "Uptime") {
          val = prettyTime(data[varName])  # Format Uptime
          # Append the note "(Wait 24h for accuracy)" to the varName
          output = output sprintf("%-" col1_width "s | %s %s\n", varName " (Wait 24h for accuracy)", val, explanation)
          # Skip further processing for Uptime
          continue
        }

        val = formatNumber(data[varName])

        # New: Append QPS to "Questions"
        if (varName == "Questions" && qps != "") {
          qps_formatted = sprintf("(%.2f QPS)", qps)
          varName = varName " " qps_formatted
        }

        # Highlight specific values if needed
        if (varName == "Innodb_buffer_pool_pages_free" && data[varName] == 0) {
          output = output sprintf("\033[0;31m%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\033[0m\n", varName, val, explanation)
        } else {
          output = output sprintf("%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", varName, val, explanation)
        }
      }

      # Additional Metrics section
      output = output sprintf("\n------------------------------- MySQL Health Metrics\n")

      # Moved Queries per Second
      # Removed the following block to eliminate the separate "Queries per Second" line
      # if (qps != "") {
      #   output = output sprintf("%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", \
      #     "Queries per Second", sprintf("%.2f QPS", qps), desc["Queries per Second"])
      # }

      if (ibp_free_mb != "") {
        output = output sprintf("%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", \
          "InnoDB Buffer Pool Free", shortSizeMB(ibp_free_mb), desc["InnoDB Buffer Pool Free"])
      }

      if (ibp_efficiency != "") {
        output = output sprintf("%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", \
          "InnoDB Buffer Pool Hit Ratio", sprintf("%.1f%%", ibp_efficiency), desc["InnoDB Buffer Pool Hit Ratio"])
      }

      if (thread_cache_ratio != "") {
        output = output sprintf("%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", \
          "Thread Cache Hit Ratio", sprintf("%.1f%%", thread_cache_ratio), desc["Thread Cache Hit Ratio"])
      }

      if (table_cache_ratio != "") {
        output = output sprintf("%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", \
          "Table Cache Hit Ratio", sprintf("%.1f%%", table_cache_ratio), desc["Table Cache Hit Ratio"])
      }

      if (tmp_disk_ratio != "") {
        output = output sprintf("%-" col1_width "s | %-" col2_width "s | %-" col3_width "s\n", \
          "Temp tables created on disk", sprintf("%.1f%%", tmp_disk_ratio), desc["Temp tables created on disk"])
      }

      print output
    }
  ')

  # Append newline
  output+="${mysql_data}"$'\n'

  # System Memory Section
  mem_raw=$(free -b | awk '/Mem:/ {print $2, $3, $4, $7}')
  read -r -a mem_array <<< "$mem_raw"

  mem_total_bytes=${mem_array[0]}
  mem_used_bytes=${mem_array[1]}
  mem_free_bytes=${mem_array[2]}
  mem_avail_bytes=${mem_array[3]}

  # Convert bytes to gigabytes with two decimal places
  mem_total_gb=$(awk "BEGIN {printf \"%.2f\", $mem_total_bytes / 1024 / 1024 / 1024}")
  mem_used_gb=$(awk "BEGIN {printf \"%.2f\", $mem_used_bytes / 1024 / 1024 / 1024}")
  mem_free_gb=$(awk "BEGIN {printf \"%.2f\", $mem_free_bytes / 1024 / 1024 / 1024}")
  mem_avail_gb=$(awk "BEGIN {printf \"%.2f\", $mem_avail_bytes / 1024 / 1024 / 1024}")

  # Calculate available memory percentage with floating-point precision
  avail_mem_percentage=$(awk "BEGIN {printf \"%.2f\", 100 * $mem_avail_bytes / $mem_total_bytes}")

  # Determine if available memory is below 10%
  is_low_mem=$(awk "BEGIN {print ($avail_mem_percentage < 10)}")

  if (( is_low_mem )); then
    mem_info="Total Memory: ${mem_total_gb} GB, Used: ${mem_used_gb} GB, Free: ${mem_free_gb} GB, Available: ${mem_avail_gb} GB \033[0;31m(Warning!: ${avail_mem_percentage}%%)\033[0m"
  else
    mem_info="Total Memory: ${mem_total_gb} GB, Used: ${mem_used_gb} GB, Free: ${mem_free_gb} GB, Available: ${mem_avail_gb} GB"
  fi
  # Append mem_info with an empty line before it
  output+=$'\n'"${mem_info}"$'\n\n'

  # Add title followed by a newline
  output+="${TITLE}"$'\n'

  # Move cursor to top-left and print all output at once
  printf "\033[H%s" "$output"

  # Read user input with timeout
  read -t "$INTERVAL" -n 1 -r key
  if [[ $key == "q" || $key == "Q" ]]; then
    echo -e "\nQuitting MySQL Monitor. Goodbye!"
    break
  fi
done

# Restore the cursor before exiting (in case loop is exited without SIGINT)
printf '\033[?25h'
