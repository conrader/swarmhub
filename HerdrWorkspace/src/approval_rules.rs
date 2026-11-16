//! Temporary, exact-read approvals. Rules do not modify runtime policy.
use crate::history::now;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use tokio::sync::Semaphore;

const LIFETIME: Duration = Duration::from_secs(3600);
const MAX_RULES: usize = 24;
static CHECKS: Semaphore = Semaphore::const_new(4);

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct ExactRead {
    cwd: PathBuf,
    path: PathBuf,
    identity: (u64, u64, u64, i64, i64, i64, i64),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Resources {
    resources: Vec<String>,
}

fn literal(value: &str) -> bool {
    !value.is_empty()
        && !value.contains(['*', '?', '[', ']', '{', '}'])
        && !value.chars().any(|c| {
            c.is_control()
                || matches!(c, '\u{061c}' | '\u{200b}'..='\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{feff}')
        })
}

fn canonical(path: &Path) -> Option<PathBuf> {
    if !path.is_absolute() {
        return None;
    }
    let resolved = fs::canonicalize(path).ok()?;
    (resolved.as_os_str() == path.as_os_str()).then_some(resolved)
}

fn identify(cwd: &Path, file: &Path) -> Option<ExactRead> {
    let cwd = canonical(cwd)?;
    let path = canonical(file)?;
    if cwd.parent().is_none() || path == cwd || !path.starts_with(&cwd) {
        return None;
    }
    let stat = fs::symlink_metadata(&path).ok()?;
    if !stat.file_type().is_file() {
        return None;
    }
    Some(ExactRead {
        cwd,
        path,
        identity: (
            stat.dev(),
            stat.ino(),
            stat.size(),
            stat.mtime(),
            stat.mtime_nsec(),
            stat.ctime(),
            stat.ctime_nsec(),
        ),
    })
}

async fn check(cwd: PathBuf, path: PathBuf) -> Option<ExactRead> {
    let slot = CHECKS.try_acquire().ok()?;
    tokio::time::timeout(
        Duration::from_secs(1),
        tokio::task::spawn_blocking(move || {
            let _slot = slot;
            identify(&cwd, &path)
        }),
    )
    .await
    .ok()?
    .ok()?
}

impl ExactRead {
    pub(crate) async fn from_request(cwd: &str, input: &str) -> Option<Self> {
        let args: Resources = serde_json::from_str(input).ok()?;
        let [path] = args.resources.as_slice() else {
            return None;
        };
        if !literal(cwd) || !literal(path) {
            return None;
        }
        check(cwd.into(), path.into()).await
    }

    pub(crate) async fn unchanged(&self) -> bool {
        check(self.cwd.clone(), self.path.clone()).await.as_ref() == Some(self)
    }
}

#[derive(Clone, Serialize)]
pub(crate) struct RuleView {
    pub(crate) id: i64,
    agent: String,
    path: String,
    expires_ms: i64,
}

struct Rule {
    view: RuleView,
    launch: String,
    session: String,
    read: ExactRead,
    until: Instant,
}

#[derive(Default)]
pub(crate) struct Rules(BTreeMap<i64, Rule>);

impl Rules {
    fn expire(&mut self) {
        let now = Instant::now();
        self.0.retain(|_, rule| rule.until > now);
    }

    pub(crate) fn remember(
        &mut self,
        id: i64,
        launch: String,
        session: String,
        agent: String,
        read: ExactRead,
    ) {
        self.expire();
        self.0.retain(|_, rule| {
            !(rule.launch == launch && rule.session == session && rule.read == read)
        });
        if self.0.len() >= MAX_RULES {
            return;
        }
        let view = RuleView {
            id,
            agent,
            path: read.path.to_string_lossy().into_owned(),
            expires_ms: now() + 3_600_000,
        };
        self.0.insert(
            id,
            Rule {
                view,
                launch,
                session,
                read,
                until: Instant::now() + LIFETIME,
            },
        );
    }

    pub(crate) fn applicable(
        &mut self,
        launch: &str,
        session: &str,
        read: &ExactRead,
    ) -> Option<i64> {
        self.expire();
        self.0
            .values()
            .find(|rule| rule.launch == launch && rule.session == session && &rule.read == read)
            .map(|rule| rule.view.id)
    }

    pub(crate) fn list(&mut self) -> Vec<RuleView> {
        self.expire();
        self.0
            .values()
            .rev()
            .map(|rule| rule.view.clone())
            .collect()
    }

    pub(crate) fn revoke(&mut self, id: i64) -> bool {
        self.expire();
        self.0.remove(&id).is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn exact_rule_rejects_other_launches_changed_files_and_aliases() {
        let dir = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(dir.path()).unwrap();
        let file = root.join("notes");
        fs::write(&file, "before").unwrap();
        let candidate = |path: &Path| serde_json::json!({"resources":[path]}).to_string();
        let cwd = root.to_str().unwrap();
        let read = ExactRead::from_request(cwd, &candidate(&file))
            .await
            .unwrap();
        let mut rules = Rules::default();
        rules.remember(
            1,
            "first".into(),
            "ses_primary".into(),
            "Researcher".into(),
            read.clone(),
        );
        assert_eq!(rules.applicable("first", "ses_primary", &read), Some(1));
        assert_eq!(rules.applicable("second", "ses_primary", &read), None);
        assert_eq!(rules.applicable("first", "ses_child", &read), None);
        let link = root.join("alias");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(
            ExactRead::from_request(cwd, &candidate(&link))
                .await
                .is_none()
        );
        assert!(
            ExactRead::from_request(cwd, &candidate(&root))
                .await
                .is_none()
        );
        let sibling = tempfile::NamedTempFile::new().unwrap();
        let outside = fs::canonicalize(sibling.path()).unwrap();
        assert!(
            ExactRead::from_request(cwd, &candidate(&outside))
                .await
                .is_none()
        );
        fs::write(&file, "after changing this file").unwrap();
        assert!(!read.unchanged().await);
        let updated = ExactRead::from_request(cwd, &candidate(&file))
            .await
            .unwrap();
        assert_eq!(rules.applicable("first", "ses_primary", &updated), None);
        rules.0.get_mut(&1).unwrap().until = Instant::now();
        assert_eq!(rules.applicable("first", "ses_primary", &read), None);
        assert!(rules.list().is_empty());
    }
}
