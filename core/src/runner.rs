use crate::provider::{
    ProgressUpdate, RestorationProvider, RestoreControl, RestoreError, RestoreErrorKind,
    RestoreResult, execute_with,
};
use crate::{RestoreRequest, TaskState};

pub fn run_restore(
    provider: &dyn RestorationProvider,
    request: &RestoreRequest,
    control: &RestoreControl<'_>,
) -> Result<RestoreResult, RestoreError> {
    control.progress.report(ProgressUpdate {
        percent: 0,
        state: TaskState::Pending,
        stage: "accepted",
    });

    if control.cancellation.is_cancelled() {
        return cancelled(control);
    }

    control.progress.report(ProgressUpdate {
        percent: 1,
        state: TaskState::Running,
        stage: "validating",
    });

    match execute_with(provider, request, control) {
        Ok(result) => {
            control.progress.report(ProgressUpdate {
                percent: 100,
                state: TaskState::Succeeded,
                stage: "completed",
            });
            Ok(result)
        }
        Err(error) => {
            let state = if error.kind == RestoreErrorKind::Cancelled {
                TaskState::Cancelled
            } else {
                TaskState::Failed
            };
            control.progress.report(ProgressUpdate {
                percent: 100,
                state,
                stage: if state == TaskState::Cancelled {
                    "cancelled"
                } else {
                    "failed"
                },
            });
            Err(error)
        }
    }
}

fn cancelled(control: &RestoreControl<'_>) -> Result<RestoreResult, RestoreError> {
    control.progress.report(ProgressUpdate {
        percent: 0,
        state: TaskState::Cancelled,
        stage: "cancelled",
    });
    Err(RestoreError::new(
        RestoreErrorKind::Cancelled,
        "restore cancelled",
    ))
}
