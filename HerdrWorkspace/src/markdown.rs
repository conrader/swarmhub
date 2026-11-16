use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd, html};
use serde::Deserialize;
use serde_json::value::RawValue;
use std::fmt::Write;
use std::{cell::RefCell, collections::VecDeque};

const REPLY_LIMIT: usize = 32 * 1024;
const HTML_LIMIT: usize = 96 * 1024;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Reply,
    Page,
    Portable,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ReplyKey {
    Direct(i64),
    Group(i64),
}

struct CachedReply {
    key: ReplyKey,
    text: String,
    html: Option<String>,
}

thread_local! {
    // Polling reads many of the same messages. Cache only recent, bounded previews.
    static REPLIES: RefCell<VecDeque<CachedReply>> = const { RefCell::new(VecDeque::new()) };
}

pub fn reply(key: ReplyKey, text: &str) -> Option<String> {
    if text.len() > REPLY_LIMIT
        || !text
            .bytes()
            .any(|byte| b"*_~`>#-|[]+=.0123456789".contains(&byte))
    {
        return None;
    }
    REPLIES.with_borrow_mut(|cache| {
        if let Some(index) = cache
            .iter()
            .position(|entry| entry.key == key && entry.text == text)
        {
            let entry = cache.remove(index).expect("located cache entry");
            let html = entry.html.clone();
            cache.push_front(entry);
            return html;
        }
        let (html, formatted) = render(text, Mode::Reply);
        let html = (formatted && html.len() <= HTML_LIMIT).then_some(html);
        cache.retain(|entry| entry.key != key);
        if cache.len() >= 48 {
            cache.pop_back();
        }
        cache.push_front(CachedReply {
            key,
            text: text.into(),
            html: html.clone(),
        });
        html
    })
}

pub fn page(text: &str) -> String {
    render(text, Mode::Page).0
}

pub fn portable_page(title: &str, revision: i64, text: &str) -> String {
    let mut output = String::from(concat!(
        "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n",
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\">\n",
        "<title>"
    ));
    escape_text(&mut output, title);
    output.push_str(concat!(
        "</title>\n<style>\n",
        include_str!("../web/page-export.css"),
        "</style>\n</head>\n<body><main>\n<header><h1>"
    ));
    escape_text(&mut output, title);
    writeln!(
        output,
        "</h1><p>SwarmHub Page · Revision {revision} · Read-only copy</p></header>\n<article>"
    )
    .expect("formatting into a string");
    output.push_str(&render(text, Mode::Portable).0);
    output.push_str("</article>\n</main></body></html>\n");
    output
}

pub fn check_task(markdown: &mut String, index: usize, checked: bool) -> Option<bool> {
    let (was_checked, range) = Parser::new_ext(markdown, options(false))
        .into_offset_iter()
        .filter_map(|(event, range)| match event {
            Event::TaskListMarker(checked) => Some((checked, range)),
            _ => None,
        })
        .nth(index)?;
    if was_checked == checked {
        return Some(false);
    }
    if !matches!(markdown.get(range.clone())?, "[ ]" | "[\t]" | "[x]" | "[X]") {
        return None;
    }
    markdown.replace_range(range, if checked { "[x]" } else { "[ ]" });
    Some(true)
}

fn options(for_reply: bool) -> Options {
    let standard = Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH;
    if for_reply {
        standard
    } else {
        standard | Options::ENABLE_TASKLISTS
    }
}

fn render(markdown: &str, mode: Mode) -> (String, bool) {
    let mut links = Vec::new();
    let mut formatted = false;
    let mut chart: Option<String> = None;
    let parser = Parser::new_ext(markdown, options(mode == Mode::Reply));
    let events = parser.filter_map(|event| {
        if let Some(source) = chart.as_mut() {
            return match event {
                Event::End(TagEnd::CodeBlock) => {
                    let source = chart.take().expect("open chart");
                    Some(Event::Html(render_chart(&source).into()))
                }
                Event::Text(content) => {
                    source.push_str(&content);
                    None
                }
                _ => None,
            };
        }
        match event {
            Event::Html(text) | Event::InlineHtml(text) => Some(Event::Text(text)),
            Event::Start(Tag::Image { .. }) | Event::End(TagEnd::Image) => None,
            Event::Start(Tag::Link { ref dest_url, .. }) => {
                let allowed = ["https://", "http://"]
                    .iter()
                    .any(|prefix| dest_url.starts_with(prefix))
                    && !dest_url.chars().any(char::is_control)
                    && reqwest::Url::parse(dest_url).is_ok_and(|url| {
                        url.has_host() && url.username().is_empty() && url.password().is_none()
                    });
                formatted |= allowed;
                links.push((
                    allowed,
                    (mode == Mode::Portable && allowed).then(|| dest_url.clone()),
                ));
                (allowed && mode != Mode::Portable).then_some(event)
            }
            Event::End(TagEnd::Link) => match links.pop() {
                Some((true, Some(url))) => Some(Event::Text(format!(" ({url})").into())),
                Some((true, None)) => Some(event),
                _ => None,
            },
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(ref info)))
                if mode == Mode::Portable && info.split(' ').next() == Some("chart") =>
            {
                chart = Some(String::new());
                None
            }
            Event::Start(
                Tag::Heading { .. }
                | Tag::BlockQuote(_)
                | Tag::CodeBlock(_)
                | Tag::List(_)
                | Tag::Table(_)
                | Tag::Emphasis
                | Tag::Strong
                | Tag::Strikethrough,
            )
            | Event::Code(_)
            | Event::Rule
            | Event::HardBreak => {
                formatted = true;
                Some(event)
            }
            Event::SoftBreak if mode == Mode::Reply => Some(Event::HardBreak),
            _ => Some(event),
        }
    });
    let mut output = String::new();
    html::push_html(&mut output, events);
    (output, formatted)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Chart<'a> {
    #[serde(rename = "type")]
    kind: String,
    title: String,
    #[serde(default, deserialize_with = "chart_unit")]
    unit: Option<String>,
    #[serde(borrow)]
    points: Vec<Point<'a>>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Point<'a> {
    label: String,
    #[serde(borrow)]
    value: &'a RawValue,
}

fn chart_label(label: &str, limit: usize) -> bool {
    !label.trim().is_empty()
        && label.encode_utf16().count() <= limit
        && !label.chars().any(char::is_control)
}

// An omitted unit is valid, but JSON null is not a unit label.
fn chart_unit<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Option<String>, D::Error> {
    String::deserialize(deserializer).map(Some)
}

fn read_chart(source: &str) -> Option<Chart<'_>> {
    if source.encode_utf16().count() > 16_384 {
        return None;
    }
    let chart: Chart = serde_json::from_str(source).ok()?;
    let min = match chart.kind.as_str() {
        "bar" => 1,
        "line" => 2,
        _ => return None,
    };
    (chart_label(&chart.title, 120)
        && chart
            .unit
            .as_deref()
            .is_none_or(|label| chart_label(label, 32))
        && (min..=48).contains(&chart.points.len())
        && chart.points.iter().all(|point| {
            chart_label(&point.label, 100)
                && serde_json::from_str::<f64>(point.value.get())
                    .is_ok_and(|value| value.is_finite() && value.abs() <= 1e12)
        }))
    .then_some(chart)
}

fn render_chart(source: &str) -> String {
    let mut output = String::new();
    if let Some(chart) = read_chart(source) {
        output.push_str("<figure class=\"chart-data\"><table><caption>");
        escape_text(&mut output, &chart.title);
        output.push_str("</caption><thead><tr><th scope=\"col\">Label</th><th scope=\"col\">Value");
        if let Some(unit) = chart.unit {
            output.push_str(" (");
            escape_text(&mut output, &unit);
            output.push(')');
        }
        output.push_str("</th></tr></thead><tbody>");
        for point in chart.points {
            output.push_str("<tr><td>");
            escape_text(&mut output, &point.label);
            output.push_str("</td><td>");
            escape_text(&mut output, point.value.get());
            output.push_str("</td></tr>");
        }
        output.push_str("</tbody></table></figure>\n");
    } else {
        output.push_str("<p>This chart couldn’t be rendered. Its source data is below.</p>\n<pre><code class=\"language-chart\">");
        escape_text(&mut output, source);
        output.push_str("</code></pre>\n");
    }
    output
}

fn escape_text(output: &mut String, text: &str) {
    for ch in text.chars() {
        match ch {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            _ => output.push(ch),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_formatting_but_does_not_activate_reply_html_or_external_images() {
        let input = "# Summary\n\n- **Ready**\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n```text\n<script>literal</script>\n```\n\n<img src=x onerror=alert(1)>\n\n[bad](javascript:alert%281%29) ![hidden alt](https://example.test/p.png) [ok](https://example.test/) [private](https://user:pass@example.test/)";
        for result in [page(input), reply(ReplyKey::Direct(1), input).unwrap()] {
            for expected in [
                "<table>",
                "<ul>",
                "<strong>Ready",
                "<h1>Summary",
                "<pre><code",
                "hidden alt",
                "&lt;img",
                "href=\"https://example.test/\"",
            ] {
                assert!(result.contains(expected), "{expected}");
            }
            for forbidden in [
                "<img",
                "<script>",
                "href=\"javascript:",
                "user:pass",
                "p.png",
            ] {
                assert!(!result.contains(forbidden), "{forbidden}");
            }
        }
        assert!(reply(ReplyKey::Direct(1), "plain text\n<em>literal</em>").is_none());
        assert!(reply(ReplyKey::Group(1), "```\ncode\n```").is_some());
    }

    #[test]
    fn checks_only_real_task_markers_and_leaves_other_markdown_intact() {
        let original = "# Café\r\n\r\n```md\r\n- [ ] text only\r\n```\r\n\r\n1. [ ] Review\r\n   - [X] Sign off\r\n";
        let mut source = original.to_owned();
        assert_eq!(check_task(&mut source, 1, false), Some(true));
        assert_eq!(source, original.replace("[X] Sign off", "[ ] Sign off"));
        assert_eq!(check_task(&mut source, 0, true), Some(true));
        assert!(source.contains("1. [x] Review"));
        assert_eq!(check_task(&mut source, 0, true), Some(false));
        assert_eq!(check_task(&mut source, 2, false), None);
        assert_eq!(page(&source).matches("type=\"checkbox\"").count(), 2);
        assert!(
            !reply(ReplyKey::Direct(2), &source)
                .unwrap()
                .contains("type=\"checkbox\"")
        );
    }
}
