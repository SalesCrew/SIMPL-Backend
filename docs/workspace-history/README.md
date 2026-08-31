> Historical workspace note copied before the Trello migration on 2026-08-31. Earlier deployment addresses and test counts below describe the time of that note; the current app is https://get-simpl.vercel.app.

# SIMPL

Ein gemeinsames, deutschsprachiges Taskboard für SalesCrew. React + TypeScript im `frontend/`, eine unabhängig deploybare Express-API im `backend/`, Supabase für Auth, Postgres und Realtime.

## Live-Projekte

- Frontend: https://simpl-salescrew.vercel.app (bisherige Adresse bleibt erreichbar)
- API: https://simpl-backend-production.up.railway.app/api/health
- Supabase: https://supabase.com/dashboard/project/xqvexzoswhraqicbmckj
- Vercel: https://vercel.com/sales-crew/simpl
- Railway: https://railway.com/project/c2426000-3925-4144-8298-45c831d58b1f
- GitHub: https://github.com/SalesCrew/SIMPL-Frontend und https://github.com/SalesCrew/SIMPL-Backend

Das bestehende Supabase-Projekt **Trello+** liegt in **SalesCrew's Org**, Region Frankfurt. Frontend und Backend sind getrennt versioniert und deployen automatisch von ihren GitHub-Branches `main`. Der aktuelle Stand und die Prüfungen stehen in `DEPLOYMENT_STATUS.md`. Es wurde kein Datenbank-Reset durchgeführt.

## Verhalten

- Unter dem Logo öffnet der Workspace-Wechsler ein eigenes Popover. Admins können Workspaces anlegen, umbenennen und gegenseitig sperren; Mitarbeiter sehen ausschließlich freigegebene Workspaces.
- Jeder Workspace hat ein eigenes Board mit eigenen Projekten und festen Status-Spalten. Neue Workspaces starten mit **Allgemein**, **In Arbeit** und **Fertig**. Das bisherige Board liegt unverändert in **SalesCrew**.
- Unter **Team & Zugänge → Zugang bearbeiten** legen Admins den **Start-Workspace** und ein dazu passendes **Standardprojekt** fest. Der Start-Workspace öffnet sich nach der Zugriffsprüfung und ist die serverseitige Grundlage der Rechte. Die Auswahl eines anderen Boards verändert diese Zuordnung nicht. Neue Karten landen im aktuell geöffneten Workspace, bevorzugt im passenden Standardprojekt.
- Mitglieder sehen und bearbeiten Karten nur in freigegebenen Workspaces. Admins behalten Zugriff auf alle Workspaces.
- Admins verwalten Projekte/Spalten und Zugänge. Der blaue **Gelesen**-Haken ist ebenfalls eine bewusste Admin-Aktion, unabhängig vom Erledigt-Status.
- Neue Karten starten standardmäßig im dem Benutzer zugewiesenen Projekt. Ein explizit gewähltes Projekt hat Vorrang. Das Ursprungsprojekt bleibt beim Verschieben erhalten, auch in **In Arbeit** und **Fertig**.
- Karten lassen sich per Griff ziehen, per Tastatur verschieben oder im Detaildialog einer anderen Spalte zuordnen. Ein Erledigt-Haken verschiebt nach **Fertig**; Wiederöffnen führt an die gemerkte Stelle im zuletzt besuchten Projekt zurück. **In Arbeit** und **Fertig** überschreiben diese Rückkehrposition nicht. Ist die nächste Nachbarkarte verschwunden, dienen die vorherige Nachbarkarte und zuletzt die gemerkte Reihenfolge als Ersatz. Ältere bereits abgeschlossene Karten ohne gespeicherte Rückkehrposition landen einmalig am Ende ihres ursprünglichen Projekts.
- **In Arbeit** und **Fertig** sind feste, eindeutige Status-Spalten rechts neben den Projekten. Auch Admins können sie nicht umbenennen, umfärben, umwandeln oder löschen. Neue Karten entstehen in Projekten; **In Arbeit** wird nur durch bewusstes Verschieben befüllt. Jeder grüne Haken – auch im Detaildialog – führt serverseitig immer nach **Fertig**. Die Aufgaben in beiden Spalten bleiben bearbeitbar.
- Titel, Beschreibung, Verantwortliche und frei benennbare Labels mit 16 Pastellfarben sind editierbar. Dieselbe Palette steht für Projekte und Profile zur Verfügung. Kommentare stehen rechts mit Datum und Uhrzeit.
- Alle sichtbaren Dropdowns verwenden eigene Popover-Fenster mit Tastatursteuerung. Filter öffnen sich in einem schwebenden Panel; auch Zugangsschalter und Zahlenregler sind im Workspace-Stil gestaltet.
- Formulare verwenden weiße Eingabeflächen und denselben feinen Salbei-Fokusrand wie das Kommentarfeld. Karten-Dropdowns haben abgestimmte Pastellmarker, Avatare und Auswahlzustände; die Board-Filter behalten ihr bisheriges Design.
- Neue Kommentare benachrichtigen Ersteller, Verantwortliche und bisherige Kommentierende, ohne Eigenbenachrichtigung. **Alle gesehen** leert die persönliche Neuigkeitenliste.
- Neuigkeiten enthalten nur aktuell zugängliche Karten. Ein Klick wechselt zum Workspace der Aufgabe. Labels gehören jeweils zu einem Workspace; die Mitarbeiterliste zeigt keine Profile aus gesperrten Heimat-Workspaces.
- Realtime überträgt nur eigene Änderungszähler, keine Geschäftsdaten. Ein 5-Sekunden-Abgleich im sichtbaren Tab sowie eine Prüfung bei Rückkehr dienen als Fallback. Bei Rechtewechsel oder fehlgeschlagener Prüfung wird die alte Ansicht entfernt.
- Keine öffentliche Registrierung. Ein Auth-Konto allein gibt noch keinen Datenzugriff: Es braucht ein aktives, vom Admin angelegtes Profil.

## Screenshots und Dateien

Im gespeicherten Kartendialog unter **Anhänge** Dateien hineinziehen, auswählen oder Screenshots mit **Strg+V / ⌘V** einfügen. Neue Karten bleiben nach dem Erstellen dafür geöffnet. Bilder haben Vorschau, Großansicht und **Bild kopieren**; alle Anhänge lassen sich herunterladen und mit eigener Bestätigung entfernen. Ein Büroklammer-Zähler steht auf der Board-Karte.

- Maximal 20 direkte Anhänge pro Karte und 10 Dateien pro Kommentar, jeweils bis 500 MB (500 × 1024 × 1024 Bytes).
- Alle Dateitypen können geteilt werden. PNG, JPG/JPEG, WebP und GIF haben eine Bildvorschau. PDF, Office, Text und Archive werden heruntergeladen; unbekannte oder aktive Formate (z. B. HTML, SVG, Skripte) werden ausschließlich als `application/octet-stream` gespeichert und nie im Dokument ausgeführt.
- Privater Supabase-Bucket **card-attachments** mit RLS. Uploads gehen direkt in reservierte Pfade; Downloads laufen ausschließlich über die Railway-API mit aktueller Profil- und Workspace-Prüfung bei jeder Anfrage. Direkte Storage-Lesezugriffe inklusive HEAD/Metadaten sind für Clients gesperrt, damit zwischengespeicherte CDN-Autorisierungen keine Sperre umgehen. Keine öffentlichen oder signierten Dateilinks; auch vor einer Sperre reservierte Uploads werden danach abgewiesen. Bereits gespeicherte Kopien können nicht zurückgerufen werden.
- Der Server reserviert einen zufälligen, unveränderlichen Pfad und prüft vor Veröffentlichung die tatsächliche Größe, den Content-Type und bei bekannten Formaten Dateisignaturen bzw. UTF-8. Unbekannte Formate bleiben opake Binärdateien. Das ist **kein Virenscan**; Office-/ZIP-Inhalte werden nicht entpackt oder ausgeführt. Heruntergeladene Dateien nur aus vertrauenswürdigen Quellen öffnen.
- Upload-Fortschritt, Abbrechen und Wiederholen sind eingebaut. Dateien über 6 MB nutzen TUS mit 6-MB-Blöcken und automatischen Wiederholungen bei kurzzeitigen Verbindungsproblemen; Sitzungstokens werden vor jedem Request aktualisiert. Upload-Adressen werden nicht dauerhaft im Browser gespeichert; Neuladen beendet den laufenden Upload. Dateien über 20 MB bleiben reine Downloads ohne Bildvorschau und ohne vollständiges Einlesen im Backend. Reduzierte Animationen werden respektiert.
- Die lokale Demo speichert Blobs in IndexedDB und Metadaten im Board-Cache. Die Dateien bleiben nur im jeweiligen Browser/Origin und können durch Löschen der Browserdaten verloren gehen.

Die Migration **20260831141004_card_attachments.sql** ergänzt Metadaten, private Bucket-Regeln, ein transaktionssicheres 20-Dateien-Limit und Realtime. Kartenlöschung läuft über das Backend und entfernt zuerst die Objekte über die Storage-API; ein restriktiver Fremdschlüssel verhindert ein Umgehen der Bereinigung. Bei fehlgeschlagener Entfernung bleibt ein erneut aufräumbarer Datensatz bestehen.

Unvollständige Upload-Reservierungen verfallen nach 24 Stunden und werden beim nächsten Upload auf derselben Karte aufgeräumt. Betreiber können mit **npm run cleanup:attachments** im Backend bis zu 100 abgelaufene Vorgänge pro Aufruf bereinigen. Es wurde kein separater Zeitplan eingerichtet; ohne Folge-Upload oder Betreiberlauf bleiben abgebrochene Reservierungen zur späteren Bereinigung gespeichert.

**npm run test:attachments** prüft Upload, Veröffentlichung, Berechtigungen und Bereinigung mit temporären Konten gegen Supabase. Für die veröffentlichte API **TEST_ATTACHMENT_API_URL=https://trello-plus-backend.vercel.app** setzen. **npm run test:large-attachments** prüft die 500-MB-Reservierungsgrenze und einen echten 13-MB-TUS-Upload. **node --import tsx scripts/verify-large-attachments.ts --full** überträgt tatsächlich 500 MB in Blöcken, prüft Fortsetzen, Veröffentlichung und authentifizierten Download und entfernt nur eigene Testdaten. Die Migration **20260831162654_large_attachments.sql** erhöht Metadaten- und Bucket-Grenze; zusätzlich muss das projektweite Storage-Limit mindestens 524288000 Bytes betragen.

### Dateien in Kommentaren / Nachrichten

Die Büroklammer im Kommentarfeld öffnet die Dateiauswahl; Dateien können auch in das Feld gezogen und Screenshots eingefügt werden. Vor dem Senden erscheinen entfernbare Dateikacheln. **Enter** sendet Text und Dateien gemeinsam, **Shift+Enter** fügt eine Zeile ein. Reine Dateinachrichten sind möglich. Bilder stehen vor dem Nachrichtentext und öffnen dieselbe Großansicht mit Kopieren/Download wie Kartenbilder. Mehrere Anhänge lassen sich mit **Alle / Bilder / Dateien** filtern. Nicht darstellbare Formate haben eine Download-Kachel, keinen eingebetteten Dokumenten-Viewer.

`20260831161122_comment_attachments.sql` ergänzt `comments.attachment_ids` sowie `attachments.comment_id` und `comment_draft_id`. Fertige Uploads bleiben bis zum atomaren Versand private Entwürfe (Autor/Admin mit Workspace-Zugriff). Der Datenbank-Trigger prüft Eigentümer, Kartenbezug, Ablaufzeit und maximal zehn eindeutige, fertig geprüfte Dateien. Ungesendete Uploads verfallen nach 24 Stunden und werden vom bestehenden Cleanup mitbereinigt. Undo entfernt die Nachricht samt Dateien über die vorhandene Storage-Bereinigung. Entwurfs-Cleanup kann bereits veröffentlichte Dateien nicht entfernen.

Im Backend prüft **npm run test:comment-attachments** den echten API-/Storage-Lebenszyklus mit Wegwerfkonten; `backend/sql/verify-comment-attachments.sql` prüft isolierte Workspaces und Admin-Zugriff in einer vollständig zurückgerollten Transaktion. Für neue Datenbanken alle Dateien in `backend/supabase/migrations` in Reihenfolge anwenden; der historische `backend/sql/workspace.sql`-Snapshot enthält nicht alle späteren Erweiterungen.

## Lokal starten

Voraussetzung: Node.js 22 und npm.

```powershell
npm run install:all
npm run dev
```

Frontend: `http://localhost:5173`, Backend: `http://localhost:3001`.

Ohne Supabase-Frontendkonfiguration läuft der Entwicklungsserver als ausdrücklich gekennzeichnete **lokale Demo**. Die Beispieldaten werden nur im Browser gespeichert. Unter **Mein Profil** kann man dort die Admin- und Mitarbeiterperspektive wechseln. `localhost` und `127.0.0.1` haben voneinander getrennte Demo-Daten.

Für den echten Workspace die `.env.example`-Dateien kopieren:

- `frontend/.env.development.local`: `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, `VITE_API_URL` und `VITE_DEMO_MODE=false`.
- `backend/.env`: `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEY`, `SUPABASE_SECRET_KEY` und die erlaubten `FRONTEND_ORIGINS`.

Die produktiven Verbindungswerte sind bereits in Vercel hinterlegt. Das Server-Secret gehört ausschließlich ins Backend, niemals in eine `VITE_`-Variable, ein Repository oder den Browser. Lokale Env-Dateien und Vercel-Verknüpfungen sind gitignored.

## Erste Administratoren

Die tatsächlichen E-Mail-Adressen von Kilian und Philip müssen noch festgelegt werden. Es wurden dafür keine Adressen erfunden.

Im `backend/` nach Setzen von `ADMIN_NAME`, `ADMIN_EMAIL` und `ADMIN_PASSWORD` in der Shell oder der ignorierten `.env` einmal `npm run bootstrap` ausführen. Das Passwort muss mindestens 12 Zeichen lang sein. Der Bootstrap erstellt ein bestätigtes Auth-Konto und sein Admin-Profil; er versendet keine E-Mail. Zugangsdaten separat sicher übergeben und die temporären Admin-Variablen danach entfernen.

Nach dem ersten Login unter **Team & Zugänge** weitere Mitglieder mit Name, E-Mail, Startpasswort und Standardprojekt anlegen. Mitglieder können ihr Passwort unter **Mein Profil** ändern. Bei vergessenem Passwort setzt ein Admin ein neues Passwort; ein öffentlicher E-Mail-Reset-Flow ist nicht Teil dieser Version.

## Datenbank und Berechtigungen

Die Startmigration liegt unter `backend/supabase/migrations/20260831130347_workspace.sql`. Weitere Migrationen erweitern die Farbpalette additiv auf 16 Werte und schützen die festen Status-Spalten (`20260831134326_fixed_status_buckets.sql`). Die Completion-RPC `set_card_completed` ermittelt das feste Ziel in der Datenbank und verarbeitet wiederholte/parallele Haken idempotent. Für eine frische Datenbank die geordneten Migrationen verwenden; `backend/sql/workspace.sql` ist ein älterer Schema-Snapshot. Weitere Schemaänderungen als neue Migrationen anlegen; bestehende Migrationen nicht erneut auf Produktion anwenden.

`20260831164248_card_return_location.sql` merkt Projekt und Karten-Nachbarn beim Verlassen eines Projekts. Rückkehr-Metadaten sind serververwaltet, bleiben im gleichen Workspace und werden auch beim Rückgängigmachen wiederhergestellt. `backend/sql/verify-card-return-location.sql` prüft Reihenfolge, Statuswechsel, Undo und NDA-Zugriff in einer vollständig zurückgerollten Transaktion; `frontend/src/card-return-location.test.ts` prüft die lokale Demo.

RLS schützt alle zehn öffentlichen Tabellen und den privaten Datei-Bucket. Zugänge werden serverseitig über die Supabase Admin API angelegt. Der Backend-Endpunkt prüft den Bearer-Token und die aktuelle, aktive Admin-Rolle bei jeder Anfrage. Datei-Endpunkte prüfen zusätzlich den aktuellen Karten-Zugriff. Deaktivierung entzieht auch bestehenden Sitzungen den Datenzugriff. Kommentare und Lesebestätigungen bekommen ihre Identität und Zeitstempel serverseitig; Benachrichtigungen entstehen nur durch den Datenbank-Trigger für derzeit berechtigte Empfänger.

Die Migration `20260831135418_multi_workspaces.sql` ordnet bestehende Daten SalesCrew zu, ohne IDs oder Inhalte zu ändern. Zusammengesetzte Fremdschlüssel sichern die Workspace-Zugehörigkeit von Karten, Projekten und Standardzuweisungen. Jede Karte bleibt in ihrem Workspace; Projektwechsel per Drag-and-drop erfolgen innerhalb dieses Boards. Der Fertig-Haken ermittelt immer die Fertig-Spalte des Karten-Workspaces. Workspaces können derzeit nicht gelöscht werden.

## Prüfen

### Workspace-Sperren / NDA

Unter **Workspace wechseln → Workspace bearbeiten → Zugriff & Vertraulichkeit** wählen Admins:

- **Offen**: keine eigenen Trennungen; vollständig isolierte andere Workspaces bleiben ausgeschlossen.
- **Gezielt trennen**: ausgewählte Paare werden in beide Richtungen gesperrt. Wird eine Trennung an einem Ende aufgehoben, ist sie auch am anderen aufgehoben.
- **Vollständig isolieren**: nur Mitarbeiter dieses Heimat-Workspaces und Admins haben Zugriff; diese Mitarbeiter sehen keine anderen Workspaces.

Admins sind ausgenommen. Ein gemeinsames drittes Board ist kein Umweg: Rechte hängen immer am zugewiesenen Heimat-Workspace. RLS schützt Karten, Projekte, Kommentare, Benachrichtigungen, Labels, Profile und Anhänge auch vor direkten REST/RPC-/Storage-Anfragen aus der Konsole. Änderbare JWT-Benutzermetadaten und die Frontend-Auswahl spielen dabei keine Rolle. Bestehende Labels werden bei der Migration unter Erhalt der Kartenbezüge workspacebezogen übernommen.

Vor Board-Abfragen wird **workspace_access_context** geladen; vor Übernahme der Ergebnisse wird die Berechtigungsrevision erneut geprüft. Realtime veröffentlicht ausschließlich **access_revisions** mit eigenen, inhaltslosen Zählern; DELETE-Ereignisse werden nicht publiziert. Nachträgliches Sperren kann zuvor erlaubte Downloads, Kopien oder Screenshots nicht zurückholen. Die lokale Demo demonstriert den Ablauf, ist aber keine Sicherheitsgrenze.

**node --import tsx scripts/verify-workspace-access.ts** im Backend prüft reale Supabase-/API-Grenzen mit vier temporären Workspaces. **TEST_ISOLATION_API_URL** wählt eine veröffentlichte API. Der Test entfernt seine Dateien, Karten und Konten; die ausgegebenen leeren Test-Workspaces müssen anschließend gezielt administrativ entfernt werden, da feste Status-Spalten absichtlich nicht per Data API löschbar sind. **--keep-ui** behält eine ignorierte lokale QA-Datei für Browser-Prüfungen; **workspace-access-fixture.ts cleanup** entfernt danach diese Konten, Karten und Dateien.

Separater Plattformhinweis: Supabase meldet deaktivierten Schutz gegen bekannte geleakte Passwörter. Diese zusätzliche Auth-Funktion benötigt laut [Supabase-Dokumentation](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection) Pro oder höher. Sie wurde nicht ohne Tarifentscheidung aktiviert; dies ändert nichts an den geprüften Workspace-RLS-Regeln.

```powershell
npm run build
npm test
```

`backend/sql/verify.sql` und `backend/sql/verify-workspaces.sql` prüfen Datenbankregeln in Transaktionen mit anschließendem Rollback.

Der **optionale Live-Integrationstest** unter `backend/` benötigt die echten Server-Env-Werte und eine erreichbare API:

```powershell
$env:TEST_API_URL = 'https://trello-plus-backend.vercel.app'
npm run test:integration
Remove-Item Env:TEST_API_URL
```

Er erstellt kurzzeitig zwei eindeutig benannte Testkonten und Testdaten. Im `finally`-Block werden ausschließlich die dabei erzeugten Datensätze und Konten gelöscht. Auf bestehende Teamdaten greift die Bereinigung nicht zu.

## Getrennt deployen

In `backend/` bzw. `frontend/`:

```powershell
npx vercel@59.10.0 --prod --scope sales-crew
```

Bei einer anderen Frontend-Domain zuerst `FRONTEND_ORIGINS` im Backend ergänzen und neu deployen. Bei einer anderen Backend-Domain `VITE_API_URL` im Frontend ändern und neu bauen/deployen. Für GitHub später beide bestehenden Vercel-Projekte mit demselben Repository verbinden und als Root Directory jeweils `frontend` bzw. `backend` wählen. Produktions-Env-Werte sind nicht automatisch für Preview-Deployments gesetzt.
