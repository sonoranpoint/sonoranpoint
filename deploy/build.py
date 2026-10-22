#!/usr/bin/env python3
"""Builds the upload-ready folders for Cloudflare Pages (and the Pi) into deploy/dist/.

  python3 deploy/build.py

  dist/app/       -> Cloudflare Pages project "sonoranpoint-app",     domain app.sonoranpoint.com
  dist/console/   -> Cloudflare Pages project "sonoranpoint-console", domain console.sonoranpoint.com
  dist/station/   -> copied onto each Pi (served at http://localhost/)
"""
import pathlib, shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "deploy" / "dist"
SUPABASE = "https://qzzukfjefqwifnqzxhhu.supabase.co"

HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex">
<link rel="icon" href="brand/favicon.ico" sizes="32x32">
<link rel="icon" type="image/png" href="brand/mark-64.png">
<link rel="apple-touch-icon" href="brand/apple-touch-icon.png">
"""
HEADERS = f"""/*
  X-Frame-Options: DENY
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: https:; connect-src 'self' {SUPABASE} wss://{SUPABASE[8:]}; frame-ancestors 'none'; base-uri 'none'; form-action 'self'
  Cache-Control: no-cache
"""

def page(src):
    return HEAD + src.read_text() + "\n</html>\n"

def build():
    if DIST.exists(): shutil.rmtree(DIST)
    for name, src in [("app", ROOT / "dashboard" / "dashboard.html"), ("console", ROOT / "platform" / "console.html")]:
        out = DIST / name; out.mkdir(parents=True)
        (out / "index.html").write_text(page(src))
        (out / "_headers").write_text(HEADERS)
        (out / "robots.txt").write_text("User-agent: *\nDisallow: /\n")
        (out / "brand").mkdir()
        for f in ["logo.png", "logo@2x.png", "logo-light.png", "logo-light@2x.png", "mark-64.png", "mark-180.png", "mark-512.png", "favicon.ico", "apple-touch-icon.png", "app-icon-512.png"]:
            shutil.copy(ROOT / "brand" / f, out / "brand" / f)
    st = DIST / "station"; st.mkdir(parents=True)
    (st / "index.html").write_text(page(ROOT / "station" / "station.html"))
    for f in ["wifi_helper.py", "nfc_reader.py", "README.md"]:
        shutil.copy(ROOT / "station" / "pi" / f, st / f)
    (st / "brand").mkdir()   # the station shows Sonoran Point's logo when a company has none
    for f in ["logo.png", "mark-180.png", "favicon.ico"]:
        shutil.copy(ROOT / "brand" / f, st / "brand" / f)
    print("built", ", ".join(str(p.relative_to(ROOT)) for p in sorted(DIST.iterdir())))

if __name__ == "__main__":
    build()
