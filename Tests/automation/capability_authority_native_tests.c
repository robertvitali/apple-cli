/* Synthetic native-entry primitive tests. No exec, pipe, signal or real clock. */
#include "capability_authority_entry.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    double now, step;
    int fail; unsigned calls;
    int watch_file, seen_file;
    uint64_t device, inode;
} FakeClock;
static FakeClock clock_state;
static CABudget budget;
static CAJsonToken tokens[CA_JSON_ITEMS];
static unsigned failures, cases;

static int fake_clock(void *state, double *value) {
    FakeClock *clock = state;
    clock->calls++;
    if (clock->fail) return 1;
    if (clock->watch_file) {
        int found = 0;
        for (int fd = 3; fd <= 255; fd++) {
            struct stat info;
            if (fstat(fd, &info) == 0 && (uint64_t)info.st_dev == clock->device
                && (uint64_t)info.st_ino == clock->inode) found = 1;
        }
        if (found) clock->seen_file = 1;
        if ((clock->watch_file == 1 && found)
            || (clock->watch_file == 2 && clock->seen_file && !found)) {
            *value = 158.0; return 0;
        }
    }
    *value = clock->now;
    clock->now += clock->step;
    return 0;
}
static void reset_budget(double started) {
    clock_state = (FakeClock){.now = started + 1.0};
    budget = (CABudget){started, started + 58.0, started, fake_clock, &clock_state};
}
static void check(const char *label, int passed) {
    cases++;
    if (!passed) failures++;
    printf("case=%s status=%s\n", label, passed ? "pass" : "fail");
}
static int parse(const char *text, size_t capacity, size_t *count) {
    reset_budget(100.0);
    return ca_json_parse((const unsigned char *)text, strlen(text), tokens,
                         capacity, count, &budget);
}
static int hex_bytes(const char *text, unsigned char *out, size_t length) {
    static const char digits[] = "0123456789abcdef";
    if (strlen(text) != length * 2) return 0;
    for (size_t i = 0; i < length; i++) {
        const char *high = strchr(digits, text[i * 2]);
        const char *low = strchr(digits, text[i * 2 + 1]);
        if (!high || !low) return 0;
        out[i] = (unsigned char)((high - digits) * 16 + low - digits);
    }
    return 1;
}

static void budget_cases(void) {
    reset_budget(100.0);
    check("budget-valid", ca_budget_check(&budget) == CA_OK && budget.last == 101.0);
    reset_budget(100.0); clock_state.now = 158.0;
    check("budget-expired", ca_budget_check(&budget) == CA_REFUSED);
    reset_budget(100.0); budget.last = 102.0;
    check("budget-backward", ca_budget_check(&budget) == CA_REFUSED);
    reset_budget(100.0); clock_state.fail = 1;
    check("budget-clock-error", ca_budget_check(&budget) == CA_REFUSED);
    reset_budget(100.0); clock_state.now = NAN;
    check("budget-nonfinite", ca_budget_check(&budget) == CA_REFUSED);
}

static void json_cases(void) {
    size_t count = 0;
    const char *valid = "{\"name\":\"synthetic\",\"values\":[0,true,false,null]}";
    int status = parse(valid, CA_JSON_ITEMS, &count);
    check("json-tree", status == CA_OK && count == 9 && tokens[0].kind == CA_OBJECT
          && tokens[0].parent == SIZE_MAX && tokens[0].children == 4);
    const char *invalid[] = {
        "{\"x\":1,\"x\":2}", "{\"x\":1,\"\\u0078\":2}",
        "[1,]", "{\"x\":}", "true false", "[01]", "[+1]", "[NaN]",
        "\"\\uD800\"", "\"\\uDC00\"", "\"\xc0\xaf\"", "\"\x01\""
    };
    int all_refused = 1;
    for (size_t i = 0; i < sizeof(invalid) / sizeof(invalid[0]); i++)
        if (parse(invalid[i], CA_JSON_ITEMS, &count) != CA_REFUSED) all_refused = 0;
    check("json-malformed-and-duplicate", all_refused);
    char nested[36]; memset(nested, '[', 17); nested[17] = '0';
    memset(nested + 18, ']', 17); nested[35] = 0;
    check("json-depth-limit", parse(nested, CA_JSON_ITEMS, &count) == CA_REFUSED);
    char allowed_nested[34]; memset(allowed_nested, '[', 16); allowed_nested[16] = '0';
    memset(allowed_nested + 17, ']', 16); allowed_nested[33] = 0;
    check("json-depth-sixteen", parse(allowed_nested, CA_JSON_ITEMS, &count) == CA_OK);
    struct { CAJsonToken value; unsigned char canary[16]; } bounded;
    memset(&bounded, 0xa5, sizeof(bounded)); reset_budget(0);
    status = ca_json_parse((const unsigned char *)"[1,2]", 5, &bounded.value, 1, &count, &budget);
    int intact = 1;
    for (size_t i = 0; i < sizeof(bounded.canary); i++) if (bounded.canary[i] != 0xa5) intact = 0;
    check("json-token-capacity", status == CA_REFUSED && intact);
    memset(&bounded, 0xa5, sizeof(bounded)); reset_budget(0);
    status = ca_json_parse((const unsigned char *)"0", 1, &bounded.value,
                          CA_JSON_ITEMS + 1, &count, &budget);
    intact = 1;
    for (size_t i = 0; i < sizeof(bounded); i++) if (((unsigned char *)&bounded)[i] != 0xa5) intact = 0;
    check("json-token-policy-bound", status == CA_REFUSED && intact);
    unsigned char byte = 0; reset_budget(0);
    check("json-size-before-read", ca_json_parse(&byte, CA_JSON_BYTES + 1,
          tokens, CA_JSON_ITEMS, &count, &budget) == CA_REFUSED);
    const char *escaped = "\"A\\uD83D\\uDE00\\n\"";
    unsigned char decoded[16]; size_t written = 0;
    status = parse(escaped, CA_JSON_ITEMS, &count);
    if (status == CA_OK) status = ca_json_string((const unsigned char *)escaped,
        strlen(escaped), &tokens[0], decoded, sizeof(decoded), &written, &budget);
    check("json-unicode-decoding", status == CA_OK && written == 6
          && memcmp(decoded, "A\xf0\x9f\x98\x80\n", 6) == 0);
    const char *small_string = "\"abc\"";
    struct { unsigned char output[3], canary[8]; } string_buffer;
    memset(&string_buffer, 0xa5, sizeof(string_buffer));
    status = parse(small_string, CA_JSON_ITEMS, &count);
    if (status == CA_OK) status = ca_json_string((const unsigned char *)small_string,
        strlen(small_string), &tokens[0], string_buffer.output, 3, &written, &budget);
    intact = 1;
    for (size_t i = 0; i < sizeof(string_buffer.canary); i++) if (string_buffer.canary[i] != 0xa5) intact = 0;
    check("json-string-exact-capacity", status == CA_OK && written == 3
          && memcmp(string_buffer.output, "abc", 3) == 0 && intact);
    memset(&string_buffer, 0xa5, sizeof(string_buffer));
    status = parse(small_string, CA_JSON_ITEMS, &count);
    if (status == CA_OK) status = ca_json_string((const unsigned char *)small_string,
        strlen(small_string), &tokens[0], string_buffer.output, 2, &written, &budget);
    intact = 1;
    for (size_t i = 2; i < sizeof(string_buffer); i++) if (((unsigned char *)&string_buffer)[i] != 0xa5) intact = 0;
    check("json-string-capacity-refusal", status == CA_REFUSED && intact);
    const size_t extents[][2] = {{2,1},{0,6},{SIZE_MAX,SIZE_MAX}};
    int extents_refused = 1;
    for (size_t i = 0; i < sizeof(extents) / sizeof(extents[0]); i++) {
        CAJsonToken forged = {CA_STRING,extents[i][0],extents[i][1],SIZE_MAX,0};
        reset_budget(0);
        if (ca_json_string((const unsigned char *)small_string,5,&forged,decoded,
                           sizeof(decoded),&written,&budget) != CA_REFUSED) extents_refused = 0;
        forged.kind = CA_NUMBER; uint64_t ignored = 0; reset_budget(0);
        if (ca_json_u64((const unsigned char *)"0",1,&forged,&ignored,&budget) != CA_REFUSED) extents_refused = 0;
    }
    CAJsonToken wrong = {CA_TRUE,0,4,SIZE_MAX,0}; uint64_t ignored = 0; reset_budget(0);
    if (ca_json_string((const unsigned char *)"true",4,&wrong,decoded,sizeof(decoded),&written,&budget) != CA_REFUSED) extents_refused = 0;
    reset_budget(0);
    if (ca_json_u64((const unsigned char *)"true",4,&wrong,&ignored,&budget) != CA_REFUSED) extents_refused = 0;
    check("json-accessor-forged-token", extents_refused);
    const char *maximum = "18446744073709551615"; uint64_t number = 0;
    status = parse(maximum, CA_JSON_ITEMS, &count);
    if (status == CA_OK) status = ca_json_u64((const unsigned char *)maximum,
        strlen(maximum), &tokens[0], &number, &budget);
    check("json-uint64-maximum", status == CA_OK && number == UINT64_MAX);
    const char *zero = "-0";
    status = parse(zero, CA_JSON_ITEMS, &count); number = UINT64_MAX;
    if (status == CA_OK) status = ca_json_u64((const unsigned char *)zero,
        strlen(zero), &tokens[0], &number, &budget);
    check("json-negative-zero-value", status == CA_OK && number == 0);
    const char *negative = "-1";
    status = parse(negative, CA_JSON_ITEMS, &count);
    check("json-negative-value-refusal", status == CA_OK && count == 1
          && tokens[0].kind == CA_NUMBER
          && ca_json_u64((const unsigned char *)negative,strlen(negative),&tokens[0],&number,&budget) == CA_REFUSED);
    const char *fractional = "1.0";
    status = parse(fractional, CA_JSON_ITEMS, &count);
    check("json-fractional-value-refusal", status == CA_OK && count == 1
          && tokens[0].kind == CA_NUMBER
          && ca_json_u64((const unsigned char *)fractional,strlen(fractional),&tokens[0],&number,&budget) == CA_REFUSED);
    status = parse("[-1,1.0,1e+2,0]", CA_JSON_ITEMS, &count);
    check("json-standard-number-tokens", status == CA_OK && count == 5
          && tokens[1].kind == CA_NUMBER && tokens[2].kind == CA_NUMBER
          && tokens[3].kind == CA_NUMBER && tokens[4].kind == CA_NUMBER);
    const char *not_unsigned[] = {"18446744073709551616", "-1", "1.0", "1e0", "true"};
    all_refused = 1;
    for (size_t i = 0; i < sizeof(not_unsigned) / sizeof(not_unsigned[0]); i++) {
        status = parse(not_unsigned[i], CA_JSON_ITEMS, &count);
        CAJsonKind expected_kind = i == 4 ? CA_TRUE : CA_NUMBER;
        if (status != CA_OK || count != 1 || tokens[0].kind != expected_kind
            || tokens[0].parent != SIZE_MAX
            || ca_json_u64((const unsigned char *)not_unsigned[i],
                strlen(not_unsigned[i]), &tokens[0], &number, &budget) != CA_REFUSED) all_refused = 0;
    }
    check("json-unsigned-type-range", all_refused);
    reset_budget(0); clock_state.now = 58.0;
    check("json-original-deadline", ca_json_parse((const unsigned char *)"{}", 2,
          tokens, CA_JSON_ITEMS, &count, &budget) == CA_REFUSED);
    unsigned char long_string[8194]; memset(long_string, 'a', sizeof(long_string));
    long_string[0] = '"'; long_string[sizeof(long_string) - 1] = '"';
    reset_budget(0); clock_state.step = 60.0;
    check("json-deadline-during-work", ca_json_parse(long_string, sizeof(long_string),
          tokens, CA_JSON_ITEMS, &count, &budget) == CA_REFUSED && clock_state.calls >= 2);
}

static void codec_cases(void) {
    /* Golden values originate in fixtures/capability-bootstrap-v1.json.
       Root must bind that fixture and cross-check these bytes before compilation. */
    const char *manifest = "0000000000000000000000000000000000000000000000000000000000000000";
    unsigned char binding[32], expected[32], record[64], expected_record[64];
    int valid = hex_bytes("3a0bc6fb422f075a384800ea540b7096556b4085e9660837530593c93bee1049", expected, 32);
    reset_budget(100.0);
    int status = ca_authority_binding("/synthetic/trusted-package", manifest,
                                     "synthetic-unqualified", binding, &budget);
    check("authority-binding-golden", valid && status == CA_OK && memcmp(binding, expected, 32) == 0);
    reset_budget(100.0);
    valid = hex_bytes("434150424f4f5431000000080000000040590000000000004063c000000000003a0bc6fb422f075a384800ea540b7096556b4085e9660837530593c93bee1049", expected_record, 64);
    status = ca_bootstrap_record(&budget, expected, record);
    check("bootstrap-golden", valid && status == CA_OK && memcmp(record, expected_record, 64) == 0);
    reset_budget(0.0);
    valid = hex_bytes("434150424f4f543100000008000000000000000000000000404d0000000000003a0bc6fb422f075a384800ea540b7096556b4085e9660837530593c93bee1049", expected_record, 64);
    status = ca_bootstrap_record(&budget, expected, record);
    check("bootstrap-zero-origin", valid && status == CA_OK && memcmp(record, expected_record, 64) == 0);
    reset_budget(100.0); budget.deadline = 159.0;
    check("bootstrap-no-budget-reset", ca_bootstrap_record(&budget, expected, record) == CA_REFUSED);
    int invalid_times_refused = 1;
    const double invalid_times[] = {-1.0,NAN,INFINITY};
    for (size_t i = 0; i < sizeof(invalid_times) / sizeof(invalid_times[0]); i++) {
        reset_budget(100.0); budget.started = invalid_times[i]; budget.deadline = invalid_times[i] + 58.0;
        if (ca_bootstrap_record(&budget,expected,record) != CA_REFUSED) invalid_times_refused = 0;
    }
    check("bootstrap-invalid-original-times", invalid_times_refused);
    reset_budget(100.0);
    check("authority-unset-refuses", ca_authority_binding("UNSET", "UNSET", "UNSET", binding, &budget) == CA_REFUSED);
    reset_budget(100.0);
    check("authority-root-canonical", ca_authority_binding("/synthetic/../other", manifest,
          "synthetic-unqualified", binding, &budget) == CA_REFUSED);
    char oversized[4098]; memset(oversized, 'a', sizeof(oversized)); oversized[0] = '/'; oversized[4097] = 0;
    reset_budget(100.0);
    check("authority-root-bound", ca_authority_binding(oversized, manifest,
          "synthetic-unqualified", binding, &budget) == CA_REFUSED);
    char malformed[65]; memset(malformed,'g',64); malformed[64]=0; reset_budget(100.0);
    int malformed_refused = ca_authority_binding("/synthetic",malformed,"synthetic",binding,&budget) == CA_REFUSED;
    reset_budget(100.0);
    if (ca_authority_binding("/synthetic","0","synthetic",binding,&budget) != CA_REFUSED) malformed_refused = 0;
    char long_profile[130]; memset(long_profile,'a',129);long_profile[129]=0;reset_budget(100.0);
    if (ca_authority_binding("/synthetic",manifest,long_profile,binding,&budget) != CA_REFUSED) malformed_refused = 0;
    reset_budget(100.0);
    if (ca_authority_binding("/synthetic",manifest,"non-ascii-\xc3\xa9",binding,&budget) != CA_REFUSED) malformed_refused = 0;
    check("authority-malformed-literals", malformed_refused);
    /* Canonical component bytes match the Python binding predicate. NUL ends a
       C string; the later JSON-to-path bridge must reject embedded decoded NUL
       before calling this pointer-only literal API. */
    unsigned char path_expected[32];
    valid = hex_bytes("7ee9ccf75307964aafac0b172e4e09b937b04a96ad75d6c6a34336343698f654",path_expected,32);
    reset_budget(100.0);
    status = ca_authority_binding("/synthetic/a\tb",manifest,
                                  "synthetic-unqualified",binding,&budget);
    check("authority-tab-component",valid && status == CA_OK && memcmp(binding,path_expected,32) == 0);
    valid = hex_bytes("778f672e4728cd15784140281fd0e3ec4157219e5c6d78cc02e1c45f87f4e55b",path_expected,32);
    reset_budget(100.0);
    status = ca_authority_binding("/synthetic/a\x7f" "b",manifest,
                                  "synthetic-unqualified",binding,&budget);
    check("authority-del-component",valid && status == CA_OK && memcmp(binding,path_expected,32) == 0);
}

static int low_fd_count(void) {
    int count = 0;
    for (int fd = 3; fd <= 255; fd++) {
        if (fcntl(fd,F_GETFD) >= 0) count++;
        else if (errno != EBADF) return -1;
    }
    return count;
}
static int fd_range_stable = 1;
static int observed_read(const char *path, const CAFileIdentity *expected,
                         unsigned char *output, size_t capacity, size_t *written) {
    int before = low_fd_count();
    int status = ca_read_verified_file(path,expected,output,capacity,written,&budget);
    int after = low_fd_count();
    if (before < 0 || after != before) fd_range_stable = 0;
    return status;
}

static CAFileIdentity file_identity(const struct stat *info) {
    CAFileIdentity result = {0};
    result.device = (uint64_t)info->st_dev; result.inode = (uint64_t)info->st_ino;
    result.size = (uint64_t)info->st_size; result.mode = (uint64_t)info->st_mode;
    result.uid = (uint64_t)info->st_uid; result.gid = (uint64_t)info->st_gid;
    result.mtime_ns = (uint64_t)info->st_mtimespec.tv_sec * 1000000000u + (uint64_t)info->st_mtimespec.tv_nsec;
    result.ctime_ns = (uint64_t)info->st_ctimespec.tv_sec * 1000000000u + (uint64_t)info->st_ctimespec.tv_nsec;
    (void)hex_bytes("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", result.sha256, 32);
    return result;
}

static int filesystem_cases(const char *root) {
    struct stat root_info;
    if (lstat(root, &root_info) || !S_ISDIR(root_info.st_mode) || root_info.st_uid != getuid()
        || (root_info.st_mode & 0777) != 0700) return 0;
    char directory[4096], path[4096], link_path[4096], fifo_path[4096], parent_link[4096], indirect_path[4096];
    int setup = 1, fd = -1, source_created = 0, link_created = 0, fifo_created = 0, parent_created = 0;
    if (snprintf(directory, sizeof(directory), "%s/native-XXXXXX", root) >= (int)sizeof(directory)
        || !mkdtemp(directory)) return 0;
    if (snprintf(path, sizeof(path), "%s/source", directory) >= (int)sizeof(path)
        || snprintf(link_path, sizeof(link_path), "%s/link", directory) >= (int)sizeof(link_path)
        || snprintf(fifo_path, sizeof(fifo_path), "%s/fifo", directory) >= (int)sizeof(fifo_path)
        || snprintf(parent_link,sizeof(parent_link),"%s/parent-link",directory) >= (int)sizeof(parent_link)
        || snprintf(indirect_path,sizeof(indirect_path),"%s/parent-link/source",directory) >= (int)sizeof(indirect_path)) {
        setup = 0; goto cleanup;
    }
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) { setup = 0; goto cleanup; }
    source_created = 1;
    if (write(fd, "abc", 3) != 3) { setup = 0; goto cleanup; }
    struct stat info;
    if (fstat(fd, &info)) { setup = 0; goto cleanup; }
    int closing_fd = fd; fd = -1;
    if (close(closing_fd)) { setup = 0; goto cleanup; }
    CAFileIdentity expected = file_identity(&info);
    unsigned char output[8]; size_t written = 0; reset_budget(100.0);
    check("file-read-verified", observed_read(path, &expected, output, sizeof(output), &written) == CA_OK
          && written == 3 && memcmp(output, "abc", 3) == 0);
    CAFileIdentity changed = expected; changed.inode++; reset_budget(100.0);
    check("file-identity-refusal", observed_read(path, &changed, output, sizeof(output), &written) == CA_REFUSED);
    changed = expected; changed.sha256[0] ^= 1; reset_budget(100.0);
    check("file-digest-refusal", observed_read(path, &changed, output, sizeof(output), &written) == CA_REFUSED);
    reset_budget(100.0);
    check("file-buffer-bound", observed_read(path, &expected, output, 2, &written) == CA_REFUSED);
    reset_budget(100.0);clock_state.now=158.0;
    check("file-expired-entry", observed_read(path,&expected,output,sizeof(output),&written) == CA_REFUSED);
    reset_budget(100.0);clock_state.watch_file=1;clock_state.device=expected.device;clock_state.inode=expected.inode;
    check("file-deadline-after-open", observed_read(path,&expected,output,sizeof(output),&written) == CA_REFUSED && clock_state.seen_file);
    reset_budget(100.0);clock_state.watch_file=2;clock_state.device=expected.device;clock_state.inode=expected.inode;
    check("file-deadline-after-close", observed_read(path,&expected,output,sizeof(output),&written) == CA_REFUSED && clock_state.seen_file);
    if (symlink("source", link_path)) { setup = 0; goto cleanup; }
    link_created = 1;
    if (mkfifo(fifo_path, 0600)) { setup = 0; goto cleanup; }
    fifo_created = 1;
    reset_budget(100.0);
    check("file-symlink-refusal", observed_read(link_path, &expected, output, sizeof(output), &written) == CA_REFUSED);
    reset_budget(100.0);
    check("file-fifo-nonblocking", observed_read(fifo_path, &expected, output, sizeof(output), &written) == CA_REFUSED);
    if (symlink(".",parent_link)) { setup=0;goto cleanup; }
    parent_created=1;reset_budget(100.0);
    check("file-parent-symlink-refusal", observed_read(indirect_path,&expected,output,sizeof(output),&written) == CA_REFUSED);
    check("file-fd-range-stable",fd_range_stable);
cleanup:
    if (fd >= 0) {
        int owned_fd = fd; fd = -1;
        if (close(owned_fd)) setup = 0;
    }
    if (fifo_created && unlink(fifo_path)) setup = 0;
    if (parent_created && unlink(parent_link)) setup = 0;
    if (link_created && unlink(link_path)) setup = 0;
    if (source_created && unlink(path)) setup = 0;
    if (rmdir(directory)) setup = 0;
    return setup;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    budget_cases(); json_cases(); codec_cases();
    if (!filesystem_cases(argv[1])) { fputs("fixture=refused\n", stderr); return 2; }
    printf("cases=%u failures=%u\n", cases, failures);
    return failures ? 1 : 0;
}
