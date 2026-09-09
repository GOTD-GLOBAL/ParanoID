//! Bounded concurrent sockets including handshakes; no queue of waiting permits.
use axum_server::accept::Accept;
use std::{
    future::Future,
    io,
    pin::Pin,
    sync::Arc,
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    net::TcpStream,
    sync::{OwnedSemaphorePermit, Semaphore},
};
#[derive(Clone)]
pub struct LimitedAccept<A> {
    inner: A,
    permits: Arc<Semaphore>,
}
impl<A> LimitedAccept<A> {
    pub fn new(inner: A) -> Self {
        Self {
            inner,
            permits: Arc::new(Semaphore::new(16)),
        }
    }
}
pub struct LimitedStream<I> {
    inner: I,
    _permit: OwnedSemaphorePermit,
    deadline: Pin<Box<tokio::time::Sleep>>,
}
impl<A, S> Accept<TcpStream, S> for LimitedAccept<A>
where
    A: Accept<TcpStream, S> + Clone + Send + 'static,
    A::Future: Send,
    A::Stream: Send + 'static,
    A::Service: Send + 'static,
    S: Send + 'static,
{
    type Stream = LimitedStream<A::Stream>;
    type Service = A::Service;
    type Future = Pin<Box<dyn Future<Output = io::Result<(Self::Stream, Self::Service)>> + Send>>;
    fn accept(&self, stream: TcpStream, service: S) -> Self::Future {
        let permit = self.permits.clone().try_acquire_owned();
        let inner = self.inner.clone();
        Box::pin(async move {
            let permit = permit.map_err(|_| io::Error::other("connection limit"))?;
            let (inner, service) =
                tokio::time::timeout(Duration::from_secs(8), inner.accept(stream, service))
                    .await
                    .map_err(|_| io::Error::other("handshake timeout"))??;
            Ok((
                LimitedStream {
                    inner,
                    _permit: permit,
                    deadline: Box::pin(tokio::time::sleep(Duration::from_secs(15))),
                },
                service,
            ))
        })
    }
}
impl<I: AsyncRead + Unpin> AsyncRead for LimitedStream<I> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.deadline.as_mut().poll(cx).is_ready() {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "connection lifetime",
            )));
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}
impl<I: AsyncWrite + Unpin> AsyncWrite for LimitedStream<I> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if self.deadline.as_mut().poll(cx).is_ready() {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "connection lifetime",
            )));
        }
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.deadline.as_mut().poll(cx).is_ready() {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "connection lifetime",
            )));
        }
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.deadline.as_mut().poll(cx).is_ready() {
            return Poll::Ready(Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "connection lifetime",
            )));
        }
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}
