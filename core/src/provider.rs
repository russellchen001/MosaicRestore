use crate::{ComputeBackend, RestoreRequest};
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreResult {
    pub output: PathBuf,
}

pub trait RestorationProvider {
    fn name(&self) -> &'static str;

    fn supports(&self, backend: ComputeBackend) -> bool;

    fn restore(
        &self,
        request: &RestoreRequest,
    ) -> Result<RestoreResult, &'static str>;
}

pub fn execute_with<P: RestorationProvider>(
    provider: &P,
    request: &RestoreRequest,
) -> Result<RestoreResult, &'static str> {
    request.validate()?;

    if !provider.supports(request.backend) {
        return Err("provider does not support requested backend");
    }

    provider.restore(request)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct MpsOnlyProvider;

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
        ) -> Result<RestoreResult, &'static str> {
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

        let result =
            execute_with(&MpsOnlyProvider, &request).expect("supported backend should execute");

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

        let result = execute_with(&MpsOnlyProvider, &request);

        assert_eq!(
            result,
            Err("provider does not support requested backend")
        );

        let _ = fs::remove_file(input);
    }
}
