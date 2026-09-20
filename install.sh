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

    mkdir -p "${BACKUP_DIR}"

    cp -fa \
        "${USER_CONFIG_PATH}/." \
        "${BACKUP_DIR}" \
        2>/dev/null || :

    # Delete only Klippain-managed symlinks from the backup.
    # Preserve external config symlinks such as mainsail.cfg.
    while IFS= read -r -d '' link; do

        link_target="$(
            readlink -f "${link}" 2>/dev/null || true
        )"

        case "${link_target}" in

            "${FRIX_CONFIG_PATH}"|"${FRIX_CONFIG_PATH}"/*)
                rm -f "${link}"
                ;;

        esac

    done < <(
        find "${BACKUP_DIR}" -type l -print0
    )

    # If Klippain wasn't already installed, clean the user's
    # configuration directory before performing a new installation.
    if [ ! -f "${BACKUP_DIR}/.VERSION" ]; then
        rm -fR "${USER_CONFIG_PATH}"
    fi

    printf \
        "[BACKUP] Backup of current user config files done in: %s\n\n" \
        "${BACKUP_DIR}"
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
    local old_variables_template=""
    
    local new_printer="${FRIX_CONFIG_PATH}/user_templates/printer.cfg"
    local new_variables="${FRIX_CONFIG_PATH}/user_templates/variables.cfg"

    local live_printer="${USER_CONFIG_PATH}/printer.cfg"
    local live_variables="${USER_CONFIG_PATH}/variables.cfg"

    local previous_version=""

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

    # ------------------------------------------------------------
    # Retrieve the variables.cfg template from the version that was
    # installed before this update.
    #
    # This allows us to distinguish:
    #
    #   - removed upstream variables the user customized
    #   - removed upstream variables left at their old default
    #   - completely custom user variables
    # ------------------------------------------------------------

    if [[ -f "${BACKUP_DIR}/.VERSION" ]]; then
        previous_version="$(tr -d '[:space:]' < "${BACKUP_DIR}/.VERSION")"

        if [[ -n "$previous_version" ]] &&
           git -C "${FRIX_CONFIG_PATH}" cat-file -e \
           "${previous_version}^{commit}" 2>/dev/null; then

            old_variables_template="$(
                mktemp "${USER_CONFIG_PATH}/.variables.old.XXXXXX"
            )"

            if ! git -C "${FRIX_CONFIG_PATH}" show \
                "${previous_version}:user_templates/variables.cfg" \
                > "$old_variables_template" 2>/dev/null; then

                rm -f "$old_variables_template"
                old_variables_template=""
            fi
        fi
    fi

    if [[ -f "$old_variables" && -f "$new_variables" ]]; then
        migrate_variables_config \
            "$old_variables" \
            "$new_variables" \
            "$live_variables" \
            "$old_variables_template"

        if [[ -n "$old_variables_template" ]]; then
            rm -f "$old_variables_template"
        fi
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

    # Keep the temporary file on the same filesystem as the
    # destination so the final mv is atomic.
    tmp_file="$(mktemp "${config_dir}/.${config_name}.update.XXXXXX")" || {
        echo "[ERROR] Unable to create printer.cfg temporary file."
        return 1
    }

    echo "[CONFIG-UPDATE] Updating printer.cfg..."

    if ! awk '

    # ------------------------------------------------------------
    # Extract and normalize an [include ...] directive.
    #
    # Examples:
    #
    #   [include config/foo.cfg]
    #   # [include config/foo.cfg]
    #   # [include config/foo.cfg] # description
    #
    # all return:
    #
    #   [include config/foo.cfg]
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

        return substr(result, 1, endpos)
    }


    # ============================================================
    # FIRST FILE: EXISTING USER printer.cfg
    # ============================================================

    NR == FNR {
        key = get_include($0)

        if (key != "") {
            old_exists[key] = 1
            old_order[++old_count] = key
            old_original[key] = $0

            test = $0
            sub(/^[[:space:]]*/, "", test)

            if (test !~ /^#/)
                old_active[key] = 1
        }

        next
    }


    # ============================================================
    # SECOND FILE: NEW printer.cfg TEMPLATE
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
    # BUILD MERGED printer.cfg
    # ============================================================

    END {

        # --------------------------------------------------------
        # Find old/custom includes that no longer exist in the
        # current template.
        #
        # Anchor each one to the closest preceding include from the
        # old file that still exists in the new template.
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

                insert_after[line_number, insert_count[line_number]] = old_original[key]
            }
            else {
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

                # Strip the template comment marker for comparison
                # and possible activation.
                content = line
                sub(/^[[:space:]]*#[[:space:]]*/, "", content)

                if (key in old_active) {
                    # Include was active in the old config.
                    line = content
                }
                else {
                    # Include existed but was disabled in old config.
                    line = "# " content
                }
            }

            print line


            # ----------------------------------------------------
            # Insert custom includes anchored after this line.
            # ----------------------------------------------------

            if (i in insert_count) {
                for (j = 1; j <= insert_count[i]; j++) {
                    print insert_after[i, j]
                }
            }
        }


        # --------------------------------------------------------
        # Preserve custom includes for which no usable preceding
        # anchor exists.
        # --------------------------------------------------------

        if (orphan_count > 0) {
            print ""
            print "# ------------------------------------------------"
            print "# Preserved custom includes from previous config"
            print "# ------------------------------------------------"

            for (i = 1; i <= orphan_count; i++) {
                print orphan[i]
            }
        }
    }

    ' "$old_config" "$new_template" > "$tmp_file"; then
        echo "[ERROR] Failed to generate updated printer.cfg."
        rm -f "$tmp_file"
        return 1
    fi


    # ------------------------------------------------------------
    # Validate generated configuration.
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


    # ------------------------------------------------------------
    # Preserve existing permissions/ownership where possible.
    # ------------------------------------------------------------

    if [[ -f "$output_config" ]]; then
        chmod --reference="$output_config" "$tmp_file" 2>/dev/null || true
        chown --reference="$output_config" "$tmp_file" 2>/dev/null || true
    fi


    # ------------------------------------------------------------
    # Atomic replacement.
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
    local old_template="${4:-}"

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
        "$tmp_file" \
        "$old_template" <<'PYTHON'

import re
import sys
from pathlib import Path


old_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])

old_template_path = (
    Path(sys.argv[4])
    if len(sys.argv) > 4 and sys.argv[4]
    else None
)

# ----------------------------------------------------------------
# Parse the template from the previously installed Klippain
# version, if available.
# ----------------------------------------------------------------

old_template_vars = {}

if (
    old_template_path is not None
    and old_template_path.is_file()
):

    old_template_lines = old_template_path.read_text(
        encoding="utf-8"
    ).splitlines()

    old_template_vars = parse_variables(
        old_template_lines
    )

# ----------------------------------------------------------------
# Patterns / constants
# ----------------------------------------------------------------

VARIABLE_RE = re.compile(
    r'^(\s*)(variable_[A-Za-z0-9_]+)(\s*:\s*)(.*)$'
)

NEW_DEFAULT_RE = re.compile(
    r'\s+#new default=.*$',
    re.IGNORECASE
)

MULTILINE_NOTICE = (
    "# NEW DEFAULT AVAILABLE - "
    "see current Klippain variables.cfg"
)


# ----------------------------------------------------------------
# Utility functions
# ----------------------------------------------------------------

def strip_new_default(text):
    """
    Remove an annotation previously added by this updater.

    Example:

        300 #new default=350

    becomes:

        300
    """

    return NEW_DEFAULT_RE.sub("", text).rstrip()


def split_inline_comment(text):
    """
    Separate the actual variable value from an inline Klipper
    comment.

    This intentionally only treats # as a comment when it is
    outside quotes.

    Examples:

        300 # my setting

    returns:

        ("300", "# my setting")


        "abc#123"

    returns:

        ("\"abc#123\"", "")
    """

    quote = None
    escaped = False

    for i, char in enumerate(text):

        if escaped:
            escaped = False
            continue

        if char == "\\" and quote is not None:
            escaped = True
            continue

        if quote is not None:
            if char == quote:
                quote = None
            continue

        if char in ("'", '"'):
            quote = char
            continue

        if char == "#":
            value = text[:i].rstrip()
            comment = text[i:].strip()
            return value, comment

    return text.rstrip(), ""


def brace_delta(text):
    """
    Count {}, [] and () while ignoring characters inside strings.

    Used only to determine where a multiline Python-style
    dictionary/list/tuple ends.
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

        if char == "\\" and quote is not None:
            escaped = True
            continue

        if quote is not None:
            if char == quote:
                quote = None
            continue

        if char in ("'", '"'):
            quote = char
            continue

        delta += pairs.get(char, 0)

    return delta


# ----------------------------------------------------------------
# Parse variables.cfg
# ----------------------------------------------------------------

def parse_variables(lines):
    """
    Parse variable definitions.

    Returns a dict keyed by variable name.

    Each entry contains:

        start
        end
        lines
        multiline
        prefix
        raw_rhs
        value
        comment
    """

    variables = {}

    i = 0

    while i < len(lines):

        match = VARIABLE_RE.match(lines[i])

        if not match:
            i += 1
            continue

        name = match.group(2)

        prefix = (
            match.group(1)
            + match.group(2)
            + match.group(3)
        )

        # Remove an annotation created by a previous migration.
        rhs = strip_new_default(match.group(4))

        value, comment = split_inline_comment(rhs)

        start = i
        end = i

        depth = brace_delta(value)

        # Continue until a multiline dictionary/list/tuple closes.
        while depth > 0 and end + 1 < len(lines):
            end += 1
            depth += brace_delta(lines[end])

        block = lines[i:end + 1]

        variables[name] = {
            "start": start,
            "end": end,
            "lines": block,
            "multiline": end > i,
            "prefix": prefix,
            "raw_rhs": rhs,
            "value": value.strip(),
            "comment": comment,
        }

        i = end + 1

    return variables


# ----------------------------------------------------------------
# Normalize values for comparison
# ----------------------------------------------------------------

def normalized_value(entry):
    """
    Return only the meaningful variable value.

    Existing migration annotations and inline comments are ignored
    for default comparison.
    """

    if not entry["multiline"]:
        return entry["value"].strip()

    lines = entry["lines"]

    first_match = VARIABLE_RE.match(lines[0])

    if not first_match:
        return ""

    first_rhs = strip_new_default(first_match.group(4))

    first_value, _ = split_inline_comment(first_rhs)

    values = [first_value.rstrip()]

    for line in lines[1:]:
        values.append(line.rstrip())

    return "\n".join(values).strip()


# ----------------------------------------------------------------
# Build a single-line variable
# ----------------------------------------------------------------

def make_single_line(old_entry, new_entry):
    """
    Preserve the user's current value.

    If the template default changed, append:

        #new default=X

    Existing user comments are also preserved.
    """

    old_value = old_entry["value"]
    old_comment = old_entry["comment"]

    new_value = new_entry["value"]

    # Preserve the formatting before the value from the NEW
    # template. This lets upstream formatting changes propagate.
    prefix = new_entry["prefix"]

    result = prefix + old_value

    # Preserve user's inline comment.
    if old_comment:
        result += " " + old_comment

    # Only add an annotation when the meaningful values differ.
    if old_value.strip() != new_value.strip():
        result += f" #new default={new_value.strip()}"

    return [result]


# ----------------------------------------------------------------
# Build a multiline variable
# ----------------------------------------------------------------

def make_multiline(old_entry, new_entry):
    """
    Preserve the user's complete multiline block.

    A changed upstream default receives one notice immediately
    above the variable.
    """

    old_value = normalized_value(old_entry)
    new_value = normalized_value(new_entry)

    # Clean the first line in case it contains an old single-line
    # migration annotation.
    block = list(old_entry["lines"])

    first_match = VARIABLE_RE.match(block[0])

    if first_match:
        clean_rhs = strip_new_default(first_match.group(4))

        block[0] = (
            first_match.group(1)
            + first_match.group(2)
            + first_match.group(3)
            + clean_rhs
        )

    if old_value == new_value:
        return block

    return [MULTILINE_NOTICE] + block


# ----------------------------------------------------------------
# Read files
# ----------------------------------------------------------------

old_lines = old_path.read_text(
    encoding="utf-8"
).splitlines()

template_lines = template_path.read_text(
    encoding="utf-8"
).splitlines()


# Remove multiline notices created by a previous migration from the
# old file before parsing/output.
old_lines = [
    line
    for line in old_lines
    if line.strip() != MULTILINE_NOTICE
]


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
# Build the output from the NEW template.
#
# This means:
#
#   NEW template:
#       structure
#       documentation
#       comments
#       newly introduced variables
#
#   OLD user file:
#       existing variable values
#       custom variables
#
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


    # ------------------------------------------------------------
    # Brand-new upstream variable
    # ------------------------------------------------------------

    if name not in old_vars:

        output.extend(new_entry["lines"])

        new_count += 1

        i = new_entry["end"] + 1
        continue


    # ------------------------------------------------------------
    # Existing variable
    # ------------------------------------------------------------

    old_entry = old_vars[name]

    old_value = normalized_value(old_entry)
    new_value = normalized_value(new_entry)

    preserved += 1

    if old_value != new_value:
        changed_defaults += 1


    # If either side is multiline, treat the variable as a complete
    # block rather than attempting to merge dictionary members.
    if old_entry["multiline"] or new_entry["multiline"]:

        if old_value != new_value:
            multiline_changed += 1

        output.extend(
            make_multiline(
                old_entry,
                new_entry
            )
        )

    else:

        output.extend(
            make_single_line(
                old_entry,
                new_entry
            )
        )


    i = new_entry["end"] + 1


# ----------------------------------------------------------------
# Handle variables absent from the new template.
#
# There are three possible cases:
#
# 1. Variable existed in the previous upstream template and the
#    user changed it:
#
#       Preserve + #deprecated
#
# 2. Variable existed in the previous upstream template and the
#    user never changed it:
#
#       Drop it. Upstream intentionally removed it.
#
# 3. Variable never existed in the previous upstream template:
#
#       It is a user-created/custom variable. Preserve it without
#       marking it deprecated.
#
# If the previous template cannot be retrieved, preserve unknown
# variables rather than risk deleting user configuration.
# ----------------------------------------------------------------

removed_variables = [
    name
    for name in old_vars
    if name not in new_vars
]

deprecated_count = 0
removed_default_count = 0
custom_count = 0


if removed_variables:

    preserved_removed = []

    removed_variables.sort(
        key=lambda name: old_vars[name]["start"]
    )

    for name in removed_variables:

        user_entry = old_vars[name]

        # --------------------------------------------------------
        # Was this an upstream variable in the previous version?
        # --------------------------------------------------------

        if name in old_template_vars:

            old_default_entry = old_template_vars[name]

            user_value = normalized_value(user_entry)
            old_default = normalized_value(old_default_entry)

            # User never changed the old upstream default.
            #
            # Since upstream removed the variable, do not carry it
            # into the new configuration.
            if user_value == old_default:
                removed_default_count += 1
                continue

            # User modified an upstream variable that has since
            # disappeared. Preserve it and mark it deprecated.
            preserved_removed.append(
                ("deprecated", name)
            )

            deprecated_count += 1

        else:

            # ----------------------------------------------------
            # Variable did not exist in the previous upstream
            # template. Treat it as a user-created variable.
            # ----------------------------------------------------

            preserved_removed.append(
                ("custom", name)
            )

            custom_count += 1


    if preserved_removed:

        output.extend([
            "",
            "# ------------------------------------------------",
            "# Preserved variables from previous configuration",
            "# ------------------------------------------------",
        ])


        for variable_type, name in preserved_removed:

            entry = old_vars[name]
            block = list(entry["lines"])

            first_match = VARIABLE_RE.match(block[0])

            if first_match:

                # Remove any obsolete #new default annotation.
                clean_rhs = strip_new_default(
                    first_match.group(4)
                )

                # Also remove an old deprecated annotation so the
                # operation remains idempotent.
                clean_rhs = re.sub(
                    r'\s+#deprecated\s*$',
                    "",
                    clean_rhs,
                    flags=re.IGNORECASE
                ).rstrip()

                if variable_type == "deprecated":

                    if entry["multiline"]:

                        # Keep multiline annotation above the block.
                        block.insert(
                            0,
                            "# DEPRECATED - variable removed "
                            "from current Klippain template"
                        )

                    else:

                        clean_rhs += " #deprecated"


                block[
                    1 if (
                        variable_type == "deprecated"
                        and entry["multiline"]
                    ) else 0
                ] = (
                    first_match.group(1)
                    + first_match.group(2)
                    + first_match.group(3)
                    + clean_rhs
                )

            output.extend(block)

# ----------------------------------------------------------------
# Write generated file
# ----------------------------------------------------------------

output_path.write_text(
    "\n".join(output) + "\n",
    encoding="utf-8"
)


# ----------------------------------------------------------------
# Migration report
# ----------------------------------------------------------------

print(
    f"[CONFIG-UPDATE]   "
    f"{preserved} existing variables preserved"
)

print(
    f"[CONFIG-UPDATE]   "
    f"{new_count} new variables added"
)

print(
    f"[CONFIG-UPDATE]   "
    f"{changed_defaults} variables have new defaults"
)

if multiline_changed:

    print(
        f"[CONFIG-UPDATE]   "
        f"{multiline_changed} multiline variables "
        f"have new defaults"
    )

if deprecated_count:

    print(
        f"[CONFIG-UPDATE]   "
        f"{deprecated_count} modified variables are now deprecated"
    )

if removed_default_count:

    print(
        f"[CONFIG-UPDATE]   "
        f"{removed_default_count} obsolete default variables removed"
    )

if custom_count:

    print(
        f"[CONFIG-UPDATE]   "
        f"{custom_count} custom user variables preserved"
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


    if ! grep -qF \
        '[gcode_macro _USER_VARIABLES]' \
        "$tmp_file"; then

        echo "[ERROR] Generated variables.cfg is missing _USER_VARIABLES."
        rm -f "$tmp_file"
        return 1
    fi


    # ------------------------------------------------------------
    # Preserve permissions
    # ------------------------------------------------------------

    if [[ -f "$output_config" ]]; then

        chmod \
            --reference="$output_config" \
            "$tmp_file" \
            2>/dev/null || true

        chown \
            --reference="$output_config" \
            "$tmp_file" \
            2>/dev/null || true
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


    # ------------------------------------------------------------
    # Tell user when defaults need review.
    # ------------------------------------------------------------

    if grep -q '#new default=' "$output_config" ||
       grep -qF \
       '# NEW DEFAULT AVAILABLE - see current Klippain variables.cfg' \
       "$output_config"; then

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
