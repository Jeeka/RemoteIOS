"""Prepare a pinned, isolated FreeRDP checkout; never modify the Android vendor tree."""
import hashlib
import json
from pathlib import Path
import shutil
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def replace(path, old, new):
    content = path.read_text(encoding="utf-8")
    if content.count(old) != 1:
        raise RuntimeError(f"Expected exactly one patch location in {path}: {old[:70]}")
    path.write_text(content.replace(old, new), encoding="utf-8")

def prepare():
    lock = json.loads((ROOT / "freerdp.lock.json").read_text())
    archive = ROOT / ".cache/freerdp.tar.gz"
    archive.parent.mkdir(exist_ok=True)
    if not archive.exists():
        with urllib.request.urlopen(lock["url"], timeout=120) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != lock["sha256"]:
        raise RuntimeError("FreeRDP archive checksum mismatch")
    build = ROOT / ".build"
    build.mkdir(exist_ok=True)
    source = build / ("FreeRDP-" + lock["commit"])
    # Each preparation starts from the verified archive, so patches cannot accumulate.
    if source.exists():
        if source.parent.resolve() != build.resolve():
            raise RuntimeError("Unsafe extraction path")
        shutil.rmtree(source)
    with tarfile.open(archive) as tar:
        tar.extractall(build, filter="data")
    client = source / "client/iOS"
    app = client / "Mipt"
    shutil.copytree(ROOT / "App", app)
    shutil.copyfile(app / "SceneDelegate.m", client / "SceneDelegate.m")
    plist = (client / "iFreeRDP.plist.in").read_text()
    plist = plist.replace("<key>CFBundleDisplayName</key>\n\t<string>@PROJECT_NAME@</string>", "<key>CFBundleDisplayName</key>\n\t<string>MiptRDP</string>")
    plist = plist.replace("FreeRDP connects to remote desktops and gateways on your local network.", "MiptRDP подключается к рабочим компьютерам и шлюзам в локальной сети.")
    (client / "iFreeRDP.plist.in").write_text(plist)
    with (client / "CMakeLists.txt").open("a") as out:
        out.write('''
# MiptRDP overlay. Upstream files retain their original licenses.
target_sources(${PROJECT_NAME} PRIVATE Mipt/MiptApp.m)
target_include_directories(${PROJECT_NAME} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/Mipt")
set_target_properties(${PROJECT_NAME} PROPERTIES
  MACOSX_BUNDLE_GUI_IDENTIFIER "ru.mipt.rdp.ios"
  MACOSX_BUNDLE_BUNDLE_NAME "MiptRDP"
  MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
  MACOSX_BUNDLE_BUNDLE_VERSION "1"
  XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
  XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED "NO"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2")
''')
    replace(client / "cmake/ExternalDeps.cmake", "set(IOS_CMAKE_CACHE_ARGS)", '''list(APPEND IOS_CMAKE_ARGS
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED:STRING=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED:STRING=NO)
set(IOS_CMAKE_CACHE_ARGS)''')
    session = client / "Models/RDPSession.m"
    replace(session, 'if ([_params hasValueForKey:@"width"])', 'if ([_params intForKey:@"width"] > 0)')
    replace(session, 'if ([_params hasValueForKey:@"height"])', 'if ([_params intForKey:@"height"] > 0)')
    old = '''if (!addArgument(&argc, &argv, "/gateway:g:%s:%d,u:%s,d:%s,p:%s",
\t\t                 [_params UTF8StringForKey:@"tsg_hostname"],
\t\t                 [_params intForKey:@"tsg_port"],
\t\t                 [_params UTF8StringForKey:@"tsg_username"],
\t\t                 [_params UTF8StringForKey:@"tsg_domain"],
\t\t                 [_params UTF8StringForKey:@"tsg_password"]))'''
    new = '''NSMutableArray *gateway = [NSMutableArray array];
        NSString *host = [_params StringForKey:@"tsg_hostname"];
        if ([host containsString:@":"]) host = [NSString stringWithFormat:@"[%@]", host];
        [gateway addObject:[NSString stringWithFormat:@"g:%@:%d", host, [_params intForKey:@"tsg_port"]]];
        for (NSString *key in @[@"username", @"domain", @"password"]) {
            NSString *value = [_params StringForKey:[@"tsg_" stringByAppendingString:key]] ?: @"";
            value = [value stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\\\\\\\"];
            value = [value stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\\\\\\\""];
            value = [value stringByReplacingOccurrencesOfString:@"'" withString:@"\\\\'"];
            value = [value stringByReplacingOccurrencesOfString:@"," withString:@"\\\\,"];
            [gateway addObject:[NSString stringWithFormat:@"\\\"%@: %@\\\"", [key substringToIndex:1], value]];
        }
        NSString *argument = [@"/gateway:" stringByAppendingString:[gateway componentsJoinedByString:@","]];
        if (!addArgument(&argc, &argv, "%s", [argument UTF8String]))'''
    # No spaces between a gateway suboption and its value.
    new = new.replace('%@: %@', '%@:%@')
    replace(session, old, new)
    header = client / "Controllers/RDPSessionViewController.h"
    replace(header, "BOOL _pointer_is_indirect;", "BOOL _pointer_is_indirect;\n\tBOOL _mipt_direct_touch;")
    controller = client / "Controllers/RDPSessionViewController.m"
    native_ui = client / "FreeRDP/ios_freerdp_ui.m"
    replace(native_ui, '(fingerprint) ? [NSString stringWithUTF8String:subject] : @""', '(fingerprint) ? [NSString stringWithUTF8String:fingerprint] : @""')
    replace(native_ui, '@"fingerprint", nil];', '@"fingerprint", (host) ? [NSString stringWithUTF8String:host] : @"", @"hostname", nil];')
    # Check the predicate as well as waiting, so a fast UI response cannot be lost.
    ui = native_ui.read_text()
    ui = ui.replace('[[mfi->session uiRequestCompleted] wait];', 'while (![params objectForKey:@"result"]) [[mfi->session uiRequestCompleted] wait];')
    native_ui.write_text(ui)
    replace(controller, '''- (void)handleSingleTap:(UITapGestureRecognizer *)gesture
{
\tif (_pointer_is_indirect)''', '''- (void)miptToggleTouch:(UIButton *)sender
{
    _mipt_direct_touch = !_mipt_direct_touch;
    sender.selected = _mipt_direct_touch;
    sender.tintColor = _mipt_direct_touch ? [UIColor systemOrangeColor] : [UIColor systemBlueColor];
    sender.accessibilityValue = _mipt_direct_touch ? @"Прямые касания" : @"Тачпад";
}

- (void)handleSingleTap:(UITapGestureRecognizer *)gesture
{
\tif (_pointer_is_indirect || _mipt_direct_touch)''')
    replace(controller, '''- (void)handleMousePan:(UIPanGestureRecognizer *)gesture
{''', '''- (void)handleMousePan:(UIPanGestureRecognizer *)gesture
{
    if (_mipt_direct_touch && !_pointer_is_indirect) {
        [self moveCursorToSessionViewPosition:[gesture locationInView:_session_view]];
        if (gesture.state == UIGestureRecognizerStateBegan) {
            [self sendMouseButtonEvent:GetLeftMouseButtonClickEvent(YES)];
            _mouse_drag_active = YES;
        } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
            if (_mouse_drag_active) [self sendMouseButtonEvent:GetLeftMouseButtonClickEvent(NO)];
            _mouse_drag_active = NO;
        }
        return;
    }''')
    replace(controller, '''- (void)showSessionToolbar:(BOOL)show
{''', '''- (void)showSessionToolbar:(BOOL)show
{
    show = NO; // MiptRDP supplies a compact, always accessible keyboard toolbar.
''')
    print(source)
    return source

if __name__ == "__main__":
    prepare()
