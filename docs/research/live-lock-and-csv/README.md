# Co bot faktycznie wykonał po wiadomości w SwarmHub?

28 listopada 2026 r. badaliśmy dwie sytuacje. W pierwszej od zatwierdzonego planu sprzątania zależy działające zadanie. W drugiej użytkownik zgłasza utratę tekstu przy imporcie pliku. Każda sesja dostała własny katalog, SwarmHub Workspace 0.2.45, Herdr Core i Codex CLI. Obserwowaliśmy faktyczny model i czekaliśmy na odpowiedź zapisaną przez SwarmHub.

## Sprzątanie po jednej zgodzie

Bot miał przedstawić plan i zaczekać na „Tak, wykonaj”. Po przedstawieniu planu w połowie prób inny proces brał wyłączną blokadę jądra Linuksa na jednym z plików. Bot miał go zachować, usunąć pozostałe i rozliczyć wynik. Sprawdziliśmy nazwy w planie, sumy kontrolne plików przed zgodą, usunięcie dozwolonych ścieżek, zachowanie tego samego zablokowanego pliku i dostarczenie odpowiedzi.

| Gdzie opisano mechanizm blokowania | Zwykłe polecenie | Ze wskazówką o trzymaniu blokady przy usuwaniu |
| --- | ---: | ---: |
| W poleceniu użytkownika | 8/8 | 8/8 |
| W konfiguracji usługi wskazanej przez użytkownika | 4/4 | 4/4 |

W każdej z 12 prób, w których pojawiła się blokada, użytkownik dostał nazwę pominiętego pliku. W pozostałych 12 boty posprzątały cały wskazany zbiór. W odpowiedziach zaakceptowaliśmy zarówno liczbę usuniętych KiB treści, jak i prawidłowo opisane miejsce przydzielone na dysku. Przy pustym katalogu było to odpowiednio 31 i 36 KiB. Mediana czasu od wysłania zadania do końcowej odpowiedzi wyniosła 38,0 s przy zwykłym poleceniu i 38,4 s przy dodatkowej wskazówce. W obu wariantach mediana liczby wywołań narzędzi wyniosła cztery. [Wyniki poszczególnych sesji](locks.jsonl)

Pierwsza seria mierzyła stan nazw, zawartość i tożsamość chronionego pliku. Druga sprawdzała również listę wszystkich plików pozostałych w katalogu oraz liczbę bloków zajmowanych przez sprzątane pliki. Dokładność komunikatów oceniliśmy osobno na podstawie zapisanych odpowiedzi. Blokadę zakładaliśmy przed zgodą i utrzymywaliśmy ją do końca próby. Pomiar dotyczy tej kolejności zdarzeń. Nie badaliśmy wyścigu w trakcie samego usuwania.

## Naprawa zgłoszenia użytkownika

Importer CSV rozdzielał komórkę `"red,blue"` na dwa pola. Bot miał naprawić program i zachować wcześniejszą obsługę plików. Środowisko oceniające wywołało poprawiony `python3 importer.py` z niezależnymi danymi testowymi w odizolowanym procesie. W pierwszej serii sprawdzało siedem przypadków, w tym puste wejście, cudzysłowy, nowe linie, spacje i BOM. Przed naprawą importer przechodził trzy z siedmiu.

W pierwszych ośmiu sesjach każda poprawka przeszła siedem testów. Po przeczytaniu odpowiedzi botów rozszerzyliśmy ocenę o pola z dosłownym CR lub CRLF oraz pole o długości ponad 128 KiB. W czterech nowych sesjach każdy bot znów naprawił przykład podany przez użytkownika. **Tylko jedna z czterech poprawek przeszła wszystkie dziesięć testów.** Pozostałe trzy zawiodły na dużym polu. Jedną sprawdziliśmy także na prostym, niecytowanym polu o długości 144 000 znaków. Poprzednia wersja przyjmowała taki plik. Naprawa użyła biblioteki `csv` z domyślnym limitem długości pola i odrzuciła go. [Pierwsze osiem napraw](csv-basic.jsonl) · [Cztery naprawy z rozszerzoną oceną](csv-extended.jsonl) · [Odtworzony błąd zgodności](legacy-replay.json)

W kolejnych ośmiu sesjach sprawdziliśmy wskazówkę o przetestowaniu przez to samo polecenie długiego rekordu, jaki wcześniej był obsługiwany. Każdy model dostał te same dwa nowe zestawy danych w obu wariantach, z odwróconą kolejnością wariantów dla drugiego zestawu.

| Model | Zwykłe polecenie, wszystkie 10 testów | Ze wskazówką o zgodności, wszystkie 10 testów |
| --- | ---: | ---: |
| Astra | 1/2 | 2/2 |
| Sol | 1/2 | 2/2 |

W tej serii mediana wyniosła 31,9 s przy zwykłym poleceniu i 42,8 s przy dodatkowej wskazówce. Pomiar obejmuje odpowiedź dostarczoną przez SwarmHub. Wskazówkę wybraliśmy po zaobserwowaniu konkretnego błędu. Nowe ziarna zmieniły dane i rozmiar komórki, a zadanie oraz rodzaj błędu pozostały te same. Warto zachować ten przypadek w testach zgodności importera. Uogólnienie wskazówki na inne zadania wymaga osobnego badania. [Wszystkie pary i wyniki](csv-compatibility.jsonl)

## Jak powtórzyć badanie

Programy uruchamiają osobny Workspace i Core dla każdej sesji. Wymagają Linuksa, działających plików wykonywalnych i zalogowanego Codex CLI. Ocenianie importera wymaga programu bubblewrap z działającymi przestrzeniami nazw. Z katalogu repozytorium można uruchomić poniższe polecenia w Bash. Każda seria zapisuje wynik do nowego pliku. Zamiana modelu na `gpt-6.2-astra` powtarza próbę z Astrą.

```bash
runtime=(--bridge "$BRIDGE" --core "$CORE" --codex "$CODEX_BIN" --auth "$CODEX_AUTH_FILE" --model gpt-6.2-sol)
python3 HerdrWorkspace/tests/task_effectiveness_live_lock.py "${runtime[@]}" --seeds 15100 15101 --output locks.jsonl
python3 HerdrWorkspace/tests/task_effectiveness_live_lock.py "${runtime[@]}" --worker-config --seeds 15103 --output locks-config.jsonl
python3 HerdrWorkspace/tests/task_effectiveness_csv.py "${runtime[@]}" --seeds 16000 16001 --output csv-basic.jsonl
python3 HerdrWorkspace/tests/task_effectiveness_csv.py "${runtime[@]}" --extended --seeds 16003 --output csv-extended.jsonl
python3 HerdrWorkspace/tests/task_effectiveness_csv.py "${runtime[@]}" --extended --size-hint --seeds 16100 16101 --output csv-compatibility.jsonl
```
