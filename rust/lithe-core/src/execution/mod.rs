//! Run configuration generation, resolution, and project detectors.

mod configuration;
mod detectors;
mod project_metadata;
mod types;

pub(crate) use configuration::*;
pub(crate) use project_metadata::{normalize_project_metadata, ProjectMetadataRequest};
