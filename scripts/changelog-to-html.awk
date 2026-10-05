# Converts one CHANGELOG.md section to HTML for the Sparkle update window.
# Usage: awk -f scripts/changelog-to-html.awk < section.md
#
# Supports what CHANGELOG.md uses: "##" to "######" headings (all as <h3>), "- " list items with indented
# continuation lines, paragraphs, **bold**, `code`, and [text](url) links.

function inline(s,    text, k, n, codes, url) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    # Set code spans aside first, so ** inside code stays literal.
    n = 0
    while (match(s, /`[^`]+`/)) {
        codes[++n] = "<code>" substr(s, RSTART + 1, RLENGTH - 2) "</code>"
        s = substr(s, 1, RSTART - 1) "\001" n "\002" substr(s, RSTART + RLENGTH)
    }
    while (match(s, /\*\*[^*]+\*\*/))
        s = substr(s, 1, RSTART - 1) "<strong>" substr(s, RSTART + 2, RLENGTH - 4) \
            "</strong>" substr(s, RSTART + RLENGTH)
    while (match(s, /\[[^]]+\]\([^)]+\)/)) {
        text = substr(s, RSTART + 1, RLENGTH - 2)
        k = index(text, "](")
        url = substr(text, k + 2)
        gsub(/"/, "\\&quot;", url)
        s = substr(s, 1, RSTART - 1) "<a href=\"" url "\">" \
            substr(text, 1, k - 1) "</a>" substr(s, RSTART + RLENGTH)
    }
    while (match(s, /\001[0-9]+\002/))
        s = substr(s, 1, RSTART - 1) codes[substr(s, RSTART + 1, RLENGTH - 2) + 0] \
            substr(s, RSTART + RLENGTH)
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

/^#{2,6} / { end_list(); sub(/^#+ /, ""); print "<h3>" inline($0) "</h3>"; next }

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
