#!/bin/bash

source /var/lib/conanexiles/redis_cmds.sh
source /var/lib/conanexiles/notifier.sh

APPID=443030

function get_available_build() {
    # clear appcache (to avoid reading infos from cache)
    rm -rf /root/Steam/appcache

    # get available build id and return it
    local _build_id=$(/steamcmd/steamcmd.sh +login anonymous +app_info_update 1 +app_info_print $APPID +quit | \
    			    grep -EA 1000 "^\s+\"branches\"$" | grep -EA 5 "^\s+\"public\"$" | \
    			    grep -m 1 -EB 10 "^\s+}" | grep -E "^\s+\"buildid\"\s+" | \
    			    tr '[:blank:]"' ' ' | awk '{print $2}')

    echo $_build_id
}

function get_installed_build() {
    # get currently installed build id and return it
    local _build_id=$(cat /conanexiles/steamapps/appmanifest_$APPID.acf | \
              grep -E "^\s+\"buildid\"" |  tr '[:blank:]"' ' ' | awk '{print $2}')

    echo $_build_id
}

check_server_running() {
    if ps axg | grep -F 'ConanSandboxServer' | grep -v -F 'grep' > /dev/null; then
        echo 0
    else
        echo 1
    fi
}

function start_server() {
    # check if server is already running to avoid running it more than one time
    if [[ `check_server_running` == 0 ]];then
        notfier_error "The server is already running. I don't want to start it twice."
        return
    else
        notifier_info "Cleaning up game.db."
        sqlite3 /conanexiles/ConanSandbox/Saved/game.db "VACUUM;REINDEX;ANALYZE;pragma integrity_check"
        supervisorctl status conanexilesServer | grep RUNNING > /dev/null
        [[ $? != 0 ]] && supervisorctl start conanexilesServer
	# restart chat bot to read the new log
        if [[ ${CONANEXILES_Game_DiscordPlugin_Chat_Enabled} == 1 ]]; then
            supervisorctl restart conanexilesChat
        fi
        if [[ ${CONANEXILES_Game_DiscordPlugin_Broadcast_Enabled} == 1 ]]; then
            /usr/bin/discord_broadcast "Server is starting..."
        fi
    fi
}

function stop_server() {
    # stop the server
    supervisorctl status conanexilesServer | grep RUNNING > /dev/null
    [[ $? == 0 ]] && supervisorctl stop conanexilesServer

    # wait until the server process is gone
    while ps axg | grep -F 'ConanSandboxServer' | grep -v -F 'grep' > /dev/null; do 
      notifier_error "Seems I can't stop the server. Help me!"
      sleep 5
    done
}

function update_server() {
    # update server
    supervisorctl status conanexilesUpdate | grep RUNNING > /dev/null
    [[ $? != 0 ]] && supervisorctl start conanexilesUpdate
}

function backup_server() {
    # backup the server db and config
    local _src="/conanexiles/ConanSandbox/Saved"
    local _dst="/conanexiles/ConanSandbox/Saved.$(get_installed_build)"

    # remove backup dir if already exists (should never happen)
    if [ -d "$_dst" ]; then
        rm -rf "$_dst"
        notifier_info "Removed existing build backup in $_dst"
    fi

    # backup current build db and config
    if [ -d "$_src" ]; then
        cp -a "$_src" "$_dst"

        # Was backup successfull ?
        if [ $? -eq 0 ]; then
            notifier_info "Backed up current build db and configs to $_dst"
        else
            notifier_warn "Failed to backup current build db and configs to $_dst."
        fi
    fi
}

start_shutdown_timer() {
    _t_val="$1"
    _i=0

    while true; do
        if [ $_i == $_t_val ]; then
            break
        fi

        notifier_debug "Shutdown Server in $((_t_val - _i)) minutes"

        if [[ ${CONANEXILES_Game_RconPlugin_RconEnabled} == 1 ]]; then
            /usr/bin/rconcli broadcast --type shutdown --value $((_t_val - _i))
	    # notify discord bot too
            if [[ ${CONANEXILES_Game_DiscordPlugin_Broadcast_Enabled} == 1 ]]; then
		/usr/bin/discord_broadcast "Server is shutting down in $((_t_val - _i)) minutes."
            fi
        fi
        sleep 60
        ((_i++))
    done
}

function do_update() {
    # This function take either 0 for update with sleep, or 1 for update without sleep and backup
    # stop, backup, update and start again the server
    redis_cmd_proxy redis_set_update_running_start
    if [[ $1 == 1 ]];then
        update_server
    else
        start_shutdown_timer 10
        stop_server
        # Give other instances time to shutdown
        sleep 30
        backup_server
        update_server
    fi

    # wait till update is finished
    while $(supervisorctl status conanexilesUpdate | grep RUNNING > /dev/null); do
        sleep 1
    done

    # check if server is up to date
    local _ab=$(get_available_build)
    local _ib=$(get_installed_build)

    if [[ $_ab != $_ib ]];then
        echo "Warning: Update seems to have failed. Installed build ($_ib) does not match available build ($_ab)."
    else
        echo "Info: Updated to build ($_ib) successfully."
    fi

    redis_cmd_proxy redis_set_update_running_stop

    start_server
}

start_master_loop() {

    notifier_info "Mode: Master - Instance: `hostname`"

    while true; do
        # if initial install/update fails try again
        if [ ! -f "/conanexiles/ConanSandbox/Binaries/Win64/ConanSandboxServer-Win64-Test.exe" ]; then
            notifier_warn "No binaries found. Doing a fresh installation"
            do_update 1
            notifier_debug "Initial installation finished."
        fi

        # check if an update is needed
        ab=$(get_available_build)
        ib=$(get_installed_build)

        if [[ -z $ab ]];then
            echo "Warning: Available build string is NULL."
        elif [[ $ab != $ib ]];then
            notifier_info "New build available. Updating $ib -> $ab"
            if [[ ${CONANEXILES_Game_DiscordPlugin_Broadcast_Enabled} == 1 ]]; then
                /usr/bin/discord_broadcast "New build available. Updating $ib -> $ab"
            fi
            do_update 0
        fi

        # check if mods are updated
        if [[ -f /modscript.txt ]]; then
            $(/steamcmd/steamcmd.sh +runscript /modscript.txt)
            if [[ ! -f /conanexiles/steamapps/workshop/content/440900/modlist.txt ]]; then
                echo > /conanexiles/steamapps/workshop/content/440900/modlist.txt
                for i in `cat /mod_list.txt` ; do
                    filename=`basename $(ls /conanexiles/steamapps/workshop/content/440900/$i/*.pak)`;
                    echo "Z:/conanexiles/ConanSandbox/Mods/$i/$filename" >> /conanexiles/steamapps/workshop/content/440900/modlist.txt;
                done
            fi
            bytes=`rsync -avr --stats /conanexiles/steamapps/workshop/content/440900/* /conanexiles/ConanSandbox/Mods | grep "Total transferred file size:" | sed 's/Total transferred file size: \(.*\) bytes/\1/'`
            if [[ $bytes != "0" ]];then
                notifier_info "Mods have been updated: $bytes bytes"
                if [[ ${CONANEXILES_Game_DiscordPlugin_Broadcast_Enabled} == 1 ]]; then
                    /usr/bin/discord_broadcast "Mods have been updated: $bytes bytes"
                fi
                do_update 0
            fi
        fi

        start_server
        sleep 300
    done
}

start_slave_loop() {

    notifier_info "Mode: Slave - Instance: `hostname`"

    while true; do
        if [[ "`redis_cmd_proxy redis_get_update_running`" == 0 ]]; then
            if [[ `check_server_running` == 0 ]]; then
                start_shutdown_timer 10
                stop_server
            fi
        # NOTE: We need to check this explcitly, when redis server is not accessible
        elif [[ "`redis_cmd_proxy redis_get_update_running`" == 1 ]]; then
            [[ `check_server_running` == 1 ]] && \
                start_server
        fi
        sleep 10
    done
}

#
# Main loop
#

# notifier_info "Global Master Server Instance: `get_master_server_instance`"

# if [[ "`get_master_server_instance`" == "`hostname`" ]];then
if [[ "${CONANEXILES_MASTERSERVER}" == 1 ]]; then
    start_master_loop
else
    start_slave_loop
fi
