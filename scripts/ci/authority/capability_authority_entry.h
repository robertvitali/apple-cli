#ifndef CAPABILITY_AUTHORITY_ENTRY_H
#define CAPABILITY_AUTHORITY_ENTRY_H

#include <stddef.h>
#include <stdint.h>

/* Internal native-entry primitives, not a caller-supplied authority interface. */
enum { CA_OK = 0, CA_REFUSED = 1 };
enum { CA_JSON_BYTES = 1048576, CA_JSON_DEPTH = 16, CA_JSON_ITEMS = 32768 };
typedef int (*CAClockRead)(void *state, double *value);
typedef struct {
    double started, deadline, last;
    CAClockRead read;
    void *state;
} CABudget;

typedef enum {
    CA_OBJECT, CA_ARRAY, CA_STRING, CA_NUMBER, CA_TRUE, CA_FALSE, CA_NULL
} CAJsonKind;
typedef struct {
    CAJsonKind kind;
    size_t start, end;
    size_t parent; /* SIZE_MAX for the single root value. */
    size_t children;
} CAJsonToken;

typedef struct {
    uint64_t device, inode, size, mode, uid, gid, mtime_ns, ctime_ns;
    unsigned char sha256[32];
} CAFileIdentity;

int ca_budget_check(CABudget *budget);
int ca_json_parse(const unsigned char *input, size_t length,
                  CAJsonToken *tokens, size_t capacity, size_t *count,
                  CABudget *budget);
int ca_json_string(const unsigned char *input, size_t length,
                   const CAJsonToken *token, unsigned char *output,
                   size_t capacity, size_t *written, CABudget *budget);
int ca_json_u64(const unsigned char *input, size_t length,
                const CAJsonToken *token, uint64_t *value, CABudget *budget);
int ca_authority_binding(const char *root, const char *manifest_sha256,
                         const char *profile_id, unsigned char output[32],
                         CABudget *budget);
int ca_bootstrap_record(CABudget *budget, const unsigned char binding[32],
                        unsigned char output[64]);
int ca_read_verified_file(const char *path, const CAFileIdentity *expected,
                          unsigned char *output, size_t capacity,
                          size_t *written, CABudget *budget);

/* Data records only. None establishes preflight, runtime or launch authority. */
typedef struct {
    uint64_t size;
    unsigned char sha256[32];
} CAManifestMember;
typedef struct { CAManifestMember members[8]; } CAManifest;
typedef struct {
    char path[4097];
    CAFileIdentity identity;
} CAPathIdentity;
typedef struct { size_t start, end; } CAUnvalidatedJsonSpan;
enum { CA_TOOL_GIT, CA_TOOL_SWIFT, CA_TOOL_COMPILER, CA_TOOL_LINKER, CA_TOOL_COUNT };
typedef struct {
    CAPathIdentity tools[CA_TOOL_COUNT];
    CAUnvalidatedJsonSpan platform, runtime, preload, projection, compiler_arguments;
} CAProfileEnvelope;

/* Index follows the fixed sorted eight-member package roster. The eventual
   external entry supplies expected_sha256 from its independently pinned literal. */
int ca_manifest_decode(const unsigned char *input, size_t length,
                       const unsigned char expected_sha256[32], CAManifest *output,
                       CABudget *budget);
/* require_execute is exactly 0 or 1. Common integer fields retain the uint64
   domain; runtime-specific size limits are a later mandatory schema predicate. */
int ca_file_identity_decode(const unsigned char *input, size_t length, int require_execute,
                            CAPathIdentity *output, CABudget *budget);
/* These spans refer to caller-retained immutable verified bytes. Full nested
   platform/runtime/preload/projection admission and fixed compiler selection
   MUST follow before any profile file preflight or launch. */
int ca_profile_envelope_decode(const unsigned char *input, size_t length,
                               const char *profile_id, CAProfileEnvelope *output,
                               CABudget *budget);

/* Selected platform/runtime/preload consistency only; no effects or authority
   result. Projection/compiler admission and finite file preflight remain required.
   The input is unchanged and every check consumes the existing original budget. */
int ca_profile_preload_check(const unsigned char *input, size_t length,
                             const char *profile_id, CABudget *budget);

/* Finite package/selected pre-load observations only. The eventual caller must
   supply independently selected root/digest/profile literals. No launch authority
   or transferable accepted record is returned; the original budget is consumed. */
int ca_preload_files_check(const char *root, const unsigned char manifest_sha256[32],
                           const char *profile_id, CABudget *budget);

/* Internal compiled execution selection. It is never supplied by a public
   argument/environment override or imported as an authority receipt. */
typedef struct {
    const char *root, *manifest_sha256, *profile_id;
    const char *interpreter_path, *interpreter_sha256;
    const char *shim_path, *shim_sha256;
} CAExecutionPins;
/* Original CABudget provenance belongs to the trusted native caller. Every
   return refuses; success can only replace this process via the sole exec. */
int ca_authority_dispatch(const CAExecutionPins *, size_t,
                          const char *const [], CABudget *);
#endif
