#ifndef CA_HANDOFF_TEST_HOOKS_H
#define CA_HANDOFF_TEST_HOOKS_H
#include "capability_authority_files_test_hooks.h"
#include <stddef.h>
#include <stdint.h>
enum {
 HT_NONE, HT_PIPE_ERROR, HT_PIPE_LATE, HT_GETFL_ERROR, HT_SETFL_ERROR,
 HT_GETFD_ERROR, HT_SETFD_ERROR, HT_DUP_ERROR, HT_DUP_LATE,
 HT_OLD_CLOSE_ERROR, HT_WRITE_SHORT, HT_WRITE_ZERO, HT_WRITE_EINTR,
 HT_WRITE_EAGAIN, HT_WRITE_EPIPE, HT_WRITE_ERROR, HT_WRITE_LATE,
 HT_WRITER_CLOSE_ERROR, HT_WRITER_CLOSE_LATE, HT_CLEAR_ERROR,
 HT_CLEAR_LATE, HT_EXEC_ERROR, HT_EXEC_LATE
};
typedef struct {
 int fault, stdio_pipe, active;
 unsigned pipe_calls, fcntl_calls, dup_calls, write_calls, exec_calls, fired;
 unsigned invalid, live, peak_live, close_calls, writer_closed, copied;
 unsigned shim_reads, final_shim_reads, final_package_scans, last_observation;
 unsigned writer_closed_at_final;
 uint64_t shim_device, shim_inode, package_device, package_inode;
 double *clock_value;
 unsigned char record[64]; size_t record_size;
 char arguments[17][4097]; size_t argument_count;
 const char *expected_interpreter, *expected_shim;
 const char *const *expected_operands; size_t expected_count;
 void (*at_pipe)(void *); void *at_pipe_context;
} CAHandoffTestState;
extern CAHandoffTestState ca_handoff_test;
void ca_handoff_test_reset(void);
int ca_handoff_test_finish(void);
#endif
