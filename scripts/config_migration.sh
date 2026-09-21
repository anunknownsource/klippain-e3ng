#!/usr/bin/env bash
# ================================================================
# KLIPPAIN USER CONFIG MIGRATION MODULE
# ================================================================
# Sourced by install.sh during existing-installation updates.
# May also be executed directly with --test-migration.
# ================================================================

# ================================================================
# USER CONFIG MIGRATION
# ================================================================
#
# During an update:
#
# printer.cfg
#   - Start with the newest Klippain template.
#   - Preserve enabled/disabled state of existing includes.
#   - Preserve custom user includes.
#   - Keep new upstream comments and organization.
#
# variables.cfg
#   - Start with the newest Klippain template.
#   - Preserve all existing user values.
#   - Add newly introduced upstream variables.
#   - Annotate changed defaults.
#   - Preserve customized variables removed upstream as #deprecated.
#   - Remove obsolete upstream variables that were never customized.
#   - Preserve user-created variables.
#
# ================================================================

function update_user_templates {
    local old_printer="${BACKUP_DIR}/printer.cfg"
    local old_variables="${BACKUP_DIR}/variables.cfg"

    local new_printer="${FRIX_CONFIG_PATH}/user_templates/printer.cfg"
    local new_variables="${FRIX_CONFIG_PATH}/user_templates/variables.cfg"

    local live_printer="${USER_CONFIG_PATH}/printer.cfg"
    local live_variables="${USER_CONFIG_PATH}/variables.cfg"

    local old_variables_template=""
    local previous_version=""

    echo "[CONFIG-UPDATE] Migrating user configuration..."


    # ============================================================
    # printer.cfg
    # ============================================================

    if [[ -f "$old_printer" && -f "$new_printer" ]]; then

        migrate_printer_config \
            "$old_printer" \
            "$new_printer" \
            "$live_printer"

    else

        echo "[CONFIG-UPDATE] WARNING: Unable to migrate printer.cfg."
        echo "[CONFIG-UPDATE] Old config or new template is missing."

    fi


    # ============================================================
    # Locate the variables.cfg template from the version that was
    # previously installed.
    #
    # .VERSION contains the Git commit associated with the user's
    # previous Klippain configuration.
    #
    # This lets us distinguish:
    #
    #   old upstream variable + unchanged
    #       -> safe to remove if upstream removed it
    #
    #   old upstream variable + user customized
    #       -> preserve as #deprecated
    #
    #   never existed upstream
    #       -> preserve as custom user variable
    #
    # ============================================================

    if [[ -f "${BACKUP_DIR}/.VERSION" ]]; then

        previous_version="$(
            tr -d '[:space:]' < "${BACKUP_DIR}/.VERSION"
        )"

        if [[ -n "$previous_version" ]] &&
           git -C "${FRIX_CONFIG_PATH}" cat-file -e \
               "${previous_version}^{commit}" 2>/dev/null; then

            old_variables_template="$(
                mktemp "${TMPDIR:-/tmp}/klippain-variables.old.XXXXXX"
            )"

            if ! git -C "${FRIX_CONFIG_PATH}" show \
                "${previous_version}:user_templates/variables.cfg" \
                > "$old_variables_template" 2>/dev/null; then

                rm -f "$old_variables_template"
                old_variables_template=""

                echo \
                    "[CONFIG-UPDATE] Historical variables template unavailable."

            else

                echo \
                    "[CONFIG-UPDATE] Previous variables template recovered."

            fi

        else

            echo \
                "[CONFIG-UPDATE] Previous Klippain commit unavailable locally."

        fi

    fi


    # ============================================================
    # variables.cfg
    # ============================================================

    if [[ -f "$old_variables" && -f "$new_variables" ]]; then

        migrate_variables_config \
            "$old_variables" \
            "$new_variables" \
            "$live_variables" \
            "$old_variables_template"

    else

        echo "[CONFIG-UPDATE] WARNING: Unable to migrate variables.cfg."
        echo "[CONFIG-UPDATE] Old config or new template is missing."

    fi


    # Remove temporary historical template.
    if [[ -n "$old_variables_template" ]]; then
        rm -f "$old_variables_template"
    fi


    printf \
        "[CONFIG-UPDATE] User configuration migration complete!\n\n"
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

    tmp_file="$(
        mktemp "${TMPDIR:-/tmp}/klippain-${config_name}.candidate.XXXXXX"
    )" || {
        echo "[ERROR] Unable to create printer.cfg temporary file."
        return 1
    }

    echo "[CONFIG-UPDATE] Updating printer.cfg..."


    if ! awk '

    # ------------------------------------------------------------
    # Extract normalized [include ...] directive.
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
    # EXISTING USER printer.cfg
    # ============================================================

    NR == FNR {

        key = get_include($0)

        if (key != "") {

            # Ignore exact duplicate includes.
            if (!(key in old_exists)) {

                old_exists[key] = 1
                old_order[++old_count] = key
                old_original[key] = $0

                test = $0
                sub(/^[[:space:]]*/, "", test)

                if (test !~ /^#/)
                    old_active[key] = 1
            }
        }

        next
    }


    # ============================================================
    # NEW TEMPLATE
    # ============================================================

    {
        new_lines[++new_count] = $0

        key = get_include($0)

        if (key != "") {

            new_exists[key] = 1

            # Use the first occurrence as the custom-include anchor.
            if (!(key in new_line_number))
                new_line_number[key] = new_count
        }
    }


    # ============================================================
    # BUILD RESULT
    # ============================================================

    END {

        matched_count = 0
        new_include_count = 0
        custom_count = 0


        # --------------------------------------------------------
        # Determine custom includes and their anchors.
        # --------------------------------------------------------

        for (i = 1; i <= old_count; i++) {

            key = old_order[i]

            if (key in new_exists)
                continue

            custom_count++
            anchor = ""


            # Find closest preceding surviving include.
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

                idx = line_number SUBSEP insert_count[line_number]
                insert_after[idx] = old_original[key]

            } else {

                # No previous anchor. Try the closest following
                # surviving include.
                next_anchor = ""

                for (j = i + 1; j <= old_count; j++) {

                    following = old_order[j]

                    if (following in new_exists) {
                        next_anchor = following
                        break
                    }
                }


                if (next_anchor != "") {

                    line_number = new_line_number[next_anchor]
                    insert_before_count[line_number]++

                    idx = line_number SUBSEP insert_before_count[line_number]
                    insert_before[idx] = old_original[key]

                } else {

                    orphan_count++
                    orphan[orphan_count] = old_original[key]

                }
            }
        }


        # --------------------------------------------------------
        # Count template include categories.
        # --------------------------------------------------------

        for (key in new_exists) {

            if (key in old_exists)
                matched_count++
            else
                new_include_count++
        }


        # --------------------------------------------------------
        # Output new template.
        # --------------------------------------------------------

        for (i = 1; i <= new_count; i++) {

            # Custom includes that belong before this line.
            if (i in insert_before_count) {

                for (j = 1; j <= insert_before_count[i]; j++) {

                    idx = i SUBSEP j
                    print insert_before[idx]
                }
            }


            line = new_lines[i]
            key = get_include(line)


            if (key != "" && key in old_exists) {

                # Remove template comment prefix.
                content = line

                leading = ""
                temp = content

                match(temp, /^[[:space:]]*/)
                leading = substr(temp, 1, RLENGTH)
                content = substr(temp, RLENGTH + 1)

                sub(/^#[[:space:]]*/, "", content)


                if (key in old_active) {

                    # Previously active.
                    line = leading content

                } else {

                    # Previously disabled.
                    line = leading "# " content
                }
            }


            print line


            # Custom includes anchored after this line.
           if (i in insert_count) {

                for (j = 1; j <= insert_count[i]; j++) {

                    idx = i SUBSEP j
                    print insert_after[idx]
                }
            }
        }


        # --------------------------------------------------------
        # Includes with no usable anchor.
        # --------------------------------------------------------

        if (orphan_count > 0) {

            print ""
            print "# ------------------------------------------------"
            print "# Preserved custom includes from previous config"
            print "# ------------------------------------------------"

            for (i = 1; i <= orphan_count; i++)
                print orphan[i]
        }


        # --------------------------------------------------------
        # Statistics
        # --------------------------------------------------------

        print \
            "[CONFIG-UPDATE]   " matched_count \
            " existing includes preserved" > "/dev/stderr"

        print \
            "[CONFIG-UPDATE]   " new_include_count \
            " new includes available" > "/dev/stderr"

        if (custom_count > 0) {

            print \
                "[CONFIG-UPDATE]   " custom_count \
                " custom includes preserved" > "/dev/stderr"
        }
    }

    ' "$old_config" "$new_template" > "$tmp_file"; then

        echo "[ERROR] Failed to generate updated printer.cfg."

        rm -f "$tmp_file"

        return 1
    fi


    # ============================================================
    # Validation
    # ============================================================

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


    # Preserve permissions/ownership.
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


    # ============================================================
    # INSTALL ONLY WHEN CONTENT CHANGED
    # ============================================================

    if [[ -f "$output_config" ]] && cmp -s "$tmp_file" "$output_config"; then
        rm -f "$tmp_file"
        echo "[CONFIG-UPDATE] printer.cfg already up to date."
        return 0
    fi

    # Stage the validated candidate on the destination filesystem so
    # the final rename remains atomic without exposing the generation
    # process to Moonraker's watched config directory.
    local staged_file
    staged_file="$(mktemp "${config_dir}/.${config_name}.update.XXXXXX")" || {
        echo "[ERROR] Unable to create printer.cfg staging file."
        rm -f "$tmp_file"
        return 1
    }

    if ! cp -f "$tmp_file" "$staged_file"; then
        echo "[ERROR] Unable to stage updated printer.cfg."
        rm -f "$tmp_file" "$staged_file"
        return 1
    fi

    rm -f "$tmp_file"

    # Preserve permissions/ownership on the staged file.
    if [[ -f "$output_config" ]]; then
        chmod --reference="$output_config" "$staged_file" 2>/dev/null || true
        chown --reference="$output_config" "$staged_file" 2>/dev/null || true
    fi

    # Atomic replacement.
    if ! mv -f "$staged_file" "$output_config"; then
        echo "[ERROR] Unable to install updated printer.cfg."
        rm -f "$staged_file"
        return 1
    fi

    echo "[CONFIG-UPDATE] printer.cfg successfully migrated."
}


# ================================================================
# VARIABLES.CFG MIGRATION
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

    tmp_file="$(
        mktemp "${TMPDIR:-/tmp}/klippain-${config_name}.candidate.XXXXXX"
    )" || {
        echo "[ERROR] Unable to create variables.cfg temporary file."
        return 1
    }


    echo "[CONFIG-UPDATE] Updating variables.cfg..."


    if ! python3 - \
        "$old_config" \
        "$new_template" \
        "$tmp_file" \
        "$old_template" <<'PYTHON'

import ast
import re
import sys
from pathlib import Path


# ================================================================
# INPUTS
# ================================================================

old_path = Path(sys.argv[1])
template_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])

old_template_path = (
    Path(sys.argv[4])
    if len(sys.argv) > 4 and sys.argv[4]
    else None
)


# ================================================================
# CONSTANTS
# ================================================================

VARIABLE_RE = re.compile(
    r'^(\s*)(variable_[A-Za-z0-9_]+)(\s*:\s*)(.*)$'
)

NEW_DEFAULT_RE = re.compile(
    r'\s+#new\s+default=.*$',
    re.IGNORECASE
)

DEPRECATED_RE = re.compile(
    r'\s+#deprecated\s*$',
    re.IGNORECASE
)

MULTILINE_NOTICE = (
    "# NEW DEFAULT AVAILABLE - "
    "see current Klippain variables.cfg"
)

DEPRECATED_MULTILINE_NOTICE = (
    "# DEPRECATED - variable removed "
    "from current Klippain template"
)


# ================================================================
# CLEANUP HELPERS
# ================================================================

def strip_new_default(text):
    return NEW_DEFAULT_RE.sub("", text).rstrip()


def strip_deprecated(text):
    return DEPRECATED_RE.sub("", text).rstrip()


def strip_migration_annotations(text):
    text = strip_new_default(text)
    text = strip_deprecated(text)
    return text.rstrip()


# ================================================================
# COMMENT PARSER
# ================================================================

def split_inline_comment(text):
    """
    Split an inline # comment while ignoring # characters inside
    quoted strings.
    """

    quote = None
    escaped = False

    for index, char in enumerate(text):

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

            return (
                text[:index].rstrip(),
                text[index:].strip(),
            )

    return text.rstrip(), ""


# ================================================================
# MULTILINE DETECTION
# ================================================================

def brace_delta(text):
    """
    Count (), [] and {} outside quoted strings.
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


# ================================================================
# VARIABLE PARSER
# ================================================================

def parse_variables(lines):

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


        rhs = strip_migration_annotations(
            match.group(4)
        )

        value, comment = split_inline_comment(rhs)

        start = i
        end = i

        depth = brace_delta(value)


        while depth > 0 and end + 1 < len(lines):

            end += 1

            depth += brace_delta(
                lines[end]
            )


        block = lines[i:end + 1]


        variables[name] = {
            "name": name,
            "start": start,
            "end": end,
            "lines": block,
            "multiline": end > i,
            "prefix": prefix,
            "value": value.strip(),
            "comment": comment,
        }


        i = end + 1


    return variables


# ================================================================
# NORMALIZED VALUE
# ================================================================

def raw_value_text(entry):
    """
    Return the variable's value without migration annotations or
    user comments.
    """

    lines = entry["lines"]

    if not lines:
        return ""


    match = VARIABLE_RE.match(lines[0])

    if not match:
        return ""


    first_rhs = strip_migration_annotations(
        match.group(4)
    )

    first_value, _ = split_inline_comment(
        first_rhs
    )


    if not entry["multiline"]:
        return first_value.strip()


    result = [first_value.rstrip()]

    for line in lines[1:]:
        result.append(line.rstrip())


    return "\n".join(result).strip()


def normalized_value(entry):
    """
    Prefer semantic Python-literal comparison.

    This prevents harmless whitespace/formatting changes in a
    dictionary from being reported as a new default.

    Fall back to normalized text if the value is not a valid Python
    literal.
    """

    raw = raw_value_text(entry)


    try:

        value = ast.literal_eval(raw)

        return (
            "literal",
            value,
        )

    except (ValueError, SyntaxError):

        normalized = "\n".join(
            line.strip()
            for line in raw.splitlines()
        ).strip()

        return (
            "text",
            normalized,
        )


def values_equal(first, second):
    return normalized_value(first) == normalized_value(second)


# ================================================================
# SINGLE-LINE OUTPUT
# ================================================================

def make_single_line(old_entry, new_entry):

    old_value = old_entry["value"]
    old_comment = old_entry["comment"]

    new_value = new_entry["value"]

    # Use formatting from current template before the value.
    result = (
        new_entry["prefix"]
        + old_value
    )


    # Preserve user's inline comment.
    if old_comment:
        result += " " + old_comment


    # Add current upstream default if user value differs.
    if not values_equal(old_entry, new_entry):

        result += (
            " #new default="
            + new_value
        )


    return [result]


# ================================================================
# MULTILINE OUTPUT
# ================================================================

def clean_old_block(entry):

    block = list(entry["lines"])

    if not block:
        return block


    first_match = VARIABLE_RE.match(
        block[0]
    )


    if first_match:

        clean_rhs = strip_migration_annotations(
            first_match.group(4)
        )

        block[0] = (
            first_match.group(1)
            + first_match.group(2)
            + first_match.group(3)
            + clean_rhs
        )


    return block


def make_multiline(old_entry, new_entry):

    block = clean_old_block(old_entry)


    if values_equal(old_entry, new_entry):
        return block


    return [
        MULTILINE_NOTICE
    ] + block


# ================================================================
# READ FILES
# ================================================================

old_lines = old_path.read_text(
    encoding="utf-8"
).splitlines()

template_lines = template_path.read_text(
    encoding="utf-8"
).splitlines()


# Remove notices created by previous migrations.
old_lines = [
    line
    for line in old_lines
    if line.strip() not in (
        MULTILINE_NOTICE,
        DEPRECATED_MULTILINE_NOTICE,
    )
]


old_vars = parse_variables(
    old_lines
)

new_vars = parse_variables(
    template_lines
)


# ================================================================
# HISTORICAL TEMPLATE
# ================================================================

old_template_vars = {}


if (
    old_template_path is not None
    and old_template_path.is_file()
):

    old_template_lines = (
        old_template_path.read_text(
            encoding="utf-8"
        ).splitlines()
    )

    old_template_vars = parse_variables(
        old_template_lines
    )


historical_template_available = bool(
    old_template_vars
)


# ================================================================
# STATISTICS
# ================================================================

preserved = 0
new_count = 0
changed_defaults = 0
multiline_changed = 0

deprecated_count = 0
obsolete_removed_count = 0
custom_count = 0
unknown_preserved_count = 0


# ================================================================
# BUILD FROM CURRENT TEMPLATE
# ================================================================

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
    # Brand-new upstream variable.
    # ------------------------------------------------------------

    if name not in old_vars:

        output.extend(
            new_entry["lines"]
        )

        new_count += 1

        i = new_entry["end"] + 1

        continue


    # ------------------------------------------------------------
    # Existing variable.
    # ------------------------------------------------------------

    old_entry = old_vars[name]

    preserved += 1


    changed = not values_equal(
        old_entry,
        new_entry
    )


    if changed:
        changed_defaults += 1


    if (
        old_entry["multiline"]
        or new_entry["multiline"]
    ):

        if changed:
            multiline_changed += 1

        output.extend(
            make_multiline(
                old_entry,
                new_entry,
            )
        )

    else:

        output.extend(
            make_single_line(
                old_entry,
                new_entry,
            )
        )


    i = new_entry["end"] + 1


# ================================================================
# VARIABLES ABSENT FROM CURRENT TEMPLATE
# ================================================================

removed_names = [
    name
    for name in old_vars
    if name not in new_vars
]


removed_names.sort(
    key=lambda name: old_vars[name]["start"]
)


preserved_removed = []


for name in removed_names:

    user_entry = old_vars[name]


    # ------------------------------------------------------------
    # Historical template is available and this variable existed
    # upstream previously.
    # ------------------------------------------------------------

    if name in old_template_vars:

        historical_entry = old_template_vars[name]


        # User left it at the historical default.
        #
        # Upstream removed it, so allow it to disappear.
        if values_equal(
            user_entry,
            historical_entry,
        ):

            obsolete_removed_count += 1

            continue


        # User changed the value.
        #
        # Preserve it but explicitly identify that upstream no
        # longer defines it.
        preserved_removed.append(
            (
                "deprecated",
                name,
            )
        )

        deprecated_count += 1

        continue


    # ------------------------------------------------------------
    # Historical template is available but this variable did not
    # exist in it.
    #
    # It is therefore user-created.
    # ------------------------------------------------------------

    if historical_template_available:

        preserved_removed.append(
            (
                "custom",
                name,
            )
        )

        custom_count += 1

        continue


    # ------------------------------------------------------------
    # Historical template unavailable.
    #
    # We cannot safely determine whether this is:
    #
    #   - a removed upstream variable
    #   - a custom user variable
    #
    # Preserve it without claiming it is deprecated.
    # ------------------------------------------------------------

    preserved_removed.append(
        (
            "unknown",
            name,
        )
    )

    unknown_preserved_count += 1


# ================================================================
# OUTPUT PRESERVED REMOVED/CUSTOM VARIABLES
# ================================================================

if preserved_removed:

    output.extend([
        "",
        "# ------------------------------------------------",
        "# Preserved variables from previous configuration",
        "# ------------------------------------------------",
    ])


    for variable_type, name in preserved_removed:

        entry = old_vars[name]

        block = clean_old_block(entry)


        if variable_type == "deprecated":

            if entry["multiline"]:

                block.insert(
                    0,
                    DEPRECATED_MULTILINE_NOTICE,
                )

            else:

                first_match = VARIABLE_RE.match(
                    block[0]
                )

                if first_match:

                    clean_rhs = (
                        strip_migration_annotations(
                            first_match.group(4)
                        )
                    )

                    block[0] = (
                        first_match.group(1)
                        + first_match.group(2)
                        + first_match.group(3)
                        + clean_rhs
                        + " #deprecated"
                    )


        output.extend(block)


# ================================================================
# WRITE RESULT
# ================================================================

output_path.write_text(
    "\n".join(output) + "\n",
    encoding="utf-8",
)


# ================================================================
# REPORT
# ================================================================

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
        f"{deprecated_count} customized variables "
        f"are now deprecated"
    )


if obsolete_removed_count:

    print(
        f"[CONFIG-UPDATE]   "
        f"{obsolete_removed_count} obsolete default "
        f"variables removed"
    )


if custom_count:

    print(
        f"[CONFIG-UPDATE]   "
        f"{custom_count} custom user variables preserved"
    )


if unknown_preserved_count:

    print(
        f"[CONFIG-UPDATE]   "
        f"{unknown_preserved_count} unclassified variables "
        f"preserved because historical template was unavailable"
    )

PYTHON
    then

        echo "[ERROR] Failed to generate updated variables.cfg."

        rm -f "$tmp_file"

        return 1
    fi


    # ============================================================
    # VALIDATION
    # ============================================================

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

        echo \
            "[ERROR] Generated variables.cfg is missing _USER_VARIABLES."

        rm -f "$tmp_file"

        return 1
    fi


    # ============================================================
    # PRESERVE PERMISSIONS
    # ============================================================

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


    # ============================================================
    # INSTALL ONLY WHEN CONTENT CHANGED
    # ============================================================

    local variables_changed=1

    if [[ -f "$output_config" ]] && cmp -s "$tmp_file" "$output_config"; then
        variables_changed=0
        rm -f "$tmp_file"
        echo "[CONFIG-UPDATE] variables.cfg already up to date."
    else
        # Stage the validated candidate on the destination filesystem so
        # the final rename remains atomic.
        local staged_file
        staged_file="$(mktemp "${config_dir}/.${config_name}.update.XXXXXX")" || {
            echo "[ERROR] Unable to create variables.cfg staging file."
            rm -f "$tmp_file"
            return 1
        }

        if ! cp -f "$tmp_file" "$staged_file"; then
            echo "[ERROR] Unable to stage updated variables.cfg."
            rm -f "$tmp_file" "$staged_file"
            return 1
        fi

        rm -f "$tmp_file"

        if [[ -f "$output_config" ]]; then
            chmod --reference="$output_config" "$staged_file" 2>/dev/null || true
            chown --reference="$output_config" "$staged_file" 2>/dev/null || true
        fi

        if ! mv -f "$staged_file" "$output_config"; then
            echo "[ERROR] Unable to install updated variables.cfg."
            rm -f "$staged_file"
            return 1
        fi

        echo "[CONFIG-UPDATE] variables.cfg successfully migrated."
    fi


    # ============================================================
    # REVIEW NOTICE
    # ============================================================

    if grep -qE \
        '#new default=|#deprecated|# DEPRECATED -' \
        "$output_config"; then

        echo \
            "[CONFIG-UPDATE] NOTICE: variables.cfg contains settings requiring review."

        echo \
            "[CONFIG-UPDATE] Existing user values were NOT automatically changed."

        echo \
            "[CONFIG-UPDATE] Review #new default and #deprecated annotations."

    fi
}

# ================================================================
# MIGRATION REGRESSION TEST SUITE
# ================================================================

function run_migration_tests() (
    set -u

    local test_root
    local old_printer new_printer output_printer
    local old_variables new_variables old_variables_template output_variables
    local passed=0
    local failed=0

    test_root="$(mktemp -d "${TMPDIR:-/tmp}/klippain-migration-test.XXXXXX")" || {
        echo "[TEST] ERROR: Unable to create temporary test directory."
        return 1
    }
    trap 'rm -rf "$test_root"' EXIT

    old_printer="${test_root}/printer-old.cfg"
    new_printer="${test_root}/printer-new.cfg"
    output_printer="${test_root}/printer-output.cfg"
    old_variables="${test_root}/variables-old.cfg"
    new_variables="${test_root}/variables-new.cfg"
    old_variables_template="${test_root}/variables-historical.cfg"
    output_variables="${test_root}/variables-output.cfg"

    test_pass() {
        printf "[TEST] %-48s PASS\n" "$1"
        passed=$((passed + 1))
    }

    test_fail() {
        printf "[TEST] %-48s FAIL\n" "$1"
        failed=$((failed + 1))
        if [[ -n "${2:-}" ]]; then
            printf "       %s\n" "$2"
        fi
    }

    assert_contains() {
        grep -Fq -- "$2" "$1"
    }

    assert_not_contains() {
        ! grep -Fq -- "$2" "$1"
    }

    assert_count() {
        local actual
        actual="$(grep -F -c -- "$2" "$1" 2>/dev/null || true)"
        [[ "$actual" -eq "$3" ]]
    }

    assert_before() {
        local first_line second_line
        first_line="$(grep -nF -- "$2" "$1" | head -n1 | cut -d: -f1)"
        second_line="$(grep -nF -- "$3" "$1" | head -n1 | cut -d: -f1)"
        [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]]
    }

    echo
    echo "======================================"
    echo "- Klippain Migration Test Suite -"
    echo "======================================"
    echo
    echo "[TEST] Temporary workspace: ${test_root}"
    echo "[TEST] Live Klipper configuration will NOT be modified."
    echo "[TEST] Klipper and Moonraker will NOT be restarted."
    echo

    # ------------------------------------------------------------
    # Tests 1-4: printer.cfg
    # ------------------------------------------------------------
    cat > "$new_printer" <<'TEST_EOF'
# Test Klippain printer.cfg template

# Kinematics
[include config/kinematics/cartesian.cfg]
# [include config/kinematics/corexy.cfg]

# Fans
[include config/hardware/fans/controller_fan.cfg]
# [include config/hardware/fans/rpi_fan.cfg]

# User configuration
[include variables.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF

    # Test 1: existing include state.
    cat > "$old_printer" <<'TEST_EOF'
[include config/kinematics/cartesian.cfg]
# [include config/kinematics/corexy.cfg]
# [include config/hardware/fans/controller_fan.cfg]
[include config/hardware/fans/rpi_fan.cfg]
[include variables.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF

    if migrate_printer_config "$old_printer" "$new_printer" "$output_printer" >/dev/null 2>&1 &&
       assert_contains "$output_printer" "# [include config/hardware/fans/controller_fan.cfg]" &&
       assert_contains "$output_printer" "[include config/hardware/fans/rpi_fan.cfg]" &&
       ! grep -qE '^[[:space:]]*#[[:space:]]*\[include[[:space:]]+config/hardware/fans/rpi_fan\.cfg\]' "$output_printer"; then
        test_pass "1. Existing include state"
    else
        test_fail "1. Existing include state"
    fi

    # Test 2: active custom include.
    cat > "$old_printer" <<'TEST_EOF'
[include config/kinematics/cartesian.cfg]
# [include config/kinematics/corexy.cfg]
[include config/hardware/fans/controller_fan.cfg]
# [include config/hardware/fans/rpi_fan.cfg]
[include variables.cfg]
[include migration_test.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF

    if migrate_printer_config "$old_printer" "$new_printer" "$output_printer" >/dev/null 2>&1 &&
       assert_contains "$output_printer" "[include migration_test.cfg]" &&
       assert_before "$output_printer" "[include variables.cfg]" "[include migration_test.cfg]" &&
       assert_before "$output_printer" "[include migration_test.cfg]" "[include mcu.cfg]"; then
        test_pass "2. Active custom include"
    else
        test_fail "2. Active custom include"
    fi

    # Test 3: disabled custom include remains disabled.
    cat > "$old_printer" <<'TEST_EOF'
[include config/kinematics/cartesian.cfg]
# [include config/kinematics/corexy.cfg]
[include config/hardware/fans/controller_fan.cfg]
# [include config/hardware/fans/rpi_fan.cfg]
[include variables.cfg]
# [include migration_disabled_test.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF

    if migrate_printer_config "$old_printer" "$new_printer" "$output_printer" >/dev/null 2>&1 &&
       grep -qF "# [include migration_disabled_test.cfg]" "$output_printer" &&
       ! grep -qE '^[[:space:]]*\[include[[:space:]]+migration_disabled_test\.cfg\]' "$output_printer"; then
        test_pass "3. Disabled custom include"
    else
        test_fail "3. Disabled custom include" "Disabled custom include was missing or became active."
    fi

    # Test 4: custom include before first template include.
    cat > "$old_printer" <<'TEST_EOF'
# [include early_custom_test.cfg]
[include config/kinematics/cartesian.cfg]
# [include config/kinematics/corexy.cfg]
[include config/hardware/fans/controller_fan.cfg]
# [include config/hardware/fans/rpi_fan.cfg]
[include variables.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF

    if migrate_printer_config "$old_printer" "$new_printer" "$output_printer" >/dev/null 2>&1 &&
       assert_before "$output_printer" "# [include early_custom_test.cfg]" "[include config/kinematics/cartesian.cfg]"; then
        test_pass "4. Following-anchor custom include"
    else
        test_fail "4. Following-anchor custom include"
    fi

    # Historical/base variables template used by tests 5-9.
    cat > "$old_variables_template" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]

variable_travel_speed: 350
variable_homing_first: "X" # can be set to "Y" first

variable_material_parameters: {
    'PLA': {
        'pressure_advance': 0.0525,
        'retract_length': 0.75,
    },
}

variable_migration_test_removed: 100
variable_migration_test_deprecated: 100

gcode:
    {% set dummy = 1 %}
TEST_EOF

    cp "$old_variables_template" "$new_variables"

    # Tests 5 and 6: customized single-line values and comments.
    cat > "$old_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]

variable_travel_speed: 375
variable_homing_first: "Y" # My migration test

variable_material_parameters: {
    'PLA': {
        'pressure_advance': 0.0525,
        'retract_length': 0.75,
    },
}

variable_migration_test_removed: 100
variable_migration_test_deprecated: 100

gcode:
    {% set dummy = 1 %}
TEST_EOF

    if migrate_variables_config "$old_variables" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1 &&
       assert_contains "$output_variables" "variable_travel_speed: 375 #new default=350"; then
        test_pass "5. Customized single-line value"
    else
        test_fail "5. Customized single-line value"
    fi

    if assert_contains "$output_variables" 'variable_homing_first: "Y" # My migration test #new default="X"'; then
        test_pass "6. Inline user comment preservation"
    else
        test_fail "6. Inline user comment preservation"
    fi

    # Test 7: new-default annotation idempotency.
    cp "$output_variables" "${test_root}/variables-pass1.cfg"
    if migrate_variables_config "${test_root}/variables-pass1.cfg" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1 &&
       assert_count "$output_variables" "#new default=350" 1 &&
       assert_count "$output_variables" '#new default="X"' 1; then
        test_pass "7. New-default annotation idempotency"
    else
        test_fail "7. New-default annotation idempotency"
    fi

    # Test 8: stale annotation cleanup when user adopts current default.
    cat > "$old_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]

variable_travel_speed: 350 #new default=350
variable_homing_first: "X"

variable_material_parameters: {
    'PLA': {
        'pressure_advance': 0.0525,
        'retract_length': 0.75,
    },
}

variable_migration_test_removed: 100
variable_migration_test_deprecated: 100

gcode:
    {% set dummy = 1 %}
TEST_EOF

    if migrate_variables_config "$old_variables" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1 &&
       assert_contains "$output_variables" "variable_travel_speed: 350" &&
       assert_not_contains "$output_variables" "variable_travel_speed: 350 #new default="; then
        test_pass "8. Stale new-default cleanup"
    else
        test_fail "8. Stale new-default cleanup"
    fi

    # Test 9: multiline customization and warning idempotency.
    cat > "$old_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]

variable_travel_speed: 350
variable_homing_first: "X"

variable_material_parameters: {
    'PLA': {
        'pressure_advance': 0.0525,
        'retract_length': 0.76,
    },
}

variable_migration_test_removed: 100
variable_migration_test_deprecated: 100

gcode:
    {% set dummy = 1 %}
TEST_EOF

    if migrate_variables_config "$old_variables" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1 &&
       assert_contains "$output_variables" "'retract_length': 0.76," &&
       assert_count "$output_variables" "# NEW DEFAULT AVAILABLE - see current Klippain variables.cfg" 1; then
        cp "$output_variables" "${test_root}/multiline-pass1.cfg"
        if migrate_variables_config "${test_root}/multiline-pass1.cfg" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1 &&
           assert_count "$output_variables" "# NEW DEFAULT AVAILABLE - see current Klippain variables.cfg" 1; then
            test_pass "9. Multiline variable + idempotency"
        else
            test_fail "9. Multiline variable + idempotency" "Warning was duplicated or removed on second migration."
        fi
    else
        test_fail "9. Multiline variable + idempotency"
    fi

    # Test 10: new upstream variable.
    cat > "$old_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
variable_homing_first: "X"
variable_material_parameters: {
    'PLA': {
        'pressure_advance': 0.0525,
        'retract_length': 0.75,
    },
}
gcode:
    {% set dummy = 1 %}
TEST_EOF

    cat > "$new_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
variable_homing_first: "X"
variable_migration_test_new: 12345
variable_material_parameters: {
    'PLA': {
        'pressure_advance': 0.0525,
        'retract_length': 0.75,
    },
}
gcode:
    {% set dummy = 1 %}
TEST_EOF

    if migrate_variables_config "$old_variables" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1 &&
       assert_contains "$output_variables" "variable_migration_test_new: 12345"; then
        test_pass "10. New upstream variable"
    else
        test_fail "10. New upstream variable"
    fi

    # Test 11: new upstream include.
    cat > "$old_printer" <<'TEST_EOF'
[include config/kinematics/cartesian.cfg]
[include variables.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF
    cat > "$new_printer" <<'TEST_EOF'
[include config/kinematics/cartesian.cfg]
# [include migration_test_new.cfg]
[include variables.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF

    if migrate_printer_config "$old_printer" "$new_printer" "$output_printer" >/dev/null 2>&1 &&
       assert_contains "$output_printer" "# [include migration_test_new.cfg]"; then
        test_pass "11. New upstream include"
    else
        test_fail "11. New upstream include"
    fi

    # Tests 12-14: historical removed/default/custom classification.
    cat > "$old_variables_template" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
variable_migration_test_removed: 100
variable_migration_test_deprecated: 100
gcode:
    {% set dummy = 1 %}
TEST_EOF
    cat > "$old_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
variable_migration_test_removed: 100
variable_migration_test_deprecated: 250
variable_george_custom_test: 8675309
gcode:
    {% set dummy = 1 %}
TEST_EOF
    cat > "$new_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
gcode:
    {% set dummy = 1 %}
TEST_EOF

    if migrate_variables_config "$old_variables" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1; then
        if assert_not_contains "$output_variables" "variable_migration_test_removed:"; then
            test_pass "12. Removed unchanged upstream variable"
        else
            test_fail "12. Removed unchanged upstream variable" "Obsolete variable was preserved."
        fi

        if assert_contains "$output_variables" "variable_migration_test_deprecated: 250 #deprecated"; then
            test_pass "13. Removed customized variable"
        else
            test_fail "13. Removed customized variable" "Customized removed variable was not marked deprecated."
        fi

        if assert_contains "$output_variables" "variable_george_custom_test: 8675309" &&
           assert_not_contains "$output_variables" "variable_george_custom_test: 8675309 #deprecated"; then
            test_pass "14. User-created variable"
        else
            test_fail "14. User-created variable" "Custom variable was removed or incorrectly deprecated."
        fi
    else
        test_fail "12. Removed unchanged upstream variable"
        test_fail "13. Removed customized variable"
        test_fail "14. User-created variable"
    fi

    # Test 15: deprecated annotation idempotency.
    cp "$output_variables" "${test_root}/deprecated-pass1.cfg"
    if migrate_variables_config "${test_root}/deprecated-pass1.cfg" "$new_variables" "$output_variables" "$old_variables_template" >/dev/null 2>&1 &&
       assert_count "$output_variables" "variable_migration_test_deprecated: 250 #deprecated" 1; then
        test_pass "15. Deprecated annotation idempotency"
    else
        test_fail "15. Deprecated annotation idempotency"
    fi

    # Test 16: historical template unavailable.
    cat > "$old_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
variable_unknown_history_test: 777
gcode:
    {% set dummy = 1 %}
TEST_EOF
    cat > "$new_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
gcode:
    {% set dummy = 1 %}
TEST_EOF

    if migrate_variables_config "$old_variables" "$new_variables" "$output_variables" "" >/dev/null 2>&1 &&
       assert_contains "$output_variables" "variable_unknown_history_test: 777" &&
       assert_not_contains "$output_variables" "variable_unknown_history_test: 777 #deprecated"; then
        test_pass "16. Missing-history safe fallback"
    else
        test_fail "16. Missing-history safe fallback"
    fi

    # Test 17: unchanged printer.cfg must not be replaced.
    cat > "$old_printer" <<'TEST_EOF'
[include config/kinematics/cartesian.cfg]
# [include config/kinematics/corexy.cfg]
[include config/hardware/fans/controller_fan.cfg]
# [include config/hardware/fans/rpi_fan.cfg]
[include variables.cfg]
[include mcu.cfg]
[include overrides.cfg]
TEST_EOF
    # First migration establishes the canonical migrated output.
    migrate_printer_config "$old_printer" "$new_printer" "$output_printer" >/dev/null 2>&1
    printer_inode_before="$(stat -c %i "$output_printer")"
    printer_mtime_before="$(stat -c %y "$output_printer")"

    # A second migration using the already-migrated file as the source
    # must leave the live file itself untouched.
    if migrate_printer_config "$output_printer" "$new_printer" "$output_printer" >/dev/null 2>&1 &&
       [[ "$(stat -c %i "$output_printer")" == "$printer_inode_before" ]] &&
       [[ "$(stat -c %y "$output_printer")" == "$printer_mtime_before" ]]; then
        test_pass "17. Unchanged printer.cfg not replaced"
    else
        test_fail "17. Unchanged printer.cfg not replaced" "Inode or modification time changed."
    fi

    # Test 18: unchanged variables.cfg must not be replaced.
    cat > "$old_variables" <<'TEST_EOF'
[gcode_macro _USER_VARIABLES]
variable_travel_speed: 350
gcode:
    {% set dummy = 1 %}
TEST_EOF
    cp "$old_variables" "$new_variables"
    cp "$old_variables" "$output_variables"
    variables_inode_before="$(stat -c %i "$output_variables")"
    variables_mtime_before="$(stat -c %y "$output_variables")"

    if migrate_variables_config "$old_variables" "$new_variables" "$output_variables" "" >/dev/null 2>&1 &&
       [[ "$(stat -c %i "$output_variables")" == "$variables_inode_before" ]] &&
       [[ "$(stat -c %y "$output_variables")" == "$variables_mtime_before" ]]; then
        test_pass "18. Unchanged variables.cfg not replaced"
    else
        test_fail "18. Unchanged variables.cfg not replaced" "Inode or modification time changed."
    fi

    echo
    echo "--------------------------------------"
    printf "%d passed\n" "$passed"
    printf "%d failed\n" "$failed"
    echo "--------------------------------------"
    echo

    if [[ "$failed" -eq 0 ]]; then
        echo "[TEST] Migration test suite PASSED."
        echo
        return 0
    fi

    echo "[TEST] Migration test suite FAILED."
    echo
    return 1
)

# ================================================================
# DIRECT EXECUTION
# ================================================================
# When sourced by install.sh, only the functions above are loaded.
# When executed directly, expose the regression-test entry point.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -eu

    case "${1:-}" in
        --test|--test-migration)
            run_migration_tests
            ;;
        "")
            echo "Klippain configuration migration module"
            echo
            echo "This script is normally sourced by install.sh."
            echo
            echo "Usage:"
            echo "  $0 --test-migration"
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown option: $1"
            echo "Usage: $0 --test-migration"
            exit 1
            ;;
    esac
fi
