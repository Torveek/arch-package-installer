#!/bin/bash

# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

log_success() {
    echo -e "${CYAN}[SUCCESS]${NC} $1"
}

# Package lists
PACMAN_PACKAGES=(
    # Timeshift
    "timeshift" "grub-btrfs" "inotify-tools"
)

AUR_PACKAGES=(
    
)

# Check if script is run by root
check_permissions() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script with sudo. Run as a normal user."
        exit 1
    fi
}

# Check for Arch-based distro
check_system() {
    if ! command -v pacman &> /dev/null; then
        log_error "This script is designed for Arch-based distributions only."
        exit 1
    fi
    
    log_info "System check passed. Continuing installation..."
}

# Update system packages
update_system() {
    log_step "Updating system packages"
    sudo pacman -Syu --noconfirm || {
        log_warning "System update completed with some warnings. Continuing..."
    }
}

# Install packages from official repositories
install_pacman_packages() {
    log_step "Installing packages from official repositories"
    
    # Check for existing packages to avoid reinstalling
    local to_install=()
    for pkg in "${PACMAN_PACKAGES[@]}"; do
        if ! pacman -Q "$pkg" &> /dev/null; then
            to_install+=("$pkg")
        fi
    done
    
    if [ ${#to_install[@]} -eq 0 ]; then
        log_info "All official packages are already installed."
    else
        log_info "Installing ${#to_install[@]} packages..."
        sudo pacman -S --needed --noconfirm "${to_install[@]}" || {
            log_error "Failed to install some packages. Please check the output above."
            read -p "Do you want to continue anyway? (y/n): " continue_choice
            [[ $continue_choice != [yY] ]] && exit 1
        }
    fi
}

# Install yay AUR helper
install_yay() {
    log_step "Checking for AUR helper (yay)"
    
    if command -v yay &> /dev/null; then
        log_info "Yay is already installed."
        return 0
    fi
    
    log_info "Installing Yay AUR helper..."
    
    # Dependencies for yay
    sudo pacman -S --needed --noconfirm git base-devel
    
    # Create temp directory and clone yay
    local temp_dir=$(mktemp -d)
    git clone https://aur.archlinux.org/yay.git "$temp_dir"
    cd "$temp_dir" || {
        log_error "Failed to navigate to temporary directory for yay installation."
        exit 1
    }
    
    # Build and install yay
    makepkg -si --noconfirm || {
        log_error "Failed to install yay. Please install it manually."
        exit 1
    }
    
    # Clean up
    cd - > /dev/null
    rm -rf "$temp_dir"
    
    log_success "Yay installed successfully."
}

# Install packages from AUR
install_aur_packages() {
    log_step "Installing packages from AUR"
    
    # Check for existing packages to avoid reinstalling
    local to_install=()
    for pkg in "${AUR_PACKAGES[@]}"; do
        if ! yay -Q "$pkg" &> /dev/null; then
            to_install+=("$pkg")
        fi
    done
    
    if [ ${#to_install[@]} -eq 0 ]; then
        log_info "All AUR packages are already installed."
    else
        log_info "Installing ${#to_install[@]} AUR packages..."
        yay -S --needed --noconfirm "${to_install[@]}" || {
            log_warning "Some AUR packages may have failed to install."
            read -p "Do you want to continue anyway? (y/n): " continue_choice
            [[ $continue_choice != [yY] ]] && exit 1
        }
    fi
}

# Install and configure timeshift backup
configure_timeshift() {
    announce_step "Setting up Timeshift"

    # Ensure Timeshift is installed
    if ! command -v timeshift &>/dev/null; then
        if ! distro_install "timeshift"; then
            track_config_status "Timeshift Setup" "$CROSS_MARK"
            return 1
        fi
    fi

    # Enable the cronie service (required for scheduling snapshots)
    if ! execute_command "sudo systemctl enable --now cronie.service" "Enable Cronie for Timeshift scheduling"; then
        track_config_status "Timeshift Setup" "$CROSS_MARK"
        return 1
    fi

    # Create an initial snapshot without a .snapshot suffix
    if execute_command "sudo timeshift --create --comments 'Automated snapshot created by Linux-Setup script' --tags D" "Create initial Timeshift snapshot"; then
        track_config_status "Timeshift Setup" "$CHECK_MARK"
    else
        track_config_status "Timeshift Setup" "$CROSS_MARK"
    fi
}

configure_grub_btrfsd() {
    announce_step "Configuring grub-btrfsd"

    # Check if  Bootloader is GRUB
    if ! check_bootloader "grub"; then
        print_warning "Bootloader is not GRUB. Skipping grub-btrfsd configuration."
        track_config_status "grub-btrfsd Configuration" "$CIRCLE (Not GRUB bootloader)"
        return 0
    fi

    # Check if the root filesystem is BTRFS
    if ! mount | grep "on / type btrfs" > /dev/null; then
        print_warning "Root filesystem is not BTRFS. Skipping grub-btrfsd configuration."
        track_config_status "grub-btrfsd Configuration" "$CIRCLE (Not BTRFS filesystem)"
        return 0
    fi

    # Create systemd override directory if it doesn't exist
    if ! execute_command "sudo mkdir -p /etc/systemd/system/grub-btrfsd.service.d" "Create override directory for grub-btrfsd"; then
        track_config_status "grub-btrfsd Configuration" "$CROSS_MARK"
        return 1
    fi

    # Create (or overwrite) a drop-in override file that removes any '.snapshot' and appends '-t' to ExecStart
    if sudo bash -c "cat > /etc/systemd/system/grub-btrfsd.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=\$(grep '^ExecStart=' /etc/systemd/system/grub-btrfsd.service | sed 's/\.snapshot//g; s/\$/ -t/')
EOF"; then
        print_message "grub-btrfsd override file created."
    else
        print_error "Failed to create grub-btrfsd override file."
        track_config_status "grub-btrfsd Configuration" "$CROSS_MARK"
        return 1
    fi

    # Reload systemd daemon and enable the service
    if execute_command "sudo systemctl daemon-reload && sudo systemctl enable --now grub-btrfsd" "Enable grub-btrfsd service"; then
        track_config_status "Enable grub-btrfsd service" "$CHECK_MARK"
    else
        track_config_status "grub-btrfsd Configuration" "$CROSS_MARK"
    fi
}

# Main installation function
main() {
    clear

    # Print ASCII art header
    echo -e "${GREEN}"
    cat << "EOF"
                                                          shinzo™
 _     _ __   __  _____   ______ ______   _____  _______ _______
 |_____|   \_/   |_____] |_____/ |     \ |     |    |    |______
 |     |    |    |       |    \_ |_____/ |_____|    |    ______|

EOF
    echo -e "${NC}"
    echo -e "${CYAN}Timeshift Installation Script${NC}"
    echo -e "This will install Timeshift and configure your system."
    echo

    # Check basic requirements
    check_permissions
    check_system
    
    # Confirm installation
    echo
    read -p "Do you want to start the Timeshift installation? (y/n): " confirm
    if [[ $confirm != [yY] ]]; then
        log_info "Installation aborted by user."
        exit 0
    fi
    
    # Run installation steps
    update_system
    install_pacman_packages
    install_yay
    install_aur_packages
    configure_timeshift
    configure_grub_btrfsd
    
    # Installation complete
    echo
    log_success "Timeshift installation complete!"
    # log_success "Welcome to your new Hyprland desktop environment!"
    echo
    log_warning "Please reboot your system to apply all changes."
    echo
    
    # Prompt for reboot
    read -p "Would you like to reboot now? (y/n): " reboot_choice
    if [[ $reboot_choice == [yY] ]]; then
        log_info "Rebooting system..."
        sudo reboot
    else
        log_info "Remember to reboot later to fully apply the changes."
    fi
}

# Run the main function
main
