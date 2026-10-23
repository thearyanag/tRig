use std::{
    io::{self, Write},
    path::PathBuf,
};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let mut assets = None;
    let mut parent = None;
    let mut port = 0;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--assets" => assets = args.next().map(PathBuf::from),
            "--parent-pid" => {
                parent = Some(args.next().ok_or("Missing parent PID")?.parse::<i32>()?)
            }
            "--port" => port = args.next().ok_or("Missing port")?.parse::<u16>()?,
            _ => return Err(format!("Unknown argument: {arg}").into()),
        }
    }
    let assets = assets.ok_or("--assets is required")?;
    if !assets.join("index.html").is_file() {
        return Err("Chart host resources are missing".into());
    }
    let app = trading_data_service::router(assets)?;
    let listener = TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).await?;
    println!(
        "{}",
        serde_json::json!({"port":listener.local_addr()?.port()})
    );
    io::stdout().flush()?;
    axum::serve(listener, app)
        .with_graceful_shutdown(async move {
            if let Some(parent) = parent {
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                    // The app owns the sidecar. Reparenting means its owner has exited.
                    if unsafe { libc::getppid() } != parent {
                        break;
                    }
                }
            } else {
                let _ = tokio::signal::ctrl_c().await;
            }
        })
        .await?;
    Ok(())
}
