#!/usr/bin/env bash
# ProtonVPN status + control for waybar.
#
#   protonvpn-status.sh            JSON for waybar (fast, nmcli only)
#   protonvpn-status.sh --text     plain one-line status
#   protonvpn-status.sh --details  JSON with server/load in the tooltip
#                                  (queries the protonvpn CLI, ~1s)
#   protonvpn-status.sh --toggle   connect using DEFAULT_CONNECT, or disconnect
#   protonvpn-status.sh --pick     searchable picker: country, server, or feature
#
# Configured by ~/.config/protonvpn-waybar.conf
# Exit code: --text and --toggle report 0 connected / 1 disconnected;
# the waybar JSON mode always exits 0 (non-zero would hide the module).

set -uo pipefail

CONFIG=${PROTONVPN_WAYBAR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/protonvpn-waybar.conf}
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/protonvpn-countries
CACHE_AGE_DAYS=7

DEFAULT_CONNECT=""
FAVOURITES=""
PICKER="fuzzel"
PICKER_ARGS="--dmenu --lines 15 --width 34 --prompt=vpn> "
# shellcheck source=/dev/null
[[ -r $CONFIG ]] && source "$CONFIG"

ICON_UP=$'\uf023'     # nf-fa-lock
ICON_DOWN=$'\uf09c'   # nf-fa-unlock
ICON_BLOCK=$'\uf071'  # nf-fa-warning

# ---------------------------------------------------------------- state

# Active NM connections: NAME:TYPE:DEVICE
active=$(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null)

vpn_line=$(printf '%s\n' "$active" | awk -F: '$2 == "wireguard" || $2 == "vpn" { print; exit }')
killswitch=$(printf '%s\n' "$active" | grep -c 'pvpn-killswitch')

server=""
if [[ -n $vpn_line ]]; then
    conn=${vpn_line%%:*}
    # "ProtonVPN NL#885" -> "NL#885"; anything else keeps its own name
    server=${conn#ProtonVPN }
fi

if [[ -n $server ]]; then
    state=connected
elif (( killswitch > 0 )); then
    state=blocked   # kill switch up with no tunnel: traffic is being dropped
else
    state=disconnected
fi

# ---------------------------------------------------------------- helpers

notify() {
    command -v notify-send >/dev/null && notify-send -a ProtonVPN -i network-vpn "$@"
}

details() {
    # Only the protonvpn CLI knows city/load; it is slow, so it is opt-in.
    command -v protonvpn >/dev/null || return
    protonvpn status 2>/dev/null | sed '/^Status:/d;/^[[:space:]]*$/d'
}

json() {
    local text=$1 alt=$2 class=$3 tooltip=$4
    jq -cn --arg t "$text" --arg a "$alt" --arg c "$class" --arg tt "$tooltip" \
        '{text: $t, alt: $a, class: $c, tooltip: $tt}'
}

# `protonvpn connect $args`, reporting the outcome through the notification daemon.
connect_to() {
    local label=$1 args=$2
    notify "Connecting" "$label"
    # shellcheck disable=SC2086
    if out=$(protonvpn connect $args 2>&1); then
        notify "Connected" "$(printf '%s\n' "$out" | grep -i '^Server:' || echo "$label")"
    else
        notify -u critical "Connection failed" "$(printf '%s\n' "$out" | tail -1)"
        return 1
    fi
}

# Country list is slow to fetch, so keep a cached copy.
countries() {
    if [[ ! -s $CACHE ]] || [[ -n $(find "$CACHE" -mtime +$CACHE_AGE_DAYS 2>/dev/null) ]]; then
        local fresh
        fresh=$(protonvpn countries list 2>/dev/null |
                awk '/^[A-Za-z].*[[:space:]][A-Z][A-Z][[:space:]]*$/ {
                         code = $NF; sub(/[[:space:]]*[A-Z][A-Z][[:space:]]*$/, "")
                         print $0 " | --country " code
                     }' |
                sed 's/[[:space:]]\+|/ |/')
        [[ -n $fresh ]] && printf '%s\n' "$fresh" > "$CACHE"
    fi
    cat "$CACHE" 2>/dev/null
}

# Turn text the user typed (rather than picked) into `protonvpn connect` arguments.
freeform_args() {
    local input=$1
    case $input in
        *'#'*)              printf '%s' "$input" ;;          # NL#885
        city:*)             printf -- '--city %q' "${input#city:}" ;;
        [A-Za-z][A-Za-z])   printf -- '--country %s' "${input^^}" ;;
        *)                  printf -- '--country %q' "$input" ;;
    esac
}

pick() {
    local menu selection label args
    menu=$(
        printf '%s\n' "$FAVOURITES" | sed '/^[[:space:]]*$/d'
        echo "Fastest (auto) |"
        [[ $state == connected ]] && echo "Disconnect | DISCONNECT"
        countries
    )

    selection=$(printf '%s\n' "$menu" | sed 's/[[:space:]]*|.*$//' |
                $PICKER $PICKER_ARGS) || return 0
    [[ -z $selection ]] && return 0

    # An exact label match uses its configured arguments; anything else is
    # treated as free text, so you can type NL#885 or city:Amsterdam directly.
    args=$(printf '%s\n' "$menu" |
           awk -F'|' -v s="$selection" '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1) }
                                        $1 == s { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }')
    label=$selection

    if [[ $args == DISCONNECT ]]; then
        protonvpn disconnect && notify "Disconnected"
        return
    fi
    if ! printf '%s\n' "$menu" | sed 's/[[:space:]]*|.*$//' | grep -qxF "$selection"; then
        args=$(freeform_args "$selection")
    fi

    eval "connect_to \"\$label\" \"\$args\""
}

# ---------------------------------------------------------------- modes

case ${1-} in
--toggle)
    if [[ $state == connected ]]; then
        protonvpn disconnect && notify "Disconnected"
    else
        connect_to "${DEFAULT_CONNECT:-fastest server}" "$DEFAULT_CONNECT"
    fi
    exit $?
    ;;
--pick)
    pick
    exit $?
    ;;
--text)
    case $state in
        connected)    echo "ProtonVPN: connected ($server)" ;;
        blocked)      echo "ProtonVPN: disconnected, kill switch active" ;;
        disconnected) echo "ProtonVPN: disconnected" ;;
    esac
    [[ $state == connected ]]
    exit $?
    ;;
*)
    extra=""
    [[ ${1-} == --details && $state == connected ]] && extra=$'\n'"$(details)"

    case $state in
        connected)
            json "$ICON_UP $server" connected connected \
                 "ProtonVPN connected: $server$extra"$'\n'"Right-click to switch server" ;;
        blocked)
            json "$ICON_BLOCK" blocked blocked \
                 "ProtonVPN disconnected — kill switch is blocking traffic" ;;
        disconnected)
            json "$ICON_DOWN" disconnected disconnected \
                 "ProtonVPN disconnected"$'\n'"Right-click to pick a server" ;;
    esac
    # Always succeed: waybar hides a custom module whose exec exits non-zero.
    exit 0
    ;;
esac
