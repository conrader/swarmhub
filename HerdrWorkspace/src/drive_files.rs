use crate::{
    ApiError, Workspace,
    core::{Failure, MAX_FILE, valid_filename},
    drive_oauth::Setup,
    file_download_response,
    history::History,
    task_files::Export,
    vault::Vault,
};
use axum::{
    Json, Router,
    extract::{Query, State},
    response::IntoResponse,
    routing::{get, post},
};
use reqwest::{Client, Response, StatusCode, Url, header};
use ring::digest::{Digest, SHA256, digest};
use serde::{Deserialize, Serialize};
use std::{
    env,
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::Mutex;

const MIME_FOLDER: &str = "application/vnd.google-apps.folder";
const MIME_SHORTCUT: &str = "application/vnd.google-apps.shortcut";
const FIELDS: &str =
    "id,name,mimeType,parents,trashed,size,capabilities(canDownload,canAddChildren)";
const UNREACHABLE: ApiError = ApiError::ConnectedFiles("Google Drive could not be reached.");
const UNREADABLE: ApiError =
    ApiError::ConnectedFiles("Google Drive returned an unreadable response.");
const CREDENTIALS: ApiError =
    ApiError::ConnectedFiles("Google Drive authorization failed. Check the workspace connection.");
const UNCONFIRMED: ApiError = ApiError::ConnectedFiles(
    "Google Drive did not confirm the saved copy. Check the destination before retrying.",
);

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Credentials {
    folder_id: String,
    client_id: String,
    client_secret: String,
    refresh_token: Option<String>,
    #[serde(default)]
    browser_oauth: bool,
    #[serde(default)]
    allow_uploads: bool,
}

#[derive(Deserialize)]
struct OAuth {
    access_token: String,
    expires_in: u64,
}

#[derive(Deserialize)]
struct Grant {
    access_token: String,
    refresh_token: String,
}

struct Token {
    value: String,
    expires: Instant,
    refresh: Digest,
}

#[derive(Clone)]
pub struct Drive(Arc<Connection>);

struct Connection {
    config: Credentials,
    client: Client,
    oauth: Url,
    files: Url,
    upload: Url,
    setup: Option<Setup>,
    token: Mutex<Option<Token>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GoogleFile {
    id: String,
    name: String,
    mime_type: String,
    #[serde(default)]
    parents: Vec<String>,
    #[serde(default)]
    trashed: bool,
    size: Option<String>,
    capabilities: Option<Capabilities>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Capabilities {
    #[serde(default)]
    can_download: bool,
    #[serde(default)]
    can_add_children: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Results {
    files: Vec<GoogleFile>,
    next_page_token: Option<String>,
    #[serde(default)]
    incomplete_search: bool,
}

#[derive(Serialize)]
struct Entry {
    id: String,
    name: String,
    folder: bool,
    bytes: Option<u64>,
    attachable: bool,
}

#[derive(Serialize)]
struct Listing {
    configured: bool,
    path: String,
    label: String,
    entries: Vec<Entry>,
    truncated: bool,
    uploads: bool,
}

#[derive(Deserialize)]
struct CreatedFile {
    id: String,
    name: String,
    parents: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Selection {
    #[serde(default)]
    path: String,
}

impl Drive {
    pub fn configured(
        history: &History,
        vault: Option<&Vault>,
        port: u16,
    ) -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let Some(path) = env::var_os("SWARMHUB_DRIVE_CREDENTIALS_FILE") else {
            return Ok(None);
        };
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
            .map_err(|_| "Could not open the Google Drive credentials file.")?;
        let meta = file.metadata()?;
        if !meta.is_file() || meta.permissions().mode() & 0o077 != 0 {
            return Err("Use an owner-only regular file for Google Drive credentials.".into());
        }
        let mut data = Vec::new();
        file.take(16_385).read_to_end(&mut data)?;
        let config: Credentials =
            serde_json::from_slice(&data).map_err(|_| "Invalid Google Drive credentials file.")?;
        if data.len() > 16_384
            || !valid_id(&config.folder_id)
            || !valid_credential(&config.client_id)
            || !valid_credential(&config.client_secret)
            || config.browser_oauth == config.refresh_token.is_some()
            || config
                .refresh_token
                .as_deref()
                .is_some_and(|token| !valid_credential(token))
        {
            return Err("Invalid Google Drive credentials file.".into());
        }
        let client = Client::builder()
            .https_only(true)
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(20))
            .build()?;
        let setup = if config.browser_oauth {
            Some(Setup::new(
                vault.cloned().ok_or(
                    "Configure the SwarmHub Vault key before enabling Google Drive browser setup.",
                )?,
                history.clone(),
                port,
                &config.client_id,
                &config.folder_id,
                config.allow_uploads,
            ))
        } else {
            None
        };
        Ok(Some(Self(Arc::new(Connection {
            config,
            client,
            oauth: Url::parse("https://oauth2.googleapis.com/token")?,
            files: Url::parse("https://www.googleapis.com/drive/v3/files")?,
            upload: Url::parse("https://www.googleapis.com/upload/drive/v3/files")?,
            setup,
            token: Mutex::new(None),
        }))))
    }

    fn uploads(&self) -> bool {
        self.0.config.allow_uploads
    }

    pub fn vault_entry(&self) -> Option<&str> {
        self.0.setup.as_ref().map(Setup::name)
    }

    fn refresh_secret(&self) -> Result<Option<String>, ApiError> {
        match &self.0.setup {
            Some(setup) => setup.secret(),
            None => Ok(self.0.config.refresh_token.clone()),
        }
    }

    pub fn connected(&self) -> bool {
        self.refresh_secret().ok().flatten().is_some()
    }

    pub(crate) fn access_identity(&self) -> Option<[u8; 32]> {
        let secret = self.refresh_secret().ok().flatten()?;
        digest(&SHA256, secret.as_bytes()).as_ref().try_into().ok()
    }

    pub(crate) async fn agent_list(&self, path: String) -> Result<Vec<u8>, ApiError> {
        let row = self.list(path).await?;
        serde_json::to_vec(&serde_json::json!({
            "path":row.path,"label":row.label,"entries":row.entries,"truncated":row.truncated
        }))
        .map_err(|_| UNREADABLE)
    }

    pub fn begin_oauth(&self) -> Result<Url, ApiError> {
        let setup = self.0.setup.as_ref().ok_or(Failure::Input(
            "Browser setup for Google Drive is not configured.",
        ))?;
        setup.begin(&self.0.config.client_id, self.uploads())
    }

    pub async fn disconnect_oauth(&self) -> Result<(), ApiError> {
        let setup = self.0.setup.as_ref().ok_or(Failure::Input(
            "Browser setup for Google Drive is not configured.",
        ))?;
        setup.disconnect()?;
        *self.0.token.lock().await = None;
        Ok(())
    }

    pub async fn complete_oauth(&self, state: &str, code: Option<String>) -> Result<(), ApiError> {
        let setup = self.0.setup.as_ref().ok_or(CREDENTIALS)?;
        let (verifier, generation) = setup.take(state)?.ok_or(CREDENTIALS)?;
        let code = code
            .filter(|value| valid_credential(value))
            .ok_or(CREDENTIALS)?;
        let config = &self.0.config;
        let form = [
            ("client_id", config.client_id.as_str()),
            ("client_secret", config.client_secret.as_str()),
            ("redirect_uri", setup.redirect()),
            ("code_verifier", &verifier),
            ("code", &code),
            ("grant_type", "authorization_code"),
        ];
        let response = self
            .0
            .client
            .post(self.0.oauth.clone())
            .form(&form)
            .send()
            .await
            .map_err(|_| UNREACHABLE)?;
        if !response.status().is_success() {
            return Err(CREDENTIALS);
        }
        let grant: Grant =
            serde_json::from_slice(&bounded(response, 16_384).await?).map_err(|_| UNREADABLE)?;
        if !valid_credential(&grant.access_token) || !valid_credential(&grant.refresh_token) {
            return Err(UNREADABLE);
        }
        let mut url = self.file_url(&config.folder_id)?;
        url.query_pairs_mut()
            .append_pair("fields", FIELDS)
            .append_pair("supportsAllDrives", "true");
        let response = self
            .0
            .client
            .get(url)
            .bearer_auth(&grant.access_token)
            .send()
            .await
            .map_err(|_| UNREACHABLE)?;
        if response.status() != StatusCode::OK {
            return Err(CREDENTIALS);
        }
        let root: GoogleFile =
            serde_json::from_slice(&bounded(response, 65_536).await?).map_err(|_| UNREADABLE)?;
        if root.trashed || root.mime_type != MIME_FOLDER || !valid_id(&root.id) {
            return Err(CREDENTIALS);
        }
        setup.save(generation, grant.refresh_token)?;
        *self.0.token.lock().await = None;
        Ok(())
    }

    async fn token(&self) -> Result<String, ApiError> {
        let mut cached = self.0.token.lock().await;
        let refresh = self.refresh_secret()?.ok_or(ApiError::Conflict(
            "Connect Google Drive before opening its files.",
        ))?;
        let fingerprint = digest(&SHA256, refresh.as_bytes());
        if let Some(token) = cached.as_ref().filter(|token| {
            token.expires > Instant::now() && token.refresh.as_ref() == fingerprint.as_ref()
        }) {
            return Ok(token.value.clone());
        }
        let config = &self.0.config;
        let form = [
            ("client_id", config.client_id.as_str()),
            ("client_secret", &config.client_secret),
            ("refresh_token", &refresh),
            ("grant_type", "refresh_token"),
        ];
        let response = self
            .0
            .client
            .post(self.0.oauth.clone())
            .form(&form)
            .send()
            .await
            .map_err(|_| UNREACHABLE)?;
        if !response.status().is_success() {
            return Err(CREDENTIALS);
        }
        let token: OAuth =
            serde_json::from_slice(&bounded(response, 16_384).await?).map_err(|_| UNREADABLE)?;
        if token.access_token.is_empty()
            || token.access_token.len() > 4096
            || !token.access_token.bytes().all(|b| b.is_ascii_graphic())
        {
            return Err(UNREADABLE);
        }
        *cached = Some(Token {
            value: token.access_token.clone(),
            refresh: fingerprint,
            expires: Instant::now()
                + Duration::from_secs(token.expires_in.saturating_sub(60).min(3600)),
        });
        Ok(token.access_token)
    }

    async fn get(&self, url: Url) -> Result<Response, ApiError> {
        for attempt in 0..=1 {
            let token = self.token().await?;
            let response = self
                .0
                .client
                .get(url.clone())
                .bearer_auth(&token)
                .header(header::ACCEPT_ENCODING, "identity")
                .send()
                .await
                .map_err(|_| UNREACHABLE)?;
            match response.status() {
                StatusCode::OK => return Ok(response),
                StatusCode::UNAUTHORIZED if attempt == 0 => {
                    let mut cached = self.0.token.lock().await;
                    if cached.as_ref().is_some_and(|saved| saved.value == token) {
                        *cached = None;
                    }
                }
                StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => return Err(CREDENTIALS),
                StatusCode::NOT_FOUND => return Err(ApiError::NotFound),
                _ => return Err(UNREACHABLE),
            }
        }
        Err(CREDENTIALS)
    }

    fn file_url(&self, id: &str) -> Result<Url, ApiError> {
        let mut url = self.0.files.clone();
        url.path_segments_mut().map_err(|_| UNREADABLE)?.push(id);
        Ok(url)
    }

    async fn metadata(&self, id: &str) -> Result<GoogleFile, ApiError> {
        let mut url = self.file_url(id)?;
        url.query_pairs_mut()
            .append_pair("fields", FIELDS)
            .append_pair("supportsAllDrives", "true");
        let response = self.get(url).await?;
        let item: GoogleFile =
            serde_json::from_slice(&bounded(response, 65_536).await?).map_err(|_| UNREADABLE)?;
        if item.trashed || item.mime_type == MIME_SHORTCUT || !valid_id(&item.id) {
            return Err(ApiError::NotFound);
        }
        Ok(item)
    }

    async fn target(&self, path: &[&str]) -> Result<(GoogleFile, Vec<String>), ApiError> {
        let mut item = self.metadata(&self.0.config.folder_id).await?;
        if item.mime_type != MIME_FOLDER {
            return Err(
                Failure::Input("Choose a Google Drive folder as the connection root.").into(),
            );
        }
        let mut breadcrumbs = vec![item.name.clone()];
        for id in path {
            if item.mime_type != MIME_FOLDER {
                return Err(ApiError::NotFound);
            }
            let child = self.metadata(id).await?;
            if child.id != *id || !child.parents.contains(&item.id) {
                return Err(ApiError::NotFound);
            }
            breadcrumbs.push(child.name.clone());
            item = child;
        }
        Ok((item, breadcrumbs))
    }

    async fn list(&self, path: String) -> Result<Listing, ApiError> {
        let (folder, labels) = self.target(&segments(&path)?).await?;
        if folder.mime_type != MIME_FOLDER {
            return Err(ApiError::NotFound);
        }
        let mut url = self.0.files.clone();
        url.query_pairs_mut()
            .append_pair(
                "q",
                &format!("'{}' in parents and trashed = false", folder.id),
            )
            .append_pair(
                "fields",
                &format!("nextPageToken,incompleteSearch,files({FIELDS})"),
            )
            .append_pair("orderBy", "folder,name_natural")
            .append_pair("pageSize", "100")
            .append_pair("supportsAllDrives", "true")
            .append_pair("includeItemsFromAllDrives", "true");
        let mut entries = Vec::new();
        let mut token: Option<String> = None;
        let mut truncated = false;
        for _ in 0..5 {
            let mut page = url.clone();
            if let Some(token) = token.as_deref() {
                page.query_pairs_mut().append_pair("pageToken", token);
            }
            let result: Results =
                serde_json::from_slice(&bounded(self.get(page).await?, 256 * 1024).await?)
                    .map_err(|_| UNREADABLE)?;
            entries.extend(
                result
                    .files
                    .into_iter()
                    .filter(|f| {
                        valid_id(&f.id)
                            && !f.trashed
                            && f.mime_type != MIME_SHORTCUT
                            && f.parents.contains(&folder.id)
                    })
                    .take(500 - entries.len())
                    .map(|f| {
                        let folder = f.mime_type == MIME_FOLDER;
                        let attachable = f.attachable();
                        Entry {
                            id: f.id,
                            name: f.name,
                            folder,
                            bytes: f.size.as_deref().and_then(|size| size.parse().ok()),
                            attachable,
                        }
                    }),
            );
            truncated |= result.incomplete_search;
            token = result.next_page_token;
            if token.is_none() || entries.len() == 500 {
                break;
            }
        }
        Ok(Listing {
            configured: true,
            path,
            label: labels.join(" / "),
            entries,
            truncated: token.is_some() || truncated,
            uploads: self.uploads() && folder.can_add_files(),
        })
    }

    pub(crate) async fn read(&self, path: &str) -> Result<(String, Vec<u8>), ApiError> {
        let segments = segments(path)?;
        if segments.is_empty() {
            return Err(Failure::Input("Choose a Google Drive file to attach.").into());
        }
        let (file, _) = self.target(&segments).await?;
        if !file.attachable() {
            return Err(Failure::Input("This Google Drive file cannot be attached.").into());
        }
        if file
            .size
            .as_ref()
            .and_then(|size| size.parse::<u64>().ok())
            .is_some_and(|size| size > MAX_FILE as u64)
        {
            return Err(ApiError::PayloadTooLarge(
                "This Google Drive file exceeds 8 MiB.",
            ));
        }
        let mut url = self.file_url(&file.id)?;
        let mut name = safe_name(&file.name);
        if let Some((mime, suffix)) = export_format(&file.mime_type) {
            url.path_segments_mut()
                .map_err(|_| UNREADABLE)?
                .push("export");
            url.query_pairs_mut().append_pair("mimeType", mime);
            if !name.to_ascii_lowercase().ends_with(suffix) {
                name.push_str(suffix);
            }
        } else {
            url.query_pairs_mut()
                .append_pair("alt", "media")
                .append_pair("supportsAllDrives", "true");
        }
        Ok((name, bounded(self.get(url).await?, MAX_FILE).await?))
    }

    async fn save(
        &self,
        path: &str,
        name: &str,
        data: Vec<u8>,
    ) -> Result<(String, String), ApiError> {
        if !self.uploads() {
            return Err(
                Failure::Input("Saving to Google Drive is disabled for this workspace.").into(),
            );
        }
        let (folder, breadcrumbs) = self.target(&segments(path)?).await?;
        if !folder.can_add_files() {
            return Err(Failure::Input("Choose a writable Google Drive folder.").into());
        }
        let token = self.token().await?;
        let mut url = self.0.upload.clone();
        url.query_pairs_mut()
            .append_pair("uploadType", "resumable")
            .append_pair("supportsAllDrives", "true")
            .append_pair("fields", "id,name,parents");
        let size = data.len();
        let body = serde_json::json!({"name":name,"parents":[folder.id]}).to_string();
        let response = self
            .0
            .client
            .post(url.clone())
            .bearer_auth(&token)
            .header(header::CONTENT_TYPE, "application/json; charset=utf-8")
            .header("X-Upload-Content-Type", "application/octet-stream")
            .header("X-Upload-Content-Length", size.to_string())
            .body(body)
            .send()
            .await
            .map_err(|_| UNREACHABLE)?;
        match response.status() {
            StatusCode::OK | StatusCode::CREATED => {}
            StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => return Err(CREDENTIALS),
            StatusCode::NOT_FOUND => return Err(ApiError::NotFound),
            _ => return Err(UNREACHABLE),
        }
        let location = response
            .headers()
            .get(header::LOCATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| url.join(value).ok())
            .filter(|location| is_upload_session(&self.0.upload, location))
            .ok_or(UNREADABLE)?;
        let response = self
            .0
            .client
            .put(location)
            .bearer_auth(&token)
            .header(header::CONTENT_TYPE, "application/octet-stream")
            .body(data)
            .send()
            .await
            .map_err(|_| UNCONFIRMED)?;
        if !matches!(response.status(), StatusCode::OK | StatusCode::CREATED) {
            return Err(UNCONFIRMED);
        }
        let result: CreatedFile =
            serde_json::from_slice(&bounded(response, 65_536).await.map_err(|_| UNCONFIRMED)?)
                .map_err(|_| UNCONFIRMED)?;
        if !valid_id(&result.id) || result.name != name || !result.parents.contains(&folder.id) {
            return Err(UNCONFIRMED);
        }
        Ok((
            format!("Google Drive / {} / {name}", breadcrumbs.join(" / ")),
            result.id,
        ))
    }
}

fn valid_credential(value: &str) -> bool {
    !value.is_empty() && value.len() <= 4096 && value.bytes().all(|b| b.is_ascii_graphic())
}

impl GoogleFile {
    fn can_add_files(&self) -> bool {
        self.mime_type == MIME_FOLDER
            && self
                .capabilities
                .as_ref()
                .is_some_and(|caps| caps.can_add_children)
    }
    fn attachable(&self) -> bool {
        self.capabilities
            .as_ref()
            .is_some_and(|caps| caps.can_download)
            && (!self.mime_type.starts_with("application/vnd.google-apps.")
                || export_format(&self.mime_type).is_some())
    }
}

fn is_upload_session(endpoint: &Url, location: &Url) -> bool {
    location.origin() == endpoint.origin()
        && location.path() == endpoint.path()
        && location.username().is_empty()
        && location.password().is_none()
        && location.fragment().is_none()
        && location
            .query_pairs()
            .any(|(key, value)| key == "upload_id" && !value.is_empty() && value.len() <= 2048)
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_".contains(&c))
}

fn segments(path: &str) -> Result<Vec<&str>, ApiError> {
    if path.is_empty() {
        return Ok(vec![]);
    }
    let parts: Vec<_> = path.split('/').collect();
    if parts.len() > 12 || parts.iter().any(|part| !valid_id(part)) {
        return Err(Failure::Input("Choose a valid Google Drive folder or file.").into());
    }
    Ok(parts)
}

fn safe_name(name: &str) -> String {
    let mut output = String::new();
    for c in name.trim().chars().map(|c| {
        if c.is_control() || matches!(c, '/' | '\\') {
            '_'
        } else {
            c
        }
    }) {
        if output.len() + c.len_utf8() > 160 {
            break;
        }
        output.push(c);
    }
    if output.is_empty() || matches!(output.as_str(), "." | "..") {
        "Drive file".into()
    } else {
        output
    }
}

fn export_format(mime: &str) -> Option<(&'static str, &'static str)> {
    Some(match mime {
        "application/vnd.google-apps.document" => (
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            ".docx",
        ),
        "application/vnd.google-apps.spreadsheet" => (
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            ".xlsx",
        ),
        "application/vnd.google-apps.presentation" => (
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            ".pptx",
        ),
        _ => return None,
    })
}

async fn bounded(mut response: Response, limit: usize) -> Result<Vec<u8>, ApiError> {
    let large = || ApiError::PayloadTooLarge("This Google Drive response exceeds the size limit.");
    if response.content_length().is_some_and(|n| n > limit as u64) {
        return Err(large());
    }
    if response
        .headers()
        .get(header::CONTENT_ENCODING)
        .is_some_and(|value| !value.as_bytes().eq_ignore_ascii_case(b"identity"))
    {
        return Err(UNREADABLE);
    }
    let mut data = vec![];
    while let Some(chunk) = response.chunk().await.map_err(|_| UNREACHABLE)? {
        if chunk.len() > limit - data.len() {
            return Err(large());
        }
        data.extend_from_slice(&chunk);
    }
    Ok(data)
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/drive-files/status", get(status))
        .route("/api/drive-files", get(browse))
        .route("/api/drive-files/file", get(read))
        .route("/api/drive-files/export", post(export))
}

async fn status(State(w): State<Workspace>) -> impl IntoResponse {
    let connected = w.drive_files.as_ref().is_some_and(Drive::connected);
    Json(serde_json::json!({"configured":connected,
        "uploads":connected && w.drive_files.as_ref().is_some_and(Drive::uploads),
        "connectable":w.drive_files.as_ref().and_then(Drive::vault_entry).is_some()}))
}

async fn export(
    State(w): State<Workspace>,
    Json(body): Json<Export>,
) -> Result<impl IntoResponse, ApiError> {
    let drive = w
        .drive_files
        .as_ref()
        .filter(|drive| drive.uploads())
        .ok_or(Failure::Input(
            "Saving to Google Drive is disabled for this workspace.",
        ))?;
    if !valid_filename(&body.name) {
        return Err(
            Failure::Input("Use a filename up to 180 bytes without path separators.").into(),
        );
    }
    let data = body.data(&w.history)?;
    let bytes = data.len();
    let (path, id) = tokio::time::timeout(
        Duration::from_secs(40),
        drive.save(&body.folder, &body.name, data),
    )
    .await
    .map_err(|_| UNCONFIRMED)??;
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!({"path":path,"id":id,"bytes":bytes})),
    ))
}

async fn browse(
    State(w): State<Workspace>,
    Query(query): Query<Selection>,
) -> Result<impl IntoResponse, ApiError> {
    let drive = w
        .drive_files
        .ok_or(Failure::Input("Google Drive is not connected."))?;
    Ok(Json(
        tokio::time::timeout(Duration::from_secs(30), drive.list(query.path))
            .await
            .map_err(|_| UNREACHABLE)??,
    ))
}

async fn read(
    State(w): State<Workspace>,
    Query(query): Query<Selection>,
) -> Result<impl IntoResponse, ApiError> {
    let drive = w
        .drive_files
        .ok_or(Failure::Input("Google Drive is not connected."))?;
    let (name, data) = tokio::time::timeout(Duration::from_secs(30), drive.read(&query.path))
        .await
        .map_err(|_| UNREACHABLE)??;
    Ok(file_download_response(&name, data))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use axum::{body::to_bytes, extract::Request, response::Response};
    use serde_json::json;
    use std::{
        collections::HashMap,
        sync::atomic::{AtomicUsize, Ordering},
    };

    fn entry(
        id: &str,
        name: &str,
        mime: &str,
        parent: &str,
        size: Option<&str>,
        download: bool,
    ) -> serde_json::Value {
        json!({"id":id,"name":name,"mimeType":mime,"parents":[parent],"size":size,"capabilities":{"canDownload":download}})
    }

    async fn fixture(State(tokens): State<Arc<AtomicUsize>>, request: Request) -> Response {
        if request.uri().path() == "/token" {
            assert_eq!(request.method(), "POST");
            let data = to_bytes(request.into_body(), 1024).await.unwrap();
            let form: HashMap<_, _> = Url::parse(&format!(
                "http://example.test/?{}",
                std::str::from_utf8(&data).unwrap()
            ))
            .unwrap()
            .query_pairs()
            .into_owned()
            .collect();
            if form["grant_type"] == "authorization_code" {
                assert_eq!(form["code"], "fixture-auth");
                assert_eq!(form["code_verifier"].len(), 43);
                assert!(form["redirect_uri"].ends_with("/drive/oauth/callback"));
                tokens.fetch_add(1, Ordering::SeqCst);
                return Json(json!({"access_token":"valid","refresh_token":"fixture-refresh"}))
                    .into_response();
            }
            assert_eq!(form["grant_type"], "refresh_token");
            assert_eq!(form["refresh_token"], "fixture-refresh");
            let token = if tokens.fetch_add(1, Ordering::SeqCst) == 0 {
                "expired"
            } else {
                "valid"
            };
            return Json(json!({"access_token":token,"expires_in":3600})).into_response();
        }
        if request.headers().get(header::AUTHORIZATION).unwrap() == "Bearer expired" {
            return StatusCode::UNAUTHORIZED.into_response();
        }
        assert_eq!(
            request.headers().get(header::AUTHORIZATION).unwrap(),
            "Bearer valid"
        );
        let query: HashMap<_, _> = Url::parse(&format!("http://example.test{}", request.uri()))
            .unwrap()
            .query_pairs()
            .into_owned()
            .collect();
        if request.uri().path() == "/upload" {
            if request.method() == "POST" {
                assert_eq!(query["uploadType"], "resumable");
                assert_eq!(request.headers()["x-upload-content-length"], "12");
                let data = to_bytes(request.into_body(), 1024).await.unwrap();
                let metadata: serde_json::Value = serde_json::from_slice(&data).unwrap();
                assert_eq!(metadata["parents"], json!(["sub"]));
                if metadata["name"] == "Untrusted destination.txt" {
                    return (
                        [(
                            header::LOCATION,
                            "https://example.invalid/upload?upload_id=outside",
                        )],
                        "",
                    )
                        .into_response();
                }
                assert_eq!(metadata["name"], "Workspace copy.txt");
                return ([(header::LOCATION, "/upload?upload_id=fixture")], "").into_response();
            }
            assert_eq!(request.method(), "PUT");
            assert_eq!(query["upload_id"], "fixture");
            assert_eq!(
                to_bytes(request.into_body(), 1024).await.unwrap(),
                b"saved source".as_slice()
            );
            return (
                StatusCode::CREATED,
                Json(json!({"id":"created-file","name":"Workspace copy.txt","parents":["sub"]})),
            )
                .into_response();
        }
        assert_eq!(request.method(), "GET");
        let doc = || {
            entry(
                "doc",
                "Notes / review",
                "application/vnd.google-apps.document",
                "sub",
                None,
                true,
            )
        };
        let sub = || {
            let mut folder = entry("sub", "Team reports", MIME_FOLDER, "root", None, false);
            folder["capabilities"]["canAddChildren"] = json!(true);
            folder
        };
        let blob = || entry("blob", "Original.txt", "text/plain", "sub", Some("7"), true);
        let big = || {
            entry(
                "big",
                "Over limit.bin",
                "application/octet-stream",
                "sub",
                Some("99999999"),
                true,
            )
        };
        let outside = || entry("outside", "Unrelated", "text/plain", "other", None, true);
        let result = match request.uri().path() {
            "/files/root" => entry("root", "Shared folder", MIME_FOLDER, "", None, false),
            "/files/sub" => sub(),
            "/files/doc/export" => {
                assert_eq!(
                    query["mimeType"],
                    export_format("application/vnd.google-apps.document")
                        .unwrap()
                        .0
                );
                return b"Office bytes".as_slice().into_response();
            }
            "/files/doc" => doc(),
            "/files/blob" if query.get("alt").is_some_and(|value| value == "media") => {
                return b"content".as_slice().into_response();
            }
            "/files/blob" => blob(),
            "/files/big" => big(),
            "/files/outside" => outside(),
            "/files" if query["q"] == "'root' in parents and trashed = false" => {
                if query
                    .get("pageToken")
                    .is_some_and(|value| value == "second")
                {
                    json!({"files":[entry("next","Next folder",MIME_FOLDER,"root",None,false)]})
                } else {
                    json!({"files":[sub(),entry("link","Shortcut",MIME_SHORTCUT,"root",None,true)],"nextPageToken":"second"})
                }
            }
            "/files" if query["q"] == "'sub' in parents and trashed = false" => {
                json!({"files":[doc(),blob(),big(),outside()]})
            }
            _ => return StatusCode::NOT_FOUND.into_response(),
        };
        Json(result).into_response()
    }

    pub(crate) async fn fixture_connector() -> (Drive, Arc<AtomicUsize>, tokio::task::JoinHandle<()>)
    {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let tokens = Arc::new(AtomicUsize::new(0));
        let router = Router::new().fallback(fixture).with_state(tokens.clone());
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let drive = Drive(Arc::new(Connection {
            config: Credentials {
                folder_id: "root".into(),
                client_id: "fixture-client".into(),
                client_secret: "fixture-secret".into(),
                refresh_token: Some("fixture-refresh".into()),
                browser_oauth: false,
                allow_uploads: true,
            },
            client: Client::builder().no_proxy().build().unwrap(),
            oauth: Url::parse(&format!("{origin}/token")).unwrap(),
            files: Url::parse(&format!("{origin}/files")).unwrap(),
            upload: Url::parse(&format!("{origin}/upload")).unwrap(),
            setup: None,
            token: Mutex::new(None),
        }));
        (drive, tokens, server)
    }

    #[tokio::test]
    async fn drive_refreshes_oauth_and_reads_only_the_configured_tree() {
        let (drive, tokens, server) = fixture_connector().await;
        let root = drive.list(String::new()).await.ok().unwrap();
        assert_eq!(
            root.entries
                .iter()
                .map(|f| f.id.as_str())
                .collect::<Vec<_>>(),
            ["sub", "next"]
        );
        assert!(!root.truncated);
        assert!(!root.uploads);
        let sub = drive.list("sub".into()).await.ok().unwrap();
        assert_eq!(sub.label, "Shared folder / Team reports");
        assert_eq!(sub.entries.len(), 3);
        assert!(sub.uploads);
        assert!(matches!(
            drive.read("sub/outside").await,
            Err(ApiError::NotFound)
        ));
        assert!(matches!(
            drive.read("sub/big").await,
            Err(ApiError::PayloadTooLarge(_))
        ));
        let (name, data) = drive.read("sub/doc").await.ok().unwrap();
        assert_eq!(name, "Notes _ review.docx");
        assert_eq!(data, b"Office bytes");
        assert_eq!(drive.read("sub/blob").await.ok().unwrap().1, b"content");
        assert!(drive.read("../blob").await.is_err());
        assert!(
            drive
                .save("", "Blocked.txt", b"saved source".to_vec())
                .await
                .is_err()
        );
        assert!(matches!(
            drive
                .save("sub", "Untrusted destination.txt", b"saved source".to_vec())
                .await,
            Err(ApiError::ConnectedFiles(_))
        ));
        let (path, id) = drive
            .save("sub", "Workspace copy.txt", b"saved source".to_vec())
            .await
            .ok()
            .unwrap();
        assert_eq!(
            path,
            "Google Drive / Shared folder / Team reports / Workspace copy.txt"
        );
        assert_eq!(id, "created-file");
        assert_eq!(tokens.load(Ordering::SeqCst), 2);
        server.abort();
    }

    #[tokio::test]
    async fn browser_oauth_validates_state_once_and_seals_the_verified_grant() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let origin = format!("http://{addr}");
        let tokens = Arc::new(AtomicUsize::new(0));
        let router = Router::new().fallback(fixture).with_state(tokens.clone());
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let temp = tempfile::tempdir().unwrap();
        let history = History::open_at(&temp.path().join("workspace")).unwrap();
        let setup = Setup::new(
            Vault::fixture(),
            history.clone(),
            addr.port(),
            "fixture-client",
            "root",
            false,
        );
        let name = setup.name().to_owned();
        let drive = Drive(Arc::new(Connection {
            config: Credentials {
                folder_id: "root".into(),
                client_id: "fixture-client".into(),
                client_secret: "fixture-secret".into(),
                refresh_token: None,
                browser_oauth: true,
                allow_uploads: false,
            },
            setup: Some(setup),
            client: Client::builder().no_proxy().build().unwrap(),
            token: Mutex::new(None),
            oauth: Url::parse(&format!("{origin}/token")).unwrap(),
            files: Url::parse(&format!("{origin}/files")).unwrap(),
            upload: Url::parse(&format!("{origin}/upload")).unwrap(),
        }));
        assert!(!drive.connected());
        let start = drive.begin_oauth().ok().unwrap();
        let link: HashMap<_, _> = start.query_pairs().into_owned().collect();
        assert_eq!(start.host_str(), Some("accounts.google.com"));
        assert_eq!(link["code_challenge_method"], "S256");
        assert_eq!(
            link["scope"],
            "https://www.googleapis.com/auth/drive.readonly"
        );
        assert!(!start.as_str().contains("fixture-secret"));
        let finish = |state| drive.complete_oauth(state, Some("fixture-auth".into()));
        assert!(finish("forged state").await.is_err());
        assert_eq!(tokens.load(Ordering::SeqCst), 0);
        let last = drive.begin_oauth().ok().unwrap();
        assert!(finish(&link["state"]).await.is_err());
        let state = last
            .query_pairs()
            .find(|(name, _)| name == "state")
            .unwrap()
            .1;
        assert!(finish(&state).await.is_ok());
        assert!(finish(&state).await.is_err());
        assert_eq!(tokens.load(Ordering::SeqCst), 1);
        assert!(drive.connected());
        let ciphertext: Vec<u8> = history
            .db()
            .unwrap()
            .query_row(
                "SELECT ciphertext FROM vault_secrets WHERE name=?1",
                [name],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            !ciphertext
                .windows(15)
                .any(|part| part == b"fixture-refresh")
        );
        assert!(drive.list(String::new()).await.is_ok());
        assert_eq!(tokens.load(Ordering::SeqCst), 2);
        let pending = drive.begin_oauth().ok().unwrap();
        let state = pending
            .query_pairs()
            .find(|(name, _)| name == "state")
            .unwrap()
            .1;
        assert!(drive.disconnect_oauth().await.is_ok());
        assert!(!drive.connected() && drive.list(String::new()).await.is_err());
        assert!(finish(&state).await.is_err());
        assert_eq!(tokens.load(Ordering::SeqCst), 2);
        server.abort();
    }
}
