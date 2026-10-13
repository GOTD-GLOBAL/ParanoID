#ifndef PARANOID_CORE_H
#define PARANOID_CORE_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Runs one paranoid-client-core command.
 *
 * `state` and `request` are NUL-terminated UTF-8 JSON documents (`state` may
 * be "" for a fresh identity). The result is a NUL-terminated UTF-8 JSON
 * document and is never NULL: on failure it is {"error":"<code>"}, including
 * "invalid_request" for NULL/non-UTF-8 arguments and "native_failure" for an
 * internal panic. Input limits (8 MiB state, 65536-byte request) are enforced
 * inside the core. Release the result with paranoid_core_free.
 */
char *paranoid_core_command(const char *state, const char *request);

/* Frees a string returned by paranoid_core_command. NULL is ignored. */
void paranoid_core_free(char *text);

/*
 * Runs one unchanged paranoid-devnet-client JSON command (RFC-0030 candidate).
 * request must be NULL or a readable NUL-terminated string, valid for the call.
 * At most 16384 UTF-8 bytes excluding NUL; oversized input yields "input_limit"
 * before copying. NULL/non-UTF-8 yields "invalid_request"; an unwinding Rust
 * panic yields "native_failure". A returned reply is NUL-terminated UTF-8 JSON,
 * never NULL under normal allocation, and can contain words/entropy: never log
 * it. The bridge zeroizes its input copy; caller-owned input is untouched.
 * Read the reply without modifying it, then call paranoid_devnet_free exactly
 * once. Do not use free() or paranoid_core_free(). Invalid pointers, concurrent
 * mutation, double free, allocator failure and aborting panics are not caught.
 */
char *paranoid_devnet_command(const char *request);

/* Overwrites and frees an unmodified Devnet reply (including NUL). NULL is safe. */
void paranoid_devnet_free(char *text);

#ifdef __cplusplus
}
#endif

#endif /* PARANOID_CORE_H */
