#ifndef CAPABILITY_FILES_TEST_HOOKS_H
#define CAPABILITY_FILES_TEST_HOOKS_H
#include <stddef.h>
#include <stdint.h>
enum {
    FT_NONE, FT_WRONG_UID, FT_READ_ERROR, FT_CLOSE_UNCERTAIN,
    FT_READ_LATE, FT_CLOSE_LATE, FT_READDIR_ERROR, FT_FDOPENDIR_ERROR,
    FT_CLOSEDIR_UNCERTAIN, FT_ACCESS_ERROR
};
typedef struct {
    int fault;
    uint64_t device, inode;
    unsigned fired, runtime_observations, open_attempts, before_final, invalid_close, leaked;
    uint64_t runtime_devices[8], runtime_inodes[8];
    size_t runtime_count;
    double *clock_value;
    const char *denied_component;
    void (*final_action)(void *);
    void *action_context;
} CAFileTestState;
extern CAFileTestState ca_file_test;
/* Reset only after finish has reclaimed any leaked test-owned descriptions. */
void ca_files_test_reset(void);
int ca_files_test_finish(void);
void ca_files_test_before_final(void);
#endif
