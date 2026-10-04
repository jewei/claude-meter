# Converts one CHANGELOG.md section to HTML for the Sparkle update window.
# Usage: awk -f scripts/changelog-to-html.awk < section.md
#
# Supports what CHANGELOG.md uses: "### " headings, "- " list items with indented
# continuation lines, paragraphs, **bold**, `code`, and [text](url) links.

function inline(s,    text, k) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    while (match(s, /\*\*[^*]+\*\*/))
        s = substr(s, 1, RSTART - 1) "<strong>" substr(s, RSTART + 2, RLENGTH - 4) \
            "</strong>" substr(s, RSTART + RLENGTH)
    while (match(s, /`[^`]+`/))
        s = substr(s, 1, RSTART - 1) "<code>" substr(s, RSTART + 1, RLENGTH - 2) \
            "</code>" substr(s, RSTART + RLENGTH)
    while (match(s, /\[[^]]+\]\([^)]+\)/)) {
        text = substr(s, RSTART + 1, RLENGTH - 2)
        k = index(text, "](")
        s = substr(s, 1, RSTART - 1) "<a href=\"" substr(text, k + 2) "\">" \
            substr(text, 1, k - 1) "</a>" substr(s, RSTART + RLENGTH)
    }
    return s
}

function flush() {
    if (paragraph != "") print "<p>" paragraph "</p>"
    if (item != "") print "<li>" item "</li>"
    paragraph = ""
    item = ""
}

function end_list() {
    flush()
    if (in_list) print "</ul>"
    in_list = 0
}

/^### / { end_list(); print "<h3>" inline(substr($0, 5)) "</h3>"; next }

/^- / {
    flush()
    if (!in_list) print "<ul>"
    in_list = 1
    item = inline(substr($0, 3))
    next
}

!NF { end_list(); next }

{
    line = inline($0)
    sub(/^[ \t]+/, "", line)
    if (in_list) item = item " " line
    else paragraph = (paragraph == "" ? line : paragraph " " line)
}

END { end_list() }
