# SleepFlow – arkitektur

SleepFlow består af to dele:

- **SleepCore** (`Packages/SleepCore`) – søvnmotoren. Ren Swift + Foundation, ingen UIKit, ingen
  AVFoundation. Alle algoritmer kan derfor testes på Linux og macOS uden simulator.
- **Appen** (`App/Sources`) – SwiftUI, optagelse fra mikrofon og bevægelsessensor, alarmer,
  lagring (SwiftData), skærme og tekster.

```
 Mikrofon ─► AudioCaptureService ─┐                       ┌─► SmartAlarmEngine / NapTracker ─► AlarmCoordinator
 Bevægelse ─► MotionCaptureService ┤─► TrackingController ─┤
 (Demo) SimulatedNightSource ──────┘        │              └─► SessionJournal (JSON-linjer, crash-sikker)
                                            ▼
                         ved stop: SessionAssembler ─► SleepStager ─► metrics ─► SleepScore ─► Insights
                                            ▼
                                  SleepStore (SwiftData) ─► rapport, statistik, dagbog, eksport
```

## SleepCore-moduler

| Modul | Ansvar |
|---|---|
| `SleepModels` | Fælles typer: 30-sekunders epoker, faser (vågen/let/dyb), hændelser, alarmindstillinger, hypnogram. `SleepConstants.algorithmVersion` gemmes med hver nat. |
| `AudioAnalysis` | 20–30 lydrammer pr. sekund (vinduer på 64–93 ms med 50 % overlap): lydniveau (dBFS), FFT-spektrum, spektral tyngde/fladhed, nulgennemgange, adaptivt støjgulv, vejrtrækningsrytme. Segmenterer hændelser og klassificerer snorken, tale, hoste, bevægelseslyde og forstyrrelser ud fra mønster. |
| `MotionAnalysis` | Accelerometer-data: aktivitet pr. epoke, store bevægelser, periodiske mønstre (fx urolige ben). |
| `SleepIntelligence` | Omsætter lyd/bevægelse til evidens pr. epoke. `OnlineSleepEstimator` giver løbende sandsynligheder i løbet af natten (bruges af alarmerne). `SleepStager` laver nattens endelige faser med en skjult Markov-model: forward–backward giver sikkerhed, Viterbi den mest sandsynlige sti. `SleepMetricsCalculator` beregner søvntid, effektivitet, indsovningstid, afbrydelser, uro. |
| `SleepScoring` | Søvnscore 0–100 fra seks delscorer og vægte (standard: længde 30 %, effektivitet 20 %, indsovning 10 %, afbrydelser 15 %, uro 10 %, regelmæssighed 15 %). Manglende faktorer (fx regelmæssighed før 3 nætter) udelades, og vægtene fordeles på resten. Indsigter og forslag som enum-værdier – teksterne ligger i appen. |
| `SmartAlarm` | `AlarmPlanner` (næste vækning, ugedage, sommertid/tidszoner), `SmartAlarmEngine` (vækker i let søvn i vinduet, aldrig efter deadline), `NapPlan`/`SleepOnsetDetector`/`NapTracker` ("Vågn efter søvn"). |
| `SleepSession` | `SessionJournal` skriver hver færdig epoke, hændelse og markør som en JSON-linje med det samme. `SessionAssembler` bygger den færdige nat ud fra journalen – også efter et nedbrud. |
| `SleepStatistics` | Uge/måned/år, gennemsnit, regelmæssighed, mål-stribe, vaner mod score. |
| `SleepSimulation` | Syntetiske nætter med kendte faser til tests og demotilstand. |

## En nat fra start til rapport

1. **Start** (`TrackingController.start`): journalen oprettes, alarmen for natten eller luren
   planlægges, og optagelsen starter. Mikrofon-tilstand bruger baggrunds-lyd (`UIBackgroundModes:
   audio`), så målingen fortsætter med låst skærm. Bevægelses-tilstand kræver, at appen er åben.
2. **Hver 30. sekund**: lyd- og bevægelsesdata samles til en epoke, som skrives til journalen og
   sendes til `OnlineSleepEstimator`. Estimatet går videre til `SmartAlarmEngine` (nat) eller
   `NapTracker` (lur), som kan beslutte at vække nu.
3. **Stop** (bruger stopper, alarmen stoppes, eller natten gendannes): `SessionAssembler` læser
   journalen, `SleepStager` beregner faserne, derefter metrics, score og indsigter. Natten gemmes i
   SwiftData, og journalen slettes.
4. **Nedbrud eller lukning**: ved næste start findes den ufærdige journal. Brugeren kan gemme natten
   eller fortsætte målingen. Højst den sidste ufærdige epoke går tabt.

## Alarmer – hvorfor de ikke kan glippe

- Når en vækning planlægges, sættes der altid en **systemalarm ved deadline** (det seneste
  tidspunkt). På iOS 26+ er det en AlarmKit-alarm, som ringer i lydløs tilstand og fokustilstand.
  På ældre iOS er det en serie lokale notifikationer med lyd.
- Smart Alarm og "Vågn efter søvn" kan kun **fremskynde** vækningen. Deadline-alarmen fjernes først,
  når brugeren faktisk har stoppet en alarm for den morgen.
- Med AlarmKit følger en ekstra notifikation ét minut efter deadline.
- `AlarmCoordinator.reconcile` kører ved opstart, når appen bliver aktiv, efter ændrede indstillinger,
  tidszoneskift og større tidsændringer (sommertid, manuelt ur). Den annullerer aldrig en alarm,
  der allerede er forfalden eller ringer.
- Til lure planlægges alarmen ved start til *start + maksimal indsovningstid + søvnlængde*. Når søvnen
  registreres, flyttes den tidligere (`AlarmCoordinator.updateNap` accepterer kun tidligere tidspunkter).

## "Vågn efter søvn" i detaljer

- `SleepOnsetDetector`: søvn regnes for startet, når P(søvn) ≥ 0,7 i 8 epoker i træk (4 min), med op
  til 2 enkeltstående udsving. Er P(vågen) ≥ 0,85, eller kommer der 2 udsving i træk, starter
  tællingen forfra. Starttidspunktet rykkes tilbage over de stille epoker før bekræftelsen (højst 10 min).
- `NapPlan`: powernap 20 min (vindue 5 min) eller 30 min (vindue 10 min) med beskyttelse mod dyb
  søvn efter mindst 10 min søvn; 1 cyklus = 90 min (vindue 20 min), 2–5 cyklusser (vindue 30 min).
  Maksimal indsovningstid 30 min, derefter tælles der alligevel.
- Simulationstests (`NapSimulationTests`) kører 12 syntetiske lure pr. metode og kræver bl.a., at
  søvnstarten rammes inden for ±4 min i mindst 10 af 12, og at en powernap aldrig vækker mere end
  10 min inde i dyb søvn (median højst 4 min). Telefonen ser kun dyb søvn gennem stilhed og vejrtrækning, så den opdager den
  med nogle minutters forsinkelse.

## Lagring og privatliv

- `SleepStore` har to adskilte SwiftData-lagre: egne nætter og demodata. Demodata kan aldrig havne
  i egen statistik eller eksport. Ingen CloudKit.
- Journal og diagnostiklog får iOS-databeskyttelse `completeUntilFirstUserAuthentication` (så der kan
  skrives med låst skærm), lydklip `completeUnlessOpen`. Mappen med journal, lydklip og diagnostik er
  udeladt af sikkerhedskopier; nætterne i SwiftData følger telefonens almindelige sikkerhedskopi.
- Lure (`isNap`) gemmes som egne poster og holdes ude af nattens statistik, historik og dagbog.
- Eksport: JSON med alle detaljer + CSV med én linje pr. nat, delt via iOS' del-ark.
- Ingen netværkskald, ingen analyseværktøjer, ingen tredjepartskode.

## Tekster og sprog

- Engelsk er udviklingssproget; de engelske tekster er nøglerne. Danske oversættelser ligger i
  `tools/strings_da.py` og skrives til `App/Resources/da.lproj/Localizable.strings` af
  `tools/generate_strings.py` (tjekker at `%@`/`%lld` stemmer).
- `SWIFT_EMIT_LOC_STRINGS` får compileren til at udtrække alle lokaliserbare tekster. CI
  (`ci/check-localization.py`) sammenligner dem med den danske tabel og lægger rapporten i build-artefakterne.
- Sprogvalg i appen sætter `AppleLanguages` for appen og kræver genstart af appen.

## Tests

| Niveau | Hvor | Hvad |
|---|---|---|
| Algoritmer | `Packages/SleepCore/Tests` (Linux-job) | lydfeatures, hændelser, bevægelse, faser, score, Smart Alarm, alarmplanlægning inkl. sommertid, lure, statistik, journal/gendannelse, integration med simulerede nætter |
| App | `Tests/SleepFlowTests` | alarmkoordinator med falsk scheduler, lagring/sletning/genberegning, simulerede målinger, danske tekster |
| UI | `Tests/SleepFlowUITests` | onboarding, powernap fra start til rapport, simuleret nat med alarm, demo-skærme |

UI-tests starter appen med `-UITestMode -ResetState` og simulerede sensorer, så en hel nat tager
under et minut.

## Byg

`project.yml` (XcodeGen) er kilden til Xcode-projektet; `.xcodeproj` committes ikke. GitHub Actions
vælger nyeste stabile Xcode på `macos-15`, bygger usigneret (`CODE_SIGNING_ALLOWED=NO`) og pakker
`Payload/SleepFlow.app` som `SleepFlow.ipa` – samme metode som Transkriptor. Se README for releases
og valgfri signering.
