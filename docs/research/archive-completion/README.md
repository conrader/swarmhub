# Czy agent doprowadzi zadanie do końca po zmianie planu?

Sprawdziliśmy osiem rzeczywistych sesji gpt-6.2-sol uruchomionych przez Workspace 0.2.48. Każda pracowała na własnym katalogu testowym. Celem było 20 KiB wolnego. Po zmianie stanu kopii pierwsza zgoda wystarczała do osiągnięcia 7 KiB. Inny plik o wielkości 25 KiB właśnie otrzymał poprawną kopię. Zgoda na jego usunięcie pozwalała dojść do 32 KiB. Program wysyłał tę zgodę po wymienieniu pliku przez bota i sprawdzeniu, że do tego momentu zmienił się wyłącznie zatwierdzony zakres. Po odpowiedzi sprawdzał bajty, sumy kontrolne, doręczenie i model.

| Zestawy | Standardowe polecenie | Przypomnienie o ponownym sprawdzeniu odłożonych możliwości |
| --- | ---: | ---: |
| Dwie pary pilotażowe | 1/2 | 2/2 |
| Dwie nowe pary | 1/2 | 2/2 |

We wszystkich ośmiu sesjach bot wykonał dozwoloną część pierwszego planu i zachował chronione dane. W dwóch nieukończonych próbach zaproponował czekanie na zakończenie kompilacji. W pozostałych sześciu wystarczyły dwie zgody, po jednej dla każdego zakresu, bez ponaglania. Weryfikacja treści daje ważne rozróżnienie. W obu ukończonych próbach standardowych bot nazwał plik, lecz zaproponował dopiero sprawdzić lub przygotować kopię. We wszystkich czterech próbach ze wskazówką opisał już sprawdzoną kopię, a po zgodzie uzyskał 32 KiB.

To porównanie jednego modelu i dwóch układów wielkości plików. W obu parach z większym pierwotnym archiwum wariant standardowy proponował czekanie. Próby mierzą działanie w krótkich rozmowach przy zmianie stanu plików, bez produkcyjnego serwera i bez przejścia przez mechanizm celów w aplikacji Mac. [Wyniki pilotażu](pilot.jsonl) · [Niezależne powtórzenie](holdout.jsonl)

Do powtórzenia służy scenariusz `archive_completion` w programie `HerdrWorkspace/tests/task_effectiveness_research.py`. Z katalogu projektu, po ustawieniu ścieżek do Workspace, Core, Codex i pliku autoryzacji, uruchom:

```bash
python3 HerdrWorkspace/tests/task_effectiveness_research.py \
  --bridge "$BRIDGE" --core "$CORE" --codex "$CODEX_BIN" --auth "$CODEX_AUTH_FILE" \
  --bridge-version 0.2.48 --model gpt-6.2-sol --cases archive_completion \
  --guidance-file docs/research/candidates/revisit-options.txt \
  --screen-seeds 28100 28101 --holdout-seeds 28102 28103 --out-dir wyniki-nowej-proby
```
