use crate::{ApiError, Workspace, core::Failure, history::History, vault::Vault};
use axum::{
    Json, Router,
    extract::{Query, State},
    http::{StatusCode, header},
    response::IntoResponse,
    routing::get,
};
use reqwest::{Client, Url, redirect::Policy};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{sync::Arc, time::Duration};

#[path = "github_access.rs"]
pub(crate) mod access;

const API: &str = "https://api.github.com/";
const API_VERSION: &str = "2022-11-28";
const PER_PAGE: u16 = 25;
const MAX_PAGE: u16 = 20;
const EXCERPT: usize = 8 * 1024;
const UPSTREAM_LIMIT: usize = 4 * 1024 * 1024;

#[derive(Clone)]
pub struct Project(Arc<Connection>);

struct Connection {
    repository: Repository,
    client: Client,
    origin: Url,
    credential: Option<Credential>,
    agent_access: access::Desk,
}

struct Repository {
    owner: String,
    name: String,
}

struct Credential {
    history: History,
    vault: Vault,
    name: String,
}

#[derive(Clone, Eq, PartialEq)]
enum CredentialStamp {
    Public,
    Vault(String, i64),
}

struct Authorization {
    token: Option<String>,
    stamp: CredentialStamp,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Kind {
    Issue,
    PullRequest,
}

impl Kind {
    fn path(self) -> &'static str {
        match self {
            Self::Issue => "issues",
            Self::PullRequest => "pulls",
        }
    }

    fn web_path(self) -> &'static str {
        match self {
            Self::Issue => "issues",
            Self::PullRequest => "pull",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Issue => "Issue",
            Self::PullRequest => "Pull request",
        }
    }
}

#[derive(Deserialize)]
struct Summary {
    number: u32,
    title: String,
    state: String,
    #[serde(default)]
    pull_request: Option<serde::de::IgnoredAny>,
}

#[derive(Deserialize)]
struct Details {
    #[serde(flatten)]
    summary: Summary,
    body_text: Option<String>,
    body: Option<String>,
}

#[derive(Serialize)]
struct Entry {
    kind: Kind,
    number: u32,
    title: String,
}

#[derive(Serialize)]
struct Listing {
    repository: String,
    entries: Vec<Entry>,
    next_page: Option<u16>,
}

#[derive(Serialize)]
struct Excerpt {
    title: String,
    source: String,
    excerpt: String,
    file_name: String,
    attachment: String,
    truncated: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BrowserPage {
    #[serde(default = "first_page")]
    page: u16,
}

fn first_page() -> u16 {
    1
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Item {
    kind: Kind,
    number: u32,
}

impl Repository {
    fn parse(raw: &str) -> Option<Self> {
        let (owner, name) = raw.split_once('/')?;
        if !(1..=39).contains(&owner.len())
            || !owner
                .as_bytes()
                .first()
                .is_some_and(u8::is_ascii_alphanumeric)
            || !owner
                .as_bytes()
                .last()
                .is_some_and(u8::is_ascii_alphanumeric)
            || owner.contains("--")
            || !owner
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-')
            || !(1..=100).contains(&name.len())
            || matches!(name, "." | "..")
            || !name
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b".-_".contains(&c))
        {
            return None;
        }
        Some(Self {
            owner: owner.into(),
            name: name.into(),
        })
    }

    fn name(&self) -> String {
        format!("{}/{}", self.owner, self.name)
    }
}

impl Project {
    pub fn configured(
        history: &History,
        vault: Option<&Vault>,
    ) -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let Some(raw) = std::env::var_os("SWARMHUB_GITHUB_REPOSITORY") else {
            return Ok(None);
        };
        let repository = raw.to_str().and_then(Repository::parse).ok_or(
            "Set SWARMHUB_GITHUB_REPOSITORY to one GitHub repository in owner/repository form.",
        )?;
        let credential = std::env::var_os("SWARMHUB_GITHUB_VAULT_ENTRY")
            .map(|name| {
                let vault = vault
                    .cloned()
                    .ok_or("Configure the workspace Vault before using a GitHub credential.")?;
                let name = name
                    .into_string()
                    .ok()
                    .filter(|s| crate::vault::valid_name(s))
                    .ok_or("Set SWARMHUB_GITHUB_VAULT_ENTRY to a valid Vault entry name.")?;
                Ok::<_, &str>(Credential {
                    history: history.clone(),
                    vault,
                    name,
                })
            })
            .transpose()?;
        let origin = Url::parse(API)?;
        #[cfg(feature = "github-test-fixture")]
        let origin = if let Some(raw) = std::env::var_os("SWARMHUB_GITHUB_TEST_ORIGIN") {
            if credential.is_some() {
                return Err("The GitHub test fixture cannot use a Vault credential.".into());
            }
            let port = raw
                .to_str()
                .and_then(|raw| raw.strip_prefix("http://127.0.0.1:"))
                .and_then(|port| {
                    let port = port.strip_suffix('/').unwrap_or(port);
                    if !port.bytes().all(|byte| byte.is_ascii_digit()) {
                        return None;
                    }
                    port.parse::<u16>().ok().filter(|value| *value > 0)
                })
                .ok_or("The GitHub test fixture must use a literal 127.0.0.1 HTTP origin.")?;
            Url::parse(&format!("http://127.0.0.1:{port}/"))?
        } else {
            origin
        };
        Ok(Some(Self::new(repository, credential, origin)?))
    }

    fn new(
        repository: Repository,
        credential: Option<Credential>,
        origin: Url,
    ) -> Result<Self, reqwest::Error> {
        let client = Client::builder()
            .no_proxy()
            .redirect(Policy::none())
            .retry(reqwest::retry::never())
            .https_only(origin.scheme() == "https")
            .timeout(Duration::from_secs(15))
            .build()?;
        Ok(Self(Arc::new(Connection {
            repository,
            credential,
            client,
            origin,
            agent_access: access::Desk::default(),
        })))
    }

    fn url(&self, kind: Kind, item: Option<u32>) -> Url {
        let mut url = self.0.origin.clone();
        {
            let mut path = url
                .path_segments_mut()
                .expect("HTTPS or fixture HTTP origin");
            path.pop_if_empty()
                .push("repos")
                .push(&self.0.repository.owner)
                .push(&self.0.repository.name)
                .push(kind.path());
            if let Some(number) = item {
                path.push(&number.to_string());
            }
        }
        url
    }

    fn authorization(&self) -> Result<Authorization, ApiError> {
        if let Some(credential) = &self.0.credential {
            let (token, id, revision) = credential
                .vault
                .lookup_versioned(&credential.history, &credential.name)?
                .filter(|(token, _, _)| {
                    !token.is_empty()
                        && token.len() <= 3072
                        && token
                            .bytes()
                            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
                })
                .ok_or(ApiError::ConnectedFiles(
                    "Add a valid GitHub read token to the configured Vault entry.",
                ))?;
            return Ok(Authorization {
                token: Some(token),
                stamp: CredentialStamp::Vault(id, revision),
            });
        }
        let token = None;
        #[cfg(feature = "github-test-fixture")]
        let token = token
            .or_else(|| (self.0.origin.scheme() == "http").then(|| "swarmhub-fixture-only".into()));
        Ok(Authorization {
            token,
            stamp: CredentialStamp::Public,
        })
    }

    async fn fetch(&self, url: Url) -> Result<(Vec<u8>, bool), ApiError> {
        self.fetch_as(url, self.authorization()?.token.as_deref())
            .await
    }

    async fn fetch_as(&self, url: Url, token: Option<&str>) -> Result<(Vec<u8>, bool), ApiError> {
        const UNAVAILABLE: ApiError =
            ApiError::ConnectedFiles("GitHub could not return this repository’s data.");
        let mut request = self
            .0
            .client
            .get(url)
            .header(header::USER_AGENT, "SwarmHub-Herdr")
            .header(header::ACCEPT, "application/vnd.github.text+json")
            .header("X-GitHub-Api-Version", API_VERSION);
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        let mut response = request.send().await.map_err(|_| UNAVAILABLE)?;
        match response.status() {
            StatusCode::OK => {}
            StatusCode::NOT_FOUND => return Err(ApiError::NotFound),
            StatusCode::FORBIDDEN | StatusCode::UNAUTHORIZED | StatusCode::TOO_MANY_REQUESTS => {
                return Err(ApiError::ConnectedFiles(
                    "GitHub denied the read or reached its rate limit. Check the repository and token, or try later.",
                ));
            }
            _ => return Err(UNAVAILABLE),
        }
        let next = response
            .headers()
            .get_all(header::LINK)
            .iter()
            .filter_map(|link| link.to_str().ok())
            .any(|link| link.contains("rel=\"next\""));
        let mut data = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| UNAVAILABLE)? {
            if data.len() + chunk.len() > UPSTREAM_LIMIT {
                return Err(ApiError::ConnectedFiles(
                    "GitHub returned too much data for this page.",
                ));
            }
            data.extend_from_slice(&chunk);
        }
        Ok((data, next))
    }

    async fn browse(&self, page: u16) -> Result<Listing, ApiError> {
        if !(1..=MAX_PAGE).contains(&page) {
            return Err(Failure::Input("Choose a valid GitHub results page.").into());
        }
        let mut url = self.url(Kind::Issue, None);
        url.query_pairs_mut()
            .append_pair("state", "open")
            .append_pair("per_page", &PER_PAGE.to_string())
            .append_pair("page", &page.to_string());
        // GitHub's issue list also includes pull requests. The marker is used
        // only to select the appropriate fixed detail endpoint.
        let (data, next) = self.fetch(url).await?;
        let rows: Vec<Summary> = serde_json::from_slice(&data)
            .map_err(|_| ApiError::ConnectedFiles("GitHub returned an invalid issue list."))?;
        let entries = rows
            .into_iter()
            .take(usize::from(PER_PAGE))
            .filter(|row| row.number > 0 && row.state == "open")
            .map(|row| Entry {
                kind: if row.pull_request.is_some() {
                    Kind::PullRequest
                } else {
                    Kind::Issue
                },
                number: row.number,
                title: clean(&row.title, 300, false).0,
            })
            .collect();
        Ok(Listing {
            repository: self.0.repository.name(),
            entries,
            next_page: (next && page < MAX_PAGE).then(|| page + 1),
        })
    }

    async fn read(&self, item: Item) -> Result<Excerpt, ApiError> {
        self.read_as(item, self.authorization()?.token.as_deref())
            .await
    }

    async fn read_as(&self, item: Item, token: Option<&str>) -> Result<Excerpt, ApiError> {
        if item.number == 0 {
            return Err(Failure::Input("Choose a GitHub issue or pull request number.").into());
        }
        let (data, _) = self
            .fetch_as(self.url(item.kind, Some(item.number)), token)
            .await?;
        let result: Details = serde_json::from_slice(&data)
            .map_err(|_| ApiError::ConnectedFiles("GitHub returned invalid item details."))?;
        if result.summary.number != item.number
            || result.summary.state != "open"
            || (item.kind == Kind::Issue && result.summary.pull_request.is_some())
        {
            return Err(ApiError::NotFound);
        }
        let title = clean(&result.summary.title, 300, false).0;
        let body = result
            .body_text
            .as_deref()
            .or(result.body.as_deref())
            .unwrap_or("");
        let (excerpt, truncated) = clean(body, EXCERPT, true);
        let source = format!(
            "https://github.com/{}/{}/{}",
            self.0.repository.name(),
            item.kind.web_path(),
            item.number
        );
        let label = format!("{} #{}: {title}", item.kind.label(), item.number);
        let note = if truncated {
            "\n\n[Excerpt shortened by SwarmHub.]"
        } else {
            ""
        };
        let attachment = format!(
            "GitHub {}\n{label}\nSource: {source}\n\n{excerpt}{note}\n",
            self.0.repository.name()
        );
        Ok(Excerpt {
            title: label,
            source,
            excerpt,
            file_name: format!("github-{}-{}.txt", item.kind.path(), item.number),
            attachment,
            truncated,
        })
    }
}

fn clean(raw: &str, limit: usize, multiline: bool) -> (String, bool) {
    let mut text = String::new();
    let normalized = raw.replace("\r\n", "\n");
    for c in normalized.chars() {
        let c = if c.is_control() && !(multiline && matches!(c, '\n' | '\t')) {
            ' '
        } else {
            c
        };
        if text.len() + c.len_utf8() > limit {
            return (text.trim().to_owned(), true);
        }
        text.push(c);
    }
    (text.trim().to_owned(), false)
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .merge(access::routes())
        .route(
            "/github-project.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/github-project.js"),
                )
            }),
        )
        .route("/api/github-project/status", get(status))
        .route("/api/github-project/items", get(browse))
        .route("/api/github-project/item", get(read))
}

async fn status(State(w): State<Workspace>) -> impl IntoResponse {
    Json(json!({"repository":w.github_project.as_ref().map(|project| project.0.repository.name())}))
}

async fn browse(
    State(w): State<Workspace>,
    Query(query): Query<BrowserPage>,
) -> Result<Json<Listing>, ApiError> {
    let project = w.github_project.as_ref().ok_or(ApiError::NotFound)?;
    Ok(Json(project.browse(query.page).await?))
}

async fn read(
    State(w): State<Workspace>,
    Query(query): Query<Item>,
) -> Result<Json<Excerpt>, ApiError> {
    let project = w.github_project.as_ref().ok_or(ApiError::NotFound)?;
    Ok(Json(project.read(query).await?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{http::HeaderMap, response::Redirect};
    use std::sync::atomic::{AtomicBool, Ordering};

    #[tokio::test]
    async fn scoped_reads_use_the_vault_but_never_follow_links_or_redirects() {
        let home = tempfile::tempdir().unwrap();
        let history = History::open_at(&home.path().join("workspace")).unwrap();
        let vault = Vault::fixture();
        let synthetic = "github_pat_synthetic_vault_only";
        assert!(
            vault
                .put_connector(&history, "Fixture project", synthetic.into())
                .is_ok()
        );
        let followed = Arc::new(AtomicBool::new(false));
        let leak = followed.clone();
        let router = Router::new()
            .route("/repos/demo/work/issues", get(|headers: HeaderMap, Query(query): Query<std::collections::HashMap<String,String>>| async move {
                assert_eq!(headers[header::AUTHORIZATION], "Bearer github_pat_synthetic_vault_only");
                assert_eq!(headers[header::ACCEPT], "application/vnd.github.text+json");
                assert_eq!(headers["X-GitHub-Api-Version"], API_VERSION);
                assert_eq!(query.get("state").map(String::as_str), Some("open"));
                assert_eq!(query.get("page").map(String::as_str), Some("1"));
                ([(header::LINK, "<http://outside.invalid/ignore-me>; rel=\"next\"")], Json(json!([
                    {"title":"Issue","state":"open","number":42},
                    {"title":"PR","state":"open","number":45,"pull_request":{}},
                    {"title":"Closed","state":"closed","number":50}
                ])))
            }))
            .route("/repos/demo/work/pulls/45", get(|| async {
                Json(json!({"title":"Reviewed PR","state":"open","number":45,
                    "body_text":"literal <img> \u{001b}control","html_url":"http://outside.invalid/ignore-me"}))
            }))
            .route("/repos/demo/work/issues/42", get(|| async { Redirect::temporary("/leak") }))
            .route("/leak", get(move || async move { leak.store(true, Ordering::Relaxed); "wrong" }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
        let project = Project::new(
            Repository::parse("demo/work").unwrap(),
            Some(Credential {
                history,
                vault,
                name: "Fixture project".into(),
            }),
            origin,
        )
        .unwrap();
        let listing = project.browse(1).await.ok().unwrap();
        assert_eq!(listing.next_page, Some(2));
        assert_eq!(listing.entries.len(), 2);
        assert_eq!(listing.entries[1].kind, Kind::PullRequest);
        let result = project
            .read(Item {
                kind: Kind::PullRequest,
                number: 45,
            })
            .await
            .ok()
            .unwrap();
        assert_eq!(result.source, "https://github.com/demo/work/pull/45");
        assert!(result.excerpt.contains("<img>") && !result.excerpt.contains('\u{001b}'));
        assert!(!serde_json::to_string(&result).unwrap().contains(synthetic));
        assert!(matches!(
            project
                .read(Item {
                    kind: Kind::Issue,
                    number: 42
                })
                .await,
            Err(ApiError::ConnectedFiles(_))
        ));
        assert!(!followed.load(Ordering::Relaxed));
        server.abort();
    }

    #[test]
    fn rejects_repo_path_changes_and_preserves_utf8_at_excerpt_boundaries() {
        for invalid in [
            "demo/..",
            "https://demo/work",
            "demo/work/issues",
            "demo/a%2fb",
            "demo/a?private",
            "démø/work",
        ] {
            assert!(Repository::parse(invalid).is_none(), "{invalid}");
        }
        let (prefix, cut) = clean("éé🙂", 5, true);
        assert_eq!(prefix, "éé");
        assert!(cut);
    }
}
