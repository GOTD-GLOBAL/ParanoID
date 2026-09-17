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

#ifdef __cplusplus
}
#endif

#endif /* PARANOID_CORE_H */
