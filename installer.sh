#!/bin/bash

# Constants
SCRIPT_NAME="wgctl"
SCRIPT_PATH="/usr/local/bin/$SCRIPT_NAME"
DB_PATH="/var/lib/$SCRIPT_NAME"
SCRIPT_URL="https://raw.githubusercontent.com/snaeim/$SCRIPT_NAME/refs/heads/main/$SCRIPT_NAME.sh"

# Function to check if the script is being run with sudo
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "This script must be run with sudo."
        exit 1
    fi
}

# Function to display a confirmation prompt
confirm() {
    local prompt="$1"
    while true; do
        read -p "$prompt (Y/n): " choice
        case "$choice" in
        [Yy] | "") return 0 ;; # Accept empty input as "yes"
        [Nn]) return 1 ;;
        *) echo "Invalid input. Please enter y, n, or press Enter for yes." ;;
        esac
    done
}

# Function to install the script and cron job
install_script() {
    # Download the script from the URL
    if ! curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"; then
        echo "Error: Failed to download the script."
        exit 1
    fi
    echo "$SCRIPT_NAME script downloaded to $SCRIPT_PATH."

    # Set the script as executable
    chmod +x "$SCRIPT_PATH"
    echo "Set execute permission for $SCRIPT_PATH."

    # Create necessary directories for the database
    if [ ! -d "$DB_PATH" ]; then
        mkdir -p "$DB_PATH"
        echo "Created database directory: $DB_PATH."
        # Set the required permissions on DB_PATH (drwxr-xr-x)
        chmod 755 "$DB_PATH"
        echo "Set permissions on $DB_PATH to drwxr-xr-x."
    else
        echo "Directory already exists: $DB_PATH."
    fi

    #source "$SCRIPT_PATH" >/dev/null && echo "$SCRIPT_NAME successfully installed!" || echo "Something went wrong!"
}

# Function to uninstall the script and cron job
uninstall_script() {
    # Remove script from /usr/local/bin
    if [ -f "$SCRIPT_PATH" ]; then
        rm "$SCRIPT_PATH"
        echo "Removed script from $SCRIPT_PATH."
    else
        echo "Script not found at $SCRIPT_PATH."
    fi

    # Ask if the user wants to keep the database path
    if confirm "Do you want to keep the database path ($DB_PATH)?"; then
        echo "Database directory kept: $DB_PATH."
    else
        rm -rf "$DB_PATH"
        echo "Removed database directory: $DB_PATH."
    fi

    echo "$SCRIPT_NAME uninstalled."
}

# Main script logic to check if already installed
check_root

if [ -f "$SCRIPT_PATH" ]; then
    echo "$SCRIPT_NAME is already installed."
    if confirm "Do you want to uninstall the script?"; then
        uninstall_script
    fi
else
    echo "$SCRIPT_NAME is not installed."
    if confirm "Do you want to install the script?"; then
        install_script
    fi
fi
