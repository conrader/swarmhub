"""Python port of GoalProtocol.looksLikeCoding (Sources/AgentApp/Models/ChatAutomation.swift).

There is no Swift toolchain on the Linux review host, so the classifier's rules are run here against the Swift test
table. The word lists are read from the Swift source itself (sim/test_fixes8.py checks that every list exists there),
so only the control flow below has to be kept in step with the Swift by hand.
"""
from pathlib import Path
import re

SWIFT = Path(__file__).resolve().parents[1] / 'Sources/AgentApp/Models/ChatAutomation.swift'
LISTS = ('explainVerbs', 'changeVerbs', 'codingOnlyVerbs', 'codeNouns', 'codePhrases', 'clauseWords', 'leadIns',
         'askingVerbs', 'questionStarters', 'pronouns')


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
        clause_start, index, explains, embedded = True, 0, False, False
        while index < len(words):
            word = words[index]
            index += 1
            if explains and word in QUESTION_STARTERS:
                embedded = True
            if explains and not embedded and word in ('and', 'then'):
                clause_start = True
                continue
            if clause_start and word in EXPLAIN_VERBS and (not question or words[0] in ASKING_VERBS):
                explains = True
            if word == ',' or word in CLAUSE_WORDS:
                clause_start = clause_start or (not question and not embedded)
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
