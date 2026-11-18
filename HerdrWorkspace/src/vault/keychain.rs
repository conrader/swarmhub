//! Generic-password items in the bridge user's macOS Keychain. The journal
//! keeps only a reference. Each write uses a fresh account until SQLite commits.
use crate::history::StoreError;
use ring::digest;
use std::{ffi::c_void, fmt::Write, os::unix::ffi::OsStrExt, path::Path, ptr};

pub(super) const MARKER: &[u8] = b"mac-keychain/v1";

#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    fn SecKeychainAddGenericPassword(
        keychain: *const c_void,
        service_len: u32,
        service: *const u8,
        account_len: u32,
        account: *const u8,
        password_len: u32,
        password: *const u8,
        item: *mut *mut c_void,
    ) -> i32;
    fn SecKeychainFindGenericPassword(
        keychain: *const c_void,
        service_len: u32,
        service: *const u8,
        account_len: u32,
        account: *const u8,
        password_len: *mut u32,
        password: *mut *mut c_void,
        item: *mut *mut c_void,
    ) -> i32;
    fn SecKeychainItemFreeContent(attributes: *const c_void, data: *mut c_void) -> i32;
    fn SecKeychainItemDelete(item: *const c_void) -> i32;
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(reference: *const c_void);
}

#[derive(Clone)]
pub(super) struct Keychain(String);

impl Keychain {
    pub(super) fn for_workspace(journal: &Path) -> Self {
        let directory = journal.parent().unwrap_or(journal);
        let canonical = directory
            .canonicalize()
            .unwrap_or_else(|_| directory.to_owned());
        let hash = digest::digest(&digest::SHA256, canonical.as_os_str().as_bytes());
        Self(format!("com.swarmhub.herdr.vault.{}", hex(hash.as_ref())))
    }

    pub(super) fn service(&self) -> &str {
        &self.0
    }

    pub(super) fn add(&self, id: &str, nonce: &[u8], value: &[u8]) -> Result<String, StoreError> {
        let account = account(id, nonce);
        // Null keychain selects the current user's default keychain.
        let status = unsafe {
            SecKeychainAddGenericPassword(
                ptr::null(),
                self.0.len() as u32,
                self.0.as_ptr(),
                account.len() as u32,
                account.as_ptr(),
                value.len() as u32,
                value.as_ptr(),
                ptr::null_mut(),
            )
        };
        if status == 0 {
            Ok(account)
        } else {
            Err(StoreError)
        }
    }

    pub(super) fn read(&self, id: &str, nonce: &[u8]) -> Result<String, StoreError> {
        let account = account(id, nonce);
        let mut len = 0;
        let mut data = ptr::null_mut();
        let status = unsafe {
            SecKeychainFindGenericPassword(
                ptr::null(),
                self.0.len() as u32,
                self.0.as_ptr(),
                account.len() as u32,
                account.as_ptr(),
                &mut len,
                &mut data,
                ptr::null_mut(),
            )
        };
        if status != 0 || data.is_null() {
            return Err(StoreError);
        }
        // Security.framework owns this allocation until SecKeychainItemFreeContent.
        unsafe {
            let bytes = std::slice::from_raw_parts(data.cast::<u8>(), len as usize);
            let decoded = std::str::from_utf8(bytes)
                .map(str::to_owned)
                .map_err(|_| StoreError);
            SecKeychainItemFreeContent(ptr::null(), data);
            decoded
        }
    }

    pub(super) fn remove(&self, account: &str) -> Result<(), StoreError> {
        let mut item = ptr::null_mut();
        unsafe {
            let status = SecKeychainFindGenericPassword(
                ptr::null(),
                self.0.len() as u32,
                self.0.as_ptr(),
                account.len() as u32,
                account.as_ptr(),
                ptr::null_mut(),
                ptr::null_mut(),
                &mut item,
            );
            const ITEM_NOT_FOUND: i32 = -25300;
            if status == ITEM_NOT_FOUND {
                return Ok(());
            }
            if status != 0 || item.is_null() {
                return Err(StoreError);
            }
            let status = SecKeychainItemDelete(item);
            CFRelease(item);
            if status == 0 || status == ITEM_NOT_FOUND {
                Ok(())
            } else {
                Err(StoreError)
            }
        }
    }
}

pub(super) fn account(id: &str, nonce: &[u8]) -> String {
    format!("{id}.{}", hex(nonce))
}

fn hex(bytes: &[u8]) -> String {
    let mut result = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(result, "{byte:02x}");
    }
    result
}
