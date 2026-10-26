#!/bin/bash

# macOS Bloat Service Disabler - Enhanced Version (System Update Safe)
# Disables 32+ unnecessary services while keeping essential ones
# Handles both user and system services + kills running processes
# UPDATED: Added system update protection and safer process handling
# Created: $(date)

set -euo pipefail

if [ "$EUID" -eq 0 ]; then
    LOG_FILE="/var/log/disable_bloat_services.log"
else
    LOG_FILE="${HOME:?}/Library/Logs/disable_bloat_services.log"
fi
SCRIPT_PATH="${SCRIPT_PATH:-/usr/local/bin/disable_bloat_services.sh}"
# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# The daemon and agent can fire at the same time. One run must own the log and
# counters so the two jobs do not report duplicate or conflicting results.
LOCK_DIR="/tmp/lean-mac-disable-bloat.lock"
acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        return 0
    fi
    local owner_pid=""
    [ -r "$LOCK_DIR/pid" ] && owner_pid=$(cat "$LOCK_DIR/pid")
    if [ -z "$owner_pid" ] || ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f "$LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            printf '%s\n' "$$" > "$LOCK_DIR/pid"
            return 0
        fi
    fi
    return 1
}
if ! acquire_lock; then
    log_message() { :; }
    exit 0
fi
trap 'rm -f "$LOCK_DIR/pid" 2>/dev/null || true; rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
SERVICES_DISABLED=0
SERVICES_FAILED=0
SERVICES_NOT_FOUND=0
PROCESSES_KILLED=0
PROCESSES_FAILED=0
PROCESSES_SKIPPED=0
RAM_BEFORE_BYTES=0
RAM_AFTER_BYTES=0
MODE="auto"

case "${1:-}" in
    --auto|"") MODE="auto" ;;
    --interactive) MODE="interactive" ;;
    --dry-run) MODE="dry-run" ;;
    --list) MODE="list" ;;
    --system-only) MODE="system-only" ;;
    --user-only) MODE="user-only" ;;
    --help|-h)
        cat <<'USAGE'
Usage: disable_bloat_services.sh [--auto|--interactive|--dry-run|--list]
  --auto          Apply the curated macOS 26/27 list (default).
  --interactive   Ask before each exact launchd label.
  --dry-run       Report checks without disabling anything.
  --list          Read-only inventory of matching labels in system/gui domains.
  --system-only   Run system services and process cleanup (LaunchDaemon mode).
  --user-only     Run GUI services only (LaunchAgent mode).
USAGE
        exit 0
        ;;
    *) echo "Unknown option: $1 (use --help)" >&2; exit 2 ;;
esac

# System LaunchDaemons checked by their exact launchd labels. Keep this list
# explicit so every target is visible in the log and independently testable.
SYSTEM_SERVICES=(
    "com.apple.wifianalyticsd|WiFi Analytics"
    "com.apple.icloud.findmydeviced|Find My Device"
    "com.apple.ecosystemanalyticsd|Ecosystem Analytics"
    "com.apple.findmy.findmylocateagent|Find My Location"
    "com.apple.findmy.findmymacmessenger|Find My Mac Messenger"
    "com.apple.findmymacd|Find My Mac"
    "com.apple.diagnosticservicesd|Diagnostic Services"
    "com.apple.osanalytics.osanalyticshelper|OS Analytics Helper"
    "com.apple.analyticsd|Analytics Daemon"
    "com.apple.analyticsd.agent|Analytics Agent"
    "com.apple.audioanalyticsd|Audio Analytics"
    "com.apple.usbctelemetryd|USB-C Telemetry"
    "com.apple.cloudtelemetryd|Cloud Telemetry"
    "com.apple.osanalytics.diagnosticmonitor|OS Analytics Monitor"
)

# System Update Protection - Processes that should NEVER be killed
SYSTEM_UPDATE_PROTECTED=(
    "softwareupdate"
    "softwareupdated"
    "mobileassetd"          # Mobile Asset Daemon (System Updates)
    "installd"
    "installer"
    "pkgbuild"
    "packagekitd"
    "system_installd"
    "MobileSoftwareUpdate"
    "SoftwareUpdateNotificationManager"
    "mas"                   # Mac App Store updates
    "App Store"
    "storedownloadd"
    "storeassetd"
    "commerce"
    "CommerceKit"
    "nsurlsessiond"         # Network sessions for downloads
    "cloudd"                # May be needed for update downloads
    "deleted"               # Cache management during updates
    "deleted_helper"        # Cache management helper
    "xpcproxy"              # XPC proxy for system services
    "launchservicesd"       # Launch Services
    "coreservicesd"         # Core Services
    "systemstats"           # System statistics
    "kernel_task"           # Kernel
    "launchd"               # Launch daemon
    "loginwindow"           # Login window
    "WindowServer"          # Window server
    "Finder"                # Finder
    "Dock"                  # Dock
)

# Function to log messages
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

memory_available_bytes() {
    local page_size
    page_size=$(vm_stat | awk '/page size of/{gsub(/[^0-9]/, "", $8); print $8; exit}')
    [ -n "$page_size" ] || page_size=4096
    vm_stat | awk -v ps="$page_size" '
        /Pages free/ || /Pages inactive/ || /Pages speculative/ || /Pages purgeable/ {
            gsub(/[^0-9]/, "", $NF); total += $NF
        }
        END { printf "%.0f", total * ps }
    '
}

format_mb() {
    awk -v bytes="$1" 'BEGIN { printf "%.0f MB", bytes / 1048576 }'
}

get_gui_uids() {
    local console_user console_uid sudo_uid
    console_user=$(stat -f '%Su' /dev/console 2>/dev/null || true)
    if [ -n "$console_user" ] && [ "$console_user" != "root" ]; then
        console_uid=$(id -u "$console_user" 2>/dev/null || true)
        [ -n "$console_uid" ] && printf '%s\n' "$console_uid"
    fi
    if [ -n "${SUDO_USER:-}" ]; then
        sudo_uid=$(id -u "$SUDO_USER" 2>/dev/null || true)
        [ -n "$sudo_uid" ] && printf '%s\n' "$sudo_uid"
    fi
}

should_process_service() {
    local service_name="$1"
    local description="$2"
    local domain="$3"
    case "$MODE" in
        auto) return 0 ;;
        dry-run)
            log_message "🧪 DRY RUN: would check $domain/$service_name - $description"
            return 1
            ;;
        interactive)
            printf 'Disable %s/%s (%s)? [y/N] ' "$domain" "$service_name" "$description" > /dev/tty
            read -r answer < /dev/tty || answer=""
            [[ "$answer" =~ ^[Yy]$ ]]
            ;;
    esac
}

list_matching_services() {
    local domain="$1"
    log_message "🔎 Inventory for $domain:"
    launchctl print "$domain" 2>/dev/null |
        awk '{label=$NF; if (label ~ /^com\.apple\./ && label ~ /(analytics|telemetry|intelligence|siri|spotlight|knowledge|proactive|duet|diagnostic|feedback|mediaanalysis|weather|social|rapport|itunes|commerce)/) print label}' |
        sed 's/[{},]//g' | sort -u | while IFS= read -r label; do
            [ -n "$label" ] && log_message "  $label"
        done
}

# Enhanced function to safely kill processes with system update protection
kill_process() {
    local process_name="$1"
    local description="$2"

    if [ "$MODE" = "dry-run" ]; then
        log_message "🧪 DRY RUN: would inspect process $process_name - $description"
        return 0
    fi
    if [ "$MODE" = "user-only" ]; then
        return 0
    fi
    
    # Check if this process is protected
    for protected in "${SYSTEM_UPDATE_PROTECTED[@]}"; do
        if [[ "$process_name" == *"$protected"* ]] || [[ "$protected" == *"$process_name"* ]]; then
            log_message "🛡️  PROTECTED: $process_name - $description (System update critical)"
            ((PROCESSES_SKIPPED+=1))
            return 0
        fi
    done
    
    local pids=$(pgrep -f "$process_name" 2>/dev/null)
    if [ -n "$pids" ]; then
        for pid in $pids; do
            # Double-check the actual process name to avoid false positives
            local actual_name=$(ps -p "$pid" -o comm= 2>/dev/null | xargs basename)
            
            # Additional protection check on actual process name
            local is_protected=false
            for protected in "${SYSTEM_UPDATE_PROTECTED[@]}"; do
                if [[ "$actual_name" == *"$protected"* ]] || [[ "$protected" == *"$actual_name"* ]]; then
                    log_message "🛡️  PROTECTED: $actual_name (PID: $pid) - System critical process"
                    ((PROCESSES_SKIPPED+=1))
                    is_protected=true
                    break
                fi
            done
            
            if [ "$is_protected" = false ]; then
                # Use SIGTERM first, then SIGKILL if needed (gentler approach)
                if kill -TERM "$pid" 2>/dev/null; then
                    sleep 1
                    # Check if process is still running
                    if kill -0 "$pid" 2>/dev/null; then
                        # Still running, use SIGKILL
                        if kill -9 "$pid" 2>/dev/null; then
                            log_message "💀 KILLED: $process_name (PID: $pid) - $description (SIGKILL)"
                            ((PROCESSES_KILLED+=1))
                        else
                            log_message "❌ FAILED TO KILL: $process_name (PID: $pid) - $description"
            ((PROCESSES_FAILED+=1))
                        fi
                    else
                        log_message "✅ TERMINATED: $process_name (PID: $pid) - $description (SIGTERM)"
                            ((PROCESSES_KILLED+=1))
                    fi
                else
                    log_message "❌ FAILED TO TERMINATE: $process_name (PID: $pid) - $description"
                    ((PROCESSES_FAILED+=1))
                fi
            fi
        done
    fi
}

# Function to disable system-level services
disable_system_service() {
    local service_name="$1"
    local description="$2"
    if [ "$MODE" = "user-only" ]; then
        return 0
    fi
    
    local launchctl_cmd=(launchctl)
    if [ "$EUID" -ne 0 ]; then
        launchctl_cmd=(sudo launchctl)
    fi

    if ! should_process_service "$service_name" "$description" "system"; then
        return 0
    fi

    if "${launchctl_cmd[@]}" print system 2>/dev/null | grep -Fq "$service_name" 2>/dev/null; then
        if "${launchctl_cmd[@]}" disable "system/$service_name" 2>/dev/null; then
            log_message "🔴 SYSTEM DISABLED: $service_name - $description"
            ((SERVICES_DISABLED+=1))
        else
            log_message "❌ SYSTEM FAILED: $service_name - $description"
            ((SERVICES_FAILED+=1))
        fi
    else
        log_message "ℹ️  SYSTEM NOT FOUND: $service_name - $description"
        ((SERVICES_NOT_FOUND+=1))
    fi
}

# Function to disable a service for all logged-in users
disable_service() {
    local service_name="$1"
    local description="$2"
    local disabled=false
    if [ "$MODE" = "system-only" ]; then
        return 0
    fi

    if ! should_process_service "$service_name" "$description" "gui"; then
        return 0
    fi
    
    # Check the active console user and the sudo caller's GUI domains.
    for user_id in $(get_gui_uids | sort -u); do
        if [[ "$user_id" =~ ^[0-9]+$ ]] && [ "$user_id" -ge 500 ]; then
            # Try to disable for this user
            if launchctl print "gui/$user_id" 2>/dev/null | grep -q "$service_name" 2>/dev/null; then
                if launchctl disable "gui/$user_id/$service_name" 2>/dev/null; then
                    log_message "✅ DISABLED: $service_name - $description (UID: $user_id)"
                    disabled=true
                    ((SERVICES_DISABLED+=1))
                else
                    log_message "❌ FAILED: $service_name - $description (UID: $user_id)"
                    ((SERVICES_FAILED+=1))
                fi
            fi
        fi
    done
    
    if [ "$disabled" = false ]; then
        log_message "ℹ️  NOT FOUND: $service_name - $description"
        ((SERVICES_NOT_FOUND+=1))
    fi
}

# Function to check if macOS system updates are running
check_system_updates() {
    # Only look for known update/installer processes and match them exactly
    local update_processes=(
        "softwareupdate"    # Command line macOS updater
        "InstallAssistant"  # macOS GUI installer
        "Installer"         # macOS package installer
    )

    for proc in "${update_processes[@]}"; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
            local pids
            pids=$(pgrep -x "$proc")
            log_message "⚠️  ACTIVE SYSTEM UPDATE DETECTED: $proc (PIDs: $pids)"
            log_message "🛑 ABORTING: Will not run debloat service during system updates"
            log_message "💡 TIP: Try running again after updates complete"
            exit 0
        fi
    done

    # Check specifically for macOS installer apps by their window title
    if pgrep -f "Install macOS" >/dev/null 2>&1; then
        log_message "⚠️  macOS INSTALLER DETECTED - Aborting debloat service"
        exit 0
    fi
}

log_message "=== Starting macOS Bloat Service Disabler (System Update Safe) ==="
RAM_BEFORE_BYTES=$(memory_available_bytes)
log_message "📊 Available RAM before: $(format_mb "$RAM_BEFORE_BYTES")"

if [ "$MODE" = "list" ]; then
    list_matching_services "system"
    for user_id in $(get_gui_uids | sort -u); do
        list_matching_services "gui/$user_id"
    done
    exit 0
fi

log_message "🔍 Checking for active system updates..."
check_system_updates
log_message "✅ No system updates detected - proceeding with debloat service"

# Cloud & Sync Services (5) - PRESERVING MAIL SERVICES
log_message "--- Disabling Cloud & Sync Services (Preserving Mail) ---"
# PRESERVED: com.apple.cloudd - Required for iCloud Mail sync
# PRESERVED: com.apple.icloudmailagent - Required for iCloud Mail
# PRESERVED: com.apple.syncdefaultsd - Required for Mail sync
# PRESERVED: com.apple.protectedcloudstorage.protectedcloudkeysyncing - May be needed for Mail keychain
disable_service "com.apple.icloud.searchpartyuseragent" "Find My network"
disable_service "com.apple.icloud.findmydeviced.findmydevice-user-agent" "Find My device"
disable_service "com.apple.findmy.findmylocateagent" "Find My location"
disable_service "com.apple.itunescloudd" "iTunes/Music cloud sync"
log_message "✅ PRESERVED: Mail-related services (cloudd, icloudmailagent, syncdefaultsd, protectedcloudstorage)"

# AI & Intelligence Services (12)
log_message "--- Disabling AI & Intelligence Services ---"
disable_service "com.apple.intelligenceplatformd" "Apple Intelligence platform"
disable_service "com.apple.siri.context.service" "Siri context"
disable_service "com.apple.siriactionsd" "Siri actions"
disable_service "com.apple.siriknowledged" "Siri knowledge"
disable_service "com.apple.assistantd" "Assistant daemon"
disable_service "com.apple.siriinferenced" "Siri inference"
disable_service "com.apple.assistant_cdmd" "Assistant command"
disable_service "com.apple.sirittsd" "Siri text-to-speech"
disable_service "com.apple.proactived" "Proactive suggestions"
disable_service "com.apple.duetexpertd" "Duet expert system"
disable_service "com.apple.knowledge-agent" "Knowledge agent"
disable_service "com.apple.spotlightknowledged.updater" "Spotlight knowledge updater"
# macOS 27.2 additions discovered from the live gui launchd domain.
disable_service "com.apple.intelligencecontextd" "Intelligence context"
disable_service "com.apple.intelligenceflowd" "Intelligence flow"
disable_service "com.apple.intelligencetasksd" "Intelligence task scheduler"
disable_service "com.apple.intelligenceplatformd" "Intelligence platform"
disable_service "com.apple.knowledgeconstructiond" "Knowledge construction"
disable_service "com.apple.corespotlightd" "Core Spotlight"
disable_service "com.apple.corespotlightservice" "Core Spotlight service"
disable_service "com.apple.managedcorespotlightd" "Managed Core Spotlight"
disable_service "com.apple.spotlightknowledged" "Spotlight knowledge"
disable_service "com.apple.spotlightknowledged.importer" "Spotlight knowledge importer"
disable_service "com.apple.visualintelligenced" "Visual Intelligence"
disable_service "com.apple.visualintelligence.daemon-status" "Visual Intelligence status"
disable_service "com.apple.uiintelligencesupport.agent" "UI Intelligence support"
disable_service "com.apple.sirisuggestions" "Siri suggestions"
disable_service "com.apple.siriappintentsd" "Siri App Intents"
disable_service "com.apple.spotlightknowledged.updater.cachedelete" "Spotlight updater cache cleanup"
disable_service "com.apple.proactiveeventtrackerd" "Proactive event tracker"

# Telemetry & Analytics (3)
log_message "--- Disabling Telemetry & Analytics ---"
disable_service "com.apple.analyticsagent" "Analytics collection"
disable_service "com.apple.feedbackd" "Feedback daemon"
disable_service "com.apple.diagnostics_agent" "Diagnostics"

# Store & Media Services (4)
log_message "--- Disabling Store & Media Services ---"
disable_service "com.apple.appstoreagent" "App Store agent"
disable_service "com.apple.weatherd" "Weather service"
disable_service "com.apple.weather.menu" "Weather menu"
disable_service "com.apple.mediaremoteagent" "Media remote"

# Social & Communication (3)
log_message "--- Disabling Social & Communication ---"
disable_service "com.apple.sociallayerd" "Social framework"
disable_service "com.apple.keychainsharingmessagingd" "Keychain sharing"
disable_service "com.apple.rapportd" "Handoff/Continuity"

# Previously Disabled Media Services (2)
log_message "--- Disabling Media Services ---"
disable_service "com.apple.mediaanalysisd" "Media analysis"
disable_service "com.apple.mediastream.mstreamd" "Media streaming"

# SYSTEM-LEVEL SERVICES (LaunchDaemons)
log_message "--- Checking System-Level Services by exact launchd name ---"
for service_entry in "${SYSTEM_SERVICES[@]}"; do
    IFS='|' read -r service_name service_description <<< "$service_entry"
    disable_system_service "$service_name" "$service_description"
done

# KILL RUNNING PROCESSES
log_message "--- Killing Running Bloat Processes ---"
kill_process "analyticsagent" "Analytics Agent"
kill_process "siriinferenced" "Siri Inference"
kill_process "siriactionsd" "Siri Actions"
kill_process "findmylocateagent" "Find My Location"
kill_process "findmydevice-user-agent" "Find My Device Agent"
kill_process "proactived" "Proactive Suggestions"
kill_process "intelligenceplatformd" "Apple Intelligence"
kill_process "intelligencecontextd" "Intelligence Context"
kill_process "intelligenceflowd" "Intelligence Flow"
kill_process "intelligencetasksd" "Intelligence Tasks"
kill_process "visualintelligenced" "Visual Intelligence"
kill_process "siriappintentsd" "Siri App Intents"
kill_process "siriknowledged" "Siri Knowledge"
kill_process "feedbackd" "Feedback Daemon"
kill_process "knowledge-agent" "Knowledge Agent"
kill_process "diagnostics_agent" "Diagnostics Agent"
kill_process "duetexpertd" "Duet Expert"
kill_process "rapportd" "Handoff/Continuity"
kill_process "sirittsd" "Siri TTS"
kill_process "spotlightknowledged" "Spotlight Knowledge"
kill_process "wifianalyticsd" "WiFi Analytics"
kill_process "ecosystemanalyticsd" "Ecosystem Analytics"
kill_process "osanalyticshelper" "OS Analytics Helper"
kill_process "geoanalyticsd" "Geo Analytics"
kill_process "mediaanalysisd" "Media Analysis"
kill_process "inputanalyticsd" "Input Analytics"
kill_process "analyticsd" "Analytics Daemon"
kill_process "audioanalyticsd" "Audio Analytics"
kill_process "ecosystemanalyticsd" "Ecosystem Analytics"
kill_process "osanalyticshelper" "OS Analytics Helper"
kill_process "proactiveeventtrackerd" "Proactive Event Tracker"
kill_process "spotlightknowledged.updater" "Spotlight Knowledge Updater"

# iTunes/Music Related Processes
log_message "--- Killing iTunes/Music Related Processes ---"
kill_process "commerce" "iTunes Commerce"
kill_process "itunescloudd" "iTunes Cloud"
kill_process "mediaremoteagent" "Media Remote"
kill_process "Music" "Music App"
kill_process "com.apple.Music" "Music Service"

# Spotlight Related Processes (if you want to reduce indexing)
log_message "--- Killing Spotlight Related Processes (Optional) ---"
kill_process "mdworker" "Spotlight Worker"
kill_process "mds_stores" "Spotlight Stores"
kill_process "corespotlightd" "Core Spotlight"
kill_process "managedcorespotlightd" "Managed Core Spotlight"

log_message "=== Summary ==="
log_message "Processes killed: $PROCESSES_KILLED"
log_message "Processes failed: $PROCESSES_FAILED"
log_message "Processes protected: $PROCESSES_SKIPPED"
log_message "Services disabled: $SERVICES_DISABLED"
log_message "Services failed: $SERVICES_FAILED"
log_message "Services not found: $SERVICES_NOT_FOUND"
log_message "Total services processed: $((SERVICES_DISABLED + SERVICES_FAILED))"
RAM_AFTER_BYTES=$(memory_available_bytes)
log_message "📊 Available RAM after:  $(format_mb "$RAM_AFTER_BYTES")"
log_message "📈 RAM change:          $(format_mb "$((RAM_AFTER_BYTES - RAM_BEFORE_BYTES))")"
log_message "🛡️  System update protection: ENABLED"
log_message "=== Bloat Service Disabler Complete ==="

# Verify essential services are still running
log_message "--- Verifying Essential Services ---"
if launchctl print "gui/$(id -u)" | grep -q "com.apple.sharingd" 2>/dev/null; then
    log_message "✅ KEPT: com.apple.sharingd - AirDrop/Sharing (as requested)"
else
    log_message "⚠️  WARNING: com.apple.sharingd not found"
fi

if launchctl print "gui/$(id -u)" | grep -q "com.apple.exchange.exchangesyncd" 2>/dev/null; then
    log_message "✅ KEPT: com.apple.exchange.exchangesyncd - Exchange Sync (as requested)"
else
    log_message "ℹ️  INFO: com.apple.exchange.exchangesyncd not found (may not be needed)"
fi

exit 0
