use axum::{
    Router,
    extract::Path,
    http::{StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};

const ASSETS: &[(&str, &str, &[u8])] = include!(concat!(env!("OUT_DIR"), "/pdf-assets.rs"));

pub fn routes() -> Router<crate::Workspace> {
    Router::new()
        .route(
            "/pdf-preview.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/pdf-preview.js"),
                )
            }),
        )
        .route("/vendor/pdfjs/{*asset}", get(serve))
}

async fn serve(Path(asset): Path<String>) -> Response {
    match ASSETS.binary_search_by_key(&asset.as_str(), |(path, _, _)| path) {
        Ok(index) => {
            let (_, mime, contents) = ASSETS[index];
            ([(header::CONTENT_TYPE, mime)], contents).into_response()
        }
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}
