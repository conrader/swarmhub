//! The bridge reads public evidence from a separate operator account. The journal
//! and session environment cannot supply the trust root or publication generation.

use super::{
    Actor, Error, PolicyRef, Principal, Publication, Published, Purpose, Signed, Target, principals,
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use rustix::fs::{Dir, Mode, OFlags, openat};
use serde::{Deserialize, de::DeserializeOwned};
use std::{
    fs::{File, TryLockError},
    io::Read,
    os::unix::fs::MetadataExt,
    path::{Component, PathBuf},
};

pub(super) const LIMIT: usize = 128 * 1024;
const DIRECTORY: OFlags = OFlags::RDONLY
    .union(OFlags::DIRECTORY)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);
const READ: OFlags = OFlags::RDONLY
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC)
    .union(OFlags::NONBLOCK);

#[derive(Clone)]
pub(crate) struct Authority {
    directory: PathBuf,
    workspace: String,
    operator_uid: u32,
    #[cfg(test)]
    fixture: bool,
}

#[derive(Clone, Copy)]
pub(crate) enum Role {
    Bridge,
    Operator,
    Inspect,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Enrollment {
    workspace: String,
    operator_key: String,
    delegate: Option<Delegate>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Delegate {
    bot_id: String,
    key: String,
}

pub(super) struct Trust {
    pub(super) workspace: String,
    pub(super) operator_key: [u8; 32],
    delegate: Option<(String, [u8; 32])>,
}

impl Trust {
    fn enrolled(enrollment: Enrollment, workspace: &str) -> Result<Self, Error> {
        fn key(encoded: &str) -> Result<[u8; 32], Error> {
            STANDARD
                .decode(encoded)
                .map_err(|_| Error::Invalid)?
                .try_into()
                .map_err(|_| Error::Invalid)
        }

        if enrollment.workspace != workspace {
            return Err(Error::Binding);
        }
        let operator_key = key(&enrollment.operator_key)?;
        let delegate = enrollment
            .delegate
            .map(|delegate| {
                let public_key = key(&delegate.key)?;
                if !crate::bots::valid_id(&delegate.bot_id) || public_key == operator_key {
                    return Err(Error::Invalid);
                }
                Ok((delegate.bot_id, public_key))
            })
            .transpose()?;
        Ok(Self {
            workspace: enrollment.workspace,
            operator_key,
            delegate,
        })
    }

    pub(super) fn delegate_key(&self, actor: &Actor) -> Result<&[u8; 32], Error> {
        match (&self.delegate, actor) {
            (Some((bot, key)), Actor::Bot { id }) if bot == id => Ok(key),
            _ => Err(Error::Principal),
        }
    }
}

pub(super) struct Snapshot<'a> {
    authority: &'a Authority,
    directory: File,
    pub(super) trust: Trust,
}

impl Authority {
    pub(crate) fn configured(role: Role) -> Result<Option<Self>, Error> {
        let directory = std::env::var_os("SWARMHUB_FLEET_POLICY_DIR");
        let workspace = std::env::var_os("SWARMHUB_FLEET_WORKSPACE");
        let operator = std::env::var_os("SWARMHUB_FLEET_OPERATOR_UID");
        let (directory, workspace, operator_uid) = match (directory, workspace, operator) {
            (None, None, None) => return Ok(None),
            (Some(directory), Some(workspace), Some(operator)) => (
                PathBuf::from(directory),
                workspace.into_string().map_err(|_| Error::Invalid)?,
                operator
                    .to_str()
                    .and_then(|uid| uid.parse::<u32>().ok())
                    .ok_or(Error::Invalid)?,
            ),
            _ => return Err(Error::Invalid),
        };
        if !directory.is_absolute() || !principals::identifier(&workspace) || operator_uid == 0 {
            return Err(Error::Invalid);
        }
        let authority = Self {
            directory,
            workspace,
            operator_uid,
            #[cfg(test)]
            fixture: false,
        };
        authority.check_role(role)?;
        Ok(Some(authority))
    }

    fn check_role(&self, role: Role) -> Result<(), Error> {
        #[cfg(test)]
        if self.fixture {
            return Ok(());
        }
        // Root would bypass the operator's file protections. The server and the
        // operator CLI must run as ordinary users, under distinct identities.
        let uid = unsafe { libc::getuid() };
        let effective = unsafe { libc::geteuid() };
        let allowed = match role {
            Role::Bridge => uid != self.operator_uid,
            Role::Operator => uid == self.operator_uid,
            Role::Inspect => true,
        };
        if uid == 0 || uid != effective || !allowed {
            return Err(Error::Unavailable);
        }
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn fixture(directory: &std::path::Path, workspace: &str) -> Self {
        Self {
            directory: directory.canonicalize().unwrap(),
            workspace: workspace.to_owned(),
            operator_uid: unsafe { libc::getuid() },
            fixture: true,
        }
    }

    fn open_directory(&self) -> Result<File, Error> {
        let mut parts = self.directory.components();
        if parts.next() != Some(Component::RootDir) {
            return Err(Error::Unavailable);
        }
        let mut directory = File::open("/").map_err(|_| Error::Unavailable)?;
        self.protect(&directory, true)?;
        for part in parts {
            let Component::Normal(name) = part else {
                return Err(Error::Unavailable);
            };
            directory = File::from(
                openat(&directory, name, DIRECTORY, Mode::empty())
                    .map_err(|_| Error::Unavailable)?,
            );
            self.protect(&directory, true)?;
        }
        self.protect(&directory, false)?;
        Ok(directory)
    }

    /// Walk from a trusted ancestor with no symlink traversal. Even an otherwise
    /// valid file under a replaceable parent cannot act as a trust root.
    fn protect(&self, file: &File, ancestor: bool) -> Result<(), Error> {
        let metadata = file.metadata().map_err(|_| Error::Unavailable)?;
        let mode = metadata.mode();
        let root_sticky = ancestor && metadata.uid() == 0 && mode & 0o1000 != 0;
        if !(metadata.uid() == self.operator_uid || ancestor && metadata.uid() == 0)
            || (mode & 0o022 != 0 && !root_sticky)
            || (!metadata.is_dir() && (!metadata.is_file() || metadata.nlink() != 1))
            || has_extra_acl(file)?
        {
            return Err(Error::Unavailable);
        }
        Ok(())
    }

    fn snapshot<T>(
        &self,
        role: Role,
        action: impl FnOnce(&Snapshot<'_>) -> Result<T, Error>,
    ) -> Result<T, Error> {
        self.check_role(role)?;
        let directory = self.open_directory()?;
        let exclusive = matches!(role, Role::Operator);
        let flags = if exclusive {
            READ.difference(OFlags::RDONLY).union(OFlags::RDWR)
        } else {
            READ
        };
        let lock = self
            .open_file(&directory, "policy.lock", flags)?
            .ok_or(Error::Unavailable)?;
        let locked = if exclusive {
            lock.try_lock()
        } else {
            lock.try_lock_shared()
        };
        locked.map_err(|error| match error {
            TryLockError::WouldBlock => Error::Busy,
            TryLockError::Error(_) => Error::Unavailable,
        })?;
        let enrollment = self
            .read(&directory, "trust.json")?
            .ok_or(Error::Unavailable)?;
        let trust = Trust::enrolled(enrollment, &self.workspace)?;
        action(&Snapshot {
            authority: self,
            directory,
            trust,
        })
    }

    pub(super) fn with_snapshot<T>(
        &self,
        action: impl FnOnce(&Snapshot<'_>) -> Result<T, Error>,
    ) -> Result<T, Error> {
        self.snapshot(Role::Bridge, action)
    }

    pub(super) fn inspect_snapshot<T>(
        &self,
        action: impl FnOnce(&Snapshot<'_>) -> Result<T, Error>,
    ) -> Result<T, Error> {
        self.snapshot(Role::Inspect, action)
    }

    fn open_file(&self, directory: &File, name: &str, flags: OFlags) -> Result<Option<File>, Error> {
        let file = match openat(directory, name, flags, Mode::empty()) {
            Ok(file) => File::from(file),
            Err(rustix::io::Errno::NOENT) => return Ok(None),
            Err(_) => return Err(Error::Unavailable),
        };
        if !file.metadata().map_err(|_| Error::Unavailable)?.is_file() {
            return Err(Error::Unavailable);
        }
        self.protect(&file, false)?;
        Ok(Some(file))
    }

    fn read<T: DeserializeOwned>(&self, directory: &File, name: &str) -> Result<Option<T>, Error> {
        let Some(file) = self.open_file(directory, name, READ)? else {
            return Ok(None);
        };
        let mut bytes = Vec::new();
        file.take(LIMIT as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Unavailable)?;
        if bytes.len() > LIMIT {
            return Err(Error::Invalid);
        }
        serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| Error::Invalid)
    }

    pub(super) fn import_policy(&self, publication: Publication) -> Result<PolicyRef, Error> {
        self.snapshot(Role::Operator, |snapshot| {
            let now = crate::history::now();
            let reference = publication.verify(&snapshot.trust, now)?;
            if let Some(previous) = snapshot.generations()?.last() {
                let (current, stored) = snapshot.version(*previous)?;
                if current == reference && stored.publication.signed == publication.signed {
                    return Ok(current);
                }
                if current.generation.checked_add(1) != Some(reference.generation) {
                    return Err(Error::StalePolicy);
                }
                if !publication.policy.revoked.is_superset(&stored.publication.policy.revoked) {
                    return Err(Error::Invalid);
                }
            } else if reference.generation != 1 {
                return Err(Error::StalePolicy);
            }
            let name = policy_name(reference.generation);
            snapshot.publish(
                &name,
                &Published {
                    published_ms: now,
                    publication,
                },
            )?;
            Ok(reference)
        })
    }

    pub(super) fn import_decision(&self, signed: Signed) -> Result<String, Error> {
        self.snapshot(Role::Operator, |snapshot| {
            let (current, _) = snapshot.current()?;
            signed.verify(
                &snapshot.trust.operator_key,
                &snapshot.trust.workspace,
                crate::history::now(),
            )?;
            match &signed.envelope.target {
                Target::Park { policy, .. } | Target::Supersession { policy, .. }
                    if signed.envelope.principal == Principal::Operator => {
                    if *policy != current {
                        return Err(Error::StalePolicy);
                    }
                }
                _ => return Err(Error::Binding),
            }
            let nonce = &signed.envelope.nonce;
            let name = decision_name(nonce);
            match self.read::<Signed>(&snapshot.directory, &name)? {
                Some(existing) if existing == signed => {}
                Some(_) => return Err(Error::Binding),
                None => snapshot.publish(&name, &signed)?,
            }
            Ok(nonce.clone())
        })
    }
}

impl Snapshot<'_> {
    pub(super) fn generations(&self) -> Result<Vec<i64>, Error> {
        let entries = Dir::read_from(&self.directory).map_err(|_| Error::Unavailable)?;
        let mut versions = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|_| Error::Unavailable)?;
            let name = entry.file_name().to_str().map_err(|_| Error::Invalid)?;
            if let Some(rest) = name.strip_prefix("policy-") {
                let generation = rest
                    .strip_suffix(".json")
                    .and_then(|number| number.parse::<i64>().ok())
                    .filter(|number| *number > 0 && policy_name(*number) == name)
                    .ok_or(Error::Invalid)?;
                versions.push(generation);
            }
        }
        versions.sort_unstable();
        for (index, version) in versions.iter().enumerate() {
            if *version != index as i64 + 1 {
                return Err(Error::Invalid);
            }
        }
        Ok(versions)
    }

    pub(super) fn version(&self, generation: i64) -> Result<(PolicyRef, Published), Error> {
        let stored: Published = self
            .authority
            .read(&self.directory, &policy_name(generation))?
            .ok_or(Error::Unavailable)?;
        // Expiry bounds the publication operation. The signed rule intervals govern
        // how long the resulting generation can grant authority.
        let reference = stored.publication.verify(&self.trust, stored.published_ms)?;
        if reference.generation != generation || stored.published_ms > crate::history::now() {
            return Err(Error::Invalid);
        }
        Ok((reference, stored))
    }

    pub(super) fn current(&self) -> Result<(PolicyRef, Published), Error> {
        let latest = self.generations()?.pop().ok_or(Error::Unavailable)?;
        self.version(latest)
    }

    pub(super) fn operator_decision(&self, nonce: &str) -> Result<Signed, Error> {
        if !principals::identifier(nonce) {
            return Err(Error::Invalid);
        }
        let decision: Signed = self
            .authority
            .read(&self.directory, &decision_name(nonce))?
            .ok_or(Error::Unavailable)?;
        if decision.envelope.nonce != nonce
            || decision.envelope.principal != Principal::Operator
            || decision.envelope.purpose == Purpose::PublishPolicy
        {
            return Err(Error::Binding);
        }
        Ok(decision)
    }

    fn publish(&self, name: &str, document: &impl serde::Serialize) -> Result<(), Error> {
        use std::io::Write as _;
        use std::os::unix::fs::PermissionsExt as _;

        let bytes = serde_json::to_vec(document).map_err(|_| Error::Invalid)?;
        if bytes.len() > LIMIT {
            return Err(Error::Invalid);
        }
        let folder = &self.authority.directory;
        let mut file = tempfile::NamedTempFile::new_in(folder).map_err(|_| Error::Unavailable)?;
        file.write_all(&bytes).map_err(|_| Error::Unavailable)?;
        file.as_file()
            .set_permissions(std::fs::Permissions::from_mode(0o644))
            .map_err(|_| Error::Unavailable)?;
        file.as_file().sync_all().map_err(|_| Error::Unavailable)?;
        file.persist_noclobber(folder.join(name))
            .map_err(|_| Error::Unavailable)?;
        self.directory.sync_all().map_err(|_| Error::Unavailable)?;
        Ok(())
    }
}

fn policy_name(generation: i64) -> String {
    format!("policy-{generation}.json")
}

fn decision_name(nonce: &str) -> String {
    format!("decision-{nonce}.json")
}

// macOS extended ACLs can grant write access independently of the POSIX mode.
// Require an ACL-free store and ancestry. On Linux the mode check already
// covers the POSIX ACL write mask.
#[cfg(target_os = "macos")]
fn has_extra_acl(file: &File) -> Result<bool, Error> {
    use std::os::fd::AsRawFd as _;
    unsafe extern "C" {
        fn acl_get_fd_np(fd: libc::c_int, kind: libc::c_int) -> *mut libc::c_void;
        fn acl_free(acl: *mut libc::c_void) -> libc::c_int;
    }
    const ACL_TYPE_EXTENDED: libc::c_int = 0x100;
    let acl = unsafe { acl_get_fd_np(file.as_raw_fd(), ACL_TYPE_EXTENDED) };
    if !acl.is_null() {
        unsafe { acl_free(acl) };
        return Ok(true);
    }
    match std::io::Error::last_os_error().raw_os_error() {
        Some(libc::ENOENT) => Ok(false),
        _ => Err(Error::Unavailable),
    }
}

#[cfg(target_os = "linux")]
fn has_extra_acl(_: &File) -> Result<bool, Error> {
    Ok(false)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn has_extra_acl(_: &File) -> Result<bool, Error> {
    Err(Error::Unavailable)
}
