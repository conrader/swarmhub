"""Python port of GoalProtocol.looksLikeCoding (Sources/AgentApp/Models/ChatAutomation.swift).

There is no Swift toolchain on the Linux review host, so the classifier's rules are run here against the Swift test
table. The word lists are read from the Swift source itself (sim/test_fixes8.py checks that every list exists there),
so only the control flow below has to be kept in step with the Swift by hand.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
from pathlib import Path
import re

SWIFT = Path(__file__).resolve().parents[1] / 'Sources/AgentApp/Models/ChatAutomation.swift'
LISTS = ('explainVerbs', 'changeVerbs', 'codingOnlyVerbs', 'codeNouns', 'codePhrases', 'clauseWords', 'leadIns',
         'askingVerbs', 'questionStarters', 'pronouns', 'subordinateMarkers', 'seriesConnectors', 'nounDeterminers',
         'nonPluralModifiers', 'pluralQuantifiers')


def swift_lists(source=None):
    """name -> list of strings for every `static let name...= [...]` word list in the Swift source."""
    source = source if source is not None else SWIFT.read_text()
    lists = {}
    for name in LISTS:
        match = re.search(r'static let %s(?::[^=]+)?\s*=\s*\[(.*?)\]' % name, source, re.S)
        if match:
            lists[name] = re.findall(r'"([^"]*)"', match.group(1))
    return lists


_LISTS = swift_lists()
EXPLAIN_VERBS = set(_LISTS['explainVerbs'])
CHANGE_VERBS = set(_LISTS['changeVerbs'])
CODING_ONLY_VERBS = set(_LISTS['codingOnlyVerbs'])
CODE_NOUNS = set(_LISTS['codeNouns'])
CODE_PHRASES = list(_LISTS['codePhrases'])
CLAUSE_WORDS = set(_LISTS['clauseWords'])
LEAD_INS = set(_LISTS['leadIns'])
ASKING_VERBS = set(_LISTS['askingVerbs'])
QUESTION_STARTERS = set(_LISTS['questionStarters'])
PRONOUNS = set(_LISTS['pronouns'])
SUBORDINATE_MARKERS = set(_LISTS['subordinateMarkers'])
SERIES_CONNECTORS = set(_LISTS['seriesConnectors'])
NOUN_DETERMINERS = set(_LISTS['nounDeterminers'])
NON_PLURAL_MODIFIERS = set(_LISTS['nonPluralModifiers'])
PLURAL_QUANTIFIERS = set(_LISTS['pluralQuantifiers'])


def word_char(character):
    return character.isalpha() or character.isnumeric()


def names_code(words):
    scope = ' '.join(words)
    return any(word in CODE_NOUNS for word in words) or any(phrase in scope for phrase in CODE_PHRASES)


def sentence_words(text):
    characters = text.lower()
    parts, word = [[]], ''
    for offset, character in enumerate(characters):
        if word_char(character):
            word += character
            continue
        if word:
            parts[-1].append(word)
            word = ''
        ends = character in ';!?' or character in '\n\r\v\f\x85  ' or (
            character == '.' and (offset + 1 == len(characters) or characters[offset + 1].isspace()))
        if ends:
            if parts[-1]:
                parts.append([])
        elif character == ',':
            parts[-1].append(',')
    if word:
        parts[-1].append(word)
    return [part for part in parts if part]


def is_verb(word):
    return word in CHANGE_VERBS or word in CODING_ONLY_VERBS


def looks_plural(word):
    """A plural-subject hint: quantity words or an s suffix, excluding known names and -ss/-us/-is."""
    if word in NON_PLURAL_MODIFIERS:
        return False
    return word in PLURAL_QUANTIFIERS or (
        len(word) > 3 and word.endswith('s') and not word.endswith(('ss', 'us', 'is')))


def follows_determiner(words, index):
    """True when words[index] ends a noun phrase: a determiner, then up to three non-plural modifiers ("the nightly
    build", "our slow unit test"). A comma, connector, marker or question word before the determiner ends the scan.
    Quantity subjects also stop it; digits after a determiner count as quantities, while version modifiers
    ("the Windows 11 build") can still reach their determiner."""
    for back in range(index - 1, max(index - 5, -1), -1):
        word = words[back]
        if word in NOUN_DETERMINERS:
            return True
        if back > 0 and words[back - 1] in NOUN_DETERMINERS \
                and word and all('0' <= character <= '9' for character in word):
            return False
        if word in SERIES_CONNECTORS or word in SUBORDINATE_MARKERS or word in QUESTION_STARTERS \
                or word in CLAUSE_WORDS or looks_plural(word):
            return False
    return False


def is_series_head(words, index, embedded, coordinated):
    """Require a predicate marker or an uncoordinated finite noun-subject clause, not a noun object.
    This mirrors isSeriesHead in Swift, including the determiner and compound-noun guards."""
    if index <= 0 or not is_verb(words[index]):
        return False
    previous = words[index - 1]
    if previous in SUBORDINATE_MARKERS or (
            previous == 'also' and index > 1 and words[index - 2] in SUBORDINATE_MARKERS):
        return True
    compound_noun = previous + ' ' + words[index] in CODE_PHRASES
    return embedded == 'clause' and not coordinated and not follows_determiner(words, index) and not compound_noun


def verb_series_end(words, start):
    """Index of the last verb when words[start:] begins "V2, V3", "V2 and V3" or "V2, and then V3" (two or more verbs
    joined by connectors), else None. The series ends at the verb after its first conjunction ("A, B and C")."""
    index, last, count, closing = start, None, 0, False
    while index < len(words) and is_verb(words[index]):
        last, count = index, count + 1
        following = index + 1
        while following < len(words) and words[following] in SERIES_CONNECTORS:
            following += 1
        if closing or following == index + 1:
            break
        closing = any(word not in (',', 'also') for word in words[index + 1:following])
        index = following
    return last if count >= 2 else None


def requests_code_in_a_clause(text):
    parts = sentence_words(text)
    topic = [word for part in parts for word in part if word != ',']
    for index, word in enumerate(topic):
        if word in ('about', 'regarding'):
            topic = topic[:index]
            break
    mentions_code = names_code(topic)
    for words in parts:
        question = words[0] in QUESTION_STARTERS
        # embedded: None, 'infinitive' ("how to build and test") or 'clause' ("why the parser crashes").
        clause_start, index, explains, embedded, coordinated, objected = True, 0, False, None, False, False
        inner_verb = False
        series_ended = False
        while index < len(words):
            word = words[index]
            index += 1
            follows_series, series_ended = series_ended, False
            series_end = verb_series_end(words, index) if explains and word == ',' and inner_verb else None
            if series_end is not None:
                index, clause_start = series_end + 1, False
                # A completed series cannot be reused to swallow the next comma's commands.
                inner_verb = False
                series_ended = True
                coordinated = coordinated or embedded == 'clause'
                continue
            series_head = not clause_start and is_series_head(words, index - 1, embedded, coordinated)
            inner_verb = False
            if explains and word in QUESTION_STARTERS and embedded != 'infinitive':
                embedded = 'infinitive' if index < len(words) and words[index] == 'to' else 'clause'
                coordinated = False
                objected = False
            elif embedded == 'infinitive' and word not in ('to', 'and', 'then', 'also', 'plus', ',') and word not in CHANGE_VERBS \
                    and word not in CODING_ONLY_VERBS:
                objected = True
            if embedded == 'clause' and index >= 2 and (words[index - 2] in SUBORDINATE_MARKERS or (
                    index >= 3 and words[index - 2] == 'also' and words[index - 3] in SUBORDINATE_MARKERS)) and (
                    word in CHANGE_VERBS or word in CODING_ONLY_VERBS):
                coordinated = True
            reopens = (follows_series and word == ',') or embedded is None or (
                embedded == 'clause' and (word in (',', 'then') or not coordinated)) or (
                embedded == 'infinitive' and objected and word in (',', 'then'))
            if explains and reopens and word in ('and', 'then', 'plus'):
                clause_start, embedded, coordinated = True, None, False
                continue
            if clause_start and word in EXPLAIN_VERBS and (not question or words[0] in ASKING_VERBS):
                explains = True
            if word == ',' or word in CLAUSE_WORDS:
                if (not question or explains) and reopens:
                    clause_start, embedded, coordinated = True, None, False
                continue
            if clause_start and word in LEAD_INS:
                continue
            if clause_start and word in ASKING_VERBS and index < len(words) and words[index] == 'you':
                index += 1
                continue
            if clause_start and word in CODING_ONLY_VERBS:
                return True
            if clause_start and word in CHANGE_VERBS:
                objects = []
                for following in words[index:]:
                    if following == ',' or following in CLAUSE_WORDS or following in ('about', 'regarding'):
                        break
                    objects.append(following)
                if names_code(objects):
                    return True
                if objects and objects[0] in PRONOUNS and mentions_code:
                    return True
            inner_verb = series_head
            clause_start = False
    return False


def first_verb_requests_code(text):
    words = ''.join(c if word_char(c) else ' ' for c in text.lower()).split()
    for index, word in enumerate(words):
        if word in ('about', 'regarding'):
            words = words[:index]
            break
    objects = words
    for index, verb in enumerate(words):
        if verb in EXPLAIN_VERBS or verb in CHANGE_VERBS or verb in CODING_ONLY_VERBS:
            if verb in EXPLAIN_VERBS:
                return False
            if verb in CODING_ONLY_VERBS:
                return True
            objects = words[index + 1:]
            break
    return names_code(objects)


def looks_like_coding(text):
    return requests_code_in_a_clause(text) or first_verb_requests_code(text)
