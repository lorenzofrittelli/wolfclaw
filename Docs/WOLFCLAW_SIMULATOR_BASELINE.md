# WolfClaw: base verificata sul simulatore

Verifica eseguita il 26 ottobre 2026, partendo da PhoneClaw `31bf61d`.

## Ambiente e risultato

- Xcode 27.1, SDK iOS 27.1, runtime del simulatore iOS 27.0.
- Simulatore iPhone 18 Pro Max, build Debug senza firma.
- CocoaPods 1.17.0; dipendenze installate tramite `pod install`.
- Build completata, app installata e avviata.
- Gemma 4 E4B caricato da `Documents/models/gemma-4-E4B-it.litertlm` nel contenitore dell'app.
- Prova dall'interfaccia: «Rispondi in italiano: quanto fa 2 + 2?».
- Risposta osservata: «2 più 2 fa 4.».

## Correzioni necessarie

- Collegamento di Piper Plus limitato a `iphoneos`: il framework fornito non contiene una variante per il simulatore. Nel simulatore resta il fallback vocale già previsto dal progetto.
- Adeguamento di due riferimenti a Foundation Models all'SDK installato: inizializzazione di `LanguageModelCapabilities` e casi di `Transcript.Segment`.
- Installazione del componente Metal con `xcodebuild -downloadComponent MetalToolchain`.
- Aggiunta locale del dizionario ufficiale Open JTalk 1.11 in `Models/open_jtalk_dic_utf_8-1.11`, richiesto dalle risorse del progetto.

I modelli, il dizionario e `Pods/` sono esclusi dal repository tramite le regole già presenti. I pin SwiftPM non sono stati aggiornati; cambia solo il metadato `originHash`.

## Ripetere la build

Aprire `PhoneClaw.xcworkspace` dopo `pod install`. Selezionare il simulatore iPhone 18 Pro Max e compilare lo schema PhoneClaw. Da terminale:

```sh
xcodebuild -workspace PhoneClaw.xcworkspace -scheme PhoneClaw \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' \
  CODE_SIGNING_ALLOWED=NO build
```

Il file del modello deve essere presente nella directory `Documents/models` del contenitore dell'app installata, oppure scaricato dall'app.

## Limiti della verifica

Questa base verifica compilazione, avvio e una risposta testuale locale sul simulatore. Non verifica prestazioni, memoria, firma, fotocamera, HealthKit o audio su un iPhone fisico. Non rappresenta il completamento delle milestone funzionali di WolfClaw.

Nell'analisi iniziale dei test del core erano passati 108 test su 111; restavano tre fallimenti nei contratti del codice Live/LiveLand (`testLiveLandEntryStartsDedicatedMicrophoneSession`, `testLiveModeKeepsMainRuntimeChain`, `testLiveModeUsesMainLiveConversationPath`). La presente prova non risolve né ricertifica quei test.
