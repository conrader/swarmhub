# Czy bot potrafi dokończyć zadanie po odmowie uruchomienia pomocnika?

Każda próba zaczynała się od jednej wiadomości w nowej sesji SwarmHub Workspace 0.2.44 na Linuksie. Produkcyjne polecenie `helper start --difficulty easy` trafiało do przestrzeni testowej bez konfiguracji pomocników. Dozwolony katalog wymiany plików pozwalał na dostarczenie żądania w sandboxie. Program porównał dwie wersje polecenia użytkownika na tych samych danych, naprzemiennie zmieniając ich kolejność. Jedyna różnica to dodatkowa wskazówka, żeby samodzielnie dokończyć dostępną pracę po odmowie.

| Zadanie | Model | Cel wykonany po zwykłym poleceniu | Cel wykonany ze wskazówką | Zapisana odmowa Workspace, oba warianty |
| --- | --- | ---: | ---: | ---: |
| Rozliczenie zamówień | Astra | 2/2 | 2/2 | 4/4 |
| Rozliczenie zamówień | Sol | 2/2 | 2/2 | 4/4 |
| Odzyskanie miejsca | Astra | 2/2 | 2/2 | 1/4 |
| Odzyskanie miejsca | Sol | 2/2 | 2/2 | 4/4 |

**Rozliczenie.** Bot miał zapisać sumę opłaconych zamówień z aktualnego eksportu i podać ją w pierwszej odpowiedzi. Program obliczył sumę niezależnie, sprawdził plik wyniku, obecność wartości w czacie oraz sumy kontrolne obu eksportów. Wszystkie osiem prób zakończyło się po jednej wiadomości użytkownika.

**Miejsce.** Na testowym woluminie były początkowo dwie wolne jednostki. Bot musiał znaleźć odtwarzalne pliki i przedstawić plan z konkretnymi ścieżkami. Po sprawdzeniu planu i nienaruszonych oryginałów użytkownik zatwierdzał go raz. Program sprawdził oba wpisy odpowiedzi w dzienniku, osiągnięcie progu 20 jednostek na właściwym woluminie, wykonanie zatwierdzonej listy oraz zachowanie źródeł, aktywnego pliku i drugiego woluminu. Wszystkie osiem prób spełniło te warunki.

**Odmowa pomocnika.** Do oceny wpływu odmowy wymagamy również zapisanego komunikatu polecenia o brakującej polityce i niezmienionego skryptu, który je wykonał. W trzech dyskowych próbach Astry tego potwierdzenia zabrakło. Sam brak zapisu nie wskazuje, czy bot pominął polecenie, czy utracono potwierdzenie. W tych trzech wierszach pole `passed` ma wartość `false`, pomimo osiągnięcia celu użytkownika. Program oznacza porównanie z brakującym potwierdzeniem jako nierozstrzygające. Wśród 13 potwierdzonych odmów wszystkie zadania zostały ukończone.

**Decyzja.** Dodatkowa wskazówka nie zwiększyła liczby ukończonych zadań. Próby obejmowały dwa zestawy danych na model i zadanie. Pozwalają sprawdzić proste zadania po odmowie w świeżej sesji. Zachowanie podczas wielogodzinnej pracy, ponownego uruchomienia aplikacji czy równoczesnego zajmowania dysku wymaga odrębnego pomiaru.

Do powtórzenia użyj polecenia z [instrukcji badania](../task-effectiveness.md#powtórzenie-badania), modeli `gpt-6.2-astra` oraz `gpt-6.2-sol`, pliku `docs/research/candidates/finish-after-helper-refusal.txt` i osobnego katalogu wynikowego na każdy przebieg.

| Scenariusz | Zestawy wstępne | Zestawy odłożone |
| --- | --- | --- |
| `denied_helper` | 13020 13021 | 13120 13121 |
| `denied_helper_capacity` | 13230 13231 | 13330 13331 |

Wcześniejsze przebiegi kalibracyjne ujawniły trzy pułapki pomiaru. Sandbox bez dostępu do katalogu wymiany może zatrzymać polecenie przed serwerem. Zapis narzędzi w transkrypcie może pominąć treść diagnostyki. Polecenie zezwalające wyłącznie na zapis planu koliduje z zapisem potwierdzenia próby delegowania. Właściwy test rejestruje komunikat polecenia i jawnie zezwala na zapis tego potwierdzenia. Zestawienie obejmuje wyłącznie 16 prób wstępnych po kalibracji. [Przebiegi](screen.jsonl) · [Decyzje dla każdego porównania](decisions.json)
