#!/usr/bin/env zsh
# Zsh Storage Saturation Backup Script (macOS Compatible)
# Dynamic Drive Selection, Checklist & Size Validation Edition

USERNAME=$(whoami)
SOURCE_ROOT="$HOME"
SIZE_CHECK_ENABLED=true
LARGE_FILE_AUDIT=false

# ANSI Color Codes
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RED='\033[0;31m'
GRAY='\033[1;30m'
BLACK_ON_CYAN='\033[30;46m'
BLACK_ON_GREEN='\033[30;42m'
BLACK_ON_RED='\033[30;41m'
NC='\033[0m' # No Color

# Hide cursor on exit
trap 'tput cnorm; clear; exit 0' INT TERM

# --- TUI MENU ENGINE FUNCTION (SINGLE SELECTION) ---
show_tui_menu() {
    local title="$1"
    shift
    local options=("$@")
    local current_index=0
    local key

    tput civis # Hide cursor
    while true; do
        tput cup 0 0 # Cursor to top left
        echo -e "${CYAN}=====================================================================${NC}"
        echo -e "  ${YELLOW}${title}${NC}"
        echo -e "${CYAN}=====================================================================${NC}"
        echo -e " Navigation: [↑/↓] | Select: [Enter] | Back: [Esc] | Quit: [Q]\n"

        for i in {1..${#options[@]}}; do
            if [[ $((i-1)) -eq $current_index ]]; then
                echo -e "  -> ${BLACK_ON_CYAN}[ X ] ${options[i]} ${NC}"
            else
                echo -e "     [   ] ${options[i]} "
            fi
        done
        echo -e "\n${CYAN}=====================================================================${NC}\n"

        # Read 1 character silently
        read -sk 1 key
        if [[ $key == $'\e' ]]; then
            read -sk 2 -t 0.1 rest
            key="$key$rest"
        fi

        case $key in
            $'\e[A') ((current_index--)); [[ $current_index -lt 0 ]] && current_index=$((${#options[@]} - 1)) ;; # Up
            $'\e[B') ((current_index++)); [[ $current_index -ge ${#options[@]} ]] && current_index=0 ;;         # Down
            $'\n'|$'\r') tput cnorm; clear; return $current_index ;;                                            # Enter
            $'\e') tput cnorm; clear; return 255 ;;                                                             # Esc
            q|Q) tput cnorm; clear; echo -e "\n${RED}Operation aborted by user (Q pressed).${NC}"; exit 0 ;;    # Q
        esac
    done
}

# --- TUI CHECKLIST ENGINE FUNCTION (MULTI-SELECTION) ---
show_tui_checklist() {
    local title="$1"
    local current_index=0
    local key

    # Snapshot state for Escape functionality
    typeset -A initial_state
    for item in "${backup_items[@]}"; do
        initial_state[$item]=$item_enabled[$item]
    done

    tput civis
    while true; do
        tput cup 0 0
        echo -e "${CYAN}=====================================================================${NC}"
        echo -e "  ${YELLOW}${title}${NC}"
        echo -e "${CYAN}=====================================================================${NC}"
        echo -e " Navigation: [↑/↓] | Toggle: [Space] | Save: [Enter] | Cancel: [Esc] | Quit: [Q]\n"

        local i=0
        for item in "${backup_items[@]}"; do
            local check="[ ]"
            [[ ${item_enabled[$item]} == true ]] && check="[X]"
            
            if [[ $i -eq $current_index ]]; then
                echo -e "  -> ${BLACK_ON_CYAN}$check $item ${NC}"
            else
                echo -e "     ${GRAY}$check $item ${NC}"
            fi
            ((i++))
        done
        
        if [[ $current_index -eq ${#backup_items[@]} ]]; then
            echo -e "\n  -> ${BLACK_ON_GREEN}[ CONFIRM SELECTION AND RETURN ] ${NC}"
        else
            echo -e "\n     ${GREEN}[ CONFIRM SELECTION AND RETURN ] ${NC}"
        fi
        echo -e "\n${CYAN}=====================================================================${NC}\n\n"

        read -sk 1 key
        if [[ $key == $'\e' ]]; then
            read -sk 2 -t 0.1 rest
            key="$key$rest"
        fi

        case $key in
            $'\e[A') ((current_index--)); [[ $current_index -lt 0 ]] && current_index=${#backup_items[@]} ;;
            $'\e[B') ((current_index++)); [[ $current_index -gt ${#backup_items[@]} ]] && current_index=0 ;;
            ' ') 
                if [[ $current_index -lt ${#backup_items[@]} ]]; then
                    local target="${backup_items[$((current_index+1))]}"
                    if [[ ${item_enabled[$target]} == true ]]; then
                        item_enabled[$target]=false
                    else
                        item_enabled[$target]=true
                    fi
                fi
                ;;
            $'\n'|$'\r') 
                if [[ $current_index -eq ${#backup_items[@]} ]]; then
                    tput cnorm; clear; return 0
                fi
                ;;
            $'\e') 
                for item in "${backup_items[@]}"; do item_enabled[$item]=${initial_state[$item]}; done
                tput cnorm; clear; return 1 
                ;;
            q|Q) tput cnorm; clear; echo -e "\n${RED}Operation aborted by user (Q pressed).${NC}"; exit 0 ;;
        esac
    done
}

# --- RSYNC LOG AUDITING ENGINE ---
verify_rsync_log() {
    local item_name="$1"
    local log_file="$2"
    
    echo -e " -> Parsing transfer summary for: ${CYAN}$item_name${NC}..."
    
    # Rsync --stats outputs lines we can parse
    local total_files=$(grep "Number of files:" "$log_file" | awk '{print $4}')
    local errors=$(grep -i -E "rsync error:|failed:" "$log_file")
    
    if [[ -z "$errors" && -n "$total_files" ]]; then
        echo -e "    ${GREEN}[✓] Pass: Data mirrored. $total_files file(s) accounted for with 0 failures.${NC}"
    else
        echo -e "    ${RED}[!] ALERT: File transfer errors detected!${NC}"
        if [[ -z "$errors" ]]; then
            echo "    -> Log parsing failed or transfer was incomplete." >> "$log_file.err"
        else
            echo "$errors" | while read -r line; do
                echo "    -> $line" >> "$log_file.err"
            done
        fi
        return 1
    fi
    return 0
}

# --- BROWSER PROFILE SCANNER (macOS Paths) ---
get_browser_profiles() {
    local browser="$1"
    local user_data_path="$2"
    
    if [[ ! -d "$user_data_path" ]]; then return; fi
    
    # Capitalize browser name
    local browser_name="${(C)browser}"
    
    if [[ "$browser" == "chrome" || "$browser" == "edge" ]]; then
        for folder in "$user_data_path"/Default "$user_data_path"/Profile*; do
            if [[ -d "$folder" ]]; then
                local folder_name=$(basename "$folder")
                local target_name="$browser_name/$folder_name"
                backup_items+=("$target_name")
                item_src[$target_name]="$folder"
                item_dest[$target_name]="$target_name"
                item_enabled[$target_name]=true
            fi
        done
    elif [[ "$browser" == "firefox" ]]; then
        for folder in "$user_data_path"/*.default-release; do
            if [[ -d "$folder" ]]; then
                local folder_name=$(basename "$folder")
                local target_name="Firefox/$folder_name"
                backup_items+=("$target_name")
                item_src[$target_name]="$folder"
                item_dest[$target_name]="$target_name"
                item_enabled[$target_name]=true
            fi
        done
    fi
}


# --- PHASE 1: STORAGE TARGET DETECTION ---
declare -a drive_options
declare -A drive_mapping

# macOS typically mounts external drives in /Volumes
for vol in /Volumes/*; do
    if [[ -d "$vol" && ! -L "$vol" ]]; then
        # Exclude system volumes (like Macintosh HD if mounted weirdly)
        if [[ "$vol" != "/Volumes/Macintosh HD" ]]; then
            drive_options+=("$vol")
            drive_mapping["$vol"]="$vol"
        fi
    fi
done

if [[ ${#drive_options[@]} -eq 0 ]]; then
    echo -e "${RED}Critical Failure: No external storage drives found in /Volumes!${NC}"
    exit 1
fi

show_tui_menu "SELECT DESTINATION STORAGE DRIVE" "${drive_options[@]}"
menu_result=$?
if [[ $menu_result -eq 255 ]]; then
    echo -e "${RED}Operation aborted.${NC}"
    exit 0
fi

CHOSEN_DRIVE="${drive_options[$((menu_result+1))]}"
DEST_ROOT="$CHOSEN_DRIVE/$USERNAME"


# --- PHASE 2: ENVIRONMENT STAGING ---
declare -a backup_items
typeset -A item_src
typeset -A item_dest
typeset -A item_enabled
typeset -A global_excluded_files

# Standard macOS Directories (Note: Movies instead of Videos)
standard_dirs=("Desktop" "Documents" "Downloads" "Pictures" "Movies" "Music")
for dir in "${standard_dirs[@]}"; do
    if [[ -d "$SOURCE_ROOT/$dir" ]]; then
        backup_items+=("$dir")
        item_src[$dir]="$SOURCE_ROOT/$dir"
        item_dest[$dir]="$dir"
        item_enabled[$dir]=true
    fi
done

get_browser_profiles "chrome" "$HOME/Library/Application Support/Google/Chrome"
get_browser_profiles "edge" "$HOME/Library/Application Support/Microsoft Edge"
get_browser_profiles "firefox" "$HOME/Library/Application Support/Firefox/Profiles"


# --- PHASE 3: MAIN OPERATIONAL TUI LOOP ---
running=true
while $running; do
    selected_count=0
    for item in "${backup_items[@]}"; do
        [[ ${item_enabled[$item]} == true ]] && ((selected_count++))
    done
    
    size_check_status="DISABLED"
    [[ $SIZE_CHECK_ENABLED == true ]] && size_check_status="ENABLED"
    
    large_file_status="DISABLED"
    [[ $LARGE_FILE_AUDIT == true ]] && large_file_status="ENABLED"
    
    menu_title="SATURATION BACKUP ENGINE | Target: $CHOSEN_DRIVE"
    menu_items=(
        "Start Backup Operation ($selected_count items staged)"
        "Configure Backup Locations"
        "Toggle Pre-Flight Large File Audit (5GB+) [$large_file_status]"
        "Toggle Post-Copy Size Auditing [$size_check_status]"
        "Preview Destination Mapping Path"
        "Exit Utility"
    )

    show_tui_menu "$menu_title" "${menu_items[@]}"
    selection=$?

    case $selection in
        0) # Start Backup
            if [[ $selected_count -eq 0 ]]; then
                echo -e "${RED}Error: You must select at least one location to backup!${NC}"
                sleep 2
                continue
            fi

            user_cancelled=false

            # Intercept for 5GB+ File Audit
            if [[ $LARGE_FILE_AUDIT == true ]]; then
                for item in "${backup_items[@]}"; do
                    if [[ ${item_enabled[$item]} == true ]]; then
                        clear
                        echo -e "${CYAN}Scanning $item for files over 5GB. Please wait...${NC}"
                        
                        # BSD find uses +5G for Greater than 5 Gigabytes
                        large_files_raw=("${(@f)$(find "${item_src[$item]}" -type f -size +5G 2>/dev/null)}")
                        
                        if [[ ${#large_files_raw[@]} -gt 0 && -n "${large_files_raw[1]}" ]]; then
                            declare -a large_file_menu
                            typeset -A large_file_paths
                            
                            for lf in "${large_files_raw[@]}"; do
                                size_bytes=$(stat -f%z "$lf")
                                size_gb=$(awk "BEGIN {printf \"%.2f\", $size_bytes/1073741824}")
                                display_name="[$size_gb GB] $lf"
                                large_file_menu+=("$display_name")
                                large_file_paths["$display_name"]="$lf"
                            done
                            
                            # Temporarily swap engine arrays to reuse checklist
                            local backup_cache=("${backup_items[@]}")
                            backup_items=("${large_file_menu[@]}")
                            for m_item in "${backup_items[@]}"; do item_enabled[$m_item]=true; done
                            
                            show_tui_checklist "Review 5GB+ Files in $item (Uncheck to Skip)"
                            audit_result=$?
                            
                            # Restore arrays
                            backup_items=("${backup_cache[@]}")
                            
                            if [[ $audit_result -eq 1 ]]; then
                                user_cancelled=true
                                break
                            fi
                            
                            # Gather skipped
                            skipped_str=""
                            for m_item in "${large_file_menu[@]}"; do
                                if [[ ${item_enabled[$m_item]} == false ]]; then
                                    skipped_str+=" --exclude=\"$(basename "${large_file_paths[$m_item]}")\""
                                fi
                            done
                            global_excluded_files[$item]=$skipped_str
                        fi
                    fi
                done
            fi

            if [[ $user_cancelled == false ]]; then
                running=false
            fi
            ;;
        1) # Configure Locations
            show_tui_checklist "Toggle Locations Using [Space]"
            ;;
        2) # Toggle Audit
            if [[ $LARGE_FILE_AUDIT == true ]]; then LARGE_FILE_AUDIT=false; else LARGE_FILE_AUDIT=true; fi
            ;;
        3) # Toggle Size
            if [[ $SIZE_CHECK_ENABLED == true ]]; then SIZE_CHECK_ENABLED=false; else SIZE_CHECK_ENABLED=true; fi
            ;;
        4) # Preview Paths
            clear
            echo -e "${YELLOW}=== Dynamic Backup Path Blueprint ===${NC}"
            for item in "${backup_items[@]}"; do
                status="SKIPPED"
                color=$GRAY
                if [[ ${item_enabled[$item]} == true ]]; then
                    status="ACTIVE "
                    color=$CYAN
                fi
                echo -e " [${color}$status${NC}] Target: $item"
                echo -e "          ${GRAY}From:   ${item_src[$item]}${NC}"
                echo -e "          ${GRAY}To:     $DEST_ROOT/${item_dest[$item]}${NC}"
                echo -e " -----------------------------------------------------------"
            done
            echo -e "\n${YELLOW}Press any key to return to the main menu...${NC}"
            read -sk 1
            ;;
        5|255) # Exit
            echo -e "${RED}Operation aborted.${NC}"
            exit 0
            ;;
    esac
done


# --- PHASE 4: RSYNC EXECUTION ENGINE ---
clear
echo -e "${GREEN}Initializing backup matrix execution...${NC}"

temp_log="/tmp/rsync_migration.log"
typeset -A audit_logs

for item in "${backup_items[@]}"; do
    if [[ ${item_enabled[$item]} == false ]]; then
        echo -e "\n${GRAY}Skipping (Disabled by User): $item${NC}"
        continue
    fi
    if [[ ! -d "${item_src[$item]}" ]]; then
        echo -e "\n${YELLOW}Skipping (Directory Not Found): ${item_src[$item]}${NC}"
        continue
    fi
    
    dst="$DEST_ROOT/${item_dest[$item]}"
    mkdir -p "$dst"
    
    echo -e "\n${CYAN}Mirroring structure: $item${NC}"
    
    rm -f "$temp_log"
    
    # Build rsync command: -a (Archive/Mirror), -v (Verbose for parsing), --delete (Sync dest), --stats (For Phase 5)
    rsync_cmd="rsync -a -v --delete --stats"
    
    if [[ -n "${global_excluded_files[$item]}" ]]; then
        rsync_cmd+=" ${global_excluded_files[$item]}"
    fi
    
    rsync_cmd+=" \"${item_src[$item]}/\" \"$dst/\" > \"$temp_log\" 2>&1"
    
    # Execute in background for live-tail UI
    eval "$rsync_cmd" &
    pid=$!
    
    spinner=('|' '/' '-' '\')
    spin_index=0
    
    tput civis
    while kill -0 $pid 2>/dev/null; do
        if [[ -f "$temp_log" ]]; then
            # Tail the last file transferred
            last_line=$(tail -n 3 "$temp_log" | grep -v "/$" | tail -n 1 | cut -c 1-62)
            if [[ -n "$last_line" && "$last_line" != *"Number of files"* && "$last_line" != *"sending incremental file list"* ]]; then
                printf "\r  [%c] Copying: %-62s" "${spinner[$((spin_index % 4))]}" "$last_line"
            fi
        fi
        ((spin_index++))
        sleep 0.15
    done
    
    printf "\r  ${GREEN}[✓] Transfer Complete!                                                              ${NC}\n"
    audit_logs[$item]="$temp_log.$item.saved"
    mv "$temp_log" "${audit_logs[$item]}"
done


# --- PHASE 5: INTERACTIVE SIZE & COUNT FOOTPRINT AUDIT ---
if [[ $SIZE_CHECK_ENABLED == true ]]; then
    echo -e "\n${CYAN}=====================================================================${NC}"
    echo -e " ${YELLOW}Analyzing Post-Copy Rsync Summaries...${NC}"
    echo -e "${CYAN}=====================================================================${NC}"
    
    declare -a failed_items

    for item in "${backup_items[@]}"; do
        if [[ ${item_enabled[$item]} == true && -f "${audit_logs[$item]}" ]]; then
            verify_rsync_log "$item" "${audit_logs[$item]}"
            if [[ $? -ne 0 ]]; then
                failed_items+=("$item")
            fi
        fi
    done

    if [[ ${#failed_items[@]} -gt 0 ]]; then
        echo -ne "\n${YELLOW}[?] Would you like to view the detailed list of failed files? (Y/N): ${NC}"
        while true; do
            read -sk 1 key
            if [[ $key == 'y' || $key == 'Y' ]]; then
                echo -e "${YELLOW}$key${NC}"
                
                error_export_path="$SOURCE_ROOT/Desktop/Migration_Failed_Files_$(date +%Y%m%d_%H%M%S).txt"
                
                clear
                echo -e "${RED}=====================================================================${NC}"
                echo -e "  ${YELLOW}FAILED FILE TRANSFER REPORT${NC}"
                echo -e "${RED}=====================================================================${NC}"
                
                for f_item in "${failed_items[@]}"; do
                    echo -e "\n ${BLACK_ON_RED} LOCATION: $f_item ${NC}"
                    echo "LOCATION: $f_item" >> "$error_export_path"
                    echo "---------------------------------------------------" >> "$error_export_path"
                    
                    if [[ -f "${audit_logs[$f_item]}.err" ]]; then
                        cat "${audit_logs[$f_item]}.err" | while read -r err_line; do
                            echo -e " ${GRAY}-> $err_line${NC}"
                            echo " -> $err_line" >> "$error_export_path"
                        done
                    fi
                    echo "" >> "$error_export_path"
                done
                
                echo -e "\n${RED}=====================================================================${NC}"
                echo -e " ${CYAN}[i] A full copy of this report was saved to: $error_export_path${NC}"
                echo -e "${RED}=====================================================================${NC}"
                echo -e "${YELLOW}Press any key to return to termination sequence...${NC}"
                read -sk 1
                echo ""
                break
            elif [[ $key == 'n' || $key == 'N' ]]; then
                echo -e "${YELLOW}$key${NC}"
                break
            fi
        done
    fi
fi


# --- PHASE 6: TERMINATION ---
tput cnorm
echo -e "\n${GREEN}Backup operation process sequence finalized.${NC}"
echo -ne "Script terminating in 5 seconds."

for i in {1..5}; do
    sleep 1
    echo -ne "."
done
echo ""
