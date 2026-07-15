#!/usr/bin/env python3
# ============================================================
#  File:      appcast_annotate.py
#  Created:   2026-07-15
#  Updated:   2026-07-15
#  Developer: Kennt Kim / Calida Lab
#  Overview:  Post-processes the appcast.xml that Sparkle's generate_appcast emits,
#             injecting two things it never writes itself:
#               1. <sparkle:criticalUpdate sparkle:version="VERSION"/>  — ONLY when
#                  CRITICAL=1. Most releases are ordinary updates, so this is opt-in;
#                  when set, users below VERSION cannot skip the update.
#               2. <description><![CDATA[ ... ]]></description> — the release notes
#                  shown in Sparkle's update dialog, converted from a small Markdown
#                  subset (headings, bullet lists, **bold**, inline text) to HTML.
#             Only the newest <item> (matching VERSION) is annotated; the DMG
#             enclosure and its EdDSA signature are left untouched.
#
#  Env in:    VERSION    (required) e.g. "3.2.0" — the release being annotated
#             CRITICAL   "1" to mark critical, anything else = ordinary update
#             NOTES_FILE (optional) path to a Markdown/HTML release-notes file
#  Argv:      argv[1] = path to appcast.xml to edit in place
#  Notes:     Idempotent — re-running does not duplicate tags. If NOTES_FILE looks
#             like HTML already (contains a tag), it is embedded verbatim.
# ============================================================
import html as _html
import os
import re
import sys


def md_to_html(md: str) -> str:
    """Convert a small, predictable Markdown subset to HTML for the Sparkle dialog."""
    out, in_ul = [], False

    def inline(text: str) -> str:
        text = _html.escape(text.strip())
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
        text = re.sub(r"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)", r"<i>\1</i>", text)
        # [label](url) -> anchor
        text = re.sub(r"\[(.+?)\]\((https?://[^)]+)\)", r'<a href="\2">\1</a>', text)
        return text

    for raw in md.splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped:
            if in_ul:
                out.append("</ul>"); in_ul = False
            continue
        m = re.match(r"^(#{1,6})\s+(.*)$", stripped)
        if m:
            if in_ul:
                out.append("</ul>"); in_ul = False
            level = min(len(m.group(1)) + 1, 4)  # '# ' -> h2, keep it modest for a dialog
            out.append("<h%d>%s</h%d>" % (level, inline(m.group(2)), level))
            continue
        m = re.match(r"^[-*]\s+(.*)$", stripped)
        if m:
            if not in_ul:
                out.append("<ul>"); in_ul = True
            out.append("<li>%s</li>" % inline(m.group(1)))
            continue
        # plain paragraph line
        if in_ul:
            out.append("</ul>"); in_ul = False
        out.append("<p>%s</p>" % inline(stripped))

    if in_ul:
        out.append("</ul>")
    return "\n".join(out)


def load_notes(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        text = f.read().strip()
    if not text:
        return ""
    # Already HTML? (has a tag) — embed verbatim; otherwise treat as Markdown.
    if re.search(r"<[a-zA-Z][^>]*>", text):
        return text
    return md_to_html(text)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: appcast_annotate.py <appcast.xml>", file=sys.stderr)
        return 2
    path = sys.argv[1]
    version = os.environ.get("VERSION", "").strip()
    critical = os.environ.get("CRITICAL", "0").strip() == "1"
    notes_file = os.environ.get("NOTES_FILE", "").strip()
    if not version:
        print("appcast_annotate: VERSION env is required", file=sys.stderr)
        return 2

    xml = open(path, encoding="utf-8").read()

    # Locate the <item> whose <sparkle:version> matches VERSION (the release we built).
    item_re = re.compile(r"(<item>)(.*?)(</item>)", re.S)

    def annotate(match: "re.Match") -> str:
        open_tag, body, close_tag = match.group(1), match.group(2), match.group(3)
        ver_m = re.search(r"<sparkle:version>([^<]+)</sparkle:version>", body)
        if not ver_m or ver_m.group(1).strip() != version:
            return match.group(0)  # not our release — leave untouched

        indent = "            "  # match generate_appcast's 12-space item-child indent

        # 1) critical (opt-in, idempotent)
        if critical and "criticalUpdate" not in body:
            tag = '%s<sparkle:criticalUpdate sparkle:version="%s"/>\n' % (indent, version)
            # place right before the enclosure for readability
            enc = re.search(r"\n\s*<enclosure", body)
            if enc:
                body = body[:enc.start()] + "\n" + tag.rstrip("\n") + body[enc.start():]
            else:
                body = body + tag

        # 2) description (idempotent)
        if notes_file and "<description>" not in body:
            notes_html = load_notes(notes_file)
            if notes_html:
                desc = "%s<description><![CDATA[\n%s\n%s]]></description>\n" % (
                    indent, notes_html, indent)
                enc = re.search(r"\n\s*<enclosure", body)
                if enc:
                    body = body[:enc.start()] + "\n" + desc.rstrip("\n") + body[enc.start():]
                else:
                    body = body + desc

        return open_tag + body + close_tag

    new_xml, n = item_re.subn(annotate, xml, count=0)
    if n == 0:
        print("appcast_annotate: no <item> found", file=sys.stderr)
        return 1
    open(path, "w", encoding="utf-8").write(new_xml)
    print("appcast_annotate: v%s  critical=%s  notes=%s"
          % (version, int(critical), notes_file or "-"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
