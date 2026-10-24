"""Portable screenshot reports and failure artifacts; no external dependencies."""
from html import escape
import json
from pathlib import Path
import shutil
import zipfile

SCREENS = ("settings", "integrations", "account")
LABELS = {"iphone": "iPhone", "ipad": "iPad", "iphone-duo": "iPhone Duo"}


def write_review(output, profiles, baselines, status="captured", errors=()):
    output = Path(output)
    cards = []
    rows = ["# Mobile screenshot results", "", f"Status: {status}", ""]
    for error in errors:
        rows.extend([f"- {error}", ""])
    rows.extend(["| Device | Settings | Integrations | Account |", "| --- | --- | --- | --- |"])
    for profile in profiles:
        label = LABELS[profile]
        links = []
        diagnostics = []
        for filename in ("xcodebuild.log", "error.txt", "result.xcresult", "comparisons.json"):
            if (output / profile / filename).exists():
                diagnostics.append(f'<a href="{profile}/{filename}">{filename}</a>')
        for screen in SCREENS:
            figures = []
            latest = output / profile / f"{screen}.png"
            links.append(f"[{screen.title()}]({profile}/{screen}.png)" if latest.exists() else "Not captured")
            baseline = Path(baselines) / profile / f"{screen}.png"
            if baseline.exists():
                destination = output / "baselines" / profile
                destination.mkdir(parents=True, exist_ok=True)
                shutil.copy2(baseline, destination / baseline.name)
            for title, relative in (
                ("Approved baseline", f"baselines/{profile}/{screen}.png"),
                ("Latest", f"{profile}/{screen}.png"),
                ("Difference", f"{profile}/{screen}-diff.png"),
            ):
                if (output / relative).exists():
                    figures.append(f'<figure><figcaption>{title}</figcaption><a href="{relative}">'
                                   f'<img src="{relative}" alt="{label} {screen}: {title}" loading="lazy"></a></figure>')
            if not latest.exists():
                figures.append('<p class="missing">Latest screenshot unavailable. See diagnostics below.</p>')
            cards.append(f'<section data-profile="{profile}"><h2>{label}: {screen.title()}</h2>'
                         f'<div class="images">{"".join(figures)}</div>'
                         f'<p class="diagnostics">{" · ".join(diagnostics)}</p></section>')
        rows.append("| " + " | ".join([label, *links]) + " |")
    (output / "review.md").write_text("\n".join(rows) + "\n")
    controls = '<label><input type="radio" name="device" value="all" checked>All devices</label>' + "".join(
        f'<label><input type="radio" name="device" value="{profile}">{LABELS[profile]}</label>' for profile in profiles)
    error_html = "".join(f"<li>{escape(str(error))}</li>" for error in errors)
    (output / "review.html").write_text('''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mobile screenshot results</title><style>
body{font:16px system-ui;margin:24px;background:#eee;color:#171717}
fieldset{display:flex;flex-wrap:wrap;gap:16px;border:0;padding:16px 0}legend{font-weight:600}
label{padding:10px;background:white;border-radius:12px;cursor:pointer}
main{display:grid;gap:20px}section{background:white;padding:16px;border-radius:16px}
h2{font-size:18px}.images{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:16px}
figure{margin:0}figcaption{font-weight:600;margin-bottom:12px}img{width:100%;height:460px;object-fit:contain}
.diagnostics,.missing{color:#555}section[hidden]{display:none}.errors{color:#a40000;white-space:pre-wrap}
</style></head><body><h1>Mobile screenshot results</h1>'''
        + f'<p>Status: <strong>{escape(status)}</strong>. Click an image for full resolution.</p>'
        + '<p>Capture candidates require user approval before becoming baselines.</p>'
        + (f'<ul class="errors">{error_html}</ul>' if error_html else '')
        + '<fieldset><legend>Filter by device</legend>' + controls + '</fieldset><main>' + ''.join(cards)
        + '''</main><script>
const controls = document.querySelectorAll('input[name="device"]');
function filter(value) {
  document.querySelectorAll('section[data-profile]').forEach(card => {
    card.hidden = value !== 'all' && card.dataset.profile !== value;
  });
  const url = new URL(location.href);
  url.searchParams.set('device', value);
  history.replaceState(null, '', url);
}
controls.forEach(control => control.addEventListener('change', () => filter(control.value)));
const requested = new URLSearchParams(location.search).get('device');
const selected = Array.from(controls).find(control => control.value === requested);
if (selected) { selected.checked = true; filter(selected.value); }
</script></body></html>''')


def package_failure(output):
    """Keep relative links usable after extracting; exclude the archive itself."""
    output = Path(output)
    archive = output / "mobile-visual-failure.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(output.rglob("*")):
            if path.is_file() and not path.is_symlink() and path != archive and path.name != "compare":
                bundle.write(path, path.relative_to(output))
    return archive


def finish_report(output, profiles, baselines, status, errors=()):
    Path(output).mkdir(parents=True, exist_ok=True)
    (Path(output) / "result.json").write_text(json.dumps({
        "status": status, "profiles": profiles, "errors": list(errors)
    }, indent=2) + "\n")
    write_review(output, profiles, baselines, status, errors)
    if status == "failed":
        print(f"Failure artifact: {package_failure(output)}")
