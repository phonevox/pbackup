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
LOG_FILE_PATH="/var/log"
LOG_FILE_NAME="pbackup.log"
LOG_FILE="$LOG_FILE_PATH/$LOG_FILE_NAME-$(date '+%Y-%m-%d').log"

# Versioning 
REPO_OWNER="phonevox"
REPO_NAME="pbackup"
REPO_URL="https://github.com/$REPO_OWNER/$REPO_NAME"
ZIP_URL="$REPO_URL/archive/refs/heads/main.zip"
APP_VERSION="v$(grep '"version"' $CURRDIR/lib/version.json | sed -E 's/.*"version": *"([^"]+)".*/\1/')"

# === FLAG GENERATION ===
source "$CURRDIR/lib/ezflags.sh"
source "$CURRDIR/lib/uzful.sh"

# General flags
add_flag "d" "dry" "Do NOT make changes to the system" bool
add_flag "V" "verbose" "Prints more information about the script's progress" bool
# Script flags
add_flag "cf" "conf-file" "Path to a file containing multiple paths to upload. One path per line.\n- The paths can be formatted as \"<local>[:<remote>]\". If '-t|--to' destination is provided, \"[:<remote>]\" will be suffixed to the \"-t|--to\" flag's value.\n- Example: -t \"mega:/folder\" on \"./hello.txt:/test\" will be saved to \"mega:/folder/test/hello.txt\"" string
add_flag "f" "files" "Path(s) to file(s) or folder(s) to be uploaded to remote. Separate multiple files by comma (,)\n- The paths can be formatted as \"<local>[:<remote>]\". If '-t|--to' destination is provided, \"[:<remote>]\" will be suffixed to the \"-t|--to\" flag's value.\n- Example: -t \"mega:/folder\" on \"./cheese.txt:/test\" will be saved to \"mega:/folder/test/cheese.txt\"" string
add_flag "t" "to" "rclone's remote name. Optionally can also set to where, on the remote, your files will be moved to.\n- Example: -t|--to \"<remote_name>[:<path>]\"" string
add_flag "config:HIDDEN" "config" "Alias for \"rclone config\"" bool
add_flag "list:HIDDEN" "list" "Alias for \"rclone listremotes\"" bool
add_flag "install:HIDDEN" "install" "Install this script to your path, so you can call it from anywhere with '$(echo $SCRIPT_NAME | cut -d '.' -f 1) <flags>'" bool

add_flag "y:HIDDEN" "yesterday" "Alias for \"--days-ago 1\"" bool
add_flag "da" "days-ago" "If there is any %YEAR%, %MONTH% or %DAY% variables in paths, how many days to subtract from them. Defaults to 0\n- Do note that if you use %DAY-<n>d% together with \"--days-ago <x>\", the amount subtracted will be summed (in this case, %DAY-<n+x>d%).\n- If n and x were both 1, this would result in 2 days ago result for %DAY% conversion." string

add_flag "v" "version" "Show app version and exit" bool
add_flag "upd:HIDDEN" "update" "Update this script to the newest version" bool
add_flag "fu:HIDDEN" "force-update" "Force the update even if its in the same version" bool
# === GENERATING ===
set_description "Phonevox's rclone abstraction for backups on cloud remotes.\nYou need to configure remotes on rclone manually (through 'rclone config').\nWhen defining paths, you can use the following variables:\n- %YEAR%: The current year\n- %MONTH%: The current month\n- %DAY%: The current day\n- %YEAR-<n>d%: The year n days ago\n- %MONTH-<n>d%: The month n days ago\n- %DAY-<n>d%: The day n days ago"
set_usage "sudo bash $FULL_SCRIPT_PATH --files \"<path_one[:<remote_p1>]>[,<path_two[:<remote_p2>]>]\" --to \"<remote_name>[:<remote_path>]\""
parse_flags $@


# === POST-PARSE VARIABLES ===

_DEBUG="false"
_DAYS_AGO=0 # today
hasFlag "y" && _DAYS_AGO=1
hasFlag "da" && _DAYS_AGO=$(getFlag "da")
hasFlag "V" && _DEBUG="true"

# === UTILITARY FUNCTIONS ===

# logging
log () {
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

# ==============================================================================================================
# SCRIPT MANAGEMENT, BINARY

# add to system path
# Usage: add_script_to_path 
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
# VERSION CONTROL, UPDATES

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

# === RUNTIME ===

function parse_date() {
    local INPUT="$1"
    local CURRENT_DATE=$(date +%Y-%m-%d %H-%M-%s)  # Mantemos um formato padrão AAAA-MM-DD

    # Tratamento de %DAY%
    if [[ "$INPUT" =~ %DAY% ]]; then
        local NEW_DATE=$(date -d "$CURRENT_DATE -$_DAYS_AGO days" +%d)
        INPUT=$(echo "$INPUT" | sed "s/%DAY%/$NEW_DATE/g")
    fi

    # Tratamento de %MONTH%
    if [[ "$INPUT" =~ %MONTH% ]]; then
        local NEW_DATE=$(date -d "$CURRENT_DATE -$_DAYS_AGO days" +%m)
        INPUT=$(echo "$INPUT" | sed "s/%MONTH%/$NEW_DATE/g")
    fi

    # Tratamento de %YEAR%
    if [[ "$INPUT" =~ %YEAR% ]]; then
        local NEW_DATE=$(date -d "$CURRENT_DATE -$_DAYS_AGO days" +%Y)
        INPUT=$(echo "$INPUT" | sed "s/%YEAR%/$NEW_DATE/g")
    fi

    # Tratamento de %HOUR%
    if [[ "$INPUT" =~ %HOUR% ]]; then
        local NEW_DATE=$(date -d "$CURRENT_DATE -$_DAYS_AGO days" +%H)
        INPUT=$(echo "$INPUT" | sed "s/%HOUR%/$NEW_DATE/g")
    fi

    # Tratamento de %MINUTE%
    if [[ "$INPUT" =~ %MINUTE% ]]; then
        local NEW_DATE=$(date -d "$CURRENT_DATE -$_DAYS_AGO days" +%M)
        INPUT=$(echo "$INPUT" | sed "s/%MINUTE%/$NEW_DATE/g")
    fi

    # Tratamento de %SECOND%
    if [[ "$INPUT" =~ %SECOND% ]]; then
        local NEW_DATE=$(date -d "$CURRENT_DATE -$_DAYS_AGO days" +%S)
        INPUT=$(echo "$INPUT" | sed "s/%SECOND%/$NEW_DATE/g")
    fi

    # Tratamento de %DAY-n%
    while [[ "$INPUT" =~ %DAY-([0-9]+)d% ]]; do
        local DAYS_TO_SUBTRACT="$((${BASH_REMATCH[1]} + $_DAYS_AGO))"
        local NEW_DATE=$(date -d "$CURRENT_DATE -$DAYS_TO_SUBTRACT days" +%d)
        INPUT=$(echo "$INPUT" | sed "s/%DAY-${BASH_REMATCH[1]}d%/$NEW_DATE/g")
    done

    # Tratamento de %MONTH-n% (subtrai dias, não meses!)
    while [[ "$INPUT" =~ %MONTH-([0-9]+)d% ]]; do
        local DAYS_TO_SUBTRACT="$((${BASH_REMATCH[1]} + $_DAYS_AGO))"
        local NEW_DATE=$(date -d "$CURRENT_DATE -$DAYS_TO_SUBTRACT days" +%m)
        INPUT=$(echo "$INPUT" | sed "s/%MONTH-${BASH_REMATCH[1]}d%/$NEW_DATE/g")
    done

    # Tratamento de %YEAR-n% (subtrai dias, não anos!)
    while [[ "$INPUT" =~ %YEAR-([0-9]+)d% ]]; do
        local DAYS_TO_SUBTRACT="$((${BASH_REMATCH[1]} + $_DAYS_AGO))"
        local NEW_DATE=$(date -d "$CURRENT_DATE -$DAYS_TO_SUBTRACT days" +%Y)
        INPUT=$(echo "$INPUT" | sed "s/%YEAR-${BASH_REMATCH[1]}d%/$NEW_DATE/g")
    done

    echo "$INPUT"
}

function main() {
    if hasFlag "v"; then echo "$SCRIPT_NAME> $APP_VERSION"; exit 0; fi
    if hasFlag "install"; then add_script_to_path; fi
    if hasFlag "update"; then check_for_updates "false"; fi
    if hasFlag "fu"; then check_for_updates "true"; fi # force

    # check rclone is installed
    log "Checking for rclone..."
    if ! $(rclone --version >/dev/null 2>&1); then 
        log "- Installing rclone"

        # guarantee user is sudo
        if ! $(sudo -v >/dev/null 2>&1); then
            log "ERROR: You need to be root to install rclone"
            exit 1
        fi

        srun "sudo -v ; curl https://rclone.org/install.sh | sudo bash"

        log "- SUCCESS! rclone was installed."
    else
        log "- OK"
    fi

    if hasFlag "config"; then
        log "CONFIG ALIAS WAS CALLED! Opening rclone config..."
        rclone config
        exit 0
    fi

    if hasFlag "list"; then
        log "Listing remotes..."
        rclone listremotes
        exit 0
    fi

    # check remote exists
    REMOTE="$(getFlag "t" | cut -d ':' -f 1)"
    log "Checking rclone remote '$REMOTE'..."
    if ! $(rclone listremotes | grep -q "^$REMOTE:$"); then
        log "ERROR: Remote '$REMOTE' does not exist. Please configure it on rclone manually (through 'rclone config')"
        exit 1
    else
        log "- OK"
    fi
    
    # get files user wants to upload
    log "Checking target files..."
    PATHS_TO_UPLOAD=()
    INVALID_PATHS=()

    if hasFlag "f"; then
        log "- COMMAND LINE"
        for path in $(getFlag "f" | tr ',' ' '); do
            path=$(parse_date "$path")
            source_path=$(echo "$path" | cut -d ':' -f 1)
            if ! $(test -e "$source_path"); then
                log " $(colorir "vermelho" "x") invalid: $source_path"
                INVALID_PATHS+=("$path")
            else
                PATHS_TO_UPLOAD+=("$path")
                log " $(colorir "verde" "+") added: $source_path"
            fi
        done
    fi

    if hasFlag "cf"; then
        log "- CONFIGURATION FILE"
        for path in $(cat $(getFlag "cf")); do
            path=$(parse_date "$path")
            source_path=$(echo "$path" | cut -d ':' -f 1)
            if ! $(test -e "$source_path"); then
                log " $(colorir "vermelho" "x") invalid: $source_path"
                INVALID_PATHS+=("$path")
            else
                PATHS_TO_UPLOAD+=("$path")
                log " $(colorir "verde" "+") added: $source_path"
            fi
        done
    fi

    if [ ! -z "$INVALID_PATHS" ]; then
        log "WARNING: The following paths do not exist and will be ignored:"
        for path in "${INVALID_PATHS[@]}"; do
            log "- $(colorir "amarelo" "$(echo "$path" | cut -d ':' -f 1)")"
        done
    fi

    log "Starting upload..."
    REMOTE_DESTINATION="$(getFlag "t")"; if [[ "$REMOTE_DESTINATION" =~ ^[^:]+$ ]]; then REMOTE_DESTINATION="$REMOTE_DESTINATION:/"; fi
    REMOTE_DESTINATION=$(parse_date "$REMOTE_DESTINATION")
    for path in "${PATHS_TO_UPLOAD[@]}"; do
        CUSTOM_DESTINATION="$(echo "$path" | awk -F ':' '{print ($2 != "") ? $2 : ""}')"
        FINAL_DESTINATION="$REMOTE_DESTINATION$CUSTOM_DESTINATION"
        SOURCE_PATH="$(echo "$path" | cut -d ':' -f 1)"

        if $(test -d "$SOURCE_PATH"); then # if its a folder, tell cloud to create the base folder too
            FINAL_DESTINATION="$FINAL_DESTINATION/$(basename "$SOURCE_PATH")"
        fi

        $_DEBUG && log "              PATH : $path"
        $_DEBUG && log "REMOTE DESTINATION : $REMOTE_DESTINATION"
        $_DEBUG && log "CUSTOM DESTINATION : $CUSTOM_DESTINATION"
        $_DEBUG && log "       SOURCE_PATH : (what?) : $SOURCE_PATH"
        $_DEBUG && log " FINAL DESTINATION :   (to?) : $FINAL_DESTINATION"

        if $(test -d "$SOURCE_PATH"); then
            log "- '$(colorir "azul" "$SOURCE_PATH/* (directory)")' > '$(colorir "ciano" "$FINAL_DESTINATION")'"

            if hasFlag "d"; then
                log "$(colorir "amarelo" "[DRY]") rclone copy \"$SOURCE_PATH\" \"$FINAL_DESTINATION\" --progress"
            else
                # Executa o rclone e captura a saída
                output=$(rclone copy "$SOURCE_PATH" "$FINAL_DESTINATION" --progress 2>&1)
                rclone_exit_code=$?

                # Loga a saída do rclone
                while IFS= read -r line; do
                    log "(rclone) $line"
                done <<< "$output"

                # Verifica se o rclone foi bem-sucedido
                if [ $rclone_exit_code -eq 0 ]; then
                    log "Upload successful: $SOURCE_PATH"
                else
                    log "$(colorir "vermelho" "Failed to upload: $SOURCE_PATH!")"
                fi
            fi

        elif $(test -f "$SOURCE_PATH"); then
            log "- '$(colorir "azul" "$SOURCE_PATH (file)")' > '$(colorir "ciano" "$FINAL_DESTINATION")'"

            if hasFlag "d"; then
                log "$(colorir "amarelo" "[DRY]") rclone copy \"$SOURCE_PATH\" \"$FINAL_DESTINATION\" --progress"
            else
                # Executa o rclone e captura a saída
                output=$(rclone copy "$SOURCE_PATH" "$FINAL_DESTINATION" --progress 2>&1)
                rclone_exit_code=$?

                # Loga a saída do rclone
                while IFS= read -r line; do
                    log "(rclone) $line"
                done <<< "$output"

                # Verifica se o rclone foi bem-sucedido
                if [ $rclone_exit_code -eq 0 ]; then
                    log "Upload successful: $SOURCE_PATH"
                else
                    log "$(colorir "vermelho" "Failed to upload: $SOURCE_PATH!")"
                fi
            fi

        else
            log "- '$(colorir "vermelho" "x '$SOURCE_PATH' (unknown)")' > '$(colorir "ciano" "$FINAL_DESTINATION/")'"
            log "ERROR: Unknown type! '$SOURCE_PATH'"
        fi
    done
    log "Upload finished."
}

main
