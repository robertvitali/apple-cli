/* Internal authority primitives. This translation unit has no executable entry. */
#include "capability_authority_entry.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { CA_PATH_BYTES = 4096, CA_PROFILE_BYTES = 128,
       CA_FILE_BYTES = 67108864, CA_IO_BYTES = 65536 };

int ca_budget_check(CABudget *budget) {
    double now;
    if (!budget || !budget->read || !isfinite(budget->started)
        || budget->started < 0 || !isfinite(budget->deadline)
        || budget->deadline != budget->started + 58.0
        || budget->deadline <= budget->started || !isfinite(budget->last)
        || budget->last < budget->started || budget->last >= budget->deadline)
        return CA_REFUSED;
    if (budget->read(budget->state, &now) != 0 || !isfinite(now)
        || now < budget->last || now >= budget->deadline) return CA_REFUSED;
    budget->last = now;
    return CA_OK;
}

static int hex_digit(unsigned char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

/* Decode one Unicode scalar without reading outside [*position, end). */
static int utf8_scalar(const unsigned char *input, size_t end, size_t *position,
                       uint32_t *scalar) {
    if (*position >= end) return CA_REFUSED;
    unsigned char first = input[(*position)++];
    if (first < 0x80) { *scalar = first; return CA_OK; }
    unsigned extra; uint32_t minimum, result;
    if (first >= 0xc2 && first <= 0xdf) {
        extra = 1; minimum = 0x80; result = first & 0x1f;
    } else if (first >= 0xe0 && first <= 0xef) {
        extra = 2; minimum = 0x800; result = first & 0x0f;
    } else if (first >= 0xf0 && first <= 0xf4) {
        extra = 3; minimum = 0x10000; result = first & 0x07;
    } else return CA_REFUSED;
    if (end - *position < extra) return CA_REFUSED;
    for (unsigned i = 0; i < extra; i++) {
        unsigned char next = input[(*position)++];
        if ((next & 0xc0) != 0x80) return CA_REFUSED;
        result = (result << 6) | (next & 0x3f);
    }
    if (result < minimum || result > 0x10ffff
        || (result >= 0xd800 && result <= 0xdfff)) return CA_REFUSED;
    *scalar = result;
    return CA_OK;
}

static int hex_quad(const unsigned char *input, size_t end, size_t *position,
                    uint32_t *result) {
    if (end - *position < 4) return CA_REFUSED;
    uint32_t value = 0;
    for (unsigned i = 0; i < 4; i++) {
        int digit = hex_digit(input[(*position)++]);
        if (digit < 0) return CA_REFUSED;
        value = (value << 4) | (unsigned)digit;
    }
    *result = value;
    return CA_OK;
}

/* The surrounding quotation marks are handled by the caller. */
static int string_scalar(const unsigned char *input, size_t end, size_t *position,
                         uint32_t *scalar) {
    if (*position >= end) return CA_REFUSED;
    unsigned char first = input[*position];
    if (first < 0x20 || first == '"') return CA_REFUSED;
    if (first != '\\') return utf8_scalar(input, end, position, scalar);
    (*position)++;
    if (*position >= end) return CA_REFUSED;
    unsigned char escaped = input[(*position)++];
    switch (escaped) {
        case '"': case '\\': case '/': *scalar = escaped; return CA_OK;
        case 'b': *scalar = 8; return CA_OK;
        case 'f': *scalar = 12; return CA_OK;
        case 'n': *scalar = 10; return CA_OK;
        case 'r': *scalar = 13; return CA_OK;
        case 't': *scalar = 9; return CA_OK;
        case 'u': break;
        default: return CA_REFUSED;
    }
    uint32_t value;
    if (hex_quad(input, end, position, &value) != CA_OK) return CA_REFUSED;
    if (value >= 0xd800 && value <= 0xdbff) {
        if (end - *position < 6 || input[*position] != '\\'
            || input[*position + 1] != 'u') return CA_REFUSED;
        *position += 2;
        uint32_t low;
        if (hex_quad(input, end, position, &low) != CA_OK
            || low < 0xdc00 || low > 0xdfff) return CA_REFUSED;
        value = 0x10000 + ((value - 0xd800) << 10) + low - 0xdc00;
    } else if (value >= 0xdc00 && value <= 0xdfff) return CA_REFUSED;
    *scalar = value;
    return CA_OK;
}

static size_t encode_scalar(uint32_t scalar, unsigned char bytes[4]) {
    if (scalar <= 0x7f) { bytes[0] = (unsigned char)scalar; return 1; }
    if (scalar <= 0x7ff) {
        bytes[0] = (unsigned char)(0xc0 | (scalar >> 6));
        bytes[1] = (unsigned char)(0x80 | (scalar & 0x3f)); return 2;
    }
    if (scalar <= 0xffff) {
        bytes[0] = (unsigned char)(0xe0 | (scalar >> 12));
        bytes[1] = (unsigned char)(0x80 | ((scalar >> 6) & 0x3f));
        bytes[2] = (unsigned char)(0x80 | (scalar & 0x3f)); return 3;
    }
    bytes[0] = (unsigned char)(0xf0 | (scalar >> 18));
    bytes[1] = (unsigned char)(0x80 | ((scalar >> 12) & 0x3f));
    bytes[2] = (unsigned char)(0x80 | ((scalar >> 6) & 0x3f));
    bytes[3] = (unsigned char)(0x80 | (scalar & 0x3f)); return 4;
}

static int token_extent(size_t length, const CAJsonToken *token, CAJsonKind kind) {
    return token && length <= CA_JSON_BYTES && token->kind == kind
        && token->start < token->end && token->end <= length;
}

int ca_json_string(const unsigned char *input, size_t length,
                   const CAJsonToken *token, unsigned char *output,
                   size_t capacity, size_t *written, CABudget *budget) {
    if (!input || !written || (!output && capacity)
        || !token_extent(length, token, CA_STRING)
        || token->end - token->start < 2 || ca_budget_check(budget) != CA_OK)
        return CA_REFUSED;
    *written = 0;
    if (input[token->start] != '"' || input[token->end - 1] != '"') return CA_REFUSED;
    size_t position = token->start + 1, result = 0, checkpoint = position;
    while (position < token->end - 1) {
        uint32_t scalar; unsigned char bytes[4];
        if (position - checkpoint >= 256) {
            if (ca_budget_check(budget) != CA_OK) return CA_REFUSED;
            checkpoint = position;
        }
        if (string_scalar(input, token->end - 1, &position, &scalar) != CA_OK)
            return CA_REFUSED;
        size_t size = encode_scalar(scalar, bytes);
        if (result > capacity || size > capacity - result) return CA_REFUSED;
        memcpy(output + result, bytes, size); result += size;
    }
    if (ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    *written = result;
    return CA_OK;
}

int ca_json_u64(const unsigned char *input, size_t length,
                const CAJsonToken *token, uint64_t *value, CABudget *budget) {
    if (!input || !value || !token_extent(length, token, CA_NUMBER)
        || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    size_t count = token->end - token->start;
    if (count > 20 || (count > 1 && input[token->start] == '0')) return CA_REFUSED;
    size_t start = token->start;
    /* JSON's integer spelling -0 has the same unsigned semantic value as 0. */
    if (count == 2 && input[start] == '-' && input[start + 1] == '0') start++;
    uint64_t result = 0;
    for (size_t i = start; i < token->end; i++) {
        if (input[i] < '0' || input[i] > '9') return CA_REFUSED;
        unsigned digit = input[i] - '0';
        if (result > (UINT64_MAX - digit) / 10) return CA_REFUSED;
        result = result * 10 + digit;
    }
    if (ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    *value = result;
    return CA_OK;
}

typedef struct {
    const unsigned char *input;
    size_t length, position, checkpoint, count, capacity;
    CAJsonToken *tokens;
    size_t *keys, key_capacity;
    CABudget *budget;
} CAParser;

static int parser_checkpoint(CAParser *parser) {
    if (parser->position - parser->checkpoint < 256) return CA_OK;
    parser->checkpoint = parser->position;
    return ca_budget_check(parser->budget);
}

static int whitespace(CAParser *parser) {
    while (parser->position < parser->length) {
        unsigned char byte = parser->input[parser->position];
        if (byte != ' ' && byte != '\n' && byte != '\r' && byte != '\t') break;
        parser->position++;
        if (parser_checkpoint(parser) != CA_OK) return CA_REFUSED;
    }
    return CA_OK;
}

static int add_token(CAParser *parser, CAJsonKind kind, size_t parent, size_t *index) {
    if (parser->count >= parser->capacity || ca_budget_check(parser->budget) != CA_OK)
        return CA_REFUSED;
    *index = parser->count++;
    parser->tokens[*index] = (CAJsonToken){kind, parser->position, 0, parent, 0};
    if (parent != SIZE_MAX) parser->tokens[parent].children++;
    return CA_OK;
}

static int parse_string(CAParser *parser, size_t parent, size_t *index) {
    if (parser->position >= parser->length || parser->input[parser->position] != '"'
        || add_token(parser, CA_STRING, parent, index) != CA_OK) return CA_REFUSED;
    parser->position++;
    while (parser->position < parser->length) {
        if (parser->input[parser->position] == '"') {
            parser->tokens[*index].end = ++parser->position;
            return CA_OK;
        }
        uint32_t scalar;
        if (parser_checkpoint(parser) != CA_OK
            || string_scalar(parser->input, parser->length, &parser->position, &scalar) != CA_OK)
            return CA_REFUSED;
    }
    return CA_REFUSED;
}

static int key_hash(CAParser *parser, size_t index, uint64_t *result) {
    CAJsonToken *key = &parser->tokens[index];
    uint64_t hash = UINT64_C(14695981039346656037) ^ (uint64_t)key->parent;
    size_t position = key->start + 1, checkpoint = position;
    while (position < key->end - 1) {
        if (position - checkpoint >= 256) {
            if (ca_budget_check(parser->budget) != CA_OK) return CA_REFUSED;
            checkpoint = position;
        }
        uint32_t scalar;
        if (string_scalar(parser->input, key->end - 1, &position, &scalar) != CA_OK)
            return CA_REFUSED;
        hash = (hash ^ scalar) * UINT64_C(1099511628211);
    }
    *result = hash;
    return CA_OK;
}

static int keys_equal(CAParser *parser, size_t a, size_t b, int *equal) {
    CAJsonToken *left = &parser->tokens[a], *right = &parser->tokens[b];
    size_t l = left->start + 1, r = right->start + 1, checkpoint = l;
    *equal = 0;
    if (left->parent != right->parent) return CA_OK;
    while (l < left->end - 1 && r < right->end - 1) {
        if (l - checkpoint >= 256) {
            if (ca_budget_check(parser->budget) != CA_OK) return CA_REFUSED;
            checkpoint = l;
        }
        uint32_t ls, rs;
        if (string_scalar(parser->input, left->end - 1, &l, &ls) != CA_OK
            || string_scalar(parser->input, right->end - 1, &r, &rs) != CA_OK)
            return CA_REFUSED;
        if (ls != rs) return CA_OK;
    }
    *equal = l == left->end - 1 && r == right->end - 1;
    return CA_OK;
}

static int unique_key(CAParser *parser, size_t index) {
    uint64_t hash;
    if (key_hash(parser, index, &hash) != CA_OK) return CA_REFUSED;
    size_t slot = (size_t)hash & (parser->key_capacity - 1);
    for (size_t tried = 0; tried < parser->key_capacity; tried++) {
        if (ca_budget_check(parser->budget) != CA_OK) return CA_REFUSED;
        if (!parser->keys[slot]) { parser->keys[slot] = index + 1; return CA_OK; }
        int equal;
        if (keys_equal(parser, index, parser->keys[slot] - 1, &equal) != CA_OK || equal)
            return CA_REFUSED;
        slot = (slot + 1) & (parser->key_capacity - 1);
    }
    return CA_REFUSED;
}

static int digit_at(CAParser *parser) {
    return parser->position < parser->length && parser->input[parser->position] >= '0'
        && parser->input[parser->position] <= '9';
}

static int digits(CAParser *parser) {
    if (!digit_at(parser)) return CA_REFUSED;
    do {
        parser->position++;
        if (parser_checkpoint(parser) != CA_OK) return CA_REFUSED;
    } while (digit_at(parser));
    return CA_OK;
}

static int parse_value(CAParser *parser, size_t parent, unsigned depth) {
    if (whitespace(parser) != CA_OK || parser->position >= parser->length)
        return CA_REFUSED;
    unsigned char first = parser->input[parser->position];
    size_t index;
    if (first == '"') return parse_string(parser, parent, &index);
    if (first == '{' || first == '[') {
        if (depth >= CA_JSON_DEPTH || add_token(parser, first == '{' ? CA_OBJECT : CA_ARRAY,
                                                parent, &index) != CA_OK) return CA_REFUSED;
        parser->position++;
        if (whitespace(parser) != CA_OK) return CA_REFUSED;
        unsigned char close = first == '{' ? '}' : ']';
        if (parser->position < parser->length && parser->input[parser->position] == close) {
            parser->tokens[index].end = ++parser->position; return CA_OK;
        }
        for (;;) {
            if (first == '{') {
                size_t key;
                if (parse_string(parser, index, &key) != CA_OK || unique_key(parser, key) != CA_OK
                    || whitespace(parser) != CA_OK || parser->position >= parser->length
                    || parser->input[parser->position++] != ':') return CA_REFUSED;
            }
            if (parse_value(parser, index, depth + 1) != CA_OK || whitespace(parser) != CA_OK
                || parser->position >= parser->length) return CA_REFUSED;
            unsigned char next = parser->input[parser->position++];
            if (next == close) { parser->tokens[index].end = parser->position; return CA_OK; }
            if (next != ',' || whitespace(parser) != CA_OK) return CA_REFUSED;
        }
    }
    if (first == 't' || first == 'f' || first == 'n') {
        const char *literal = first == 't' ? "true" : first == 'f' ? "false" : "null";
        size_t length = first == 'f' ? 5 : 4;
        if (parser->length - parser->position < length
            || memcmp(parser->input + parser->position, literal, length) != 0
            || add_token(parser, first == 't' ? CA_TRUE : first == 'f' ? CA_FALSE : CA_NULL,
                         parent, &index) != CA_OK) return CA_REFUSED;
        parser->position += length; parser->tokens[index].end = parser->position; return CA_OK;
    }
    if (first != '-' && (first < '0' || first > '9')) return CA_REFUSED;
    if (add_token(parser, CA_NUMBER, parent, &index) != CA_OK) return CA_REFUSED;
    if (first == '-') parser->position++;
    if (!digit_at(parser)) return CA_REFUSED;
    if (parser->input[parser->position] == '0') parser->position++;
    else if (digits(parser) != CA_OK) return CA_REFUSED;
    if (parser->position < parser->length && parser->input[parser->position] == '.') {
        parser->position++;
        if (digits(parser) != CA_OK) return CA_REFUSED;
    }
    if (parser->position < parser->length
        && (parser->input[parser->position] == 'e' || parser->input[parser->position] == 'E')) {
        parser->position++;
        if (parser->position < parser->length
            && (parser->input[parser->position] == '+' || parser->input[parser->position] == '-'))
            parser->position++;
        if (digits(parser) != CA_OK) return CA_REFUSED;
    }
    parser->tokens[index].end = parser->position;
    return CA_OK;
}

int ca_json_parse(const unsigned char *input, size_t length,
                  CAJsonToken *tokens, size_t capacity, size_t *count, CABudget *budget) {
    if (!input || !tokens || !count || !length || length > CA_JSON_BYTES
        || !capacity || capacity > CA_JSON_ITEMS || ca_budget_check(budget) != CA_OK)
        return CA_REFUSED;
    *count = 0;
    size_t key_capacity = 2;
    while (key_capacity < capacity * 2) key_capacity *= 2;
    size_t *keys = calloc(key_capacity, sizeof(*keys));
    if (!keys) return CA_REFUSED;
    CAParser parser = {input, length, 0, 0, 0, capacity, tokens, keys, key_capacity, budget};
    int status = CA_REFUSED;
    if (ca_budget_check(budget) == CA_OK && parse_value(&parser, SIZE_MAX, 0) == CA_OK
        && whitespace(&parser) == CA_OK && parser.position == length) status = CA_OK;
    free(keys);
    if (ca_budget_check(budget) != CA_OK) status = CA_REFUSED;
    if (status == CA_OK) *count = parser.count;
    return status;
}

static void big_u32(unsigned char *out, uint32_t value) {
    for (unsigned i = 0; i < 4; i++) out[i] = (unsigned char)(value >> (24 - i * 8));
}

static void big_u64(unsigned char *out, uint64_t value) {
    for (unsigned i = 0; i < 8; i++) out[i] = (unsigned char)(value >> (56 - i * 8));
}

static int canonical_path(const char *path, size_t *length, CABudget *budget) {
    if (!path || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    size_t size = strnlen(path, CA_PATH_BYTES + 1);
    if (!size || size > CA_PATH_BYTES || path[0] != '/' || (size > 1 && path[size - 1] == '/'))
        return CA_REFUSED;
    size_t position = 0, checkpoint = 0;
    while (position < size) {
        uint32_t scalar;
        if (position - checkpoint >= 256) {
            if (ca_budget_check(budget) != CA_OK) return CA_REFUSED;
            checkpoint = position;
        }
        if (utf8_scalar((const unsigned char *)path, size, &position, &scalar) != CA_OK)
            return CA_REFUSED;
    }
    size_t start = 1;
    for (size_t i = 1; i <= size; i++) {
        if (i != size && path[i] != '/') continue;
        size_t part = i - start;
        if (size != 1 && (!part || (part == 1 && path[start] == '.')
            || (part == 2 && path[start] == '.' && path[start + 1] == '.'))) return CA_REFUSED;
        start = i + 1;
    }
    if (ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    *length = size;
    return CA_OK;
}

int ca_authority_binding(const char *root, const char *manifest_sha256,
                         const char *profile_id, unsigned char output[32], CABudget *budget) {
    size_t root_size;
    if (!manifest_sha256 || !profile_id || !output
        || canonical_path(root, &root_size, budget) != CA_OK
        || strnlen(manifest_sha256, 65) != 64) return CA_REFUSED;
    size_t profile_size = strnlen(profile_id, CA_PROFILE_BYTES + 1);
    if (!profile_size || profile_size > CA_PROFILE_BYTES) return CA_REFUSED;
    for (size_t i = 0; i < profile_size; i++) {
        unsigned char c = (unsigned char)profile_id[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
              || (i && (c == '.' || c == '_' || c == '-')))) return CA_REFUSED;
    }
    unsigned char digest[32];
    for (size_t i = 0; i < 32; i++) {
        unsigned char high = (unsigned char)manifest_sha256[i * 2];
        unsigned char low = (unsigned char)manifest_sha256[i * 2 + 1];
        if ((high >= 'A' && high <= 'F') || (low >= 'A' && low <= 'F')) return CA_REFUSED;
        int h = hex_digit(high), l = hex_digit(low);
        if (h < 0 || l < 0) return CA_REFUSED;
        digest[i] = (unsigned char)((h << 4) | l);
    }
    static const unsigned char domain[] = "capability-bootstrap-authority-v1";
    unsigned char encoded[sizeof(domain) + 4 + CA_PATH_BYTES + 32 + 4 + CA_PROFILE_BYTES];
    size_t at = 0;
    memcpy(encoded + at, domain, sizeof(domain)); at += sizeof(domain);
    big_u32(encoded + at, (uint32_t)root_size); at += 4;
    memcpy(encoded + at, root, root_size); at += root_size;
    memcpy(encoded + at, digest, 32); at += 32;
    big_u32(encoded + at, (uint32_t)profile_size); at += 4;
    memcpy(encoded + at, profile_id, profile_size); at += profile_size;
    if (ca_budget_check(budget) != CA_OK || !CC_SHA256(encoded, (CC_LONG)at, digest)
        || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    memcpy(output, digest, 32);
    return CA_OK;
}

int ca_bootstrap_record(CABudget *budget, const unsigned char binding[32], unsigned char output[64]) {
    if (!binding || !output || sizeof(double) != 8 || FLT_RADIX != 2 || DBL_MANT_DIG != 53
        || DBL_MAX_EXP != 1024 || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    unsigned char record[64]; uint64_t started, deadline;
    memcpy(&started, &budget->started, 8); memcpy(&deadline, &budget->deadline, 8);
    memcpy(record, "CAPBOOT1", 8); big_u32(record + 8, 8); big_u32(record + 12, 0);
    big_u64(record + 16, started); big_u64(record + 24, deadline);
    memcpy(record + 32, binding, 32);
    if (ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    memcpy(output, record, sizeof(record));
    return CA_OK;
}

static int timespec_ns(const struct timespec *value, uint64_t *result) {
    if (value->tv_sec < 0 || value->tv_nsec < 0 || value->tv_nsec >= 1000000000
        || (uint64_t)value->tv_sec > (UINT64_MAX - (uint64_t)value->tv_nsec) / 1000000000)
        return CA_REFUSED;
    *result = (uint64_t)value->tv_sec * 1000000000 + (uint64_t)value->tv_nsec;
    return CA_OK;
}

static int same_stat(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_mode == b->st_mode
        && a->st_uid == b->st_uid && a->st_gid == b->st_gid && a->st_size == b->st_size
        && a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec
        && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec
        && a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec
        && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}

static int expected_stat(const struct stat *info, const CAFileIdentity *expected) {
    uint64_t mtime, ctime;
    return S_ISREG(info->st_mode) && info->st_size >= 0
        && timespec_ns(&info->st_mtimespec, &mtime) == CA_OK
        && timespec_ns(&info->st_ctimespec, &ctime) == CA_OK
        && (uint64_t)info->st_dev == expected->device && (uint64_t)info->st_ino == expected->inode
        && (uint64_t)info->st_size == expected->size && (uint64_t)info->st_mode == expected->mode
        && (uint64_t)info->st_uid == expected->uid && (uint64_t)info->st_gid == expected->gid
        && mtime == expected->mtime_ns && ctime == expected->ctime_ns;
}

/* A close attempt consumes the descriptor even if its result is uncertain. */
static int close_owned(int *descriptor, CABudget *budget) {
    if (*descriptor < 0) return CA_OK;
    int value = *descriptor; *descriptor = -1;
    int status = close(value);
    int checkpoint = ca_budget_check(budget);
    return status == 0 && checkpoint == CA_OK ? CA_OK : CA_REFUSED;
}

/* Walk from / with O_NOFOLLOW for every component, retaining two FDs at most.
   The second walk compares every directory against the first read-only walk. */
static int walk_parent(char *const *parts, size_t count, struct stat *directories,
                       int compare, int *result, CABudget *budget) {
    int current = -1, next = -1, status = CA_REFUSED;
    if (ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (ca_budget_check(budget) != CA_OK || current < 0) goto cleanup;
    for (size_t i = 0; i < count; i++) {
        struct stat info;
        if (ca_budget_check(budget) != CA_OK || fstat(current, &info) != 0
            || ca_budget_check(budget) != CA_OK || !S_ISDIR(info.st_mode)) goto cleanup;
        if (compare) { if (!same_stat(&directories[i], &info)) goto cleanup; }
        else directories[i] = info;
        if (i + 1 == count) break;
        if (ca_budget_check(budget) != CA_OK) goto cleanup;
        next = openat(current, parts[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (ca_budget_check(budget) != CA_OK || next < 0) goto cleanup;
        if (close_owned(&current, budget) != CA_OK) goto cleanup;
        current = next; next = -1;
    }
    *result = current; current = -1; status = CA_OK;
cleanup:
    if (close_owned(&next, budget) != CA_OK) status = CA_REFUSED;
    if (close_owned(&current, budget) != CA_OK) status = CA_REFUSED;
    return status;
}

int ca_read_verified_file(const char *path, const CAFileIdentity *expected,
                          unsigned char *output, size_t capacity,
                          size_t *written, CABudget *budget) {
    size_t path_size;
    if (!expected || !written || (!output && capacity) || expected->size > CA_FILE_BYTES
        || expected->size > capacity || !S_ISREG(expected->mode)
        || canonical_path(path, &path_size, budget) != CA_OK || path_size == 1)
        return CA_REFUSED;
    *written = 0;
    char copy[CA_PATH_BYTES + 1]; char *parts[CA_PATH_BYTES / 2 + 1];
    memcpy(copy, path, path_size + 1);
    size_t count = 0; parts[count++] = copy + 1;
    for (size_t i = 1; i < path_size; i++) if (copy[i] == '/') {
        copy[i] = 0;
        if (count >= sizeof(parts) / sizeof(parts[0])) return CA_REFUSED;
        parts[count++] = copy + i + 1;
    }
    struct stat *directories = calloc(count, sizeof(*directories));
    int parent = -1, leaf = -1, status = CA_REFUSED;
    if (!directories) return CA_REFUSED;
    if (ca_budget_check(budget) != CA_OK
        || walk_parent(parts, count, directories, 0, &parent, budget) != CA_OK) goto cleanup;
    if (ca_budget_check(budget) != CA_OK) goto cleanup;
    leaf = openat(parent, parts[count - 1], O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (ca_budget_check(budget) != CA_OK || leaf < 0) goto cleanup;
    struct stat initial, final, named;
    if (fstat(leaf, &initial) != 0 || ca_budget_check(budget) != CA_OK
        || !expected_stat(&initial, expected)) goto cleanup;
    CC_SHA256_CTX hash; unsigned char digest[32];
    if (!CC_SHA256_Init(&hash) || ca_budget_check(budget) != CA_OK) goto cleanup;
    size_t used = 0;
    while (used < (size_t)expected->size) {
        if (ca_budget_check(budget) != CA_OK) goto cleanup;
        size_t amount = (size_t)expected->size - used;
        if (amount > CA_IO_BYTES) amount = CA_IO_BYTES;
        ssize_t received = read(leaf, output + used, amount);
        int read_error = errno;
        if (ca_budget_check(budget) != CA_OK) goto cleanup;
        if (received < 0 && read_error == EINTR) continue;
        if (received <= 0 || (size_t)received > amount) goto cleanup;
        if (!CC_SHA256_Update(&hash, output + used, (CC_LONG)received)
            || ca_budget_check(budget) != CA_OK) goto cleanup;
        used += (size_t)received;
    }
    for (;;) {
        unsigned char extra;
        if (ca_budget_check(budget) != CA_OK) goto cleanup;
        ssize_t received = read(leaf, &extra, 1);
        int read_error = errno;
        if (ca_budget_check(budget) != CA_OK) goto cleanup;
        if (received < 0 && read_error == EINTR) continue;
        if (received != 0) goto cleanup;
        break;
    }
    if (!CC_SHA256_Final(digest, &hash) || ca_budget_check(budget) != CA_OK
        || memcmp(digest, expected->sha256, 32) != 0) goto cleanup;
    if (fstat(leaf, &final) != 0 || ca_budget_check(budget) != CA_OK
        || !same_stat(&initial, &final)) goto cleanup;
    if (fstatat(parent, parts[count - 1], &named, AT_SYMLINK_NOFOLLOW) != 0
        || ca_budget_check(budget) != CA_OK || !same_stat(&initial, &named)) goto cleanup;
    if (close_owned(&leaf, budget) != CA_OK || close_owned(&parent, budget) != CA_OK) goto cleanup;
    if (walk_parent(parts, count, directories, 1, &parent, budget) != CA_OK) goto cleanup;
    if (fstatat(parent, parts[count - 1], &named, AT_SYMLINK_NOFOLLOW) != 0
        || ca_budget_check(budget) != CA_OK || !same_stat(&initial, &named)) goto cleanup;
    status = CA_OK;
cleanup:
    if (close_owned(&leaf, budget) != CA_OK) status = CA_REFUSED;
    if (close_owned(&parent, budget) != CA_OK) status = CA_REFUSED;
    free(directories);
    if (ca_budget_check(budget) != CA_OK) status = CA_REFUSED;
    if (status == CA_OK) *written = (size_t)expected->size;
    return status;
}

/* Schema extraction is data-only. These helpers neither observe files nor
   turn an envelope's nested byte spans into accepted runtime metadata. */
typedef struct {
    const unsigned char *input;
    size_t length, count;
    CAJsonToken *tokens;
    CABudget *budget;
} CASchemaDocument;

static int schema_open(CASchemaDocument *document, const unsigned char *input,
                       size_t length, size_t maximum, CABudget *budget) {
    *document = (CASchemaDocument){input, length, 0, NULL, budget};
    if (!input || !length || length > maximum || maximum > CA_JSON_BYTES
        || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    document->tokens = calloc(CA_JSON_ITEMS, sizeof(*document->tokens));
    if (!document->tokens || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    return ca_json_parse(input, length, document->tokens, CA_JSON_ITEMS,
                         &document->count, budget);
}

static int schema_close(CASchemaDocument *document) {
    free(document->tokens); document->tokens = NULL;
    return ca_budget_check(document->budget);
}

static int schema_string(CASchemaDocument *document, size_t index,
                         char *output, size_t capacity) {
    if (index >= document->count || !capacity) return CA_REFUSED;
    size_t written = 0;
    if (ca_json_string(document->input, document->length, &document->tokens[index],
                       (unsigned char *)output, capacity - 1, &written, document->budget) != CA_OK
        || memchr(output, 0, written) != NULL) return CA_REFUSED;
    output[written] = 0;
    return CA_OK;
}

static int schema_u64(CASchemaDocument *document, size_t index, uint64_t *value) {
    if (index >= document->count) return CA_REFUSED;
    return ca_json_u64(document->input, document->length, &document->tokens[index],
                       value, document->budget);
}

static size_t schema_after(CASchemaDocument *document, size_t index) {
    if (index >= document->count) return SIZE_MAX;
    size_t end = document->tokens[index].end;
    for (index++; index < document->count && document->tokens[index].start < end; index++)
        if (ca_budget_check(document->budget) != CA_OK) return SIZE_MAX;
    return index;
}

/* Map an exact object field set without trusting encoded key spelling/order. */
static int schema_fields(CASchemaDocument *document, size_t object,
                         const char *const *names, size_t count, size_t *values) {
    if (object >= document->count || document->tokens[object].kind != CA_OBJECT
        || document->tokens[object].children != count * 2
        || ca_budget_check(document->budget) != CA_OK) return CA_REFUSED;
    for (size_t i = 0; i < count; i++) values[i] = SIZE_MAX;
    size_t at = object + 1;
    for (size_t pair = 0; pair < count; pair++) {
        char key[64];
        if (at >= document->count || document->tokens[at].parent != object
            || schema_string(document, at, key, sizeof(key)) != CA_OK
            || at + 1 >= document->count || document->tokens[at + 1].parent != object)
            return CA_REFUSED;
        size_t found = count;
        for (size_t i = 0; i < count; i++) if (strcmp(key, names[i]) == 0) { found = i; break; }
        if (found == count || values[found] != SIZE_MAX) return CA_REFUSED;
        values[found] = at + 1;
        at = schema_after(document, at + 1);
        if (at == SIZE_MAX || ca_budget_check(document->budget) != CA_OK) return CA_REFUSED;
    }
    return CA_OK;
}

static int schema_digest(CASchemaDocument *document, size_t index, unsigned char digest[32]) {
    char value[65];
    if (schema_string(document, index, value, sizeof(value)) != CA_OK || strlen(value) != 64)
        return CA_REFUSED;
    for (size_t i = 0; i < 32; i++) {
        unsigned char high = (unsigned char)value[i * 2], low = (unsigned char)value[i * 2 + 1];
        if ((high >= 'A' && high <= 'F') || (low >= 'A' && low <= 'F')) return CA_REFUSED;
        int h = hex_digit(high), l = hex_digit(low);
        if (h < 0 || l < 0) return CA_REFUSED;
        digest[i] = (unsigned char)((h << 4) | l);
    }
    return ca_budget_check(document->budget);
}

static int schema_profile_id(const char *value, CABudget *budget) {
    if (!value || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    size_t size = strnlen(value, CA_PROFILE_BYTES + 1);
    if (!size || size > CA_PROFILE_BYTES) return CA_REFUSED;
    for (size_t i = 0; i < size; i++) {
        unsigned char c = (unsigned char)value[i];
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
              || (i && (c == '.' || c == '_' || c == '-')))) return CA_REFUSED;
    }
    return ca_budget_check(budget);
}

static int schema_identity(CASchemaDocument *document, size_t object,
                           int require_execute, CAPathIdentity *output) {
    static const char *const names[] = {
        "path", "sha256", "device", "inode", "size", "mode", "uid", "gid", "mtime_ns", "ctime_ns"
    };
    size_t values[10], path_size;
    CAPathIdentity result = {0};
    if (schema_fields(document, object, names, 10, values) != CA_OK
        || schema_string(document, values[0], result.path, sizeof(result.path)) != CA_OK
        || canonical_path(result.path, &path_size, document->budget) != CA_OK
        || schema_digest(document, values[1], result.identity.sha256) != CA_OK)
        return CA_REFUSED;
    uint64_t *const numbers[] = {
        &result.identity.device, &result.identity.inode, &result.identity.size,
        &result.identity.mode, &result.identity.uid, &result.identity.gid,
        &result.identity.mtime_ns, &result.identity.ctime_ns
    };
    for (size_t i = 0; i < 8; i++)
        if (schema_u64(document, values[i + 2], numbers[i]) != CA_OK) return CA_REFUSED;
    if (!S_ISREG(result.identity.mode) || (require_execute && !(result.identity.mode & 0111))
        || ca_budget_check(document->budget) != CA_OK) return CA_REFUSED;
    *output = result;
    return CA_OK;
}

int ca_manifest_decode(const unsigned char *input, size_t length,
                       const unsigned char expected_sha256[32], CAManifest *output,
                       CABudget *budget) {
    if (!input || !length || length > 65536 || !expected_sha256 || !output
        || ca_budget_check(budget) != CA_OK) return CA_REFUSED;
    unsigned char actual[32];
    if (!CC_SHA256(input, (CC_LONG)length, actual) || ca_budget_check(budget) != CA_OK
        || memcmp(actual, expected_sha256, 32) != 0) return CA_REFUSED;
    static const char *const top_names[] = {"schema_version", "members"};
    static const char *const member_fields[] = {"path", "kind", "size", "sha256"};
    static const char *const member_names[] = {
        "bats_evidence.py", "bats_inventory.py", "capability_policy.py", "capability_process.py",
        "capability_process_native.c", "capability_process_profiles.json",
        "capability_process_protocol.py", "capability_schema.py"
    };
    static const char *const member_kinds[] = {
        "python-source", "python-source", "python-source", "python-source",
        "native-source", "profile-data", "python-source", "python-source"
    };
    CASchemaDocument document;
    CAManifest result = {0}; size_t top[2]; uint64_t version;
    int status = CA_REFUSED;
    if (schema_open(&document, input, length, 65536, budget) != CA_OK) goto cleanup;
    if (schema_fields(&document, 0, top_names, 2, top) != CA_OK
        || schema_u64(&document, top[0], &version) != CA_OK || version != 1
        || document.tokens[top[1]].kind != CA_ARRAY || document.tokens[top[1]].children != 8)
        goto cleanup;
    size_t at = top[1] + 1; uint64_t total = 0;
    for (size_t i = 0; i < 8; i++) {
        size_t fields[4]; char name[64], kind[32];
        if (at >= document.count || document.tokens[at].parent != top[1]
            || schema_fields(&document, at, member_fields, 4, fields) != CA_OK
            || schema_string(&document, fields[0], name, sizeof(name)) != CA_OK
            || schema_string(&document, fields[1], kind, sizeof(kind)) != CA_OK
            || strcmp(name, member_names[i]) != 0 || strcmp(kind, member_kinds[i]) != 0
            || schema_u64(&document, fields[2], &result.members[i].size) != CA_OK
            || result.members[i].size > 1048576
            || schema_digest(&document, fields[3], result.members[i].sha256) != CA_OK)
            goto cleanup;
        total += result.members[i].size;
        if (total > 8388608 || ca_budget_check(budget) != CA_OK) goto cleanup;
        at = schema_after(&document, at);
        if (at == SIZE_MAX) goto cleanup;
    }
    status = CA_OK;
cleanup:
    if (schema_close(&document) != CA_OK) status = CA_REFUSED;
    if (status == CA_OK) *output = result;
    return status;
}

int ca_file_identity_decode(const unsigned char *input, size_t length, int require_execute,
                            CAPathIdentity *output, CABudget *budget) {
    if (!output || (require_execute != 0 && require_execute != 1)) return CA_REFUSED;
    CASchemaDocument document; CAPathIdentity result;
    int status = CA_REFUSED;
    if (schema_open(&document, input, length, CA_JSON_BYTES, budget) == CA_OK)
        status = schema_identity(&document, 0, require_execute, &result);
    if (schema_close(&document) != CA_OK) status = CA_REFUSED;
    if (status == CA_OK) *output = result;
    return status;
}

static CAUnvalidatedJsonSpan schema_span(CASchemaDocument *document, size_t index) {
    return (CAUnvalidatedJsonSpan){document->tokens[index].start, document->tokens[index].end};
}

static int schema_arguments(CASchemaDocument *document, size_t array) {
    if (array >= document->count || document->tokens[array].kind != CA_ARRAY
        || !document->tokens[array].children || document->tokens[array].children > 256)
        return CA_REFUSED;
    size_t at = array + 1;
    for (size_t i = 0; i < document->tokens[array].children; i++) {
        char value[4097];
        if (at >= document->count || document->tokens[at].parent != array
            || schema_string(document, at, value, sizeof(value)) != CA_OK)
            return CA_REFUSED;
        at = schema_after(document, at);
        if (at == SIZE_MAX || ca_budget_check(document->budget) != CA_OK) return CA_REFUSED;
    }
    return CA_OK;
}

int ca_profile_envelope_decode(const unsigned char *input, size_t length,
                               const char *profile_id, CAProfileEnvelope *output,
                               CABudget *budget) {
    if (!output || schema_profile_id(profile_id, budget) != CA_OK) return CA_REFUSED;
    static const char *const top_names[] = {"schema_version", "profiles"};
    static const char *const row_names[] = {
        "id", "status", "platform", "runtime", "preload", "projection", "compiler_arguments", "executables"
    };
    static const char *const tool_names[] = {"git", "swift", "compiler", "linker"};
    CASchemaDocument document; CAProfileEnvelope selected = {0};
    char seen[16][CA_PROFILE_BYTES + 1];
    size_t top[2]; uint64_t version; int found = 0, status = CA_REFUSED;
    if (schema_open(&document, input, length, CA_JSON_BYTES, budget) != CA_OK) goto cleanup;
    if (schema_fields(&document, 0, top_names, 2, top) != CA_OK
        || schema_u64(&document, top[0], &version) != CA_OK || version != 1
        || document.tokens[top[1]].kind != CA_ARRAY || document.tokens[top[1]].children > 16)
        goto cleanup;
    size_t at = top[1] + 1;
    for (size_t i = 0; i < document.tokens[top[1]].children; i++) {
        size_t fields[8], tools[4]; char state[16]; CAProfileEnvelope row = {0};
        if (at >= document.count || document.tokens[at].parent != top[1]
            || schema_fields(&document, at, row_names, 8, fields) != CA_OK
            || schema_string(&document, fields[0], seen[i], sizeof(seen[i])) != CA_OK
            || schema_profile_id(seen[i], budget) != CA_OK
            || schema_string(&document, fields[1], state, sizeof(state)) != CA_OK
            || (strcmp(state, "qualified") != 0 && strcmp(state, "inactive") != 0))
            goto cleanup;
        for (size_t previous = 0; previous < i; previous++)
            if (strcmp(seen[previous], seen[i]) == 0) goto cleanup;
        for (size_t field = 2; field < 6; field++)
            if (document.tokens[fields[field]].kind != CA_OBJECT) goto cleanup;
        if (schema_arguments(&document, fields[6]) != CA_OK
            || schema_fields(&document, fields[7], tool_names, 4, tools) != CA_OK) goto cleanup;
        for (size_t tool = 0; tool < CA_TOOL_COUNT; tool++)
            if (schema_identity(&document, tools[tool], 1, &row.tools[tool]) != CA_OK) goto cleanup;
        row.platform = schema_span(&document, fields[2]);
        row.runtime = schema_span(&document, fields[3]);
        row.preload = schema_span(&document, fields[4]);
        row.projection = schema_span(&document, fields[5]);
        row.compiler_arguments = schema_span(&document, fields[6]);
        if (strcmp(seen[i], profile_id) == 0 && strcmp(state, "qualified") == 0) {
            selected = row; found = 1;
        }
        at = schema_after(&document, at);
        if (at == SIZE_MAX || ca_budget_check(budget) != CA_OK) goto cleanup;
    }
    if (found) status = CA_OK;
cleanup:
    if (schema_close(&document) != CA_OK) status = CA_REFUSED;
    if (status == CA_OK) *output = selected;
    return status;
}
