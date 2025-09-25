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
UPLOAD_ONLY_MODE="false"

# === FLAG GENERATION ===

# dirname so we access the directory "behind" us
source "$(dirname "$CURRDIR")/lib/ezflags.sh"
source "$(dirname "$CURRDIR")/lib/uzful.sh"

add_flag "d" "dry" "Do NOT make changes to the system" bool
add_flag "t" "remote" "Remote destination to upload to" string
add_flag "rec:HIDDEN" "recordings" "Backup recordings" bool
add_flag "config:HIDDEN" "configuration" "Backup configuration" bool
add_flag "s:HIDDEN" "token" "If you're using a remote thats not in rclone and it needs a JWT token, provide it here\nThis was created mainly for Phonevox's Upload-Only-API (UOA)" string
add_flag "test:HIDDEN" "test" "[!] test mode, ignore app exit attempts" bool

set_description "IssabelPBX Backup script for pbackup\nExample usage: sudo bash $FULL_SCRIPT_PATH --recordings --configuration -r 7 -t mega-bkp:/issabel-pbackup"
set_usage "sudo bash $FULL_SCRIPT_PATH [--recordings] [--configuration] [-r <days>] -t <remote> "
parse_flags $@

# === FUNCS ===

log.debug "=== STARTING - ARGUMENTS: $*" muted


function parse_date() {
    local INPUT="$1"
    local DAYS_AGO="${_DAYS_AGO:-0}"  # Se _DAYS_AGO não estiver definido, usa 0 dias atrás

    # Tratamento de substituições simples
    declare -A DATE_FORMATS=(
        ["%DAY%"]="%d"
        ["%MONTH%"]="%m"
        ["%YEAR%"]="%Y"
        ["%HOUR%"]="%H"
        ["%MINUTE%"]="%M"
        ["%SECOND%"]="%S"
    )

    for KEY in "${!DATE_FORMATS[@]}"; do
        if [[ "$INPUT" =~ $KEY ]]; then
            local NEW_DATE=$(date -d "-${DAYS_AGO} days" +"${DATE_FORMATS[$KEY]}")
            INPUT=${INPUT//$KEY/$NEW_DATE}
        fi
    done

    # Tratamento de %DAY-n%, %MONTH-n%, %YEAR-n%
    while [[ "$INPUT" =~ %([A-Z]+)-([0-9]+)d% ]]; do
        local TYPE="${BASH_REMATCH[1]}"  # DAY, MONTH ou YEAR
        local N_DAYS="${BASH_REMATCH[2]}"  # Quantidade de dias a subtrair

        local TOTAL_DAYS=$((N_DAYS + DAYS_AGO))
        local FORMAT=""

        case "$TYPE" in
            DAY)   FORMAT="%d" ;;
            MONTH) FORMAT="%m" ;;  # Subtrai dias, não meses
            YEAR)  FORMAT="%Y" ;;  # Subtrai dias, não anos
            *) continue ;;
        esac

        local NEW_DATE=$(date -d "-${TOTAL_DAYS} days" +"$FORMAT")
        INPUT=${INPUT//%$TYPE-${N_DAYS}d%/$NEW_DATE}
    done

    echo "$INPUT"
}

# custom exit para possibilitar continuar o script mesmo depois de um erro através da flag --test
function cexit() {
    local EXIT_CODE="$1"
    local COLOR="amarelo"
    if [ "$EXIT_CODE" -eq 0 ]; then
        COLOR="verde"
    fi

    if ! hasFlag "test"; then
        exit "$EXIT_CODE"
    else
        echo "$(colorir "$COLOR" "> exit $EXIT_CODE")"
        if [ "$EXIT_MESSAGE_SENT" != true ]; then
            echo "$(colorir "vermelho" "--- supposed to exit with code $EXIT_CODE, anything beyond is probably unexpected ---")"
            EXIT_MESSAGE_SENT=true
        fi
    fi
}

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
        cexit 1
    fi

    log.info "'$BACKUP_DIR/$BACKUP_FILE' generated, proceeding..."
}

function upload_via_curl() {
    local FILES_CSV="$1"
    local FULL_DEST="$2"

    log.debug "Preparing upload via curl..."
    log.debug "FILES: $FILES_CSV"
    log.debug "FULL_DEST: $FULL_DEST"

    # Extrai URL base (tudo antes do último ":") e path remoto (após o último ":")
    local CURL_URL="${FULL_DEST%%:*}"
    local CURL_URL_REMAINDER="${FULL_DEST#*:}"
    while [[ "$CURL_URL_REMAINDER" == *:* ]]; do
        CURL_URL="${FULL_DEST%:*}"
        CURL_URL_REMAINDER="${FULL_DEST##*:}"
        break
    done
    local REMOTE_PATH="$CURL_URL_REMAINDER"

    log.trace "CURL_URL: $CURL_URL"
    log.trace "REMOTE_PATH (will be passed as form field): $REMOTE_PATH"

    # Prepara cabeçalho de autorização se a flag -s estiver presente
    local CURL_AUTH_HEADER=()
    if hasFlag "s"; then
        local TOKEN="$(getFlag "s")"
        log.trace "Authorization token provided"
        CURL_AUTH_HEADER=(-H "Authorization: Bearer $TOKEN")
    else
        log.trace "No authorization token provided"
    fi

    IFS=',' read -ra FILES <<< "$FILES_CSV"
    log.debug "Parsed ${#FILES[@]} file(s) to upload"

    for FILE_ENTRY in "${FILES[@]}"; do
        # Separa parte local e remota (com base no ":")
        LOCAL_PATH="${FILE_ENTRY%%:*}"
        FILE_REMOTE_PATH="${FILE_ENTRY#*:}"

        log.trace "Processing file entry: $FILE_ENTRY"
        log.trace "  LOCAL_PATH: $LOCAL_PATH"
        log.trace "  FILE_REMOTE_PATH: $FILE_REMOTE_PATH"

        if [[ ! -f "$LOCAL_PATH" && ! -d "$LOCAL_PATH" ]]; then
            log.warn "Skipping '$LOCAL_PATH', file or directory not found"
            continue
        fi

        # Monta path final remoto = REMOTE_BASE_PATH + FILE_REMOTE_PATH
        # Remove possíveis barras duplicadas
        FULL_REMOTE_PATH="${REMOTE_PATH%/}/${FILE_REMOTE_PATH#/}"
        log.trace "  FULL_REMOTE_PATH (final path field): $FULL_REMOTE_PATH"

        log.info "Uploading '$LOCAL_PATH' to '$CURL_URL' with remote path '$FULL_REMOTE_PATH'"

        RESPONSE_BODY=$(mktemp)
        HTTP_STATUS=$(curl -s -w "%{http_code}" -o "$RESPONSE_BODY" -X POST "$CURL_URL" \
            "${CURL_AUTH_HEADER[@]}" \
            -F "file=@$LOCAL_PATH" \
            -F "path=$FULL_REMOTE_PATH")

        if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
            log.info "Successfully uploaded '$LOCAL_PATH' (HTTP $HTTP_STATUS)"
        else
            log.error "Failed to upload '$LOCAL_PATH' (HTTP $HTTP_STATUS)"
            log.error "Response body:"
            cat "$RESPONSE_BODY" >&2
        fi

        rm -f "$RESPONSE_BODY"
    done
}

# === RUNTIME ===
hasFlag "s" && UPLOAD_ONLY_MODE="true"

function validations () {
    FULL_REMOTE_DEST="$(getFlag "t")"

    REMOTE_PREFIX="${FULL_REMOTE_DEST%%:*}" # FIXME: possivel falha: https:/teste.txt # não vou corrigir, quem é o gênio que nomeia um remote como "http" ou "https"
    if [[ "$REMOTE_PREFIX" =~ ^(http|https) ]]; then
        UPLOAD_ONLY_MODE="true"
    fi

    # if not first argument, quit 
    log.trace "Checking for required arguments..."
    if  [ -z "$FULL_REMOTE_DEST" ]; then
        log.fatal "ERROR: You need to provide a valid remote destination! Example: -t \"mega:/backup\""
        cexit 1
    fi

    # we are using rclone
    if [ "$UPLOAD_ONLY_MODE" != "true" ]; then

        # test if usr/sbin/pbackup exists
        log.trace "Checking if pbackup is installed..."
        if ! [ -f "/usr/sbin/pbackup" ] && [ "$UPLOAD_ONLY_MODE" != "true" ]; then
            log.fatal "ERROR: You need to install pbackup! Exiting..."
            cexit 1
        fi

        # check if remote exists
        log.trace "Checking if remote exists..."
        REMOTE_NAME="$(echo $FULL_REMOTE_DEST | cut -d ':' -f 1)"
        if ! pbackup --list | grep -q "^$REMOTE_NAME:"; then
            log.fatal "ERROR: Remote $REMOTE_NAME not found! Exiting..."
            cexit 1
        fi

    fi

    # checking for issabelhelper, to generate the backups. if this is not present this may not be an issabel server
    log.trace "Checking for issabel-helper to handle backup generation..."
    if ! [ -f "/usr/bin/issabel-helper" ]; then
        log.fatal "ERROR: '/usr/bin/issabel-helper' not found. Is this really an IssabelPBX?"
        cexit 1
    fi
}

function main () {
    validations

    TMP_DIR=$(mktemp -d)
    log.debug "Temporary directory created at $TMP_DIR"

    # ======== SHOULD SAVE RECORDINGS ========
    if hasFlag "rec"; then
        RECORDINGS_LOCAL=$(parse_date "/var/spool/asterisk/monitor/%YEAR-1d%/%MONTH-1d%/%DAY-1d%")
        RECORDINGS_REMOTE=$(parse_date ":$_REMOTE_FOLDER_RECORDINGS/%YEAR-1d%/%MONTH-1d%")

        # Extrai ano/mes/dia do path
        YEAR=$(basename "$(dirname "$(dirname "$RECORDINGS_LOCAL")")")
        MONTH=$(basename "$(dirname "$RECORDINGS_LOCAL")")
        DAY=$(basename "$RECORDINGS_LOCAL")

        ARCHIVE_FILE="$TMP_DIR/$DAY.tar.gz"

        if [ -d "$RECORDINGS_LOCAL" ]; then
            log.debug "Compressing recordings from $RECORDINGS_LOCAL ..."
            tar -czf "$ARCHIVE_FILE" -C "$(dirname "$RECORDINGS_LOCAL")" "$(basename "$RECORDINGS_LOCAL")"
        else
            log.warn "No recordings directory found at $RECORDINGS_LOCAL"
        fi

        RECORDINGS_DESTINATION="$ARCHIVE_FILE$RECORDINGS_REMOTE"
        FILES+=("$RECORDINGS_DESTINATION")

        log.trace "--- RECORDINGS ---"
        log.trace "FILES: $FILES"
        log.trace "RECORDINGS_LOCAL: $RECORDINGS_LOCAL"
        log.trace "ARCHIVE_FILE: $ARCHIVE_FILE"
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
    log.debug "Uploading files to remote..."

    log.test "UPLOAD_ONLY_MODE $UPLOAD_ONLY_MODE"

    FILES=$(echo "${FILES[@]}" | tr ' ' ',')
    if [ "$UPLOAD_ONLY_MODE" != "true" ]; then
        log.trace ": Using pbackup for upload..."
        pbackup --files "$FILES" --to "$FULL_REMOTE_DEST"
    elif [ "$UPLOAD_ONLY_MODE" = "true" ]; then
        log.trace ": Uploading through curl..."
        upload_via_curl "$FILES" "$FULL_REMOTE_DEST"
    else # eu sei que isso é redundante, mas vou manter aqui pra caso haja a possibilidade da gente fazer outro elif
        log.fatal "Unexpected error: UPLOAD_ONLY_MODE $UPLOAD_ONLY_MODE"
    fi


    # ======== CLEAN UP ========
    log.debug "Cleaning up..."

    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
        rm -f "$BACKUP_DIR/$BACKUP_FILE"
        log.trace "- '$BACKUP_DIR/$BACKUP_FILE' deleted."
    else
        log.error "Backup file '$BACKUP_DIR/$BACKUP_FILE' was not found. Skipping delete."
    fi

    if [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
        log.trace "- Temporary directory '$TMP_DIR' deleted."
    fi

    log.info "All done!"
    cexit 0
}

main "$@"