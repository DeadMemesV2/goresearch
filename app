# app.py
"""
Gore Scanner — 2 tabs: Scan (online databases + media), AI Verifier (double-check media for gore).
Dark mode default. Severity 0.1–1.0.
"""

import csv
import os
import re
import sys
import threading
import json
from datetime import datetime
from urllib.parse import urljoin, urlparse

try:
    import tkinter as tk
    from tkinter import ttk, messagebox, filedialog
except ImportError:
    print("ERROR: Tkinter not installed.")
    sys.exit(1)

try:
    from PIL import Image, ImageTk
except ImportError:
    print("ERROR: Pillow not installed. pip install pillow")
    sys.exit(1)

try:
    from duckduckgo_search import DDGS
except ImportError:
    print("ERROR: duckduckgo_search not installed. pip install duckduckgo-search")
    sys.exit(1)

import webbrowser
import requests
from io import BytesIO

from config import (
    API_KEY,
    GORE_PRESETS,
    MEDIA_SEARCH_PRESETS,
    MAX_SEARCH_RESULTS,
    SOURCES_DEFAULT,
    SEVERITY_MIN,
    GORE_VERIFY_THRESHOLD,
    AUTO_LOG_SEVERITY_MIN,
)
from news_client import NewsClient
from scoring import (
    score_text,
    score_article,
    score_image_from_url,
    clamp_severity_display,
    score_to_color,
)
from database import (
    get_db_path,
    init_db,
    insert as db_insert,
    query as db_query,
    get_stats,
    export_csv as db_export_csv,
)

SETTINGS_FILE = "gore_scanner_settings.json"

# --- Dark theme (default) ---
DARK = {
    "bg": "#0d0d0d",
    "surface": "#1a1a1a",
    "surface2": "#252525",
    "fg": "#e0e0e0",
    "muted": "#888888",
    "accent": "#c62828",
    "accent_soft": "#8b3a3a",
    "success": "#2e7d32",
    "border": "#333333",
}


def load_settings(script_dir: str) -> dict:
    path = os.path.join(script_dir, SETTINGS_FILE)
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"api_key": API_KEY, "sources": SOURCES_DEFAULT.copy()}


def save_settings(script_dir: str, data: dict) -> None:
    path = os.path.join(script_dir, SETTINGS_FILE)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


AUTO_LOG_HEADERS = ["datetime", "source", "url", "title", "media_type", "severity", "gore_flagged", "snippet"]

def _append_to_auto_log(log_dir: str, row: dict) -> None:
    """Append one row to today's auto-log CSV if severity >= AUTO_LOG_SEVERITY_MIN. Row: source, url, title, media_type, severity, gore_flagged (optional), snippet (optional)."""
    try:
        path = os.path.join(log_dir, f"gore_auto_{datetime.now().strftime('%Y%m%d')}.csv")
        file_exists = os.path.exists(path)
        with open(path, "a", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            if not file_exists:
                w.writerow(AUTO_LOG_HEADERS)
            w.writerow([
                datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
                row.get("source", ""),
                row.get("url", ""),
                (row.get("title") or "")[:500],
                row.get("media_type", ""),
                row.get("severity", 0),
                row.get("gore_flagged", ""),
                (row.get("snippet") or "")[:500],
            ])
    except Exception:
        pass


def _normalize_url_for_dedup(url: str) -> str:
    """Normalize URL so duplicates (same page/image) are detected."""
    if not url or not url.strip():
        return ""
    url = url.strip()
    try:
        p = urlparse(url)
        netloc = (p.netloc or "").lower()
        path = (p.path or "").rstrip("/") or "/"
        # Drop fragment and query for page URLs; keep path for images
        if any(path.lower().endswith(ext) for ext in (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp")):
            return (p.scheme or "https") + "://" + netloc + path
        return (p.scheme or "https") + "://" + netloc + path
    except Exception:
        return url


def setup_dark_style(root: tk.Tk) -> None:
    style = ttk.Style()
    style.theme_use("clam")
    bg, surface, fg, muted, border = DARK["bg"], DARK["surface"], DARK["fg"], DARK["muted"], DARK["border"]
    style.configure(".", background=surface, foreground=fg, fieldbackground=surface)
    style.configure("TFrame", background=bg)
    style.configure("TLabel", background=surface, foreground=fg)
    style.configure("TButton", background=DARK["surface2"], foreground=fg, padding=(10, 6))
    style.map("TButton", background=[("active", DARK["accent_soft"])])
    style.configure("TEntry", fieldbackground=DARK["surface2"], foreground=fg, insertcolor=fg)
    style.configure("TLabelframe", background=surface, foreground=fg)
    style.configure("TLabelframe.Label", background=surface, foreground=fg)
    style.configure("TCheckbutton", background=surface, foreground=fg)
    style.configure("Treeview", background=DARK["surface2"], foreground=fg, fieldbackground=DARK["surface2"], rowheight=22)
    style.configure("Treeview.Heading", background=surface, foreground=fg)
    style.map("Treeview", background=[("selected", DARK["accent_soft"])], foreground=[("selected", fg)])
    style.configure("Vertical.TScrollbar", background=surface, troughcolor=bg, arrowcolor=fg)
    style.configure("TCombobox", fieldbackground=DARK["surface2"], foreground=fg, background=surface)


class GoreScannerAdvanced:
    def __init__(self, root):
        self.root = root
        self.root.title("Gore Scanner — Scan & AI Verifier")
        self.root.geometry("1400x820")
        self.root.configure(bg=DARK["bg"])
        self.root.option_add("*Font", "Arial 10")

        setup_dark_style(root)

        self.script_dir = os.path.dirname(os.path.abspath(__file__))
        self.settings = load_settings(self.script_dir)
        self.db_path = get_db_path(self.script_dir)
        self.log_dir = os.path.join(self.script_dir, "gore_logs")
        os.makedirs(self.log_dir, exist_ok=True)
        init_db(self.db_path)

        self.api_key = self.settings.get("api_key") or API_KEY
        self.sources = self.settings.get("sources", SOURCES_DEFAULT.copy())
        self.news = NewsClient(self.api_key)

        self.current_results = []
        self.verifier_results = []
        self.is_loading = False

        self.create_ui()

    def create_ui(self):
        # Header
        header = tk.Frame(self.root, bg=DARK["surface"], height=64)
        header.pack(fill="x")
        header.pack_propagate(False)
        tk.Label(
            header,
            text="GORE SCANNER",
            font=("Arial", 20, "bold"),
            bg=DARK["surface"],
            fg=DARK["accent"],
        ).pack(side="left", padx=20, pady=10)
        tk.Label(
            header,
            text="Scan databases & media  ·  AI Verifier double-checks for gore (0.1–1.0)",
            font=("Arial", 9),
            bg=DARK["surface"],
            fg=DARK["muted"],
        ).pack(side="left", padx=0, pady=10)
        ttk.Button(header, text="Settings", command=self.open_settings_dialog).pack(side="right", padx=16, pady=10)
        tk.Frame(self.root, bg=DARK["border"], height=1).pack(fill="x")

        self.notebook = ttk.Notebook(self.root)
        self.notebook.pack(fill="both", expand=True, padx=0, pady=0)

        # Tab 1: Scan
        scan_tab = tk.Frame(self.notebook, bg=DARK["bg"])
        self.notebook.add(scan_tab, text="  Scan (databases & media)  ")
        self.create_scan_tab(scan_tab)

        # Tab 2: AI Verifier
        verifier_tab = tk.Frame(self.notebook, bg=DARK["bg"])
        self.notebook.add(verifier_tab, text="  AI Verifier (double-check gore)  ")
        self.create_verifier_tab(verifier_tab)

        self.status_label = tk.Label(
            self.root, text="Ready", bg=DARK["surface"], fg=DARK["success"], font=("Arial", 9)
        )
        self.status_label.pack(fill="x", padx=12, pady=6)

    # ---------- Scan tab ----------
    def create_scan_tab(self, parent):
        # Toolbar
        bar = tk.Frame(parent, bg=DARK["surface"], pady=10, padx=12)
        bar.pack(fill="x")
        tk.Label(bar, text="Query", bg=DARK["surface"], fg=DARK["fg"], font=("Arial", 9, "bold")).pack(side="left", padx=(0, 6))
        self.search_query = tk.StringVar(value="real gore footage -movie -film -fake")
        entry = ttk.Entry(bar, textvariable=self.search_query, width=42)
        entry.pack(side="left", padx=(0, 12))
        tk.Label(bar, text="Type", bg=DARK["surface"], fg=DARK["muted"]).pack(side="left", padx=(12, 4))
        self.search_media_type = tk.StringVar(value="all")
        ttk.Combobox(bar, textvariable=self.search_media_type, values=["all", "images", "videos", "articles"], width=10, state="readonly").pack(side="left", padx=(0, 12))
        self.search_btn = ttk.Button(bar, text="Scan", command=self.do_scan)
        self.search_btn.pack(side="left", padx=8)
        ttk.Button(bar, text="Preview", command=self.preview_scan_selection).pack(side="left", padx=4)
        ttk.Button(bar, text="Send selected → AI Verifier", command=self.send_selected_to_verifier).pack(side="left", padx=8)
        tk.Frame(bar, width=20).pack(side="left")
        tk.Label(bar, text="Saved DB", bg=DARK["surface"], fg=DARK["muted"]).pack(side="left", padx=(0, 4))
        self.db_score_min = tk.StringVar(value="0.1")
        ttk.Entry(bar, textvariable=self.db_score_min, width=4).pack(side="left", padx=2)
        tk.Label(bar, text="–", bg=DARK["surface"], fg=DARK["muted"]).pack(side="left")
        self.db_score_max = tk.StringVar(value="1.0")
        ttk.Entry(bar, textvariable=self.db_score_max, width=4).pack(side="left", padx=2)
        ttk.Button(bar, text="Load", command=self.load_from_database).pack(side="left", padx=6)
        ttk.Button(bar, text="Export CSV", command=self.export_database_csv).pack(side="left", padx=4)

        # Presets
        presets_row = tk.Frame(parent, bg=DARK["bg"], pady=4, padx=12)
        presets_row.pack(fill="x")
        tk.Label(presets_row, text="Presets:", bg=DARK["bg"], fg=DARK["muted"], font=("Arial", 9)).pack(side="left", padx=(0, 8))
        for label, (q, kind) in MEDIA_SEARCH_PRESETS.items():
            ttk.Button(presets_row, text=label, command=lambda qq=q, k=kind: self._set_scan_preset(qq, k)).pack(side="left", padx=3, pady=2)
        for name, query in list(GORE_PRESETS.items())[:4]:
            ttk.Button(presets_row, text=name, command=lambda q=query: self._set_scan_preset(q, "articles")).pack(side="left", padx=3, pady=2)

        # Table
        table_frame = tk.Frame(parent, bg=DARK["bg"], padx=12, pady=8)
        table_frame.pack(fill="both", expand=True)
        self.scan_tree = ttk.Treeview(table_frame, columns=("Source", "Type", "Severity", "Title"), height=24, selectmode="extended")
        self.scan_tree.heading("#0", text="#")
        self.scan_tree.heading("Source", text="Source")
        self.scan_tree.heading("Type", text="Type")
        self.scan_tree.heading("Severity", text="Severity")
        self.scan_tree.heading("Title", text="Title")
        self.scan_tree.column("#0", width=40)
        self.scan_tree.column("Source", width=110)
        self.scan_tree.column("Type", width=72)
        self.scan_tree.column("Severity", width=64)
        self.scan_tree.column("Title", width=900)
        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.scan_tree.yview)
        self.scan_tree.configure(yscroll=sb.set)
        self.scan_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.scan_tree.bind("<Double-1>", lambda e: self.open_scan_selection())
        self.scan_tree.bind("<Return>", lambda e: self.preview_scan_selection())

    def _set_scan_preset(self, query: str, kind: str):
        self.search_query.set(query)
        self.search_media_type.set("all" if kind == "articles" else kind)
        self.do_scan()

    def do_scan(self):
        self.is_loading = True
        self.search_btn.config(state="disabled")
        self.update_status("Scanning databases and media...")
        q = (self.search_query.get() or "graphic gore").strip()
        media_type = self.search_media_type.get()

        def run():
            results = []
            seen_urls = set()  # normalized URLs so we don't repeat the same site
            def add_result(item):
                norm = _normalize_url_for_dedup(item.get("url") or "")
                if norm and norm not in seen_urls:
                    seen_urls.add(norm)
                    results.append(item)
                    db_insert(
                        self.db_path,
                        url=item["url"],
                        source_name=item.get("source_name", ""),
                        media_type=item.get("media_type", ""),
                        severity_score=item.get("severity_score", 0.0),
                        title=item.get("title"),
                        snippet=item.get("snippet"),
                    )
                    if item.get("severity_score", 0) >= AUTO_LOG_SEVERITY_MIN:
                        _append_to_auto_log(self.log_dir, {
                            "source": item.get("source_name", ""),
                            "url": item.get("url", ""),
                            "title": item.get("title", ""),
                            "media_type": item.get("media_type", ""),
                            "severity": item.get("severity_score", 0),
                            "gore_flagged": "Yes",
                            "snippet": item.get("snippet", ""),
                        })
            try:
                if self.sources.get("news_api") and media_type in ("all", "articles"):
                    arts = self.news.fetch(q, None, None, page_size=MAX_SEARCH_RESULTS)
                    for a in arts:
                        score = score_article(a, include_image=False)
                        score = clamp_severity_display(score)
                        url = a.get("url") or ""
                        if url:
                            add_result({
                                "title": (a.get("title") or "")[:200],
                                "url": url,
                                "source_name": (a.get("source") or {}).get("name") or "News",
                                "media_type": "article",
                                "severity_score": score,
                                "snippet": (a.get("description") or "")[:300],
                            })
                if self.sources.get("duckduckgo_images") and media_type in ("all", "images"):
                    with DDGS() as ddgs:
                        for r in list(ddgs.images(q, max_results=MAX_SEARCH_RESULTS)):
                            url = r.get("image") or r.get("url") or ""
                            title = (r.get("title") or r.get("description") or "")[:200]
                            if url:
                                score = clamp_severity_display(max(0.2, score_text(title)))
                                add_result({"title": title, "url": url, "source_name": "DuckDuckGo", "media_type": "image", "severity_score": score, "snippet": title})
                if self.sources.get("duckduckgo_videos") and media_type in ("all", "videos"):
                    with DDGS() as ddgs:
                        for r in list(ddgs.videos(q, max_results=MAX_SEARCH_RESULTS)):
                            url = r.get("url") or r.get("content") or ""
                            title = (r.get("title") or r.get("description") or "")[:200]
                            if url:
                                score = clamp_severity_display(max(0.2, score_text(title)))
                                add_result({"title": title, "url": url, "source_name": "DuckDuckGo", "media_type": "video", "severity_score": score, "snippet": title})
                if self.sources.get("duckduckgo_text") and media_type in ("all", "articles"):
                    with DDGS() as ddgs:
                        for r in list(ddgs.text(q, max_results=MAX_SEARCH_RESULTS)):
                            url = r.get("url") or ""
                            title = (r.get("title") or r.get("body") or "")[:200]
                            if url:
                                score = clamp_severity_display(max(0.1, score_text(title + " " + (r.get("body") or ""))))
                                add_result({"title": title, "url": url, "source_name": "DuckDuckGo", "media_type": "text", "severity_score": score, "snippet": (r.get("body") or "")[:300]})
            except Exception as ex:
                self.update_status(f"Error: {str(ex)[:55]}")
            self.current_results = results
            self.root.after(0, self.refresh_scan_tree)
            self.update_status(f"Found {len(results)} results — saved to database")
            self.is_loading = False
            self.root.after(0, lambda: self.search_btn.config(state="normal"))

        threading.Thread(target=run, daemon=True).start()

    def refresh_scan_tree(self):
        for iid in self.scan_tree.get_children():
            self.scan_tree.delete(iid)
        for i, r in enumerate(self.current_results, 1):
            sev = r.get("severity_score", 0.0)
            tag = f"s{i}"
            self.scan_tree.insert("", "end", text=str(i), values=(
                r.get("source_name", ""),
                r.get("media_type", ""),
                f"{sev:.2f}",
                (r.get("title") or "")[:95],
            ), tags=(tag,))
            self.scan_tree.tag_configure(tag, foreground=score_to_color(sev))

    def open_scan_selection(self):
        sel = self.scan_tree.selection()
        if not sel or not self.current_results:
            return
        try:
            idx = list(self.scan_tree.get_children()).index(sel[0])
            if 0 <= idx < len(self.current_results) and self.current_results[idx].get("url"):
                webbrowser.open(self.current_results[idx]["url"])
        except Exception:
            pass

    def _is_image_url(self, url: str) -> bool:
        return any((url or "").lower().endswith(ext) for ext in (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"))

    def preview_scan_selection(self):
        sel = self.scan_tree.selection()
        if not sel or not self.current_results:
            messagebox.showinfo("Preview", "Select a row in the Scan table to preview.")
            return
        try:
            idx = list(self.scan_tree.get_children()).index(sel[0])
            if 0 <= idx < len(self.current_results):
                self._show_preview(
                    self.current_results[idx].get("url"),
                    self.current_results[idx].get("title", ""),
                    self.current_results[idx].get("snippet", ""),
                    is_scan=True,
                )
        except Exception as e:
            messagebox.showerror("Preview", str(e)[:100])

    def _show_preview(self, url: str, title: str, snippet: str, is_scan: bool = True):
        if not url:
            return
        win = tk.Toplevel(self.root)
        win.title("Preview — " + (title[:50] or url[:50]))
        win.configure(bg=DARK["surface"])
        win.geometry("720x560")
        win.transient(self.root)
        if self._is_image_url(url):
            tk.Label(win, text="Loading image...", bg=DARK["surface"], fg=DARK["muted"]).pack(pady=20)
            def load_in_thread():
                try:
                    resp = requests.get(url, timeout=8)
                    resp.raise_for_status()
                    img = Image.open(BytesIO(resp.content))
                    img.thumbnail((680, 480))
                    self.root.after(0, lambda i=img: _show_img(i))
                except Exception as ex:
                    self.root.after(0, lambda: _show_err(str(ex)))
            def _show_img(pil_img):
                for w in win.winfo_children():
                    w.destroy()
                try:
                    photo = ImageTk.PhotoImage(pil_img)
                    lbl = tk.Label(win, image=photo, bg=DARK["surface"])
                    lbl.image = photo
                    lbl.pack(pady=10, padx=10)
                    ttk.Button(win, text="Close", command=win.destroy).pack(pady=8)
                except Exception as e:
                    _show_err(str(e))
            def _show_err(msg):
                for w in win.winfo_children():
                    w.destroy()
                tk.Label(win, text="Could not load image: " + msg[:80], bg=DARK["surface"], fg=DARK["accent"]).pack(pady=20, padx=20)
                ttk.Button(win, text="Close", command=win.destroy).pack(pady=8)
            threading.Thread(target=load_in_thread, daemon=True).start()
        else:
            tk.Label(win, text=title or url[:80], font=("Arial", 11, "bold"), bg=DARK["surface"], fg=DARK["fg"], wraplength=680).pack(anchor="w", padx=15, pady=10)
            text_frame = tk.Frame(win, bg=DARK["surface2"])
            text_frame.pack(fill="both", expand=True, padx=10, pady=5)
            txt = tk.Text(text_frame, wrap="word", height=18, bg=DARK["surface2"], fg=DARK["fg"], insertbackground=DARK["fg"], font=("Consolas", 9))
            txt.pack(side="left", fill="both", expand=True)
            sb = ttk.Scrollbar(text_frame, orient="vertical", command=txt.yview)
            sb.pack(side="right", fill="y")
            txt.config(yscrollcommand=sb.set)
            def fetch_snippet():
                try:
                    resp = requests.get(url, timeout=8, headers={"User-Agent": "Mozilla/5.0"})
                    resp.raise_for_status()
                    raw = resp.text[:12000]
                    clean = re.sub(r"<[^>]+>", " ", raw)
                    clean = re.sub(r"\s+", " ", clean).strip()[:1200]
                    win.after(0, lambda: (txt.insert("1.0", clean or "(No text content)"), txt.config(state="disabled")))
                except Exception as ex:
                    win.after(0, lambda: (txt.insert("1.0", "Could not load page: " + str(ex)[:200]), txt.config(state="disabled")))
            threading.Thread(target=fetch_snippet, daemon=True).start()
            txt.insert("1.0", "Loading...")
            btn_frame = tk.Frame(win, bg=DARK["surface"])
            btn_frame.pack(fill="x", padx=10, pady=10)
            ttk.Button(btn_frame, text="Open in browser", command=lambda: webbrowser.open(url)).pack(side="left", padx=5)
            ttk.Button(btn_frame, text="Close", command=win.destroy).pack(side="left", padx=5)

    def send_selected_to_verifier(self):
        sel = self.scan_tree.selection()
        if not sel:
            messagebox.showinfo("AI Verifier", "Select one or more rows in the Scan table, then click Send.")
            return
        urls = []
        for item_id in sel:
            idx = list(self.scan_tree.get_children()).index(item_id)
            if 0 <= idx < len(self.current_results):
                u = self.current_results[idx].get("url")
                if u:
                    urls.append(u)
        if urls:
            self.verifier_urls_text.delete("1.0", "end")
            self.verifier_urls_text.insert("1.0", "\n".join(urls))
            self.notebook.select(1)
            self.update_status(f"Sent {len(urls)} URL(s) to AI Verifier")

    def load_from_database(self):
        try:
            smin = float(self.db_score_min.get() or 0.1)
            smax = float(self.db_score_max.get() or 1.0)
        except ValueError:
            smin, smax = 0.1, 1.0
        rows = db_query(self.db_path, score_min=smin, score_max=smax, limit=500)
        self.current_results = [
            {"title": r.get("title", ""), "url": r.get("url", ""), "source_name": r.get("source_name", ""), "media_type": r.get("media_type", ""), "severity_score": r.get("severity_score", 0.0), "snippet": r.get("snippet", "")}
            for r in rows
        ]
        self.refresh_scan_tree()
        self.update_status(f"Loaded {len(self.current_results)} from database")
        stats = get_stats(self.db_path)
        messagebox.showinfo("Database", f"Loaded {len(self.current_results)} rows. Total in DB: {stats['total']}")

    def export_database_csv(self):
        path = filedialog.asksaveasfilename(defaultextension=".csv", filetypes=[("CSV", "*.csv")])
        if path:
            n = db_export_csv(self.db_path, path)
            messagebox.showinfo("Export", f"Exported {n} rows to {path}")
            self.update_status(f"Exported {n} rows")

    # ---------- AI Verifier tab ----------
    def create_verifier_tab(self, parent):
        top = tk.Frame(parent, bg=DARK["surface"], pady=12, padx=12)
        top.pack(fill="x")
        tk.Label(top, text="Paste URLs (one per line) for the AI to double-check for gore. Severity 0.1–1.0; Gore = Yes if ≥ " + str(GORE_VERIFY_THRESHOLD), bg=DARK["surface"], fg=DARK["muted"], font=("Arial", 9)).pack(anchor="w")
        url_frame = tk.Frame(parent, bg=DARK["bg"], padx=12, pady=6)
        url_frame.pack(fill="x")
        self.verifier_urls_text = tk.Text(url_frame, height=5, width=90, bg=DARK["surface2"], fg=DARK["fg"], insertbackground=DARK["fg"], relief="flat", padx=8, pady=8, font=("Consolas", 9))
        self.verifier_urls_text.pack(fill="x")
        btn_row = tk.Frame(parent, bg=DARK["bg"], pady=8, padx=12)
        btn_row.pack(fill="x")
        self.verify_btn = ttk.Button(btn_row, text="Verify (double-check gore)", command=self.do_verify)
        self.verify_btn.pack(side="left", padx=(0, 8))
        ttk.Button(btn_row, text="Use selected from Scan", command=self.send_selected_to_verifier).pack(side="left", padx=4)
        ttk.Button(btn_row, text="Preview selected", command=self.preview_verifier_selection).pack(side="left", padx=4)
        ttk.Button(btn_row, text="Clear", command=lambda: self.verifier_urls_text.delete("1.0", "end")).pack(side="left", padx=4)

        table_frame = tk.Frame(parent, bg=DARK["bg"], padx=12, pady=8)
        table_frame.pack(fill="both", expand=True)
        self.verifier_tree = ttk.Treeview(table_frame, columns=("Severity", "Gore", "Details", "URL"), height=18)
        self.verifier_tree.heading("#0", text="#")
        self.verifier_tree.heading("Severity", text="Severity")
        self.verifier_tree.heading("Gore", text="Gore")
        self.verifier_tree.heading("Details", text="Details")
        self.verifier_tree.heading("URL", text="URL")
        self.verifier_tree.column("#0", width=36)
        self.verifier_tree.column("Severity", width=64)
        self.verifier_tree.column("Gore", width=56)
        self.verifier_tree.column("Details", width=320)
        self.verifier_tree.column("URL", width=600)
        sb = ttk.Scrollbar(table_frame, orient="vertical", command=self.verifier_tree.yview)
        self.verifier_tree.configure(yscroll=sb.set)
        self.verifier_tree.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        self.verifier_tree.bind("<Double-1>", lambda e: self.open_verifier_row())

    def do_verify(self):
        raw = self.verifier_urls_text.get("1.0", "end")
        urls = [u.strip() for u in raw.splitlines() if u.strip() and (u.startswith("http://") or u.startswith("https://"))]
        if not urls:
            messagebox.showinfo("AI Verifier", "Paste at least one URL (http or https), one per line.")
            return
        self.verify_btn.config(state="disabled")
        self.update_status("AI Verifier analyzing...")

        def run():
            results = []
            for url in urls:
                try:
                    text_score = 0.0
                    image_score = 0.0
                    details_parts = []
                    if any(url.lower().endswith(x) for x in (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp")):
                        image_score = score_image_from_url(url)
                        text_score = 0.0
                        details_parts.append(f"image={image_score:.2f}")
                    else:
                        try:
                            resp = requests.get(url, timeout=8, headers={"User-Agent": "Mozilla/5.0"})
                            resp.raise_for_status()
                            text = resp.text[:15000]
                            import re
                            text_clean = re.sub(r"<[^>]+>", " ", text)
                            text_score = score_text(text_clean)
                            details_parts.append(f"text={text_score:.2f}")
                            img_urls = []
                            for m in re.finditer(r'src=["\']([^"\']+\.(?:jpg|jpeg|png|gif|webp)[^"\']*)["\']', text, re.I):
                                img_urls.append(m.group(1))
                            if img_urls and not img_urls[0].startswith("data:"):
                                img_url = img_urls[0]
                                if img_url.startswith("//"):
                                    img_url = "https:" + img_url
                                elif img_url.startswith("/"):
                                    img_url = urljoin(url, img_url)
                                image_score = score_image_from_url(img_url)
                                details_parts.append(f"img={image_score:.2f}")
                        except Exception:
                            details_parts.append("fetch failed")
                    severity = clamp_severity_display(max(text_score, image_score))
                    gore_yes = "Yes" if severity >= GORE_VERIFY_THRESHOLD else "No"
                    results.append({"url": url, "severity": severity, "gore": gore_yes, "details": " | ".join(details_parts)})
                    if severity >= AUTO_LOG_SEVERITY_MIN:
                        _append_to_auto_log(self.log_dir, {
                            "source": "AI Verifier",
                            "url": url,
                            "title": "",
                            "media_type": "verified",
                            "severity": severity,
                            "gore_flagged": gore_yes,
                            "snippet": " | ".join(details_parts),
                        })
                except Exception as e:
                    results.append({"url": url, "severity": 0.0, "gore": "No", "details": str(e)[:80]})
            self.verifier_results = results
            self.root.after(0, self.refresh_verifier_tree)
            self.update_status(f"Verified {len(results)} URL(s)")
            self.root.after(0, lambda: self.verify_btn.config(state="normal"))

        threading.Thread(target=run, daemon=True).start()

    def refresh_verifier_tree(self):
        for iid in self.verifier_tree.get_children():
            self.verifier_tree.delete(iid)
        for i, r in enumerate(getattr(self, "verifier_results", []), 1):
            sev = r.get("severity", 0.0)
            tag = f"v{i}"
            self.verifier_tree.insert("", "end", text=str(i), values=(
                f"{sev:.2f}",
                r.get("gore", ""),
                (r.get("details") or "")[:60],
                (r.get("url") or "")[:80],
            ), tags=(tag,))
            self.verifier_tree.tag_configure(tag, foreground=score_to_color(sev))

    def open_verifier_row(self):
        sel = self.verifier_tree.selection()
        if not sel or not getattr(self, "verifier_results", []):
            return
        try:
            idx = list(self.verifier_tree.get_children()).index(sel[0])
            if 0 <= idx < len(self.verifier_results):
                url = self.verifier_results[idx].get("url")
                if url:
                    webbrowser.open(url)
        except Exception:
            pass

    def preview_verifier_selection(self):
        sel = self.verifier_tree.selection()
        if not sel or not getattr(self, "verifier_results", []):
            messagebox.showinfo("Preview", "Select a row in the Verifier table to preview.")
            return
        try:
            idx = list(self.verifier_tree.get_children()).index(sel[0])
            if 0 <= idx < len(self.verifier_results):
                r = self.verifier_results[idx]
                self._show_preview(r.get("url"), "", r.get("details", ""), is_scan=False)
        except Exception as e:
            messagebox.showerror("Preview", str(e)[:100])

    # ---------- Settings dialog ----------
    def open_settings_dialog(self):
        win = tk.Toplevel(self.root)
        win.title("Settings")
        win.geometry("420x280")
        win.configure(bg=DARK["surface"])
        win.transient(self.root)
        win.grab_set()
        f = tk.Frame(win, bg=DARK["surface"], padx=20, pady=20)
        f.pack(fill="both", expand=True)
        tk.Label(f, text="News API Key", bg=DARK["surface"], fg=DARK["fg"], font=("Arial", 10, "bold")).pack(anchor="w", pady=(0, 4))
        api_var = tk.StringVar(value=self.api_key)
        ttk.Entry(f, textvariable=api_var, width=48).pack(anchor="w", fill="x", pady=(0, 14))
        tk.Label(f, text="Data sources for Scan", bg=DARK["surface"], fg=DARK["fg"], font=("Arial", 10, "bold")).pack(anchor="w", pady=(0, 6))
        vars_map = {}
        for key, label in [
            ("news_api", "News API (articles)"),
            ("duckduckgo_images", "DuckDuckGo Images"),
            ("duckduckgo_videos", "DuckDuckGo Videos"),
            ("duckduckgo_text", "DuckDuckGo Text"),
        ]:
            v = tk.BooleanVar(value=self.sources.get(key, True))
            vars_map[key] = v
            ttk.Checkbutton(f, text=label, variable=v).pack(anchor="w", padx=0, pady=2)
        def save_and_close():
            self.api_key = api_var.get().strip()
            self.sources = {k: v.get() for k, v in vars_map.items()}
            self.settings["api_key"] = self.api_key
            self.settings["sources"] = self.sources
            save_settings(self.script_dir, self.settings)
            self.news = NewsClient(self.api_key or API_KEY)
            messagebox.showinfo("Settings", "Saved.")
            win.destroy()
        ttk.Button(f, text="Save and close", command=save_and_close).pack(anchor="w", pady=16)

    def update_status(self, msg: str):
        self.root.after(0, lambda: self.status_label.config(text=msg))
