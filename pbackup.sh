#!/usr/bin/bash

# Author : Adrian K. (https://github.com/adriankubinyete)
# Co-author, assistance : Rafael R. (https://github.com/rafaelRizzo) 
# Organization : Phonevox (https://github.com/phonevox)

# === CONSTANTS ===

# General script constants
FULL_SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
CURRDIR="$(dirname "$FULL_SCRIPT_PATH")"
SCRIPT_NAME="$(basename "$FULL_SCRIPT_PATH")"

# Logging
_LOG_FILE="/var/log/pbackup.log"
_LOG_LEVEL=3 # 0:test, 1:trace, 2:debug, 3:info, 4:warn, 5:error, 6:fatal
_LOG_ROTATE_PERIOD=7

# Versioning 
REPO_OWNER="phonevox"
REPO_NAME="pbackup"
REPO_URL="https://github.com/$REPO_OWNER/$REPO_NAME"
ZIP_URL="$REPO_URL/archive/refs/heads/main.zip"
APP_VERSION="v$(grep '"version"' $CURRDIR/lib/version.json | sed -E 's/.*"version": *"([^"]+)".*/\1/')"

UPLOAD_ONLY_MODE="false"  # New: for HTTP remotes

# === FLAG GENERATION ===
source "$CURRDIR/lib/ezflags.sh"
source "$CURRDIR/lib/uzful.sh"

# General flags (existing)
add_flag "d" "dry" "Do NOT make changes to the system" bool
add_flag "V" "verbose" "Prints more information about the script's progress" bool
add_flag "VV" "very-verbose" "Prints even more information about the script's progress" bool
# Script flags (existing)
add_flag "cf" "conf-file" "Path to a file containing multiple paths to upload. One path per line.\n- The paths can be formatted as \"<local>[:<remote>]\". If '-t|--to' destination is provided, \"[:<remote>]\" will be suffixed to the \"-t|--to\" flag's value.\n- Example: -t \"mega:/folder\" on \"./hello.txt:/test\" will be saved to \"mega:/folder/test/hello.txt\"" string
add_flag "f" "files" "Path(s) to file(s) or folder(s) to be uploaded to remote. Separate multiple files by comma (,)\n- The paths can be formatted as \"<local>[:<remote>]\". If '-t|--to' destination is provided, \"[:<remote>]\" will be suffixed to the \"-t|--to\" flag's value.\n- Example: -t \"mega:/folder\" on \"./cheese.txt:/test\" will be saved to \"mega:/folder/test/cheese.txt\"" string
add_flag "t" "to" "rclone's remote name or HTTP URL. Optionally can also set to where, on the remote, your files will be moved to.\n- Example: -t|--to \"<remote_name>[:<path>]\" or \"http://example.com/upload:/basepath\"" string
add_flag "config:HIDDEN" "config" "Alias for \"rclone config\"" bool
add_flag "delete:HIDDEN" "delete" "Alias for \"rclone delete\"" string
add_flag "purge:HIDDEN" "purge" "Alias for \"rclone purge\"" string
add_flag "nfs:HIDDEN" "no-failsafe" "Run unsafe commands, even if they trigger a failsafe mechanism." bool
add_flag "list:HIDDEN" "list" "Alias for \"rclone listremotes\"" bool
add_flag "install:HIDDEN" "install" "Install this script to your path, so you can call it from anywhere with '$(echo $SCRIPT_NAME | cut -d '.' -f 1) <flags>'" bool

add_flag "y:HIDDEN" "yesterday" "Alias for \"--days-ago 1\"" bool
add_flag "da" "days-ago" "If there is any %YEAR%, %MONTH% or %DAY% variables in paths, how many days to subtract from them. Defaults to 0\n- Do note that if you use %DAY-<n>d% together with \"--days-ago <x>\", the amount subtracted will be summed (in this case, %DAY-<n+x>d%).\n- If n and x were both 1, this would result in 2 days ago result for %DAY% conversion." string

add_flag "v" "version" "Show app version and exit" bool
add_flag "upd:HIDDEN" "update" "Update this script to the newest version" bool
add_flag "fu:HIDDEN" "force-update" "Force the update even if its in the same version" bool

# Integrated flags from uoe-upload
add_flag "s:HIDDEN" "token" "If you're using a remote thats not in rclone and it needs a JWT token, provide it here\nThis was created mainly for Phonevox's Upload-Only-API (UOA)" string
add_flag "a" "autocompact" "Automatically compact directories into tar.gz before upload if needed" bool
add_flag "F" "flatten" "Upload to remote root using only basename (ignores local paths when no :remote_path is specified)" bool
add_flag "C" "split-size" "Split compacted directories into multiple ZIP files of the given size (e.g. 250M, 1G, 500K)" string
add_flag "test:HIDDEN" "test" "[!] test mode, ignore app exit attempts" bool

# === GENERATING ===
set_description "Phonevox's rclone abstraction for backups on cloud remotes, now with uoe-upload integration (HTTP uploads, autocompact, flatten, split-zip).\nYou need to configure remotes on rclone manually (through 'rclone config').\nWhen defining paths, you can use the following variables:\n- %YEAR%: The current year\n- %MONTH%: The current month\n- %DAY%: The current day\n- %YEAR-<n>d%: The year n days ago\n- %MONTH-<n>d%: The month n days ago\n- %DAY-<n>d%: The day n days ago"
set_usage "sudo bash $FULL_SCRIPT_PATH --files \"<path_one[:<remote_p1>]>[,<path_two[:<remote_p2>]>]\" --to \"<remote_name>[:<remote_path>]\" [--autocompact] [--flatten] [--split-size <size>] [--token <jwt>]"
parse_flags $@

# === POST-PARSE VARIABLES ===

_DEBUG="false"
_VDEBUG="false"
_FAILSAFE="true"
_DAYS_AGO=0 # today
hasFlag "y" && _DAYS_AGO=1
hasFlag "da" && _DAYS_AGO=$(getFlag "da")
hasFlag "V" && _LOG_LEVEL=2
hasFlag "VV" && _LOG_LEVEL=0
hasFlag "nfs" && _FAILSAFE="false"

# Integrated: Detect HTTP mode
FULL_REMOTE_DEST="$(getFlag "t")"
REMOTE_PREFIX="${FULL_REMOTE_DEST%%:*}"
if [[ "$REMOTE_PREFIX" =~ ^(http|https) ]]; then
    UPLOAD_ONLY_MODE="true"
    hasFlag "s" && log.info "HTTP mode detected: Token provided for auth."
fi

# === UTILITARY FUNCTIONS === (existing + integrated)

log.debug "=== STARTING - ARGUMENTS: $* ===" muted

# Integrated: custom exit para test mode
EXIT_MESSAGE_SENT=false
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

# Integrated: cleanup
function cleanup() {
    log.debug "Interrupt received - Cleaning up temporary directory..."
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
        log.trace "- Temporary directory '$TMP_DIR' deleted."
    fi
    log.info "Cleanup done. Exiting."
    exit 130
}

# "safe-run", abstraction to "run" function, so it can work with our dry mode
# Usage: same as run
function srun() {
    local CMD=$1
    local ACCEPTABLE_EXIT_CODES=$2

    run "$CMD >/dev/null" "$ACCEPTABLE_EXIT_CODES" "$_DRY" "$_SILENT"
}

# rpm_is_installed "<rpm_name>"
function rpm_is_installed() {
    local RES=$(rpm -qa | grep -i $1)
    if [[ "$RES" = "" ]]; then
        return 1
    else
        return 0
    fi
}

# Integrated: check_disk_space
function check_disk_space() {
    local DIR_PATH="$1"
    local TMP_DIR="$2"

    # Get directory size in bytes
    local DIR_SIZE=$(du -sb "$DIR_PATH" | cut -f1)
    log.trace "Directory size: $DIR_SIZE bytes" >&2

    # Get available space in TMP_DIR filesystem in bytes
    local AVAILABLE_SPACE=$(df -B1 "$TMP_DIR" | tail -1 | awk '{print $4}')
    log.trace "Available space: $AVAILABLE_SPACE bytes" >&2

    # Check if available space is at least 110% of dir size (buffer for overhead)
    if [ $((AVAILABLE_SPACE)) -lt $((DIR_SIZE * 11 / 10)) ]; then
        log.fatal "ERROR: Insufficient disk space to compact '$DIR_PATH'. Need at least ~$((DIR_SIZE * 11 / 10 / 1024 / 1024)) MB, but only $((AVAILABLE_SPACE / 1024 / 1024)) MB available." >&2
        cexit 1
    fi

    log.info "Disk space check passed for '$DIR_PATH'." >&2
}

# Integrated: compact_directory (tar.gz)
function compact_directory() {
    local LOCAL_PATH="$1"
    local TMP_DIR="$2"
    local BASENAME=$(basename "$LOCAL_PATH")

    # Create tar.gz in TMP_DIR
    local TAR_FILE="$TMP_DIR/${BASENAME}.tar.gz"
    log.debug "Compacting directory '$LOCAL_PATH' to '$TAR_FILE'..." >&2

    check_disk_space "$LOCAL_PATH" "$TMP_DIR"

    if ! tar -czf "$TAR_FILE" -C "$(dirname "$LOCAL_PATH")" "$(basename "$LOCAL_PATH")"; then
        log.fatal "ERROR: Failed to compact directory '$LOCAL_PATH'." >&2
        cexit 1
    fi

    log.info "Directory compacted successfully to '$TAR_FILE'." >&2

    # Return the tar file path to stdout only
    echo "$TAR_FILE"
}

# Integrated: compact_directory_zip (split) - adapted to return all parts including .zip
function compact_directory_zip() {
    local LOCAL_PATH="$1"
    local TMP_DIR="$2"
    local SPLIT_SIZE="$3"
    local BASENAME=$(basename "$LOCAL_PATH")
    local ZIP_BASE="$TMP_DIR/${BASENAME}.zip"

    log.debug "Compacting directory '$LOCAL_PATH' into split ZIPs at '$ZIP_BASE' (size per part: $SPLIT_SIZE)" >&2
    check_disk_space "$LOCAL_PATH" "$TMP_DIR"

    pushd "$(dirname "$LOCAL_PATH")" >/dev/null || {
        log.fatal "Failed to enter directory for compression." >&2
        cexit 1
    }

    log.info "Compacting directory '$LOCAL_PATH' into split ZIPs at '$ZIP_BASE' (size per part: $SPLIT_SIZE, total size: $(du -sh "$LOCAL_PATH"))" >&2

    # todo output do zip vai para stderr
    if ! zip -r -s "$SPLIT_SIZE" "$ZIP_BASE" "$(basename "$LOCAL_PATH")" >&2; then
        popd >/dev/null
        log.fatal "ERROR: Failed to compact directory '$LOCAL_PATH' with split size." >&2
        cexit 1
    fi

    popd >/dev/null
    log.info "Directory compacted successfully into ZIP parts at '$TMP_DIR'" >&2

    # retorna todos os arquivos gerados, incluindo .zip
    ls "$TMP_DIR/${BASENAME}.z"* "$TMP_DIR/${BASENAME}.zip" 2>/dev/null | sort
}

# Integrated: upload_via_curl (for HTTP)
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

# ==============================================================================================================
# SCRIPT MANAGEMENT, BINARY (existing - unchanged)
function add_script_to_path() {
    local _BIN_NAME="$(echo $SCRIPT_NAME | cut -d '.' -f 1)"
    local _PATHS=("/usr/sbin/$_BIN_NAME" "/usr/bin/$_BIN_NAME")
    local _PATH_SCRIPT_BINARY="$FULL_SCRIPT_PATH"

    for _PATH in "${_PATHS[@]}"; do
        local _CURRENT_SYMLINK_PATH=$(readlink -f "$_PATH") # where the current symlink is pointing towards
        if [[ -f "$_CURRENT_SYMLINK_PATH" ]]; then 
            _SYMLINK_FILE_EXISTS=true
        else 
            _SYMLINK_FILE_EXISTS=false
        fi # does the file which the symlink is pointing towards exist?

        echo "- $(colorir "azul" "Trying to add '$FULL_SCRIPT_PATH' to path '$_PATH'")"
        if [[ "$_CURRENT_SYMLINK_PATH" == "$_PATH_SCRIPT_BINARY" ]]; then
            # symlink is pointing towards this script.
            echo "- $(colorir verde "Your symlink ($_PATH) is set up correctly: $_PATH")"
        else
            if $_SYMLINK_FILE_EXISTS; then # symlink is pointing towards something else
                echo "- $(colorir amarelo "Your symlink ($_PATH) is pointing to something else: $_CURRENT_SYMLINK_PATH (expected $FULL_SCRIPT_PATH)")"
                echo "> Do you want to update it? ($(colorir verde y)/$(colorir vermelho n))"
                read -r _answer
                if ! [[ "$_answer" == "y" ]]; then
                    echo "Skipping $_PATH..."
                    continue
                fi
            fi

            # symlink does not exist, and user is fine with it being created
            echo "- $(colorir verde "Adding to path... ('$_PATH' -> '$_PATH_SCRIPT_BINARY')")"
            srun "ln -sf \"$_PATH_SCRIPT_BINARY\" \"$_PATH\""
        fi
    done

    exit 0
}

# ==============================================================================================================
# VERSION CONTROL, UPDATES (existing - unchanged)
function check_for_updates() {
    local FORCE_UPDATE="false"; if [[ -n "$1" ]]; then FORCE_UPDATE="true"; fi
    local CURRENT_VERSION=$APP_VERSION
    local LATEST_VERSION="$(curl -s https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/tags | grep '"name":' | head -n 1 | sed 's/.*"name": "\(.*\)",/\1/')"

    # its the same version
    if ! version_is_greater "$LATEST_VERSION" "$CURRENT_VERSION"; then
        echo "$(colorir verde "You are using the latest version. ($CURRENT_VERSION)")"
        if ! $FORCE_UPDATE; then exit 1; fi
    else
        echo "You are not using the latest version. (CURRENT: '$CURRENT_VERSION', LATEST: '$LATEST_VERSION')"
    fi

    echo "Do you want to download the latest version from source? ($(colorir azul "$CURRENT_VERSION") -> $(colorir azul "$LATEST_VERSION")) ($(colorir verde y)/$(colorir vermelho n))"
    read -r _answer 
    if ! [[ "$_answer" == "y" ]]; then
        echo "Exiting..."
        exit 1
    fi
    update_all_files
    exit 0
}

# needs curl and unzip installed
function update_all_files() {
    local INSTALL_DIR=$CURRDIR
    local REPO_NAME=$REPO_NAME
    local ZIP_URL=$ZIP_URL

    echo "- Creating temp dir"
    tmp_dir=$(mktemp -d) # NOTE(adrian): this is not dry-able. dry will actually make change in the system just as this tmp folder.
    
    echo "- Downloading repository zip to '$tmp_dir/repo.zip'"
    srun "curl -L \"$ZIP_URL\" -o \"$tmp_dir/repo.zip\""

    echo "- Unzipping '$tmp_dir/repo.zip' to '$tmp_dir'"
    srun "unzip -qo \"$tmp_dir/repo.zip\" -d \"$tmp_dir\""

    echo "- Copying files from '$tmp_dir/$REPO_NAME-main' to '$INSTALL_DIR'"
    srun "cp -r \"$tmp_dir/$REPO_NAME-main/\"* \"$INSTALL_DIR/\""
    
    echo "- Updating permissions on '$INSTALL_DIR'"
    srun "find \"$INSTALL_DIR\" -type f -name \"*.sh\" -exec chmod +x {} \;"

    # cleaning
    echo "- Cleaning up"
    srun "rm -rf \"$tmp_dir\""
    echo "--- UPDATE FINISHED ---"
}


function version_is_greater() {
    # ignore metadata
    ver1=$(echo "$1" | grep -oE '^[vV]?[0-9]+\.[0-9]+\.[0-9]+')
    ver2=$(echo "$2" | grep -oE '^[vV]?[0-9]+\.[0-9]+\.[0-9]+')
    
    # remove "v" prefix
    ver1="${ver1#v}"
    ver2="${ver2#v}"

    # gets major, minor and patch
    IFS='.' read -r major1 minor1 patch1 <<< "$ver1"
    IFS='.' read -r major2 minor2 patch2 <<< "$ver2"

    # compares major, then minor, then patch
    if (( major1 > major2 )); then
        return 0
    elif (( major1 < major2 )); then
        return 1
    elif (( minor1 > minor2 )); then
        return 0
    elif (( minor1 < minor2 )); then
        return 1
    elif (( patch1 > patch2 )); then
        return 0
    else
        return 1
    fi
}

# Existing: rclone_copy (unchanged, but now conditional)
function rclone_copy() {
    local SOURCE="$1"
    local DESTINATION="$2"
    local MAX_RETRIES=3  # max retries
    local RETRY_DELAY=30 # seconds before retrying

    # Definir o comando Rclone com as flags desejadas
    local DEBUG_FLAG="--ignore-times"
    local RCLONE_CMD="rclone copy $SOURCE $DESTINATION $DEBUG_FLAG --transfers=8 --checkers=16 --buffer-size=64M --multi-thread-streams=4 --retries=5 --low-level-retries=10 --fast-list --progress"

    if hasFlag "d"; then
        log.test "$(colorir "amarelo" "[DRY]") $RCLONE_CMD"
        return
    fi

    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        log.info "$(colorir "azul" "Attempt $attempt of $MAX_RETRIES: Copying $SOURCE -> $DESTINATION")"


        $RCLONE_CMD 2>&1 | while IFS= read -r line; do log "(rclone) $line"; done
        local RCLONE_EXITCODE=${PIPESTATUS[0]}
        log "$(colorir "magenta" "<!> Exit code: $RCLONE_EXITCODE <!>")"

        if [ $RCLONE_EXITCODE -eq 0 ]; then
            log.info "$(colorir "verde" "Upload successful: $SOURCE -> $DESTINATION (Attempt $attempt/$MAX_RETRIES) (Exit code: $RCLONE_EXITCODE)")"
            return 0
        else
            log.info "$(colorir "amarelo" "Upload failed: $SOURCE -> $DESTINATION (Attempt $attempt/$MAX_RETRIES) (Exit code: $RCLONE_EXITCODE)")"
            if [ $attempt -lt $MAX_RETRIES ]; then
                log.info "$(colorir "amarelo" "Waiting $RETRY_DELAY seconds before reattempting...")"
                sleep $RETRY_DELAY
            fi
        fi

        ((attempt++))
    done

    log.error "$(colorir "vermelho" "ERROR: All $MAX_RETRIES failed for: $SOURCE -> $DESTINATION")"
    echo "$(date +"%Y-%m-%d %H:%M:%S") - ERROR : All $MAX_RETRIES failed for: $SOURCE -> $DESTINATION" >> $CURRDIR/error.log
    return 1
}

# Existing: parse_date (unchanged)
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

# === RUNTIME === (integrated main logic)

function main() {
    if hasFlag "v"; then echo "$SCRIPT_NAME> $APP_VERSION"; exit 0; fi
    if hasFlag "install"; then add_script_to_path; fi
    if hasFlag "update"; then check_for_updates "false"; fi
    if hasFlag "fu"; then check_for_updates "true"; fi # force

    # Trap SIGINT for cleanup (integrated)
    trap cleanup INT

    # check rclone is installed (only if not HTTP mode)
    if [ "$UPLOAD_ONLY_MODE" != "true" ]; then
        log.debug "Checking for rclone..."
        if ! $(rclone --version >/dev/null 2>&1); then 
            log.info "- Installing rclone"

            # guarantee user is sudo
            if ! $(sudo -v >/dev/null 2>&1); then
                log.fatal "ERROR: Failed to install rclone: you need to be root to install rclone"
                exit 1
            fi

            srun "sudo -v ; curl https://rclone.org/install.sh | sudo bash"

            log.info "- SUCCESS! rclone was installed."
        else
            log.trace "- OK"
        fi
    fi

    # Integrated: Check for split-size and validate zip
    if hasFlag "C"; then
        if ! command -v zip &>/dev/null; then
            log.fatal "ERROR: 'zip' is required for --split-size (-C) but not found in PATH. Please install it (e.g. apt install zip)"
            cexit 1
        fi
        SPLIT_SIZE="$(getFlag "C")"
        log.info "Split-size mode enabled: $SPLIT_SIZE"
    fi

    if hasFlag "config"; then
        log.info "CONFIG ALIAS WAS CALLED! Opening rclone config..."
        rclone config
        exit 0
    fi

    if hasFlag "list"; then
        log.info "Listing remotes..."
        rclone listremotes
        exit 0
    fi

    # delete and purge logic (existing - unchanged, but use cexit)
    if hasFlag "delete"; then
        REMOTE="$(getFlag "delete")"
        log.info "Deleting remote... \"$REMOTE\""

        if [[ "$REMOTE" == *":" || "$REMOTE" == *":/" ]] && [[ "$_FAILSAFE" == "true" ]]; then
            log.fatal "$(colorir "vermelho" "FAILSAFE: You tried to remove your entire remote. If this is right, run again with '--no-failsafe'")"
            cexit 1
        fi

        # Função para detectar o tipo do remote e retornar a flag correta para pular a lixeira
        get_skip_trash_flag() {
            local remote_path="$1"
            local remote_name="${remote_path%%:*}"
            local remote_type

            log.trace "remote_path: $remote_path" silent
            log.trace "remote_name: $remote_name" silent

            remote_type=$(rclone listremotes --json | tr -d '\n' | sed -n "s/.*{\"name\":\"$remote_name\",\"type\":\"\([^\"]*\)\".*/\1/p")

            if [[ -z "$remote_type" ]]; then
                log.warn "Could not detect remote type for '$remote_name'. Skipping trash flag." silent
                echo ""
                return
            fi

            log.trace "remote_type: $remote_type" silent

            case "$remote_type" in
                drive) echo "--drive-use-trash=false" ;;
                onedrive) echo "--onedrive-no-trashed=true" ;;
                *) echo "" ;;
            esac
        }


        SKIP_TRASH_FLAG="$(get_skip_trash_flag "$REMOTE")"

        # Verifica se o caminho existe e determina se é diretório
        if rclone lsjson "$REMOTE" >/dev/null 2>&1; then
            if rclone lsjson "$REMOTE" 2>/dev/null | grep -q '"IsDir": true'; then
                log.trace "Detected directory. Running: rclone delete \"$REMOTE\" --rmdirs $SKIP_TRASH_FLAG"
                output=$(rclone delete "$REMOTE" --rmdirs $SKIP_TRASH_FLAG 2>&1)
                rclone_cmd="rclone delete"
            else
                log.trace "Detected file. Running: rclone deletefile \"$REMOTE\" $SKIP_TRASH_FLAG"
                output=$(rclone deletefile "$REMOTE" $SKIP_TRASH_FLAG 2>&1)
                rclone_cmd="rclone deletefile"
            fi
        else
            log.warn "$(colorir "vermelho" "Path not found or inaccessible: $REMOTE")"
            cexit 1
        fi

        rclone_exit_code=$?

        log.trace "--- Begin output of $rclone_cmd ---"
        while IFS= read -r line; do
            log.trace "(rclone) $line"
        done <<< "$output"
        log.trace "--- End output of $rclone_cmd ---"

        # Mesmo se deu erro, verifica se o arquivo realmente sumiu
        if ! rclone ls "$REMOTE" >/dev/null 2>&1; then
            if [ $rclone_exit_code -eq 0 ]; then
                log.info "Delete successful: $REMOTE"
            else
                log.warn "$(colorir "amarelo" "Warning: Rclone reported error, but path was removed: $REMOTE")"
            fi
            cexit 0
        else
            log.warn "$(colorir "vermelho" "Failed to delete: $REMOTE!")"
            cexit $rclone_exit_code
        fi
    fi

    if hasFlag "purge"; then
        REMOTE="$(getFlag "purge")"
        log.info "Purging remote... \"$REMOTE\""

        if [[ "$REMOTE" == *":" || "$REMOTE" == *":/" ]] && [[ "$_FAILSAFE" == "true" ]]; then
            log "$(colorir "vermelho" "FAILSAFE: You tried to remove your entire remote. If this is right, run again with '--no-failsafe'")"
            cexit 1
        fi

        # Executa o rclone purge e captura a saída
        log.test "test: rclone purge \"$REMOTE\" --rmdirs"
        output=$(rclone purge "$REMOTE" --rmdirs 2>&1)
        rclone_exit_code=$?

        # Loga a saída do rclone
        while IFS= read -r line; do
            log.debug "(rclone) $line"
        done <<< "$output"

        # Verifica se o rclone foi bem-sucedido
        if [ $rclone_exit_code -eq 0 ]; then
            log.info "Purge successful: $REMOTE"
        else
            log.error "$(colorir "vermelho" "Failed to purge: $REMOTE!")"
        fi

        cexit $rclone_exit_code
    fi

    # Integrated: Validations (required args, remote exists if rclone)
    if [ -z "$FULL_REMOTE_DEST" ]; then
        log.fatal "ERROR: You need to provide a valid remote destination! Example: -t \"http://example.com/upload:/basepath\" or \"mega:/folder\""
        cexit 1
    fi

    FILES_CSV="$(getFlag "f")"
    if [ -z "$FILES_CSV" ] && ! hasFlag "cf"; then
        log.fatal "ERROR: You need to provide files to upload! Example: -f \"/local/file:/remote/path,/local/dir2\""
        cexit 1
    fi

    if [ "$UPLOAD_ONLY_MODE" != "true" ]; then
        REMOTE_NAME="$(echo $FULL_REMOTE_DEST | cut -d ':' -f 1)"
        if ! rclone listremotes | grep -q "^$REMOTE_NAME:"; then
            log.fatal "ERROR: Remote $REMOTE_NAME not found! Exiting..."
            cexit 1
        fi
    fi

    # get files user wants to upload (existing, but now process with compact/flatten)
    log.debug "Checking target files..."
    declare -a PREPARED_FILES=()
    TMP_DIR=$(mktemp -d)
    log.debug "Temporary directory created at $TMP_DIR"

    # Handle command line files
    if hasFlag "f"; then
        log.trace "- COMMAND LINE"
        IFS=',' read -ra DIRECT_FILES <<< "$(getFlag "f")"
        for entry in "${DIRECT_FILES[@]}"; do
            entry=$(parse_date "$entry")
            local local_path="${entry%%:*}"
            local remote_path="${entry#*:}"
            local has_remote_path=false
            if [[ "$entry" == *:* ]]; then
                has_remote_path=true
            fi

            # Flatten logic (mesmo de antes)
            if ! $has_remote_path; then
                if hasFlag "F"; then
                    remote_path="$(basename "$local_path")"
                    log.trace "Flatten mode: Using basename '$remote_path' for local_path '$local_path'"
                else
                    remote_path="$local_path"
                    log.trace "No remote_path: Using full local path '$remote_path'"
                fi
            fi

            # Check if exists
            if [[ ! -e "$local_path" ]]; then
                log.warn "Skipping '$local_path': not found"
                continue
            fi

            SPLIT_SIZE="$(getFlag "C")"
            if [ -n "$SPLIT_SIZE" ]; then
                # Split mode: aplica pra dirs OU arquivos
                local item_to_split="$local_path"
                local original_basename=$(basename "$local_path")
                local split_dir_name="${original_basename%.*}"  # Basename sem extensão (ex: heavy-issabelbackup sem .tar)
                local temp_tar=""
                if [ -d "$local_path" ]; then
                    log.debug "Detected directory: $local_path (will compact + split)"
                    if ! hasFlag "a"; then
                        log.fatal "ERROR: Directory without --autocompact."
                        cexit 1
                    fi
                    temp_tar="$TMP_DIR/${original_basename}.tar"
                    if ! tar -cf "$temp_tar" -C "$(dirname "$local_path")" "$original_basename"; then
                        log.fatal "Failed to tar dir"; cexit 1;
                    fi
                    item_to_split="$temp_tar"
                    split_dir_name="${original_basename}"  # Pra dir, usa nome original como dir
                else
                    log.debug "Detected file: $local_path (will split)"
                fi

                # Split o item em ZIPs
                local zip_base_name="${item_to_split##*/}"  # Basename do item to split
                zip_base_name="${zip_base_name%.tar}"  # Remove .tar se dir
                local zip_base="$TMP_DIR/${zip_base_name}.zip"
                pushd "$(dirname "$item_to_split")" >/dev/null
                if ! zip -r -s "$SPLIT_SIZE" "$zip_base" "$(basename "$item_to_split")" >&2; then
                    popd >/dev/null
                    log.fatal "ERROR: Failed to split '$item_to_split'."
                    cexit 1
                fi
                popd >/dev/null

                # Add parts: common dir = split_dir_name, server appends part_basename
                local zip_parts=($(ls "$TMP_DIR/${zip_base_name}."{zip,z01,z02,z03,z04,z05,z06,z07,z08,z09,z10,z11,z12} 2>/dev/null | sort))
                for zip_file in "${zip_parts[@]}"; do
                    local part_basename=$(basename "$zip_file")
                    local zip_remote_path="$split_dir_name"  # Common dir sem / final (server appends part_basename)

                    # Se remote_path original termina com /, usa como base dir
                    if [[ "$remote_path" == */ ]]; then
                        zip_remote_path="${remote_path%/}/$split_dir_name"
                    # Se custom não-dir, usa custom como base dir
                    elif [[ "$has_remote_path" == true ]]; then
                        zip_remote_path="${remote_path%.*}"  # Custom sem ext como dir
                    fi  # Senão, original basename sem ext como dir

                    PREPARED_FILES+=("$zip_file:$zip_remote_path")
                    log.trace "Added split ZIP part: $zip_file:$zip_remote_path (server will append $part_basename)"
                done

                # Cleanup
                [ -n "$temp_tar" ] && [ -f "$temp_tar" ] && rm -f "$temp_tar"
            else
                # No split: add as-is (com compact pra dir se -a)
                if [ -d "$local_path" ]; then
                    # Lógica original de compact tar.gz pra dir
                    if ! hasFlag "a"; then
                        log.fatal "ERROR: Directory without --autocompact."
                        cexit 1
                    fi
                    local tar_file=$(compact_directory "$local_path" "$TMP_DIR")
                    local tar_remote_path
                    if [[ "$remote_path" == */ ]]; then
                        tar_remote_path="${remote_path%/}/$(basename "$local_path").tar.gz"
                    else
                        tar_remote_path="${remote_path}.tar.gz"
                    fi
                    PREPARED_FILES+=("$tar_file:$tar_remote_path")
                else
                    PREPARED_FILES+=("$local_path:$remote_path")
                fi
            fi
        done
    fi

    # Handle conf-file (similar processing, but line-by-line) - fixed split logic to match command line
    if hasFlag "cf"; then
        log.trace "- CONFIGURATION FILE"
        while IFS= read -r entry; do
            if [ -z "$entry" ]; then continue; fi
            entry=$(parse_date "$entry")
            local local_path="${entry%%:*}"
            local remote_path="${entry#*:}"
            local has_remote_path=false
            if [[ "$entry" == *:* ]]; then
                has_remote_path=true
            fi

            # Flatten logic (same as above)
            if ! $has_remote_path; then
                if hasFlag "F"; then
                    remote_path="$(basename "$local_path")"
                else
                    remote_path="$local_path"
                fi
            fi

            # Check if exists
            if [[ ! -e "$local_path" ]]; then
                log.warn "Skipping conf entry '$local_path': not found"
                continue
            fi

            SPLIT_SIZE="$(getFlag "C")"
            if [ -n "$SPLIT_SIZE" ]; then
                # Split mode for conf (adapted from command line)
                local item_to_split="$local_path"
                local item_basename=$(basename "$local_path")
                local temp_tar=""
                if [ -d "$local_path" ]; then
                    log.debug "Detected directory in conf: $local_path (will compact + split)"
                    if ! hasFlag "a"; then
                        log.fatal "ERROR: Directory in conf without --autocompact."
                        cexit 1
                    fi
                    temp_tar="$TMP_DIR/${item_basename}.tar"
                    if ! tar -cf "$temp_tar" -C "$(dirname "$local_path")" "$(basename "$local_path")"; then
                        log.fatal "Failed to tar conf dir"; cexit 1;
                    fi
                    item_to_split="$temp_tar"
                    item_basename="${item_basename}.tar"
                else
                    log.debug "Detected file in conf: $local_path (will split)"
                fi

                local zip_base_name="${item_basename%.tar}.zip"
                local zip_base="$TMP_DIR/${zip_base_name}"
                pushd "$(dirname "$item_to_split")" >/dev/null
                if ! zip -r -s "$SPLIT_SIZE" "$zip_base" "$(basename "$item_to_split")" >&2; then
                    popd >/dev/null
                    log.fatal "ERROR: Failed to split conf item '$item_to_split'."
                    cexit 1
                fi
                popd >/dev/null

                local zip_parts=($(ls "$TMP_DIR/${zip_base_name%.*}."{zip,z01,z02,z03,z04,z05,z06,z07,z08,z09,z10,z11,z12} 2>/dev/null | sort))
                for zip_file in "${zip_parts[@]}"; do
                    local part_basename=$(basename "$zip_file")
                    local zip_remote_path="$part_basename"  # Default: basename do part

                    if [[ "$remote_path" == */ ]]; then
                        zip_remote_path="${remote_path%/}/$part_basename"
                    elif [[ "$has_remote_path" == true ]]; then
                        zip_remote_path="${remote_path%.*}-${part_basename}"
                    fi

                    PREPARED_FILES+=("$zip_file:$zip_remote_path")
                    log.trace "Added conf split ZIP part: $zip_file:$zip_remote_path"
                done

                [ -n "$temp_tar" ] && [ -f "$temp_tar" ] && rm -f "$temp_tar"
            else
                # No split for conf
                if [ -d "$local_path" ]; then
                    log.debug "Detected directory in conf: $local_path (no split)"
                    if ! hasFlag "a"; then
                        log.fatal "ERROR: Directory in conf without --autocompact."
                        cexit 1
                    fi
                    local tar_file=$(compact_directory "$local_path" "$TMP_DIR")
                    local tar_remote_path
                    if [[ "$remote_path" == */ ]]; then
                        tar_remote_path="${remote_path%/}/$(basename "$local_path").tar.gz"
                    else
                        tar_remote_path="${remote_path}.tar.gz"
                    fi
                    PREPARED_FILES+=("$tar_file:$tar_remote_path")
                else
                    if [ -f "$local_path" ]; then
                        PREPARED_FILES+=("$local_path:$remote_path")
                    else
                        log.warn "Skipping conf entry '$local_path': not file/dir"
                    fi
                fi
            fi
        done < <(cat "$(getFlag "cf")")
    fi

    if [ ${#PREPARED_FILES[@]} -eq 0 ]; then
        log.fatal "ERROR: No valid files or directories to upload."
        cexit 1
    fi

    log.info "Files/directories prepared for upload: ${PREPARED_FILES[*]}"

    # Upload logic: conditional on mode
    log.debug "Starting upload..."
    local UPLOAD_FILES_CSV=$(IFS=','; echo "${PREPARED_FILES[*]}")
    local REMOTE_DESTINATION="$FULL_REMOTE_DEST"
    if [[ "$REMOTE_DESTINATION" =~ ^[^:]+$ ]]; then REMOTE_DESTINATION="$REMOTE_DESTINATION:/"; fi
    REMOTE_DESTINATION=$(parse_date "$REMOTE_DESTINATION")

    if [ "$UPLOAD_ONLY_MODE" = "true" ]; then
        # HTTP: use curl
        upload_via_curl "$UPLOAD_FILES_CSV" "$REMOTE_DESTINATION"
    else
        # rclone: loop with rclone_copy (adjusted for prepared files)
        for prepared_entry in "${PREPARED_FILES[@]}"; do
            local SOURCE_PATH="${prepared_entry%%:*}"
            local CUSTOM_DEST="${prepared_entry#*:}"
            local FINAL_DESTINATION="$REMOTE_DESTINATION$CUSTOM_DEST"

            if [ -d "$SOURCE_PATH" ]; then
                FINAL_DESTINATION="$FINAL_DESTINATION/$(basename "$SOURCE_PATH")"
            fi

            log.trace "SOURCE: $SOURCE_PATH -> FINAL_DEST: $FINAL_DESTINATION"
            rclone_copy "$SOURCE_PATH" "$FINAL_DESTINATION"
        done
    fi

    # Cleanup temp dir
    log.debug "Cleaning up temporary directory..."
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
        log.trace "- Temporary directory '$TMP_DIR' deleted."
    fi

    log.info "Upload finished."
    cexit 0
}

main