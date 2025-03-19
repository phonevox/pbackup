#!/usr/bin/bash

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
_LOG_FILE="/var/log/pbackup.log"
_LOG_LEVEL=3 # 0:test, 1:trace, 2:debug, 3:info, 4:warn, 5:error, 6:fatal
_LOG_ROTATE_PERIOD=7

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

log "=== STARTING - ARGUMENTS: $*" muted

function generate_backup_file() {

    local COMPONENTS="as_db,as_config_files,as_sounds,as_mohmp3,as_dahdi,fx_db,fx_pdf,ep_db,ep_config_files,callcenter_db,asternic_db,FOP2_settings_db,sugar_db,vtiger_db,a2billing_db,mysql_db,menus_permissions,calendar_db,address_db,conference_db,eop_db"

    # adding extra components if our custom bkp engine is installed
    if [ -f "/usr/share/issabel/privileged/pvx-backupengine-extras" ]; then
        log "Custom backup engine detected, adding extra components to backup..."
        CUSTOM_BACKUPENGINE_COMPONENTS=",int_ixcsoft,int_sgp,int_receitanet,int_altarede" # start with comma!!!!!!
    else
        log "Custom backup engine not detected, skipping extra components..."
    fi
    COMPONENTS="$COMPONENTS$CUSTOM_BACKUPENGINE_COMPONENTS"
    log "Components to backup: $COMPONENTS"

    log "Generating Issabel backup, this might take a while..."
    /usr/bin/issabel-helper backupengine --backup --backupfile "$BACKUP_FILE" --tmpdir "$BACKUP_DIR" --components $COMPONENTS 2>&1

    # checking if backup was generated
    if ! [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        log "ERROR: '$BACKUP_DIR/$BACKUP_FILE' was not generated! Exiting for safety reasons..."
        exit 1
    fi

    log "'$BACKUP_DIR/$BACKUP_FILE' generated, proceeding..."
}

# === RUNTIME ===

function validations () {
    FULL_REMOTE_DEST="$1"

    # if not first argument, quit 
    log "Checking for required arguments..."
    if  [ -z "$FULL_REMOTE_DEST" ]; then
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
    if ! pbackup --list | grep -q "^$REMOTE_NAME:"; then
        log "ERROR: Remote $REMOTE_NAME not found! Exiting..."
        exit 1
    fi

    # checking for issabelhelper, to generate the backups. if this is not present this may not be an issabel server
    log "Checking for issabel-helper to handle backup generation..."
    if ! [ -f "/usr/bin/issabel-helper" ]; then
        log "ERROR: '/usr/bin/issabel-helper' not found. Is this really an IssabelPBX?"
        exit 1
    fi

}

function main () {
    validations $@

    generate_backup_file

    log "Uploading through pbackup..."
    pbackup --files "$FILES" --to "$FULL_REMOTE_DEST"

    log "Cleaning backupfile from local machine..."
    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        rm -f "$BACKUP_DIR/$BACKUP_FILE"
        log "- '$BACKUP_DIR/$BACKUP_FILE' deleted."
    else
        log "ERROR: '$BACKUP_DIR/$BACKUP_FILE' was not found. We aren't going to perform any delete operation in order to avoid deleting other files. Location checked: \"$BACKUP_DIR/$BACKUP_FILE\""
    fi

    log "All done!"
}

main "$@"
