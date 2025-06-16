#!/bin/bash

# Fly.io PostgreSQL Cluster Recovery Script
# This script diagnoses and attempts to recover a failing PostgreSQL cluster on Fly.io
# Updated for latest flyctl commands (2025)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
APP_NAME=""
POSTGRES_APP_NAME=""
LOG_LINES=100
BACKUP_BEFORE_RECOVERY=true
DRY_RUN=false
LOG_FILE=""

# Create secure temp file for operations
TMP_FILE=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT

# Function to print colored output
print_status() {
    local msg="$1"
    echo -e "${BLUE}[INFO]${NC} $msg"
    [[ -n "$LOG_FILE" ]] && echo "[$(date)] INFO: $msg" >> "$LOG_FILE"
}

print_warning() {
    local msg="$1"
    echo -e "${YELLOW}[WARNING]${NC} $msg"
    [[ -n "$LOG_FILE" ]] && echo "[$(date)] WARNING: $msg" >> "$LOG_FILE"
}

print_error() {
    local msg="$1"
    echo -e "${RED}[ERROR]${NC} $msg"
    [[ -n "$LOG_FILE" ]] && echo "[$(date)] ERROR: $msg" >> "$LOG_FILE"
}

print_success() {
    local msg="$1"
    echo -e "${GREEN}[SUCCESS]${NC} $msg"
    [[ -n "$LOG_FILE" ]] && echo "[$(date)] SUCCESS: $msg" >> "$LOG_FILE"
}

# Function to execute commands with dry-run support
execute_command() {
    local cmd="$1"
    local description="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        print_status "[DRY RUN] Would execute: $description"
        print_status "[DRY RUN] Command: $cmd"
        return 0
    else
        print_status "Executing: $description"
        eval "$cmd"
    fi
}

# Function to check if flyctl and dependencies are installed and authenticated
check_flyctl() {
    print_status "Checking flyctl installation and authentication..."
    
    # Check for flyctl
    if ! command -v fly &> /dev/null; then
        print_error "flyctl is not installed. Please install it first."
        print_status "Install with: curl -L https://fly.io/install.sh | sh"
        exit 1
    fi
    
    # Check for jq dependency
    if ! command -v jq &> /dev/null; then
        print_error "jq is required but not installed. Please install jq."
        print_status "Install with: apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
        exit 1
    fi
    
    # Check authentication
    if ! fly auth whoami &> /dev/null; then
        print_error "Not authenticated with Fly.io. Please run 'fly auth login'"
        exit 1
    fi
    
    print_success "flyctl and dependencies are ready"
}

# Function to discover PostgreSQL app name
discover_postgres_app() {
    print_status "Discovering PostgreSQL applications..."
    
    # List all apps and filter for PostgreSQL
    fly apps list --json | jq -r '.[] | select(.Name | contains("db") or contains("postgres")) | .Name' > "$TMP_FILE"
    
    if [[ ! -s "$TMP_FILE" ]]; then
        print_warning "No PostgreSQL apps found automatically. Please specify manually."
        read -p "Enter your PostgreSQL app name: " POSTGRES_APP_NAME
    else
        echo "Found potential PostgreSQL apps:"
        cat "$TMP_FILE" | nl
        read -p "Select app number (or enter custom name): " selection
        
        if [[ "$selection" =~ ^[0-9]+$ ]]; then
            POSTGRES_APP_NAME=$(sed -n "${selection}p" "$TMP_FILE")
        else
            POSTGRES_APP_NAME="$selection"
        fi
    fi
    
    print_status "Using PostgreSQL app: $POSTGRES_APP_NAME"
}

# Function to get cluster status
get_cluster_status() {
    print_status "Getting cluster status for $POSTGRES_APP_NAME..."
    
    echo "=== Machine Status ==="
    fly machine list --app "$POSTGRES_APP_NAME" || echo "Failed to get machine list"
    
    echo -e "\n=== App Status ==="
    fly status --app "$POSTGRES_APP_NAME" || echo "Failed to get app status"
    
    echo -e "\n=== Recent Logs ==="
    fly logs --app "$POSTGRES_APP_NAME" -n 50 || echo "Failed to get logs"
}

# Function to check database connectivity
check_db_connectivity() {
    print_status "Checking database connectivity..."
    
    # Try to connect using postgres connect with proper syntax
    local connect_result
    if connect_result=$(fly postgres connect --app "$POSTGRES_APP_NAME" --pty --command "psql -c 'SELECT 1 as test;'" 2>/dev/null); then
        if echo "$connect_result" | grep -q "test"; then
            print_success "Database is accessible via postgres connect"
            return 0
        fi
    fi
    
    # Fallback: Try via machine exec
    local test_machine
    test_machine=$(fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[0].id')
    
    if [[ -n "$test_machine" && "$test_machine" != "null" ]]; then
        if fly machine exec "$test_machine" --app "$POSTGRES_APP_NAME" -- su - postgres -c "psql -c 'SELECT 1;'" 2>/dev/null | grep -q "1 row"; then
            print_success "Database is accessible via machine exec"
            return 0
        else
            print_error "Cannot connect to PostgreSQL cluster"
            return 1
        fi
    else
        print_error "No machines available to test connectivity"
        return 1
    fi
}

# Function to check PostgreSQL cluster status (modern approach)
check_postgres_cluster_status() {
    print_status "Checking PostgreSQL cluster status..."
    
    # Check if this is a managed Postgres app
    local app_info
    app_info=$(fly apps list --json 2>/dev/null | jq -r --arg app "$POSTGRES_APP_NAME" '.[] | select(.Name == $app)')
    
    if echo "$app_info" | jq -e '.Organization' >/dev/null 2>&1; then
        # Try to get postgres-specific status
        fly status --app "$POSTGRES_APP_NAME" 2>/dev/null || {
            print_warning "Unable to get postgres status directly, checking via machines..."
            
            # Get postgres process status from each machine
            fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
                if [[ -n "$machine_id" ]]; then
                    echo "=== Machine $machine_id PostgreSQL Status ==="
                    fly machine exec "$machine_id" --app "$POSTGRES_APP_NAME" -- su - postgres -c "pg_isready -h localhost -p 5432" 2>/dev/null || echo "PostgreSQL not ready on $machine_id"
                fi
            done
        }
    else
        print_warning "App not found or not accessible, checking repmgr status instead..."
        check_repmgr_status
    fi
}

# Function to check repmgr status
check_repmgr_status() {
    print_status "Checking repmgr cluster status..."
    
    # Get list of machines and check repmgr status on each
    fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
        if [[ -n "$machine_id" ]]; then
            echo "=== Machine $machine_id ==="
            fly machine exec "$machine_id" --app "$POSTGRES_APP_NAME" -- su - postgres -c "repmgr cluster show" 2>/dev/null || echo "Failed to get repmgr status for $machine_id"
            echo ""
        fi
    done
}

# Function to check machine resources
check_machine_resources() {
    print_status "Checking machine resources..."
    
    fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
        if [[ -n "$machine_id" ]]; then
            echo "=== Machine $machine_id Resources ==="
            fly machine exec "$machine_id" --app "$POSTGRES_APP_NAME" -- sh -c "df -h && echo '---' && free -h && echo '---' && ps aux | grep postgres | head -10" 2>/dev/null || echo "Failed to get resource info for $machine_id"
            echo ""
        fi
    done
}

# Function to create backup before recovery
create_backup() {
    if [[ "$BACKUP_BEFORE_RECOVERY" == "true" ]]; then
        print_status "Creating backup before recovery..."
        
        # Try creating a volume snapshot as backup
        local backup_created=false
        
        # Get volumes associated with the app
        fly volumes list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read volume_id; do
            if [[ -n "$volume_id" ]]; then
                local snapshot_name="emergency-backup-$(date +%Y%m%d-%H%M%S)"
                if fly volumes snapshots create "$volume_id" --app "$POSTGRES_APP_NAME" 2>/dev/null; then
                    print_success "Volume snapshot created for $volume_id"
                    backup_created=true
                fi
            fi
        done
        
        # Alternative: try postgres-specific backup if available
        if [[ "$backup_created" != "true" ]]; then
            # Try running pg_dump via machine exec as fallback
            local primary_machine
            primary_machine=$(fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[0].id')
            
            if [[ -n "$primary_machine" && "$primary_machine" != "null" ]]; then
                print_status "Attempting database dump backup..."
                if fly machine exec "$primary_machine" --app "$POSTGRES_APP_NAME" -- su - postgres -c "pg_dumpall > /data/emergency-backup-$(date +%Y%m%d-%H%M%S).sql" 2>/dev/null; then
                    print_success "Database dump backup created"
                else
                    print_warning "Backup creation failed, but continuing with recovery..."
                fi
            else
                print_warning "No machines available for backup, continuing with recovery..."
            fi
        fi
    fi
}

# Function to restart failed machines
restart_machines() {
    print_status "Restarting failed machines..."
    
    # Get list of machines and their states (Machines v2 approach)
    fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[] | select(.state != "started") | .id' | while read machine_id; do
        if [[ -n "$machine_id" ]]; then
            execute_command "fly machine restart '$machine_id' --app '$POSTGRES_APP_NAME'" "Restart failed machine $machine_id"
            sleep 10
        fi
    done
}

# Function to force restart all machines
force_restart_all() {
    print_warning "Force restarting ALL machines in the cluster..."
    read -p "This will cause downtime. Continue? (y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
            if [[ -n "$machine_id" ]]; then
                print_status "Force restarting machine $machine_id..."
                fly machine restart "$machine_id" --app "$POSTGRES_APP_NAME" --force-stop
                sleep 15
            fi
        done
    fi
}

# Function to check and fix DNS resolution
check_dns() {
    print_status "Checking DNS resolution..."
    
    fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
        if [[ -n "$machine_id" ]]; then
            echo "=== Machine $machine_id DNS ==="
            fly machine exec "$machine_id" --app "$POSTGRES_APP_NAME" -- sh -c "nslookup $POSTGRES_APP_NAME.internal && echo '---' && cat /etc/hosts" 2>/dev/null || echo "Failed to check DNS for $machine_id"
            echo ""
        fi
    done
}

# Function to perform PostgreSQL recovery
postgres_recovery() {
    print_status "Attempting PostgreSQL recovery..."
    
    # Try to identify the primary node
    PRIMARY_MACHINE=""
    
    fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
        if [[ -n "$machine_id" ]]; then
            ROLE=$(fly machine exec "$machine_id" --app "$POSTGRES_APP_NAME" -- su - postgres -c "repmgr node status --verbose" 2>/dev/null | grep "Role" | awk '{print $2}' || echo "unknown")
            echo "Machine $machine_id role: $ROLE"
            
            if [[ "$ROLE" == "primary" ]]; then
                PRIMARY_MACHINE="$machine_id"
                echo "PRIMARY_MACHINE=$machine_id" > /tmp/primary_machine
            fi
        fi
    done
    
    # Read the primary machine from temp file (due to subshell limitations)
    if [[ -f /tmp/primary_machine ]]; then
        source /tmp/primary_machine
        rm -f /tmp/primary_machine
    fi
    
    if [[ -z "$PRIMARY_MACHINE" ]]; then
        print_warning "No primary found. Attempting to promote a standby..."
        promote_standby
    else
        print_status "Primary found: $PRIMARY_MACHINE"
        # Try to restart PostgreSQL on primary using modern supervisor command
        fly machine exec "$PRIMARY_MACHINE" --app "$POSTGRES_APP_NAME" -- supervisorctl restart postgres 2>/dev/null || {
            print_warning "Supervisor restart failed, trying alternative restart methods..."
            # Try direct postgres restart
            fly machine exec "$PRIMARY_MACHINE" --app "$POSTGRES_APP_NAME" -- su - postgres -c "pg_ctl restart -D /data/postgresql" 2>/dev/null || {
                print_warning "Direct postgres restart failed, trying machine restart..."
                fly machine restart "$PRIMARY_MACHINE" --app "$POSTGRES_APP_NAME"
            }
        }
    fi
}

# Function to promote a standby to primary
promote_standby() {
    print_status "Promoting a standby to primary..."
    
    # Find the first available machine to promote
    PROMOTE_MACHINE=$(fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[0].id')
    
    if [[ -n "$PROMOTE_MACHINE" && "$PROMOTE_MACHINE" != "null" ]]; then
        print_status "Attempting to promote machine $PROMOTE_MACHINE to primary..."
        fly machine exec "$PROMOTE_MACHINE" --app "$POSTGRES_APP_NAME" -- su - postgres -c "repmgr standby promote --force --siblings-follow"
        sleep 10
        
        # Restart other machines to follow new primary
        fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read other_machine; do
            if [[ -n "$other_machine" && "$other_machine" != "$PROMOTE_MACHINE" ]]; then
                print_status "Restarting machine $other_machine to follow new primary..."
                fly machine restart "$other_machine" --app "$POSTGRES_APP_NAME"
                sleep 5
            fi
        done
    else
        print_error "No machines available for promotion"
    fi
}

# Function to scale the app (Machines v2 compatible restart)
scale_restart() {
    print_status "Performing Machines v2 compatible restart..."
    
    # Get current machine count
    local current_count
    current_count=$(fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq '. | length')
    
    print_status "Current machine count: $current_count"
    print_warning "This will stop and start all machines (Machines v2 approach). Continue? (y/N)"
    read -r confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_status "Stopping all machines..."
        fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
            if [[ -n "$machine_id" ]]; then
                execute_command "fly machine stop '$machine_id' --app '$POSTGRES_APP_NAME'" "Stop machine $machine_id"
            fi
        done
        
        sleep 30
        
        print_status "Starting all machines..."
        fly machine list --app "$POSTGRES_APP_NAME" --json 2>/dev/null | jq -r '.[].id' | while read machine_id; do
            if [[ -n "$machine_id" ]]; then
                execute_command "fly machine start '$machine_id' --app '$POSTGRES_APP_NAME'" "Start machine $machine_id"
            fi
        done
    fi
}

# Function to check application logs
check_logs() {
    print_status "Checking recent logs for errors..."
    
    echo "=== PostgreSQL Error Logs ==="
    fly logs --app "$POSTGRES_APP_NAME" -n "$LOG_LINES" | grep -E "(ERROR|FATAL|PANIC|repmgr|haproxy)" || echo "No errors found in recent logs"
    
    echo -e "\n=== Recent Connection Errors ==="
    fly logs --app "$POSTGRES_APP_NAME" -n "$LOG_LINES" | grep -i "connection refused" || echo "No connection errors found"
}

# Function to display recovery menu
show_menu() {
    echo ""
    echo "=== Fly.io PostgreSQL Recovery Menu ==="
    echo "1. Check cluster status"
    echo "2. Check database connectivity"
    echo "3. Check PostgreSQL cluster status"
    echo "4. Check repmgr status"
    echo "5. Check machine resources"
    echo "6. Check DNS resolution"
    echo "7. Create backup"
    echo "8. Restart failed machines only"
    echo "9. Force restart ALL machines"
    echo "10. Attempt PostgreSQL recovery"
    echo "11. Promote standby to primary"
    echo "12. Scale restart (stop/start all machines)"
    echo "13. Check error logs"
    echo "14. Full diagnostic report"
    echo "15. Auto recovery (recommended)"
    echo "0. Exit"
    echo ""
}

# Function to run full diagnostic
full_diagnostic() {
    print_status "Running full diagnostic report..."
    
    echo "======================================"
    echo "FULL DIAGNOSTIC REPORT"
    echo "App: $POSTGRES_APP_NAME"
    echo "Time: $(date)"
    echo "======================================"
    
    get_cluster_status
    echo -e "\n" && check_db_connectivity
    echo -e "\n" && check_postgres_cluster_status
    echo -e "\n" && check_repmgr_status
    echo -e "\n" && check_machine_resources
    echo -e "\n" && check_dns
    echo -e "\n" && check_logs
    
    echo "======================================"
    echo "DIAGNOSTIC REPORT COMPLETE"
    echo "======================================"
}

# Function to run automatic recovery
auto_recovery() {
    print_status "Starting automatic recovery process..."
    
    # Step 1: Create backup
    create_backup
    
    # Step 2: Check connectivity
    if ! check_db_connectivity; then
        print_status "Database not accessible, starting recovery procedures..."
        
        # Step 3: Try restarting failed machines first
        restart_machines
        sleep 30
        
        # Step 4: Check again
        if ! check_db_connectivity; then
            print_status "Still not accessible, trying PostgreSQL recovery..."
            # Step 5: Try PostgreSQL recovery
            postgres_recovery
            sleep 30
            
            # Step 6: Final check
            if ! check_db_connectivity; then
                print_warning "Standard recovery failed. Trying force restart..."
                force_restart_all
            fi
        fi
    else
        print_success "Database is already accessible!"
    fi
    
    # Final status check
    sleep 30
    print_status "Recovery complete. Final status check:"
    get_cluster_status
}

# Main script
main() {
    echo "=== Fly.io PostgreSQL Recovery Script (Updated 2025) ==="
    echo ""
    
    check_flyctl
    
    if [[ -z "$POSTGRES_APP_NAME" ]]; then
        discover_postgres_app
    fi
    
    while true; do
        show_menu
        read -p "Select an option: " choice
        
        case $choice in
            1) get_cluster_status ;;
            2) check_db_connectivity ;;
            3) check_postgres_cluster_status ;;
            4) check_repmgr_status ;;
            5) check_machine_resources ;;
            6) check_dns ;;
            7) create_backup ;;
            8) restart_machines ;;
            9) force_restart_all ;;
            10) postgres_recovery ;;
            11) promote_standby ;;
            12) scale_restart ;;
            13) check_logs ;;
            14) full_diagnostic ;;
            15) auto_recovery ;;
            0) print_status "Exiting..."; exit 0 ;;
            *) print_error "Invalid option. Please try again." ;;
        esac
        
        echo ""
        read -p "Press Enter to continue..."
    done
}

# Handle command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -a|--app)
            POSTGRES_APP_NAME="$2"
            shift 2
            ;;
        -l|--log-lines)
            LOG_LINES="$2"
            shift 2
            ;;
        --no-backup)
            BACKUP_BEFORE_RECOVERY=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --log-file)
            LOG_FILE="$2"
            shift 2
            ;;
        --auto)
            check_flyctl
            if [[ -z "$POSTGRES_APP_NAME" ]]; then
                discover_postgres_app
            fi
            auto_recovery
            exit 0
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -a, --app NAME        PostgreSQL app name"
            echo "  -l, --log-lines NUM   Number of log lines to check (default: 100)"
            echo "  --no-backup           Skip backup creation"
            echo "  --dry-run             Show what would be executed without running commands"
            echo "  --log-file FILE       Write operation log to specified file"
            echo "  --auto                Run automatic recovery and exit"
            echo "  -h, --help            Show this help"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Run main function
main