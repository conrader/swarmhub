use crate::{
    ApiError, Workspace,
    agent::shell_quote,
    core::{Failure, Terminal, validate_task},
    delivery_failure, file_download_response, file_preview,
    group_forms::Values,
    group_handoffs::{self, Candidate},
    groups::{Delivery, Group, Queued, Quote, Target, Upload},
    history::StoreError,
    task_files,
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Multipart, Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashSet, sync::Arc};

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/groups", get(list).post(create))
        .route("/api/groups/{id}", get(get_group).post(edit))
        .route("/api/groups/{id}/messages", get(messages).post(send))
        .route(
            "/api/groups/{id}/messages/with-files",
            post(send_with_files).layer(DefaultBodyLimit::max(task_files::UPLOAD_LIMIT)),
        )
        .route("/api/groups/{id}/files/{file}", get(download))
        .route("/api/groups/{id}/files/{file}/info", get(group_file_info))
        .route("/api/groups/{id}/files/{file}/image", get(group_file_image))
}

async fn list(State(w): State<Workspace>) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(w.history.groups()?))
}

fn name(input: &str) -> Result<&str, Failure> {
    let input = input.trim();
    if input.is_empty() || input.chars().count() > 60 || input.chars().any(char::is_control) {
        return Err(Failure::Input("Enter a group name up to 60 characters."));
    }
    Ok(input)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create {
    name: String,
    members: Vec<Target>,
}

async fn create(
    State(w): State<Workspace>,
    Json(body): Json<Create>,
) -> Result<impl IntoResponse, ApiError> {
    let name = name(&body.name)?;
    if !(2..=6).contains(&body.members.len()) || !distinct(&body.members) {
        return Err(Failure::Input("Choose two to six different agents.").into());
    }
    let hello = w.core.identify().await?;
    let mut agents = Vec::with_capacity(body.members.len());
    for target in body.members {
        agents.push(member(&w, &target).await?);
    }
    let id = w.history.create_group(&hello.core.id, name, &agents)?;
    Ok((StatusCode::CREATED, Json(load_group(&w, id)?)))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Edit {
    name: String,
    members: Vec<Target>,
    revision: i64,
}

const GROUP_CHANGED: ApiError =
    ApiError::Conflict("Group settings changed. Review the current members and try again.");

async fn edit(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<Edit>,
) -> Result<impl IntoResponse, ApiError> {
    let name = name(&body.name)?;
    let group = load_group(&w, id)?;
    if body.revision != group.revision {
        return Err(GROUP_CHANGED);
    }
    if !(2..=6).contains(&body.members.len()) || !distinct(&body.members) {
        return Err(Failure::Input("Choose two to six different agents.").into());
    }
    let mut additions = Vec::new();
    let new_targets = body
        .members
        .iter()
        .filter(|target| !group.members.iter().any(|member| member.target == **target))
        .collect::<Vec<_>>();
    if !new_targets.is_empty() {
        let hello = w.core.identify().await?;
        if hello.core.id != group.core {
            return Err(Failure::Input("This group belongs to a different Herdr Core.").into());
        }
        for target in new_targets {
            additions.push(member(&w, target).await?);
        }
    }
    if !w.history.edit_group(
        &group,
        name,
        &body.members.into_iter().collect(),
        &additions,
    )? {
        return Err(GROUP_CHANGED);
    }
    Ok(Json(load_group(&w, id)?))
}

async fn member(w: &Workspace, target: &Target) -> Result<Terminal, Failure> {
    let agent = w.core.agent(&target.address, target.created_ms).await?;
    agent.require_live()?;
    if agent.launch_key().is_none() {
        return Err(Failure::Input("Choose agents started from this workspace."));
    }
    Ok(agent)
}

async fn get_group(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(load_group(&w, id)?))
}

fn load_group(w: &Workspace, id: i64) -> Result<Group, ApiError> {
    w.history.group(id)?.ok_or(ApiError::NotFound)
}

#[derive(Deserialize)]
struct Cursor {
    before: Option<i64>,
}

async fn messages(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Query(query): Query<Cursor>,
) -> Result<impl IntoResponse, ApiError> {
    load_group(&w, id)?;
    let mut page = w.history.group_page(id, query.before)?.with_markup();
    if query.before.is_none() {
        page.live_drafts = w.drafts.group_drafts(&w.history, id)?;
    }
    Ok(Json(page))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Send {
    text: String,
    recipients: Vec<Target>,
    revision: i64,
    reply_to: Option<i64>,
    form_values: Option<Values>,
}

async fn send(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<Send>,
) -> Result<impl IntoResponse, ApiError> {
    send_group(w, id, body, vec![], None).await
}

async fn send_with_files(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    multipart: Multipart,
) -> Result<impl IntoResponse, ApiError> {
    let (message, files) = task_files::read(multipart).await?;
    send_group(w, id, message, files, None).await
}

pub(crate) async fn send_handoff(
    w: Workspace,
    id: i64,
    handoff: i64,
    revision: i64,
    task: String,
    target: Target,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    send_group(
        w,
        id,
        Send {
            text: task,
            recipients: vec![target],
            revision,
            reply_to: None,
            form_values: None,
        },
        vec![],
        Some(handoff),
    )
    .await
}

async fn download(
    State(w): State<Workspace>,
    Path((group, file)): Path<(i64, i64)>,
) -> Result<impl IntoResponse, ApiError> {
    let (name, data) = w
        .history
        .group_file(group, file)?
        .ok_or(ApiError::NotFound)?;
    Ok(file_download_response(&name, data))
}

async fn group_file_info(
    State(w): State<Workspace>,
    Path((group, file)): Path<(i64, i64)>,
) -> Result<impl IntoResponse, ApiError> {
    let (name, data) = w
        .history
        .group_file(group, file)?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(file_preview::info(&name, &data)).into_response())
}

async fn group_file_image(
    State(w): State<Workspace>,
    Path((group, file)): Path<(i64, i64)>,
) -> Result<impl IntoResponse, ApiError> {
    let (_, data) = w
        .history
        .group_file(group, file)?
        .ok_or(ApiError::NotFound)?;
    file_preview::raster_response(data)
}

async fn send_group(
    w: Workspace,
    id: i64,
    mut body: Send,
    files: Vec<Upload>,
    handoff: Option<i64>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let group = load_group(&w, id)?;
    if body.revision != group.revision {
        return Err(GROUP_CHANGED);
    }
    if body.recipients.is_empty()
        || !distinct(&body.recipients)
        || !body
            .recipients
            .iter()
            .all(|target| group.members.iter().any(|member| &member.target == target))
    {
        return Err(Failure::Input("Choose at least one group member as a recipient.").into());
    }
    let quote = if let Some(message) = body.reply_to {
        let source = w
            .history
            .reply_source(id, message)?
            .ok_or(ApiError::NotFound)?;
        if body.recipients.as_slice() != [source.target] {
            return Err(Failure::Input(
                "A directed reply must go only to the original agent session.",
            )
            .into());
        }
        match (source.form, body.form_values.take()) {
            (Some(form), Some(values)) if body.text.is_empty() && files.is_empty() => {
                body.text = form.response(values)?;
            }
            (Some(_), _) => {
                return Err(Failure::Input(
                    "Submit the requested form fields without extra text or files.",
                )
                .into());
            }
            (None, Some(_)) => {
                return Err(Failure::Input("This message does not have a form to answer.").into());
            }
            (None, None) => {}
        }
        Some(Arc::new(source.quote))
    } else {
        if body.form_values.is_some() {
            return Err(Failure::Input("Choose a group form to answer.").into());
        }
        None
    };
    validate_task(&body.text)?;
    if body.text.len() > 8 * 1024 {
        return Err(Failure::Input("Group messages can contain up to 8 KiB of text.").into());
    }
    let hello = w.core.identify().await?;
    if hello.core.id != group.core {
        return Err(Failure::Input("This group belongs to a different Herdr Core.").into());
    }
    if !files.is_empty() && !hello.supports("terminal.put") {
        return Err(Failure::Input("This Herdr Core does not support file staging.").into());
    }
    let executable = std::env::current_exe()
        .ok()
        .and_then(|path| path.into_os_string().into_string().ok())
        .filter(|path| !path.chars().any(char::is_control) && path.len() <= 512)
        .ok_or(Failure::Input(
            "The workspace binary path cannot be used for group replies.",
        ))?;
    let prompt_group = Arc::new(PromptGroup {
        name: group.name.clone(),
        candidates: if handoff.is_some() {
            vec![]
        } else {
            let db = w.history.db()?;
            group_handoffs::candidates(&db, id).map_err(StoreError::from)?
        },
    });
    let (message_id, deliveries) = match w.history.queue_group(
        &group,
        &body.text,
        body.recipients,
        &files,
        body.reply_to,
        handoff,
    )? {
        Queued::Ready(id, deliveries) => (id, deliveries),
        Queued::RosterChanged => return Err(GROUP_CHANGED),
        Queued::HandoffUnavailable => {
            return Err(ApiError::Conflict(
                "This handoff is no longer available for this group.",
            ));
        }
        Queued::AnswerExists => {
            return Err(ApiError::Conflict(
                "An answer is already recorded for this question.",
            ));
        }
    };
    let files = Arc::new(files);
    let task: Arc<str> = body.text.into();
    for delivery in deliveries {
        let w = w.clone();
        let files = files.clone();
        let task = task.clone();
        let group = prompt_group.clone();
        let executable = executable.clone();
        let quote = quote.clone();
        tokio::spawn(async move {
            let result = deliver(
                &w,
                &delivery,
                &files,
                &executable,
                &group,
                &task,
                quote.as_deref(),
            )
            .await;
            let (state, detail) = match &result {
                Ok(delivery) if delivery.started == Some(false) => ("start_not_observed", None),
                Ok(_) => ("sent", None),
                Err(SendError::File(name)) => ("not_sent", Some(name.as_str())),
                Err(SendError::Core(error)) => {
                    let (state, detail) = delivery_failure(error);
                    (
                        match state {
                            crate::history::State::NotSent => "not_sent",
                            _ => "unconfirmed",
                        },
                        detail,
                    )
                }
            };
            if w.history
                .finish_group_delivery(delivery.id, state, detail)
                .is_err()
            {
                eprintln!("SwarmHub could not record a group delivery receipt");
            }
        });
    }
    Ok((StatusCode::ACCEPTED, Json(json!({"id":message_id}))))
}

fn distinct(targets: &[Target]) -> bool {
    let unique: HashSet<_> = targets.iter().collect();
    unique.len() == targets.len()
}

async fn deliver(
    w: &Workspace,
    delivery: &Delivery,
    files: &[Upload],
    executable: &str,
    group: &PromptGroup,
    task: &str,
    quote: Option<&Quote>,
) -> Result<crate::core::Delivery, SendError> {
    let target = &delivery.target;
    let agent = match w.core.agent(&target.address, target.created_ms).await {
        Err(Failure::Rejected(kind, _)) if kind == "not_found" => {
            return Err(Failure::Missing.into());
        }
        other => other?,
    };
    if agent.launch_key() != Some(delivery.launch_key.as_str()) {
        return Err(Failure::Missing.into());
    }
    let mut paths = vec![];
    for file in files {
        let error = || {
            SendError::File(format!(
                "Could not attach {}. The task was not sent.",
                file.name
            ))
        };
        let staged = w
            .core
            .stage_file(&agent, &file.name, &file.data)
            .await
            .map_err(|_| error())?;
        if staged.bytes != file.data.len()
            || staged.path.is_empty()
            || staged.path.chars().any(char::is_control)
        {
            return Err(error());
        }
        paths.push(json!({"name":file.name,"path":staged.path}));
    }
    let context = clean_context(&delivery.context);
    let prompt = prompt(executable, group, delivery, &context, task, &paths, quote);
    let binding =
        crate::group_preview::Binding::new(&delivery.launch_key, delivery.id, &delivery.token);
    Ok(w.send_to_agent_with_group(&agent, prompt, binding).await?)
}

enum SendError {
    Core(Failure),
    File(String),
}

impl From<Failure> for SendError {
    fn from(error: Failure) -> Self {
        Self::Core(error)
    }
}

fn clean_context(context: &str) -> String {
    let clean: String = context
        .chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .collect();
    let mut end = clean.len().min(3_500);
    while !clean.is_char_boundary(end) {
        end -= 1;
    }
    clean[..end].to_owned()
}

struct PromptGroup {
    name: String,
    candidates: Vec<Candidate>,
}

fn prompt(
    exe: &str,
    group: &PromptGroup,
    delivery: &Delivery,
    context: &str,
    task: &str,
    paths: &[serde_json::Value],
    quote: Option<&Quote>,
) -> String {
    let command = format!("{} group-reply {}", shell_quote(exe), delivery.token);
    let files = if paths.is_empty() {
        String::new()
    } else {
        format!(
            "\nAttached files for your session (names and paths):\n{}\n",
            json!(paths)
        )
    };
    let quote = quote
        .map(|row| {
            let kind = if row.is_form {
                "Form"
            } else if row.is_question {
                "Question"
            } else {
                "Message"
            };
            format!(
                "\n{kind} from {} that you are responding to:\n{}\n",
                row.author,
                clean_context(&row.text)
            )
        })
        .unwrap_or_default();
    let destinations: Vec<_> = group
        .candidates
        .iter()
        .filter(|candidate| candidate.address != delivery.target.address)
        .map(Candidate::choice)
        .collect();
    let handoff = if destinations.is_empty() {
        String::new()
    } else {
        format!(
            "\nInstead of a final reply, you may suggest one follow-up for user review: pipe JSON with to and task into {} group-handoff {}. Use one of these recipient names in to: {}. Keep the token out of the task. No handoff is sent without the user’s approval.",
            shell_quote(exe),
            delivery.token,
            json!(destinations)
        )
    };
    let mut message = format!(
        "SwarmHub group: {}\nTask for: {}\nReply to this group by piping your plain-text response to this command:\n{command}\nThis command posts one response for this task. Keep the reply token out of the response.\nOn a longer task, add --draft by itself to post or replace a short progress update for the group. Use only group-appropriate text. This does not use up your final reply.\nAdd --question for a short clarification or --form for structured input. For --form, pipe JSON with a title and 1–6 fields: each has a key (lowercase, digits or underscores), a label, optional required boolean, and optional choices array of strings.\nTo include result files in a plain reply, add --file followed by each file path (up to four files, 8 MiB total).\n\nRecent group messages (context):\n{context}\n{quote}{files}\nCurrent task:\n{task}",
        group.name, delivery.name
    );
    if !handoff.is_empty()
        && message.len() + handoff.len() <= 16_384
        && let Some(index) = message.find("\n\nRecent group messages (context):")
    {
        message.insert_str(index, &handoff);
    }
    message
}
