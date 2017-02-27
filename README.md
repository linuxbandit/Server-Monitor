# server-monitor.sh

This script creates an NGINX webserver with a PHP backend.

Run the script the first time to install the necessary applications.

After that, running the script will return:

```
Would you like to?
	1) Add a new server monitor
	2) Remove a server monitor
	3) Show server status
	4) Edit notification scripts
	5) Choose notification times
	6) Uninstall Server Monitor
	7) Exit
```

Adding a new server will supply you with a key to curl every minute (using cron) from another server. The server that uses this script will then monitor to check the curl has been made.

<img src="https://i.imgur.com/RAClgkZ.png">
