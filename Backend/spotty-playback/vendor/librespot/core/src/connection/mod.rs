mod codec;
mod handshake;

pub use self::{codec::ApCodec, handshake::handshake};

use std::{io, time::Duration};

use futures_util::{SinkExt, StreamExt};
use num_traits::FromPrimitive;
use protobuf::Message;
use thiserror::Error;
use tokio::net::TcpStream;
use tokio_util::codec::Framed;
use url::Url;

use crate::{Error, authentication::Credentials, packet::PacketType, version};

use crate::protocol::keyexchange::{APLoginFailed, ErrorCode};

pub type Transport = Framed<TcpStream, ApCodec>;

fn login_error_message(code: &ErrorCode) -> &'static str {
    pub use ErrorCode::*;
    match code {
        ProtocolError => "Protocol error",
        TryAnotherAP => "Try another access point",
        BadConnectionId => "Bad connection ID",
        TravelRestriction => "Travel restriction",
        PremiumAccountRequired => "Premium account required",
        BadCredentials => "Bad credentials",
        CouldNotValidateCredentials => "Could not validate credentials",
        AccountExists => "Account exists",
        ExtraVerificationRequired => "Extra verification required",
        InvalidAppKey => "Invalid app key",
        ApplicationBanned => "Application banned",
    }
}

#[derive(Debug, Error)]
pub enum AuthenticationError {
    #[error("Login failed with reason: {}", login_error_message(.0))]
    LoginFailed(ErrorCode),
    #[error("invalid packet {0}")]
    Packet(u8),
    #[error("transport returned no data")]
    Transport,
}

impl From<AuthenticationError> for Error {
    fn from(err: AuthenticationError) -> Self {
        match err {
            AuthenticationError::LoginFailed(_) => Error::permission_denied(err),
            AuthenticationError::Packet(_) => Error::unimplemented(err),
            AuthenticationError::Transport => Error::unavailable(err),
        }
    }
}

impl From<APLoginFailed> for AuthenticationError {
    fn from(login_failure: APLoginFailed) -> Self {
        Self::LoginFailed(login_failure.error_code())
    }
}

pub async fn connect(host: &str, port: u16, proxy: Option<&Url>) -> io::Result<Transport> {
    const TIMEOUT: Duration = Duration::from_secs(5);
    tokio::time::timeout(TIMEOUT, async {
        let socket = crate::socket::connect(host, port, proxy).await?;
        debug!("Connection to AP established.");
        handshake(socket).await
    })
    .await?
}

pub async fn connect_with_retry(
    host: &str,
    port: u16,
    proxy: Option<&Url>,
    max_retries: u8,
) -> io::Result<Transport> {
    let mut num_retries = 0;
    loop {
        match connect(host, port, proxy).await {
            Ok(f) => return Ok(f),
            Err(e) => {
                debug!("Connection to \"{host}:{port}\" failed: {e}");
                if num_retries < max_retries {
                    num_retries += 1;
                    debug!("Retry access point...");
                    continue;
                }
                return Err(e);
            }
        }
    }
}

pub async fn authenticate(
    transport: &mut Transport,
    credentials: Credentials,
    device_id: &str,
) -> Result<Credentials, Error> {
    use crate::protocol::authentication::{APWelcome, ClientResponseEncrypted, CpuFamily, Os};

    let cpu_family = match std::env::consts::ARCH {
        "blackfin" => CpuFamily::CPU_BLACKFIN,
        "arm" | "aarch64" => CpuFamily::CPU_ARM,
        "ia64" => CpuFamily::CPU_IA64,
        "mips" => CpuFamily::CPU_MIPS,
        "ppc" => CpuFamily::CPU_PPC,
        "ppc64" => CpuFamily::CPU_PPC_64,
        "sh" => CpuFamily::CPU_SH,
        "x86" => CpuFamily::CPU_X86,
        "x86_64" => CpuFamily::CPU_X86_64,
        _ => CpuFamily::CPU_UNKNOWN,
    };

    let os = match crate::config::OS {
        "android" => Os::OS_ANDROID,
        "freebsd" | "netbsd" | "openbsd" => Os::OS_FREEBSD,
        "ios" => Os::OS_IPHONE,
        "linux" => Os::OS_LINUX,
        "macos" => Os::OS_OSX,
        "windows" => Os::OS_WINDOWS,
        _ => Os::OS_UNKNOWN,
    };

    let mut packet = ClientResponseEncrypted::new();
    if let Some(username) = credentials.username {
        packet
            .login_credentials
            .mut_or_insert_default()
            .set_username(username);
    }
    packet
        .login_credentials
        .mut_or_insert_default()
        .set_typ(credentials.auth_type);
    packet
        .login_credentials
        .mut_or_insert_default()
        .set_auth_data(credentials.auth_data);
    packet
        .system_info
        .mut_or_insert_default()
        .set_cpu_family(cpu_family);
    packet.system_info.mut_or_insert_default().set_os(os);
    packet
        .system_info
        .mut_or_insert_default()
        .set_system_information_string(format!(
            "librespot-{}-{}",
            version::SHA_SHORT,
            version::BUILD_ID
        ));
    packet
        .system_info
        .mut_or_insert_default()
        .set_device_id(device_id.to_string());
    packet.set_version_string(format!("librespot {}", version::SEMVER));

    let cmd = PacketType::Login;
    let data = packet.write_to_bytes()?;

    debug!("Authenticating with AP using {:?}", credentials.auth_type);
    transport.send((cmd as u8, data)).await?;
    let (cmd, data) = transport
        .next()
        .await
        .ok_or(AuthenticationError::Transport)??;
    let packet_type = FromPrimitive::from_u8(cmd);
    let result = match packet_type {
        Some(PacketType::APWelcome) => {
            let welcome_data = APWelcome::parse_from_bytes(data.as_ref())?;

            let reusable_credentials = Credentials {
                username: Some(welcome_data.canonical_username().to_owned()),
                auth_type: welcome_data.reusable_auth_credentials_type(),
                auth_data: welcome_data.reusable_auth_credentials().to_owned(),
            };

            Ok(reusable_credentials)
        }
        Some(PacketType::AuthFailure) => {
            let error_data = APLoginFailed::parse_from_bytes(data.as_ref())?;
            Err(error_data.into())
        }
        _ => {
            trace!("Did not expect {cmd:?} AES key packet with data {data:#?}");
            Err(AuthenticationError::Packet(cmd))
        }
    };
    Ok(result?)
}

#[cfg(test)]
mod spotty_deadline_tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
        sync::{mpsc, oneshot},
    };

    // Keep the real clock running until the socket has reached the intended phase. Starting
    // paused would let Tokio auto-advance a deadline before the loopback I/O is even observed.
    async fn advance_after_socket_progress(
        progress: &mut mpsc::UnboundedReceiver<()>,
        by: Duration,
    ) {
        tokio::time::timeout(Duration::from_secs(2), progress.recv())
            .await
            .expect("loopback phase reached")
            .expect("server reported socket progress");
        tokio::time::pause();
        tokio::time::advance(by).await;
        tokio::time::resume();
    }

    async fn read_proxy_request(socket: &mut TcpStream) {
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            let byte = socket.read_u8().await.expect("complete CONNECT request");
            request.push(byte);
            assert!(
                request.len() <= 4096,
                "synthetic CONNECT request is bounded"
            );
        }
        assert!(request.starts_with(b"CONNECT "));
    }

    #[tokio::test]
    async fn spotty_proxy_setup_and_handshake_share_attempt_deadline() {
        enum Phase {
            ProxySetup,
            DirectHandshake,
            SlowProxyThenHandshake,
        }
        for phase in [
            Phase::ProxySetup,
            Phase::DirectHandshake,
            Phase::SlowProxyThenHandshake,
        ] {
            let uses_proxy = !matches!(phase, Phase::DirectHandshake);
            let delayed_tunnel = matches!(phase, Phase::SlowProxyThenHandshake);
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let (progress_tx, mut progress_rx) = mpsc::unbounded_channel();
            let (open_tunnel, tunnel_allowed) = oneshot::channel();
            let server = tokio::spawn(async move {
                let (mut socket, _) = listener.accept().await.unwrap();
                let mut bytes = [0; 4096];
                if uses_proxy {
                    read_proxy_request(&mut socket).await;
                } else {
                    assert!(
                        socket.read(&mut bytes).await.unwrap() > 0,
                        "AP handshake started"
                    );
                }
                progress_tx.send(()).unwrap();
                if delayed_tunnel {
                    tunnel_allowed.await.unwrap();
                    socket.write_all(b"HTTP/1.1 200 OK\r\n\r\n").await.unwrap();
                    assert!(
                        socket.read(&mut bytes).await.unwrap() > 0,
                        "tunneled handshake started"
                    );
                    progress_tx.send(()).unwrap();
                }
                // Leave the chosen phase stalled, then observe EOF when its attempt expires.
                while socket.read(&mut bytes).await.unwrap() != 0 {}
            });
            let proxy = Url::parse(&format!("http://{address}")).unwrap();
            let started = tokio::time::Instant::now();
            let request = tokio::spawn(async move {
                connect("127.0.0.1", address.port(), uses_proxy.then_some(&proxy)).await
            });
            if delayed_tunnel {
                advance_after_socket_progress(&mut progress_rx, Duration::from_secs(2)).await;
                open_tunnel.send(()).unwrap();
                advance_after_socket_progress(&mut progress_rx, Duration::from_secs(3)).await;
            } else {
                advance_after_socket_progress(&mut progress_rx, Duration::from_secs(5)).await;
            }
            let result = tokio::time::timeout(Duration::from_secs(1), request)
                .await
                .expect("attempt must use the original shared deadline")
                .unwrap();
            assert_eq!(result.err().unwrap().kind(), io::ErrorKind::TimedOut);
            assert!(started.elapsed() >= Duration::from_secs(5));
            tokio::time::timeout(Duration::from_secs(1), server)
                .await
                .expect("expired attempt releases its socket")
                .unwrap();
        }
    }

    #[tokio::test]
    async fn spotty_stalled_proxy_allows_bounded_retry() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (progress_tx, mut progress_rx) = mpsc::unbounded_channel();
        let server = tokio::spawn(async move {
            for _ in 0..2 {
                let (mut socket, _) = listener.accept().await.unwrap();
                read_proxy_request(&mut socket).await;
                progress_tx.send(()).unwrap();
                let mut bytes = [0; 4096];
                while socket.read(&mut bytes).await.unwrap() != 0 {}
            }
        });
        let proxy = Url::parse(&format!("http://{address}")).unwrap();
        let request = tokio::spawn(async move {
            connect_with_retry("127.0.0.1", address.port(), Some(&proxy), 1).await
        });
        for _ in 0..2 {
            advance_after_socket_progress(&mut progress_rx, Duration::from_secs(5)).await;
        }
        let result = tokio::time::timeout(Duration::from_secs(1), request)
            .await
            .expect("both attempts are bounded")
            .unwrap();
        assert_eq!(result.err().unwrap().kind(), io::ErrorKind::TimedOut);
        tokio::time::timeout(Duration::from_secs(1), server)
            .await
            .expect("both expired attempts release their sockets")
            .unwrap();
    }
}
