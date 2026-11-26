use crate::{
    ApiError, Workspace,
    core::{Failure, MAX_FILE, valid_filename},
    file_download_response, file_preview,
    groups::{MAX_FILES, Upload},
};
use axum::{
    Json, Router,
    extract::{Multipart, Path, State, multipart::MultipartError},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use serde::{Deserialize, de::DeserializeOwned};

// Team Pack instructions travel with the turn without consuming the user's four uploads.
const WORKFLOW_LIMIT: usize = 2 * 1024 * 1024;
pub const UPLOAD_LIMIT: usize = MAX_FILE + WORKFLOW_LIMIT + 128 * 1024;
const TOO_LARGE: ApiError = ApiError::PayloadTooLarge("Task attachments must total 8 MiB or less.");

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum SavedSource {
    Library {
        id: i64,
    },
    Group {
        id: i64,
        group: i64,
    },
    Direct {
        id: i64,
        core: String,
        address: String,
        created: u64,
        task: i64,
    },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Export {
    source: SavedSource,
    pub folder: String,
    pub name: String,
}

impl Export {
    pub fn data(&self, history: &crate::history::History) -> Result<Vec<u8>, ApiError> {
        let (_, contents) = match &self.source {
            SavedSource::Library { id } => history.artifact(*id)?,
            SavedSource::Group { id, group } => history.group_file(*group, *id)?,
            SavedSource::Direct {
                id,
                core,
                address,
                created,
                task,
            } => history.direct_file(core, address, *created, *task, *id)?,
        }
        .ok_or(ApiError::NotFound)?;
        if contents.len() > MAX_FILE {
            return Err(Failure::Input("Save a file up to 8 MiB.").into());
        }
        Ok(contents)
    }
}

fn upload_error(error: MultipartError) -> ApiError {
    if error.status() == StatusCode::PAYLOAD_TOO_LARGE {
        TOO_LARGE
    } else {
        Failure::Input("The upload could not be read. Try attaching the files again.").into()
    }
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/history/{core}/{id}/{created}/files/{task}/{file}",
            get(download),
        )
        .route(
            "/api/history/{core}/{id}/{created}/files/{task}/{file}/info",
            get(info),
        )
        .route(
            "/api/history/{core}/{id}/{created}/files/{task}/{file}/image",
            get(image),
        )
}

#[derive(Deserialize)]
struct Target {
    core: String,
    id: String,
    created: u64,
    task: i64,
    file: i64,
}

impl Target {
    fn load(&self, w: &Workspace) -> Result<(String, Vec<u8>), ApiError> {
        w.history
            .direct_file(&self.core, &self.id, self.created, self.task, self.file)?
            .ok_or(ApiError::NotFound)
    }
}

async fn download(
    State(w): State<Workspace>,
    Path(target): Path<Target>,
) -> Result<Response, ApiError> {
    let (name, data) = target.load(&w)?;
    Ok(file_download_response(&name, data))
}

async fn info(
    State(w): State<Workspace>,
    Path(target): Path<Target>,
) -> Result<impl IntoResponse, ApiError> {
    let (name, data) = target.load(&w)?;
    Ok(Json(file_preview::info(&name, &data)).into_response())
}

async fn image(
    State(w): State<Workspace>,
    Path(target): Path<Target>,
) -> Result<Response, ApiError> {
    let (_, data) = target.load(&w)?;
    file_preview::raster_response(data)
}

pub async fn read<T: DeserializeOwned>(
    mut multipart: Multipart,
) -> Result<(T, Vec<Upload>), ApiError> {
    let mut message = None;
    let mut files = vec![];
    let mut workflow = None;
    let mut total = 0;
    while let Some(field) = multipart.next_field().await.map_err(upload_error)? {
        match field.name() {
            Some("message") if message.is_none() && field.file_name().is_none() => {
                let raw = field.bytes().await.map_err(upload_error)?;
                if raw.len() > 64 * 1024 {
                    return Err(Failure::Input("The message is too large.").into());
                }
                message = Some(
                    serde_json::from_slice(&raw)
                        .map_err(|_| Failure::Input("Enter a valid message."))?,
                );
            }
            Some("workflow") if workflow.is_none() => {
                let name = field.file_name().filter(|name| valid_filename(name))
                    .ok_or(Failure::Input("Choose a valid workflow filename."))?.to_owned();
                let data = field.bytes().await.map_err(upload_error)?;
                if data.len() > WORKFLOW_LIMIT || std::str::from_utf8(&data).is_err() {
                    return Err(Failure::Input("Group workflow instructions must be UTF-8 text up to 2 MiB.").into());
                }
                workflow = Some(Upload { name, data });
            }
            Some("file") if files.len() < MAX_FILES => {
                let name = field
                    .file_name()
                    .filter(|name| valid_filename(name))
                    .ok_or(Failure::Input(
                        "Use filenames up to 180 bytes without path separators.",
                    ))?
                    .to_owned();
                let data = field.bytes().await.map_err(upload_error)?;
                total += data.len();
                if total > MAX_FILE {
                    return Err(TOO_LARGE);
                }
                files.push(Upload { name, data });
            }
            Some("file") => {
                return Err(Failure::Input("Attach up to four files per message.").into());
            }
            _ => return Err(Failure::Input("The upload contains an unexpected field.").into()),
        }
    }
    let message = message.ok_or(Failure::Input("Write a task before sending attachments."))?;
    files.extend(workflow);
    if files.is_empty() {
        return Err(Failure::Input("Choose at least one file to attach.").into());
    }
    Ok((message, files))
}


pub fn stage_launch_files(
    workspace: &std::path::Path,
    files: &[Upload],
) -> Result<(tempfile::TempDir, String), ApiError> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    const ERROR: ApiError = ApiError::Conflict("A file could not be attached. The task was not sent.");
    // Use a non-hidden directory name inside the private bot workspace so Claude Code and other
    // runtimes do not treat staged attachments or handoffs as sensitive dotfile reads.
    let directory = tempfile::Builder::new().prefix("swarmhub-files-").tempdir_in(workspace).map_err(|_| ERROR)?;
    let mut paths = Vec::new();
    for (index, file) in files.iter().enumerate() {
        if !valid_filename(&file.name) { return Err(ERROR); }
        let path = directory.path().join(format!("{}-{}", index + 1, file.name));
        let mut target = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).map_err(|_| ERROR)?;
        target.write_all(&file.data).map_err(|_| ERROR)?;
        let path = path.to_str().ok_or(ERROR)?;
        paths.push(serde_json::json!({"name": file.name, "path": path}));
    }
    Ok((directory, format!("\n\nAttached files (name and terminal path):\n{}", serde_json::json!(paths))))
}

#[cfg(test)]
mod launch_file_tests {
    use super::*;

    #[test]
    fn first_task_files_remain_whole_and_have_distinct_private_paths() {
        let workspace = tempfile::tempdir().unwrap();
        let document = "x".repeat(12_000) + "final question";
        let files = vec![
            Upload { name: "notes.txt".into(), data: document.clone().into_bytes().into() },
            Upload { name: "notes.txt".into(), data: b"second file".to_vec().into() },
        ];
        let (directory, suffix) = stage_launch_files(workspace.path(), &files).ok().unwrap();
        assert_eq!(std::fs::read(directory.path().join("1-notes.txt")).unwrap(), document.as_bytes());
        assert_eq!(std::fs::read(directory.path().join("2-notes.txt")).unwrap(), b"second file");
        assert!(suffix.contains("1-notes.txt") && suffix.contains("2-notes.txt"));
        assert!(stage_launch_files(workspace.path(), &[Upload { name: "../outside".into(), data: Default::default() }]).is_err());
    }
}
