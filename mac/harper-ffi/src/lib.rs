//! C bridge for Harper (https://github.com/Automattic/harper): `harper_lint(text, dialect)` returns a JSON
//! array of lints with char offsets; `harper_free` releases the string. Rules and dictionary come from
//! harper-core's curated set, all offline.
use harper_core::linting::{LintGroup, Linter, Suggestion};
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

fn lint_impl(text: &str, dialect: u32) -> Vec<LintOut> {
    let dialect = match dialect {
        1 => Dialect::British,
        2 => Dialect::Canadian,
        3 => Dialect::Australian,
        _ => Dialect::American,
    };
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

/// # Safety
/// `p` must come from `harper_lint`.
#[no_mangle]
pub unsafe extern "C" fn harper_free(p: *mut c_char) {
    if !p.is_null() {
        drop(CString::from_raw(p));
    }
}

#[no_mangle]
pub extern "C" fn harper_version() -> u32 {
    1
}
