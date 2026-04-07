#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════
# WordPress Docker Deploy Script
# Idempotent interactive deployer for WordPress + MySQL
# with Cloudflare Tunnel integration
# ═══════════════════════════════════════════════════════════

SCRIPT_VERSION="1.0.0"

# ── Globals ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCES_DIR="$HOME/wordpress-instances"
CREDS_DIR="/root/wp-creds"
CF_SERVICE_CONFIG_DIR="/etc/cloudflared"
CF_USER_CONFIG_DIR="/root/.cloudflared"
CF_CERT="/root/.cloudflared/cert.pem"
GLOBAL_ENV_FILE="$SCRIPT_DIR/.env"
GLOBAL_ENV_TEMPLATE="$SCRIPT_DIR/.env.template"
declare -A GLOBAL_CONFIG=()
LOG_FILE=""
CURRENT_STEP=0
TOTAL_STEPS=16
# Weighted cumulative end-% per step. Each value is the % the bar shows
# when that step COMPLETES. Weights reflect typical wall-clock time.
#  1-detect 2-deps 3-cf 4-config 5-dirs 6-creds 7-compose
#  8-pull-mysql 9-pull-wp 10-up 11-mysql-wait 12-wp-wait
#  13-wpcli 14-cf-finalize 15-verify 16-done
declare -a _STEP_END=(
    [0]=0
    [1]=2   [2]=20  [3]=24  [4]=25
    [5]=26  [6]=27  [7]=28  [8]=38
    [9]=48  [10]=52 [11]=63 [12]=74
    [13]=86 [14]=91 [15]=98 [16]=100
)
CURRENT_PROGRESS_PERCENT=""
CURRENT_PROGRESS_MESSAGE=""
PROGRESS_ACTIVE=false

# Instance config (populated by prompts)
INSTANCE_NAME=""
WP_PORT=""
CF_HOSTNAME=""
CF_TUNNEL_NAME=""
CF_TUNNEL_UUID=""
CF_NEEDS_INITIAL_CONFIG=false
CF_NEEDS_SERVICE_INSTALL=false
WP_SITE_TITLE=""
WP_ADMIN_USER=""
WP_ADMIN_PASSWORD=""
WP_ADMIN_EMAIL=""
WP_LOCALE=""
WP_TIMEZONE=""
WP_DEBUG=""
WP_PUBLIC_URL=""
WP_BLOG_PUBLIC=""
WP_GMT_OFFSET=""
MYSQL_ROOT_PASSWORD=""
MYSQL_PASSWORD=""
MYSQL_DATABASE=""
MYSQL_USER=""
WP_TABLE_PREFIX=""

# System detection
DISTRO_ID=""
DISTRO_NAME=""
DISTRO_VERSION=""
ARCH=""
PKG_MANAGER=""

# ── Colors ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'
NC='\033[0m'

# ── Logging ──────────────────────────────────────────────
log_file() {
    local level="$1"; shift
    if [[ -n "$LOG_FILE" && -w "$(dirname "$LOG_FILE")" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOG_FILE"
    fi
}

log_info()  { log_file "INFO" "$@"; }
log_warn()  { log_file "WARN" "$@"; }
log_error() { log_file "ERROR" "$@"; }
log_cmd()   { log_file "CMD" "$@"; }

# Run a command, log its full output, suppress terminal output
run_logged() {
    log_cmd "$*"
    local output="" exit_code=0
    output=$("$@" 2>&1) || exit_code=$?
    [[ -n "$output" ]] && log_file "OUTPUT" "$output"
    if [[ $exit_code -ne 0 ]]; then
        log_error "Command failed (exit $exit_code): $*"
        return $exit_code
    fi
    return 0
}

# Run a command with sudo, using -A flag if needed
run_sudo() {
    if sudo -n true 2>/dev/null; then
        run_logged sudo "$@"
    else
        run_logged sudo -A "$@"
    fi
}

# Run sudo without logging (for interactive commands)
run_sudo_interactive() {
    if sudo -n true 2>/dev/null; then
        sudo "$@"
    else
        sudo -A "$@"
    fi
}

escape_compose_dollars() {
    printf '%s' "$1" | sed 's/\$/$$/g'
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

strip_surrounding_quotes() {
    local value="$1"
    if [[ ${#value} -ge 2 ]]; then
        case "$value" in
            \"*\") value="${value:1:-1}" ;;
            \'*\') value="${value:1:-1}" ;;
        esac
    fi
    printf '%s' "$value"
}

global_config_has_value() {
    [[ -n "${GLOBAL_CONFIG[$1]:-}" ]]
}

global_config_get() {
    printf '%s' "${GLOBAL_CONFIG[$1]:-}"
}

parse_bool_value() {
    local raw
    raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        true|1|yes|y|on) printf 'true' ;;
        false|0|no|n|off) printf 'false' ;;
        *) return 1 ;;
    esac
}

validate_port_value() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

load_global_env_config() {
    local line="" key="" value="" loaded=0

    [[ -f "$GLOBAL_ENV_FILE" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export }"
        fi

        [[ "$line" == *=* ]] || continue
        key=$(trim_whitespace "${line%%=*}")
        value=$(trim_whitespace "${line#*=}")
        value=$(strip_surrounding_quotes "$value")
        [[ -n "$key" ]] || continue
        GLOBAL_CONFIG["$key"]="$value"
        (( loaded += 1 ))
    done < "$GLOBAL_ENV_FILE"

    print_info "Loaded runtime overrides from $GLOBAL_ENV_FILE ($loaded keys)"
    log_info "Loaded runtime overrides from $GLOBAL_ENV_FILE ($loaded keys)"
}

# ── Docker Compose Helper ────────────────────────────────
# Copies the root-owned .env to a user-readable temp file, runs docker compose, cleans up
dc() {
    local instance_dir="$1"; shift
    local creds_path="$CREDS_DIR/$(basename "$instance_dir")/.env"
    local tmp_env
    local log_target="${LOG_FILE:-/tmp/wp-deploy-docker.log}"
    tmp_env=$(mktemp /tmp/wp-env-XXXXXX)
    sudo cat "$creds_path" > "$tmp_env"
    chmod 600 "$tmp_env"
    log_cmd "sudo docker compose --env-file $tmp_env $* (cwd=$instance_dir)"
    (cd "$instance_dir" && sudo docker compose --env-file "$tmp_env" "$@") >> "$log_target" 2>&1
    local rc=$?
    log_info "sudo docker compose $* exited with status $rc"
    rm -f "$tmp_env"
    return $rc
}

# ── Progress Bar ─────────────────────────────────────────
render_progress_bar() {
    local percent="$CURRENT_PROGRESS_PERCENT"
    local message="$CURRENT_PROGRESS_MESSAGE"
    local bar_width=30
    local filled=$(( percent * bar_width / 100 ))
    local empty=$(( bar_width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf "\r${CYAN}[${bar}]${NC} ${BOLD}%3d%%${NC} ▸ %s" "$percent" "$message"
    printf "\033[K"
}

clear_progress_bar() {
    if $PROGRESS_ACTIVE; then
        printf "\r\033[K"
    fi
}

finish_progress_bar() {
    clear_progress_bar
    PROGRESS_ACTIVE=false
    CURRENT_PROGRESS_PERCENT=""
    CURRENT_PROGRESS_MESSAGE=""
}

progress_bar() {
    CURRENT_PROGRESS_PERCENT="$1"
    CURRENT_PROGRESS_MESSAGE="$2"
    PROGRESS_ACTIVE=true
    render_progress_bar
    return 0
}

step() {
    local step_num=$1
    local message="$2"
    CURRENT_STEP=$step_num
    local percent
    if [[ $step_num -le 0 ]]; then
        percent=0
    elif [[ $step_num -ge $TOTAL_STEPS ]]; then
        percent="${_STEP_END[$TOTAL_STEPS]:-100}"
    else
        # Show end-% of the *previous* step (= start of this step)
        percent="${_STEP_END[$((step_num - 1))]:-0}"
    fi
    progress_bar "$percent" "$message"
    log_info "STEP $step_num/$TOTAL_STEPS: $message"
}

# Animate the progress bar while a background PID is running.
# Usage: progress_ticker START_PCT END_PCT "message" BG_PID
# Returns the exit code of the background process.
progress_ticker() {
    local start_pct="$1" end_pct="$2" msg="$3" bg_pid="$4"
    local pct="$start_pct"
    # Advance 1% every 0.5 s, but stop 2 points short so we don't
    # reach the end before the real work is done.
    local hold=$(( end_pct - 2 ))
    [[ $hold -lt $start_pct ]] && hold=$start_pct
    while kill -0 "$bg_pid" 2>/dev/null; do
        progress_bar "$pct" "$msg"
        [[ $pct -lt $hold ]] && (( pct++ ))
        sleep 0.5
    done
    wait "$bg_pid"
    local rc=$?
    (( rc == 0 )) && progress_bar "$end_pct" "$msg"
    return $rc
}

# Run a command in background under sudo and tick the progress bar.
# Usage: run_sudo_with_tick START_PCT END_PCT "message" -- cmd [args...]
# Output (stdout+stderr) is appended to LOG_FILE (or a preflight temp log).
run_sudo_with_tick() {
    local start_pct="$1" end_pct="$2" msg="$3"
    shift 3
    [[ "${1:-}" == "--" ]] && shift
    local log_target="${LOG_FILE:-/tmp/wp-deploy-preflight.log}"
    log_cmd "$*"
    sudo "$@" >> "$log_target" 2>&1 &
    local bg_pid=$!
    progress_ticker "$start_pct" "$end_pct" "$msg" "$bg_pid"
}

print_status_line() {
    local color="$1"
    local symbol="$2"
    local message="$3"

    clear_progress_bar
    printf "%b%s%b %s\033[K\n" "$color" "$symbol" "$NC" "$message"
    if $PROGRESS_ACTIVE; then
        render_progress_bar
    fi
}

print_success() { print_status_line "$GREEN" "✓" "$1"; log_info "$1"; }
print_error()   { print_status_line "$RED" "✗" "$1"; log_error "$1"; }
print_warn()    { print_status_line "$YELLOW" "!" "$1"; log_warn "$1"; }
print_info()    { print_status_line "$BLUE" "ℹ" "$1"; log_info "$1"; }

# ── System Detection ─────────────────────────────────────
detect_system() {
    step 1 "Detecting system..."

    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect Linux distribution (/etc/os-release not found)"
        exit 1
    fi

    # Source os-release with nounset temporarily disabled (file may reference unset vars)
    # shellcheck disable=SC1091
    set +u
    source /etc/os-release
    set -u
    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-unknown}"
    DISTRO_VERSION="${VERSION_ID:-unknown}"
    ARCH=$(uname -m)

    if command -v apt-get &>/dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MANAGER="yum"
    elif command -v pacman &>/dev/null; then
        PKG_MANAGER="pacman"
    else
        print_error "Unsupported package manager. Install docker, openssl, curl, jq manually."
        exit 1
    fi

    log_info "System: $DISTRO_NAME ($DISTRO_ID $DISTRO_VERSION) $ARCH, pkg=$PKG_MANAGER"
    print_success "System: $DISTRO_NAME | $ARCH | pkg=$PKG_MANAGER"
}

# ── Dependency Installation ──────────────────────────────
install_package() {
    local pkg="$1"
    log_info "Installing $pkg via $PKG_MANAGER"
    case "$PKG_MANAGER" in
        apt)    run_sudo apt-get update -qq && run_sudo apt-get install -y -qq "$pkg" ;;
        dnf)    run_sudo dnf install -y -q "$pkg" ;;
        yum)    run_sudo yum install -y -q "$pkg" ;;
        pacman) run_sudo pacman -S --noconfirm --quiet "$pkg" ;;
    esac
}

install_docker() {
    log_info "Installing Docker..."
    print_info "Installing Docker Engine..."
    case "$PKG_MANAGER" in
        apt)
            run_sudo apt-get update -qq
            run_sudo apt-get install -y -qq ca-certificates curl gnupg
            run_sudo install -m 0755 -d /etc/apt/keyrings
            if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
                local gpg_url="https://download.docker.com/linux/${DISTRO_ID}/gpg"
                curl -fsSL "$gpg_url" 2>>"${LOG_FILE:-/dev/null}" | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
                run_sudo chmod a+r /etc/apt/keyrings/docker.asc
            fi
            local codename
            codename="${VERSION_CODENAME:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DISTRO_ID} ${codename} stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            run_sudo apt-get update -qq
            run_sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        dnf)
            run_sudo dnf install -y -q dnf-plugins-core
            run_sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            run_sudo dnf install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        yum)
            run_sudo yum install -y -q yum-utils
            run_sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            run_sudo yum install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
            ;;
        pacman)
            run_sudo pacman -S --noconfirm docker docker-compose
            ;;
    esac
    run_sudo systemctl enable --now docker
    # Add current user to docker group so future logins work without sudo
    if ! groups "$USER" 2>/dev/null | grep -qw docker; then
        run_sudo usermod -aG docker "$USER"
        log_info "Added $USER to docker group (effective after re-login)"
    fi
}

check_dependencies() {
    step 2 "Checking dependencies..."

    # ── System update (apt-based distros) ────────────────────
    if [[ "$PKG_MANAGER" == "apt" ]]; then
        local apt_log="${LOG_FILE:-/tmp/wp-deploy-preflight.log}"
        # Run all three apt phases in a single background job so the progress
        # bar can animate (step 2 spans 2 → 20 % in the weighted table).
        {
            sudo env DEBIAN_FRONTEND=noninteractive apt-get update -qq
            sudo env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
                -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
            sudo env DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -qq \
                -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"
        } >> "$apt_log" 2>&1 &
        local apt_pid=$!
        progress_ticker "${_STEP_END[1]}" "${_STEP_END[2]}" "Updating system packages (apt)..." "$apt_pid" || {
            print_error "System package update failed — check $apt_log"
            exit 1
        }
        print_success "System packages up to date"
    fi

    # ── Docker ───────────────────────────────────────────────
    if ! command -v docker &>/dev/null; then
        install_docker
    fi

    # Verify Docker Compose v2 plugin (use sudo — user may not be in docker group yet)
    if ! sudo docker compose version &>/dev/null 2>&1; then
        print_error "Docker Compose v2 not available after Docker install (arch: $ARCH, distro: $DISTRO_ID)"
        exit 1
    fi

    # Ensure Docker daemon is running
    if ! sudo docker info &>/dev/null 2>&1; then
        print_info "Starting Docker daemon..."
        run_sudo systemctl start docker
        # Wait up to 15s for daemon to become available
        local _d=0
        until sudo docker info &>/dev/null 2>&1 || (( ++_d >= 15 )); do sleep 1; done
        if ! sudo docker info &>/dev/null 2>&1; then
            print_error "Docker daemon failed to start (arch: $ARCH)"
            exit 1
        fi
    fi

    # ── Other tools ──────────────────────────────────────────
    for tool in openssl curl jq; do
        if ! command -v "$tool" &>/dev/null; then
            print_info "Installing $tool..."
            install_package "$tool"
        fi
    done

    local docker_ver compose_ver
    docker_ver=$(sudo docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
    compose_ver=$(sudo docker compose version --short 2>/dev/null || echo "unknown")
    log_info "All dependencies satisfied (arch=$ARCH distro=$DISTRO_ID)"
    print_success "Dependencies OK — docker $docker_ver, compose $compose_ver, arch=$ARCH"
}

# ── Cloudflare Tunnel ────────────────────────────────────
install_cloudflared() {
    print_info "Installing cloudflared..."
    case "$PKG_MANAGER" in
        apt)
            run_sudo mkdir -p --mode=0755 /usr/share/keyrings
            curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | sudo tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null 2>>"${LOG_FILE:-/dev/null}"
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null 2>>"${LOG_FILE:-/dev/null}"
            run_sudo apt-get update -qq
            run_sudo apt-get install -y -qq cloudflared
            ;;
        *)
            local arch
            arch=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
            curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o /tmp/cloudflared 2>>"${LOG_FILE:-/dev/null}"
            run_sudo mv /tmp/cloudflared /usr/local/bin/cloudflared
            run_sudo chmod +x /usr/local/bin/cloudflared
            ;;
    esac

    if ! command -v cloudflared &>/dev/null; then
        print_error "cloudflared installation failed"
        exit 1
    fi
    local cf_ver
    cf_ver=$(cloudflared --version 2>&1 | head -1)
    print_success "cloudflared installed ($cf_ver)"
}

cf_login() {
    print_info "Cloudflare authentication required."
    print_info "A browser window will open — log in to your Cloudflare account."
    echo ""
    run_sudo_interactive cloudflared login
    if ! sudo test -f "$CF_CERT"; then
        print_error "Authentication failed — $CF_CERT not found"
        exit 1
    fi
    print_success "Cloudflare authentication successful"
}

cf_get_tunnel_info() {
    # First: check for local credential .json files in /root/.cloudflared/
    # These are the authoritative source — if a .json exists, a tunnel exists on this system
    local json_files=()
    while IFS= read -r f; do
        # Filter: must be a UUID-shaped filename (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.json)
        local basename_f
        basename_f=$(basename "$f")
        if [[ "$basename_f" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$ ]]; then
            json_files+=("$f")
        fi
    done < <(sudo find "$CF_USER_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null)

    local json_count=${#json_files[@]}

    if [[ "$json_count" -eq 0 ]]; then
        return 1
    elif [[ "$json_count" -eq 1 ]]; then
        # Single tunnel — use it automatically
        local uuid_file
        uuid_file=$(basename "${json_files[0]}" .json)
        CF_TUNNEL_UUID="$uuid_file"
        # Get tunnel name from cloudflared
        local tname
        tname=$(sudo cloudflared tunnel list --output json 2>/dev/null | jq -r --arg id "$CF_TUNNEL_UUID" '.[] | select(.id == $id) | .name' 2>/dev/null || echo "")
        CF_TUNNEL_NAME="${tname:-$CF_TUNNEL_UUID}"
        print_success "Detected tunnel: $CF_TUNNEL_NAME ($CF_TUNNEL_UUID)"
    else
        # Multiple tunnels — resolve names via cloudflared, let user pick
        local tunnels_json
        tunnels_json=$(sudo cloudflared tunnel list --output json 2>/dev/null || echo "[]")

        echo ""
        print_info "Multiple tunnels found on this system:"
        local names=() uuids=()
        local i=0
        for jf in "${json_files[@]}"; do
            local uuid
            uuid=$(basename "$jf" .json)
            local tname
            tname=$(echo "$tunnels_json" | jq -r --arg id "$uuid" '.[] | select(.id == $id) | .name' 2>/dev/null || echo "$uuid")
            names+=("$tname")
            uuids+=("$uuid")
            echo "  $((i+1)). $tname ($uuid)"
            ((i++)) || true
        done
        echo ""
        local selection
        read -rp "$(echo -e "${CYAN}Select tunnel${NC} [1-${#names[@]}] or name: ")" selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#names[@]} )); then
            CF_TUNNEL_NAME="${names[$((selection-1))]}"
            CF_TUNNEL_UUID="${uuids[$((selection-1))]}"
        else
            # Typed a name — find its UUID
            CF_TUNNEL_NAME="$selection"
            CF_TUNNEL_UUID=""
            for idx in "${!names[@]}"; do
                if [[ "${names[$idx]}" == "$selection" ]]; then
                    CF_TUNNEL_UUID="${uuids[$idx]}"
                    break
                fi
            done
            if [[ -z "$CF_TUNNEL_UUID" ]]; then
                print_error "Tunnel '$selection' not found"
                exit 1
            fi
        fi
    fi
    log_info "Using tunnel: $CF_TUNNEL_NAME ($CF_TUNNEL_UUID)"
    return 0
}

cf_create_tunnel() {
    local default_name
    default_name="$(hostname)-tunnel"
    local tunnel_name
    read -rp "$(echo -e "${CYAN}Tunnel name${NC} [$default_name]: ")" tunnel_name
    tunnel_name="${tunnel_name:-$default_name}"

    print_info "Creating tunnel '$tunnel_name'..."
    clear_progress_bar
    run_sudo_interactive cloudflared tunnel create "$tunnel_name" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
    if $PROGRESS_ACTIVE; then
        render_progress_bar
    fi

    cf_get_tunnel_info || {
        print_error "Failed to retrieve tunnel info after creation"
        exit 1
    }

    print_success "Tunnel created: $CF_TUNNEL_NAME ($CF_TUNNEL_UUID)"
}

cf_find_config() {
    local dir="$1"
    if sudo test -f "$dir/config.yaml"; then echo "$dir/config.yaml"
    elif sudo test -f "$dir/config.yml"; then echo "$dir/config.yml"
    else echo "$dir/config.yaml"
    fi
}

cf_write_initial_config() {
    local hostname="$1" port="$2"
    local config_path="$CF_USER_CONFIG_DIR/config.yaml"

    sudo tee "$config_path" > /dev/null <<EOF
tunnel: ${CF_TUNNEL_UUID}
credentials-file: ${CF_USER_CONFIG_DIR}/${CF_TUNNEL_UUID}.json
ingress:
  - hostname: ${hostname}
    service: http://localhost:${port}
  - service: http_status:404
EOF
    log_info "Wrote initial CF config to $config_path"
    print_success "Cloudflare config written"
}

cf_backup_config() {
    local config="$1"
    if sudo test -f "$config"; then
        local backup_path="${config}.bak.$(date +%Y%m%d%H%M%S)"
        run_sudo cp "$config" "$backup_path"
        log_info "Backed up $config to $backup_path"
    fi
}

cf_validate_config() {
    local config="$1"
    if ! sudo test -f "$config"; then
        return 0
    fi

    log_cmd "cloudflared tunnel --config $config ingress validate"
    if run_sudo cloudflared tunnel --config "$config" ingress validate; then
        print_info "Validated cloudflared ingress config: $config"
        return 0
    fi

    print_error "cloudflared ingress validation failed: $config"
    return 1
}

cf_validate_all_configs() {
    local service_config user_config
    service_config=$(cf_find_config "$CF_SERVICE_CONFIG_DIR")
    user_config=$(cf_find_config "$CF_USER_CONFIG_DIR")

    cf_validate_config "$user_config"
    cf_validate_config "$service_config"
}

cf_install_service() {
    print_info "Installing cloudflared as a system service..."
    clear_progress_bar
    run_sudo_interactive cloudflared service install 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
    if $PROGRESS_ACTIVE; then
        render_progress_bar
    fi

    # Verify /etc/cloudflared/config.yaml exists
    local svc_config
    svc_config=$(cf_find_config "$CF_SERVICE_CONFIG_DIR")
    if ! sudo test -f "$svc_config"; then
        run_sudo mkdir -p "$CF_SERVICE_CONFIG_DIR"
        local user_config
        user_config=$(cf_find_config "$CF_USER_CONFIG_DIR")
        run_sudo cp "$user_config" "$svc_config"
        log_info "Copied config to $svc_config (service install didn't create it)"
    fi

    run_sudo systemctl enable cloudflared 2>/dev/null || true
    run_sudo systemctl start cloudflared
    print_success "cloudflared service installed and running"
}

cf_append_ingress() {
    local hostname="$1" port="$2"

    for config_dir in "$CF_SERVICE_CONFIG_DIR" "$CF_USER_CONFIG_DIR"; do
        local config
        config=$(cf_find_config "$config_dir")
        if ! sudo test -f "$config"; then
            continue
        fi

        cf_backup_config "$config"

        # Check if hostname already exists — update port if so
        if sudo grep -Fq "hostname: ${hostname}" "$config" 2>/dev/null; then
            log_info "Hostname $hostname already in $config — updating port"
            sudo sed -i "/hostname: ${hostname}/{n;s|service: http://localhost:[0-9]*|service: http://localhost:${port}|}" "$config"
        else
            # Insert new entry before the catch-all rule using a temp file for portability
            local tmpfile
            tmpfile=$(mktemp)
            sudo awk -v host="$hostname" -v port="$port" '
                /^  - service: http_status:404/ {
                    print "  - hostname: " host
                    print "    service: http://localhost:" port
                }
                { print }
            ' "$config" > "$tmpfile"
            sudo mv "$tmpfile" "$config"
            sudo chmod 644 "$config"
        fi
        log_info "Updated ingress in $config"
    done

    print_success "Ingress entry added: ${hostname} → localhost:${port}"
}

cf_remove_ingress() {
    local hostname="$1"

    for config_dir in "$CF_SERVICE_CONFIG_DIR" "$CF_USER_CONFIG_DIR"; do
        local config
        config=$(cf_find_config "$config_dir")
        if ! sudo test -f "$config"; then
            continue
        fi

        cf_backup_config "$config"

        # Remove the hostname line and the service line that follows it
        local tmpfile
        tmpfile=$(mktemp)
        sudo awk -v host="$hostname" '
            $0 == "  - hostname: " host { skip=1; next }
            skip && $0 ~ /^    service:/ { skip=0; next }
            { print }
        ' "$config" > "$tmpfile"
        sudo mv "$tmpfile" "$config"
        sudo chmod 644 "$config"
        log_info "Removed ingress for $hostname from $config"
    done
}

cf_route_dns() {
    local tunnel_name="$1" hostname="$2"
    print_info "Adding DNS route: $hostname → tunnel $tunnel_name"
    clear_progress_bar
    run_sudo_interactive cloudflared tunnel route dns --overwrite-dns "$tunnel_name" "$hostname" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"
    if $PROGRESS_ACTIVE; then
        render_progress_bar
    fi
    print_success "DNS route added: $hostname"
}

cf_extract_api_credentials() {
    if ! sudo test -f "$CF_CERT"; then
        return 1
    fi

    local cert_payload cert_json
    cert_payload=$(sudo awk '/BEGIN ARGO TUNNEL TOKEN/{next}/END ARGO TUNNEL TOKEN/{next}{printf "%s",$0}' "$CF_CERT")
    cert_json=$(printf '%s' "$cert_payload" | base64 -d 2>/dev/null || true)

    if [[ -z "$cert_json" ]]; then
        return 1
    fi

    CF_API_ZONE_ID=$(jq -r '.zoneID // empty' <<<"$cert_json")
    CF_API_TOKEN=$(jq -r '.apiToken // empty' <<<"$cert_json")
    [[ -n "$CF_API_ZONE_ID" && -n "$CF_API_TOKEN" ]]
}

cf_delete_dns_record_via_api() {
    local hostname="$1"
    local records record_ids deleted_count=0

    if ! cf_extract_api_credentials; then
        print_warn "Cloudflare API credentials not available in $CF_CERT; manual DNS cleanup required for $hostname"
        return 1
    fi

    records=$(curl -fsSL -G \
        -H "Authorization: Bearer $CF_API_TOKEN" \
        --data-urlencode "name=$hostname" \
        "https://api.cloudflare.com/client/v4/zones/$CF_API_ZONE_ID/dns_records")

    record_ids=$(jq -r --arg name "$hostname" '.result[] | select(.name == $name) | .id' <<<"$records")
    if [[ -z "$record_ids" ]]; then
        print_info "No Cloudflare DNS record found for $hostname"
        return 0
    fi

    while IFS= read -r record_id; do
        [[ -z "$record_id" ]] && continue
        log_cmd "DELETE https://api.cloudflare.com/client/v4/zones/$CF_API_ZONE_ID/dns_records/$record_id"
        curl -fsSL -X DELETE \
            -H "Authorization: Bearer $CF_API_TOKEN" \
            "https://api.cloudflare.com/client/v4/zones/$CF_API_ZONE_ID/dns_records/$record_id" \
            >> "${LOG_FILE:-/tmp/wp-deploy-cloudflare.log}" 2>&1
        (( deleted_count += 1 ))
    done <<<"$record_ids"

    print_success "Removed $deleted_count Cloudflare DNS record(s) for $hostname"
}

cf_remove_dns_route() {
    local tunnel_name="$1" hostname="$2"
    print_info "Removing DNS route for $hostname..."
    if cf_delete_dns_record_via_api "$hostname"; then
        return 0
    fi
    print_warn "Please remove the DNS record for '$hostname' from your Cloudflare dashboard."
    log_warn "DNS record cleanup needed for $hostname — user notified"
}

setup_cloudflared() {
    step 3 "Setting up Cloudflare Tunnel..."

    # ── Check each condition independently ───────────────────
    local cf_installed=false cf_authenticated=false
    local cf_has_tunnel=false cf_service_installed=false cf_has_config=false

    command -v cloudflared &>/dev/null \
        && cf_installed=true

    sudo test -f "$CF_CERT" 2>/dev/null \
        && cf_authenticated=true

    # Look for UUID-shaped credential JSON (tunnel exists on this host)
    local _creds_json=""
    while IFS= read -r _f; do
        local _bn
        _bn=$(basename "$_f")
        if [[ "$_bn" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$ ]]; then
            _creds_json="$_f"
            break
        fi
    done < <(sudo find "$CF_USER_CONFIG_DIR" -maxdepth 1 -name '*.json' 2>/dev/null)
    [[ -n "$_creds_json" ]] && cf_has_tunnel=true

    systemctl is-enabled cloudflared &>/dev/null 2>&1 \
        && cf_service_installed=true

    local _user_config
    _user_config=$(cf_find_config "$CF_USER_CONFIG_DIR")
    sudo test -f "$_user_config" 2>/dev/null \
        && cf_has_config=true

    log_info "CF flags: installed=$cf_installed auth=$cf_authenticated tunnel=$cf_has_tunnel service=$cf_service_installed config=$cf_has_config"

    # ── Fast path: everything already in place ────────────────
    if $cf_installed && $cf_authenticated && $cf_has_tunnel && $cf_service_installed; then
        if cf_get_tunnel_info 2>/dev/null; then
            CF_NEEDS_INITIAL_CONFIG=false
            CF_NEEDS_SERVICE_INSTALL=false
            print_success "Cloudflare Tunnel fully operational: $CF_TUNNEL_NAME ($CF_TUNNEL_UUID)"
            return 0
        fi
        # Credential JSON gone — fall through and re-create tunnel
        cf_has_tunnel=false
        print_warn "Tunnel credential missing — re-creating tunnel"
    fi

    finish_progress_bar

    # ── Step 1: Install cloudflared (official Cloudflare method) ─
    if ! $cf_installed; then
        install_cloudflared
    else
        local _cf_ver
        _cf_ver=$(cloudflared --version 2>&1 | head -1)
        print_success "cloudflared already installed: $_cf_ver"
    fi

    # ── Step 2: Authenticate (generates $CF_CERT) ────────────────
    if ! $cf_authenticated; then
        cf_login
    else
        print_success "Cloudflare credentials present: $CF_CERT"
    fi

    # ── Step 3: Create or load tunnel ────────────────────────────
    if ! $cf_has_tunnel; then
        cf_create_tunnel
        cf_has_config=false   # New tunnel — config must be (re)written
    else
        cf_get_tunnel_info
        print_success "Using existing tunnel: $CF_TUNNEL_NAME ($CF_TUNNEL_UUID)"
    fi

    # ── Step 4: Write initial config.yaml if missing ─────────────
    if ! $cf_has_config; then
        local cf_domain
        cf_domain="$(global_config_get DOMAIN)"
        if [[ -z "$cf_domain" ]]; then
            echo ""
            read -rp "$(echo -e "${CYAN}Cloudflare domain${NC} (e.g. yourdomain.com): ")" cf_domain
            cf_domain=$(trim_whitespace "$cf_domain")
        fi
        if [[ -z "$cf_domain" ]]; then
            print_error "A Cloudflare domain is required to write the tunnel config"
            exit 1
        fi
        # Write initial config: tunnel → hostname.$domain → localhost:8080 (placeholder)
        cf_write_initial_config "${CF_TUNNEL_NAME}.${cf_domain}" "8080"
    else
        print_success "cloudflared config exists: $_user_config"
    fi

    # ── Step 5: Install cloudflared as system service ─────────────
    if ! $cf_service_installed; then
        cf_install_service
    else
        print_success "cloudflared service already installed — restarting"
        run_sudo systemctl restart cloudflared 2>/dev/null || true
    fi

    CF_NEEDS_INITIAL_CONFIG=false
    CF_NEEDS_SERVICE_INSTALL=false
}

# ── Instance Configuration ───────────────────────────────
get_next_instance_number() {
    local max=0
    if [[ -d "$INSTANCES_DIR" ]]; then
        for dir in "$INSTANCES_DIR"/wordpress-*/; do
            [[ ! -d "$dir" ]] && continue
            local num="${dir##*wordpress-}"
            num="${num%/}"
            if [[ "$num" =~ ^[0-9]+$ ]] && (( num > max )); then
                max=$num
            fi
        done
    fi
    echo $(( max + 1 ))
}

port_is_in_use() {
    local port="$1"

    if sudo test -d "$CREDS_DIR" 2>/dev/null; then
        for env_file in "$CREDS_DIR"/*/.env; do
            [[ ! -f "$env_file" ]] && continue
            local used_port
            used_port=$(sudo grep -oP '^WP_PORT=\K.*' "$env_file" 2>/dev/null || true)
            if [[ "$used_port" == "$port" ]]; then
                log_info "Port $port skipped (already assigned to a managed instance)"
                return 0
            fi
        done
    fi

    if command -v ss &>/dev/null; then
        if ss -H -ltn 2>/dev/null | awk -v port="$port" '{addr=$4; sub(/.*:/, "", addr); if (addr == port) { found=1; exit }} END { exit(found ? 0 : 1) }'; then
            log_info "Port $port skipped (host listener already bound)"
            return 0
        fi
    elif command -v lsof &>/dev/null; then
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
            log_info "Port $port skipped (host listener already bound)"
            return 0
        fi
    elif command -v netstat &>/dev/null; then
        if netstat -ltn 2>/dev/null | awk -v port="$port" 'NR > 2 {addr=$4; sub(/.*:/, "", addr); if (addr == port) { found=1; exit }} END { exit(found ? 0 : 1) }'; then
            log_info "Port $port skipped (host listener already bound)"
            return 0
        fi
    fi

    return 1
}

get_next_port() {
    local port="${GLOBAL_CONFIG[HTTP_PORT]:-8080}"

    if ! validate_port_value "$port"; then
        log_warn "Invalid HTTP_PORT override '${port:-}' in $GLOBAL_ENV_FILE; falling back to 8080"
        port=8080
    fi

    while port_is_in_use "$port"; do
        (( port++ ))
    done

    echo "$port"
}

normalize_locale_code() {
    local locale="${1:-}"
    local language=""
    local region=""

    locale="${locale%%.*}"
    locale="${locale%%@*}"
    locale="${locale//-/_}"

    case "$locale" in
        ""|C|POSIX|C_UTF_8|C.UTF_8) echo "en_US" ;;
        en) echo "en_US" ;;
        fr) echo "fr_FR" ;;
        es) echo "es_ES" ;;
        de) echo "de_DE" ;;
        pt) echo "pt_PT" ;;
        zh) echo "zh_CN" ;;
        [a-z][a-z]_[A-Za-z][A-Za-z])
            language="${locale%%_*}"
            region="${locale#*_}"
            printf '%s_%s\n' "$language" "${region^^}"
            ;;
        *) echo "$locale" ;;
    esac
}

detect_system_locale() {
    local detected=""
    local candidate
    local -a candidates=("${LANG:-}" "${LANGUAGE:-}" "${LC_ALL:-}" "${LC_MESSAGES:-}")

    for candidate in "${candidates[@]}"; do
        candidate="${candidate%%:*}"
        case "$candidate" in
            ""|C|POSIX|C_UTF_8|C.UTF-8) continue ;;
        esac
        if [[ -n "$candidate" ]]; then
            detected="$candidate"
            break
        fi
    done

    if [[ -z "$detected" ]] && command -v locale &>/dev/null; then
        detected=$(locale 2>/dev/null | awk -F= '/^LANG=/{gsub(/"/, "", $2); print $2; exit}')
    fi

    normalize_locale_code "${detected:-en_US}"
}

detect_system_timezone() {
    local detected=""
    local timezone_link=""

    if command -v timedatectl &>/dev/null; then
        detected=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    fi

    [[ "$detected" == "n/a" ]] && detected=""

    if [[ -z "$detected" && -f /etc/timezone ]]; then
        detected=$(tr -d '[:space:]' < /etc/timezone)
    fi

    if [[ -z "$detected" && -L /etc/localtime ]]; then
        timezone_link=$(readlink /etc/localtime 2>/dev/null || true)
        if [[ "$timezone_link" == *"/zoneinfo/"* ]]; then
            detected="${timezone_link#*/zoneinfo/}"
        fi
    fi

    printf '%s' "${detected:-UTC}"
}

wp_offset_display_from_value() {
    local offset_value="${1#UTC}"
    local sign="+"
    local hours minutes

    if [[ "$offset_value" == -* ]]; then
        sign="-"
        offset_value="${offset_value#-}"
    else
        offset_value="${offset_value#+}"
    fi

    hours="${offset_value%%.*}"
    minutes="00"

    if [[ "$offset_value" == *.* ]]; then
        case "${offset_value#*.}" in
            25) minutes="15" ;;
            5|50) minutes="30" ;;
            75) minutes="45" ;;
        esac
    fi

    printf 'UTC%s%02d:%s' "$sign" "$hours" "$minutes"
}

timezone_display_to_gmt_offset() {
    local timezone_display="$1"
    local sign hours minutes value

    if [[ ! "$timezone_display" =~ ^UTC([+-])([0-9]{2}):([0-9]{2})$ ]]; then
        return 1
    fi

    sign="${BASH_REMATCH[1]}"
    hours=$((10#${BASH_REMATCH[2]}))
    minutes="${BASH_REMATCH[3]}"

    case "$minutes" in
        00) value="$hours" ;;
        15) value="${hours}.25" ;;
        30) value="${hours}.5" ;;
        45) value="${hours}.75" ;;
        *) return 1 ;;
    esac

    [[ "$sign" == "-" ]] && value="-$value"
    printf '%s' "$value"
}

apply_timezone_choice() {
    local configured_timezone="$1"

    if [[ "$configured_timezone" =~ ^UTC[+-][0-9]{2}:[0-9]{2}$ ]]; then
        WP_TIMEZONE="$configured_timezone"
        WP_GMT_OFFSET=$(timezone_display_to_gmt_offset "$configured_timezone")
    else
        WP_TIMEZONE="$configured_timezone"
        WP_GMT_OFFSET=""
    fi
}

select_locale_prompt() {
    local detected_locale="$1"
    local locale_input=""
    local locale_selection=""
    local entry locale_code locale_label
    local -a locale_entries=()
    local -A seen_locales=()

    read -rp "$(echo -e "${CYAN}Use detected locale${NC} [$detected_locale]? [Y/n]: ")" locale_input
    if [[ ! "${locale_input:-}" =~ ^[Nn]$ ]]; then
        WP_LOCALE="$detected_locale"
        return 0
    fi

    locale_entries+=("$detected_locale|Detected system default")
    seen_locales["$detected_locale"]=1

    while IFS='|' read -r locale_code locale_label; do
        [[ -z "$locale_code" ]] && continue
        [[ -n "${seen_locales[$locale_code]:-}" ]] && continue
        locale_entries+=("$locale_code|$locale_label")
        seen_locales["$locale_code"]=1
    done <<'EOF'
en_US|English (United States)
en_CA|English (Canada)
fr_CA|French (Canada)
es_MX|Spanish (Mexico)
fr_FR|French (France)
es_ES|Spanish (Spain)
de_DE|German
it_IT|Italian
pt_BR|Portuguese (Brazil)
pt_PT|Portuguese (Portugal)
nl_NL|Dutch
sv_SE|Swedish
da_DK|Danish
fi|Finnish
nb_NO|Norwegian (Bokmal)
pl_PL|Polish
cs_CZ|Czech
hu_HU|Hungarian
ro_RO|Romanian
tr_TR|Turkish
ru_RU|Russian
uk|Ukrainian
he_IL|Hebrew
ar|Arabic
ja|Japanese
ko_KR|Korean
zh_CN|Chinese (China)
zh_TW|Chinese (Taiwan)
EOF

    echo ""
    print_info "Select a WordPress locale code:"
    for i in "${!locale_entries[@]}"; do
        entry="${locale_entries[$i]}"
        locale_code="${entry%%|*}"
        locale_label="${entry#*|}"
        printf "  %2d. %-10s %s\n" "$(( i + 1 ))" "$locale_code" "$locale_label"
    done

    while true; do
        read -rp "Choose locale [1]: " locale_selection
        locale_selection="${locale_selection:-1}"
        if [[ "$locale_selection" =~ ^[0-9]+$ ]] && (( locale_selection >= 1 && locale_selection <= ${#locale_entries[@]} )); then
            WP_LOCALE="${locale_entries[$(( locale_selection - 1 ))]%%|*}"
            return 0
        fi
        print_warn "Please enter a valid locale option number."
    done
}

select_timezone_prompt() {
    local detected_timezone="$1"
    local timezone_input=""
    local timezone_selection=""
    local timezone_display=""
    local offset_value
    local -a timezone_entries=("$detected_timezone")

    read -rp "$(echo -e "${CYAN}Use detected timezone${NC} [$detected_timezone]? [Y/n]: ")" timezone_input
    if [[ ! "${timezone_input:-}" =~ ^[Nn]$ ]]; then
        WP_TIMEZONE="$detected_timezone"
        WP_GMT_OFFSET=""
        return 0
    fi

    while IFS= read -r offset_value; do
        [[ -z "$offset_value" ]] && continue
        timezone_entries+=("$(wp_offset_display_from_value "$offset_value")")
    done <<'EOF'
-12
-11.5
-11
-10.5
-10
-9.5
-9
-8.5
-8
-7.5
-7
-6.5
-6
-5.5
-5
-4.5
-4
-3.5
-3
-2.5
-2
-1.5
-1
-0.5
0
0.5
1
1.5
2
2.5
3
3.5
4
4.5
5
5.5
5.75
6
6.5
7
7.5
8
8.5
8.75
9
9.5
10
10.5
11
11.5
12
12.75
13
13.75
14
EOF

    echo ""
    print_info "Select a timezone or UTC offset:"
    for i in "${!timezone_entries[@]}"; do
        timezone_display="${timezone_entries[$i]}"
        if (( i == 0 )); then
            printf "  %2d. %s (detected system default)\n" "$(( i + 1 ))" "$timezone_display"
        else
            printf "  %2d. %s\n" "$(( i + 1 ))" "$timezone_display"
        fi
    done

    while true; do
        read -rp "Choose timezone [1]: " timezone_selection
        timezone_selection="${timezone_selection:-1}"
        if [[ "$timezone_selection" =~ ^[0-9]+$ ]] && (( timezone_selection >= 1 && timezone_selection <= ${#timezone_entries[@]} )); then
            timezone_display="${timezone_entries[$(( timezone_selection - 1 ))]}"
            if (( timezone_selection == 1 )); then
                WP_TIMEZONE="$detected_timezone"
                WP_GMT_OFFSET=""
            else
                WP_TIMEZONE="$timezone_display"
                WP_GMT_OFFSET=$(timezone_display_to_gmt_offset "$timezone_display")
            fi
            return 0
        fi
        print_warn "Please enter a valid timezone option number."
    done
}

prompt_instance_config() {
    step 4 "Instance configuration..."
    finish_progress_bar
    echo ""

    local default_name="wordpress-$(get_next_instance_number)"
    local default_port
    local detected_locale
    local detected_timezone
    local configured_domain=""
    local hostname_input=""
    local wp_debug_override=""
    local seo_override=""
    default_port=$(get_next_port)
    detected_locale=$(detect_system_locale)
    detected_timezone=$(detect_system_timezone)
    configured_domain="$(global_config_get DOMAIN)"

    # Instance name
    if global_config_has_value INSTANCE_NAME; then
        INSTANCE_NAME="$(global_config_get INSTANCE_NAME)"
        print_info "Using instance name from $GLOBAL_ENV_FILE: $INSTANCE_NAME"
    else
        read -rp "$(echo -e "${CYAN}Instance name${NC} [$default_name]: ")" INSTANCE_NAME
        INSTANCE_NAME="${INSTANCE_NAME:-$default_name}"
    fi
    # Sanitize: lowercase, alphanumeric and hyphens only
    INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

    # Check if exists
    if [[ -d "$INSTANCES_DIR/$INSTANCE_NAME" ]]; then
        print_warn "Instance '$INSTANCE_NAME' already exists."
        read -rp "Rebuild/restart it? (y/n): " rebuild
        if [[ "$rebuild" != "y" ]]; then
            print_info "Aborting."
            exit 0
        fi
    fi

    # Port
    if global_config_has_value WP_PORT; then
        WP_PORT="$(global_config_get WP_PORT)"
        if ! validate_port_value "$WP_PORT"; then
            print_error "Invalid WP_PORT override '$WP_PORT' in $GLOBAL_ENV_FILE"
            exit 1
        fi
        if port_is_in_use "$WP_PORT"; then
            print_error "Configured WP_PORT '$WP_PORT' is already in use"
            exit 1
        fi
        print_info "Using HTTP port from $GLOBAL_ENV_FILE: $WP_PORT"
    else
        read -rp "$(echo -e "${CYAN}HTTP port${NC} [$default_port]: ")" WP_PORT
        WP_PORT="${WP_PORT:-$default_port}"
    fi

    # ── Public hostname (Cloudflare tunnel exposure) ─────────────
    # This hostname is routed via:
    #   cloudflared tunnel route dns $CF_TUNNEL_NAME <hostname>
    # An ingress rule is added to /etc/cloudflared/config.yaml pointing
    # to localhost:$WP_PORT and the cloudflared service is restarted.
    # WordPress wp-config.php is set to https://<hostname> for SSL.
    if [[ -n "${CF_TUNNEL_NAME:-}" ]]; then
        echo ""
        print_info "Tunnel active: ${BOLD}$CF_TUNNEL_NAME${NC}"
        print_info "The public hostname you enter will be:"
        print_info "  • Exposed via:  cloudflared tunnel route dns $CF_TUNNEL_NAME <hostname>"
        print_info "  • Ingress rule: <hostname> → localhost:$WP_PORT"
        print_info "  • WordPress:    https://<hostname>  (Cloudflare handles SSL)"
        echo ""
        if global_config_has_value CF_HOSTNAME; then
            CF_HOSTNAME="$(global_config_get CF_HOSTNAME)"
            print_info "Using hostname from $GLOBAL_ENV_FILE: $CF_HOSTNAME"
        elif [[ -n "$configured_domain" ]]; then
            while true; do
                read -rp "$(echo -e "${CYAN}Subdomain or full hostname${NC} (e.g. myblog or myblog.${configured_domain}): ")" hostname_input
                hostname_input=$(trim_whitespace "$hostname_input")
                [[ -n "$hostname_input" ]] && break
                print_warn "A public hostname is required."
            done
            if [[ "$hostname_input" == *.* ]]; then
                CF_HOSTNAME="$hostname_input"
            else
                CF_HOSTNAME="${hostname_input}.${configured_domain}"
            fi
        else
            while true; do
                read -rp "$(echo -e "${CYAN}Public hostname${NC} (e.g. myblog.yourdomain.com): ")" CF_HOSTNAME
                CF_HOSTNAME=$(trim_whitespace "$CF_HOSTNAME")
                [[ "$CF_HOSTNAME" == *.* ]] && break
                print_warn "Enter a fully qualified hostname (must contain a dot, e.g. blog.example.com)."
            done
        fi
        print_success "Public URL: https://$CF_HOSTNAME"
    else
        CF_HOSTNAME=""
    fi

    # Site title
    if global_config_has_value WP_SITE_TITLE; then
        WP_SITE_TITLE="$(global_config_get WP_SITE_TITLE)"
        print_info "Using site title from $GLOBAL_ENV_FILE: $WP_SITE_TITLE"
    else
        read -rp "$(echo -e "${CYAN}Site title${NC} [My WordPress Site]: ")" WP_SITE_TITLE
        WP_SITE_TITLE="${WP_SITE_TITLE:-My WordPress Site}"
    fi

    # Admin user
    if global_config_has_value WP_ADMIN_USER; then
        WP_ADMIN_USER="$(global_config_get WP_ADMIN_USER)"
        print_info "Using admin username from $GLOBAL_ENV_FILE: $WP_ADMIN_USER"
    else
        read -rp "$(echo -e "${CYAN}Admin username${NC} [admin]: ")" WP_ADMIN_USER
        WP_ADMIN_USER="${WP_ADMIN_USER:-admin}"
    fi

    # Admin password
    if global_config_has_value WP_ADMIN_PASSWORD; then
        WP_ADMIN_PASSWORD="$(global_config_get WP_ADMIN_PASSWORD)"
        print_info "Using admin password from $GLOBAL_ENV_FILE"
    else
        read -rsp "$(echo -e "${CYAN}Admin password${NC} [blank=random]: ")" WP_ADMIN_PASSWORD
        echo ""
        if [[ -z "$WP_ADMIN_PASSWORD" ]]; then
            WP_ADMIN_PASSWORD=$(openssl rand -hex 16)
            print_info "Generated random admin password (saved in .env)"
        fi
    fi

    # Admin email
    if global_config_has_value WP_ADMIN_EMAIL; then
        WP_ADMIN_EMAIL="$(global_config_get WP_ADMIN_EMAIL)"
        if [[ ! "$WP_ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
            print_warn "Invalid WP_ADMIN_EMAIL in $GLOBAL_ENV_FILE; prompting instead"
            WP_ADMIN_EMAIL=""
        else
            print_info "Using admin email from $GLOBAL_ENV_FILE: $WP_ADMIN_EMAIL"
        fi
    fi
    while [[ -z "$WP_ADMIN_EMAIL" ]]; do
        read -rp "$(echo -e "${CYAN}Admin email${NC}: ")" WP_ADMIN_EMAIL
        if [[ "$WP_ADMIN_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
            break
        fi
        WP_ADMIN_EMAIL=""
        print_warn "Please enter a valid email address."
    done

    # Locale
    if global_config_has_value WP_LOCALE; then
        WP_LOCALE="$(global_config_get WP_LOCALE)"
        print_info "Using locale from $GLOBAL_ENV_FILE: $WP_LOCALE"
    else
        select_locale_prompt "$detected_locale"
    fi

    # Timezone
    if global_config_has_value WP_TIMEZONE; then
        apply_timezone_choice "$(global_config_get WP_TIMEZONE)"
        print_info "Using timezone from $GLOBAL_ENV_FILE: $WP_TIMEZONE"
    else
        select_timezone_prompt "$detected_timezone"
    fi

    # WP_DEBUG
    if global_config_has_value WP_DEBUG; then
        if wp_debug_override=$(parse_bool_value "$(global_config_get WP_DEBUG)"); then
            WP_DEBUG="$wp_debug_override"
            print_info "Using WP_DEBUG from $GLOBAL_ENV_FILE: $WP_DEBUG"
        else
            print_warn "Invalid WP_DEBUG in $GLOBAL_ENV_FILE; prompting instead"
            WP_DEBUG=""
        fi
    fi
    if [[ -z "${WP_DEBUG:-}" ]]; then
        read -rp "$(echo -e "${CYAN}Enable WP_DEBUG?${NC} [y/N]: ")" wp_debug_input
        WP_DEBUG="false"
        [[ "${wp_debug_input:-}" =~ ^[Yy] ]] && WP_DEBUG="true"
    fi

    # Search engine visibility
    if global_config_has_value WP_BLOG_PUBLIC; then
        if seo_override=$(parse_bool_value "$(global_config_get WP_BLOG_PUBLIC)"); then
            if [[ "$seo_override" == "true" ]]; then
                WP_BLOG_PUBLIC="1"
            else
                WP_BLOG_PUBLIC="0"
            fi
            print_info "Using WP_BLOG_PUBLIC from $GLOBAL_ENV_FILE: $WP_BLOG_PUBLIC"
        else
            print_warn "Invalid WP_BLOG_PUBLIC in $GLOBAL_ENV_FILE; prompting instead"
            WP_BLOG_PUBLIC=""
        fi
    fi
    if [[ -z "${WP_BLOG_PUBLIC:-}" ]]; then
        read -rp "$(echo -e "${CYAN}Search engine visibility?${NC} [Y/n]: ")" seo_input
        WP_BLOG_PUBLIC="1"
        [[ "${seo_input:-}" =~ ^[Nn] ]] && WP_BLOG_PUBLIC="0"
    fi

    echo ""
    print_success "Instance configured: $INSTANCE_NAME on port $WP_PORT"
    print_info "Locale: $WP_LOCALE | Timezone: $WP_TIMEZONE"
}

# ── Credential Generation ────────────────────────────────
generate_credentials() {
    step 6 "Generating credentials..."

    local creds_path="$CREDS_DIR/$INSTANCE_NAME"

    # Check for existing credentials
    if sudo test -f "$creds_path/.env" 2>/dev/null; then
        print_warn "Credentials file already exists: $creds_path/.env"
        read -rp "Overwrite? (y/n): " overwrite
        if [[ "$overwrite" != "y" ]]; then
            print_info "Keeping existing credentials."
            # Source existing values
            eval "$(sudo cat "$creds_path/.env" | grep -E '^(MYSQL_|WP_TABLE_PREFIX|WP_PUBLIC_URL)')"
            return 0
        fi
    fi

    # Generate random values unless a root-level .env override provides them.
    MYSQL_ROOT_PASSWORD="$(global_config_get MYSQL_ROOT_PASSWORD)"
    [[ -n "$MYSQL_ROOT_PASSWORD" ]] || MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)

    MYSQL_PASSWORD="$(global_config_get MYSQL_PASSWORD)"
    [[ -n "$MYSQL_PASSWORD" ]] || MYSQL_PASSWORD=$(openssl rand -hex 16)

    WP_TABLE_PREFIX="$(global_config_get WP_TABLE_PREFIX)"
    [[ -n "$WP_TABLE_PREFIX" ]] || WP_TABLE_PREFIX="wp_$(openssl rand -hex 2)_"

    MYSQL_DATABASE="$(global_config_get MYSQL_DATABASE)"
    [[ -n "$MYSQL_DATABASE" ]] || MYSQL_DATABASE="wordpress_$(echo "$INSTANCE_NAME" | tr '-' '_')"

    MYSQL_USER="$(global_config_get MYSQL_USER)"
    [[ -n "$MYSQL_USER" ]] || MYSQL_USER="wp_$(echo "$INSTANCE_NAME" | tr '-' '_')"

    # Public URL
    WP_PUBLIC_URL=""
    [[ -n "$CF_HOSTNAME" ]] && WP_PUBLIC_URL="https://$CF_HOSTNAME"

    # ── WORDPRESS_CONFIG_EXTRA: PHP injected into wp-config.php ──
    # Cloudflare tunnel architecture:
    #   Browser → Cloudflare CDN (HTTPS/443)
    #           → cloudflared encrypted tunnel
    #           → localhost:WP_PORT (HTTP)  ← WordPress container
    # Cloudflare sets X-Forwarded-Proto: https on every request.
    # Dollar signs below are escaped as \$ so bash keeps them literal;
    # escape_compose_dollars then doubles them ($→$$) for the .env file
    # so Docker Compose passes them through to the container as plain $.
    local raw_config_extra="" config_extra=""

    # 1. SSL detection — mark the PHP request as HTTPS so WordPress stops
    #    issuing http:// redirects. Trust Cloudflare's forwarded headers:
    #      HTTP_X_FORWARDED_PROTO  — standard proxy header (Cloudflare CDN)
    #      HTTP_CF_VISITOR          — legacy Cloudflare SSL indicator (JSON)
    raw_config_extra+="if (!empty(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && 'https' === \$_SERVER['HTTP_X_FORWARDED_PROTO']) { \$_SERVER['HTTPS'] = 'on'; } "
    raw_config_extra+="elseif (!empty(\$_SERVER['HTTP_CF_VISITOR'])) { \$_cfv = json_decode(\$_SERVER['HTTP_CF_VISITOR'], true); if (!empty(\$_cfv['scheme']) && 'https' === \$_cfv['scheme']) { \$_SERVER['HTTPS'] = 'on'; } } "

    # 2. WP_HOME / WP_SITEURL — use the hardcoded public HTTPS URL for all
    #    non-loopback requests so WordPress never auto-redirects to http://.
    #    Loopback access (localhost / 127.0.0.1) keeps http:// for local dev.
    raw_config_extra+="\$_wp_h = preg_replace('/:\\d+\$/', '', \$_SERVER['HTTP_HOST'] ?? ''); "
    if [[ -n "$CF_HOSTNAME" ]]; then
        raw_config_extra+="if (in_array(\$_wp_h, ['localhost', '127.0.0.1', '[::1]'], true)) { "
        raw_config_extra+="define('WP_HOME', 'http://' . (\$_SERVER['HTTP_HOST'] ?? 'localhost')); "
        raw_config_extra+="define('WP_SITEURL', 'http://' . (\$_SERVER['HTTP_HOST'] ?? 'localhost')); "
        raw_config_extra+="} else { "
        raw_config_extra+="define('WP_HOME', 'https://${CF_HOSTNAME}'); "
        raw_config_extra+="define('WP_SITEURL', 'https://${CF_HOSTNAME}'); "
        raw_config_extra+="define('FORCE_SSL_ADMIN', true); "
        raw_config_extra+="} "
    else
        raw_config_extra+="if (\$_wp_h !== '') { "
        raw_config_extra+="define('WP_HOME', 'http://' . (\$_SERVER['HTTP_HOST'] ?? 'localhost')); "
        raw_config_extra+="define('WP_SITEURL', 'http://' . (\$_SERVER['HTTP_HOST'] ?? 'localhost')); "
        raw_config_extra+="} "
    fi

    # 3. Memory limit
    raw_config_extra+="define('WP_MEMORY_LIMIT', '256M');"

    config_extra=$(escape_compose_dollars "$raw_config_extra")

    # Generate salts
    local wp_auth_key wp_secure_auth_key wp_logged_in_key wp_nonce_key
    local wp_auth_salt wp_secure_auth_salt wp_logged_in_salt wp_nonce_salt
    wp_auth_key="$(global_config_get WP_AUTH_KEY)"
    [[ -n "$wp_auth_key" ]] || wp_auth_key=$(openssl rand -base64 48)

    wp_secure_auth_key="$(global_config_get WP_SECURE_AUTH_KEY)"
    [[ -n "$wp_secure_auth_key" ]] || wp_secure_auth_key=$(openssl rand -base64 48)

    wp_logged_in_key="$(global_config_get WP_LOGGED_IN_KEY)"
    [[ -n "$wp_logged_in_key" ]] || wp_logged_in_key=$(openssl rand -base64 48)

    wp_nonce_key="$(global_config_get WP_NONCE_KEY)"
    [[ -n "$wp_nonce_key" ]] || wp_nonce_key=$(openssl rand -base64 48)

    wp_auth_salt="$(global_config_get WP_AUTH_SALT)"
    [[ -n "$wp_auth_salt" ]] || wp_auth_salt=$(openssl rand -base64 48)

    wp_secure_auth_salt="$(global_config_get WP_SECURE_AUTH_SALT)"
    [[ -n "$wp_secure_auth_salt" ]] || wp_secure_auth_salt=$(openssl rand -base64 48)

    wp_logged_in_salt="$(global_config_get WP_LOGGED_IN_SALT)"
    [[ -n "$wp_logged_in_salt" ]] || wp_logged_in_salt=$(openssl rand -base64 48)

    wp_nonce_salt="$(global_config_get WP_NONCE_SALT)"
    [[ -n "$wp_nonce_salt" ]] || wp_nonce_salt=$(openssl rand -base64 48)

    # Write .env
    run_sudo mkdir -p "$creds_path"
    sudo tee "$creds_path/.env" > /dev/null <<ENVEOF
# WordPress Instance: $INSTANCE_NAME
# Generated: $(date -Iseconds)

INSTANCE_NAME=$INSTANCE_NAME
WP_PORT=$WP_PORT
WP_PUBLIC_URL=$WP_PUBLIC_URL
CF_TUNNEL_NAME=${CF_TUNNEL_NAME:-}
CF_HOSTNAME=${CF_HOSTNAME:-}

MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
MYSQL_DATABASE=$MYSQL_DATABASE
MYSQL_USER=$MYSQL_USER
MYSQL_PASSWORD=$MYSQL_PASSWORD

WP_TABLE_PREFIX=$WP_TABLE_PREFIX
WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_PASSWORD=$WP_ADMIN_PASSWORD
WP_ADMIN_EMAIL=$WP_ADMIN_EMAIL
WP_SITE_TITLE=$WP_SITE_TITLE
WP_LOCALE=$WP_LOCALE
WP_TIMEZONE=$WP_TIMEZONE
WP_GMT_OFFSET=$WP_GMT_OFFSET
WP_BLOG_PUBLIC=$WP_BLOG_PUBLIC
WP_DEBUG=$WP_DEBUG

WP_AUTH_KEY=$wp_auth_key
WP_SECURE_AUTH_KEY=$wp_secure_auth_key
WP_LOGGED_IN_KEY=$wp_logged_in_key
WP_NONCE_KEY=$wp_nonce_key
WP_AUTH_SALT=$wp_auth_salt
WP_SECURE_AUTH_SALT=$wp_secure_auth_salt
WP_LOGGED_IN_SALT=$wp_logged_in_salt
WP_NONCE_SALT=$wp_nonce_salt

WP_CONFIG_EXTRA=${config_extra}
ENVEOF

    run_sudo chmod 600 "$creds_path/.env"
    log_info "Credentials written to $creds_path/.env"
    print_success "Credentials saved to $creds_path/.env"
}

# ── Directory Setup ──────────────────────────────────────
setup_directories() {
    step 5 "Setting up directories..."
    local instance_dir="$INSTANCES_DIR/$INSTANCE_NAME"
    mkdir -p "$instance_dir"/{wp-data,db-data,backups}
    LOG_FILE="$instance_dir/deploy.log"
    touch "$LOG_FILE"
    run_sudo chown -R 33:33 "$instance_dir/wp-data"
    run_sudo chmod 775 "$instance_dir/wp-data"
    log_info "Instance directory created: $instance_dir"
    print_success "Directory: $instance_dir"
    print_info "Log file: $LOG_FILE"
}

# ── Docker Compose Generation ────────────────────────────
generate_compose() {
    step 7 "Generating docker-compose.yml..."
    local instance_dir="$INSTANCES_DIR/$INSTANCE_NAME"
    local creds_path="$CREDS_DIR/$INSTANCE_NAME/.env"

    cat > "$instance_dir/docker-compose.yml" <<COMPOSEYAML
services:
  mysql:
    image: mysql:8.4
    container_name: ${INSTANCE_NAME}-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - ./db-data:/var/lib/mysql
    networks:
      - ${INSTANCE_NAME}-net
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 12
      start_period: 10s

  wordpress:
    image: wordpress:latest
    container_name: ${INSTANCE_NAME}-wordpress
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
    ports:
      - "${WP_PORT}:80"
    environment:
      WORDPRESS_DB_HOST: ${INSTANCE_NAME}-mysql
      WORDPRESS_DB_USER: \${MYSQL_USER}
      WORDPRESS_DB_PASSWORD: \${MYSQL_PASSWORD}
      WORDPRESS_DB_NAME: \${MYSQL_DATABASE}
      WORDPRESS_TABLE_PREFIX: \${WP_TABLE_PREFIX}
      WORDPRESS_AUTH_KEY: \${WP_AUTH_KEY}
      WORDPRESS_SECURE_AUTH_KEY: \${WP_SECURE_AUTH_KEY}
      WORDPRESS_LOGGED_IN_KEY: \${WP_LOGGED_IN_KEY}
      WORDPRESS_NONCE_KEY: \${WP_NONCE_KEY}
      WORDPRESS_AUTH_SALT: \${WP_AUTH_SALT}
      WORDPRESS_SECURE_AUTH_SALT: \${WP_SECURE_AUTH_SALT}
      WORDPRESS_LOGGED_IN_SALT: \${WP_LOGGED_IN_SALT}
      WORDPRESS_NONCE_SALT: \${WP_NONCE_SALT}
      WORDPRESS_DEBUG: \${WP_DEBUG}
      WORDPRESS_CONFIG_EXTRA: \${WP_CONFIG_EXTRA}
    volumes:
      - ./wp-data:/var/www/html
    networks:
      - ${INSTANCE_NAME}-net

networks:
  ${INSTANCE_NAME}-net:
    name: ${INSTANCE_NAME}-net
COMPOSEYAML

    log_info "docker-compose.yml written to $instance_dir"
    print_success "docker-compose.yml generated"
}

# ── Docker Deploy ────────────────────────────────────────
deploy_containers() {
    local instance_dir="$INSTANCES_DIR/$INSTANCE_NAME"

    # Pull latest images — run in background so the bar can animate.
    step 8 "Pulling MySQL 8.4 image..."
    dc "$instance_dir" pull mysql &
    progress_ticker "${_STEP_END[7]}" "${_STEP_END[8]}" "Pulling MySQL 8.4 image..." $! || {
        print_error "Failed to pull mysql:8.4"
        exit 1
    }
    print_success "mysql:8.4 pulled"

    step 9 "Pulling WordPress image..."
    dc "$instance_dir" pull wordpress &
    progress_ticker "${_STEP_END[8]}" "${_STEP_END[9]}" "Pulling WordPress image..." $! || {
        print_error "Failed to pull wordpress:latest"
        exit 1
    }
    print_success "wordpress:latest pulled"

    # Start containers — fast enough to not need a ticker
    step 10 "Starting containers..."
    dc "$instance_dir" up -d
    print_success "Containers started"
}

wait_for_mysql() {
    step 11 "Waiting for MySQL..."
    local timeout=60
    local elapsed=0

    # Phase 1: daemon liveness (mysqladmin ping)
    while (( elapsed < timeout )); do
        if sudo docker exec "${INSTANCE_NAME}-mysql" mysqladmin ping -h localhost --silent 2>/dev/null; then
            break
        fi
        sleep 2
        (( elapsed += 2 ))
        local pct=$(( ${_STEP_END[10]} + (elapsed * (${_STEP_END[11]} - ${_STEP_END[10]}) / timeout) ))
        progress_bar "$pct" "Waiting for MySQL daemon... (${elapsed}s/${timeout}s)"
    done
    if (( elapsed >= timeout )); then
        print_error "MySQL failed to start within ${timeout}s"
        log_error "MySQL health check timeout after ${timeout}s"
        return 1
    fi

    # Phase 2: wait for the WordPress user + database to be initialized.
    # MySQL's entrypoint init scripts run after the daemon starts, so
    # the user may not exist yet even though the ping passed.
    local user_timeout=60
    local user_elapsed=0
    while (( user_elapsed < user_timeout )); do
        if sudo docker exec "${INSTANCE_NAME}-mysql" \
               mysql -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" \
               "${MYSQL_DATABASE}" -e "SELECT 1" 2>/dev/null | grep -q 1; then
            print_success "MySQL is ready (user verified)"
            return 0
        fi
        sleep 2
        (( user_elapsed += 2 ))
        local pct2=$(( ${_STEP_END[10]} + ((elapsed + user_elapsed) * (${_STEP_END[11]} - ${_STEP_END[10]}) / (timeout + user_timeout)) ))
        progress_bar "$pct2" "Waiting for MySQL user init... (${user_elapsed}s)"
    done
    print_error "MySQL user '${MYSQL_USER}' not ready after ${user_timeout}s"
    log_error "MySQL user init timeout after ${user_timeout}s"
    return 1
}

wait_for_wordpress() {
    step 12 "Waiting for WordPress..."
    local timeout=120
    local elapsed=0
    while (( elapsed < timeout )); do
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${WP_PORT}" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" || "$http_code" == "302" || "$http_code" == "301" ]]; then
            print_success "WordPress is responding (HTTP $http_code)"
            return 0
        fi
        sleep 3
        (( elapsed += 3 ))
        local pct=$(( ${_STEP_END[11]} + (elapsed * (${_STEP_END[12]} - ${_STEP_END[11]}) / timeout) ))
        progress_bar "$pct" "Waiting for WordPress... (${elapsed}s, HTTP $http_code)"
    done
    print_error "WordPress failed to respond within ${timeout}s"
    log_error "WordPress health check timeout after ${timeout}s"
    return 1
}

run_wp_cli_install() {
    step 13 "Running WP-CLI setup..."

    local db_host="${INSTANCE_NAME}-mysql"
    local url="${WP_PUBLIC_URL:-http://localhost:${WP_PORT}}"

    # Build a WP-CLI env file with all the env vars the WordPress container has
    # This ensures WP-CLI sees the same table prefix, salts, DB settings, etc.
    local cli_env
    cli_env=$(mktemp /tmp/wp-cli-env-XXXXXX)
    {
        echo "WORDPRESS_DB_HOST=${db_host}"
        echo "WORDPRESS_DB_USER=${MYSQL_USER}"
        echo "WORDPRESS_DB_PASSWORD=${MYSQL_PASSWORD}"
        echo "WORDPRESS_DB_NAME=${MYSQL_DATABASE}"
        echo "WORDPRESS_TABLE_PREFIX=${WP_TABLE_PREFIX}"
        # Filter out WP_CONFIG_EXTRA from the creds file (has special chars)
        # and remap WP_ salt vars to WORDPRESS_ prefix for the Docker image
        sudo cat "$CREDS_DIR/$INSTANCE_NAME/.env" | grep '^WP_AUTH_KEY\|^WP_SECURE_AUTH_KEY\|^WP_LOGGED_IN_KEY\|^WP_NONCE_KEY\|^WP_AUTH_SALT\|^WP_SECURE_AUTH_SALT\|^WP_LOGGED_IN_SALT\|^WP_NONCE_SALT' | sed 's/^WP_/WORDPRESS_/'
    } > "$cli_env"

    # Helper to run WP-CLI with the correct env
    run_wpcli() {
        sudo docker run --rm \
            --network "${INSTANCE_NAME}-net" \
            --volumes-from "${INSTANCE_NAME}-wordpress" \
            --user 33:33 \
            --env-file "$cli_env" \
            wordpress:cli \
            "$@"
    }

    # wp core install — run in background so the bar animates.
    # This step spans _STEP_END[12]=74 → ~82% (leaving ~4 pts for options).
    local core_install_end=$(( ${_STEP_END[12]} + 8 ))
    log_info "Running wp core install..."
    run_wpcli wp core install \
        --url="$url" \
        --title="$WP_SITE_TITLE" \
        --admin_user="$WP_ADMIN_USER" \
        --admin_password="$WP_ADMIN_PASSWORD" \
        --admin_email="$WP_ADMIN_EMAIL" \
        --skip-email \
        >> "$LOG_FILE" 2>&1 &
    local wp_core_pid=$!
    progress_ticker "${_STEP_END[12]}" "$core_install_end" "Installing WordPress core..." "$wp_core_pid" || {
        print_error "WP-CLI core install failed — check $LOG_FILE"
        rm -f "$cli_env"
        return 1
    }

    # Options — fast; tick 1% each so the bar visibly advances.
    local opt_pct=$core_install_end

    # Set timezone
    progress_bar "$opt_pct" "Setting timezone..."
    if [[ -n "${WP_GMT_OFFSET:-}" ]]; then
        run_wpcli wp option update timezone_string '' >> "$LOG_FILE" 2>&1 || true
        run_wpcli wp option update gmt_offset "$WP_GMT_OFFSET" >> "$LOG_FILE" 2>&1 || true
    else
        run_wpcli wp option update timezone_string "$WP_TIMEZONE" >> "$LOG_FILE" 2>&1 || true
    fi
    (( opt_pct++ ))

    # Set locale
    progress_bar "$opt_pct" "Setting locale..."
    if [[ "$WP_LOCALE" != "en_US" ]]; then
        run_wpcli wp language core install "$WP_LOCALE" --activate >> "$LOG_FILE" 2>&1 || true
    else
        run_wpcli wp site switch-language en_US >> "$LOG_FILE" 2>&1 || true
    fi
    (( opt_pct++ ))

    # Set search engine visibility (blog_public: 1=visible, 0=discourage)
    progress_bar "$opt_pct" "Configuring site settings..."
    run_wpcli wp option update blog_public "$WP_BLOG_PUBLIC" >> "$LOG_FILE" 2>&1 || true
    (( opt_pct++ ))

    # Ensure we land on the step-13 end boundary
    progress_bar "${_STEP_END[13]}" "WP-CLI setup complete"

    rm -f "$cli_env"
    print_success "WordPress installed and configured"
}

# ── Cloudflared Finalization ─────────────────────────────
finalize_cloudflared() {
    step 14 "Updating Cloudflare Tunnel..."

    if [[ -z "${CF_HOSTNAME:-}" ]]; then
        print_info "No Cloudflare hostname configured — skipping"
        return 0
    fi

    # Route DNS for this instance's public hostname
    cf_route_dns "$CF_TUNNEL_NAME" "$CF_HOSTNAME"

    # Append this instance's ingress rule to the existing config
    # (setup_cloudflared already ensured the config and service exist)
    cf_append_ingress "$CF_HOSTNAME" "$WP_PORT"

    # Restart service to pick up the new ingress rule
    print_info "Restarting cloudflared service..."
    run_sudo systemctl restart cloudflared 2>>"${LOG_FILE:-/dev/null}" || true

    cf_validate_all_configs
    print_success "Cloudflare Tunnel updated"
}

# ── Post-Deploy Verification ─────────────────────────────
verify_all_endpoints() {
    step 15 "Verifying all endpoints are live..."

    local local_url="http://localhost:${WP_PORT}"
    local public_url="${WP_PUBLIC_URL:-}"
    local timeout=300
    local elapsed=0
    local ingress_config
    ingress_config=$(cf_find_config "$CF_SERVICE_CONFIG_DIR")

    # Flush local DNS cache so the new CNAME resolves
    if command -v resolvectl &>/dev/null; then
        sudo resolvectl flush-caches 2>/dev/null || true
    elif command -v systemd-resolve &>/dev/null; then
        sudo systemd-resolve --flush-caches 2>/dev/null || true
    fi
    log_info "Flushed local DNS cache"

    if [[ -n "$public_url" && -f "$ingress_config" ]]; then
        log_cmd "cloudflared tunnel --config $ingress_config ingress rule $public_url"
        run_sudo cloudflared tunnel --config "$ingress_config" ingress rule "$public_url" >> "${LOG_FILE:-/tmp/wp-deploy-cloudflare.log}" 2>&1 || true
    fi

    resolve_authoritative_ipv4() {
        local hostname="$1"
        dig @1.1.1.1 +short A "$hostname" 2>/dev/null | head -n1
    }

    curl_endpoint_result() {
        local url="$1" endpoint_type="$2"
        local curl_result host authoritative_ip
        curl_result=$(curl -ksS -o /dev/null -w '%{http_code}|%{url_effective}' -L --max-redirs 5 --max-time 15 "$url" 2>/dev/null || printf '000|')

        if [[ "$endpoint_type" == "public" && "${curl_result%%|*}" == "000" ]]; then
            host="${url#https://}"
            host="${host%%/*}"
            authoritative_ip=$(resolve_authoritative_ipv4 "$host")
            if [[ -n "$authoritative_ip" ]]; then
                log_info "Retrying public endpoint via authoritative resolver: $host -> $authoritative_ip"
                curl_result=$(curl -ksS -o /dev/null -w '%{http_code}|%{url_effective}' -L --max-redirs 5 --max-time 15 \
                    --resolve "${host}:443:${authoritative_ip}" \
                    "$url" 2>/dev/null || printf '000|')
            fi
        fi

        printf '%s' "$curl_result"
    }

    # Define endpoints to check
    local -a endpoints=()
    endpoints+=("$local_url|Local root|local")
    endpoints+=("${local_url}/wp-admin/|Local wp-admin|local")
    if [[ -n "$public_url" ]]; then
        endpoints+=("${public_url}/|Public root|public")
        endpoints+=("${public_url}/wp-admin/|Public wp-admin|public")
    fi

    # Poll until all endpoints return healthy responses and resolve to the expected host.
    while (( elapsed < timeout )); do
        local all_ok=true
        local failed_ep="" failed_reason=""

        for ep_entry in "${endpoints[@]}"; do
            local url="${ep_entry%%|*}"
            local rest="${ep_entry#*|}"
            local label="${rest%%|*}"
            local endpoint_type="${ep_entry##*|}"
            local curl_result http_code effective_url expected_prefix
            expected_prefix="$local_url"
            [[ "$endpoint_type" == "public" ]] && expected_prefix="$public_url"

            curl_result=$(curl_endpoint_result "$url" "$endpoint_type")
            http_code="${curl_result%%|*}"
            effective_url="${curl_result#*|}"
            log_info "Endpoint check [$label] code=$http_code effective=$effective_url"

            if [[ "$http_code" == "000" || "$http_code" == "502" || "$http_code" == "503" || "$http_code" == "504" ]]; then
                all_ok=false
                failed_ep="$label (HTTP $http_code)"
                failed_reason="unreachable"
                break
            fi

            if [[ -z "$effective_url" || "$effective_url" != "$expected_prefix"* ]]; then
                all_ok=false
                failed_ep="$label"
                failed_reason="redirected to unexpected URL: ${effective_url:-unknown}"
                break
            fi
        done

        if $all_ok; then
            for ep_entry in "${endpoints[@]}"; do
                local url="${ep_entry%%|*}"
                local rest="${ep_entry#*|}"
                local label="${rest%%|*}"
                local curl_result http_code effective_url
                curl_result=$(curl_endpoint_result "$url" "${ep_entry##*|}")
                http_code="${curl_result%%|*}"
                effective_url="${curl_result#*|}"
                print_success "$label → HTTP $http_code [$effective_url]"
            done
            return 0
        fi

        sleep 5
        (( elapsed += 5 ))
        local pct=$(( ${_STEP_END[14]} + (elapsed * (${_STEP_END[15]} - ${_STEP_END[14]}) / timeout) ))
        [[ $pct -gt ${_STEP_END[15]} ]] && pct=${_STEP_END[15]}
        progress_bar "$pct" "Waiting for $failed_ep (${failed_reason})... (${elapsed}s/${timeout}s)"

        # Re-flush DNS every 30s
        if (( elapsed % 30 == 0 )); then
            if command -v resolvectl &>/dev/null; then
                sudo resolvectl flush-caches 2>/dev/null || true
            fi
        fi
    done

    # Timeout — show what we got and fail loudly.
    print_error "Endpoint verification failed after ${timeout}s:"
    for ep_entry in "${endpoints[@]}"; do
        local url="${ep_entry%%|*}"
        local rest="${ep_entry#*|}"
        local label="${rest%%|*}"
        local curl_result http_code effective_url
        curl_result=$(curl_endpoint_result "$url" "${ep_entry##*|}")
        http_code="${curl_result%%|*}"
        effective_url="${curl_result#*|}"
        print_warn "$label → HTTP $http_code [${effective_url:-$url}]"
    done
    return 1
}

# ── Final Report ─────────────────────────────────────────
repeat_char() {
    local char="$1"
    local count="$2"
    local out=""
    local i
    for ((i=0; i<count; i++)); do
        out+="$char"
    done
    printf '%s' "$out"
}

print_final_report() {
    step 16 "Done!"

    local local_url="http://localhost:${WP_PORT}"
    local public_url="${WP_PUBLIC_URL:-N/A}"
    local creds_path="$CREDS_DIR/$INSTANCE_NAME/.env"
    local log_path="$INSTANCES_DIR/$INSTANCE_NAME/deploy.log"
    local title="WordPress Instance Deployed!"
    local border=""
    local content_width=${#title}
    local line=""
    local -a report_lines=(
        "Instance: $INSTANCE_NAME"
        "Status: RUNNING"
        "Local: $local_url"
        "Public: $public_url"
        "Creds: $creds_path"
        "Log: $log_path"
    )

    for line in "${report_lines[@]}"; do
        if (( ${#line} > content_width )); then
            content_width=${#line}
        fi
    done

    finish_progress_bar
    border="+-$(repeat_char "-" "$content_width")-+"

    echo ""
    echo -e "${BOLD}${GREEN}"
    echo "$border"
    printf "| %-*s |\n" "$content_width" "$title"
    echo "$border"
    for line in "${report_lines[@]}"; do
        printf "| %-*s |\n" "$content_width" "$line"
    done
    echo "$border"
    echo -e "${NC}"

    # Open browser — use public URL if available, go straight to wp-admin
    local browser_url="$local_url/wp-admin/"
    [[ "$public_url" != "N/A" ]] && browser_url="${public_url}/wp-admin/"
    if command -v xdg-open &>/dev/null; then
        print_info "Opening browser at $browser_url ..."
        nohup xdg-open "$browser_url" &>/dev/null &
    fi
}

# ── Deploy Cleanup ───────────────────────────────────────
deploy_cleanup() {
    print_error "Deployment failed — cleaning up..."
    local instance_dir="$INSTANCES_DIR/${INSTANCE_NAME:-}"
    if [[ -n "${INSTANCE_NAME:-}" && -f "$instance_dir/docker-compose.yml" ]]; then
        local creds_path="$CREDS_DIR/$INSTANCE_NAME/.env"
        dc "$instance_dir" down 2>/dev/null || true
    fi
    print_error "Check log: ${LOG_FILE:-/tmp/wp-deploy.log}"
    exit 1
}

# ── Main Deploy Flow ────────────────────────────────────
cmd_deploy() {
    echo ""
    echo -e "${BOLD}${CYAN}═══ WordPress Docker Deploy v${SCRIPT_VERSION} ═══${NC}"
    echo ""

    # Initialize temp log
    LOG_FILE="/tmp/wp-deploy-$$.log"
    touch "$LOG_FILE"
    load_global_env_config

    detect_system
    check_dependencies
    setup_cloudflared
    prompt_instance_config

    setup_directories
    # Merge temp log now that the per-instance log exists
    if [[ -f "/tmp/wp-deploy-$$.log" ]]; then
        cat "/tmp/wp-deploy-$$.log" >> "$LOG_FILE"
        rm -f "/tmp/wp-deploy-$$.log"
    fi

    generate_credentials
    generate_compose

    # Deploy with cleanup trap
    trap 'deploy_cleanup' ERR
    deploy_containers
    wait_for_mysql
    wait_for_wordpress
    run_wp_cli_install
    trap - ERR

    finalize_cloudflared
    verify_all_endpoints
    print_final_report
}

# ── Lifecycle: list ──────────────────────────────────────
cmd_list() {
    echo ""
    echo -e "${BOLD}WordPress Instances${NC}"
    echo ""
    printf "%-20s %-12s %-6s %-28s %s\n" "NAME" "STATUS" "PORT" "LOCAL URL" "PUBLIC URL"
    printf "%-20s %-12s %-6s %-28s %s\n" "----" "------" "----" "---------" "----------"

    local found=false
    if [[ -d "$INSTANCES_DIR" ]]; then
        for dir in "$INSTANCES_DIR"/*/; do
            [[ ! -d "$dir" ]] && continue
            found=true
            local name
            name=$(basename "$dir")
            local port="?" public_url=""

            # Read creds
            if sudo test -f "$CREDS_DIR/$name/.env" 2>/dev/null; then
                port=$(sudo grep -oP '^WP_PORT=\K.*' "$CREDS_DIR/$name/.env" 2>/dev/null || echo "?")
                public_url=$(sudo grep -oP '^WP_PUBLIC_URL=\K.*' "$CREDS_DIR/$name/.env" 2>/dev/null || echo "")
            fi

            # Check container status
            local status
            if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}-wordpress$"; then
                status="${GREEN}running${NC}  "
            elif sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}-wordpress$"; then
                status="${YELLOW}stopped${NC}  "
            else
                status="${RED}gone${NC}     "
            fi

            printf "%-20s %-22b %-6s %-28s %s\n" "$name" "$status" "$port" "http://localhost:$port" "${public_url:-N/A}"
        done
    fi

    if ! $found; then
        print_info "No instances found."
    fi
    echo ""
}

# ── Lifecycle: stop ──────────────────────────────────────
cmd_stop() {
    local name="$1"
    local instance_dir="$INSTANCES_DIR/$name"
    local creds_path="$CREDS_DIR/$name/.env"

    if [[ ! -d "$instance_dir" ]]; then
        print_error "Instance '$name' not found"
        exit 1
    fi

    print_info "Stopping $name..."
    dc "$instance_dir" stop 2>&1
    print_success "Instance '$name' stopped"
}

# ── Lifecycle: start ─────────────────────────────────────
cmd_start() {
    local name="$1"
    local instance_dir="$INSTANCES_DIR/$name"
    local creds_path="$CREDS_DIR/$name/.env"

    if [[ ! -d "$instance_dir" ]]; then
        print_error "Instance '$name' not found"
        exit 1
    fi

    print_info "Pulling latest images..."
    dc "$instance_dir" pull 2>&1
    print_info "Starting $name..."
    dc "$instance_dir" up -d 2>&1
    print_success "Instance '$name' started"
}

# ── Lifecycle: destroy ───────────────────────────────────
cmd_destroy() {
    local name="$1"
    local instance_dir="$INSTANCES_DIR/$name"
    local creds_path="$CREDS_DIR/$name/.env"

    if [[ ! -d "$instance_dir" ]]; then
        print_error "Instance '$name' not found"
        exit 1
    fi

    # Read hostname and tunnel name before destruction
    local cf_hostname="" tunnel_name=""
    if sudo test -f "$creds_path" 2>/dev/null; then
        cf_hostname=$(sudo grep -oP '^CF_HOSTNAME=\K.*' "$creds_path" 2>/dev/null || echo "")
        tunnel_name=$(sudo grep -oP '^CF_TUNNEL_NAME=\K.*' "$creds_path" 2>/dev/null || echo "")
    fi

    echo ""
    print_warn "This will permanently destroy instance '$name':"
    print_warn "  - Docker containers and volumes"
    print_warn "  - Instance data ($instance_dir)"
    print_warn "  - Credentials ($creds_path)"
    [[ -n "$cf_hostname" ]] && print_warn "  - Cloudflare ingress for $cf_hostname"
    echo ""
    read -rp "Are you sure? (type 'yes' to confirm): " confirm
    if [[ "$confirm" != "yes" ]]; then
        print_info "Aborted."
        exit 0
    fi

    # Tear down containers
    print_info "Removing containers..."
    dc "$instance_dir" down -v 2>&1 || true

    # Remove CF ingress and DNS
    if [[ -n "$cf_hostname" ]]; then
        print_info "Removing Cloudflare ingress..."
        cf_remove_ingress "$cf_hostname"
        if [[ -n "$tunnel_name" ]]; then
            cf_remove_dns_route "$tunnel_name" "$cf_hostname"
        fi
        if systemctl is-active cloudflared &>/dev/null 2>&1; then
            sudo systemctl restart cloudflared 2>/dev/null
        fi
    fi

    # Remove directories (sudo needed — MySQL data files are owned by root)
    sudo rm -rf "$instance_dir"
    run_sudo rm -rf "$CREDS_DIR/$name"

    print_success "Instance '$name' destroyed"
}

# ── Backup ───────────────────────────────────────────────
cmd_backup() {
    local name="$1"
    local instance_dir="$INSTANCES_DIR/$name"
    local creds_path="$CREDS_DIR/$name/.env"

    if [[ ! -d "$instance_dir" ]]; then
        print_error "Instance '$name' not found"
        exit 1
    fi

    # Check containers are running
    if ! sudo docker ps --format '{{.Names}}' | grep -q "^${name}-mysql$"; then
        print_error "MySQL container not running. Start the instance first:"
        print_error "  ./wp-deploy.sh --start $name"
        exit 1
    fi

    # Read credentials
    eval "$(sudo cat "$creds_path" | grep -E '^(MYSQL_ROOT_PASSWORD|MYSQL_DATABASE)=')"

    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H-%M-%S')
    local backup_dir="$instance_dir/backups"
    local backup_file="$backup_dir/${name}-${timestamp}.tar.gz"
    mkdir -p "$backup_dir"

    # MySQL dump
    print_info "Dumping MySQL database..."
    sudo docker exec "${name}-mysql" mysqldump -u root -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" > "/tmp/${name}-dump.sql" 2>/dev/null

    # Copy .env to temp
    sudo cp "$creds_path" "/tmp/${name}-backup-env"

    # Create archive
    print_info "Creating archive..."
    tar -czf "$backup_file" \
        -C "$instance_dir" wp-data docker-compose.yml \
        -C /tmp "${name}-dump.sql" "${name}-backup-env"

    # Cleanup temp files
    rm -f "/tmp/${name}-dump.sql" "/tmp/${name}-backup-env"

    local size
    size=$(du -h "$backup_file" | cut -f1)
    echo ""
    print_success "Backup complete: $backup_file ($size)"
}

# ── Restore ──────────────────────────────────────────────
cmd_restore() {
    local name="$1"
    local archive="$2"
    local instance_dir="$INSTANCES_DIR/$name"
    local creds_path="$CREDS_DIR/$name/.env"

    if [[ ! -f "$archive" ]]; then
        print_error "Archive not found: $archive"
        exit 1
    fi

    # Stop existing instance if running
    if sudo docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}-wordpress$"; then
        print_info "Stopping existing instance..."
        dc "$instance_dir" stop 2>/dev/null || true
    fi

    # Create directories
    mkdir -p "$instance_dir"
    run_sudo mkdir -p "$CREDS_DIR/$name"

    # Extract archive
    print_info "Extracting archive..."
    tar -xzf "$archive" -C "$instance_dir"

    # Move credentials to correct location
    if [[ -f "$instance_dir/${name}-backup-env" ]]; then
        sudo mv "$instance_dir/${name}-backup-env" "$creds_path"
        run_sudo chmod 600 "$creds_path"
    fi

    # Move SQL dump to temp
    local dump_file=""
    if [[ -f "$instance_dir/${name}-dump.sql" ]]; then
        dump_file="/tmp/${name}-restore-dump.sql"
        mv "$instance_dir/${name}-dump.sql" "$dump_file"
    fi

    # Source credentials for compose
    eval "$(sudo cat "$creds_path" | grep -E '^(MYSQL_ROOT_PASSWORD|MYSQL_DATABASE|WP_PORT)=')"

    # Pull and start
    print_info "Pulling latest images..."
    dc "$instance_dir" pull 2>&1
    print_info "Starting containers..."
    dc "$instance_dir" up -d 2>&1

    # Wait for MySQL
    print_info "Waiting for MySQL..."
    local timeout=60 elapsed=0
    while (( elapsed < timeout )); do
        if sudo docker exec "${name}-mysql" mysqladmin ping -h localhost --silent 2>/dev/null; then
            break
        fi
        sleep 2
        (( elapsed += 2 ))
    done

    # Import dump
    if [[ -n "$dump_file" && -f "$dump_file" ]]; then
        print_info "Importing database..."
        sudo docker exec -i "${name}-mysql" mysql -u root -p"${MYSQL_ROOT_PASSWORD}" "${MYSQL_DATABASE}" < "$dump_file"
        rm -f "$dump_file"
    fi

    # Verify
    sleep 5
    local http_code
    http_code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${WP_PORT}" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" || "$http_code" == "302" || "$http_code" == "301" ]]; then
        print_success "Instance '$name' restored and running on port $WP_PORT"
    else
        print_warn "Instance started but WordPress returned HTTP $http_code — may need a moment"
    fi
}

# ── CLI Dispatch ─────────────────────────────────────────
usage() {
    cat <<EOF
WordPress Docker Deploy Script v${SCRIPT_VERSION}

Usage:
  wp-deploy.sh                          Deploy new WordPress instance
  wp-deploy.sh --list                   List all instances
  wp-deploy.sh --stop <name>            Stop instance
  wp-deploy.sh --start <name>           Start instance
  wp-deploy.sh --destroy <name>         Destroy instance
  wp-deploy.sh --backup <name>          Backup instance
  wp-deploy.sh --restore <name> <file>  Restore instance from backup
  wp-deploy.sh --help                   Show this help
EOF
}

main() {
    case "${1:-}" in
        --list)     cmd_list ;;
        --stop)     [[ -z "${2:-}" ]] && { print_error "Usage: --stop <name>"; exit 1; }; cmd_stop "$2" ;;
        --start)    [[ -z "${2:-}" ]] && { print_error "Usage: --start <name>"; exit 1; }; cmd_start "$2" ;;
        --destroy)  [[ -z "${2:-}" ]] && { print_error "Usage: --destroy <name>"; exit 1; }; cmd_destroy "$2" ;;
        --backup)   [[ -z "${2:-}" ]] && { print_error "Usage: --backup <name>"; exit 1; }; cmd_backup "$2" ;;
        --restore)  [[ -z "${2:-}" || -z "${3:-}" ]] && { print_error "Usage: --restore <name> <file>"; exit 1; }; cmd_restore "$2" "$3" ;;
        --help|-h)  usage; exit 0 ;;
        "")         cmd_deploy ;;
        *)          print_error "Unknown option: $1"; usage; exit 1 ;;
    esac
}

main "$@"
