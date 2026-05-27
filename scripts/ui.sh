#!/usr/bin/env bash
# ============================================================================
# Pexip Quick Deploy - Modern Terminal UI helper
# ============================================================================

# Color palettes (256-color ANSI escapes)
TEXT_BOLD="\033[1m"
TEXT_MUTED="\033[38;5;244m"      # Soft slate gray
TEXT_PURPLE="\033[38;5;99m"       # Pexip purple/indigo
TEXT_CYAN="\033[38;5;39m"         # Sky blue/cyan
TEXT_GREEN="\033[38;5;76m"        # Success green
TEXT_RED="\033[38;5;196m"         # Error red
TEXT_YELLOW="\033[38;5;214m"      # Warning orange/yellow
TEXT_UNDERLINE="\033[4m"          # Underline
RESET="\033[0m"

# Check if fractional read timeout is supported (legacy bash fallback, e.g. macOS bash 3.2)
# Increased to 0.3s to be robust against remote network/websocket latency in Cloud Shell
READ_TIMEOUT=1
if read -t 0.3 -n 0 2>/dev/null; then
  READ_TIMEOUT=0.3
fi

# Print a divider line
print_divider() {
  echo -e "${TEXT_MUTED}  ────────────────────────────────────────────────────────────${RESET}"
}

# Print step header
print_step() {
  local num="$1"
  local title="$2"
  echo
  echo -e "  ${TEXT_PURPLE}${num}.${RESET} ${TEXT_BOLD}${title}${RESET}"
  print_divider
}

# UI feedback helpers
print_success() {
  echo -e "  ${TEXT_GREEN}✔${RESET}  $*"
}

# UI error helpers
print_error() {
  echo -e "  ${TEXT_RED}✖${RESET}  $*" >&2
}

# UI warning helpers
print_warning() {
  echo -e "  ${TEXT_YELLOW}⚠${RESET}  ${TEXT_MUTED}$*${RESET}"
}

# UI info helpers
print_info() {
  echo -e "  ${TEXT_CYAN}ℹ${RESET}  ${TEXT_MUTED}$*${RESET}"
}

# Styled text input prompt
ask_input() {
  local prompt="$1"
  local default="${2:-}"
  local var

  # Fallback for non-interactive shells
  if [[ ! -t 0 ]]; then
    echo "$default"
    return
  fi

  echo -e "  ┌   ${TEXT_BOLD}${prompt}${RESET}" >&2
  if [[ -n "$default" ]]; then
    echo -e "  │   ${TEXT_MUTED}Default: ${default}${RESET}" >&2
  fi

  # Read user input
  echo -ne "  │   › " >&2
  read -r var || true
  echo -e "  └" >&2

  local result="${var:-$default}"
  echo "$result"
}

# Styled secure password input prompt with asterisk masking
ask_password() {
  local prompt="$1"
  local var=""
  local char

  # Fallback for non-interactive shells
  if [[ ! -t 0 ]]; then
    echo ""
    return
  fi

  echo -e "  ┌   ${TEXT_BOLD}${prompt}${RESET}" >&2
  echo -ne "  │   › " >&2

  # Save terminal settings
  local old_tty
  old_tty=$(stty -g 2>/dev/null) || true

  # Read character by character silently
  while :; do
    if ! IFS= read -r -s -n 1 char; then
      break
    fi

    if [[ -z "$char" ]]; then
      break
    fi

    # Get hex representation to check for backspace or return
    local hex
    hex=$(printf '%02x' "'$char")

    if [[ "$hex" == "7f" || "$hex" == "08" ]]; then
      if [[ ${#var} -gt 0 ]]; then
        var="${var%?}"
        echo -ne "\b \b" >&2
      fi
    elif [[ "$hex" == "0a" || "$hex" == "0d" ]]; then
      break
    else
      var+="$char"
      echo -n "*" >&2
    fi
  done

  if [[ -n "$old_tty" ]]; then
    stty "$old_tty" 2>/dev/null || true
  fi

  echo >&2 # Print newline
  echo -e "  └" >&2

  echo "$var"
}

# Pure-Bash Arrow-Key Interactive Selection Menu
# Usage: ask_select "Prompt" <default_index> "Option 1" "Option 2" ...
# Outputs selected index (0-based) to stdout
ask_select() {
  local prompt="$1"
  local default_idx="$2"
  shift 2
  local options=("$@")
  local selected="$default_idx"
  local key=""

  # Fallback for non-interactive shells
  if [[ ! -t 0 || ${#options[@]} -eq 0 ]]; then
    echo "$default_idx"
    return
  fi

  # Hide cursor
  tput civis >&2 2>/dev/null || echo -ne "\033[?25l" >&2

  # Restore cursor on ctrl-c
  trap 'tput cnorm >&2 2>/dev/null || echo -ne "\033[?25h" >&2; exit 130' INT TERM

  while true; do
    # Render the question and options
    echo -e "  ┌   ${TEXT_BOLD}${prompt}${RESET}" >&2
    for i in "${!options[@]}"; do
      if [[ $i -eq $selected ]]; then
        echo -e "  │   ${TEXT_PURPLE}❯ ${options[$i]}${RESET}" >&2
      else
        echo -e "  │     ${TEXT_MUTED}${options[$i]}${RESET}" >&2
      fi
    done
    echo -e "  └" >&2

    # Read a single key press (including escapes)
    if ! read -r -s -n1 key; then
      break
    fi

    # Escape sequence parsing (supports vt100 [A/[B and application OA/OB)
    if [[ "$key" == $'\x1b' ]]; then
      if ! read -r -s -n2 -t "$READ_TIMEOUT" key; then
        key=""
      fi
      if [[ "$key" == "[A" || "$key" == "OA" ]]; then # Up arrow
        ((selected--))
        [[ $selected -lt 0 ]] && selected=$((${#options[@]} - 1))
      elif [[ "$key" == "[B" || "$key" == "OB" ]]; then # Down arrow
        ((selected++))
        [[ $selected -ge ${#options[@]} ]] && selected=0
      fi
    elif [[ "$key" == "" ]]; then # Enter key
      break
    fi

    # Clear the menu lines for redrawing:
    # 1 (header line) + number of options + 1 (footer line) = options + 2 lines
    local lines_to_clear=$((${#options[@]} + 2))
    for ((l=0; l<lines_to_clear; l++)); do
      echo -ne "\033[A\033[K" >&2
    done
  done

  # Restore cursor
  tput cnorm >&2 2>/dev/null || echo -ne "\033[?25h" >&2
  trap - INT TERM

  echo "$selected"
}

# Interactive Yes/No Confirmation Dialog using ask_select
# Returns 0 for Yes, 1 for No
ask_confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local options=("Yes" "No")
  local default_idx=0
  [[ "$default" =~ ^[Nn]$ ]] && default_idx=1

  local selected
  selected="$(ask_select "$prompt" "$default_idx" "${options[@]}")"

  if [[ "$selected" -eq 0 ]]; then
    return 0
  else
    return 1
  fi
}

# Helper to print N characters of a string (pure bash)
print_chars() {
  local char="$1"
  local count="$2"
  if [[ $count -le 0 ]]; then
    return
  fi
  local i
  for ((i=0; i<count; i++)); do
    printf "%s" "$char"
  done
}

# Print a beautiful warning/error banner box
print_error_banner() {
  local title="$1"
  local detail="$2"
  local border_color="${3:-$TEXT_RED}"

  local max_w=52
  local len_title=$((${#title}))
  local len_detail=$((${#detail}))

  for len in $len_title $len_detail; do
    if [[ $len -gt $max_w ]]; then
      max_w=$len
    fi
  done

  local border_top="┌$(print_chars '─' $((max_w + 4)))┐"
  local border_mid="├$(print_chars '─' $((max_w + 4)))┤"
  local border_bot="└$(print_chars '─' $((max_w + 4)))┘"

  echo
  echo -e "  ${border_color}${border_top}${RESET}"

  # Title line
  local pad_title=$((max_w - len_title))
  local spaces_t; spaces_t=$(print_chars ' ' $pad_title)
  echo -e "  ${border_color}│${RESET}  ${TEXT_BOLD}${title}${RESET}${spaces_t}  ${border_color}│${RESET}"

  # Detail line if present
  if [[ -n "$detail" ]]; then
    echo -e "  ${border_color}${border_mid}${RESET}"
    local pad_detail=$((max_w - len_detail))
    local spaces_d; spaces_d=$(print_chars ' ' $pad_detail)
    echo -e "  ${border_color}│${RESET}  ${TEXT_MUTED}${detail}${RESET}${spaces_d}  ${border_color}│${RESET}"
  fi

  echo -e "  ${border_color}${border_bot}${RESET}"
  echo
}

# Print a beautiful credentials card at the end of deployment
print_credentials_card() {
  local url="$1"
  local username="$2"
  local password="$3"
  local tls_status="$4"

  # Map long TLS status to a shorter, cleaner version for the card
  local clean_tls
  case "$tls_status" in
    *PRODUCTION*)
      clean_tls="Let's Encrypt PRODUCTION (Trusted)"
      ;;
    *STAGING*)
      clean_tls="Let's Encrypt STAGING (Untrusted)"
      ;;
    *)
      clean_tls="Self-signed (Browser warning)"
      ;;
  esac

  local label_url="Admin URL:  "
  local label_user="Username:   "
  local label_pw="Password:   "
  local label_tls="TLS Cert:   "

  # Find length of each line's content
  local len_url=$((${#label_url} + ${#url}))
  local len_user=$((${#label_user} + ${#username}))
  local len_pw=$((${#label_pw} + ${#password}))
  local len_tls=$((${#label_tls} + ${#clean_tls}))

  local header_text="🚀  Pexip Infinity Successfully Deployed!"
  local len_header=39 # Approximate visible column width for alignment

  # Determine max content width (at least 52 to look good)
  local max_w=52
  for len in $len_url $len_user $len_pw $len_tls $len_header; do
    if [[ $len -gt $max_w ]]; then
      max_w=$len
    fi
  done

  # Build borders
  local border_top
  border_top="┌$(print_chars '─' $((max_w + 4)))┐"
  local border_mid
  border_mid="├$(print_chars '─' $((max_w + 4)))┤"
  local border_bot
  border_bot="└$(print_chars '─' $((max_w + 4)))┘"

  # Print the card
  echo
  echo -e "  ${TEXT_PURPLE}${border_top}${RESET}"

  # Header line (centered)
  local pad_total=$((max_w + 4 - len_header))
  local pad_left=$((pad_total / 2))
  local pad_right=$((pad_total - pad_left))
  [[ $pad_left -lt 1 ]] && pad_left=1
  [[ $pad_right -lt 1 ]] && pad_right=1

  local space_l; space_l=$(print_chars ' ' $pad_left)
  local space_r; space_r=$(print_chars ' ' $pad_right)
  echo -e "  ${TEXT_PURPLE}│${RESET}${space_l}${TEXT_BOLD}${header_text}${RESET}${space_r}${TEXT_PURPLE}│${RESET}"

  echo -e "  ${TEXT_PURPLE}${border_mid}${RESET}"

  # Helper to print a line with correct padding
  print_card_line() {
    local label="$1"
    local val_color="$2"
    local val="$3"
    local val_clean="$4"
    local pad=$((max_w - ${#label} - ${#val_clean}))
    local spaces; spaces=$(print_chars ' ' $pad)
    echo -e "  ${TEXT_PURPLE}│${RESET}  ${TEXT_BOLD}${label}${RESET}${val_color}${val}${RESET}${spaces}  ${TEXT_PURPLE}│${RESET}"
  }

  print_card_line "$label_url" "$TEXT_CYAN" "$url" "$url"
  print_card_line "$label_user" "" "$username" "$username"
  print_card_line "$label_pw" "$TEXT_GREEN" "$password" "$password"

  echo -e "  ${TEXT_PURPLE}${border_mid}${RESET}"
  print_card_line "$label_tls" "" "$clean_tls" "$clean_tls"
  echo -e "  ${TEXT_PURPLE}${border_bot}${RESET}"
  echo
}

# Background loop that prints humorous progress updates during long builds
funny_progress_loop() {
  local messages=(
    "Robots are assembling your deployment..."
    "Soddering your virtual CPU to the motherboard..."
    "Trying to spell Pexip correctly..."
    "Bribing GCP API gateways for extra bandwidth..."
    "Downloading the cloud (please hold)..."
    "Feeding the server VMs virtual energy drinks..."
    "Aligning the hypervisors and quantum couplers..."
    "Polishing the status indicators to shine brighter..."
    "Warming up the transcoding engine..."
    "Convincing packets not to take detours in transit..."
    "Whispering sweet nothings to the virtual disk drive..."
    "Double-checking the blueprints for gravity consistency..."
    "Brewing digital espresso for the Management Node..."
    "Untangling virtual fiber-optic cables..."
    "Asking the cloud nicely to speed things up..."
    "Charging the lasers for the Conferencing Nodes..."
    "Updating hostnames (no typos this time, promise)..."
    "Locating the power button on the virtual mainframe..."
    "Counting virtual server racks..."
    "Checking if turning it off and on again works..."
  )

  # Shuffle messages using RANDOM to keep the experience fresh
  local shuffled=()
  while [[ ${#shuffled[@]} -lt ${#messages[@]} ]]; do
    local idx=$((RANDOM % ${#messages[@]}))
    local msg="${messages[$idx]}"
    local found=0
    for m in "${shuffled[@]}"; do
      if [[ "$m" == "$msg" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      shuffled+=("$msg")
    fi
  done

  local i=0
  while true; do
    local msg="${shuffled[i % ${#shuffled[@]}]}"
    echo -e "\n  ${TEXT_PURPLE}•  ${TEXT_BOLD}${msg}${RESET}\n" >&2
    ((i++))
    sleep 30
  done
}
