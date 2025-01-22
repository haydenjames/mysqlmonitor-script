## MySQL Monitor Script
![MySQL Monitor Script Output](https://static.linuxblog.io/wp-content/uploads/2025/01/mysqlmonitor-script-7.png)

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
