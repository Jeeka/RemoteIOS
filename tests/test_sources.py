"""Portable integrity checks plus real Foundation address tests on macOS."""
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Sources(unittest.TestCase):
    def test_archive_integrity(self):
        archive = ROOT / ".cache/freerdp.tar.gz"
        if not archive.exists(): self.skipTest("Verified during source preparation")
        lock = json.loads((ROOT / "freerdp.lock.json").read_text())
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(),lock["sha256"])

    def test_android_unchanged(self):
        baseline = ROOT / "reports/android-baseline.json"
        if not baseline.exists(): self.skipTest("Android exists only in the original Windows workspace")
        for entry in json.loads(baseline.read_text(encoding="utf-8-sig")):
            path = ROOT.parent / entry["path"]
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest().lower(),entry["sha256"].lower(),str(path))

    @unittest.skipUnless(platform.system() == "Darwin", "Foundation requires macOS")
    def test_native_address_parser(self):
        # Compile the actual production function, rather than a Python reimplementation.
        app = (ROOT / "App/MiptApp.m").read_text()
        function = app[app.index("NSDictionary *MiptEndpoint("):app.index("static void SetIdentity(")]
        cases = r'''
int main(void) { @autoreleasepool {
    NSArray *valid = @[@[@"pc.local",@"pc.local",@3389],@[@"pc:444",@"pc",@444],@[@"[2001:db8::1]:3390",@"2001:db8::1",@3390],@[@"2001:db8::1",@"2001:db8::1",@3389],@[@"  pc  ",@"pc",@3389]];
    for (NSArray *item in valid) { NSDictionary *p = MiptEndpoint(item[0],3389); if (![p[@"host"] isEqual:item[1]] || ![p[@"port"] isEqual:item[2]]) return 1; }
    for (NSString *s in @[@"",@"pc:",@"pc:0",@"pc:65536",@"pc:abc",@"https://pc",@"pc name",@"[::1",@"[::1]oops",@"pc,other",@"pc\"bad"]) if (MiptEndpoint(s,3389)) return 2;
    if (![MiptEndpoint(@"gateway",443)[@"port"] isEqual:@443]) return 3;
} return 0; }
'''
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "test.m"; binary = Path(temp) / "test"
            source.write_text('#import <Foundation/Foundation.h>\n' + function + cases)
            subprocess.run(["clang","-fno-objc-arc","-framework","Foundation",str(source),"-o",str(binary)],check=True)
            subprocess.run([str(binary)],check=True)

if __name__ == "__main__": unittest.main()
