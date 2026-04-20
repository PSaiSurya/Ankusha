#!/bin/bash
# ==============================================================================
# █████╗ ███╗ ██╗██╗ ██╗██╗ ██╗███████╗██╗ ██╗ █████╗
# ██╔══██╗████╗ ██║██║ ██╔╝██║ ██║██╔════╝██║ ██║██╔══██╗
# ███████║██╔██╗ ██║█████╔╝ ██║ ██║███████╗███████║███████║
# ██╔══██║██║╚██╗██║██╔═██╗ ██║ ██║╚════██║██╔══██║██╔══██║
# ██║ ██║██║ ╚████║██║ ██╗╚██████╔╝███████║██║ ██║██║ ██║
# ╚═╝ ╚═╝╚═╝ ╚═══╝╚═╝ ╚═╝ ╚═════╝ ╚══════╝╚═╝ ╚═╝╚═╝ ╚═╝
#
# HPC Cluster Monitoring Dashboard — v2.0 - The Modern
# "The Goad of the Great White Elephant."
# https://github.com/PSaiSurya/Ankusha
# ==============================================================================

set -o pipefail

# ==============================================================================
# IDENTITY
# ==============================================================================
readonly TOOL_NAME="ANKUSHA"
readonly TOOL_TAGLINE="The Goad of the Great White Elephant."
readonly VERSION="2.0"
readonly DEFAULT_PARTITION="default"
readonly DEFAULT_REFRESH=30
readonly MIN_SAFE_REFRESH=30
readonly DEFAULT_TZ="Asia/Kolkata"

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
    readonly C_ACCENT=$(tput setaf 51)
    readonly C_SECTION=$(tput setaf 75)
else
    readonly C_RESET='' C_BOLD='' C_DIM=''
    readonly C_SUCCESS='' C_SUCCESS2='' C_WARNING='' C_WARNING2=''
    readonly C_ERROR='' C_ERROR2='' C_MUTED=''
    readonly C_HEADER='' C_BORDER='' C_LABEL='' C_VALUE=''
    readonly C_HIGHLIGHT='' C_HIGHLIGHT2='' C_GPU='' C_MEM='' C_CPU=''
    readonly C_TAG1='' C_TAG2='' C_TAG3='' C_ACCENT='' C_SECTION=''
fi

get_term_width()  { local w; w=$(tput cols  2>/dev/null); printf '%s' "${w:-135}"; }
get_term_height() { local h; h=$(tput lines 2>/dev/null); printf '%s' "${h:-40}";  }

# ── Timezone ──────────────────────────────────────────────────────────────────
ACTIVE_TZ=""
ACTIVE_TZ_LABEL=""
resolve_timezone() {
    local req="${1:-$DEFAULT_TZ}"
    if TZ="$req" date >/dev/null 2>&1; then
        ACTIVE_TZ="$req"
    else
        printf '%sWarning: Unknown timezone "%s", using UTC%s\n' \
            "$C_WARNING" "$req" "$C_RESET" >&2
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

# ── Alignment ─────────────────────────────────────────────────────────────────
pad() {
    local text="$1" vw="$2" align="${3:-l}"
    [[ "$vw" =~ ^[0-9]+$ ]] || vw=10; [ "$vw" -eq 0 ] && return
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

# ── Helpers ───────────────────────────────────────────────────────────────────
calc_pct() {
    local u="$1" t="$2"
    [[ "$u" =~ ^[0-9]+$ ]] || u=0
    [[ "$t" =~ ^[0-9]+$ ]] || t=0
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
# VISUAL PRIMITIVES
#
# Single-line box-drawing only — universally supported across:
# Windows Terminal, MobaXterm, PuTTY, iTerm2, Kitty, Alacritty, xterm
#
# Double-line characters (╔ ═ ╗ ╚ ╝ ╠ ╣ ╟ ╢) are intentionally avoided —
# they render as garbage in Windows Terminal due to Unicode width-table
# mismatches in the U+2550–U+256C range.
#
# Single-line equivalents used instead:
#   ┌  top-left        ┐  top-right
#   └  bottom-left     ┘  bottom-right
#   ─  horizontal      │  vertical
#   ├  left-T          ┤  right-T
# ==============================================================================

draw_bar() {
    local used="$1" total="$2" bar_width="${3:-16}" color_override="${4:-}"
    [[ "$used"      =~ ^[0-9]+$ ]] || used=0
    [[ "$total"     =~ ^[0-9]+$ ]] || total=0
    [[ "$bar_width" =~ ^[0-9]+$ ]] || bar_width=16
    if [ "$total" -eq 0 ]; then
        printf '%s' "$C_MUTED"
        local i; for (( i=0; i<bar_width; i++ )); do printf '░'; done
        printf '%s 0%%' "$C_RESET"
        return
    fi
    local pct filled empty color
    pct=$(calc_pct "$used" "$total")
    filled=$(( pct*bar_width/100 ))
    empty=$(( bar_width-filled ))
    color="${color_override:-$(usage_color "$pct")}"
    printf '%s' "$color"
    local i; for (( i=0; i<filled; i++ )); do printf '▓'; done
    printf '%s' "$C_BORDER"
    for (( i=0; i<empty; i++ )); do printf '░'; done
    printf '%s %3d%%' "$C_RESET" "$pct"
}

# ┌─────────────────────┐
# │  TITLE   subtitle   │
# ├─────────────────────┤
section_header() {
    local title="$1" subtitle="${2:-}" w
    w=$(get_term_width)
    local inner=$(( w-4 ))

    printf '%s┌' "$C_HEADER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┐%s\n' "$C_RESET"

    if [ -n "$subtitle" ]; then
        printf '%s│%s  %s%s%-*s%s%s│%s\n' \
            "$C_HEADER" "$C_RESET" \
            "$C_BOLD$C_HEADER" "$title" \
            $(( inner - ${#title} - ${#subtitle} - 4 )) '' \
            "$C_MUTED" "$subtitle" \
            "$C_HEADER" "$C_RESET"
    else
        printf '%s│%s  %s%s%-*s%s│%s\n' \
            "$C_HEADER" "$C_RESET" \
            "$C_BOLD$C_HEADER" "$title" \
            $(( inner - ${#title} - 2 )) '' \
            "$C_HEADER" "$C_RESET"
    fi

    printf '%s├' "$C_HEADER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┤%s\n' "$C_RESET"
}

# ├─────────────────────┤  (mid-section thin rule)
section_sep() {
    local w; w=$(get_term_width)
    local inner=$(( w-4 ))
    printf '%s├' "$C_BORDER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┤%s\n' "$C_RESET"
}

# └─────────────────────┘
section_footer_box() {
    local w; w=$(get_term_width)
    local inner=$(( w-4 ))
    printf '%s└' "$C_HEADER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┘%s\n' "$C_RESET"
}

col_header() {
    printf '  %s%s%s\n' "$C_LABEL$C_BOLD" "$1" "$C_RESET"
}

# ── Memory formatters ─────────────────────────────────────────────────────────
fmt_mem() {
    local mb="$1"; [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
    if [ "$mb" -ge 1048576 ]; then
        local tw=$(( mb/1048576 )) tf=$(( (mb%1048576)*10/1048576 ))
        [ "$tf" -eq 0 ] && printf '%dTB' "$tw" || printf '%d.%dTB' "$tw" "$tf"
    elif [ "$mb" -ge 1024 ]; then
        local gw=$(( mb/1024 )) gf=$(( (mb%1024)*10/1024 ))
        [ "$gf" -eq 0 ] && printf '%dGB' "$gw" || printf '%d.%dGB' "$gw" "$gf"
    else
        printf '%dMB' "$mb"
    fi
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

# ── GPU parsers ───────────────────────────────────────────────────────────────
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

# ── Partition validation ──────────────────────────────────────────────────────
validate_partition() {
    local partition="$1" all_flag="${2:-false}"

    if ! scontrol ping >/dev/null 2>&1; then
        printf '%s%s: Error: slurmctld is not responding (scontrol ping failed).%s\n' \
            "$C_ERROR" "$TOOL_NAME" "$C_RESET" >&2
        exit 1
    fi

    [ "$all_flag" = "true" ] && return 0

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

# ── Node cache ────────────────────────────────────────────────────────────────
# FIX: added 15s timeout to guard against an unresponsive slurmctld hanging
# the script indefinitely. Consistent with v1's timeout guard.
NODE_CACHE=""
load_node_cache() {
    local partition="$1" all_flag="${2:-false}" node_list
    if [ "$all_flag" = "true" ]; then
        NODE_CACHE=$(timeout 15s scontrol show node 2>/dev/null)
    else
        node_list=$(sinfo -p "$partition" -N -h -o "%n" 2>/dev/null \
            | sort -u | tr '\n' ',')
        node_list="${node_list%,}"
        if [ -n "$node_list" ]; then
            NODE_CACHE=$(timeout 15s scontrol show node "$node_list" 2>/dev/null)
        else
            NODE_CACHE=""
        fi
    fi
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
    nm_cpu_total=${nm_cpu_total:-0}
    nm_cpu_alloc=${nm_cpu_alloc:-0}
    local rm fm
    rm=$(printf '%s' "$raw" | grep -oP 'RealMemory=\K[0-9]+' | head -1)
    fm=$(printf '%s' "$raw" | grep -oP 'FreeMem=\K[0-9]+'    | head -1)
    nm_mem_total=${rm:-0}
    nm_mem_free=${fm:-0}
    nm_mem_used=$(( nm_mem_total - nm_mem_free ))
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

# FIX: normalise the raw memory token (e.g. "16G", "512M") to integer MB
# before formatting, so squeue %m values are never silently zeroed.
build_res_str() {
    local cpus="$1" mem_raw="$2" gres="$3" num_nodes="$4"
    [[ "$cpus"      =~ ^[0-9]+$ ]] || cpus=0
    [[ "$num_nodes" =~ ^[0-9]+$ ]] || num_nodes=1

    local mem=0
    if [[ "$mem_raw" =~ ^([0-9]+)([KMGTkmgt])?$ ]]; then
        local _mv="${BASH_REMATCH[1]}" _mu="${BASH_REMATCH[2],,}"
        case "$_mu" in
            k) mem=$(( _mv / 1024 ))    ;;
            m) mem=$_mv                 ;;
            g) mem=$(( _mv * 1024 ))    ;;
            t) mem=$(( _mv * 1048576 )) ;;
            *) mem=$_mv                 ;;
        esac
    fi

    local gc; gc=$(parse_gpu_total "$gres")
    [[ "$gc" =~ ^[0-9]+$ ]] || gc=0
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
# Shows the full ASCII banner, then usage.
# ==============================================================================
show_help() {
    local w; w=$(get_term_width)

    # ── Full ASCII art banner (matches the script header) ────────────────────
    printf '\n'
    printf '%s █████╗ ███╗ ██╗██╗ ██╗██╗ ██╗███████╗██╗ ██╗ █████╗%s\n'          "$C_TAG1" "$C_RESET"
    printf '%s ██╔══██╗████╗ ██║██║ ██╔╝██║ ██║██╔════╝██║ ██║██╔══██╗%s\n'       "$C_TAG2" "$C_RESET"
    printf '%s ███████║██╔██╗ ██║█████╔╝ ██║ ██║███████╗███████║███████║%s\n'      "$C_TAG3" "$C_RESET"
    printf '%s ██╔══██║██║╚██╗██║██╔═██╗ ██║ ██║╚════██║██╔══██║██╔══██║%s\n'     "$C_TAG1" "$C_RESET"
    printf '%s ██║ ██║██║ ╚████║██║ ██╗╚██████╔╝███████║██║ ██║██║ ██║%s\n'       "$C_TAG2" "$C_RESET"
    printf '%s ╚═╝ ╚═╝╚═╝ ╚═══╝╚═╝ ╚═╝ ╚═════╝ ╚══════╝╚═╝ ╚═╝╚═╝ ╚═╝%s\n'     "$C_TAG3" "$C_RESET"
    printf '\n'
    printf '  %s%s%s\n'           "$C_DIM"   "$TOOL_TAGLINE" "$C_RESET"
    printf '  %sVersion %s%s%s\n' "$C_MUTED" "$C_VALUE" "$VERSION" "$C_RESET"
    printf '\n'

    # ── Divider ───────────────────────────────────────────────────────────────
    printf '%s' "$C_BORDER"
    printf '%*s' "$w" '' | tr ' ' '─'
    printf '%s\n\n' "$C_RESET"

    # ── Usage ─────────────────────────────────────────────────────────────────
    printf '  %sUSAGE%s   ankusha [OPTIONS]\n\n' "$C_LABEL$C_BOLD" "$C_RESET"

    local pad_w=26
    _hf() {
        printf '  %s%-*s%s %s\n' "$C_HIGHLIGHT" "$pad_w" "$1" "$C_RESET" "$2"
    }
    _hf "-p, --partition PART"  "Partition to monitor (default: $DEFAULT_PARTITION)"
    _hf "-u, --user USER"       "Show jobs for USER (default: current user)"
    _hf "-i, --interactive [S]" "Live refresh; S = interval in seconds (default: ${DEFAULT_REFRESH}s)"
    _hf "--all"                 "Monitor all partitions on the cluster"
    _hf "--tz TIMEZONE"         "Timestamps timezone, e.g. UTC, America/New_York"
    _hf ""                      "(default: $DEFAULT_TZ)"
    _hf "-h, --help"            "Show this help and exit"

    printf '\n  %sEXAMPLES%s\n' "$C_LABEL$C_BOLD" "$C_RESET"
    printf '  %sankusha%s                    Snapshot, default partition\n'         "$C_VALUE" "$C_RESET"
    printf '  %sankusha -p gpu%s             Snapshot, gpu partition\n'             "$C_VALUE" "$C_RESET"
    printf '  %sankusha -p gpu -u alice%s    Jobs for alice on gpu partition\n'     "$C_VALUE" "$C_RESET"
    printf '  %sankusha -i%s                 Live mode, 30 s refresh\n'             "$C_VALUE" "$C_RESET"
    printf '  %sankusha -i 60 -p highmem%s   Live mode, 60 s refresh\n'            "$C_VALUE" "$C_RESET"
    printf '  %sankusha --all%s              All partitions, snapshot\n'            "$C_VALUE" "$C_RESET"
    printf '  %sankusha --all -i 120%s       All partitions, 2 min live refresh\n'  "$C_VALUE" "$C_RESET"
    printf '  %sankusha --tz UTC%s           Force UTC timestamps\n'                "$C_VALUE" "$C_RESET"

    printf '\n  %sNOTES%s\n' "$C_LABEL$C_BOLD" "$C_RESET"
    printf '  * Refresh intervals below %ds require explicit confirmation.\n' \
        "$MIN_SAFE_REFRESH"
    printf '  * Snapshot mode is safe for cron; interactive mode is not.\n'
    printf '  * sacct and sprio are optional; sections degrade gracefully.\n'
    printf '  * No external dependencies: pure Bash + standard Slurm CLI.\n'

    printf '\n'
    printf '%s' "$C_BORDER"
    printf '%*s' "$w" '' | tr ' ' '─'
    printf '%s\n\n' "$C_RESET"
}

# ==============================================================================
# HEADER SECTION
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  ANKUSHA  The Goad of the Great White Elephant.                   v2.0  │
# ├──────────────────────────────────────────────────────────────────────────┤
# │  ● User: researcher   ◈ Partition: gpu   ⊙ 20-04-2026 02:47 PM IST  ◷  │
# └──────────────────────────────────────────────────────────────────────────┘
# ==============================================================================
draw_header() {
    local partition="$1" target_user="$2" mode="${3:-snapshot}"
    local current_user ts w
    current_user=$(whoami)
    ts=$(current_time_fmt)
    w=$(get_term_width)
    local inner=$(( w-4 ))

    # ┌───...───┐
    printf '%s┌' "$C_HEADER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┐%s\n' "$C_RESET"

    # │  ANKUSHA  tagline  v2.0  │
    printf '%s│%s  ' "$C_HEADER" "$C_RESET"
    printf '%s%sA%sN%sK%sU%sS%sH%sA%s' \
        "$C_BOLD" \
        "$C_TAG1" "$C_TAG2" "$C_TAG3" \
        "$C_TAG1" "$C_TAG2" "$C_TAG3" \
        "$C_TAG1" "$C_RESET"
    printf '  %s%s%s' "$C_DIM" "$TOOL_TAGLINE" "$C_RESET"
    local name_len=7        # "ANKUSHA"
    local gap_len=2         # two spaces after name
    local name_and_tag=$(( name_len + gap_len + ${#TOOL_TAGLINE} + 2 ))
    local ver_str="v${VERSION}"
    local rpad=$(( inner - name_and_tag - ${#ver_str} - 1 ))
    [ "$rpad" -lt 1 ] && rpad=1
    printf '%*s%s%s%s' "$rpad" '' "$C_MUTED" "$ver_str" "$C_RESET"
    printf '%s│%s\n' "$C_HEADER" "$C_RESET"

    # ├───...───┤
    printf '%s├' "$C_BORDER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┤%s\n' "$C_RESET"

    # │  ● User: ...  ◈ Partition: ...  timestamp  [mode badge]  │
    printf '%s│%s  ' "$C_HEADER" "$C_RESET"
    printf '%s●%s  ' "$C_SUCCESS" "$C_RESET"
    printf '%sUser:%s %s%s%s' "$C_LABEL" "$C_RESET" "$C_HIGHLIGHT" "$target_user" "$C_RESET"
    [ "$target_user" != "$current_user" ] && \
        printf '  %s[viewed by %s]%s' "$C_MUTED" "$current_user" "$C_RESET"
    printf '  %s◈%s  ' "$C_GPU" "$C_RESET"
    printf '%sPartition:%s %s%s%s' \
        "$C_LABEL" "$C_RESET" "$C_GPU$C_BOLD" "$partition" "$C_RESET"
    printf '  %s⊙%s  ' "$C_MUTED" "$C_RESET"
    printf '%s%s %s%s' "$C_MUTED" "$ts" "$ACTIVE_TZ_LABEL" "$C_RESET"

    local badge
    [ "$mode" = "interactive" ] \
        && badge="[ LIVE ${REFRESH}s ]" \
        || badge="[ SNAPSHOT ]"
    local info_len=$(( 2 + 2 + 5 + ${#target_user} + 3 + 2 + 11 + ${#partition} + 3 + 2 + ${#ts} + 1 + ${#ACTIVE_TZ_LABEL} + 1 ))
    local badge_pad=$(( inner - info_len - ${#badge} - 1 ))
    [ "$badge_pad" -lt 1 ] && badge_pad=1
    if [ "$mode" = "interactive" ]; then
        printf '%*s%s%s%s' "$badge_pad" '' "$C_SUCCESS$C_BOLD" "$badge" "$C_RESET"
    else
        printf '%*s%s%s%s' "$badge_pad" '' "$C_MUTED$C_BOLD"   "$badge" "$C_RESET"
    fi
    printf '%s│%s\n' "$C_HEADER" "$C_RESET"

    # └───...───┘
    printf '%s└' "$C_HEADER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┘%s\n' "$C_RESET"
}

# ==============================================================================
# CLUSTER OVERVIEW
# ==============================================================================
draw_quick_stats() {
    local partition="$1" all_flag="${2:-false}"
    section_header "CLUSTER OVERVIEW"

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

    # FIX: single squeue call per state.
    local _rq_data _pd_data
    _rq_data=$(squeue $sq -t R  -h 2>/dev/null)
    _pd_data=$(squeue $sq -t PD -h 2>/dev/null)
    local jr jp
    jr=$(printf '%s\n' "$_rq_data" | grep -c '.' || echo 0)
    jp=$(printf '%s\n' "$_pd_data" | grep -c '.' || echo 0)

    # FIX: derive GPU total from NODE_CACHE — no additional sinfo call needed.
    local gt
    gt=$(printf '%s' "$NODE_CACHE" \
        | grep -oP 'CfgTRES=\S+' \
        | grep -oP 'gres/gpu=\K[0-9]+' \
        | awk '{s+=$1} END {print s+0}')
    gt=${gt:-0}

    local gu
    gu=$(squeue $sq -t R -h -o "%b" 2>/dev/null \
        | grep -oP '(?:gpu=|gpu(?::[^:]+)?:)\K[0-9]+' \
        | awk '{s+=$1} END {print s+0}')

    for v in jr jp ni na nm nd gt gu; do
        eval "[[ \"\${$v}\" =~ ^[0-9]+\$ ]] || $v=0"
    done

    printf '  '
    printf '%s JOBS%s  '           "$C_ACCENT"  "$C_RESET"
    printf '%s Running [%d]%s  '   "$C_SUCCESS"  "$jr" "$C_RESET"
    printf '%s Pending [%d]%s'     "$C_WARNING"  "$jp" "$C_RESET"
    printf '  %s│%s  '             "$C_BORDER"   "$C_RESET"
    printf '%s NODES%s  '          "$C_ACCENT"   "$C_RESET"
    printf '%s Idle [%d]%s  '      "$C_SUCCESS"  "$ni" "$C_RESET"
    printf '%s Mix [%d]%s  '       "$C_WARNING"  "$nm" "$C_RESET"
    printf '%s Alloc [%d]%s'       "$C_ERROR"    "$na" "$C_RESET"
    [ "$nd" -gt 0 ] && \
        printf '  %s Down [%d]%s'  "$C_ERROR2"   "$nd" "$C_RESET"
    printf '  %s│%s  '             "$C_BORDER"   "$C_RESET"
    printf '%s GPU%s  '            "$C_GPU"       "$C_RESET"
    local gpu_pct=0
    [ "$gt" -gt 0 ] && gpu_pct=$(calc_pct "$gu" "$gt")
    printf '%s%d/%d%s'             "$(usage_color "$gpu_pct")" "$gu" "$gt" "$C_RESET"
    printf '  %sused%s\n'          "$C_MUTED"    "$C_RESET"

    section_footer_box
}

# ==============================================================================
# COMPUTE NODES
# ==============================================================================
draw_nodes_section() {
    local partition="$1" all_flag="${2:-false}"
    local w; w=$(get_term_width)

    local W_NODE=18 W_STATE=8
    local W_CPU_BAR=12 W_MEM_BAR=12 W_GPU_BAR=8
    local CPU_BT=$(( W_CPU_BAR+5 ))
    local MEM_BT=$(( W_MEM_BAR+5 ))
    local GPU_BT=$(( W_GPU_BAR+5 ))
    local GAP=1 COL_SEP=1
    local overhead=$(( 2+W_NODE+W_STATE+CPU_BT+GAP+COL_SEP+MEM_BT+GAP+COL_SEP+GPU_BT+GAP ))
    local ann_pool=$(( w-overhead ))
    [ "$ann_pool" -lt 54 ] && ann_pool=54
    local W_MEM_ANN=$(( ann_pool*40/100 ))
    local W_GPU_ANN=$(( ann_pool*27/100 ))
    local W_CPU_ANN=$(( ann_pool - W_MEM_ANN - W_GPU_ANN ))
    local w_cpu_col=$(( CPU_BT+GAP+W_CPU_ANN ))
    local w_mem_col=$(( MEM_BT+GAP+W_MEM_ANN ))
    local w_gpu_col=$(( GPU_BT+GAP+W_GPU_ANN ))

    section_header "COMPUTE NODES"
    col_header "$(pad "NODE"           "$W_NODE"    c) \
$(pad "STATE"          "$W_STATE"   c) \
$(pad "CPU (Cores)"    "$w_cpu_col" c) \
$(pad "MEMORY (GB/TB)" "$w_mem_col" c) \
$(pad "GPU (Count)"    "$w_gpu_col" c)"
    section_sep

    local n_nodes=0
    local t_cpu_u=0 t_cpu_t=0
    local t_mem_u=0 t_mem_t=0 t_mem_f=0
    local t_gpu_u=0 t_gpu_t=0
    local nm_cpu_total nm_cpu_alloc nm_mem_total nm_mem_used \
          nm_mem_free nm_gpu_total nm_gpu_used
    local sna="-N -h -o %n|%t|%C|%m|%G"
    [ "$all_flag" = "false" ] && sna="-p $partition $sna"

    while IFS='|' read -r node state _c _m _g; do
        [ -z "$node" ] && continue
        get_node_metrics "$node"
        (( t_cpu_u += nm_cpu_alloc )); (( t_cpu_t += nm_cpu_total ))
        (( t_mem_u += nm_mem_used  )); (( t_mem_t += nm_mem_total  ))
        (( t_mem_f += nm_mem_free  ))
        (( t_gpu_u += nm_gpu_used  )); (( t_gpu_t += nm_gpu_total  ))
        (( n_nodes++ ))

        local sc; sc=$(state_color "$state")
        printf '  %s%s%s' "$C_VALUE" "$(pad "$node"  "$W_NODE"  l)" "$C_RESET"
        printf '%s%s%s'   "$sc"      "$(pad "$state" "$W_STATE" l)" "$C_RESET"

        local cpu_free=$(( nm_cpu_total - nm_cpu_alloc ))
        draw_bar "$nm_cpu_alloc" "$nm_cpu_total" "$W_CPU_BAR" "$C_CPU"
        printf '%*s%s%s%s' "$GAP" '' "$C_CPU" \
            "$(pad "(${nm_cpu_alloc}c/${nm_cpu_total}c) [${cpu_free}c Free]" \
                "$W_CPU_ANN" l)" "$C_RESET"
        printf '%*s' "$COL_SEP" ''

        local mp mc mu_s mt_s mf_s
        mp=$(calc_pct "$nm_mem_used" "$nm_mem_total")
        mc=$(usage_color "$mp")
        mu_s=$(fmt_mem      "$nm_mem_used")
        mt_s=$(fmt_mem      "$nm_mem_total")
        mf_s=$(fmt_mem_free "$nm_mem_free")
        draw_bar "$nm_mem_used" "$nm_mem_total" "$W_MEM_BAR" "$mc"
        printf '%*s%s%s%s' "$GAP" '' "$C_MEM" \
            "$(pad "(${mu_s}/${mt_s}) [${mf_s} Free]" "$W_MEM_ANN" l)" "$C_RESET"
        printf '%*s' "$COL_SEP" ''

        if [ "$nm_gpu_total" -gt 0 ]; then
            local gf=$(( nm_gpu_total - nm_gpu_used ))
            draw_bar "$nm_gpu_used" "$nm_gpu_total" "$W_GPU_BAR" "$C_GPU"
            printf '%*s%s%s%s' "$GAP" '' "$C_GPU" \
                "$(pad "(${nm_gpu_used}/${nm_gpu_total} GPUs) [${gf} Free]" \
                    "$W_GPU_ANN" l)" "$C_RESET"
        else
            printf '%s%s%s' "$C_MUTED" \
                "$(pad "No GPU" $(( GPU_BT+GAP+W_GPU_ANN )) l)" "$C_RESET"
        fi
        printf '\n'
    done < <(sinfo $sna 2>/dev/null | sort -V)

    if [ "$n_nodes" -gt 0 ]; then
        section_sep
        printf '  %s%s%s' "$C_BOLD$C_HEADER" \
            "$(pad "TOTAL ($n_nodes nodes)" "$W_NODE" l)" "$C_RESET"
        printf '%*s' "$W_STATE" ''

        local tcf=$(( t_cpu_t - t_cpu_u ))
        draw_bar "$t_cpu_u" "$t_cpu_t" "$W_CPU_BAR" "$C_CPU"
        printf '%*s%s%s%s' "$GAP" '' "$C_CPU" \
            "$(pad "(${t_cpu_u}c/${t_cpu_t}c) [${tcf}c Free]" "$W_CPU_ANN" l)" "$C_RESET"
        printf '%*s' "$COL_SEP" ''

        local tmp tmu tmt tmf
        tmp=$(calc_pct "$t_mem_u" "$t_mem_t")
        tmu=$(fmt_mem      "$t_mem_u")
        tmt=$(fmt_mem      "$t_mem_t")
        tmf=$(fmt_mem_free "$t_mem_f")
        draw_bar "$t_mem_u" "$t_mem_t" "$W_MEM_BAR" "$(usage_color "$tmp")"
        printf '%*s%s%s%s' "$GAP" '' "$C_MEM" \
            "$(pad "(${tmu}/${tmt}) [${tmf} Free]" "$W_MEM_ANN" l)" "$C_RESET"
        printf '%*s' "$COL_SEP" ''

        if [ "$t_gpu_t" -gt 0 ]; then
            local tgf=$(( t_gpu_t - t_gpu_u ))
            draw_bar "$t_gpu_u" "$t_gpu_t" "$W_GPU_BAR" "$C_GPU"
            printf '%*s%s%s%s' "$GAP" '' "$C_GPU" \
                "$(pad "(${t_gpu_u}/${t_gpu_t} GPUs) [${tgf} Free]" \
                    "$W_GPU_ANN" l)" "$C_RESET"
        fi
        printf '\n'
    fi
    section_footer_box
}

# ==============================================================================
# ACTIVE JOBS
# ==============================================================================
draw_jobs_section() {
    local partition="$1" target_user="$2" all_flag="${3:-false}"
    local w jc
    w=$(get_term_width)
    section_header "ACTIVE JOBS" "user: $target_user"

    local sq_args="-u $target_user -h"
    [ "$all_flag" = "false" ] && sq_args="$sq_args -p $partition"

    # FIX: one call — fetch formatted data immediately, check emptiness from it.
    local job_data
    job_data=$(squeue $sq_args -o "%i|%j|%T|%M|%C|%m|%b|%D|%R|%r" 2>/dev/null)

    if [ -z "$job_data" ]; then
        printf '  %sNo active jobs for %s%s\n' "$C_MUTED" "$target_user" "$C_RESET"
        section_footer_box; return
    fi

    local wJID=12 wSTATE=10 wRT=14
    local fixed=$(( 2+wJID+wSTATE+wRT ))
    local rem=$(( w-fixed ))
    [ "$rem" -lt 54 ] && rem=54
    local wNAME=$(( rem*30/100 ))
    local wRES=$(( rem*40/100 ))
    local wNOD=$(( rem - wNAME - wRES ))
    [ "$wNAME" -lt 12 ] && wNAME=12
    [ "$wRES"  -lt 20 ] && wRES=20
    [ "$wNOD"  -lt 12 ] && wNOD=12

    col_header "$(pad "JOB ID"       "$wJID"   l)\
$(pad "NAME"         "$wNAME"  l)\
$(pad "STATE"        "$wSTATE" l)\
$(pad "RUNTIME"      "$wRT"    l)\
$(pad "RESOURCES"    "$wRES"   l)\
$(pad "NODES/REASON" "$wNOD"   l)"
    section_sep

    while IFS='|' read -r jid jname state runtime cpus mem gres num_nodes nodelist reason; do
        [ -z "$jid" ] && continue
        local res sc nr
        res=$(build_res_str "$cpus" "$mem" "$gres" "$num_nodes")
        sc=$(state_color "$state")
        nr="$nodelist"
        { [ "$state" = "PENDING" ] || [ "$state" = "PD" ]; } && nr="$reason"
        [ -z "$nr" ] && nr="$reason"
        printf '  %s%s%s' "$C_VALUE"      "$(pad "$jid"     "$wJID"   l)" "$C_RESET"
        printf '%s'                         "$(pad "$jname"   "$wNAME"  l)"
        printf '%s%s%s'   "$sc"            "$(pad "$state"   "$wSTATE" l)" "$C_RESET"
        printf '%s'                         "$(pad "$runtime" "$wRT"    l)"
        printf '%s%s%s'   "$C_GPU"         "$(pad "$res"     "$wRES"   l)" "$C_RESET"
        printf '%s%s%s\n' "$C_HIGHLIGHT2"  "$(pad "$nr"      "$wNOD"   l)" "$C_RESET"
    done <<< "$job_data"

    section_footer_box
}

# ==============================================================================
# RECENT JOBS
# ==============================================================================
draw_recent_jobs_section() {
    local partition="$1" target_user="$2" all_flag="${3:-false}"
    local w; w=$(get_term_width)
    section_header "RECENT JOBS (last 5)" "user: $target_user"

    if ! command -v sacct >/dev/null 2>&1; then
        printf '  %ssacct not available on this cluster%s\n' "$C_MUTED" "$C_RESET"
        section_footer_box; return
    fi

    local wJID=12 wSTATE=12 wSTART=20 wEND=20 wELAP=10
    local fixed=$(( 2+wJID+wSTATE+wSTART+wEND+wELAP ))
    local rem=$(( w-fixed ))
    [ "$rem" -lt 30 ] && rem=30
    local wNAME=$(( rem*38/100 ))
    local wRES=$(( rem - wNAME ))
    [ "$wNAME" -lt 12 ] && wNAME=12
    [ "$wRES"  -lt 14 ] && wRES=14

    col_header "$(pad "JOB ID"    "$wJID"   l)\
$(pad "NAME"      "$wNAME"  l)\
$(pad "STATE"     "$wSTATE" l)\
$(pad "START"     "$wSTART" l)\
$(pad "END"       "$wEND"   l)\
$(pad "ELAPSED"   "$wELAP"  l)\
$(pad "RESOURCES" "$wRES"   l)"
    section_sep

    local sa="-u $target_user -X --noheader --parsable2 --starttime=now-7days"
    [ "$all_flag" = "false" ] && sa="$sa -r $partition"
    local fmt="JobID,JobName,State,Elapsed,Start,End,AllocCPUS,ReqMem,AllocNodes,ReqTRES"
    local count=0

    # FIX: single sacct call. Reverse with tac (Linux standard); fall back to
    # tail -r only if tac is absent.
    local _reverse_cmd
    if command -v tac >/dev/null 2>&1; then
        _reverse_cmd="tac"
    else
        _reverse_cmd="tail -r"
    fi

    while IFS='|' read -r jid jname state elapsed start_time end_time \
                            alloc_cpus req_mem alloc_nodes req_tres; do
        [ -z "$jid" ] && continue
        [[ "$jid" =~ ^JobID ]] && continue
        case "$state" in RUNNING|PENDING|COMPLETING) continue ;; esac
        (( count++ ))
        [ "$count" -gt 5 ] && break

        local gc=0 mem_mb=0
        gc=$(printf '%s' "$req_tres" \
            | grep -oP 'gres/gpu=\K[0-9]+' | head -1)
        gc=${gc:-0}
        if [[ "$req_mem" =~ ^([0-9]+(\.[0-9]+)?)([KMGTkmgt])[cn]?$ ]]; then
            local mv="${BASH_REMATCH[1]}" mu="${BASH_REMATCH[3]}"
            case "${mu,,}" in
                k) mem_mb=$(( ${mv%.*}/1024 ))      ;;
                m) mem_mb=${mv%.*}                  ;;
                g) mem_mb=$(( ${mv%.*}*1024 ))      ;;
                t) mem_mb=$(( ${mv%.*}*1048576 ))   ;;
            esac
        fi
        [[ "$alloc_nodes" =~ ^[0-9]+$ ]] || alloc_nodes=1
        [[ "$alloc_cpus"  =~ ^[0-9]+$ ]] || alloc_cpus=0

        local res ss sc sd ed
        res=$(build_res_str "$alloc_cpus" "$mem_mb" "gpu=${gc}" "$alloc_nodes")
        ss=$(printf '%s' "$state" | awk '{print $1}')
        sc=$(state_color "$ss")
        sd=$(fmt_time_12h "$start_time")
        ed=$(fmt_time_12h "$end_time")

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
    section_footer_box
}

# ==============================================================================
# QUEUE STATUS
# ==============================================================================
draw_queue_section() {
    local partition="$1" target_user="$2" all_flag="${3:-false}"
    local w pt pu
    w=$(get_term_width)
    section_header "QUEUE STATUS"

    local sqf="-p $partition"
    [ "$all_flag" = "true" ] && sqf=""

    # FIX: one squeue call; derive pt and pu from the same data.
    local pq_data
    pq_data=$(squeue $sqf -t PD -h -o "%i|%u|%M|%C|%m|%b|%D|%r" 2>/dev/null)
    pt=$(printf '%s\n' "$pq_data" | grep -c '.' || echo 0)
    pu=$(printf '%s\n' "$pq_data" \
        | awk -F'|' -v u="$target_user" '$2==u' | grep -c '.' || echo 0)
    [[ "$pt" =~ ^[0-9]+$ ]] || pt=0
    [[ "$pu" =~ ^[0-9]+$ ]] || pu=0

    if [ "$pt" -eq 0 ]; then
        printf '  %s ✓ Queue is clear — no pending jobs%s\n' "$C_SUCCESS" "$C_RESET"
        section_footer_box; return
    fi

    printf '  %s ⏳ Pending total: %s%d%s  %s%s pending: %s%d%s\n' \
        "$C_WARNING" "$C_RESET" "$pt" "$C_WARNING" \
        "$C_LABEL$target_user" "$C_RESET" \
        "$C_HIGHLIGHT" "$pu" "$C_RESET"

    local spa=""
    [ "$all_flag" = "false" ] && spa="-p $partition"
    local sprio_data
    sprio_data=$(sprio $spa --noheader -o "%.15i %.15y" 2>/dev/null || true)

    local wJID=12 wUSER=14 wWT=10 wPRI=10
    local fixed=$(( 2+wJID+wUSER+wWT+wPRI ))
    local rem=$(( w-fixed ))
    [ "$rem" -lt 30 ] && rem=30
    local wREQ=$(( rem*52/100 ))
    local wREA=$(( rem - wREQ ))
    [ "$wREQ" -lt 20 ] && wREQ=20
    [ "$wREA" -lt 15 ] && wREA=15

    col_header "$(pad "JOB ID"    "$wJID"  l)\
$(pad "USER"      "$wUSER" l)\
$(pad "WAIT TIME" "$wWT"   l)\
$(pad "PRIORITY"  "$wPRI"  l)\
$(pad "REQUESTED" "$wREQ"  l)\
$(pad "REASON"    "$wREA"  l)"
    section_sep

    local count=0
    while IFS='|' read -r jid juser wt cpus mem gres num_nodes reason; do
        [ -z "$jid" ] && continue
        (( count++ ))
        [ "$count" -gt 8 ] && break

        local res pri pc uc
        res=$(build_res_str "$cpus" "$mem" "$gres" "$num_nodes")
        pri=$(printf '%s' "$sprio_data" \
            | awk -v id="$jid" '$1==id { print $2; exit }')
        [ -z "$pri" ] && pri="-"
        if [[ "$pri" =~ ^[0-9]+$ ]]; then
            if   [ "$pri" -ge 1000 ]; then pc="$C_SUCCESS"
            elif [ "$pri" -ge 500  ]; then pc="$C_WARNING2"
            else                           pc="$C_MUTED"
            fi
        else
            pc="$C_MUTED"
        fi
        uc="$C_RESET"
        [ "$juser" = "$target_user" ] && uc="$C_HIGHLIGHT"

        printf '  %s%s%s' "$C_VALUE" "$(pad "$jid"    "$wJID"  l)" "$C_RESET"
        printf '%s%s%s'   "$uc"      "$(pad "$juser"  "$wUSER" l)" "$C_RESET"
        printf '%s'                   "$(pad "$wt"     "$wWT"   l)"
        printf '%s%s%s'   "$pc"      "$(pad "$pri"    "$wPRI"  l)" "$C_RESET"
        printf '%s%s%s'   "$C_GPU"   "$(pad "$res"    "$wREQ"  l)" "$C_RESET"
        printf '%s%s%s\n' "$C_MUTED" "$(pad "$reason" "$wREA"  l)" "$C_RESET"
    done <<< "$pq_data"

    [ "$pt" -gt 8 ] && \
        printf '  %s ... and %d more pending jobs%s\n' \
            "$C_MUTED" "$(( pt-8 ))" "$C_RESET"
    section_footer_box
}

# ==============================================================================
# FOOTER
# ==============================================================================
draw_footer() {
    local partition="$1" mode="${2:-snapshot}" all_flag="${3:-false}"
    local w; w=$(get_term_width)
    local inner=$(( w-4 ))

    printf '%s┌' "$C_HEADER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┐%s\n' "$C_RESET"

    printf '%s│%s  ' "$C_HEADER" "$C_RESET"
    if [ "$mode" = "interactive" ]; then
        printf '%s ▶ Refreshing every %ds%s' \
            "$C_SUCCESS" "${REFRESH:-$DEFAULT_REFRESH}" "$C_RESET"
        printf '  %sCtrl+C to exit%s' "$C_MUTED" "$C_RESET"
    else
        printf '%s■ Snapshot%s' "$C_MUTED" "$C_RESET"
    fi

    local part_label="$partition"
    [ "$all_flag" = "true" ] && part_label="ALL PARTITIONS"
    printf '  %s◈ %s%s' "$C_GPU"   "$part_label"      "$C_RESET"
    printf '  %s⊙ %s%s' "$C_MUTED" "$ACTIVE_TZ_LABEL" "$C_RESET"

    local right="${TOOL_NAME} v${VERSION}"
    printf '%*s%s%s%s' "4" '' "$C_MUTED" "$right" "$C_RESET"
    printf '%s│%s\n' "$C_HEADER" "$C_RESET"

    printf '%s└' "$C_HEADER"
    printf '%*s' "$inner" '' | tr ' ' '─'
    printf '┘%s\n' "$C_RESET"
}

# ==============================================================================
# DASHBOARD
# ==============================================================================
draw_dashboard() {
    local partition="$1" target_user="$2" mode="${3:-snapshot}" all_flag="${4:-false}"

    load_node_cache "$partition" "$all_flag"

    draw_header              "$partition" "$target_user" "$mode"
    printf '\n'
    draw_quick_stats         "$partition" "$all_flag"
    printf '\n'
    draw_nodes_section       "$partition" "$all_flag"
    printf '\n'
    draw_jobs_section        "$partition" "$target_user" "$all_flag"
    printf '\n'
    draw_recent_jobs_section "$partition" "$target_user" "$all_flag"
    printf '\n'
    draw_queue_section       "$partition" "$target_user" "$all_flag"
    printf '\n'
    draw_footer              "$partition" "$mode" "$all_flag"
}

# ==============================================================================
# FAST REFRESH WARNING
# ==============================================================================
confirm_fast_refresh() {
    local secs="$1"
    printf '\n%s ⚠ WARNING%s\n' "$C_WARNING" "$C_RESET" >/dev/tty
    printf '%sInterval %s%ds%s is below the safe minimum of %ds.\n' \
        "$C_MUTED" "$C_VALUE" "$secs" "$C_MUTED" "$MIN_SAFE_REFRESH" >/dev/tty
    printf 'Aggressive polling can overwhelm slurmctld and may result in throttling.%s\n' \
        "$C_RESET" >/dev/tty
    printf '\n%sProceed? [y/N]:%s ' "$C_LABEL" "$C_RESET" >/dev/tty
    local ans; read -r ans </dev/tty
    case "$ans" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *)                  return 1 ;;
    esac
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
    local partition="$DEFAULT_PARTITION"
    local target_user; target_user=$(whoami)
    local refresh="$DEFAULT_REFRESH"
    local interactive=false
    local all_flag=false
    local tz_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--partition)
                partition="$2"; shift 2 ;;
            -u|--user)
                target_user="$2"; shift 2 ;;
            --tz)
                tz_override="$2"; shift 2 ;;
            --all)
                all_flag=true; shift ;;
            -i|--interactive)
                interactive=true; shift
                if [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ]; then
                    refresh="$1"; shift
                fi ;;
            -h|--help)
                # resolve_timezone so the help footer can show the tz label
                resolve_timezone "${tz_override:-$DEFAULT_TZ}"
                show_help
                exit 0 ;;
            -*)
                printf '%sUnknown option: %s (try --help)%s\n' \
                    "$C_WARNING" "$1" "$C_RESET" >&2
                shift ;;
            *)
                partition="$1"; shift ;;
        esac
    done

    [[ "$refresh" =~ ^[0-9]+$ ]] && [ "$refresh" -ge 1 ] || refresh="$DEFAULT_REFRESH"
    export REFRESH="$refresh"
    resolve_timezone "${tz_override:-$DEFAULT_TZ}"

    validate_partition "$partition" "$all_flag"

    if [ "$all_flag" = "true" ] && [ "$interactive" = "true" ]; then
        printf '%s%s: Note: --all in interactive mode queries the full cluster each cycle.\n' \
            "$C_WARNING" "$TOOL_NAME" >&2
        printf 'Recommend a longer interval, e.g. -i 120%s\n' "$C_RESET" >&2
    fi

    if [ "$interactive" = true ] && [ "$refresh" -lt "$MIN_SAFE_REFRESH" ]; then
        confirm_fast_refresh "$refresh" \
            || { printf '%sAborted.%s\n' "$C_MUTED" "$C_RESET"; exit 0; }
    fi

    # ── Snapshot mode ─────────────────────────────────────────────────────────
    if [ "$interactive" = false ]; then
        draw_dashboard "$partition" "$target_user" "snapshot" "$all_flag"
        exit 0
    fi

    # ── Interactive mode ──────────────────────────────────────────────────────
    tput civis 2>/dev/null
    clear

    while true; do
        tput cup 0 0 2>/dev/null
        draw_dashboard "$partition" "$target_user" "interactive" "$all_flag"
        tput ed 2>/dev/null
        sleep "$refresh" &
        _SLEEP_PID=$!
        wait "$_SLEEP_PID" 2>/dev/null
        _SLEEP_PID=""
    done
}

main "$@"