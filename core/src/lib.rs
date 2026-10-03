pub mod adapters;
pub mod cloud;
pub mod provider;
pub mod runner;
pub mod workflow;

use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComputeBackend {
    AppleMps,
    NvidiaCuda,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskState {
    Pending,
    Running,
    Succeeded,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreRequest {
    pub input: PathBuf,
    pub output: PathBuf,
    pub backend: ComputeBackend,
}

impl RestoreRequest {
    pub fn validate(&self) -> Result<(), &'static str> {
        if !self.input.is_file() {
            return Err("input video does not exist");
        }
        if self.input == self.output {
            return Err("input and output must differ");
        }
        if self.output.exists() {
            return Err("output already exists");
        }
        if self.output.parent().is_some_and(|parent| !parent.is_dir()) {
            return Err("output directory does not exist");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_input() {
        let request = RestoreRequest {
            input: PathBuf::from("/definitely/missing/video.mp4"),
            output: PathBuf::from("/tmp/output.mp4"),
            backend: ComputeBackend::AppleMps,
        };
        assert_eq!(request.validate(), Err("input video does not exist"));
    }
}
