#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Render BUSINESS_PLAN.md -> business-playbook.pdf (brand-styled, CJK-safe) using reportlab.
Single source of truth = the markdown. Run: python3 tools/build_playbook_pdf.py
"""
import re, sys, os
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import cm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import (SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
                                HRFlowable, KeepTogether)
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

# Embed a real CJK TrueType font (subset travels inside the PDF) so it renders
# correctly on ANY reader incl. iPhone. Adobe CID fonts (e.g. STSong-Light) are
# NOT embedded and get mis-substituted on devices without them -> garbled text.
FONT = 'WQY'
_TTC = '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc'
pdfmetrics.registerFont(TTFont(FONT, _TTC, subfontIndex=0))
# WenQuanYi Zen Hei has only a Regular weight; map bold/italic to it so <b>/<i>
# never fall back to a non-embedded font. Emphasis is conveyed via colour instead.
pdfmetrics.registerFontFamily(FONT, normal=FONT, bold=FONT, italic=FONT, boldItalic=FONT)

GOLD = colors.HexColor('#6E4F31')
GOLD_DEEP = colors.HexColor('#4A341F')
GOLD_LIGHT = colors.HexColor('#E8DACA')
INK = colors.HexColor('#2A2017')
MUTED = colors.HexColor('#8A7B6A')
CREAM = colors.HexColor('#FBF4EA')
LINE = colors.HexColor('#EADFCF')
HEADBG = colors.HexColor('#F3EADD')

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(HERE, 'BUSINESS_PLAN.md')
OUT = os.path.join(HERE, 'business-playbook.pdf')

PAGE_W, PAGE_H = A4
LMAR = RMAR = 1.5 * cm
USABLE = PAGE_W - LMAR - RMAR

# ---- styles (uniform type system: restrained 3-level hierarchy) ----
body = ParagraphStyle('body', fontName=FONT, fontSize=10.5, leading=16, textColor=INK, spaceAfter=7)
h1 = ParagraphStyle('h1', fontName=FONT, fontSize=16, leading=21, textColor=GOLD_DEEP, spaceBefore=4, spaceAfter=6)
h2 = ParagraphStyle('h2', fontName=FONT, fontSize=13, leading=18, textColor=GOLD, spaceBefore=8, spaceAfter=6)
h3 = ParagraphStyle('h3', fontName=FONT, fontSize=10.5, leading=16, textColor=GOLD_DEEP, spaceBefore=10, spaceAfter=4)
sub = ParagraphStyle('sub', fontName=FONT, fontSize=10.5, leading=15, textColor=MUTED, alignment=1, spaceAfter=2)
li = ParagraphStyle('li', parent=body, leftIndent=16, bulletIndent=2, spaceAfter=4)
cellst = ParagraphStyle('cell', fontName=FONT, fontSize=9.5, leading=13, textColor=INK)
cellhd = ParagraphStyle('cellhd', fontName=FONT, fontSize=9.5, leading=13, textColor=colors.white)
codest = ParagraphStyle('code', fontName=FONT, fontSize=9.5, leading=14, textColor=GOLD_DEEP)
callst = ParagraphStyle('call', fontName=FONT, fontSize=10.5, leading=16, textColor=INK)

# strip emoji / pictographs that the CID font can't render (keep arrows, math, CJK)
EMOJI = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF\U0000FE00-\U0000FE0F⬀-⯿]+",
    flags=re.UNICODE)

def vis_len(s):
    return sum(2 if ord(c) > 0x2E7F else 1 for c in s)

def inline(text):
    text = EMOJI.sub('', text)
    text = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    text = re.sub(r'`([^`]+)`', lambda m: '<font color="#4A341F">%s</font>' % m.group(1), text)
    # WQY has no bold weight -> render **emphasis** as deep-brown coloured text
    text = re.sub(r'\*\*([^*]+)\*\*', r'<font color="#4A341F"><b>\1</b></font>', text)
    text = re.sub(r'\*([^*]+)\*', r'<i>\1</i>', text)
    return text.strip()

def make_table(rows):
    header = [c.strip() for c in rows[0].strip().strip('|').split('|')]
    data_rows = []
    for r in rows[2:]:  # skip separator row
        cells = [c.strip() for c in r.strip().strip('|').split('|')]
        if len(cells) < len(header):
            cells += [''] * (len(header) - len(cells))
        data_rows.append(cells[:len(header)])
    ncol = len(header)
    # column widths proportional to max visible content length
    weights = []
    for c in range(ncol):
        w = vis_len(header[c])
        for dr in data_rows:
            w = max(w, vis_len(dr[c]))
        weights.append(max(w, 4))
    tot = sum(weights)
    widths = [max(38, USABLE * w / tot) for w in weights]
    # scale to fit
    scale = USABLE / sum(widths)
    widths = [w * scale for w in widths]
    table_data = [[Paragraph(inline(h), cellhd) for h in header]]
    for dr in data_rows:
        table_data.append([Paragraph(inline(x), cellst) for x in dr])
    t = Table(table_data, colWidths=widths, repeatRows=1)
    style = [
        ('FONTNAME', (0, 0), (-1, -1), FONT),
        ('BACKGROUND', (0, 0), (-1, 0), GOLD),
        ('TEXTCOLOR', (0, 0), (-1, 0), colors.white),
        ('GRID', (0, 0), (-1, -1), 0.5, LINE),
        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
        ('TOPPADDING', (0, 0), (-1, -1), 5),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 5),
        ('LEFTPADDING', (0, 0), (-1, -1), 6),
        ('RIGHTPADDING', (0, 0), (-1, -1), 6),
    ]
    for i in range(1, len(table_data)):
        if i % 2 == 0:
            style.append(('BACKGROUND', (0, i), (-1, i), CREAM))
    t.setStyle(TableStyle(style))
    return t

def make_callout(lines):
    html = '<br/>'.join(inline(l) for l in lines)
    p = Paragraph(html, callst)
    t = Table([[p]], colWidths=[USABLE])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, -1), CREAM),
        ('LINEBEFORE', (0, 0), (0, -1), 3, GOLD),
        ('BOX', (0, 0), (-1, -1), 0.5, GOLD_LIGHT),
        ('LEFTPADDING', (0, 0), (-1, -1), 12),
        ('RIGHTPADDING', (0, 0), (-1, -1), 10),
        ('TOPPADDING', (0, 0), (-1, -1), 8),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 8),
    ]))
    return t

def make_code(lines):
    safe = []
    for l in EMOJI.sub('', '\n'.join(lines)).split('\n'):
        l = l.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
        l = l.replace(' ', ' ')
        safe.append(l)
    p = Paragraph('<br/>'.join(safe), codest)
    t = Table([[p]], colWidths=[USABLE])
    t.setStyle(TableStyle([
        ('BACKGROUND', (0, 0), (-1, -1), HEADBG),
        ('BOX', (0, 0), (-1, -1), 0.5, GOLD_LIGHT),
        ('LEFTPADDING', (0, 0), (-1, -1), 12),
        ('RIGHTPADDING', (0, 0), (-1, -1), 10),
        ('TOPPADDING', (0, 0), (-1, -1), 8),
        ('BOTTOMPADDING', (0, 0), (-1, -1), 8),
    ]))
    return t

def parse(md):
    lines = md.split('\n')
    flow = []
    i = 0
    n = len(lines)
    first_h1_done = False
    while i < n:
        raw = lines[i]
        s = raw.strip()
        if not s:
            i += 1
            continue
        # fenced code
        if s.startswith('```'):
            j = i + 1
            buf = []
            while j < n and not lines[j].strip().startswith('```'):
                buf.append(lines[j])
                j += 1
            flow.append(make_code(buf))
            flow.append(Spacer(1, 6))
            i = j + 1
            continue
        # table
        if s.startswith('|'):
            buf = []
            while i < n and lines[i].strip().startswith('|'):
                buf.append(lines[i])
                i += 1
            if len(buf) >= 2:
                flow.append(make_table(buf))
                flow.append(Spacer(1, 6))
            continue
        # hr (the single, uniform section divider used throughout)
        if s in ('---', '***', '___'):
            flow.append(HRFlowable(width='100%', thickness=0.5, color=LINE,
                                   spaceBefore=4, spaceAfter=10))
            i += 1
            continue
        # headings (no underlines; hierarchy via size + colour + spacing only)
        if s.startswith('# '):
            flow.append(Paragraph(inline(s[2:]), h1))
            i += 1
            continue
        if s.startswith('## '):
            flow.append(Paragraph(inline(s[3:]), h2))
            i += 1
            continue
        if s.startswith('### '):
            flow.append(Paragraph(inline(s[4:]), h3))
            i += 1
            continue
        # blockquote (callout)
        if s.startswith('>'):
            buf = []
            while i < n and lines[i].strip().startswith('>'):
                buf.append(lines[i].strip()[1:].strip())
                i += 1
            buf = [b for b in buf if b != '']
            flow.append(make_callout(buf))
            flow.append(Spacer(1, 6))
            continue
        # lists (bullets, checkboxes, numbered)
        if re.match(r'^(-|\*)\s+', s) or re.match(r'^\d+\.\s+', s):
            while i < n and (re.match(r'^(-|\*)\s+', lines[i].strip()) or
                             re.match(r'^\d+\.\s+', lines[i].strip())):
                it = lines[i].strip()
                m = re.match(r'^(-|\*)\s+\[ \]\s+(.*)', it)
                if m:
                    flow.append(Paragraph(inline(m.group(2)), li, bulletText='□'))
                elif re.match(r'^(-|\*)\s+', it):
                    flow.append(Paragraph(inline(re.sub(r'^(-|\*)\s+', '', it)), li, bulletText='•'))
                else:
                    num = re.match(r'^(\d+\.)\s+(.*)', it)
                    flow.append(Paragraph(inline(num.group(2)), li, bulletText=num.group(1)))
                i += 1
            flow.append(Spacer(1, 3))
            continue
        # paragraph
        buf = [s]
        i += 1
        while i < n and lines[i].strip() and not re.match(
                r'^(#|>|\||```|-\s|\*\s|\d+\.\s|---|\*\*\*)', lines[i].strip()):
            buf.append(lines[i].strip())
            i += 1
        flow.append(Paragraph(inline(' '.join(buf)), body))
    return flow

def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont(FONT, 8)
    canvas.setFillColor(MUTED)
    canvas.drawString(LMAR, 1.0 * cm, 'The Unspoken Gift · Business & Operations Playbook')
    canvas.drawRightString(PAGE_W - RMAR, 1.0 * cm, 'P. %d' % doc.page)
    canvas.setStrokeColor(LINE)
    canvas.setLineWidth(0.5)
    canvas.line(LMAR, 1.35 * cm, PAGE_W - RMAR, 1.35 * cm)
    canvas.restoreState()

def main():
    with open(SRC, encoding='utf-8') as f:
        md = f.read()
    flow = parse(md)
    doc = SimpleDocTemplate(OUT, pagesize=A4, leftMargin=LMAR, rightMargin=RMAR,
                            topMargin=1.4 * cm, bottomMargin=1.7 * cm,
                            title='The Unspoken Gift — Business & Operations Playbook')
    doc.build(flow, onFirstPage=footer, onLaterPages=footer)
    print('WROTE', OUT, os.path.getsize(OUT), 'bytes')

if __name__ == '__main__':
    main()
