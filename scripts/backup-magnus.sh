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

log "=== STARTING - ARGUMENTS: $* ===" muted

# === RUNTIME ===

function validations () {
    FULL_REMOTE_DEST="$1"

    # if not first argument, quit 
    log "Checking for required arguments..."
    if  [ -z $FULL_REMOTE_DEST ]; then
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
    REMOTE_NAME="$(echo $FULL_REMOTE_DEST | cut -d ':' -f 1)"
    if ! $(pbackup --list | grep -q "^$REMOTE_NAME:"); then
        log "ERROR: Remote $REMOTE_NAME not found! Exiting..."
        exit 1
    fi
}

function main () {
    validations $@

    FILES_TO_UPLOAD=()
    RECORDINGS=false
    AUDIO_FILES=false

    # @TODO(Adrian) : locate yesterday's backup file, confirm it exists

    TODAY=$(date '+%d-%m-%Y')
    YESTERDAY=$(date -d "yesterday" '+%d-%m-%Y')
    YESTERDAY_BACKUP_FILE=/usr/local/src/magnus/backup/backup_voip_softswitch.$YESTERDAY.tgz


    log "Looking for yesterday's backup file... ($YESTERDAY_BACKUP_FILE)"
    if ! [ -f $YESTERDAY_BACKUP_FILE ]; then
        log "WARN: Could not locate yesterday's backup file! Trying to make today's backup..."
        
        # make backup
        if ! [ -f /var/www/html/mbilling/cron.php ]; then
            log "ERROR: Could not locate mbilling cron.php! Is this really a mbilling server? Exiting... (/var/www/html/mbilling/cron.php)"
            exit 1
        fi
        php /var/www/html/mbilling/cron.php Backup

        TODAY_BACKUP_FILE=/usr/local/src/magnus/backup/backup_voip_softswitch.$TODAY.tgz
        if ! [ -f $TODAY_BACKUP_FILE ]; then
            log "ERROR: Failed to generate today's backup file! Exiting... ($TODAY_BACKUP_FILE)"
            log "failed: $TODAY_BACKUP_FILE"
            exit 1
        fi 

        log "SUCCESS: Today's backup file generated! ($TODAY_BACKUP_FILE)"
        FILES_TO_UPLOAD+=($TODAY_BACKUP_FILE)
    else
        log "Yesterday's backup file found! Using it..."
        FILES_TO_UPLOAD+=($YESTERDAY_BACKUP_FILE)
    fi

    # show files to be uploded, separated by commas, no spaces
    log "Files to be uploaded:"
    read -a FILES_TO_UPLOAD <<< $(echo $FILES_TO_UPLOAD | tr ' ' ',')
    log "Files to be uploaded: $FILES_TO_UPLOAD"

}

main "$@"
