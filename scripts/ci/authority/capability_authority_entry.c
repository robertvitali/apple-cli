/* Internal authority primitives. This translation unit has no executable entry. */
#include "capability_authority_entry.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
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

static int schema_envelope(CASchemaDocument *source, const char *profile_id,
                            CAProfileEnvelope *output) {
    CABudget *budget = source->budget;
    if (!output || schema_profile_id(profile_id, budget) != CA_OK) return CA_REFUSED;
    static const char *const top_names[] = {"schema_version", "profiles"};
    static const char *const row_names[] = {
        "id", "status", "platform", "runtime", "preload", "projection", "compiler_arguments", "executables"
    };
    static const char *const tool_names[] = {"git", "swift", "compiler", "linker"};
    CASchemaDocument document = *source; CAProfileEnvelope selected = {0};
    char seen[16][CA_PROFILE_BYTES + 1];
    size_t top[2]; uint64_t version; int found = 0, status = CA_REFUSED;
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
    if (status == CA_OK) *output = selected;
    return status;
}

int ca_profile_envelope_decode(const unsigned char *input, size_t length,
                               const char *profile_id, CAProfileEnvelope *output,
                               CABudget *budget) {
    if (!output || schema_profile_id(profile_id, budget) != CA_OK) return CA_REFUSED;
    CASchemaDocument document; CAProfileEnvelope selected;
    int status = CA_REFUSED;
    if (schema_open(&document, input, length, CA_JSON_BYTES, budget) == CA_OK)
        status = schema_envelope(&document, profile_id, &selected);
    if (schema_close(&document) != CA_OK) status = CA_REFUSED;
    if (status == CA_OK) *output = selected;
    return status;
}

/* Connected nested metadata only. No structure below confers launch authority.
   Strings are decoded once into an input-sized pool; relationships retain indices
   and pointers into that pool rather than multiplying maximum-length paths. */
typedef struct {
    const char *id, *path;
    CAFileIdentity identity;
} CANestedFile;
typedef struct {
    const char *name;
    size_t file;
    int kind, stock, searched;
} CANestedModule;
typedef struct {
    CASchemaDocument *document;
    char **strings, *pool;
    size_t pool_used, pool_size;
    CANestedFile *files;
    size_t file_count;
    CANestedModule *modules;
    size_t module_count;
    const char **names, **absent, **search, **directories, **candidates;
    size_t name_count, absent_count, search_count, directory_count;
    int failed;
} CANested;
enum { CN_BUILTIN, CN_FROZEN, CN_SOURCE, CN_EXTENSION };

static int nested_check(CANested *n) {
    if (n->failed || ca_budget_check(n->document->budget) != CA_OK) {
        n->failed = 1; return CA_REFUSED;
    }
    return CA_OK;
}
static const char *nested_text(CANested *n, size_t token) {
    CASchemaDocument *d = n->document;
    if (token >= d->count || d->tokens[token].kind != CA_STRING || nested_check(n) != CA_OK)
        return NULL;
    if (n->strings[token]) return n->strings[token];
    size_t length;
    if (n->pool_used >= n->pool_size
        || ca_json_string(d->input, d->length, &d->tokens[token],
                          (unsigned char *)n->pool + n->pool_used,
                          n->pool_size - n->pool_used - 1, &length, d->budget) != CA_OK
        || memchr(n->pool + n->pool_used, 0, length)) { n->failed = 1; return NULL; }
    char *value = n->pool + n->pool_used;
    value[length] = 0; n->pool_used += length + 1; n->strings[token] = value;
    return value;
}
static int nested_equal(CANested *n, size_t token, const char *expected) {
    const char *value = nested_text(n, token);
    return value && strcmp(value, expected) == 0;
}
static int nested_null(CANested *n, size_t token) {
    return token < n->document->count && n->document->tokens[token].kind == CA_NULL;
}
static int nested_number(CANested *n, size_t token, uint64_t minimum, uint64_t maximum) {
    uint64_t value;
    return schema_u64(n->document, token, &value) == CA_OK && value >= minimum && value <= maximum;
}
static int nested_array(CANested *n, size_t token, size_t minimum, size_t maximum) {
    return token < n->document->count && n->document->tokens[token].kind == CA_ARRAY
        && n->document->tokens[token].children >= minimum
        && n->document->tokens[token].children <= maximum;
}
static int nested_hex(CANested *n, size_t token, size_t length) {
    const char *value = nested_text(n, token);
    if (!value || strlen(value) != length) return 0;
    for (size_t i = 0; i < length; i++)
        if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f')))
            return 0;
    return nested_check(n) == CA_OK;
}
static int nested_path(CANested *n, const char *path) {
    size_t length;
    return path && canonical_path(path, &length, n->document->budget) == CA_OK;
}
/* Apple-base install names use canonical components under the complete-input
   bound. They are declarations, not the 4096-byte filesystem paths below.
   nested_text already validates decoded UTF-8 and rejects embedded NUL. */
static int nested_install_path(CANested *n, const char *path) {
    if (!path || path[0] != '/' || nested_check(n) != CA_OK) return 0;
    size_t length = strnlen(path, n->document->length + 1), start = 1;
    if (!length || length > n->document->length) return 0;
    for (size_t i = 1; i <= length; i++) {
        if (nested_check(n) != CA_OK) return 0;
        if (i != length && path[i] != '/') continue;
        size_t part = i - start;
        if (length != 1 && (!part || (part == 1 && path[start] == '.')
            || (part == 2 && path[start] == '.' && path[start + 1] == '.'))) return 0;
        start = i + 1;
    }
    return nested_check(n) == CA_OK;
}
static int nested_identifier(CANested *n, const char *value, int module) {
    if (!value || !*value) return 0;
    int initial = 1;
    for (size_t i = 0; value[i]; i++) {
        unsigned char c = (unsigned char)value[i];
        if (nested_check(n) != CA_OK) return 0;
        if (module) {
            if (c == '.' && !initial) { initial = 1; continue; }
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
                  || (!initial && c >= '0' && c <= '9'))) return 0;
            initial = 0;
        } else if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                     || (i && (c == '.' || c == '_' || c == '-')))) return 0;
    }
    return !module || !initial;
}
/* Prefix relations compare complete canonical components, never lexical prefixes. */
static int nested_under(const char *path, const char *root) {
    size_t length = strlen(root);
    return strcmp(path, root) == 0 || (strcmp(root, "/") == 0)
        || (strncmp(path, root, length) == 0 && path[length] == '/');
}
static int nested_contains(CANested *n, const char *const *values, size_t count,
                            const char *value) {
    for (size_t i = 0; i < count; i++) {
        if (nested_check(n) != CA_OK) return -1;
        if (strcmp(values[i], value) == 0) return 1;
    }
    return 0;
}
static int nested_absent_ancestor(CANested *n, const char *path) {
    for (size_t i = 0; i < n->absent_count; i++) {
        if (nested_check(n) != CA_OK) return -1;
        if (nested_under(path, n->absent[i])) return 1;
    }
    return 0;
}
static int nested_file_ancestor(CANested *n, const char *path, int include_self) {
    for (size_t i = 0; i < n->file_count; i++) {
        if (nested_check(n) != CA_OK) return -1;
        if (nested_under(path, n->files[i].path)
            && (include_self || strcmp(path, n->files[i].path) != 0)) return 1;
    }
    return 0;
}
static int nested_parent(CANested *n, const char *path) {
    const char *last = strrchr(path, '/');
    size_t length = last == path ? 1 : (size_t)(last - path);
    for (size_t i = 0; i < n->directory_count; i++) {
        if (nested_check(n) != CA_OK) return 0;
        if (strlen(n->directories[i]) == length && strncmp(n->directories[i], path, length) == 0)
            return 1;
    }
    return 0;
}
static size_t nested_file(CANested *n, const char *id) {
    if (!id) return SIZE_MAX;
    for (size_t i = 0; i < n->file_count; i++) {
        if (nested_check(n) != CA_OK) return SIZE_MAX;
        if (strcmp(n->files[i].id, id) == 0) return i;
    }
    return SIZE_MAX;
}
static int nested_paths(CANested *n, size_t array, const char ***output, size_t *count) {
    if (!nested_array(n, array, 0, CA_JSON_ITEMS)) return CA_REFUSED;
    *count = n->document->tokens[array].children;
    *output = calloc(*count ? *count : 1, sizeof(**output));
    if (!*output || nested_check(n) != CA_OK) return CA_REFUSED;
    size_t at = array + 1;
    for (size_t i = 0; i < *count; i++) {
        const char *value = nested_text(n, at);
        if (!nested_path(n, value) || nested_contains(n, *output, i, value) != 0)
            return CA_REFUSED;
        (*output)[i] = value;
        at = schema_after(n->document, at);
        if (at == SIZE_MAX) return CA_REFUSED;
    }
    return nested_check(n);
}
static int nested_version(CANested *n, const char *value, int build) {
    if (!value) return 0;
    size_t at = 0, digits = 0, dots = 0;
    while (value[at] >= '0' && value[at] <= '9') {
        if (nested_check(n) != CA_OK) return 0;
        at++; digits++;
    }
    if (!digits) return 0;
    if (build) {
        if (value[at] < 'A' || value[at] > 'Z') return 0;
        at++; digits = 0;
        while (value[at] >= '0' && value[at] <= '9') {
            if (nested_check(n) != CA_OK) return 0;
            at++; digits++;
        }
        if (!digits) return 0;
        if (value[at] >= 'a' && value[at] <= 'z') at++;
        return value[at] == 0;
    }
    while (value[at] == '.' && dots < 2) {
        at++; dots++; digits = 0;
        while (value[at] >= '0' && value[at] <= '9') {
            if (nested_check(n) != CA_OK) return 0;
            at++; digits++;
        }
        if (!digits) return 0;
    }
    return dots >= 1 && value[at] == 0;
}
static int nested_platform(CANested *n, size_t object) {
    static const char *const fields[] = {
        "schema_version", "system", "architecture", "product_version", "build_version", "apple_base"
    };
    static const char *const base_fields[] = {"assumption", "cache_uuid", "images"};
    static const char *const image_fields[] = {"install_name", "uuid", "file_type"};
    size_t v[6], base[3]; CASchemaDocument *d = n->document;
    if (schema_fields(d, object, fields, 6, v) != CA_OK
        || !nested_number(n, v[0], 1, 1) || !nested_equal(n, v[1], "Darwin")
        || !nested_equal(n, v[2], "arm64")
        || !nested_version(n, nested_text(n, v[3]), 0)
        || !nested_version(n, nested_text(n, v[4]), 1)
        || schema_fields(d, v[5], base_fields, 3, base) != CA_OK
        || !nested_equal(n, base[0], "selected-apple-system")
        || !nested_hex(n, base[1], 32) || !nested_array(n, base[2], 1, CA_JSON_ITEMS))
        return CA_REFUSED;
    size_t at = base[2] + 1;
    for (size_t i = 0; i < d->tokens[base[2]].children; i++) {
        size_t image[3];
        if (schema_fields(d, at, image_fields, 3, image) != CA_OK) return CA_REFUSED;
        const char *path = nested_text(n, image[0]);
        if (!nested_install_path(n, path)
            || (strncmp(path, "/usr/lib/", 9) != 0 && strncmp(path, "/System/Library/", 16) != 0)
            || !nested_hex(n, image[1], 32) || !nested_number(n, image[2], 6, 6)) return CA_REFUSED;
        size_t prior = base[2] + 1;
        for (size_t j = 0; j < i; j++) {
            size_t p[3];
            if (schema_fields(d, prior, image_fields, 3, p) != CA_OK
                || nested_equal(n, p[0], path)) return CA_REFUSED;
            prior = schema_after(d, prior);
            if (prior == SIZE_MAX) return CA_REFUSED;
        }
        at = schema_after(d, at);
        if (at == SIZE_MAX) return CA_REFUSED;
    }
    return nested_check(n);
}

static int nested_files(CANested *n, size_t array, const uint64_t limits[8]) {
    static const char *const fields[] = {"id", "identity"};
    static const char *const identity_fields[] = {
        "path", "sha256", "device", "inode", "size", "mode", "uid", "gid", "mtime_ns", "ctime_ns"
    };
    CASchemaDocument *d = n->document;
    if (!nested_array(n, array, 1, 4096) || d->tokens[array].children > limits[1]) return CA_REFUSED;
    n->file_count = d->tokens[array].children;
    n->files = calloc(n->file_count, sizeof(*n->files));
    if (!n->files || nested_check(n) != CA_OK) return CA_REFUSED;
    size_t at = array + 1; uint64_t total = 0;
    for (size_t i = 0; i < n->file_count; i++) {
        size_t v[2], identity[10]; CAPathIdentity decoded;
        if (schema_fields(d, at, fields, 2, v) != CA_OK) return CA_REFUSED;
        const char *id = nested_text(n, v[0]);
        if (!nested_identifier(n, id, 0) || schema_identity(d, v[1], 0, &decoded) != CA_OK
            || schema_fields(d, v[1], identity_fields, 10, identity) != CA_OK) return CA_REFUSED;
        const char *path = nested_text(n, identity[0]);
        if (!path || decoded.identity.size > limits[2] || decoded.identity.size > 67108864
            || decoded.identity.size > 134217728 - total) return CA_REFUSED;
        total += decoded.identity.size;
        if (total > limits[3]) return CA_REFUSED;
        for (size_t j = 0; j < i; j++) {
            if (nested_check(n) != CA_OK || strcmp(n->files[j].id, id) == 0
                || strcmp(n->files[j].path, path) == 0) return CA_REFUSED;
        }
        n->files[i] = (CANestedFile){id, path, decoded.identity};
        at = schema_after(d, at);
        if (at == SIZE_MAX) return CA_REFUSED;
    }
    return nested_check(n);
}
static int nested_images(CANested *n, size_t object) {
    static const char *const names[] = {"launcher", "main", "framework"};
    static const char *const image_fields[] = {"file", "uuid", "file_type", "architecture"};
    size_t images[3], seen[3];
    if (schema_fields(n->document, object, names, 3, images) != CA_OK) return CA_REFUSED;
    for (size_t i = 0; i < 3; i++) {
        size_t v[4];
        if (schema_fields(n->document, images[i], image_fields, i ? 4 : 1, v) != CA_OK)
            return CA_REFUSED;
        size_t file = nested_file(n, nested_text(n, v[0]));
        if (file == SIZE_MAX || (i != 2 && !(n->files[file].identity.mode & 0111))) return CA_REFUSED;
        for (size_t j = 0; j < i; j++)
            if (file == seen[j] || (n->files[file].identity.device == n->files[seen[j]].identity.device
                && n->files[file].identity.inode == n->files[seen[j]].identity.inode)) return CA_REFUSED;
        seen[i] = file;
        if (i && (!nested_hex(n, v[1], 32) || !nested_number(n, v[2], i == 1 ? 2 : 6, i == 1 ? 2 : 6)
                  || !nested_equal(n, v[3], "arm64"))) return CA_REFUSED;
    }
    return nested_check(n);
}
static int nested_name(CANested *n, const char *value) {
    if (!nested_identifier(n, value, 1)
        || nested_contains(n, n->names, n->name_count, value) != 0
        || n->name_count >= n->document->count) return CA_REFUSED;
    n->names[n->name_count++] = value;
    return CA_OK;
}
static int nested_package(CANested *n, const char *module, size_t token) {
    static const char *const members[] = {
        "bats_evidence.py", "bats_inventory.py", "capability_policy.py", "capability_process.py",
        "capability_process_protocol.py", "capability_schema.py"
    };
    const char *value = nested_text(n, token);
    if (!value) return 0;
    size_t length = strlen(module);
    if (strlen(value) != length + 3 || strncmp(value, module, length) != 0
        || strcmp(value + length, ".py") != 0) return 0;
    return nested_contains(n, members, 6, value) == 1;
}
static int nested_modules(CANested *n, size_t array, uint64_t maximum) {
    static const char *const builtin[] = {"name", "kind", "spec_name", "aliases", "registry_name"};
    static const char *const frozen[] = {"name", "kind", "spec_name", "aliases", "registry_name", "file_alias"};
    static const char *const source[] = {
        "name", "kind", "spec_name", "aliases", "loader", "selected_input", "source", "cache", "package_member"
    };
    static const char *const extension[] = {"name", "kind", "spec_name", "aliases", "file", "uuid", "dependencies"};
    CASchemaDocument *d = n->document;
    if (!nested_array(n, array, 1, CA_JSON_ITEMS) || d->tokens[array].children > maximum) return CA_REFUSED;
    n->module_count = d->tokens[array].children;
    n->modules = calloc(n->module_count, sizeof(*n->modules));
    n->names = calloc(d->count, sizeof(*n->names));
    if (!n->modules || !n->names || nested_check(n) != CA_OK) return CA_REFUSED;
    n->names[n->name_count++] = "__main__";
    size_t at = array + 1; int has_time = 0, has_signal = 0;
    for (size_t i = 0; i < n->module_count; i++) {
        /* A closed full field-set match chooses the kind; no raw unvalidated
           dictionary lookup or alternate schema admits additional fields. */
        size_t v[9]; int kind = -1;
        if (schema_fields(d, at, builtin, 5, v) == CA_OK && nested_equal(n, v[1], "builtin")) kind = CN_BUILTIN;
        else if (schema_fields(d, at, frozen, 6, v) == CA_OK && nested_equal(n, v[1], "frozen")) kind = CN_FROZEN;
        else if (schema_fields(d, at, source, 9, v) == CA_OK && nested_equal(n, v[1], "source")) kind = CN_SOURCE;
        else if (schema_fields(d, at, extension, 7, v) == CA_OK && nested_equal(n, v[1], "extension")) kind = CN_EXTENSION;
        if (kind < 0 || nested_check(n) != CA_OK) return CA_REFUSED;
        const char *name = nested_text(n, v[0]), *spec = nested_text(n, v[2]);
        if (nested_name(n, name) != CA_OK || !nested_identifier(n, spec, 1)
            || !nested_array(n, v[3], 0, CA_JSON_ITEMS)) return CA_REFUSED;
        size_t alias = v[3] + 1;
        for (size_t j = 0; j < d->tokens[v[3]].children; j++) {
            if (nested_name(n, nested_text(n, alias)) != CA_OK) return CA_REFUSED;
            alias = schema_after(d, alias);
            if (alias == SIZE_MAX) return CA_REFUSED;
        }
        CANestedModule module = {name, SIZE_MAX, kind, 0, 0};
        if (kind == CN_BUILTIN || kind == CN_FROZEN) {
            const char *registry = nested_text(n, v[4]);
            if (!nested_identifier(n, registry, 1) || strcmp(registry, spec) != 0) return CA_REFUSED;
            if (kind == CN_FROZEN && !nested_null(n, v[5])
                && nested_file(n, nested_text(n, v[5])) == SIZE_MAX) return CA_REFUSED;
            if (kind == CN_BUILTIN && strcmp(name, registry) == 0) {
                if (strcmp(name, "time") == 0) has_time = 1;
                if (strcmp(name, "_signal") == 0) has_signal = 1;
            }
        } else {
            if (strcmp(spec, name) != 0) return CA_REFUSED;
            if (kind == CN_SOURCE) {
                if (nested_equal(n, v[4], "verified-package-buffer")) {
                    if (!nested_equal(n, v[5], "package-buffer") || !nested_null(n, v[6])
                        || !nested_null(n, v[7]) || !nested_package(n, name, v[8])) return CA_REFUSED;
                } else {
                    /* The connected pre-load policy only supports source plus
                       absence. General runtime cache declarations cannot pass it. */
                    if (!nested_equal(n, v[4], "SourceFileLoader") || !nested_equal(n, v[5], "source")
                        || !nested_null(n, v[7]) || !nested_null(n, v[8])) return CA_REFUSED;
                    module.file = nested_file(n, nested_text(n, v[6])); module.stock = 1;
                    if (module.file == SIZE_MAX) return CA_REFUSED;
                }
            } else {
                module.file = nested_file(n, nested_text(n, v[4]));
                if (module.file == SIZE_MAX || !nested_hex(n, v[5], 32)
                    || !nested_array(n, v[6], 0, CA_JSON_ITEMS)) return CA_REFUSED;
                size_t dependency = v[6] + 1;
                for (size_t j = 0; j < d->tokens[v[6]].children; j++) {
                    const char *id = nested_text(n, dependency);
                    size_t file = nested_file(n, id);
                    if (file == SIZE_MAX || file == module.file) return CA_REFUSED;
                    size_t prior = v[6] + 1;
                    for (size_t k = 0; k < j; k++) {
                        if (nested_equal(n, prior, id)) return CA_REFUSED;
                        prior = schema_after(d, prior);
                        if (prior == SIZE_MAX) return CA_REFUSED;
                    }
                    dependency = schema_after(d, dependency);
                    if (dependency == SIZE_MAX) return CA_REFUSED;
                }
            }
        }
        n->modules[i] = module;
        at = schema_after(d, at);
        if (at == SIZE_MAX) return CA_REFUSED;
    }
    return has_time && has_signal ? nested_check(n) : CA_REFUSED;
}
static int nested_runtime(CANested *n, size_t object) {
    static const char *const fields[] = {
        "schema_version", "implementation", "startup", "images", "bindings", "files", "search_paths",
        "absent_inputs", "external_entry_module", "modules", "popen", "limits"
    };
    static const char *const implementation[] = {"name", "version", "pointer_bits", "byteorder", "cache_tag", "bytecode_magic"};
    static const char *const startup[] = {"isolated", "no_site", "dont_write_bytecode", "ignore_environment", "optimize"};
    static const char *const bindings[] = {"clock", "reset"};
    static const char *const clock_fields[] = {"module", "name", "constant", "value"};
    static const char *const reset_fields[] = {"module", "name", "getter_offset", "wrapper_offset", "helper_offset"};
    static const char *const limit_fields[] = {"module_count", "file_count", "per_file_bytes", "aggregate_file_bytes", "code_nodes", "code_depth", "code_bytes", "image_command_bytes"};
    static const char *const popen_fields[] = {"module", "class", "destructor", "source", "active_name", "expected_active_count"};
    CASchemaDocument *d = n->document;
    size_t v[12], imp[6], start[5], bind[2], clock[4], reset[5], limit[8], popen[6];
    uint64_t limits[8];
    if (schema_fields(d, object, fields, 12, v) != CA_OK || !nested_number(n, v[0], 1, 1)
        || schema_fields(d, v[1], implementation, 6, imp) != CA_OK
        || !nested_equal(n, imp[0], "cpython") || !nested_array(n, imp[1], 3, 3)
        || !nested_number(n, imp[1] + 1, 3, 3) || !nested_number(n, imp[1] + 2, 9, 9)
        || !nested_number(n, imp[1] + 3, 0, UINT64_MAX)
        || !nested_number(n, imp[2], 64, 64) || !nested_equal(n, imp[3], "little")
        || !nested_equal(n, imp[4], "cpython-39") || !nested_hex(n, imp[5], 8)
        || schema_fields(d, v[2], startup, 5, start) != CA_OK
        || schema_fields(d, v[4], bindings, 2, bind) != CA_OK
        || schema_fields(d, bind[0], clock_fields, 4, clock) != CA_OK
        || !nested_equal(n, clock[0], "time") || !nested_equal(n, clock[1], "clock_gettime")
        || !nested_equal(n, clock[2], "CLOCK_UPTIME_RAW") || !nested_number(n, clock[3], 8, 8)
        || schema_fields(d, bind[1], reset_fields, 5, reset) != CA_OK
        || !nested_equal(n, reset[0], "_signal") || !nested_equal(n, reset[1], "signal")
        || schema_fields(d, v[11], limit_fields, 8, limit) != CA_OK) return CA_REFUSED;
    for (size_t i = 0; i < 5; i++)
        if (!nested_number(n, start[i], i == 4 ? 0 : 1, i == 4 ? 0 : 1)) return CA_REFUSED;
    for (size_t i = 2; i < 5; i++)
        if (!nested_number(n, reset[i], 0, UINT64_MAX)) return CA_REFUSED;
    for (size_t i = 0; i < 8; i++)
        if (schema_u64(d, limit[i], &limits[i]) != CA_OK || !limits[i]) return CA_REFUSED;
    if (nested_files(n, v[5], limits) != CA_OK || nested_images(n, v[3]) != CA_OK
        || nested_paths(n, v[6], &n->search, &n->search_count) != CA_OK || !n->search_count
        || nested_paths(n, v[7], &n->absent, &n->absent_count) != CA_OK
        || !nested_equal(n, v[8], "__main__") || nested_modules(n, v[9], limits[0]) != CA_OK
        || schema_fields(d, v[10], popen_fields, 6, popen) != CA_OK
        || !nested_equal(n, popen[0], "subprocess") || !nested_equal(n, popen[1], "Popen")
        || !nested_equal(n, popen[2], "__del__") || !nested_equal(n, popen[4], "_active")
        || !nested_number(n, popen[5], 0, 0)) return CA_REFUSED;
    for (size_t i = 0; i < n->file_count; i++)
        if (nested_absent_ancestor(n, n->files[i].path) != 0) return CA_REFUSED;
    size_t file = nested_file(n, nested_text(n, popen[3])); int found = 0;
    if (file == SIZE_MAX) return CA_REFUSED;
    for (size_t i = 0; i < n->module_count; i++) {
        if (nested_check(n) != CA_OK) return CA_REFUSED;
        if (strcmp(n->modules[i].name, "subprocess") == 0
            && n->modules[i].kind == CN_SOURCE && n->modules[i].file == file) found = 1;
    }
    return found ? nested_check(n) : CA_REFUSED;
}

static int nested_directories(CANested *n, size_t array) {
    static const char *const fields[] = {"path", "device", "inode", "mode", "uid", "gid", "mtime_ns", "ctime_ns"};
    CASchemaDocument *d = n->document;
    if (!nested_array(n, array, 1, 4096)) return CA_REFUSED;
    n->directory_count = d->tokens[array].children;
    n->directories = calloc(n->directory_count, sizeof(*n->directories));
    if (!n->directories || nested_check(n) != CA_OK) return CA_REFUSED;
    size_t at = array + 1;
    for (size_t i = 0; i < n->directory_count; i++) {
        size_t v[8]; uint64_t mode;
        if (schema_fields(d, at, fields, 8, v) != CA_OK) return CA_REFUSED;
        const char *path = nested_text(n, v[0]);
        if (!nested_path(n, path) || (i && strcmp(n->directories[i - 1], path) >= 0)
            || schema_u64(d, v[3], &mode) != CA_OK || (mode & 0170000) != 0040000
            || (mode & ~(UINT64_C(0040000) | UINT64_C(0755))) != 0 || (mode & 0500) != 0500
            || nested_absent_ancestor(n, path) != 0 || nested_file_ancestor(n, path, 1) != 0)
            return CA_REFUSED;
        for (size_t j = 1; j < 8; j++)
            if (!nested_number(n, v[j], 0, UINT64_MAX)) return CA_REFUSED;
        n->directories[i] = path;
        at = schema_after(d, at);
        if (at == SIZE_MAX) return CA_REFUSED;
    }
    for (size_t i = 0; i < n->file_count; i++)
        if (!nested_parent(n, n->files[i].path) || nested_file_ancestor(n, n->files[i].path, 0) != 0
            || nested_absent_ancestor(n, n->files[i].path) != 0) return CA_REFUSED;
    for (size_t i = 0; i < n->search_count; i++) {
        int directory = nested_contains(n, n->directories, n->directory_count, n->search[i]);
        int absent = nested_contains(n, n->absent, n->absent_count, n->search[i]);
        if (directory < 0 || absent < 0 || (!directory && !absent)
            || nested_file_ancestor(n, n->search[i], 1) != 0) return CA_REFUSED;
    }
    return nested_check(n);
}
static int nested_candidate_root(CANested *n, const char *path) {
    int found = 0;
    for (size_t i = 0; i < n->search_count; i++) {
        int absent = nested_contains(n, n->absent, n->absent_count, n->search[i]);
        int directory = nested_contains(n, n->directories, n->directory_count, n->search[i]);
        if (absent < 0 || directory < 0 || nested_check(n) != CA_OK) return 0;
        if (nested_under(path, n->search[i])) {
            if (absent) return 0;
            if (directory) found = 1;
        }
    }
    return found;
}
static int nested_caches(CANested *n, const CANestedModule *module, char ordinary[4097], char legacy[4097]) {
    const char *path = n->files[module->file].path;
    size_t length = strlen(path);
    if (length < 3 || strcmp(path + length - 3, ".py") != 0) return CA_REFUSED;
    const char *base = strrchr(path, '/') + 1;
    size_t parent_length = (size_t)(base - path) - 1, stem_length = strlen(base) - 3;
    int count = snprintf(ordinary, 4097, "%.*s/__pycache__/%.*s.cpython-39.pyc",
                         (int)parent_length, path, (int)stem_length, base);
    if (count < 0 || count > 4096) return CA_REFUSED;
    count = snprintf(legacy, 4097, "%sc", path);
    if (count < 0 || count > 4096 || !nested_path(n, ordinary) || !nested_path(n, legacy)
        || nested_contains(n, n->absent, n->absent_count, ordinary) != 1
        || nested_contains(n, n->absent, n->absent_count, legacy) != 1) return CA_REFUSED;
    return nested_check(n);
}
static int nested_searches(CANested *n, size_t array) {
    static const char *const fields[] = {"module", "candidates"};
    static const char *const candidate_fields[] = {"path", "file"};
    CASchemaDocument *d = n->document;
    size_t expected = 0;
    for (size_t i = 0; i < n->module_count; i++) {
        if (nested_check(n) != CA_OK) return CA_REFUSED;
        if (n->modules[i].stock || n->modules[i].kind == CN_EXTENSION) expected++;
    }
    if (!nested_array(n, array, 0, 1024) || d->tokens[array].children != expected) return CA_REFUSED;
    n->candidates = calloc(4096, sizeof(*n->candidates));
    if (!n->candidates || nested_check(n) != CA_OK) return CA_REFUSED;
    size_t at = array + 1, total = 0; const char *previous = NULL;
    for (size_t i = 0; i < expected; i++) {
        size_t v[2];
        if (schema_fields(d, at, fields, 2, v) != CA_OK) return CA_REFUSED;
        const char *name = nested_text(n, v[0]); CANestedModule *module = NULL;
        if (!name || (previous && strcmp(previous, name) >= 0)) return CA_REFUSED;
        previous = name;
        for (size_t j = 0; j < n->module_count; j++) {
            if (nested_check(n) != CA_OK) return CA_REFUSED;
            if (strcmp(name, n->modules[j].name) == 0) module = &n->modules[j];
        }
        if (!module || module->searched || !(module->stock || module->kind == CN_EXTENSION)
            || !nested_array(n, v[1], 1, 4096 - total)) return CA_REFUSED;
        module->searched = 1;
        char ordinary[4097], legacy[4097];
        if (module->stock && nested_caches(n, module, ordinary, legacy) != CA_OK) return CA_REFUSED;
        size_t candidate = v[1] + 1, selected = 0, start = total;
        for (size_t j = 0; j < d->tokens[v[1]].children; j++) {
            size_t c[2];
            if (schema_fields(d, candidate, candidate_fields, 2, c) != CA_OK) return CA_REFUSED;
            const char *path = nested_text(n, c[0]);
            if (!nested_path(n, path) || nested_contains(n, n->candidates + start, total - start, path) != 0
                || !nested_candidate_root(n, path) || nested_file_ancestor(n, path, 0) != 0)
                return CA_REFUSED;
            int absent_ancestor = nested_absent_ancestor(n, path);
            if (absent_ancestor < 0 || (!nested_parent(n, path) && !absent_ancestor)) return CA_REFUSED;
            /* Absence of the candidate itself is not an absent parent. Python
               permits an absent ancestor only when that component is a parent. */
            if (!nested_parent(n, path)) {
                int parent_absent = 0;
                for (size_t k = 0; k < n->absent_count; k++) {
                    if (nested_check(n) != CA_OK) return CA_REFUSED;
                    if (strcmp(path, n->absent[k]) != 0 && nested_under(path, n->absent[k])) parent_absent = 1;
                }
                if (!parent_absent) return CA_REFUSED;
            }
            if (nested_null(n, c[1])) {
                if (nested_contains(n, n->absent, n->absent_count, path) != 1) return CA_REFUSED;
            } else {
                size_t file = nested_file(n, nested_text(n, c[1]));
                if (file != module->file || absent_ancestor || strcmp(path, n->files[file].path) != 0)
                    return CA_REFUSED;
                selected++;
            }
            n->candidates[total++] = path;
            candidate = schema_after(d, candidate);
            if (candidate == SIZE_MAX) return CA_REFUSED;
        }
        if (selected != 1 || (module->stock
            && (nested_contains(n, n->candidates + start, total - start, ordinary) != 1
                || nested_contains(n, n->candidates + start, total - start, legacy) != 1))) return CA_REFUSED;
        at = schema_after(d, at);
        if (at == SIZE_MAX) return CA_REFUSED;
    }
    for (size_t i = 0; i < n->module_count; i++) {
        if (nested_check(n) != CA_OK) return CA_REFUSED;
        if ((n->modules[i].stock || n->modules[i].kind == CN_EXTENSION) && !n->modules[i].searched)
            return CA_REFUSED;
    }
    return nested_check(n);
}
static int nested_preload(CANested *n, size_t object) {
    static const char *const fields[] = {"schema_version", "policy", "launch_environment", "cache_branch", "directories", "searches"};
    static const char *const env_fields[] = {"LC_ALL", "PATH"};
    static const char *const branch_fields[] = {"pycache_prefix", "check_hash_based_pycs"};
    size_t v[6], env[2], branch[2]; CASchemaDocument *d = n->document;
    if (schema_fields(d, object, fields, 6, v) != CA_OK || !nested_number(n, v[0], 1, 1)
        || !nested_equal(n, v[1], "stock-source-no-cache-v1")
        || schema_fields(d, v[2], env_fields, 2, env) != CA_OK
        || !nested_equal(n, env[0], "C") || !nested_equal(n, env[1], "/usr/bin:/bin:/usr/sbin:/sbin")
        || schema_fields(d, v[3], branch_fields, 2, branch) != CA_OK
        || !nested_null(n, branch[0]) || !nested_equal(n, branch[1], "default")
        || nested_directories(n, v[4]) != CA_OK || nested_searches(n, v[5]) != CA_OK) return CA_REFUSED;
    return nested_check(n);
}
static void nested_release(CANested *n) {
    free(n->candidates); free(n->directories); free(n->search); free(n->absent);
    free(n->names); free(n->modules); free(n->files); free(n->strings); free(n->pool);
}
int ca_profile_preload_check(const unsigned char *input, size_t length,
                             const char *profile_id, CABudget *budget) {
    if (schema_profile_id(profile_id, budget) != CA_OK) return CA_REFUSED;
    CASchemaDocument document; CAProfileEnvelope envelope;
    CANested n = {0}; n.document = &document;
    int status = CA_REFUSED;
    if (schema_open(&document, input, length, CA_JSON_BYTES, budget) != CA_OK) goto cleanup;
    if (schema_envelope(&document, profile_id, &envelope) != CA_OK) goto cleanup;
    n.pool_size = document.length + document.count;
    n.pool = malloc(n.pool_size);
    n.strings = calloc(document.count, sizeof(*n.strings));
    if (!n.pool || !n.strings || nested_check(&n) != CA_OK) goto cleanup;
    size_t platform = SIZE_MAX, runtime = SIZE_MAX, preload = SIZE_MAX;
    for (size_t i = 0; i < document.count; i++) {
        if (nested_check(&n) != CA_OK) goto cleanup;
        if (document.tokens[i].start == envelope.platform.start && document.tokens[i].end == envelope.platform.end) platform = i;
        if (document.tokens[i].start == envelope.runtime.start && document.tokens[i].end == envelope.runtime.end) runtime = i;
        if (document.tokens[i].start == envelope.preload.start && document.tokens[i].end == envelope.preload.end) preload = i;
    }
    if (nested_platform(&n, platform) == CA_OK && nested_runtime(&n, runtime) == CA_OK
        && nested_preload(&n, preload) == CA_OK) status = CA_OK;
cleanup:
    nested_release(&n);
    if (schema_close(&document) != CA_OK) status = CA_REFUSED;
    return status;
}
