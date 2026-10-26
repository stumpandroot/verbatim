#!/usr/bin/env python3
"""The word patch gate: checks the built-in vocabulary (Verbatim/Resources/ModernVocabulary.json) and the everyday
fixes (Verbatim/Resources/EverydayFixes.json) before they ship. mac/tools/test-vocabulary.sh runs it in CI.

    python3 mac/tools/vocab_check.py                      # every check; exits 1 on a failure
    python3 mac/tools/vocab_check.py --corpus a.txt b.txt # also report every rule that fires on prose you supply
    python3 mac/tools/vocab_check.py --fix "some text"    # show what the app would make of a sentence
    python3 mac/tools/vocab_check.py --build-common-words  # rebuild the common-words list (needs `pip install wordfreq`)

Checks, in the order they run:
1. Schema: the file's keys, each term's keys and types, known categories, and no research fields.
2. Duplicates: one spelling per term, and no form listed twice or under two terms.
3. Frequency: a single-word `heard` or `exact` form is never a common English word (vocab-fixtures/common-words.txt),
   with vocab-fixtures/allowlist.txt listing the deliberate exceptions, each with its reason. `--phrases` also lists
   every `heard` phrase made only of common words, for a review by hand of new terms.
   A context form that starts with a name is listed with a capital, so only a context word triggers it.
4. Overlap and order: every form fixes to exactly its own term, every term's spelling is left alone, and the pass
   gives the same result when run twice. A shorter form inside a longer one for another term fails here unless the
   longest-first order handles it.
5. Corpus: no rule and no everyday fix changes a line of vocab-fixtures/negatives.txt (ordinary sentences).
6. Everyday fixes: the schema, every pattern compiles, every example becomes its fix, and every "keep" stays.
   A pattern's first group that took part is the span replaced (alternatives each have their own group).

The matching below mirrors Verbatim/Model/BuiltInVocabulary.swift and Verbatim/Flow/EverydayFixes.swift (whole-word
pattern, longest form first, context words, protected links and code), so a pass here is what the app does. Uses
only the standard library, so it runs on CI's stock python3.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MAC = os.path.dirname(HERE)
VOCAB = os.path.join(MAC, "Verbatim", "Resources", "ModernVocabulary.json")
EVERYDAY = os.path.join(MAC, "Verbatim", "Resources", "EverydayFixes.json")
FIXTURES = os.path.join(HERE, "vocab-fixtures")
COMMON = os.path.join(FIXTURES, "common-words.txt")
ALLOW = os.path.join(FIXTURES, "allowlist.txt")
NEGATIVES = os.path.join(FIXTURES, "negatives.txt")

# The categories the Settings list shows. A new one is a deliberate choice: add it here.
CATEGORIES = {"AI", "Software", "Platforms", "Devices", "Internet", "Creative tools", "Brands", "Finance", "Places",
              "People", "Film and video", "Business", "General"}
TERM_KEYS = {"term", "category", "heard", "exact", "context", "after", "boost"}
RESEARCH_KEYS = {"confidence", "why", "sources", "risk", "existing"}

# BuiltInVocabulary.beforeWords and .afterWords.
BEFORE_WORDS = {"on", "via", "using", "open", "opened", "opening", "into"}
AFTER_WORDS = {
    "call", "calls", "meeting", "meetings", "link", "links", "channel", "channels", "workspace", "workspaces",
    "account", "accounts", "page", "pages", "doc", "docs", "database", "app", "apps", "invite", "invites",
    "message", "messages", "thread", "threads", "profile", "integration", "integrations", "plugin", "plugins",
    "extension", "login", "subscription", "dashboard", "api", "bot", "server", "servers", "webinar", "template",
    "templates", "notification", "notifications",
}

# BuiltInVocabulary.guards, in Python's dialect ([\p{L}\p{N}] is [^\W_]).
GUARDS = [re.compile(p) for p in [
    r"(?i)\b(?:https?|ftp)://\S+",
    r"(?i)\bwww\.\S+",
    r"\S+@\S+\.\S+",
    r"(?i)\b[\w-]+(?:\.[\w-]+)*\.(?:com|org|net|io|ai|app|dev|co|me|gg|tv|ly|so|xyz|us|uk|ca|edu|gov|fm|to|sh|new|page|site|link)\b(?:/\S*)?",
    r"`[^`\n]*`",
    r"(?<!\S)[~.]{0,2}/\S+",
    r"\S*(?:[={}<>\\]|::|\(\))\S*",
]]

failures = []


def fail(msg):
    failures.append(msg)


# ---------------------------------------------------------------- the app's pass, in Python

def words(s):
    """BuiltInVocabulary.words: lowercased runs of letters and digits."""
    return re.findall(r"[^\W_]+", s.lower())


def pattern(form):
    """BuiltInVocabulary.pattern: whole words, not inside a handle, hashtag, path, or dotted name."""
    parts = [re.escape(p) for p in form.split()]
    return r"(?<![\w@#/.\-])" + r"\s+".join(parts) + r"(?![\w@/]|[.\-][^\W_])"


class Rule:
    def __init__(self, term, form, kind, after, order):
        self.term, self.form, self.kind, self.after, self.order = term, form, kind, after, order
        self.key = words(form)[0] if words(form) else None
        self.re = re.compile(pattern(form), 0 if kind == "exact" else re.IGNORECASE)


def rules_for(terms):
    raw = []
    for t in terms:
        after = {a.lower() for a in t.get("after", [])}
        for kind in ("heard", "exact", "context"):
            for f in t.get(kind, []):
                raw.append((t["term"], f, {"heard": "always"}.get(kind, kind), after))
    # Longest forms first, ties in file order (Swift's sort compares Character counts; ASCII-safe here).
    ordered = sorted(enumerate(raw), key=lambda e: (-len(e[1][1]), e[0]))
    out = []
    for i, (_, (term, form, kind, after)) in enumerate(ordered):
        r = Rule(term, form, kind, after, i)
        if r.key:
            out.append(r)
    return out


def protected(text):
    if not any(c in "./@`=<>{}\\:(" for c in text):
        return []
    return [m.span() for g in GUARDS for m in g.finditer(text)]


def is_sentence_start(text, loc):
    j = loc - 1
    while j >= 0 and text[j] in " \t\"'“‘([":
        j -= 1
    return j < 0 or text[j] in ".!?…:\n"


def _wordch(c):
    return c.isalpha() or c.isnumeric() or c in "'’"


def word_before(s):
    if not s or s[-1] not in " \t":
        return None
    t = s.rstrip(" \t")
    j = len(t)
    while j > 0 and _wordch(t[j - 1]):
        j -= 1
    return t[j:].lower() or None


def word_after(s):
    if not s or s[0] not in " \t":
        return None
    t = s.lstrip(" \t")
    j = 0
    while j < len(t) and _wordch(t[j]):
        j += 1
    return t[:j].lower() or None


def context_allows(text, span, extra, capital_counts=True):
    found = text[span[0]:span[1]]
    if capital_counts and found[:1].isupper() and not is_sentence_start(text, span[0]):
        return True
    w = word_before(text[:span[0]])
    if w and w in BEFORE_WORDS:
        return True
    w = word_after(text[span[1]:])
    return bool(w and (w in AFTER_WORDS or w in extra))


def allowed(rule, text):
    spans = [m.span() for m in rule.re.finditer(text)]
    if not spans:
        return []
    guarded = protected(text)
    out = []
    for s in spans:
        if text[s[0]:s[1]] == rule.term:
            continue
        if any(g[0] < s[1] and s[0] < g[1] for g in guarded):
            continue
        if rule.kind == "context" and not context_allows(text, s, rule.after, not rule.form[:1].isupper()):
            continue
        out.append(s)
    return out


class Vocabulary:
    def __init__(self, terms):
        self.rules = rules_for(terms)
        self.by_key = {}
        for r in self.rules:
            self.by_key.setdefault(r.key, []).append(r)

    def fix(self, text, trace=None):
        """BuiltInVocabulary.apply on one passage: candidates from the passage's words, then each rule in order."""
        cands = sorted({r for w in set(words(text)) for r in self.by_key.get(w, [])}, key=lambda r: r.order)
        for r in cands:
            spans = allowed(r, text)
            if not spans:
                continue
            if trace is not None:
                trace.append((r, text[spans[0][0]:spans[0][1]]))
            for a, b in reversed(spans):
                text = text[:a] + r.term + text[b:]
        return text


# ---------------------------------------------------------------- everyday fixes, in Python

def everyday_compile(fix):
    return re.compile(fix["pattern"], re.IGNORECASE | re.MULTILINE)


def match_case(found, repl):
    """EverydayFixes.matchCase: all capitals stay all capitals, a capital first letter stays capital."""
    if len(found) > 1 and found.isupper():
        return repl.upper()
    if found[:1].isupper():
        return repl[:1].upper() + repl[1:]
    return repl


def everyday_apply(fixes, text, trace=None):
    for fx, rx in fixes:
        # Curly apostrophes match as straight ones; both are one character, so spans line up.
        plain = text.replace("’", "'")
        spans = []
        for m in rx.finditer(plain):
            # The first group that took part is the span to replace; with none, the whole match.
            g = next((i for i in range(1, rx.groups + 1) if m.group(i) is not None), 0)
            spans.append(m.span(g))
        if not spans:
            continue
        if trace is not None:
            trace.append((fx, text[spans[0][0]:spans[0][1]]))
        for a, b in reversed(spans):
            text = text[:a] + match_case(text[a:b], fx["replace"]) + text[b:]
    return text


# ---------------------------------------------------------------- checks

def load_lines(path):
    if not os.path.exists(path):
        return []
    out = []
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        if line.strip() and not line.lstrip().startswith("#"):
            out.append(line)
    return out


def load_allow():
    """vocab-fixtures/allowlist.txt: `form | reason`, one per line."""
    allow = {}
    for line in load_lines(ALLOW):
        if "|" not in line:
            fail(f"allowlist: '{line}' needs a reason after |")
            continue
        form, why = (x.strip() for x in line.split("|", 1))
        if not why:
            fail(f"allowlist: '{form}' needs a reason")
        allow[form.lower()] = why
    return allow


def check_schema(data):
    if set(data) - {"version", "about", "terms"} or not isinstance(data.get("version"), int) or not isinstance(data.get("terms"), list):
        fail("schema: the file needs an integer version and a terms list, and nothing else besides about")
        return []
    terms = []
    for i, t in enumerate(data["terms"]):
        where = f"schema: term {i} ({t.get('term', '?')})"
        if not isinstance(t, dict):
            fail(f"{where}: not an object")
            continue
        extra = set(t) - TERM_KEYS
        if extra & RESEARCH_KEYS:
            fail(f"{where}: research fields don't ship: {sorted(extra & RESEARCH_KEYS)}")
        elif extra:
            fail(f"{where}: unknown keys {sorted(extra)}")
        if not isinstance(t.get("term"), str) or not t["term"].strip() or t["term"] != t["term"].strip():
            fail(f"{where}: term must be a trimmed, non-empty string")
            continue
        if t.get("category") not in CATEGORIES:
            fail(f"{where}: category {t.get('category')!r} isn't one of {sorted(CATEGORIES)}")
        for k in ("heard", "exact", "context", "after"):
            if k in t:
                v = t[k]
                if not isinstance(v, list) or not v or not all(isinstance(x, str) and x.strip() and x == x.strip() for x in v):
                    fail(f"{where}: {k} must be a non-empty list of trimmed strings")
                elif k != "after" and not all(words(x) for x in v):
                    fail(f"{where}: every {k} form needs a letter or digit")
                elif k == "after" and not all(len(x.split()) == 1 for x in v):
                    fail(f"{where}: after holds single words (the pass compares one word before or after)")
        if "boost" in t and not isinstance(t["boost"], bool):
            fail(f"{where}: boost must be true or false")
        if not any(t.get(k) for k in ("heard", "exact", "context")):
            fail(f"{where}: no forms")
        for f in t.get("exact", []):
            if f == t["term"]:
                fail(f"{where}: exact form {f!r} is the term itself")
        terms.append(t)
    return terms


def check_duplicates(terms):
    seen_terms = {}
    for t in terms:
        k = t["term"].lower()
        if k in seen_terms:
            fail(f"duplicate: term {t['term']!r} is listed twice")
        seen_terms[k] = t["term"]
    owner = {}
    for t in terms:
        mine = set()
        for kind in ("heard", "exact", "context"):
            for f in t.get(kind, []):
                key = f if kind == "exact" else f.lower()
                norm = " ".join(key.split())
                if (kind, norm) in mine or (kind != "exact" and ("any", norm) in mine):
                    fail(f"duplicate: {t['term']!r} lists {f!r} twice")
                mine.add((kind, norm))
                if kind != "exact":
                    mine.add(("any", norm))
                prev = owner.get(norm.lower())
                if prev and prev != t["term"]:
                    fail(f"duplicate: {f!r} is a form of both {prev!r} and {t['term']!r}")
                owner[norm.lower()] = t["term"]
                other = seen_terms.get(norm.lower())
                if other and other != t["term"]:
                    fail(f"duplicate: {f!r} (a form of {t['term']!r}) is another term's spelling, {other!r}")


def check_frequency(terms, common, allow, phrases=False):
    def common_word(w):
        w = w.lower()
        return w in common or w.replace("-", "") in common

    def token_common(tok):
        tok = tok.lower().strip(".,'’")
        return tok in common or tok.isdigit() or tok in NUMBER_WORDS

    for t in terms:
        for kind in ("heard", "exact"):
            for f in t.get(kind, []):
                if f.lower() in allow:
                    continue
                toks = f.split()
                if len(toks) == 1:
                    if kind == "exact" and f not in (f.lower(), f.capitalize()):
                        continue  # a mixed-case exact form ("NVidia") can't be an ordinary word as written
                    if common_word(f):
                        fail(f"frequency: {kind} form {f!r} of {t['term']!r} is a common English word "
                             "(move it to context, drop it, or allowlist it with a reason)")
                elif phrases and kind == "heard" and all(token_common(x) for x in toks):
                    # Report only: most such phrases are names ("magic mouse"), not ordinary English. Review
                    # each new one by hand; the corpus checks catch the ordinary ones.
                    print(f"review: heard phrase {f!r} of {t['term']!r} is made only of common words")


NUMBER_WORDS = {"zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
                "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "oh"}


def check_context_capitals(terms, common, allow):
    """A context form also fires when the engine capitalized it mid-sentence. For a name ("kofi", "disney plus")
    that capital is always there, so such a form must be listed with a capital, which limits it to context words."""
    for t in terms:
        for f in t.get("context", []):
            first = words(f)[0]
            if f[:1].isupper() or first[:1].isdigit() or first in common or f.lower() in allow:
                continue
            if "".join(words(f)) != "".join(words(t["term"])):
                fail(f"context: {f!r} of {t['term']!r} starts with a name, so a capital says nothing; list it as "
                     f"{f[:1].upper() + f[1:]!r} so only a context word counts")


def check_order(terms, vocab):
    """Every form fixes to its own term (so an overlap the longest-first order doesn't handle fails), terms stay."""
    for t in terms:
        term = t["term"]
        got = vocab.fix(term)
        if got != term:
            fail(f"order: the term {term!r} itself changes to {got!r}")
        for kind in ("heard", "exact"):
            for f in t.get(kind, []):
                trace = []
                got = vocab.fix(f, trace)
                if got != term:
                    by = ", ".join(f"{r.term!r} via {r.form!r}" for r, _ in trace) or "nothing fired"
                    fail(f"order: {kind} form {f!r} of {term!r} becomes {got!r} ({by})")
                elif vocab.fix(got) != got:
                    fail(f"order: {f!r} isn't stable: {got!r} then {vocab.fix(got)!r}")
        for f in t.get("context", []):
            s = f"I opened it on {f} today."
            want = f"I opened it on {term} today."
            got = vocab.fix(s)
            if got != want:
                fail(f"order: context form {f!r} of {term!r} gives {got!r}, not {want!r}")
    # Shorter forms inside longer ones for another term, reported for the record (the checks above decide).
    pairs = 0
    forms = [(t["term"], f) for t in terms for k in ("heard", "exact") for f in t.get(k, [])]
    for ta, fa in forms:
        wa = " " + " ".join(words(fa)) + " "
        for tb, fb in forms:
            if ta != tb and len(fb) < len(fa) and (" " + " ".join(words(fb)) + " ") in wa:
                pairs += 1
    return pairs


def check_corpus(vocab, fixes, lines, label):
    hits = 0
    for line in lines:
        trace = []
        got = vocab.fix(line, trace)
        etrace = []
        got2 = everyday_apply(fixes, got, etrace)
        if got2 != line:
            hits += 1
            why = "; ".join([f"{r.term} via {found!r}" for r, found in trace] +
                            [f"everyday {fx['id']} via {found!r}" for fx, found in etrace])
            fail(f"{label}: changed {line!r} -> {got2!r} ({why})")
    return hits


def check_everyday(path):
    if not os.path.exists(path):
        fail("everyday: EverydayFixes.json is missing")
        return []
    data = json.load(open(path, encoding="utf-8"))
    if set(data) - {"version", "about", "fixes"} or not isinstance(data.get("version"), int) or not isinstance(data.get("fixes"), list):
        fail("everyday: the file needs an integer version and a fixes list, and nothing else besides about")
        return []
    out, ids = [], set()
    keys = {"id", "wrong", "right", "pattern", "replace", "examples", "keep"}
    for i, fx in enumerate(data["fixes"]):
        where = f"everyday: fix {i} ({fx.get('id', '?')})"
        if set(fx) - keys or not {"id", "pattern", "replace", "examples", "keep"} <= set(fx):
            fail(f"{where}: keys must be {sorted(keys)} (wrong and right optional)")
            continue
        if fx["id"] in ids:
            fail(f"{where}: duplicate id")
        ids.add(fx["id"])
        try:
            rx = everyday_compile(fx)
        except re.error as e:
            fail(f"{where}: pattern doesn't compile: {e}")
            continue
        if not fx["examples"] or not fx["keep"]:
            fail(f"{where}: needs at least one example and one keep sentence")
        out.append((fx, rx))
    for fx, rx in out:
        for pair in fx["examples"]:
            if not (isinstance(pair, list) and len(pair) == 2):
                fail(f"everyday {fx['id']}: an example is [before, after]")
                continue
            got = everyday_apply([(fx, rx)], pair[0])
            if got != pair[1]:
                fail(f"everyday {fx['id']}: {pair[0]!r} gives {got!r}, not {pair[1]!r}")
            all_got = everyday_apply(out, pair[0])
            if all_got != pair[1]:
                fail(f"everyday {fx['id']}: with every fix, {pair[0]!r} gives {all_got!r}, not {pair[1]!r}")
        for s in fx["keep"]:
            got = everyday_apply(out, s)
            if got != s:
                fail(f"everyday {fx['id']}: keep sentence {s!r} changed to {got!r}")
    return out


def build_common_words(threshold=2.5):
    """Common English words: wordfreq's list at Zipf >= threshold, kept only when a lowercase entry of the en_US
    Hunspell dictionary (or a regular inflection of one) spells it, so brand names that are frequent on the web
    ("youtube", "github") aren't counted as English. Single letters other than a and I are left out."""
    from wordfreq import iter_wordlist, zipf_frequency  # pip install wordfreq
    dic = os.environ.get("HUNSPELL_DIC", "/usr/share/hunspell/en_US.dic")
    stems = set()
    for line in open(dic, encoding="utf-8"):
        w = line.split("/")[0].strip()
        if w and w == w.lower() and w.isalpha():
            stems.add(w)
    suffixes = ["'s", "s", "es", "ed", "d", "ing", "er", "ers", "est", "ly", "ies", "ied"]

    def in_dictionary(w):
        if w in stems:
            return True
        for s in suffixes:
            if w.endswith(s) and len(w) - len(s) >= 2:
                b = w[:-len(s)]
                if b in stems or (s in ("ies", "ied") and b + "y" in stems) or (s in ("ing", "ed", "er", "est") and b + "e" in stems):
                    return True
                if s in ("ing", "ed", "er") and len(b) > 2 and b[-1] == b[-2] and b[:-1] in stems:
                    return True
        return False

    out = set()
    for w in iter_wordlist("en"):
        if zipf_frequency(w, "en") < threshold:
            break
        if not w.replace("'", "").isalpha() or (len(w) == 1 and w not in ("a", "i")):
            continue
        if in_dictionary(w):
            out.add(w)
    header = ("# Common English words for the word patch gate (vocab_check.py). Generated by\n"
              f"# `python3 mac/tools/vocab_check.py --build-common-words`: wordfreq (Zipf >= {threshold}) words that the\n"
              "# en_US Hunspell dictionary spells in lowercase. wordfreq data: CC BY-SA 4.0, Robyn Speer\n"
              "# (https://github.com/rspeer/wordfreq). Hunspell en_US: SCOWL (http://wordlist.aspell.net).\n")
    with open(COMMON, "w", encoding="utf-8") as f:
        f.write(header + "\n".join(sorted(out)) + "\n")
    print(f"wrote {len(out)} words to {COMMON}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--corpus", nargs="*", default=[], help="prose files to report rule hits on (not committed)")
    ap.add_argument("--phrases", action="store_true", help="list heard phrases made only of common words")
    ap.add_argument("--fix", help="print what the vocabulary and everyday fixes make of this text")
    ap.add_argument("--build-common-words", action="store_true")
    ap.add_argument("--emit-parity", metavar="FILE", help="write cases with this script's results, for the Swift run "
                    "in test-vocabulary.sh to compare against the app's own code")
    ap.add_argument("--vocab", default=VOCAB)
    ap.add_argument("--everyday", default=EVERYDAY)
    args = ap.parse_args()

    if args.build_common_words:
        build_common_words()
        return 0

    data = json.load(open(args.vocab, encoding="utf-8"))
    terms = check_schema(data)
    vocab = Vocabulary(terms)
    fixes = check_everyday(args.everyday)

    if args.fix is not None:
        trace, etrace = [], []
        out = everyday_apply(fixes, vocab.fix(args.fix, trace), etrace)
        print(out)
        for r, found in trace:
            print(f"  vocabulary: {found!r} -> {r.term!r} ({r.kind} form {r.form!r})")
        for fx, found in etrace:
            print(f"  everyday: {found!r} -> {fx['replace']!r} ({fx['id']})")
        return 0

    if args.emit_parity:
        negatives = load_lines(NEGATIVES)
        vocab_inputs = list(negatives)
        for t in terms:
            vocab_inputs.append(t["term"])
            vocab_inputs += [f for k in ("heard", "exact") for f in t.get(k, [])]
            vocab_inputs += [f"I opened it on {f} today." for f in t.get("context", [])]
            vocab_inputs += [f"Then {f} was fine." for f in t.get("context", [])]
        every_inputs = list(negatives) + [p[0] for fx, _ in fixes for p in fx["examples"]] + [k for fx, _ in fixes for k in fx["keep"]]
        cases = {"vocabulary": [[x, vocab.fix(x)] for x in vocab_inputs],
                 "everyday": [[x, everyday_apply(fixes, x)] for x in every_inputs]}
        json.dump(cases, open(args.emit_parity, "w", encoding="utf-8"), ensure_ascii=False)
        print(f"wrote {len(cases['vocabulary'])} vocabulary and {len(cases['everyday'])} everyday cases")
        return 0

    common = set(load_lines(COMMON))
    if len(common) < 10000:
        fail("frequency: vocab-fixtures/common-words.txt is missing or too short")
    allow = load_allow()
    check_duplicates(terms)
    check_frequency(terms, common, allow, args.phrases)
    check_context_capitals(terms, common, allow)
    pairs = check_order(terms, vocab)
    negatives = load_lines(NEGATIVES)
    if len(negatives) < 100:
        fail("corpus: vocab-fixtures/negatives.txt is missing or too short")
    check_corpus(vocab, fixes, negatives, "corpus")

    for path in args.corpus:
        text = open(path, encoding="utf-8", errors="replace").read()
        # Paragraphs as passages, the way a transcript's segments reach the pass.
        paras = [" ".join(p.split()) for p in re.split(r"\n\s*\n", text) if p.strip()]
        before = len(failures)
        check_corpus(vocab, fixes, paras, f"corpus {os.path.basename(path)}")
        print(f"{os.path.basename(path)}: {len(paras)} paragraphs, {len(failures) - before} changed")

    unused = [f for f in allow if not any(f == x.lower() for t in terms for k in ("heard", "exact", "context") for x in t.get(k, []))]
    for f in unused:
        fail(f"allowlist: {f!r} isn't a heard or exact form any more; remove it")

    n_forms = sum(len(t.get(k, [])) for t in terms for k in ("heard", "exact", "context"))
    print(f"vocabulary v{data.get('version')}: {len(terms)} terms, {n_forms} forms, {len(vocab.rules)} rules, "
          f"{pairs} nested forms handled by order; {len(fixes)} everyday fixes; {len(negatives)} negative sentences")
    if failures:
        for f in failures:
            print("FAIL " + f)
        print(f"{len(failures)} word patch check(s) failed")
        return 1
    print("All word patch checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
