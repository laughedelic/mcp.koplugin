#!/usr/bin/env python3
"""Write the e2e test books: a small EPUB and a small PDF.

The text is from Lewis Carroll's "Alice's Adventures in Wonderland" (1865),
which is in the public domain. The books are generated rather than downloaded
so the test needs no network access for them and the content never changes.

Usage: make_books.py OUT_DIR
"""
import sys
import zipfile
from pathlib import Path

TITLE = "Alice's Adventures in Wonderland (excerpt)"
AUTHOR = "Lewis Carroll"

CHAPTERS = [
    ("Down the Rabbit-Hole", [
        "Alice was beginning to get very tired of sitting by her sister on the bank, "
        "and of having nothing to do: once or twice she had peeped into the book her "
        "sister was reading, but it had no pictures or conversations in it, "
        "“and what is the use of a book,” thought Alice "
        "“without pictures or conversations?”",
        "So she was considering in her own mind (as well as she could, for the hot day "
        "made her feel very sleepy and stupid), whether the pleasure of making a "
        "daisy-chain would be worth the trouble of getting up and picking the daisies, "
        "when suddenly a White Rabbit with pink eyes ran close by her.",
        "There was nothing so very remarkable in that; nor did Alice think it so very "
        "much out of the way to hear the Rabbit say to itself, “Oh dear! Oh dear! "
        "I shall be late!”",
    ]),
    ("The Pool of Tears", [
        "“Curiouser and curiouser!” cried Alice (she was so much surprised, "
        "that for the moment she quite forgot how to speak good English); “now I'm "
        "opening out like the largest telescope that ever was! Good-bye, feet!”",
        "Just then her head struck against the roof of the hall: in fact she was now "
        "rather more than nine feet high, and she at once took up the little golden key "
        "and hurried off to the garden door.",
    ]),
    ("A Caucus-Race and a Long Tale", [
        "They were indeed a queer-looking party that assembled on the bank, the birds "
        "with draggled feathers, the animals with their fur clinging close to them, and "
        "all dripping wet, cross, and uncomfortable.",
        "“What I was going to say,” said the Dodo in an offended tone, "
        "“was, that the best thing to get us dry would be a Caucus-race.”",
    ]),
]


def xml_escape(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def make_epub(path):
    container = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>
"""
    manifest, spine, nav_items, ncx_points = [], [], [], []
    chapters = {}
    for i, (name, paras) in enumerate(CHAPTERS, 1):
        fname = f"ch{i}.xhtml"
        body = "\n".join(f"<p>{xml_escape(p)}</p>" for p in paras)
        chapters[fname] = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en">
<head><title>{xml_escape(name)}</title></head>
<body><h1>Chapter {i}: {xml_escape(name)}</h1>
{body}
</body></html>
"""
        manifest.append(f'<item id="ch{i}" href="{fname}" media-type="application/xhtml+xml"/>')
        spine.append(f'<itemref idref="ch{i}"/>')
        nav_items.append(f'<li><a href="{fname}">{xml_escape(name)}</a></li>')
        ncx_points.append(f'<navPoint id="np{i}" playOrder="{i}"><navLabel><text>{xml_escape(name)}</text>'
                          f'</navLabel><content src="{fname}"/></navPoint>')
    opf = f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">urn:uuid:6f1e6c2e-7d4b-4f0e-9a51-3c0e2e7e5b00</dc:identifier>
    <dc:title>{xml_escape(TITLE)}</dc:title>
    <dc:creator>{AUTHOR}</dc:creator>
    <dc:language>en</dc:language>
    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    {"".join(manifest)}
  </manifest>
  <spine toc="ncx">{"".join(spine)}</spine>
</package>
"""
    nav = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body><nav epub:type="toc"><ol>{"".join(nav_items)}</ol></nav></body></html>
"""
    ncx = f"""<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
<head><meta name="dtb:uid" content="urn:uuid:6f1e6c2e-7d4b-4f0e-9a51-3c0e2e7e5b00"/></head>
<docTitle><text>{xml_escape(TITLE)}</text></docTitle>
<navMap>{"".join(ncx_points)}</navMap></ncx>
"""
    with zipfile.ZipFile(path, "w") as z:
        z.writestr(zipfile.ZipInfo("mimetype"), "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("OEBPS/toc.ncx", ncx, compress_type=zipfile.ZIP_DEFLATED)
        for fname, content in chapters.items():
            z.writestr("OEBPS/" + fname, content, compress_type=zipfile.ZIP_DEFLATED)


def wrap(text, width=70):
    lines, line = [], ""
    for word in text.split():
        if line and len(line) + 1 + len(word) > width:
            lines.append(line)
            line = word
        else:
            line = f"{line} {word}" if line else word
    if line:
        lines.append(line)
    return lines


def pdf_string(s):
    # WinAnsiEncoding covers the curly quotes used in the text
    b = s.encode("cp1252")
    return b"(" + b.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)") + b")"


def make_pdf(path):
    objects = []  # index i holds object number i+1

    def add(body):
        objects.append(body)
        return len(objects)

    catalog = add(None)
    pages = add(None)
    font = add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    page_ids = []
    for i, (name, paras) in enumerate(CHAPTERS, 1):
        # 18 pt heading, then 12 pt body text with 16 pt leading (' moves to the next line and shows text)
        ops = [b"BT /F1 18 Tf 72 740 Td", pdf_string(f"Chapter {i}: {name}") + b" Tj", b"/F1 12 Tf 16 TL T* T*"]
        for p in paras:
            for line in wrap(p):
                ops.append(pdf_string(line) + b" ' ")
            ops.append(b"T*")
        ops.append(b"ET")
        stream = b"\n".join(ops)
        content = add(b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream")
        page_ids.append(add(b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 612 792] "
                            b"/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>" % (pages, font, content)))
    info = add(b"<< /Title " + pdf_string(TITLE) + b" /Author " + pdf_string(AUTHOR) + b" >>")
    objects[catalog - 1] = b"<< /Type /Catalog /Pages %d 0 R >>" % pages
    kids = b" ".join(b"%d 0 R" % p for p in page_ids)
    objects[pages - 1] = b"<< /Type /Pages /Kids [" + kids + b"] /Count %d >>" % len(page_ids)

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for n, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % n + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root %d 0 R /Info %d 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1, catalog, info, xref)
    Path(path).write_bytes(bytes(out))


if __name__ == "__main__":
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    make_epub(out_dir / "alice.epub")
    make_pdf(out_dir / "alice.pdf")
    print(out_dir / "alice.epub")
    print(out_dir / "alice.pdf")
