// Older Sidecar – Mac cast. Jakmile je iPad pripojeny kabelem a bezi na nem aplikace
// Older Sidecar, zrcadli na nej hlavni obrazovku Macu: snima ji (ScreenCaptureKit),
// zmensi do displeje iPadu a posila jako JPEG. Dotyky z iPadu prevadi na kliknuti mysi.
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <ImageIO/ImageIO.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/hidsystem/ev_keymap.h>

#define PORT 7777
#ifndef USBMUXD_CESTA // pri zkousce bez iPadu se sem da cesta k falesnemu usbmuxd
#define USBMUXD_CESTA "/var/run/usbmuxd"
#endif

#define AGENT @"com.oldersidecar.mac" // LaunchAgent pro spousteni po prihlaseni
#define ADRESA_REPA @"https://vp-of-tradelin.github.io/OlderSidecar/" // Cydia zdroj (GitHub Pages)

// Stejne zpravy jako v aplikaci na iPadu (ios/main.m).
enum {
    ZpravaAhoj = 1,     // iPad -> Mac: sirka a vyska displeje v pixelech
    ZpravaHotovo = 2,   // iPad -> Mac: snimek rozbalen, muzes poslat dalsi
    ZpravaDotyk = 3,    // iPad -> Mac: faze (0 polozeni, 1 tah, 2 zvednuti), x, y (starsi verze)
    ZpravaRezim = 4,    // iPad -> Mac: RezimObrazovka / RezimOvladani
    ZpravaPohyb = 5,    // iPad -> Mac: posun kurzoru o dx, dy (se znamenkem)
    ZpravaKlik = 6,     // iPad -> Mac: tlacitko (0 leve, 1 prave), pocet kliknuti
    ZpravaTlacitko = 7, // iPad -> Mac: leve tlacitko dole (1) / nahore (0) – tazeni
    ZpravaKolecko = 8,  // iPad -> Mac: posouvani obsahu o dx, dy
    ZpravaKlavesa = 9,  // iPad -> Mac: Klavesa...
    ZpravaSnimek = 10,  // Mac -> iPad: obrazek JPEG
    ZpravaStav = 11,    // Mac -> iPad: proc obraz nejde (Stav...)
    ZpravaZivot = 12,   // Mac -> iPad kazde 2 s: Mac zije; kdyz prestane chodit, iPad spojeni ukonci
    ZpravaText = 13,    // iPad -> Mac: napsany text v UTF-8
    ZpravaInfo = 14,    // iPad -> Mac: jmeno, model a verze iOS (UTF-8, oddelene novym radkem)
    ZpravaBaterie = 15, // iPad -> Mac: baterie v % (999 = nevi se), stav (Baterie...)
    ZpravaZkratka = 16, // iPad -> Mac: Mod... (4 bajty) + text v UTF-8, napr. Cmd + c
};
enum { StavChybiPovoleni = 1, StavNejdeSnimat = 2, StavObrazovkaSpi = 3, StavMacSpi = 4, StavProbuzeno = 5 };
enum { RezimObrazovka = 1, RezimOvladani = 2 };
enum { KlavesaMazat = 1, KlavesaEnter = 2, KlavesaEsc = 3, KlavesaTab = 4,
       KlavesaVlevo = 5, KlavesaVpravo = 6, KlavesaDolu = 7, KlavesaNahoru = 8,
       KlavesaPrehrat = 10, KlavesaDalsi = 11, KlavesaPredchozi = 12, KlavesaHlasiteji = 13, KlavesaTiseji = 14, KlavesaZtlumit = 15,
       KlavesaJasMene = 16, KlavesaJasVic = 17, KlavesaMissionControl = 18, KlavesaLaunchpad = 19, KlavesaZamknout = 20 };
enum { ModCmd = 1, ModAlt = 2, ModCtrl = 4, ModShift = 8 };
enum { BaterieNevi = 0, BaterieNaBaterii = 1, BaterieNabiji = 2, BaterieNabito = 3 };

static BOOL CtiVse(int fd, void *kam, size_t n) {
    uint8_t *p = kam;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return NO;
        p += r;
        n -= r;
    }
    return YES;
}

static BOOL PisVse(int fd, const void *co, size_t n) {
    const uint8_t *p = co;
    while (n > 0) {
        ssize_t r = write(fd, p, n);
        if (r <= 0) return NO;
        p += r;
        n -= r;
    }
    return YES;
}

#pragma mark - usbmuxd (spojeni s iPadem pres USB, totez co dela iproxy)

static int UsbmuxSocket(void) {
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un adresa = { .sun_family = AF_UNIX };
    strlcpy(adresa.sun_path, USBMUXD_CESTA, sizeof adresa.sun_path);
    if (connect(s, (struct sockaddr *)&adresa, sizeof adresa) < 0) {
        close(s);
        return -1;
    }
    return s;
}

// usbmuxd mluvi plisty s hlavickou: delka, verze 1, typ 8 (plist), tag – vse little-endian.
static NSDictionary *UsbmuxDotaz(int s, NSDictionary *dotaz) {
    NSMutableDictionary *d = [dotaz mutableCopy];
    d[@"ClientVersionString"] = @"OlderSidecar";
    d[@"ProgName"] = @"OlderSidecar";
    d[@"kLibUSBMuxVersion"] = @3;
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    uint32_t h[4] = { OSSwapHostToLittleInt32(16 + (uint32_t)plist.length), OSSwapHostToLittleInt32(1),
                      OSSwapHostToLittleInt32(8), OSSwapHostToLittleInt32(1) };
    if (!PisVse(s, h, sizeof h) || !PisVse(s, plist.bytes, plist.length) || !CtiVse(s, h, sizeof h)) return nil;
    uint32_t delka = OSSwapLittleToHostInt32(h[0]);
    if (delka < 16 || delka > (1 << 20)) return nil;
    NSMutableData *odpoved = [NSMutableData dataWithLength:delka - 16];
    if (!CtiVse(s, odpoved.mutableBytes, odpoved.length)) return nil;
    return [NSPropertyListSerialization propertyListWithData:odpoved options:0 format:NULL error:NULL];
}

// Vrati socket propojeny s portem na iPadu, nebo -1 (iPad neni pripojen nebo na nem nebezi aplikace).
static int PripojIPad(uint16_t port) {
    int s = UsbmuxSocket();
    if (s < 0) return -1;
    NSDictionary *seznam = UsbmuxDotaz(s, @{@"MessageType": @"ListDevices"});
    close(s);
    for (NSDictionary *zarizeni in seznam[@"DeviceList"]) {
        NSDictionary *vlastnosti = zarizeni[@"Properties"];
        if (![vlastnosti[@"ConnectionType"] isEqual:@"USB"]) continue;
        s = UsbmuxSocket();
        if (s < 0) return -1;
        NSDictionary *odpoved = UsbmuxDotaz(s, @{@"MessageType": @"Connect",
                                                 @"DeviceID": zarizeni[@"DeviceID"] ?: vlastnosti[@"DeviceID"],
                                                 @"PortNumber": @(CFSwapInt16HostToBig(port))});
        if (odpoved[@"Number"] && [odpoved[@"Number"] intValue] == 0) return s;
        close(s);
    }
    return -1;
}

// Cely displej iPadu (sirka x vyska): cerne pozadi a v obdelniku kam (pocitano shora) snimek obrazovky Macu.
static NSData *JPEGZeSnimku(CVPixelBufferRef snimek, size_t sirka, size_t vyska, CGRect kam) {
    CGImageRef obrazek = NULL;
    VTCreateCGImageFromCVPixelBuffer(snimek, NULL, &obrazek);
    if (!obrazek) return nil;
    CGColorSpaceRef barvy = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, sirka, vyska, 8, 0, barvy, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(barvy);
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, 0, sirka, vyska));
    // CoreGraphics ma pocatek vlevo dole
    CGContextDrawImage(c, CGRectMake(kam.origin.x, vyska - CGRectGetMaxY(kam), kam.size.width, kam.size.height), obrazek);
    CGImageRelease(obrazek);
    CGImageRef cely = CGBitmapContextCreateImage(c);
    CGContextRelease(c);

    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef cil = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.jpeg"), 1, NULL);
    CGImageDestinationAddImage(cil, cely, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.7});
    BOOL ok = CGImageDestinationFinalize(cil);
    CFRelease(cil);
    CGImageRelease(cely);
    return ok ? data : nil;
}

static NSString *CestaAgenta(void) {
    return [NSString stringWithFormat:@"%@/Library/LaunchAgents/%@.plist", NSHomeDirectory(), AGENT];
}

#pragma mark - Vzhled starych Mac OS X (kartacovany hlinik, leskle Aqua prvky, Lucida Grande)

typedef NS_ENUM(NSInteger, OSKontrolka) { OSKontrolkaSeda, OSKontrolkaZelena, OSKontrolkaOranzova };

static NSColor *Barva(CGFloat r, CGFloat g, CGFloat b) {
    return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1];
}

// Lucida Grande bylo pismo Mac OS X; kdyby v systemu chybelo, pouzije se systemove
static NSFont *Pismo(CGFloat velikost, BOOL tucne) {
    NSFont *f = [NSFont fontWithName:tucne ? @"LucidaGrande-Bold" : @"LucidaGrande" size:velikost];
    return f ?: (tucne ? [NSFont boldSystemFontOfSize:velikost] : [NSFont systemFontOfSize:velikost]);
}

static NSTextField *Popisek(NSString *text, NSFont *pismo, NSColor *barva, BOOL vyryty) {
    NSTextField *t = [NSTextField wrappingLabelWithString:@""];
    t.selectable = NO;
    NSMutableDictionary *vzhled = [@{NSFontAttributeName: pismo, NSForegroundColorAttributeName: barva} mutableCopy];
    if (vyryty) { // svetly odlesk pod pismem = text vyryty do kovu
        NSShadow *odlesk = [[NSShadow alloc] init];
        odlesk.shadowColor = [NSColor colorWithWhite:1 alpha:0.75];
        odlesk.shadowOffset = NSMakeSize(0, -1);
        vzhled[NSShadowAttributeName] = odlesk;
    }
    t.attributedStringValue = [[NSAttributedString alloc] initWithString:text attributes:vzhled];
    return t;
}

// Leskla kulata kontrolka: zelena = v poradku, oranzova = je potreba neco udelat, seda = ceka se
static NSImage *Kontrolka(OSKontrolka druh, CGFloat velikost) {
    NSColor *b = druh == OSKontrolkaZelena ? Barva(0.25, 0.78, 0.22)
               : druh == OSKontrolkaOranzova ? Barva(0.98, 0.62, 0.12) : Barva(0.62, 0.63, 0.66);
    return [NSImage imageWithSize:NSMakeSize(velikost, velikost) flipped:NO drawingHandler:^BOOL(NSRect r) {
        NSRect kruh = NSInsetRect(r, 1, 1);
        [[NSColor colorWithWhite:0 alpha:0.5] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:kruh] fill];
        NSGradient *telo = [[NSGradient alloc] initWithStartingColor:[b blendedColorWithFraction:0.45 ofColor:NSColor.whiteColor]
                                                         endingColor:[b blendedColorWithFraction:0.35 ofColor:NSColor.blackColor]];
        [telo drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(kruh, 1, 1)] relativeCenterPosition:NSMakePoint(0, -0.5)];
        NSRect odlesk = NSMakeRect(NSMinX(kruh) + kruh.size.width * 0.22, NSMinY(kruh) + kruh.size.height * 0.5,
                                   kruh.size.width * 0.56, kruh.size.height * 0.4);
        NSGradient *lesk = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:1 alpha:0.95]
                                                         endingColor:[NSColor colorWithWhite:1 alpha:0.05]];
        [lesk drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:odlesk] angle:-90];
        return YES;
    }];
}

// Leskle tlacitko Aqua: modre (hlavni) nebo sede, s ostrym prechodem v pulce jako v Mac OS X
@interface OSAquaBunka : NSButtonCell
@property (nonatomic) BOOL modra;
@end

@implementation OSAquaBunka
- (void)drawBezelWithFrame:(NSRect)ram inView:(NSView *)pohled {
    NSRect r = NSInsetRect(ram, 2, 3);
    CGFloat polomer = r.size.height / 2;
    NSBezierPath *tvar = [NSBezierPath bezierPathWithRoundedRect:r xRadius:polomer yRadius:polomer];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *stin = [[NSShadow alloc] init];
    stin.shadowOffset = NSMakeSize(0, -1);
    stin.shadowBlurRadius = 2;
    stin.shadowColor = [NSColor colorWithWhite:0 alpha:0.4];
    [stin set];
    [[NSColor colorWithWhite:0.5 alpha:1] setFill];
    [tvar fill];
    [NSGraphicsContext restoreGraphicsState];

    NSArray *barvy = self.modra
        ? @[Barva(0.68, 0.84, 0.99), Barva(0.40, 0.65, 0.94), Barva(0.22, 0.50, 0.89), Barva(0.52, 0.79, 0.99)]
        : @[Barva(1.00, 1.00, 1.00), Barva(0.93, 0.93, 0.94), Barva(0.85, 0.86, 0.87), Barva(0.96, 0.96, 0.97)];
    if (self.isHighlighted) { // stisknute tlacitko ztmavne
        NSMutableArray *tmavsi = [NSMutableArray array];
        for (NSColor *b in barvy) [tmavsi addObject:[b blendedColorWithFraction:0.18 ofColor:NSColor.blackColor]];
        barvy = tmavsi;
    }
    CGFloat mista[] = {0, 0.5, 0.5, 1};
    NSGradient *telo = [[NSGradient alloc] initWithColors:barvy atLocations:mista colorSpace:NSColorSpace.sRGBColorSpace];
    [telo drawInBezierPath:tvar angle:pohled.isFlipped ? 90 : -90];
    [(self.modra ? Barva(0.14, 0.33, 0.66) : Barva(0.52, 0.52, 0.54)) setStroke];
    tvar.lineWidth = 1;
    [tvar stroke];
}

- (NSRect)drawTitle:(NSAttributedString *)titulek withFrame:(NSRect)ram inView:(NSView *)pohled {
    NSShadow *odlesk = [[NSShadow alloc] init];
    odlesk.shadowColor = [NSColor colorWithWhite:1 alpha:self.modra ? 0.35 : 0.8];
    odlesk.shadowOffset = NSMakeSize(0, -1);
    NSMutableParagraphStyle *odstavec = [[NSMutableParagraphStyle alloc] init];
    odstavec.alignment = NSTextAlignmentCenter;
    NSAttributedString *t = [[NSAttributedString alloc] initWithString:titulek.string attributes:@{
        NSFontAttributeName: Pismo(13, NO), NSForegroundColorAttributeName: Barva(0.08, 0.08, 0.10),
        NSShadowAttributeName: odlesk, NSParagraphStyleAttributeName: odstavec}];
    return [super drawTitle:t withFrame:ram inView:pohled];
}
@end

static NSButton *Tlacitko(NSString *nazev, BOOL modre, id cil, SEL akce) {
    NSButton *b = [[NSButton alloc] initWithFrame:NSZeroRect];
    OSAquaBunka *bunka = [[OSAquaBunka alloc] initTextCell:nazev];
    bunka.modra = modre;
    bunka.bezelStyle = NSBezelStyleRounded;
    bunka.bordered = YES;
    b.cell = bunka;
    b.target = cil;
    b.action = akce;
    return b;
}

// Pozadi okna: kartacovany hlinik jako v Mac OS X Tiger a v nem propadly panel s kroky
@interface OSKov : NSView
@property (nonatomic) NSRect panel;
@property (nonatomic, copy) NSArray<NSNumber *> *predely; // y oddelovacu radku v panelu
@end

@implementation OSKov
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)oblast {
    // textura z tools/make-graphics.swift (sum rozmazany vodorovne, jako skutecny kartacovany kov)
    [[NSImage imageNamed:@"Kov"] drawInRect:self.bounds];
    if (NSIsEmptyRect(self.panel)) return;

    NSBezierPath *tvar = [NSBezierPath bezierPathWithRoundedRect:self.panel xRadius:9 yRadius:9];
    [[NSColor colorWithWhite:1 alpha:0.6] setFill]; // svetla spodni hrana, panel je do kovu zapusteny
    [[NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(self.panel, 0, 1) xRadius:9 yRadius:9] fill];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0.90 alpha:1] endingColor:[NSColor colorWithWhite:0.97 alpha:1]]
        drawInBezierPath:tvar angle:90];
    [NSGraphicsContext saveGraphicsState];
    [tvar addClip];
    [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:0.2] endingColor:[NSColor colorWithWhite:0 alpha:0]]
        drawInRect:NSMakeRect(NSMinX(self.panel), NSMinY(self.panel), NSWidth(self.panel), 9) angle:90];
    [NSGraphicsContext restoreGraphicsState];
    [[NSColor colorWithWhite:0.48 alpha:1] setStroke];
    tvar.lineWidth = 1;
    [tvar stroke];
    for (NSNumber *y in self.predely) {
        [[NSColor colorWithWhite:0.72 alpha:1] setFill];
        NSRectFill(NSMakeRect(NSMinX(self.panel) + 14, y.doubleValue, NSWidth(self.panel) - 28, 1));
        [[NSColor whiteColor] setFill];
        NSRectFill(NSMakeRect(NSMinX(self.panel) + 14, y.doubleValue + 1, NSWidth(self.panel) - 28, 1));
    }
}
@end

#pragma mark - Pruvodce nastavenim

static void OtevriSoukromi(NSString *cast) {
    NSString *adresa = [@"x-apple.systempreferences:com.apple.preference.security?" stringByAppendingString:cast];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:adresa]];
}

// Okno se tremi kroky: Nahravani obrazovky, Zpristupneni a appka na iPadu. Kontrolky se samy obnovuji.
@interface OSPruvodce : NSObject <NSWindowDelegate>
@property (nonatomic) BOOL ipadPripojen;
- (void)ukaz;
@end

@implementation OSPruvodce {
    NSWindow *_okno;
    NSImageView *_kontrolky[3];
    NSButton *_tlacitka[3];
    NSTextField *_hotovo[3];
    NSTimer *_casovac;
}

- (void)ukaz {
    if (!_okno) {
        [self postav];
        [_okno center];
    }
    [self obnov];
    if (!_casovac) _casovac = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(obnov) userInfo:nil repeats:YES];
    [NSApp activateIgnoringOtherApps:YES];
    [_okno makeKeyAndOrderFront:nil];
}

- (void)setIpadPripojen:(BOOL)pripojen {
    _ipadPripojen = pripojen;
    if (_okno.visible) [self obnov];
}

- (void)windowWillClose:(NSNotification *)oznameni {
    [_casovac invalidate];
    _casovac = nil;
}

- (void)postav {
    CGFloat sirka = 560, vyska = 490;
    _okno = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, sirka, vyska)
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskFullSizeContentView
                                          backing:NSBackingStoreBuffered defer:NO];
    _okno.title = @"Older Sidecar";
    _okno.titlebarAppearsTransparent = YES; // hlinik i pod titulkem, jako cela okna v Tigeru
    _okno.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    _okno.releasedWhenClosed = NO;
    _okno.delegate = self;
    OSKov *kov = [[OSKov alloc] initWithFrame:NSMakeRect(0, 0, sirka, vyska)];
    _okno.contentView = kov;

    NSImageView *ikona = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    ikona.frame = NSMakeRect(10, 22, 136, 136); // sajdkara je siroka, ikona proto vetsi
    [kov addSubview:ikona];
    NSTextField *nadpis = Popisek(NSLocalizedString(@"Welcome to Older Sidecar", nil), Pismo(19, YES), Barva(0.16, 0.17, 0.19), YES);
    nadpis.frame = NSMakeRect(152, 56, sirka - 176, 28);
    [kov addSubview:nadpis];
    NSTextField *uvod = Popisek(NSLocalizedString(@"Mirror your Mac's screen to an old iPad over a USB cable. Allow two things and install the iPad app:", nil),
                                Pismo(12, NO), Barva(0.27, 0.28, 0.31), YES);
    uvod.frame = NSMakeRect(152, 88, sirka - 176, 58);
    [kov addSubview:uvod];

    CGFloat radek = 82;
    NSRect panel = NSMakeRect(20, 160, sirka - 40, 3 * radek);
    kov.panel = panel;
    kov.predely = @[@(NSMinY(panel) + radek), @(NSMinY(panel) + 2 * radek)];
    NSArray *nazvy = @[NSLocalizedString(@"Screen Recording", nil), NSLocalizedString(@"Accessibility", nil), NSLocalizedString(@"iPad app", nil)];
    NSArray *popisy = @[NSLocalizedString(@"So the iPad can show your screen.", nil),
                        NSLocalizedString(@"So a tap on the iPad can click on the Mac.", nil),
                        [NSString stringWithFormat:NSLocalizedString(@"In Cydia add the source %@ and install Older Sidecar.", nil), ADRESA_REPA]];
    NSArray *akce = @[NSLocalizedString(@"Allow…", nil), NSLocalizedString(@"Allow…", nil), NSLocalizedString(@"Copy Source", nil)];
    NSArray *splneno = @[NSLocalizedString(@"Allowed", nil), NSLocalizedString(@"Allowed", nil), NSLocalizedString(@"Connected", nil)];
    for (int i = 0; i < 3; i++) {
        CGFloat y = NSMinY(panel) + i * radek;
        _kontrolky[i] = [[NSImageView alloc] initWithFrame:NSMakeRect(NSMinX(panel) + 18, y + 28, 20, 20)];
        [kov addSubview:_kontrolky[i]];
        NSTextField *nazev = Popisek(nazvy[i], Pismo(13, YES), Barva(0.12, 0.12, 0.14), YES);
        nazev.frame = NSMakeRect(NSMinX(panel) + 50, y + 14, 296, 18);
        [kov addSubview:nazev];
        NSTextField *popis = Popisek(popisy[i], Pismo(11, NO), Barva(0.36, 0.37, 0.40), YES);
        popis.frame = NSMakeRect(NSMinX(panel) + 50, y + 33, 296, 48);
        [kov addSubview:popis];
        _tlacitka[i] = Tlacitko(akce[i], NO, self, @selector(krok:));
        _tlacitka[i].tag = i;
        _tlacitka[i].frame = NSMakeRect(NSMaxX(panel) - 166, y + 22, 152, 32);
        [kov addSubview:_tlacitka[i]];
        _hotovo[i] = Popisek(splneno[i], Pismo(12, YES), Barva(0.18, 0.50, 0.16), YES);
        _hotovo[i].alignment = NSTextAlignmentRight;
        _hotovo[i].frame = NSMakeRect(NSMaxX(panel) - 166, y + 29, 148, 18);
        [kov addSubview:_hotovo[i]];
    }

    NSButton *hotovo = Tlacitko(NSLocalizedString(@"Done", nil), YES, _okno, @selector(performClose:));
    hotovo.frame = NSMakeRect(sirka - 146, vyska - 54, 126, 34);
    hotovo.keyEquivalent = @"\r";
    [kov addSubview:hotovo];
}

- (void)obnov {
    BOOL splneno[3] = { CGPreflightScreenCaptureAccess(), AXIsProcessTrusted(), self.ipadPripojen };
    for (int i = 0; i < 3; i++) {
        _kontrolky[i].image = Kontrolka(splneno[i] ? OSKontrolkaZelena : i < 2 ? OSKontrolkaOranzova : OSKontrolkaSeda, 20);
        _tlacitka[i].hidden = splneno[i];
        _hotovo[i].hidden = !splneno[i];
    }
}

- (void)krok:(NSButton *)tlacitko {
    if (tlacitko.tag == 0) {
        CGRequestScreenCaptureAccess(); // zaradi aplikaci do seznamu v Nastaveni
        OtevriSoukromi(@"Privacy_ScreenCapture");
    } else if (tlacitko.tag == 1) {
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
        OtevriSoukromi(@"Privacy_Accessibility");
    } else {
        [[NSPasteboard generalPasteboard] clearContents];
        [[NSPasteboard generalPasteboard] setString:ADRESA_REPA forType:NSPasteboardTypeString];
        tlacitko.title = NSLocalizedString(@"Copied", nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            tlacitko.title = NSLocalizedString(@"Copy Source", nil);
        });
    }
}
@end

// Zahlavi menu v liste: ikona, nazev a verze
static NSView *ZahlaviMenu(void) {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 54)];
    NSImageView *ikona = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    ikona.frame = NSMakeRect(14, 6, 42, 42);
    [v addSubview:ikona];
    NSTextField *nazev = Popisek(@"Older Sidecar", Pismo(13, YES), NSColor.labelColor, NO);
    nazev.frame = NSMakeRect(62, 27, 190, 18);
    [v addSubview:nazev];
    NSString *verze = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSTextField *popis = Popisek([NSString stringWithFormat:NSLocalizedString(@"Version %@", nil), verze], Pismo(11, NO), NSColor.secondaryLabelColor, NO);
    popis.frame = NSMakeRect(62, 9, 190, 16);
    [v addSubview:popis];
    return v;
}

#pragma mark - Karta iPadu v menu a hlaseni na obrazovce

// Karta v menu: maly iPad, jmeno, model s verzi iOS a baterie
@interface OSKartaIPadu : NSView
@property (nonatomic, copy) NSString *jmeno, *popis;
@property (nonatomic) int baterie;       // %, 999 = nevi se
@property (nonatomic) uint32_t stav;     // Baterie...
@end

@implementation OSKartaIPadu
- (instancetype)initWithFrame:(NSRect)ram {
    if ((self = [super initWithFrame:ram])) _baterie = 999;
    return self;
}

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)oblast {
    CGFloat w = self.bounds.size.width;
    // maly iPad na sirku: cerny ram se stribrnou hranou, modra obrazovka, tlacitko Domu
    NSRect ipad = NSMakeRect(16, 16, 42, 32);
    NSBezierPath *telo = [NSBezierPath bezierPathWithRoundedRect:ipad xRadius:5 yRadius:5];
    [[NSColor colorWithWhite:0.12 alpha:1] setFill];
    [telo fill];
    [[NSColor colorWithWhite:0.78 alpha:1] setStroke];
    telo.lineWidth = 1.5;
    [telo stroke];
    [[[NSGradient alloc] initWithStartingColor:Barva(0.08, 0.18, 0.45) endingColor:Barva(0.35, 0.56, 0.95)]
        drawInRect:NSMakeRect(NSMinX(ipad) + 6, NSMinY(ipad) + 4, ipad.size.width - 12, ipad.size.height - 8) angle:-90];
    [[NSColor colorWithWhite:0.45 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMaxX(ipad) - 5, NSMidY(ipad) - 1.5, 3, 3)] fill];

    [self.jmeno ?: @"iPad" drawInRect:NSMakeRect(68, 7, w - 76, 18)
                       withAttributes:@{NSFontAttributeName: Pismo(13, YES), NSForegroundColorAttributeName: NSColor.labelColor}];
    [self.popis ?: @"" drawInRect:NSMakeRect(68, 25, w - 76, 16)
                   withAttributes:@{NSFontAttributeName: Pismo(11, NO), NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
    if (self.baterie > 100) return;
    // baterie: obrys, nabiti barvou podle stavu, blesk pri nabijeni
    NSRect b = NSMakeRect(68, 45, 24, 11);
    NSBezierPath *obrys = [NSBezierPath bezierPathWithRoundedRect:b xRadius:2.5 yRadius:2.5];
    [NSColor.secondaryLabelColor setStroke];
    obrys.lineWidth = 1;
    [obrys stroke];
    [NSColor.secondaryLabelColor setFill];
    NSRectFill(NSMakeRect(NSMaxX(b) + 0.5, NSMidY(b) - 2.5, 2, 5));
    NSColor *barva = self.baterie <= 10 ? NSColor.systemRedColor : self.baterie <= 20 ? NSColor.systemOrangeColor : NSColor.systemGreenColor;
    [barva setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(b.origin.x + 2, b.origin.y + 2, (b.size.width - 4) * self.baterie / 100.0, b.size.height - 4)
                                     xRadius:1 yRadius:1] fill];
    if (self.stav == BaterieNabiji) {
        NSBezierPath *blesk = [NSBezierPath bezierPath];
        [blesk moveToPoint:NSMakePoint(NSMidX(b) + 2, NSMinY(b) - 1)];
        [blesk lineToPoint:NSMakePoint(NSMidX(b) - 4, NSMidY(b) + 1)];
        [blesk lineToPoint:NSMakePoint(NSMidX(b) - 0.5, NSMidY(b) + 1)];
        [blesk lineToPoint:NSMakePoint(NSMidX(b) - 2, NSMaxY(b) + 1)];
        [blesk lineToPoint:NSMakePoint(NSMidX(b) + 4, NSMidY(b) - 1)];
        [blesk lineToPoint:NSMakePoint(NSMidX(b) + 0.5, NSMidY(b) - 1)];
        [blesk closePath];
        [NSColor.whiteColor setFill];
        [blesk fill];
        [[NSColor colorWithWhite:0 alpha:0.6] setStroke];
        blesk.lineWidth = 0.6;
        [blesk stroke];
    }
    NSString *text = [NSString stringWithFormat:@"%d %%", self.baterie];
    if (self.stav == BaterieNabiji) text = [text stringByAppendingFormat:@"  ·  %@", NSLocalizedString(@"Charging", nil)];
    else if (self.stav == BaterieNabito) text = [text stringByAppendingFormat:@"  ·  %@", NSLocalizedString(@"Charged", nil)];
    [text drawInRect:NSMakeRect(100, 42, w - 108, 16)
      withAttributes:@{NSFontAttributeName: Pismo(11, NO), NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
}
@end

// Hlaseni uprostred dole na obrazovce jako hlasitost v Mac OS X: pruhledny cerny ctverec, bila znacka a text
typedef NS_ENUM(NSInteger, OSZnacka) { OSZnackaIPad, OSZnackaOdpojeno, OSZnackaOko, OSZnackaTouchpad };

@interface OSOznameniPohled : NSView
@property (nonatomic, copy) NSString *nadpis, *podnadpis;
@property (nonatomic) OSZnacka znacka;
@end

@implementation OSOznameniPohled
- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)oblast {
    [[NSColor colorWithWhite:0 alpha:0.7] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:22 yRadius:22] fill];
    [NSColor.whiteColor set];
    NSRect z = NSMakeRect(52, 24, 96, 76);
    if (self.znacka == OSZnackaIPad || self.znacka == OSZnackaOdpojeno) {
        NSBezierPath *telo = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(z, 3, 6) xRadius:10 yRadius:10];
        telo.lineWidth = 5;
        [telo stroke];
        [[NSColor colorWithWhite:1 alpha:0.3] setFill];
        NSRectFillUsingOperation(NSInsetRect(z, 17, 17), NSCompositingOperationSourceOver);
        [NSColor.whiteColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMaxX(z) - 13, NSMidY(z) - 3.5, 7, 7)] fill];
        if (self.znacka == OSZnackaOdpojeno) { // preskrtnuty iPad
            NSBezierPath *cara = [NSBezierPath bezierPath];
            [cara moveToPoint:NSMakePoint(NSMinX(z) - 2, NSMaxY(z) + 2)];
            [cara lineToPoint:NSMakePoint(NSMaxX(z) + 2, NSMinY(z) - 2)];
            cara.lineWidth = 6;
            cara.lineCapStyle = NSLineCapStyleRound;
            [cara stroke];
        }
    } else if (self.znacka == OSZnackaOko) {
        NSBezierPath *oko = [NSBezierPath bezierPath];
        [oko moveToPoint:NSMakePoint(NSMinX(z), NSMidY(z))];
        [oko curveToPoint:NSMakePoint(NSMaxX(z), NSMidY(z)) controlPoint1:NSMakePoint(NSMinX(z) + 25, NSMinY(z) - 6)
             controlPoint2:NSMakePoint(NSMaxX(z) - 25, NSMinY(z) - 6)];
        [oko curveToPoint:NSMakePoint(NSMinX(z), NSMidY(z)) controlPoint1:NSMakePoint(NSMaxX(z) - 25, NSMaxY(z) + 6)
             controlPoint2:NSMakePoint(NSMinX(z) + 25, NSMaxY(z) + 6)];
        oko.lineWidth = 5;
        [oko stroke];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(z) - 17, NSMidY(z) - 17, 34, 34)] fill];
        [[NSColor colorWithWhite:0.1 alpha:1] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(NSMidX(z) - 7, NSMidY(z) - 7, 14, 14)] fill];
    } else { // touchpad pod klavesnici
        for (int y = 0; y < 2; y++)
            for (int x = 0; x < 6; x++)
                [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(z) + 4 + x * 15.3, NSMinY(z) + y * 15, 12, 11) xRadius:2.5 yRadius:2.5] fill];
        NSBezierPath *plocha = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMidX(z) - 26, NSMinY(z) + 36, 52, 38) xRadius:5 yRadius:5];
        plocha.lineWidth = 4;
        [plocha stroke];
    }
    NSMutableParagraphStyle *stred = [[NSMutableParagraphStyle alloc] init];
    stred.alignment = NSTextAlignmentCenter;
    [self.nadpis drawInRect:NSMakeRect(8, 116, 184, 22) withAttributes:@{NSFontAttributeName: Pismo(15, YES),
        NSForegroundColorAttributeName: NSColor.whiteColor, NSParagraphStyleAttributeName: stred}];
    [self.podnadpis ?: @"" drawInRect:NSMakeRect(8, 142, 184, 40) withAttributes:@{NSFontAttributeName: Pismo(12, NO),
        NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.7], NSParagraphStyleAttributeName: stred}];
}
@end

@interface OSOznameni : NSObject
+ (void)ukazNadpis:(NSString *)nadpis podnadpis:(NSString *)podnadpis znacka:(OSZnacka)znacka;
@end

@implementation OSOznameni
static NSPanel *gOkno;
static NSUInteger gGenerace; // novejsi hlaseni prepise starsi, at ho to nezhasne driv

+ (void)ukazNadpis:(NSString *)nadpis podnadpis:(NSString *)podnadpis znacka:(OSZnacka)znacka {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gOkno) {
            gOkno = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 200, 200)
                                               styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                 backing:NSBackingStoreBuffered defer:NO];
            gOkno.opaque = NO;
            gOkno.backgroundColor = NSColor.clearColor;
            gOkno.hasShadow = NO;
            gOkno.ignoresMouseEvents = YES;
            gOkno.releasedWhenClosed = NO;
            gOkno.level = NSPopUpMenuWindowLevel;
            gOkno.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary
                                     | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
            gOkno.contentView = [[OSOznameniPohled alloc] initWithFrame:NSMakeRect(0, 0, 200, 200)];
        }
        OSOznameniPohled *pohled = (OSOznameniPohled *)gOkno.contentView;
        pohled.nadpis = nadpis;
        pohled.podnadpis = podnadpis;
        pohled.znacka = znacka;
        [pohled setNeedsDisplay:YES];
        NSRect obrazovka = NSScreen.mainScreen.frame;
        [gOkno setFrameOrigin:NSMakePoint(NSMidX(obrazovka) - 100, NSMinY(obrazovka) + obrazovka.size.height * 0.16)];
        gOkno.alphaValue = 1;
        [gOkno orderFrontRegardless];
        NSUInteger generace = ++gGenerace;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generace != gGenerace) return;
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext *k) {
                k.duration = 0.45;
                gOkno.animator.alphaValue = 0;
            } completionHandler:^{
                if (generace == gGenerace) [gOkno orderOut:nil];
            }];
        });
    });
}
@end

// Nabidka jazyku: kod .lproj a nazev v tom jazyce (prvni = podle systemu)
static NSString *const kJazyky[][2] = {
    { @"", @"" }, { @"cs", @"Čeština" }, { @"sk", @"Slovenčina" }, { @"en", @"English" }, { @"de", @"Deutsch" },
    { @"pl", @"Polski" }, { @"fr", @"Français" }, { @"es", @"Español" }, { @"it", @"Italiano" }, { @"pt", @"Português" },
    { @"nl", @"Nederlands" }, { @"ru", @"Русский" }, { @"uk", @"Українська" }, { @"ja", @"日本語" }, { @"zh-Hans", @"简体中文" },
};
#define POCET_JAZYKU 15

#pragma mark - Aplikace

@interface OSDisplej : NSObject <NSApplicationDelegate, NSMenuDelegate, SCStreamOutput, SCStreamDelegate>
- (void)restartujSnimani;
@end

// macOS hlasi zmenu displeje (rozliseni, jiny hlavni monitor): snimat znovu s novou velikosti
static void ZmenaDispleje(CGDirectDisplayID displej, CGDisplayChangeSummaryFlags priznaky, void *aplikace) {
    if (priznaky & kCGDisplayBeginConfigurationFlag) return;
    [(__bridge OSDisplej *)aplikace restartujSnimani];
}

@implementation OSDisplej {
    NSStatusItem *_ikona;
    NSMenuItem *_stav, *_poPrihlaseni;
    NSMenu *_rozliseni;
    OSPruvodce *_pruvodce;
    dispatch_queue_t _fronta;       // vse kolem spojeni bezi na teto fronte
    dispatch_queue_t _vstup;        // ovladani z iPadu zvlast, at kurzor neceka na odeslani snimku
    dispatch_source_t _casovac;
    int _ipad;                      // socket k iPadu, -1 = nepripojen
    uint32_t _sirka, _vyska;
    CGDirectDisplayID _displej;     // zrcadlena obrazovka Macu (hlavni)
    CGRect _obraz;                  // kam na displeji iPadu pada obrazovka Macu, zbytek jsou cerne pruhy
    SCStream *_snimani;
    CVPixelBufferRef _cekajici;     // nejnovejsi snimek, ktery jeste nesel na iPad
    BOOL _ipadZpracovava;           // iPad jeste nepotvrdil predchozi snimek
    NSTimeInterval _dvojklik, _casPolozeni;
    CGPoint _mistoPolozeni, _polozeniNaIPadu;
    int _pocetKliku;
    BOOL _tahne;
    BOOL _obrazovkaSpi;             // displej Macu je zhasnuty (Mac sam bezi)
    uint32_t _rezim;                // co si na iPadu vybrali: RezimObrazovka / RezimOvladani (0 = starsi iPad)
    BOOL _tlacitkoDole;             // iPad drzi leve tlacitko (tazeni)
    CGEventFlags _flagyTazeni;      // ⌘ ⌥ ⌃ ⇧ platne po dobu tazeni
    NSMenuItem *_ipadPolozka;       // karta iPadu v menu (jmeno, model, baterie), jen kdyz je pripojeny
    OSKartaIPadu *_karta;
}

- (void)applicationDidFinishLaunching:(NSNotification *)oznameni {
    _ikona = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    _ikona.button.image = [NSImage imageWithSystemSymbolName:@"ipad.landscape" accessibilityDescription:@"Older Sidecar"];
    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;
    NSMenuItem *zahlavi = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    zahlavi.view = ZahlaviMenu();
    [menu addItem:[NSMenuItem separatorItem]];
    _stav = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _stav.enabled = NO;
    _karta = [[OSKartaIPadu alloc] initWithFrame:NSMakeRect(0, 0, 280, 64)];
    _ipadPolozka = [menu addItemWithTitle:@"" action:nil keyEquivalent:@""];
    _ipadPolozka.view = _karta;
    _ipadPolozka.hidden = YES; // ukaze se, az iPad posle sve jmeno
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"Setup…", nil) action:@selector(ukazPruvodce) keyEquivalent:@","].target = self;
    // mensi rozliseni = vetsi pismo i ovladaci prvky na Macu i na iPadu
    _rozliseni = [[NSMenu alloc] init];
    _rozliseni.delegate = self;
    [menu addItemWithTitle:NSLocalizedString(@"Mac Resolution", nil) action:nil keyEquivalent:@""].submenu = _rozliseni;
    _poPrihlaseni = [menu addItemWithTitle:NSLocalizedString(@"Open at Login", nil) action:@selector(prepniSpousteni:) keyEquivalent:@""];
    _poPrihlaseni.target = self;
    // jazyk appky: vlastni volba, nebo podle systemu (prelozene texty se nactou pri spusteni)
    NSMenu *jazyky = [[NSMenu alloc] init];
    NSArray *vlastni = [[NSUserDefaults standardUserDefaults] persistentDomainForName:[NSBundle mainBundle].bundleIdentifier][@"AppleLanguages"];
    NSString *soucasny = vlastni.count ? vlastni.firstObject : @"";
    for (int i = 0; i < POCET_JAZYKU; i++) {
        NSMenuItem *polozka = [jazyky addItemWithTitle:i == 0 ? NSLocalizedString(@"Automatic (system language)", nil) : kJazyky[i][1]
                                                action:@selector(zmenJazyk:) keyEquivalent:@""];
        polozka.target = self;
        polozka.tag = i;
        BOOL vybrany = i == 0 ? !soucasny.length : soucasny.length && [soucasny hasPrefix:kJazyky[i][0]];
        polozka.state = vybrany ? NSControlStateValueOn : NSControlStateValueOff;
        if (i == 0) [jazyky addItem:[NSMenuItem separatorItem]];
    }
    [menu addItemWithTitle:NSLocalizedString(@"Language", nil) action:nil keyEquivalent:@""].submenu = jazyky;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:NSLocalizedString(@"Quit Older Sidecar", nil) action:@selector(terminate:) keyEquivalent:@"q"];
    _ikona.menu = menu;
    _pruvodce = [[OSPruvodce alloc] init];
    [self nastavStav:NSLocalizedString(@"Waiting for the iPad", nil) kontrolka:OSKontrolkaSeda];

    // Pri prvnim spusteni se spousteni po prihlaseni zapne samo, pak plati volba v menu.
    // Pri kazdem spusteni se agent zapise znovu, kdyby se aplikace mezitim presunula.
    NSUserDefaults *volby = [NSUserDefaults standardUserDefaults];
    [self nastavSpousteni:![volby boolForKey:@"SpousteniNastaveno"] || [[NSFileManager defaultManager] fileExistsAtPath:CestaAgenta()]];
    [volby setBool:YES forKey:@"SpousteniNastaveno"];

    // Chybi-li povoleni (Nahravani obrazovky pro obraz, Zpristupneni pro dotyk), provede jimi pruvodce
    if (!CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted()) [self ukazPruvodce];

    CGDisplayRegisterReconfigurationCallback(ZmenaDispleje, (__bridge void *)self);
    NSNotificationCenter *spanek = [NSWorkspace sharedWorkspace].notificationCenter;
    [spanek addObserver:self selector:@selector(macUsina:) name:NSWorkspaceWillSleepNotification object:nil];
    [spanek addObserver:self selector:@selector(obrazovkaUsnula:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [spanek addObserver:self selector:@selector(obrazovkaSeProbudila:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    _dvojklik = [NSEvent doubleClickInterval];
    _ipad = -1;
    _fronta = dispatch_queue_create("ipad", DISPATCH_QUEUE_SERIAL);
    _vstup = dispatch_queue_create("ovladani", DISPATCH_QUEUE_SERIAL);
    _casovac = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _fronta);
    dispatch_source_set_timer(_casovac, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(_casovac, ^{ [self zkusPripojit]; });
    dispatch_resume(_casovac);
}

- (void)nastavStav:(NSString *)text kontrolka:(OSKontrolka)kontrolka {
    NSLog(@"%@", text);
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_stav.title = text;
        self->_stav.image = Kontrolka(kontrolka, 14);
    });
}

- (void)ukazPruvodce {
    [_pruvodce ukaz];
}

- (void)oznamPripojeni:(BOOL)pripojen {
    dispatch_async(dispatch_get_main_queue(), ^{ self->_pruvodce.ipadPripojen = pripojen; });
}

// Jazyk se nacita pri spusteni: ulozit volbu a appku znovu spustit (iPad se na chvili odpoji a zase pripoji)
- (void)zmenJazyk:(NSMenuItem *)polozka {
    NSString *kod = kJazyky[polozka.tag][0];
    NSUserDefaults *volby = [NSUserDefaults standardUserDefaults];
    if (kod.length) [volby setObject:@[kod] forKey:@"AppleLanguages"];
    else [volby removeObjectForKey:@"AppleLanguages"];
    [volby synchronize];
    NSTask *znovu = [[NSTask alloc] init];
    znovu.launchPath = @"/bin/sh";
    znovu.arguments = @[@"-c", @"sleep 1; /usr/bin/open \"$0\"", [NSBundle mainBundle].bundlePath];
    [znovu launch];
    [NSApp terminate:nil];
}

- (void)prepniSpousteni:(NSMenuItem *)polozka {
    [self nastavSpousteni:polozka.state != NSControlStateValueOn];
}

// Spousteni po prihlaseni = LaunchAgent v ~/Library/LaunchAgents (funguje uz od macOS 12).
- (void)nastavSpousteni:(BOOL)zapnout {
    NSString *program = [NSBundle mainBundle].executablePath;
    if (zapnout && [program containsString:@"/AppTranslocation/"]) {
        // macOS spousti stazenou aplikaci z docasneho mista, ktere po restartu zmizi
        [self nastavStav:NSLocalizedString(@"Move Older Sidecar to the Applications folder", nil) kontrolka:OSKontrolkaOranzova];
        zapnout = NO;
    } else if (zapnout) {
        [[NSFileManager defaultManager] createDirectoryAtPath:CestaAgenta().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDictionary *agent = @{@"Label": AGENT,
                                @"ProgramArguments": @[program],
                                @"RunAtLoad": @YES,
                                @"LimitLoadToSessionType": @"Aqua",
                                @"ProcessType": @"Interactive"};
        [agent writeToURL:[NSURL fileURLWithPath:CestaAgenta()] error:NULL];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:CestaAgenta() error:NULL];
    }
    _poPrihlaseni.state = zapnout ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)zkusPripojit {
    if (_ipad >= 0) { // pripojeno: jen dat vedet, ze Mac zije
        uint32_t zivot[2] = { htonl(ZpravaZivot), 0 };
        if (!PisVse(_ipad, zivot, sizeof zivot)) shutdown(_ipad, SHUT_RDWR);
        return;
    }
    int s = PripojIPad(PORT);
    if (s < 0) return;
    _ipad = s;
    _ipadZpracovava = NO;
    [NSThread detachNewThreadSelector:@selector(ctiZIPadu:) toTarget:self withObject:@(s)];
}

- (void)ctiZIPadu:(NSNumber *)cislo {
    int s = cislo.intValue;
    for (;;) @autoreleasepool {
        uint32_t h[2];
        if (!CtiVse(s, h, sizeof h)) break;
        uint32_t typ = ntohl(h[0]), delka = ntohl(h[1]);
        if (delka > 4096) break;
        NSMutableData *data = [NSMutableData dataWithLength:delka];
        if (!CtiVse(s, data.mutableBytes, delka)) break;
        if (typ == ZpravaText || typ == ZpravaZkratka) { // text z klavesnice iPadu, pripadne s ⌘ ⌥ ⌃ ⇧
            uint32_t mod = 0;
            NSUInteger od = 0;
            if (typ == ZpravaZkratka && delka >= 4) { memcpy(&mod, data.bytes, 4); mod = ntohl(mod); od = 4; }
            NSString *text = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(od, delka - od)] encoding:NSUTF8StringEncoding];
            if (text) dispatch_async(_vstup, ^{ [self napis:text modifikatory:mod]; });
            continue;
        }
        if (typ == ZpravaInfo) { // jmeno, model a iOS do menu
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (text) dispatch_async(dispatch_get_main_queue(), ^{ [self ukazInfo:text]; });
            continue;
        }
        uint32_t d[3] = {0};
        memcpy(d, data.bytes, MIN(delka, sizeof d));
        uint32_t a = ntohl(d[0]), b = ntohl(d[1]), c = ntohl(d[2]);
        BOOL ovladani = typ == ZpravaRezim || (typ >= ZpravaPohyb && typ <= ZpravaKlavesa);
        if (ovladani) dispatch_async(_vstup, ^{ [self ovladani:typ a:a b:b c:c]; });
        else dispatch_async(_fronta, ^{ [self zprava:typ a:a b:b c:c]; });
    }
    dispatch_async(_fronta, ^{ [self odpoj:s]; });
}

- (void)zprava:(uint32_t)typ a:(uint32_t)a b:(uint32_t)b c:(uint32_t)c {
    if (typ == ZpravaAhoj) {
        if (_snimani || a == 0 || b == 0 || a > 4096 || b > 4096) return;
        _sirka = a;
        _vyska = b;
        [self spustSnimani];
        [self oznamPripojeni:YES];
        [OSOznameni ukazNadpis:NSLocalizedString(@"iPad connected", nil) podnadpis:nil znacka:OSZnackaIPad];
        if (_rezim) [self ukazRezim]; // iPad uz rekl, jestli se jen diva, nebo ovlada
        else if (AXIsProcessTrusted()) [self nastavStav:NSLocalizedString(@"iPad connected", nil) kontrolka:OSKontrolkaZelena];
        else [self nastavStav:NSLocalizedString(@"iPad connected – touch needs the Accessibility permission", nil) kontrolka:OSKontrolkaOranzova];
    } else if (typ == ZpravaHotovo) {
        _ipadZpracovava = NO;
        if (_cekajici) [self posliSnimek];
    } else if (typ == ZpravaDotyk) { // starsi iPad: tuknuti primo do obrazu
        [self dotykFaze:a x:b y:c];
    } else if (typ == ZpravaBaterie) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_karta.baterie = (int)a;
            self->_karta.stav = b;
            [self->_karta setNeedsDisplay:YES];
        });
    }
}

// bezi na fronte _vstup
- (void)ovladani:(uint32_t)typ a:(uint32_t)a b:(uint32_t)b c:(uint32_t)c {
    if (typ == ZpravaRezim) {
        _rezim = a;
        [self ukazRezim];
        if (_rezim) dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ovladani = self->_rezim == RezimOvladani;
            [OSOznameni ukazNadpis:ovladani ? NSLocalizedString(@"Remote control", nil) : NSLocalizedString(@"Screen only", nil)
                         podnadpis:self->_karta.jmeno znacka:ovladani ? OSZnackaTouchpad : OSZnackaOko];
        });
        // ovladani = jen touchpad a tlacitka, obraz se neposila; jen obrazovka = snimat
        dispatch_async(_fronta, ^{
            if (self->_rezim == RezimOvladani) {
                [self->_snimani stopCaptureWithCompletionHandler:^(NSError *chyba) {}];
                self->_snimani = nil;
                if (self->_cekajici) {
                    CVPixelBufferRelease(self->_cekajici);
                    self->_cekajici = NULL;
                }
            } else if (self->_ipad >= 0 && !self->_snimani) {
                [self spustSnimani];
            }
        });
        return;
    }
    if (_rezim != RezimOvladani) return; // v rezimu "jen obrazovka" iPad Mac neovlada
    // Zhasnuty displej: pohyb, klik ani psani nic neudela, jen ho probudi. Hudba a hlasitost jdou i potme.
    BOOL hudba = typ == ZpravaKlavesa && a >= KlavesaPrehrat && a <= KlavesaZtlumit;
    if (_obrazovkaSpi && !hudba) {
        [self probudDisplej];
        return;
    }
    if (typ == ZpravaPohyb) [self pohniX:(int32_t)a y:(int32_t)b];
    else if (typ == ZpravaKlik) [self klikni:a pocet:b flagy:Flagy(c)];
    else if (typ == ZpravaTlacitko) [self drzTlacitko:b != 0 flagy:Flagy(c)];
    else if (typ == ZpravaKolecko) [self posunX:(int32_t)a y:(int32_t)b];
    else if (typ == ZpravaKlavesa) [self klavesa:a flagy:Flagy(b)];
}

#pragma mark - Ovladani z iPadu (touchpad, klavesnice, hudba)

// V liste je videt, jestli se z iPadu jen diva, nebo Mac ovlada
- (void)ukazRezim {
    if (!_rezim) { // iPad je zpatky v menu
        [self nastavStav:NSLocalizedString(@"iPad connected", nil) kontrolka:OSKontrolkaZelena];
        [self ukazIkonu:@"ipad.landscape"];
        return;
    }
    BOOL ovladani = _rezim == RezimOvladani;
    if (ovladani && !AXIsProcessTrusted())
        [self nastavStav:NSLocalizedString(@"iPad connected – control needs the Accessibility permission", nil) kontrolka:OSKontrolkaOranzova];
    else
        [self nastavStav:ovladani ? NSLocalizedString(@"iPad connected – remote control", nil)
                                  : NSLocalizedString(@"iPad connected – screen only", nil) kontrolka:OSKontrolkaZelena];
    [self ukazIkonu:ovladani ? @"hand.tap" : @"ipad.landscape"];
}

// Jmeno, model a iOS z iPadu (radky oddelene \n) -> karta v menu
- (void)ukazInfo:(NSString *)text {
    NSArray *radky = [text componentsSeparatedByString:@"\n"];
    _karta.jmeno = radky.count > 0 ? radky[0] : @"iPad";
    _karta.popis = radky.count > 2 ? [NSString stringWithFormat:@"%@  ·  %@", radky[1], radky[2]] : radky.count > 1 ? radky[1] : @"";
    [_karta setNeedsDisplay:YES];
    _ipadPolozka.hidden = NO;
}

- (void)ukazIkonu:(NSString *)symbol {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_ikona.button.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@"Older Sidecar"]
                                 ?: [NSImage imageWithSystemSymbolName:@"ipad.landscape" accessibilityDescription:@"Older Sidecar"];
    });
}

static CGPoint KdeJeMys(void) {
    CGEventRef udalost = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(udalost);
    CFRelease(udalost);
    return p;
}

static CGRect VsechnyDispleje(void) {
    CGDirectDisplayID displeje[16];
    uint32_t pocet = 0;
    CGGetActiveDisplayList(16, displeje, &pocet);
    CGRect r = CGRectNull;
    for (uint32_t i = 0; i < pocet; i++) r = CGRectUnion(r, CGDisplayBounds(displeje[i]));
    return r;
}

// ⌘ ⌥ ⌃ ⇧ zapnute na iPadu -> priznaky udalosti
static CGEventFlags Flagy(uint32_t m) {
    CGEventFlags f = 0;
    if (m & ModCmd) f |= kCGEventFlagMaskCommand;
    if (m & ModAlt) f |= kCGEventFlagMaskAlternate;
    if (m & ModCtrl) f |= kCGEventFlagMaskControl;
    if (m & ModShift) f |= kCGEventFlagMaskShift;
    return f;
}

- (void)mys:(CGEventType)typ tlacitko:(CGMouseButton)tlacitko bod:(CGPoint)p pocet:(int64_t)pocet flagy:(CGEventFlags)flagy {
    CGEventRef udalost = CGEventCreateMouseEvent(NULL, typ, p, tlacitko);
    CGEventSetIntegerValueField(udalost, kCGMouseEventClickState, pocet);
    if (flagy) CGEventSetFlags(udalost, flagy);
    CGEventPost(kCGHIDEventTap, udalost);
    CFRelease(udalost);
}

- (void)pohniX:(int32_t)dx y:(int32_t)dy {
    CGRect plocha = VsechnyDispleje();
    CGPoint p = KdeJeMys();
    p.x = MIN(MAX(p.x + dx, CGRectGetMinX(plocha)), CGRectGetMaxX(plocha) - 1);
    p.y = MIN(MAX(p.y + dy, CGRectGetMinY(plocha)), CGRectGetMaxY(plocha) - 1);
    [self mys:_tlacitkoDole ? kCGEventLeftMouseDragged : kCGEventMouseMoved tlacitko:kCGMouseButtonLeft bod:p pocet:1
         flagy:_tlacitkoDole ? _flagyTazeni : 0];
}

- (void)klikni:(uint32_t)tlacitko pocet:(uint32_t)pocet flagy:(CGEventFlags)flagy {
    BOOL prave = tlacitko == 1;
    CGPoint p = KdeJeMys();
    int64_t kolikrat = MAX(pocet, 1u);
    CGMouseButton t = prave ? kCGMouseButtonRight : kCGMouseButtonLeft;
    [self mys:prave ? kCGEventRightMouseDown : kCGEventLeftMouseDown tlacitko:t bod:p pocet:kolikrat flagy:flagy];
    [self mys:prave ? kCGEventRightMouseUp : kCGEventLeftMouseUp tlacitko:t bod:p pocet:kolikrat flagy:flagy];
}

- (void)drzTlacitko:(BOOL)dole flagy:(CGEventFlags)flagy {
    _tlacitkoDole = dole;
    if (dole) _flagyTazeni = flagy; // napr. ⇧ + tazeni = rozsireni vyberu
    [self mys:dole ? kCGEventLeftMouseDown : kCGEventLeftMouseUp tlacitko:kCGMouseButtonLeft bod:KdeJeMys() pocet:1 flagy:_flagyTazeni];
}

- (void)posunX:(int32_t)dx y:(int32_t)dy {
    CGEventRef udalost = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, dy, dx);
    CGEventPost(kCGHIDEventTap, udalost);
    CFRelease(udalost);
}

static void Klavesa(CGKeyCode kod, CGEventFlags flagy) {
    for (int dole = 1; dole >= 0; dole--) {
        CGEventRef udalost = CGEventCreateKeyboardEvent(NULL, kod, dole);
        if (flagy) CGEventSetFlags(udalost, flagy);
        CGEventPost(kCGHIDEventTap, udalost);
        CFRelease(udalost);
    }
}

// Hudebni a hlasitostni klavesy jako na klavesnici Macu (NX_KEYTYPE_...)
static void MediaKlavesa(int klavesa) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (int dole = 1; dole >= 0; dole--) {
            NSEvent *udalost = [NSEvent otherEventWithType:NSEventTypeSystemDefined location:NSZeroPoint
                                             modifierFlags:dole ? 0xa00 : 0xb00 timestamp:0 windowNumber:0 context:nil
                                                   subtype:8 data1:(klavesa << 16) | ((dole ? 0xa : 0xb) << 8) data2:-1];
            CGEventPost(kCGHIDEventTap, udalost.CGEvent);
        }
    });
}

// Systemova appka (Mission Control, Launchpad); prvni, ktera v tomhle macOS existuje
static void OtevriSystemovouAppku(NSArray<NSString *> *jmena) {
    for (NSString *jmeno in jmena) {
        NSString *cesta = [NSString stringWithFormat:@"/System/Applications/%@.app", jmeno];
        if (![[NSFileManager defaultManager] fileExistsAtPath:cesta]) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:cesta]
                                                  configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
        });
        return;
    }
}

- (void)klavesa:(uint32_t)kod flagy:(CGEventFlags)flagy {
    switch (kod) {
        case KlavesaMazat: Klavesa(51, flagy); break; // Backspace
        case KlavesaEnter: Klavesa(36, flagy); break; // Return
        case KlavesaEsc: Klavesa(53, flagy); break;
        case KlavesaTab: Klavesa(48, flagy); break;
        case KlavesaVlevo: Klavesa(123, flagy); break;
        case KlavesaVpravo: Klavesa(124, flagy); break;
        case KlavesaDolu: Klavesa(125, flagy); break;
        case KlavesaNahoru: Klavesa(126, flagy); break;
        case KlavesaJasMene: MediaKlavesa(NX_KEYTYPE_BRIGHTNESS_DOWN); break;
        case KlavesaJasVic: MediaKlavesa(NX_KEYTYPE_BRIGHTNESS_UP); break;
        case KlavesaMissionControl: OtevriSystemovouAppku(@[@"Mission Control"]); break;
        case KlavesaLaunchpad: OtevriSystemovouAppku(@[@"Launchpad", @"Apps"]); break;
        case KlavesaZamknout: Klavesa(12, kCGEventFlagMaskControl | kCGEventFlagMaskCommand); break; // ⌃⌘Q zamkne Mac
        case KlavesaPrehrat: MediaKlavesa(NX_KEYTYPE_PLAY); break;
        case KlavesaDalsi: MediaKlavesa(NX_KEYTYPE_NEXT); break;
        case KlavesaPredchozi: MediaKlavesa(NX_KEYTYPE_PREVIOUS); break;
        case KlavesaHlasiteji: MediaKlavesa(NX_KEYTYPE_SOUND_UP); break;
        case KlavesaTiseji: MediaKlavesa(NX_KEYTYPE_SOUND_DOWN); break;
        case KlavesaZtlumit: MediaKlavesa(NX_KEYTYPE_MUTE); break;
    }
}

// Text z klavesnice iPadu: kazdy znak jako stisk klavesy s danym znakem (funguje i s hacky a carkami)
- (void)probudDisplej {
    IOPMAssertionID probuzeni;
    IOPMAssertionDeclareUserActivity(CFSTR("Older Sidecar"), kIOPMUserActiveLocal, &probuzeni);
}

- (void)napis:(NSString *)text modifikatory:(uint32_t)modifikatory {
    if (_rezim != RezimOvladani) return;
    if (_obrazovkaSpi) {
        [self probudDisplej];
        return;
    }
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *znak, NSRange r1, NSRange r2, BOOL *stop) {
        if ([znak isEqualToString:@"\n"]) { Klavesa(36, Flagy(modifikatory)); return; }
        UniChar znaky[8];
        NSUInteger pocet = MIN(znak.length, 8u);
        [znak getCharacters:znaky range:NSMakeRange(0, pocet)];
        for (int dole = 1; dole >= 0; dole--) {
            CGEventRef udalost = CGEventCreateKeyboardEvent(NULL, 0, dole);
            CGEventKeyboardSetUnicodeString(udalost, pocet, znaky);
            if (modifikatory) CGEventSetFlags(udalost, Flagy(modifikatory)); // napr. ⌘ + c = Kopirovat
            CGEventPost(kCGHIDEventTap, udalost);
            CFRelease(udalost);
        }
    }];
}

- (void)spustSnimani {
    CGDirectDisplayID cislo = CGMainDisplayID();
    [SCShareableContent getShareableContentWithCompletionHandler:^(SCShareableContent *obsah, NSError *chyba) {
        dispatch_async(self->_fronta, ^{
            // mezitim odpojeno, uz se snima, nebo iPad jen ovlada (obrazovku Macu tam neukazuje)
            if (self->_ipad < 0 || self->_snimani || self->_rezim == RezimOvladani) return;
            SCDisplay *displej = nil;
            for (SCDisplay *d in obsah.displays) if (d.displayID == cislo) displej = d;
            if (!displej) {
                NSLog(@"Snimani obrazovky: %@", chyba);
                BOOL povoleno = CGPreflightScreenCaptureAccess();
                [self nastavStav:povoleno ? NSLocalizedString(@"The screen can't be captured", nil)
                                          : NSLocalizedString(@"The Screen Recording permission is missing", nil)
                       kontrolka:OSKontrolkaOranzova];
                // at to iPad napise na obrazovku, misto aby donekonecna cekal na obraz
                uint32_t zprava[3] = { htonl(ZpravaStav), htonl(4), htonl(povoleno ? StavNejdeSnimat : StavChybiPovoleni) };
                PisVse(self->_ipad, zprava, sizeof zprava);
                if (!povoleno) dispatch_async(dispatch_get_main_queue(), ^{ [self ukazPruvodce]; });
                return;
            }
            // Obrazovka Macu zmensena do displeje iPadu se zachovanim pomeru stran, uprostred
            CGRect plocha = CGDisplayBounds(cislo);
            CGFloat meritko = MIN(self->_sirka / plocha.size.width, self->_vyska / plocha.size.height);
            size_t w = (size_t)(plocha.size.width * meritko) & ~1, h = (size_t)(plocha.size.height * meritko) & ~1;
            self->_displej = cislo;
            self->_obraz = CGRectMake((self->_sirka - w) / 2, (self->_vyska - h) / 2, w, h);

            SCContentFilter *filtr = [[SCContentFilter alloc] initWithDisplay:displej excludingWindows:@[]];
            SCStreamConfiguration *nastaveni = [[SCStreamConfiguration alloc] init];
            nastaveni.width = w;
            nastaveni.height = h;
            nastaveni.minimumFrameInterval = CMTimeMake(1, 30);
            nastaveni.pixelFormat = kCVPixelFormatType_32BGRA;
            nastaveni.colorSpaceName = kCGColorSpaceSRGB;
            nastaveni.showsCursor = YES;
            nastaveni.queueDepth = 4;
            self->_snimani = [[SCStream alloc] initWithFilter:filtr configuration:nastaveni delegate:self];
            [self->_snimani addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_fronta error:NULL];
            [self->_snimani startCaptureWithCompletionHandler:^(NSError *chyba) {
                if (chyba) NSLog(@"Snimani nejde spustit: %@", chyba);
            }];
        });
    }];
}

- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)vzorek ofType:(SCStreamOutputType)typ {
    if (typ != SCStreamOutputTypeScreen || stream != _snimani || _obrazovkaSpi) return; // zhasnuty displej neposilat
    CFArrayRef prilohy = CMSampleBufferGetSampleAttachmentsArray(vzorek, NO);
    if (!prilohy || CFArrayGetCount(prilohy) == 0) return;
    NSDictionary *info = (__bridge NSDictionary *)CFArrayGetValueAtIndex(prilohy, 0);
    if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return; // obraz se nezmenil
    CVPixelBufferRef snimek = CMSampleBufferGetImageBuffer(vzorek);
    if (!snimek) return;
    if (_cekajici) CVPixelBufferRelease(_cekajici);
    _cekajici = CVPixelBufferRetain(snimek);
    if (!_ipadZpracovava) [self posliSnimek];
}

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)chyba {
    NSLog(@"Snimani skoncilo: %@", chyba);
    // napr. po probuzeni displeje; jen pro aktualni snimani, ne pro to, ktere jsme sami zastavili
    dispatch_async(_fronta, ^{ if (stream == self->_snimani) [self restartujSnimani]; });
}

#pragma mark - Spanek Macu

// pise se na _fronte, stejne jako snimky
- (void)posliStav:(uint32_t)stav {
    if (_ipad < 0) return;
    uint32_t zprava[3] = { htonl(ZpravaStav), htonl(4), htonl(stav) };
    if (!PisVse(_ipad, zprava, sizeof zprava)) shutdown(_ipad, SHUT_RDWR);
}

// Cely Mac jde spat: rict to iPadu a spojeni ukoncit. Po probuzeni ho casovac navaze znovu.
- (void)macUsina:(NSNotification *)oznameni {
    dispatch_sync(_fronta, ^{
        [self posliStav:StavMacSpi];
        if (self->_ipad >= 0) shutdown(self->_ipad, SHUT_RDWR);
    });
}

// Zhasl jen displej: iPad to napise, tuknuti na nem displej probudi
- (void)obrazovkaUsnula:(NSNotification *)oznameni {
    dispatch_async(_fronta, ^{
        self->_obrazovkaSpi = YES;
        [self posliStav:StavObrazovkaSpi];
    });
}

- (void)obrazovkaSeProbudila:(NSNotification *)oznameni {
    dispatch_async(_fronta, ^{
        self->_obrazovkaSpi = NO;
        [self posliStav:StavProbuzeno]; // iPad smaze hlaseni "obrazovka spi" (v rezimu ovladani neprijde obraz, ktery by ho smazal)
    });
    [self restartujSnimani];
}

- (void)posliSnimek {
    CVPixelBufferRef snimek = _cekajici;
    _cekajici = NULL;
    NSData *jpeg = JPEGZeSnimku(snimek, _sirka, _vyska, _obraz);
    CVPixelBufferRelease(snimek);
    if (!jpeg || _ipad < 0) return;
    uint32_t h[2] = { htonl(ZpravaSnimek), htonl((uint32_t)jpeg.length) };
    if (!PisVse(_ipad, h, sizeof h) || !PisVse(_ipad, jpeg.bytes, jpeg.length)) {
        shutdown(_ipad, SHUT_RDWR); // cteci vlakno to pozna a zavola odpoj:
        return;
    }
    _ipadZpracovava = YES;
}

- (void)dotykFaze:(uint32_t)faze x:(uint32_t)x y:(uint32_t)y {
    if (_obrazovkaSpi) { // tuknuti jen probudi displej, nikam neklikne
        IOPMAssertionID probuzeni;
        IOPMAssertionDeclareUserActivity(CFSTR("Older Sidecar"), kIOPMUserActiveLocal, &probuzeni);
        return;
    }
    if (!_snimani) return;
    // bod na iPadu -> bod na obrazovce Macu (dotyk v cernem pruhu = okraj obrazovky)
    CGRect plocha = CGDisplayBounds(_displej);
    CGFloat fx = MIN(MAX((x - _obraz.origin.x) / _obraz.size.width, 0), 1);
    CGFloat fy = MIN(MAX((y - _obraz.origin.y) / _obraz.size.height, 0), 1);
    CGPoint p = CGPointMake(plocha.origin.x + fx * (plocha.size.width - 1), plocha.origin.y + fy * (plocha.size.height - 1));
    CGPoint naIPadu = CGPointMake(x, y); // vzdalenosti prstu se meri na iPadu
    CGEventType typ;
    if (faze == 0) {
        // dve rychla tuknuti na stejne misto = dvojklik
        NSTimeInterval ted = [NSDate timeIntervalSinceReferenceDate];
        BOOL blizko = hypot(naIPadu.x - _polozeniNaIPadu.x, naIPadu.y - _polozeniNaIPadu.y) < 15;
        _pocetKliku = (ted - _casPolozeni < _dvojklik && blizko) ? _pocetKliku + 1 : 1;
        _casPolozeni = ted;
        _mistoPolozeni = p;
        _polozeniNaIPadu = naIPadu;
        _tahne = NO;
        typ = kCGEventLeftMouseDown;
    } else if (faze == 1) {
        // prst se pri tuknuti trochu hne, to jeste neni tazeni
        if (!_tahne && hypot(naIPadu.x - _polozeniNaIPadu.x, naIPadu.y - _polozeniNaIPadu.y) < 8) return;
        _tahne = YES;
        typ = kCGEventLeftMouseDragged;
    } else {
        if (!_tahne) p = _mistoPolozeni;
        typ = kCGEventLeftMouseUp;
    }
    CGEventRef udalost = CGEventCreateMouseEvent(NULL, typ, p, kCGMouseButtonLeft);
    CGEventSetIntegerValueField(udalost, kCGMouseEventClickState, _pocetKliku);
    CGEventPost(kCGHIDEventTap, udalost);
    CFRelease(udalost);
}

#pragma mark - Rozliseni Macu

// Nabidka se sestavi pri kazdem otevreni: jeden rezim na kazdou velikost, z nich ten s nejvic pixely (ostrejsi)
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != _rozliseni) return;
    [menu removeAllItems];
    CGDirectDisplayID displej = CGMainDisplayID();
    CGDisplayModeRef ted = CGDisplayCopyDisplayMode(displej);
    NSArray *rezimy = CFBridgingRelease(CGDisplayCopyAllDisplayModes(displej,
        (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES}));
    NSMutableDictionary *nejlepsi = [NSMutableDictionary dictionary];
    for (id r in rezimy) {
        CGDisplayModeRef m = (__bridge CGDisplayModeRef)r;
        if (!CGDisplayModeIsUsableForDesktopGUI(m)) continue;
        NSString *klic = [NSString stringWithFormat:@"%zux%zu", CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m)];
        id byl = nejlepsi[klic];
        if (!byl || CGDisplayModeGetPixelWidth(m) > CGDisplayModeGetPixelWidth((__bridge CGDisplayModeRef)byl)) nejlepsi[klic] = r;
    }
    NSArray *serazene = [nejlepsi.allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        size_t wa = CGDisplayModeGetWidth((__bridge CGDisplayModeRef)a), wb = CGDisplayModeGetWidth((__bridge CGDisplayModeRef)b);
        size_t ha = CGDisplayModeGetHeight((__bridge CGDisplayModeRef)a), hb = CGDisplayModeGetHeight((__bridge CGDisplayModeRef)b);
        if (wa != wb) return wa > wb ? NSOrderedAscending : NSOrderedDescending;
        return ha > hb ? NSOrderedAscending : ha < hb ? NSOrderedDescending : NSOrderedSame;
    }];
    for (id r in serazene) {
        CGDisplayModeRef m = (__bridge CGDisplayModeRef)r;
        int w = (int)CGDisplayModeGetWidth(m), h = (int)CGDisplayModeGetHeight(m);
        NSString *nazev = w * 3 == h * 4 ? [NSString stringWithFormat:NSLocalizedString(@"%d × %d – fills the iPad", nil), w, h]
                                         : [NSString stringWithFormat:@"%d × %d", w, h];
        NSMenuItem *polozka = [menu addItemWithTitle:nazev action:@selector(zmenRozliseni:) keyEquivalent:@""];
        polozka.target = self;
        polozka.representedObject = r;
        BOOL soucasne = w == (int)CGDisplayModeGetWidth(ted) && h == (int)CGDisplayModeGetHeight(ted);
        polozka.state = soucasne ? NSControlStateValueOn : NSControlStateValueOff;
    }
    CGDisplayModeRelease(ted);
}

- (void)zmenRozliseni:(NSMenuItem *)polozka {
    CGDisplayConfigRef nastaveni;
    if (CGBeginDisplayConfiguration(&nastaveni) != kCGErrorSuccess) return;
    CGConfigureDisplayWithDisplayMode(nastaveni, CGMainDisplayID(), (__bridge CGDisplayModeRef)polozka.representedObject, NULL);
    CGCompleteDisplayConfiguration(nastaveni, kCGConfigurePermanently);
}

- (void)restartujSnimani {
    dispatch_async(_fronta, ^{
        if (self->_ipad < 0) return; // iPad neni pripojeny, neni pro koho snimat
        [self->_snimani stopCaptureWithCompletionHandler:^(NSError *chyba) {}];
        self->_snimani = nil;
        if (self->_cekajici) {
            CVPixelBufferRelease(self->_cekajici);
            self->_cekajici = NULL;
        }
        // macOS posila pri zmene vic oznameni za sebou, at se displej nejdriv usadi
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), self->_fronta, ^{ [self spustSnimani]; });
    });
}

- (void)odpoj:(int)s {
    close(s);
    if (s != _ipad) return;
    _ipad = -1;
    _ipadZpracovava = NO;
    if (_cekajici) {
        CVPixelBufferRelease(_cekajici);
        _cekajici = NULL;
    }
    [_snimani stopCaptureWithCompletionHandler:^(NSError *chyba) {}];
    _snimani = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [OSOznameni ukazNadpis:NSLocalizedString(@"iPad disconnected", nil) podnadpis:self->_karta.jmeno znacka:OSZnackaOdpojeno];
        self->_ipadPolozka.hidden = YES;
        self->_karta.jmeno = nil;
        self->_karta.popis = nil;
        self->_karta.baterie = 999;
    });
    dispatch_async(_vstup, ^{
        if (self->_tlacitkoDole) [self drzTlacitko:NO flagy:0]; // nenechat tlacitko mysi viset
        self->_rezim = 0;
        [self ukazIkonu:@"ipad.landscape"];
    });
    [self oznamPripojeni:NO];
    [self nastavStav:NSLocalizedString(@"Waiting for the iPad", nil) kontrolka:OSKontrolkaSeda];
}
@end

int main(void) {
    signal(SIGPIPE, SIG_IGN); // odpojeny kabel nesmi aplikaci shodit
    @autoreleasepool {
        NSApplication *aplikace = [NSApplication sharedApplication];
        OSDisplej *displej = [[OSDisplej alloc] init];
        aplikace.delegate = displej;
        [aplikace setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [aplikace run];
    }
    return 0;
}
