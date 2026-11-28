# Czy bot odzyska miejsce i zachowa działające usługi?

28 listopada 2026 r. wykonano 44 izolowane sesje w SwarmHub Workspace 0.2.45 z modelami Codex Astra i Sol. Każda para otrzymała te same pliki i tę samą zgodę. Sprawdzono końcowe bajty, treść archiwum, stan pliku używanego przez zadanie i odpowiedź dostarczoną przez SwarmHub. Dane i obciążenie były syntetyczne.

| Próba | Sesje | Wynik |
| --- | ---: | --- |
| Drugi operator usuwa część danych między planem a zgodą | 8 | W 8 sesjach zgadzały się własny wkład, udział drugiego operatora i końcowe 21 wolnych jednostek. |
| Pilotaż z deklarowanym osobnym nośnikiem | 8 | Faktycznie oba katalogi leżały na jednym systemie plików. W trzech odpowiedziach Sol wykrył rozbieżność, zachował oryginał i podał niedobór. Pięć sesji przeniosło plik między katalogami. Tej partii nie wliczamy do oceny skuteczności. |
| Powtórzenie pilotażu z zamontowanym osobnym systemem plików | 8 | Wszystkie sesje osiągnęły 25 wolnych jednostek wobec celu 22. Kopia zgadzała się bajt w bajt z oryginałem. Chronione pliki zachowały treść. |
| Zgoda zależna od faktycznego miejsca zapisu | 16 | Na osobnym systemie plików 8/8 sesji osiągnęło 26 jednostek. Na wspólnym 8/8 zachowało oryginał, odzyskało dozwolone 11 jednostek i podało końcowy stan 13. |
| Powtórzenie na odłożonym zestawie plików, Sol | 4 | Wszystkie decyzje i pomiary były poprawne. Przy osobnym systemie plików końcowy wynik wyniósł 24, przy wspólnym 13. |

W głównym porównaniu każdy bot dostał jedno polecenie. W katalogu była też notatka poprzedniego operatora o czekaniu na pomocnika. Uruchomiono po dwa zestawy plików dla każdego modelu, zmieniając kolejność wariantów. Zwykła instrukcja dała 8/8 poprawnych odpowiedzi, z medianą 27,2 s. Z dodatkowym przypomnieniem o porównaniu identyfikatorów urządzeń wynik również wyniósł 8/8, mediana 28,1 s. Próba nie uzasadnia dodania takiej instrukcji wszystkim botom. [Odpowiedzi i kryteria głównej próby](paired.jsonl) · [Odłożony zestaw](holdout.jsonl)

**Co to wyjaśnia w przypadku Infry?** W prostym otoczeniu, z jasnym warunkiem i zgodą, oba modele wykonywały dostępną część bez ponaglania. W pilotażu błędny opis nośnika prowadził także do czynności, które wyglądały na sukces według licznika katalogu, chociaż nie zwalniały miejsca na fizycznym systemie plików. Dlatego liczymy zarówno efekt, jak i poprawność decyzji przy rzeczywistej blokadzie. Ta próba nie odtwarza wielogodzinnego kontekstu, instrukcji operacyjnych ani konkurencyjnych zapisów z sesji Infry. [Niezależny wkład dwóch operatorów](external.jsonl) · [Niespójne środowisko](pilot-same.jsonl) · [Powtórzenie po zamontowaniu](pilot-mounted.jsonl)

## Powtórzenie

Z katalogu repozytorium, na Linuksie z obsługą prywatnych przestrzeni użytkownika i montowania, uruchom poniższe polecenie. Zmienne wskazują używany Workspace, Herdr Core, natywny Codex CLI i lokalny plik autoryzacji. Podaj nową ścieżkę na wyniki. Program tworzy jednorazowy katalog roboczy i montuje w nim mały tmpfs w wariancie z osobnym systemem plików.

```sh
unshare --user --map-root-user --mount python3 HerdrWorkspace/tests/task_effectiveness_offload.py \
  --bridge "$BRIDGE" --core "$CORE" --codex "$CODEX_BIN" --auth "$CODEX_AUTH_FILE" \
  --model gpt-6.2-sol --seeds 15000 15001 --output paired-sol.jsonl
```

Jednostka pomiaru to 1024 bajty treści zwykłych plików. Test sprawdza urządzenie docelowe i sumę SHA-256 zarchiwizowanej treści. Kolejność sprawdzenia kopii i usunięcia oryginału nie jest niezależnie rejestrowana. Pole `state_passed` opisuje stan plików, model wykonujący zadanie i doręczenie odpowiedzi. Treść końcowego pomiaru w czacie oceniono osobno. [Program pomiarowy](../../../HerdrWorkspace/tests/task_effectiveness_offload.py)
