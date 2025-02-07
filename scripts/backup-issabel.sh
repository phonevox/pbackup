#!/usr/bin/bash

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
LOG_FILE_PATH="$CURRDIR"
LOG_FILE_NAME="issabel-backup"
LOG_FILE="$LOG_FILE_PATH/$LOG_FILE_NAME-$(date '+%Y-%m-%d').log"

# Issabel Backup
BACKUP_DIR="/var/www/backup" # Padrão
BACKUP_FILE="issabelbackup-$(date +%Y%m%d%H%M%S)-06.tar" # Não mude isso. É necessário pra poder upar o backup depois.

# idiotice a baixo @Adrian K.
_BACKUP_FILE_LOCAL="$BACKUP_DIR/$BACKUP_FILE" # onde está o arquivo de backup que vamos upar
_RECORDINGS_LOCAL="/var/spool/asterisk/monitor/%YEAR-1d%/%MONTH-1d%/%DAY-1d%" # onde está as gravações que vamos upar
_BACKUP_FILE_REMOTE=":/configuration" # pra onde o backup vai, no remote? ('SOMADO' AO $1)
_RECORDINGS_REMOTE=":/recordings/%YEAR-1d%/%MONTH-1d%" # pra onde as gravações vão, no remote? ('SOMADO' AO $1)
__BACKUP_FILE="$_BACKUP_FILE_LOCAL$_BACKUP_FILE_REMOTE"
__RECORDINGS="$_RECORDINGS_LOCAL$_RECORDINGS_REMOTE"
# fim da idiotice

FILES="$__BACKUP_FILE,$__RECORDINGS"

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

function generate_backup_file() {
    log "Checking for issabel-helper to handle backup generation..."
    if ! [ -f "/usr/bin/issabel-helper" ]; then
        log "ERROR: '/usr/bin/issabel-helper' not found. Is this really an IssabelPBX?"
        exit 1
    fi

    log "Generating Issabel backup, this might take a while..."
    /usr/bin/issabel-helper backupengine --backup --backupfile "$BACKUP_FILE" --tmpdir "$BACKUP_DIR" --components as_db,as_config_files,as_sounds,as_mohmp3,as_dahdi,fx_db,fx_pdf,ep_db,ep_config_files,callcenter_db,asternic_db,FOP2_settings_db,sugar_db,vtiger_db,a2billing_db,mysql_db,menus_permissions,calendar_db,address_db,conference_db,eop_db,int_ixcsoft,int_sgp,int_receitanet,int_altarede 2>&1

    # checking if backup was generated
    if ! [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        log "ERROR: '$BACKUP_DIR/$BACKUP_FILE' was not generated! Exiting for safety reasons..."
        exit 1
    fi

    log "'$BACKUP_DIR/$BACKUP_FILE' generated, proceeding..."
}

# === RUNTIME ===

function main () {

    # if not first argument, quit 
    log "Checking for required arguments..."
    if  [ -z $1 ]; then
        log "ERROR: Your first argument must be the rclone remote name and path if any. Example: \"mega:/backup\""
        exit 1
    fi
    DESTINATION="$1"

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

    generate_backup_file

    log "Uploading through pbackup..."
    pbackup --files "$FILES" --to "$DESTINATION"

    log "Cleaning backupfile from local machine..."
    
    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        rm -f "$BACKUP_DIR/$BACKUP_FILE"
    else
        log "ERROR: '$BACKUP_DIR/$BACKUP_FILE' was not found. We aren't going to perform any delete operation in order to avoid deleting other files. Location checked: \"$BACKUP_DIR/$BACKUP_FILE\""
    fi

    log "All done!"
}

main "$@"
