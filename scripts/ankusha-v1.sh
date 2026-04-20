#!/bin/bash
# ==============================================================================
# █████╗ ███╗ ██╗██╗ ██╗██╗ ██╗███████╗██╗ ██╗ █████╗
# ██╔══██╗████╗ ██║██║ ██╔╝██║ ██║██╔════╝██║ ██║██╔══██╗
# ███████║██╔██╗ ██║█████╔╝ ██║ ██║███████╗███████║███████║
# ██╔══██║██║╚██╗██║██╔═██╗ ██║ ██║╚════██║██╔══██║██╔══██║
# ██║ ██║██║ ╚████║██║ ██╗╚██████╔╝███████║██║ ██║██║ ██║
# ╚═╝ ╚═╝╚═╝ ╚═══╝╚═╝ ╚═╝ ╚═════╝ ╚══════╝╚═╝ ╚═╝╚═╝ ╚═╝
#
# HPC Cluster Monitoring Dashboard — v1.0 - The Mythical
# "The Goad of the Great White Elephant."
# https://github.com/PSaiSurya/Ankusha
# ==============================================================================

set -o pipefail

# ==============================================================================
# IDENTITY
# ==============================================================================
readonly TOOL_NAME="ANKUSHA"
readonly TOOL_TAGLINE="The Goad of the Great White Elephant."
readonly VERSION="1.0"
readonly DEFAULT_PARTITION="default"
readonly DEFAULT_REFRESH=30
readonly MIN_SAFE_REFRESH=30
readonly DEFAULT_TZ="Asia/Kolkata"
MEMORY_OVERRIDE_MB=0
PENDING_JOBS_DATA=""

# ==============================================================================
# COLORS
# ==============================================================================
if command -v tput >/dev/null 2>&1 && [ -t 1 ]; then
    readonly C_RESET=$(tput sgr0)
    readonly C_BOLD=$(tput bold)
    readonly C_DIM=$(tput dim)
    readonly C_SUCCESS=$(tput setaf 82)
    readonly C_SUCCESS2=$(tput setaf 120)
    readonly C_WARNING=$(tput setaf 208)
    readonly C_WARNING2=$(tput setaf 220)
    readonly C_ERROR=$(tput setaf 196)
    readonly C_ERROR2=$(tput setaf 203)
    readonly C_MUTED=$(tput setaf 244)
    readonly C_HEADER=$(tput setaf 45)
    readonly C_BORDER=$(tput setaf 238)
    readonly C_LABEL=$(tput setaf 255)
    readonly C_VALUE=$(tput setaf 159)
    readonly C_HIGHLIGHT=$(tput setaf 227)
    readonly C_HIGHLIGHT2=$(tput setaf 187)
    readonly C_GPU=$(tput setaf 206)
    readonly C_MEM=$(tput setaf 85)
    readonly C_CPU=$(tput setaf 39)
    readonly C_TAG1=$(tput setaf 213)
    readonly C_TAG2=$(tput setaf 226)
    readonly C_TAG3=$(tput setaf 120)
else
    readonly C_RESET='' C_BOLD='' C_DIM=''
    readonly C_SUCCESS='' C_SUCCESS2='' C_WARNING='' C_WARNING2=''
    readonly C_ERROR='' C_ERROR2='' C_MUTED=''
    readonly C_HEADER='' C_BORDER='' C_LABEL='' C_VALUE=''
    readonly C_HIGHLIGHT='' C_HIGHLIGHT2='' C_GPU='' C_MEM='' C_CPU=''
    readonly C_TAG1='' C_TAG2='' C_TAG3=''
fi

# ==============================================================================
# TERMINAL
# ==============================================================================
get_term_width()  { local w; w=$(tput cols  2>/dev/null); printf '%s' "${w:-135}"; }
get_term_height() { local h; h=$(tput lines 2>/dev/null); printf '%s' "${h:-40}";  }

# ==============================================================================
# TIMEZONE
# ==============================================================================
ACTIVE_TZ=""
ACTIVE_TZ_LABEL=""

resolve_timezone() {
    local req="${1:-$DEFAULT_TZ}"
    if TZ="$req" date >/dev/null 2>&1; then
        ACTIVE_TZ="$req"
    else
        printf '%s%s: Warning: Unknown timezone "%s", falling back to UTC%s\n' \
            "$C_WARNING" "$TOOL_NAME" "$req" "$C_RESET" >&2
        ACTIVE_TZ="UTC"
    fi
    ACTIVE_TZ_LABEL=$(TZ="$ACTIVE_TZ" date '+%Z' 2>/dev/null)
    [ -z "$ACTIVE_TZ_LABEL" ] && ACTIVE_TZ_LABEL="$ACTIVE_TZ"
}

fmt_time_12h() {
    local raw="$1"
    # FIX: explicit if block — original && chaining had operator-precedence bug
    # that silently swallowed the printf '-' when raw was empty.
    if [ -z "$raw" ] || [ "$raw" = "Unknown" ] || [ "$raw" = "-" ]; then
        printf '-'
        return
    fi
    local dt; dt=$(printf '%s' "$raw" | sed 's/T/ /' | cut -c1-16)
    local datep timep yr mo dy hh mm rest
    datep="${dt%% *}"; timep="${dt##* }"
    yr="${datep%%-*}"; rest="${datep#*-}"; mo="${rest%%-*}"; dy="${rest##*-}"
    hh="${timep%%:*}"; mm="${timep##*:}"
    [[ "$hh" =~ ^[0-9]+$ ]] || { printf '%s' "$raw"; return; }
    local ampm="AM" hh12=$(( 10#$hh ))
    if   [ "$hh12" -eq 0  ]; then hh12=12; ampm="AM"
    elif [ "$hh12" -eq 12 ]; then ampm="PM"
    elif [ "$hh12" -gt 12 ]; then hh12=$(( hh12-12 )); ampm="PM"
    fi
    printf '%02d-%02d-%s %02d:%s %s' "$dy" "$mo" "$yr" "$hh12" "$mm" "$ampm"
}

current_time_fmt() { TZ="$ACTIVE_TZ" date '+%d-%m-%Y %I:%M %p'; }

# ==============================================================================
# ALIGNMENT
# ==============================================================================
pad() {
    local text="$1" vw="$2" align="${3:-l}"
    [[ "$vw" =~ ^[0-9]+$ ]] || vw=10
    [ "$vw" -eq 0 ] && return
    local len=${#text}
    if [ "$len" -ge "$vw" ]; then
        [ "$vw" -le 2 ] && printf '%s' "${text:0:$vw}" \
            || printf '%s~~' "${text:0:$(( vw-2 ))}"; return
    fi
    local p=$(( vw-len ))
    case "$align" in
        r) printf '%*s%s'       "$p" '' "$text" ;;
        c) local l=$(( p/2 )) r=$(( p-p/2 ))
           printf '%*s%s%*s' "$l" '' "$text" "$r" '' ;;
        *) printf '%s%*s' "$text" "$p" '' ;;
    esac
}

# ==============================================================================
# PRINT HELPERS
# ==============================================================================
print_line() {
    local width="${1:-80}" char="${2:-=}" color="${3:-$C_BORDER}"
    [[ "$width" =~ ^[0-9]+$ ]] || width=80
    printf '%s' "$color"
    printf '%*s' "$width" '' | tr ' ' "${char:0:1}"
    printf '%s\n' "$C_RESET"
}

# ==============================================================================
# MATH & COLOR BY VALUE
# ==============================================================================
calc_pct() {
    local u="$1" t="$2"
    [[ "$u" =~ ^[0-9]+$ ]] || u=0; [[ "$t" =~ ^[0-9]+$ ]] || t=0
    [ "$t" -eq 0 ] && echo "0" && return
    echo $(( u*100/t ))
}

state_color() {
    case "$1" in
        alloc*|ALLOC*)                          printf '%s' "$C_ERROR"    ;;
        mix*|MIX*)                              printf '%s' "$C_WARNING"  ;;
        idle*|IDLE*)                            printf '%s' "$C_SUCCESS"  ;;
        down*|DOWN*)                            printf '%s' "$C_ERROR2"   ;;
        drain*|DRAIN*)                          printf '%s' "$C_WARNING2" ;;
        RUNNING|R)                              printf '%s' "$C_SUCCESS"  ;;
        PENDING|PD)                             printf '%s' "$C_WARNING"  ;;
        FAILED|F|CANCELLED|CA|TIMEOUT|TO)       printf '%s' "$C_ERROR"    ;;
        COMPLETED|CD)                           printf '%s' "$C_SUCCESS2" ;;
        *)                                      printf '%s' "$C_MUTED"    ;;
    esac
}

usage_color() {
    local p="$1"; [[ "$p" =~ ^[0-9]+$ ]] || p=0
    if   [ "$p" -ge 90 ]; then printf '%s' "$C_ERROR"
    elif [ "$p" -ge 70 ]; then printf '%s' "$C_WARNING"
    elif [ "$p" -ge 50 ]; then printf '%s' "$C_WARNING2"
    else                        printf '%s' "$C_SUCCESS"
    fi
}

# ==============================================================================
# PROGRESS BAR
# ==============================================================================
draw_bar() {
    local used="$1" total="$2" bar_width="${3:-16}" color_override="${4:-}"
    [[ "$used"      =~ ^[0-9]+$ ]] || used=0
    [[ "$total"     =~ ^[0-9]+$ ]] || total=0
    [[ "$bar_width" =~ ^[0-9]+$ ]] || bar_width=16
    if [ "$total" -eq 0 ]; then
        printf '%s' "$C_MUTED"; printf '%*s' "$bar_width" '' | tr ' ' '-'
        printf '%s 0%%' "$C_RESET"; return
    fi
    local pct filled empty color
    pct=$(calc_pct "$used" "$total")
    filled=$(( pct*bar_width/100 )); empty=$(( bar_width-filled ))
    color="${color_override:-$(usage_color "$pct")}"
    printf '%s' "$color"
    [ "$filled" -gt 0 ] && printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%s' "$C_BORDER"
    [ "$empty"  -gt 0 ] && printf '%*s' "$empty"  '' | tr ' ' '.'
    printf '%s %3d%%' "$C_RESET" "$pct"
}

# ==============================================================================
# MEMORY FORMATTERS
# ==============================================================================
fmt_mem() {
    local mb="$1"; [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
    if [ "$mb" -ge 1048576 ]; then
        local tw=$(( mb/1048576 )) tf=$(( (mb%1048576)*10/1048576 ))
        [ "$tf" -eq 0 ] && printf '%dTB' "$tw" || printf '%d.%dTB' "$tw" "$tf"
    elif [ "$mb" -ge 1024 ]; then
        local gw=$(( mb/1024 )) gf=$(( (mb%1024)*10/1024 ))
        [ "$gf" -eq 0 ] && printf '%dGB' "$gw" || printf '%d.%dGB' "$gw" "$gf"
    else printf '%dMB' "$mb"; fi
}

fmt_mem_free() {
    local mb="$1"; [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
    if [ "$mb" -ge 1048576 ]; then
        local tw=$(( mb/1048576 )) tf=$(( (mb%1048576)*10/1048576 ))
        [ "$tf" -eq 0 ] && printf '%dTB' "$tw" || printf '%d.%dTB' "$tw" "$tf"
    else
        local gw=$(( mb/1024 )) gf=$(( (mb%1024)*10/1024 ))
        printf '%d.%dGB' "$gw" "$gf"
    fi
}

# ==============================================================================
# GPU PARSING
# ==============================================================================
parse_gpu_total() {
    local gres="$1" n
    n=$(printf '%s' "$gres" | grep -oP 'gres/gpu=\K[0-9]+' | head -1)
    [ -n "$n" ] && { printf '%s' "$n"; return; }
    n=$(printf '%s' "$gres" | grep -oP 'gpu(?::[^:,(]+)?:\K[0-9]+' | head -1)
    [ -n "$n" ] && { printf '%s' "$n"; return; }
    n=$(printf '%s' "$gres" | grep -oP 'gpu=\K[0-9]+' | head -1)
    printf '%s' "${n:-0}"
}

parse_gpu_from_gres_used() {
    local n
    n=$(printf '%s' "$1" | grep -oP 'gpu(?::[^:,(]+)?:\K[0-9]+' | head -1)
    printf '%s' "${n:-0}"
}

# ==============================================================================
# PARTITION VALIDATION
# ==============================================================================
validate_partition() {
    local partition="$1" all_flag="${2:-false}"

    # FIX: use scontrol ping — the canonical Slurm liveness check.
    # sinfo --version is not a portable flag across all Slurm versions.
    if ! scontrol ping >/dev/null 2>&1; then
        printf '%s%s: Error: slurmctld is not responding (scontrol ping failed).%s\n' \
            "$C_ERROR" "$TOOL_NAME" "$C_RESET" >&2
        exit 1
    fi

    # --all mode does not target a single partition
    [ "$all_flag" = "true" ] && return 0

    # Check the requested partition exists
    if ! sinfo -p "$partition" -h -o "%P" 2>/dev/null | grep -q .; then
        printf '%s%s: Error: Partition "%s" not found or not accessible.%s\n' \
            "$C_ERROR" "$TOOL_NAME" "$partition" "$C_RESET" >&2
        printf '\n%sAvailable partitions:%s\n' "$C_LABEL" "$C_RESET" >&2
        sinfo -h -o "  %s%P%s — %s nodes, %s%s%s state" \
            "$C_VALUE" "$C_RESET" "%D" "$C_MUTED" "%a" "$C_RESET" \
            2>/dev/null >&2 \
            || printf '  %s(could not retrieve partition list)%s\n' \
                "$C_MUTED" "$C_RESET" >&2
        printf '\n%sRun with -p <partition> or --all%s\n' \
            "$C_MUTED" "$C_RESET" >&2
        exit 1
    fi
}

# ==============================================================================
# NODE CACHE
# ==============================================================================
NODE_CACHE=""

load_node_cache() {
    local partition="$1" all_flag="${2:-false}" node_list

    # Show loading feedback immediately — erased by \r once data arrives
    printf '%s Querying cluster nodes...%s' "$C_MUTED" "$C_RESET" >&2

    if [ "$all_flag" = "true" ]; then
        NODE_CACHE=$(timeout 15s scontrol show node 2>/dev/null)
    else
        node_list=$(sinfo -p "$partition" -N -h -o "%n" 2>/dev/null \
            | sort -u | tr '\n' ',')
        node_list="${node_list%,}"
        if [ -n "$node_list" ]; then
            # FIX: fetch only partition nodes, not --all nodes.
            NODE_CACHE=$(timeout 15s scontrol show node "$node_list" 2>/dev/null)
        else
            NODE_CACHE=""
        fi
    fi

    # Erase the loading message — \r returns to line start, spaces overwrite
    printf '\r%*s\r' "40" "" >&2
}

get_node_metrics() {
    local node="$1" raw
    raw=$(printf '%s' "$NODE_CACHE" \
        | awk -v n="$node" '
            /^NodeName=/ { found=($0 ~ ("NodeName="n"( |$)")) }
            found        { print }
            found && /^[[:space:]]*$/ { exit }
        ')
    nm_cpu_total=$(printf '%s' "$raw" | grep -oP 'CPUTot=\K[0-9]+'   | head -1)
    nm_cpu_alloc=$(printf '%s' "$raw" | grep -oP 'CPUAlloc=\K[0-9]+' | head -1)
    nm_cpu_total=${nm_cpu_total:-0}; nm_cpu_alloc=${nm_cpu_alloc:-0}
    local rm fm
    rm=$(printf '%s' "$raw" | grep -oP 'RealMemory=\K[0-9]+' | head -1)
    fm=$(printf '%s' "$raw" | grep -oP 'FreeMem=\K[0-9]+'    | head -1)
    
    # FIX: Allow memory override when Slurm RealMemory is incorrect
    if [ "$MEMORY_OVERRIDE_MB" -gt 0 ]; then
        nm_mem_total=$MEMORY_OVERRIDE_MB
    else
        nm_mem_total=${rm:-0}
    fi
    nm_mem_free=${fm:-0}
    nm_mem_used=$(( nm_mem_total-nm_mem_free ))
    [ "$nm_mem_used" -lt 0 ] && nm_mem_used=0
    
    local cfg_tres gres_line gres_used_line alloc_tres
    cfg_tres=$(      printf '%s' "$raw" | grep -oP 'CfgTRES=\S+'   | head -1)
    gres_line=$(     printf '%s' "$raw" | grep -oP 'Gres=\S+'      | head -1)
    gres_used_line=$(printf '%s' "$raw" | grep -oP 'GresUsed=\S+'  | head -1)
    alloc_tres=$(    printf '%s' "$raw" | grep -oP 'AllocTRES=\S+' | head -1)
    nm_gpu_total=$(parse_gpu_total "$cfg_tres")
    [ "$nm_gpu_total" = "0" ] && nm_gpu_total=$(parse_gpu_total "$gres_line")
    nm_gpu_total=${nm_gpu_total:-0}
    nm_gpu_used=$(parse_gpu_from_gres_used "$gres_used_line")
    if [ "$nm_gpu_used" = "0" ] && [ -n "$alloc_tres" ]; then
        nm_gpu_used=$(printf '%s' "$alloc_tres" \
            | grep -oP 'gres/gpu=\K[0-9]+' | head -1)
        nm_gpu_used=${nm_gpu_used:-0}
    fi
    
    for v in nm_cpu_total nm_cpu_alloc nm_mem_total nm_mem_used \
              nm_mem_free nm_gpu_total nm_gpu_used; do
        eval "[[ \"\${$v}\" =~ ^[0-9]+\$ ]] || $v=0"
    done
}

# ==============================================================================
# RESOURCE STRING
# ==============================================================================
build_res_str() {
    local cpus="$1" mem_raw="$2" gres="$3" num_nodes="$4"
    [[ "$cpus"      =~ ^[0-9]+$ ]] || cpus=0
    [[ "$num_nodes" =~ ^[0-9]+$ ]] || num_nodes=1

    # Normalise mem to integer MB regardless of suffix
    local mem=0
    if [[ "$mem_raw" =~ ^([0-9]+)([KMGTkmgt])?$ ]]; then
        local _mv="${BASH_REMATCH[1]}" _mu="${BASH_REMATCH[2],,}"
        case "$_mu" in
            k) mem=$(( _mv / 1024 ))      ;;
            m) mem=$_mv                   ;;
            g) mem=$(( _mv * 1024 ))      ;;
            t) mem=$(( _mv * 1048576 ))   ;;
            *) mem=$_mv                   ;;
        esac
    fi

    local gc; gc=$(parse_gpu_total "$gres"); [[ "$gc" =~ ^[0-9]+$ ]] || gc=0
    local res="${cpus}C"
    [ "$mem" -gt 0 ] && res="${res}, $(fmt_mem "$mem") RAM"
    if [ "$gc" -gt 0 ]; then
        local tg=$(( gc*num_nodes ))
        [ "$num_nodes" -gt 1 ] \
            && res="${res}, ${gc}GPU/node (${tg} total)" \
            || res="${res}, ${gc} GPU(s)"
    fi
    res="${res}, ${num_nodes} Node(s)"
    printf '%s' "$res"
}

# ==============================================================================
# HELP
# ==============================================================================
show_help() {
    local w; w=$(get_term_width)

    printf '\n'
    printf '%s █████╗ ███╗ ██╗██╗ ██╗██╗ ██╗███████╗██╗ ██╗ █████╗%s\n'          "$C_TAG1" "$C_RESET"
    printf '%s ██╔══██╗████╗ ██║██║ ██╔╝██║ ██║██╔════╝██║ ██║██╔══██╗%s\n'       "$C_TAG2" "$C_RESET"
    printf '%s ███████║██╔██╗ ██║█████╔╝ ██║ ██║███████╗███████║███████║%s\n'      "$C_TAG3" "$C_RESET"
    printf '%s ██╔══██║██║╚██╗██║██╔═██╗ ██║ ██║╚════██║██╔══██║██╔══██║%s\n'     "$C_TAG1" "$C_RESET"
    printf '%s ██║ ██║██║ ╚████║██║ ██╗╚██████╔╝███████║██║ ██║██║ ██║%s\n'       "$C_TAG2" "$C_RESET"
    printf '%s ╚═╝ ╚═╝╚═╝ ╚═══╝╚═╝ ╚═╝ ╚═════╝ ╚══════╝╚═╝ ╚═╝╚═╝ ╚═╝%s\n'     "$C_TAG3" "$C_RESET"
    printf '\n'
    printf '  %s%s%s\n'        "$C_DIM"   "$TOOL_TAGLINE" "$C_RESET"
    printf '  %sVersion %s%s%s\n' "$C_MUTED" "$C_VALUE" "$VERSION" "$C_RESET"
    printf '\n'
    print_line "$w" "=" "$C_HEADER"
    printf '\n  %sUSAGE%s   ankusha [OPTIONS]\n\n' "$C_LABEL$C_BOLD" "$C_RESET"

    local fmt='  %s%-26s%s %s\n'
    printf "$fmt" "$C_HIGHLIGHT" "-p, --partition PARTITION" "$C_RESET" \
        "Partition to monitor (default: $DEFAULT_PARTITION)"
    printf "$fmt" "$C_HIGHLIGHT" "-u, --user USER"           "$C_RESET" \
        "Show jobs for USER (default: current user)"
    printf "$fmt" "$C_HIGHLIGHT" "-i, --interactive [SECS]"  "$C_RESET" \
        "Live refresh; interval in seconds (default: ${DEFAULT_REFRESH}s)"
    printf "$fmt" "$C_HIGHLIGHT" "--all"                     "$C_RESET" \
        "Monitor all partitions on the cluster"
    printf "$fmt" "$C_HIGHLIGHT" "--override-mem SIZE"       "$C_RESET" \
        "Override node memory total (e.g., 1TB, 1024GB)"
    printf "$fmt" "$C_HIGHLIGHT" ""                          "$C_RESET" \
        "Use when Slurm RealMemory is incorrect"
    printf "$fmt" "$C_HIGHLIGHT" "--tz TIMEZONE"             "$C_RESET" \
        "Timestamps timezone, e.g. UTC, America/New_York"
    printf "$fmt" "$C_HIGHLIGHT" ""                          "$C_RESET" \
        "(default: $DEFAULT_TZ)"
    printf "$fmt" "$C_HIGHLIGHT" "-h, --help"                "$C_RESET" \
        "Show this help and exit"

    printf '\n  %sEXAMPLES%s\n' "$C_LABEL$C_BOLD" "$C_RESET"
    printf '  %sankusha%s                    Snapshot, default partition\n'        "$C_VALUE" "$C_RESET"
    printf '  %sankusha -p gpu%s             Snapshot, "gpu" partition\n'          "$C_VALUE" "$C_RESET"
    printf '  %sankusha -u alice -p highmem%s Jobs for user alice\n'               "$C_VALUE" "$C_RESET"
    printf '  %sankusha -i%s                 Live mode, 30 s refresh\n'            "$C_VALUE" "$C_RESET"
    printf '  %sankusha -i 60 -p gpu%s       Live mode, 60 s\n'                   "$C_VALUE" "$C_RESET"
    printf '  %sankusha --all%s              All partitions\n'                     "$C_VALUE" "$C_RESET"
    printf '  %sankusha --all -i 120%s       All partitions, 2 min live refresh\n' "$C_VALUE" "$C_RESET"
    printf '  %sankusha --tz UTC%s           UTC timestamps\n'                     "$C_VALUE" "$C_RESET"
    printf '  %sankusha --override-mem 1TB%s  Force 1TB memory per node\n'         "$C_VALUE" "$C_RESET"

    printf '\n  %sNOTES%s\n' "$C_LABEL$C_BOLD" "$C_RESET"
    printf '  * Refresh intervals below %ds require explicit confirmation.\n' \
        "$MIN_SAFE_REFRESH"
    printf '  * Snapshot mode is safe for cron; interactive mode is not.\n'
    printf '  * sacct and sprio are optional; sections degrade gracefully.\n'
    printf '  * No external dependencies: pure Bash + standard Slurm CLI.\n'
    printf '\n'
    print_line "$w" "=" "$C_HEADER"
    printf '\n'
}

# ==============================================================================
# HEADER
# ==============================================================================
draw_header() {
    local partition="$1" target_user="$2" mode="${3:-snapshot}"
    local current_user ts w
    current_user=$(whoami); ts=$(current_time_fmt); w=$(get_term_width)
    print_line "$w" "=" "$C_HEADER"
    printf '  %s%s' "$C_BOLD" "$C_RESET"
    printf '%sA%sN%sK%sU%sS%sH%sA%s' \
        "$C_TAG1" "$C_TAG2" "$C_TAG3" \
        "$C_TAG1" "$C_TAG2" "$C_TAG3" "$C_TAG1" "$C_RESET"
    printf '  %s%s%s' "$C_DIM" "$TOOL_TAGLINE" "$C_RESET"
    printf '  %sv%s%s\n' "$C_MUTED" "$VERSION" "$C_RESET"
    printf '  %sUser:%s %s%s%s' "$C_LABEL" "$C_RESET" "$C_HIGHLIGHT" "$target_user" "$C_RESET"
    [ "$target_user" != "$current_user" ] && \
        printf '  %s(viewed by %s)%s' "$C_MUTED" "$current_user" "$C_RESET"
    printf '  %sPartition:%s %s%s%s%s' \
        "$C_LABEL" "$C_RESET" "$C_GPU" "$C_BOLD" "$partition" "$C_RESET"
    printf '  %s%s %s%s\n' "$C_MUTED" "$ts" "$ACTIVE_TZ_LABEL" "$C_RESET"
    print_line "$w" "=" "$C_HEADER"
}

# ==============================================================================
# CLUSTER OVERVIEW
# ==============================================================================
draw_quick_stats() {
    local partition="$1" all_flag="${2:-false}" w
    w=$(get_term_width)
    printf '%s%sCLUSTER OVERVIEW%s\n' "$C_BOLD" "$C_HEADER" "$C_RESET"
    print_line "$w" "-" "$C_BORDER"

    local sf="" sq=""
    [ "$all_flag" = "false" ] && sf="-p $partition" && sq="-p $partition"

    local ni=0 na=0 nm=0 nd=0
    local _eval_str
    _eval_str=$(sinfo $sf -N -h -o "%t" 2>/dev/null | awk '
        /^idle/  { ni++ }
        /^alloc/ { na++ }
        /^mix/   { nm++ }
        /^down/  { nd++ }
        END { printf "ni=%d na=%d nm=%d nd=%d", ni+0, na+0, nm+0, nd+0 }
    ')
    # FIX: validate awk output format before eval to prevent executing
    # error messages if sinfo fails.
    if [[ "$_eval_str" =~ ^ni=[0-9]+\ na=[0-9]+\ nm=[0-9]+\ nd=[0-9]+$ ]]; then
        eval "$_eval_str"
    else
        ni=0; na=0; nm=0; nd=0
    fi

    # FIX: single squeue call for running jobs - get both count and GPU usage
    local _rq_data
    _rq_data=$(squeue $sq -t R -h -o "%b" 2>/dev/null)
    local jr
    jr=$(printf '%s\n' "$_rq_data" | grep -c '.' || echo 0)

    # FIX: fetch detailed pending jobs data once for reuse in queue section
    PENDING_JOBS_DATA=$(squeue $sq -t PD -h -o "%i|%u|%M|%C|%m|%b|%D|%r" 2>/dev/null)
    local jp
    jp=$(printf '%s\n' "$PENDING_JOBS_DATA" | grep -c '.' || echo 0)

    # FIX: derive GPU total from NODE_CACHE — no additional sinfo call needed.
    local gt
    gt=$(printf '%s' "$NODE_CACHE" \
        | grep -oP 'CfgTRES=\S+' \
        | grep -oP 'gres/gpu=\K[0-9]+' \
        | awk '{s+=$1} END {print s+0}')
    gt=${gt:-0}

    local gu
    gu=$(printf '%s\n' "$_rq_data" \
        | grep -oP '(?:gpu=|gpu(?::[^:]+)?:)\K[0-9]+' \
        | awk '{s+=$1}END{print s+0}')

    for v in jr jp ni na nm nd gt gu; do
        eval "[[ \"\${$v}\" =~ ^[0-9]+\$ ]] || $v=0"
    done

    printf '  %s>> Running:%s %s%s%s  '  "$C_SUCCESS" "$C_RESET" "$C_VALUE"     "$jr" "$C_RESET"
    printf '%s:: Pending:%s %s%s%s  '    "$C_WARNING" "$C_RESET" "$C_HIGHLIGHT" "$jp" "$C_RESET"
    printf '%s|%s  '                     "$C_BORDER"  "$C_RESET"
    printf '%sIdle:%s %s%s%s  '          "$C_SUCCESS" "$C_RESET" "$C_VALUE"     "$ni" "$C_RESET"
    printf '%sMixed:%s %s%s%s  '         "$C_WARNING" "$C_RESET" "$C_WARNING"   "$nm" "$C_RESET"
    printf '%sAlloc:%s %s%s%s  '         "$C_ERROR"   "$C_RESET" "$C_ERROR"     "$na" "$C_RESET"
    [ "$nd" -gt 0 ] && \
        printf '%sDown:%s %s%s%s  '      "$C_ERROR2"  "$C_RESET" "$C_ERROR2"    "$nd" "$C_RESET"
    printf '%s|%s  '                     "$C_BORDER"  "$C_RESET"
    printf '%sGPUs Used: %s/%s%s\n'      "$C_GPU" "$gu" "$gt" "$C_RESET"
    print_line "$w" "-" "$C_BORDER"
}

# ==============================================================================
# COMPUTE NODES
# ==============================================================================
draw_nodes_section() {
    local partition="$1" all_flag="${2:-false}"
    local w; w=$(get_term_width)

    local W_NODE=18 W_STATE=8
    local W_CPU_BAR=12 W_MEM_BAR=12 W_GPU_BAR=8
    local CPU_BT=$(( W_CPU_BAR+5 )) MEM_BT=$(( W_MEM_BAR+5 )) GPU_BT=$(( W_GPU_BAR+5 ))
    local GAP=1 COL_SEP=1
    local overhead=$(( 2+W_NODE+W_STATE+CPU_BT+GAP+COL_SEP+MEM_BT+GAP+COL_SEP+GPU_BT+GAP ))
    local ann_pool=$(( w-overhead )); [ "$ann_pool" -lt 54 ] && ann_pool=54
    local W_MEM_ANN=$(( ann_pool*40/100 ))
    local W_GPU_ANN=$(( ann_pool*27/100 ))
    local W_CPU_ANN=$(( ann_pool-W_MEM_ANN-W_GPU_ANN ))
    local w_cpu_col=$(( CPU_BT+GAP+W_CPU_ANN ))
    local w_mem_col=$(( MEM_BT+GAP+W_MEM_ANN ))
    local w_gpu_col=$(( GPU_BT+GAP+W_GPU_ANN ))

    printf '%s%sCOMPUTE NODES%s\n' "$C_BOLD" "$C_HEADER" "$C_RESET"
    printf '  %s%s%s%s%s%s%s%s\n' "$C_LABEL$C_BOLD" \
        "$(pad "NODE"           "$W_NODE"    c)" \
        "$(pad "STATE"          "$W_STATE"   c)" \
        "$(pad "CPU (Cores)"    "$w_cpu_col" c)" \
        "$(pad " "              "$COL_SEP"   l)" \
        "$(pad "MEMORY (GB/TB)" "$w_mem_col" c)" \
        "$(pad " "              "$COL_SEP"   l)" \
        "$(pad "GPU (Count)"    "$w_gpu_col" c)" "$C_RESET"
    print_line "$w" "-" "$C_BORDER"

    local n_nodes=0
    local t_cpu_u=0 t_cpu_t=0 t_mem_u=0 t_mem_t=0 t_mem_f=0 t_gpu_u=0 t_gpu_t=0
    local nm_cpu_total nm_cpu_alloc nm_mem_total nm_mem_used \
          nm_mem_free nm_gpu_total nm_gpu_used

    local sna="-N -h -o %n|%t|%C|%m|%G"
    [ "$all_flag" = "false" ] && sna="-p $partition $sna"

    while IFS='|' read -r node state _c _m _g; do
        [ -z "$node" ] && continue
        get_node_metrics "$node"
        (( t_cpu_u+=nm_cpu_alloc )); (( t_cpu_t+=nm_cpu_total ))
        (( t_mem_u+=nm_mem_used  )); (( t_mem_t+=nm_mem_total  ))
        (( t_mem_f+=nm_mem_free  ))
        (( t_gpu_u+=nm_gpu_used  )); (( t_gpu_t+=nm_gpu_total  ))
        (( n_nodes++ ))

        local sc; sc=$(state_color "$state")
        printf '  %s%s%s' "$C_VALUE" "$(pad "$node"  "$W_NODE"  l)" "$C_RESET"
        printf '%s%s%s'   "$sc"      "$(pad "$state" "$W_STATE" l)" "$C_RESET"

        local cpu_free=$(( nm_cpu_total-nm_cpu_alloc ))
        draw_bar "$nm_cpu_alloc" "$nm_cpu_total" "$W_CPU_BAR" "$C_CPU"
        printf '%*s' "$GAP" ''
        printf '%s%s%s' "$C_CPU" \
            "$(pad "(${nm_cpu_alloc}c/${nm_cpu_total}c) [${cpu_free}c Free]" "$W_CPU_ANN" l)" \
            "$C_RESET"
        printf '%*s' "$COL_SEP" ''

        local mp mu mt mf mc
        mp=$(calc_pct "$nm_mem_used" "$nm_mem_total"); mc=$(usage_color "$mp")
        mu=$(fmt_mem      "$nm_mem_used");  mt=$(fmt_mem     "$nm_mem_total")
        mf=$(fmt_mem_free "$nm_mem_free")
        draw_bar "$nm_mem_used" "$nm_mem_total" "$W_MEM_BAR" "$mc"
        printf '%*s' "$GAP" ''
        printf '%s%s%s' "$C_MEM" \
            "$(pad "(${mu}/${mt}) [${mf} Free]" "$W_MEM_ANN" l)" "$C_RESET"
        printf '%*s' "$COL_SEP" ''

        if [ "$nm_gpu_total" -gt 0 ]; then
            local gf=$(( nm_gpu_total-nm_gpu_used ))
            draw_bar "$nm_gpu_used" "$nm_gpu_total" "$W_GPU_BAR" "$C_GPU"
            printf '%*s' "$GAP" ''
            printf '%s%s%s' "$C_GPU" \
                "$(pad "(${nm_gpu_used}/${nm_gpu_total} GPUs) [${gf} Free]" "$W_GPU_ANN" l)" \
                "$C_RESET"
        else
            printf '%s%s%s' "$C_MUTED" \
                "$(pad "No GPU" $(( GPU_BT+GAP+W_GPU_ANN )) l)" "$C_RESET"
        fi
        printf '\n'
    done < <(sinfo $sna 2>/dev/null | sort -V)

    if [ "$n_nodes" -gt 0 ]; then
        print_line "$w" "-" "$C_BORDER"
        printf '  %s%s%s' "$C_BOLD$C_HEADER" \
            "$(pad "TOTAL ($n_nodes nodes)" "$W_NODE" l)" "$C_RESET"
        printf '%*s' "$W_STATE" ''
        local tcf=$(( t_cpu_t-t_cpu_u ))
        draw_bar "$t_cpu_u" "$t_cpu_t" "$W_CPU_BAR" "$C_CPU"
        printf '%*s' "$GAP" ''
        printf '%s%s%s' "$C_CPU" \
            "$(pad "(${t_cpu_u}c/${t_cpu_t}c) [${tcf}c Free]" "$W_CPU_ANN" l)" "$C_RESET"
        printf '%*s' "$COL_SEP" ''
        local tmp tmu tmt tmf
        tmp=$(calc_pct "$t_mem_u" "$t_mem_t")
        tmu=$(fmt_mem      "$t_mem_u"); tmt=$(fmt_mem     "$t_mem_t")
        tmf=$(fmt_mem_free "$t_mem_f")
        draw_bar "$t_mem_u" "$t_mem_t" "$W_MEM_BAR" "$(usage_color "$tmp")"
        printf '%*s' "$GAP" ''
        printf '%s%s%s' "$C_MEM" \
            "$(pad "(${tmu}/${tmt}) [${tmf} Free]" "$W_MEM_ANN" l)" "$C_RESET"
        printf '%*s' "$COL_SEP" ''
        if [ "$t_gpu_t" -gt 0 ]; then
            local tgf=$(( t_gpu_t-t_gpu_u ))
            draw_bar "$t_gpu_u" "$t_gpu_t" "$W_GPU_BAR" "$C_GPU"
            printf '%*s' "$GAP" ''
            printf '%s%s%s' "$C_GPU" \
                "$(pad "(${t_gpu_u}/${t_gpu_t} GPUs) [${tgf} Free]" "$W_GPU_ANN" l)" \
                "$C_RESET"
        fi
        printf '\n'
    fi
}

# ==============================================================================
# ACTIVE JOBS
# ==============================================================================
draw_jobs_section() {
    local partition="$1" target_user="$2" all_flag="${3:-false}" w
    w=$(get_term_width)
    printf '%s%sACTIVE JOBS — %s%s%s\n' \
        "$C_BOLD" "$C_HEADER" "$C_HIGHLIGHT" "$target_user" "$C_RESET"

    local sq="-u $target_user -h"
    [ "$all_flag" = "false" ] && sq="$sq -p $partition"

    # FIX: one call — fetch formatted data immediately, check emptiness from it.
    local job_data
    job_data=$(squeue $sq -o "%i|%j|%T|%M|%C|%m|%b|%D|%R|%r" 2>/dev/null)

    if [ -z "$job_data" ]; then
        printf "  %sNo active jobs for '%s'%s\n" "$C_MUTED" "$target_user" "$C_RESET"
        return
    fi

    local wJID=12 wSTATE=10 wRT=14
    local fixed=$(( 2+wJID+wSTATE+wRT ))
    local rem=$(( w-fixed )); [ "$rem" -lt 54 ] && rem=54
    local wNAME=$(( rem*30/100 )) wRES=$(( rem*40/100 ))
    local wNOD=$(( rem-wNAME-wRES ))
    [ "$wNAME" -lt 12 ] && wNAME=12
    [ "$wRES"  -lt 20 ] && wRES=20
    [ "$wNOD"  -lt 12 ] && wNOD=12

    printf '  %s%s%s%s%s%s%s%s\n' "$C_LABEL$C_BOLD" \
        "$(pad "JOB ID"       "$wJID"   l)" \
        "$(pad "NAME"         "$wNAME"  l)" \
        "$(pad "STATE"        "$wSTATE" l)" \
        "$(pad "RUNTIME"      "$wRT"    l)" \
        "$(pad "RESOURCES"    "$wRES"   l)" \
        "$(pad "NODES/REASON" "$wNOD"   l)" "$C_RESET"
    print_line "$w" "-" "$C_BORDER"

    while IFS='|' read -r jid jname state runtime cpus mem gres \
                            num_nodes nodelist reason; do
        [ -z "$jid" ] && continue
        local res sc
        res=$(build_res_str "$cpus" "$mem" "$gres" "$num_nodes")
        sc=$(state_color "$state")
        local nr="$nodelist"
        { [ "$state" = "PENDING" ] || [ "$state" = "PD" ]; } && nr="$reason"
        [ -z "$nr" ] && nr="$reason"
        printf '  %s%s%s' "$C_VALUE"     "$(pad "$jid"     "$wJID"   l)" "$C_RESET"
        printf '%s'                       "$(pad "$jname"   "$wNAME"  l)"
        printf '%s%s%s'   "$sc"          "$(pad "$state"   "$wSTATE" l)" "$C_RESET"
        printf '%s'                       "$(pad "$runtime" "$wRT"    l)"
        printf '%s%s%s'   "$C_GPU"       "$(pad "$res"     "$wRES"   l)" "$C_RESET"
        printf '%s%s%s\n' "$C_HIGHLIGHT2" "$(pad "$nr"     "$wNOD"   l)" "$C_RESET"
    done <<< "$job_data"
}

# ==============================================================================
# RECENT JOBS
# ==============================================================================
draw_recent_jobs_section() {
    local partition="$1" target_user="$2" all_flag="${3:-false}" w
    w=$(get_term_width)
    printf '%s%sRECENT JOBS (last 5) — %s%s%s\n' \
        "$C_BOLD" "$C_HEADER" "$C_HIGHLIGHT" "$target_user" "$C_RESET"

    if ! command -v sacct >/dev/null 2>&1; then
        printf '  %ssacct not available%s\n' "$C_MUTED" "$C_RESET"; return
    fi

    local wJID=12 wSTATE=12 wSTART=20 wEND=20 wELAP=10
    local fixed=$(( 2+wJID+wSTATE+wSTART+wEND+wELAP ))
    local rem=$(( w-fixed )); [ "$rem" -lt 30 ] && rem=30
    local wNAME=$(( rem*38/100 )) wRES=$(( rem-rem*38/100 ))
    [ "$wNAME" -lt 12 ] && wNAME=12; [ "$wRES" -lt 14 ] && wRES=14

    printf '  %s%s%s%s%s%s%s%s%s\n' "$C_LABEL$C_BOLD" \
        "$(pad "JOB ID"    "$wJID"   l)" "$(pad "NAME"    "$wNAME"  l)" \
        "$(pad "STATE"     "$wSTATE" l)" "$(pad "START"   "$wSTART" l)" \
        "$(pad "END"       "$wEND"   l)" "$(pad "ELAPSED" "$wELAP"  l)" \
        "$(pad "RESOURCES" "$wRES"   l)" "$C_RESET"
    print_line "$w" "-" "$C_BORDER"

    local sa="-u $target_user -X --noheader --parsable2 --starttime=now-7days"
    [ "$all_flag" = "false" ] && sa="$sa -r $partition"
    local fmt="JobID,JobName,State,Elapsed,Start,End,AllocCPUS,ReqMem,AllocNodes,ReqTRES"
    local count=0

    # FIX: single sacct call. Reverse with tac (Linux standard); fall back to
    # tail -r only if tac is absent — avoiding the double-call pattern.
    local _reverse_cmd
    if command -v tac >/dev/null 2>&1; then
        _reverse_cmd="tac"
    else
        _reverse_cmd="tail -r"
    fi

    while IFS='|' read -r jid jname state elapsed st et ac rm an rt; do
        [ -z "$jid" ] && continue; [[ "$jid" =~ ^JobID ]] && continue
        case "$state" in RUNNING|PENDING|COMPLETING) continue ;; esac
        (( count++ )); [ "$count" -gt 5 ] && break

        local gc=0 mem_mb=0
        gc=$(printf '%s' "$rt" | grep -oP 'gres/gpu=\K[0-9]+' | head -1); gc=${gc:-0}
        if [[ "$rm" =~ ^([0-9]+(\.[0-9]+)?)([KMGTkmgt])[cn]?$ ]]; then
            local mv="${BASH_REMATCH[1]}" mu="${BASH_REMATCH[3]}"
            case "${mu,,}" in
                k) mem_mb=$(( ${mv%.*}/1024 ))      ;;
                m) mem_mb=${mv%.*}                  ;;
                g) mem_mb=$(( ${mv%.*}*1024 ))      ;;
                t) mem_mb=$(( ${mv%.*}*1048576 ))   ;;
            esac
        fi
        [[ "$an" =~ ^[0-9]+$ ]] || an=1
        [[ "$ac" =~ ^[0-9]+$ ]] || ac=0

        local res ss sc sd ed
        res=$(build_res_str "$ac" "$mem_mb" "gpu=${gc}" "$an")
        ss=$(printf '%s' "$state" | awk '{print $1}'); sc=$(state_color "$ss")
        sd=$(fmt_time_12h "$st"); ed=$(fmt_time_12h "$et")

        printf '  %s%s%s' "$C_VALUE" "$(pad "$jid"     "$wJID"   l)" "$C_RESET"
        printf '%s'                   "$(pad "$jname"   "$wNAME"  l)"
        printf '%s%s%s'   "$sc"      "$(pad "$ss"      "$wSTATE" l)" "$C_RESET"
        printf '%s%s%s'   "$C_MUTED" "$(pad "$sd"      "$wSTART" l)" "$C_RESET"
        printf '%s%s%s'   "$C_MUTED" "$(pad "$ed"      "$wEND"   l)" "$C_RESET"
        printf '%s'                   "$(pad "$elapsed" "$wELAP"  l)"
        printf '%s%s%s\n' "$C_GPU"   "$(pad "$res"     "$wRES"   l)" "$C_RESET"
    done < <(
        sacct $sa --format="$fmt" 2>/dev/null \
        | awk -F'|' '$3 !~ /^(RUNNING|PENDING|COMPLETING)/' \
        | $_reverse_cmd 2>/dev/null
    )
    [ "$count" -eq 0 ] && \
        printf '  %sNo completed jobs in the last 7 days%s\n' "$C_MUTED" "$C_RESET"
}

# ==============================================================================
# QUEUE STATUS
# ==============================================================================
draw_queue_section() {
    local partition="$1" target_user="$2" all_flag="${3:-false}" w
    w=$(get_term_width)
    printf '%s%sQUEUE STATUS%s\n' "$C_BOLD" "$C_HEADER" "$C_RESET"

    # FIX: use the pending jobs data already fetched in draw_quick_stats
    local pq_data="$PENDING_JOBS_DATA"
    local pt pu
    pt=$(printf '%s\n' "$pq_data" | grep -c '.' || echo 0)
    pu=$(printf '%s\n' "$pq_data" \
        | awk -F'|' -v u="$target_user" '$2==u' | grep -c '.' || echo 0)
    [[ "$pt" =~ ^[0-9]+$ ]] || pt=0; [[ "$pu" =~ ^[0-9]+$ ]] || pu=0

    if [ "$pt" -eq 0 ]; then
        printf '  %sQueue is clear — no pending jobs%s\n' "$C_SUCCESS" "$C_RESET"
        return
    fi

    printf '  %sPending total:%s %s%d%s  %s%s pending:%s %s%d%s\n' \
        "$C_WARNING" "$C_RESET" "$C_WARNING" "$pt" "$C_RESET" \
        "$C_LABEL" "$target_user" "$C_RESET" "$C_HIGHLIGHT" "$pu" "$C_RESET"

    local spa=""; [ "$all_flag" = "false" ] && spa="-p $partition"
    local sprio_data
    sprio_data=$(sprio $spa --noheader -o "%.15i %.15y" 2>/dev/null || true)

    local wJID=12 wUSER=14 wWT=10 wPRI=10
    local fixed=$(( 2+wJID+wUSER+wWT+wPRI ))
    local rem=$(( w-fixed )); [ "$rem" -lt 30 ] && rem=30
    local wREQ=$(( rem*52/100 )) wREA=$(( rem-rem*52/100 ))
    [ "$wREQ" -lt 20 ] && wREQ=20; [ "$wREA" -lt 15 ] && wREA=15

    printf '  %s%s%s%s%s%s%s%s\n' "$C_LABEL$C_BOLD" \
        "$(pad "JOB ID"    "$wJID"  l)" "$(pad "USER"      "$wUSER" l)" \
        "$(pad "WAIT TIME" "$wWT"   l)" "$(pad "PRIORITY"  "$wPRI"  l)" \
        "$(pad "REQUESTED" "$wREQ"  l)" "$(pad "REASON"    "$wREA"  l)" "$C_RESET"
    print_line "$w" "-" "$C_BORDER"

    local count=0
    while IFS='|' read -r jid juser wt cpus mem gres num_nodes reason; do
        [ -z "$jid" ] && continue
        (( count++ )); [ "$count" -gt 8 ] && break
        local res pri pc uc
        res=$(build_res_str "$cpus" "$mem" "$gres" "$num_nodes")
        pri=$(printf '%s' "$sprio_data" \
            | awk -v id="$jid" '$1==id{print $2;exit}')
        [ -z "$pri" ] && pri="-"
        if [[ "$pri" =~ ^[0-9]+$ ]]; then
            [ "$pri" -ge 1000 ] && pc="$C_SUCCESS" \
                || { [ "$pri" -ge 500 ] && pc="$C_WARNING2" || pc="$C_MUTED"; }
        else pc="$C_MUTED"; fi
        uc="$C_RESET"; [ "$juser" = "$target_user" ] && uc="$C_HIGHLIGHT"
        printf '  %s%s%s' "$C_VALUE" "$(pad "$jid"    "$wJID"  l)" "$C_RESET"
        printf '%s%s%s'   "$uc"      "$(pad "$juser"  "$wUSER" l)" "$C_RESET"
        printf '%s'                   "$(pad "$wt"     "$wWT"   l)"
        printf '%s%s%s'   "$pc"      "$(pad "$pri"    "$wPRI"  l)" "$C_RESET"
        printf '%s%s%s'   "$C_GPU"   "$(pad "$res"    "$wREQ"  l)" "$C_RESET"
        printf '%s%s%s\n' "$C_MUTED" "$(pad "$reason" "$wREA"  l)" "$C_RESET"
    done <<< "$pq_data"

    [ "$pt" -gt 8 ] && \
        printf '  %s... and %d more pending jobs%s\n' \
            "$C_MUTED" "$(( pt-8 ))" "$C_RESET"
}

# ==============================================================================
# FOOTER
# ==============================================================================
draw_footer() {
    local partition="$1" mode="${2:-snapshot}" all_flag="${3:-false}" w
    w=$(get_term_width)
    print_line "$w" "=" "$C_HEADER"
    if [ "$mode" = "interactive" ]; then
        printf '  %sCtrl+C to exit' "$C_MUTED"
        printf '  | Refresh: %s%ds%s%s' \
            "$C_VALUE" "${REFRESH:-$DEFAULT_REFRESH}" "$C_RESET" "$C_MUTED"
    else
        printf '  %sSnapshot mode' "$C_MUTED"
    fi
    [ "$all_flag" = "true" ] \
        && printf '  | Partition: %sALL%s%s'        "$C_GPU" "$C_RESET" "$C_MUTED" \
        || printf '  | Partition: %s%s%s%s'         "$C_GPU" "$partition" "$C_RESET" "$C_MUTED"
    printf '  | %s%s%s'  "$C_VALUE" "$ACTIVE_TZ_LABEL" "$C_MUTED"
    printf '  | %s v%s%s\n' "$TOOL_NAME" "$VERSION" "$C_RESET"
    print_line "$w" "=" "$C_HEADER"
}

# ==============================================================================
# DASHBOARD
# ==============================================================================
draw_dashboard() {
    local partition="$1" target_user="$2" mode="${3:-snapshot}" all_flag="${4:-false}"
    load_node_cache "$partition" "$all_flag"
    draw_header     "$partition" "$target_user" "$mode"
    printf '\n'
    draw_quick_stats        "$partition" "$all_flag"
    printf '\n'
    draw_nodes_section      "$partition" "$all_flag"
    printf '\n'
    draw_jobs_section       "$partition" "$target_user" "$all_flag"
    printf '\n'
    draw_recent_jobs_section "$partition" "$target_user" "$all_flag"
    printf '\n'
    draw_queue_section      "$partition" "$target_user" "$all_flag"
    printf '\n'
    draw_footer             "$partition" "$mode" "$all_flag"
}

# ==============================================================================
# FAST REFRESH WARNING
# ==============================================================================
confirm_fast_refresh() {
    local secs="$1"
    printf '\n%s ⚠ WARNING%s\n' "$C_WARNING" "$C_RESET" >/dev/tty
    printf '%sRefresh interval %s%ds%s is below the safe minimum of %ds.\n' \
        "$C_MUTED" "$C_VALUE" "$secs" "$C_MUTED" "$MIN_SAFE_REFRESH" >/dev/tty
    printf 'Aggressive polling can overwhelm slurmctld and may cause throttling.\n%s' \
        "$C_RESET" >/dev/tty
    printf '\n%sProceed anyway? [y/N]:%s ' "$C_LABEL" "$C_RESET" >/dev/tty
    local ans; read -r ans </dev/tty
    case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ==============================================================================
# CLEANUP 
# ==============================================================================
_SLEEP_PID=""

cleanup() {
    tput cnorm 2>/dev/null
    printf '%s' "$C_RESET" 2>/dev/null
    trap - SIGINT SIGTERM SIGHUP EXIT
    [ -n "$_SLEEP_PID" ] && kill "$_SLEEP_PID" 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM SIGHUP EXIT

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    local partition="$DEFAULT_PARTITION" target_user
    target_user=$(whoami)
    local refresh="$DEFAULT_REFRESH" interactive=false all_flag=false tz_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--partition) partition="$2";     shift 2 ;;
            -u|--user)      target_user="$2";   shift 2 ;;
            --tz)           tz_override="$2";   shift 2 ;;
            --all)          all_flag=true;       shift   ;;
            --override-mem)
                # Parse memory override: supports 1024GB, 1TB, or raw MB number
                local mem_input="$2"
                if [[ "$mem_input" =~ ^([0-9]+)(GB|gb)$ ]]; then
                    MEMORY_OVERRIDE_MB=$(( ${BASH_REMATCH[1]} * 1024 ))
                elif [[ "$mem_input" =~ ^([0-9]+)(TB|tb)$ ]]; then
                    MEMORY_OVERRIDE_MB=$(( ${BASH_REMATCH[1]} * 1048576 ))
                elif [[ "$mem_input" =~ ^([0-9]+)(MB|mb)?$ ]]; then
                    MEMORY_OVERRIDE_MB="${BASH_REMATCH[1]}"
                else
                    printf '%sInvalid memory format: %s (use: 1024GB, 1TB, or 1048576)%s\n' \
                        "$C_ERROR" "$mem_input" "$C_RESET" >&2
                    exit 1
                fi
                shift 2 ;;
            -i|--interactive)
                interactive=true; shift
                if [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; then
                    refresh="$1"; shift
                fi ;;
            -h|--help)
                resolve_timezone "${tz_override:-$DEFAULT_TZ}"
                show_help
                exit 0 ;;
            -*)
                printf '%sUnknown option: %s (try --help)%s\n' \
                    "$C_WARNING" "$1" "$C_RESET" >&2; shift ;;
            *) partition="$1"; shift ;;
        esac
    done

    [[ "$refresh" =~ ^[0-9]+$ ]] && [ "$refresh" -ge 1 ] || refresh="$DEFAULT_REFRESH"
    export REFRESH="$refresh"
    resolve_timezone "${tz_override:-$DEFAULT_TZ}"

    # Validate partition before doing any rendering
    validate_partition "$partition" "$all_flag"

    if [ "$all_flag" = "true" ] && [ "$interactive" = "true" ]; then
        printf '%s%s: Note: --all in interactive mode queries the full cluster each cycle.\n' \
            "$C_WARNING" "$TOOL_NAME" >&2
        printf 'Consider a longer interval, e.g. -i 120%s\n' "$C_RESET" >&2
    fi

    if [ "$interactive" = true ] && [ "$refresh" -lt "$MIN_SAFE_REFRESH" ]; then
        confirm_fast_refresh "$refresh" \
            || { printf '%sAborted.%s\n' "$C_MUTED" "$C_RESET"; exit 0; }
    fi

    # ── Snapshot mode ────────────────────────────────────────────────────────
    if [ "$interactive" = false ]; then
        draw_dashboard "$partition" "$target_user" "snapshot" "$all_flag"
        exit 0
    fi

    # ── Interactive mode ─────────────────────────────────────────────────────

    tput civis 2>/dev/null
    clear

    while true; do
        clear
        draw_dashboard "$partition" "$target_user" "interactive" "$all_flag"
        sleep "$refresh" &
        _SLEEP_PID=$!
        wait "$_SLEEP_PID" 2>/dev/null
        _SLEEP_PID=""
    done
}

main "$@"
