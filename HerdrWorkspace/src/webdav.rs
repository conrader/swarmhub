use crate::{
    ApiError, Workspace,
    core::{Failure, MAX_FILE, valid_filename},
    stage_attachment,
    task_files::Export,
};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::header,
    response::IntoResponse,
    routing::{get, post},
};
use percent_encoding::percent_decode_str;
use reqwest::{Client, Method, Response, StatusCode, Url};
use roxmltree::{Document, Node, ParsingOptions};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    env,
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    time::Duration,
};

const PROPERTIES: &str = r#"<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"#;
const UNREACHABLE: ApiError =
    ApiError::ConnectedFiles("The connected folder could not be reached.");
const UNREADABLE: ApiError =
    ApiError::ConnectedFiles("The WebDAV service returned an unreadable folder listing.");
const LIST_LIMIT: usize = 512 * 1024;
const MAX_ENTRIES: usize = 500;

#[derive(Clone)]
pub struct Folder {
    root: Url,
    client: Client,
    auth: Option<Credential>,
    allow_uploads: bool,
}

#[derive(Clone)]
enum Credential {
    File {
        username: String,
        password: String,
    },
    Vault {
        username: String,
        name: String,
        vault: crate::vault::Vault,
        history: crate::history::History,
    },
}

#[derive(Serialize)]
struct Entry {
    name: String,
    folder: bool,
    bytes: Option<u64>,
}

#[derive(Serialize)]
struct Listing {
    configured: bool,
    uploads: bool,
    path: String,
    entries: Vec<Entry>,
    truncated: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    #[serde(default)]
    path: String,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/connected-files.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/connected-files.js"),
                )
            }),
        )
        .route("/api/connected-files", get(browse))
        .route("/api/connected-files/file", get(read_file))
        .route("/api/connected-files/capabilities", get(capabilities))
        .route("/api/connected-files/export", post(export))
        .route("/api/agents/{id}/{created}/connected-file", post(attach))
}

impl Folder {
    pub fn vault_entry(&self) -> Option<&str> {
        match &self.auth {
            Some(Credential::Vault { name, .. }) => Some(name),
            _ => None,
        }
    }

    pub fn configured(
        history: &crate::history::History,
        vault: Option<&crate::vault::Vault>,
    ) -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let Some(raw) = env::var_os("SWARMHUB_WEBDAV_URL") else {
            return Ok(None);
        };
        let allow_uploads = match env::var("SWARMHUB_WEBDAV_ALLOW_UPLOADS") {
            Ok(value) if value == "1" => true,
            Ok(value) if value == "0" => false,
            Err(env::VarError::NotPresent) => false,
            _ => return Err("Set SWARMHUB_WEBDAV_ALLOW_UPLOADS to 0 or 1.".into()),
        };
        let mut root = raw.to_str().and_then(|url| Url::parse(url).ok()).filter(|url|
            url.scheme()=="https" && url.has_host() && url.username().is_empty() && url.password().is_none()
                && url.query().is_none() && url.fragment().is_none() && url_parts(url).is_some()
        ).ok_or("Set SWARMHUB_WEBDAV_URL to an HTTPS collection URL without credentials, a query, or a fragment.")?;
        if !root.path().ends_with('/') {
            root.path_segments_mut()
                .map_err(|_| "Invalid WebDAV path.")?
                .push("");
        }
        let auth = match (
            env::var("SWARMHUB_WEBDAV_USERNAME"),
            env::var_os("SWARMHUB_WEBDAV_PASSWORD_FILE"),
            env::var_os("SWARMHUB_WEBDAV_VAULT_ENTRY"),
        ) {
            (Err(env::VarError::NotPresent), None, None) => None,
            (Ok(username), None, Some(name)) if valid_username(&username) => {
                let name = name
                    .to_str()
                    .filter(|value| crate::vault::valid_name(value))
                    .ok_or("Set SWARMHUB_WEBDAV_VAULT_ENTRY to a valid vault entry name.")?;
                let vault = vault
                    .cloned()
                    .ok_or("Set SWARMHUB_VAULT_KEY_FILE to use a WebDAV vault entry.")?;
                Some(Credential::Vault {
                    username,
                    name: name.to_owned(),
                    vault,
                    history: history.clone(),
                })
            }
            (Ok(username), Some(path), None) if valid_username(&username) => {
                let file = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                    .open(path)
                    .map_err(|_| "Could not read the WebDAV password file.")?;
                let meta = file
                    .metadata()
                    .map_err(|_| "Could not inspect the WebDAV password file.")?;
                if !meta.is_file() || meta.permissions().mode() & 0o077 != 0 {
                    return Err(
                        "Use a private regular file for the WebDAV password (mode 0600).".into(),
                    );
                }
                let mut password = String::new();
                file.take(4097)
                    .read_to_string(&mut password)
                    .map_err(|_| "Invalid WebDAV password file.")?;
                let password = password.trim_end_matches(['\n', '\r']);
                if password.is_empty()
                    || password.len() > 4096
                    || password.chars().any(char::is_control)
                {
                    return Err("Invalid WebDAV password file.".into());
                }
                Some(Credential::File {
                    username,
                    password: password.to_owned(),
                })
            }
            _ => {
                return Err(
                    "Set a WebDAV username with either a password file or a vault entry.".into(),
                );
            }
        };
        let mut client = Client::builder()
            .https_only(true)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(20));
        if let Some(path) = env::var_os("SWARMHUB_WEBDAV_CA_FILE") {
            let file =
                std::fs::File::open(path).map_err(|_| "Could not read the WebDAV CA file.")?;
            let mut pem = Vec::new();
            file.take(128 * 1024 + 1)
                .read_to_end(&mut pem)
                .map_err(|_| "Could not read the WebDAV CA file.")?;
            if pem.len() > 128 * 1024 {
                return Err("The WebDAV CA file is too large.".into());
            }
            let certificates = reqwest::Certificate::from_pem_bundle(&pem)
                .map_err(|_| "Invalid WebDAV CA certificate.")?;
            if certificates.is_empty() {
                return Err("The WebDAV CA file contains no certificates.".into());
            }
            for cert in certificates {
                client = client.add_root_certificate(cert);
            }
        }
        let client = client.build().map_err(|error| {
            format!(
                "Could not start the WebDAV client: {:?}",
                error.without_url()
            )
        })?;
        Ok(Some(Self {
            root,
            client,
            auth,
            allow_uploads,
        }))
    }

    fn url(&self, path: &[&str], folder: bool) -> Result<Url, ApiError> {
        let mut url = self.root.clone();
        let mut segments = url.path_segments_mut().map_err(|_| UNREACHABLE)?;
        segments.pop_if_empty().extend(path.iter().copied());
        if folder {
            segments.push("");
        }
        drop(segments);
        Ok(url)
    }

    fn request(&self, method: Method, url: Url) -> Result<reqwest::RequestBuilder, ApiError> {
        let request = self
            .client
            .request(method, url)
            .header(header::ACCEPT_ENCODING, "identity");
        match &self.auth {
            Some(Credential::File { username, password }) => {
                Ok(request.basic_auth(username, Some(password)))
            }
            Some(Credential::Vault {
                username,
                name,
                vault,
                history,
            }) => {
                let password = vault
                    .lookup(history, name)
                    .map_err(|_| {
                        ApiError::ConnectedFiles("The vault could not open the saved credential.")
                    })?
                    .ok_or(ApiError::ConnectedFiles(
                        "Add the configured WebDAV credential to the vault.",
                    ))?;
                Ok(request.basic_auth(username, Some(password)))
            }
            None => Ok(request),
        }
    }

    async fn list(&self, path: String) -> Result<Listing, ApiError> {
        let url = self.url(&parts(&path)?, true)?;
        let method = Method::from_bytes(b"PROPFIND").expect("valid WebDAV method");
        let response = self
            .request(method, url.clone())?
            .header("Depth", "1")
            .header(header::CONTENT_TYPE, "application/xml")
            .body(PROPERTIES)
            .send()
            .await
            .map_err(|_| UNREACHABLE)?;
        if response.status() != StatusCode::MULTI_STATUS {
            return Err(service_error(response.status()));
        }
        let body = bounded(
            response,
            LIST_LIMIT,
            ApiError::ConnectedFiles(
                "This WebDAV folder listing is too large. Choose a smaller collection.",
            ),
        )
        .await?;
        let (entries, truncated) = listing(&url, &body)?;
        Ok(Listing {
            configured: true,
            uploads: self.allow_uploads,
            path,
            entries,
            truncated,
        })
    }

    async fn read(&self, path: &[&str]) -> Result<Vec<u8>, ApiError> {
        let url = self.url(path, false)?;
        let response = self
            .request(Method::GET, url)?
            .send()
            .await
            .map_err(|_| UNREACHABLE)?;
        if response.status() != StatusCode::OK {
            return Err(service_error(response.status()));
        }
        bounded(
            response,
            MAX_FILE,
            Failure::Input("Connect a file up to 8 MiB.").into(),
        )
        .await
    }

    async fn create_file(&self, path: &[&str], data: Vec<u8>) -> Result<(), ApiError> {
        let url = self.url(path, false)?;
        let response = self
            .request(Method::PUT, url)?
            .header(header::IF_NONE_MATCH, "*")
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .body(data)
            .send()
            .await
            .map_err(|_| {
                ApiError::ConnectedFiles(
                    "WebDAV did not confirm the save. Check the destination before retrying.",
                )
            })?;
        match response.status() {
            StatusCode::CREATED => Ok(()),
            StatusCode::PRECONDITION_FAILED => Err(ApiError::Conflict(
                "A file with that name already exists. Choose a different name.",
            )),
            StatusCode::CONFLICT => Err(ApiError::Conflict(
                "The destination folder is not available. Choose another folder.",
            )),
            status if status.is_success() => Err(ApiError::ConnectedFiles(
                "WebDAV did not confirm that a new file was created. Check the destination before retrying.",
            )),
            status => Err(service_error(status)),
        }
    }
}

fn valid_username(username: &str) -> bool {
    !username.is_empty()
        && username.len() <= 240
        && !username.chars().any(|c| c == ':' || c.is_control())
}

fn service_error(status: StatusCode) -> ApiError {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => {
            ApiError::ConnectedFiles("The WebDAV account cannot access this folder or file.")
        }
        StatusCode::NOT_FOUND => {
            ApiError::ConnectedFiles("This file or folder is no longer available on WebDAV.")
        }
        _ if status.is_redirection() => ApiError::ConnectedFiles(
            "WebDAV redirected this request. Configure its final HTTPS collection URL.",
        ),
        _ => ApiError::ConnectedFiles("The WebDAV service could not complete this request."),
    }
}

async fn bounded(
    mut response: Response,
    limit: usize,
    large: ApiError,
) -> Result<Vec<u8>, ApiError> {
    if response
        .headers()
        .get(header::CONTENT_ENCODING)
        .is_some_and(|value| !value.as_bytes().eq_ignore_ascii_case(b"identity"))
    {
        return Err(ApiError::ConnectedFiles(
            "The WebDAV service used an unexpected content encoding.",
        ));
    }
    if response
        .content_length()
        .is_some_and(|size| size > limit as u64)
    {
        return Err(large);
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| UNREACHABLE)? {
        if chunk.len() > limit - body.len() {
            return Err(large);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn parts(path: &str) -> Result<Vec<&str>, ApiError> {
    let names: Vec<_> = if path.is_empty() {
        vec![]
    } else {
        path.split('/').collect()
    };
    if path.len() > 4096 || names.len() > 32 || names.iter().any(|name| !valid_filename(name)) {
        return Err(Failure::Input("Choose a path inside the connected folder.").into());
    }
    Ok(names)
}

fn url_parts(url: &Url) -> Option<Vec<String>> {
    if url.path() == "/" {
        return Some(vec![]);
    }
    url.path()
        .strip_prefix('/')?
        .strip_suffix('/')
        .unwrap_or(&url.path()[1..])
        .split('/')
        .map(|part| {
            percent_decode_str(part)
                .decode_utf8()
                .ok()
                .filter(|name| valid_filename(name))
                .map(|name| name.into_owned())
        })
        .collect()
}

fn child<'a, 'input>(node: Node<'a, 'input>, name: &str) -> Option<Node<'a, 'input>> {
    node.children()
        .find(|child| child.has_tag_name(("DAV:", name)))
}

fn successful(status: Node<'_, '_>) -> bool {
    status
        .text()
        .and_then(|text| text.split_ascii_whitespace().nth(1))
        .and_then(|status| status.parse::<u16>().ok())
        .is_some_and(|status| (200..300).contains(&status))
}

fn listing(folder: &Url, bytes: &[u8]) -> Result<(Vec<Entry>, bool), ApiError> {
    let xml = std::str::from_utf8(bytes).map_err(|_| UNREADABLE)?;
    let tree = Document::parse_with_options(
        xml,
        ParsingOptions {
            nodes_limit: 24_000,
            ..ParsingOptions::default()
        },
    )
    .map_err(|_| UNREADABLE)?;
    let root = tree.root_element();
    if !root.has_tag_name(("DAV:", "multistatus")) {
        return Err(UNREADABLE);
    }
    let prefix = url_parts(folder).ok_or(UNREADABLE)?;
    let mut entries = Vec::new();
    let mut seen = HashSet::new();
    for response in root
        .children()
        .filter(|node| node.has_tag_name(("DAV:", "response")))
    {
        if child(response, "status").is_some_and(|status| !successful(status)) {
            continue;
        }
        let Some(href) = child(response, "href")
            .and_then(|node| node.text())
            .map(str::trim)
        else {
            continue;
        };
        let addressed = if href.starts_with('/') && !href.starts_with("//") {
            folder.join(href)
        } else {
            Url::parse(href)
        };
        let Ok(addressed) = addressed else { continue };
        if addressed.origin() != folder.origin()
            || !addressed.username().is_empty()
            || addressed.password().is_some()
            || addressed.query().is_some()
            || addressed.fragment().is_some()
        {
            continue;
        }
        let Some(names) = url_parts(&addressed) else {
            continue;
        };
        let Some([name]) = names.strip_prefix(prefix.as_slice()) else {
            continue;
        };
        let mut collection = None;
        let mut size = None;
        for stat in response
            .children()
            .filter(|node| node.has_tag_name(("DAV:", "propstat")))
        {
            if !child(stat, "status").is_some_and(successful) {
                continue;
            }
            let Some(prop) = child(stat, "prop") else {
                continue;
            };
            if let Some(kind) = child(prop, "resourcetype") {
                collection = Some(child(kind, "collection").is_some());
            }
            if let Some(value) = child(prop, "getcontentlength").and_then(|node| node.text()) {
                size = value.trim().parse().ok();
            }
        }
        if let Some(folder) = collection
            && seen.insert(name.clone())
        {
            entries.push(Entry {
                name: name.clone(),
                folder,
                bytes: if folder { None } else { size },
            });
        }
    }
    entries.sort_by(|a, b| b.folder.cmp(&a.folder).then_with(|| a.name.cmp(&b.name)));
    let truncated = entries.len() > MAX_ENTRIES;
    entries.truncate(MAX_ENTRIES);
    Ok((entries, truncated))
}

async fn browse(
    State(w): State<Workspace>,
    Query(selection): Query<Selection>,
) -> Result<Json<Listing>, ApiError> {
    match w.connected_files {
        Some(connection) => Ok(Json(connection.list(selection.path).await?)),
        None => Ok(Json(Listing {
            configured: false,
            uploads: false,
            path: String::new(),
            entries: vec![],
            truncated: false,
        })),
    }
}

async fn capabilities(State(w): State<Workspace>) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "configured":w.connected_files.is_some(),
        "uploads":w.connected_files.as_ref().is_some_and(|connection| connection.allow_uploads),
    }))
}

async fn export(
    State(w): State<Workspace>,
    Json(body): Json<Export>,
) -> Result<impl IntoResponse, ApiError> {
    let connection = w
        .connected_files
        .as_ref()
        .filter(|connection| connection.allow_uploads)
        .ok_or(Failure::Input(
            "Saving to the connected folder is disabled for this workspace.",
        ))?;
    if !valid_filename(&body.name) {
        return Err(
            Failure::Input("Use a filename up to 180 bytes without path separators.").into(),
        );
    }
    let contents = body.data(&w.history)?;
    let relative = if body.folder.is_empty() {
        body.name
    } else {
        format!("{}/{}", body.folder, body.name)
    };
    let destination = parts(&relative)?;
    let bytes = contents.len();
    connection.create_file(&destination, contents).await?;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({"path":relative,"bytes":bytes})),
    ))
}

async fn read_file(
    State(w): State<Workspace>,
    Query(selection): Query<Selection>,
) -> Result<impl IntoResponse, ApiError> {
    let connection = w
        .connected_files
        .as_ref()
        .ok_or(Failure::Input("No connected folder is configured."))?;
    let path = parts(&selection.path)?;
    let name = path
        .last()
        .ok_or(Failure::Input("Choose a file to attach."))?;
    let data = connection.read(&path).await?;
    Ok(crate::file_download_response(name, data))
}

async fn attach(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    Json(selection): Json<Selection>,
) -> Result<impl IntoResponse, ApiError> {
    let connection = w
        .connected_files
        .as_ref()
        .ok_or(Failure::Input("No connected folder is configured."))?;
    let path = parts(&selection.path)?;
    let name = path
        .last()
        .ok_or(Failure::Input("Choose a file to attach."))?
        .to_string();
    let hello = w.core.identify().await?;
    if !hello.supports("terminal.put") {
        return Err(Failure::Input("This Herdr Core does not support file staging.").into());
    }
    w.core.agent(&id, created).await?.require_live()?;
    let data = connection.read(&path).await?;
    if w.core.identify().await?.core.id != hello.core.id {
        return Err(Failure::Input("Herdr Core changed before the file could be attached.").into());
    }
    let terminal = w.core.agent(&id, created).await?;
    stage_attachment(w, terminal, hello.core.id, name, data.into()).await
}
