use crate::Workspace;
use axum::{Router, http::header, routing::get};

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/appearance.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/appearance.js"),
                )
            }),
        )
        .route(
            "/appearance.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
                    include_str!("../web/appearance.css"),
                )
            }),
        )
}
