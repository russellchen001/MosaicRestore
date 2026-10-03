use crate::{ComputeBackend, RestoreRequest, TaskState};
use std::fmt;
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreResult {
    pub output: PathBuf,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestoreErrorKind {
    InvalidRequest,
    UnsupportedBackend,
    ProviderUnavailable,
    ExecutionFailed,
    OutputMissing,
    Cancelled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreError {
    pub kind: RestoreErrorKind,
    pub message: String,
}

impl RestoreError {
    pub fn new(kind: RestoreErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }
}

impl fmt::Display for RestoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}", self.message)
    }
}

impl std::error::Error for RestoreError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProgressUpdate {
    pub percent: u8,
    pub state: TaskState,
    pub stage: &'static str,
}

pub trait ProgressReporter: Send + Sync {
    fn report(&self, update: ProgressUpdate);
}

impl<F> ProgressReporter for F
where
    F: Fn(ProgressUpdate) + Send + Sync,
{
    fn report(&self, update: ProgressUpdate) {
        self(update);
    }
}

#[derive(Debug, Clone, Default)]
pub struct CancellationToken(Arc<AtomicBool>);

impl CancellationToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

pub struct RestoreControl<'a> {
    pub cancellation: &'a CancellationToken,
    pub progress: &'a dyn ProgressReporter,
}

pub trait RestorationProvider {
    fn name(&self) -> &'static str;

    fn supports(&self, backend: ComputeBackend) -> bool;

    fn restore(
        &self,
        request: &RestoreRequest,
        control: &RestoreControl<'_>,
    ) -> Result<RestoreResult, RestoreError>;
}

pub fn execute_with(
    provider: &dyn RestorationProvider,
    request: &RestoreRequest,
    control: &RestoreControl<'_>,
) -> Result<RestoreResult, RestoreError> {
    request
        .validate()
        .map_err(|message| RestoreError::new(RestoreErrorKind::InvalidRequest, message))?;

    if !provider.supports(request.backend) {
        return Err(RestoreError::new(
            RestoreErrorKind::UnsupportedBackend,
            "provider does not support requested backend",
        ));
    }
    if control.cancellation.is_cancelled() {
        return Err(RestoreError::new(
            RestoreErrorKind::Cancelled,
            "restore cancelled",
        ));
    }

    provider.restore(request, control)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct MpsOnlyProvider;
    const NO_PROGRESS: fn(ProgressUpdate) = |_| {};

    impl RestorationProvider for MpsOnlyProvider {
        fn name(&self) -> &'static str {
            "mock-mps"
        }

        fn supports(&self, backend: ComputeBackend) -> bool {
            backend == ComputeBackend::AppleMps
        }

        fn restore(
            &self,
            request: &RestoreRequest,
            _control: &RestoreControl<'_>,
        ) -> Result<RestoreResult, RestoreError> {
            Ok(RestoreResult {
                output: request.output.clone(),
            })
        }
    }

    fn make_input_file(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(name);
        fs::write(&path, b"test").expect("create temporary input");
        path
    }

    #[test]
    fn executes_supported_backend() {
        let input = make_input_file("mosaic_core_supported_input.mp4");
        let output = std::env::temp_dir().join("mosaic_core_supported_output.mp4");

        let request = RestoreRequest {
            input: input.clone(),
            output: output.clone(),
            backend: ComputeBackend::AppleMps,
        };

        let cancellation = CancellationToken::new();
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &NO_PROGRESS,
        };
        let result = execute_with(&MpsOnlyProvider, &request, &control)
            .expect("supported backend should execute");

        assert_eq!(result.output, output);

        let _ = fs::remove_file(input);
    }

    #[test]
    fn rejects_unsupported_backend() {
        let input = make_input_file("mosaic_core_unsupported_input.mp4");
        let output = std::env::temp_dir().join("mosaic_core_unsupported_output.mp4");

        let request = RestoreRequest {
            input: input.clone(),
            output,
            backend: ComputeBackend::NvidiaCuda,
        };

        let cancellation = CancellationToken::new();
        let control = RestoreControl {
            cancellation: &cancellation,
            progress: &NO_PROGRESS,
        };
        let result = execute_with(&MpsOnlyProvider, &request, &control);

        assert_eq!(
            result.unwrap_err().kind,
            RestoreErrorKind::UnsupportedBackend
        );

        let _ = fs::remove_file(input);
    }
}
