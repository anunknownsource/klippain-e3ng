#!/usr/bin/env bash
#################################################
###### AUTOMATED INSTALL AND UPDATE SCRIPT ######
#################################################
# Written by yomgui1 & Frix_x
# @version: 1.3

# CHANGELOG:
#   v1.4: added Shake&Tune install call
#   v1.3: - added a warning on first install to be sure the user wants to install klippain and fixed a bug
#           where some artefacts of the old user config where still present after the install (harmless bug but not clean)
#         - automated the install of the Gcode shell commands plugin
#   v1.2: fixed some bugs and adding small new features:
#          - now it's ok to use the install script with the user config folder absent
#          - avoid copying all the existing MCU templates to the user config directory during install to keep it clean
#          - updated the logic to keep the user custom files and folders structure during a backup (it was previously flattened)
#   v1.1: added an MCU template automatic installation system
#   v1.0: first version of the script to allow a peaceful install and update ;)


# Where the user Klipper config is located (ie. the one used by Klipper to work)
USER_CONFIG_PATH="${HOME}/printer_data/config"
# Where to clone Frix-x repository config files (read-only and keep untouched)
FRIX_CONFIG_PATH="${HOME}/klippain_config"
# Path used to store backups when updating (backups are automatically dated when saved inside)
BACKUP_PATH="${HOME}/klippain_config_backups"
# Where the Klipper folder is located (ie. the internal Klipper firmware machinery)
KLIPPER_PATH="${HOME}/klipper"
# Branch from Frix-x/klippain repo to use during install (default: main)
FRIX_BRANCH="main"


set -eu
export LC_ALL=C

# Step 1: Verify that the script is not run as root and Klipper is installed.
#         Then if it's a first install, warn and ask the user if he is sure to proceed
function preflight_checks {
    if [ "$EUID" -eq 0 ]; then
        echo "[PRE-CHECK] This script must not be run as root!"
        exit -1
    fi

    if [ "$(sudo systemctl list-units --full -all -t service --no-legend | grep -F 'klipper.service')" ]; then
        printf "[PRE-CHECK] Klipper service found! Continuing...\n\n"
    else
        echo "[ERROR] Klipper service not found, please install Klipper first!"
        exit -1
    fi

    local install_klippain_answer
    if [ ! -f "${USER_CONFIG_PATH}/.VERSION" ]; then
        echo "[PRE-CHECK] New installation of Klippain detected!"
        echo "[PRE-CHECK] This install script will WIPE AND REPLACE your current Klipper config with the full Klippain system (a backup will be kept)"
        echo "[PRE-CHECK] Be sure that the printer is idle before continuing!"
        
        read < /dev/tty -rp "[PRE-CHECK] Are you sure want to proceed and install Klippain? (y/N) " install_klippain_answer
        if [[ -z "$install_klippain_answer" ]]; then
            install_klippain_answer="n"
        fi
        install_klippain_answer="${install_klippain_answer,,}"

        if [[ "$install_klippain_answer" =~ ^(yes|y)$ ]]; then
            printf "[PRE-CHECK] Installation confirmed! Continuing...\n\n"
        else
            echo "[PRE-CHECK] Installation was canceled!"
            exit -1
        fi
    fi
}


# Step 2: Check if the git config folder exist (or download it)
function check_download {
    local frixtemppath frixreponame
    frixtemppath="$(dirname ${FRIX_CONFIG_PATH})"
    frixreponame="$(basename ${FRIX_CONFIG_PATH})"
    frixbranchname="${FRIX_BRANCH}"

    if [ ! -d "${FRIX_CONFIG_PATH}" ]; then
        echo "[DOWNLOAD] Downloading Klippain repository..."
        if git -C $frixtemppath clone -b $frixbranchname https://github.com/Frix-x/klippain.git $frixreponame; then
            printf "[DOWNLOAD] Download complete!\n\n"
        else
            echo "[ERROR] Download of Klippain git repository failed!"
            exit -1
        fi
    else
        printf "[DOWNLOAD] Klippain repository already found locally. Continuing...\n\n"
    fi
}


# Step 3: Backup the old Klipper configuration
function backup_config {
    local link link_target

    if [ ! -e "${USER_CONFIG_PATH}" ]; then
        printf "[BACKUP] No previous config found, skipping backup...\n\n"
        return 0
    fi

    mkdir -p ${BACKUP_DIR}

    # Copy every files from the user config ("2>/dev/null || :" allow it to fail silentely in case the config dir doesn't exist)
    cp -fa ${USER_CONFIG_PATH}/. ${BACKUP_DIR} 2>/dev/null || :
    # Then delete Klippain-managed symlinks while preserving external config symlinks like mainsail.cfg
    while IFS= read -r -d '' link; do
        link_target="$(readlink -f "${link}" 2>/dev/null || true)"
        case "${link_target}" in
            "${FRIX_CONFIG_PATH}"|"${FRIX_CONFIG_PATH}"/*)
                rm -f "${link}"
                ;;
        esac
    done < <(find "${BACKUP_DIR}" -type l -print0)

    # If Klippain is not already installed (we check for .VERSION in the backup to detect it),
    # we need to remove, wipe and clean the current user config folder...
    if [ ! -f "${BACKUP_DIR}/.VERSION" ]; then
        rm -fR ${USER_CONFIG_PATH}
    fi

    printf "[BACKUP] Backup of current user config files done in: ${BACKUP_DIR}\n\n"
}

# ================================================================
# USER CONFIG MIGRATION
#
# During an update:
#   - printer.cfg is rebuilt from the newest template while
#     preserving the user's enabled includes and custom includes.
#
#   - variables.cfg is rebuilt from the newest template while
#     preserving the user's existing variable values.
#
# Existing values are NEVER automatically changed to new defaults.
# ================================================================

function update_user_templates {
    local old_printer="${BACKUP_DIR}/printer.cfg"
    local old_variables="${BACKUP_DIR}/variables.cfg"

    local new_printer="${FRIX_CONFIG_PATH}/user_templates/printer.cfg"
    local new_variables="${FRIX_CONFIG_PATH}/user_templates/variables.cfg"

    local live_printer="${USER_CONFIG_PATH}/printer.cfg"
    local live_variables="${USER_CONFIG_PATH}/variables.cfg"

    echo "[CONFIG-UPDATE] Migrating user configuration..."

    if [[ -f "$old_printer" && -f "$new_printer" ]]; then
        migrate_printer_config \
            "$old_printer" \
            "$new_printer" \
            "$live_printer"
    else
        echo "[CONFIG-UPDATE] WARNING: Unable to migrate printer.cfg."
        echo "[CONFIG-UPDATE] Old config or new template is missing."
    fi

    if [[ -f "$old_variables" && -f "$new_variables" ]]; then
        migrate_variables_config \
            "$old_variables" \
            "$new_variables" \
            "$live_variables"
    else
        echo "[CONFIG-UPDATE] WARNING: Unable to migrate variables.cfg."
        echo "[CONFIG-UPDATE] Old config or new template is missing."
    fi

    printf "[CONFIG-UPDATE] User configuration migration complete!\n\n"
}


# ================================================================
# PRINTER.CFG MIGRATION
# ================================================================

function migrate_printer_config {
    local old_config="$1"
    local new_template="$2"
    local output_config="$3"

    local config_dir
    local config_name
    local tmp_file

    config_dir="$(dirname "$output_config")"
    config_name="$(basename "$output_config")"

    mkdir -p "$config_dir"

    # Temporary file must be on the same filesystem as the final
    # configuration so mv performs an atomic rename.
    tmp_file="$(mktemp \
        "${config_dir}/.${config_name}.update.XXXXXX")" || {
        echo "[ERROR] Unable to create printer.cfg temporary file."
        return 1
    }

    echo "[CONFIG-UPDATE] Updating printer.cfg..."

    if ! awk '

    # ------------------------------------------------------------
    # Return the include portion of a line.
    #
    # Examples:
    #
    # [include config/foo.cfg]
    #
    # # [include config/foo.cfg] # description
    #
    # Both return:
    #
    # [include config/foo.cfg]
    # ------------------------------------------------------------

    function get_include(line, result, endpos) {
        result = line

        sub(/\r$/, "", result)
        sub(/^[[:space:]]*/, "", result)
        sub(/^#[[:space:]]*/, "", result)

        if (result !~ /^\[include[[:space:]]+/)
            return ""

        endpos = index(result, "]")

        if (endpos == 0)
            return ""

        result = substr(result, 1, endpos)

        return result
    }


    # ============================================================
    # OLD printer.cfg
    # ============================================================

    NR == FNR {

        key = get_include($0)

        if (key != "") {

            old_exists[key] = 1
            old_order[++old_count] = key

            # Save the original line in case this is a custom
            # include that no longer exists in the new template.
            old_original[key] = $0

            # Active include = first non-whitespace character
            # is NOT "#".
            test = $0
            sub(/^[[:space:]]*/, "", test)

            if (test !~ /^#/)
                old_active[key] = 1
        }

        next
    }


    # ============================================================
    # NEW printer.cfg TEMPLATE
    # ============================================================

    {
        new_lines[++new_count] = $0

        key = get_include($0)

        if (key != "") {
            new_exists[key] = 1
            new_line_number[key] = new_count
        }
    }


    # ============================================================
    # BUILD NEW printer.cfg
    # ============================================================

    END {

        # --------------------------------------------------------
        # Locate custom includes from the old config.
        #
        # Custom includes are inserted immediately after the
        # nearest preceding include that still exists in the
        # new template.
        # --------------------------------------------------------

        for (i = 1; i <= old_count; i++) {

            key = old_order[i]

            if (key in new_exists)
                continue

            anchor = ""

            for (j = i - 1; j >= 1; j--) {

                previous = old_order[j]

                if (previous in new_exists) {
                    anchor = previous
                    break
                }
            }

            if (anchor != "") {

                line_number = new_line_number[anchor]

                insert_count[line_number]++

                insert_after[
                    line_number,
                    insert_count[line_number]
                ] = old_original[key]

            } else {

                orphan_count++
                orphan[orphan_count] = old_original[key]
            }
        }


        # --------------------------------------------------------
        # Process the new template.
        # --------------------------------------------------------

        for (i = 1; i <= new_count; i++) {

            line = new_lines[i]
            key = get_include(line)

            if (key != "" && key in old_exists) {

                # Remove existing comment prefix.
                content = line
                sub(/^[[:space:]]*#[[:space:]]*/, "", content)

                if (key in old_active) {

                    # User had this include enabled.
                    line = content

                } else {

                    # User had this include disabled.
                    line = "# " content
                }
            }

            print line


            # Insert old custom includes after their closest
            # surviving anchor.
            if (i in insert_count) {

                for (
                    j = 1;
                    j <= insert_count[i];
                    j++
                ) {
                    print insert_after[i, j]
                }
            }
        }


        # --------------------------------------------------------
        # Includes with no surviving anchor.
        #
        # These are rare, but never silently discard user config.
        # --------------------------------------------------------

        if (orphan_count > 0) {

            print ""
            print "# ------------------------------------------------"
            print "# Preserved custom includes from previous config"
            print "# ------------------------------------------------"

            for (i = 1; i <= orphan_count; i++)
                print orphan[i]
        }
    }

    ' "$old_config" "$new_template" > "$tmp_file"; then

        echo "[ERROR] Failed to generate updated printer.cfg."
        rm -f "$tmp_file"
        return 1
    fi


    # ------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------

    if [[ ! -s "$tmp_file" ]]; then
        echo "[ERROR] Generated printer.cfg is empty."
        rm -f "$tmp_file"
        return 1
    fi

    if ! grep -qE \
        '^[[:space:]]*#?[[:space:]]*\[include[[:space:]]+' \
        "$tmp_file"; then

        echo "[ERROR] Generated printer.cfg contains no includes."
        rm -f "$tmp_file"
        return 1
    fi


    # Preserve permissions if possible.
    if [[ -f "$output_config" ]]; then
        chmod --reference="$output_config" "$tmp_file" 2>/dev/null || true
        chown --reference="$output_config" "$tmp_file" 2>/dev/null || true
    fi


    # ------------------------------------------------------------
    # Atomic replacement
    # ------------------------------------------------------------

    if ! mv -f "$tmp_file" "$output_config"; then
        echo "[ERROR] Unable to install updated printer.cfg."
        rm -f "$tmp_file"
        return 1
    fi

    echo "[CONFIG-UPDATE] printer.cfg successfully migrated."
}


# ================================================================
# VARIABLES.CFG MIGRATION
#
# Uses Python because variables.cfg contains Python-style multiline
# dictionaries. Parsing these safely in awk would be unnecessarily
# fragile.
# ================================================================

function migrate_variables_config {
    local old_config="$1"
    local new_template="$2"
    local output_config="$3"

    local config_dir
    local config_name
    local tmp_file

    config_dir="$(dirname "$output_config")"
    config_name="$(basename "$output_config")"

    mkdir -p "$config_dir"

    tmp_file="$(mktemp \
        "${config_dir}/.${config_name}.update.XXXXXX")" || {
        echo "[ERROR] Unable to create variables.cfg temporary file."
        return 1
    }

    echo "[CONFIG-UPDATE] Updating variables.cfg..."

    if ! python3 - \
        "$old_config" \
        "$new_template" \
        "$tmp_file" <<'PYTHON'
import re
import sys
from pathlib import Path

old_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])

VARIABLE_RE = re.compile(
    r'^(\s*)(variable_[A-Za-z0-9_]+)\s*:\s*(.*)$'
)

NEW_DEFAULT_RE = re.compile(
    r'\s+#new default=.*$',
    re.IGNORECASE
)

MULTILINE_NOTICE = (
    "# NEW DEFAULT AVAILABLE - "
    "see current Klippain variables.cfg"
)

def strip_new_default(value):
    """Remove an annotation previously created by this updater."""
    return NEW_DEFAULT_RE.sub("", value).rstrip()

def brace_delta(text):
    """
    Count {}, [] and () while ignoring quoted strings.

    Klippain multiline variable values are Python-like structures.
    This is sufficient to identify where the current dictionary,
    list, or tuple ends.
    """

    delta = 0
    quote = None
    escaped = False

    pairs = {
        "{": 1,
        "[": 1,
        "(": 1,
        "}": -1,
        "]": -1,
        ")": -1,
    }

    for char in text:
        if escaped:
            escaped = False
            continue
        if char == "\\" and quote:
            escaped = True
            continue
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            continue
        delta += pairs.get(char, 0)
    return delta

def parse_variables(lines):
    """
    Return information about every variable.

    Each entry contains:
      start      first line number
      end        last line number
      lines      complete variable value/block
      multiline whether the value spans multiple lines
    """

    variables = {}
    i = 0

    while i < len(lines):
        match = VARIABLE_RE.match(lines[i])
        if not match:
            i += 1
            continue
        name = match.group(2)
        first_value = strip_new_default(match.group(3))
        start = i
        end = i
        depth = brace_delta(first_value)

        # A positive brace depth indicates a multiline Python-style
        # dictionary/list/tuple.
        while depth > 0 and end + 1 < len(lines):
            end += 1
            depth += brace_delta(lines[end])
        block = lines[start:end + 1]

        # Remove our own old multiline warning if somehow captured.
        while (
            start > 0
            and lines[start - 1].strip() == MULTILINE_NOTICE
        ):
            start -= 1
        variables[name] = {
            "start": start,
            "value_start": i,
            "end": end,
            "lines": block,
            "multiline": end > i,
        }
        i = end + 1
    return variables

def normalized_value(entry):
    """
    Normalize a variable value for comparison while preserving the
    actual original text for output.
    """
    lines = entry["lines"]
    if not lines:
        return ""
    match = VARIABLE_RE.match(lines[0])
    if not match:
        return ""
    first = strip_new_default(match.group(3))
    if not entry["multiline"]:
        return first.strip()
    values = [first.rstrip()]
    for line in lines[1:]:
        values.append(line.rstrip())
    return "\n".join(values).strip()

def make_single_line(old_entry, new_entry):
    """
    Preserve the old value while using the variable spelling/
    formatting from the new template.
    """

    old_match = VARIABLE_RE.match(old_entry["lines"][0])
    new_match = VARIABLE_RE.match(new_entry["lines"][0])

    old_value = strip_new_default(old_match.group(3))
    new_value = strip_new_default(new_match.group(3))

    # Preserve inline comments that belong to the user's value.
    #
    # The entire old RHS is retained. The new default annotation is
    # simply appended.
    if old_value.strip() == new_value.strip():
        return [old_entry["lines"][0].rstrip()]
    return [
        f"{old_entry['lines'][0].rstrip()} "
        f"#new default={new_value.strip()}"
    ]

def make_multiline(old_entry, new_entry):
    """
    Preserve the complete old multiline block.
    If the new template differs, place a warning immediately above
    the variable.
    """
    old_value = normalized_value(old_entry)
    new_value = normalized_value(new_entry)
    block = list(old_entry["lines"])
    if old_value == new_value:
        return block
    return [MULTILINE_NOTICE] + block

old_lines = old_path.read_text(
    encoding="utf-8"
).splitlines()
template_lines = template_path.read_text(
    encoding="utf-8"
).splitlines()

old_vars = parse_variables(old_lines)
new_vars = parse_variables(template_lines)

# ----------------------------------------------------------------
# Statistics
# ----------------------------------------------------------------
preserved = 0
new_count = 0
changed_defaults = 0
multiline_changed = 0
custom_count = 0

# ----------------------------------------------------------------
# Build output from the NEW template.
#
# This preserves new comments, organization and documentation.
# ----------------------------------------------------------------
output = []
i = 0
while i < len(template_lines):
    line = template_lines[i]
    match = VARIABLE_RE.match(line)
    if not match:
        output.append(line)
        i += 1
        continue
    name = match.group(2)
    new_entry = new_vars[name]

    # Variable exists only in new template.
    if name not in old_vars:
        output.extend(new_entry["lines"])
        new_count += 1
        i = new_entry["end"] + 1
        continue

    old_entry = old_vars[name]
    old_value = normalized_value(old_entry)
    new_value = normalized_value(new_entry)
    preserved += 1
    if old_value != new_value:
        changed_defaults += 1

    # Multiline on either side: preserve complete old block.
    if old_entry["multiline"] or new_entry["multiline"]:
        block = make_multiline(old_entry, new_entry)
        if old_value != new_value:
            multiline_changed += 1
        output.extend(block)
    else:
        output.extend(
            make_single_line(old_entry, new_entry)
        )

    i = new_entry["end"] + 1

# ----------------------------------------------------------------
# Preserve variables that no longer exist in the new template.
#
# These may be user-created variables or variables removed upstream.
# Never silently delete them.
# ----------------------------------------------------------------
custom_variables = [
    name
    for name in old_vars
    if name not in new_vars
]
if custom_variables:
    output.extend([
        "",
        "# ------------------------------------------------",
        "# Preserved variables from previous configuration",
        "# ------------------------------------------------",
    ])
    # Preserve original order.
    custom_variables.sort(
        key=lambda name: old_vars[name]["value_start"]
    )
    for name in custom_variables:
        entry = old_vars[name]
        output.extend(entry["lines"])
        custom_count += 1

output_path.write_text(
    "\n".join(output) + "\n",
    encoding="utf-8"
)

# Machine-readable statistics returned to the shell through stderr
# would complicate installer output, so print the report here.
print(
    f"[CONFIG-UPDATE]   {preserved} existing variables preserved"
)
print(
    f"[CONFIG-UPDATE]   {new_count} new variables added"
)
print(
    f"[CONFIG-UPDATE]   {changed_defaults} variables have "
    f"new defaults"
)
if multiline_changed:
    print(
        f"[CONFIG-UPDATE]   {multiline_changed} multiline "
        f"variables have new defaults"
    )
if custom_count:
    print(
        f"[CONFIG-UPDATE]   {custom_count} custom/deprecated "
        f"variables preserved"
    )
PYTHON
    then
        echo "[ERROR] Failed to generate updated variables.cfg."
        rm -f "$tmp_file"
        return 1
    fi

    # ------------------------------------------------------------
    # Validation
    # ------------------------------------------------------------
    if [[ ! -s "$tmp_file" ]]; then
        echo "[ERROR] Generated variables.cfg is empty."
        rm -f "$tmp_file"
        return 1
    fi
    if ! grep -qE \
        '^[[:space:]]*variable_[A-Za-z0-9_]+[[:space:]]*:' \
        "$tmp_file"; then

        echo "[ERROR] Generated variables.cfg contains no variables."
        rm -f "$tmp_file"
        return 1
    fi
    if ! grep -qF '[gcode_macro _USER_VARIABLES]' "$tmp_file"; then
        echo "[ERROR] Generated variables.cfg is missing _USER_VARIABLES."
        rm -f "$tmp_file"
        return 1
    fi

    # Preserve permissions.
    if [[ -f "$output_config" ]]; then
        chmod --reference="$output_config" "$tmp_file" 2>/dev/null || true
        chown --reference="$output_config" "$tmp_file" 2>/dev/null || true
    fi

    # ------------------------------------------------------------
    # Atomic replacement
    # ------------------------------------------------------------
    if ! mv -f "$tmp_file" "$output_config"; then
        echo "[ERROR] Unable to install updated variables.cfg."
        rm -f "$tmp_file"
        return 1
    fi

    echo "[CONFIG-UPDATE] variables.cfg successfully migrated."

    if grep -q '#new default=' "$output_config" ||
       grep -qF "$(
           printf '%s' \
           '# NEW DEFAULT AVAILABLE - see current Klippain variables.cfg'
       )" "$output_config"; then

        echo "[CONFIG-UPDATE] NOTICE: New defaults are available."
        echo "[CONFIG-UPDATE] Your existing values were NOT changed."
        echo "[CONFIG-UPDATE] Review variables.cfg for details."
    fi
}

# Step 4: Put the new configuration files in place to be ready to start
function install_config {
    echo "[INSTALL] Installation of the latest Klippain config files"
    mkdir -p "${USER_CONFIG_PATH}"

    # Symlink Klippain config folders (read-only git repository)
    # to the user's config directory.
    for dir in config macros scripts moonraker; do
        ln -fsn \
            "${FRIX_CONFIG_PATH}/${dir}" \
            "${USER_CONFIG_PATH}/${dir}"
    done

    # ============================================================
    # NEW INSTALLATION
    # ============================================================

    if [ ! -f "${BACKUP_DIR}/.VERSION" ]; then
        printf "[INSTALL] New installation detected: config templates will be set in place!\n\n"
        find "${FRIX_CONFIG_PATH}/user_templates/" \
            -type d -name 'mcu_defaults' -prune \
            -o -type f -print |
            xargs cp -ft "${USER_CONFIG_PATH}/"

        # Restore external service configuration files if they
        # existed before Klippain was installed.
        #
        # This behavior exists in the current upstream installer.
        for config_file in \
            crowsnest.conf \
            sonar.conf \
            timelapse.cfg
        do
            if [ -f "${BACKUP_DIR}/${config_file}" ]; then
                cp -f \
                    "${BACKUP_DIR}/${config_file}" \
                    "${USER_CONFIG_PATH}/${config_file}"
                printf \
                    "[INSTALL] Existing %s restored from backup\n\n" \
                    "${config_file}"
            fi
        done
        install_mcu_templates

    # ============================================================
    # EXISTING INSTALLATION
    # ============================================================
    else
        printf "[INSTALL] Existing Klippain installation detected.\n"
        printf "[INSTALL] Updating user configuration templates...\n\n"
        update_user_templates
    fi

    # CHMOD scripts.
    chmod +x "${FRIX_CONFIG_PATH}/install.sh"
    chmod +x "${FRIX_CONFIG_PATH}/uninstall.sh"

    # Symlink gcode_shell_command.py.
    ln -fsn \
        "${FRIX_CONFIG_PATH}/scripts/gcode_shell_command.py" \
        "${KLIPPER_PATH}/klippy/extras"

    # Record the repository version associated with this config.
    git -C "${FRIX_CONFIG_PATH}" rev-parse HEAD \
        > "${USER_CONFIG_PATH}/.VERSION"
}


# Helper function to convert a template filename to a friendlier display name
function format_template_display_name {
    local display_name
    display_name="${1%.cfg}"
    display_name="${display_name//_/ }"
    display_name="${display_name//-/ }"
    display_name="$(printf '%s\n' "${display_name}" | tr -s ' ' | sed -E 's/(^| )V([0-9])/\1v\2/g')"

    if [[ "${display_name}" == "MY OWN CUSTOM TEMPLATE" ]]; then
        display_name="My Own Custom Template"
    fi

    printf '%s\n' "${display_name}"
}

# Helper function to build sorted "display name <tab> file path" entries for a template directory
function build_template_menu_entries {
    local template_dir="$1"
    local file display_name

    while IFS= read -r -d '' file; do
        display_name="$(format_template_display_name "$(basename "${file}")")"
        printf '%s\t%s\n' "${display_name}" "${file}"
    done < <(find "${template_dir}" -maxdepth 1 -type f -name '*.cfg' -print0) | sort -f
}

# Helper function to ask and install the MCU templates if needed
function install_mcu_templates {
    local install_template file_list display_list main_template install_toolhead_template toolhead_template install_mmu_template install_expander_template expander_template
    local display_name selected_file selected_name

    read < /dev/tty -rp "[CONFIG] Would you like to select and install MCU wiring templates files? (Y/n) " install_template
    if [[ -z "$install_template" ]]; then
        install_template="y"
    fi
    install_template="${install_template,,}"

    # Check and exit if the user do not wants to install an MCU template file
    if [[ "$install_template" =~ ^(no|n)$ ]]; then
        printf "[CONFIG] Skipping installation of MCU templates. You will need to manually populate your own mcu.cfg file!\n\n"
        return
    fi

    # If "yes" was selected, let's continue the install by listing the main MCU template
    file_list=()
    display_list=()
    while IFS=$'\t' read -r display_name selected_file; do
        file_list+=("${selected_file}")
        display_list+=("${display_name}")
    done < <(build_template_menu_entries "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/main")
    echo "[CONFIG] Please select your main MCU in the following list:"
    for i in "${!file_list[@]}"; do
        echo "  $((i+1))) ${display_list[i]}"
    done

    read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " main_template
    if [[ "$main_template" -gt 0 ]]; then
        # If the user selected a file, copy its content into the mcu.cfg file
        selected_file="${file_list[$((main_template-1))]}"
        selected_name="${display_list[$((main_template-1))]}"
        cat "${selected_file}" >> ${USER_CONFIG_PATH}/mcu.cfg
        printf "[CONFIG] Template '%s' inserted into your mcu.cfg user file\n\n" "${selected_name}"
    else
        printf "[CONFIG] No template selected. Skip and continuing...\n\n"
    fi

    # Next see if the user use a toolhead board
    read < /dev/tty -rp "[CONFIG] Do you have a toolhead MCU and want to install a template? (y/N) " install_toolhead_template
    if [[ -z "$install_toolhead_template" ]]; then
        install_toolhead_template="n"
    fi
    install_toolhead_template="${install_toolhead_template,,}"

    # Check if the user wants to install a toolhead MCU template
    if [[ "$install_toolhead_template" =~ ^(yes|y)$ ]]; then
        file_list=()
        display_list=()
        while IFS=$'\t' read -r display_name selected_file; do
            file_list+=("${selected_file}")
            display_list+=("${display_name}")
        done < <(build_template_menu_entries "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/toolhead")
        echo "[CONFIG] Please select your toolhead MCU in the following list:"
        for i in "${!file_list[@]}"; do
            echo "  $((i+1))) ${display_list[i]}"
        done

        read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " toolhead_template
        if [[ "$toolhead_template" -gt 0 ]]; then
            # If the user selected a file, copy its content into the mcu.cfg file
            selected_file="${file_list[$((toolhead_template-1))]}"
            selected_name="${display_list[$((toolhead_template-1))]}"
            cat "${selected_file}" >> ${USER_CONFIG_PATH}/mcu.cfg
            printf "[CONFIG] Template '%s' inserted into your mcu.cfg user file\n\n" "${selected_name}"
        else
            printf "[CONFIG] No toolhead template selected. Skip and continuing...\n\n"
        fi
    fi

    # Next see if the user use an MMU/ERCF board
    read < /dev/tty -rp "[CONFIG] Do you have an MMU/ERCF MCU and want to install a template? (y/N) " install_mmu_template
    if [[ -z "$install_mmu_template" ]]; then
        install_mmu_template="n"
    fi
    install_mmu_template="${install_mmu_template,,}"

    # Check if the user wants to install an MMU/ERCF MCU template
    if [[ "$install_mmu_template" =~ ^(yes|y)$ ]]; then
        file_list=()
        display_list=()
        while IFS=$'\t' read -r display_name selected_file; do
            file_list+=("${selected_file}")
            display_list+=("${display_name}")
        done < <(build_template_menu_entries "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/mmu")
        echo "[CONFIG] Please select your MMU/ERCF MCU in the following list:"
        for i in "${!file_list[@]}"; do
            echo "  $((i+1))) ${display_list[i]}"
        done

        read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " mmu_template
        if [[ "$mmu_template" -gt 0 ]]; then
            # If the user selected a file, copy its content into the mcu.cfg file
            selected_file="${file_list[$((mmu_template-1))]}"
            selected_name="${display_list[$((mmu_template-1))]}"
            cat "${selected_file}" >> ${USER_CONFIG_PATH}/mcu.cfg
            printf "[CONFIG] Template '%s' inserted into your mcu.cfg user file\n" "${selected_name}"
            printf "[CONFIG] Note: keep in mind that you have to install the HappyHare backend manually to use an MMU/ERCF with Klippain. See the Klippain documentation for more information!\n\n"
        else
            printf "[CONFIG] No MMU/ERCF template selected. Skip and continuing...\n\n"
        fi
    fi

    # Finally see if the user use an expander board
    read < /dev/tty -rp "[CONFIG] Do you have an expander board and want to install a template? (y/N) " install_expander_template
    if [[ -z "$install_expander_template" ]]; then
        install_expander_template="n"
    fi
    install_expander_template="${install_expander_template,,}"

    # Check if the user wants to install an expander MCU template
    if [[ "$install_expander_template" =~ ^(yes|y)$ ]]; then
        file_list=()
        display_list=()
        while IFS=$'\t' read -r display_name selected_file; do
            file_list+=("${selected_file}")
            display_list+=("${display_name}")
        done < <(build_template_menu_entries "${FRIX_CONFIG_PATH}/user_templates/mcu_defaults/expander")
        echo "[CONFIG] Please select your expander MCU in the following list:"
        for i in "${!file_list[@]}"; do
            echo "  $((i+1))) ${display_list[i]}"
        done

        read < /dev/tty -p "[CONFIG] Template to install (or 0 to skip): " expander_template
        if [[ "$expander_template" -gt 0 ]]; then
            # If the user selected a file, copy its content into the mcu.cfg file
            selected_file="${file_list[$((expander_template-1))]}"
            selected_name="${display_list[$((expander_template-1))]}"
            cat "${selected_file}" >> ${USER_CONFIG_PATH}/mcu.cfg
            printf "[CONFIG] Template '%s' inserted into your mcu.cfg user file\n\n" "${selected_name}"
        else
            printf "[CONFIG] No expander template selected. Skip and continuing...\n\n"
        fi
    fi
}

# Step 5: restarting Klipper
function restart_klipper {
    echo "[POST-INSTALL] Restarting Klipper..."
    sudo systemctl restart klipper
}


BACKUP_DIR="${BACKUP_PATH}/$(date +'%Y_%m_%d-%H%M%S')"

printf "\n======================================\n"
echo "- Klippain install and update script -"
printf "======================================\n\n"

# Run steps
preflight_checks
check_download
backup_config
install_config
restart_klipper

wget -O - https://raw.githubusercontent.com/Frix-x/klippain-shaketune/main/install.sh | bash

echo "[POST-INSTALL] Everything is ok, Klippain installed and up to date!"
echo "[POST-INSTALL] Be sure to check the breaking changes on the release page: https://github.com/Frix-x/klippain/releases"
