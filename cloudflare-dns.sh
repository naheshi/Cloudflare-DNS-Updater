#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Symbols
CHECKMARK="${GREEN}✓${RESET}"
CROSS="${RED}✗${RESET}"
ARROW="${CYAN}→${RESET}"
SPINNER="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

# ============================================
# ANIMATION FUNCTIONS
# ============================================

spinner() {
    local pid=$1
    local message=$2
    local delay=0.1
    local i=0
    
    while ps -p $pid > /dev/null 2>&1; do
        local frame=${SPINNER:$i:1}
        printf "\r${CYAN}%s${RESET} %s" "$frame" "$message"
        i=$(( (i + 1) % ${#SPINNER} ))
        sleep $delay
    done
    printf "\r"
}

info() {
    echo -e "${ARROW} ${1}"
}

success() {
    echo -e "${CHECKMARK} ${GREEN}${1}${RESET}"
}

error() {
    echo -e "${CROSS} ${RED}${1}${RESET}"
}

warning() {
    echo -e "${YELLOW}⚠${RESET}  ${YELLOW}${1}${RESET}"
}

header() {
    echo -e "\n${BOLD}${BLUE}╭─────────────────────────────────────────╮${RESET}"
    echo -e "${BOLD}${BLUE}│${RESET} ${BOLD}$1${RESET}"
    echo -e "${BOLD}${BLUE}╰─────────────────────────────────────────╯${RESET}\n"
}

# ============================================
# PARSE ARGUMENTS
# ============================================

zone=""
cloudflare_api_token=""
subdomain=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --zone)
            zone="$2"
            shift 2
            ;;
        --token)
            cloudflare_api_token="$2"
            shift 2
            ;;
        --subdomain)
            subdomain="$2"
            shift 2
            ;;
        --help)
            header "Cloudflare DNS Updater"
            echo "Usage: $0 --zone <domain> --subdomain <subdomain> --token <value>"
            echo ""
            echo "Example:"
            echo "  $0 --zone example.com --subdomain mail --token your_token"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

cloudflare_api_token=$(echo "$cloudflare_api_token" | tr -d '[:space:]')

if [[ -z "$zone" || -z "$cloudflare_api_token" ]]; then
    error "Missing required parameters"
    echo "Usage: $0 --zone <domain> --subdomain <subdomain> --token <value>"
    exit 1
fi

if ! [[ "$zone" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)+$ ]]; then
    error "Invalid zone format: $zone"
    exit 1
fi

if [[ -n "$subdomain" ]] && ! [[ "$subdomain" =~ ^[a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)*$ ]]; then
    error "Invalid subdomain format: $subdomain"
    exit 1
fi

# ============================================
# STARTUP MESSAGE
# ============================================

header "Cloudflare DNS Updater"

echo -e "${BOLD}Configuration:${RESET}"
echo -e "  Zone:      ${CYAN}$zone${RESET}"
echo -e "  Subdomain: ${CYAN}${subdomain:-<root>}${RESET}"


if [[ ${#cloudflare_api_token} -ne 40 ]]; then
    warning "Cloudflare API tokens are typically 40 characters"
    warning "Your token has ${#cloudflare_api_token} characters"
    echo ""
fi

echo ""

# ============================================
# GET PUBLIC IP
# ============================================

info "Getting public IP address..."
(sleep 0.5) &
spinner $! "Checking IP..."

ip_local=$(curl -s "https://checkip.amazonaws.com/" | tr -d '\n')
if [[ -z "$ip_local" ]]; then
    error "Failed to get public IP"
    exit 1
fi
success "Public IP: ${BOLD}$ip_local${RESET}"
echo ""

# ============================================
# VERIFY TOKEN
# ============================================

info "Verifying Cloudflare token..."
(sleep 0.5) &
spinner $! "Authenticating..."

token_verify=$(curl -s "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    -H "Authorization: Bearer $cloudflare_api_token" \
    -H "Content-Type: application/json")

token_valid=$(echo "$token_verify" | jq -r '.success')
if [[ "$token_valid" != "true" ]]; then
    error "Token verification failed"
    exit 1
fi

success "Token is valid"
echo ""

# ============================================
# GET ZONE ID
# ============================================

info "Looking up Zone ID for ${BOLD}$zone${RESET}..."
(sleep 0.5) &
spinner $! "Querying Cloudflare API..."

cloudflare=$(curl -s "https://api.cloudflare.com/client/v4/zones?name=$zone" \
    -H "Authorization: Bearer $cloudflare_api_token" \
    -H "Content-Type: application/json")

cf_success=$(echo "$cloudflare" | jq -r '.success')
if [[ "$cf_success" != "true" ]]; then
    error "Failed to get Zone ID"
    echo ""
    echo "$cloudflare" | jq '.'
    exit 1
fi

ZONE_ID=$(echo "$cloudflare" | jq -r '.result[0].id')
if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
    error "Zone not found: $zone"
    exit 1
fi
success "Zone ID: ${DIM}$ZONE_ID${RESET}"
echo ""

# ============================================
# PREPARE DOMAIN
# ============================================

if [[ -z "$subdomain" ]]; then
    full_domain="$zone"
else
    full_domain="${subdomain}.${zone}"
fi

info "Working with: ${BOLD}${CYAN}$full_domain${RESET}"
echo ""

# ============================================
# SEARCH FOR EXISTING DNS RECORD
# ============================================

info "Checking for existing DNS records..."
(sleep 0.5) &
spinner $! "Searching..."

dns_record=$(curl -s "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$full_domain" \
    -H "Authorization: Bearer $cloudflare_api_token" \
    -H "Content-Type: application/json")

record_id=$(echo "$dns_record" | jq -r '.result[0].id')
existing_ip=$(echo "$dns_record" | jq -r '.result[0].content')

# ============================================
# CREATE OR UPDATE RECORD
# ============================================

if [[ -n "$record_id" && "$record_id" != "null" ]]; then
    success "Found existing record: ${BOLD}$full_domain${RESET} → $existing_ip"
    
    if [[ "$existing_ip" == "$ip_local" ]]; then
        success "IP address is already up to date!"
        echo ""
        echo -e "${BOLD}${GREEN}✓ No changes needed${RESET}"
        exit 0
    fi
    
    echo ""
    info "Updating DNS record..."
    (sleep 0.5) &
    spinner $! "Updating..."
    
    update_response=$(curl -s -X PUT \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$record_id" \
        -H "Authorization: Bearer $cloudflare_api_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$full_domain\",\"content\":\"$ip_local\",\"ttl\":1,\"proxied\":false}")
    
    update_success=$(echo "$update_response" | jq -r '.success')
    if [[ "$update_success" == "true" ]]; then
        success "DNS record updated!"
        echo ""
        echo -e "  ${DIM}Old IP:${RESET} $existing_ip"
        echo -e "  ${GREEN}New IP:${RESET} $ip_local"
    else
        error "Failed to update DNS record"
        echo ""
        echo "$update_response" | jq '.'
        exit 1
    fi
else
    success "No existing record found"
    echo ""
    info "Creating new DNS record..."
    (sleep 0.5) &
    spinner $! "Creating..."
    
    create_response=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
        -H "Authorization: Bearer $cloudflare_api_token" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$full_domain\",\"content\":\"$ip_local\",\"ttl\":1,\"proxied\":false}")
    
    create_success=$(echo "$create_response" | jq -r '.success')
    if [[ "$create_success" == "true" ]]; then
        success "DNS record created!"
        echo ""
        echo -e "  ${GREEN}Domain:${RESET} $full_domain"
        echo -e "  ${GREEN}IP:${RESET}     $ip_local"
    else
        error "Failed to create DNS record"
        echo ""
        echo "$create_response" | jq '.'
        exit 1
    fi
fi

echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║  ✓ DNS Update Complete!                ║${RESET}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════╝${RESET}"
echo ""