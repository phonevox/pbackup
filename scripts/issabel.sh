#!/usr/bin/bash

# === CONSTANTS ===
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

_LOG_FILE="/var/log/pbackup.log"
_LOG_LEVEL=0
_LOG_ROTATE_PERIOD=7

BACKUP_DIR="/var/www/backup"
BACKUP_FILE="issabelbackup-$(date +%Y%m%d%H%M%S)-06.tar"

_REMOTE_FOLDER_CONFIGURATION="/configuration"
_REMOTE_FOLDER_RECORDINGS="/recordings"
UPLOAD_ONLY_MODE="false"

# === FLAGS ===
source "$(dirname "$CURRDIR")/lib/ezflags.sh"
source "$(dirname "$CURRDIR")/lib/uzful.sh"

add_flag "d" "dry" "Do NOT make changes" bool
add_flag "t" "remote" "Remote destination" string
add_flag "rec:HIDDEN" "recordings" "Backup recordings" bool
add_flag "config:HIDDEN" "configuration" "Backup configuration" bool
add_flag "s:HIDDEN" "token" "Upload-only token" string
add_flag "test:HIDDEN" "test" "Ignore exit" bool

# === passthrough flags for pbackup ===
add_flag "a" "autocompact" "Automatically compact directories (pbackup passthrough)" bool
add_flag "F" "flatten" "Flatten upload path (pbackup passthrough)" bool
add_flag "C" "split-size" "Split ZIP size (pbackup passthrough)" string


set_description "Issabel backup"
set_usage "sudo bash $FULL_SCRIPT_PATH --recordings --configuration -t <remote>"
parse_flags $@

log.debug "=== STARTING - ARGS: $*"

PBACKUP_CMD=(pbackup --files "$BACKUP_DIR/$BACKUP_FILE" --to "$(getFlag t)")

# === passthrough short flags ===
# bool short-flags: -a  -F
for SF in a F; do
    if hasFlag "$SF"; then
        PBACKUP_CMD+=("-$SF")
    fi
done

# string short-flag: -C <value>
if hasFlag C; then
    PBACKUP_CMD+=("--split-size" "$(getFlag C)")
fi

# string short-flag: -s <token>
if hasFlag s; then
    PBACKUP_CMD+=("--token" "$(getFlag s)")
fi




# ======================================================================

function parse_date() {
    local INPUT="$1"
    local DAYS_AGO="${_DAYS_AGO:-0}"

    declare -A DATE_FORMATS=(
        ["%DAY%"]="%d"
        ["%MONTH%"]="%m"
        ["%YEAR%"]="%Y"
        ["%HOUR%"]="%H"
        ["%MINUTE%"]="%M"
        ["%SECOND%"]="%S"
    )

    # Simple replacements
    for KEY in "${!DATE_FORMATS[@]}"; do
        if [[ "$INPUT" == *"$KEY"* ]]; then
            local D=$(date -d "-${DAYS_AGO} days" +"${DATE_FORMATS[$KEY]}")
            INPUT="${INPUT//$KEY/$D}"
        fi
    done

    # Patterns with -Nd
    while [[ "$INPUT" =~ %([A-Z]+)-([0-9]+)d% ]]; do
        local TYPE="${BASH_REMATCH[1]}"
        local NUM="${BASH_REMATCH[2]}"
        local TOTAL=$(( NUM + DAYS_AGO ))

        case "$TYPE" in
            DAY)   fmt="%d" ;;
            MONTH) fmt="%m" ;;
            YEAR)  fmt="%Y" ;;
            *) break ;;
        esac

        local VAL=$(date -d "-${TOTAL} days" +"$fmt")
        INPUT="${INPUT//%$TYPE-$NUMd%/$VAL}"
    done

    echo "$INPUT"
}

# ======================================================================

function cexit() {
    local CODE="$1"
    if ! hasFlag "test"; then
        exit "$CODE"
    fi
    echo "> exit $CODE (ignored by --test)"
}

# ======================================================================

function generate_backup_file() {
    local COMPONENTS="as_db,as_config_files,as_sounds,as_mohmp3,as_dahdi,fx_db,fx_pdf,ep_db,ep_config_files,callcenter_db,asternic_db,FOP2_settings_db,sugar_db,vtiger_db,a2billing_db,mysql_db,menus_permissions,calendar_db,address_db,conference_db,eop_db"

    if [ -f "/usr/share/issabel/privileged/pvx-backupengine-extras" ]; then
        COMPONENTS="$COMPONENTS,int_ixcsoft,int_sgp,int_receitanet,int_altarede"
    fi

    /usr/bin/issabel-helper backupengine --backup --backupfile "$BACKUP_FILE" --tmpdir "$BACKUP_DIR" --components $COMPONENTS

    if ! [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        log.fatal "Backup not generated!"
        cexit 1
    fi
}

# ======================================================================

UPLOAD_ONLY_MODE="false"
hasFlag "s" && UPLOAD_ONLY_MODE="true"

FILES=()   # REAL ARRAY FIXED

function validations() {
    local FULL_REMOTE_DEST
    FULL_REMOTE_DEST="$(getFlag t)"

    if [[ -z "$FULL_REMOTE_DEST" ]]; then
        log.fatal "Remote required"
        cexit 1
    fi

    if [[ "$UPLOAD_ONLY_MODE" == "false" ]]; then
        if ! [ -f "/usr/sbin/pbackup" ]; then
            log.fatal "pbackup missing"
            cexit 1
        fi

        local NAME="${FULL_REMOTE_DEST%%:*}"
        if ! pbackup --list | grep -q "^$NAME:"; then
            log.fatal "Remote '$NAME' not found"
            cexit 1
        fi
    fi

    if ! [ -f "/usr/bin/issabel-helper" ]; then
        log.fatal "Not an Issabel PBX"
        cexit 1
    fi
}

# ======================================================================

function main() {
    validations

    TMP_DIR=$(mktemp -d)

    # RECORDINGS ==================================
    if hasFlag "rec"; then
        for DAYS_BACK in 1 2 3; do
            _DAYS_AGO=$DAYS_BACK

            LOCAL_DIR=$(parse_date "/var/spool/asterisk/monitor/%YEAR%/%MONTH%/%DAY%")
            REMOTE_DIR=$(parse_date ":$_REMOTE_FOLDER_RECORDINGS/%YEAR%/%MONTH%/%DAY%")

            if [ -d "$LOCAL_DIR" ]; then
                ARCHIVE_FILE="$TMP_DIR/recordings-${_DAYS_AGO}d.tar.gz"
                tar -czf "$ARCHIVE_FILE" -C "$(dirname "$LOCAL_DIR")" "$(basename "$LOCAL_DIR")"

                FILES+=( "$ARCHIVE_FILE$REMOTE_DIR" )
            fi
        done
    fi

    # CONFIGURATION ================================
    if hasFlag "config"; then
        generate_backup_file
        FILES+=( "$BACKUP_DIR/$BACKUP_FILE:$_REMOTE_FOLDER_CONFIGURATION" )
    fi

    # UPLOAD =====================================
    CSV=$(printf "%s," "${FILES[@]}")
    CSV="${CSV%,}"

    # Log do comando FINAL completo
    log.info "Executing pbackup command:"
    printf "  %q" "${PBACKUP_CMD[@]}" --files "$CSV"
    echo

    # Execução real
    "${PBACKUP_CMD[@]}" --files "$CSV"

    # CLEANUP ====================================
    [ -f "$BACKUP_DIR/$BACKUP_FILE" ] && rm -f "$BACKUP_DIR/$BACKUP_FILE"
    rm -rf "$TMP_DIR"

    log.info "Done."
    cexit 0
}


main "$@"
