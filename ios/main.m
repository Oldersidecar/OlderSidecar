// Older Sidecar – iPad cast. Stary iPad (iOS 6–10) zrcadli obrazovku Macu pres USB kabel.
// Aplikace posloucha na portu 7777, Mac (aplikace Older Sidecar) se k ni pripoji
// pres usbmuxd, posila snimky obrazovky jako JPEG a dostava zpet dotyky.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <sys/sysctl.h>

#define PORT 7777

// Jazyk appky: zvoleny v menu (NSUserDefaults "Jazyk", prazdny = podle iPadu). Preklad() bere texty
// z prislusneho .lproj, takze se jazyk prepne hned, bez restartu. KLIC() jen oznacuje text, ktery
// se prelozi az pri zobrazeni.
#define KLIC(text) text
static NSBundle *gPreklady;

static void NastavJazyk(NSString *kod) {
    [gPreklady release];
    NSString *cesta = kod.length ? [[NSBundle mainBundle] pathForResource:kod ofType:@"lproj"] : nil;
    gPreklady = cesta ? [[NSBundle alloc] initWithPath:cesta] : [[NSBundle mainBundle] retain];
}

static NSString *Preklad(NSString *klic) {
    if (!gPreklady) NastavJazyk([[NSUserDefaults standardUserDefaults] stringForKey:@"Jazyk"]);
    return [gPreklady localizedStringForKey:klic value:klic table:nil];
}

// Nabidka jazyku: kod .lproj a nazev v tom jazyce (prvni = automaticky)
static NSString *const kJazyky[][2] = {
    { @"", @"" }, { @"cs", @"Čeština" }, { @"sk", @"Slovenčina" }, { @"en", @"English" }, { @"de", @"Deutsch" },
    { @"pl", @"Polski" }, { @"fr", @"Français" }, { @"es", @"Español" }, { @"it", @"Italiano" }, { @"pt", @"Português" },
    { @"nl", @"Nederlands" }, { @"ru", @"Русский" }, { @"uk", @"Українська" }, { @"ja", @"日本語" }, { @"zh-Hans", @"简体中文" },
};
#define POCET_JAZYKU 15

// Zprava = hlavicka 2x uint32 (typ, delka dat) v sitovem poradi bajtu + data.
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
    ZpravaZivot = 12,   // Mac -> iPad kazde 2 s: Mac zije; kdyz prestane chodit, spojeni se ukonci
    ZpravaText = 13,    // iPad -> Mac: napsany text v UTF-8
    ZpravaInfo = 14,    // iPad -> Mac: jmeno, model a verze iOS (UTF-8, oddelene novym radkem)
    ZpravaBaterie = 15, // iPad -> Mac: baterie v % (999 = nevi se), stav (Baterie...)
    ZpravaZkratka = 16, // iPad -> Mac: Mod... (4 bajty) + text v UTF-8, napr. Cmd + c
};
enum { RezimObrazovka = 1, RezimOvladani = 2 };
enum { KlavesaMazat = 1, KlavesaEnter = 2, KlavesaEsc = 3, KlavesaTab = 4,
       KlavesaVlevo = 5, KlavesaVpravo = 6, KlavesaDolu = 7, KlavesaNahoru = 8,
       KlavesaPrehrat = 10, KlavesaDalsi = 11, KlavesaPredchozi = 12, KlavesaHlasiteji = 13, KlavesaTiseji = 14, KlavesaZtlumit = 15,
       KlavesaJasMene = 16, KlavesaJasVic = 17, KlavesaMissionControl = 18, KlavesaLaunchpad = 19, KlavesaZamknout = 20 };
// Modifikatory (zapnou se klavesou na iPadu a plati pro dalsi klavesu, text nebo klik)
enum { ModCmd = 1, ModAlt = 2, ModCtrl = 4, ModShift = 8 };
enum { BaterieNevi = 0, BaterieNaBaterii = 1, BaterieNabiji = 2, BaterieNabito = 3 };
enum { StavChybiPovoleni = 1, StavNejdeSnimat = 2, StavObrazovkaSpi = 3, StavMacSpi = 4, StavProbuzeno = 5 };

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

// Rozbali JPEG uz tady na pozadi, jinak by to brzdilo hlavni vlakno pri kresleni.
static CGImageRef RozbalJPEG(NSData *data) {
    CGDataProviderRef zdroj = CGDataProviderCreateWithCFData((CFDataRef)data);
    CGImageRef jpeg = CGImageCreateWithJPEGDataProvider(zdroj, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(zdroj);
    if (!jpeg) return NULL;
    size_t w = CGImageGetWidth(jpeg), h = CGImageGetHeight(jpeg);
    CGColorSpaceRef barvy = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, w * 4, barvy, kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(barvy);
    CGContextDrawImage(c, CGRectMake(0, 0, w, h), jpeg);
    CGImageRelease(jpeg);
    CGImageRef hotovy = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return hotovy;
}

static NSString *NapisPripoj(void) {
    return KLIC(@"Connect the iPad to your Mac with a USB cable and open Older Sidecar on the Mac.");
}

static UILabel *VytlacenyNapis(CGFloat velikost, BOOL tucne, UIColor *barva) {
    UILabel *n = [[[UILabel alloc] initWithFrame:CGRectZero] autorelease];
    n.backgroundColor = [UIColor clearColor];
    n.textColor = barva;
    n.shadowColor = [UIColor colorWithWhite:0 alpha:0.85]; // tmavy stin nad pismem = vytlaceno jako v iOS 6
    n.shadowOffset = CGSizeMake(0, -1);
    n.font = tucne ? [UIFont boldSystemFontOfSize:velikost] : [UIFont systemFontOfSize:velikost];
    n.textAlignment = NSTextAlignmentCenter;
    n.numberOfLines = 0;
    return n;
}

// Cerna leskla lista s nazvem, jako cerny UINavigationBar v iOS 6 (kreslena rucne, at vypada stejne i v iOS 7–10)
@interface OSLista : UIView
@end

@implementation OSLista
- (void)drawRect:(CGRect)oblast {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = self.bounds;
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGFloat barvy[] = { 0.40, 0.41, 0.43, 1,  0.19, 0.20, 0.21, 1,  0.09, 0.09, 0.10, 1,  0.03, 0.03, 0.04, 1 };
    CGFloat mista[] = { 0, 0.5, 0.5, 1 };
    CGGradientRef prechod = CGGradientCreateWithColorComponents(rgb, barvy, mista, 4);
    CGContextDrawLinearGradient(c, prechod, CGPointZero, CGPointMake(0, r.size.height), 0);
    CGGradientRelease(prechod);
    CGColorSpaceRelease(rgb);
    CGContextSetRGBFillColor(c, 1, 1, 1, 0.28);
    CGContextFillRect(c, CGRectMake(0, 0, r.size.width, 1));
    CGContextSetRGBFillColor(c, 0, 0, 0, 1);
    CGContextFillRect(c, CGRectMake(0, r.size.height - 1, r.size.width, 1));
}

// dotyk na liste neni dotyk na touchpadu
- (void)touchesBegan:(NSSet *)dotyky withEvent:(UIEvent *)udalost {}
- (void)touchesMoved:(NSSet *)dotyky withEvent:(UIEvent *)udalost {}
- (void)touchesEnded:(NSSet *)dotyky withEvent:(UIEvent *)udalost {}
@end

#pragma mark - Kreslene znacky a tlacitka

enum { ZnackaKlavesnice, ZnackaPredchozi, ZnackaPrehrat, ZnackaDalsi, ZnackaTiseji, ZnackaZtlumit, ZnackaHlasiteji,
       ZnackaOko, ZnackaTouchpad, ZnackaMenu, ZnackaJasMene, ZnackaJasVic, ZnackaMissionControl, ZnackaLaunchpad,
       ZnackaZamek, ZnackaVlevo, ZnackaVpravo, ZnackaNahoru, ZnackaDolu };

static void Trojuhelnik(CGContextRef c, CGFloat x, CGFloat y, CGFloat w, CGFloat h, BOOL vpravo) {
    CGContextMoveToPoint(c, vpravo ? x : x + w, y);
    CGContextAddLineToPoint(c, vpravo ? x + w : x, y + h / 2);
    CGContextAddLineToPoint(c, vpravo ? x : x + w, y + h);
    CGContextClosePath(c);
    CGContextFillPath(c);
}

static void Klavesy(CGContextRef c, CGRect r, int sloupcu, int radku) {
    CGFloat mezera = r.size.width * 0.04;
    CGFloat w = (r.size.width - mezera * (sloupcu + 1)) / sloupcu, h = (r.size.height - mezera * (radku + 2)) / (radku + 1);
    for (int y = 0; y <= radku; y++)
        for (int x = 0; x < sloupcu; x++) {
            if (y == radku && (x == 0 || x == sloupcu - 1)) continue; // posledni rada: jen mezernik
            CGRect k = CGRectMake(r.origin.x + mezera + x * (w + mezera), r.origin.y + mezera + y * (h + mezera), w, h);
            if (y == radku) k.size.width = (sloupcu - 2) * (w + mezera) - mezera, k.origin.x = r.origin.x + mezera + w + mezera;
            [[UIBezierPath bezierPathWithRoundedRect:k cornerRadius:MIN(w, h) * 0.25] fill];
            if (y == radku) break;
        }
}

static void Reproduktor(CGContextRef c, CGRect r, int vln) {
    CGFloat x = r.origin.x, y = r.origin.y, w = r.size.width, h = r.size.height;
    CGContextFillRect(c, CGRectMake(x, y + h * 0.35, w * 0.17, h * 0.3));
    CGContextMoveToPoint(c, x + w * 0.17, y + h * 0.35);
    CGContextAddLineToPoint(c, x + w * 0.42, y + h * 0.1);
    CGContextAddLineToPoint(c, x + w * 0.42, y + h * 0.9);
    CGContextAddLineToPoint(c, x + w * 0.17, y + h * 0.65);
    CGContextClosePath(c);
    CGContextFillPath(c);
    CGContextSetLineWidth(c, MAX(1.5, w * 0.07));
    CGContextSetLineCap(c, kCGLineCapRound);
    for (int i = 1; i <= vln; i++) {
        CGContextAddArc(c, x + w * 0.42, y + h / 2, w * (0.06 + 0.15 * i), -M_PI / 4, M_PI / 4, 0);
        CGContextStrokePath(c);
    }
}

// Bila znacka v obdelniku r (barvu a stin nastavi volajici)
static void KresliZnacku(CGContextRef c, NSInteger znacka, CGRect r) {
    CGFloat x = r.origin.x, y = r.origin.y, w = r.size.width, h = r.size.height;
    switch (znacka) {
        case ZnackaKlavesnice: {
            CGRect deska = CGRectMake(x, y + h * 0.18, w, h * 0.64);
            UIBezierPath *obrys = [UIBezierPath bezierPathWithRoundedRect:deska cornerRadius:w * 0.08];
            obrys.lineWidth = MAX(1.5, w * 0.06);
            [obrys stroke];
            Klavesy(c, CGRectInset(deska, w * 0.06, h * 0.06), 6, 2);
            break;
        }
        case ZnackaPredchozi:
            CGContextFillRect(c, CGRectMake(x, y + h * 0.15, w * 0.1, h * 0.7));
            Trojuhelnik(c, x + w * 0.1, y + h * 0.15, w * 0.45, h * 0.7, NO);
            Trojuhelnik(c, x + w * 0.55, y + h * 0.15, w * 0.45, h * 0.7, NO);
            break;
        case ZnackaDalsi:
            Trojuhelnik(c, x, y + h * 0.15, w * 0.45, h * 0.7, YES);
            Trojuhelnik(c, x + w * 0.45, y + h * 0.15, w * 0.45, h * 0.7, YES);
            CGContextFillRect(c, CGRectMake(x + w * 0.9, y + h * 0.15, w * 0.1, h * 0.7));
            break;
        case ZnackaPrehrat:
            Trojuhelnik(c, x, y + h * 0.15, w * 0.5, h * 0.7, YES);
            CGContextFillRect(c, CGRectMake(x + w * 0.62, y + h * 0.15, w * 0.13, h * 0.7));
            CGContextFillRect(c, CGRectMake(x + w * 0.85, y + h * 0.15, w * 0.13, h * 0.7));
            break;
        case ZnackaTiseji: Reproduktor(c, r, 1); break;
        case ZnackaHlasiteji: Reproduktor(c, r, 3); break;
        case ZnackaZtlumit:
            Reproduktor(c, r, 0);
            CGContextSetLineWidth(c, MAX(1.5, w * 0.08));
            CGContextSetLineCap(c, kCGLineCapRound);
            CGContextMoveToPoint(c, x + w * 0.6, y + h * 0.33); CGContextAddLineToPoint(c, x + w * 0.92, y + h * 0.67);
            CGContextMoveToPoint(c, x + w * 0.92, y + h * 0.33); CGContextAddLineToPoint(c, x + w * 0.6, y + h * 0.67);
            CGContextStrokePath(c);
            break;
        case ZnackaOko: {
            CGContextSetLineWidth(c, w * 0.06);
            CGContextMoveToPoint(c, x, y + h / 2);
            CGContextAddQuadCurveToPoint(c, x + w / 2, y - h * 0.15, x + w, y + h / 2);
            CGContextAddQuadCurveToPoint(c, x + w / 2, y + h * 1.15, x, y + h / 2);
            CGContextStrokePath(c);
            CGContextFillEllipseInRect(c, CGRectMake(x + w * 0.33, y + h / 2 - w * 0.17, w * 0.34, w * 0.34)); // duhovka
            CGContextSaveGState(c);
            CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
            CGContextSetRGBFillColor(c, 0.12, 0.13, 0.15, 1);
            CGContextFillEllipseInRect(c, CGRectMake(x + w * 0.43, y + h / 2 - w * 0.07, w * 0.14, w * 0.14));
            CGContextRestoreGState(c);
            break;
        }
        case ZnackaJasMene:
        case ZnackaJasVic: { // slunce: mensi a vetsi
            BOOL vic = znacka == ZnackaJasVic;
            CGFloat polomer = w * (vic ? 0.2 : 0.15), od = polomer + w * 0.08, delka = w * (vic ? 0.17 : 0.1);
            CGPoint s = CGPointMake(x + w / 2, y + h / 2);
            CGContextFillEllipseInRect(c, CGRectMake(s.x - polomer, s.y - polomer, polomer * 2, polomer * 2));
            CGContextSetLineWidth(c, MAX(1.5, w * 0.07));
            CGContextSetLineCap(c, kCGLineCapRound);
            for (int i = 0; i < 8; i++) {
                CGFloat u = i * M_PI / 4;
                CGContextMoveToPoint(c, s.x + cos(u) * od, s.y + sin(u) * od);
                CGContextAddLineToPoint(c, s.x + cos(u) * (od + delka), s.y + sin(u) * (od + delka));
            }
            CGContextStrokePath(c);
            break;
        }
        case ZnackaMissionControl: { // okna rozlozena po plose
            CGFloat r1 = w * 0.06;
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y + h * 0.12, w * 0.44, h * 0.34) cornerRadius:r1] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + w * 0.56, y + h * 0.12, w * 0.44, h * 0.34) cornerRadius:r1] fill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + w * 0.2, y + h * 0.56, w * 0.6, h * 0.32) cornerRadius:r1] fill];
            break;
        }
        case ZnackaLaunchpad: { // mrizka ikon
            CGFloat d = w * 0.24, mezera = (w - 3 * d) / 2;
            for (int i = 0; i < 9; i++)
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + (i % 3) * (d + mezera), y + (i / 3) * (d + mezera), d, d) cornerRadius:d * 0.3] fill];
            break;
        }
        case ZnackaZamek: { // visaci zamek
            CGContextSetLineWidth(c, MAX(1.5, w * 0.11));
            CGContextAddArc(c, x + w / 2, y + h * 0.42, w * 0.22, M_PI, 0, 0);
            CGContextMoveToPoint(c, x + w * 0.28, y + h * 0.42); CGContextAddLineToPoint(c, x + w * 0.28, y + h * 0.5);
            CGContextMoveToPoint(c, x + w * 0.72, y + h * 0.42); CGContextAddLineToPoint(c, x + w * 0.72, y + h * 0.5);
            CGContextStrokePath(c);
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + w * 0.14, y + h * 0.48, w * 0.72, h * 0.46) cornerRadius:w * 0.08] fill];
            break;
        }
        case ZnackaVlevo: Trojuhelnik(c, x + w * 0.2, y + h * 0.2, w * 0.6, h * 0.6, NO); break;
        case ZnackaVpravo: Trojuhelnik(c, x + w * 0.2, y + h * 0.2, w * 0.6, h * 0.6, YES); break;
        case ZnackaNahoru:
        case ZnackaDolu: {
            BOOL nahoru = znacka == ZnackaNahoru;
            CGContextMoveToPoint(c, x + w * 0.2, nahoru ? y + h * 0.75 : y + h * 0.25);
            CGContextAddLineToPoint(c, x + w * 0.8, nahoru ? y + h * 0.75 : y + h * 0.25);
            CGContextAddLineToPoint(c, x + w / 2, nahoru ? y + h * 0.2 : y + h * 0.8);
            CGContextClosePath(c);
            CGContextFillPath(c);
            break;
        }
        case ZnackaMenu: { // ctyri ctverecky jako domovska obrazovka
            CGFloat mezera = w * 0.14, d = (w - mezera) / 2;
            for (int i = 0; i < 4; i++)
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x + (i % 2) * (d + mezera), y + (i / 2) * (d + mezera), d, d)
                                            cornerRadius:d * 0.28] fill];
            break;
        }
        case ZnackaTouchpad: {
            CGRect klavesnice = CGRectMake(x, y, w, h * 0.42);
            Klavesy(c, klavesnice, 7, 2);
            CGRect plocha = CGRectMake(x + w * 0.25, y + h * 0.52, w * 0.5, h * 0.42);
            UIBezierPath *obrys = [UIBezierPath bezierPathWithRoundedRect:plocha cornerRadius:w * 0.05];
            obrys.lineWidth = MAX(1.5, w * 0.045);
            [obrys stroke];
            CGContextFillEllipseInRect(c, CGRectMake(CGRectGetMidX(plocha) + w * 0.03, CGRectGetMidY(plocha) - w * 0.02, w * 0.09, w * 0.09));
            break;
        }
    }
}

static void Prechod(CGContextRef c, CGRect r, const CGFloat *barvy, const CGFloat *mista, size_t pocet) {
    CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
    CGGradientRef p = CGGradientCreateWithColorComponents(rgb, barvy, mista, pocet);
    CGContextDrawLinearGradient(c, p, CGPointMake(0, r.origin.y), CGPointMake(0, CGRectGetMaxY(r)), 0);
    CGGradientRelease(p);
    CGColorSpaceRelease(rgb);
}

// Tlacitko na cerne liste jako UIBarButtonItem v iOS 6: leskle, tmave, s bilou znackou
@interface OSTlacitkoListy : UIButton
@property (nonatomic) NSInteger znacka;
@end

@implementation OSTlacitkoListy
@synthesize znacka = _znacka;
- (void)setHighlighted:(BOOL)stisknuto { [super setHighlighted:stisknuto]; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)oblast {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectInset(self.bounds, 3, 5);
    [[UIColor colorWithWhite:1 alpha:0.12] setFill]; // svetla hrana pod tlacitkem, je zapustene do listy
    [[UIBezierPath bezierPathWithRoundedRect:CGRectOffset(r, 0, 1) cornerRadius:6] fill];
    UIBezierPath *tvar = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:6];
    CGContextSaveGState(c);
    [tvar addClip];
    CGFloat normalni[] = { 0.45, 0.46, 0.48, 1,  0.22, 0.23, 0.25, 1,  0.13, 0.13, 0.15, 1,  0.07, 0.07, 0.08, 1 };
    CGFloat stisknute[] = { 0.10, 0.10, 0.11, 1,  0.16, 0.16, 0.18, 1,  0.16, 0.16, 0.18, 1,  0.22, 0.22, 0.24, 1 };
    CGFloat mista[] = { 0, 0.5, 0.5, 1 };
    Prechod(c, r, self.highlighted ? stisknute : normalni, mista, 4);
    CGContextRestoreGState(c);
    [[UIColor colorWithWhite:0 alpha:0.95] setStroke];
    tvar.lineWidth = 1;
    [tvar stroke];
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -1), 0, [UIColor colorWithWhite:0 alpha:0.85].CGColor);
    [[UIColor whiteColor] setFill];
    [[UIColor whiteColor] setStroke];
    CGFloat s = MIN(r.size.width, r.size.height) * 0.56;
    KresliZnacku(c, self.znacka, CGRectMake(CGRectGetMidX(r) - s / 2, CGRectGetMidY(r) - s / 2, s, s));
    CGContextRestoreGState(c);
}
@end

// Hlinikova klavesa jako na klavesnici Apple: svetla, tmavy popisek nebo znacka.
// Modifikator (⌘ ⌥ ⌃ ⇧) ma zelenou kontrolku jako Caps Lock, sviti, kdyz je zapnuty.
@interface OSKlavesa : UIButton
@property (nonatomic, copy) NSString *symbol, *slovo; // velky symbol a male slovo pod nim (control, option…)
@property (nonatomic) NSInteger znacka;               // -1 = jen text
@property (nonatomic) BOOL kontrolka, zapnuto;
@end

@implementation OSKlavesa
@synthesize symbol = _symbol, slovo = _slovo, znacka = _znacka, kontrolka = _kontrolka, zapnuto = _zapnuto;
- (void)setHighlighted:(BOOL)stisknuto { [super setHighlighted:stisknuto]; [self setNeedsDisplay]; }
- (void)setZapnuto:(BOOL)zapnuto { _zapnuto = zapnuto; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)oblast {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectInset(self.bounds, 3, 3);
    r.size.height -= 2;
    if (self.highlighted) r = CGRectOffset(r, 0, 1); // stisknuta klavesa jde dolu
    [[UIColor colorWithWhite:0 alpha:0.35] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectOffset(r, 0, self.highlighted ? 1 : 2) cornerRadius:7] fill];
    UIBezierPath *tvar = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:7];
    CGContextSaveGState(c);
    [tvar addClip];
    CGFloat normalni[] = { 0.99, 0.99, 1.0, 1,  0.87, 0.88, 0.90, 1 };
    CGFloat stisknute[] = { 0.82, 0.83, 0.85, 1,  0.90, 0.91, 0.93, 1 };
    CGFloat dve[] = { 0, 1 };
    Prechod(c, r, self.highlighted ? stisknute : normalni, dve, 2);
    CGContextRestoreGState(c);
    [[UIColor colorWithWhite:0.52 alpha:1] setStroke];
    tvar.lineWidth = 1;
    [tvar stroke];
    if (self.kontrolka) { // kontrolka vlevo nahore
        CGRect led = CGRectMake(r.origin.x + 7, r.origin.y + 7, 7, 7);
        CGContextSaveGState(c);
        if (self.zapnuto) CGContextSetShadowWithColor(c, CGSizeZero, 5, [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1].CGColor);
        [(self.zapnuto ? [UIColor colorWithRed:0.25 green:0.9 blue:0.25 alpha:1] : [UIColor colorWithWhite:0.72 alpha:1]) setFill];
        CGContextFillEllipseInRect(c, led);
        CGContextRestoreGState(c);
    }
    [[UIColor colorWithWhite:0.26 alpha:1] setFill];
    [[UIColor colorWithWhite:0.26 alpha:1] setStroke];
    CGContextSetShadowWithColor(c, CGSizeMake(0, 1), 0, [UIColor colorWithWhite:1 alpha:0.9].CGColor);
    if (self.znacka >= 0) {
        CGFloat s = MIN(r.size.width, r.size.height) * 0.42;
        KresliZnacku(c, self.znacka, CGRectMake(CGRectGetMidX(r) - s / 2, CGRectGetMidY(r) - s / 2, s, s));
    } else if (self.slovo.length) {
        [self.symbol drawInRect:CGRectMake(r.origin.x, r.origin.y + 6, r.size.width, 24) withFont:[UIFont systemFontOfSize:20]
                  lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
        [self.slovo drawInRect:CGRectMake(r.origin.x, CGRectGetMaxY(r) - 17, r.size.width, 14) withFont:[UIFont systemFontOfSize:10]
                 lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
    } else {
        [self.symbol drawInRect:CGRectMake(r.origin.x, CGRectGetMidY(r) - 11, r.size.width, 22) withFont:[UIFont systemFontOfSize:17]
                  lineBreakMode:NSLineBreakByClipping alignment:NSTextAlignmentCenter];
    }
}

- (void)dealloc {
    [_symbol release];
    [_slovo release];
    [super dealloc];
}
@end

// Leskle tlacitko s textem (volba jazyka); vybrane je modre
@interface OSTextoveTlacitko : UIButton
@property (nonatomic, copy) NSString *nadpis;
@property (nonatomic) BOOL vybrane;
@end

@implementation OSTextoveTlacitko
@synthesize nadpis = _nadpis, vybrane = _vybrane;
- (void)setHighlighted:(BOOL)stisknuto { [super setHighlighted:stisknuto]; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)oblast {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectInset(self.bounds, 3, 4);
    [[UIColor colorWithWhite:1 alpha:0.12] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectOffset(r, 0, 1) cornerRadius:10] fill];
    UIBezierPath *tvar = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:10];
    CGContextSaveGState(c);
    [tvar addClip];
    CGFloat seda[] = { 0.45, 0.46, 0.48, 1,  0.22, 0.23, 0.25, 1,  0.13, 0.13, 0.15, 1,  0.07, 0.07, 0.08, 1 };
    CGFloat modra[] = { 0.50, 0.70, 0.97, 1,  0.22, 0.47, 0.88, 1,  0.11, 0.35, 0.78, 1,  0.18, 0.44, 0.88, 1 };
    CGFloat stisknute[] = { 0.10, 0.10, 0.11, 1,  0.16, 0.16, 0.18, 1,  0.16, 0.16, 0.18, 1,  0.22, 0.22, 0.24, 1 };
    CGFloat mista[] = { 0, 0.5, 0.5, 1 };
    Prechod(c, r, self.highlighted ? stisknute : self.vybrane ? modra : seda, mista, 4);
    CGContextRestoreGState(c);
    [[UIColor colorWithWhite:0 alpha:0.95] setStroke];
    tvar.lineWidth = 1;
    [tvar stroke];
    CGContextSetShadowWithColor(c, CGSizeMake(0, -1), 0, [UIColor colorWithWhite:0 alpha:0.8].CGColor);
    [[UIColor whiteColor] setFill];
    [self.nadpis drawInRect:CGRectMake(r.origin.x + 8, CGRectGetMidY(r) - 11, r.size.width - 16, 24)
                   withFont:[UIFont boldSystemFontOfSize:17] lineBreakMode:NSLineBreakByTruncatingTail alignment:NSTextAlignmentCenter];
}

- (void)dealloc {
    [_nadpis release];
    [super dealloc];
}
@end

// Velke tlacitko na obrazovce vyberu rezimu: tmave sklo s leskem, znacka, nadpis a popis
@interface OSVelkeTlacitko : UIButton
@property (nonatomic) NSInteger znacka;
@property (nonatomic, copy) NSString *nadpis, *popis;
@end

@implementation OSVelkeTlacitko
@synthesize znacka = _znacka, nadpis = _nadpis, popis = _popis;
- (void)setHighlighted:(BOOL)stisknuto { [super setHighlighted:stisknuto]; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)oblast {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectInset(self.bounds, 10, 10);
    UIBezierPath *tvar = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:18];
    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, 5), 14, [UIColor colorWithWhite:0 alpha:0.75].CGColor);
    [[UIColor colorWithWhite:0.12 alpha:1] setFill];
    [tvar fill];
    CGContextRestoreGState(c);
    CGContextSaveGState(c);
    [tvar addClip];
    CGFloat normalni[] = { 0.36, 0.38, 0.42, 1,  0.21, 0.22, 0.25, 1,  0.14, 0.15, 0.17, 1,  0.09, 0.09, 0.11, 1 };
    CGFloat stisknute[] = { 0.10, 0.10, 0.12, 1,  0.15, 0.16, 0.18, 1,  0.15, 0.16, 0.18, 1,  0.20, 0.21, 0.23, 1 };
    CGFloat mista[] = { 0, 0.5, 0.5, 1 };
    Prechod(c, r, self.highlighted ? stisknute : normalni, mista, 4);
    CGContextRestoreGState(c);
    [[UIColor colorWithWhite:0 alpha:0.95] setStroke];
    tvar.lineWidth = 1.5;
    [tvar stroke];
    UIBezierPath *hrana = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, 1.5, 1.5) cornerRadius:16.5];
    [[UIColor colorWithWhite:1 alpha:0.14] setStroke];
    hrana.lineWidth = 1;
    [hrana stroke];

    CGContextSaveGState(c);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -1), 0, [UIColor colorWithWhite:0 alpha:0.9].CGColor);
    [[UIColor whiteColor] setFill];
    [[UIColor whiteColor] setStroke];
    KresliZnacku(c, self.znacka, CGRectMake(CGRectGetMidX(r) - 52, r.origin.y + 26, 104, 92));
    [self.nadpis drawInRect:CGRectMake(r.origin.x + 12, r.origin.y + 134, r.size.width - 24, 34)
                   withFont:[UIFont boldSystemFontOfSize:26] lineBreakMode:NSLineBreakByTruncatingTail alignment:NSTextAlignmentCenter];
    [[UIColor colorWithRed:0.76 green:0.78 blue:0.82 alpha:1] setFill];
    [self.popis drawInRect:CGRectMake(r.origin.x + 22, r.origin.y + 176, r.size.width - 44, r.size.height - 182)
                  withFont:[UIFont systemFontOfSize:15] lineBreakMode:NSLineBreakByWordWrapping alignment:NSTextAlignmentCenter];
    CGContextRestoreGState(c);
}

- (void)dealloc {
    [_nadpis release];
    [_popis release];
    [super dealloc];
}
@end

// Lista s tlacitky v rezimu ovladani: cerne leskle sklo zapustene do hliniku
@interface OSTouchBar : UIView
@end

@implementation OSTouchBar
- (void)drawRect:(CGRect)oblast {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = CGRectInset(self.bounds, 1, 1);
    r.size.height -= 1;
    [[UIColor colorWithWhite:1 alpha:0.55] setFill]; // svetla hrana pod listou, je do hliniku zapustena
    [[UIBezierPath bezierPathWithRoundedRect:CGRectOffset(r, 0, 1) cornerRadius:12] fill];
    UIBezierPath *tvar = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12];
    CGContextSaveGState(c);
    [tvar addClip];
    CGFloat barvy[] = { 0.24, 0.25, 0.27, 1,  0.10, 0.10, 0.11, 1,  0.04, 0.04, 0.05, 1,  0.02, 0.02, 0.03, 1 };
    CGFloat mista[] = { 0, 0.5, 0.5, 1 };
    Prechod(c, r, barvy, mista, 4);
    CGContextRestoreGState(c);
    [[UIColor colorWithWhite:0 alpha:0.9] setStroke];
    tvar.lineWidth = 1;
    [tvar stroke];
}

// dotyk na liste mimo tlacitka neni dotyk na touchpadu
- (void)touchesBegan:(NSSet *)dotyky withEvent:(UIEvent *)udalost {}
- (void)touchesMoved:(NSSet *)dotyky withEvent:(UIEvent *)udalost {}
- (void)touchesEnded:(NSSet *)dotyky withEvent:(UIEvent *)udalost {}
@end

// Oprerka dlani MacBooku: kartacovany hlinik a v nem zapusteny touchpad
@interface OSPodlozka : UIView
@property (nonatomic) CGRect touchpad;
@end

@implementation OSPodlozka
@synthesize touchpad = _touchpad;
- (void)drawRect:(CGRect)oblast {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGRect r = self.bounds;
    [[UIColor colorWithPatternImage:[UIImage imageNamed:@"Hlinik.png"]] setFill];
    UIRectFill(r);
    CGFloat svetlo[] = { 1, 1, 1, 0.22,  1, 1, 1, 0,  0, 0, 0, 0.14 };
    CGFloat mistaSvetla[] = { 0, 0.45, 1 };
    Prechod(c, r, svetlo, mistaSvetla, 3);
    CGRect t = self.touchpad;
    if (CGRectIsEmpty(t)) return;
    [[UIColor colorWithWhite:1 alpha:0.65] setFill]; // svetla spodni hrana: touchpad je zapusteny
    [[UIBezierPath bezierPathWithRoundedRect:CGRectOffset(t, 0, 1.5) cornerRadius:16] fill];
    UIBezierPath *plocha = [UIBezierPath bezierPathWithRoundedRect:t cornerRadius:16];
    CGContextSaveGState(c);
    [plocha addClip];
    CGFloat sklo[] = { 0.81, 0.82, 0.84, 1,  0.73, 0.74, 0.76, 1 };
    CGFloat dve[] = { 0, 1 };
    Prechod(c, t, sklo, dve, 2);
    CGFloat stin[] = { 0, 0, 0, 0.3,  0, 0, 0, 0 }; // vnitrni stin pri horni hrane
    Prechod(c, CGRectMake(t.origin.x, t.origin.y, t.size.width, 12), stin, dve, 2);
    CGContextRestoreGState(c);
    [[UIColor colorWithWhite:0.42 alpha:1] setStroke];
    plocha.lineWidth = 1;
    [plocha stroke];
}
@end

// Napis vyryty do hliniku: tmavy, se svetlym odleskem pod pismem
static UILabel *VyrytyNapis(CGFloat velikost, BOOL tucne) {
    UILabel *n = VytlacenyNapis(velikost, tucne, [UIColor colorWithRed:0.32 green:0.33 blue:0.36 alpha:1]);
    n.shadowColor = [UIColor colorWithWhite:1 alpha:0.75];
    n.shadowOffset = CGSizeMake(0, 1);
    return n;
}

// Poradi tlacitek na liste ovladani (jako Touch Bar), -1 = mezera mezi skupinami:
// menu, klavesnice | jas, Mission Control, Launchpad | hudba | hlasitost, zamek
static const NSInteger kPoradiListy[] = { 101, 100, -1, KlavesaJasMene, KlavesaJasVic, KlavesaMissionControl, KlavesaLaunchpad, -1,
                                          KlavesaPredchozi, KlavesaPrehrat, KlavesaDalsi, -1,
                                          KlavesaTiseji, KlavesaZtlumit, KlavesaHlasiteji, KlavesaZamknout };
#define POCET_NA_LISTE (sizeof kPoradiListy / sizeof kPoradiListy[0])

// Rada klaves pod listou: { tag, symbol, slovo, sirka }; tag 300 + Klavesa..., 400 + Mod..., -1 = mezera
typedef struct { NSInteger tag; const char *symbol, *slovo; CGFloat sirka; } OSKlavesaRady;
static const OSKlavesaRady kRadaKlaves[] = {
    { 300 + KlavesaEsc, "esc", "", 78 }, { 300 + KlavesaTab, "tab", "", 78 }, { -1, "", "", 20 },
    { 400 + ModCtrl, "⌃", "control", 74 }, { 400 + ModAlt, "⌥", "option", 74 },
    { 400 + ModCmd, "⌘", "command", 74 }, { 400 + ModShift, "⇧", "shift", 74 }, { -1, "", "", 20 },
    { 300 + KlavesaVlevo, "", "", 60 }, { 300 + KlavesaNahoru, "", "", 60 }, { 300 + KlavesaDolu, "", "", 60 }, { 300 + KlavesaVpravo, "", "", 60 },
};
#define POCET_KLAVES_RADY (sizeof kRadaKlaves / sizeof kRadaKlaves[0])

// Nazev modelu iPadu podle hw.machine (napr. iPad2,5 = iPad mini)
static NSString *NazevModelu(void) {
    char stroj[32] = {0};
    size_t delka = sizeof stroj - 1;
    sysctlbyname("hw.machine", stroj, &delka, NULL, 0);
    int hlavni = 0, vedlejsi = 0;
    sscanf(stroj, "iPad%d,%d", &hlavni, &vedlejsi);
    NSString *nazev = nil;
    if (hlavni == 1) nazev = @"iPad";
    else if (hlavni == 2) nazev = vedlejsi <= 4 ? @"iPad 2" : @"iPad mini";
    else if (hlavni == 3) nazev = vedlejsi <= 3 ? @"iPad (3rd generation)" : @"iPad (4th generation)";
    else if (hlavni == 4) nazev = vedlejsi <= 3 ? @"iPad Air" : vedlejsi <= 6 ? @"iPad mini 2" : @"iPad mini 3";
    else if (hlavni == 5) nazev = vedlejsi <= 2 ? @"iPad mini 4" : @"iPad Air 2";
    NSString *kod = [NSString stringWithUTF8String:stroj];
    return nazev ?: [NSString stringWithFormat:@"%@ (%@)", [UIDevice currentDevice].model, kod];
}

@interface OSDisplejController : UIViewController <UITextFieldDelegate>
@end

@implementation OSDisplejController {
    UIView *_cekani;        // vse, co je videt, dokud nejde obraz z Macu
    OSLista *_lista;
    UIView *_stinListy;
    UIImageView *_obrazek;  // Mac a iPad spojene kabelem
    UILabel *_napis, *_napoveda;
    UIActivityIndicatorView *_kolecko;
    NSLock *_zamek;     // chrani zapis do _mac (vlakno spojeni i hlavni vlakno s dotyky)
    int _mac;           // socket pripojeneho Macu, -1 = nepripojen
    uint32_t _sirka, _vyska;    // v bodech, ne pixelech: Retina iPad by plny rozmer nestihal rozbalovat
    uint32_t _rezim;            // RezimObrazovka / RezimOvladani, 0 = jeste nevybrano
    UIView *_vyber;             // obrazovka s vyberem rezimu (pri kazdem otevreni)
    UIView *_ovladaniPlocha;    // rezim ovladani: hlinik, lista s tlacitky a touchpad (bez obrazovky Macu)
    OSPodlozka *_podlozka;
    OSTouchBar *_ovladani;      // lista: klavesnice, hudba, hlasitost
    UILabel *_stavOvladani, *_napovedaOvladani;
    UIView *_klavesy;           // rada hlinikovych klaves: esc, tab, ⌃ ⌥ ⌘ ⇧, sipky
    uint32_t _modifikatory;     // zapnute Mod... (plati pro dalsi klavesu, text nebo klik)
    NSString *_stavKlic;        // posledni hlaseni (neprelozene), aby slo prelozit i po zmene jazyka
    UIView *_jazyky;            // nabidka jazyku (otevre se z menu)
    OSTlacitkoListy *_tlacitkoMenu; // Jen obrazovka: tuknutim se na chvili ukaze, vrati do menu
    UITextField *_psani;        // skryte pole: otevre klavesnici iPadu, napsane jde do Macu
    // Jen obrazovka: dva prsty = zvetseni a posun, jeden prst posouva zvetseny obraz
    BOOL _gesto;                // tahle sada dotyku zvetsuje
    CGFloat _zoom;              // 1 = cely obraz, nejvys 4
    CGPoint _vyrez;             // levy horni roh viditelne casti obrazu (0..1)
    CGFloat _zoomNaZacatku, _vzdalenostNaZacatku;
    CGPoint _bodNaZacatku;      // bod obrazu (0..1), ktery byl na zacatku gesta mezi prsty
    // Ovladani jako touchpad
    CGPoint _posledniBod;       // posledni poloha prstu (u dvou prstu jejich stred)
    CGFloat _ujeto;             // kolik prsty urazily: tuk, nebo pohyb?
    NSUInteger _nejvicPrstu;    // nejvic prstu v teto sade dotyku (0 = zadny dotyk)
    NSTimeInterval _zacatek, _posledniTuk;
    BOOL _mozneTazeni, _tahnu;  // tuk a hned znovu prst dolu = tazeni s drzenym tlacitkem
    CGPoint _zbytekPohybu, _zbytekKolecka; // desetinne zbytky, at se pomaly pohyb neztrati
}

- (id)init {
    if ((self = [super init])) {
        _zamek = [[NSLock alloc] init];
        _mac = -1;
        _zoom = 1;
        CGSize velikost = [UIScreen mainScreen].bounds.size;
        _sirka = MAX(velikost.width, velikost.height);
        _vyska = MIN(velikost.width, velikost.height);
        [NSThread detachNewThreadSelector:@selector(server) toTarget:self withObject:nil];
        [UIDevice currentDevice].batteryMonitoringEnabled = YES; // baterie iPadu se ukazuje v menu na Macu
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(posliBaterii) name:UIDeviceBatteryLevelDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(posliBaterii) name:UIDeviceBatteryStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)loadView {
    UIView *plocha = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    // dokud nejde obraz: lnene platno jako v iOS 6, obrazek a vytlaceny napis
    plocha.backgroundColor = [UIColor colorWithPatternImage:[UIImage imageNamed:@"Platno.png"]];
    plocha.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    plocha.layer.contentsGravity = kCAGravityResize;
    plocha.multipleTouchEnabled = YES; // dva prsty = zvetseni
    _cekani =[[UIView alloc] initWithFrame:plocha.bounds];
    [plocha addSubview:_cekani];

    _obrazek = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Sajdkara.png"]];
    [_cekani addSubview:_obrazek];

    _kolecko = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    _kolecko.hidesWhenStopped = YES;
    [_cekani addSubview:_kolecko];
    _napis = [VytlacenyNapis(22, YES, [UIColor colorWithRed:0.82 green:0.84 blue:0.87 alpha:1]) retain];
    [_cekani addSubview:_napis];
    _napoveda = [VytlacenyNapis(15, NO, [UIColor colorWithRed:0.58 green:0.60 blue:0.64 alpha:1]) retain];
    [_cekani addSubview:_napoveda];

    _lista = [[OSLista alloc] initWithFrame:CGRectZero];
    _lista.contentMode = UIViewContentModeRedraw;
    UILabel *nazev = VytlacenyNapis(20, YES, [UIColor whiteColor]);
    nazev.text = @"Older Sidecar";
    nazev.frame = CGRectMake(0, 0, 1, 44);
    nazev.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_lista addSubview:nazev];
    [_cekani addSubview:_lista];
    _stinListy = [[UIView alloc] initWithFrame:CGRectZero]; // jemny stin listy na platne
    CAGradientLayer *stin = [CAGradientLayer layer];
    stin.colors = [NSArray arrayWithObjects:(id)[UIColor colorWithWhite:0 alpha:0.45].CGColor, (id)[UIColor clearColor].CGColor, nil];
    stin.frame = CGRectMake(0, 0, 2048, 7);
    [_stinListy.layer addSublayer:stin];
    _stinListy.clipsToBounds = YES;
    [_cekani addSubview:_stinListy];

    // Rezim ovladani: jako oprerka dlani MacBooku – hlinik, nahore lista s tlacitky, pod ni touchpad
    _ovladaniPlocha = [[UIView alloc] initWithFrame:plocha.bounds];
    _ovladaniPlocha.hidden = YES;
    _podlozka = [[OSPodlozka alloc] initWithFrame:plocha.bounds];
    _podlozka.contentMode = UIViewContentModeRedraw;
    [_ovladaniPlocha addSubview:_podlozka];
    _napovedaOvladani = [VyrytyNapis(17, NO) retain];
    [_ovladaniPlocha addSubview:_napovedaOvladani];
    _stavOvladani = [VyrytyNapis(20, YES) retain];
    [_ovladaniPlocha addSubview:_stavOvladani];
    _ovladani = [[OSTouchBar alloc] initWithFrame:CGRectZero];
    _ovladani.backgroundColor = [UIColor clearColor];
    _ovladani.contentMode = UIViewContentModeRedraw;
    // 100 = klavesnice, 101 = zpet do menu, ostatni = Klavesa...
    int tlacitka[] = { 101, 100, KlavesaJasMene, KlavesaJasVic, KlavesaMissionControl, KlavesaLaunchpad,
                       KlavesaPredchozi, KlavesaPrehrat, KlavesaDalsi, KlavesaTiseji, KlavesaZtlumit, KlavesaHlasiteji, KlavesaZamknout };
    int znacky[] = { ZnackaMenu, ZnackaKlavesnice, ZnackaJasMene, ZnackaJasVic, ZnackaMissionControl, ZnackaLaunchpad,
                     ZnackaPredchozi, ZnackaPrehrat, ZnackaDalsi, ZnackaTiseji, ZnackaZtlumit, ZnackaHlasiteji, ZnackaZamek };
    for (int i = 0; i < 13; i++) {
        OSTlacitkoListy *t = [[OSTlacitkoListy alloc] initWithFrame:CGRectZero];
        t.backgroundColor = [UIColor clearColor];
        t.contentMode = UIViewContentModeRedraw;
        t.znacka = znacky[i];
        t.tag = tlacitka[i];
        [t addTarget:self action:@selector(tlacitkoListy:) forControlEvents:UIControlEventTouchUpInside];
        [_ovladani addSubview:t];
        [t release];
    }
    [_ovladaniPlocha addSubview:_ovladani];
    _klavesy = [[UIView alloc] initWithFrame:CGRectZero];
    for (size_t i = 0; i < POCET_KLAVES_RADY; i++) {
        OSKlavesaRady k = kRadaKlaves[i];
        if (k.tag < 0) continue;
        OSKlavesa *klavesa = [[OSKlavesa alloc] initWithFrame:CGRectZero];
        klavesa.backgroundColor = [UIColor clearColor];
        klavesa.tag = k.tag;
        klavesa.symbol = [NSString stringWithUTF8String:k.symbol];
        klavesa.slovo = [NSString stringWithUTF8String:k.slovo];
        klavesa.kontrolka = k.tag >= 400;
        klavesa.znacka = k.tag == 300 + KlavesaVlevo ? ZnackaVlevo : k.tag == 300 + KlavesaVpravo ? ZnackaVpravo
                       : k.tag == 300 + KlavesaNahoru ? ZnackaNahoru : k.tag == 300 + KlavesaDolu ? ZnackaDolu : -1;
        [klavesa addTarget:self action:@selector(klavesa:) forControlEvents:UIControlEventTouchUpInside];
        [_klavesy addSubview:klavesa];
        [klavesa release];
    }
    [_ovladaniPlocha addSubview:_klavesy];
    [plocha addSubview:_ovladaniPlocha];
    _psani = [[UITextField alloc] initWithFrame:CGRectMake(-1000, -1000, 10, 10)];
    _psani.delegate = self;
    _psani.text = @" "; // vzdy jedna mezera, aby slo mazat i v prazdnem poli
    _psani.autocorrectionType = UITextAutocorrectionTypeNo;
    _psani.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _psani.spellCheckingType = UITextSpellCheckingTypeNo;
    _psani.keyboardAppearance = UIKeyboardAppearanceAlert; // tmava klavesnice
    [plocha addSubview:_psani];

    // Vyber rezimu: ukaze se pri kazdem otevreni appky
    _vyber = [[UIView alloc] initWithFrame:plocha.bounds];
    _vyber.backgroundColor = [UIColor colorWithPatternImage:[UIImage imageNamed:@"Platno.png"]];
    OSLista *nahore = [[[OSLista alloc] initWithFrame:CGRectZero] autorelease];
    nahore.contentMode = UIViewContentModeRedraw;
    nahore.tag = 1;
    UILabel *nazevVyberu = VytlacenyNapis(20, YES, [UIColor whiteColor]);
    nazevVyberu.text = @"Older Sidecar";
    nazevVyberu.frame = CGRectMake(0, 0, 1, 44);
    nazevVyberu.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [nahore addSubview:nazevVyberu];
    [_vyber addSubview:nahore];
    UILabel *otazka = VytlacenyNapis(24, YES, [UIColor colorWithRed:0.86 green:0.88 blue:0.91 alpha:1]);
    otazka.tag = 2;
    [_vyber addSubview:otazka];
    for (int i = 0; i < 2; i++) {
        OSVelkeTlacitko *t = [[OSVelkeTlacitko alloc] initWithFrame:CGRectZero];
        t.backgroundColor = [UIColor clearColor];
        t.znacka = i == 0 ? ZnackaOko : ZnackaTouchpad;
        t.tag = i == 0 ? 10 + RezimObrazovka : 10 + RezimOvladani;
        [t addTarget:self action:@selector(zvolRezim:) forControlEvents:UIControlEventTouchUpInside];
        [_vyber addSubview:t];
        [t release];
    }
    OSTextoveTlacitko *jazyk = [[[OSTextoveTlacitko alloc] initWithFrame:CGRectZero] autorelease];
    jazyk.backgroundColor = [UIColor clearColor];
    jazyk.contentMode = UIViewContentModeRedraw;
    jazyk.tag = 3;
    [jazyk addTarget:self action:@selector(ukazJazyky) forControlEvents:UIControlEventTouchUpInside];
    [_vyber addSubview:jazyk];
    [plocha addSubview:_vyber];

    _tlacitkoMenu = [[OSTlacitkoListy alloc] initWithFrame:CGRectMake(14, 14, 66, 54)];
    _tlacitkoMenu.backgroundColor = [UIColor clearColor];
    _tlacitkoMenu.znacka = ZnackaMenu;
    _tlacitkoMenu.hidden = YES;
    [_tlacitkoMenu addTarget:self action:@selector(zpetDoMenu) forControlEvents:UIControlEventTouchUpInside];
    [plocha addSubview:_tlacitkoMenu];

    self.view = plocha;
    [plocha release];
    _stavKlic = [NapisPripoj() copy];
    [self nastavTexty];
}

- (void)viewWillLayoutSubviews {
    CGRect r = self.view.bounds;
    CGFloat w = r.size.width, h = r.size.height;
    _cekani.frame = r;
    _lista.frame = CGRectMake(0, 0, w, 44);
    _stinListy.frame = CGRectMake(0, 44, w, 7);
    _obrazek.center = CGPointMake(w / 2, 44 + (h - 44) * 0.36);
    _kolecko.center = CGPointMake(w / 2, h * 0.68);
    _napis.frame = CGRectMake(80, h * 0.72, w - 160, 100); // i triradkove hlaseni
    _napoveda.frame = CGRectMake(40, h - 58, w - 80, 46); // delsi preklady se zalomi
    // ovladani: lista nahore (klavesnice vlevo, hudba uprostred, hlasitost vpravo), pod ni touchpad
    _ovladaniPlocha.frame = r;
    _podlozka.frame = r;
    CGRect touchpad = CGRectMake(70, 178, w - 140, h - 206);
    _podlozka.touchpad = touchpad;
    [_podlozka setNeedsDisplay];
    CGFloat sirkaListy = w - 48;
    _ovladani.frame = CGRectMake(24, 22, sirkaListy, 66);
    CGFloat celkem = 0;
    for (size_t i = 0; i < POCET_NA_LISTE; i++) celkem += kPoradiListy[i] < 0 ? 18 : 68;
    CGFloat x = (sirkaListy - celkem) / 2;
    for (size_t i = 0; i < POCET_NA_LISTE; i++) {
        if (kPoradiListy[i] < 0) { x += 18; continue; }
        [_ovladani viewWithTag:kPoradiListy[i]].frame = CGRectMake(x, 6, 64, 54);
        x += 68;
    }
    // rada klaves pod listou, na stred
    celkem = 0;
    for (size_t i = 0; i < POCET_KLAVES_RADY; i++) celkem += kRadaKlaves[i].sirka + (kRadaKlaves[i].tag < 0 ? 0 : 6);
    _klavesy.frame = CGRectMake((w - celkem) / 2, 102, celkem, 62);
    x = 0;
    for (size_t i = 0; i < POCET_KLAVES_RADY; i++) {
        if (kRadaKlaves[i].tag < 0) { x += kRadaKlaves[i].sirka; continue; }
        [_klavesy viewWithTag:kRadaKlaves[i].tag].frame = CGRectMake(x, 0, kRadaKlaves[i].sirka, 62);
        x += kRadaKlaves[i].sirka + 6;
    }
    _napovedaOvladani.frame = CGRectMake(CGRectGetMinX(touchpad) + 50, CGRectGetMidY(touchpad) - 70, touchpad.size.width - 100, 90);
    _stavOvladani.frame = CGRectMake(CGRectGetMinX(touchpad) + 40, CGRectGetMaxY(touchpad) - 100, touchpad.size.width - 80, 80);
    // vyber rezimu: dve velka tlacitka vedle sebe
    _vyber.frame = r;
    [_vyber viewWithTag:1].frame = CGRectMake(0, 0, w, 44);
    [_vyber viewWithTag:2].frame = CGRectMake(40, h / 2 - 220, w - 80, 40);
    [_vyber viewWithTag:10 + RezimObrazovka].frame = CGRectMake(w / 2 - 430, h / 2 - 160, 420, 300);
    [_vyber viewWithTag:10 + RezimOvladani].frame = CGRectMake(w / 2 + 10, h / 2 - 160, 420, 300);
    [_vyber viewWithTag:3].frame = CGRectMake(w / 2 - 190, h - 92, 380, 60);
    _jazyky.frame = r;
    [_jazyky viewWithTag:4].center = CGPointMake(w / 2, h / 2);
}

#pragma mark - Menu: jazyk a navrat zpet

- (void)ukazJazyky {
    if (!_jazyky) { // tmavy zavoj a na nem panel z cerneho skla s tlacitky jazyku
        _jazyky = [[UIView alloc] initWithFrame:self.view.bounds];
        _jazyky.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        UIControl *zavoj = [[[UIControl alloc] initWithFrame:_jazyky.bounds] autorelease];
        zavoj.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [zavoj addTarget:self action:@selector(skryjJazyky) forControlEvents:UIControlEventTouchUpInside];
        [_jazyky addSubview:zavoj];
        OSTouchBar *panel = [[[OSTouchBar alloc] initWithFrame:CGRectMake(0, 0, 720, 436)] autorelease];
        panel.backgroundColor = [UIColor clearColor];
        panel.tag = 4;
        UILabel *nadpis = VytlacenyNapis(22, YES, [UIColor whiteColor]);
        nadpis.frame = CGRectMake(0, 16, 720, 32);
        nadpis.tag = 5;
        [panel addSubview:nadpis];
        for (int i = 0; i < POCET_JAZYKU; i++) {
            OSTextoveTlacitko *t = [[OSTextoveTlacitko alloc] initWithFrame:CGRectMake(24 + (i % 3) * 228, 62 + (i / 3) * 72, 216, 64)];
            t.backgroundColor = [UIColor clearColor];
            t.tag = 200 + i;
            [t addTarget:self action:@selector(vyberJazyk:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:t];
            [t release];
        }
        [_jazyky addSubview:panel];
        [self.view addSubview:_jazyky];
        [self.view setNeedsLayout];
    }
    NSString *kod = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jazyk"];
    UIView *panel = [_jazyky viewWithTag:4];
    ((UILabel *)[panel viewWithTag:5]).text = Preklad(@"Language");
    for (int i = 0; i < POCET_JAZYKU; i++) {
        OSTextoveTlacitko *t = (OSTextoveTlacitko *)[panel viewWithTag:200 + i];
        t.nadpis = i == 0 ? Preklad(@"Automatic (iPad language)") : kJazyky[i][1];
        t.vybrane = [kJazyky[i][0] isEqualToString:kod ?: @""];
        [t setNeedsDisplay];
    }
    _jazyky.hidden = NO;
    _jazyky.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ _jazyky.alpha = 1; }];
}

- (void)skryjJazyky {
    [UIView animateWithDuration:0.2 animations:^{ _jazyky.alpha = 0; } completion:^(BOOL hotovo) { _jazyky.hidden = YES; }];
}

- (void)vyberJazyk:(UIButton *)tlacitko {
    NSString *kod = kJazyky[tlacitko.tag - 200][0];
    [[NSUserDefaults standardUserDefaults] setObject:kod forKey:@"Jazyk"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NastavJazyk(kod);
    [self nastavTexty];
    [self skryjJazyky];
}

- (void)zpetDoMenu {
    [_psani resignFirstResponder];
    [self skryjTlacitkoMenu];
    _rezim = 0;
    uint32_t rezim = 0; // Mac: iPad je v menu, nic neovlada
    [self posli:ZpravaRezim hodnoty:&rezim pocet:1];
    _vyber.alpha = 0;
    _vyber.hidden = NO;
    [UIView animateWithDuration:0.3 animations:^{ _vyber.alpha = 1; }];
}

// Jen obrazovka: tuknuti na chvili ukaze tlacitko menu v rohu (a dalsi tuknuti ho schova)
- (void)prepniTlacitkoMenu {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(skryjTlacitkoMenu) object:nil];
    BOOL ukazat = _tlacitkoMenu.hidden;
    _tlacitkoMenu.hidden = !ukazat;
    if (ukazat) [self performSelector:@selector(skryjTlacitkoMenu) withObject:nil afterDelay:4];
}

- (void)skryjTlacitkoMenu {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(skryjTlacitkoMenu) object:nil];
    _tlacitkoMenu.hidden = YES;
}

- (void)zvolRezim:(UIButton *)tlacitko {
    _rezim = (uint32_t)(tlacitko.tag - 10);
    uint32_t rezim = _rezim;
    [self posli:ZpravaRezim hodnoty:&rezim pocet:1];
    _ovladaniPlocha.hidden = _rezim != RezimOvladani;
    [self prelozStav];
    [UIView animateWithDuration:0.3 animations:^{ _vyber.alpha = 0; } completion:^(BOOL hotovo) { _vyber.hidden = YES; }];
}

- (void)tlacitkoListy:(UIButton *)tlacitko {
    if (tlacitko.tag == 101) {
        [self zpetDoMenu];
        return;
    }
    if (tlacitko.tag == 100) { // klavesnice: otevrit / zavrit
        if (_psani.isFirstResponder) [_psani resignFirstResponder];
        else [_psani becomeFirstResponder];
        return;
    }
    uint32_t klavesa[2] = { (uint32_t)tlacitko.tag, 0 }; // tlacitka Macu a hudby bez modifikatoru
    [self posli:ZpravaKlavesa hodnoty:klavesa pocet:2];
}

// Rada klaves: esc, tab a sipky se poslou (se zapnutymi modifikatory), modifikator se zapne/vypne
- (void)klavesa:(OSKlavesa *)klavesa {
    if (klavesa.tag >= 400) {
        _modifikatory ^= (uint32_t)(klavesa.tag - 400);
        [self ukazModifikatory];
        return;
    }
    uint32_t hodnoty[2] = { (uint32_t)(klavesa.tag - 300), _modifikatory };
    [self posli:ZpravaKlavesa hodnoty:hodnoty pocet:2];
    [self vynulujModifikatory];
}

- (void)ukazModifikatory {
    for (int bit = 1; bit <= 8; bit <<= 1)
        ((OSKlavesa *)[_klavesy viewWithTag:400 + bit]).zapnuto = (_modifikatory & bit) != 0;
}

// Modifikator plati jen pro jednu dalsi akci, pak zhasne (jako Shift na iPadu)
- (void)vynulujModifikatory {
    if (!_modifikatory) return;
    _modifikatory = 0;
    [self ukazModifikatory];
}

#pragma mark - Psani na Mac

// Text (nebo se zapnutym modifikatorem zkratka, napr. ⌘ + c) do Macu
- (void)posliText:(NSString *)text {
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!d.length || d.length > 4000) return;
    BOOL zkratka = _modifikatory != 0;
    uint32_t hlavicka[3] = { htonl(zkratka ? ZpravaZkratka : ZpravaText), htonl((uint32_t)d.length + (zkratka ? 4 : 0)), htonl(_modifikatory) };
    [_zamek lock];
    if (_mac >= 0 && PisVse(_mac, hlavicka, zkratka ? 12 : 8)) PisVse(_mac, d.bytes, d.length);
    [_zamek unlock];
    [self vynulujModifikatory];
}

- (void)posliPopis:(uint32_t)typ text:(NSString *)text {
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t hlavicka[2] = { htonl(typ), htonl((uint32_t)d.length) };
    [_zamek lock];
    if (_mac >= 0 && PisVse(_mac, hlavicka, sizeof hlavicka)) PisVse(_mac, d.bytes, d.length);
    [_zamek unlock];
}

// Jmeno, model a verze iOS, aby je Mac ukazal v menu
- (void)posliInfo {
    UIDevice *zarizeni = [UIDevice currentDevice];
    [self posliPopis:ZpravaInfo text:[NSString stringWithFormat:@"%@\n%@\niOS %@", zarizeni.name, NazevModelu(), zarizeni.systemVersion]];
    [self posliBaterii];
}

- (void)posliBaterii {
    UIDevice *zarizeni = [UIDevice currentDevice];
    float uroven = zarizeni.batteryLevel;
    UIDeviceBatteryState s = zarizeni.batteryState;
    uint32_t hodnoty[2] = { uroven < 0 ? 999 : (uint32_t)lroundf(uroven * 100),
                            s == UIDeviceBatteryStateCharging ? BaterieNabiji : s == UIDeviceBatteryStateFull ? BaterieNabito
                          : s == UIDeviceBatteryStateUnplugged ? BaterieNaBaterii : BaterieNevi };
    [self posli:ZpravaBaterie hodnoty:hodnoty pocet:2];
}

// Pole drzi stale jednu mezeru: napsane i smazane se posle na Mac a pole zustane, jak je
- (BOOL)textField:(UITextField *)pole shouldChangeCharactersInRange:(NSRange)rozsah replacementString:(NSString *)text {
    if (text.length) {
        [self posliText:text];
    } else if (rozsah.length) {
        uint32_t klavesa[2] = { KlavesaMazat, _modifikatory };
        [self posli:ZpravaKlavesa hodnoty:klavesa pocet:2];
        [self vynulujModifikatory];
    }
    return NO;
}

- (BOOL)textFieldShouldReturn:(UITextField *)pole {
    uint32_t klavesa[2] = { KlavesaEnter, _modifikatory };
    [self posli:ZpravaKlavesa hodnoty:klavesa pocet:2];
    [self vynulujModifikatory];
    return NO;
}

// Plynule prolnuti mezi cekanim a obrazem z Macu
- (void)prolni {
    CATransition *prechod = [CATransition animation];
    prechod.type = kCATransitionFade;
    prechod.duration = 0.35;
    [self.view.layer addAnimation:prechod forKey:nil];
}

// Texty v zvolenem jazyce; vola se pri startu a po zmene jazyka
- (void)nastavTexty {
    _napoveda.text = Preklad(@"Two fingers = zoom  ·  one finger = move the zoomed picture");
    _napovedaOvladani.text = Preklad(@"One finger = pointer  ·  tap = click  ·  two fingers = scroll  ·  two-finger tap = right click  ·  double tap and drag = drag");
    ((UILabel *)[_vyber viewWithTag:2]).text = Preklad(@"What would you like to do?");
    OSVelkeTlacitko *obrazovka = (OSVelkeTlacitko *)[_vyber viewWithTag:10 + RezimObrazovka];
    obrazovka.nadpis = Preklad(@"Screen only");
    obrazovka.popis = Preklad(@"Watch the Mac's screen. Tapping does nothing; spread two fingers to zoom.");
    [obrazovka setNeedsDisplay];
    OSVelkeTlacitko *ovladani = (OSVelkeTlacitko *)[_vyber viewWithTag:10 + RezimOvladani];
    ovladani.nadpis = Preklad(@"Control the Mac");
    ovladani.popis = Preklad(@"The iPad becomes a trackpad, keyboard and music remote.");
    [ovladani setNeedsDisplay];
    NSString *kod = [[NSUserDefaults standardUserDefaults] stringForKey:@"Jazyk"];
    NSString *nazev = Preklad(@"Automatic (iPad language)");
    for (int i = 1; i < POCET_JAZYKU; i++) if ([kJazyky[i][0] isEqualToString:kod]) nazev = kJazyky[i][1];
    OSTextoveTlacitko *jazyk = (OSTextoveTlacitko *)[_vyber viewWithTag:3];
    jazyk.nadpis = [NSString stringWithFormat:Preklad(@"Language: %@"), nazev];
    [jazyk setNeedsDisplay];
    [self prelozStav];
}

// V rezimu ovladani se obraz necheka: "cekam na obraz" tam znamena, ze touchpad uz ovlada Mac
- (void)prelozStav {
    _napis.text = Preklad(_stavKlic);
    _stavOvladani.text = Preklad([_stavKlic isEqualToString:KLIC(@"Connected, waiting for the picture from the Mac…")]
                                 ? KLIC(@"Connected – the trackpad controls the Mac.") : _stavKlic);
}

- (void)ukazCekani:(NSString *)klic kolecko:(BOOL)kolecko {
    [_stavKlic release];
    _stavKlic = [klic copy];
    [self prelozStav];
    [self prolni];
    self.view.layer.contents = nil;
    _zoom = 1; // po dalsim pripojeni zase cely obraz
    [self nastavVyrez:CGPointZero];
    _cekani.hidden = NO;
    if (kolecko) [_kolecko startAnimating];
    else [_kolecko stopAnimating];
}

- (void)server {
    @autoreleasepool {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        int ano = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &ano, sizeof ano);
        struct sockaddr_in adresa;
        memset(&adresa, 0, sizeof adresa);
        adresa.sin_len = sizeof adresa;
        adresa.sin_family = AF_INET;
        adresa.sin_port = htons(PORT);
        adresa.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // usbmuxd se pripojuje lokalne, z Wi-Fi to nejde
        if (bind(s, (struct sockaddr *)&adresa, sizeof adresa) < 0 || listen(s, 1) < 0) {
            NSLog(@"Port %d nejde otevrit", PORT);
            return;
        }
        for (;;) {
            int mac = accept(s, NULL, NULL);
            if (mac < 0) {
                usleep(100000);
                continue;
            }
            [self obsluzMac:mac];
        }
    }
}

- (void)posli:(uint32_t)typ hodnoty:(const uint32_t *)hodnoty pocet:(int)pocet {
    uint32_t zprava[5];
    zprava[0] = htonl(typ);
    zprava[1] = htonl(pocet * 4);
    for (int i = 0; i < pocet; i++) zprava[2 + i] = htonl(hodnoty[i]);
    [_zamek lock];
    if (_mac >= 0) PisVse(_mac, zprava, (2 + pocet) * 4);
    [_zamek unlock];
}

// Hlaseni Stav... z Macu (klic, prelozi se pri zobrazeni)
static NSString *TextStavu(uint32_t stav) {
    switch (stav) {
        case StavChybiPovoleni: return KLIC(@"Older Sidecar on the Mac needs the Screen Recording permission. Allow it in the setup window on the Mac.");
        case StavObrazovkaSpi: return KLIC(@"The Mac's screen is asleep. Tap to wake it up.");
        case StavMacSpi: return KLIC(@"The Mac is asleep. Wake it up and the picture will come back by itself.");
        default: return KLIC(@"The Mac can't capture its screen right now.");
    }
}

- (void)obsluzMac:(int)mac {
    int ano = 1;
    setsockopt(mac, IPPROTO_TCP, TCP_NODELAY, &ano, sizeof ano);
    [_zamek lock];
    _mac = mac;
    [_zamek unlock];

    uint32_t rozmer[2] = { _sirka, _vyska };
    [self posli:ZpravaAhoj hodnoty:rozmer pocet:2];
    uint32_t rezim = _rezim;
    if (rezim) [self posli:ZpravaRezim hodnoty:&rezim pocet:1]; // at Mac vi, jestli se jen diva, nebo ovlada
    dispatch_async(dispatch_get_main_queue(), ^{ [self posliInfo]; }); // jmeno, model a baterie do menu na Macu
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = YES; // pri pripojeni neusinat
        [self ukazCekani:KLIC(@"Connected, waiting for the picture from the Mac…") kolecko:YES];
    });

    BOOL hlidat = NO;           // Mac posila "zivot" (starsi verze ne) -> dlouhe ticho = Mac neodpovida
    BOOL ticho = NO;            // spojeni skoncilo, protoze Mac prestal odpovidat
    uint32_t posledniStav = 0;  // posledni hlaseni z Macu od posledniho snimku
    for (;;) {
        uint32_t hlavicka[2];
        errno = 0;
        if (!CtiVse(mac, hlavicka, sizeof hlavicka)) { ticho = errno == EAGAIN || errno == EWOULDBLOCK; break; }
        uint32_t typ = ntohl(hlavicka[0]), delka = ntohl(hlavicka[1]);
        if (delka > 16 * 1024 * 1024) break;
        NSMutableData *data = [[NSMutableData alloc] initWithLength:delka];
        errno = 0;
        BOOL ok = CtiVse(mac, data.mutableBytes, delka);
        CGImageRef obrazek = (ok && typ == ZpravaSnimek) ? RozbalJPEG(data) : NULL;
        uint32_t stav = (ok && typ == ZpravaStav && delka >= 4) ? ntohl(*(uint32_t *)data.bytes) : 0;
        [data release];
        if (!ok) { ticho = errno == EAGAIN || errno == EWOULDBLOCK; break; }
        if (typ == ZpravaZivot) {
            if (!hlidat) { // od ted: 7 s bez jedine zpravy = Mac spi nebo je pryc
                struct timeval limit = { 7, 0 };
                setsockopt(mac, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof limit);
                hlidat = YES;
            }
            continue;
        }
        if (stav == StavProbuzeno) { // displej Macu se rozsvitil: obraz (nebo ovladani) jde zas
            posledniStav = 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self ukazCekani:KLIC(@"Connected, waiting for the picture from the Mac…") kolecko:YES];
            });
            continue;
        }
        if (stav) { // Mac obraz neposle – napsat proc
            posledniStav = stav;
            NSString *proc = TextStavu(stav);
            dispatch_async(dispatch_get_main_queue(), ^{ [self ukazCekani:proc kolecko:NO]; });
            continue;
        }
        if (typ != ZpravaSnimek) continue;
        posledniStav = 0;
        // Potvrdit hned, Mac mezitim pripravi dalsi snimek
        [self posli:ZpravaHotovo hodnoty:NULL pocet:0];
        if (!obrazek) continue;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (_rezim == RezimOvladani) { // v rezimu ovladani se obrazovka Macu neukazuje
                CGImageRelease(obrazek);
                return;
            }
            if (!_cekani.hidden) { // prvni snimek: cekaci obrazovka se prolne do obrazu z Macu
                [self prolni];
                _cekani.hidden = YES;
                [_kolecko stopAnimating];
            }
            self.view.layer.contents = (id)obrazek;
            CGImageRelease(obrazek);
        });
    }

    [_zamek lock];
    _mac = -1;
    [_zamek unlock];
    close(mac);
    // Mac spi nebo neodpovida: hlaseni nechat svitit (iPad nezhasne), az se Mac probudi, pripoji se sam
    NSString *klic = posledniStav == StavMacSpi ? TextStavu(StavMacSpi)
                   : ticho ? KLIC(@"The Mac stopped responding. It may be asleep – wake it up and the picture will come back by itself.")
                   : NapisPripoj();
    BOOL nezhasinat = posledniStav == StavMacSpi || ticho;
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication sharedApplication].idleTimerDisabled = nezhasinat;
        [self ukazCekani:klic kolecko:NO];
    });
}

#pragma mark - Dotyky

static NSArray *AktivniDotyky(UIEvent *udalost) {
    NSMutableArray *a = [NSMutableArray array];
    for (UITouch *t in [udalost allTouches])
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) [a addObject:t];
    return a;
}

static CGPoint StredDotyku(NSArray *dotyky, UIView *pohled) {
    CGPoint s = CGPointZero;
    for (UITouch *t in dotyky) {
        CGPoint p = [t locationInView:pohled];
        s.x += p.x / dotyky.count;
        s.y += p.y / dotyky.count;
    }
    return s;
}

// Bod na displeji iPadu -> bod v obraze z Macu (0..1) s ohledem na zvetseni
- (CGPoint)doObrazu:(CGPoint)p {
    CGSize v = self.view.bounds.size;
    return CGPointMake(_vyrez.x + p.x / v.width / _zoom, _vyrez.y + p.y / v.height / _zoom);
}

// Zvetseni = vrstva ukazuje jen cast snimku (contentsRect), roztazenou pres cely displej
- (void)nastavVyrez:(CGPoint)roh {
    CGFloat w = 1 / _zoom;
    _vyrez = CGPointMake(MIN(MAX(roh.x, 0), 1 - w), MIN(MAX(roh.y, 0), 1 - w));
    self.view.layer.contentsRect = CGRectMake(_vyrez.x, _vyrez.y, w, w);
}

- (void)zacniGesto:(NSArray *)dotyky {
    CGPoint a = [[dotyky objectAtIndex:0] locationInView:self.view], b = [[dotyky objectAtIndex:1] locationInView:self.view];
    _zoomNaZacatku = _zoom;
    _vzdalenostNaZacatku = MAX(hypot(a.x - b.x, a.y - b.y), 1);
    _bodNaZacatku = [self doObrazu:CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2)];
}

- (void)posunGesto:(NSArray *)dotyky {
    if (dotyky.count < 2) return;
    CGPoint a = [[dotyky objectAtIndex:0] locationInView:self.view], b = [[dotyky objectAtIndex:1] locationInView:self.view];
    CGPoint stred = CGPointMake((a.x + b.x) / 2, (a.y + b.y) / 2);
    _zoom = MIN(MAX(_zoomNaZacatku * hypot(a.x - b.x, a.y - b.y) / _vzdalenostNaZacatku, 1), 4);
    if (_zoom < 1.05) _zoom = 1;
    // bod obrazu, ktery byl na zacatku mezi prsty, zustane mezi nimi (zvetseni i posun najednou)
    CGSize v = self.view.bounds.size;
    [self nastavVyrez:CGPointMake(_bodNaZacatku.x - stred.x / v.width / _zoom, _bodNaZacatku.y - stred.y / v.height / _zoom)];
}

// --- Jen obrazovka: zvetseni a posun obrazu, nic se neposila ---

- (void)lupaZacatek:(UIEvent *)udalost {
    NSArray *a = AktivniDotyky(udalost);
    if (_nejvicPrstu == 0) { // nova sada dotyku: mozna je to tuknuti
        _zacatek = [NSDate timeIntervalSinceReferenceDate];
        _ujeto = 0;
    }
    _nejvicPrstu = MAX(_nejvicPrstu, a.count);
    if (a.count >= 2) {
        _gesto = YES;
        [self zacniGesto:a];
    } else if (!_gesto && a.count == 1) {
        _posledniBod = [[a objectAtIndex:0] locationInView:self.view];
    }
}

- (void)lupaPohyb:(UIEvent *)udalost {
    NSArray *a = AktivniDotyky(udalost);
    if (_gesto) {
        [self posunGesto:a];
        return;
    }
    if (a.count != 1) return;
    CGPoint p = [[a objectAtIndex:0] locationInView:self.view];
    _ujeto += hypot(p.x - _posledniBod.x, p.y - _posledniBod.y);
    if (_zoom > 1) { // jeden prst posouva zvetseny obraz
        CGSize v = self.view.bounds.size;
        [self nastavVyrez:CGPointMake(_vyrez.x - (p.x - _posledniBod.x) / v.width / _zoom, _vyrez.y - (p.y - _posledniBod.y) / v.height / _zoom)];
    }
    _posledniBod = p;
}

- (void)lupaKonec:(UIEvent *)udalost {
    NSArray *zbyle = AktivniDotyky(udalost);
    if (!zbyle.count) {
        BOOL tuk = _nejvicPrstu == 1 && [NSDate timeIntervalSinceReferenceDate] - _zacatek < 0.3 && _ujeto < 12;
        _nejvicPrstu = 0;
        if (tuk) [self prepniTlacitkoMenu];
    }
    if (_gesto) {
        if (zbyle.count >= 2) [self zacniGesto:zbyle];
        else if (zbyle.count == 0) _gesto = NO;
    } else if (zbyle.count == 1) {
        _posledniBod = [[zbyle objectAtIndex:0] locationInView:self.view];
    }
}

// --- Ovladani: iPad jako touchpad ---

// posle cele body posunu, desetinny zbytek si pamatuje na priste
- (void)posliPosun:(uint32_t)typ x:(CGFloat)x y:(CGFloat)y zbytek:(CGPoint *)zbytek {
    zbytek->x += x;
    zbytek->y += y;
    int32_t cx = (int32_t)zbytek->x, cy = (int32_t)zbytek->y;
    if (!cx && !cy) return;
    zbytek->x -= cx;
    zbytek->y -= cy;
    uint32_t hodnoty[2] = { (uint32_t)cx, (uint32_t)cy };
    [self posli:typ hodnoty:hodnoty pocet:2];
}

- (void)touchpadZacatek:(UIEvent *)udalost {
    NSArray *a = AktivniDotyky(udalost);
    NSTimeInterval ted = [NSDate timeIntervalSinceReferenceDate];
    if (_nejvicPrstu == 0) { // nova sada dotyku
        _zacatek = ted;
        _ujeto = 0;
        _tahnu = NO;
        _mozneTazeni = ted - _posledniTuk < 0.35;
    }
    _nejvicPrstu = MAX(_nejvicPrstu, a.count);
    _posledniBod = StredDotyku(a, self.view);
}

- (void)touchpadPohyb:(UIEvent *)udalost {
    NSArray *a = AktivniDotyky(udalost);
    if (!a.count) return;
    CGPoint bod = StredDotyku(a, self.view);
    CGFloat dx = bod.x - _posledniBod.x, dy = bod.y - _posledniBod.y;
    _posledniBod = bod;
    _ujeto += hypot(dx, dy);
    if (a.count >= 2) { // dva prsty = posouvani obsahu (obsah jde s prsty)
        [self posliPosun:ZpravaKolecko x:dx * 2 y:dy * 2 zbytek:&_zbytekKolecka];
        return;
    }
    if (_nejvicPrstu >= 2) return; // po zvednuti jednoho ze dvou prstu kurzorem neskakat
    if (_mozneTazeni && !_tahnu && _ujeto > 10) { // tuk a hned tah = drzet tlacitko
        _tahnu = YES;
        uint32_t dole[3] = { 0, 1, _modifikatory };
        [self posli:ZpravaTlacitko hodnoty:dole pocet:3];
    }
    CGFloat zrychleni = 1.4 + MIN(hypot(dx, dy) / 6, 2.6); // rychly tah dojede dal, pomaly je presny
    [self posliPosun:ZpravaPohyb x:dx * zrychleni y:dy * zrychleni zbytek:&_zbytekPohybu];
}

- (void)touchpadKonec:(UIEvent *)udalost {
    NSArray *zbyle = AktivniDotyky(udalost);
    if (zbyle.count) { // nektery prst jeste lezi: pokracovat od nej, at kurzor neskoci
        _posledniBod = StredDotyku(zbyle, self.view);
        return;
    }
    NSTimeInterval ted = [NSDate timeIntervalSinceReferenceDate];
    if (_tahnu) {
        uint32_t nahore[3] = { 0, 0, _modifikatory };
        [self posli:ZpravaTlacitko hodnoty:nahore pocet:3];
        _tahnu = NO;
        [self vynulujModifikatory];
    } else if (ted - _zacatek < 0.3 && _ujeto < 12) { // kratky dotyk bez pohybu = tuk
        if (_nejvicPrstu >= 2) {
            uint32_t pravy[3] = { 1, 1, _modifikatory };
            [self posli:ZpravaKlik hodnoty:pravy pocet:3];
            [self vynulujModifikatory];
        } else {
            uint32_t klik[3] = { 0, _mozneTazeni ? 2 : 1, _modifikatory }; // druhy rychly tuk = dvojklik
            [self posli:ZpravaKlik hodnoty:klik pocet:3];
            [self vynulujModifikatory];
            _posledniTuk = _mozneTazeni ? 0 : ted;
        }
    }
    _nejvicPrstu = 0;
}

- (void)touchesBegan:(NSSet *)dotyky withEvent:(UIEvent *)udalost {
    if (_rezim == RezimOvladani) [self touchpadZacatek:udalost];
    else if (_rezim == RezimObrazovka) [self lupaZacatek:udalost];
}

- (void)touchesMoved:(NSSet *)dotyky withEvent:(UIEvent *)udalost {
    if (_rezim == RezimOvladani) [self touchpadPohyb:udalost];
    else if (_rezim == RezimObrazovka) [self lupaPohyb:udalost];
}

- (void)touchesEnded:(NSSet *)dotyky withEvent:(UIEvent *)udalost {
    if (_rezim == RezimOvladani) [self touchpadKonec:udalost];
    else if (_rezim == RezimObrazovka) [self lupaKonec:udalost];
}

- (void)touchesCancelled:(NSSet *)dotyky withEvent:(UIEvent *)udalost { [self touchesEnded:dotyky withEvent:udalost]; }

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)orientace { return UIInterfaceOrientationIsLandscape(orientace); }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_klavesy release];
    [_cekani release];
    [_lista release];
    [_stinListy release];
    [_obrazek release];
    [_napis release];
    [_napoveda release];
    [_kolecko release];
    [_vyber release];
    [_ovladani release];
    [_ovladaniPlocha release];
    [_podlozka release];
    [_stavOvladani release];
    [_napovedaOvladani release];
    [_stavKlic release];
    [_jazyky release];
    [_tlacitkoMenu release];
    [_psani release];
    [_zamek release];
    [super dealloc];
}
@end

@interface OSAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, retain) UIWindow *window;
@end

@implementation OSAppDelegate
@synthesize window = _window;

- (BOOL)application:(UIApplication *)aplikace didFinishLaunchingWithOptions:(NSDictionary *)volby {
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];
    self.window.rootViewController = [[[OSDisplejController alloc] init] autorelease];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)dealloc {
    [_window release];
    [super dealloc];
}
@end

int main(int argc, char *argv[]) {
    signal(SIGPIPE, SIG_IGN); // odpojeny kabel nesmi aplikaci shodit
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([OSAppDelegate class]));
    }
}
