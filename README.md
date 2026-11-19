# SleepFlow

SleepFlow er en native iPhone-app (SwiftUI, iOS 17+) der måler din søvn med mikrofonen eller
bevægelsessensoren, vurderer hvornår du er vågen, sover let eller sover dybt, og vækker dig i en
let fase. Alt behandles og gemmes lokalt på telefonen – ingen konto, ingen server, ingen sporing.

> SleepFlow er ikke medicinsk udstyr. En telefon kan ikke måle hjernebølger; faserne er
> vurderinger ud fra lyd og bevægelse, ikke en søvnmåling som i et søvnlaboratorium (EEG).

## Det vigtigste: "Vågn efter søvn"

Vælg en powernap eller et antal hele søvncyklusser. SleepFlow begynder først at tælle, når den
registrerer at du er faldet i søvn – ikke når du trykker start.

| Valg | Søvn talt fra du falder i søvn | Vækkevindue til sidst | Særligt |
|---|---|---|---|
| Powernap 20 min | 20 min | sidste 5 min | vækker dig med det samme, hvis dyb søvn begynder (efter mindst 10 min søvn) |
| Powernap 30 min | 30 min | sidste 10 min | samme beskyttelse mod dyb søvn |
| 1 søvncyklus | 90 min | sidste 20 min | vækker dig i let søvn ved cyklussens slutning |
| 2–5 søvncyklusser | 3 t – 7 t 30 min | sidste 30 min | samme princip |

Sådan virker det:

1. Lyd og bevægelse samles i 30-sekunders perioder og omsættes løbende til sandsynligheder for
   vågen / let / dyb søvn.
2. Når søvnen har været stabil i ca. 4 minutter, regnes den for startet. Starttidspunktet rykkes
   tilbage over den stille periode, hvor du faldt i søvn (højst 10 min).
3. Er der ikke registreret søvn efter 30 minutter, begynder tællingen alligevel – så du aldrig
   bliver liggende for længe.
4. I vækkevinduet venter SleepFlow på et øjeblik med let søvn eller opvågning. Ved vinduets
   slutning ringer alarmen altid.

Sikkerhed: Når du starter, sættes en systemalarm til det senest mulige tidspunkt (start + 30 min
+ den valgte søvn). Når søvnen registreres, flyttes alarmen kun **tidligere** – aldrig senere. Går
appen ned eller lukkes, ringer systemalarmen stadig.

## Funktioner

- **Søvnmåling** med mikrofon (virker med låst skærm) eller bevægelse (telefonen på madrassen,
  appen skal være åben).
- **Lydanalyse på telefonen**: snorken, hoste, søvnsnak, bevægelseslyde og forstyrrelser. Apples
  indbyggede lydgenkendelse kan bekræfte hændelser. Lyd gemmes kun som tal; korte lydklip gemmes
  kun hvis du selv slår det til.
- **Søvnfaser** (vågen / let / dyb) – ingen REM- eller kliniske påstande.
- **Smart Alarm** med vindue (0–90 min), lyd, snooze, ugedage og vibration. På iOS 26 bruges iOS'
  egne alarmer (AlarmKit), som ringer i lydløs tilstand og fokustilstand. På ældre iOS bruges
  notifikationer med lyd plus en ekstra påmindelse.
- **Søvnscore 0–100** ud fra seks faktorer med vægte du selv kan ændre: længde i forhold til dit
  mål (30 %), effektivitet (20 %), tid til at falde i søvn (10 %), afbrydelser (15 %), uro (10 %)
  og regelmæssighed (15 %). Rapporten viser præcis hvor mange point hver faktor giver.
- **Morgenrapport** med søvnfaser, lyde, vækning, indsigter og forslag.
- **Statistik** for uge, måned og år: score, søvnlængde, sengetider og sammenhæng mellem vaner og score.
- **Dagbog** med vurdering af morgenen og vaner fra dagen før.
- **Afslapning**: lyde der skabes direkte på telefonen (regn, hav, skov, støj m.m.), sovetimer og
  vejrtrækningsøvelser.
- **Privatliv og data**: eksport (JSON + CSV), slet enkelte nætter, slet alt.
- **Dansk og engelsk**, mørkt og lyst udseende, VoiceOver-etiketter.
- **Demotilstand** med simulerede nætter, holdt helt adskilt fra dine egne data.

## Installér på iPhone fra Windows

Den byggede `SleepFlow.ipa` er usigneret. Den signeres med dit eget Apple-id, når du installerer
den – samme vej som Transkriptor.

1. Hent `SleepFlow.ipa` fra [seneste build](https://github.com/MSJaba-S/SleepFlow/releases/tag/latest).
2. Har du ikke `iPhone-Installer.exe`, så hent den fra
   [release "installer" i Transkriptor-repoet](https://github.com/MSJaba-S/Transkriptor/releases/tag/installer).
   Den kræver iTunes fra apple.com på PC'en.
3. Udviklertilstand (kun første gang): Indstillinger › Anonymitet og sikkerhed › Udviklertilstand › til.
4. iPhonen i USB, åbn iPhone-Installer. Første gang: tandhjulet › Tilføj Apple ID › e-mail og
   adgangskode › koden fra din iPhone. Slå **Forny automatisk** til, træk `SleepFlow.ipa` ind og tryk
   **Installér**. Lad kablet sidde, til der står Færdig.
5. Indstillinger › Generelt › VPN og enhedsadministration › dit Apple-id › Betro.
6. Åbn SleepFlow og giv adgang til mikrofon og alarmer.

Et gratis Apple-id giver 7 dages signering og højst 3 sideloadede apps ad gangen. Med *Forny
automatisk* og iPhone-Installer kørende på PC'en fornyes appen af sig selv. Installerer du en ny
version ovenpå, bliver dine nætter liggende.

## Byg og udgivelse

Alt bygges på GitHub Actions (`.github/workflows/build.yml`) – der kræves ingen Mac:

| Job | Hvad det gør |
|---|---|
| Søvnmotor (SleepCore) | kører alle algoritme-tests på Linux (Swift 6.2) |
| iPhone-app | genererer Xcode-projektet (XcodeGen), bygger til simulator, kører unit-tests og UI-tests, bygger en usigneret Release-version og pakker `SleepFlow.ipa` |

Hvert push til `main` udgiver release **latest** med:

- `SleepFlow.ipa` – appen
- `Source-Code.zip` – kildekoden for netop det build
- `Build-Information.txt` – version, commit, Xcode/SDK, testresultater og signeringsstatus
- `SHA256SUMS.txt` – kontrolsummer for filerne ovenfor

Et tag `v1.2.3` laver en versioneret release. Workflowet kan også startes manuelt under *Actions*.

**Valgfri signering i CI**: Hvis repoet får secrets `IOS_CERTIFICATE_P12_BASE64`,
`IOS_CERTIFICATE_PASSWORD` og `IOS_PROVISIONING_PROFILE_BASE64` (kræver betalt Apple Developer-konto),
signeres IPA'en i en midlertidig nøglering, som slettes igen. Uden secrets bygges der usigneret, og
`Build-Information.txt` siger det. Certifikater, profiler og adgangskoder må aldrig ligge i repoet.

## Udvikling

```bash
brew install xcodegen
xcodegen generate                              # laver SleepFlow.xcodeproj ud fra project.yml
swift test --package-path Packages/SleepCore   # algoritme-tests (også på Linux)
python3 tools/generate_strings.py              # danske tekster -> da.lproj
python3 tools/generate_resources.py            # app-ikon og originale alarmlyde
```

Danske tekster redigeres i `tools/strings_da.py`. Nøglerne er de engelske tekster præcis som
compileren udtrækker dem (`%@` for tekst, `%lld` for heltal). CI-trinnet *Lokaliseringstjek*
sammenligner med de nøgler compileren faktisk har fundet.

Start-argumenter til test og demo: `-UITestMode`, `-ResetState`, `-SkipOnboarding`,
`-SeedDemoData`, `-SimulatedSensors`.

## Projektstruktur

```
App/Sources/          SwiftUI-appen (skærme, optagelse, alarmer, lagring)
App/Resources/        ikon, farver, originale lyde, danske tekster
Packages/SleepCore/   søvnmotoren: lydanalyse, bevægelse, faser, score, Smart Alarm, statistik
Tests/                unit-tests og UI-tests for appen
ci/                   hjælpescripts til GitHub Actions
tools/                generering af ikon, lyde og danske tekster
```

Se [ARCHITECTURE.md](ARCHITECTURE.md) for hvordan delene hænger sammen.

## Privatliv

- Ingen konto, ingen server, ingen analyseværktøjer, ingen reklamer, ingen tredjepartskode.
- Lyd analyseres i hukommelsen og kasseres; kun tal og hændelser gemmes.
- Data ligger i appens private lager med iOS-databeskyttelse. Lydklip og den igangværende nats
  optagelse er udeladt af sikkerhedskopier. Intet synkroniseres til iCloud af appen.
- Du kan eksportere og slette alt fra appen. Sletter du appen, slettes alle data.

## Kendte begrænsninger

- Faserne er vurderinger. Let søvn omfatter drømmesøvn (REM), som ikke kan skelnes fra.
- Bevægelsesmåling kræver at appen er åben; iOS stopper bevægelsessensoren for apps i baggrunden.
- Før iOS 26 er alarmen en notifikation: den følger lydløs tilstand og fokustilstande.
- Den usignerede IPA kan kun installeres ved at signere den med et Apple-id (fx via iPhone-Installer).
- Appen er bygget og testet på simulatoren i CI; den er ikke testet på en fysisk iPhone af udvikleren.
