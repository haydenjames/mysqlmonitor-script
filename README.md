## MySQL Monitor Script
![MySQL Monitor Script Output](https://static.linuxblog.io/wp-content/uploads/2025/01/mysqlmonitor-script-1.png)

This is a lightweight bash script designed to provide sysadmins and DBAs with a quick overview of MySQL metrics. It displays critical metrics like InnoDB buffer usage, query performance, and system memory, along with brief explanations of each variable.

## How to Install and Use

### Step 1: Download the script
```bash
curl -O https://raw.githubusercontent.com/haydenjames/mysqlmonitor-script/main/mysqlmonitor.sh
```

### Step 2: Make the script executable
```bash
chmod +x mysql-monitor.sh
```

### Step 3: Run the script
`./mysqlmonitor.sh`

### Blog Article 
Linuxblog.io: [MySQL Monitor: A Simple MySQL Monitoring Script](https://linuxblog.io/mysql-monitor-script/)
