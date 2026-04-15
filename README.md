# wgctl - WireGuard Control CLI

A comprehensive command-line interface for managing WireGuard VPN interfaces and peers. This tool simplifies the creation, configuration, and management of WireGuard setups through an intuitive CLI.

## Features

- **Interface Management**: Create, display, apply, start, stop, and delete WireGuard interfaces
- **Peer Management**: Add, remove, enable, disable, and export peer configurations
- **JSON-based Configuration**: Store and manage configuration in structured JSON format
- **Command Validation**: Robust error handling and parameter validation
- **Output Formatting**: Support for both INI and JSON output formats

## Requirements

- Root privileges
- WireGuard (`wg` and `wg-quick` commands)
- `jq` for JSON processing
- `find` command


## Installation

To install **wgctl**, run the following command with root privileges:

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/snaeim/wgctl/refs/heads/main/installer.sh)"
```
This installer will:
1. Download the wgctl.sh script to /usr/local/bin/wgctl
2. Set executable permissions for the script
3. Create the database directory at /var/lib/wgctl with the proper permissions

## Usage

Once installed, run **wgctl** using:

```bash
wgctl <command> [options]
```

For help, run:

```bash
wgctl help
```

### Available Commands

#### Interface Operations

- **create**  
  Create a new WireGuard interface.

  **Usage:**  
  ```bash
  wgctl create <interface> [options]
  ```

  **Options:**
  - `address <address>` – Interface address in CIDR notation.
  - `listen-port <port>` – Listening port.
  - `pre-up <command>` / `post-up <command>` – Commands to run before/after interface activation.
  - `pre-down <command>` / `post-down <command>` – Commands to run before/after interface deactivation.
  - `private-key <key>` – Specify a private key (if omitted, one is auto-generated).
  - `dns <dns>` – DNS servers (default: `1.1.1.1, 1.0.0.1`).
  - `endpoint <endpoint>` – Remote endpoint.

- **show interfaces**  
  List all interfaces along with their status (up/down).

  **Usage:**  
  ```bash
  wgctl show interfaces [format <plain|json>]
  ```

- **show <interface>**  
  Display detailed configuration for a specific interface.

  **Usage:**  
  ```bash
  wgctl show <interface> [format <ini|json>]
  ```

- **apply**  
  Generate and apply the WireGuard configuration file for an interface.

  **Usage:**  
  ```bash
  wgctl apply <interface>
  ```

- **start**  
  Start a WireGuard interface.

  **Usage:**  
  ```bash
  wgctl start <interface>
  ```

- **stop**  
  Stop a WireGuard interface.

  **Usage:**  
  ```bash
  wgctl stop <interface>
  ```

- **delete**  
  Delete an interface and its configuration.

  **Usage:**  
  ```bash
  wgctl delete <interface>
  ```

#### Peer Operations

- **add**  
  Add a new peer to an interface.

  **Usage:**  
  ```bash
  wgctl add <peer> for <interface> [options]
  ```

  **Options:**
  - `private-key <key>` – Specify the peer’s private key.
  - `allowed-ips <ips>` – Specify allowed IPs (auto-calculated if omitted).
  - `use-psk [psk]` - Generate or use supplied PSK for added privacy.

- **remove**  
  Remove a peer from an interface.

  **Usage:**  
  ```bash
  wgctl remove <peer> for <interface>
  ```

- **enable**  
  Enable a peer.

  **Usage:**  
  ```bash
  wgctl enable <peer> for <interface>
  ```

- **disable**  
  Disable a peer.

  **Usage:**  
  ```bash
  wgctl disable <peer> for <interface>
  ```

- **export**  
  Export a peer configuration.  
  The configuration is printed in a format ready for client import.

  **Usage:**  
  ```bash
  wgctl export <peer> for <interface>
  ```

## Examples

- **Creating an Interface:**

  ```bash
  sudo wgctl create mywg \
      address 10.0.0.1/24 \
      listen-port 51820 \
      endpoint example.com \
      pre-up "echo 'Starting...'" \
      post-down "echo 'Stopped...'"
  ```

- **Adding a Peer:**

  ```bash
  sudo wgctl add peer1 for mywg allowed-ips 10.0.0.2/32
  ```

  ```bash
  sudo wgctl add peer2 for mywg allowed-ips 10.0.0.3/32 use-psk
  ```

- **Exporting a Peer Configuration:**

  ```bash
  sudo wgctl export peer1 for mywg
  ```

## Uninstall
To uninstall wgctl, run the following command:
```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/snaeim/wgctl/refs/heads/main/installer.sh)"
```
This command will:
1. Remove the main wgctl script
2. Prompt you to delete the database directory located at `/var/lib/wgctl`