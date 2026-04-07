#!/bin/bash

# Variables
SCRIPT_NAME=$(basename "$0")
CONFIG_PATH="/etc/wireguard"
DB_PATH="/var/lib/$SCRIPT_NAME"

# Define error codes
ERR_CONFIG_PATH_NOT_EXIST=4
ERR_DB_PATH_NOT_EXIST=5
ERR_MISSING_COMMAND=6
ERR_ROOT_REQUIRED=7
ERR_NO_INTERFACE_FOUND=8
ERR_MISSING_TOOL=9
ERR_INVALID_INTERFACE_NAME=10
ERR_UNKNOWN_PARAM=11
ERR_INTERFACE_EXISTS=12
ERR_MISSING_PARAMS=13
ERR_INVALID_IP_FORMAT=14
ERR_INVALID_PREFIX=15
ERR_FAILED_TO_SAVE_CONFIG=16
ERR_FAILED_TO_LOAD_CONFIG=17
ERR_FAILED_TO_GENERATE_KEY=18
ERR_INVALID_PORT=19
ERR_NO_AVAILABLE_IP=20
ERR_FAILED_TO_SYNC_CONFIG=21
ERR_FAILED_TO_START_INTERFACE=22
ERR_FAILED_TO_STOP_INTERFACE=23
ERR_FAILED_TO_DELETE_INTERFACE=24
ERR_PEER_ALREADY_EXISTS=25
ERR_PEER_NOT_FOUND=26
ERR_INVALID_PEER_NAME=27
ERR_MISSING_VALUE=28
ERR_INVALID_PSK=29

# Error Handler function
error_handler() {
    local code="$1"
    case "$code" in
        $ERR_CONFIG_PATH_NOT_EXIST) echo "Error: WireGuard configuration path does not exist" >&2 ;;
        $ERR_DB_PATH_NOT_EXIST) echo "Error: Database path does not exist" >&2 ;;
        $ERR_MISSING_COMMAND) ;; #echo "Error: Missing command" >&2
        $ERR_ROOT_REQUIRED) echo "Error: Root privileges required" >&2 ;;
        $ERR_NO_INTERFACE_FOUND) echo "Error: No interfaces found" >&2 ;;
        $ERR_MISSING_TOOL) echo "Error: Missing required tool" >&2 ;;
        $ERR_INVALID_INTERFACE_NAME) echo "Error: Invalid interface name" >&2 ;;
        $ERR_UNKNOWN_PARAM) echo "Error: Unknown parameter" >&2 ;;
        $ERR_INTERFACE_EXISTS) echo "Error: Interface already exists" >&2 ;;
        $ERR_MISSING_PARAMS) echo "Error: Missing required parameters" >&2 ;;
        $ERR_INVALID_IP_FORMAT) echo "Error: Invalid IP format" >&2 ;;
        $ERR_INVALID_PREFIX) echo "Error: Invalid prefix" >&2 ;;
        $ERR_FAILED_TO_SAVE_CONFIG) echo "Error: Failed to save configuration" >&2 ;;
        $ERR_FAILED_TO_LOAD_CONFIG) echo "Error: Failed to load configuration" >&2 ;;
        $ERR_INVALID_PORT) echo "Error: Invalid port" >&2 ;;
        $ERR_FAILED_TO_GENERATE_KEY) echo "Error: Failed to generate key" >&2 ;;
        $ERR_NO_AVAILABLE_IP) echo "Error: No available IP found" >&2 ;;
        $ERR_FAILED_TO_SYNC_CONFIG) echo "Error: Failed to sync configuration" >&2 ;;
        $ERR_FAILED_TO_START_INTERFACE) echo "Error: Failed to start interface" >&2 ;;
        $ERR_FAILED_TO_STOP_INTERFACE) echo "Error: Failed to stop interface" >&2 ;;
        $ERR_FAILED_TO_DELETE_INTERFACE) echo "Error: Failed to delete interface" >&2 ;;
        $ERR_PEER_ALREADY_EXISTS) echo "Error: Peer already exists" >&2 ;;
        $ERR_PEER_NOT_FOUND) echo "Error: Peer not found" >&2 ;;
        $ERR_INVALID_PEER_NAME) echo "Error: Invalid peer name" >&2 ;;
        $ERR_MISSING_VALUE) echo "Error: Missing a value needed by an option" >&2 ;;
        $ERR_INVALID_PSK) echo "Error: Invalid Preshared Key" >&2 ;;
        *) echo "Error: Unknown error" >&2 ;;
    esac
    exit "$code"
}

# Check if script is running as root
if [ "$EUID" -ne 0 ]; then
    error_handler $ERR_ROOT_REQUIRED
fi

# Exit if reqired paths do not exist
[ ! -d "$CONFIG_PATH" ] && error_handler $ERR_CONFIG_PATH_NOT_EXIST
[ ! -d "$DB_PATH" ] && error_handler $ERR_DB_PATH_NOT_EXIST

# Validate commands
for cmd in "wg" "wg-quick" "find" "jq" "openssl"; do
    if ! command -v "$cmd" &> /dev/null; then
        error_handler $ERR_MISSING_TOOL
    fi
done

# Usage function
usage() {
    echo "Usage: $SCRIPT_NAME <command> [options]"
    echo ""
    echo "Commands:"
    echo "  show interfaces [options]               List all WireGuard interfaces"
    echo "  create <interface> [options]            Create a new WireGuard interface"
    echo "  show <interface> [options]              Show details of a WireGuard interface"
    echo "  apply <interface>                       Apply configuration to a WireGuard interface"
    echo "  start <interface>                       Start a WireGuard interface"
    echo "  stop <interface>                        Stop a WireGuard interface"
    echo "  delete <interface>                      Delete a WireGuard interface"
    echo "  add <peer> for <interface> [options]    Add a new peer to a WireGuard interface"
    echo "  remove <peer> for <interface>           Remove a peer from a WireGuard interface"
    echo "  enable <peer> for <interface>           Enable a peer in a WireGuard interface"
    echo "  disable <peer> for <interface>          Disable a peer in a WireGuard interface"
    echo "  export <peer> for <interface>           Export a peer configuration"
    echo "  help                                    Show this usage information"
    echo ""
    echo "Use '$SCRIPT_NAME help' for more information on a command."
}

# Check if interface is up
# Usage: interface_is_up <interface_name>
interface_is_up() {
    local interface_name="$1"
    # Validate interface name
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi
    local interfaces=($(wg show interfaces))
    local iface=""
    for iface in "${interfaces[@]}"; do
        if [ "$iface" == "$interface_name" ]; then
            return 0
        fi
    done
    return 1
}

list_interfaces() {
    local format="plain"
    # Parse arguments
    shift
    while [[ $# -gt 0 ]]; do
        local key="$1"
        shift
        case "$key" in
            format) 
                format="$1"
                shift
                ;;
            *) 
                return $ERR_UNKNOWN_PARAM
                ;;
        esac
    done
    
    # Generate an array of interfaces from json files in DB_PATH
    local interfaces=()
    while IFS= read -r line; do
        interfaces+=("$line")
    done < <(find "$DB_PATH" -type f -name "*.json" -exec basename {} \; | sed 's/\.json//g')
    
    # Print interfaces list if found any
    [ ${#interfaces[@]} -gt 0 ] || return $ERR_NO_INTERFACE_FOUND

    if [ "$format" == "plain" ]; then
        local output=""
        local iface=""
        for iface in "${interfaces[@]}"; do
            if interface_is_up "$iface"; then
                output+="${iface}(up) "
            else
                output+="${iface}(down) "
            fi
        done
        echo "${output%?}" # Remove trailing space
    elif [ "$format" == "json" ]; then
        local json_obj="{}"
        local iface=""
        for iface in "${interfaces[@]}"; do
            # Extract address in CIDR notation from the json file
            local iface_json=$(cat "$DB_PATH/$iface.json")
            local cidr_addr=$(echo "$iface_json" | jq -r '.interface.address')
            
            # Skip this interface if cidr_addr is not valid
            if [[ -z "$cidr_addr" || "$cidr_addr" != *"/"* ]]; then
                continue
            fi
            
            # Split the address and prefix length
            local address=${cidr_addr%/*}
            local prefix=${cidr_addr#*/}
            
            # Skip if prefix is not a valid number
            if ! [[ "$prefix" =~ ^[0-9]+$ ]] || [ "$prefix" -lt 0 ] || [ "$prefix" -gt 32 ]; then
                continue
            fi
            
            # Create netmask from prefix length
            local mask_int=$(( 0xffffffff ^ ((1 << (32 - prefix)) - 1) ))
            
            # Calculate network address
            local addr_int=$(ip_to_int "$address")
            local network_int=$(( addr_int & mask_int ))
            local network=$(int_to_ip "$network_int")
            
            # Format network in CIDR notation
            local network_cidr="$network/$prefix"
            
            # Detect interface status
            if interface_is_up "$iface"; then
                status="up"
            else
                status="down"
            fi
            
            # Build JSON object using jq
            json_obj=$(echo "$json_obj" | jq --arg iface "$iface" --arg status "$status" --arg network "$network_cidr" '.[$iface] = {"network": $network, "status": $status}')
        done
        # Wrap in interfaces object
        echo "$json_obj" | jq '{"interfaces":.}'
    fi
    
    return 0
}

# Create interface function
# Usage: create_interface <interface_name> [options]
# Options:
#   address <address>         Interface address in CIDR format
#   listen-port <port>        Interface listen port
#   pre-up <command>          Pre-up command
#   post-up <command>         Post-up command
#   pre-down <command>        Pre-down command
#   post-down <command>       Post-down command
#   private-key <key>         Private key
#   dns <dns>                 DNS servers (default:1.1.1.1, 1.0.0.1)
#   endpoint <endpoint>       Endpoint
create_interface() {
    local interface_name="$1" dns="1.1.1.1, 1.0.0.1" endpoint="" address="" listen_port="" 
    local private_key="" pre_up="" post_up="" pre_down="" post_down=""
    shift

    # validate interface name
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi
    
    if [[ ! "$interface_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return $ERR_INVALID_INTERFACE_NAME
    fi

    # Check if interface already exists
    if [ -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_INTERFACE_EXISTS
    fi

    # Parse arguments
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        local key="$1"
        shift
        case "$key" in
            address)
                address="$1"
                shift
                ;;
            listen-port)
                listen_port="$1"
                shift
                ;;
            pre-up)
                # Capture the entire command (which may contain spaces)
                pre_up="$1"
                shift
                ;;
            post-up)
                post_up="$1"
                shift
                ;;
            pre-down)
                pre_down="$1"
                shift
                ;;
            post-down)
                post_down="$1"
                shift
                ;;
            private-key)
                private_key="$1"
                shift
                ;;
            dns)
                dns="$1"
                shift
                ;;
            endpoint)
                endpoint="$1"
                shift
                ;;
            *)
                return $ERR_UNKNOWN_PARAM
                ;;
        esac
    done

    # Check address, listen port and endpoint are provided
    if [ -z "$address" ] || [ -z "$listen_port" ] || [ -z "$endpoint" ]; then
        return $ERR_MISSING_PARAMS
    fi

    # Validate address
    if [[ ! "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        return $ERR_INVALID_IP_FORMAT
    fi

    # Make sure port is valid
    if [[ ! "$listen_port" =~ ^[0-9]+$ ]] || [ "$listen_port" -lt 1 ] || [ "$listen_port" -gt 65535 ]; then
        return #ERR_INVALID_PORT
    fi
    
    # Validate Private Key if provided or generate new key pair
    if [ -z "$private_key" ]; then
        private_key=$(wg genkey)
    fi
    public_key=$(echo "$private_key" | wg pubkey)
    [ $? -ne 0 ] && return $ERR_FAILED_TO_GENERATE_KEY

    # Create JSON configuration
    json_config=$(jq -n \
        --arg name "$interface_name" \
        --arg private_key "$private_key" \
        --arg public_key "$public_key" \
        --arg listen_port "$listen_port" \
        --arg address "$address" \
        --arg pre_up "$pre_up" \
        --arg post_up "$post_up" \
        --arg pre_down "$pre_down" \
        --arg post_down "$post_down" \
        --arg dns "$dns" \
        --arg endpoint "$endpoint" \
        '{
            "global": {
                "dns": $dns,
                "endpoint": $endpoint
            },
            "interface": {
                "name": $name,
                "privateKey": $private_key,
                "publicKey": $public_key,
                "listenPort": $listen_port,
                "address": $address,
                "preUp": $pre_up,
                "postUp": $post_up,
                "preDown": $pre_down,
                "postDown": $post_down,
            },
            "peers": {}
        }')

    # Save configuration to file
    echo "$json_config" > "$DB_PATH/$interface_name.json" || return $ERR_FAILED_TO_SAVE_CONFIG
    return 0
}

# Show interface function
# Usage: show_interface <interface_name>
# Options:
#   format <format>           Output format(ini, json; default: ini)
show_interface() {
    local interface_name="$1"
    local format="ini"
    shift
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi

    # Return error if interface does not exist
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # Load JSON configuration from file into variable and validate JSON
    local json_config=$(jq -r . "$DB_PATH/$interface_name.json")
    if [ -z "$json_config" ]; then
        return $ERR_FAILED_TO_LOAD_CONFIG
    fi

    while [[ $# -gt 0 ]]; do
        local key="$1"
        shift
        case "$key" in
            format) 
                format="$1"
                shift
                ;;
            *) 
                return $ERR_UNKNOWN_PARAM
                ;;
        esac
    done

    if [ "$format" == "json" ]; then
        jq '.interface |= with_entries(select(.value != ""))' <<< "$json_config"
    elif [ "$format" == "ini" ]; then
        # Print global section from JSON configuration in INI format(dont print empty fields)
        echo "[Global]"
        jq -r '.global | "DNS = " + .dns, "Endpoint = " + .endpoint' <<< "$json_config"
        echo ""

        echo "[Interface]"
        # Build the interface section (excluding "name" and "publicKey")
        jq -r '
            .interface as $i | [
            "Name = " + $i.name,
            "PrivateKey = " + $i.privateKey,
            "PublicKey = " + $i.publicKey,
            "ListenPort = " + $i.listenPort,
            "Address = " + $i.address
            ]
            + (if $i.preUp != "" then ["PreUp = " + $i.preUp] else [] end)
            + (if $i.postUp != "" then ["PostUp = " + $i.postUp] else [] end)
            + (if $i.preDown != "" then ["PreDown = " + $i.preDown] else [] end)
            + (if $i.postDown != "" then ["PostDown = " + $i.postDown] else [] end)
            | .[]
        ' <<< "$json_config"
        
        # Print peers section from JSON configuration in INI format(print empty line after each peer)
        jq -r '.peers | to_entries[] | "\n[Peer]\nName = \(.key)\nPublicKey = \(.value.publicKey)\nAllowedIPs = \(.value.allowedIPs)\nStatus = \(.value.status)"' <<< "$json_config"
    fi

    return 0
}

# Apply interface function
# Usage: apply_interface <interface_name>
apply_interface() {
    # validate interface name
    local interface_name="$1"
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi

    # Check if interface exists
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # Load JSON configuration from file into variable and validate JSON
    local json_config=$(jq -r . "$DB_PATH/$interface_name.json")
    if [ -z "$json_config" ]; then
        return $ERR_FAILED_TO_LOAD_CONFIG
    fi

    # Parse JSON configuration
    local wg_config=""
    wg_config=$(
        echo "[Interface]"
        # Build the interface section (excluding "name" and "publicKey")
        jq -r '
            .interface as $i |
            [
            "PrivateKey = " + $i.privateKey,
            "ListenPort = " + $i.listenPort,
            "Address = " + $i.address
            ]
            + (if $i.preUp != "" then ["PreUp = " + $i.preUp] else [] end)
            + (if $i.postUp != "" then ["PostUp = " + $i.postUp] else [] end)
            + (if $i.preDown != "" then ["PreDown = " + $i.preDown] else [] end)
            + (if $i.postDown != "" then ["PostDown = " + $i.postDown] else [] end)
            | .[]
        ' <<< "$json_config"
        # Build the peers section (one block per peer, with an empty line preceding each)
        jq -r '.peers | to_entries[] | select(.value.status == "enable")
            | "\n[Peer]\nPublicKey = \(.value.publicKey)\nAllowedIPs = \(.value.allowedIPs)"' <<< "$json_config"

        # add a PSK if one exists for the peer
        local usePSK = jq -r --arg peer "$peer_name" '.peers[$peer].usePSK' <<< "$json_config"
        if [ ! -z  $usePSK ]; then
            "\nPresharedKey = $usePSK"
        fi
    )

    # Save WireGuard configuration to file
    echo -e "$wg_config" > "$CONFIG_PATH/$interface_name.conf" || return $ERR_FAILED_TO_SAVE_CONFIG

    # Sync WireGuard configuration using wg-quick strip
    if interface_is_up "$interface_name"; then
        wg syncconf "$interface_name" <(wg-quick strip "$interface_name") || return $ERR_FAILED_TO_SYNC_CONFIG
    fi

    return 0
}

# Start interface function
# Usage: start_interface <interface_name>
start_interface() { 
    # validate interface name
    local interface_name="$1"
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi

    # check if interface exists in wireguard path
    if [ ! -f "$CONFIG_PATH/$interface_name.conf" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # start wireguard interface if not running
    if ! interface_is_up "$interface_name"; then
        wg-quick up "$interface_name" > /dev/null 2>&1 || return $ERR_FAILED_TO_START_INTERFACE
    fi
}

# Stop interface function
# Usage: stop_interface <interface_name>
stop_interface() { 
    # validate interface name
    local interface_name="$1"
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi

    # check if interface exists in wireguard path
    if [ ! -f "$CONFIG_PATH/$interface_name.conf" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # stop wireguard interface 
    if interface_is_up "$interface_name"; then
        wg-quick down "$interface_name" > /dev/null 2>&1 || return $ERR_FAILED_TO_STOP_INTERFACE
    fi

    return 0
}

# Delete interface function
# Usage: delete_interface <interface_name>
delete_interface() {
    # validate interface name
    local interface_name="$1"
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi

    # check if interface exists in database path
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # stop wireguard interface if running(check using wg show interfaces)
    if interface_is_up "$interface_name"; then
        wg-quick down "$interface_name" > /dev/null 2>&1 || return $ERR_FAILED_TO_STOP_INTERFACE
    fi

    # delete wireguard configuration file
    if [ -f "$CONFIG_PATH/$interface_name.conf" ]; then
        rm -f "$CONFIG_PATH/$interface_name.conf" || return $ERR_FAILED_TO_DELETE_INTERFACE
    fi


    # delete interface configuration file
    if [ -f "$DB_PATH/$interface_name.json" ]; then
        rm -f "$DB_PATH/$interface_name.json" || return $ERR_FAILED_TO_DELETE_INTERFACE
    fi

    return 0
}

# Remove peer function
# Usage: remove_peer <peer_name> from <interface_name>
remove_peer() {
    local peer_name="$1" interface_name="$3"
    if [[ -z "$peer_name" || -z "$interface_name" ]]; then
        return $ERR_MISSING_PARAMS
    fi

    # Validate peer name
    if [[ ! "$peer_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return $ERR_INVALID_PEER_NAME
    fi

    # Check if interface exists
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # Load JSON configuration from file into variable and validate JSON
    local json_config=$(jq -r . "$DB_PATH/$interface_name.json")
    if [ -z "$json_config" ]; then
        return $ERR_FAILED_TO_LOAD_CONFIG
    fi

    # Check if peer exists
    if ! jq -e ".peers | has(\"$peer_name\")" <<< "$json_config" > /dev/null; then
        return $ERR_PEER_NOT_FOUND
    fi

    # Remove peer from JSON configuration
    json_config=$(jq "del(.peers[\"$peer_name\"])" <<< "$json_config")

    # Save configuration to file
    echo "$json_config" > "$DB_PATH/$interface_name.json" || return $ERR_FAILED_TO_SAVE_CONFIG

    return 0
}

# Enable peer function
# Usage: enable_peer <peer_name> from <interface_name>
enable_peer() {
    # Validate peer name and interface name
    local peer_name="$1" interface_name="$3"
    if [[ -z "$peer_name" || -z "$interface_name" ]]; then
        return $ERR_MISSING_PARAMS
    fi

    # Check if interface exists
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # Load JSON configuration from file into variable and validate JSON
    local json_config=$(jq -r . "$DB_PATH/$interface_name.json")
    if [ -z "$json_config" ]; then
        return $ERR_FAILED_TO_LOAD_CONFIG
    fi

    # Check if peer exists
    if ! jq -e ".peers | has(\"$peer_name\")" <<< "$json_config" > /dev/null; then
        return $ERR_PEER_NOT_FOUND
    fi

    # Enable peer in JSON configuration
    json_config=$(jq ".peers[\"$peer_name\"].status = \"enable\"" <<< "$json_config")

    # Save configuration to file
    echo "$json_config" > "$DB_PATH/$interface_name.json" || return $ERR_FAILED_TO_SAVE_CONFIG

    return 0
}

# Disable peer function
# Usage: disable_peer <peer_name> from <interface_name>
disable_peer() {
    # Validate peer name and interface name
    local peer_name="$1" interface_name="$3"
    if [[ -z "$peer_name" || -z "$interface_name" ]]; then
        return $ERR_MISSING_PARAMS
    fi

    # Check if interface exists
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # Load JSON configuration from file into variable and validate JSON
    local json_config=$(jq -r . "$DB_PATH/$interface_name.json")
    if [ -z "$json_config" ]; then
        return $ERR_FAILED_TO_LOAD_CONFIG
    fi

    # Check if peer exists
    if ! jq -e ".peers | has(\"$peer_name\")" <<< "$json_config" > /dev/null; then
        return $ERR_PEER_NOT_FOUND
    fi

    # Disable peer in JSON configuration
    json_config=$(jq ".peers[\"$peer_name\"].status = \"disable\"" <<< "$json_config")

    # Save configuration to file
    echo "$json_config" > "$DB_PATH/$interface_name.json" || return $ERR_FAILED_TO_SAVE_CONFIG

    return 0
}

# Export peer function
# Usage: export_peer <peer_name> from <interface_name>
export_peer() {
    # Validate peer name and interface name
    local peer_name="$1" interface_name="$3"
    if [[ -z "$peer_name" || -z "$interface_name" ]]; then
        return $ERR_MISSING_PARAMS
    fi

    # Check if interface exists
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # Load JSON configuration from file into variable and validate JSON
    local json_config=$(jq -r . "$DB_PATH/$interface_name.json")
    if [ -z "$json_config" ]; then
        return $ERR_FAILED_TO_LOAD_CONFIG
    fi

    # Check if peer exists
    if ! jq -e --arg peer "$peer_name" '.peers | has($peer)' <<< "$json_config" > /dev/null; then
        return $ERR_PEER_NOT_FOUND
    fi

    # Get DNS and endpoint from global configuration
    local dns=$(jq -r '.global.dns' <<< "$json_config")
    local endpoint=$(jq -r '.global.endpoint' <<< "$json_config")

    # Get interface public key and listen port from interface configuration
    local listen_port=$(jq -r '.interface.listenPort' <<< "$json_config")
    local public_key=$(jq -r '.interface.publicKey' <<< "$json_config")

    # Get peer private key and allowed IPs from peer configuration
    local private_key=$(jq -r --arg peer "$peer_name" '.peers[$peer].privateKey' <<< "$json_config")
    local allowed_ips=$(jq -r --arg peer "$peer_name" '.peers[$peer].allowedIPs' <<< "$json_config")

    # Generate peer configuration
    peer_config="[Interface]\n"
    peer_config+="PrivateKey = $private_key\n"
    peer_config+="Address = $allowed_ips\n"
    peer_config+="DNS = $dns\n\n"
    peer_config+="[Peer]\n"
    peer_config+="PublicKey = $public_key\n"
    peer_config+="Endpoint = $endpoint:$listen_port\n"
    peer_config+="AllowedIPs = 0.0.0.0/0, ::"

    # add a PSK if one exists for the peer
    local use_psk=$(jq -r --arg peer "$peer_name" '.peers[$peer].usePSK' <<< "$json_config")
    if [ -n $use_psk ]; then
        peer_config+="\nPresharedKey = $use_psk"
    fi

    # output config
    echo -e "$peer_config"

    return 0
}


# Convert IP address to integer
ip_to_int() {
    local ip="$1"
    local o1 o2 o3 o4
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    echo $(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
}

# Convert integer to IP address
int_to_ip() {
    local int="$1"
    echo "$(( (int >> 24) & 0xFF )).$(( (int >> 16) & 0xFF )).$(( (int >> 8) & 0xFF )).$(( int & 0xFF ))"
}

# Add peer function
# Usage: add_peer <peer_name> for <interface_name> [options]
# Options:
#   private-key <key>         Private key
#   allowed-ips <ips>         Allowed IPs
#   use-psk [psk]             PresharedKey  
add_peer() {
    # Validate peer name
    local peer_name="$1"
    shift
    if [ -z "$peer_name" ]; then
        return $ERR_MISSING_PARAMS
    fi
    if [[ ! "$peer_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return $ERR_INVALID_PEER_NAME
    fi

    # Skip word "for"
    shift

    # Validate peer name and interface name
    local interface_name="$1"
    shift
    if [ -z "$interface_name" ]; then
        return $ERR_MISSING_PARAMS
    fi

    # Check if interface exists
    if [ ! -f "$DB_PATH/$interface_name.json" ]; then
        return $ERR_NO_INTERFACE_FOUND
    fi

    # Load JSON configuration from file into variable and validate JSON
    local json_config=$(jq -r . "$DB_PATH/$interface_name.json")
    if [ -z "$json_config" ]; then
        return $ERR_FAILED_TO_LOAD_CONFIG
    fi

    # Check if peer already exists
    if jq -e ".peers | has(\"$peer_name\")" <<< "$json_config" > /dev/null; then
        return $ERR_PEER_ALREADY_EXISTS
    fi

    # Parse arguments
    local private_key="" allowed_ips="" use_psk="" use_psk="" generate_psk=false
    local psk_regex='^[A-Za-z0-9+/]{43}=$'

    while [[ $# -gt 0 ]]; do
        case "$1" in
            private-key)
                if [[ -z "${2-}" || "$2" == "private-key" || "$2" == "allowed-ips" || "$2" == "use-psk" ]]; then
                    return $ERR_MISSING_VALUE
                fi
                private_key="$2"
                shift 2
                ;;
            allowed-ips)
                if [[ -z "${2-}" || "$2" == "private-key" || "$2" == "allowed-ips" || "$2" == "use-psk" ]]; then
                    return $ERR_MISSING_VALUE
                fi
                allowed_ips="$2"
                shift 2
                ;;
            use-psk)
                if [[ -z "${2-}" || "$2" == "private-key" || "$2" == "allowed-ips" || "$2" == "use-psk" ]]; then
                    generate_psk=true
                    shift 1
                else
                    use_psk="$2"
                    if [[ ! "$use_psk" =~ $psk_regex ]]; then
                        return $ERR_INVALID_PSK
                    fi
                    shift 2
                fi
                ;;
            *)
                return $ERR_UNKNOWN_PARAM
                ;;
        esac
    done

    # generate a psk if not provided
    if [[ "$generate_psk" == true ]]; then
        use_psk="$(openssl rand --base64 32)"
    fi

    # Generate key pair if not provided
    if [[ -z "$private_key" ]]; then
        private_key=$(wg genkey)
    fi
    public_key=$(echo "$private_key" | wg pubkey)

    # Calculate peer IP address if not provided
    if [[ -z "$allowed_ips" ]]; then
        # Get interface address and validate format
        local interface_address=$(jq -r '.interface.address' <<< "$json_config")
        if [[ ! "$interface_address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            return $ERR_INVALID_IP_FORMAT
        fi

        # Parse interface IP and CIDR
        local interface_ip="${interface_address%%/*}"
        local cidr="${interface_address##*/}"

        # Calculate network address
        local interface_int=$(ip_to_int "$interface_ip")
        local mask=$((0xFFFFFFFF << (32 - cidr)))
        local network_int=$(( $interface_int & mask ))
        local network_ip=$(int_to_ip "$network_int")

        # Calculate IP range boundaries
        local first_host=$(( network_int + 1 ))
        local last_host=$(( network_int | (~mask & 0xFFFFFFFF) - 1 ))

        # Initialize used_ips array with interface IP
        used_ips=($(ip_to_int "$interface_ip"))

        # Single loop to process all peer IPs
        while IFS= read -r ip; do
            ip_part="${ip%%/*}"
            used_ips+=($(ip_to_int "$ip_part"))
        done < <(jq -r '.peers[].allowedIPs' <<< "$json_config" | tr ',' '\n')

        # Find first available IP in subnet range
        for (( ip_int = first_host; ip_int <= last_host; ip_int++ )); do
            # Check if IP is used
            for used in "${used_ips[@]}"; do
                [[ "$used" == "$ip_int" ]] && continue 2
            done

            # Found available IP
            allowed_ips="$(int_to_ip "$ip_int")/32"
            break
        done

        [[ -z "$allowed_ips" ]] && return $ERR_NO_AVAILABLE_IP
    fi

    # append peer to peers section in JSON configuration
    json_config=$(jq --arg peer_name "$peer_name" \
                     --arg public_key "$public_key" \
                     --arg private_key "$private_key" \
                     --arg allowed_ips "$allowed_ips" \
                     --arg use_psk "$use_psk" \
                     --arg status "enable" \
        '.peers[$peer_name] = {"privateKey": $private_key, "publicKey": $public_key, "allowedIPs": $allowed_ips, "usePSK": $use_psk, "status": $status}' <<< "$json_config")

    # Save configuration to file
    echo "$json_config" > "$DB_PATH/$interface_name.json" || return $ERR_FAILED_TO_SAVE_CONFIG
    return 0
}


# Main function
main() {
    if [ "$#" -eq 0 ]; then
        echo "Usage: $SCRIPT_NAME <command> [options]"
        echo "Use '$SCRIPT_NAME help' for more information."
        error_handler $ERR_MISSING_COMMAND
    fi

    COMMAND="$1"
    shift
    
    case "$COMMAND" in
        create) 
            create_interface "$@" && echo "Interface created successfully" || error_handler $?
        ;;
        show)
            if [ "$1" == "interfaces" ]; then
                list_interfaces "$@" || error_handler $?
            else
                show_interface "$@" || error_handler $?
            fi
        ;;
        apply)
            apply_interface "$@" && echo "Interface applied successfully" || error_handler $? 
        ;;
        start)
            start_interface "$@" && echo "Interface started successfully" || error_handler $?
        ;;
        stop)
            stop_interface "$@" && echo "Interface stopped successfully" || error_handler $?
        ;;
        delete)
            delete_interface "$@" && echo "Interface deleted successfully" || error_handler $?
        ;;
        add)
            add_peer "$@" && echo "Peer added successfully" || error_handler $?
        ;;
        remove)
            remove_peer "$@" && echo "Peer removed successfully" || error_handler $?
        ;;
        enable)
            enable_peer "$@" && echo "Peer enabled successfully" || error_handler $?
        ;;
        disable)
            disable_peer "$@" && echo "Peer disabled successfully" || error_handler $?
        ;;
        export)
            export_peer "$@" || error_handler $?
        ;;
        help)
            usage
        ;;
        *)
            echo "Invalid command: $COMMAND"
            echo "Use '$SCRIPT_NAME help' for more information."
            error_handler $ERR_MISSING_COMMAND
        ;;
    esac
}

# Execute main function with all arguments
main "$@"
exit 0