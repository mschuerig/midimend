# Midimend

*Deutsche Übersetzung — [English version](README.md).*

Flick dein MIDI zurecht, bevor die DAW es sieht.

Hardware-Controller sprechen nicht immer den Dialekt, den deine Software
erwartet. Ein Drehregler sendet ein einzelnes relatives CC, wo die DAW
zwei getrennte Tasten braucht; ein Pedal sendet die falsche
Controller-Nummer; die Meldungen eines Keyboards passen fast, aber eben
nur fast. In Logic Pro und MainStage gibt es dafür keine globale Lösung:
MIDI-Verarbeitungs-Plug-ins sind immer an eine einzelne Spur bzw. einen
Channel Strip gebunden. Midimend setzt stattdessen *vor* der DAW an — es
verbindet sich mit deinen MIDI-Quellen, lässt pro Ereignis ein kleines
JavaScript-Verarbeitungsskript laufen und gibt den reparierten Strom auf
einem virtuellen Ausgangsport aus, den die DAW als Eingang verwendet.

Skripte verwenden dieselbe JavaScript-API wie das Scripter-MIDI-Plug-in:
Vorhandene Skripte laufen unverändert, und hier entwickelte Skripte lassen
sich im Plug-in testen — mit derselben zugrunde liegenden Engine (dem
JavaScriptCore-Framework des Systems).

Keine grafische Oberfläche — konfiguriert wird über eine JSON-Datei.

Status: **v0** — der Host-unabhängige Teil der Skript-API (siehe
[PLANNING.md](PLANNING.md) für die Roadmap).

## Beispiel: ein Drehregler, aber die DAW will zwei Tasten

Der Anlassfall: Der Hauptregler des Arturia MiniLab sendet ein *einzelnes*
relatives CC — die Richtung steckt im Wert —, aber die Aktionen *voriges
Patch* / *nächstes Patch* in MainStage brauchen je ein eigenes CC. Kein
Mapping der Welt behebt das.
[examples/minilab-mainknob.js](examples/minilab-mainknob.js) flickt es:
Aus dem einen relativen CC werden zwei getrennte CCs (Wert 127), die
[examples/config.example.json](examples/config.example.json) an MainStage
liefert. Die Tasten für voriges/nächstes Patch und Set sind in den
mitgelieferten MainStage-Layouts ab Werk keinem CC zugeordnet — weise
ihnen diese CCs unter „Zuweisungen & Zuordnungen“ zu.

## Installieren & starten

```sh
brew install mschuerig/tap/midimend
brew services start midimend    # läuft sofort und bei jeder Anmeldung
```

Der Dienst startet `midimend` ohne Argumente; gelesen wird dann
`~/Music/Midimend/config.json` — ein sichtbarer Ordner für Konfiguration
und Skripte, gleich neben dem Ort, an dem Logic-/MainStage-Nutzer ihre
Inhalte ohnehin ablegen. Benötigt macOS 13+. Keine Entitlements oder
Berechtigungen nötig.

Für den Anfang erzeugst du ein Konfigurationsgerüst mit den
Parameter-Vorgaben des Skripts und trägst dann den Namen des
Eingabegeräts ein:

```sh
midimend --init dein-skript.js > ~/Music/Midimend/config.json
```

Was angeschlossen ist — und, mit Konfiguration, was davon sie erfasst:

```sh
midimend --list-devices
midimend --list-devices ~/Music/Midimend/config.json
```

Fehlt ein konfiguriertes Gerät beim Start, warnt midimend, listet die
vorhandenen Geräte auf und verbindet das Gerät automatisch, sobald es
erscheint. Die Ausgabe des Dienstes landet in
`/opt/homebrew/var/log/midimend.log`.

Den neuesten, noch unveröffentlichten Stand aus dem Quelltext über Homebrew
installieren — lokal gebaut und wie die Release-Version als Dienst verwaltet:

```sh
brew install --HEAD mschuerig/tap/midimend
```

Oder direkt bauen und ausführen, ohne Homebrew:

```sh
swift build -c release
.build/release/midimend examples/config.example.json
```

## Konfiguration

```jsonc
{
  "script": "minilab-mainknob.js",        // Pfad, absolut oder relativ zu dieser Datei
  "midi": {
    "inputs": [
      { "hardware": "MiniLab" },          // Quellen verbinden, deren Name passt (Teilstring)
      { "virtual": "Midimend In" }        // virtuellen Port anlegen, an den andere Apps senden können
    ],
    "outputs": [
      { "virtual": "Midimend" }           // virtueller Port; in der DAW als Eingang wählen
      // { "hardware": "ein Gerät" }      // ... oder an ein Hardware-Ziel senden
    ],
    "feedback": "all",                    // Parameter-Feedback der DAW an alle Geräte zurückgeben
                                          // ("all" oder eine Geräteliste wie bei "inputs"; weglassen = aus)
    "ignore": ["DAW"]                     // Geräte ganz in Ruhe lassen (Teilstring-Abgleich)
  },
  "keepAwake": false,                      // true: MIDI-Spiel hält das Display wach (Standard: aus)
  "parameters": {                          // Werte für die PluginParameters des Skripts, nach Name
    "Source CC": 28,                       // Zahlen für Schieberegler
    "Mode": "Auto",                        // Menü-Parameter nehmen den valueStrings-Eintrag
    "Enabled": true                        // Checkboxen nehmen Booleans
  }
}
```

Lässt du `"inputs"` ganz weg, verbindet Midimend *alle* MIDI-Geräte
(außer den ignorierten und seinen eigenen virtuellen Ports). Geräte werden
verbunden, sobald sie erscheinen — einen Controller nach dem Start
einzustecken funktioniert einfach. `"ignore"` ist für Endpunkte gedacht,
die Midimend weder lesen noch beschicken soll — typischerweise der
DAW-Steuerport eines Controllers (z. B. „Minilab37 DAW“ neben
„Minilab37 MIDI“), der direkt mit der DAW spricht.

Parameter-*Definitionen* stehen wie üblich im `PluginParameters`-Array des
Skripts; die Konfiguration liefert die *Werte*. Konfigurations- und
Skriptdatei werden überwacht — beim Speichern wird das Skript neu geladen
und `ParameterChanged` für jeden Parameter erneut ausgelöst, wie beim
Laden einer Plug-in-Einstellung. Änderungen am `midi`-Abschnitt erfordern
einen Neustart.

In MainStage stellst du den MIDI-Eingang deiner Layout-Objekte auf den
virtuellen Ausgangsport (z. B. „Midimend“), damit die rohen
Hardware-Ereignisse ignoriert werden; in Logic nimmst du den
MIDI-In-Anschluss im Spur-Informationsfenster. Tu das *vor* dem Lernen —
„Lernen“ bindet sich an den Port, dessen Meldung zuerst eintrifft.

### Parameter-Feedback

Controller mit LED-Kränzen, Tastenbeleuchtung oder Motorfadern erwarten,
dass die DAW Werte *zurücksendet* — etwa damit Encoder-Kränze nach einem
Patch-Wechsel den Parameter anzeigen. Mit konfiguriertem `"feedback"`
bekommt jeder virtuelle Ausgang einen gleichnamigen Begleitport, an den
DAWs senden können; was dort ankommt, wird unverändert an die
Feedback-Geräte durchgereicht — `"all"` (alle Geräte außer den
ignorierten) oder eine explizite Liste wie `[{ "hardware": "X-TOUCH" }]`.
Ohne den Schlüssel gibt es weder den Begleitport noch den Feedback-Pfad.

In MainStage wählst du den virtuellen Port (z. B. „Midimend“) im
Layout-Modus als **Wert senden an** des Bildschirm-Steuerelements. Ging
das Feedback eines Steuerelements früher direkt an den Hardware-Port,
wähle „Wert senden an“ nach dem Umstellen neu — MainStage lässt die alte
Feedback-Route aktiv, obwohl das Einblendmenü dafür „Ohne“ anzeigt.

### Display beim Spielen wach halten

Das Spielen an einem Controller wertet macOS nicht als Aktivität — mitten im
Set können also Bildschirmschoner und Display-Ruhezustand einsetzen, obwohl du
gerade ein Instrument benutzt. Mit `"keepAwake": true` hält eingehendes MIDI
das Display wach, solange gespielt wird; hören die Noten auf, schläft der Mac
wie gewohnt ein. Nur echtes Spielen zählt — Noten, Controller, Pitch Bend,
Programmwechsel — nie die Haushaltsdaten, die ein Gerät von sich aus sendet
(Active Sensing, MIDI-Clock); ein angeschlossener, aber unbespielter Controller
hält den Bildschirm also nicht an. Betrifft nur den Display-Ruhezustand, nicht
den System-Ruhezustand. Standardmäßig aus.

## Unterstützte Skript-API (v0)

| Bereich | Status |
|---|---|
| `HandleMIDI(event)`, typspezifische Handler (`HandleNote`, `HandleControlChange`, …) | ✅ |
| Ereignisklassen: `NoteOn`, `NoteOff`, `PolyPressure`, `ControlChange`, `ProgramChange`, `ChannelPressure`, `PitchBend` (+ Klon-Konstruktoren, `pitch`/`velocity`/`number`/`value`-Zugriffe) | ✅ |
| `event.send()`, `event.sendAfterMilliseconds(ms)`, `event.trace()`, `event.toString()` | ✅ |
| `MIDI`-Objekt: `noteName`, `noteNumber`, `ccName`, `allNotesOff`, `normalize*` | ✅ |
| `PluginParameters` (`lin`/`log`/`menu`/`checkbox`/`momentary`/`text`), `GetParameter`, `SetParameter`, `ParameterChanged` | ✅ (Werte aus der Konfiguration; `hidden`/`readOnly`/`disableAutomation` werden akzeptiert und ignoriert) |
| `Trace()` | ✅ (stdout, ohne Ausdünnung) |
| `Idle()` | ✅ (alle 0,25 s) |
| Laufzeit-Ausnahmen | pro Callback eingedämmt und protokolliert |
| System-Echtzeit-/Common-Meldungen (Clock, Start/Stop) | werden unverändert durchgereicht |
| `sendAtBeat()`, `sendAfterBeats()` | ⚠️ noch kein Transport — warnt einmal, sendet sofort |
| `GetTimingInfo()`, `NeedsTimingInfo`, `beatPos` | ⚠️ noch kein Transport — `undefined` / 0, mit Warnung |
| `ProcessMIDI()`, `Reset()` | ⚠️ werden noch nicht aufgerufen (kommen mit dem Transport in v1) |
| `TargetEvent`, Parameter vom `type:"target"` | ❌ Host-spezifisch — Ereignisse werden mit Warnung verworfen |
| Eigenschaften `articulationID`, `port`, `isRealtime`, `beatPos` | auf Ereignissen vorhanden; Durchreich-Werte |

Bekannte Abweichungen: `toString()`-Ausgaben und CC-Namen können im
Wortlaut vom Original-Plug-in abweichen; Konstruktor-Vorgabewerte
(`new NoteOn()` ohne Argumente) sind noch nicht verifiziert.

## Testen

```sh
swift test
```

Die Testsuite prüft die Skript-Engine ohne CoreMIDI (Ereignisse rein,
aufgezeichnete Ereignisse raus) und läuft daher überall.

## Roadmap

- **v1 — Timing**: interner Transport (Tempo/Taktart aus der
  Konfiguration), `TimingInfo`, `beatPos`, Beat-basierter Scheduler für
  `sendAtBeat`/`sendAfterBeats`, `ProcessMIDI`-Tick, `Reset`.
- **v1.x — Sync**: MIDI-Clock-Slave (Start/Stop/SPP), vielleicht
  Ableton Link.
- Details und Design-Notizen in [PLANNING.md](PLANNING.md), bewusst
  zurückgestellte Funktionen in [IDEAS.md](IDEAS.md).

## Änderungsverlauf

- **v0.4.0** — Optionales `keepAwake`: Während du spielst, hält eingehendes
  MIDI das Display wach und schiebt den Bildschirmschoner auf; sobald die Noten
  aufhören, schläft der Mac wie gewohnt ein. Standardmäßig aus.
- **v0.3.0** — Parameter-Feedback: Wertänderungen der DAW werden über einen
  gepaarten virtuellen Zielport an die Controller zurückgegeben (LED-Kränze,
  Motorfader). Der virtuelle Standardport heißt jetzt schlicht „Midimend“.
- **v0.2.2** — Die Formula installiert das mit Developer-ID signierte,
  notarisierte Universal-Binary.
- **v0.2.1** — Hot-Plug korrigiert, sodass nach dem Start angeschlossene
  Controller erkannt werden; End-to-End-Testebene gegen das echte Binary
  ergänzt.
- **v0.2.0** — `--measure` meldet die zusätzliche Latenz;
  `sendAfterMilliseconds` nutzt einen Timer ohne Toleranz; der Dienst läuft im
  interaktiven Tier für weniger Jitter.
- **v0.1.x** — Erste Veröffentlichung: Scripter-kompatible Engine auf
  JavaScriptCore, JSON-Konfiguration, Homebrew-Tap und Login-Dienst.
