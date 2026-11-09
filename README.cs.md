<p align="center"><img src="obrazky/ikona.png" width="128" alt=""></p>

# Older Sidecar

Propojí starý iPad nebo iPhone s jailbreakem s dnešním Macem přes USB. iPad umí ukazovat obrazovku Macu a oba můžou
sloužit jako touchpad a ovladač, nebo jako Dock s velkými tlačítky (trochu jako Stream Deck).

[English](README.md)

## Co je potřeba

- Mac s macOS 12.3 nebo novějším (Intel i Apple Silicon)
- iPad nebo iPhone s jailbreakem a iOS 6 až 10 (iPad 2, 3, 4, iPad mini 1, iPhone 4S, 5, 5c, 5s, 6, …)
- USB kabel. Wi-Fi se nepoužívá.

## Instalace

**iPad / iPhone:** v Cydii přidej zdroj `http://oldersidecar.surge.sh/` (s http, ne https, jinak se k němu iOS 6 nedostane).
Na iOS 6 nainstaluj **Older Sidecar**, na novějších zařízeních **Older Sidecar (iOS 7–10)**.
Pokud máš jen AppSync, nainstaluj `OlderSidecar-iOS6.ipa` nebo `OlderSidecar-iOS7-10.ipa` z [Releases](https://github.com/Oldersidecar/OlderSidecar/releases).

**Mac:**

1. Stáhni `OlderSidecar-1.9.1.dmg` z [Releases](https://github.com/Oldersidecar/OlderSidecar/releases),
   otevři ho a přetáhni Older Sidecar do Aplikací.
2. Aplikace není ověřená Applem, takže ji macOS poprvé zablokuje. V Nastavení systému >
   Soukromí a zabezpečení klikni na Přesto otevřít.
3. Povol Nahrávání obrazovky a Zpřístupnění. Aplikace ukáže okno, které tě tím provede.

Běží v liště nahoře a spouští se po přihlášení. V jejím menu to jde vypnout.

## Používání

Připoj iPad nebo iPhone kabelem a otevři na něm Older Sidecar. Vyber si režim:

- **Jen obrazovka** - obraz Macu, nic se omylem neklikne. Dvěma prsty jde přiblížit.
- **Druhý monitor** (iPad) - z iPadu je další monitor Macu vedle hlavního. Přetáhneš na něj okna. Kde leží,
  nastavíš v Nastavení systému > Monitory.
- **Ovládat Mac** - z iPadu nebo iPhonu je touchpad s řadou kláves (esc, tab, ⌘⌥⌃⇧, šipky), klávesnice
  a tlačítka na jas, Mission Control, Launchpad, hudbu, hlasitost a zamčení. Obraz Macu se neukazuje.
- **Dock** - mřížka velkých tlačítek. Každé na Macu otevře appku, web nebo složku, nebo stiskne klávesovou
  zkratku. Nastavují se na Macu v menu: Older Sidecar → Dock….

Na iPhonu režimy s obrazem nejsou, jen Ovládat Mac a Dock.

V menu na Macu jde změnit rozlišení (režimy 4:3 vyplní celý iPad), je tam baterie zařízení a volba jazyka.
Jazyků je 14; překlady zatím nekontroloval rodilý mluvčí, opravy jsou vítané.

Když Mac usne, iPad nebo iPhone to napíše a nezamrzne.

## Licence

Zdarma ke stažení, používání a sdílení v původní podobě. Zdrojový kód není veřejný.
Viz [LICENSE](LICENSE). Sidecar je ochranná známka Apple Inc. Tento projekt s Applem nemá nic společného.
