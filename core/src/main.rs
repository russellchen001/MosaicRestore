use mosaic_core::adapters::{LocalLadaProvider, NvidiaJasnaProvider};
use mosaic_core::provider::{CancellationToken, RestorationProvider, RestoreControl};
use mosaic_core::runner::run_restore;
use mosaic_core::{ComputeBackend, RestoreRequest};
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

struct Options {
    provider: String,
    input: PathBuf,
    output: PathBuf,
    provider_root: Option<PathBuf>,
    runner: Option<PathBuf>,
    cancel_file: Option<PathBuf>,
}

fn main() {
    let options = match parse_options() {
        Ok(options) => options,
        Err(message) => {
            eprintln!("FAIL P1 restore — {message}");
            print_usage();
            std::process::exit(2);
        }
    };

    let cancellation = CancellationToken::new();
    if let Some(cancel_file) = options.cancel_file.clone() {
        let watcher = cancellation.clone();
        thread::spawn(move || {
            loop {
                if cancel_file.exists() {
                    watcher.cancel();
                    break;
                }
                thread::sleep(Duration::from_millis(100));
            }
        });
    }

    let (provider, backend): (Box<dyn RestorationProvider>, ComputeBackend) =
        match options.provider.as_str() {
            "local-lada" => {
                let root = options.provider_root.unwrap_or_else(default_lada_root);
                (
                    Box::new(LocalLadaProvider::from_root(root)),
                    ComputeBackend::AppleMps,
                )
            }
            "nvidia-jasna" => {
                let runner = options
                    .runner
                    .or_else(|| std::env::var_os("MOSAIC_JASNA_RUNNER").map(PathBuf::from));
                let Some(runner) = runner else {
                    eprintln!(
                        "FAIL P1 restore — nvidia-jasna requires --runner or MOSAIC_JASNA_RUNNER"
                    );
                    std::process::exit(2);
                };
                (
                    Box::new(NvidiaJasnaProvider::new(runner)),
                    ComputeBackend::NvidiaCuda,
                )
            }
            value => {
                eprintln!("FAIL P1 restore — unknown provider: {value}");
                std::process::exit(2);
            }
        };

    let request = RestoreRequest {
        input: options.input,
        output: options.output,
        backend,
    };
    let reporter = |update: mosaic_core::provider::ProgressUpdate| {
        println!("{}% {:?} {}", update.percent, update.state, update.stage);
    };
    let control = RestoreControl {
        cancellation: &cancellation,
        progress: &reporter,
    };

    match run_restore(provider.as_ref(), &request, &control) {
        Ok(result) => println!("PASS P1 restore — {}", result.output.display()),
        Err(error) => {
            eprintln!("FAIL P1 restore — {:?}: {}", error.kind, error);
            std::process::exit(1);
        }
    }
}

fn parse_options() -> Result<Options, String> {
    let mut provider = None;
    let mut input = None;
    let mut output = None;
    let mut provider_root = None;
    let mut runner = None;
    let mut cancel_file = None;
    let mut arguments = std::env::args().skip(1);

    while let Some(argument) = arguments.next() {
        let value = match argument.as_str() {
            "--provider" | "--input" | "--output" | "--provider-root" | "--runner"
            | "--cancel-file" => arguments
                .next()
                .ok_or_else(|| format!("missing value for {argument}"))?,
            "--help" | "-h" => {
                print_usage();
                std::process::exit(0);
            }
            _ => return Err(format!("unknown argument: {argument}")),
        };
        match argument.as_str() {
            "--provider" => provider = Some(value),
            "--input" => input = Some(PathBuf::from(value)),
            "--output" => output = Some(PathBuf::from(value)),
            "--provider-root" => provider_root = Some(PathBuf::from(value)),
            "--runner" => runner = Some(PathBuf::from(value)),
            "--cancel-file" => cancel_file = Some(PathBuf::from(value)),
            _ => unreachable!(),
        }
    }

    Ok(Options {
        provider: provider.ok_or_else(|| "--provider is required".to_string())?,
        input: input.ok_or_else(|| "--input is required".to_string())?,
        output: output.ok_or_else(|| "--output is required".to_string())?,
        provider_root,
        runner,
        cancel_file,
    })
}

fn default_lada_root() -> PathBuf {
    if let Some(root) = std::env::var_os("MOSAIC_LADA_ROOT") {
        return PathBuf::from(root);
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("MosaicRestore/benchmark/lada-upstream")
}

fn print_usage() {
    eprintln!(
        "Usage: mosaic-core --provider local-lada|nvidia-jasna --input VIDEO --output VIDEO \\\n++         [--provider-root DIR] [--runner PATH] [--cancel-file PATH]"
    );
}
