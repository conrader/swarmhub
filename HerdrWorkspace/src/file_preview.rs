use crate::ApiError;
use axum::{
    http::header,
    response::{IntoResponse, Response},
};
use serde::Serialize;

const TEXT_LIMIT: usize = 256 * 1024;
const ROW_LIMIT: usize = 50;
const COLUMN_LIMIT: usize = 20;
const CELL_LIMIT: usize = 240;

#[derive(Serialize)]
pub struct Info<'a> {
    pub name: &'a str,
    pub bytes: usize,
    pub preview: Option<&'a str>,
    pub image: Option<Raster>,
    pub table: Option<Table>,
    pub media: Option<Media>,
    pub pdf: bool,
}

#[derive(Serialize)]
pub struct Media {
    kind: &'static str,
    mime: &'static str,
    label: &'static str,
}

#[derive(Serialize)]
pub struct Raster {
    mime: &'static str,
    width: usize,
    height: usize,
}

#[derive(Serialize)]
pub struct Table {
    headers: Vec<String>,
    rows: Vec<Vec<String>>,
    truncated: bool,
}

pub fn info<'a>(name: &'a str, data: &'a [u8]) -> Info<'a> {
    let image = raster(data);
    let media = media(name, data);
    let pdf = data.starts_with(b"%PDF-");
    let text = (data.len() <= TEXT_LIMIT)
        .then(|| std::str::from_utf8(data).ok())
        .flatten()
        .filter(|text| {
            !text
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\r' | '\n' | '\t'))
        });
    let table = if name
        .rsplit_once('.')
        .is_some_and(|(_, ext)| ext.eq_ignore_ascii_case("csv"))
    {
        text.and_then(csv_table)
    } else {
        None
    };
    let preview = if image.is_none() && table.is_none() && media.is_none() && !pdf {
        text
    } else {
        None
    };
    Info {
        name,
        bytes: data.len(),
        preview,
        image,
        table,
        media,
        pdf,
    }
}

fn media(name: &str, data: &[u8]) -> Option<Media> {
    let (_, extension) = name.rsplit_once('.')?;
    let (kind, mime, label) = if extension.eq_ignore_ascii_case("mp4") && is_mp4(data) {
        ("video", "video/mp4", "MP4 video")
    } else if extension.eq_ignore_ascii_case("webm") && is_webm(data) {
        ("video", "video/webm", "WebM video")
    } else if extension.eq_ignore_ascii_case("weba") && is_webm(data) {
        ("audio", "audio/webm", "WebM audio")
    } else if extension.eq_ignore_ascii_case("ogg")
        && data.starts_with(b"OggS")
        && data[..data.len().min(64)]
            .windows(8)
            .any(|id| id == b"OpusHead")
    {
        ("audio", "audio/ogg", "Ogg Opus audio")
    } else if extension.eq_ignore_ascii_case("m4a") && is_mp4(data) {
        ("audio", "audio/mp4", "M4A audio")
    } else if extension.eq_ignore_ascii_case("wav")
        && data.starts_with(b"RIFF")
        && data.get(8..12) == Some(b"WAVE")
    {
        ("audio", "audio/wav", "WAV audio")
    } else {
        return None;
    };
    Some(Media { kind, mime, label })
}

fn is_webm(data: &[u8]) -> bool {
    data.starts_with(b"\x1a\x45\xdf\xa3")
        && data[..data.len().min(64)]
            .windows(7)
            .any(|id| id == b"\x42\x82\x84webm")
}

fn is_mp4(data: &[u8]) -> bool {
    if data.get(4..8) != Some(b"ftyp") {
        return false;
    }
    let Some(size) = data
        .get(..4)
        .and_then(|bytes| bytes.try_into().ok())
        .map(u32::from_be_bytes)
    else {
        return false;
    };
    let Some(brands) = data.get(8..size as usize) else {
        return false;
    };
    let (brands, trailing) = brands.as_chunks::<4>();
    trailing.is_empty()
        && brands.len() >= 2
        && brands
            .iter()
            // The second field is the minor version, not a brand.
            .enumerate()
            .any(|(i, brand)| {
                i != 1
                    && matches!(
                        brand,
                        b"isom" | b"iso2" | b"mp41" | b"mp42" | b"avc1" | b"M4A "
                    )
            })
}

pub fn raster_response(data: Vec<u8>) -> Result<Response, ApiError> {
    let image = raster(&data).ok_or(ApiError::NotFound)?;
    Ok(([(header::CONTENT_TYPE, image.mime)], data).into_response())
}

fn raster(data: &[u8]) -> Option<Raster> {
    let mime = if data.starts_with(b"\x89PNG\r\n\x1a\n") && data.get(12..16) == Some(b"IHDR") {
        "image/png"
    } else if data.starts_with(&[0xff, 0xd8, 0xff]) {
        "image/jpeg"
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        "image/gif"
    } else if data.starts_with(b"RIFF") && data.get(8..12) == Some(b"WEBP") {
        "image/webp"
    } else {
        return None;
    };
    let size = imagesize::blob_size(data).ok()?;
    let (width, height) = (size.width, size.height);
    if !(1..=8192).contains(&width) || !(1..=8192).contains(&height) || width * height > 24_000_000
    {
        return None;
    }
    Some(Raster {
        mime,
        width,
        height,
    })
}

fn csv_table(text: &str) -> Option<Table> {
    let mut reader = csv::ReaderBuilder::new()
        .has_headers(false)
        .flexible(true)
        .from_reader(text.trim_start_matches('\u{feff}').as_bytes());
    let mut records = reader.records();
    let mut truncated = false;
    let mut headers = crop_row(&records.next()?.ok()?, &mut truncated);
    let mut rows = Vec::new();
    for record in records.take(ROW_LIMIT + 1) {
        if rows.len() == ROW_LIMIT {
            truncated = true;
            break;
        }
        rows.push(crop_row(&record.ok()?, &mut truncated));
    }
    let width = rows.iter().map(Vec::len).fold(headers.len(), usize::max);
    headers.resize(width, String::new());
    for row in &mut rows {
        row.resize(width, String::new());
    }
    Some(Table {
        headers,
        rows,
        truncated,
    })
}

fn crop_row(record: &csv::StringRecord, truncated: &mut bool) -> Vec<String> {
    *truncated |= record.len() > COLUMN_LIMIT;
    record
        .iter()
        .take(COLUMN_LIMIT)
        .map(|cell| {
            if let Some((end, _)) = cell.char_indices().nth(CELL_LIMIT) {
                *truncated = true;
                format!("{}…", &cell[..end])
            } else {
                cell.to_owned()
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    #[test]
    fn csv_preserves_quotes_and_newlines_and_reports_clipping() {
        let text = format!(
            "Item,Note\r\n\"A, B\",\"Two\nlines\"\n{}",
            "Long,entry\n".repeat(51)
        );
        let table = super::csv_table(&text).unwrap();
        assert_eq!(table.headers, ["Item", "Note"]);
        assert_eq!(table.rows[0], ["A, B", "Two\nlines"]);
        assert_eq!(table.rows.len(), 50);
        assert!(table.truncated);
    }

    #[test]
    fn treats_active_and_mislabeled_files_as_nondisplayable_images() {
        assert!(
            super::info("fake.png", b"<svg onload=alert(1)>")
                .image
                .is_none()
        );
        assert!(super::raster(b"\x89PNG\r\n\x1a\nnot a usable raster").is_none());
    }
}
