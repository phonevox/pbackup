#!/usr/bin/bash

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
LOG_FILE_PATH="$CURRDIR"
LOG_FILE_NAME="magnus-backup"
LOG_FILE="$LOG_FILE_PATH/$LOG_FILE_NAME-$(date '+%Y-%m-%d').log"

# Magnus Backup
FILES=""

# === FUNCS ===

function log () {
    local CURRTIME=$(date '+%Y-%m-%d %H:%M:%S')
    if ! [ -f "$LOG_FILE" ]; then
        echo -e "[$CURRTIME] $SCRIPT_NAME> Iniciando novo logfile" > "$LOG_FILE"
    fi

    if [ -z $2 ]; then
        local muted=false
    else 
        local muted=true
    fi

    echo -e "[$CURRTIME] $SCRIPT_NAME> $1" >> "$LOG_FILE"
    if ! $muted; then
        echo -e "[$CURRTIME] $SCRIPT_NAME> $1"
    fi
}

log "=== STARTING - ARGUMENTS: $*" muted

# === RUNTIME ===

function validations () {
    echo "Validation arguments:"
    for i in "$@"; do
        echo "Argument: $i"
    done

    DESTINATION="$1"

    # if not first argument, quit 
    log "Checking for required arguments..."
    if  [ -z $1 ]; then
        log "ERROR: Your first argument must be the rclone remote name and path if any. Example: \"mega:/backup\""
        exit 1
    fi

    # test if usr/sbin/pbackup exists
    log "Checking if pbackup is installed..."
    if ! [ -f "/usr/sbin/pbackup" ]; then
        log "ERROR: You need to install pbackup! Exiting..."
        exit 1
    fi

    # check if remote exists
    log "Checking if remote exists..."
    REMOTE_NAME="$(echo $DESTINATION | cut -d ':' -f 1)"
    if ! $(pbackup --list | grep -q "^$REMOTE_NAME:"); then
        log "ERROR: Remote $REMOTE_NAME not found! Exiting..."
        exit 1
    fi
}

function main () {
    validations $@
}

main "$@"
