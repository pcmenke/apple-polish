#!/usr/bin/env python3
"""Build a local, filterable gallery of the biggest iMessage attachments.

Reads a private copy of ~/Library/Messages/chat.db (needs Full Disk Access for your
terminal), joins each attachment to its conversation, sender and date, makes
thumbnails (sips for photos, ffmpeg for videos), and writes out/index.html.
Nothing leaves this machine and nothing in ~/Library/Messages is modified or deleted.

Usage: ./build.py [--top 400] [--min-mb 1] [--all-kinds] [--open]
Delete things from inside the Messages app (not from the Attachments folder), so the
database and iCloud stay consistent.
"""
import argparse
import datetime
import html
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import urllib.parse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HOME = Path.home()
MESSAGES = HOME / "Library/Messages"
OUT = Path(__file__).resolve().parent / "out"
APPLE_EPOCH = 978307200
VIDEO_EXT = {"mov", "mp4", "m4v", "3gp", "avi"}
IMAGE_EXT = {"heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "tiff", "tif"}


def kind_of(path, mime):
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
    mime = mime or ""
    if mime.startswith("video") or ext in VIDEO_EXT:
        return "video"
    if mime.startswith("image") or ext in IMAGE_EXT:
        return "photo"
    return "other"


def copy_db(tmp):
    for name in ("chat.db", "chat.db-wal", "chat.db-shm"):
        src = MESSAGES / name
        if src.exists():
            shutil.copy2(src, Path(tmp) / name)
    return Path(tmp) / "chat.db"


def norm_phone(s):
    digits = re.sub(r"\D", "", s or "")
    return digits[-10:] if len(digits) >= 10 else digits


def load_contacts():
    """handle id (phone or email) -> display name, from the local AddressBook."""
    names = {}
    for db in (HOME / "Library/Application Support/AddressBook").glob("**/AddressBook-v22.abcddb"):
        try:
            with tempfile.TemporaryDirectory() as tmp:
                shutil.copy2(db, Path(tmp) / "ab.db")
                con = sqlite3.connect(Path(tmp) / "ab.db")
                recs = {}
                for pk, first, last, nick, org in con.execute(
                    "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZNICKNAME, ZORGANIZATION FROM ZABCDRECORD"
                ):
                    full = " ".join(p for p in (first, last) if p) or nick or org
                    if full:
                        recs[pk] = full
                for owner, num in con.execute("SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER"):
                    if owner in recs and num:
                        names[norm_phone(num)] = recs[owner]
                for owner, addr in con.execute("SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS"):
                    if owner in recs and addr:
                        names[addr.lower()] = recs[owner]
        except Exception as exc:  # contacts are a nicety; never fail on them
            print(f"warning: could not read contacts from {db}: {exc}", file=sys.stderr)
    return names


def who(handle, contacts):
    if not handle:
        return ""
    return contacts.get(handle.lower()) or contacts.get(norm_phone(handle)) or handle


QUERY = """
SELECT a.ROWID, a.filename, a.mime_type, a.transfer_name,
       m.date, m.is_from_me, h.id,
       c.display_name, c.chat_identifier, c.style,
       (SELECT group_concat(h2.id, ',') FROM chat_handle_join chj
          JOIN handle h2 ON h2.ROWID = chj.handle_id WHERE chj.chat_id = c.ROWID)
FROM attachment a
JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
JOIN message m ON m.ROWID = maj.message_id
LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
LEFT JOIN chat c ON c.ROWID = cmj.chat_id
LEFT JOIN handle h ON h.ROWID = m.handle_id
WHERE a.filename IS NOT NULL
"""


def collect(args):
    contacts = load_contacts()
    items = {}
    with tempfile.TemporaryDirectory() as tmp:
        con = sqlite3.connect(copy_db(tmp))
        for (rowid, filename, mime, transfer, date, from_me, handle,
             disp, ident, style, members) in con.execute(QUERY):
            path = filename.replace("~", str(HOME), 1) if filename.startswith("~") else filename
            kind = kind_of(path, mime)
            if kind == "other" and not args.all_kinds:
                continue
            try:
                size = os.path.getsize(path)
            except OSError:
                continue  # not downloaded locally
            if size < args.min_mb * 1e6 or path in items:
                continue
            group = style == 43
            if disp:
                convo = disp
            elif group and members:
                convo = ", ".join(who(x, contacts) for x in members.split(",")[:4])
            else:
                convo = who(ident, contacts) if ident else "(unknown)"
            ts = datetime.datetime.fromtimestamp(date / 1e9 + APPLE_EPOCH) if date else None
            items[path] = {
                "id": rowid,
                "path": path,
                "name": transfer or os.path.basename(path),
                "kind": kind,
                "size": size,
                "date": ts.strftime("%Y-%m-%d %H:%M") if ts else "",
                "convo": convo,
                "group": bool(group),
                "sender": "You" if from_me else who(handle, contacts),
                "url": "file://" + urllib.parse.quote(path),
            }
    rows = sorted(items.values(), key=lambda r: r["size"], reverse=True)
    return rows[: args.top]


def make_thumb(row):
    dest = OUT / "thumbs" / f"{row['id']}.jpg"
    row["thumb"] = f"thumbs/{row['id']}.jpg"
    if dest.exists():
        return
    if row["kind"] == "photo":
        cmd = ["sips", "-s", "format", "jpeg", "-Z", "480", row["path"], "--out", str(dest)]
    else:
        cmd = ["ffmpeg", "-loglevel", "error", "-y", "-ss", "0.5", "-i", row["path"],
               "-frames:v", "1", "-vf", "scale=480:-2", str(dest)]
    r = subprocess.run(cmd, capture_output=True)
    if r.returncode != 0 and row["kind"] == "video":  # clip shorter than 0.5s
        subprocess.run([c if c != "0.5" else "0" for c in cmd], capture_output=True)
    if not dest.exists():
        row["thumb"] = ""


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>iMessage media</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1d1d1f;--mut:#6e6e73;--card:#f5f5f7;--line:#d2d2d7;--acc:#0071e3}
@media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--fg:#f5f5f7;--mut:#98989d;--card:#2c2c2e;--line:#3a3a3c;--acc:#0a84ff}}
body{margin:0;font:14px -apple-system,system-ui,sans-serif;background:var(--bg);color:var(--fg)}
header{position:sticky;top:0;z-index:5;background:var(--bg);border-bottom:1px solid var(--line);padding:12px 16px}
h1{font-size:17px;margin:0 0 8px}
.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center}
select,input[type=search],input[type=number]{font:inherit;padding:5px 8px;border:1px solid var(--line);border-radius:7px;background:var(--card);color:var(--fg)}
input[type=number]{width:64px}
button{font:inherit;padding:5px 10px;border:0;border-radius:7px;background:var(--acc);color:#fff;cursor:pointer}
button.sec{background:var(--card);color:var(--fg);border:1px solid var(--line)}
#sum{color:var(--mut);margin-left:auto}
.note{background:var(--card);border-radius:8px;padding:8px 12px;margin:12px 16px;color:var(--mut)}
#grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(210px,1fr));gap:12px;padding:0 16px 40px}
.c{background:var(--card);border-radius:10px;overflow:hidden;position:relative}
.c.sel{outline:3px solid var(--acc)}
.t{aspect-ratio:1;background:#0003;display:flex;align-items:center;justify-content:center;cursor:pointer;position:relative}
.t img{width:100%;height:100%;object-fit:cover}
.badge{position:absolute;left:6px;bottom:6px;background:#000a;color:#fff;border-radius:5px;padding:1px 6px;font-size:12px}
.sz{position:absolute;right:6px;top:6px;background:#000a;color:#fff;border-radius:5px;padding:1px 6px;font-size:12px;font-weight:600}
.cb{position:absolute;left:6px;top:6px;width:18px;height:18px}
.m{padding:7px 9px;font-size:12px;line-height:1.35}
.m b{display:block;font-size:13px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.m span{color:var(--mut);display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#lb{position:fixed;inset:0;background:#000d;display:none;align-items:center;justify-content:center;z-index:9;flex-direction:column;gap:10px}
#lb.on{display:flex}
#lb img,#lb video{max-width:94vw;max-height:84vh;border-radius:6px}
#lb .cap{color:#fff;text-align:center}
#lb a{color:#8cf}
</style>
<header>
<h1>iMessage media, biggest first <span style="font-weight:400;color:var(--mut)">(__TOTAL__ across __COUNT__ files)</span></h1>
<div class=bar>
<select id=kind><option value="">Photos + videos</option><option value=video>Videos</option><option value=photo>Photos</option></select>
<select id=convo></select>
<input id=q type=search placeholder="Search name, person, date (2025-06)">
<label>min <input id=min type=number value=0 min=0 step=1> MB</label>
<select id=sort><option value=size>Largest first</option><option value=old>Oldest first</option><option value=new>Newest first</option></select>
<button class=sec id=clr>Clear selection</button>
<button id=copy>Copy selected list</button>
<span id=sum></span>
</div></header>
<div class=note>Select items to total them up and copy a list (conversation, date, sender, file). To delete, open that
conversation in Messages, find the date, and delete there (Info → Photos, or press and hold on the item). Don't delete files
from the Attachments folder directly. Videos play best in Safari. Click a tile to preview it.</div>
<div id=grid></div>
<div id=lb><div class=cap id=cap></div><div id=media></div></div>
<script>
const D=__DATA__;
const $=id=>document.getElementById(id);
const mb=n=>n>=1e9?(n/1e9).toFixed(2)+' GB':(n/1e6).toFixed(1)+' MB';
const sel=new Set();
const convos=new Map();
D.forEach(r=>{const c=convos.get(r.convo)||{n:0,s:0};c.n++;c.s+=r.size;convos.set(r.convo,c)});
$('convo').innerHTML='<option value="">All conversations</option>'+[...convos].sort((a,b)=>b[1].s-a[1].s)
 .map(([k,v])=>`<option value="${k.replace(/"/g,'&quot;')}">${k.replace(/</g,'&lt;')} - ${mb(v.s)} (${v.n})</option>`).join('');
function view(){
 const kind=$('kind').value,cv=$('convo').value,q=$('q').value.toLowerCase(),min=+$('min').value*1e6,so=$('sort').value;
 let rows=D.filter(r=>(!kind||r.kind===kind)&&(!cv||r.convo===cv)&&r.size>=min&&
  (!q||(r.name+' '+r.convo+' '+r.sender+' '+r.date).toLowerCase().includes(q)));
 rows.sort((a,b)=>so==='size'?b.size-a.size:so==='old'?a.date.localeCompare(b.date):b.date.localeCompare(a.date));
 $('grid').innerHTML=rows.map(r=>`<div class="c${sel.has(r.id)?' sel':''}" data-id=${r.id}>
  <div class=t onclick="open_(${r.id})">${r.thumb?`<img loading=lazy src="${r.thumb}">`:'<span>no preview</span>'}
   <span class=sz>${mb(r.size)}</span><span class=badge>${r.kind==='video'?'video':'photo'}</span></div>
  <input class=cb type=checkbox ${sel.has(r.id)?'checked':''} onchange="tog(${r.id},this.checked)">
  <div class=m><b title="${r.convo.replace(/"/g,'&quot;')}">${r.convo.replace(/</g,'&lt;')}</b>
  <span>${r.date} - ${r.sender.replace(/</g,'&lt;')}</span><span>${r.name.replace(/</g,'&lt;')}</span></div></div>`).join('');
 stat(rows);
}
function stat(rows){
 const picked=D.filter(r=>sel.has(r.id));
 $('sum').textContent=(rows?rows.length+' shown. ':'')+picked.length+' selected = '+mb(picked.reduce((s,r)=>s+r.size,0));
}
function tog(id,on){on?sel.add(id):sel.delete(id);document.querySelector(`.c[data-id="${id}"]`).classList.toggle('sel',on);stat();}
function open_(id){
 const r=D.find(x=>x.id===id);
 $('media').innerHTML=r.kind==='video'?`<video src="${r.url}" controls autoplay></video>`:`<img src="${r.url}" onerror="this.src='${r.thumb}'">`;
 $('cap').innerHTML=`${r.convo.replace(/</g,'&lt;')} - ${r.date} - ${r.sender.replace(/</g,'&lt;')} - ${mb(r.size)}<br><a href="${r.url}">open original</a>`;
 $('lb').classList.add('on');
}
$('lb').onclick=e=>{if(e.target.tagName!=='A'&&e.target.tagName!=='VIDEO'){$('lb').classList.remove('on');$('media').innerHTML='';}};
['kind','convo','sort'].forEach(i=>$(i).onchange=view);['q','min'].forEach(i=>$(i).oninput=view);
$('clr').onclick=()=>{sel.clear();view();};
$('copy').onclick=()=>{
 const t=D.filter(r=>sel.has(r.id)).map(r=>`${r.date}\\t${mb(r.size)}\\t${r.convo}\\t${r.sender}\\t${r.name}`).join('\\n');
 navigator.clipboard.writeText(t).then(()=>{$('copy').textContent='Copied';setTimeout(()=>$('copy').textContent='Copy selected list',1200)});
};
view();
</script>"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--top", type=int, default=400, help="keep the N largest (default 400)")
    ap.add_argument("--min-mb", type=float, default=1.0, help="ignore files smaller than this (default 1)")
    ap.add_argument("--all-kinds", action="store_true", help="include link previews, stickers, etc.")
    ap.add_argument("--open", action="store_true", help="open the page when done")
    args = ap.parse_args()

    (OUT / "thumbs").mkdir(parents=True, exist_ok=True)
    try:
        rows = collect(args)
    except (sqlite3.OperationalError, PermissionError) as exc:
        sys.exit(f"error: cannot read Messages data ({exc}).\n"
                 "Give your terminal Full Disk Access in System Settings -> Privacy & Security.")
    print(f"{len(rows)} attachments, {sum(r['size'] for r in rows) / 1e9:.2f} GB; making thumbnails...")
    with ThreadPoolExecutor(6) as pool:
        list(pool.map(make_thumb, rows))
    page = (PAGE.replace("__DATA__", json.dumps(rows).replace("</", "<\\/"))
            .replace("__TOTAL__", f"{sum(r['size'] for r in rows) / 1e9:.2f} GB")
            .replace("__COUNT__", str(len(rows))))
    (OUT / "index.html").write_text(page)
    print(f"wrote {OUT / 'index.html'}")
    if args.open:
        subprocess.run(["open", str(OUT / "index.html")])


if __name__ == "__main__":
    main()
