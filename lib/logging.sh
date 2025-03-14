#!/bin/bash

# failsafe in case you import logging.sh directly.
if [ -z "$_LOG_FILE" ]; then
    echo "ERROR: Please set _LOG_FILE in your main script."
    exit 1
fi

if [ -z "$_LOG_ROTATE_PERIOD" ]; then
    # log rotate was not set. assuming 7 days rotate.
    _LOG_ROTATE_PERIOD=7
fi

if [ -z "$_LOG_LEVEL" ]; then
    # 0: test
    # 1: trace
    # 2: debug
    # 3: info
    # 4: warn
    # 5: error
    # 6: critical
    _LOG_LEVEL=2
fi

_LOG_BASEPATH="$(dirname "$_LOG_FILE")"
_LOG_FILENAME="$(basename "$_LOG_FILE")"

if [ ! -w "$_LOG_BASEPATH" ]; then
    echo "WARNING: Insufficient permissions to write to '$_LOG_BASEPATH'. Saving logs to '$CURRDIR' instead as fallback."
    _LOG_BASEPATH="$CURRDIR"
fi

[ -w "$_LOG_BASEPATH" ] || _LOG_BASEPATH="$CURRDIR"

_LOG_COMPLETE_PATH="$_LOG_BASEPATH/$_LOG_FILENAME-$(date '+%Y%m%d')"
_LOG_ROTATED_COMPLETE_PATH="$_LOG_BASEPATH/$_LOG_FILENAME-$(date -d "-$_LOG_ROTATE_PERIOD days" +%Y%m%d)" # logfilet o be deleted, because it was rotated

# echo "Logfile: $_LOG_COMPLETE_PATH"
# echo "Rotated: $_LOG_ROTATED_COMPLETE_PATH"

if ! type "colorir" > /dev/null 2>&1; then
    # mock color function so it doesnt break. it will just run color-less.
    function colorir() {
        local COLOR="$1"
        local TEXT="$2"
        echo "$2"
    }
fi

function log () {
    local CURRTIME=$(date '+%Y-%m-%d %H:%M:%S')
    local SHOULD_ECHO_TO_CONSOLE=true
    if [ -n "$SCRIPT_NAME" ]; then local SCRIPT_NAME="$SCRIPT_NAME> "; fi
    local LOG_MESSAGE="$1"
    local LOG_IS_MUTED="$2"
    local LOG_TAG="$3"
    local LOG_TAG_COLOR="$4"
    local ECHO_MESSAGE="[$CURRTIME] ${SCRIPT_NAME}$LOG_MESSAGE"
    if [ -n "$LOG_TAG" ]; then
        if [ -n "$LOG_TAG_COLOR" ]; then
            local LOG_TAG=$(colorir "$LOG_TAG_COLOR" "$(printf "%-5s" "$LOG_TAG")")
        else
            local LOG_TAG=$(printf "%-5s" "$LOG_TAG")
        fi
        local ECHO_MESSAGE="[$CURRTIME] [ $LOG_TAG ] ${SCRIPT_NAME}$LOG_MESSAGE"
    fi

    if [ -n "$LOG_IS_MUTED" ]; then
        SHOULD_ECHO_TO_CONSOLE=false
    fi
    
    if ! [ -f "$_LOG_COMPLETE_PATH" ]; then
        echo -e "[$CURRTIME] $SCRIPT_NAME> Iniciando novo logfile" > "$_LOG_COMPLETE_PATH"

        # We will only activate the rotate routine once a new logfile is created.
        if [ -f "$_LOG_ROTATED_COMPLETE_PATH" ]; then
            rm -f "$_LOG_ROTATED_COMPLETE_PATH" && log "Deleting rotated log file: $_LOG_ROTATED_COMPLETE_PATH" || log "Could not delete rotated log file: $_LOG_ROTATED_COMPLETE_PATH"
        fi
    fi

    # log to file
    echo -e "$ECHO_MESSAGE" >> "$_LOG_COMPLETE_PATH"

    # log to console (if enabled))
    $SHOULD_ECHO_TO_CONSOLE && echo -e "$ECHO_MESSAGE"
}

# ---

# im so sorry for what you're about to see
function log.test () { 
    local MUTED="$2"
    [[ $_LOG_LEVEL -gt 0 ]] && local MUTED="true"
    log "$1" "$MUTED" "TEST" "magenta" 
}
function log.trace () { 
    local MUTED="$2"
    [[ $_LOG_LEVEL -gt 1 ]] && local MUTED="muted"
    log "$1" "$MUTED" "TRACE" "azul_claro" 
}
function log.debug() { 
    local MUTED="$2"
    [[ $_LOG_LEVEL -gt 2 ]] && local MUTED="muted"
    log "$1" "$MUTED" "DEBUG" "azul" 
}
function log.info() { 
    local MUTED="$2"
    [[ $_LOG_LEVEL -gt 3 ]] && local MUTED="muted"
    log "$1" "$MUTED" "INFO" "verde" 
}
function log.warn() { 
    local MUTED="$2"
    [[ $_LOG_LEVEL -gt 4 ]] && local MUTED="muted"
    log "$1" "$MUTED" "WARN" "amarelo" 
}
function log.error() { 
    local MUTED="$2"
    [[ $_LOG_LEVEL -gt 5 ]] && local MUTED="muted"
    log "$1" "$MUTED" "ERROR" "vermelho" 
}
function log.fatal() { 
    local MUTED="$2"
    [[ $_LOG_LEVEL -gt 6 ]] && local MUTED="muted"
    log "$1" "$MUTED" "FATAL" "vermelho_claro" 
}
