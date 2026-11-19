use super::*;
use crate::parks::{self, Outcome, Reason, Source, State, tests};
use std::{
    cell::Cell,
    io::Write,
    path::{Path, PathBuf},
};

const REFERENCE: &str = "refs/heads/staging";

pub(crate) struct GitFixture {
    pub directory: PathBuf,
    pub manifest: Manifest,
    pub other: String,
}

impl GitFixture {
    pub(crate) fn new(root: &Path) -> Self {
        let directory = root.join("staging.git");
        Self::read(Self::command(&directory, &["init", "--bare"]).output().unwrap());
        let mut tree = Self::command(&directory, &["mktree"])
            .stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        tree.stdin.take().unwrap().write_all(b"").unwrap();
        let tree = Self::read(tree.wait_with_output().unwrap());
        let commit = |args: &[&str]| Self::read(Self::command(&directory, args).output().unwrap());
        let old = commit(&["commit-tree", &tree, "-m", "fixture old"]);
        let new = commit(&["commit-tree", &tree, "-p", &old, "-m", "fixture reviewed"]);
        let other = commit(&["commit-tree", &tree, "-p", &old, "-m", "fixture concurrent"]);
        let manifest = Manifest {
            operation: Operation::AdvanceStagingRef { reference: REFERENCE.into(), rollback: true },
            precondition: old.clone(),
            expected_postcondition: new.clone(),
            artifact_pin: new,
            apply_pin: APPLY_PIN.into(),
            reverse_pin: REVERSE_PIN.into(),
            ..tests::manifest()
        };
        let git = Self { directory, manifest, other };
        Self::read(git.git(&["update-ref", REFERENCE, &old]));
        git
    }

    fn command(directory: &Path, args: &[&str]) -> Command {
        let mut command = Command::new("/usr/bin/git");
        command.env_clear().env("PATH", "/usr/bin:/bin")
            .env("GIT_CONFIG_NOSYSTEM", "1").env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_AUTHOR_NAME", "Fixture").env("GIT_COMMITTER_NAME", "Fixture")
            .env("GIT_AUTHOR_EMAIL", "fixture@swarmhub.local")
            .env("GIT_COMMITTER_EMAIL", "fixture@swarmhub.local")
            .arg("--git-dir").arg(directory).args(args);
        command
    }

    fn git(&self, args: &[&str]) -> Output {
        Self::command(&self.directory, args).output().unwrap()
    }

    fn read(output: Output) -> String {
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        String::from_utf8(output.stdout).unwrap().trim().into()
    }

    pub(crate) fn head(&self) -> String {
        Self::read(self.git(&["rev-parse", "--verify", REFERENCE]))
    }

    pub(crate) fn set_head(&self, revision: &str) {
        Self::read(self.git(&["update-ref", REFERENCE, revision]));
    }

    pub(crate) fn advance_externally(&self) {
        self.set_head(&self.other);
    }
}

#[test]
fn gapplan_05_unit_staging_git_cas_and_independent_readback() {
    let root = tempfile::tempdir().unwrap();
    let git = GitFixture::new(root.path());
    let adapter = Project::fixture(&git.directory, git.manifest.clone());
    let old = tests::marker(&git.manifest.precondition);
    let new = tests::marker(&git.manifest.expected_postcondition);
    let other = tests::marker(&git.other);
    assert!(adapter.check().is_ok());
    assert_ne!(adapter.apply(&other, &new), Step::Exit(0));
    assert_eq!(git.head(), old.revision);
    assert_eq!(adapter.apply(&old, &new), Step::Exit(0));
    assert_eq!(adapter.observe().unwrap(), new);
    assert_eq!(git.head(), new.revision);
    assert_eq!(adapter.rollback(&new, &old), Step::Exit(0));
    assert_eq!(git.head(), old.revision);

    GitFixture::read(git.git(&["update-ref", "refs/heads/alternate", &old.revision]));
    GitFixture::read(git.git(&["symbolic-ref", REFERENCE, "refs/heads/alternate"]));
    assert_ne!(adapter.apply(&old, &new), Step::Exit(0));
    assert_eq!(git.head(), old.revision);
}

struct LostReadback<'a> {
    adapter: Project,
    git: &'a GitFixture,
    observations: Cell<usize>,
    concurrent_drift: bool,
}

impl Adapter for LostReadback<'_> {
    fn observe(&self) -> io::Result<Marker> {
        let observations = self.observations.get() + 1;
        self.observations.set(observations);
        if observations == 2 { return Err(io::Error::other("fixture lost readback")); }
        self.adapter.observe()
    }
    fn apply(&self, expected: &Marker, replacement: &Marker) -> Step {
        self.adapter.apply(expected, replacement)
    }
    fn rollback(&self, expected: &Marker, replacement: &Marker) -> Step {
        if self.concurrent_drift {
            // Move the ref independently just before the adapter attempts rollback.
            self.git.advance_externally();
        }
        self.adapter.rollback(expected, replacement)
    }
}

pub(crate) fn verify_rollback(concurrent_drift: bool, authorized: bool) {
    let root = tempfile::tempdir().unwrap();
    let mut git = GitFixture::new(root.path());
    let Operation::AdvanceStagingRef { rollback, .. } = &mut git.manifest.operation else { unreachable!() };
    *rollback = authorized;
    let adapter = LostReadback {
        adapter: Project::fixture(&git.directory, git.manifest.clone()),
        git: &git, observations: Cell::new(0), concurrent_drift,
    };
    let history = crate::History::open_at(&root.path().join("journal")).unwrap();
    let mut db = history.db().unwrap();
    let park = parks::file(&db, "rollback-case", &git.manifest).unwrap();
    let unresolved = concurrent_drift || !authorized;
    let receipt = tests::receipt(
        parks::execute(&mut db, &park, tests::decision(Source::Human), &adapter).unwrap(),
        if unresolved { State::Reconciliation } else { State::Failed },
    );
    assert_eq!(receipt.reason, Some(Reason::VerificationFailed));
    assert_eq!(receipt.apply, Some(Step::Exit(0)));
    assert_eq!(receipt.outcome, if unresolved { Outcome::Reconciliation } else { Outcome::Failed });
    if authorized {
        let rollback = receipt.rollback.unwrap();
        let expected = if concurrent_drift { &git.other } else { &git.manifest.precondition };
        assert_eq!(&git.head(), expected);
        assert_eq!(&rollback.after.unwrap().revision, expected);
        assert_eq!(rollback.step == Some(Step::Exit(0)), !concurrent_drift);
    } else {
        assert!(receipt.rollback.is_none());
        assert_eq!(git.head(), git.manifest.expected_postcondition);
    }
}
