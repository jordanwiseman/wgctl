#!/bin/bash
# test_wgctl.sh — unit test suite for wgctl.sh
#
# REQUIREMENTS
#   No root required. wgctl.sh's root check is stripped by the awk extraction
#   (see HOW IT WORKS), all privileged paths are redirected to temp dirs, and
#   all privileged tools are mocked, so nothing in the suite needs elevation.
#   Runtime dependencies: bash, jq, awk, grep. Real WireGuard tools are NOT
#   required — wg, wg-quick, and openssl are replaced by mock binaries.
#
# HOW IT WORKS
#   1. A temporary directory tree is created under $(mktemp -d) with
#      subdirectories standing in for /etc/wireguard (CONFIG_PATH) and
#      /var/lib/wgctl (DB_PATH).
#   2. Mock binaries for wg, wg-quick, and openssl are written to a bin/
#      subdirectory and prepended to PATH so no real WireGuard interaction
#      occurs. Key behaviour of the mocks:
#        wg genkey   — returns a fixed private-key string
#        wg pubkey   — returns a fixed public-key string (input ignored)
#        wg show interfaces — returns $WG_MOCK_INTERFACES (default empty),
#                             allowing individual tests to simulate a live
#                             interface by setting that variable inline
#        wg syncconf — returns $WG_MOCK_SYNCCONF_RC (default 0)
#        wg-quick    — returns $WGQUICK_MOCK_RC (default 0)
#        openssl rand --base64 — returns a fixed PSK string
#   3. The guard code at the top of wgctl.sh (root check, path existence
#      checks, tool availability loop) and the trailing `main "$@"` call are
#      stripped with awk, and the remaining function definitions are sourced
#      directly into the test shell. CONFIG_PATH and DB_PATH are then
#      overridden to point at the temporary directories.
#   4. Each test calls a function directly, captures its return code and/or
#      stdout, and asserts the result with assert_eq / assert_return /
#      assert_contains / assert_not_contains helpers.
#   5. On exit, mock binaries and the extracted functions file are removed;
#      the JSON DB files and .conf files are intentionally kept so they can
#      be inspected after a run. Their paths are printed in the summary.
#
# COVERAGE
#   ip_to_int / int_to_ip   — normal values, boundary values (0.0.0.0 and
#                              255.255.255.255), integer roundtrip
#   create_interface        — success, duplicate detection, invalid name/IP,
#                              missing required params, unknown option, hooks
#                              (pre-up/post-down), port boundary validation
#                              (0 and 65536 rejected, 65535 accepted), custom
#                              private key, custom DNS
#   show_interface          — INI and JSON output formats, field presence,
#                              hooks in INI, peers section after peers are
#                              added, PresharedKey rendered for PSK peers,
#                              error on nonexistent interface and unknown flag
#   list_interfaces         — plain and JSON formats, (up)/(down) status
#                              labels using WG_MOCK_INTERFACES, JSON status
#                              field, multiple interfaces, unknown format
#                              value, empty DB error
#   add_peer                — auto IP assignment, sequential IP allocation,
#                              explicit IP, generated PSK, explicit PSK,
#                              PSK stored under correct key, duplicate
#                              detection, missing value errors for keyed
#                              options, invalid PSK formats (too short, too
#                              long, bad character), auto-IP skips manually
#                              assigned addresses, subnet exhaustion
#   show_interface          — peers section, AllowedIPs, Status, PresharedKey
#   (with peers)
#   enable_peer /           — status toggled correctly in JSON, nonexistent
#   disable_peer              peer and interface error codes
#   remove_peer             — peer deleted from JSON, idempotent error on
#                              second removal, invalid peer name rejected
#   export_peer             — full client config structure, [Peer] block uses
#                              server public key (not peer key), Endpoint
#                              formatted as host:port, no PresharedKey line
#                              for peers without PSK, PresharedKey present
#                              for PSK peers, nonexistent peer error
#   apply_interface         — .conf file created; Interface field values
#                              (PrivateKey, ListenPort, Address) cross-checked
#                              against JSON; enabled peers included and their
#                              PublicKey/AllowedIPs values verified against
#                              JSON; disabled peers excluded and [Peer] block
#                              count asserted to drop by one; PresharedKey
#                              value cross-checked against JSON usePSK field;
#                              hook values (PreUp, PostDown) cross-checked
#                              against JSON; syncconf path exercised when
#                              interface is live; error codes for nonexistent
#                              interface and empty name

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WGCTL="${SCRIPT_DIR}/wgctl.sh"

PASS=0
FAIL=0

# ── helpers ──────────────────────────────────────────────────────────────────

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then pass "$desc"; else
        fail "$desc (expected='$expected' got='$actual')"; fi
}

assert_return() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then pass "$desc"; else
        fail "$desc (expected rc=$expected got rc=$actual)"; fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then pass "$desc"; else
        fail "$desc (expected to contain '$needle' in output)"; fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        fail "$desc (expected NOT to contain '$needle' in output)"; else
        pass "$desc"; fi
}

# ── environment setup ─────────────────────────────────────────────────────────


TEST_DIR=$(mktemp -d)
CONFIG_PATH="$TEST_DIR/etc/wireguard"
DB_PATH="$TEST_DIR/var/lib/wgctl"
MOCK_BIN="$TEST_DIR/bin"
mkdir -p "$CONFIG_PATH" "$DB_PATH" "$MOCK_BIN"

cleanup() { rm -rf "$TEST_DIR/bin" "$TEST_DIR/wgctl_funcs.sh"; }
trap cleanup EXIT

# ── mock binaries ─────────────────────────────────────────────────────────────

cat > "$MOCK_BIN/wg" <<'EOF'
#!/bin/bash
case "$1" in
    genkey)   echo "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey)   echo "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" ;;
    show)
        case "$2" in
            interfaces) echo "${WG_MOCK_INTERFACES:-}" ;;
            *) exit 0 ;;
        esac ;;
    syncconf) exit "${WG_MOCK_SYNCCONF_RC:-0}" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$MOCK_BIN/wg"

cat > "$MOCK_BIN/wg-quick" <<'EOF'
#!/bin/bash
exit "${WGQUICK_MOCK_RC:-0}"
EOF
chmod +x "$MOCK_BIN/wg-quick"

cat > "$MOCK_BIN/openssl" <<'EOF'
#!/bin/bash
if [[ "$1" == "rand" && "$2" == "--base64" ]]; then
    echo "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
fi
EOF
chmod +x "$MOCK_BIN/openssl"

export PATH="$MOCK_BIN:$PATH"

# ── source functions from wgctl.sh ────────────────────────────────────────────
# Strip the top-level guards (root check, path checks, tool check) and the
# trailing `main "$@"` + `exit 0` so we can source the functions directly.

FUNCS_FILE="$TEST_DIR/wgctl_funcs.sh"
awk '
    /if \[ "\$EUID" -ne 0 \]/ { skip="fi"; next }
    /\[ ! -d "\$CONFIG_PATH" \]/ { next }
    /\[ ! -d "\$DB_PATH" \]/ { next }
    /for cmd in "wg"/ { skip="done"; next }
    /^main "\$@"$/ { next }
    /^exit 0$/ { next }
    skip != "" && $0 ~ ("^" skip "$") { skip=""; next }
    skip != "" { next }
    { print }
' "$WGCTL" > "$FUNCS_FILE"

# Override path variables before sourcing
CONFIG_PATH="$CONFIG_PATH" DB_PATH="$DB_PATH" source "$FUNCS_FILE"

# Point the functions at our test directories
CONFIG_PATH="$TEST_DIR/etc/wireguard"
DB_PATH="$TEST_DIR/var/lib/wgctl"
SCRIPT_NAME="wgctl.sh"

# helper to (re)create the standard test interfaces
_create_wg0()    { create_interface "wg0"     address "10.0.0.1/24" listen-port "51820" endpoint "vpn.example.com" > /dev/null; }
_create_wg_opts(){ create_interface "wg_opts" address "10.0.1.1/24" listen-port "51821" endpoint "vpn2.example.com" \
                       pre-up "iptables -A FORWARD" post-down "iptables -D FORWARD" > /dev/null; }

# ── ip_to_int / int_to_ip ─────────────────────────────────────────────────────

echo ""
echo "=== ip_to_int / int_to_ip ==="

result=$(ip_to_int "10.0.0.1")
assert_eq "ip_to_int 10.0.0.1" "167772161" "$result"

result=$(int_to_ip 167772161)
assert_eq "int_to_ip 167772161" "10.0.0.1" "$result"

result=$(ip_to_int "192.168.1.100")
back=$(int_to_ip "$result")
assert_eq "roundtrip 192.168.1.100" "192.168.1.100" "$back"

result=$(ip_to_int "0.0.0.0")
assert_eq "ip_to_int 0.0.0.0" "0" "$result"

result=$(ip_to_int "255.255.255.255")
assert_eq "ip_to_int 255.255.255.255" "4294967295" "$result"

result=$(int_to_ip 0)
assert_eq "int_to_ip 0" "0.0.0.0" "$result"

result=$(int_to_ip 4294967295)
assert_eq "int_to_ip 4294967295" "255.255.255.255" "$result"

# ── create_interface ──────────────────────────────────────────────────────────

echo ""
echo "=== create_interface ==="

_create_wg0
assert_return "creates interface file" "0" "$?"
[[ -f "$DB_PATH/wg0.json" ]] && pass "JSON file exists" || fail "JSON file missing"

iface_json=$(cat "$DB_PATH/wg0.json")
assert_contains "stores address"     "10.0.0.1/24"      "$iface_json"
assert_contains "stores listen port" "51820"             "$iface_json"
assert_contains "stores endpoint"    "vpn.example.com"   "$iface_json"
assert_contains "stores public key"  "BBBBBBBBBBBBBBBBB" "$iface_json"

create_interface "wg0" address "10.0.0.1/24" listen-port "51820" endpoint "vpn.example.com"
assert_return "duplicate interface returns ERR_INTERFACE_EXISTS" "12" "$?"

create_interface "" address "10.0.0.1/24" listen-port "51820" endpoint "vpn.example.com"
assert_return "empty name returns ERR_MISSING_PARAMS" "13" "$?"

create_interface "bad name!" address "10.0.0.1/24" listen-port "51820" endpoint "vpn.example.com"
assert_return "invalid name returns ERR_INVALID_INTERFACE_NAME" "10" "$?"

create_interface "wg_new" address "not-an-ip" listen-port "51820" endpoint "vpn.example.com"
assert_return "invalid IP returns ERR_INVALID_IP_FORMAT" "14" "$?"

create_interface "wg_miss" address "10.0.0.1/24" listen-port "51820"
assert_return "missing endpoint returns ERR_MISSING_PARAMS" "13" "$?"

create_interface "wg_unk" address "10.0.4.1/24" listen-port "51826" endpoint "vpn.example.com" unknown-option
assert_return "unknown option returns ERR_UNKNOWN_PARAM" "11" "$?"

_create_wg_opts
assert_return "creates interface with hooks" "0" "$?"
opts_json=$(cat "$DB_PATH/wg_opts.json")
assert_contains "stores preUp"    "iptables -A FORWARD" "$opts_json"
assert_contains "stores postDown" "iptables -D FORWARD" "$opts_json"

# port boundary validation
# BUG: `return #ERR_INVALID_PORT` comments out the error code, so these return 0 instead of 19
create_interface "wg_p0" address "10.0.2.1/24" listen-port "0" endpoint "vpn.example.com"
assert_return "port 0 returns ERR_INVALID_PORT" "19" "$?"

create_interface "wg_phi" address "10.0.2.1/24" listen-port "65536" endpoint "vpn.example.com"
assert_return "port 65536 returns ERR_INVALID_PORT" "19" "$?"

create_interface "wg_pmax" address "10.0.2.1/24" listen-port "65535" endpoint "vpn.example.com"
assert_return "port 65535 is valid" "0" "$?"

# custom private key and DNS
CUSTOM_PRIVKEY="EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE="
create_interface "wg_custom" address "10.0.3.1/24" listen-port "51823" endpoint "custom.example.com" \
    private-key "$CUSTOM_PRIVKEY" dns "8.8.8.8, 8.8.4.4"
assert_return "custom private key and DNS accepted" "0" "$?"
custom_json=$(cat "$DB_PATH/wg_custom.json")
assert_contains "stores custom private key" "$CUSTOM_PRIVKEY"    "$custom_json"
assert_contains "stores custom DNS"         "8.8.8.8, 8.8.4.4"  "$custom_json"

# ── show_interface ────────────────────────────────────────────────────────────

echo ""
echo "=== show_interface ==="

ini_out=$(show_interface "wg0")
assert_return "show_interface succeeds" "0" "$?"
assert_contains "ini has [Interface]"    "[Interface]"        "$ini_out"
assert_contains "ini has PrivateKey"     "PrivateKey"         "$ini_out"
assert_contains "ini has ListenPort"     "ListenPort = 51820" "$ini_out"
assert_contains "ini has Address"        "Address = 10.0.0.1/24" "$ini_out"

json_out=$(show_interface "wg0" format json)
assert_return "show_interface json format" "0" "$?"
assert_contains "json has address key"    '"address"'    "$json_out"
assert_contains "json has listenPort key" '"listenPort"' "$json_out"

show_interface "nonexistent"
assert_return "nonexistent returns ERR_NO_INTERFACE_FOUND" "8" "$?"

show_interface "wg0" unknown-flag
assert_return "unknown flag returns ERR_UNKNOWN_PARAM" "11" "$?"

# hooks appear in INI output
hooks_out=$(show_interface "wg_opts")
assert_contains "PreUp in INI"    "PreUp = iptables -A FORWARD"    "$hooks_out"
assert_contains "PostDown in INI" "PostDown = iptables -D FORWARD" "$hooks_out"

# ── list_interfaces ───────────────────────────────────────────────────────────

echo ""
echo "=== list_interfaces ==="

plain_out=$(list_interfaces interfaces)
assert_return "list_interfaces succeeds" "0" "$?"
assert_contains "plain output has wg0"       "wg0"      "$plain_out"
assert_contains "plain output marks status"  "(down)"   "$plain_out"

json_out=$(list_interfaces interfaces format json)
assert_return "list_interfaces json" "0" "$?"
assert_contains "json has interfaces key" '"interfaces"' "$json_out"
assert_contains "json has wg0 key"        '"wg0"'        "$json_out"

# multiple interfaces (wg0 + wg_opts both exist)
assert_contains "multiple interfaces: wg0 listed"     "wg0"     "$plain_out"
assert_contains "multiple interfaces: wg_opts listed" "wg_opts" "$plain_out"

# interface marked (up) when mock returns it as active
up_plain=$(WG_MOCK_INTERFACES="wg0" list_interfaces interfaces)
assert_contains "active interface shown as (up)"   "wg0(up)"       "$up_plain"
assert_contains "inactive interface stays (down)"  "wg_opts(down)" "$up_plain"

# JSON status reflects live state
up_json=$(WG_MOCK_INTERFACES="wg0" list_interfaces interfaces format json)
up_status=$(echo "$up_json" | jq -r '.interfaces.wg0.status')
assert_eq "json status is 'up' for live interface" "up" "$up_status"
down_status=$(echo "$up_json" | jq -r '.interfaces.wg_opts.status')
assert_eq "json status is 'down' for inactive interface" "down" "$down_status"

# unknown format value — falls through if/elif silently (returns 0, empty output)
unk_out=$(list_interfaces interfaces format xml)
assert_return "unknown format value returns 0" "0" "$?"
assert_eq "unknown format produces no output" "" "$unk_out"

# empty DB
rm -f "$DB_PATH"/*.json
list_interfaces interfaces
assert_return "empty DB returns ERR_NO_INTERFACE_FOUND" "8" "$?"
# Restore interfaces deleted above
_create_wg0
_create_wg_opts

# ── add_peer ──────────────────────────────────────────────────────────────────

echo ""
echo "=== add_peer ==="

add_peer "alice" for "wg0"
assert_return "add peer auto-IP" "0" "$?"
peer_json=$(cat "$DB_PATH/wg0.json")
assert_contains "peer alice exists"     '"alice"'       "$peer_json"
assert_contains "peer has publicKey"    "BBBBBBBBBBBBB" "$peer_json"
assert_contains "peer has allowedIPs"   "allowedIPs"    "$peer_json"
assert_contains "peer auto-IP is /32"   "/32"           "$peer_json"
assert_contains "peer status is enable" '"enable"'      "$peer_json"

add_peer "bob" for "wg0"
assert_return "add second peer gets next IP" "0" "$?"
bob_ip=$(jq -r '.peers.bob.allowedIPs' "$DB_PATH/wg0.json")
assert_eq "bob gets 10.0.0.3/32" "10.0.0.3/32" "$bob_ip"

add_peer "alice" for "wg0"
assert_return "duplicate peer returns ERR_PEER_ALREADY_EXISTS" "25" "$?"

add_peer "charlie" for "nonexistent"
assert_return "unknown interface returns ERR_NO_INTERFACE_FOUND" "8" "$?"

add_peer "dave" for "wg0" allowed-ips "10.0.0.50/32"
assert_return "add peer with explicit IP" "0" "$?"
dave_ip=$(jq -r '.peers.dave.allowedIPs' "$DB_PATH/wg0.json")
assert_eq "dave gets explicit IP" "10.0.0.50/32" "$dave_ip"

add_peer "eve" for "wg0" use-psk
assert_return "add peer with generated PSK" "0" "$?"
eve_keys=$(jq -r '.peers.eve | keys[]' "$DB_PATH/wg0.json")
assert_contains "PSK key present" "usePSK" "$eve_keys"

VALID_PSK="DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD="
add_peer "frank" for "wg0" use-psk "$VALID_PSK"
assert_return "add peer with explicit PSK" "0" "$?"
frank_psk=$(jq -r '.peers.frank.usePSK' "$DB_PATH/wg0.json")
assert_eq "frank PSK stored correctly" "$VALID_PSK" "$frank_psk"

add_peer "bad peer!" for "wg0"
assert_return "invalid peer name returns ERR_INVALID_PEER_NAME" "27" "$?"

add_peer "" for "wg0"
assert_return "empty peer name returns ERR_MISSING_PARAMS" "13" "$?"

add_peer "grace" for "wg0" unknown-flag
assert_return "unknown flag returns ERR_UNKNOWN_PARAM" "11" "$?"

# missing value for keyed options
add_peer "henry" for "wg0" private-key
assert_return "private-key with no value returns ERR_MISSING_VALUE" "28" "$?"

add_peer "henry" for "wg0" allowed-ips
assert_return "allowed-ips with no value returns ERR_MISSING_VALUE" "28" "$?"

# invalid PSK formats
add_peer "henry" for "wg0" use-psk "tooshort="
assert_return "too-short PSK returns ERR_INVALID_PSK" "29" "$?"

add_peer "henry" for "wg0" use-psk "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD="  # 47 chars
assert_return "too-long PSK returns ERR_INVALID_PSK" "29" "$?"

add_peer "henry" for "wg0" use-psk "!AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="  # invalid char
assert_return "PSK with invalid char returns ERR_INVALID_PSK" "29" "$?"

# auto-IP skips over manually assigned addresses
create_interface "wg_skip" address "10.6.0.1/24" listen-port "51825" endpoint "vpn.example.com" > /dev/null
add_peer "skip_manual" for "wg_skip" allowed-ips "10.6.0.2/32" > /dev/null  # occupy .2 explicitly
add_peer "skip_auto"   for "wg_skip" > /dev/null                             # auto should skip .2
skip_ip=$(jq -r '.peers.skip_auto.allowedIPs' "$DB_PATH/wg_skip.json")
assert_eq "auto-IP skips manually assigned .2, gets .3" "10.6.0.3/32" "$skip_ip"

# subnet exhaustion — /30 has only one host slot after the interface IP
create_interface "wg_small" address "10.5.0.1/30" listen-port "51824" endpoint "vpn.example.com" > /dev/null
add_peer "small_p1" for "wg_small" > /dev/null    # gets 10.5.0.2/32 (only available slot)
add_peer "small_p2" for "wg_small"                # should fail — subnet exhausted
assert_return "subnet exhaustion returns ERR_NO_AVAILABLE_IP" "20" "$?"

# ── show_interface (with peers) ───────────────────────────────────────────────

echo ""
echo "=== show_interface (with peers) ==="

peers_ini=$(show_interface "wg0")
assert_contains "peers section present"       "[Peer]"     "$peers_ini"
assert_contains "peer Name field shown"        "Name ="     "$peers_ini"
assert_contains "peer AllowedIPs field shown"  "AllowedIPs" "$peers_ini"
assert_contains "peer Status field shown"      "Status ="   "$peers_ini"
assert_contains "PSK peer shows PresharedKey"  "PresharedKey" "$peers_ini"

# ── enable_peer / disable_peer ────────────────────────────────────────────────

echo ""
echo "=== enable_peer / disable_peer ==="

disable_peer "alice" for "wg0"
assert_return "disable_peer succeeds" "0" "$?"
status=$(jq -r '.peers.alice.status' "$DB_PATH/wg0.json")
assert_eq "alice status is disable" "disable" "$status"

enable_peer "alice" for "wg0"
assert_return "enable_peer succeeds" "0" "$?"
status=$(jq -r '.peers.alice.status' "$DB_PATH/wg0.json")
assert_eq "alice status is enable" "enable" "$status"

disable_peer "noone" for "wg0"
assert_return "disable nonexistent peer returns ERR_PEER_NOT_FOUND" "26" "$?"

enable_peer "alice" for "nonexistent"
assert_return "enable on missing interface returns ERR_NO_INTERFACE_FOUND" "8" "$?"

# ── remove_peer ───────────────────────────────────────────────────────────────

echo ""
echo "=== remove_peer ==="

remove_peer "bob" from "wg0"
assert_return "remove_peer succeeds" "0" "$?"
jq -e '.peers | has("bob")' "$DB_PATH/wg0.json" > /dev/null 2>&1
assert_return "bob is gone" "1" "$?"

remove_peer "bob" from "wg0"
assert_return "remove nonexistent peer returns ERR_PEER_NOT_FOUND" "26" "$?"

remove_peer "bad peer!" from "wg0"
assert_return "invalid peer name returns ERR_INVALID_PEER_NAME" "27" "$?"

# ── export_peer ───────────────────────────────────────────────────────────────

echo ""
echo "=== export_peer ==="

export_out=$(export_peer "alice" for "wg0")
assert_return "export_peer succeeds" "0" "$?"
assert_contains "export has [Interface]" "[Interface]" "$export_out"
assert_contains "export has [Peer]"      "[Peer]"      "$export_out"
assert_contains "export has PrivateKey"  "PrivateKey"  "$export_out"
assert_contains "export has Endpoint"    "Endpoint"    "$export_out"
assert_contains "export has AllowedIPs"  "AllowedIPs"  "$export_out"

# [Peer] block must use the server's public key, not the peer's own
iface_pubkey=$(jq -r '.interface.publicKey' "$DB_PATH/wg0.json")
peer_section=$(echo "$export_out" | awk '/\[Peer\]/{f=1} f{print}')
assert_contains "export [Peer] uses interface public key" "PublicKey = $iface_pubkey" "$peer_section"

# Endpoint must be host:port
assert_contains "export Endpoint is host:port" "Endpoint = vpn.example.com:51820" "$export_out"

# BUG: jq -r outputs literal "null" for absent keys, so [ -n "null" ] is true —
# non-PSK peers incorrectly get PresharedKey = null in the export
assert_not_contains "non-PSK peer export has no PresharedKey" "PresharedKey" "$export_out"

export_psk_out=$(export_peer "frank" for "wg0")
assert_contains "PSK peer export includes PresharedKey" "PresharedKey" "$export_psk_out"

export_peer "noone" for "wg0"
assert_return "export nonexistent peer returns ERR_PEER_NOT_FOUND" "26" "$?"

# ── apply_interface ───────────────────────────────────────────────────────────

echo ""
echo "=== apply_interface ==="

apply_interface "wg0"
assert_return "apply_interface succeeds" "0" "$?"
[[ -f "$CONFIG_PATH/wg0.conf" ]] && pass "wg0.conf created" || fail "wg0.conf missing"

conf=$(cat "$CONFIG_PATH/wg0.conf")
assert_contains "conf has [Interface]" "[Interface]" "$conf"
assert_contains "conf has PrivateKey"  "PrivateKey"  "$conf"
assert_contains "conf has ListenPort"  "ListenPort"  "$conf"
assert_contains "conf has Address"     "Address"     "$conf"

# interface field values match JSON
json_privkey=$(jq -r '.interface.privateKey' "$DB_PATH/wg0.json")
conf_privkey=$(awk -F' = ' '/^PrivateKey/{print $2; exit}' "$CONFIG_PATH/wg0.conf")
assert_eq "conf PrivateKey value matches JSON" "$json_privkey" "$conf_privkey"

json_port=$(jq -r '.interface.listenPort' "$DB_PATH/wg0.json")
conf_port=$(awk -F' = ' '/^ListenPort/{print $2; exit}' "$CONFIG_PATH/wg0.conf")
assert_eq "conf ListenPort value matches JSON" "$json_port" "$conf_port"

json_addr=$(jq -r '.interface.address' "$DB_PATH/wg0.json")
conf_addr=$(awk -F' = ' '/^Address/{print $2; exit}' "$CONFIG_PATH/wg0.conf")
assert_eq "conf Address value matches JSON" "$json_addr" "$conf_addr"

# exact peer block count: alice, dave, eve, frank = 4 enabled peers
peer_count=$(grep -c '^\[Peer\]' "$CONFIG_PATH/wg0.conf")
assert_eq "conf has 4 [Peer] blocks (all enabled)" "4" "$peer_count"

# peer field values match JSON (using alice's block as representative)
alice_pubkey=$(jq -r '.peers.alice.publicKey' "$DB_PATH/wg0.json")
alice_allowedips=$(jq -r '.peers.alice.allowedIPs' "$DB_PATH/wg0.json")
conf_first_pubkey=$(awk '/^\[Peer\]/{f=1} f && /^PublicKey/{print $3; exit}' "$CONFIG_PATH/wg0.conf")
assert_eq "conf peer PublicKey value matches JSON" "$alice_pubkey" "$conf_first_pubkey"
assert_contains "conf peer AllowedIPs value matches JSON" "AllowedIPs = $alice_allowedips" "$conf"

# disabled peer excluded from conf; peer block count drops by one
alice_ip=$(jq -r '.peers.alice.allowedIPs' "$DB_PATH/wg0.json")
disable_peer "alice" for "wg0" > /dev/null
apply_interface "wg0"
conf_no_alice=$(cat "$CONFIG_PATH/wg0.conf")
assert_not_contains "disabled peer excluded from conf" "$alice_ip" "$conf_no_alice"
peer_count=$(grep -c '^\[Peer\]' "$CONFIG_PATH/wg0.conf")
assert_eq "conf has 3 [Peer] blocks after disabling alice" "3" "$peer_count"
enable_peer "alice" for "wg0" > /dev/null   # restore

# PSK peer writes PresharedKey in conf; value matches JSON
apply_interface "wg0"
conf_psk=$(cat "$CONFIG_PATH/wg0.conf")
assert_contains "PSK peer PresharedKey written to conf" "PresharedKey" "$conf_psk"
frank_psk=$(jq -r '.peers.frank.usePSK' "$DB_PATH/wg0.json")
assert_contains "conf PresharedKey value matches JSON usePSK" "PresharedKey = $frank_psk" "$conf_psk"

# hooks written to conf; values match JSON
apply_interface "wg_opts"
conf_hooks=$(cat "$CONFIG_PATH/wg_opts.conf")
assert_contains "PreUp in conf"    "PreUp = iptables -A FORWARD"    "$conf_hooks"
assert_contains "PostDown in conf" "PostDown = iptables -D FORWARD" "$conf_hooks"
json_preup=$(jq -r '.interface.preUp' "$DB_PATH/wg_opts.json")
conf_preup=$(awk '/^PreUp/{sub(/^PreUp = /, ""); print; exit}' "$CONFIG_PATH/wg_opts.conf")
assert_eq "conf PreUp value matches JSON" "$json_preup" "$conf_preup"
json_postdown=$(jq -r '.interface.postDown' "$DB_PATH/wg_opts.json")
conf_postdown=$(awk '/^PostDown/{sub(/^PostDown = /, ""); print; exit}' "$CONFIG_PATH/wg_opts.conf")
assert_eq "conf PostDown value matches JSON" "$json_postdown" "$conf_postdown"

# syncconf called when interface is live (exercises the interface_is_up branch)
WG_MOCK_INTERFACES="wg0" apply_interface "wg0"
assert_return "apply on live interface (syncconf path) succeeds" "0" "$?"

apply_interface "nonexistent"
assert_return "apply nonexistent returns ERR_NO_INTERFACE_FOUND" "8" "$?"

apply_interface ""
assert_return "apply empty name returns ERR_MISSING_PARAMS" "13" "$?"

# ── summary ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "  Artefacts:"
echo "    conf files : $CONFIG_PATH"
echo "    json files : $DB_PATH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "$FAIL" -eq 0 ]]
