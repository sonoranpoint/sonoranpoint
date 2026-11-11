#!/usr/bin/env python3
"""Builds the upload-ready folders for Cloudflare Pages (and the Pi) into deploy/dist/.

  python3 deploy/build.py

  dist/app/       -> Cloudflare Pages project "sonoranpoint-app",     domain app.sonoranpoint.com
  dist/console/   -> Cloudflare Pages project "sonoranpoint-console", domain console.sonoranpoint.com
  dist/site/      -> Cloudflare Pages project "sonoranpoint-site",    domain sonoranpoint.com
                     (site/ pages + "Try it" copies of the station and dashboard on demo data)
  dist/station/   -> the station app, for setting up a Pi by hand (served at http://localhost/)
  dist/app/station-release/latest.json + station-<hash>.zip
                  -> what stations update themselves to (station/pi/station_updater.py checks it)
                     (latest.json is copied to the console too, so it can show the newest version)
"""
import base64, hashlib, io, json, os, pathlib, re, shutil, subprocess, tempfile, zipfile

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
  Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: blob: https:; connect-src 'self' {SUPABASE} wss://{SUPABASE[8:]}; frame-ancestors 'none'; base-uri 'none'; form-action 'self'
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
    # The station's version: the number in station.html plus a hash of what's in the bundle, so a
    # station only updates when the station itself changed (not on every dashboard push).
    html = page(ROOT / "station" / "station.html")
    base = re.search(r'const VERSION = "([^"]+)";', html).group(1)
    brand = ["logo.png", "logo-light.png", "mark-180.png", "favicon.ico"]
    h = hashlib.sha256(html.encode())
    for f in brand: h.update((ROOT / "brand" / f).read_bytes())
    version = f"{base}+{h.hexdigest()[:8]}"
    html = html.replace(f'const VERSION = "{base}";', f'const VERSION = "{version}";', 1)
    (st / "index.html").write_text(html)
    for f in ["wifi_helper.py", "nfc_reader.py", "test_station_updater.py", "README.md"]:
        shutil.copy(ROOT / "station" / "pi" / f, st / f)
    (st / "brand").mkdir()   # the station shows Sonoran Point's logo when a company has none
    for f in brand:
        shutil.copy(ROOT / "brand" / f, st / "brand" / f)
    shutil.copy(ROOT / "station" / "pi" / "station_updater.py", st / "station_updater.py")
    if PUBLIC_KEY.exists(): shutil.copy(PUBLIC_KEY, st / "release_key.pub")
    # The release stations download: just the app (index.html + brand/), zipped with fixed dates.
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for rel in ["index.html"] + [f"brand/{f}" for f in brand]:
            info = zipfile.ZipInfo(rel, date_time=(2026, 1, 1, 0, 0, 0)); info.external_attr = 0o644 << 16
            z.writestr(info, (st / rel).read_bytes(), zipfile.ZIP_DEFLATED)
    data = buf.getvalue()
    rel_dir = DIST / "app" / "station-release"; rel_dir.mkdir()
    name = f"station-{h.hexdigest()[:8]}.zip"
    (rel_dir / name).write_bytes(data)
    rel = {"version": version, "file": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
    sig = sign_release(rel)
    if sig: rel["sig"] = sig
    manifest = json.dumps(rel, indent=2)
    (rel_dir / "latest.json").write_text(manifest)
    (DIST / "console" / "station-release").mkdir(); (DIST / "console" / "station-release" / "latest.json").write_text(manifest)
    print("station", version)
    build_site()
    print("built", ", ".join(str(p.relative_to(ROOT)) for p in sorted(DIST.iterdir())))

# Station releases are signed (Ed25519) so a station only installs what we published. The private key is the
# STATION_SIGNING_KEY secret in GitHub (PEM); the public key is station/pi/release_key.pub, installed on each Pi.
PUBLIC_KEY = ROOT / "station" / "pi" / "release_key.pub"

def release_message(rel):
    return f"sonoranpoint-station-release\n{rel['version']}\n{rel['file']}\n{rel['sha256']}\n{rel['size']}\n".encode()

def sign_release(rel):
    key = os.environ.get("STATION_SIGNING_KEY", "").strip()
    if not key:
        if PUBLIC_KEY.exists() and os.environ.get("CI"):
            raise SystemExit("STATION_SIGNING_KEY is missing: stations would refuse this release. Add it under GitHub Settings -> Secrets.")
        print("station release NOT signed (no STATION_SIGNING_KEY)")
        return None
    with tempfile.TemporaryDirectory() as d:
        kf, mf, sf = pathlib.Path(d, "k.pem"), pathlib.Path(d, "m"), pathlib.Path(d, "s")
        kf.write_text(key + "\n"); os.chmod(kf, 0o600); mf.write_bytes(release_message(rel))
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(kf), "-rawin", "-in", str(mf), "-out", str(sf)], check=True, capture_output=True)
        sig = sf.read_bytes()
        if PUBLIC_KEY.exists():   # the secret must match the key the stations have
            r = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", str(PUBLIC_KEY), "-rawin", "-in", str(mf), "-sigfile", str(sf)], capture_output=True)
            if r.returncode != 0:
                raise SystemExit("STATION_SIGNING_KEY doesn't match station/pi/release_key.pub")
    return base64.b64encode(sig).decode()

SITE_HEADERS = """/*
  X-Frame-Options: SAMEORIGIN
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; img-src 'self' data: blob: https:; connect-src 'self' https://qzzukfjefqwifnqzxhhu.supabase.co; frame-ancestors 'self'; base-uri 'none'; form-action 'self'
  Cache-Control: no-cache
/try/app/*
  X-Robots-Tag: noindex
/try/station/*
  X-Robots-Tag: noindex
"""

def build_site():
    """sonoranpoint.com: the site's own pages, plus the station and dashboard running on made-up demo data."""
    out = DIST / "site"
    shutil.copytree(ROOT / "site", out, ignore=shutil.ignore_patterns("*.md"))
    (out / "_headers").write_text(SITE_HEADERS)
    # Stamp the stylesheet and script with their content hash, so browsers never keep an old copy after a deploy.
    for asset in ["site.css", "theme.js"]:
        h = hashlib.sha256((out / asset).read_bytes()).hexdigest()[:10]
        for page in out.rglob("*.html"):
            t = page.read_text(); t2 = re.sub(r'((?:\.\./)*' + re.escape(asset) + r')"', r'\1?v=' + h + '"', t)
            if t2 != t: page.write_text(t2)
    (out / "robots.txt").write_text("User-agent: *\nDisallow: /try/app/\nDisallow: /try/station/\nSitemap: https://sonoranpoint.com/sitemap.xml\n")
    brand = ["logo.png", "logo@2x.png", "logo-light.png", "logo-light@2x.png", "mark-64.png", "mark-180.png", "mark-512.png", "favicon.ico", "apple-touch-icon.png", "app-icon-512.png"]
    (out / "brand").mkdir(exist_ok=True)
    for f in brand: shutil.copy(ROOT / "brand" / f, out / "brand" / f)
    # Demo copies: forced onto demo data, starting fresh on each visit.
    demo = '<script>window.SP_DEMO = true;</script>\n'
    for name, src, extra in [("app", ROOT / "dashboard" / "dashboard.html", ""),
                             ("station", ROOT / "station" / "station.html", '<script>window.SP_TRY = true;</script>\n')]:
        d = out / "try" / name; d.mkdir(parents=True)
        (d / "index.html").write_text(HEAD + demo + extra + (src).read_text() + "\n</html>\n")
        (d / "brand").mkdir()
        for f in brand: shutil.copy(ROOT / "brand" / f, d / "brand" / f)

if __name__ == "__main__":
    build()
