## MySQL Monitor Script
![MySQL Monitor Script Output](https://static.linuxblog.io/wp-content/uploads/2025/01/mysqlmonitor-script-5.png)

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

### Blog Article 
Linuxblog.io: [MySQL Monitor: A Simple MySQL Monitoring Script](https://linuxblog.io/mysql-monitor-script/)
