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

# Magnus Backup
FILES=""

# other things
UPLOAD_ONLY_MODE="false"

# === FLAG GENERATION ===

# dirname so we access the directory "behind" us
source "$(dirname "$CURRDIR")/lib/ezflags.sh"
source "$(dirname "$CURRDIR")/lib/uzful.sh"

add_flag "d" "dry" "Do NOT make changes to the system" bool
add_flag "t" "remote" "Remote destination to upload to" string
add_flag "s:HIDDEN" "token" "If you're using a remote thats not in rclone and it needs a JWT token, provide it here\nThis was created mainly for Phonevox's Upload-Only-API (UOA)" string


add_flag "test:HIDDEN" "test" "[!] test mode, ignore app exit attempts" bool

set_description "MagnusBilling Backup script for pbackup\nExample usage: sudo bash $FULL_SCRIPT_PATH -t mega-bkp:/issabel-pbackup (remote example)\n or sudo bash $FULL_SCRIPT_PATH -t http://uoe.server.url/v1/upload:/ --token eyJhb...xx (uoe example)"
set_usage "sudo bash $FULL_SCRIPT_PATH -t <remote> "
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

}

function main () {
    validations

    # TMP_DIR=$(mktemp -d)
    # log.debug "Temporary directory created at $TMP_DIR"

    FILES_TO_UPLOAD=()
    GET_RECORDINGS="true"
    GET_SOUND_FILES="true"
    TODAY=$(date '+%d-%m-%Y')
    YESTERDAY=$(date -d "yesterday" '+%d-%m-%Y')

    # - Firstly, we need one backup file. Yesterday prefferably, but if it does not exist, make a new one.
    # If something goes wrong, stop.
    YESTERDAY_BACKUP_FILE=/usr/local/src/magnus/backup/backup_voip_softswitch.$YESTERDAY.tgz
    log.debug "Looking for yesterday's backup file... ($YESTERDAY_BACKUP_FILE)"
    if ! [ -f $YESTERDAY_BACKUP_FILE ]; then
        log.warn "WARN: Could not locate yesterday's backup file! Trying to make today's backup..."
        
        # make backup
        if ! [ -f /var/www/html/mbilling/cron.php ]; then
            log.fatal "ERROR: Could not locate mbilling cron.php! Is this really a mbilling server? Exiting... (/var/www/html/mbilling/cron.php)"
            exit 1
        fi
        php /var/www/html/mbilling/cron.php Backup

        TODAY_BACKUP_FILE=/usr/local/src/magnus/backup/backup_voip_softswitch.$TODAY.tgz
        if ! [ -f $TODAY_BACKUP_FILE ]; then
            log.fatal "ERROR: Failed to generate today's backup file! Exiting... ($TODAY_BACKUP_FILE)"
            log.fatal "failed: $TODAY_BACKUP_FILE"
            exit 1
        fi 

        log.debug "SUCCESS: Today's backup file generated! ($TODAY_BACKUP_FILE)"
        FILES_TO_UPLOAD+=($TODAY_BACKUP_FILE:/configuration/backup_voip_softswitch.$TODAY.tgz)
    else
        log.debug "Yesterday's backup file found! Using it..."
        FILES_TO_UPLOAD+=($YESTERDAY_BACKUP_FILE:/configuration/backup_voip_softswitch.$YESTERDAY.tgz)
    fi

    # - Now, get extra files
    if $GET_RECORDINGS; then
        log.info "Compacting recordings..."
        tar -czf /tmp/recordings.$TODAY.tgz /var/spool/asterisk/monitor
        FILES_TO_UPLOAD+=("/tmp/recordings.$TODAY.tgz:/recordings/recordings.$TODAY.tgz")
    fi
    if $GET_SOUND_FILES; then
        log.info "Compacting sound files..."
        tar -czf /tmp/soundfiles.$TODAY.tgz /usr/local/src/magnus/sounds
        FILES_TO_UPLOAD+=("/tmp/soundfiles.$TODAY.tgz:/soundfiles/soundfiles.$TODAY.tgz")
    fi

    # add everything that is not the backup_voip_softswitch file to the clean list
    # so we remember to delete it after uploading
    FILES_TO_CLEAN=()
    for FILE in ${FILES_TO_UPLOAD[@]}; do
        if ! [[ "$FILE" == *"backup_voip_softswitch"* ]]; then

            if [[ "$FILE" == *:* ]]; then
                FILE="${FILE%%:*}" # remove remote part if exists
            fi
            FILES_TO_CLEAN+=("$FILE")
        fi
    done

    # convert files to upload into pbackup format (File1,F2,F3,F4[...])
    read -a FILES <<< $(echo ${FILES_TO_UPLOAD[@]} | tr ' ' ',')

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
    for FILE in ${FILES_TO_CLEAN[@]}; do
        log.trace "- Deleting $FILE"
        rm -f $FILE
    done

    log.info "All done!"
    cexit 0
}

main "$@"