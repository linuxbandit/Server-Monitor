#!/bin/bash

# initial variables
config_dir="/etc/server-monitor/"
applications_to_install="nginx php5-fpm openssl"
notify_dir="${config_dir}website/notify/"

# file paths
server_monitor_conf="${config_dir}server-monitor.conf"
server_list="${config_dir}servers.list"
server_offline_list="${config_dir}offline_servers.list"
notify_down="${config_dir}notify-down.sh"
notify_down_script="${config_dir}custom-notify-down-script.sh"
notify_up_script="${config_dir}custom-notify-up-script.sh"
ssl_key="${config_dir}ssl/server-monitor.key"
ssl_cert="${config_dir}ssl/server-monitor.crt"

## Get public IP
pub_ip=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -o -E '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
if [[ "$pub_ip" = "" ]]; then
		pub_ip=$(wget -4qO- "http://whatismyip.akamai.com/")
fi

#FUNCTIONS
function getArrayOfServers(){
    sed -i '/^\s*$/d' "$server_list" #remove empty lines

    readarray file_lines < "$server_list"

    # remove server keys from output
    file_line_cnt=${#file_lines[@]}
    server_arr=()
    key_arr=()
    for ((i=0;i<file_line_cnt;i++)); do
        line="${file_lines[i]}"
        if [[ "$line" != "#"* ]]
        then
            IFS='|' read -r -a explode <<< "$line"
            server_arr+=("${explode[0]}")
            key_arr+=("${explode[1]}")
        fi
    done
    server_cnt=${#server_arr[@]}
}

function clean(){
    string=$1
    cleaned_string="$(echo -e "${string}" | sed -e 's/[[:space:]]*$//')" # acts like phps trim function
    cleaned_string="${cleaned_string//\|}" # remove '|'
    echo "$cleaned_string"
}

function getConfEquals(){
    var=$(clean "$1")
    file=$(clean "$2")

    equals=$(grep --only-matching --perl-regex "(?<=$var\=).*" "$file")
    echo "$equals"
}

function setConfEquals(){
    var=$(clean "$1")
    val=$(clean "$2")
    file=$(clean "$3")

    if grep -q "${var}=" "$file"
    then
        # variable already exists so update it
        sed -i "s|\($var=*\).*|$var=$val|" "$file"
    else
        echo "${var}=${val}" >> "$file"
    fi
}

# INITIAL SETUP
if [ ! -f "$server_monitor_conf" ]; then #will do setup if conf file does not exist
    ## Check if valid OS
    if [[ -e /etc/debian_version ]]; then
        OS=debian
    elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
        OS=centos
    else
        echo "Looks like you aren't running this installer on a Debian, Ubuntu or CentOS system"
        exit 5
    fi

    ## Create folder for config files
    mkdir -p "${config_dir}"

    ## Install packages
    if [[ "$OS" = 'debian' ]]; then
        apt-get update
        apt-get install -y $applications_to_install
    else
        yum update
        yum install -y $applications_to_install
    fi

    ## Check if server is behind NAT
    IP=$(wget -4qO- "http://whatismyip.akamai.com/")
    if [[ "$pub_ip" != "$IP" ]]; then
            echo -e "\nYour server may be behind a NAT!\n"
            echo -e "\nIf your server is NATed (e.g. LowEndSpirit), I need to know the external IP and an available port for the web server"
            read -p "External IP: " -e USEREXTERNALIP

            if [[ $USEREXTERNALIP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
            then
                # is valid IP
                pub_ip=$USEREXTERNALIP
            fi
    fi

    ## Ask port number
    read -p "Choose port for NGINX web-server to use: " -e -i 443 port

    ## setup default conf
    setConfEquals "ip" "$pub_ip" "$server_monitor_conf"
    setConfEquals "port" "$port" "$server_monitor_conf"
    setConfEquals "first_hour" "5" "$server_monitor_conf"
    setConfEquals "after_hour" "30" "$server_monitor_conf"

    ## Setup NGINX
    ### Setup ssl
    #### Create ssl folder
    mkdir -p "${config_dir}ssl"
    #### Create ssl certificates
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout "${ssl_key}" -out "${ssl_cert}" -subj '/CN=maxis.me/O=Lorem Ipsum/C=UK'

    ### Setup NGINX config
    echo -e "server {
    listen $port ssl;

    root ${config_dir}website/;

    server_name $pub_ip;
    ssl_certificate ${ssl_cert};
    ssl_certificate_key ${ssl_key};

    #Config to get perfect SSL Labs Score - 25/03/2017
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;
    ssl_protocols TLSv1.2;
    ssl_prefer_server_ciphers on;
    ssl_ciphers AES256+EECDH:AES256+EDH:!aNULL;
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_ecdh_curve secp384r1;
    add_header Strict-Transport-Security \"max-age=31536000; includeSubdomains\";
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;
    # gzip should not be used with ssl
    gzip off;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        try_files \$uri =404;
        fastcgi_pass unix:/var/run/php5-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }
}" > /etc/nginx/sites-enabled/server-monitor
    ln -s /etc/nginx/sites-enabled/server-monitor /etc/nginx/sites-available/server-monitor

    ## scripts setup
    ### Create website folder and notify folder
    mkdir -p "$notify_dir"
    chown www-data:www-data "$notify_dir" #allow php to write to folder when called from another servers cron

    ### Create file to list up servers
    echo -e "# DO NOT EDIT THIS FILE!
# USE THE server-monitor.sh SCRIPT
# THIS FILE IS TO LIST ALL SERVERS TO LISTEN OUT FOR" > "$server_list"

    ### Create file to list down servers
    echo -e "# DO NOT EDIT THIS FILE!
# USE THE server-monitor.sh SCRIPT
# THIS FILE IS TO LIST CURRENTLY DOWN SERVERS" > "$server_offline_list"

    ### PHP incoming notification
    echo -e "<?php
\$key = \$_GET['key'];

//get servers array
\$handle = fopen('${server_list}', \"r\");
if (\$handle) {
    while ((\$line = fgets(\$handle)) !== false) {
        if(substr(\$line, 0, 1) != \"#\") { //not lines that start with comment
            \$exp = explode(\"|\", \$line);
            \$server = trim(\$exp[0]);
            \$server_key = trim(\$exp[1]);
            if(\$server_key == \$key){
                    file_put_contents('${notify_dir}'.\$key.'.active', date(\"Y-m-d H:i:s\"));
                    echo \"Sent\";
            }
        }
    }
    fclose(\$handle);
}" > "${config_dir}website/notify.php"

    ### PHP notify file
    echo -e "<?php
sleep(2); # run after server crons come in
\$offline_servers_file = '${server_offline_list}';
\$servers = fopen('${server_list}', 'r');
if (\$servers) {
    while ((\$line = fgets(\$servers)) !== false) {
        if(substr(\$line, 0, 1) != '#') { //not lines that start with comment
            \$exp = explode('|', \$line);
            \$server = trim(\$exp[0]);
            \$server_key = trim(\$exp[1]);

            \$last_active = file_get_contents('${notify_dir}'.\$server_key.'.active');
            if(!\$last_active || empty(\$last_active)) continue;

            \$start_date = new DateTime(\$last_active);
            \$since_start = \$start_date->diff(new DateTime());

            \$days = \$since_start->days;
            \$hours = \$since_start->h;
            \$mins = \$since_start->i;
            if(\$days > 0){
                \$hours = \$hours + (\$days*24);
            }
            \$total_mins = \$mins + 60*\$hours;

            if(\$mins <= 1 && \$hours == 0){
                //ONLINE
                if(strpos(file_get_contents(\$offline_servers_file),\$server) !== false) {
                    shell_exec(\"${notify_up_script} '\$server' &\");

                    //delete \$server from offline list
                    \$contents = file_get_contents(\$offline_servers_file);
                    \$contents = str_replace(\$server.PHP_EOL, '', \$contents);
                    file_put_contents(\$offline_servers_file, \$contents);
                }

                \$file_up = '${notify_dir}'.\$server_key.'.up';
                \$up_cnt = file_get_contents(\$file_up);
                file_put_contents(\$file_up, (int)\$up_cnt + 1);
            }else{
                //OFFLINE
                shell_exec(\"${notify_down} '\$server' '\$total_mins' &\");
                if(strpos(file_get_contents(\$offline_servers_file),\$server) === false) {
                    //add \$server to offline list
                    file_put_contents(\$offline_servers_file, \$server.PHP_EOL , FILE_APPEND | LOCK_EX);
                }
                \$file_down = '${notify_dir}'.\$server_key.'.down';
                \$down_cnt = file_get_contents(\$file_down);
                file_put_contents(\$file_down, (int)\$down_cnt + 1);
            }
        }
    }
    fclose(\$servers);
}" > "${config_dir}website/check.php"
    chmod +x "${config_dir}website/check.php"

    ### Notify script
    #### Down script to handle time
    echo -e "#!/bin/bash
# DO NOT EDIT THIS FILE!
# THIS FILE EXECUTES THE CUSTOM DOWN SCRIPT AT THE CONFIG TIMES
total_mins_down=\$2

function getEquals(){
    var=\"\$1\"
    file=\"\$2\"

    equals=\$(grep --only-matching --perl-regex \"(?<=\$var\=).*\" \"\$file\")
    echo \"\$equals\"
}

f_h=\$(getEquals \"first_hour\" \"$server_monitor_conf\")
a_h=\$(getEquals \"after_hour\" \"$server_monitor_conf\")

run_script=false

if ! grep -qx \"\$1\" \"$server_offline_list\"
then
    #first time offline
    run_script=true
else
    if (( \$((total_mins_down)) <= 60 ))
    then
        #f_h
        if (( \$((total_mins_down))%\$((f_h)) == 0 )); then
            run_script=true
        fi
    else
        #a_h
        if (( \$((total_mins_down))%\$((a_h)) == 0 )); then
            run_script=true
        fi
    fi
fi

if \$run_script
then
    hours=\"\$((total_mins_down/60))\"
    mins=\"\$((total_mins_down%60))\"
    $notify_down_script \"\$1\" \"\$hours\" \"\$mins\"
fi

" > "$notify_down"

    #### Custom Down script
    echo "#!/bin/bash
# SCRIPT EXECUTED WHEN SERVER IS DOWN
server=\$1
hours_down=\$2
mins_down=\$3

# CUSTOM CODE
echo \"\$server has been down for \$down_time\" >> \"${config_dir}uptime.log\"
" > "$notify_down_script"

    #### Down script
    echo "#!/bin/bash
# SCRIPT EXECUTED WHEN SERVER IS BACK UP
server=\$1

# CUSTOM CODE
echo \"\$server is back up!\" >> \"${config_dir}uptime.log\"
" > "$notify_up_script"

    #### Make scripts executable
    chmod +x "$notify_up_script" "$notify_down_script" "$notify_down"

    #add cron
    php_path=$(which php)
    (crontab -u root -l ; echo -e "*\t*\t*\t*\t*\t$php_path -f '${config_dir}website/check.php'") | crontab -u root -

    #restart nginx
    service nginx restart

    echo -e "\e[32mSuccessfully installed! Run script again to add servers and more!\e[0m"
    exit
fi #END OF SETUP

#initial variables
pad=20

while :
do
    echo -e "Would you like to?"
    echo -e "\t1) Show server status"
    echo -e "\t2) Add a new server monitor"
    echo -e "\t3) Remove a server monitor"
    echo -e "\t4) Edit server down script"
    echo -e "\t5) Edit server up script"
    echo -e "\t6) Choose how often to execute down script"
    echo -e "\t7) Uninstall Server Monitor"
    echo -e "\t8) Exit"

    read -p "Choose option [1-7]: " option
    case $option in
        1)
            clear
            getArrayOfServers #returns $server_arr, $key_arr and $server_cnt
            if [ "$server_cnt" -eq "0" ]; then
                echo "No servers configured!"
            else
                padding="-$pad"
                printf "\e[4m%${padding}s\e[0m \e[4m%-8s\e[0m \e[4m%${padding}s\e[0m \e[4m%${padding}s\e[0m \e[4m%-7s\e[0m \e[4m%${padding}s\e[0m\n\n" "Server" "Status" "Last Notification" "Started monitor" "% Up" "Key"
                for ((i=0;i<server_cnt;i++)); do
                    info="Online"
                    color="\e[32m" #make text green

                    #last active
                    server_last_active_file="${notify_dir}${key_arr[i]}.active"
                    last_notification="$(cat "$server_last_active_file" 2>/dev/null)"

                    #calculate percentage up time and up since
                    up_file="${notify_dir}${key_arr[i]}.up"
                    if [ -a "$up_file" ]
                    then
                        up=$(cat "$up_file" 2>/dev/null)
                    else
                        up=0
                    fi

                    down_file="${notify_dir}${key_arr[i]}.down"
                    if [ -a "$down_file" ]
                    then
                        down=$(cat "$down_file" 2>/dev/null)
                    else
                        down=0
                    fi

                    if [[ "$up" == "0" ]]
                    then
                        percentage_up="0"
                        mon_since="-"
                    else
                        up_seconds=$(($up*60))
                        mon_since=$(date -d "now - $(( `date -d "$last_notification" +%s`-`date -d "now - $up_seconds seconds" +%s`)) seconds" +'%Y-%m-%d %H:%M')
                        percentage_up=$(echo $(( 100000 * $up / ($up+$down) )) | sed 's/...$/.&/')
                    fi

                    if [ -a "$server_last_active_file" ]
                    then
                        while read offline_server
                        do
                            if [[ "$offline_server" == "${server_arr[i]}" ]]
                            then
                                color="\e[31m"  #overwrite to text red
                                info="Offline  "
                            fi
                        done < "$server_offline_list"
                    else
                        color="\e[33m"
                        info="-"
                        last_notification="Waiting on curl..."
                    fi
                    #printf "${color}${server_arr[i]}\e[0m $info $last_notification ${key_arr[i]}"
                    printf "${color}%${padding}s\e[0m %-8s %${padding}s %${padding}s %-7s %${padding}s\n" "${server_arr[i]}" "$info" "$last_notification" "$mon_since" "$percentage_up" "${key_arr[i]}"
                done
            fi
        ;;
        2)
            clear
            # add new server
            ok=0
            while [ $ok = 0 ]
            do
                read -p "Server name: " -e server_name
                server_name=$(clean "$server_name")
                if [[ ${#server_name} -gt $pad || 1 -gt ${#server_name} ]]
                then
                    echo -e "\e[31mERROR:\e[0m Server name has to be 1 - $pad characters. You entered ${#server_name}!"
                else
                    ok=1
                fi
            done

            #generate random 20 char key
            key_string=$(date +%s | sha256sum | head -c 20 ; echo)

            # Check if server not already registered
            getArrayOfServers #returns $server_arr and $server_cnt
            for ((i=0;i<server_cnt;i++)); do
                if [[ "${server_arr[i]}" == "$server_name" ]]
                then
                    echo -e "\e[31mAlready registered the server named $server_name!\e[0m"
                fi
            done

            #store server config in file
            echo -e "$server_name|$key_string" >> "$server_list"

            #get ip and port from config
            ip=$(getConfEquals "ip" "$server_monitor_conf")
            port=$(getConfEquals "port" "$server_monitor_conf")

            #get result from server
            echo "Add to the crontab on your server '$server_name':"
            echo -e "\e[32m*       *       *       *       *       curl -k https://$ip:$port/notify.php?key=$key_string\e[0m"
            echo "WARNING: Monitor will not start until first successful curl."
        ;;
        3)
            clear
            #List Servers
            getArrayOfServers #returns $server_arr and $server_cnt
            if [ "$server_cnt" -eq "0" ]; then
                echo "No servers configured!"
            else
                for ((i=0;i<server_cnt;i++)); do
                    echo "$((i+1))) ${server_arr[i]}"
                done
            fi

            #pick server
            read -p "Enter # of server to delete: " -e server_num
            actual_server_num=$((server_num-1))
            if [ ${actual_server_num} -gt -1 ]; then
                server_name="${server_arr[$actual_server_num]}"
                if [[ "$server_name" != "" ]]
                then
                    read -r -p "Are you sure you want to delete '$server_name'? [y/N] " response
                    if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]
                    then
                        #delete server from $server_list
                        sed -i "/^${server_name}|/d" "$server_list"
                        echo -e "\e[31mDeleted: $server_name\e[0m"
                    fi
                fi
            fi
        ;;
        4)
            clear
            nano "$notify_down_script"
        ;;
        5)
            clear
            nano "$notify_up_script"
        ;;
        6)
            clear
            f_h=$(getConfEquals "first_hour" "$server_monitor_conf")
            a_h=$(getConfEquals "after_hour" "$server_monitor_conf")

            # Notify times
            read -p "Every x minute(s) (for first hour): " -e -i "${f_h}" first_hour
            read -p "Every x minute(s) (after first hour): " -e -i "${a_h}" after_hour

            #update config
            setConfEquals "first_hour" "$first_hour" "$server_monitor_conf"
            setConfEquals "after_hour" "$after_hour" "$server_monitor_conf"
        ;;
        7)
            clear
            # Remove server monitor

            read -p "Are you sure? This is unrecoverable. [Y/N]: " -e RUsure
            if [[ "$RUsure" == "Y" || "$RUsure" == "y" ]]
            then
                rm -rf "$config_dir"
                #remove nginx files
                rm /etc/nginx/sites-enabled/server-monitor /etc/nginx/sites-available/server-monitor
                service nginx restart

                #remove cron
                crontab -u root -l | grep -v "'${config_dir}website/check.php'"  | crontab -u root -

                echo -e "Done!\n"
                echo "If you would like to uninstall the applications run:"
                echo "apt-get remove -y $applications_to_install --purge"
            else
                echo "Canceled."
            fi
            exit
        ;;
        8)
            exit
        ;;
    esac
done