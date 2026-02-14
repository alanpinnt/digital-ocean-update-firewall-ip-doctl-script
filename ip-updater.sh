#!/bin/bash
set -euo pipefail

# IP Updater Script for Digital Ocean
# Monitors external IP changes and updates firewall rules using doctl
# Preserves existing rules, droplet assignments, and only updates the dynamic IP

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${IP_UPDATER_CONFIG:-$SCRIPT_DIR/config}"
IP_FILE="${IP_UPDATER_LOG:-$SCRIPT_DIR/current-ip.log}"
ERROR_LOG="${IP_UPDATER_ERROR_LOG:-$SCRIPT_DIR/ip-updater-error.log}"

# Check for config file
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    echo "Copy config.example to config and add your firewall settings."
    exit 1
fi

# Source the config file
source "$CONFIG_FILE"

# Validate config
if [[ -z "${FIREWALLS:-}" ]]; then
    echo "Error: FIREWALLS not defined in config file"
    exit 1
fi

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >> "$ERROR_LOG"
}

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

get_external_ip() {
    local ip=""

    # Try multiple services with fallback
    ip=$(curl -s --max-time 10 https://icanhazip.com 2>/dev/null) ||
    ip=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null) ||
    ip=$(curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null) || true

    # Clean up whitespace
    echo "$ip" | tr -d '[:space:]'
}

validate_ip() {
    local ip=$1
    [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

get_stored_ip() {
    if [[ -f "$IP_FILE" ]]; then
        tail -1 "$IP_FILE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || echo ""
    else
        echo ""
    fi
}

get_firewall_rules() {
    local fw_id=$1
    local rule_type=$2  # "inbound" or "outbound"

    local output
    output=$(doctl compute firewall get "$fw_id" --format InboundRules,OutboundRules --no-header 2>/dev/null) || return 1

    if [[ "$rule_type" == "inbound" ]]; then
        # First column (inbound rules) - everything before the large whitespace gap
        echo "$output" | awk '{
            # Find where outbound rules start (after multiple spaces)
            match($0, /protocol:icmp|protocol:tcp,ports:0|protocol:udp,ports:0/)
            if (RSTART > 0) {
                print substr($0, 1, RSTART-1)
            } else {
                print $0
            }
        }' | sed 's/[[:space:]]*$//'
    else
        # Second column (outbound rules)
        echo "$output" | grep -oE 'protocol:icmp,address:[^ ]+ protocol:tcp,ports:0[^ ]+ protocol:udp,ports:0[^ ]+' || \
        echo "protocol:icmp,address:0.0.0.0/0,address:::/0 protocol:tcp,ports:0,address:0.0.0.0/0,address:::/0 protocol:udp,ports:0,address:0.0.0.0/0,address:::/0"
    fi
}

get_firewall_droplets() {
    local fw_id=$1
    doctl compute firewall get "$fw_id" --format DropletIDs --no-header 2>/dev/null | tr -d '[:space:]'
}

get_firewall_name() {
    local fw_id=$1
    doctl compute firewall get "$fw_id" --format Name --no-header 2>/dev/null | tr -d '[:space:]'
}

# Replace old IP with new IP in specified port rules
# Modes:
#   swap       - Only replaces the old stored IP with new IP, keeps any other IPs
#   replace_all - Replaces ALL IPs on target ports with just the new IP
swap_ip_in_rules() {
    local rules=$1
    local old_ip=$2
    local new_ip=$3
    local target_ports=$4
    local mode=${5:-"swap"}

    local result=""
    local IFS=' '

    for rule in $rules; do
        # Check if this rule is for one of our target ports
        local is_target_port=false
        for port in ${target_ports//,/ }; do
            if [[ "$rule" == *"ports:$port,"* ]] || [[ "$rule" == *"ports:$port" ]]; then
                is_target_port=true
                break
            fi
        done

        if [[ "$is_target_port" == true ]]; then
            if [[ "$mode" == "replace_all" ]]; then
                # Replace all addresses with just the new IP
                local proto_port
                proto_port=$(echo "$rule" | grep -oE 'protocol:[^,]+,ports:[0-9]+')
                rule="${proto_port},address:${new_ip}/32"
            else
                # Swap mode: only replace the old IP, keep others
                if [[ -n "$old_ip" ]] && [[ "$rule" == *"$old_ip"* ]]; then
                    rule=$(echo "$rule" | sed "s|address:${old_ip}/32|address:${new_ip}/32|g")
                    rule=$(echo "$rule" | sed "s|address:${old_ip},|address:${new_ip}/32,|g")
                    rule=$(echo "$rule" | sed "s|address:${old_ip}$|address:${new_ip}/32|g")
                elif [[ "$rule" != *"address:${new_ip}"* ]]; then
                    # Old IP not found, add new IP if not already present
                    rule="${rule},address:${new_ip}/32"
                fi
            fi
        fi

        if [[ -n "$result" ]]; then
            result="$result $rule"
        else
            result="$rule"
        fi
    done

    echo "$result"
}

update_firewall() {
    local fw_id=$1
    local fw_name=$2
    local inbound_rules=$3
    local outbound_rules=$4
    local droplet_ids=$5
    local error_output
    local cmd_args=()

    cmd_args+=(--name "$fw_name")
    cmd_args+=(--inbound-rules "$inbound_rules")
    cmd_args+=(--outbound-rules "$outbound_rules")

    # Preserve droplet IDs if any exist
    if [[ -n "$droplet_ids" ]]; then
        cmd_args+=(--droplet-ids "$droplet_ids")
    fi

    if error_output=$(doctl compute firewall update "$fw_id" "${cmd_args[@]}" 2>&1); then
        log_info "Updated firewall: $fw_name"
        return 0
    else
        log_error "Failed to update firewall: $fw_name ($fw_id) - $error_output"
        return 1
    fi
}

update_firewall_smart() {
    local fw_id=$1
    local old_ip=$2
    local new_ip=$3
    local target_ports=$4
    local mode=$5  # "swap" or "replace_all"

    # Get firewall name from DO
    local fw_name
    fw_name=$(get_firewall_name "$fw_id")
    if [[ -z "$fw_name" ]]; then
        log_error "Failed to fetch firewall name for ID: $fw_id"
        return 1
    fi

    # Get current rules and droplet IDs
    local inbound_rules outbound_rules droplet_ids
    inbound_rules=$(get_firewall_rules "$fw_id" "inbound")
    outbound_rules=$(get_firewall_rules "$fw_id" "outbound")
    droplet_ids=$(get_firewall_droplets "$fw_id")

    if [[ -z "$inbound_rules" ]]; then
        log_error "Failed to fetch current rules for $fw_name"
        return 1
    fi

    # Modify the rules
    local new_inbound_rules
    new_inbound_rules=$(swap_ip_in_rules "$inbound_rules" "$old_ip" "$new_ip" "$target_ports" "$mode")

    # Update the firewall
    update_firewall "$fw_id" "$fw_name" "$new_inbound_rules" "$outbound_rules" "$droplet_ids"
}

main() {
    local new_ip
    local stored_ip
    local update_failed=0

    # Get external IP
    new_ip=$(get_external_ip)

    if [[ -z "$new_ip" ]]; then
        log_error "Failed to fetch external IP from all services"
        exit 1
    fi

    if ! validate_ip "$new_ip"; then
        log_error "Invalid IP address received: $new_ip"
        exit 1
    fi

    # Get stored IP
    stored_ip=$(get_stored_ip)

    # Compare IPs
    if [[ "$new_ip" == "$stored_ip" ]]; then
        # IP hasn't changed, exit silently
        exit 0
    fi

    log_info "IP changed: ${stored_ip:-'(none)'} -> $new_ip"

    # Process each firewall from config
    # Format: "firewall_id:mode:ports"
    for fw_config in $FIREWALLS; do
        IFS=':' read -r fw_id mode ports <<< "$fw_config"

        if [[ -z "$fw_id" ]] || [[ -z "$mode" ]] || [[ -z "$ports" ]]; then
            log_error "Invalid firewall config: $fw_config (expected format: firewall_id:mode:ports)"
            update_failed=1
            continue
        fi

        if ! update_firewall_smart "$fw_id" "$stored_ip" "$new_ip" "$ports" "$mode"; then
            update_failed=1
        fi
    done

    # Save new IP to log file
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] IP: $new_ip" >> "$IP_FILE"

    if [[ $update_failed -eq 1 ]]; then
        log_error "One or more firewall updates failed"
        exit 1
    fi

    log_info "All firewalls updated successfully"
}

main "$@"
