#import "MiptApp.h"
#import <Security/Security.h>
#import "ConnectionParams.h"
#import "Bookmark.h"
#import "RDPSession.h"
#import "RDPSessionViewController.h"
#import "MiptEndpoint.h"

static UIColor *Background(void) { return [UIColor colorWithRed:.035 green:.055 blue:.10 alpha:1]; }
static void Message(UIViewController *vc, NSString *title, NSString *body) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:body preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Хорошо" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

// The metadata file never contains passwords. Secrets stay in the device Keychain.
static NSMutableDictionary *SecretQuery(NSString *identifier) {
    return [NSMutableDictionary dictionaryWithDictionary:@{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:@"ru.mipt.rdp.ios", (__bridge id)kSecAttrAccount:identifier}];
}
static NSString *ReadSecret(NSString *identifier, NSError **error) {
    NSMutableDictionary *q = SecretQuery(identifier);
    q[(__bridge id)kSecReturnData] = @YES;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status == errSecItemNotFound) return @"";
    if (status != errSecSuccess) { if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]; return nil; }
    NSString *value = [[[NSString alloc] initWithData:(NSData *)result encoding:NSUTF8StringEncoding] autorelease];
    if (result) CFRelease(result);
    return value ?: @"";
}
static BOOL WriteSecret(NSString *identifier, NSString *value, NSError **error) {
    NSMutableDictionary *q = SecretQuery(identifier);
    NSDictionary *attributes = @{(__bridge id)kSecValueData:[value dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)q, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) { [q addEntriesFromDictionary:attributes]; status = SecItemAdd((__bridge CFDictionaryRef)q, NULL); }
    if (status != errSecSuccess && error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
    return status == errSecSuccess;
}

@interface MiptStore : NSObject
@property(nonatomic, retain) NSMutableArray *profiles;
@property(nonatomic, retain) NSError *loadError;
- (BOOL)persist:(NSArray *)profiles error:(NSError **)error;
@end
@implementation MiptStore
- (NSURL *)url {
    NSURL *folder = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    [[NSFileManager defaultManager] createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    [folder setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return [folder URLByAppendingPathComponent:@"connections.json"];
}
- (instancetype)init {
    if ((self = [super init])) {
        self.profiles = [NSMutableArray array];
        NSError *error = nil;
        NSURL *url = [self url];
        if ([[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
            id result = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error] : nil;
            if ([result isKindOfClass:[NSArray class]]) {
                for (id profile in result) {
                    if (![profile isKindOfClass:[NSDictionary class]] || ![profile[@"id"] isKindOfClass:[NSString class]] || ![profile[@"host"] isKindOfClass:[NSString class]]) {
                        error = [NSError errorWithDomain:@"MiptRDP" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Повреждён файл подключений. Исходные данные сохранены."}]; break;
                    }
                }
                if (!error) self.profiles = result;
            } else if (!error) error = [NSError errorWithDomain:@"MiptRDP" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Не удалось прочитать подключения."}];
        }
        self.loadError = error;
    }
    return self;
}
- (BOOL)persist:(NSArray *)profiles error:(NSError **)error {
    if (self.loadError) { if (error) *error = self.loadError; return NO; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:profiles options:NSJSONWritingPrettyPrinted error:error];
    if (!data || ![data writeToURL:[self url] options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:error]) return NO;
    self.profiles = [[profiles mutableCopy] autorelease]; return YES;
}
- (void)dealloc { [_profiles release]; [_loadError release]; [super dealloc]; }
@end

// Addresses accept host, host:port, IPv6, or [IPv6]:port; no separate port controls.
NSDictionary *MiptEndpoint(NSString *input, NSInteger defaultPort) {
    NSString *host = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *port = nil;
    if ([host hasPrefix:@"["]) {
        NSRange end = [host rangeOfString:@"]"];
        if (end.location == NSNotFound) return nil;
        NSString *tail = [host substringFromIndex:end.location + 1];
        if (tail.length && ![tail hasPrefix:@":"]) return nil;
        if (tail.length) port = [tail substringFromIndex:1];
        host = [host substringWithRange:NSMakeRange(1,end.location-1)];
    } else if ([[host componentsSeparatedByString:@":"] count] == 2) {
        port = [[host componentsSeparatedByString:@":"] lastObject];
        host = [[host componentsSeparatedByString:@":"] firstObject];
    }
    if (!host.length || [host rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound || [host containsString:@"/"] || [host containsString:@"\""] || [host containsString:@"'"] || [host containsString:@","] || [host containsString:@"["] || [host containsString:@"]"]) return nil;
    NSInteger number = defaultPort;
    if (port) {
        if (!port.length || [port rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return nil;
        number = port.integerValue; if (number < 1 || number > 65535) return nil;
    }
    return @{@"host":host, @"port":@(number)};
}
static void SetIdentity(ConnectionParams *params, NSString *prefix, NSString *user, NSString *domain, NSString *password) {
    NSArray *parts = [user componentsSeparatedByString:@"\\"];
    if (parts.count == 2) { domain = parts[0]; user = parts[1]; }
    if ([user containsString:@"@"]) domain = @"";
    [params setValue:user ?: @"" forKey:[prefix stringByAppendingString:@"username"]];
    [params setValue:domain ?: @"" forKey:[prefix stringByAppendingString:@"domain"]];
    [params setValue:password ?: @"" forKey:[prefix stringByAppendingString:@"password"]];
}

@interface MiptEditor : UITableViewController
@property(nonatomic, retain) NSMutableDictionary *profile;
@property(nonatomic, retain) NSMutableDictionary *fields;
@property(nonatomic, retain) MiptStore *store;
@property(nonatomic, copy) void (^completion)(void);
@end
@implementation MiptEditor
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"Подключение"; self.view.backgroundColor = Background();
    self.fields = [NSMutableDictionary dictionary];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Сохранить" style:UIBarButtonItemStyleDone target:self action:@selector(save)] autorelease];
    self.navigationItem.leftBarButtonItem = [[[UIBarButtonItem alloc] initWithTitle:@"Отмена" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)] autorelease];
    NSArray *keys = @[@"label",@"host",@"username",@"domain",@"password",@"gateway",@"gatewayUsername",@"gatewayDomain",@"gatewayPassword"];
    NSError *error = nil;
    for (NSString *key in keys) {
        UITextField *field = [[[UITextField alloc] init] autorelease];
        field.text = self.profile[key] ?: @"";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
        if ([key.lowercaseString containsString:@"password"]) { field.secureTextEntry = YES; field.text = ReadSecret([self.profile[@"id"] stringByAppendingString:key], &error); }
        field.textContentType = field.secureTextEntry ? UITextContentTypePassword : UITextContentTypeUsername;
        self.fields[key] = field;
    }
    if (error) { self.navigationItem.rightBarButtonItem.enabled = NO; dispatch_async(dispatch_get_main_queue(), ^{ Message(self,@"Keychain",error.localizedDescription); }); }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section == 0 ? 5 : (section == 1 ? 4 : 2); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return @[@"Рабочий компьютер",@"RD Gateway · необязательно",@"Параметры"][section]; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return @[@"Адрес: pc.example.org или pc.example.org:3389. Учётная запись: пользователь, DOMAIN\\user или user@domain.",@"Для общих учётных данных оставьте пользователя шлюза пустым. Адрес шлюза может содержать :порт.",@"Пароли сохраняются только в Keychain этого iPhone. Долгое нажатие на карточку открывает редактирование."][section];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil] autorelease];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (path.section == 2) {
        NSString *key = path.row ? @"admin" : @"remember";
        cell.textLabel.text = path.row ? @"Сеанс администратора" : @"Запомнить пароли";
        UISwitch *toggle = [[[UISwitch alloc] init] autorelease]; toggle.on = [self.profile[key] boolValue]; toggle.tag = path.row;
        [toggle addTarget:self action:@selector(changed:) forControlEvents:UIControlEventValueChanged]; cell.accessoryView = toggle; return cell;
    }
    NSArray *keys = path.section ? @[@"gateway",@"gatewayUsername",@"gatewayDomain",@"gatewayPassword"] : @[@"label",@"host",@"username",@"domain",@"password"];
    NSArray *titles = path.section ? @[@"Шлюз",@"Пользователь шлюза",@"Домен шлюза",@"Пароль шлюза"] : @[@"Название",@"Имя компьютера",@"Пользователь",@"Домен",@"Пароль"];
    UITextField *field = self.fields[keys[path.row]]; field.placeholder = titles[path.row]; field.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:field];
    [NSLayoutConstraint activateConstraints:@[[field.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor], [field.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor], [field.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:14], [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-14]]];
    return cell;
}
- (void)changed:(UISwitch *)toggle { self.profile[toggle.tag ? @"admin" : @"remember"] = @(toggle.on); }
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)save {
    for (NSString *key in self.fields) if (![key.lowercaseString containsString:@"password"]) self.profile[key] = ((UITextField *)self.fields[key]).text ?: @"";
    if (!MiptEndpoint(self.profile[@"host"],3389) || ([self.profile[@"gateway"] length] && !MiptEndpoint(self.profile[@"gateway"],443))) { Message(self,@"Проверьте адрес",@"Укажите имя компьютера и корректный адрес шлюза. Допустимый порт: 1–65535."); return; }
    NSError *error = nil; NSMutableDictionary *previous = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"password",@"gatewayPassword"]) {
        NSString *identifier = [self.profile[@"id"] stringByAppendingString:key];
        NSString *old = ReadSecret(identifier,&error); if (!old) break; previous[key] = old;
        if (!WriteSecret(identifier,[self.profile[@"remember"] boolValue] ? ((UITextField *)self.fields[key]).text : @"",&error)) break;
    }
    NSMutableArray *profiles = [[self.store.profiles mutableCopy] autorelease];
    NSUInteger index = [profiles indexOfObjectPassingTest:^BOOL(id obj, NSUInteger i, BOOL *stop) { return [obj[@"id"] isEqual:self.profile[@"id"]]; }];
    if (index == NSNotFound) [profiles addObject:self.profile]; else profiles[index] = self.profile;
    if (error || ![self.store persist:profiles error:&error]) {
        for (NSString *key in previous) WriteSecret([self.profile[@"id"] stringByAppendingString:key],previous[key],nil);
        Message(self,@"Не удалось сохранить",error.localizedDescription); return;
    }
    if (self.completion) self.completion(); [self cancel];
}
- (void)dealloc { [_profile release]; [_fields release]; [_store release]; [_completion release]; [super dealloc]; }
@end

@interface MiptSession : RDPSessionViewController
@end
@implementation MiptSession
- (void)session:(RDPSession *)session didFailToConnect:(int)reason {
    UINavigationController *nav = [[self.navigationController retain] autorelease];
    [super session:session didFailToConnect:reason];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Message(nav.topViewController,@"Подключение не установлено",[NSString stringWithFormat:@"Проверьте адрес, сеть, учётную запись и шлюз. Код FreeRDP: 0x%08X.",reason]);
    });
}
- (void)session:(RDPSession *)session verifyCertificateWithParams:(NSMutableDictionary *)params {
    NSString *details = [NSString stringWithFormat:@"Не удалось подтвердить сертификат сервера %@.\\n\\nИздатель: %@\\n\\nSHA-256: %@",params[@"hostname"] ?: @"",params[@"issuer"] ?: @"",params[@"fingerprint"] ?: @""];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Сертификат сервера" message:details preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Отмена" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [[session uiRequestCompleted] lock]; params[@"result"] = @NO; [[session uiRequestCompleted] signal]; [[session uiRequestCompleted] unlock];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Подключиться" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[session uiRequestCompleted] lock]; params[@"result"] = @YES; [[session uiRequestCompleted] signal]; [[session uiRequestCompleted] unlock];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    UIStackView *bar = [[[UIStackView alloc] init] autorelease]; bar.axis = UILayoutConstraintAxisHorizontal; bar.spacing = 4; bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor colorWithWhite:.06 alpha:.85]; bar.layer.cornerRadius = 18;
    NSArray *icons = @[@"keyboard",@"hand.point.up.left",@"xmark"];
    NSArray *labels = @[@"Клавиатура",@"Переключить сенсорный режим",@"Отключиться"];
    NSArray *actions = @[@"toggleKeyboard:",@"miptToggleTouch:",@"miptClose:"];
    for (NSUInteger i = 0; i < icons.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem]; [b setImage:[UIImage systemImageNamed:icons[i]] forState:UIControlStateNormal]; b.accessibilityLabel = labels[i];
        [b addTarget:self action:NSSelectorFromString(actions[i]) forControlEvents:UIControlEventTouchUpInside];
        [b.widthAnchor constraintEqualToConstant:44].active = YES; [b.heightAnchor constraintEqualToConstant:44].active = YES; [bar addArrangedSubview:b];
    }
    [self.view addSubview:bar]; [NSLayoutConstraint activateConstraints:@[[bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8], [bar.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12]]];
}
- (void)miptClose:(id)sender {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Завершить подключение?" message:@"Программы продолжат работать на удалённом компьютере." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Остаться" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Отключиться" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) { [_session disconnect]; }]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

@interface MiptHomeController ()
@property(nonatomic, retain) MiptStore *store;
@end
@implementation MiptHomeController
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"MiptRDP"; self.view.backgroundColor = Background(); self.store = [[[MiptStore alloc] init] autorelease];
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(add)] autorelease];
    self.tableView.rowHeight = 84;
    UILongPressGestureRecognizer *press = [[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(edit:)] autorelease]; [self.tableView addGestureRecognizer:press];
    if (self.store.loadError) dispatch_async(dispatch_get_main_queue(), ^{ Message(self,@"Не удалось прочитать подключения",self.store.loadError.localizedDescription); });
    [self refresh];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.navigationController setNavigationBarHidden:NO animated:animated]; }
- (void)refresh {
    [self.tableView reloadData];
    UILabel *empty = [[[UILabel alloc] init] autorelease]; empty.numberOfLines = 0; empty.textAlignment = NSTextAlignmentCenter; empty.textColor = UIColor.secondaryLabelColor;
    empty.text = @"Ваш рабочий стол — рядом\n\nДобавьте компьютер кнопкой +\nПрямое подключение и RD Gateway";
    self.tableView.backgroundView = self.store.profiles.count ? nil : empty;
}
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return self.store.profiles.count; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return self.store.profiles.count ? @"Ваши компьютеры" : nil; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)path {
    NSDictionary *p = self.store.profiles[path.row]; UITableViewCell *c = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil] autorelease];
    c.textLabel.text = [p[@"label"] length] ? p[@"label"] : p[@"host"]; c.textLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    c.detailTextLabel.text = [p[@"gateway"] length] ? [NSString stringWithFormat:@"%@ · через шлюз",p[@"host"]] : p[@"host"];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor; c.imageView.image = [UIImage systemImageNamed:@"desktopcomputer"]; c.imageView.tintColor = self.view.tintColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return c;
}
- (void)openEditor:(NSDictionary *)profile {
    MiptEditor *editor = [[[MiptEditor alloc] initWithStyle:UITableViewStyleInsetGrouped] autorelease]; editor.store = self.store; editor.profile = [[profile mutableCopy] autorelease];
    editor.completion = ^{ [self refresh]; };
    UINavigationController *nav = [[[UINavigationController alloc] initWithRootViewController:editor] autorelease]; [self presentViewController:nav animated:YES completion:nil];
}
- (void)add { [self openEditor:@{@"id":NSUUID.UUID.UUIDString,@"host":@"",@"remember":@YES}]; }
- (void)edit:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *path = [self.tableView indexPathForRowAtPoint:[gesture locationInView:self.tableView]]; if (path) [self openEditor:self.store.profiles[path.row]];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES]; NSDictionary *p = self.store.profiles[path.row]; NSDictionary *endpoint = MiptEndpoint(p[@"host"],3389);
    if (!endpoint) { Message(self,@"Некорректный адрес",@"Откройте редактирование долгим нажатием."); return; }
    NSError *error = nil; NSString *password = ReadSecret([p[@"id"] stringByAppendingString:@"password"],&error);
    NSString *gatewayPassword = ReadSecret([p[@"id"] stringByAppendingString:@"gatewayPassword"],&error);
    if (error) { Message(self,@"Keychain",error.localizedDescription); return; }
    ConnectionParams *params = [[[ConnectionParams alloc] initWithBaseDefaultParameters] autorelease];
    [params setValue:endpoint[@"host"] forKey:@"hostname"]; [params setInt:[endpoint[@"port"] intValue] forKey:@"port"];
    SetIdentity(params,@"",p[@"username"],p[@"domain"],password);
    [params setBool:[p[@"admin"] boolValue] forKey:@"console"]; [params setBool:NO forKey:@"perf_h264"]; [params setBool:NO forKey:@"enable_3g_settings"];
    CGRect viewport = self.view.bounds; CGFloat scale = self.view.window.screen.scale;
    [params setInt:(int)MAX(64,MIN(4096,viewport.size.width*scale)) forKey:@"width"];
    [params setInt:(int)MAX(64,MIN(4096,viewport.size.height*scale)) forKey:@"height"]; [params setInt:1 forKey:@"screen_resolution_type"];
    if ([p[@"gateway"] length]) {
        NSDictionary *g = MiptEndpoint(p[@"gateway"],443); if (!g) { Message(self,@"Некорректный шлюз",@"Проверьте адрес шлюза."); return; }
        [params setBool:YES forKey:@"enable_tsg_settings"]; [params setValue:g[@"host"] forKey:@"tsg_hostname"]; [params setInt:[g[@"port"] intValue] forKey:@"tsg_port"];
        BOOL separate = [p[@"gatewayUsername"] length] > 0;
        SetIdentity(params,@"tsg_",separate ? p[@"gatewayUsername"] : p[@"username"],separate ? p[@"gatewayDomain"] : p[@"domain"],separate ? gatewayPassword : password);
    } else [params setBool:NO forKey:@"enable_tsg_settings"];
    ComputerBookmark *bookmark = [[[ComputerBookmark alloc] initWithConnectionParameters:params] autorelease]; bookmark.label = [p[@"label"] length] ? p[@"label"] : p[@"host"]; bookmark.conntectedViaWLAN = YES;
    RDPSession *session = [[[RDPSession alloc] initWithBookmark:bookmark] autorelease];
    if (!session) { Message(self,@"Не удалось подготовить сеанс",@"Проверьте параметры подключения."); return; }
    MiptSession *controller = [[[MiptSession alloc] initWithNibName:@"RDPSessionView" bundle:nil session:session] autorelease];
    [self.navigationController pushViewController:controller animated:YES];
}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)path {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSDictionary *p = [[self.store.profiles[path.row] retain] autorelease]; NSMutableArray *next = [[self.store.profiles mutableCopy] autorelease]; [next removeObjectAtIndex:path.row];
    NSError *error = nil; if (![self.store persist:next error:&error]) { Message(self,@"Не удалось удалить",error.localizedDescription); return; }
    for (NSString *key in @[@"password",@"gatewayPassword"]) SecItemDelete((__bridge CFDictionaryRef)SecretQuery([p[@"id"] stringByAppendingString:key])); [self refresh];
}
- (void)dealloc { [_store release]; [super dealloc]; }
@end
