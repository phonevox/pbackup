#!/usr/bin/bash

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
LOG_FILE_PATH="/var/log"
[ -w "$LOG_FILE_PATH" ] || LOG_FILE_PATH="$(dirname "$CURRDIR")" # if not writable, use current directory
LOG_FILE_NAME="pbackup.log"
LOG_FILE="$LOG_FILE_PATH/$LOG_FILE_NAME-$(date '+%Y-%m-%d').log"

# Issabel Backup
BACKUP_DIR="/var/www/backup" # Padrão
BACKUP_FILE="issabelbackup-$(date +%Y%m%d%H%M%S)-06.tar" # Não mude isso. É necessário pra poder upar o backup depois.

# other things
ROTATE=false # this will be either false or a number
declare -ga ROTATED_FILES
ROTATED_FILES=()
_REMOTE_FOLDER_CONFIGURATION="/configuration"
_REMOTE_FOLDER_RECORDINGS="/recordings"

# === FLAG GENERATION ===

# dirname so we access the directory "behind" us
source "$(dirname "$CURRDIR")/lib/ezflags.sh"
source "$(dirname "$CURRDIR")/lib/uzful.sh"

add_flag "d" "dry" "Do NOT make changes to the system" bool
add_flag "r" "rotate" "How many days should we keep in remote before removing older ones" int
add_flag "t" "remote" "Remote destination to upload to" string
add_flag "rec:HIDDEN" "recordings" "Backup recordings" bool
add_flag "config:HIDDEN" "configuration" "Backup configuration" bool

set_description "IssabelPBX Backup script for pbackup\nExample usage: sudo bash $FULL_SCRIPT_PATH -r -c -rt 7 -t mega-bkp:/issabel-pbackup"
set_usage "sudo bash $FULL_SCRIPT_PATH [-r] [-c] [-rt <days>] -t <remote> "
parse_flags $@

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
    FULL_REMOTE_DEST="$(getFlag "t")"

    # if not first argument, quit 
    log "Checking for required arguments..."
    if  [ -z "$FULL_REMOTE_DEST" ]; then
        log "ERROR: You need to provide an rclone remote destination! Example: -t \"mega:/backup\""
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

function execute_rotate () {
    log "Rotating via scanline/pinpoint for $ROTATE days..."
    hasFlag "rec" && rotate_recordings
    hasFlag "config" && rotate_configuration
    log "The rotated files are: $(echo ${ROTATED_FILES[@]})"

    for ROTATED_FILE in "${ROTATED_FILES[@]}"; do
        log "Removing $ROTATED_FILE"
        pbackup --delete "$ROTATED_FILE"

        # TODO(adrian): purge empty folders. only really needed for recordings
    done
}

function rotate_recordings () {
    log "Rotating recordings..."
    local REMOTE="$FULL_REMOTE_DEST$_REMOTE_FOLDER_RECORDINGS"

    # i dont know why you would rotate recordings, but okay, ill make it somewhat compatible
    # think of this as "scan lines", it will just search the folder X days ago and delete. it wont really check everything older than that.
    # its just a "scan line". if you keep changing your rotate a lot, this will lead to a weird pattern in your folder so i advise
    # you dont change your rotate a lot.

    local YEAR=$(date -d "$ROTATE days ago" +%Y)
    local MONTH=$(date -d "$ROTATE days ago" +%m)
    local DAY=$(date -d "$ROTATE days ago" +%d)
    local HIT="$REMOTE/$YEAR/$MONTH/$DAY"

    log "rotate_recordings: SCANLINE TARGET: remote_folder '$HIT' "
    if rclone lsf "$HIT" > /dev/null; then # if the command fails, the folder does not exist
        log "rotate_recordings: scanline hit: $HIT"
        ROTATED_FILES+=("$HIT")
    else
        log "rotate_recordings: scanline miss: $HIT"
    fi
}

function rotate_configuration () {
    log "Rotating configuration..."
    local REMOTE="$FULL_REMOTE_DEST$_REMOTE_FOLDER_CONFIGURATION"
    local TARGET="issabelbackup"
    local TARGET_DATE=$(date -d "$ROTATE days ago" +%Y-%m-%d)

    log "rotate_configuration: SCANLINE TARGET: date '$TARGET_DATE' | target '$TARGET' | remote '$REMOTE' "
    while read -r __SIZE __DATE __TIME __FILE; do
        if [[ "$__DATE" == "$TARGET_DATE" ]] && [[ "$__FILE" == *"$TARGET"* ]]; then
            log "rotate_configuration: scanline hit: $__SIZE $__DATE $__TIME $__FILE"
            ROTATED_FILES+=("$REMOTE/$__FILE")
        else
            log "rotate_configuration: scanline miss: $__SIZE $__DATE $__TIME $__FILE"
        fi
    done < <(rclone lsl "$REMOTE")
}

function main () {
    validations

    if hasFlag "r"; then
        ROTATE="$(getFlag "r")"
    fi

    # ======== SHOULD SAVE RECORDINGS ========
    if hasFlag "rec"; then
        RECORDINGS_LOCAL="/var/spool/asterisk/monitor/%YEAR-1d%/%MONTH-1d%/%DAY-1d%" # where is the file right now
        RECORDINGS_REMOTE=":$_REMOTE_FOLDER_RECORDINGS/%YEAR-1d%/%MONTH-1d%" # where will we save them on the remote
        RECORDINGS_DESTINATION="$RECORDINGS_LOCAL$RECORDINGS_REMOTE"
        FILES+=("$RECORDINGS_DESTINATION")
    fi

    # ========= SHOULD SAVE CONFIGURATION ========
    if hasFlag "config"; then
        CONFIGURATION_LOCAL="$BACKUP_DIR/$BACKUP_FILE" # where is the file right now
        CONFIGURATION_REMOTE=":$_REMOTE_FOLDER_CONFIGURATION" # where will we save them on the remote
        CONFIGURATION_DESTINATION="$CONFIGURATION_LOCAL$CONFIGURATION_REMOTE"
        FILES+=("$CONFIGURATION_DESTINATION")
        # generate_backup_file
        echo "-> generate_backup_file"
    fi

    # ======== UPLOAD ========
    log "Uploading through pbackup..."
    FILES=$(echo "${FILES[@]}" | tr ' ' ',')
    pbackup --files "$FILES" --to "$FULL_REMOTE_DEST"

    # ======== CLEAN UP ========
    log "Cleaning backupfile from local machine..."
    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        rm -f "$BACKUP_DIR/$BACKUP_FILE"
        log "- '$BACKUP_DIR/$BACKUP_FILE' deleted."
    else
        log "ERROR: '$BACKUP_DIR/$BACKUP_FILE' was not found. We aren't going to perform any delete operation in order to avoid deleting other files. Location checked: \"$BACKUP_DIR/$BACKUP_FILE\""
    fi

    # ======== ROTATE ========
    [[ "$ROTATE" != "false" ]] && execute_rotate

    log "All done!"
    exit 0
}

main "$@"