# main.py
#!/usr/bin/env python3
"""
Gore Scanner — severity 0.1–1.0, SQLite database, multi-source search.
Sources: News API, DuckDuckGo (images, videos, text). All findings stored with severity score.
"""

import tkinter as tk

from app import GoreScannerAdvanced

if __name__ == "__main__":
    try:
        root = tk.Tk()
        app = GoreScannerAdvanced(root)
        root.mainloop()
    except Exception as e:
        print(f"Error: {e}")