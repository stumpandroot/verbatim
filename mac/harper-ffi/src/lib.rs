//! C bridge for Harper (https://github.com/Automattic/harper): `harper_lint(text, dialect)` returns a JSON
//! array of lints with char offsets; `harper_free` releases the string. Rules and dictionary come from
//! harper-core's curated set, all offline. `harper_fix(text, dialect)` applies only a short list of
//! high-confidence rules (a/an, sentence capitals, "i" → "I", repeated words, spacing, its/it's, and a few
//! contractions) and returns the corrected text, for dictation cleanup.
use harper_core::linting::{Lint, LintGroup, Linter, Suggestion};
use harper_core::spell::FstDictionary;
use harper_core::{Dialect, Document};
use serde::Serialize;
use std::ffi::{c_char, CStr, CString};

#[derive(Serialize)]
struct SuggestionOut {
    kind: &'static str, // "replace" | "insert_after" | "remove"
    text: String,
}

#[derive(Serialize)]
struct LintOut {
    start: usize, // char offsets, end exclusive
    end: usize,
    kind: String,
    message: String,
    priority: u8,
    suggestions: Vec<SuggestionOut>,
}

fn dialect_of(d: u32) -> Dialect {
    match d {
        1 => Dialect::British,
        2 => Dialect::Canadian,
        3 => Dialect::Australian,
        _ => Dialect::American,
    }
}

fn lint_impl(text: &str, dialect: u32) -> Vec<LintOut> {
    let dialect = dialect_of(dialect);
    let dict = FstDictionary::curated();
    let mut group = LintGroup::new_curated(dict, dialect);
    let doc = Document::new_plain_english_curated(text);
    let mut out: Vec<LintOut> = group
        .lint(&doc)
        .into_iter()
        .map(|l| LintOut {
            start: l.span.start,
            end: l.span.end,
            kind: format!("{:?}", l.lint_kind),
            message: l.message.clone(),
            priority: l.priority,
            suggestions: l
                .suggestions
                .iter()
                .map(|s| match s {
                    Suggestion::ReplaceWith(c) => SuggestionOut { kind: "replace", text: c.iter().collect() },
                    Suggestion::InsertAfter(c) => SuggestionOut { kind: "insert_after", text: c.iter().collect() },
                    Suggestion::Remove => SuggestionOut { kind: "remove", text: String::new() },
                })
                .collect(),
        })
        .collect();
    out.sort_by_key(|l| l.start);
    out
}

/// # Safety
/// `text` must be a valid NUL-terminated UTF-8 string. The returned pointer must be released with `harper_free`.
#[no_mangle]
pub unsafe extern "C" fn harper_lint(text: *const c_char, dialect: u32) -> *mut c_char {
    if text.is_null() {
        return CString::new("[]").unwrap().into_raw();
    }
    let s = match CStr::from_ptr(text).to_str() {
        Ok(s) => s,
        Err(_) => return CString::new("[]").unwrap().into_raw(),
    };
    let json = serde_json::to_string(&lint_impl(s, dialect)).unwrap_or_else(|_| "[]".into());
    CString::new(json).unwrap_or_else(|_| CString::new("[]").unwrap()).into_raw()
}

/// Rules `harper_fix` applies. Each one fixes form, never meaning: no spelling guesses (names and jargon), no
/// style rewrites, nothing that touches numbers.
const FIX_RULES: &[&str] = &[
    "AnA",                        // "a apple" → "an apple"
    "SentenceCapitalization",     // a sentence starts with a capital
    "CapitalizePersonalPronouns", // "i" → "I"
    "Spaces",                     // doubled spaces
    "ItsContraction",             // "its going" → "it's going"
    "Didnt",                      // "didnt" → "didn't"
    "Cant",                       // "cant" → "can't"
    // Not RepeatedWords: it turns "I had had enough" into "I had enough". CleanupPrepass collapses repeats
    // with a list of doubles that carry meaning.
];

fn fix_impl(text: &str, dialect: u32) -> String {
    let dict = FstDictionary::curated();
    let mut group = LintGroup::new_curated(dict, dialect_of(dialect));
    group.config.clear();
    for r in FIX_RULES {
        group.config.set_rule_enabled(*r, true);
    }
    // Line by line: harper-core's a/an rule stops at the first word it can't decide ("a one-time"), so one such
    // word would otherwise switch it off for the whole text. Overlapping fixes ("its a" at a sentence start)
    // need a second pass.
    text.split('\n')
        .map(|line| {
            let mut cur = line.to_string();
            for _ in 0..3 {
                let next = fix_once(&mut group, &cur);
                if next == cur {
                    break;
                }
                cur = next;
            }
            cur
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn fix_once(group: &mut LintGroup, text: &str) -> String {
    if text.trim().is_empty() {
        return text.to_string();
    }
    let doc = Document::new_plain_english_curated(text);
    let mut lints: Vec<Lint> = group
        .organized_lints(&doc)
        .into_iter()
        .filter(|(k, _)| FIX_RULES.contains(&k.as_str()))
        .flat_map(|(_, v)| v)
        .filter(|l| !l.suggestions.is_empty())
        .collect();
    // Apply from the end so earlier spans stay valid; skip any lint that overlaps one already applied.
    lints.sort_by(|a, b| b.span.start.cmp(&a.span.start).then(b.span.end.cmp(&a.span.end)));
    let mut chars: Vec<char> = text.chars().collect();
    let mut floor = usize::MAX;
    for l in lints {
        if l.span.end > floor || l.span.end > chars.len() || l.span.start >= l.span.end {
            continue;
        }
        l.suggestions[0].apply(l.span, &mut chars);
        floor = l.span.start;
    }
    chars.into_iter().collect()
}

/// # Safety
/// `text` must be a valid NUL-terminated UTF-8 string. The returned pointer must be released with `harper_free`.
/// Returns NULL when the text can't be read, so the caller keeps its own text.
#[no_mangle]
pub unsafe extern "C" fn harper_fix(text: *const c_char, dialect: u32) -> *mut c_char {
    if text.is_null() {
        return std::ptr::null_mut();
    }
    let s = match CStr::from_ptr(text).to_str() {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    match std::panic::catch_unwind(|| fix_impl(s, dialect)) {
        Ok(out) => CString::new(out).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut()),
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
/// `p` must come from `harper_lint` or `harper_fix`.
#[no_mangle]
pub unsafe extern "C" fn harper_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

#[no_mangle]
pub extern "C" fn harper_version() -> u32 {
    2
}
