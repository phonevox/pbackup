#!/usr/bin/bash

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
_LOG_FILE="/var/log/pbackup.log"
_LOG_LEVEL=0 # 0:test, 1:trace, 2:debug, 3:info, 4:warn, 5:error, 6:fatal
_LOG_ROTATE_PERIOD=7

# Issabel Backup
BACKUP_DIR="/var/www/backup" # Padrão
BACKUP_FILE="issabelbackup-$(date +%Y%m%d%H%M%S)-06.tar" # Não mude isso. É necessário pra poder upar o backup depois.

# other things
_REMOTE_FOLDER_CONFIGURATION="/configuration"
_REMOTE_FOLDER_RECORDINGS="/recordings"

# === FLAG GENERATION ===

# dirname so we access the directory "behind" us
source "$(dirname "$CURRDIR")/lib/ezflags.sh"
source "$(dirname "$CURRDIR")/lib/uzful.sh"

add_flag "d" "dry" "Do NOT make changes to the system" bool
add_flag "t" "remote" "Remote destination to upload to" string
add_flag "rec:HIDDEN" "recordings" "Backup recordings" bool
add_flag "config:HIDDEN" "configuration" "Backup configuration" bool

set_description "IssabelPBX Backup script for pbackup\nExample usage: sudo bash $FULL_SCRIPT_PATH --recordings --configuration -r 7 -t mega-bkp:/issabel-pbackup"
set_usage "sudo bash $FULL_SCRIPT_PATH [--recordings] [--configuration] [-r <days>] -t <remote> "
parse_flags $@

# === FUNCS ===

log.debug "=== STARTING - ARGUMENTS: $*" muted

function generate_backup_file() {

    local COMPONENTS="as_db,as_config_files,as_sounds,as_mohmp3,as_dahdi,fx_db,fx_pdf,ep_db,ep_config_files,callcenter_db,asternic_db,FOP2_settings_db,sugar_db,vtiger_db,a2billing_db,mysql_db,menus_permissions,calendar_db,address_db,conference_db,eop_db"

    # adding extra components if our custom bkp engine is installed
    if [ -f "/usr/share/issabel/privileged/pvx-backupengine-extras" ]; then
        log.debug "Custom backup engine detected, adding extra components to backup..."
        CUSTOM_BACKUPENGINE_COMPONENTS=",int_ixcsoft,int_sgp,int_receitanet,int_altarede" # start with comma!!!!!!
    else
        log.debug "Custom backup engine not detected, skipping extra components..."
    fi
    COMPONENTS="$COMPONENTS$CUSTOM_BACKUPENGINE_COMPONENTS"
    log.trace "Components to backup: $COMPONENTS"

    log.info "Generating Issabel backup, this might take a while..."
    /usr/bin/issabel-helper backupengine --backup --backupfile "$BACKUP_FILE" --tmpdir "$BACKUP_DIR" --components $COMPONENTS 2>&1

    # checking if backup was generated
    if ! [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        log.fatal "ERROR: '$BACKUP_DIR/$BACKUP_FILE' was not generated! Exiting for safety reasons..."
        exit 1
    fi

    log.info "'$BACKUP_DIR/$BACKUP_FILE' generated, proceeding..."
}

# === RUNTIME ===

function validations () {
    FULL_REMOTE_DEST="$(getFlag "t")"

    # if not first argument, quit 
    log.trace "Checking for required arguments..."
    if  [ -z "$FULL_REMOTE_DEST" ]; then
        log.fatal "ERROR: You need to provide an rclone remote destination! Example: -t \"mega:/backup\""
        exit 1
    fi

    # test if usr/sbin/pbackup exists
    log.trace "Checking if pbackup is installed..."
    if ! [ -f "/usr/sbin/pbackup" ]; then
        log.fatal "ERROR: You need to install pbackup! Exiting..."
        exit 1
    fi

    # check if remote exists
    log.trace "Checking if remote exists..."
    REMOTE_NAME="$(echo $FULL_REMOTE_DEST | cut -d ':' -f 1)"
    if ! pbackup --list | grep -q "^$REMOTE_NAME:"; then
        log.fatal "ERROR: Remote $REMOTE_NAME not found! Exiting..."
        exit 1
    fi

    # checking for issabelhelper, to generate the backups. if this is not present this may not be an issabel server
    log.trace "Checking for issabel-helper to handle backup generation..."
    if ! [ -f "/usr/bin/issabel-helper" ]; then
        log.fatal "ERROR: '/usr/bin/issabel-helper' not found. Is this really an IssabelPBX?"
        exit 1
    fi
}

function main () {
    validations

    # ======== SHOULD SAVE RECORDINGS ========
    if hasFlag "rec"; then
        RECORDINGS_LOCAL="/var/spool/asterisk/monitor/%YEAR-1d%/%MONTH-1d%/%DAY-1d%" # where is the file right now
        RECORDINGS_REMOTE=":$_REMOTE_FOLDER_RECORDINGS/%YEAR-1d%/%MONTH-1d%" # where will we save them on the remote
        RECORDINGS_DESTINATION="$RECORDINGS_LOCAL$RECORDINGS_REMOTE"
        FILES+=("$RECORDINGS_DESTINATION")
        log.trace "--- RECORDINGS ---"
        log.trace "FILES: $FILES"
        log.trace "RECORDINGS_LOCAL: $RECORDINGS_LOCAL"
    fi

    # ========= SHOULD SAVE CONFIGURATION ========
    if hasFlag "config"; then
        CONFIGURATION_LOCAL="$BACKUP_DIR/$BACKUP_FILE" # where is the file right now
        CONFIGURATION_REMOTE=":$_REMOTE_FOLDER_CONFIGURATION" # where will we save them on the remote
        CONFIGURATION_DESTINATION="$CONFIGURATION_LOCAL$CONFIGURATION_REMOTE"
        FILES+=("$CONFIGURATION_DESTINATION")
        generate_backup_file
    fi

    # ======== UPLOAD ========
    log.debug "Uploading through pbackup..."
    FILES=$(echo "${FILES[@]}" | tr ' ' ',')
    pbackup --files "$FILES" --to "$FULL_REMOTE_DEST"

    # ======== CLEAN UP ========
    log.debug "Cleaning backupfile from local machine..."
    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        rm -f "$BACKUP_DIR/$BACKUP_FILE"
        log.trace "- '$BACKUP_DIR/$BACKUP_FILE' deleted."
    else
        log.error "ERROR: '$BACKUP_DIR/$BACKUP_FILE' was not found. We aren't going to perform any delete operation in order to avoid deleting other files. Location checked: \"$BACKUP_DIR/$BACKUP_FILE\""
    fi

    log.info "All done!"
    exit 0
}

main "$@"