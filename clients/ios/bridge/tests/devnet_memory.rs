//! Observe bytes BEFORE System.dealloc; never read freed storage. Public data only.
//! One test owns the probes so the test harness cannot race another probe.
use paranoid_ios_bridge::{paranoid_devnet_command, paranoid_devnet_free};
use std::alloc::{GlobalAlloc, Layout, System};
use std::ffi::{CStr, CString};
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicUsize, Ordering::SeqCst};

struct ObservedAllocator;
static REQUEST_SIZE: AtomicUsize = AtomicUsize::new(0);
static REQUEST: AtomicPtr<u8> = AtomicPtr::new(std::ptr::null_mut());
static REPLY: AtomicPtr<u8> = AtomicPtr::new(std::ptr::null_mut());
static REQUEST_WIPED: AtomicBool = AtomicBool::new(false);
static REPLY_WIPED: AtomicBool = AtomicBool::new(false);

// SAFETY: delegates every allocation to System with the original layout; only
// inspects allocations still live when their owner asks to deallocate them.
unsafe impl GlobalAlloc for ObservedAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let p = unsafe { System.alloc(layout) };
        if REQUEST_SIZE
            .compare_exchange(layout.size(), 0, SeqCst, SeqCst)
            .is_ok()
        {
            REQUEST.store(p, SeqCst);
        }
        p
    }
    unsafe fn dealloc(&self, p: *mut u8, layout: Layout) {
        for (watched, wiped) in [(&REQUEST, &REQUEST_WIPED), (&REPLY, &REPLY_WIPED)] {
            if watched
                .compare_exchange(p, std::ptr::null_mut(), SeqCst, SeqCst)
                .is_ok()
            {
                let bytes = unsafe { std::slice::from_raw_parts(p, layout.size()) };
                wiped.store(bytes.iter().all(|byte| *byte == 0), SeqCst);
            }
        }
        unsafe { System.dealloc(p, layout) };
    }
}

#[global_allocator]
static ALLOCATOR: ObservedAllocator = ObservedAllocator;

#[test]
fn copied_request_and_owned_reply_are_wiped_before_deallocation() {
    let request = CString::new(r#"{"op":"recover","mnemonic":"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"}"#).unwrap();
    REQUEST_SIZE.store(request.as_bytes().len(), SeqCst);
    // SAFETY: the original input is live; the output is read unmodified and freed once.
    unsafe {
        let reply = paranoid_devnet_command(request.as_ptr());
        assert_eq!(
            CStr::from_ptr(reply).to_bytes(),
            br#"{"entropy":"AAAAAAAAAAAAAAAAAAAAAA=="}"#
        );
        REPLY.store(reply.cast(), SeqCst);
        paranoid_devnet_free(reply);
    }
    assert_eq!(REQUEST_SIZE.load(SeqCst), 0, "copy allocation not observed");
    assert!(REQUEST.load(SeqCst).is_null(), "copy not deallocated");
    assert!(REQUEST_WIPED.load(SeqCst), "copied request not wiped");
    assert!(REPLY.load(SeqCst).is_null(), "reply not deallocated");
    assert!(REPLY_WIPED.load(SeqCst), "owned reply not wiped");
    // The caller's buffer is not ours to erase.
    assert!(request.as_bytes().starts_with(br#"{"op":"recover""#));

    let oversized = CString::new("x".repeat(16385)).unwrap();
    REQUEST_SIZE.store(oversized.as_bytes().len(), SeqCst);
    unsafe {
        let reply = paranoid_devnet_command(oversized.as_ptr());
        assert_eq!(
            CStr::from_ptr(reply).to_bytes(),
            br#"{"error":"input_limit"}"#
        );
        paranoid_devnet_free(reply);
    }
    assert_eq!(
        REQUEST_SIZE.swap(0, SeqCst),
        16385,
        "oversized input was copied"
    );
}
