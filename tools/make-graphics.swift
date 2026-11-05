// Vygeneruje veskerou grafiku Older Sidecar ve starem skeuomorfnim stylu (iOS 6 / Mac OS X):
// ikonu (retro sajdkara se starym iPadem jako pasazerem), obrazek pro iPad, lnene platno a kartacovany hlinik.
// Textury vznikaji klasickym postupem: sum rozmazany jednim (hlinik) nebo dvema smery (platno).
// Pouziti z korene repozitare: swiftc tools/make-graphics.swift -o /tmp/make-graphics && /tmp/make-graphics
import AppKit
import CoreImage


let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func barva(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: rgb, components: [r, g, b, a])! }
func sedá(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { barva(v, v, v, a) }
func prechod(_ c: CGContext, _ barvy: [CGColor], _ mista: [CGFloat]? = nil, _ od: CGPoint, _ k: CGPoint) {
    let g = CGGradient(colorsSpace: rgb, colors: barvy as CFArray, locations: mista)!
    c.drawLinearGradient(g, start: od, end: k, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func kruhPrechod(_ c: CGContext, _ barvy: [CGColor], _ mista: [CGFloat]? = nil, _ stred: CGPoint, _ r: CGFloat) {
    let g = CGGradient(colorsSpace: rgb, colors: barvy as CFArray, locations: mista)!
    c.drawRadialGradient(g, startCenter: stred, startRadius: 0, endCenter: stred, endRadius: r, options: [.drawsAfterEndLocation])
}
func vOrezu(_ c: CGContext, _ cesta: CGPath, _ kresli: () -> Void) {
    c.saveGState(); c.addPath(cesta); c.clip(); kresli(); c.restoreGState()
}
func vypln(_ c: CGContext, _ cesta: CGPath, _ b: CGColor) { c.addPath(cesta); c.setFillColor(b); c.fillPath() }
func tah(_ c: CGContext, _ cesta: CGPath, _ b: CGColor, _ w: CGFloat) {
    c.addPath(cesta); c.setStrokeColor(b); c.setLineWidth(w); c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
}
func stin(_ c: CGContext, _ k: CGFloat, dolu: CGFloat, rozmazani: CGFloat, alfa: CGFloat) {
    c.setShadow(offset: CGSize(width: 0, height: -dolu * k), blur: rozmazani * k, color: sedá(0, alfa))
}
// chrom jako trubka: vrstvene tahy od tmave hrany ke svetlemu odlesku
func chromTah(_ c: CGContext, _ cesta: CGPath, _ w: CGFloat) {
    tah(c, cesta, sedá(0.22), w)
    tah(c, cesta, sedá(0.55), w * 0.82)
    tah(c, cesta.copy(using: [CGAffineTransform(translationX: 0, y: -w * 0.12)])!, sedá(0.88), w * 0.5)
    tah(c, cesta.copy(using: [CGAffineTransform(translationX: 0, y: -w * 0.2)])!, sedá(1, 0.95), w * 0.18)
}

// ---- obrazovka Macu (Leopard): tapeta s polarni zari, listа, okno Finderu, 3D Dock ----
func plochaMacu(_ c: CGContext, _ r: CGRect) {
    c.saveGState(); c.clip(to: r)
    prechod(c, [barva(0.08, 0.10, 0.32), barva(0.20, 0.12, 0.42), barva(0.05, 0.04, 0.16)], [0, 0.55, 1],
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY))
    // zare: dva meky svetly pruh pres tapetu
    c.saveGState()
    c.translateBy(x: r.midX, y: r.midY); c.rotate(by: -0.35); c.scaleBy(x: 1, y: 0.22)
    kruhPrechod(c, [barva(0.75, 0.70, 1.0, 0.85), barva(0.45, 0.35, 0.95, 0.35), barva(0.3, 0.2, 0.8, 0)], [0, 0.35, 1], .zero, r.width * 0.55)
    c.restoreGState()
    c.saveGState()
    c.translateBy(x: r.midX + r.width * 0.2, y: r.midY - r.height * 0.15); c.rotate(by: -0.6); c.scaleBy(x: 1, y: 0.12)
    kruhPrechod(c, [barva(0.95, 0.85, 1.0, 0.7), barva(0.6, 0.5, 1.0, 0)], nil, .zero, r.width * 0.35)
    c.restoreGState()
    // listа
    let lista = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.05)
    c.saveGState(); c.clip(to: lista)
    prechod(c, [sedá(0.97, 0.92), sedá(0.84, 0.92)], nil, CGPoint(x: 0, y: lista.minY), CGPoint(x: 0, y: lista.maxY)); c.restoreGState()
    // okno Finderu
    let okno = CGRect(x: r.minX + r.width * 0.16, y: r.minY + r.height * 0.15, width: r.width * 0.6, height: r.height * 0.56)
    let titulek = okno.height * 0.14
    c.saveGState(); c.setShadow(offset: CGSize(width: 0, height: -r.height * 0.02), blur: r.height * 0.07, color: sedá(0, 0.75))
    vypln(c, CGPath(rect: okno, transform: nil), sedá(0.92)); c.restoreGState()
    c.saveGState(); c.clip(to: CGRect(x: okno.minX, y: okno.minY, width: okno.width, height: titulek))
    prechod(c, [sedá(0.88), sedá(0.66)], nil, CGPoint(x: 0, y: okno.minY), CGPoint(x: 0, y: okno.minY + titulek)); c.restoreGState()
    for (i, b) in [barva(0.95, 0.30, 0.28), barva(0.98, 0.74, 0.18), barva(0.36, 0.78, 0.30)].enumerated() {
        let d = titulek * 0.56
        let k = CGRect(x: okno.minX + titulek * 0.35 + CGFloat(i) * titulek * 0.72, y: okno.minY + (titulek - d) / 2, width: d, height: d)
        c.setFillColor(b); c.fillEllipse(in: k)
        c.setFillColor(sedá(1, 0.55)); c.fillEllipse(in: k.insetBy(dx: d * 0.28, dy: d * 0.3).offsetBy(dx: 0, dy: -d * 0.12))
    }
    let bok = CGRect(x: okno.minX, y: okno.minY + titulek, width: okno.width * 0.28, height: okno.height - titulek)
    vypln(c, CGPath(rect: bok, transform: nil), barva(0.82, 0.86, 0.92))
    vypln(c, CGPath(rect: CGRect(x: bok.maxX, y: bok.minY, width: okno.width - bok.width, height: bok.height), transform: nil), sedá(1))
    for i in 0..<6 { // slozky
        let s = okno.width * 0.12
        let x = bok.maxX + okno.width * 0.06 + CGFloat(i % 3) * s * 1.55
        let y = bok.minY + okno.height * 0.1 + CGFloat(i / 3) * s * 1.4
        let slozka = CGRect(x: x, y: y, width: s, height: s * 0.78)
        c.saveGState(); c.addPath(CGPath(roundedRect: slozka, cornerWidth: s * 0.1, cornerHeight: s * 0.1, transform: nil)); c.clip()
        prechod(c, [barva(0.55, 0.75, 0.98), barva(0.25, 0.50, 0.88)], nil, CGPoint(x: 0, y: slozka.minY), CGPoint(x: 0, y: slozka.maxY))
        c.restoreGState()
    }
    // 3D Dock: lesklá police v perspektive
    let dno = r.maxY - r.height * 0.03, vrch = r.maxY - r.height * 0.1
    let police = CGMutablePath()
    police.move(to: CGPoint(x: r.minX + r.width * 0.2, y: vrch)); police.addLine(to: CGPoint(x: r.maxX - r.width * 0.2, y: vrch))
    police.addLine(to: CGPoint(x: r.maxX - r.width * 0.14, y: dno)); police.addLine(to: CGPoint(x: r.minX + r.width * 0.14, y: dno)); police.closeSubpath()
    vOrezu(c, police) { prechod(c, [sedá(1, 0.25), sedá(1, 0.65)], nil, CGPoint(x: 0, y: vrch), CGPoint(x: 0, y: dno)) }
    tah(c, CGPath(rect: CGRect(x: r.minX + r.width * 0.14, y: dno, width: r.width * 0.72, height: 0.5), transform: nil), sedá(1, 0.8), r.height * 0.008)
    let ikony = [barva(0.30, 0.62, 0.98), barva(0.96, 0.58, 0.16), barva(0.42, 0.80, 0.36), barva(0.88, 0.25, 0.30), barva(0.66, 0.68, 0.72)]
    for (i, b) in ikony.enumerated() {
        let s = r.height * 0.11
        let ik = CGRect(x: r.minX + r.width * 0.27 + CGFloat(i) * r.width * 0.095, y: vrch - s * 0.55, width: s, height: s)
        c.saveGState(); c.addPath(CGPath(roundedRect: ik, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)); c.clip()
        prechod(c, [b.copy(alpha: 1)!, b.copy(alpha: 0.75)!], nil, CGPoint(x: 0, y: ik.minY), CGPoint(x: 0, y: ik.maxY)); c.restoreGState()
    }
    c.restoreGState()
}

// lesk skla: svetly klin pres levou horni cast
func leskSkla(_ c: CGContext, _ cesta: CGPath, sila: CGFloat = 0.3) {
    let b = cesta.boundingBox
    vOrezu(c, cesta) {
        let klin = CGMutablePath()
        klin.move(to: CGPoint(x: b.minX, y: b.minY)); klin.addLine(to: CGPoint(x: b.minX + b.width * 0.72, y: b.minY))
        klin.addCurve(to: CGPoint(x: b.minX, y: b.minY + b.height * 0.85), control1: CGPoint(x: b.minX + b.width * 0.5, y: b.minY + b.height * 0.35),
                      control2: CGPoint(x: b.minX + b.width * 0.2, y: b.minY + b.height * 0.6))
        klin.closeSubpath()
        vOrezu(c, klin) { prechod(c, [sedá(1, sila), sedá(1, sila * 0.15)], nil, CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.minX + b.width * 0.4, y: b.maxY)) }
    }
}

// ---- stary iPad (iPad 2): hlinikovy ram, cerne sklo, tlacitko Domu vpravo ----
func ipad(_ c: CGContext, _ k: CGFloat) {
    let ram = CGRect(x: 365, y: 168, width: 300, height: 232)
    c.saveGState()
    c.translateBy(x: ram.midX, y: ram.maxY); c.rotate(by: -0.09); c.translateBy(x: -ram.midX, y: -ram.maxY)
    let telo = CGPath(roundedRect: ram, cornerWidth: 30, cornerHeight: 30, transform: nil)
    c.saveGState(); stin(c, k, dolu: 10, rozmazani: 24, alfa: 0.5); vypln(c, telo, sedá(0.6)); c.restoreGState()
    vOrezu(c, telo) { prechod(c, [sedá(0.96), sedá(0.72), sedá(0.88), sedá(0.6)], [0, 0.45, 0.55, 1], CGPoint(x: 0, y: ram.minY), CGPoint(x: 0, y: ram.maxY)) }
    let sklo = CGPath(roundedRect: ram.insetBy(dx: 6, dy: 6), cornerWidth: 25, cornerHeight: 25, transform: nil)
    vOrezu(c, sklo) { prechod(c, [sedá(0.16), sedá(0.03)], nil, CGPoint(x: 0, y: ram.minY), CGPoint(x: 0, y: ram.maxY)) }
    let obr = CGRect(x: ram.midX - 118, y: ram.midY - 88.5, width: 236, height: 177)
    plochaMacu(c, obr)
    tah(c, CGPath(rect: obr, transform: nil), sedá(0, 0.6), 1.5)
    let domu = CGRect(x: ram.maxX - 6 - 13 - 11, y: ram.midY - 11, width: 22, height: 22)
    vOrezu(c, CGPath(ellipseIn: domu, transform: nil)) { prechod(c, [sedá(0.02), sedá(0.2)], nil, CGPoint(x: 0, y: domu.minY), CGPoint(x: 0, y: domu.maxY)) }
    tah(c, CGPath(ellipseIn: domu, transform: nil), sedá(0.35), 1.5)
    tah(c, CGPath(roundedRect: domu.insetBy(dx: 7, dy: 7), cornerWidth: 2, cornerHeight: 2, transform: nil), sedá(0.45), 1.2)
    c.setFillColor(sedá(0.18)); c.fillEllipse(in: CGRect(x: ram.minX + 6 + 13 - 4, y: ram.midY - 4, width: 8, height: 8))
    leskSkla(c, sklo, sila: 0.28)
    c.restoreGState()
}

// ---- sajdkara ----
let telo: CGPath = {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 125, y: 482))
    p.addCurve(to: CGPoint(x: 520, y: 382), control1: CGPoint(x: 150, y: 412), control2: CGPoint(x: 300, y: 382))
    p.addCurve(to: CGPoint(x: 955, y: 522), control1: CGPoint(x: 760, y: 382), control2: CGPoint(x: 930, y: 430))
    p.addCurve(to: CGPoint(x: 770, y: 642), control1: CGPoint(x: 972, y: 588), control2: CGPoint(x: 900, y: 642))
    p.addLine(to: CGPoint(x: 330, y: 642))
    p.addCurve(to: CGPoint(x: 125, y: 482), control1: CGPoint(x: 210, y: 642), control2: CGPoint(x: 108, y: 565))
    p.closeSubpath()
    return p
}()
let lak = [barva(0.92, 0.22, 0.18), barva(0.74, 0.07, 0.08), barva(0.52, 0.03, 0.05), barva(0.30, 0.01, 0.03)]

func zavesneRameno(_ c: CGContext, _ k: CGFloat) {
    // trubka k motorce (motorka je mimo obraz vlevo)
    let p = CGMutablePath(); p.move(to: CGPoint(x: 52, y: 605)); p.addLine(to: CGPoint(x: 240, y: 605))
    c.saveGState(); stin(c, k, dolu: 4, rozmazani: 8, alfa: 0.35); chromTah(c, p, 26); c.restoreGState()
    let koule = CGRect(x: 34, y: 585, width: 40, height: 40)
    vOrezu(c, CGPath(ellipseIn: koule, transform: nil)) {
        kruhPrechod(c, [sedá(1), sedá(0.75), sedá(0.3), sedá(0.6)], [0, 0.3, 0.75, 1], CGPoint(x: koule.midX - 7, y: koule.midY - 8), 26)
    }
}

func karoserie(_ c: CGContext, _ k: CGFloat) {
    c.saveGState(); stin(c, k, dolu: 14, rozmazani: 34, alfa: 0.45); vypln(c, telo, lak[2]); c.restoreGState()
    vOrezu(c, telo) {
        prechod(c, lak, [0, 0.4, 0.75, 1], CGPoint(x: 0, y: 380), CGPoint(x: 0, y: 645))
        // odraz obzoru v laku: svetly pas a pod nim ostre tmavsi
        prechod(c, [sedá(1, 0), sedá(1, 0.13), sedá(0, 0.06), sedá(0, 0.28)], [0, 0.46, 0.52, 1], CGPoint(x: 0, y: 490), CGPoint(x: 0, y: 645))
        // lesk na hrbetu
        c.saveGState(); c.translateBy(x: 560, y: 404); c.scaleBy(x: 1, y: 0.09)
        kruhPrechod(c, [sedá(1, 0.8), sedá(1, 0.3), sedá(1, 0)], [0, 0.4, 1], .zero, 360); c.restoreGState()
        // odraz okoli na spicce
        c.saveGState(); c.translateBy(x: 900, y: 475); c.rotate(by: 0.8); c.scaleBy(x: 1, y: 0.22)
        kruhPrechod(c, [sedá(1, 0.55), sedá(1, 0)], nil, .zero, 70); c.restoreGState()
        // odrazene svetlo ze zeme podel spodni hrany
        tah(c, telo.copy(using: [CGAffineTransform(translationX: 0, y: -3)])!, barva(1, 0.45, 0.4, 0.25), 6)
    }
    tah(c, telo, barva(0.20, 0.0, 0.02, 0.45), 1.5)
    // chromova lista po boku
    let lista = CGMutablePath(); lista.move(to: CGPoint(x: 130, y: 532)); lista.addQuadCurve(to: CGPoint(x: 962, y: 540), control: CGPoint(x: 560, y: 508))
    vOrezu(c, telo) { chromTah(c, lista, 15) }
    // zadni svetlo
    let svetlo = CGRect(x: 150, y: 452, width: 30, height: 30)
    c.saveGState(); stin(c, k, dolu: 2, rozmazani: 4, alfa: 0.5)
    vOrezu(c, CGPath(ellipseIn: svetlo.insetBy(dx: -5, dy: -5), transform: nil)) {
        kruhPrechod(c, [sedá(1), sedá(0.7), sedá(0.35)], [0, 0.5, 1], CGPoint(x: svetlo.midX - 6, y: svetlo.midY - 8), 28) }
    c.restoreGState()
    vOrezu(c, CGPath(ellipseIn: svetlo, transform: nil)) {
        kruhPrechod(c, [barva(1, 0.55, 0.45), barva(0.85, 0.05, 0.05), barva(0.4, 0, 0)], [0, 0.45, 1], CGPoint(x: svetlo.midX - 5, y: svetlo.midY - 6), 22) }
}

func kozenyLem(_ c: CGContext, _ k: CGFloat) {
    // polstrovany kozeny okraj kokpitu s prosivanim
    let lem = CGMutablePath()
    lem.move(to: CGPoint(x: 345, y: 398)); lem.addQuadCurve(to: CGPoint(x: 700, y: 398), control: CGPoint(x: 520, y: 368))
    let obrys = lem.copy(strokingWithWidth: 34, lineCap: .round, lineJoin: .round, miterLimit: 10)
    c.saveGState(); stin(c, k, dolu: 5, rozmazani: 10, alfa: 0.55); vypln(c, obrys, barva(0.35, 0.19, 0.08)); c.restoreGState()
    vOrezu(c, obrys) {
        prechod(c, [barva(0.72, 0.46, 0.26), barva(0.50, 0.28, 0.13), barva(0.28, 0.14, 0.05)], [0, 0.45, 1], CGPoint(x: 0, y: 362), CGPoint(x: 0, y: 418))
    }
    c.saveGState()
    c.setLineDash(phase: 0, lengths: [11, 8])
    tah(c, lem.copy(using: [CGAffineTransform(translationX: 0, y: -2)])!, barva(0.98, 0.88, 0.66, 0.85), 3)
    c.restoreGState()
}

func stitek(_ c: CGContext, _ k: CGFloat) {
    // celni sklo: zahnute, oprene dozadu, nahore chromovy ram
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 712, y: 408))
    p.addCurve(to: CGPoint(x: 744, y: 300), control1: CGPoint(x: 704, y: 362), control2: CGPoint(x: 716, y: 318))
    p.addLine(to: CGPoint(x: 784, y: 309))
    p.addCurve(to: CGPoint(x: 762, y: 412), control1: CGPoint(x: 762, y: 330), control2: CGPoint(x: 756, y: 370))
    p.closeSubpath()
    vOrezu(c, p) {
        prechod(c, [barva(0.80, 0.90, 1, 0.55), barva(0.55, 0.70, 0.85, 0.25), barva(0.55, 0.70, 0.85, 0.12)], [0, 0.5, 1],
                CGPoint(x: 0, y: 300), CGPoint(x: 0, y: 412))
        // ostry odlesk podel prední hrany
        let o = CGMutablePath(); o.move(to: CGPoint(x: 768, y: 320)); o.addCurve(to: CGPoint(x: 752, y: 404), control1: CGPoint(x: 756, y: 342), control2: CGPoint(x: 750, y: 372))
        tah(c, o, sedá(1, 0.8), 5)
    }
    tah(c, p, sedá(1, 0.55), 1.5)
    let ram = CGMutablePath(); ram.move(to: CGPoint(x: 712, y: 408)); ram.addCurve(to: CGPoint(x: 744, y: 300), control1: CGPoint(x: 704, y: 362), control2: CGPoint(x: 716, y: 318))
    ram.addLine(to: CGPoint(x: 784, y: 309))
    chromTah(c, ram, 7)
}

func kolo(_ c: CGContext, _ k: CGFloat) {
    let s = CGPoint(x: 545, y: 655)
    // blatnik nad kolem
    let blatnik = CGMutablePath()
    blatnik.addArc(center: s, radius: 146, startAngle: .pi * 1.08, endAngle: .pi * 1.92, clockwise: false)
    let b = blatnik.copy(strokingWithWidth: 28, lineCap: .round, lineJoin: .round, miterLimit: 10)
    // pneumatika
    c.saveGState(); stin(c, k, dolu: 6, rozmazani: 14, alfa: 0.5)
    c.setFillColor(sedá(0.05)); c.fillEllipse(in: CGRect(x: s.x - 125, y: s.y - 125, width: 250, height: 250)); c.restoreGState()
    vOrezu(c, CGPath(ellipseIn: CGRect(x: s.x - 125, y: s.y - 125, width: 250, height: 250), transform: nil)) {
        kruhPrechod(c, [sedá(0.22), sedá(0.13), sedá(0.04)], [0.6, 0.85, 1], s, 125)
        // lesk gumy vlevo nahore
        c.saveGState(); c.translateBy(x: s.x - 60, y: s.y - 75); c.rotate(by: -0.7); c.scaleBy(x: 1, y: 0.35)
        kruhPrechod(c, [sedá(1, 0.18), sedá(1, 0)], nil, .zero, 70); c.restoreGState()
    }
    // bily bok
    let bok = CGRect(x: s.x - 104, y: s.y - 104, width: 208, height: 208)
    vOrezu(c, CGPath(ellipseIn: bok, transform: nil)) { kruhPrechod(c, [sedá(0.98), sedá(0.94), sedá(0.78)], [0, 0.8, 1], CGPoint(x: s.x - 20, y: s.y - 30), 115) }
    // rafek a chromova poklice
    let rafek = CGRect(x: s.x - 84, y: s.y - 84, width: 168, height: 168)
    vOrezu(c, CGPath(ellipseIn: rafek, transform: nil)) {
        prechod(c, [sedá(1), sedá(0.75), sedá(0.25), sedá(0.55), sedá(0.85)], [0, 0.35, 0.55, 0.75, 1], CGPoint(x: s.x, y: rafek.minY), CGPoint(x: s.x, y: rafek.maxY))
    }
    let poklice = CGRect(x: s.x - 70, y: s.y - 70, width: 140, height: 140)
    vOrezu(c, CGPath(ellipseIn: poklice, transform: nil)) {
        // chrom: nebe nahore, ostra tmava linie obzoru, odraz zeme dole
        prechod(c, [sedá(0.98), barva(0.78, 0.84, 0.92), barva(0.30, 0.32, 0.36), barva(0.48, 0.44, 0.40), sedá(0.82)],
                [0, 0.45, 0.52, 0.75, 1], CGPoint(x: s.x, y: poklice.minY), CGPoint(x: s.x, y: poklice.maxY))
        c.saveGState(); c.translateBy(x: s.x - 22, y: s.y - 30); c.scaleBy(x: 1, y: 0.55)
        kruhPrechod(c, [sedá(1, 0.95), sedá(1, 0)], nil, .zero, 30); c.restoreGState()
    }
    tah(c, CGPath(ellipseIn: poklice, transform: nil), sedá(0.3, 0.8), 2)
    let matice = CGRect(x: s.x - 13, y: s.y - 13, width: 26, height: 26)
    vOrezu(c, CGPath(ellipseIn: matice, transform: nil)) { kruhPrechod(c, [sedá(1), sedá(0.5)], nil, CGPoint(x: s.x - 4, y: s.y - 5), 16) }
    // blatnik lakovany jako karoserie s chromovou hranou
    c.saveGState(); stin(c, k, dolu: 8, rozmazani: 16, alfa: 0.5); vypln(c, b, lak[2]); c.restoreGState()
    vOrezu(c, b) { prechod(c, lak, [0, 0.4, 0.75, 1], CGPoint(x: 0, y: s.y - 162), CGPoint(x: 0, y: s.y - 60))
        c.saveGState(); c.translateBy(x: s.x - 30, y: s.y - 158); c.scaleBy(x: 1, y: 0.2)
        kruhPrechod(c, [sedá(1, 0.6), sedá(1, 0)], nil, .zero, 110); c.restoreGState() }
    tah(c, b, barva(0.20, 0, 0.02, 0.45), 1.5)
}

func scena(_ c: CGContext, _ k: CGFloat) {
    // stin na zemi
    c.saveGState(); c.translateBy(x: 540, y: 780); c.scaleBy(x: 1, y: 0.06)
    kruhPrechod(c, [sedá(0, 0.55), sedá(0, 0.25), sedá(0, 0)], [0, 0.5, 1], .zero, 470); c.restoreGState()
    c.saveGState(); c.translateBy(x: 545, y: 778); c.scaleBy(x: 1, y: 0.12)
    kruhPrechod(c, [sedá(0, 0.7), sedá(0, 0)], nil, .zero, 130); c.restoreGState()
    zavesneRameno(c, k)
    ipad(c, k)
    karoserie(c, k)
    kozenyLem(c, k)
    stitek(c, k)
    kolo(c, k)
}


// ---- textury (Core Image) ----
let ctx = CIContext(options: [.workingColorSpace: rgb])

// sedy sum z jednoho kanalu CIRandomGenerator, posunuty, at kazda vrstva ma jiny
func sum(_ posun: CGFloat) -> CIImage {
    // generator ma nahodnou i pruhlednost; settingAlphaOne ji nastavi na 1 bez prepoctu barev
    CIFilter(name: "CIRandomGenerator")!.outputImage!
        .transformed(by: CGAffineTransform(translationX: posun, y: posun * 0.7))
        .settingAlphaOne(in: CGRect(x: 0, y: 0, width: 4096, height: 4096))
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
}
// dlazdice bez svu: sum se nejdriv opakuje, pak rozmaze, pak orizne na jednu periodu
func vlakna(_ posun: CGFloat, _ velikost: CGSize, uhel: CGFloat, delka: CGFloat) -> CIImage {
    let dlazdice = sum(posun).cropped(to: CGRect(origin: .zero, size: velikost)).applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()])
    return dlazdice.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: delka, kCIInputAngleKey: uhel])
        .cropped(to: CGRect(origin: .zero, size: velikost))
}
// hodnota v ~ 0.5 +- odchylka -> barva zaklad + (v-0.5)*sila
func obarvi(_ i: CIImage, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, sila: CGFloat) -> CIImage {
    i.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: sila, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: sila, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: sila, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": CIVector(x: r - 0.5 * sila, y: g - 0.5 * sila, z: b - 0.5 * sila, w: 0)])
}
func uloz(_ i: CIImage, _ cesta: String) {
    try! ctx.writePNGRepresentation(of: i, to: URL(fileURLWithPath: cesta), format: .RGBA8, colorSpace: rgb)
}

func pul(_ i: CIImage) -> CIImage {
    i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
                                                   "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
}

// Lnene platno jako v iOS 6: vodorovna a svisla vlakna; bezesva ctvercova dlazdice
func lnenePlatno(_ strana: CGFloat) -> CIImage {
    let T = CGSize(width: strana, height: strana)
    let delka = 9 * strana / 512
    let tkani = pul(vlakna(0, T, uhel: 0, delka: delka)).applyingFilter("CILinearDodgeBlendMode",
                    parameters: [kCIInputBackgroundImageKey: pul(vlakna(1000, T, uhel: .pi / 2, delka: delka))])
        .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 4.0])
    let r = CGRect(origin: .zero, size: T)
    return obarvi(tkani, 0.235, 0.245, 0.27, sila: 0.11).cropped(to: r).settingAlphaOne(in: r)
}

// Kartacovany hlinik jako dlazdice (bez svetla, to si appka nakresli sama): ryhy jen vodorovne,
// sum je vodorovne opakovany, radky jsou na sobe nezavisle, takze dlazdice navazuje do vsech stran
func hlinikDlazdice(_ strana: CGFloat) -> CIImage {
    let T = CGSize(width: strana, height: strana)
    let ryhy = vlakna(700, T, uhel: 0, delka: 70 * strana / 1120).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 5.0])
    let r = CGRect(origin: .zero, size: T)
    return obarvi(ryhy, 0.76, 0.765, 0.78, sila: 0.26).cropped(to: r).settingAlphaOne(in: r)
}

// Kartacovany hlinik jako okna Mac OS X Tiger: ryhy jen vodorovne, svetlo shora
func kartacovanyHlinik(_ sirka: CGFloat, _ vyska: CGFloat) -> CIImage {
    let H = CGSize(width: sirka, height: vyska)
    let ryhy = vlakna(500, H, uhel: 0, delka: 70 * sirka / 1120).applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 5.0])
    let svetlo = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: vyska), "inputPoint1": CIVector(x: 0, y: 0),
        "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.18), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0.10)])!.outputImage!
    let r = CGRect(origin: .zero, size: H)
    return svetlo.composited(over: obarvi(ryhy, 0.72, 0.725, 0.74, sila: 0.30)).cropped(to: r).settingAlphaOne(in: r)
}

// ---- vystupy ----
func vykresli(_ sirka: Int, _ vyska: Int, _ kresli: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: sirka, pixelsHigh: vyska, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    kresli(g.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func zapis(_ rep: NSBitmapImageRep, _ cesta: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: cesta))
}

func zapis(_ i: CIImage, _ cesta: String) {
    try! ctx.writePNGRepresentation(of: i, to: URL(fileURLWithPath: cesta), format: .RGBA8, colorSpace: rgb)
}

// Sajdkara (navrzena v ctverci 1024 s y dolu) vepsana do obrazu: meritko m, bod sceny stred jde doprostred
func sajdkara(_ sirka: Int, _ vyska: Int, meritko m: CGFloat, stred: CGPoint, pozadi: Bool) -> NSBitmapImageRep {
    vykresli(sirka, vyska) { c in
        let w = CGFloat(sirka), h = CGFloat(vyska)
        if pozadi {
            // teple kremove pozadi jako stary plakat: svetlo uprostred, tmavsi kraje, naznak podlahy
            kruhPrechod(c, [barva(1.0, 0.96, 0.88), barva(0.94, 0.87, 0.74), barva(0.72, 0.62, 0.46)], [0, 0.55, 1],
                        CGPoint(x: w / 2, y: h * 0.6), max(w, h) * 0.78)
            prechod(c, [sedá(0, 0.14), sedá(0, 0)], nil, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: h * 0.32))
        }
        let u = min(w, h) / 1024 * m
        c.translateBy(x: w / 2, y: h / 2)
        c.scaleBy(x: u, y: -u)
        c.translateBy(x: -stred.x, y: -stred.y)
        scena(c, u)
    }
}

let celaSajdkara = CGPoint(x: 498, y: 479)   // stred cele sceny i se zavesnym ramenem
let ikonovaSajdkara = CGPoint(x: 548, y: 479) // karoserie uprostred, rameno vyjizdi z okraje k motorce

// iOS: ikony 72/144 (iOS 6) a 76/152 (iOS 7+); rohy a lesk prida iOS samo
for (nazev, px) in [("Icon", 72), ("Icon@2x", 144), ("Icon-76", 76), ("Icon-76@2x", 152)] {
    zapis(sajdkara(px, px, meritko: 1.1, stred: ikonovaSajdkara, pozadi: true), "ios/\(nazev).png")
}
zapis(sajdkara(64, 64, meritko: 1.1, stred: ikonovaSajdkara, pozadi: true), "docs/CydiaIcon.png")
zapis(sajdkara(256, 256, meritko: 1.1, stred: ikonovaSajdkara, pozadi: true), "docs/ikona.png") // web a README
// iOS: obrazek na uvodni obrazovce (520x372 b., sajdkara vyplni ~ 80 % sirky)
zapis(sajdkara(520, 372, meritko: 0.869 * 520 / 372, stred: celaSajdkara, pozadi: false), "ios/Sajdkara.png")
zapis(sajdkara(1040, 744, meritko: 0.869 * 520 / 372, stred: celaSajdkara, pozadi: false), "ios/Sajdkara@2x.png")
// platno: iOS (dlazdice 256/512) a web
zapis(lnenePlatno(256), "ios/Platno.png")
zapis(lnenePlatno(512), "ios/Platno@2x.png")
zapis(lnenePlatno(512), "docs/platno.png")
// iOS: hlinikova "oprerka dlani" v rezimu ovladani
zapis(hlinikDlazdice(256), "ios/Hlinik.png")
zapis(hlinikDlazdice(512), "ios/Hlinik@2x.png")
// Mac: kartacovany hlinik pro okno pruvodce (560x490 b.)
zapis(kartacovanyHlinik(560, 490), "mac/Kov.png")
zapis(kartacovanyHlinik(1120, 980), "mac/Kov@2x.png")

// macOS: volny tvar bez pozadi jako ikony Mac OS X -> AppIcon.icns
let sada = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: sada)
try! FileManager.default.createDirectory(atPath: sada, withIntermediateDirectories: true)
for bod in [16, 32, 128, 256, 512] {
    zapis(sajdkara(bod, bod, meritko: 0.98, stred: celaSajdkara, pozadi: false), "\(sada)/icon_\(bod)x\(bod).png")
    zapis(sajdkara(bod * 2, bod * 2, meritko: 0.98, stred: celaSajdkara, pozadi: false), "\(sada)/icon_\(bod)x\(bod)@2x.png")
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", sada, "-o", "mac/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
print("Grafika hotova")
