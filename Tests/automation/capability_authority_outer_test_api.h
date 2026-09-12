#ifndef CA_OUTER_TEST_API_H
#define CA_OUTER_TEST_API_H
#include "capability_authority_entry.h"
#include <time.h>
#include <sys/types.h>
/* These declarations expose the same internal conversion/initialization/adapter
   only in CA_AUTHORITY_OUTER_TEST. They are not a production admission API. */
int ca_outer_test_timespec(const struct timespec *, double *);
int ca_outer_test_budget(double, CABudget *);
int ca_outer_test_run(int, char *const [], char *const []);
int ca_test_outer_clock(int, struct timespec *);
int ca_test_outer_dispatch(const CAExecutionPins *, size_t, const char *const [], CABudget *);
ssize_t ca_test_outer_write(int, const void *, size_t);
#define CA_TEST_ROOT "/synthetic/trusted-package"
#define CA_TEST_SHA "0000000000000000000000000000000000000000000000000000000000000000"
#define CA_TEST_PROFILE "synthetic-unqualified"
#define CA_TEST_INTERPRETER "/synthetic/runtime/python"
#define CA_TEST_SHIM "/synthetic/authority/shim.py"
/* Immutable build fixture, never selected from the argv/environment under test. */
#define CA_OUTER_TEST_PINS { CA_TEST_ROOT, CA_TEST_SHA, CA_TEST_PROFILE, \
    CA_TEST_INTERPRETER, CA_TEST_SHA, CA_TEST_SHIM, CA_TEST_SHA }
#endif
