## MySQL Monitor Script

This is a lightweight bash script designed to provide sysadmins and DBAs with a quick overview of MySQL metrics. It displays critical metrics like InnoDB buffer usage, query performance, and system memory, along with brief explanations of each variable.

## How to Install and Use

```bash
# Step 1: Download the script
curl -O https://raw.githubusercontent.com/haydenjames/mysql-monitor-script/main/mysql-monitor.sh

# Step 2: Make the script executable
chmod +x mysql-monitor.sh

# Step 3: Run the script
./mysql-monitor.sh
