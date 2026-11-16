use crate::{ApiError, Workspace, core::Failure, history::StoreError};
use axum::{
    extract::{Path, State},
    http::header,
    response::{IntoResponse, Response},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use rusqlite::{OptionalExtension, params};
use std::io::Cursor;

const PIXELS: u32 = 160;
const MAX_PNG: usize = 110 * 1024;
pub const EDIT_BODY_LIMIT: usize = 200 * 1024;
const INVALID: Failure = Failure::Input("Choose a readable image and crop it before saving.");

pub fn normalize(encoded: &str) -> Result<Vec<u8>, Failure> {
    if encoded.len() > MAX_PNG.div_ceil(3) * 4 {
        return Err(INVALID);
    }
    let input = STANDARD.decode(encoded).map_err(|_| INVALID)?;
    if input.len() > MAX_PNG {
        return Err(INVALID);
    }
    let mut decoder =
        png::Decoder::new_with_limits(Cursor::new(&input), png::Limits { bytes: 512 * 1024 });
    decoder.set_ignore_text_chunk(true);
    decoder.set_ignore_iccp_chunk(true);
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let info = decoder.read_header_info().map_err(|_| INVALID)?;
    if (info.width, info.height) != (PIXELS, PIXELS) {
        return Err(INVALID);
    }
    let mut reader = decoder.read_info().map_err(|_| INVALID)?;
    if reader.info().animation_control.is_some() {
        return Err(INVALID);
    }
    let mut pixels = vec![0; (PIXELS * PIXELS * 4) as usize];
    let image = reader.next_frame(&mut pixels).map_err(|_| INVALID)?;
    // Write a clean still image with only the decoded pixels.
    let mut clean = Vec::new();
    let mut encoder = png::Encoder::new(&mut clean, PIXELS, PIXELS);
    encoder.set_color(image.color_type);
    encoder.set_depth(image.bit_depth);
    let mut writer = encoder.write_header().map_err(|_| INVALID)?;
    writer
        .write_image_data(&pixels[..image.buffer_size()])
        .map_err(|_| INVALID)?;
    writer.finish().map_err(|_| INVALID)?;
    Ok(clean)
}

pub async fn get(
    State(w): State<Workspace>,
    Path((id, key)): Path<(i64, String)>,
) -> Result<Response, ApiError> {
    if key.len() != 32 || !key.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(ApiError::NotFound);
    }
    let data: Vec<u8> = w
        .history
        .db()?
        .query_row(
            "SELECT a.png FROM profile_avatars a JOIN profiles p ON p.id=a.profile
         WHERE p.id=?1 AND p.avatar_key=?2 AND p.avatar='image'",
            params![id, key],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    Ok(([(header::CONTENT_TYPE, "image/png")], data).into_response())
}
