"""Package an unsigned, real device app for local signing by AltStore."""
from pathlib import Path
import hashlib
import plistlib
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]).resolve()
if not app.is_dir():
    raise SystemExit(f"Missing built app: {app}")
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleDisplayName"] == "MiptRDP"
assert info["CFBundleIdentifier"] == "ru.mipt.rdp.ios"
executable = app / info["CFBundleExecutable"]
assert "arm64" in subprocess.check_output(["lipo", "-archs", str(executable)], text=True)
assert info.get("CFBundleSupportedPlatforms") == ["iPhoneOS"]
assert "UIInterfaceOrientationLandscapeLeft" in info["UISupportedInterfaceOrientations"]
assert "UIInterfaceOrientationPortrait" in info["UISupportedInterfaceOrientations"]
for binary in [executable] + list((app / "Frameworks").glob("*.framework/*")):
    if not binary.is_file() or binary.suffix in (".plist", ".h"): continue
    result = subprocess.run(["otool", "-L", str(binary)], capture_output=True, text=True)
    if result.returncode == 0:
        for line in result.stdout.splitlines()[1:]:
            dependency = line.strip().split(" ")[0]
            if dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise RuntimeError(f"Unbundled dependency in {binary}: {dependency}")
out = root / "dist"
out.mkdir(exist_ok=True)
ipa = out / "MiptRDP-iOS-unsigned.ipa"
with zipfile.ZipFile(ipa, "w", zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(app.rglob("*")):
        if file.is_file() and "_CodeSignature" not in file.parts:
            archive.write(file, Path("Payload") / app.name / file.relative_to(app))
(out / "SHA256SUMS.txt").write_text(hashlib.sha256(ipa.read_bytes()).hexdigest() + "  " + ipa.name + "\n")
print(ipa)
