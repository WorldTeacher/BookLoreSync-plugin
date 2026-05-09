set -eu

PLUGIN_DIR="${1:-.}"
PLUGIN_DIR="${PLUGIN_DIR%/}"

LOCALE_DIR="$PLUGIN_DIR/locale"

PLUGIN_BASENAME="$(basename "$PLUGIN_DIR")"
DOMAIN="${2:-${PLUGIN_BASENAME%.koplugin}}"

POT_FILE="$LOCALE_DIR/$DOMAIN.pot"
TMP_FILE="$(mktemp)"

cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: $1 not found."
        echo "Install gettext first, e.g.: sudo pacman -S gettext"
        exit 1
    fi
}

need_cmd xgettext
need_cmd msgmerge
need_cmd msgfmt

mkdir -p "$LOCALE_DIR"

echo "Plugin dir:   $PLUGIN_DIR"
echo "Locale dir:   $LOCALE_DIR"
echo "Domain:       $DOMAIN"
echo "POT file:     $POT_FILE"
echo

find "$PLUGIN_DIR" \
    -type f \
    -name "*.lua" \
    ! -path "$LOCALE_DIR/*" \
    -print > "$TMP_FILE"

if [ ! -s "$TMP_FILE" ]; then
    echo "No Lua files found."
    exit 1
fi

echo "Updating POT file..."

xgettext \
    --from-code=UTF-8 \
    --language=Lua \
    --keyword=_ \
    --keyword=N_ \
    --keyword=C_:1c,2 \
    --keyword=NC_:1c,2 \
    --add-comments=TRANSLATORS: \
    --sort-by-file \
    --output="$POT_FILE" \
    --files-from="$TMP_FILE"

echo "POT file updated: $POT_FILE"
echo

find "$LOCALE_DIR" \
    -type f \
    -path "*/LC_MESSAGES/$DOMAIN.po" \
    -print | while read -r PO_FILE; do
        MO_FILE="${PO_FILE%.po}.mo"

        echo "Updating PO file: $PO_FILE"

        msgmerge \
            --update \
            --backup=none \
            --sort-by-file \
            "$PO_FILE" \
            "$POT_FILE"

        echo "Compiling MO file: $MO_FILE"

        msgfmt \
            --check \
            --output-file="$MO_FILE" \
            "$PO_FILE"

        echo
    done

echo "Done."
echo
echo "Updated:"
echo "  $POT_FILE"
echo "  locale/*/LC_MESSAGES/$DOMAIN.po"
echo "  locale/*/LC_MESSAGES/$DOMAIN.mo"