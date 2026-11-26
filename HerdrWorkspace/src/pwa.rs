use crate::Workspace;
use axum::{Router, http::header, response::IntoResponse, routing::get};

fn asset(content_type: &'static str, bytes: &'static [u8]) -> impl IntoResponse {
    ([(header::CONTENT_TYPE, content_type)], bytes)
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/workspace.webmanifest",
            get(|| async {
                asset(
                    "application/manifest+json",
                    include_bytes!("../web/pwa/workspace.webmanifest"),
                )
            }),
        )
        .route(
            "/pwa-install.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_bytes!("../web/pwa/install.js"),
                )
            }),
        )
        .route(
            "/ci-push.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_bytes!("../web/pwa/ci-push.js"),
                )
            }),
        )
        .route(
            "/workspace-sw.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_bytes!("../web/pwa/worker.js"),
                )
            }),
        )
        .route(
            "/pwa/icon-180.png",
            get(|| async { asset("image/png", include_bytes!("../web/pwa/icon-180.png")) }),
        )
        .route(
            "/pwa/icon-192.png",
            get(|| async { asset("image/png", include_bytes!("../web/pwa/icon-192.png")) }),
        )
        .route(
            "/pwa/icon-512.png",
            get(|| async { asset("image/png", include_bytes!("../web/pwa/icon-512.png")) }),
        )
}
