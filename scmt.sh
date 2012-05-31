#!/bin/sh

###----------------------------------------------------------------------
### File    : scmt.sh
### Author  : Aleksey Morarash <aleksey.morarash@gmail.com>
### Created : 24 May 2012
### License : FreeBSD
### Description : Simple Container Management Tool
###----------------------------------------------------------------------

## ----------------------------------------------------------------------
## Main definitions
## ----------------------------------------------------------------------

# Where containers image and configs will be stored.
# Default: ./run
#RUNDIR=./run

# Temporary directory.
# Default: /tmp
#TMPDIR=/tmp

# Network bridge name
# Default: br0
#NET_BRIDGE=br0

# Configuration file.
# Default: /etc/scmt.conf
#SCMT_CONFIG=/etc/scmt.conf

## ----------------------------------------------------------------------
## Utility functions
## ----------------------------------------------------------------------

scmt_error(){
    echo "$BASENAME: $1" 1>&2
    [ "$2" = "noexit" ] && return 0
    if [ -z "$2" ]; then
        exit 1
    else
        exit $2
    fi
}

scmt_warning(){
    [ $QUIET = 0 ] || echo "$BASENAME: Warning: $1" 1>&2
    :
}

scmt_is_verbose(){
    [ $VERBOSE = 0 ]
}

scmt_verbose(){
    scmt_is_verbose && echo "$BASENAME: $1" 1>&2
    :
}

scmt_help(){
    [ $HELP != 0 ] && return 0
    echo -n "Usage:\n\t$BASENAME "
    case "$1" in
        base)
            echo "list|add|del|start|start-all|stop|stop-all|kill|status [options] [args]"
            echo "\t$BASENAME list|add|del|start|start-all|stop|stop-all|kill|status --help"
            echo "Common options:"
            echo "\t--verbose - be verbose;"
            echo "\t--quiet   - do not show warnings;"
            echo "\t--trace   - only for debug purposes."
            ;;
        list)
            echo "list"
            echo "Shows deployed containers with their statuses."
            ;;
        add)
            echo -n "add [--mem MBYTES] [--cores CORES] "
            echo -n "[--mac MAC] [--vnc] [--start] "
            echo    "container-name image-url"
            echo "Adds new container with disk image from URL specified."
            ;;
        mod)
            echo -n "mod [--mem MBYTES] [--cores CORES] "
            echo    "[--mac MAC] [--vnc] container-name"
            echo "Modifies some properties of container. Changes will be "
            echo "applied only on next container start."
            ;;
        del)
            echo "del container-name"
            echo "Completely removes container from system (All data will be lost)."
            ;;
        start)
            echo "start container-name"
            echo "Starts selected container."
            ;;
        start-all)
            echo "start-all"
            echo "Starts all containers with auto-start flag. Use on system start."
            ;;
        stop)
            echo "stop [--wait SECONDS] container-name"
            echo "Stops selected container."
            ;;
        stop-all)
            echo "stop-all [--wait SECONDS]"
            echo "Stops all containers. Use on system stop."
            ;;
        kill)
            echo "kill container-name"
            echo "Brutal kill selected container."
            ;;
        status)
            echo "status container-name"
            echo "Shows selected container status."
            ;;
    esac
    exit 1
}

scmt_deploy_image(){
    local URL
    URL="$1"
    scmt_verbose "Deploying image from $URL..."
    [ -z "$1" ] && scmt_error "Container image URL undefined"
    if [ -f "$1" ]; then
        scmt_extract_image "$1" "$2"
    else
        case "$1" in
            http://*|https://*|ftp://*)
                scmt_download_image "$1" "$2" ;;
            *)
                scmt_error "Unknown proto or no such file: \"$1\"" noexit
                return 1 ;;
        esac
    fi
}

scmt_download_image(){
    local FILENAME
    FILENAME="$2"/`basename "$1"`
    rm -rf -- "$FILENAME"
    scmt_verbose "Downloading image from $1..."
    curl \
        --fail \
        --silent \
        --show-error \
        --output "$FILENAME" \
        "$1" || return $?
    scmt_extract_image "$FILENAME" "$2" || return $?
    rm -rf -- "$FILENAME"
    return 0
}

scmt_extract_image(){
    local IMG_RAW IMG_QCOW2
    scmt_verbose "Extracting image from $1..."
    IMG_RAW="$2"/run/image.raw
    tar --extract \
        --file "$1" \
        --to-stdout > "$IMG_RAW"
    scmt_verbose "Converting image to QCOW2 format..."
    IMG_QCOW2="$2"/run/image.qcow2
    qemu-img convert -O qcow2 "$IMG_RAW" "$IMG_QCOW2"
    scmt_verbose "Removing raw image..."
    rm -f -- "$IMG_RAW"
}

scmt_gen_mac(){
    scmt_verbose "Generating MAC addr..."
    cat /dev/urandom | \
        head --bytes=6 | \
        hexdump -v -e '/1 "%02X:"' | \
        sed 's/:$//'
}

scmt_check_name(){
    local NAME
    scmt_verbose "Checking container name..."
    [ -z "$1" ] && scmt_error "container name not specified"
    echo "$1" | \
        tr '[:upper:]' '[:lower:]' | \
        grep -E '^[a-z0-9-]{1,10}$' || \
        scmt_error "bad name"
}

scmt_check_real_name(){
    local NAME
    NAME=`scmt_check_name "$1"` || exit $?
    [ -f "$RUNDIR"/"$NAME"/config ] || \
        scmt_error "no such container: \"$NAME\""
    echo "$NAME"
}

scmt_free_vnc_port(){
    local USED_PORTS PORT
    scmt_verbose "Getting unused VNC port..."
    USED_PORTS=`scmt_used_vnc_ports`
    PORT=1
    while true; do
        echo "$USED_PORTS" | \
            grep --quiet -E "^$PORT$"
        if [ $? != 0 ]; then
            echo $PORT
            return 0
        fi
        PORT=`expr $PORT + 1`
    done
}

scmt_used_vnc_ports(){
    local i
    for i in `scmt_containers`; do
        grep -E '^VNC=[0-9]+$' "$RUNDIR"/"$i"/config | \
            grep -v '^VNC=0$' | \
            sed 's/VNC=//'
    done
}

scmt_containers(){
    local DIR
    for DIR in "$RUNDIR"/*; do
        if [ -f "$DIR"/config ]; then
            echo `basename "$DIR"`
        fi
    done | sort
}

scmt_container_config(){
    local CONFIG
    CONFIG=`scmt_config_name "$1"`
    [ ! -f "$CONFIG" ] && \
        scmt_error "There is no container like \"$1\""
    . "$CONFIG"
}

scmt_config_name(){
    echo "$RUNDIR"/"$1"/config
}

scmt_pid_name(){
    echo "$RUNDIR"/"$1"/run/pid
}

scmt_mon_sock_name(){
    echo "$RUNDIR"/"$1"/run/monitor.sock
}

scmt_monitor_run(){
    echo "$2" | \
        socat STDIN unix:"`scmt_mon_sock_name \"$1\"`" > \
        /dev/null 2>&1
}

scmt_powerdown(){
    scmt_monitor_run "$1" system_powerdown || :
}

scmt_do_kill(){
    scmt_monitor_run "$1" quit || :
}

scmt_shutdown_cleanup(){
    local TAP PIDFILE MONSOCK
    scmt_verbose "Removing network interfaces..."
    TAP="scmt-$1"
    sudo -n \
        tunctl -d "$TAP" || \
        scmt_warning "Failed to remove network interface"
    PIDFILE=`scmt_pid_name "$1"`
    MONSOCK=`scmt_mon_sock_name "$1"`
    rm -f -- "$PIDFILE" "$MONSOCK"
}

scmt_pid(){
    local PIDFILE PID
    PIDFILE=`scmt_pid_name "$1"`
    if [ -f "$PIDFILE" ]; then
        PID=`cat "$PIDFILE"`
        [ -z "$PID" ] && return 1
        ps --pid "$PID" --no-headers | \
            grep --quiet "kvm" && \
            echo "$PID" && return 0
    fi
    return 1
}

scmt_is_running(){
    scmt_pid "$1" > /dev/null
}

scmt_wait_stop(){
    if scmt_is_running "$1"; then
        scmt_wait_stop_ "$1"
    else
        return 0
    fi
}
scmt_wait_stop_(){
    local ELAPSED
    [ -z "$MAX_WAIT_TIME" ] && MAX_WAIT_TIME=60
    ELAPSED="$2"
    [ -z "$2" ] && ELAPSED=0
    [ $ELAPSED -ge $MAX_WAIT_TIME ] && return 1
    sleep 1s
    if scmt_is_running "$1"; then
        scmt_wait_stop_ "$1" `expr "$ELAPSED" + 1`
    else
        return 0
    fi
}

scmt_lock(){
    local LOCKFILE
    LOCKFILE="$RUNDIR"/"$1"/lock
    exec 3>"$LOCKFILE"
    flock -n -x 3 || \
        scmt_error "There is pending operation for \"$1\". Try again later."
}

## ----------------------------------------------------------------------
## Invocation modes
## ----------------------------------------------------------------------

scmt_list(){
    local NAME STATUS MEM CORES VNC MAC
    scmt_help list
    {
        if scmt_is_verbose; then
            echo "Name\tStatus\tMemTot\tCores\tVNC\tMAC"
        else
            echo "Name\tStatus"
        fi
        for NAME in `scmt_containers`; do
            STATUS="Stopped"
            scmt_is_running "$NAME" && STATUS="Running"
            if scmt_is_verbose; then
                scmt_container_config "$NAME"
                [ $VNC = 0 ] && VNC="no"
                echo "$NAME\t$STATUS\t${MEM}M\t$CORES\t$VNC\t$MAC"
            else
                echo "$NAME\t$STATUS"
            fi
        done
    } | expand --tabs=11,19,26,32,36
}

scmt_add(){
    local MEM CORES MAC VNC START NAME TGTDIR URL RETVAL
    scmt_verbose "Entering 'add' mode..."
    scmt_help add
    while true; do
        case "$1" in
            --verbose) shift ;;
            --trace) shift ;;
            --quiet) shift ;;
            --mem) MEM="$2" ; shift 2 ;;
            --cores) CORES="$2" ; shift 2 ;;
            --mac) MAC="$2" ; shift 2 ;;
            --vnc) VNC=`scmt_free_vnc_port` shift ;;
            --start) START="yes" ;;
            --) shift ; break ;;
            -*) scmt_error "Unknown option: \"$1\"" ;;
            *) break ;;
        esac
    done
    [ -z "$MEM" ] && MEM=128
    [ -z "$CORES" ] && CORES=1
    [ -z "$MAC" ] && MAC=`scmt_gen_mac`
    [ -z "$VNC" ] && VNC=0
    [ -z "$1" ] && scmt_error "Container name undefined"
    NAME=`scmt_check_name "$1"` || exit $?
    scmt_verbose "$NAME == MEM=${MEM}M; CORES=${CORES}; MAC=${MAC}; VNC=${VNC}"
    TGTDIR="$RUNDIR"/"$NAME"
    [ -f "$TGTDIR"/config ] && \
        scmt_error "container with name \"$NAME\" already exists"
    rm -rf -- "$TGTDIR" || exit 1
    mkdir -p "$TGTDIR" || exit 1
    scmt_lock "$NAME"
    mkdir -p "$TGTDIR"/run || exit 1
    URL="$2"
    scmt_deploy_image "$URL" "$TGTDIR"
    RETVAL=$?
    if [ $RETVAL != 0 ]; then
        rm -rvf -- "$TGTDIR"
        exit $RETVAL
    fi
    scmt_verbose "Creating container config..."
    cat > "$TGTDIR"/config <<-EOF
MEM=$MEM
CORES=$CORES
MAC=$MAC
VNC=$VNC
START=no
EOF
    if [ "$START" = "yes" ]; then
        scmt_start "$NAME"
    else
        scmt_verbose "Done"
    fi
}

scmt_del(){
    local NAME
    scmt_verbose "Entering 'del' mode..."
    scmt_help del
    while true; do
        case "$1" in
            --verbose) shift ;;
            --trace) shift ;;
            --quiet) shift ;;
            --) shift ; break ;;
            -*) scmt_error "Unknown option: \"$1\"" ;;
            *) break ;;
        esac
    done
    NAME=`scmt_check_real_name "$1"` || exit $?
    scmt_lock "$NAME"
    scmt_stop "$NAME"
    scmt_verbose "Removing container files..."
    rm -rf -- "$RUNDIR"/"$NAME"/*
    [ -d "$RUNDIR"/"$NAME" ] || \
        scmt_warning "Some files was not removed"
    scmt_verbose "Deleted"
}

scmt_start(){
    local NAME TAP OPT_CORES OPT_VNC CORES VNC MAC CONFIG
    scmt_verbose "Entering 'start' mode..."
    scmt_help start
    while true; do
        case "$1" in
            --verbose) shift ;;
            --trace) shift ;;
            --quiet) shift ;;
            --) shift ; break ;;
            -*) scmt_error "Unknown option: \"$1\"" ;;
            *) break ;;
        esac
    done
    NAME=`scmt_check_real_name "$1"` || exit $?
    scmt_lock "$NAME"
    scmt_container_config "$NAME"
    scmt_verbose "Preparing network interface..."
    TAP="scmt-$NAME"
    set -e
    sudo -n \
        tunctl -d "$TAP" > /dev/null 2>&1
    sudo -n \
        tunctl -u `id --user --name` -t "$TAP"
    sudo -n \
        ip link set "$TAP" up
    sudo -n \
        brctl addif "$NET_BRIDGE" "$TAP"
    OPT_CORES=""
    [ $CORES -gt 1 ] && OPT_CORES="-smp $CORES"
    OPT_VNC=""
    [ $VNC -gt 0 ] && OPT_VNC="-vnc :$VNC"
    scmt_verbose "Starting container..."
    cd "$RUNDIR"/"$NAME"/run
    kvm \
        -m "${MEM}M" \
        $OPT_CORES \
        -name "$NAME" \
        -drive file=image.qcow2,index=0,media=disk,cache=none,format=qcow2 \
        -net nic,macaddr="$MAC",vlan=0,model=virtio \
        -net tap,vlan=0,ifname="$TAP",script=no \
        -pidfile pid \
        -nographic \
        -monitor unix:"`scmt_mon_sock_name \"$NAME\"`,server,nowait" \
        $OPT_VNC &
    CONFIG=`scmt_config_name "$NAME"`
    grep -Ev '^START=.*' "$CONFIG" > "${CONFIG}.new"
    echo "START=yes" >> "${CONFIG}.new"
    mv -f "${CONFIG}.new" "$CONFIG"
    set +e
    scmt_verbose "Started"
}

scmt_start_all(){
    local NAME START
    scmt_verbose "Entering 'start-all' mode..."
    scmt_help start-all
    for NAME in `scmt_containers`; do
        if ! scmt_is_running "$NAME"; then
            scmt_container_config "$NAME"
            if [ "$START" = "yes" ]; then
                scmt_is_verbose && echo -n "Starting \"$NAME\"..."
                scmt_start "$NAME"
            fi
        else
            scmt_verbose "\"$NAME\" already running - skipping"
        fi
    done
}

scmt_stop(){
    local MAX_WAIT_TIME NAME CONFIG TAP PIDFILE
    scmt_verbose "Entering 'stop' mode..."
    scmt_help stop
    while true; do
        case "$1" in
            --verbose) shift ;;
            --trace) shift ;;
            --quiet) shift ;;
            --wait) MAX_WAIT_TIME="$2"; shift 2 ;;
            --) shift ; break ;;
            -*) scmt_error "Unknown option: \"$1\"" ;;
            *) break ;;
        esac
    done
    NAME=`scmt_check_real_name "$1"` || exit $?
    scmt_lock "$NAME"
    CONFIG=`scmt_config_name "$NAME"`
    grep -Ev '^START=.*' "$CONFIG" > "${CONFIG}.new"
    echo "START=no" >> "${CONFIG}.new"
    mv -f "${CONFIG}.new" "$CONFIG"
    scmt_powerdown "$NAME"
    scmt_verbose "Waiting container \"$NAME\" to stop..."
    scmt_wait_stop "$NAME" || \
        scmt_warning "Timeout waiting container \"$NAME\" to stop"
    scmt_do_kill "$NAME"
    scmt_is_running "$NAME" && \
        scmt_error "Unable to stop \"$NAME\""
    scmt_shutdown_cleanup "$NAME"
    scmt_verbose "Stopped"
}

scmt_stop_all(){
    local NAME
    scmt_verbose "Entering 'stop-all' mode..."
    scmt_help stop-all
    while true; do
        case "$1" in
            --verbose) shift ;;
            --trace) shift ;;
            --quiet) shift ;;
            --wait) export MAX_WAIT_TIME="$2"; shift 2 ;;
            --) shift ; break ;;
            -*) scmt_error "Unknown option: \"$1\"" ;;
            *) break ;;
        esac
    done
    export BASENAME
    export VERBOSE
    export TRACE
    export QUIET
    for NAME in `scmt_containers`; do
        if scmt_is_running "$NAME"; then
            (
                scmt_lock "$NAME"
                scmt_powerdown "$NAME"
                scmt_verbose "Waiting container \"$NAME\" to stop..."
                scmt_wait_stop "$NAME" || \
                    scmt_warning "Timeout waiting container \"$NAME\" to stop"
                scmt_do_kill "$NAME"
                scmt_is_running "$NAME" && \
                    scmt_error "Unable to stop \"$NAME\""
                scmt_shutdown_cleanup "$NAME"
            ) &
        fi
    done
    wait
}

scmt_kill(){
    local NAME CONFIG TAP PIDFILE
    scmt_verbose "Entering 'kill' mode..."
    scmt_help kill
    while true; do
        case "$1" in
            --verbose) shift ;;
            --trace) shift ;;
            --quiet) shift ;;
            --) shift ; break ;;
            -*) scmt_error "Unknown option: \"$1\"" ;;
            *) break ;;
        esac
    done
    NAME=`scmt_check_real_name "$1"` || exit $?
    scmt_lock "$NAME"
    CONFIG=`scmt_config_name "$NAME"`
    grep -Ev '^START=.*' "$CONFIG" > "${CONFIG}.new"
    echo "START=no" >> "${CONFIG}.new"
    mv -f "${CONFIG}.new" "$CONFIG"
    scmt_do_kill "$NAME"
    scmt_is_running "$NAME" && \
        scmt_error "Unable to stop \"$NAME\""
    scmt_shutdown_cleanup "$NAME"
    scmt_verbose "Stopped"
}

scmt_status(){
    local NAME
    scmt_verbose "Entering 'status' mode..."
    scmt_help status
    while true; do
        case "$1" in
            --verbose) shift ;;
            --trace) shift ;;
            --quiet) shift ;;
            --) shift ; break ;;
            -*) scmt_error "Unknown option: \"$1\"" ;;
            *) break ;;
        esac
    done
    NAME=`scmt_check_real_name "$1"` || exit $?
    if scmt_pid "$NAME" > /dev/null; then
        echo "Running"
    else
        echo "Stopped"
    fi
}

## ----------------------------------------------------------------------
## Main
## ----------------------------------------------------------------------

echo "$@" | grep -E -- '^(.*\W)?--trace(\W.*)?$' > /dev/null && set -x

BASENAME=`basename $0`

echo "$@" | grep -E -- '^(.*\W)?--verbose(\W.*)?$' > /dev/null
VERBOSE=$?

echo "$@" | grep -E -- '^(.*\W)?--quiet(\W.*)?$' > /dev/null
QUIET=$?

echo "$@" | grep -E -- '^(.*\W)?(--help|-h)(\W.*)?$' > /dev/null
HELP=$?

# use config file if such exists
[ -z "$SCMT_CONFIG" ] && SCMT_CONFIG="/etc/scmt.conf"
if [ -f "$SCMT_CONFIG" ]; then
    . "$SCMT_CONFIG" || \
        scmt_error "failed to read config file \"$SCMT_CONFIG\""
fi

[ -z "$RUNDIR" ] && RUNDIR="./run"
[ -z "$TMPDIR" ] && TMPDIR="/tmp"
[ -z "$NET_BRIDGE" ] && NET_BRIDGE="br0"

mkdir -p "$RUNDIR" || exit 1

[ $# = 0 ] && HELP=0 && scmt_help base
MODE="$1"
shift

case "$MODE" in
    l|li|lis|list)
        scmt_list ;;
    a|ad|add)
        scmt_add "$@" ;;
    d|de|del|dele|delet|delete)
        scmt_del "$@" ;;
    start)
        scmt_start "$@" ;;
    start-all)
        scmt_start_all ;;
    stop)
        scmt_stop "$@" ;;
    stop-all)
        scmt_stop_all "$@" ;;
    k|ki|kil|kill)
        scmt_kill "$@" ;;
    stat|statu|status)
        scmt_status "$@" ;;
    *) HELP=0 ; scmt_help base ;;
esac

