## MySQL Monitor Script
![MySQL Monitor Script Output](https://static.linuxblog.io/wp-content/uploads/2025/01/mysqlmonitor-script-3.png)

This is a lightweight bash script designed to provide sysadmins and DBAs with a quick overview of MySQL metrics. It displays critical metrics like InnoDB buffer usage, query performance, and system memory, along with brief explanations of each variable.

## How to Install and Use
Cut and paste each step.

### Step 1: Download the script
```bash
curl -O https://raw.githubusercontent.com/haydenjames/mysqlmonitor-script/main/mysqlmonitor.sh
```

### Step 2: Make the script executable
```bash
chmod +x mysqlmonitor.sh
```

### Step 3: Run the script
```bash
./mysqlmonitor.sh
```

Done! 

---------------------------------------------------

or...
### Single command install and run
Simply cut and paste. This command will download and run mysqlmonitor.sh immediately.  
```bash
curl -O https://raw.githubusercontent.com/haydenjames/mysqlmonitor-script/main/mysqlmonitor.sh && \
chmod +x mysqlmonitor.sh && \
./mysqlmonitor.sh
```

## Complementary Guide 
Linuxblog.io: [MySQL Monitor: A Simple MySQL Monitoring Script](https://linuxblog.io/mysql-monitor-script/) - This blog post provides detailed guidance on the variables used in the script, along with links to common MySQL tuning pitfalls and tips to help you optimize your database performance.

## What you see
A dashboard grouped into panels: throughput, connections, InnoDB buffer pool, temp tables & sorts, tables & locks, and system. Rates are per second since the last refresh, with sparklines of recent history, bars against configured limits (`max_connections`, `table_open_cache`) and ✓ / ⚠ / ✗ marks. An alerts box explains what needs attention and which setting to look at.

The layout adapts to the terminal and shows as much as fits: up to three columns, detail lines with every counter's rate and total since boot when there are enough rows, a description of each metric when there is enough width, and a compact summary that fits 80×24. Panels are packed into columns by height, and any rows left over show the active queries, longest-running first (idle connections and background threads are hidden).

| Key | Action |
| --- | --- |
| `q` | Quit |
| `?` | Help: keys, marks and what the numbers mean |
| `h` | Health checks: each ratio and rate against its target, with the setting to change and a suggested value when one fails |
| `r` | Toggle the raw counters table (the classic view) |
| `d` | Details: every counter and its description, in as many columns as fit the width. Offered when the fitted dashboard had to leave something out; `d` or `Esc` returns |
| `↓` `↑` / `j` `k`, `PgDn` `PgUp`, `Home` `End` | Scroll, whenever a view is taller than the window. The header and alerts stay in place |

`./mysqlmonitor.sh --help` lists the options and keys; `-i N` or a bare number sets the refresh interval. Set `NO_COLOR=1` to disable colors. Non-UTF-8 terminals get an ASCII version automatically.

## Requirements
`bash`, `mysqladmin` and any POSIX `awk` (gawk, mawk or busybox awk). CPU, load and memory are read from `/proc`.

To see other users' queries in the active queries panel, the MySQL user needs the `PROCESS` privilege (root has it). Without it, only that user's own queries are listed.

## Terminal size
The screen is redrawn in place, so it no longer scrolls or flickers. If the window is too small to fit everything, the script tells you the size it needs and redraws as soon as you resize.

## Common Troubleshooting
Here are some common issues and how to resolve them:

### 1. Missing MySQL Credentials
If the script fails to connect to your MySQL server due to missing credentials, you may need to create a `~/.my.cnf` file for automatic authentication.

#### Steps to Create `.my.cnf`:
1. Create the file:
    ```bash
    nano ~/.my.cnf
    ```

2. Add the following structure to the file:
    ```makefile
    [client]
    user=your_mysql_username
    password=your_mysql_password
    ```

3. Secure the file permissions:
    ```bash
    chmod 600 ~/.my.cnf
    ```

4. Rerun the script.

---

### 2. Running the Script with `sudo`
If you encounter permission issues as a non-root user, try running the script with `sudo`:
```bash
sudo ./mysqlmonitor.sh
```

---

### 3. Verifying MySQL Status
If the script fails to connect even with credentials:
- Ensure the MySQL server is running:
    ```bash
    sudo systemctl status mysql
    ```
    or
    ```bash
    sudo systemctl status mariadb
    ```
- Verify that the credentials in `~/.my.cnf` are correct.

---------------------------------------------------
Thank you for using MySQL Monitor, we hope it helps simplify your database monitoring and tuning tasks!
