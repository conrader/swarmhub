//! Workload entries use a separate executor Vault and never belong to a launch.
const FIXTURE_ENTRY: &str = "SWARMHUB_WORKLOAD_FIXTURE";

pub(super) fn reserved_name(name: &str) -> bool {
    name.eq_ignore_ascii_case(FIXTURE_ENTRY)
}

#[cfg(test)]
mod fixture;
#[cfg(test)]
pub(crate) use fixture::*;

#[cfg(test)]
pub(crate) mod outbound;
