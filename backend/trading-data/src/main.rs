use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let mut assets = None;
    let mut database = None;
    let mut quote_config = None;
    let mut parent = None;
    let mut endpoint_file = None;
    let mut port = 0;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--quote-config" => quote_config = args.next().map(PathBuf::from),
            "--database" => database = args.next().map(PathBuf::from),
            "--assets" => assets = args.next().map(PathBuf::from),
            "--endpoint-file" => {
                endpoint_file = Some(PathBuf::from(args.next().ok_or("Missing endpoint path")?))
            }
            "--parent-pid" => {
                parent = Some(args.next().ok_or("Missing parent PID")?.parse::<i32>()?)
            }
            "--port" => port = args.next().ok_or("Missing port")?.parse::<u16>()?,
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    let assets = assets.ok_or("--assets is required")?;
    if !assets.join("index.html").is_file() || !assets.join("chart.js").is_file() {
        return Err("Chart resources are missing".into());
    }
    let database = database.ok_or("--database is required")?;
    let config = trading_data_service::execution::config::Config::load(quote_config.as_deref())?;
    let app = trading_data_service::router(assets, &database, config)?;
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    let bound_port = listener.local_addr()?.port();
    let app = if let Some(path) = endpoint_file {
        let token = publish_endpoint(&path, bound_port)?;
        axum::Router::new().nest(&format!("/{token}"), app)
    } else {
        println!("{}", serde_json::json!({"port":bound_port}));
        io::stdout().flush()?;
        app
    };
    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown(parent))
        .await?;
    Ok(())
}

fn publish_endpoint(path: &Path, port: u16) -> io::Result<String> {
    let mut random = [0u8; 16];
    File::open("/dev/urandom")?.read_exact(&mut random)?;
    let token: String = random
        .into_iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    let pid = std::process::id();
    let ready = serde_json::json!({"port":port, "pid":pid, "token":token});
    let staging = path.with_file_name(format!(".endpoint-{pid}-{token}"));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&staging)?;
    let result = serde_json::to_writer(&mut file, &ready)
        .map_err(io::Error::from)
        .and_then(|_| fs::rename(&staging, path));
    if result.is_err() {
        let _ = fs::remove_file(staging);
    }
    result.map(|_| token)
}

async fn shutdown(parent: Option<i32>) {
    if let Some(parent) = parent {
        loop {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            if unsafe { libc::getppid() } != parent {
                return;
            }
        }
    }
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("register SIGTERM handler");
    tokio::select! {
        _ = terminate.recv() => {},
        _ = tokio::signal::ctrl_c() => {},
    }
}
